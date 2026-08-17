-- Read-only query helpers -- fhBridge.getFamilyGroup, fhBridge.getAllDetails,
-- fhBridge.getAncestors, fhBridge.getDescendants, fhBridge.searchByName,
-- fhBridge.getFactsByTag. Unlike sourceHelper.lua/
-- sessionLogHelper.lua, every fh* function this module calls (fhNewItemPtr, the
-- item-pointer MoveToFirstRecord/MoveTo/MoveNext/MoveToFirstChildItem/IsNotNull/
-- IsNull methods, fhGetValueAsLink, fhGetTag, fhGetItemText, fhGetRecordId,
-- fhGetQualifiedRecordId, fhGetDisplayText, fhGetValueType, fhGetValueAsRichText,
-- fhGetDataClass, fhGetValueAsText, fhHasChildItem, fhIndGetName,
-- fhCallBuiltInFunction) is a read primitive already
-- granted in sandbox.lua's
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

-- Splits a string into its qualified-id-shaped prefix letter and numeric text (e.g.
-- "I219" -> "I", "219"), or nil if it isn't shaped like one at all -- the one place this
-- pattern is written, shared by resolveQualifiedId (any tag, error on mismatch) and
-- parseQualifiedId (one specific tag, nil on mismatch) below so the shape itself can't
-- drift between the two.
local function qualifiedIdShape(value)
  return value:match("^(%a)(%d+)$")
end

-- Resolves a qualified id string (e.g. "I219") to a live Item Pointer via
-- MoveToRecordById, or raises a clear error if the prefix isn't a resolvable record
-- type or no such record exists.
local function resolveQualifiedId(qualifiedId)
  local prefix, numText = qualifiedIdShape(qualifiedId)
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

-- Tag-scoped counterpart to resolveQualifiedId above: returns the parsed numeric id if
-- value has the id shape this specific tag's own qualified id uses (e.g. "S1186" for
-- SOUR, via the same QUALIFIED_ID_PREFIX_TAG resolveQualifiedId reads) --
-- or nil (never an error) if it doesn't, so a caller can fall through to a different
-- interpretation of the same string (issue #100: sourceHelper.lua's resolveByNameOrId
-- uses this to recognize a qualified id string like "S1186" before falling into its own
-- Title/NAME text-match branch). Deliberately tag-scoped rather than reusing
-- resolveQualifiedId's own global prefix lookup: a string shaped like a DIFFERENT tag's
-- qualified id (e.g. "T4", a _SRCT template id, passed to a SOUR lookup) must not resolve
-- here at all -- it means "not this tag's id", not "some other record entirely" -- so it
-- falls through the same as any other non-matching string would.
local function parseQualifiedId(tag, value)
  if type(value) ~= "string" then return nil end
  local prefix, numText = qualifiedIdShape(value)
  if not prefix or QUALIFIED_ID_PREFIX_TAG[prefix] ~= tag then return nil end
  return tonumber(numText)
end

-- Every public function's pointer argument goes through this first: a string is
-- treated as a qualified id and resolved via resolveQualifiedId, anything else
-- (a live Item Pointer, or nil/false) is passed through unchanged for the caller's
-- own nil/IsNull check to catch. A number raises a specific error instead of falling
-- through: every descriptor this module (and getFamilyGroup/getAncestors/searchByName's
-- results) returns carries both .id (a bare number) and .qualifiedId (a string like
-- "I219") -- passing .id here by mistake is an easy slip (issue #65) that would
-- otherwise only surface many calls later as Lua's own opaque "attempt to index a
-- number value", once something tries to call a method on it. A bare number is also
-- inherently ambiguous here regardless: unlike getFamilyGroup/getAncestors/
-- getDescendants (Individual-only, where a bare id could only ever mean "I<n>"),
-- getAllDetails/getFactsByTag accept any record type's qualified id, so a number alone
-- doesn't say whether it means an INDI, FAM, SOUR, or other record -- kept uniformly
-- string-only across every function rather than guessing by function, so the contract
-- doesn't vary from one fhBridge.* call to the next.
local function resolvePointer(value)
  if type(value) == "string" then
    return resolveQualifiedId(value)
  end
  if type(value) == "number" then
    error("expected a qualified id string like 'I219', got the number " .. tostring(value) ..
      " -- pass the .qualifiedId field (e.g. from getFamilyGroup/getAncestors/getDescendants/" ..
      "searchByName), not .id")
  end
  return value
end

-- Exported so sourceHelper.lua's getPopulatedTemplateFields can accept a qualified id
-- string too, the same as every function in this module -- sourceHelper.lua already
-- require()s this module (for getAllDetails), so this just reuses the one resolution
-- rule instead of a second copy.
M.resolvePointer = resolvePointer

-- Exported for the same reason as resolvePointer above: sourceHelper.lua's
-- resolveByNameOrId (issue #100) reuses this rather than hand-rolling a second,
-- independently maintained prefix regex per tag.
M.parseQualifiedId = parseQualifiedId

-- familyHelper.pointerProblem(v) (issue #110, docs/adr/0027): the shared check every
-- validate*/get* function's own "not ptr or ptr:IsNull()" idiom used to hand-roll --
-- copy-pasted across this module and richTextHelper.lua/sourceHelper.lua/
-- sessionLogHelper.lua, and each copy assumed any non-nil value is pointer-shaped
-- enough to support :IsNull(). It isn't: a plain string, a number, a boolean, or a
-- wrong-shaped table (e.g. one of this module's own {id, qualifiedId, ...} descriptor
-- tables, handed back to a function expecting a live pointer) all raised Lua's own raw
-- "attempt to call/index a ... value" error instead of the calling function's own
-- intended message -- confirmed live, issue #110: a run_lua call passed an
-- action-description string as sessionLogHelper.logActivity's ptrRecord, and got
-- "attempt to call a nil value (method 'IsNull')" instead of logActivity's own message,
-- indistinguishable from an internal bridge crash.
--
-- Returns nil when v is a usable, non-null live Item Pointer -- the caller proceeds.
-- Otherwise returns a string to append to the caller's own "X must point to Y" message:
-- "" when v is nil or a genuinely-null pointer (the right shape, just empty -- the
-- caller's own message already says everything useful; echoing a null pointer's own
-- address would be noise, not help), or " -- got <type> (<value>), not a live Item
-- Pointer" when v is any other wrong-shaped value -- the case this fix actually targets,
-- naming what was actually passed so the mistake is diagnosable from the error text
-- alone.
--
-- v:IsNull() is pcall'd, not type()-checked, since a live Item Pointer's real Lua type
-- isn't fixed across this project (userdata in FH itself; a table with an __index
-- metatable in every *.test.lua fake pointer), and pcall handles both uniformly with no
-- branching -- the same "wrap the risky call" idiom sessionSettings.lua's
-- loadOptions/saveOptions already use. Considered and rejected: bare duck-typing (`if v
-- and v.IsNull then`) still raises Lua's own raw error for a number/boolean v, since
-- field access alone on a non-indexable value errors before the .IsNull lookup ever
-- runs -- confirmed empirically (docs/adr/0027).
local function describeWrongType(v)
  local text = tostring(v)
  if #text > 60 then
    text = text:sub(1, 60) .. "..."
  end
  return " -- got " .. type(v) .. " (" .. text .. "), not a live Item Pointer"
end

local function pointerProblem(v)
  if v == nil then
    return ""
  end
  local ok, isNull = pcall(function() return v:IsNull() end)
  if not ok then
    return describeWrongType(v)
  end
  if isNull then
    return ""
  end
  return nil
end
M.pointerProblem = pointerProblem

-- familyHelper.checkWrite(bOK, message) (issue #111, docs/adr/0028): the shared check
-- every fhSetValueAs* write call's own bOK return now goes through, instead of discarding
-- it the way sourceHelper.lua/sessionLogHelper.lua/richTextHelper.lua's ~17 call sites all
-- used to. FH's own docs describe bOK as its documented, non-throwing way of reporting a
-- write that silently didn't happen ("returns true on success and false on failure") --
-- confirmed by this project's own history: sessionLogHelper.lua's own comment records
-- fhSetValueAsRichText(notePtr, ...) once silently returning false and writing nothing,
-- before the code was fixed to target the right child item instead. ADR 0027 found and
-- named this exact gap while fixing pointer-argument-shape validation, and deliberately
-- deferred it as its own separate scoping decision -- see docs/adr/0028.
--
-- Unlike pointerProblem above, there's no "right shape, just empty" case to distinguish --
-- a write either happened or it didn't -- so this owns the whole error message rather than
-- returning a suffix for the caller to append to some other, pre-existing message.
local function checkWrite(bOK, message)
  if not bOK then
    error(message)
  end
end
M.checkWrite = checkWrite

-- familyHelper.checkCreated(item, message) (issue #111, docs/adr/0028): the fhCreateItem
-- counterpart to checkWrite above. fhCreateItem's own docs describe a different failure
-- shape from fhSetValueAs*'s boolean bOK -- "a NULL pointer if the create fails for any
-- reason" -- but a NULL Item Pointer is exactly what pointerProblem above already detects
-- (a real, pcall-guarded IsNull() check, not a Lua nil check), so this reuses it rather
-- than a second copy of the same null-detection logic.
local function checkCreated(item, message)
  if pointerProblem(item) then
    error(message)
  end
end
M.checkCreated = checkCreated

-- familyHelper.resolveDate(value, callerName) (docs/adr/0030): the shared "accept several
-- date shapes, always hand back a real Date object" resolver every write path that sets a
-- Date-typed field goes through -- sourceHelper.lua's own createSourceFromTemplate/
-- citeSource (its Date-typed template fields and the EntryDate standard field) and
-- factHelper.lua's createFact (dtDate). Moved here from sourceHelper.lua's own local
-- toDate (issue #113) once factHelper.lua needed the identical logic too -- same reasoning
-- as resolvePointer/pointerProblem/checkWrite/checkCreated above: a helper needed by more
-- than one module lives here, not duplicated per module.
--
-- Accepts three shapes:
-- 1. Already a Date object (anything not a string and not a plain Lua table) -- passed
--    through unchanged. This is the only shape the original toDate() (pre-issue-#113)
--    ever needed to distinguish, since every caller built one via fhNewDate(...) by hand.
-- 2. A {year=, month=, day=[, subtype=]} plain Lua table -- converted via fhNewDate(...).
--    strSubType is dropped entirely (not passed as an explicit nil) when value.subtype is
--    absent -- live-confirmed (issue #99) that FH's fhNewDate binding rejects an explicit
--    nil in that 4th slot ("bad argument #4 to 'fhNewDate' (string expected, got nil)")
--    rather than treating it the same as the argument being omitted entirely.
-- 3. A plain string (new, issue #113) -- parsed via FH's own Date object string parser:
--    fhNewDate():SetValueAsText(value, false) -- bAllowPhrase deliberately false, so an
--    unrecognized string is rejected outright (bResult false) rather than silently
--    accepted as a free-text date Phrase with no computable date value. Confirmed live
--    (Family Historian Sample Project 8, issue #113) that a raw string handed straight to
--    fhSetValueAsDate instead -- the mistake this resolver exists to prevent -- raises
--    "bad argument #2 to 'fhSetValueAsDate' (fh.DATE expected, got string)" from deep
--    inside fhu.createFact's own implementation, but only after the Fact item itself has
--    already been created -- a real write, arming ADR 0005's rollback tracker and ending
--    the Session for what should have been a caught-before-writing input error.
--
-- nil passes through unchanged (every caller treats a nil Date field as "not supplied,
-- skip it" -- same as every other optional field these write helpers pass through).
-- Any other type (number, boolean, a table that isn't the {year=,month=,day=} shape) is
-- handed to fhNewDate()/SetValueAsText as-is and left to raise FH's own error -- this
-- resolver's job is widening the accepted input shapes, not exhaustively validating every
-- possible wrong one; the pcall-free error a genuinely wrong-shaped value raises here is
-- still far more specific than the deferred, mid-write one that motivated this fix.
--
-- callerName names the calling function in the one error this resolver itself raises (an
-- unrecognized string) -- same "who's asking" convention checkWrite/checkCreated's own
-- messages already follow, since this can be reached from more than one module.
local function resolveDate(value, callerName)
  if value == nil then
    return nil
  end
  if type(value) == "table" then
    if value.subtype then
      return fhNewDate(value.year, value.month, value.day, value.subtype)
    end
    return fhNewDate(value.year, value.month, value.day)
  end
  if type(value) == "string" then
    local dt = fhNewDate()
    local ok = dt:SetValueAsText(value, false)
    if not ok then
      error(callerName .. ": '" .. value .. "' is not a recognized date")
    end
    return dt
  end
  return value
end
M.resolveDate = resolveDate

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
  local problem = pointerProblem(indiPtr)
  if problem then
    error("getFamilyGroup: indiPtr must point to an Individual record" .. problem)
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

-- Maps the dnaLine argument (shared by getAncestors and getDescendants) to the
-- exact built-in-function name fhCallBuiltInFunction expects -- see
-- fhCallBuiltInFunction.htm ("You can call any built-in function from within
-- Lua...") and FH's own DnaShareYChrom/DnaShareMtDna/DnaBloodRelation help
-- pages for what each actually computes. "blood" (issue #78) is
-- DnaBloodRelation, FH's general blood-relation test -- deliberately not
-- DnaHalfBlood: FH's own docs state a direct ancestor/descendant is never a
-- "half blood" relation, so offering it here would just be a dnaLine value
-- guaranteed to always return an empty result (see ADR 0021).
local DNA_LINE_BUILTIN = { ["y-chrom"] = "DnaShareYChrom", mtdna = "DnaShareMtDna", blood = "DnaBloodRelation" }

-- familyHelper.getAncestors(indiPtr, maxGenerations, dnaLine)
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
--
-- dnaLine (optional, nil/"y-chrom"/"mtdna"/"blood", issue #78) filters the returned
-- array down to ancestors who share a specific DNA line with indiPtr, via the same
-- DNA_LINE_BUILTIN/fhCallBuiltInFunction mechanism getDescendants uses (see its own
-- doc comment below for the full rationale, which applies here unchanged): defers
-- to FH's own DnaShareYChrom/DnaShareMtDna/DnaBloodRelation rather than
-- reimplementing DNA inheritance/relatedness rules, and the full ancestor tree is
-- still walked regardless of dnaLine, filtered only at result-insertion time.
-- dnaLine="blood" (DnaBloodRelation) is the case issue #78 actually asked for --
-- weeding an adoptive/step FAMC line out of an ancestor list, the same way
-- "y-chrom"/"mtdna" already weed a non-matching line out of a descendant list.
function M.getAncestors(indiPtr, maxGenerations, dnaLine)
  indiPtr = resolvePointer(indiPtr)
  local problem = pointerProblem(indiPtr)
  if problem then
    error("getAncestors: indiPtr must point to an Individual record" .. problem)
  end
  if fhGetTag(indiPtr) ~= "INDI" then
    error("getAncestors: indiPtr must point to an Individual record (got a '" .. tostring(fhGetTag(indiPtr)) .. "' record)")
  end
  local dnaBuiltin = nil
  if dnaLine ~= nil then
    dnaBuiltin = DNA_LINE_BUILTIN[dnaLine]
    if not dnaBuiltin then
      error("getAncestors: dnaLine must be nil, 'y-chrom', 'mtdna', or 'blood' (got '" .. tostring(dnaLine) .. "')")
    end
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
      if not dnaBuiltin or fhCallBuiltInFunction(dnaBuiltin, indiPtr, p) then
        table.insert(results, {
          generation = generation,
          line = line,
          individual = indiDescriptor(p),
          family = famDescriptor(fam),
        })
      end
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

-- familyHelper.getDescendants(indiPtr, maxGenerations, dnaLine)
-- indiPtr may be a live Item Pointer or a qualified id string (e.g. "I219") -- see
-- resolvePointer above.
--
-- Breadth-first walk down every FAMS record from indiPtr: generation 1 is indiPtr's
-- own children, generation 2 their children, and so on -- the mirror image of
-- getAncestors' walk up FAMC, with the same maxGenerations/pedigree-collapse/cycle
-- -safety behaviour: optional cap (nil/omit for no limit), each descendant visited
-- once at the shallowest generation it's reachable from (a descendant reachable via
-- more than one path -- e.g. cousins who married -- is only reported once).
--
-- Returns an array of { generation, line, individual, family }: line is an array of
-- "son"/"daughter" steps from indiPtr down to this descendant (e.g. {"son",
-- "daughter"} is a son's daughter), read off each step's own SEX rather than mirroring
-- getAncestors' HUSB/WIFE-role "father"/"mother" labels, since a CHIL item carries no
-- equivalent role of its own -- SEX is what dnaLine (below) actually needs anyway.
-- "child" is used for an Individual with no recorded SEX, rather than raising an
-- error over it -- a descendant list shouldn't fail outright just because one person's
-- sex was never entered.
--
-- dnaLine (optional, nil/"y-chrom"/"mtdna"/"blood") filters the returned array down
-- to descendants who share a specific DNA line -- or, for "blood" (issue #78), any
-- blood relation at all -- with indiPtr, using FH's own built-in DnaShareYChrom/
-- DnaShareMtDna/DnaBloodRelation functions (via fhCallBuiltInFunction) as the actual
-- test -- deliberately not reimplemented as a son/daughter-only tree-prune here, so
-- this defers to FH's own authoritative definition (including whatever edge cases
-- its own implementation accounts for, e.g. an adoptive FAMS link for "blood")
-- rather than this module's own understanding of DNA inheritance/relatedness rules.
-- The full descendant tree is still walked regardless of dnaLine (nextFrontier is
-- never pruned by the filter) -- simpler to reason about than pruning during the
-- walk, at the cost of some wasted work descending through a branch that can no
-- longer match (e.g. every descendant of a daughter, for "y-chrom") on a very large
-- tree. Per FH's own docs, DnaShareYChrom is always false if either party is female
-- (only males carry a Y chromosome) and DnaShareMtDna's propagation from indiPtr
-- only continues through daughters (though a son one generation down still shares
-- it, from indiPtr's own mother) -- so dnaLine="y-chrom" against a female indiPtr,
-- or dnaLine="mtdna" against a male indiPtr's grandchildren-and-beyond, legitimately
-- returns an empty (not erroring) result, matching what DnaShareYChrom/DnaShareMtDna
-- themselves would say for every pair.
--
-- dnaLine deliberately does NOT support FH's DnaHalfBlood ("half-blood"): FH's own
-- docs state a direct ancestor/descendant is never a "half blood" relation ("If one
-- person is the direct descendant of another, they are not 'half blood'
-- relations"), so it would be a dnaLine value guaranteed to always return an empty
-- result here -- considered and rejected for this reason, see ADR 0021.
function M.getDescendants(indiPtr, maxGenerations, dnaLine)
  indiPtr = resolvePointer(indiPtr)
  local problem = pointerProblem(indiPtr)
  if problem then
    error("getDescendants: indiPtr must point to an Individual record" .. problem)
  end
  if fhGetTag(indiPtr) ~= "INDI" then
    error("getDescendants: indiPtr must point to an Individual record (got a '" .. tostring(fhGetTag(indiPtr)) .. "' record)")
  end
  local dnaBuiltin = nil
  if dnaLine ~= nil then
    dnaBuiltin = DNA_LINE_BUILTIN[dnaLine]
    if not dnaBuiltin then
      error("getDescendants: dnaLine must be nil, 'y-chrom', 'mtdna', or 'blood' (got '" .. tostring(dnaLine) .. "')")
    end
  end

  local results = {}
  local visited = { [fhGetRecordId(indiPtr)] = true }
  local frontier = { { ptr = indiPtr, line = {} } }
  local generation = 0

  while #frontier > 0 and (not maxGenerations or generation < maxGenerations) do
    generation = generation + 1
    local nextFrontier = {}

    local function visit(p, fam, parentLine)
      local id = fhGetRecordId(p)
      if visited[id] then return end
      visited[id] = true
      local sex = fhGetItemText(p, "~.SEX")
      local role = sex == "Male" and "son" or (sex == "Female" and "daughter" or "child")
      local line = {}
      for i, step in ipairs(parentLine) do line[i] = step end
      line[#line + 1] = role
      if not dnaBuiltin or fhCallBuiltInFunction(dnaBuiltin, indiPtr, p) then
        table.insert(results, {
          generation = generation,
          line = line,
          individual = indiDescriptor(p),
          family = famDescriptor(fam),
        })
      end
      table.insert(nextFrontier, { ptr = p, line = line })
    end

    for _, entry in ipairs(frontier) do
      eachFamilyLink(entry.ptr, "FAMS", function(fam)
        eachFamilyMember(fam, "CHIL", function(p) visit(p, fam, entry.line) end)
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
-- fhGetValueType case by case, EXCEPT richtext and longtext (fhGetDataClass, not
-- fhGetValueType -- longtext's own value type is plain "text", same as an ordinary
-- single-line field, so fhGetValueType alone can't tell them apart):
--   - richtext: fhGetItemText/fhGetValueAsText/fhGetDisplayText all return a
--     Notes-style field's raw FTF markup, not readable prose (see
--     gedcom-knowledge-corpus "Getting clean plain text out of a rich-text field")
--     -- AND fhGetItemText(ptr, "~") can silently truncate a long richtext value
--     entirely, independent of the markup issue (517 of 1294 chars observed on a
--     real Source TEXT field, issue #70) -- so richtext goes through
--     fhGetValueAsRichText(ptr):GetPlainText() instead, sidestepping both problems.
--   - longtext: no markup to strip, but fhGetDisplayText's own docs describe its
--     result as a short string "suitable to be used... in lists", not a
--     truncation-safe full value -- same silent-shortening risk shape as richtext,
--     just via a different, documented-on-purpose mechanism rather than a bug. No
--     longtext-class field is known to exist in this project's actual data yet, but
--     the guard costs one branch and closes the same gap issue #70 asked to have
--     audited. Routed through fhGetValueAsText(ptr) instead, matching its "text"
--     fhGetValueType.
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
    elseif fhGetDataClass(ptr) == "longtext" then
      node.value = fhGetValueAsText(ptr)
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
  local problem = pointerProblem(ptr)
  if problem then
    error("getAllDetails: pointer must not be null" .. problem)
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
  local problem = pointerProblem(ptr)
  if problem then
    error("getFactsByTag: pointer must not be null" .. problem)
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
