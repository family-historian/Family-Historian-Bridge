-- Standalone tests for sourceHelper.lua. Run with: lua bridge/tests/sourceHelper.test.lua
-- No FH/socket dependency. Unlike sandbox.test.lua/runScript.test.lua's flat, no-op
-- stubs, sourceHelper.lua genuinely walks a record/child-item tree (MoveToFirstRecord,
-- MoveToFirstChildItem, MoveNext) and creates new items in it — so this file builds a
-- small in-memory fake item-pointer double, scoped narrowly to only the methods/globals
-- sourceHelper.lua actually calls: item-pointer methods MoveToFirstRecord/
-- MoveToFirstChildItem/MoveNext/IsNotNull/IsNull/Clone, plus globals fhGetTag/fhGetItemText/
-- fhGetRecordId/fhCreateItem/fhSetValueAsText/fhSetValueAsDate/fhSetValueAsLink/
-- fhSetValueAsRichText/fhNewDate/fhNewRichText/fhSrcEnableAutoTitle.

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

-- "~" is the self-reference Data Reference token (see the '~.NAME'/'~:SURNAME' qualifier
-- examples in the gedcom-knowledge-corpus and bridge/README.md's own manual write-test
-- script) — sourceHelper.lua only ever reads a pointer's own scalar value, never a
-- qualified/relative reference, so that's the only case this fake needs to support.
fhGetItemText = function(ptr, dataRef)
  local node = currentNode(ptr)
  if not node then return "" end
  if dataRef == "~" then
    return node.value or ""
  end
  return ""
end

fhGetRecordId = function(ptr)
  local node = currentNode(ptr)
  return node and node.id
end

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
  currentNode(ptr).value = value
end

fhSetValueAsDate = function(ptr, dateObj)
  currentNode(ptr).value = dateObj
end

fhSetValueAsLink = function(ptr, targetPtr)
  currentNode(ptr).value = currentNode(targetPtr)
end

fhSetValueAsRichText = function(ptr, richTextObj)
  currentNode(ptr).value = richTextObj
end

-- Real FH's fhNewDate returns a Date *object* (userdata, per the API's own Hungarian-
-- notation prefix table) — genuinely a different Lua type from a plain table, which is
-- exactly what lets sourceHelper.lua's toDate() tell "already a Date object" apart from
-- "the {year=,month=,day=} shorthand table" via a plain type() check. A fake that returned
-- a table here would collapse that distinction and defeat the test below. A coroutine
-- (type 'thread') is a free, dependency-free stand-in for opaque host userdata; its fields
-- live in this side table, keyed weakly so they don't outlive the coroutine.
local dateObjFields = setmetatable({}, { __mode = 'k' })
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

local function addFieldDef(tpl, code, type_, prom)
  local fdef = fhCreateItem("FDEF", tpl)
  fhSetValueAsText(fhCreateItem("CODE", fdef), code)
  fhSetValueAsText(fhCreateItem("TYPE", fdef), type_)
  if prom then
    fhSetValueAsText(fhCreateItem("PROM", fdef), prom)
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

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
