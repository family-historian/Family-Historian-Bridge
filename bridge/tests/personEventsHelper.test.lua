-- Standalone tests for personEventsHelper.lua. Run with: lua bridge/tests/personEventsHelper.test.lua
-- No FH/socket dependency. personEventsHelper.getPersonEvents turns the item pointers that
-- fhIndGetFactList returns into plain entries, so this file fakes only what it touches: an
-- in-memory item tree (nodes with tag, children, parent, value, valueType, display) and
-- fhIndGetFactList, which returns whatever list a test sets and records the arguments it got.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new()
local check, contains = t.check, t.contains

local recordsByTag
local nextId

local function resetTree()
  recordsByTag = {}
  nextId = 1
end

local QUALIFIED_ID_PREFIX = { INDI = "I", FAM = "F", SOUR = "S", OBJE = "O", NOTE = "N" }

local PtrMethods = {}
PtrMethods.__index = PtrMethods

local function newPtr()
  return setmetatable({ node = nil, list = nil, index = nil }, PtrMethods)
end

local function ptrFor(node)
  local ptr = newPtr()
  ptr.node = node
  return ptr
end

function PtrMethods:IsNull() return self.node == nil end
function PtrMethods:IsNotNull() return self.node ~= nil end

function PtrMethods:MoveToRecordById(tag, id)
  for _, node in ipairs(recordsByTag[tag] or {}) do
    if node.id == id then self.node = node return end
  end
  self.node = nil
end

function PtrMethods:MoveTo(parentPtr, dataReference)
  local tag = dataReference:match("^~%.(.+)$")
  assert(tag, "fake MoveTo only supports '~.TAG' data references, got: " .. tostring(dataReference))
  self.node = nil
  self.list = (parentPtr.node and parentPtr.node.children) or {}
  for i, child in ipairs(self.list) do
    if child.tag == tag then self.index, self.node = i, child return end
  end
end

function PtrMethods:MoveToRecordItem(ptrRef)
  local node = ptrRef.node
  while node and node.parent do node = node.parent end
  self.node, self.list, self.index = node, nil, nil
end

function PtrMethods:MoveToParentItem(ptrRef)
  self.node = ptrRef.node and ptrRef.node.parent
  self.list, self.index = nil, nil
end

function PtrMethods:MoveToFirstChildItem(parentPtr)
  local children = (parentPtr.node and parentPtr.node.children) or {}
  self.list, self.index, self.node = children, 1, children[1]
end

function PtrMethods:MoveNext()
  if not self.list then self.node = nil return end
  self.index = self.index + 1
  self.node = self.list[self.index]
end

function PtrMethods:Clone()
  local copy = newPtr()
  copy.list, copy.index, copy.node = self.list, self.index, self.node
  return copy
end

fhNewItemPtr = newPtr
fhGetTag = function(ptr) return ptr.node and ptr.node.tag end
fhGetRecordId = function(ptr) return ptr.node and ptr.node.id end
fhGetQualifiedRecordId = function(ptr)
  local node = ptr.node
  if not node or not node.id then return "" end
  return (QUALIFIED_ID_PREFIX[node.tag] or "?") .. tostring(node.id)
end
fhGetValueAsLink = function(ptr)
  local node = ptr.node
  if not node or node.valueType ~= "link" then return newPtr() end
  return ptrFor(node.value)
end
fhGetValueType = function(ptr) return (ptr.node and ptr.node.valueType) or "" end
fhGetDisplayText = function(ptr)
  local node = ptr.node
  if not node then return "" end
  if node.display then return node.display end
  return type(node.value) == "string" and node.value or ""
end
fhGetValueAsText = function(ptr)
  local node = ptr.node
  return (node and type(node.value) == "string" and node.value) or ""
end
fhGetItemText = function(ptr, dataReference)
  local tag = dataReference:match("^~%.(.+)$")
  for _, child in ipairs((ptr.node and ptr.node.children) or {}) do
    if child.tag == tag then return child.value or "" end
  end
  return ""
end
fhGetValueAsRichText = function(ptr)
  return { GetPlainText = function() return (ptr.node and ptr.node.plainText) or "" end }
end

local factListResult = {}
local factListArgs
fhIndGetFactList = function(ptr, ...)
  factListArgs = { ptr = ptr, ... }
  return factListResult
end

local familyHelper = require('familyHelper')
local personEventsHelper = require('personEventsHelper')

------------------------------------------------------------------
-- Fixture helpers
------------------------------------------------------------------

local function newRecord(tag, display)
  local node = { tag = tag, id = nextId, children = {}, display = display }
  nextId = nextId + 1
  recordsByTag[tag] = recordsByTag[tag] or {}
  table.insert(recordsByTag[tag], node)
  return node
end

local function addChild(parent, tag, fields)
  local child = { tag = tag, children = {}, parent = parent }
  for k, v in pairs(fields or {}) do child[k] = v end
  table.insert(parent.children, child)
  return child
end

local function addText(parent, tag, value)
  return addChild(parent, tag, { valueType = "text", value = value })
end

local function addLink(parent, tag, target)
  return addChild(parent, tag, { valueType = "link", value = target })
end

local function newIndi(name)
  return newRecord("INDI", name)
end

local function newFamily(husb, wife, children, display)
  local fam = newRecord("FAM", display)
  if husb then addLink(fam, "HUSB", husb) addLink(husb, "FAMS", fam) end
  if wife then addLink(fam, "WIFE", wife) addLink(wife, "FAMS", fam) end
  for _, child in ipairs(children or {}) do
    addLink(fam, "CHIL", child) addLink(child, "FAMC", fam)
  end
  return fam
end

local function addFact(owner, tag, display, date, place)
  local fact = addChild(owner, tag, { display = display })
  if date then addText(fact, "DATE", date) end
  if place then addText(fact, "PLAC", place) end
  return fact
end

local function addWitness(fact, witness, role)
  local shar = addLink(fact, "_SHAR", witness)
  shar.display = "Witness: " .. witness.display
  if role then addText(shar, "ROLE", role) end
  return shar
end

local function addFlag(indi, flagTag)
  local flgs
  for _, child in ipairs(indi.children) do
    if child.tag == "_FLGS" then flgs = child end
  end
  if not flgs then flgs = addChild(indi, "_FLGS") end
  addChild(flgs, flagTag)
end

local function listOf(...)
  local out = {}
  for _, node in ipairs({ ... }) do table.insert(out, ptrFor(node)) end
  return out
end

local function byQualifiedId(entries, qualifiedId)
  for _, entry in ipairs(entries) do
    if entry.qualifiedId == qualifiedId then return entry end
  end
end

local function setVisibility(private, living)
  familyHelper.setPrivacySettings({ privateVisibility = private, livingVisibility = living })
end

------------------------------------------------------------------
-- Fixture: Anne (subject) m. Bob; Anne witnesses Carl's baptism as godparent and their
-- neighbour's will as beneficiary. Anne's own birth carries a note, a citation and media.
------------------------------------------------------------------

resetTree()
setVisibility("all", "all")

local anne = newIndi("Anne ADAMS")
local bob = newIndi("Bob ADAMS")
local carl = newIndi("Carl CLARK")
local dora = newIndi("Dora DAVIS")
local marriage = newFamily(bob, anne, {}, "Bob ADAMS and Anne ADAMS")

local birth = addFact(anne, "BIRT", "Born 1 May 1900 in Leeds", "1 May 1900", "Leeds")
local factNote = addChild(birth, "NOTE2", { valueType = "richtext", plainText = "Born at home." })
local source = newRecord("SOUR", "Parish register")
local citation = addLink(birth, "SOUR", source)
addText(citation, "PAGE", "p. 12")
local media = newRecord("OBJE", "birth-certificate.jpg")
addLink(birth, "OBJE", media)

local marr = addFact(marriage, "MARR", "Married 3 June 1925", "3 June 1925", "York")
local baptism = addFact(carl, "CHR", "Baptised 5 July 1950", "5 July 1950", "Selby")
local godparent = addWitness(baptism, anne, "Godparent")
local participantNote = addChild(godparent, "NOTE2", { valueType = "richtext", plainText = "Stood for his cousin." })
local will = addFact(dora, "PROB", "Will proved 9 Sept 1960", "9 Sept 1960", "London")
local beneficiary = addWitness(will, anne, "Beneficiary")

------------------------------------------------------------------
-- Own and family facts
------------------------------------------------------------------

factListResult = listOf(birth, marr)
local events = personEventsHelper.getPersonEvents(ptrFor(anne))

check(#events == 2, 'one entry per fact fhIndGetFactList returns')
check(events[1].involvement == "own", 'a Fact on the person\'s own record is tagged own')
check(events[1].tag == "BIRT" and events[1].text == "Born 1 May 1900 in Leeds", 'an entry carries the fact tag and display text')
check(events[1].date == "1 May 1900" and events[1].place == "Leeds", 'an entry carries the date and place')
check(events[1].owner == "I" .. anne.id, 'an own entry names the owning record')
check(events[2].involvement == "family", 'a Fact on a Family the person is a spouse of is tagged family')
check(events[2].owner == "F" .. marriage.id, 'a family entry names the Family record')
check(events[2].principals[1].qualifiedId == "I" .. bob.id and events[2].principals[2].qualifiedId == "I" .. anne.id,
  'a family fact lists both spouses as principals')
check(events[1].principals[1].qualifiedId == "I" .. anne.id and #events[1].principals == 1,
  'an own fact lists the owner as the one principal')
check(events[1].role == nil, 'an own entry has no role')
check(events[1].notes[1].text == "Born at home.", 'an entry carries the fact\'s note text')
check(events[1].citations[1].qualifiedId == "S" .. source.id and events[1].citations[1].title == "Parish register"
  and events[1].citations[1].page == "p. 12", 'an entry carries each citation\'s source id, title and page')
check(events[1].media[1].qualifiedId == "O" .. media.id and events[1].media[1].name == "birth-certificate.jpg",
  'an entry carries each attached media item\'s id and name')
check(#events[2].notes == 0 and #events[2].citations == 0 and #events[2].media == 0,
  'a fact with no notes, citations or media gets empty lists, not nil')

local byQualified = personEventsHelper.getPersonEvents("I" .. anne.id)
check(#byQualified == 2, 'a qualified id string is accepted for the person')

------------------------------------------------------------------
-- Witness entries
------------------------------------------------------------------

factListResult = listOf(birth, godparent, beneficiary)
events = personEventsHelper.getPersonEvents(ptrFor(anne))

check(#events == 3, 'witness links come back as entries too')
check(events[2].involvement == "witness" and events[2].role == "Godparent", 'a witness entry is tagged witness with its ROLE text')
check(events[2].tag == "CHR" and events[2].text == "Baptised 5 July 1950", 'a witness entry describes the witnessed fact, not the link')
check(events[2].owner == "I" .. carl.id, 'a witness entry names the record that owns the fact')
check(events[2].principals[1].qualifiedId == "I" .. carl.id, 'a witness entry lists the fact\'s principal')
check(events[2].participantNotes[1].text == "Stood for his cousin.", 'a witness entry carries the participant\'s own note')
check(events[3].role == "Beneficiary", 'each witness link keeps its own role')
check(events[1].participantNotes == nil, 'an own entry has no participant notes')

local noRole = addWitness(will, anne, nil)
factListResult = listOf(noRole)
check(personEventsHelper.getPersonEvents(ptrFor(anne))[1].role == "", 'a witness link without ROLE reports an empty role')

------------------------------------------------------------------
-- Timeline facts and the options passed to fhIndGetFactList
------------------------------------------------------------------

local parentFam = newFamily(newIndi("Father ADAMS"), newIndi("Mother ADAMS"), { anne })
local parentsMarriage = addFact(parentFam, "MARR", "Parents married 1890", "1890", nil)
factListResult = listOf(parentsMarriage)
events = personEventsHelper.getPersonEvents(ptrFor(anne), { timeline = true })
check(events[1].involvement == "timeline", 'a fact on a Family the person is only a child of is tagged timeline')

personEventsHelper.getPersonEvents(ptrFor(anne))
check(factListArgs.ptr.node == anne, 'fhIndGetFactList is called on the person')
check(factListArgs[1] == true and factListArgs[2] == false and factListArgs[3] == false and factListArgs[4] == false
  and factListArgs[5] == false and factListArgs[6] == false and factListArgs[7] == true,
  'defaults: witnesses on, timeline off, rejected excluded, everything else off')

personEventsHelper.getPersonEvents(ptrFor(anne), {
  witness = false, timeline = true, timelinePrefsOnly = true, narrative = true,
  resolveExclusions = true, excludePrivate = true, excludeRejected = false,
})
check(factListArgs[1] == false and factListArgs[2] == true and factListArgs[3] == true and factListArgs[4] == true
  and factListArgs[5] == true and factListArgs[6] == true and factListArgs[7] == false,
  'each option maps to its fhIndGetFactList flag')

local okOpt, errOpt = pcall(personEventsHelper.getPersonEvents, ptrFor(anne), { witnesses = true })
check(not okOpt and contains(errOpt, "witnesses") and contains(errOpt, "witness"), 'an unknown option raises, naming it and the valid ones')

local okType, errType = pcall(personEventsHelper.getPersonEvents, ptrFor(anne), { timeline = "yes" })
check(not okType and contains(errType, "timeline"), 'a non-boolean option raises, naming it')

------------------------------------------------------------------
-- Input errors
------------------------------------------------------------------

check(not pcall(personEventsHelper.getPersonEvents, nil), 'a nil person raises')
local okFam, errFam = pcall(personEventsHelper.getPersonEvents, ptrFor(marriage))
check(not okFam and contains(errFam, "Individual"), 'a non-Individual record raises, naming Individual')

------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------

factListResult = listOf(birth, godparent)

addFlag(anne, "__LIVING")
setVisibility("all", "exclude")
local okEx, errEx = pcall(personEventsHelper.getPersonEvents, ptrFor(anne))
check(not okEx and contains(errEx, "Excluded"), 'an Excluded subject raises, naming Excluded')

setVisibility("all", "nameOnly")
check(#personEventsHelper.getPersonEvents(ptrFor(anne)) == 0, 'a Name Only subject has no events, as getFactsByTag')
anne.children[#anne.children] = nil
setVisibility("all", "all")

-- An Excluded owner hides the witnessed fact entirely.
addFlag(carl, "__LIVING")
setVisibility("all", "exclude")
events = personEventsHelper.getPersonEvents(ptrFor(anne))
check(#events == 1 and events[1].tag == "BIRT", 'a witnessed fact owned by an Excluded person is hidden entirely')

-- A Name Only owner: the entry survives with names only and no fact detail.
setVisibility("all", "nameOnly")
events = personEventsHelper.getPersonEvents(ptrFor(anne))
check(#events == 2, 'a witnessed fact owned by a Name Only person still gets an entry')
check(events[2].involvement == "witness" and events[2].role == "Godparent", 'the Name Only owner\'s entry keeps involvement and role')
check(events[2].tag == nil and events[2].text == nil and events[2].date == nil and events[2].place == nil
  and events[2].notes == nil and events[2].citations == nil and events[2].media == nil
  and events[2].participantNotes == nil, 'the Name Only owner\'s entry carries no fact detail')
check(events[2].principals[1].qualifiedId == "I" .. carl.id and events[2].principals[1].text == "Carl CLARK",
  'the Name Only owner is shown by name only')
setVisibility("all", "all")
carl.children[#carl.children] = nil

-- An Excluded spouse hides the family fact they are a principal of.
addFlag(bob, "__PRIVATE")
setVisibility("exclude", "all")
factListResult = listOf(birth, marr)
events = personEventsHelper.getPersonEvents(ptrFor(anne))
check(#events == 1 and events[1].tag == "BIRT", 'a family fact with an Excluded principal is hidden entirely')
setVisibility("all", "all")

t.report()
