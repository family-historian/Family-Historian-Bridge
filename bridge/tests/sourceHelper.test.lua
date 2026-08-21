-- Standalone tests for sourceHelper.lua. Run with: lua bridge/tests/sourceHelper.test.lua
-- No FH/socket dependency. Unlike sandbox.test.lua/runScript.test.lua's flat, no-op
-- stubs, sourceHelper.lua genuinely walks a record/child-item tree (MoveToFirstRecord,
-- MoveToFirstChildItem, MoveNext) and creates new items in it — so this file builds a
-- small in-memory fake item-pointer double, scoped narrowly to only the methods/globals
-- sourceHelper.lua actually calls: item-pointer methods MoveToFirstRecord/
-- MoveToFirstChildItem/MoveNext/IsNotNull/IsNull/Clone, plus globals fhGetTag/fhGetItemText/
-- fhGetRecordId/fhCreateItem/fhSetValueAsText/fhSetValueAsDate/fhSetValueAsLink/
-- fhSetValueAsRichText/fhNewDate/fhNewRichText/fhSrcEnableAutoTitle/fhGetRecordLinks
-- (issue #66).
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

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new()
local check, contains = t.check, t.contains

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

-- Write-result failure injection (issue #111, docs/adr/0028): sourceHelper.lua's own
-- checkWrite/checkCreated calls now inspect fhSetValueAs*'s bOK / fhCreateItem's NULL-
-- pointer failure contract, so a fixture that wants to prove the guard fires sets one of
-- these true immediately before the one call it wants to fail -- each flag self-resets
-- after firing once, so it never leaks into an unrelated later call in the same test.
local forceNextWriteFailure = false
local forceNextCreateFailure = false

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

-- Needed for citationsForSource (issue #66): parentLoc/recordLoc are stamped on every node
-- by fhCreateItem below (nil for a top-level record, since it has no parent/isn't nested).
function PtrMethods:MoveToParentItem(ptrRef)
  local node = currentNode(ptrRef)
  local loc = node and node.parentLoc
  self.list = loc and loc.list or nil
  self.index = loc and loc.index or nil
end

function PtrMethods:MoveToRecordItem(ptrRef)
  local node = currentNode(ptrRef)
  local loc = node and node.recordLoc
  if loc then
    self.list = loc.list
    self.index = loc.index
  else
    -- No recordLoc means ptrRef already points at the record itself.
    self.list = ptrRef.list
    self.index = ptrRef.index
  end
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
  if forceNextCreateFailure then
    forceNextCreateFailure = false
    -- An unpositioned fake pointer: currentNode(ptr) is nil, so :IsNull() is true --
    -- the same shape real FH's own NULL-pointer create failure has.
    return newPtr()
  end
  local node = { tag = tagOrShortcut, children = {} }
  local ptr = newPtr()
  if not parentPtr then
    node.id = nextId
    nextId = nextId + 1
    recordsByTag[tagOrShortcut] = recordsByTag[tagOrShortcut] or {}
    table.insert(recordsByTag[tagOrShortcut], node)
    ptr.list = recordsByTag[tagOrShortcut]
    ptr.index = #recordsByTag[tagOrShortcut]
    -- No parentLoc/recordLoc: a top-level record has no parent and is its own record.
  else
    local parentNode = currentNode(parentPtr)
    table.insert(parentNode.children, node)
    ptr.list = parentNode.children
    ptr.index = #parentNode.children
    -- MoveToParentItem/MoveToRecordItem (issue #66): parentLoc is always parentPtr's own
    -- location; recordLoc inherits from parentNode, or is parentLoc itself if parentNode
    -- is the record (parentNode.recordLoc == nil).
    node.parentLoc = { list = parentPtr.list, index = parentPtr.index }
    node.recordLoc = parentNode.recordLoc or node.parentLoc
  end
  return ptr
end

fhSetValueAsText = function(ptr, value)
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  local node = currentNode(ptr)
  node.value = value
  node.valueType = "text"
  return true
end

fhSetValueAsDate = function(ptr, dateObj)
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  local node = currentNode(ptr)
  node.value = dateObj
  node.valueType = "date"
  return true
end

fhSetValueAsLink = function(ptr, targetPtr)
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  local node = currentNode(ptr)
  node.value = currentNode(targetPtr)
  node.valueType = "link"
  return true
end

fhSetValueAsRichText = function(ptr, richTextObj)
  if forceNextWriteFailure then
    forceNextWriteFailure = false
    return false
  end
  local node = currentNode(ptr)
  node.value = richTextObj
  node.valueType = "richtext"
  return true
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

-- fhGetRecordLinks(ptr) -- issue #66. Real FH returns the linking item itself, item-level
-- and at whatever depth it lives, not resolved up to its owning record (live-confirmed
-- against a running Bridge). This fake walks every record's own child tree (any depth) for
-- a link value pointing at ptr's node, returning a fake pointer to each such linking item --
-- each already carries the parentLoc/recordLoc stamped on it by fhCreateItem, so
-- MoveToParentItem/MoveToRecordItem on the result work the same as in the real Bridge.
local function collectLinksTo(containerNode, targetNode, results)
  for i, child in ipairs(containerNode.children) do
    if type(child.value) == 'table' and child.value == targetNode then
      local p = newPtr()
      p.list = containerNode.children
      p.index = i
      table.insert(results, p)
    end
    collectLinksTo(child, targetNode, results)
  end
end

fhGetRecordLinks = function(ptr)
  local targetNode = currentNode(ptr)
  local results = {}
  if not targetNode then return results end
  for _, list in pairs(recordsByTag) do
    for _, recordNode in ipairs(list) do
      collectLinksTo(recordNode, targetNode, results)
    end
  end
  return results
end

-- Real FH's fhNewDate returns a Date *object* (userdata, per the API's own Hungarian-
-- notation prefix table) — genuinely a different Lua type from a plain table, which is
-- exactly what lets sourceHelper.lua's toDate() tell "already a Date object" apart from
-- "the {year=,month=,day=} shorthand table" via a plain type() check. A fake that returned
-- a table here would collapse that distinction and defeat the test below. A coroutine
-- (type 'thread') is a free, dependency-free stand-in for opaque host userdata; its fields
-- live in this side table, keyed weakly so they don't outlive the coroutine.
-- Uses varargs (not named y/m/d/subtype params) so this fake can distinguish "called with
-- 3 args" from "called with 4 args, the 4th explicitly nil" -- real FH's fhNewDate binding
-- rejects the latter ("bad argument #4 to 'fhNewDate' (string expected, got nil)",
-- live-confirmed issue #99) even though its own doc marks strSubType optional; a named-
-- param fake can't tell the two calls apart and would have let sourceHelper.lua's original
-- toDate() bug (always passing value.subtype, nil or not) through undetected, which is
-- exactly what happened -- this bug shipped past every existing unit test and was only
-- caught live.
dateObjFields = setmetatable({}, { __mode = 'k' })
-- resolveDate's string-date support (issue #113, docs/adr/0030) calls dt:SetValueAsText(...)
-- on a fhNewDate()-built object -- debug.setmetatable on a thread sets ONE shared metatable
-- for every coroutine in this process (Lua only supports a per-type, not per-value,
-- metatable for threads), so this is set once here rather than per-fhNewDate-call. Succeeds
-- only for a bare 4-digit-year string, matching resolveDate's own bAllowPhrase=false call --
-- just enough to exercise the success/failure split, not a real date-parsing engine.
debug.setmetatable(coroutine.create(function() end), {
  __index = {
    SetValueAsText = function(self, text, allowPhrase)
      if type(text) == "string" and text:match("^%d%d%d%d$") then
        dateObjFields[self].year = tonumber(text)
        dateObjFields[self].parsedFromText = text
        return true
      end
      return false
    end,
  },
})
fhNewDate = function(...)
  local argCount = select('#', ...)
  local y, m, d, subtype = ...
  if argCount >= 4 and subtype == nil then
    error("bad argument #4 to 'fhNewDate' (string expected, got nil)")
  end
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

-- Shared by the findSources and getTemplateFieldCensus fixture blocks below (both build a
-- templated SOUR record plus citations on it, sourced from raw ~PREFIX-CODE shortcuts
-- rather than sourceHelper.lua's own createSourceFromTemplate/citeSource, so a
-- citation-level field can be populated the way createSourceFromTemplate/citeSource never
-- do) -- hoisted here rather than declared once per block so the two don't drift.
local function setField(parentPtr, prefix, code, value)
  fhSetValueAsText(fhCreateItem("~" .. prefix .. "-" .. code, parentPtr), value)
end

-- type_/dateObj are optional (nil skips that field entirely) so a fixture can leave a
-- record-level field deliberately unpopulated, e.g. getTemplateFieldCensus's own
-- "only tally what's actually populated" tests below.
local function makeSource(templatePtr, type_, dateObj)
  local sour = fhCreateItem("SOUR")
  local link = fhCreateItem("_SRCT", sour)
  fhSetValueAsLink(link, templatePtr)
  if type_ then
    setField(sour, "EN", "Type", type_)
  end
  if dateObj then
    fhSetValueAsDate(fhCreateItem("~DT-RegDate", sour), dateObj)
  end
  return sour
end

local function citeWithFields(targetPtr, sourcePtr, fields)
  local citation = fhCreateItem("SOUR", targetPtr)
  fhSetValueAsLink(citation, sourcePtr)
  for code, value in pairs(fields) do
    setField(citation, "TX", code, value)
  end
  return citation
end

local function findChild(node, tag)
  for _, child in ipairs(node.children) do
    if child.tag == tag then
      return child
    end
  end
  return nil
end

-- Simulates FH's real fhGetMetafieldShortcut (fh-help: "Takes a pointer to a metafield
-- item and returns a shortcut for it... Can also be used with metafield definitions").
-- sourceHelper.lua's own shortcutFor (issue #73) only ever calls this on a metafield
-- *definition* here (an FDEF item, via def.fdefPtr) -- reads that item's own CODE/TYPE
-- children and builds "~PREFIX-CODE". Deliberately keeps CODE's exact case as stored
-- (e.g. "~TX-Reg_No"), NOT uppercased the way real FH's shortcut actually is
-- (live-confirmed, issue #73: "~TX-REFERENCE") -- this fake's own fhCreateItem already
-- tags a created field by the shortcut this fixture file's own setField/citeWithFields
-- helpers build the same (also not uppercased, below), so keeping this fake's casing
-- internally consistent matters more here than matching FH's real casing exactly, which
-- the production code doesn't depend on anyway (Data Reference resolution is
-- case-insensitive on the code portion, live-confirmed).
local METAFIELD_SHORTCUT_PREFIX = {
  Text = "TX", Name = "NM", Place = "PL", Address = "AD",
  Enum = "EN", Date = "DT", Repository = "RP", URL = "UL",
}
fhGetMetafieldShortcut = function(fdefPtr)
  local node = currentNode(fdefPtr)
  if not node then return "" end
  local codeChild = findChild(node, "CODE")
  local typeChild = findChild(node, "TYPE")
  local prefix = typeChild and METAFIELD_SHORTCUT_PREFIX[typeChild.value]
  if not prefix or not codeChild then return "" end
  return "~" .. prefix .. "-" .. codeChild.value
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
addFieldDef(civilReg, "CitationField", "Text", nil, true)  -- citation-level (CITN), issue #98

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
-- Date field via a plain string (issue #113, docs/adr/0030) -- resolved through
-- familyHelper.resolveDate, same as the table shorthand and the Date-object form above.
------------------------------------------------------------------

local resultDateString = sourceHelper.createSourceFromTemplate(civilRegId, { Reg_Date = "1899" })
local sourNode3 = recordsByTag["SOUR"][#recordsByTag["SOUR"]]
local dateStringVal, dateStringTag = nil, nil
for _, child in ipairs(sourNode3.children) do
  if child.tag == "~DT-Reg_Date" then
    dateStringVal = child.value
    dateStringTag = child.tag
  end
end
check(dateStringVal ~= nil and dateObjFields[dateStringVal] and dateObjFields[dateStringVal].year == 1899,
  'a recognized date string is parsed into a real Date object via familyHelper.resolveDate before being written')
check(dateStringTag == "~DT-Reg_Date", 'the parsed-from-string Date field still uses the ~DT- shortcut prefix')
check(resultDateString ~= nil, 'createSourceFromTemplate succeeds with a string Date field')

-- Unlike the unknown-field-code/invalid-Enum/citation-field cases above (all caught by
-- validateFields during the pure validateCreateSourceFromTemplate pass, before fhCreateItem
-- ever runs), a Date field's resolveDate call only happens inside setField, per-field,
-- during the mutate phase itself -- a pre-existing characteristic of this loop (each field
-- is created-then-set in turn), not something this change introduces. So a rejected Date
-- string here does still leave the SOUR record and its _SRCT template link behind, same as
-- any other field-population failure partway through this same loop.
local sourCountBeforeBadDate = #recordsByTag["SOUR"]
local okBadDate, errBadDate = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { Reg_Date = "not a date" })
check(not okBadDate, 'an unrecognized date string raises rather than proceeding')
check(contains(errBadDate, "not a date"), 'the rejection names the offending string')
check(#recordsByTag["SOUR"] == sourCountBeforeBadDate + 1,
  'the SOUR record and its _SRCT link are still created before the per-field loop reaches and rejects the bad Date field (pre-existing behavior, unrelated to this change)')

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
-- Citation-specific field code errors before any mutation (issue #98):
-- fields is record-level only, so a code whose FDEF carries CITN="Yes" must be rejected,
-- not silently no-op'd.
------------------------------------------------------------------

local sourCountBeforeCitationField = #recordsByTag["SOUR"]
local okCitation, errCitation = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { CitationField = "x" })
check(not okCitation, 'citation-specific field code raises an error')
check(contains(errCitation, 'CitationField'), 'error names the offending field code')
check(contains(errCitation, 'citation-specific'), 'error explains the field is citation-specific')
check(#recordsByTag["SOUR"] == sourCountBeforeCitationField, 'no SOUR record created when a citation-specific field is rejected')

local sourCountBeforeMixed = #recordsByTag["SOUR"]
local okMixed = pcall(sourceHelper.createSourceFromTemplate, civilRegId, { Reg_No = "1895/Q1/999", CitationField = "x" })
check(not okMixed, 'rejection still fires when mixed with a valid record-level field')
check(#recordsByTag["SOUR"] == sourCountBeforeMixed,
  'no SOUR record created at all (not even the valid record-level field) -- validation runs fully before any mutation')

------------------------------------------------------------------
-- Ambiguous / missing template name or id
------------------------------------------------------------------

buildTemplate("Civil Registration Certificate")
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
-- validateCreateSourceFromTemplate (issue #97): the pure validation half of
-- createSourceFromTemplate, exported so sandbox.lua can run it untracked before arming the
-- write tracker. Same success/failure behavior as createSourceFromTemplate's own steps 1-3,
-- but never creates anything -- not even on success (that's mutate's job, step 4).
------------------------------------------------------------------

local validatedTemplate, validatedDefs = sourceHelper.validateCreateSourceFromTemplate(civilRegId, { Type = "Birth" })
check(validatedTemplate ~= nil, 'validateCreateSourceFromTemplate returns the resolved template on success')
check(type(validatedDefs) == 'table' and validatedDefs.Type ~= nil, 'validateCreateSourceFromTemplate returns the template\'s field-def map on success')

local okValidateBadField, errValidateBadField = pcall(sourceHelper.validateCreateSourceFromTemplate, civilRegId, { NotAField = "x" })
check(not okValidateBadField, 'validateCreateSourceFromTemplate rejects an unknown field code, same as createSourceFromTemplate')
check(contains(errValidateBadField, 'NotAField'), 'the rejection names the unknown field code')

local okValidateMissingId = pcall(sourceHelper.validateCreateSourceFromTemplate, 999999, {})
check(not okValidateMissingId, 'validateCreateSourceFromTemplate rejects an unresolvable template id, same as createSourceFromTemplate')

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
local indiCiteReturn = sourceHelper.citeSource(indiTarget, certSourceId)
local indiCite = findChild(currentNode(indiTarget), "SOUR")
check(indiCite ~= nil, 'citeSource creates a SOUR child on an INDI record (whole-record citation), resolved by id')
check(indiCite and indiCite.value == currentNode(certSource), 'whole-record SOUR child links (fhSetValueAsLink) to the resolved source')
check(indiCiteReturn ~= nil and currentNode(indiCiteReturn) == indiCite,
  'citeSource returns the created citation\'s own item pointer even with no fields argument (issue #99)')

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

buildSource("Birth certificate of Nellie Record, 15 November 1895")
local okDupeCite, errDupeCite = pcall(sourceHelper.citeSource, badIdTarget, "Birth certificate of Nellie Record, 15 November 1895")
check(not okDupeCite, 'ambiguous source title (two sources, same title) raises an error')
check(contains(errDupeCite, '2'), 'ambiguous-title error mentions the match count')
check(sourCountOnTarget(badIdTarget) == 0, 'no SOUR citation created when the source title is ambiguous')

------------------------------------------------------------------
-- citeSource/createSourceFromTemplate: a qualified id string (e.g. "S1186") resolves by
-- id, the same as a bare number -- issue #100. Precedence: an id-shaped string always
-- resolves as an id, never attempted against Title, even if it happens to be shaped like
-- a DIFFERENT record type's qualified id -- that falls through to the ordinary Title
-- match instead of cross-resolving to the wrong tag.
------------------------------------------------------------------

do
  local qualifiedIdTarget = fhCreateItem("INDI")
  local certSourceQualifiedId = fhGetQualifiedRecordId(certSource)
  sourceHelper.citeSource(qualifiedIdTarget, certSourceQualifiedId)
  local qualifiedIdCite = findChild(currentNode(qualifiedIdTarget), "SOUR")
  check(qualifiedIdCite ~= nil and qualifiedIdCite.value == currentNode(certSource),
    'citeSource resolves a qualified id string (e.g. "S' .. certSourceId .. '") the same as the equivalent bare number')

  local templatedByQualifiedId = sourceHelper.createSourceFromTemplate(fhGetQualifiedRecordId(civilReg), { Reg_No = "1895/Q1/9" })
  local templatedSourNode
  for _, n in ipairs(recordsByTag["SOUR"]) do
    if n.id == templatedByQualifiedId.id then templatedSourNode = n end
  end
  local srctLinkByQualifiedId = findChild(templatedSourNode, "_SRCT")
  check(srctLinkByQualifiedId ~= nil and srctLinkByQualifiedId.value == currentNode(civilReg),
    'createSourceFromTemplate resolves a qualified id string (e.g. "T' .. civilRegId .. '") the same as the equivalent bare number')

  local okNotFoundQualifiedId, errNotFoundQualifiedId = pcall(sourceHelper.citeSource, qualifiedIdTarget, "S999999")
  check(not okNotFoundQualifiedId, 'a well-shaped but nonexistent qualified id string raises an error')
  check(contains(errNotFoundQualifiedId, '999999'), 'the error names the id that was looked for')
  check(not contains(errNotFoundQualifiedId, 'named'), 'the error is the id-not-found error, not a Title-lookup fallback (no fallback is ever attempted)')

  local wrongTagTarget = fhCreateItem("INDI")
  local okWrongTag, errWrongTag = pcall(sourceHelper.citeSource, wrongTagTarget, "T4")
  check(not okWrongTag, 'a string shaped like a DIFFERENT tag\'s qualified id (T4 is a _SRCT shape, not SOUR) is not treated as an id at all')
  check(contains(errWrongTag, 'named') and contains(errWrongTag, 'T4'), 'it falls through to the ordinary Title match instead, and fails as an unknown title')
end

------------------------------------------------------------------
-- citeSource: an invalid ptrTarget errors before any mutation too (issue #96) -- the same
-- validate-before-mutate coverage as the unknown/ambiguous-source cases above, just for the
-- other argument. Both cases must fail before fhCreateItem("SOUR", ptrTarget) is ever
-- called, not just eventually.
------------------------------------------------------------------

local okNilTarget, errNilTarget = pcall(sourceHelper.citeSource, nil, certSourceId)
check(not okNilTarget, 'a nil ptrTarget raises an error rather than proceeding')
check(contains(errNilTarget, 'ptrTarget'), 'the nil-ptrTarget error names ptrTarget specifically')

local nullTarget = newPtr()
local okNullTarget = pcall(sourceHelper.citeSource, nullTarget, certSourceId)
check(not okNullTarget, 'a non-nil but IsNull() ptrTarget also raises an error rather than proceeding')

local okStringTarget, errStringTarget = pcall(sourceHelper.citeSource, "not a pointer", certSourceId)
check(not okStringTarget, 'a wrong-typed (string) ptrTarget raises an error rather than a raw Lua crash (issue #110)')
check(contains(errStringTarget, 'ptrTarget') and contains(errStringTarget, 'string'),
  'the error names ptrTarget and the type actually given, not a raw "attempt to index" crash')

------------------------------------------------------------------
-- validateCiteSource (issue #97): the pure validation half of citeSource, exported so
-- sandbox.lua can run it untracked before arming the write tracker. Same success/failure
-- behavior as citeSource's own checks, but never creates a citation -- not even on success.
------------------------------------------------------------------

local validatedSource = sourceHelper.validateCiteSource(indiTarget, certSourceId)
check(validatedSource ~= nil, 'validateCiteSource returns the resolved source on success')
check(sourCountOnTarget(badIdTarget) == 0, 'validateCiteSource never creates a citation, even on success')

local okValidateNilTarget, errValidateNilTarget = pcall(sourceHelper.validateCiteSource, nil, certSourceId)
check(not okValidateNilTarget, 'validateCiteSource rejects a nil ptrTarget, same as citeSource')
check(contains(errValidateNilTarget, 'ptrTarget'), 'the rejection names ptrTarget specifically')

local okValidateBoolTarget, errValidateBoolTarget = pcall(sourceHelper.validateCiteSource, true, certSourceId)
check(not okValidateBoolTarget, 'validateCiteSource rejects a wrong-typed (boolean) ptrTarget too, same as citeSource')
check(contains(errValidateBoolTarget, 'must point to'), 'the rejection is validateCiteSource\'s own message, not a raw "attempt to index a boolean value" crash -- note Lua\'s own raw error happens to name the local variable too (issue #110 test-writing gotcha), so this checks the full semantic phrase, not just "ptrTarget"')
check(contains(errValidateBoolTarget, 'boolean'), 'the rejection also names the type actually given')

------------------------------------------------------------------
-- citeSource fields (issue #99, follow-up to #98's own closing comment): standard
-- citation fields (Page/Text/EntryDate/Assessment) apply regardless of whether the source
-- is templated; a template's own citation-specific (CITN) fields only apply when it is.
------------------------------------------------------------------

local function dataChild(citationNode)
  return findChild(citationNode, "DATA")
end

do
  local target = fhCreateItem("INDI")
  local returned = sourceHelper.citeSource(target, certSourceId, {
    Page = "p. 12",
    Text = "Transcribed citation text",
    EntryDate = { year = 2026, month = 8, day = 11 },
    Assessment = "Direct Primary",
  })

  check(returned ~= nil, 'citeSource returns a value')
  check(fhGetTag(returned) == "SOUR", 'citeSource returns the citation\'s own item pointer (tag SOUR)')

  local citationNode = currentNode(returned)
  check(citationNode == findChild(currentNode(target), "SOUR"), 'the returned pointer really is the created citation, not some other item')

  local pageChild = findChild(citationNode, "PAGE")
  check(pageChild ~= nil and pageChild.value == "p. 12", 'Page sets a PAGE child directly on the citation')

  local data = dataChild(citationNode)
  check(data ~= nil, 'Text/EntryDate share one DATA child on the citation')

  local citationTextChild = findChild(data, "TEXT")
  check(citationTextChild ~= nil and type(citationTextChild.value) == 'table' and citationTextChild.value.text == "Transcribed citation text" and citationTextChild.value.rich == false,
    'Text sets DATA.TEXT as plain (non-FTF) richtext, same fhNewRichText(text, false) convention as createSourceFromTemplate\'s transcription')

  local dateChild = findChild(data, "DATE")
  local df = dateChild and dateObjFields[dateChild.value]
  check(df ~= nil and df.year == 2026 and df.month == 8 and df.day == 11,
    'EntryDate sets DATA.DATE via fhNewDate, table shorthand converted the same way as a template Date field')

  local quayChild = findChild(citationNode, "QUAY")
  check(quayChild ~= nil and quayChild.value == "Direct Primary", 'Assessment sets a QUAY child directly on the citation')
end

------------------------------------------------------------------
-- citeSource's EntryDate as a plain string (issue #113, docs/adr/0030) -- same
-- familyHelper.resolveDate path as createSourceFromTemplate's Date-typed template fields.
------------------------------------------------------------------

do
  local target = fhCreateItem("INDI")
  local returned = sourceHelper.citeSource(target, certSourceId, { EntryDate = "1899" })
  local citationNode = findChild(currentNode(target), "SOUR")
  local dateChild = findChild(dataChild(citationNode), "DATE")
  local df = dateChild and dateObjFields[dateChild.value]
  check(df ~= nil and df.year == 1899 and df.parsedFromText == "1899",
    'a recognized EntryDate string is parsed into a real Date object via familyHelper.resolveDate before being written')
  check(returned ~= nil, 'citeSource succeeds with a string EntryDate')

  -- Same pre-existing (not introduced by this change) "citation already created before its
  -- own standard fields are populated" ordering as the SOUR-record case above -- setStandardField
  -- runs after fhCreateItem("SOUR", ptrTarget)/the source link, so a rejected EntryDate string
  -- still leaves a real, linked citation behind, just missing its EntryDate (and any field
  -- after it in the loop).
  local target2 = fhCreateItem("INDI")
  local sourCountBefore = 0
  for _, child in ipairs(currentNode(target2).children) do
    if child.tag == "SOUR" then sourCountBefore = sourCountBefore + 1 end
  end
  local okBadEntryDate, errBadEntryDate = pcall(sourceHelper.citeSource, target2, certSourceId, { EntryDate = "not a date" })
  check(not okBadEntryDate, 'an unrecognized EntryDate string raises rather than proceeding')
  check(contains(errBadEntryDate, "not a date"), 'the rejection names the offending string')
  local sourCountAfter = 0
  for _, child in ipairs(currentNode(target2).children) do
    if child.tag == "SOUR" then sourCountAfter = sourCountAfter + 1 end
  end
  check(sourCountAfter == sourCountBefore + 1,
    'the citation itself is still created and linked before EntryDate is reached and rejected (pre-existing behavior, unrelated to this change)')
end

------------------------------------------------------------------
-- Assessment (QUAY) vocabulary validation
------------------------------------------------------------------

do
  local target = fhCreateItem("INDI")
  local before = sourCountOnTarget(target)

  local okBadWord, errBadWord = pcall(sourceHelper.citeSource, target, certSourceId, { Assessment = "Maybe" })
  check(not okBadWord, 'an unrecognized Assessment word raises an error')
  check(contains(errBadWord, "Maybe"), 'the error names the offending word')
  check(sourCountOnTarget(target) == before, 'no citation created when Assessment is rejected')

  local okSameRow, errSameRow = pcall(sourceHelper.citeSource, target, certSourceId, { Assessment = "Unreliable Questionable" })
  check(not okSameRow, 'two words from the same Assessment row raises an error')
  check(contains(errSameRow, "row"), 'the error explains it\'s a same-row conflict')
  check(sourCountOnTarget(target) == before, 'no citation created when a same-row Assessment conflict is rejected')

  local okAllFour = pcall(sourceHelper.citeSource, target, certSourceId, { Assessment = "Unreliable Direct Secondary Derivative" })
  check(okAllFour, 'all four Assessment rows, one word each, is valid')

  local okEmpty = pcall(sourceHelper.citeSource, target, certSourceId, { Assessment = "" })
  check(okEmpty, 'an empty Assessment string is valid (no assessment picked)')
end

------------------------------------------------------------------
-- Template citation-specific (CITN) fields via citeSource, on a templated source
------------------------------------------------------------------

do
  local templated = sourceHelper.createSourceFromTemplate(civilRegId, { Reg_No = "1895/Q1/1" })
  local target = fhCreateItem("INDI")

  local returned = sourceHelper.citeSource(target, templated.id, { CitationField = "citation value" })
  local citationNode = currentNode(returned)
  local fieldChild = findChild(citationNode, "~TX-CitationField")
  check(fieldChild ~= nil and fieldChild.value == "citation value",
    'a template citation-specific (CITN) field code sets the metafield on the citation itself')

  -- Same field code must never land on the SOUR record too -- CITN fields are
  -- citation-level only (issue #98's own point, still true from the citing side).
  local templatedSourNode
  for _, n in ipairs(recordsByTag["SOUR"]) do
    if n.id == templated.id then templatedSourNode = n end
  end
  check(findChild(templatedSourNode, "~TX-CitationField") == nil,
    'the citation-specific field is not also created on the SOUR record')
end

------------------------------------------------------------------
-- Rejections: record-level template field via citeSource, untemplated source + template
-- field, reserved-name collision -- all validate-before-mutate.
------------------------------------------------------------------

do
  local templated = sourceHelper.createSourceFromTemplate(civilRegId, {})
  local target = fhCreateItem("INDI")
  local before = sourCountOnTarget(target)

  local okRecordLevel, errRecordLevel = pcall(sourceHelper.citeSource, target, templated.id, { Reg_No = "x" })
  check(not okRecordLevel, 'a record-level template field code passed to citeSource raises an error')
  check(contains(errRecordLevel, "Reg_No"), 'the error names the offending field code')
  check(contains(errRecordLevel, "record-level"), 'the error explains the field is record-level')
  check(sourCountOnTarget(target) == before, 'no citation created when a record-level field is rejected')

  local target2 = fhCreateItem("INDI")
  local okUntemplated, errUntemplated = pcall(sourceHelper.citeSource, target2, certSourceId, { CitationField = "x" })
  check(not okUntemplated, 'a template field code passed for an untemplated source raises an error')
  check(contains(errUntemplated, "template"), 'the error explains the source has no template')
  check(sourCountOnTarget(target2) == 0, 'no citation created when a template field is rejected on an untemplated source')
end

do
  -- A template that happens to define a citation-specific field literally coded "Page" --
  -- the reserved standard-field name always wins, so this must be a clear rejection, not
  -- a silent misroute of the caller's intent (issue #99 design decision).
  local collidingTemplate = buildTemplate("Colliding Template")
  addFieldDef(collidingTemplate, "Page", "Text", nil, true)
  local collidingSource = sourceHelper.createSourceFromTemplate(fhGetRecordId(collidingTemplate), {})
  local target = fhCreateItem("INDI")

  local okCollide, errCollide = pcall(sourceHelper.citeSource, target, collidingSource.id, { Page = "12" })
  check(not okCollide, 'a template field code colliding with a reserved standard-field name raises an error')
  check(contains(errCollide, "Page"), 'the collision error names the colliding field')
  check(sourCountOnTarget(target) == 0, 'no citation created when a reserved-name collision is rejected')
end

do
  -- A record-level (non-CITN) template field sharing a reserved name is NOT a real
  -- collision -- it was never reachable through citeSource's fields regardless of naming
  -- (citeSource only ever accepts CITN fields), so the reserved standard field just wins
  -- silently rather than being treated as an ambiguous conflict.
  local recordLevelCollidingTemplate = buildTemplate("Record-Level Colliding Template")
  addFieldDef(recordLevelCollidingTemplate, "Text", "Text", nil, false)
  local source = sourceHelper.createSourceFromTemplate(fhGetRecordId(recordLevelCollidingTemplate), {})
  local target = fhCreateItem("INDI")

  local returned = sourceHelper.citeSource(target, source.id, { Text = "citation text, not the record-level field" })
  local data = findChild(currentNode(returned), "DATA")
  local citationTextChild = data and findChild(data, "TEXT")
  check(citationTextChild ~= nil and citationTextChild.value.text == "citation text, not the record-level field",
    'a record-level template field sharing a reserved name does not block the standard field -- no collision, no error')
end

------------------------------------------------------------------
-- validateCiteSource with fields (issue #99): same pure-validation contract, extended.
------------------------------------------------------------------

do
  local target = fhCreateItem("INDI")
  local before = sourCountOnTarget(target)
  local validatedSourceF, standardFields = sourceHelper.validateCiteSource(target, certSourceId, { Page = "p. 1" })
  check(validatedSourceF ~= nil, 'validateCiteSource returns the resolved source on success, fields supplied')
  check(standardFields.Page == "p. 1", 'validateCiteSource returns the split standard-fields table')
  check(sourCountOnTarget(target) == before, 'validateCiteSource never creates a citation, even with fields supplied')
end

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

  local sourceA = makeSource(regIndex, "Birth", fhNewDate(1895, 3, 12))
  local sourceAId = fhGetRecordId(sourceA)
  local sourceB = makeSource(regIndex, "Marriage", fhNewDate(1900, 1, 1))
  local sourceBId = fhGetRecordId(sourceB)

  -- A source linked to a different template entirely -- must never appear in
  -- findSources("Test Registration Index", ...) results, however loose the filters.
  local offTemplateSource = makeSource(otherTemplate, "X", fhNewDate(2000, 1, 1))

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

  local okTablePtr, errTablePtr = pcall(sourceHelper.getPopulatedTemplateFields, { id = 1, qualifiedId = "S1" })
  check(not okTablePtr, 'getPopulatedTemplateFields raises on a wrong-shaped table too, rather than a raw Lua crash (issue #110)')
  check(contains(errTablePtr, "table"), 'the error names the type actually given')
end

------------------------------------------------------------------
-- getTemplateFieldCensus (issue #74, ADR 0017): occurrence counts for both record-level
-- and citation-level fields of one template -- the occurrence-counting half of what
-- describe_project's old sourceTemplateFields used to do (now structural-only there, see
-- server/src/describeProjectTool.ts), moved here as an opt-in helper. Reuses the same
-- record/citation resolution machinery findSources above already exercises.
------------------------------------------------------------------

do
  resetTree()

  local regIndex = buildTemplate("Test Registration Index")
  addFieldDef(regIndex, "Type", "Enum", "Birth | Marriage")
  addFieldDef(regIndex, "RegDate", "Date")
  addFieldDef(regIndex, "District", "Text", nil, true)  -- citation-level (CITN)
  addFieldDef(regIndex, "Ref", "Text", nil, true)        -- citation-level (CITN)

  local noCitationTemplate = buildTemplate("No Citation Fields Template")
  addFieldDef(noCitationTemplate, "Solo", "Text")

  local sourceA = makeSource(regIndex, "Birth", fhNewDate(1895, 3, 12))
  local sourceB = makeSource(regIndex, "Marriage", nil)  -- RegDate left unpopulated

  -- A source linked to a different template entirely -- must never contribute to
  -- getTemplateFieldCensus("Test Registration Index") counts, however its own fields
  -- happen to be named/populated.
  local offTemplateSource = makeSource(noCitationTemplate, nil, nil)
  setField(offTemplateSource, "TX", "Solo", "should not count")

  local alice = fhCreateItem("INDI")
  local aliceBirt = fhCreateItem("BIRT", alice)
  citeWithFields(aliceBirt, sourceA, { District = "Barnstaple", Ref = "123" })

  local bob = fhCreateItem("INDI")
  citeWithFields(bob, sourceA, { District = "Exeter" })  -- Ref left unpopulated on this one

  local fam1 = fhCreateItem("FAM")
  citeWithFields(fam1, sourceB, { District = "London", Ref = "789" })  -- sourceB is also linked to regIndex

  local census = sourceHelper.getTemplateFieldCensus("Test Registration Index")

  check(census.recordFields.Type == 2, 'recordFields tallies both sources with Type populated')
  check(census.recordFields.RegDate == 1, 'recordFields tallies only the one source with RegDate actually populated (sourceB left it unset)')
  check(census.citationFields.District == 3, 'citationFields tallies every citation with District populated, across every source linked to the template (sourceA\'s two citations + sourceB\'s one)')
  check(census.citationFields.Ref == 2, 'citationFields tallies only citations with Ref actually populated (Bob\'s citation left it unset)')

  local censusById = sourceHelper.getTemplateFieldCensus(fhGetRecordId(regIndex))
  check(censusById.recordFields.Type == 2, 'getTemplateFieldCensus resolves by numeric template id too')

  local noCitationCensus = sourceHelper.getTemplateFieldCensus("No Citation Fields Template")
  check(noCitationCensus.recordFields.Solo == 1, 'a template with no citation-level fields still tallies its record-level fields')
  check(type(noCitationCensus.citationFields) == 'table' and next(noCitationCensus.citationFields) == nil,
    'citationFields is an empty table (not nil, not an error) for a template with no citation-level fields')

  local okBadTemplate = pcall(sourceHelper.getTemplateFieldCensus, "No Such Template")
  check(not okBadTemplate, 'an unresolvable template name raises an error, same as findSources/createSourceFromTemplate')
end

------------------------------------------------------------------
-- Write-result checks (issue #111, docs/adr/0028): a bOK=false/NULL-pointer failure from
-- fhSetValueAs*/fhCreateItem now raises via familyHelper.checkWrite/checkCreated instead
-- of being silently discarded, at every fhCreateItem/fhSetValueAs* call
-- createSourceFromTemplate and citeSource make. One create-failure + one write-failure
-- case per function is enough to prove the wiring -- checkWrite/checkCreated themselves
-- are unit-tested directly in familyHelper.test.lua.
------------------------------------------------------------------

do
  resetTree()
  local tpl = buildTemplate("Write-Check Template")
  local tplId = fhGetRecordId(tpl)

  forceNextCreateFailure = true
  local okSourCreate, errSourCreate = pcall(sourceHelper.createSourceFromTemplate, tplId, {})
  check(not okSourCreate, 'createSourceFromTemplate raises when fhCreateItem("SOUR") itself fails')
  check(contains(errSourCreate, "createSourceFromTemplate") and contains(errSourCreate, "SOUR record"),
    'the SOUR-create error names the function and what failed to create')

  forceNextWriteFailure = true
  local okLink, errLink = pcall(sourceHelper.createSourceFromTemplate, tplId, {})
  check(not okLink, 'createSourceFromTemplate raises when the _SRCT template link write fails')
  check(contains(errLink, "createSourceFromTemplate") and contains(errLink, "template"),
    'the link-write error names the function and what it was linking')
end

do
  resetTree()
  local tpl = buildTemplate("Cite Write-Check Template")
  local tplId = fhGetRecordId(tpl)
  local sourceRecord = sourceHelper.createSourceFromTemplate(tplId, {})
  local target = fhCreateItem("INDI")

  forceNextCreateFailure = true
  local okCiteCreate, errCiteCreate = pcall(sourceHelper.citeSource, target, sourceRecord.id)
  check(not okCiteCreate, 'citeSource raises when fhCreateItem("SOUR", ptrTarget) (the citation itself) fails')
  check(contains(errCiteCreate, "citeSource"), 'the citation-create error names the function')

  forceNextWriteFailure = true
  local okCiteLink, errCiteLink = pcall(sourceHelper.citeSource, target, sourceRecord.id)
  check(not okCiteLink, 'citeSource raises when linking the citation to its source fails')
  check(contains(errCiteLink, "citeSource") and contains(errCiteLink, "link"),
    'the citation-link error names the function and what it was linking')
end

t.report()
