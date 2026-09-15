-- Read-only query helpers -- fhBridge.getFamilyGroup, getAllDetails, getAncestors,
-- getDescendants, findByNames, getFactsByTag. Every fh* call here is a read primitive,
-- so sandbox.lua wires this whole module through for both access modes.
--
-- Every function returns plain JSON-safe tables, never a raw Item Pointer (jsonEncode.lua
-- can't encode one), and accepts a qualified id string (e.g. "I219") anywhere it takes a
-- pointer -- see resolvePointer below.

local M = {}

-- Visibility levels for the Private/Living Record Flags (issue #141), set once per
-- run_lua call by sandbox.lua's M.build before env.fhBridge is handed to the script --
-- module-level rather than threaded through every function's own parameters, since
-- FH's single-threaded IUP mainloop means one script always runs to completion before the
-- next starts (see sandbox.lua's own comment at the call site). Defaults to unfiltered
-- "all"/"all" so a caller that never calls this (any pre-#141 test) sees today's behavior.
local currentPrivacySettings = { privateVisibility = "all", livingVisibility = "all" }

function M.setPrivacySettings(settings)
  currentPrivacySettings = settings or { privateVisibility = "all", livingVisibility = "all" }
end

-- Exposed for tests and for recordVisibility (added in a later #141 slice); every other
-- function in this module reads currentPrivacySettings through this accessor, never the
-- upvalue directly.
function M.getPrivacySettings()
  return currentPrivacySettings
end

-- Most-restrictive-wins ordering for the two Visibility levels (issue #141).
local VISIBILITY_RANK = { exclude = 1, nameOnly = 2, all = 3 }

-- Visibility level for ptr's own Private/Living Record Flags, per the currently-active
-- Session settings. Record Flags are Individual-only (FH help: "Record Flags can only be
-- set on Individual records"), so anything else -- FAM, SOUR, ... -- is always "all". Flag
-- tags are compared as literal strings ("__PRIVATE"/"__LIVING"), the same approach
-- describe_project's own flag census already uses and tests, rather than resolving them via
-- fhGetFlagTag -- see docs/adr/0014 and the FH help corpus's %INDI._FLGS.__PRIVATE% example.
-- When both flags are set, the more restrictive configured level wins.
local function recordVisibility(ptr)
  if fhGetTag(ptr) ~= "INDI" then
    return "all"
  end

  local settings = M.getPrivacySettings()
  local level = "all"
  local child = fhNewItemPtr()
  local flag = fhNewItemPtr()
  child:MoveToFirstChildItem(ptr)
  while child:IsNotNull() do
    if fhGetTag(child) == "_FLGS" then
      flag:MoveToFirstChildItem(child)
      while flag:IsNotNull() do
        local flagTag = fhGetTag(flag)
        local flagLevel
        if flagTag == "__PRIVATE" then
          flagLevel = settings.privateVisibility
        elseif flagTag == "__LIVING" then
          flagLevel = settings.livingVisibility
        end
        local rank = flagLevel and VISIBILITY_RANK[flagLevel]
        if rank and rank < VISIBILITY_RANK[level] then
          level = flagLevel
        end
        flag:MoveNext()
      end
    end
    child:MoveNext()
  end
  return level
end

-- Record-tag prefixes usable with MoveToRecordById ('H'/'A' have qualified ids but no
-- MoveToRecordById equivalent, so they're excluded).
local QUALIFIED_ID_PREFIX_TAG = {
  F = "FAM", I = "INDI", O = "OBJE", N = "NOTE", R = "REPO", S = "SOUR",
  U = "SUBM", B = "SUBN", P = "_PLAC", E = "_RNOT", T = "_SRCT",
}

-- Splits a qualified-id-shaped string into its letter prefix and numeric text (e.g.
-- "I219" -> "I", "219"), or nil if it isn't shaped like one.
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

-- Tag-scoped counterpart to resolveQualifiedId: returns the numeric id if value has this
-- specific tag's qualified-id shape (e.g. "S1186" for SOUR), or nil (never an error)
-- otherwise, so a caller can fall through to a different interpretation.
local function parseQualifiedId(tag, value)
  if type(value) ~= "string" then return nil end
  local prefix, numText = qualifiedIdShape(value)
  if not prefix or QUALIFIED_ID_PREFIX_TAG[prefix] ~= tag then return nil end
  return tonumber(numText)
end

-- Every public function's pointer argument goes through this: a string resolves as a
-- qualified id, anything else passes through for the caller's own nil/IsNull check. A
-- bare number raises its own error rather than falling through -- every descriptor this
-- module returns carries both .id (a number) and .qualifiedId (a string); passing .id
-- here is an easy mistake that otherwise only surfaces later as an opaque Lua error.
local function resolvePointer(value)
  if type(value) == "string" then
    return resolveQualifiedId(value)
  end
  if type(value) == "number" then
    error("expected a qualified id string like 'I219', got the number " .. tostring(value) ..
      " -- pass the .qualifiedId field (e.g. from getFamilyGroup/getAncestors/getDescendants/" ..
      "findByNames), not .id")
  end
  return value
end

-- Exported so sourceHelper.lua's getPopulatedTemplateFields can accept a qualified id too.
M.resolvePointer = resolvePointer

-- Exported so sourceHelper.lua's resolveByNameOrId can reuse the same prefix rule.
M.parseQualifiedId = parseQualifiedId

-- The shared "is v a usable live pointer" check every validate*/get* function uses instead
-- of hand-rolling "not ptr or ptr:IsNull()", which raises a raw, unhelpful Lua error for a
-- non-pointer value (string/number/table). Returns nil when v is a usable, non-null
-- pointer. Otherwise returns a string to append to the caller's own "X must point to Y"
-- message: "" for nil/a null pointer, or " -- got <type> (<value>), not a live Item
-- Pointer" for anything else.
--
-- IsNull() is pcall'd rather than type()-checked, since a live pointer's real Lua type
-- differs between FH (userdata) and this project's own test fakes (a table).
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

-- The shared check every fhSetValueAs* write call's bOK return goes through -- FH
-- reports a silently-failed write via bOK=false, not an error, so this turns that into one.
local function checkWrite(bOK, message)
  if not bOK then
    error(message)
  end
end
M.checkWrite = checkWrite

-- fhCreateItem counterpart to checkWrite: reuses pointerProblem to detect the NULL pointer
-- fhCreateItem returns on failure.
local function checkCreated(item, message)
  if pointerProblem(item) then
    error(message)
  end
end
M.checkCreated = checkCreated

-- Accepts a Date value as an already-built Date object, a {year=,month=,day=[,subtype=]}
-- table, or a plain string, and returns a real Date object every write path can pass
-- straight to fhSetValueAsDate. Shared by sourceHelper.lua's createSourceFromTemplate/
-- citeSource and factHelper.lua's createFact.
--
-- Table form: subtype is omitted entirely (not passed as explicit nil) when absent --
-- fhNewDate's 4th argument rejects an explicit nil.
-- String form: parsed via fhNewDate():SetValueAsText(value, false) -- bAllowPhrase=false,
-- so an unrecognized string errors here rather than being silently accepted as a
-- free-text Phrase with no computable date value.
--
-- nil passes through unchanged (caller treats it as "field not supplied"). callerName
-- names the calling function in this resolver's own "not a recognized date" error.
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

-- Individual summary every getFamilyGroup/getAncestors/getDescendants/findByNames entry
-- carries instead of a live pointer.
local function indiDescriptor(ptr)
  local level = recordVisibility(ptr)
  if level == "exclude" then
    return { redacted = true, tag = "INDI" }, level
  end
  return {
    id = fhGetRecordId(ptr),
    qualifiedId = fhGetQualifiedRecordId(ptr),
    name = fhIndGetName(ptr),
    sex = fhGetItemText(ptr, "~.SEX"),
  }, level
end

-- Whitespace-separated words, unchanged case. Callers that don't already have a lowercased
-- string in hand should use splitWordsLower below instead.
local function splitWords(s)
  local words = {}
  for w in tostring(s):gmatch("%S+") do
    table.insert(words, w)
  end
  return words
end

-- Lowercased whitespace-separated words, for findByNames' word-set containment.
local function splitWordsLower(s)
  local words = {}
  for w in tostring(s):gmatch("%S+") do
    table.insert(words, w:lower())
  end
  return words
end

-- true iff q is not a usable findByNames query entry: not a string, or blank/whitespace-only
-- (which would split to zero words and vacuously match everyone).
local function isBlankQuery(q)
  return type(q) ~= "string" or q:match("^%s*$") ~= nil
end

-- Word-set containment test for one query against one candidate's NAME:FULL: every word in
-- queryWords must match, case-insensitively, as an exact whole word in nameWords or (unless
-- exactMatch) a substring anywhere in nameFullLower. Returns matched (bool) and exactCount --
-- how many query words matched a whole name-word exactly, the ranking signal below (always
-- equal to #queryWords when exactMatch, since containment already requires it there).
local function matchQuery(queryWords, nameFullLower, nameWords, exactMatch)
  local exactCount = 0
  for _, qWord in ipairs(queryWords) do
    local isExact = false
    for _, nWord in ipairs(nameWords) do
      if nWord == qWord then
        isExact = true
        break
      end
    end
    if isExact then
      exactCount = exactCount + 1
    elseif exactMatch or not nameFullLower:find(qWord, 1, true) then
      return false, 0
    end
  end
  return true, exactCount
end

-- Builds a lookup set from getFactsByTag's `tags` (a single tag string or an array of tag
-- strings). Errors on nil/""/an empty table/a non-string entry, rather than matching
-- nothing silently.
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

-- Family summary identifying which FAMS/FAMC record connects a relative back to the
-- individual passed in.
local function famDescriptor(ptr)
  return {
    id = fhGetRecordId(ptr),
    qualifiedId = fhGetQualifiedRecordId(ptr),
  }
end

-- Calls onFamily(familyPtr) for every linkTag child of indiPtr (e.g. every FAMS/FAMC
-- link) -- MoveNext("SAME_TAG") is needed since FH stores multiple links as same-tag
-- siblings, not a multi-valued field.
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

-- Calls onIndi(indiPtr) for every memberTag child of a Family record (HUSB/WIFE/CHIL --
-- CHIL is commonly more than one). Same SAME_TAG reasoning as eachFamilyLink.
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
-- indiPtr: live pointer or qualified id string (see resolvePointer).
-- type: "all" (default), "parents", "siblings", or "spouses". Walks every FAMC/FAMS
-- record indiPtr belongs to, not just the first.
--
-- Returns an array of { relationship, individual, family }. relationship is
-- "father"/"mother" (read off the FAMC record's HUSB/WIFE role, not the parent's own SEX
-- field -- FH allows the two to differ), "sibling", or "spouse". family identifies which
-- FAMC/FAMS record the relationship came through, so a caller can tell full siblings from
-- half-siblings by comparing .family.id. Never includes indiPtr itself; deduplicates by
-- relationship + id.
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

-- Maps dnaLine (shared by getAncestors/getDescendants) to the built-in function
-- fhCallBuiltInFunction expects. "blood" uses DnaBloodRelation, not DnaHalfBlood -- FH's
-- own docs say a direct ancestor/descendant is never "half blood", so that would always
-- return empty (ADR 0021).
local DNA_LINE_BUILTIN = { ["y-chrom"] = "DnaShareYChrom", mtdna = "DnaShareMtDna", blood = "DnaBloodRelation" }

-- familyHelper.getAncestors(indiPtr, maxGenerations, dnaLine)
-- indiPtr: live pointer or qualified id string (see resolvePointer).
--
-- Breadth-first walk up every FAMC record: generation 1 is indiPtr's own parents,
-- generation 2 their parents, etc. maxGenerations (optional) caps the walk.
--
-- Returns an array of { generation, line, individual, family }: line is an array of
-- "father"/"mother" steps from indiPtr down to this ancestor (e.g. {"mother","father"} is
-- the maternal grandfather) -- left unresolved to an English title on purpose, since
-- that's a presentation choice for the caller. Each ancestor is visited once, at the
-- shallowest generation reachable (pedigree collapse; also guards against a cyclic FAMC
-- chain).
--
-- dnaLine (optional, nil/"y-chrom"/"mtdna"/"blood") filters the result to ancestors
-- sharing that DNA line with indiPtr, via FH's own DnaShareYChrom/DnaShareMtDna/
-- DnaBloodRelation built-ins -- the full tree is still walked, just filtered at
-- result-insertion time.
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
-- indiPtr: live pointer or qualified id string (see resolvePointer). Mirror image of
-- getAncestors, walking down FAMS instead of up FAMC, with the same maxGenerations/
-- pedigree-collapse/cycle-safety behaviour.
--
-- Returns an array of { generation, line, individual, family }: line is "son"/"daughter"
-- steps read off each step's own SEX (a CHIL item has no HUSB/WIFE-style role); "child" is
-- used when SEX isn't recorded, rather than erroring.
--
-- dnaLine (optional, nil/"y-chrom"/"mtdna"/"blood") filters to descendants sharing that
-- DNA line, via FH's own DnaShareYChrom/DnaShareMtDna/DnaBloodRelation built-ins -- the
-- full tree is still walked, just filtered at result-insertion time. Because
-- DnaShareYChrom is always false for a female and DnaShareMtDna only propagates through
-- daughters, "y-chrom" against a female indiPtr (or "mtdna" beyond a son) legitimately
-- returns an empty, not erroring, result. DnaHalfBlood is deliberately not offered: FH's
-- own docs say a direct ancestor/descendant is never "half blood", so it would always
-- return empty (ADR 0021).
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

-- Resolves a link-classed item to a plain descriptor of the record it points to (never
-- the raw pointer). Deliberately doesn't recurse into the target's own fields -- unlike
-- describeItem's recursion into an item's children, following a link back out could walk
-- the whole connected tree and cycle forever (an Individual's FAMS -> Family -> HUSB back
-- to the same Individual).
local function linkDescriptor(ptr)
  local target = fhGetValueAsLink(ptr)
  if not target or target:IsNull() then
    return nil
  end
  -- A link can point at an Excluded Individual even when ptr's own record has no flags
  -- of its own (e.g. a FAM's HUSB/WIFE link) -- redact here too, not just at indiDescriptor,
  -- so getAllDetails/getFactsByTag can't leak a name through a one-hop link (issue #141).
  if recordVisibility(target) == "exclude" then
    return { redacted = true, tag = fhGetTag(target) }
  end
  return {
    tag = fhGetTag(target),
    id = fhGetRecordId(target),
    qualifiedId = fhGetQualifiedRecordId(target),
    text = fhGetDisplayText(target),
  }
end

-- Recursively describes one item and its children as a plain tree: { tag, id/qualifiedId
-- (record items only), value, link (link-classed items only), children }.
--
-- .value uses fhGetDisplayText(ptr, "~", "min") for most value types, except:
--   - richtext: fhGetItemText/fhGetValueAsText/fhGetDisplayText all return raw FTF markup
--     rather than plain text, and can silently truncate a long value -- uses
--     fhGetValueAsRichText(ptr):GetPlainText() instead, which avoids both problems.
--   - longtext (fhGetDataClass, since its fhGetValueType is plain "text"): fhGetDisplayText
--     is documented as list-display-only, with the same truncation risk as richtext --
--     uses fhGetValueAsText(ptr) instead.
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
-- ptr: live pointer or qualified id string (any record type). A qualified id resolves to
-- that record's own top-level pointer -- to describe a single field/Fact, pass a live
-- pointer positioned on it.
--
-- Returns ptr's own value (if any) plus every child/subfield beneath it, recursively, as
-- one JSON-safe tree (see describeItem). Works on any item, not just a top-level record.
function M.getAllDetails(ptr)
  ptr = resolvePointer(ptr)
  local problem = pointerProblem(ptr)
  if problem then
    error("getAllDetails: pointer must not be null" .. problem)
  end

  local level = recordVisibility(ptr)
  if level == "exclude" then
    error("getAllDetails: this Individual is Excluded by the Session's Visibility settings")
  elseif level == "nameOnly" then
    return { tag = fhGetTag(ptr), id = fhGetRecordId(ptr), qualifiedId = fhGetQualifiedRecordId(ptr) }
  end
  return describeItem(ptr)
end

-- familyHelper.getFactsByTag(ptr, tags)
-- ptr: live pointer or qualified id string, any record type. tags: one tag string (e.g.
-- "CENS") or an array of tag strings -- FH's own resolved tag, exact and case-sensitive
-- (a custom fact resolves to its own real tag, e.g. "_ATTR-REGIMENT").
--
-- Only checks ptr's direct children, not recursively into subfields. Returns one
-- getAllDetails-shape tree per matching child, in record order, not deduped -- a repeated
-- tag (multiple CENS entries) is meant to be surfaced, not collapsed. An empty array means
-- no matches, not an error.
function M.getFactsByTag(ptr, tags)
  ptr = resolvePointer(ptr)
  local problem = pointerProblem(ptr)
  if problem then
    error("getFactsByTag: pointer must not be null" .. problem)
  end

  local level = recordVisibility(ptr)
  if level == "exclude" then
    error("getFactsByTag: this Individual is Excluded by the Session's Visibility settings")
  elseif level == "nameOnly" then
    return {}
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

-- familyHelper.findByNames(query, exactMatch)
-- Resolves one or a batch of plain-text names against every Individual in the project in
-- one pass. query is a single name string, or an array of them for a batch call; exactMatch
-- is an optional boolean (default false), scoped to the whole call, not per entry.
--
-- Matching is word-set containment: query splits on whitespace, and every resulting word
-- must independently match, case-insensitive, against ~.NAME:FULL (the resolved complete
-- name, not the raw slash-delimited NAME text) -- substring anywhere in it by default, an
-- exact whole word under exactMatch. Word order never matters on either side, so "Issac
-- Crabb" and "Crabb Issac" match the same people.
--
-- Ranking: a query word that exactly equals a whole name-word outranks one that only
-- matched as a substring; ties break by which candidate's NAME:FULL is closer in length to
-- the query.
--
-- Each search's result is {matches = {...}, totalMatches = N} -- matches capped at the top
-- 30 ranked entries, totalMatches the true pre-cap count, never a silent slice (large
-- projects can run 400k+ Individuals, and a query like "William Williams" can legitimately
-- match dozens). Output shape mirrors input shape: a single query string returns one such
-- object; a list returns an array of them, one per entry, position-preserving -- a
-- no-match entry stays in place as {matches = {}, totalMatches = 0} rather than being
-- dropped.
--
-- Any blank/whitespace-only query entry (the single query, or any item in a list) errors
-- the whole call -- there's no field to fall back to the way the old two-argument
-- searchByName had, and matching "everyone" silently is never what a name-resolution call
-- wants. Walks the INDI table once regardless of list length -- every query is tested
-- against each record as it's visited, not once per query.
--
-- Each match also carries lifeDates (e.g. "1865-1932"), FH's own built-in
-- fhCallBuiltInFunction("LifeDates", ptr, "STD") -- omitted entirely (not "") when FH has
-- nothing to report, not shared with indiDescriptor (getFamilyGroup/getAncestors/
-- getDescendants stay unchanged).

-- Local to findByNames only -- see the doc comment above for why.
local function lifeDatesFor(ptr)
  local dates = fhCallBuiltInFunction("LifeDates", ptr, "STD")
  if dates == nil or dates == "" then
    return nil
  end
  return dates
end
function M.findByNames(query, exactMatch)
  if exactMatch ~= nil and type(exactMatch) ~= "boolean" then
    error("findByNames: exactMatch must be a boolean; pass a list as the first argument to search several names at once")
  end

  local isBatch = type(query) == "table"
  local queries = isBatch and query or { query }

  if #queries == 0 then
    error("findByNames: query must be a non-blank string or a non-empty array of them")
  end

  local prepared = {}
  for i, q in ipairs(queries) do
    if isBlankQuery(q) then
      error("findByNames: query entries must be non-blank strings (entry " .. i .. ")")
    end
    prepared[i] = { raw = q, words = splitWordsLower(q), results = {} }
  end

  local ptr = fhNewItemPtr()
  ptr:MoveToFirstRecord("INDI")
  local walkIndex = 0
  while ptr:IsNotNull() do
    walkIndex = walkIndex + 1
    local nameFull = fhGetItemText(ptr, "~.NAME:FULL")
    local nameFullLower = nameFull:lower()
    local nameWords = splitWords(nameFullLower) -- already lowercase; avoids re-lowering per word
    for _, p in ipairs(prepared) do
      local matched, exactCount = matchQuery(p.words, nameFullLower, nameWords, exactMatch)
      if matched then
        local descriptor, level = indiDescriptor(ptr)
        if level == "all" then
          descriptor.lifeDates = lifeDatesFor(ptr)
        end
        table.insert(p.results, {
          descriptor = descriptor,
          exactCount = exactCount,
          lengthDelta = math.abs(#nameFull - #p.raw),
          walkIndex = walkIndex,
        })
      end
    end
    ptr:MoveNext()
  end

  local function finalize(p)
    table.sort(p.results, function(a, b)
      if a.exactCount ~= b.exactCount then return a.exactCount > b.exactCount end
      if a.lengthDelta ~= b.lengthDelta then return a.lengthDelta < b.lengthDelta end
      return a.walkIndex < b.walkIndex
    end)
    local totalMatches = #p.results
    local matches = {}
    for i = 1, math.min(30, totalMatches) do
      matches[i] = p.results[i].descriptor
    end
    return { matches = matches, totalMatches = totalMatches }
  end

  if isBatch then
    local out = {}
    for i, p in ipairs(prepared) do
      out[i] = finalize(p)
    end
    return out
  end
  return finalize(prepared[1])
end

return M
