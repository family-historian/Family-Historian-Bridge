-- Standalone tests for sourceHelper.lua. Run with: lua bridge/tests/sourceHelper.test.lua
-- No FH/socket dependency. Unlike sandbox.test.lua/runScript.test.lua's flat, no-op
-- stubs, sourceHelper.lua genuinely walks a record/child-item tree (MoveToFirstRecord,
-- MoveToFirstChildItem, MoveNext) and creates new items in it — so this file builds a
-- small in-memory fake item-pointer double, scoped narrowly to only the methods/globals
-- sourceHelper.lua actually calls: item-pointer methods MoveToFirstRecord/
-- MoveToFirstChildItem/MoveNext/IsNotNull/IsNull/Clone, plus globals fhGetTag/fhGetItemText/
-- fhGetRecordId/fhCreateItem/fhSetValueAsText/fhSetValueAsDate/fhSetValueAsLink/
-- fhSetValueAsRichText/fhNewDate/fhNewRichText/fhSrcEnableAutoTitle.
--
-- findSources (issue #65) additionally pulls in familyHelper.lua for real (require
-- isn't stubbed away the way sandbox.test.lua/runScript.test.lua stub it, since this
-- file wants findSources' actual behavior, not just that it was called) — so the fake
-- environment below also covers familyHelper.lua's own needs: fhGetQualifiedRecordId,
-- fhGetValueType, fhGetDisplayText, fhGetValueAsRichText, fhHasChildItem, and
-- fhGetValueAsLink returning a real fake pointer (not just a raw node) to a linked
-- record. Every fhSetValueAs* setter below now also stamps a .valueType on the node it
-- touches, matching what fhGetValueType needs to tell a text/date/link/richtext field
-- apart from a complex/record item (valueType "").

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local function contains(haystack, needle)
  return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

------------------------------------------------------------------
-- Fake tree: records grouped by tag, each node a plain table with
-- { tag, id (records only), value, children = {} }.
------------------------------------------------------------------

local recordsByTag
local nextId

local function resetTree()
  recordsByTag = {}
  nextId = 1
end

-- Forward-declared so fhGetDisplayText (defined before fhNewDate below) can format a
-- fake Date object's fields -- assigned (not re-declared) at fhNewDate's own definition
-- further down, so both share the same upvalue.
local dateObjFields

local PtrMethods = {}
PtrMethods.__index = PtrMethods

local function newPtr()
  return setmetatable({ list = nil, index = nil }, PtrMethods)
end

local function currentNode(ptr)
  return ptr.list and ptr.list[ptr.index]
end

function PtrMethods:MoveToFirstRecord(tag)
  self.list = recordsByTag[tag] or {}
  self.index = 1
end

-- Needed for familyHelper.resolvePointer (via getPopulatedTemplateFields accepting a
-- qualified id string, issue #73) -- mirrors familyHelper.test.lua's own fake, scanning
-- recordsByTag[tag] for a node with a matching id. Linear scan is fine for fixture-sized
-- fake trees.
function PtrMethods:MoveToRecordById(tag, id)
  local list = recordsByTag[tag] or {}
  for i, node in ipairs(list) do
    if node.id == id then
      self.list = list
      self.index = i
      return
    end
  end
  self.list = list
  self.index = #list + 1
end

function PtrMethods:MoveToFirstChildItem(parentPtr)
  local node = currentNode(parentPtr)
  self.list = node and node.children or {}
  self.index = 1
end

function PtrMethods:MoveNext()
  self.index = self.index + 1
end

function PtrMethods:IsNotNull()
  return currentNode(self) ~= nil
end

function PtrMethods:IsNull()
  return currentNode(self) == nil
end

function PtrMethods:Clone()
  local clone = newPtr()
  clone.list = self.list
  clone.index = self.index
  return clone
end

fhNewItemPtr = newPtr

fhGetTag = function(ptr)
  local node = currentNode(ptr)
  return node and node.tag
end

-- Renders a node's own value as text the way real FH's fhGetItemText/fhGetDisplayText do
-- regardless of underlying type -- a plain string as-is, a fake Date object (see
-- fhNewDate below) formatted as YYYY-MM-DD from the fake's own side table. Shared by
-- fhGetItemText (both its "~" and shortcut-Data-Reference branches below) and
-- fhGetDisplayText, so a Date-typed field renders identically through either path --
-- matching real FH, live-confirmed (issue #67/#73): fhGetItemText(sourPtr, "~.~DT-Date")
-- returns a formatted date string ("11 September 1901"), not a raw Date-object value.
local function renderValue(node)
  if type(node.value) == 'string' then return node.value end
  local df = dateObjFields and dateObjFields[node.value]
  if df then
    return string.format("%04d-%02d-%02d", df.year or 0, df.month or 0, df.day or 0)
  end
  return ""
end

-- "~" is the self-reference Data Reference token (see the '~.NAME'/'~:SURNAME' qualifier
-- examples in the gedcom-knowledge-corpus and bridge/README.md's own manual write-test
-- script) — sourceHelper.lua only ever reads a pointer's own scalar value, never a
-- qualified/relative reference, so that's the only case this fake needs to support.
fhGetItemText = function(ptr, dataRef)
  local node = currentNode(ptr)
  if not node then return "" end
  if dataRef == "~" then
    return renderValue(node)
  end
  -- "~.~PREFIX-CODE" resolves a source-template metafield's shortcut Data Reference
  -- (sourceHelper.lua's resolvedFieldValue/getPopulatedTemplateFields, issue #73). This
  -- fake's own fhCreateItem below already tags a created metafield by its shortcut string
  -- (not FH's real raw tag "_FIELD" -- a known simplification, see fhCreateItem's own
  -- comment), so resolving here means "find a child tagged exactly that shortcut" --
  -- keeps the fake's read and write sides consistent with each other rather than
  -- modeling FH's real tag-vs-Data-Reference indirection, which this fake was never
  -- built to model (that indirection is exactly what issue #67/#73 live-verified against
  -- the real Bridge instead).
  local shortcut = dataRef:match("^~%.(~.+)$")
  if shortcut then
    for _, child in ipairs(node.children) do
      if child.tag == shortcut then
        return renderValue(child)
      end
    end
  end
  return ""
end

fhGetRecordId = function(ptr)
  local node = currentNode(ptr)
  return node and node.id
end

-- Needed for familyHelper.getAllDetails (via findSources) to build a record's
-- id/qualifiedId pair -- only the record tags findSources' own fixtures actually use.
local QUALIFIED_ID_PREFIX = { INDI = "I", FAM = "F", SOUR = "S", _SRCT = "T" }
fhGetQualifiedRecordId = function(ptr)
  local node = currentNode(ptr)
  if not node or not node.id then return "" end
  return (QUALIFIED_ID_PREFIX[node.tag] or "?") .. tostring(node.id)
end

-- Mirrors familyHelper.test.lua's own valueType convention: "" (unset) for a
-- complex/record item with no value of its own, stamped onto a node by the setters
-- below the moment it's actually given a value.
fhGetValueType = function(ptr)
  local node = currentNode(ptr)
  return (node and node.valueType) or ""
end

-- Scoped to how familyHelper.lua's describeItem actually calls it: fhGetDisplayText(ptr,
-- "~", "min") for a leaf value, fhGetDisplayText(target) (bare) for a link's display
-- text -- both mean "this node's own display text", so the extra arguments are ignored
-- here. Shares renderValue's own YYYY-MM-DD Date rendering above -- just enough for
-- findSources' exact-match Date tests to have something comparable, not a claim this
-- matches FH's own date formatting.
fhGetDisplayText = function(ptr)
  local node = currentNode(ptr)
  if not node then return "" end
  return renderValue(node)
end

fhGetValueAsRichText = function(ptr)
  local node = currentNode(ptr)
  return {
    GetPlainText = function()
      return (node and type(node.value) == 'table' and node.value.text) or ""
    end,
  }
end

-- No fixture in this file needs a "longtext" dataClass (see familyHelper.lua's
-- describeItem for what that branch is for) -- this fake exists only so
-- familyHelper.getAllDetails' non-richtext branch (reached via findSources ->
-- allCitationsBySourceId) has a real global to call instead of erroring on a nil
-- global, same "" default as fhGetValueType above.
fhGetDataClass = function(ptr)
  local node = currentNode(ptr)
  return (node and node.dataClass) or ""
end

fhHasChildItem = function(ptr)
  local node = currentNode(ptr)
  return node ~= nil and #node.children > 0
end

-- Tags a created metafield by its own shortcut string (e.g. "~TX-Reg_No") rather than
-- FH's real raw tag "_FIELD" -- a known simplification (see fhGetItemText's own comment
-- above, which reads it back the same way) that keeps this fake internally consistent
-- without modeling the real tag-vs-Data-Reference indirection issue #67/#73 uncovered.
fhCreateItem = function(tagOrShortcut, parentPtr)
  local node = { tag = tagOrShortcut, children = {} }
  local ptr = newPtr()
  if not parentPtr then
    node.id = nextId
    nextId = nextId + 1
    recordsByTag[tagOrShortcut] = recordsByTag[tagOrShortcut] or {}
    table.insert(recordsByTag[tagOrShortcut], node)
    ptr.list = recordsByTag[tagOrShortcut]
    ptr.index = #recordsByTag[tagOrShortcut]
  else
    local parentNode = currentNode(parentPtr)
    table.insert(parentNode.children, node)
    ptr.list = parentNode.children
    ptr.index = #parentNode.children
  end
  return ptr
end

fhSetValueAsText = function(ptr, value)
  local node = currentNode(ptr)
  node.value = value
  node.valueType = "text"
end

fhSetValueAsDate = function(ptr, dateObj)
  local node = currentNode(ptr)
  node.value = dateObj
  node.valueType = "date"
end

fhSetValueAsLink = function(ptr, targetPtr)
  local node = currentNode(ptr)
  node.value = currentNode(targetPtr)
  node.valueType = "link"
end

fhSetValueAsRichText = function(ptr, richTextObj)
  local node = currentNode(ptr)
  node.value = richTextObj
  node.valueType = "richtext"
end

-- Needed for familyHelper.getAllDetails (via findSources) to build a link field's
-- descriptor ({tag, id, qualifiedId, text}, see familyHelper.lua's linkDescriptor) --
-- wraps the raw target node (stored directly as .value by fhSetValueAsLink above) in a
-- real fake pointer rather than handing back the node table itself.
fhGetValueAsLink = function(ptr)
  local node = currentNode(ptr)
  local target = node and node.value
  if type(target) ~= 'table' or not target.tag then
    return newPtr()
  end
  local linkPtr = newPtr()
  linkPtr.list = { target }
  linkPtr.index = 1
  return linkPtr
end

-- Real FH's fhNewDate returns a Date *object* (userdata, per the API's own Hungarian-
-- notation prefix table) — genuinely a different Lua type from a plain table, which is
-- exactly what lets sourceHelper.lua's toDate() tell "already a Date object" apart from
-- "the {year=,month=,day=} shorthand table" via a plain type() check. A fake that returned
-- a table here would collapse that distinction and defeat the test below. A coroutine
-- (type 'thread') is a free, dependency-free stand-in for opaque host userdata; its fields
-- live in this side table, keyed weakly so they don't outlive the coroutine.
dateObjFields = setmetatable({}, { __mode = 'k' })
fhNewDate = function(y, m, d, subtype)
  local co = coroutine.create(function() end)
  dateObjFields[co] = { kind = 'date', year = y, month = m, day = d, subtype = subtype }
  return co
end

fhNewRichText = function(text, bRich)
  return { kind = 'richtext', text = text, rich = bRich }
end

local autoTitleCalls = {}
fhSrcEnableAutoTitle = function(ptr, enabled)
  local node = currentNode(ptr)
  table.insert(autoTitleCalls, { node = node, enabled = enabled })
  node.value = 'Auto-title: ' .. tostring(node.id)
end

------------------------------------------------------------------
-- Fixture helpers: build _SRCT templates using the same primitives
-- sourceHelper.lua itself reads them with.
------------------------------------------------------------------

local function buildTemplate(name)
  local tpl = fhCreateItem("_SRCT")
  local nameChild = fhCreateItem("NAME", tpl)
  fhSetValueAsText(nameChild, name)
  return tpl
end

-- citation (optional boolean, issue #65): stamps a CITN="Yes" child on the field
-- definition, mirroring FH's own "Citation-specific" checkbox (Source Template Field
-- Definition Dialog) -- omitted (falsy) means the field is Source-record-level, FH's
-- own default.
local function addFieldDef(tpl, code, type_, prom, citation)
  local fdef = fhCreateItem("FDEF", tpl)
  fhSetValueAsText(fhCreateItem("CODE", fdef), code)
  fhSetValueAsText(fhCreateItem("TYPE", fdef), type_)
  if prom then
    fhSetValueAsText(fhCreateItem("PROM", fdef), prom)
  end
  if citation then
    fhSetValueAsText(fhCreateItem("CITN", fdef), "Yes")
  end
end

local function findChild(node, tag)
  for _, child in ipairs(node.children) do
    if child.tag == tag then
      return child
    end
  end
  return nil
end

------------------------------------------------------------------
-- Fixtures
------------------------------------------------------------------

resetTree()

local repo = fhCreateItem("REPO")

local civilReg = buildTemplate("Civil Registration Certificate")
addFieldDef(civilReg, "Type", "Enum", "Birth | Marriage | Death | Divorce")
addFieldDef(civilReg, "Reg_No", "Text")
addFieldDef(civilReg, "Principal_2", "Name")
addFieldDef(civilReg, "Reg_Date", "Date")
addFieldDef(civilReg, "District", "Place")
addFieldDef(civilReg, "Informant_Address", "Address")
addFieldDef(civilReg, "Held_At", "Repository")
addFieldDef(civilReg, "Ref_URL", "URL")

local civilRegId = fhGetRecordId(civilReg)

-- sourceHelper must be require()'d only after the fake globals above exist, since it
-- resolves them (fhCreateItem etc.) at module load via plain global reference.
local sourceHelper = require('sourceHelper')

------------------------------------------------------------------
-- Every field type, via name resolution
------------------------------------------------------------------

local sourBefore = #(recordsByTag["SOUR"] or {})
local result = sourceHelper.createSourceFromTemplate("civil registration certificate", {
  Type = "Birth",
  Reg_No = "1895/Q1/123",
  Principal_2 = "Nellie Record",
  Reg_Date = { year = 1895, month = 3, day = 12 },
  District = "Someplace",
  Informant_Address = "1 Some Street",
  Held_At = repo,
  Ref_URL = "https://example.invalid/cert",
}, "Transcribed certificate text")

check(type(result) == 'table' and type(result.id) == 'number', 'returns { id = <number> }')
check(type(result.title) == 'string' and result.title ~= '', 'returns a non-empty title')
check(#(recordsByTag["SOUR"]) == sourBefore + 1, 'creates exactly one new SOUR record')

local sourNode = recordsByTag["SOUR"][#recordsByTag["SOUR"]]
check(sourNode.id == result.id, 'returned id matches the created SOUR record')

local srctLink = findChild(sourNode, "_SRCT")
check(srctLink ~= nil, 'creates a _SRCT link child')
check(srctLink and srctLink.value == currentNode(civilReg), '_SRCT link points at the resolved template (name resolution)')

local function fieldValue(code)
  local suffix = "-" .. code
  for _, child in ipairs(sourNode.children) do
    if type(child.tag) == 'string' and child.tag:sub(-#suffix) == suffix then
      return child.value, child.tag
    end
  end
  return nil
end

local typeVal, typeTag = fieldValue("Type")
check(typeVal == "Birth", 'Enum field (Type) set correctly')
check(typeTag == "~EN-Type", 'Enum field uses ~EN- shortcut prefix')

local textVal, textTag = fieldValue("Reg_No")
check(textVal == "1895/Q1/123", 'Text field set correctly')
check(textTag == "~TX-Reg_No", 'Text field uses ~TX- shortcut prefix')

local nameVal, nameTag = fieldValue("Principal_2")
check(nameVal == "Nellie Record", 'Name field set correctly')
check(nameTag == "~NM-Principal_2", 'Name field uses ~NM- shortcut prefix')

local dateVal, dateTag = fieldValue("Reg_Date")
local dateFields = dateObjFields[dateVal]
check(dateFields ~= nil and dateFields.year == 1895 and dateFields.month == 3 and dateFields.day == 12,
  'Date field (table shorthand) converted via fhNewDate with the right y/m/d')
check(dateTag == "~DT-Reg_Date", 'Date field uses ~DT- shortcut prefix')

local placeVal = fieldValue("District")
check(placeVal == "Someplace", 'Place field set correctly')

local addressVal = fieldValue("Informant_Address")
check(addressVal == "1 Some Street", 'Address field set correctly')

local repoVal, repoTag = fieldValue("Held_At")
check(repoVal == currentNode(repo), 'Repository field set via fhSetValueAsLink to the supplied record')
check(repoTag == "~RP-Held_At", 'Repository field uses ~RP- shortcut prefix')

local urlVal = fieldValue("Ref_URL")
check(urlVal == "https://example.invalid/cert", 'URL field set correctly')

local textChild = findChild(sourNode, "TEXT")
check(textChild ~= nil, 'creates a TEXT child for the transcription')
check(textChild and type(textChild.value) == 'table' and textChild.value.text == "Transcribed certificate text" and textChild.value.rich == false,
  'transcription stored as plain (non-FTF) text via fhNewRichText(text, false)')

local lastAutoTitle = autoTitleCalls[#autoTitleCalls]
check(lastAutoTitle.node == sourNode, 'fhSrcEnableAutoTitle called with the new SOUR record\'s own pointer')
check(lastAutoTitle.enabled == true, 'fhSrcEnableAutoTitle called with true')

------------------------------------------------------------------
-- Date field via a pre-built Date object (fhNewDate), not the table shorthand
------------------------------------------------------------------

local dateObj = fhNewDate(1900, 1, 1)
local resultDateObj = sourceHelper.createSourceFromTemplate(civilRegId, { Reg_Date = dateObj })
local sourNode2 = recordsByTag["SOUR"][#recordsByTag["SOUR"]]
local dateObjVal = nil
for _, child in ipairs(sourNode2.children) do
  if child.tag == "~DT-Reg_Date" then
    dateObjVal = child.value
  end
end
check(dateObjVal == dateObj, 'Date field accepts an already-built Date object unchanged (not re-wrapped)')

------------------------------------------------------------------
-- Template resolution by id
------------------------------------------------------------------

check(resultDateObj ~= nil and type(resultDateObj.id) == 'number', 'template resolution by numeric id succeeds')

------------------------------------------------------------------
-- fields may be nil or {} — a linked Source with no fields is valid
------------------------------------------------------------------

local sourCountBeforeEmpty = #recordsByTag["SOUR"]
local emptyResult = sourceHelper.createSourceFromTemplate(civilRegId, nil, nil)
check(type(emptyResult.id) == 'number', 'createSourceFromTemplate(id, nil, nil) succeeds')
check(#recordsByTag["SOUR"] == sourCountBeforeEmpty + 1, 'still creates the SOUR record and its _SRCT link with no fields supplied')

------------------------------------------------------------------
-- Unknown field code errors before any mutation
------------------------------------------------------------------

local sourCountBeforeBadCode = #recordsByTag["SOUR"]
local ok, err = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { NotAField = "x" })
check(not ok, 'unknown field code raises an error')
check(contains(err, 'NotAField'), 'error names the offending field code')
check(#recordsByTag["SOUR"] == sourCountBeforeBadCode, 'no SOUR record created when an unknown field code is rejected')

------------------------------------------------------------------
-- Invalid Enum value errors before any mutation
------------------------------------------------------------------

local sourCountBeforeBadEnum = #recordsByTag["SOUR"]
local ok2, err2 = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { Type = "birth" })
check(not ok2, 'invalid Enum value (wrong case) raises an error')
check(contains(err2, 'birth'), 'error names the offending value')
check(#recordsByTag["SOUR"] == sourCountBeforeBadEnum, 'no SOUR record created when an invalid Enum value is rejected')

local ok3 = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { Type = "Adoption" })
check(not ok3, 'Enum value not among the declared options raises an error')

------------------------------------------------------------------
-- Ambiguous / missing template name or id
------------------------------------------------------------------

local dupe = buildTemplate("Civil Registration Certificate")
local okDupe, errDupe = pcall(sourceHelper.createSourceFromTemplate, "Civil Registration Certificate", {})
check(not okDupe, 'ambiguous template name (two templates, same name) raises an error')
check(contains(errDupe, '2'), 'ambiguous-name error mentions the match count')

local okMissingName, errMissingName = pcall(sourceHelper.createSourceFromTemplate, "No Such Template", {})
check(not okMissingName, 'missing template name raises an error')
check(contains(errMissingName, 'No Such Template'), 'missing-name error names the template that was looked for')

local okMissingId, errMissingId = pcall(sourceHelper.createSourceFromTemplate, 999999, {})
check(not okMissingId, 'missing template id raises an error')
check(contains(errMissingId, '999999'), 'missing-id error names the id that was looked for')

------------------------------------------------------------------
-- citeSource: attaches a SOUR citation to any target item (record or Fact)
------------------------------------------------------------------

local function buildSource(title)
  local sour = fhCreateItem("SOUR")
  fhSetValueAsText(fhCreateItem("TITL", sour), title)
  return sour
end

local certSource = buildSource("Birth certificate of Nellie Record, 15 November 1895")
local certSourceId = fhGetRecordId(certSource)

local indiTarget = fhCreateItem("INDI")
sourceHelper.citeSource(indiTarget, certSourceId)
local indiCite = findChild(currentNode(indiTarget), "SOUR")
check(indiCite ~= nil, 'citeSource creates a SOUR child on an INDI record (whole-record citation), resolved by id')
check(indiCite and indiCite.value == currentNode(certSource), 'whole-record SOUR child links (fhSetValueAsLink) to the resolved source')

local factTarget = fhCreateItem("BIRT", indiTarget)
sourceHelper.citeSource(factTarget, "Birth certificate of Nellie Record, 15 November 1895")
local factCite = findChild(currentNode(factTarget), "SOUR")
check(factCite ~= nil, 'citeSource creates a SOUR child on a Fact item too, resolved by exact title')
check(factCite and factCite.value == currentNode(certSource), 'Fact-level SOUR child links to the resolved source')

local factTarget2 = fhCreateItem("OCCU", indiTarget)
sourceHelper.citeSource(factTarget2, "BIRTH CERTIFICATE OF NELLIE RECORD, 15 NOVEMBER 1895")
local factCite2 = findChild(currentNode(factTarget2), "SOUR")
check(factCite2 and factCite2.value == currentNode(certSource), 'title resolution is case-insensitive')

------------------------------------------------------------------
-- citeSource: unknown / ambiguous source errors before any mutation
------------------------------------------------------------------

local function sourCountOnTarget(targetPtr)
  local count = 0
  for _, child in ipairs(currentNode(targetPtr).children) do
    if child.tag == "SOUR" then count = count + 1 end
  end
  return count
end

local badIdTarget = fhCreateItem("INDI")
local okBadId, errBadId = pcall(sourceHelper.citeSource, badIdTarget, 999999)
check(not okBadId, 'unknown source id raises an error')
check(contains(errBadId, '999999'), 'missing-id error names the id that was looked for')
check(sourCountOnTarget(badIdTarget) == 0, 'no SOUR citation created when the source id is not found')

local okBadTitle, errBadTitle = pcall(sourceHelper.citeSource, badIdTarget, "No Such Source")
check(not okBadTitle, 'unknown source title raises an error')
check(contains(errBadTitle, 'No Such Source'), 'missing-title error names the title that was looked for')
check(sourCountOnTarget(badIdTarget) == 0, 'no SOUR citation created when the source title is not found')

local dupeSource = buildSource("Birth certificate of Nellie Record, 15 November 1895")
local okDupeCite, errDupeCite = pcall(sourceHelper.citeSource, badIdTarget, "Birth certificate of Nellie Record, 15 November 1895")
check(not okDupeCite, 'ambiguous source title (two sources, same title) raises an error')
check(contains(errDupeCite, '2'), 'ambiguous-title error mentions the match count')
check(sourCountOnTarget(badIdTarget) == 0, 'no SOUR citation created when the source title is ambiguous')

------------------------------------------------------------------
-- findSources (issue #65): matches record-level fields on the SOUR record itself,
-- citation-level fields (CITN) on its citations instead, and reports citedBy regardless.
------------------------------------------------------------------

do
  resetTree()

  local regIndex = buildTemplate("Test Registration Index")
  addFieldDef(regIndex, "Type", "Enum", "Birth | Marriage")
  addFieldDef(regIndex, "RegDate", "Date")
  addFieldDef(regIndex, "District", "Text", nil, true)  -- citation-level (CITN)
  addFieldDef(regIndex, "Ref", "Text", nil, true)        -- citation-level (CITN)

  local otherTemplate = buildTemplate("Some Other Template")
  addFieldDef(otherTemplate, "Type", "Enum", "X | Y")

  local function setField(parentPtr, prefix, code, value)
    fhSetValueAsText(fhCreateItem("~" .. prefix .. "-" .. code, parentPtr), value)
  end

  local function makeSource(templatePtr, type_, dateObj)
    local sour = fhCreateItem("SOUR")
    local link = fhCreateItem("_SRCT", sour)
    fhSetValueAsLink(link, templatePtr)
    setField(sour, "EN", "Type", type_)
    fhSetValueAsDate(fhCreateItem("~DT-RegDate", sour), dateObj)
    return sour
  end

  local sourceA = makeSource(regIndex, "Birth", fhNewDate(1895, 3, 12))
  local sourceAId = fhGetRecordId(sourceA)
  local sourceB = makeSource(regIndex, "Marriage", fhNewDate(1900, 1, 1))
  local sourceBId = fhGetRecordId(sourceB)

  -- A source linked to a different template entirely -- must never appear in
  -- findSources("Test Registration Index", ...) results, however loose the filters.
  local offTemplateSource = makeSource(otherTemplate, "X", fhNewDate(2000, 1, 1))

  local function citeWithFields(targetPtr, sourcePtr, fields)
    local citation = fhCreateItem("SOUR", targetPtr)
    fhSetValueAsLink(citation, sourcePtr)
    for code, value in pairs(fields) do
      setField(citation, "TX", code, value)
    end
    return citation
  end

  local alice = fhCreateItem("INDI")
  local aliceQualifiedId = fhGetQualifiedRecordId(alice)
  local aliceBirt = fhCreateItem("BIRT", alice)
  citeWithFields(aliceBirt, sourceA, { District = "Barnstaple", Ref = "123" })

  local bob = fhCreateItem("INDI")
  local bobQualifiedId = fhGetQualifiedRecordId(bob)
  citeWithFields(bob, sourceA, { District = "Exeter", Ref = "456" })  -- whole-record citation

  local fam1 = fhCreateItem("FAM")
  local fam1QualifiedId = fhGetQualifiedRecordId(fam1)
  citeWithFields(fam1, sourceB, { District = "London", Ref = "789" })  -- whole-record citation

  local function findResult(results, id)
    for _, r in ipairs(results) do
      if r.source.id == id then return r end
    end
    return nil
  end

  local function citedByHas(citedBy, tag, qualifiedId)
    for _, entry in ipairs(citedBy) do
      if entry.tag == tag and entry.qualifiedId == qualifiedId then return true end
    end
    return false
  end

  ----------------------------------------------------------------
  -- No filters: every source linked to the template, each with its own citedBy
  ----------------------------------------------------------------

  local allResults = sourceHelper.findSources("Test Registration Index", {})
  check(#allResults == 2, 'findSources with no filters returns every SOUR linked to the template (not the off-template one)')

  local resultA = findResult(allResults, sourceAId)
  check(resultA ~= nil, 'sourceA is among the results')
  check(#resultA.citedBy == 2, 'sourceA.citedBy has both its citations (Alice\'s BIRT + Bob\'s whole-record)')
  check(citedByHas(resultA.citedBy, "BIRT", aliceQualifiedId), 'sourceA.citedBy reports the Fact-level citation with the enclosing Fact\'s own tag (BIRT), not "SOUR"')
  check(citedByHas(resultA.citedBy, "INDI", bobQualifiedId), 'sourceA.citedBy reports the whole-record citation with the owning record\'s own tag (INDI)')

  local resultB = findResult(allResults, sourceBId)
  check(resultB ~= nil, 'sourceB is among the results')
  check(#resultB.citedBy == 1 and citedByHas(resultB.citedBy, "FAM", fam1QualifiedId),
    'sourceB.citedBy reports its one whole-record citation on the FAM record')

  check(sourceHelper.findSources("Test Registration Index") ~= nil, 'fieldFilters is optional -- omitting it entirely behaves like {}')

  ----------------------------------------------------------------
  -- Record-level field filter (Enum, exact match)
  ----------------------------------------------------------------

  local birthOnly = sourceHelper.findSources("Test Registration Index", { Type = "Birth" })
  check(#birthOnly == 1 and birthOnly[1].source.id == sourceAId, 'record-level Enum filter (Type=Birth) matches only sourceA, exactly')

  ----------------------------------------------------------------
  -- Record-level field filter (Date, exact match against the rendered display text)
  ----------------------------------------------------------------

  local byDate = sourceHelper.findSources("Test Registration Index", { RegDate = "1900-01-01" })
  check(#byDate == 1 and byDate[1].source.id == sourceBId, 'record-level Date filter matches only sourceB, exactly')

  ----------------------------------------------------------------
  -- Citation-level field filter (Text, case-insensitive substring) -- checked against
  -- citations, not the SOUR record's own fields (District/Ref aren't even populated
  -- there)
  ----------------------------------------------------------------

  local byDistrict = sourceHelper.findSources("Test Registration Index", { District = "barn" })
  check(#byDistrict == 1 and byDistrict[1].source.id == sourceAId,
    'citation-level filter (District ~ "barn") matches sourceA via Alice\'s citation, substring + case-insensitive')

  local byDistrict2 = sourceHelper.findSources("Test Registration Index", { District = "London" })
  check(#byDistrict2 == 1 and byDistrict2[1].source.id == sourceBId, 'citation-level filter matches sourceB via its own citation')

  local byRef = sourceHelper.findSources("Test Registration Index", { Ref = "456" })
  check(#byRef == 1 and byRef[1].source.id == sourceAId,
    'citation-level filter matches a source if ANY of its citations has a matching value (Bob\'s, not Alice\'s)')

  local noMatch = sourceHelper.findSources("Test Registration Index", { District = "Nowhere" })
  check(type(noMatch) == 'table' and #noMatch == 0, 'a citation-level filter matching no citation returns an empty array, not an error')

  ----------------------------------------------------------------
  -- Combined record-level + citation-level filters (AND, both must hold for the same
  -- source; the citation-level check is scoped to THAT source's own citations)
  ----------------------------------------------------------------

  local combinedMatch = sourceHelper.findSources("Test Registration Index", { Type = "Birth", District = "Exeter" })
  check(#combinedMatch == 1 and combinedMatch[1].source.id == sourceAId, 'record-level and citation-level filters combine (AND) on the same source')

  local combinedNoMatch = sourceHelper.findSources("Test Registration Index", { Type = "Marriage", District = "Exeter" })
  check(#combinedNoMatch == 0, 'combined filters don\'t cross-match -- sourceB\'s Type matches but "Exeter" is only on sourceA\'s citation')

  ----------------------------------------------------------------
  -- Errors
  ----------------------------------------------------------------

  local okBadCode, errBadCode = pcall(sourceHelper.findSources, "Test Registration Index", { NotAField = "x" })
  check(not okBadCode, 'an unknown field code raises an error')
  check(contains(errBadCode, "NotAField"), 'the error names the offending field code')

  local okBadTemplate = pcall(sourceHelper.findSources, "No Such Template", {})
  check(not okBadTemplate, 'an unresolvable template name raises an error, same as createSourceFromTemplate')

  ----------------------------------------------------------------
  -- getPopulatedTemplateFields (issue #73): the extracted resolution helper findSources'
  -- own recordMatchesFilters already exercises indirectly above -- these tests call it
  -- directly, reusing the same fixtures.
  ----------------------------------------------------------------

  local sourceAFields = sourceHelper.getPopulatedTemplateFields(sourceA)
  check(sourceAFields.Type == "Birth", 'getPopulatedTemplateFields resolves a record-level Enum field')
  check(sourceAFields.RegDate == "1895-03-12", 'getPopulatedTemplateFields resolves a record-level Date field as rendered text')
  check(sourceAFields.District == nil and sourceAFields.Ref == nil,
    'getPopulatedTemplateFields does not surface citation-level (CITN) fields, even though sourceA has citations with them populated')

  local offTemplateFields = sourceHelper.getPopulatedTemplateFields(offTemplateSource)
  check(offTemplateFields.Type == "X", 'getPopulatedTemplateFields resolves fields per the source\'s own linked template, not a fixed one')

  local sourceAByQualifiedId = sourceHelper.getPopulatedTemplateFields(fhGetQualifiedRecordId(sourceA))
  check(sourceAByQualifiedId.Type == "Birth", 'getPopulatedTemplateFields accepts a qualified id string, same as familyHelper\'s other functions')

  local untemplatedSource = fhCreateItem("SOUR")
  local untemplatedFields = sourceHelper.getPopulatedTemplateFields(untemplatedSource)
  check(type(untemplatedFields) == 'table' and next(untemplatedFields) == nil,
    'getPopulatedTemplateFields returns an empty table, not an error, for a non-templated source')

  local okNullPtr, errNullPtr = pcall(sourceHelper.getPopulatedTemplateFields, fhNewItemPtr())
  check(not okNullPtr, 'getPopulatedTemplateFields raises on a null pointer, rather than silently reading as "not templated"')
  check(contains(errNullPtr, "getPopulatedTemplateFields"), 'the error names the function, same as getAllDetails\' own null-pointer error')
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
