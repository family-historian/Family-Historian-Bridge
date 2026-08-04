-- Read-only query helpers -- fhBridge.getFamilyGroup, fhBridge.getAllDetails,
-- fhBridge.getAncestors, fhBridge.searchByName, fhBridge.getFactsByTag. Unlike sourceHelper.lua/
-- sessionLogHelper.lua, every fh* function this module calls (fhNewItemPtr, the
-- item-pointer MoveToFirstRecord/MoveTo/MoveNext/MoveToFirstChildItem/IsNotNull/
-- IsNull methods, fhGetValueAsLink, fhGetTag, fhGetItemText, fhGetRecordId,
-- fhGetQualifiedRecordId, fhGetDisplayText, fhGetValueType, fhGetValueAsRichText,
-- fhHasChildItem, fhIndGetName) is a read primitive already granted in sandbox.lua's
-- Read-only half -- so sandbox.lua wires this module's functions through for BOTH
-- access modes, not read-write only.
--
-- Every function here returns plain JSON-safe tables (numbers/strings/booleans/
-- nested tables), never a raw Item Pointer object: jsonEncode.lua cannot encode a
-- pointer (or any other FH userdata), so a helper that handed one back -- directly or
-- nested inside a table -- would break the moment a run_lua script returned it.
--
-- Every function also accepts a qualified id string (e.g. "I219", exactly the form
-- fhGetQualifiedRecordId/the .qualifiedId field on every descriptor this module
-- returns already use) anywhere it takes a pointer, as an alternative to a live Item
-- Pointer -- see resolvePointer below. This closes the loop a caller would otherwise
-- have to hand-roll themselves (fhNewItemPtr():MoveToRecordById(tag, id)) every time
-- it wants more detail on someone getFamilyGroup/getAncestors just returned, since
-- those results already crossed the JSON boundary and can't carry a live pointer.

local M = {}

-- Record-tag letter prefixes fhGetQualifiedRecordId uses (fhGetQualifiedRecordId.htm's
-- own table), limited to the tags MoveToRecordById actually accepts (MoveToRecordById.htm's
-- sRecordTag list) -- 'H' (Header) and 'A' (Address) are real qualified-id prefixes but
-- have no MoveToRecordById equivalent, so a qualified id with either prefix falls through
-- to resolvePointer's own "not resolvable" error rather than guessing a wrong tag.
local QUALIFIED_ID_PREFIX_TAG = {
  F = "FAM", I = "INDI", O = "OBJE", N = "NOTE", R = "REPO", S = "SOUR",
  U = "SUBM", B = "SUBN", P = "_PLAC", E = "_RNOT", T = "_SRCT",
}

-- Resolves a qualified id string (e.g. "I219") to a live Item Pointer via
-- MoveToRecordById, or raises a clear error if the prefix isn't a resolvable record
-- type or no such record exists.
local function resolveQualifiedId(qualifiedId)
  local prefix, numText = qualifiedId:match("^(%a)(%d+)$")
  local tag = prefix and QUALIFIED_ID_PREFIX_TAG[prefix]
  if not tag then
    error("could not resolve qualified id '" .. tostring(qualifiedId) .. "' -- expected a " ..
      "letter prefix (F/I/O/N/R/S/U/B/P/E/T) followed by digits, e.g. 'I219'")
  end
  local ptr = fhNewItemPtr()
  ptr:MoveToRecordById(tag, tonumber(numText))
  if ptr:IsNull() then
    error("no " .. tag .. " record found for qualified id '" .. qualifiedId .. "'")
  end
  return ptr
end

-- Every public function's pointer argument goes through this first: a string is
-- treated as a qualified id and resolved via resolveQualifiedId, anything else
-- (a live Item Pointer, or nil/false) is passed through unchanged for the caller's
-- own nil/IsNull check to catch.
local function resolvePointer(value)
  if type(value) == "string" then
    return resolveQualifiedId(value)
  end
  return value
end

-- Individual record summary -- every getFamilyGroup/getAncestors entry carries one of
-- these instead of a pointer, see the module comment above.
local function indiDescriptor(ptr)
  return {
    id = fhGetRecordId(ptr),
    qualifiedId = fhGetQualifiedRecordId(ptr),
    name = fhIndGetName(ptr),
    sex = fhGetItemText(ptr, "~.SEX"),
  }
end

-- Case-insensitive substring test: true if needle occurs anywhere in haystack,
-- ignoring case. An empty/nil needle always matches (searchByName treats an omitted
-- forename/surname as "don't filter on this part"); a nil haystack is treated as ""
-- (an Individual with no NAME item at all still gets a real, if empty, GIVEN_ALL/
-- SURNAME back from fhGetItemText -- this handles the belt-and-braces case).
local function containsCI(haystack, needle)
  if needle == nil or needle == "" then
    return true
  end
  return (haystack or ""):lower():find(needle:lower(), 1, true) ~= nil
end

-- Builds a lookup set from getFactsByTag's `tags` argument, which may be a single tag
-- string (e.g. "CENS") or an array of tag strings (e.g. {"BIRT", "DEAT"}) -- accepting
-- either shape means a caller after just one fact type never has to wrap it in a
-- table. Errors loudly on nil, "", an empty table, or a table containing a
-- non-string/empty entry -- a filter that silently matched nothing (or crashed later
-- on a bad comparison) would be a worse failure mode than a clear error up front.
local function tagSet(tags, callerName)
  local list = tags
  if type(tags) == "string" then
    list = { tags }
  end
  if type(list) ~= "table" then
    error(callerName .. ": tags must be a tag string (e.g. 'CENS') or an array of tag strings")
  end
  local set = {}
  local count = 0
  for _, tag in ipairs(list) do
    if type(tag) ~= "string" or tag == "" then
      error(callerName .. ": every tag must be a non-empty string (got " .. tostring(tag) .. ")")
    end
    set[tag] = true
    count = count + 1
  end
  if count == 0 then
    error(callerName .. ": tags must include at least one tag")
  end
  return set
end

-- Family record summary -- identifies which FAMS/FAMC record connects a relative back
-- to the individual passed in, e.g. two getFamilyGroup(ptr, "siblings") entries with
-- different .family.id values are only half-siblings (share one FAMC, not two).
local function famDescriptor(ptr)
  return {
    id = fhGetRecordId(ptr),
    qualifiedId = fhGetQualifiedRecordId(ptr),
  }
end

-- Walks every linkTag child of indiPtr (e.g. every FAMS or FAMC link on an
-- Individual) and calls onFamily(familyPtr) for each one that resolves. MoveNext's
-- "SAME_TAG" form (MoveNext.htm) is what lets this see more than the first link --
-- FH stores multiple FAMS/FAMC links as same-tag siblings, not one multi-valued
-- field (see sessionLogHelper.lua's own ptr:MoveTo(parent, "~.TAG") use for the same
-- "~.TAG" data-reference shape, and fh-help's AllSurnames.htm sample for the same
-- MoveTo + MoveNext("SAME_TAG") walk over "~.FAMS"). Skips a link that fails to
-- resolve -- FH's own pointers are "safe" (Null rather than a crash), but skipping
-- explicitly costs nothing here.
local function eachFamilyLink(indiPtr, linkTag, onFamily)
  local link = fhNewItemPtr()
  link:MoveTo(indiPtr, "~." .. linkTag)
  while link:IsNotNull() do
    local fam = fhGetValueAsLink(link)
    if fam and fam:IsNotNull() then
      onFamily(fam)
    end
    link:MoveNext("SAME_TAG")
  end
end

-- Walks every memberTag child of a Family record (HUSB, WIFE, or CHIL -- CHIL in
-- particular is commonly more than one) and calls onIndi(indiPtr) for each one that
-- resolves. Same "SAME_TAG" reasoning as eachFamilyLink above.
local function eachFamilyMember(famPtr, memberTag, onIndi)
  local member = fhNewItemPtr()
  member:MoveTo(famPtr, "~." .. memberTag)
  while member:IsNotNull() do
    local indi = fhGetValueAsLink(member)
    if indi and indi:IsNotNull() then
      onIndi(indi)
    end
    member:MoveNext("SAME_TAG")
  end
end

local VALID_FAMILY_GROUP_TYPES = { all = true, parents = true, siblings = true, spouses = true }

-- familyHelper.getFamilyGroup(indiPtr, type)
-- indiPtr may be a live Item Pointer or a qualified id string (e.g. "I219") -- see
-- resolvePointer above.
--
-- type: one of "all" (default), "parents", "siblings", "spouses". Walks every FAMC
-- record the individual is a child in for "parents"/"siblings", and every FAMS
-- record they're a spouse in for "spouses" -- not just the first of each, per FH's
-- own Data Structure docs ("there can be more than one" family-as-child, and any
-- number of families-as-spouse for someone married more than once).
--
-- Returns an array of { relationship, individual, family }: relationship is
-- "father"/"mother" (read off the FAMC record's HUSB/WIFE link itself, not the
-- parent's own SEX field, which FH allows to differ from the HUSB/WIFE role -- see
-- item_pointer.htm's "Prohibited Actions" section), "sibling" (every other CHIL in
-- the same FAMC record), or "spouse" (every other HUSB/WIFE in the same FAMS
-- record). individual is an indiDescriptor; family identifies which FAMC/FAMS
-- record the relationship came through, so a caller can tell full siblings / a
-- remarriage apart from half-siblings / a different marriage by comparing
-- .family.id across entries. Never includes the individual passed in. Deduplicates
-- by relationship + id, so a person reachable via more than one FAMC/FAMS record
-- under the same relationship is only reported once.
function M.getFamilyGroup(indiPtr, type)
  indiPtr = resolvePointer(indiPtr)
  type = type or "all"
  if not VALID_FAMILY_GROUP_TYPES[type] then
    error("getFamilyGroup: type must be one of 'all', 'parents', 'siblings', 'spouses' (got '" .. tostring(type) .. "')")
  end
  if not indiPtr or indiPtr:IsNull() then
    error("getFamilyGroup: indiPtr must point to an Individual record")
  end
  if fhGetTag(indiPtr) ~= "INDI" then
    error("getFamilyGroup: indiPtr must point to an Individual record (got a '" .. tostring(fhGetTag(indiPtr)) .. "' record)")
  end

  local selfId = fhGetRecordId(indiPtr)
  local seen = {}
  local results = {}

  local function add(relationship, targetPtr, viaFam)
    if not targetPtr or targetPtr:IsNull() then return end
    local id = fhGetRecordId(targetPtr)
    if id == selfId then return end
    local key = relationship .. ":" .. tostring(id)
    if seen[key] then return end
    seen[key] = true
    table.insert(results, {
      relationship = relationship,
      individual = indiDescriptor(targetPtr),
      family = famDescriptor(viaFam),
    })
  end

  if type == "all" or type == "parents" then
    eachFamilyLink(indiPtr, "FAMC", function(fam)
      eachFamilyMember(fam, "HUSB", function(p) add("father", p, fam) end)
      eachFamilyMember(fam, "WIFE", function(p) add("mother", p, fam) end)
    end)
  end

  if type == "all" or type == "siblings" then
    eachFamilyLink(indiPtr, "FAMC", function(fam)
      eachFamilyMember(fam, "CHIL", function(p) add("sibling", p, fam) end)
    end)
  end

  if type == "all" or type == "spouses" then
    eachFamilyLink(indiPtr, "FAMS", function(fam)
      eachFamilyMember(fam, "HUSB", function(p) add("spouse", p, fam) end)
      eachFamilyMember(fam, "WIFE", function(p) add("spouse", p, fam) end)
    end)
  end

  return results
end

-- familyHelper.getAncestors(indiPtr, maxGenerations)
-- indiPtr may be a live Item Pointer or a qualified id string (e.g. "I219") -- see
-- resolvePointer above.
--
-- Breadth-first walk up every FAMC record from indiPtr: generation 1 is indiPtr's
-- own parents, generation 2 their parents, and so on. maxGenerations (optional)
-- caps how far up to walk; omit/nil for no limit (bounded naturally by the tree's
-- own depth, and by watchdog.lua's instruction budget on a truly enormous project).
--
-- Returns an array of { generation, line, individual, family }: line is an array of
-- "father"/"mother" steps from indiPtr down to this ancestor (e.g. {"mother",
-- "father"} is the maternal grandfather) -- deliberately not resolved to an English
-- title like "grandfather"/"great-grandmother", since that naming is a presentation
-- choice a caller can build from generation + line however it needs. Each ancestor
-- is visited at most once, at the shallowest generation it's reachable from
-- (pedigree collapse) -- also what keeps this from looping forever on a malformed
-- project where a FAMC chain cycles back on itself, which a correctly-formed tree
-- can't do but this doesn't assume.
function M.getAncestors(indiPtr, maxGenerations)
  indiPtr = resolvePointer(indiPtr)
  if not indiPtr or indiPtr:IsNull() then
    error("getAncestors: indiPtr must point to an Individual record")
  end
  if fhGetTag(indiPtr) ~= "INDI" then
    error("getAncestors: indiPtr must point to an Individual record (got a '" .. tostring(fhGetTag(indiPtr)) .. "' record)")
  end

  local results = {}
  local visited = { [fhGetRecordId(indiPtr)] = true }
  local frontier = { { ptr = indiPtr, line = {} } }
  local generation = 0

  while #frontier > 0 and (not maxGenerations or generation < maxGenerations) do
    generation = generation + 1
    local nextFrontier = {}

    local function visit(role, p, fam, parentLine)
      local id = fhGetRecordId(p)
      if visited[id] then return end
      visited[id] = true
      local line = {}
      for i, step in ipairs(parentLine) do line[i] = step end
      line[#line + 1] = role
      table.insert(results, {
        generation = generation,
        line = line,
        individual = indiDescriptor(p),
        family = famDescriptor(fam),
      })
      table.insert(nextFrontier, { ptr = p, line = line })
    end

    for _, entry in ipairs(frontier) do
      eachFamilyLink(entry.ptr, "FAMC", function(fam)
        eachFamilyMember(fam, "HUSB", function(p) visit("father", p, fam, entry.line) end)
        eachFamilyMember(fam, "WIFE", function(p) visit("mother", p, fam, entry.line) end)
      end)
    end

    frontier = nextFrontier
  end

  return results
end

-- Resolves a link-classed item to a plain descriptor of the record it points to
-- (tag, id, qualifiedId, and a display text) -- never the raw target pointer
-- itself, for the same JSON-safety reason as the rest of this module. Deliberately
-- does NOT recurse into the target's own fields the way describeItem recurses into
-- a plain item's children -- following FAMS/FAMC/HUSB/WIFE/CHIL links back out would
-- walk the whole connected tree, not "the record passed in", and could cycle
-- forever (an Individual's FAMS points to a Family whose HUSB points back to that
-- same Individual).
local function linkDescriptor(ptr)
  local target = fhGetValueAsLink(ptr)
  if not target or target:IsNull() then
    return nil
  end
  return {
    tag = fhGetTag(target),
    id = fhGetRecordId(target),
    qualifiedId = fhGetQualifiedRecordId(target),
    text = fhGetDisplayText(target),
  }
end

-- Recursively describes one item and every child item beneath it (fields can have
-- subfields "indefinitely" per the Data Structure docs) as a plain tree: { tag,
-- id/qualifiedId (record items only -- fhGetQualifiedRecordId returns "" for a
-- non-record item, per its own docs), value (items that actually store a value --
-- fhGetValueType returns "" for records/flags/complex container items), link
-- (link-classed items only), children (any item with fhHasChildItem true) }.
-- fhGetDisplayText(ptr, "~", "min") is used generically for .value across every
-- other value type (text/date/integer/age/link/blob) rather than branching on
-- fhGetValueType case by case, EXCEPT richtext: fhGetItemText/fhGetValueAsText/
-- fhGetDisplayText all return a Notes-style field's raw FTF markup, not readable
-- prose (see gedcom-knowledge-corpus "Getting clean plain text out of a rich-text
-- field"), so richtext goes through fhGetValueAsRichText(ptr):GetPlainText() instead.
local function describeItem(ptr)
  local node = { tag = fhGetTag(ptr) }

  local qualifiedId = fhGetQualifiedRecordId(ptr)
  if qualifiedId ~= "" then
    node.id = fhGetRecordId(ptr)
    node.qualifiedId = qualifiedId
  end

  local valueType = fhGetValueType(ptr)
  if valueType ~= "" then
    if valueType == "richtext" then
      node.value = fhGetValueAsRichText(ptr):GetPlainText()
    else
      node.value = fhGetDisplayText(ptr, "~", "min")
    end
    if valueType == "link" then
      node.link = linkDescriptor(ptr)
    end
  end

  if fhHasChildItem(ptr) then
    local children = {}
    local child = fhNewItemPtr()
    child:MoveToFirstChildItem(ptr)
    while child:IsNotNull() do
      table.insert(children, describeItem(child))
      child:MoveNext()
    end
    node.children = children
  end

  return node
end

-- familyHelper.getAllDetails(ptr)
-- ptr may be a live Item Pointer or a qualified id string (e.g. "I219", "S1191",
-- "F13" -- any record type, not just Individuals) -- see resolvePointer above. A
-- qualified id always resolves to that record's own top-level pointer; to describe
-- a single field/Fact instead of a whole record, pass a live pointer positioned on
-- it (a qualified id has no way to address a sub-field).
--
-- Returns every value stored against ptr -- its own tag/value (if any) plus every
-- child/subfield beneath it, recursively -- as one plain JSON-safe tree (see
-- describeItem above). Works on any item pointer, not just a top-level record: a
-- Fact item works just as well as an Individual/Family/Source record itself.
function M.getAllDetails(ptr)
  ptr = resolvePointer(ptr)
  if not ptr or ptr:IsNull() then
    error("getAllDetails: pointer must not be null")
  end
  return describeItem(ptr)
end

-- familyHelper.getFactsByTag(ptr, tags)
-- ptr may be a live Item Pointer or a qualified id string (e.g. "I219") -- see
-- resolvePointer above. Works on any record type, not just Individuals -- CENS/BIRT
-- are Individual concepts, but MARR/DIV live on FAM records, and this doesn't care
-- which kind of record ptr actually is.
--
-- tags is either one tag string (e.g. "CENS") or an array of tag strings (e.g.
-- {"BIRT", "DEAT"}) -- FH's own resolved tag, exact and case-sensitive, the same
-- string describeItem's own .tag field already returns (custom facts resolve to their
-- own real tag, e.g. "_ATTR-REGIMENT", not a generic FACT/EVEN + TYPE pair -- see
-- run-lua-guidance-call-shape-gotchas).
--
-- Only looks at ptr's own DIRECT children -- the "1st level" a Fact tag actually
-- lives at on a record -- not recursively into subfields, so filtering for "DATE"
-- would not reach down into every fact's own DATE subfield.
--
-- Returns an array, one full getAllDetails-shape tree per matching child, in record
-- order -- not deduped or sorted, since a repeated tag (multiple CENS entries, a
-- Rejected + Preferred BIRT) is exactly what this exists to surface, not collapse.
-- An empty array (not an error) means no matching facts were found -- same philosophy
-- as searchByName: a legitimate answer, not a failure.
function M.getFactsByTag(ptr, tags)
  ptr = resolvePointer(ptr)
  if not ptr or ptr:IsNull() then
    error("getFactsByTag: pointer must not be null")
  end
  local wanted = tagSet(tags, "getFactsByTag")

  local results = {}
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(ptr)
  while child:IsNotNull() do
    if wanted[fhGetTag(child)] then
      table.insert(results, describeItem(child))
    end
    child:MoveNext()
  end

  return results
end

-- familyHelper.searchByName(forename, surname)
-- Finds every Individual record whose given name(s) contain `forename` and whose
-- surname contains `surname`, both matched case-insensitively as substrings -- not
-- exact/whole-word matches -- so searchByName("Robert", "Taubman") also matches
-- "Robert Henry TAUBMAN", not just an exact "Robert Taubman". Either argument may be
-- omitted or "" to skip filtering on that part of the name (searchByName(nil,
-- "Taubman") returns every Taubman regardless of forename); at least one of the two
-- must be given a non-empty value, or this errors -- an unfiltered "every Individual
-- in the project" scan is almost never what a search call actually wants, and a
-- caller that does want that can use fhu.records("INDI") directly instead.
--
-- Matches against the NAME field's GIVEN_ALL/SURNAME Data Reference qualifiers (see
-- gedcom-knowledge-corpus's "Name qualifiers" entry) rather than the NAME field's raw
-- stored text or fhIndGetName's display string: GIVEN_ALL is every given name (not
-- just the first), and SURNAME is FH's own resolved surname regardless of how that
-- particular record orders/prefixes its name parts, so this matches consistently
-- across records that don't all spell their NAME field the same way.
--
-- Returns an array of indiDescriptor -- the same {id, qualifiedId, name, sex} shape
-- as getFamilyGroup/getAncestors' own .individual field -- in FH's own record order
-- (creation order, not sorted alphabetically). Walks every Individual record in the
-- project once (MoveToFirstRecord("INDI") + MoveNext(), the same record-iteration
-- shape as sourceHelper.lua's own findRecord), so cost scales with the project's
-- total Individual count -- fine for an interactive lookup, not meant for a tight
-- loop calling it repeatedly.
function M.searchByName(forename, surname)
  if (forename == nil or forename == "") and (surname == nil or surname == "") then
    error("searchByName: supply at least one of forename or surname to search on")
  end

  local results = {}
  local ptr = fhNewItemPtr()
  ptr:MoveToFirstRecord("INDI")
  while ptr:IsNotNull() do
    local given = fhGetItemText(ptr, "~.NAME:GIVEN_ALL")
    local family = fhGetItemText(ptr, "~.NAME:SURNAME")
    if containsCI(given, forename) and containsCI(family, surname) then
      table.insert(results, indiDescriptor(ptr))
    end
    ptr:MoveNext()
  end

  return results
end

return M
