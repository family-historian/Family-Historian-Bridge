-- Standalone tests for familyHelper.lua. Run with: lua bridge/tests/familyHelper.test.lua
-- No FH/socket dependency. Like sourceHelper.test.lua, familyHelper.lua genuinely walks a
-- record/child-item tree (MoveToFirstRecord, MoveTo with a "~.TAG" data reference,
-- MoveNext/MoveNext("SAME_TAG"), MoveToFirstChildItem), so this file builds a small
-- in-memory fake item-pointer double, scoped narrowly to only the methods/globals
-- familyHelper.lua actually calls: item-pointer methods MoveToFirstRecord/MoveTo/
-- MoveNext/MoveToFirstChildItem/IsNotNull/IsNull, plus globals fhNewItemPtr/fhGetTag/
-- fhGetItemText/fhGetRecordId/fhGetQualifiedRecordId/fhGetValueAsLink/fhGetDisplayText/
-- fhGetValueType/fhGetValueAsRichText/fhGetDataClass/fhGetValueAsText/fhHasChildItem/
-- fhIndGetName.
--
-- Unlike sourceHelper.test.lua's fake tree (single-tag child lists only), this module
-- walks records whose children mix several different tags as siblings (a FAM record's
-- HUSB/WIFE/CHIL, an INDI's NAME/SEX/BIRT/FAMC/FAMS, a BIRT's DATE/PLAC), so the fake
-- MoveNext must actually honor "SAME_TAG" vs the default "ANY", not just advance an index.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'

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
-- Fake tree: records grouped by tag, each node a plain table:
-- { tag, id (records only), children = {}, valueType (fields with a value only),
--   value (text/date/link-target-node/etc, per valueType), display (optional
--   fhGetDisplayText override), name (INDI display name, for fhIndGetName) }.
------------------------------------------------------------------

local recordsByTag
local nextId

local function resetTree()
  recordsByTag = {}
  nextId = 1
end

local QUALIFIED_ID_PREFIX = { INDI = "I", FAM = "F" }

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

function PtrMethods:IsNull()
  return self.node == nil
end

function PtrMethods:IsNotNull()
  return self.node ~= nil
end

function PtrMethods:MoveToFirstRecord(tag)
  self.list = recordsByTag[tag] or {}
  self.index = 1
  self.node = self.list[1]
end

-- "~.TAG" is the only Data Reference shape familyHelper.lua ever passes to MoveTo (see
-- its own eachFamilyLink/eachFamilyMember comments) -- finds the FIRST matching-tag
-- child of parentPtr, same as the real MoveTo(ptrParent, "~.TAG").
function PtrMethods:MoveTo(parentPtr, dataReference)
  local tag = dataReference:match("^~%.(.+)$")
  assert(tag, "fake MoveTo only supports '~.TAG' data references, got: " .. tostring(dataReference))
  local children = (parentPtr.node and parentPtr.node.children) or {}
  self.list = children
  for i, child in ipairs(children) do
    if child.tag == tag then
      self.index = i
      self.node = child
      return
    end
  end
  self.index = #children + 1
  self.node = nil
end

-- Scans recordsByTag[tag] for a node with a matching id -- a linear scan is fine for
-- fixture-sized fake trees; real FH presumably indexes this.
function PtrMethods:MoveToRecordById(tag, id)
  local list = recordsByTag[tag] or {}
  for i, node in ipairs(list) do
    if node.id == id then
      self.list = list
      self.index = i
      self.node = node
      return
    end
  end
  self.list = list
  self.index = #list + 1
  self.node = nil
end

function PtrMethods:MoveToFirstChildItem(parentPtr)
  local children = (parentPtr.node and parentPtr.node.children) or {}
  self.list = children
  self.index = 1
  self.node = children[1]
end

-- strTag: nil/"ANY" moves to the next sibling regardless of tag; "SAME_TAG" moves to
-- the next sibling whose tag matches the CURRENT node's tag (real MoveNext semantics,
-- MoveNext.htm) -- the distinction familyHelper.lua actually depends on to walk mixed-
-- tag children (describeItem) vs. same-tag-only link lists (eachFamilyLink/Member).
function PtrMethods:MoveNext(strTag)
  if not self.list then
    self.node = nil
    return
  end
  local matchTag = nil
  if strTag == "SAME_TAG" then
    matchTag = self.node and self.node.tag
  end
  local i = self.index + 1
  while self.list[i] do
    if not matchTag or self.list[i].tag == matchTag then
      self.index = i
      self.node = self.list[i]
      return
    end
    i = i + 1
  end
  self.index = i
  self.node = nil
end

fhNewItemPtr = newPtr

fhGetTag = function(ptr)
  return ptr.node and ptr.node.tag
end

fhGetRecordId = function(ptr)
  return ptr.node and ptr.node.id
end

fhGetQualifiedRecordId = function(ptr)
  local node = ptr.node
  if not node or not node.id then return "" end
  return (QUALIFIED_ID_PREFIX[node.tag] or "?") .. tostring(node.id)
end

fhGetValueAsLink = function(ptr)
  local node = ptr.node
  if not node or not node.value then return newPtr() end
  return ptrFor(node.value)
end

fhGetValueType = function(ptr)
  return (ptr.node and ptr.node.valueType) or ""
end

fhHasChildItem = function(ptr)
  return ptr.node ~= nil and #ptr.node.children > 0
end

fhIndGetName = function(ptr)
  return (ptr.node and ptr.node.name) or ""
end

-- Scoped to how familyHelper.lua actually calls it: fhGetItemText(ptr, "~.SEX")
-- (indiDescriptor), plus searchByName's "~.NAME:GIVEN_ALL"/"~.NAME:SURNAME" qualified
-- reads -- the fake NAME fixture stores a { given, surname } pair directly on the
-- NAME child (see newIndi below) rather than actually splitting a full-name string
-- the way FH's own qualifier resolution would, since reimplementing FH's own name-
-- parsing isn't this fake's job.
fhGetItemText = function(ptr, dataReference)
  local node = ptr.node
  if not node then return "" end
  local tag, qualifier = dataReference:match("^~%.([%w]+):?([%w_]*)$")
  if not tag then return "" end
  for _, child in ipairs(node.children) do
    if child.tag == tag then
      if qualifier == "GIVEN_ALL" then return child.given or "" end
      if qualifier == "SURNAME" then return child.surname or "" end
      return child.value or ""
    end
  end
  return ""
end

-- Scoped to how familyHelper.lua actually calls it: fhGetDisplayText(target) (bare,
-- linkDescriptor) and fhGetDisplayText(ptr, "~", "min") (describeItem) -- both mean
-- "the display text for this node itself", so dataReference/displayOption are ignored
-- here rather than reimplemented.
fhGetDisplayText = function(ptr, dataReference, displayOption)
  local node = ptr.node
  if not node then return "" end
  if node.display then return node.display end
  if type(node.value) == 'string' then return node.value end
  return ""
end

fhGetValueAsRichText = function(ptr)
  local node = ptr.node
  return {
    GetPlainText = function() return (node and node.plainText) or "" end,
  }
end

-- dataClass is a separate axis from valueType (see familyHelper.lua's describeItem
-- comment) -- a longtext-class field's own valueType is still plain "text", so tests
-- for the longtext branch set both explicitly on the fixture node.
fhGetDataClass = function(ptr)
  return (ptr.node and ptr.node.dataClass) or ""
end

-- fullText stands in for the untruncated value fhGetValueAsText would return, kept
-- distinct from .value (what fhGetDisplayText's fake reads) so a longtext test can
-- prove describeItem actually took this branch rather than the fhGetDisplayText one.
fhGetValueAsText = function(ptr)
  local node = ptr.node
  return (node and (node.fullText or node.value)) or ""
end

-- getDescendants' dnaLine filter calls fhCallBuiltInFunction(dnaBuiltin, indiPtr, p) --
-- deliberately NOT re-implemented as a real Y-chrom/mtDNA propagation rule here (that's
-- FH's own job, not this fake's); this double just logs every call it receives (so tests
-- can assert the right builtin name and the right two pointers were passed) and returns
-- a fixed, simple "matches" rule (Dad Plugin and Self Plugin only) that's just enough to
-- prove getDescendants actually filters its results by the call's return value.
local dnaCallLog = {}
fhCallBuiltInFunction = function(strFunctionName, ptrA, ptrB)
  table.insert(dnaCallLog, { fn = strFunctionName, a = ptrA.node, b = ptrB.node })
  return ptrB.node.name == "Dad Plugin" or ptrB.node.name == "Self Plugin"
end

-- fhNewDate fake, scoped only for resolveDate's own tests below -- not a real date-parsing
-- engine. Real FH's fhNewDate returns a Date OBJECT (userdata), a genuinely different Lua
-- type from a plain table -- exactly what lets resolveDate's own type(value) == "table"
-- check tell "already a Date object" apart from "the {year=,month=,day=} shorthand table"
-- (same reasoning, and the same coroutine-as-userdata-stand-in fake, sourceHelper.test.lua
-- already uses for the same distinction, issue #99). debug.setmetatable on a thread sets
-- ONE shared metatable for every coroutine in this process (confirmed: Lua only supports a
-- per-type, not per-value, metatable for threads) -- set once here, so every fhNewDate(...)
-- call below gets dt:SetValueAsText(...) support without touching type(dt) at all.
-- SetValueAsText succeeds only for a bare 4-digit-year string (e.g. "1901"), matching
-- resolveDate's own bAllowPhrase=false call -- anything else fails, just enough to exercise
-- resolveDate's success/failure branches without modeling FH's real date grammar. Fields
-- live in a side table keyed weakly by the coroutine, since a thread can't carry its own
-- named fields directly.
local dateObjFields = setmetatable({}, { __mode = 'k' })
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
fhNewDate = function(year, month, day, subtype)
  local co = coroutine.create(function() end)
  dateObjFields[co] = { year = year, month = month, day = day, subtype = subtype }
  return co
end

local familyHelper = require('familyHelper')

------------------------------------------------------------------
-- Fixture helpers
------------------------------------------------------------------

local function newRecord(tag)
  local node = { tag = tag, id = nextId, children = {} }
  nextId = nextId + 1
  recordsByTag[tag] = recordsByTag[tag] or {}
  table.insert(recordsByTag[tag], node)
  return node
end

local function addTextChild(parent, tag, value)
  local child = { tag = tag, children = {}, valueType = "text", value = value }
  table.insert(parent.children, child)
  return child
end

local function addLinkChild(parent, tag, targetNode)
  local child = { tag = tag, children = {}, valueType = "link", value = targetNode }
  table.insert(parent.children, child)
  return child
end

-- given/surname are optional overrides for the fake NAME:GIVEN_ALL/NAME:SURNAME
-- qualifier reads searchByName relies on -- when omitted, derived from name by
-- splitting off the last space-separated word as the surname (a fixture-only
-- heuristic; real FH qualifier resolution is exercised by search_gedcom_knowledge's
-- "name qualifiers" reference, not re-implemented here).
local function newIndi(name, sex, given, surname)
  local indi = newRecord("INDI")
  indi.name = name
  indi.display = name
  local nameChild = addTextChild(indi, "NAME", name)
  local derivedGiven, derivedSurname = name:match("^(.-)%s+(%S+)$")
  nameChild.given = given or derivedGiven or name
  nameChild.surname = surname or derivedSurname or ""
  addTextChild(indi, "SEX", sex)
  return indi
end

local function newFamily(husb, wife, children)
  local fam = newRecord("FAM")
  if husb then
    addLinkChild(fam, "HUSB", husb)
    addLinkChild(husb, "FAMS", fam)
  end
  if wife then
    addLinkChild(fam, "WIFE", wife)
    addLinkChild(wife, "FAMS", fam)
  end
  for _, child in ipairs(children or {}) do
    addLinkChild(fam, "CHIL", child)
    addLinkChild(child, "FAMC", fam)
  end
  return fam
end

------------------------------------------------------------------
-- Fixtures: a 3-generation tree.
--   Grandpa + Grandma -> Dad, Aunt   (FAM1)
--   Dad + Mom -> Self, Sibling        (FAM2)
--   Self + Spouse                     (FAM3)
------------------------------------------------------------------

resetTree()

local grandpa = newIndi("Grandpa Plugin", "Male")
local grandma = newIndi("Grandma Plugin", "Female")
local dad = newIndi("Dad Plugin", "Male")
local aunt = newIndi("Aunt Plugin", "Female")
newFamily(grandpa, grandma, { dad, aunt })

local mom = newIndi("Mom Plugin", "Female")
local self_ = newIndi("Self Plugin", "Male")
local sibling = newIndi("Sibling Plugin", "Female")
newFamily(dad, mom, { self_, sibling })

local spouse = newIndi("Spouse Plugin", "Female")
newFamily(self_, spouse, {})

------------------------------------------------------------------
-- getFamilyGroup: parents
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local parents = familyHelper.getFamilyGroup(selfPtr, "parents")
  check(#parents == 2, 'getFamilyGroup(self, "parents") returns 2 entries')

  local byRelationship = {}
  for _, entry in ipairs(parents) do byRelationship[entry.relationship] = entry end

  check(byRelationship.father ~= nil and byRelationship.father.individual.name == "Dad Plugin", 'father entry identifies Dad')
  check(byRelationship.mother ~= nil and byRelationship.mother.individual.name == "Mom Plugin", 'mother entry identifies Mom')
  check(byRelationship.father.individual.id == dad.id, 'father entry carries the right record id')
  check(byRelationship.father.individual.qualifiedId == "I" .. dad.id, 'father entry carries a qualified id')
  check(byRelationship.father.family.id == byRelationship.mother.family.id, 'father and mother entries point at the same FAMC record')
end

------------------------------------------------------------------
-- getFamilyGroup: siblings (excludes self)
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local siblings = familyHelper.getFamilyGroup(selfPtr, "siblings")
  check(#siblings == 1, 'getFamilyGroup(self, "siblings") returns exactly 1 entry (excludes self)')
  check(siblings[1].relationship == "sibling", 'sibling entry has relationship "sibling"')
  check(siblings[1].individual.name == "Sibling Plugin", 'sibling entry identifies the right person')
end

------------------------------------------------------------------
-- getFamilyGroup: spouses
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local spouses = familyHelper.getFamilyGroup(selfPtr, "spouses")
  check(#spouses == 1, 'getFamilyGroup(self, "spouses") returns exactly 1 entry')
  check(spouses[1].relationship == "spouse", 'spouse entry has relationship "spouse"')
  check(spouses[1].individual.name == "Spouse Plugin", 'spouse entry identifies the right person')
end

------------------------------------------------------------------
-- getFamilyGroup: all (union), default type
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local all = familyHelper.getFamilyGroup(selfPtr, "all")
  check(#all == 4, 'getFamilyGroup(self, "all") returns parents + siblings + spouses (2 + 1 + 1)')

  local allDefault = familyHelper.getFamilyGroup(selfPtr)
  check(#allDefault == 4, 'getFamilyGroup(self) with no type defaults to "all"')
end

------------------------------------------------------------------
-- getFamilyGroup: errors
------------------------------------------------------------------

do
  local ok, err = pcall(familyHelper.getFamilyGroup, ptrFor(self_), "cousins")
  check(not ok, 'an invalid type raises an error')
  check(contains(err, "cousins"), 'the error names the invalid type given')

  local okNull, errNull = pcall(familyHelper.getFamilyGroup, newPtr(), "parents")
  check(not okNull, 'a null pointer raises an error')
  check(contains(errNull, "getFamilyGroup"), 'the null-pointer error names the function')
end

------------------------------------------------------------------
-- getAncestors: unbounded, with pedigree lines and generations
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local ancestors = familyHelper.getAncestors(selfPtr)
  check(#ancestors == 4, 'getAncestors(self) returns 2 parents + 2 grandparents (Mom\'s side has no recorded FAMC)')

  local byName = {}
  for _, entry in ipairs(ancestors) do byName[entry.individual.name] = entry end

  check(byName["Dad Plugin"] ~= nil and byName["Dad Plugin"].generation == 1, 'Dad is generation 1')
  check(byName["Mom Plugin"] ~= nil and byName["Mom Plugin"].generation == 1, 'Mom is generation 1')
  check(byName["Grandpa Plugin"] ~= nil and byName["Grandpa Plugin"].generation == 2, 'Grandpa is generation 2')
  check(byName["Grandma Plugin"] ~= nil and byName["Grandma Plugin"].generation == 2, 'Grandma is generation 2')

  check(#byName["Grandpa Plugin"].line == 2 and byName["Grandpa Plugin"].line[1] == "father" and byName["Grandpa Plugin"].line[2] == "father",
    'Grandpa\'s line is {"father", "father"} (paternal grandfather)')
  check(#byName["Grandma Plugin"].line == 2 and byName["Grandma Plugin"].line[1] == "father" and byName["Grandma Plugin"].line[2] == "mother",
    'Grandma\'s line is {"father", "mother"} (paternal grandmother)')
  check(#byName["Dad Plugin"].line == 1 and byName["Dad Plugin"].line[1] == "father", 'Dad\'s line is {"father"}')
end

------------------------------------------------------------------
-- getAncestors: maxGenerations caps the walk
------------------------------------------------------------------

do
  local selfPtr = ptrFor(self_)
  local oneGen = familyHelper.getAncestors(selfPtr, 1)
  check(#oneGen == 2, 'getAncestors(self, 1) stops after generation 1 (just parents)')
  for _, entry in ipairs(oneGen) do
    check(entry.generation == 1, 'every entry with maxGenerations=1 is generation 1')
  end
end

------------------------------------------------------------------
-- getAncestors: an individual with no recorded parents returns an empty table
------------------------------------------------------------------

do
  local loner = newIndi("Loner Plugin", "Male")
  local ancestors = familyHelper.getAncestors(ptrFor(loner))
  check(type(ancestors) == 'table' and #ancestors == 0, 'getAncestors on someone with no FAMC returns an empty array')
end

------------------------------------------------------------------
-- getAncestors: errors on a null pointer
------------------------------------------------------------------

do
  local ok, err = pcall(familyHelper.getAncestors, newPtr())
  check(not ok, 'getAncestors on a null pointer raises an error')
  check(contains(err, "getAncestors"), 'the error names the function')
end

------------------------------------------------------------------
-- getAncestors: dnaLine filters results via fhCallBuiltInFunction (issue #78),
-- via the same DNA_LINE_BUILTIN map getDescendants uses -- now including "blood"
------------------------------------------------------------------

do
  dnaCallLog = {}
  local selfPtr = ptrFor(self_)
  local bloodLine = familyHelper.getAncestors(selfPtr, nil, "blood")
  check(#bloodLine == 1, 'dnaLine="blood" filters down to whatever fhCallBuiltInFunction says matches (the fake\'s fixed rule: Dad only, among self\'s 4 ancestors)')
  check(bloodLine[1].individual.name == "Dad Plugin", 'the one match is Dad, per the fake\'s rule')

  check(#dnaCallLog == 4, 'fhCallBuiltInFunction was called once per visited ancestor (all 4), not just the match')
  for _, call in ipairs(dnaCallLog) do
    check(call.fn == "DnaBloodRelation", 'dnaLine="blood" calls the DnaBloodRelation built-in')
    check(call.a == self_, 'the built-in\'s first argument is always the origin (self)')
  end

  dnaCallLog = {}
  familyHelper.getAncestors(selfPtr, nil, "y-chrom")
  check(#dnaCallLog == 4 and dnaCallLog[1].fn == "DnaShareYChrom", 'dnaLine="y-chrom" also works on getAncestors, via the same shared map')

  local okBad, errBad = pcall(familyHelper.getAncestors, selfPtr, nil, "x-chrom")
  check(not okBad, 'an invalid dnaLine raises an error')
  check(contains(errBad, "x-chrom"), 'the error names the invalid dnaLine given')
  check(contains(errBad, "blood"), 'the error message lists blood as a valid value')
end

------------------------------------------------------------------
-- getDescendants: unbounded, with lines and generations (mirror image of getAncestors)
------------------------------------------------------------------

do
  local grandpaPtr = ptrFor(grandpa)
  local descendants = familyHelper.getDescendants(grandpaPtr)
  check(#descendants == 4, 'getDescendants(grandpa) returns 2 children + 2 grandchildren (Aunt has no recorded FAMS)')

  local byName = {}
  for _, entry in ipairs(descendants) do byName[entry.individual.name] = entry end

  check(byName["Dad Plugin"] ~= nil and byName["Dad Plugin"].generation == 1, 'Dad is generation 1')
  check(byName["Aunt Plugin"] ~= nil and byName["Aunt Plugin"].generation == 1, 'Aunt is generation 1')
  check(byName["Self Plugin"] ~= nil and byName["Self Plugin"].generation == 2, 'Self is generation 2')
  check(byName["Sibling Plugin"] ~= nil and byName["Sibling Plugin"].generation == 2, 'Sibling is generation 2')

  check(#byName["Dad Plugin"].line == 1 and byName["Dad Plugin"].line[1] == "son", 'Dad\'s line is {"son"}')
  check(#byName["Aunt Plugin"].line == 1 and byName["Aunt Plugin"].line[1] == "daughter", 'Aunt\'s line is {"daughter"}')
  check(#byName["Self Plugin"].line == 2 and byName["Self Plugin"].line[1] == "son" and byName["Self Plugin"].line[2] == "son",
    'Self\'s line is {"son", "son"} (son\'s son)')
  check(#byName["Sibling Plugin"].line == 2 and byName["Sibling Plugin"].line[1] == "son" and byName["Sibling Plugin"].line[2] == "daughter",
    'Sibling\'s line is {"son", "daughter"} (son\'s daughter)')
end

------------------------------------------------------------------
-- getDescendants: maxGenerations caps the walk
------------------------------------------------------------------

do
  local grandpaPtr = ptrFor(grandpa)
  local oneGen = familyHelper.getDescendants(grandpaPtr, 1)
  check(#oneGen == 2, 'getDescendants(grandpa, 1) stops after generation 1 (just children)')
  for _, entry in ipairs(oneGen) do
    check(entry.generation == 1, 'every entry with maxGenerations=1 is generation 1')
  end
end

------------------------------------------------------------------
-- getDescendants: an individual with no recorded FAMS returns an empty table
------------------------------------------------------------------

do
  local childless = newIndi("Childless Plugin", "Female")
  local descendants = familyHelper.getDescendants(ptrFor(childless))
  check(type(descendants) == 'table' and #descendants == 0, 'getDescendants on someone with no FAMS returns an empty array')
end

------------------------------------------------------------------
-- getDescendants: errors on a null pointer, or a non-Individual pointer
------------------------------------------------------------------

do
  local ok, err = pcall(familyHelper.getDescendants, newPtr())
  check(not ok, 'getDescendants on a null pointer raises an error')
  check(contains(err, "getDescendants"), 'the error names the function')
end

------------------------------------------------------------------
-- getDescendants: dnaLine filters results via fhCallBuiltInFunction, doesn't
-- reimplement Y-chrom/mtDNA propagation itself
------------------------------------------------------------------

do
  dnaCallLog = {}
  local grandpaPtr = ptrFor(grandpa)
  local yLine = familyHelper.getDescendants(grandpaPtr, nil, "y-chrom")
  check(#yLine == 2, 'dnaLine="y-chrom" filters down to whatever fhCallBuiltInFunction says matches (the fake\'s fixed rule: Dad + Self)')
  local yByName = {}
  for _, entry in ipairs(yLine) do yByName[entry.individual.name] = true end
  check(yByName["Dad Plugin"] and yByName["Self Plugin"], 'the two matches are Dad and Self, per the fake\'s rule')

  check(#dnaCallLog == 4, 'fhCallBuiltInFunction was called once per visited descendant (all 4), not just the matches')
  for _, call in ipairs(dnaCallLog) do
    check(call.fn == "DnaShareYChrom", 'dnaLine="y-chrom" calls the DnaShareYChrom built-in')
    check(call.a == grandpa, 'the built-in\'s first argument is always the origin (grandpa)')
  end

  dnaCallLog = {}
  familyHelper.getDescendants(grandpaPtr, nil, "mtdna")
  check(#dnaCallLog == 4 and dnaCallLog[1].fn == "DnaShareMtDna", 'dnaLine="mtdna" calls the DnaShareMtDna built-in instead')

  dnaCallLog = {}
  local bloodLine = familyHelper.getDescendants(grandpaPtr, nil, "blood")
  check(#dnaCallLog == 4 and dnaCallLog[1].fn == "DnaBloodRelation", 'dnaLine="blood" (issue #78) calls the DnaBloodRelation built-in instead')
  local bloodByName = {}
  for _, entry in ipairs(bloodLine) do bloodByName[entry.individual.name] = true end
  check(#bloodLine == 2 and bloodByName["Dad Plugin"] and bloodByName["Self Plugin"], 'dnaLine="blood" filters down to whatever fhCallBuiltInFunction says matches (the fake\'s fixed rule: Dad + Self)')

  local okBad, errBad = pcall(familyHelper.getDescendants, grandpaPtr, nil, "x-chrom")
  check(not okBad, 'an invalid dnaLine raises an error')
  check(contains(errBad, "x-chrom"), 'the error names the invalid dnaLine given')
  check(contains(errBad, "blood"), 'the error message lists blood as a valid value')
end

------------------------------------------------------------------
-- getAllDetails: leaf text fields, a link field, and a nested complex fact
------------------------------------------------------------------

do
  local indi = newIndi("Detail Plugin", "Male")
  local birt = { tag = "BIRT", children = {}, valueType = "" }
  table.insert(indi.children, birt)
  addTextChild(birt, "DATE", "12 MAR 1970")
  addTextChild(birt, "PLAC", "Someplace")

  local famsTarget = newRecord("FAM")
  addLinkChild(indi, "FAMS", famsTarget)

  local details = familyHelper.getAllDetails(ptrFor(indi))

  check(details.tag == "INDI", 'top-level node tag is INDI')
  check(details.id == indi.id and details.qualifiedId == "I" .. indi.id, 'top-level node carries id/qualifiedId (it is a record)')
  check(details.value == nil, 'top-level record node has no .value (fhGetValueType is empty for records)')
  check(type(details.children) == 'table' and #details.children > 0, 'top-level node has children')

  local function findChild(node, tag)
    for _, child in ipairs(node.children) do
      if child.tag == tag then return child end
    end
    return nil
  end

  local nameNode = findChild(details, "NAME")
  check(nameNode ~= nil and nameNode.value == "Detail Plugin", 'NAME child has the right .value')
  check(nameNode.id == nil, 'a non-record child has no id/qualifiedId')

  local birtNode = findChild(details, "BIRT")
  check(birtNode ~= nil and birtNode.value == nil, 'BIRT (a complex/event item) has no .value of its own')
  check(findChild(birtNode, "DATE").value == "12 MAR 1970", 'BIRT.DATE child recurses correctly')
  check(findChild(birtNode, "PLAC").value == "Someplace", 'BIRT.PLAC child recurses correctly')

  local famsNode = findChild(details, "FAMS")
  check(famsNode ~= nil, 'FAMS link child is present')
  check(famsNode.link ~= nil and famsNode.link.tag == "FAM" and famsNode.link.id == famsTarget.id,
    'FAMS child carries a link descriptor identifying the target FAM record')
  check(famsNode.children == nil, 'getAllDetails does not recurse into a link\'s target record (would walk back out of this record)')
end

------------------------------------------------------------------
-- getAllDetails: richtext goes through GetPlainText, not the raw value
------------------------------------------------------------------

do
  local indi = newIndi("Notes Plugin", "Female")
  local note = { tag = "NOTE2", children = {}, valueType = "richtext", plainText = "Plain prose, no markup." }
  table.insert(indi.children, note)

  local details = familyHelper.getAllDetails(ptrFor(indi))
  local noteNode
  for _, child in ipairs(details.children) do
    if child.tag == "NOTE2" then noteNode = child end
  end
  check(noteNode ~= nil and noteNode.value == "Plain prose, no markup.", 'richtext field value comes from GetPlainText(), not raw fhGetDisplayText')
end

------------------------------------------------------------------
-- getAllDetails: longtext (a dataClass, not a valueType -- longtext's own valueType
-- is plain "text", same as an ordinary single-line field) goes through
-- fhGetValueAsText, not fhGetDisplayText's short list-representation (issue #70)
------------------------------------------------------------------

do
  local indi = newIndi("Longtext Plugin", "Male")
  local note = {
    tag = "NOTE2",
    children = {},
    valueType = "text",
    dataClass = "longtext",
    value = "Short display form",
    fullText = "Short display form plus a great deal more text that fhGetDisplayText's "
      .. "short list-representation would have left off entirely.",
  }
  table.insert(indi.children, note)

  local details = familyHelper.getAllDetails(ptrFor(indi))
  local noteNode
  for _, child in ipairs(details.children) do
    if child.tag == "NOTE2" then noteNode = child end
  end
  check(noteNode ~= nil and noteNode.value == note.fullText,
    'longtext field value comes from fhGetValueAsText(), not fhGetDisplayText\'s short form')
  check(noteNode.value ~= note.value,
    'longtext value differs from fhGetDisplayText\'s short-form value in this fixture (proves the branch was actually taken, not a fixture coincidence)')
end

------------------------------------------------------------------
-- getAllDetails: a plain single-line text field (dataClass "text") still goes
-- through fhGetDisplayText -- the longtext branch must not swallow every text-typed
-- field, only ones fhGetDataClass actually reports as "longtext"
------------------------------------------------------------------

do
  local indi = newIndi("PlainText Plugin", "Male")
  local occ = { tag = "OCCU", children = {}, valueType = "text", dataClass = "text", value = "Farmer" }
  table.insert(indi.children, occ)

  local details = familyHelper.getAllDetails(ptrFor(indi))
  local occNode
  for _, child in ipairs(details.children) do
    if child.tag == "OCCU" then occNode = child end
  end
  check(occNode ~= nil and occNode.value == "Farmer",
    'a plain "text"-dataClass field still goes through fhGetDisplayText, unaffected by the longtext branch')
end

------------------------------------------------------------------
-- getAllDetails: works on a non-record item pointer too (any record pointer)
------------------------------------------------------------------

do
  local indi = newIndi("SubField Plugin", "Male")
  local nameChild = indi.children[1]
  local details = familyHelper.getAllDetails(ptrFor(nameChild))
  check(details.tag == "NAME" and details.value == "SubField Plugin", 'getAllDetails works directly on a non-record (field) pointer')
  check(details.id == nil, 'a field-level getAllDetails call has no id/qualifiedId')
end

------------------------------------------------------------------
-- getAllDetails: errors on a null pointer
------------------------------------------------------------------

do
  local ok, err = pcall(familyHelper.getAllDetails, newPtr())
  check(not ok, 'getAllDetails on a null pointer raises an error')
  check(contains(err, "getAllDetails"), 'the error names the function')
end

------------------------------------------------------------------
-- searchByName: contains (not exact) matching on forename and/or surname
------------------------------------------------------------------

do
  local robertHenry = newIndi("Robert Henry TAUBMAN", "Male", "Robert Henry", "TAUBMAN")
  local robertJones = newIndi("Robert JONES", "Male", "Robert", "JONES")
  local janeTaubman = newIndi("Jane TAUBMAN", "Female", "Jane", "TAUBMAN")

  local byBoth = familyHelper.searchByName("Robert", "Taubman")
  check(#byBoth == 1 and byBoth[1].name == "Robert Henry TAUBMAN",
    'searchByName("Robert", "Taubman") matches "Robert Henry TAUBMAN" via contains, not exact, on both parts')

  local byForenameOnly = familyHelper.searchByName("Robert", nil)
  local byForenameNames = {}
  for _, entry in ipairs(byForenameOnly) do byForenameNames[entry.name] = true end
  check(#byForenameOnly == 2 and byForenameNames["Robert Henry TAUBMAN"] and byForenameNames["Robert JONES"],
    'searchByName("Robert", nil) matches every Robert regardless of surname')

  local bySurnameOnly = familyHelper.searchByName("", "Taubman")
  local bySurnameNames = {}
  for _, entry in ipairs(bySurnameOnly) do bySurnameNames[entry.name] = true end
  check(#bySurnameOnly == 2 and bySurnameNames["Robert Henry TAUBMAN"] and bySurnameNames["Jane TAUBMAN"],
    'searchByName("", "Taubman") matches every Taubman regardless of forename ("" treated the same as omitted)')

  local caseInsensitive = familyHelper.searchByName("robert", "taubman")
  check(#caseInsensitive == 1 and caseInsensitive[1].name == "Robert Henry TAUBMAN",
    'searchByName matches case-insensitively regardless of the search string\'s own casing')

  local noMatch = familyHelper.searchByName("Zzz", nil)
  check(type(noMatch) == 'table' and #noMatch == 0, 'searchByName returns an empty array, not an error, when nothing matches')

  check(byBoth[1].id == robertHenry.id and byBoth[1].qualifiedId == "I" .. robertHenry.id,
    'a searchByName result entry is a full indiDescriptor (id/qualifiedId/name/sex), same shape as getFamilyGroup/getAncestors')
  check(byBoth[1].sex == "Male", 'a searchByName result entry carries sex')

  -- silence "unused local" style nags for fixtures only referenced via search results
  check(robertJones ~= nil and janeTaubman ~= nil, 'fixtures created')
end

------------------------------------------------------------------
-- searchByName: errors when neither forename nor surname is given
------------------------------------------------------------------

do
  local okNeither, errNeither = pcall(familyHelper.searchByName, nil, nil)
  check(not okNeither, 'searchByName(nil, nil) raises an error')
  check(contains(errNeither, "searchByName"), 'the error names the function')

  local okBothEmpty, errBothEmpty = pcall(familyHelper.searchByName, "", "")
  check(not okBothEmpty, 'searchByName("", "") raises an error (empty string treated the same as omitted)')
  check(contains(errBothEmpty, "searchByName"), 'the error names the function')
end

------------------------------------------------------------------
-- getFactsByTag: filters ptr's direct children to a matching tag (or set of tags),
-- returning a full getAllDetails-shape tree for each match
------------------------------------------------------------------

do
  local indi = newIndi("Census Plugin", "Male")

  local birt = { tag = "BIRT", children = {}, valueType = "" }
  table.insert(indi.children, birt)
  addTextChild(birt, "DATE", "1 JAN 1880")

  local cens1901 = { tag = "CENS", children = {}, valueType = "" }
  table.insert(indi.children, cens1901)
  addTextChild(cens1901, "DATE", "1901")
  addTextChild(cens1901, "PLAC", "Somewhere")

  local cens1911 = { tag = "CENS", children = {}, valueType = "" }
  table.insert(indi.children, cens1911)
  addTextChild(cens1911, "DATE", "1911")
  addTextChild(cens1911, "PLAC", "Somewhere Else")

  local censusResults = familyHelper.getFactsByTag(ptrFor(indi), "CENS")
  check(#censusResults == 2, 'getFactsByTag(ptr, "CENS") returns both CENS facts, not just the first')
  check(censusResults[1].tag == "CENS" and censusResults[2].tag == "CENS", 'every result has the requested tag')

  local function findChild(node, tag)
    for _, child in ipairs(node.children) do
      if child.tag == tag then return child end
    end
    return nil
  end
  check(findChild(censusResults[1], "DATE").value == "1901", 'first CENS result carries its own full detail tree (DATE)')
  check(findChild(censusResults[2], "PLAC").value == "Somewhere Else", 'second CENS result carries its own full detail tree (PLAC)')

  local multiTag = familyHelper.getFactsByTag(ptrFor(indi), { "BIRT", "CENS" })
  check(#multiTag == 3, 'getFactsByTag accepts an array of tags and returns every match across all of them (1 BIRT + 2 CENS)')

  local noMatch = familyHelper.getFactsByTag(ptrFor(indi), "DEAT")
  check(type(noMatch) == 'table' and #noMatch == 0, 'getFactsByTag returns an empty array, not an error, when nothing matches')
end

------------------------------------------------------------------
-- getFactsByTag: errors
------------------------------------------------------------------

do
  local indi = newIndi("Errors Plugin", "Male")

  local okNullPtr, errNullPtr = pcall(familyHelper.getFactsByTag, newPtr(), "CENS")
  check(not okNullPtr, 'getFactsByTag on a null pointer raises an error')
  check(contains(errNullPtr, "getFactsByTag"), 'the error names the function')

  local okNilTags, errNilTags = pcall(familyHelper.getFactsByTag, ptrFor(indi), nil)
  check(not okNilTags, 'getFactsByTag with nil tags raises an error')
  check(contains(errNilTags, "getFactsByTag"), 'the error names the function')

  local okEmptyTable, errEmptyTable = pcall(familyHelper.getFactsByTag, ptrFor(indi), {})
  check(not okEmptyTable, 'getFactsByTag with an empty tags array raises an error')
  check(contains(errEmptyTable, "getFactsByTag"), 'the error names the function')

  local okBadEntry, errBadEntry = pcall(familyHelper.getFactsByTag, ptrFor(indi), { "CENS", 123 })
  check(not okBadEntry, 'getFactsByTag with a non-string entry in the tags array raises an error')
  check(contains(errBadEntry, "getFactsByTag"), 'the error names the function')

  local okBadType, errBadType = pcall(familyHelper.getFactsByTag, ptrFor(indi), 123)
  check(not okBadType, 'getFactsByTag with a non-string, non-table tags argument raises an error')
  check(contains(errBadType, "getFactsByTag"), 'the error names the function')
end

------------------------------------------------------------------
-- Qualified id string ("I<n>") accepted anywhere a pointer is, across all four
-- functions -- resolved via MoveToRecordById, same as a live pointer would resolve.
------------------------------------------------------------------

do
  local qualifiedId = "I" .. self_.id

  local byId = familyHelper.getFamilyGroup(qualifiedId, "parents")
  local byPtr = familyHelper.getFamilyGroup(ptrFor(self_), "parents")
  check(#byId == 2, 'getFamilyGroup accepts a qualified id string in place of a pointer')
  check(byId[1].individual.id == byPtr[1].individual.id and byId[2].individual.id == byPtr[2].individual.id,
    'qualified-id-string call returns the same result as the equivalent pointer call')

  local ancestorsById = familyHelper.getAncestors(qualifiedId, 1)
  check(#ancestorsById == 2, 'getAncestors accepts a qualified id string in place of a pointer')

  local grandpaQualifiedId = "I" .. grandpa.id
  local descendantsById = familyHelper.getDescendants(grandpaQualifiedId, 1)
  check(#descendantsById == 2, 'getDescendants accepts a qualified id string in place of a pointer')

  local detailsById = familyHelper.getAllDetails(qualifiedId)
  check(detailsById.tag == "INDI" and detailsById.id == self_.id, 'getAllDetails accepts a qualified id string and resolves the right record')

  local factsById = familyHelper.getFactsByTag(qualifiedId, "FAMS")
  check(#factsById == 1 and factsById[1].tag == "FAMS", 'getFactsByTag accepts a qualified id string in place of a pointer')
end

------------------------------------------------------------------
-- Qualified id string: errors
------------------------------------------------------------------

do
  local okBadFormat, errBadFormat = pcall(familyHelper.getAllDetails, "not-a-qualified-id")
  check(not okBadFormat, 'a malformed qualified id string raises an error')
  check(contains(errBadFormat, "not-a-qualified-id"), 'the error names the malformed id given')

  local okBadPrefix, errBadPrefix = pcall(familyHelper.getAllDetails, "H1")
  check(not okBadPrefix, 'a qualified id with an unresolvable prefix (Header) raises an error')
  check(contains(errBadPrefix, "H1"), 'the error names the malformed id given')

  local okMissing, errMissing = pcall(familyHelper.getAllDetails, "I999999")
  check(not okMissing, 'a qualified id for a record that does not exist raises an error')
  check(contains(errMissing, "I999999"), 'the missing-record error names the id given')

  -- a FAM qualified id is a valid resolve target for getAllDetails (any record type),
  -- but getFamilyGroup/getAncestors are Individual-only -- confirms the tag check, not
  -- just the resolve step, actually runs for those two.
  local famQualifiedId = "F" .. recordsByTag["FAM"][1].id
  local famDetails = familyHelper.getAllDetails(famQualifiedId)
  check(famDetails.tag == "FAM", 'getAllDetails resolves a non-Individual qualified id fine (any record type)')

  local famFacts = familyHelper.getFactsByTag(famQualifiedId, "HUSB")
  check(#famFacts == 1 and famFacts[1].tag == "HUSB", 'getFactsByTag resolves a non-Individual qualified id fine too (any record type)')

  local okWrongType, errWrongType = pcall(familyHelper.getFamilyGroup, famQualifiedId, "parents")
  check(not okWrongType, 'getFamilyGroup rejects a qualified id that resolves to a non-Individual record')
  check(contains(errWrongType, "FAM"), 'the wrong-type error names the record type actually found')

  local okWrongType2 = pcall(familyHelper.getAncestors, famQualifiedId)
  check(not okWrongType2, 'getAncestors rejects a qualified id that resolves to a non-Individual record')

  local okWrongType3 = pcall(familyHelper.getDescendants, famQualifiedId)
  check(not okWrongType3, 'getDescendants rejects a qualified id that resolves to a non-Individual record')
end

------------------------------------------------------------------
-- A bare number (e.g. a .id field grabbed instead of .qualifiedId, issue #65) raises a
-- specific error rather than falling through to a raw Lua "attempt to index a number
-- value" several calls later.
------------------------------------------------------------------

do
  local okNumber, errNumber = pcall(familyHelper.getAllDetails, self_.id)
  check(not okNumber, 'a bare number raises an error instead of silently misbehaving')
  check(contains(errNumber, "qualified id string"), 'the error explains what was expected')
  check(contains(errNumber, tostring(self_.id)), 'the error names the number that was given')
  check(contains(errNumber, ".qualifiedId"), 'the error points at .qualifiedId as the fix')

  local okNumber2, errNumber2 = pcall(familyHelper.getFactsByTag, self_.id, "FAMS")
  check(not okNumber2, 'getFactsByTag also rejects a bare number')
  check(contains(errNumber2, "qualified id string"), 'the error explains what was expected')

  local okNumber3, errNumber3 = pcall(familyHelper.getFamilyGroup, self_.id, "parents")
  check(not okNumber3, 'getFamilyGroup also rejects a bare number (Individual-only functions are not exempted)')
  check(contains(errNumber3, "qualified id string"), 'the error explains what was expected')

  local okNumber4 = pcall(familyHelper.getAncestors, self_.id)
  check(not okNumber4, 'getAncestors also rejects a bare number')

  local okNumber5 = pcall(familyHelper.getDescendants, grandpa.id)
  check(not okNumber5, 'getDescendants also rejects a bare number')
end

------------------------------------------------------------------
-- A boolean or a wrong-shaped table (e.g. a getFamilyGroup-shaped descriptor table
-- handed back to a function expecting a pointer) raises the function's own clear error
-- too, not a raw Lua "attempt to index/call a ... value" (issue #110: resolvePointer only
-- special-cases string/number, so anything else used to fall straight through to the
-- "not ptr or ptr:IsNull()" check unguarded).
------------------------------------------------------------------

do
  local okBool, errBool = pcall(familyHelper.getAllDetails, true)
  check(not okBool, 'a boolean raises an error instead of a raw "attempt to index" crash')
  check(contains(errBool, "pointer must not be null"), 'the error is getAllDetails\' own message')
  check(contains(errBool, "boolean"), 'the error names the type actually given')

  local okTable, errTable = pcall(familyHelper.getFactsByTag, { id = 1, qualifiedId = "I219" }, "FAMS")
  check(not okTable, 'a wrong-shaped table (e.g. a descriptor result reused by mistake) also raises an error')
  check(contains(errTable, "pointer must not be null"), 'the error is getFactsByTag\'s own message')
  check(contains(errTable, "table"), 'the error names the type actually given')

  local okBoolFamily, errBoolFamily = pcall(familyHelper.getFamilyGroup, false, "parents")
  check(not okBoolFamily, 'getFamilyGroup rejects a boolean rather than crashing on :IsNull()')
  check(contains(errBoolFamily, "getFamilyGroup"), 'the error is getFamilyGroup\'s own message')

  local okTableAncestors, errTableAncestors = pcall(familyHelper.getAncestors, { id = 1 })
  check(not okTableAncestors, 'getAncestors rejects a wrong-shaped table rather than crashing on :IsNull()')
  check(contains(errTableAncestors, "getAncestors"), 'the error is getAncestors\' own message')

  local okBoolDescendants, errBoolDescendants = pcall(familyHelper.getDescendants, true)
  check(not okBoolDescendants, 'getDescendants rejects a boolean rather than crashing on :IsNull()')
  check(contains(errBoolDescendants, "getDescendants"), 'the error is getDescendants\' own message')
end

------------------------------------------------------------------
-- parseQualifiedId (issue #100): tag-scoped id-shape parsing, shared by
-- sourceHelper.lua's resolveByNameOrId so a caller passing a qualified id string like
-- "S1186" resolves by id instead of being treated as a Title/NAME lookup. Pure string
-- parsing against the same QUALIFIED_ID_PREFIX_TAG resolveQualifiedId already uses --
-- no fixture records needed.
------------------------------------------------------------------

do
  check(familyHelper.parseQualifiedId("SOUR", "S1186") == 1186,
    'parseQualifiedId parses a qualified id string matching the given tag\'s own prefix')
  check(familyHelper.parseQualifiedId("_SRCT", "T4") == 4,
    'parseQualifiedId works for a different tag/prefix pair (_SRCT -> T)')
  check(familyHelper.parseQualifiedId("SOUR", "T4") == nil,
    'parseQualifiedId returns nil for a shape matching a DIFFERENT tag\'s prefix (T is _SRCT, not SOUR) -- never cross-resolves')
  check(familyHelper.parseQualifiedId("SOUR", "s1186") == nil,
    'parseQualifiedId is case-sensitive on the prefix -- lowercase does not match, same as resolveQualifiedId elsewhere')
  check(familyHelper.parseQualifiedId("SOUR", "S1186x") == nil,
    'parseQualifiedId rejects a malformed id shape (trailing non-digit)')
  check(familyHelper.parseQualifiedId("SOUR", "Not a title, just prose") == nil,
    'parseQualifiedId returns nil (not an error) for an ordinary Title-shaped string')
end

------------------------------------------------------------------
-- pointerProblem (issue #110, docs/adr/0027): the shared pcall-guarded pointer check
-- every helper module's own validate*/get* functions now build their own message from.
-- Returns nil for a valid, non-null pointer; "" for nil or a genuinely-null pointer
-- (nothing more useful to add to the caller's own message); a "-- got <type> (<value>),
-- not a live Item Pointer" suffix for anything else. Checked directly here since it's
-- the actual new public seam this fix introduces -- every call site above just wires its
-- result into an existing message.
------------------------------------------------------------------

do
  check(familyHelper.pointerProblem(nil) == "",
    'pointerProblem returns "" for nil -- the caller\'s own message already covers it')

  local nullPtr = newPtr()
  check(familyHelper.pointerProblem(nullPtr) == "",
    'pointerProblem returns "" for a right-shaped but genuinely-null pointer -- no address noise')

  check(familyHelper.pointerProblem(ptrFor(self_)) == nil,
    'pointerProblem returns nil for a valid, non-null pointer')

  local problemString = familyHelper.pointerProblem("some description text")
  check(type(problemString) == "string" and contains(problemString, "string"),
    'pointerProblem names the type for a plain string')
  check(contains(problemString, "not a live Item Pointer"),
    'pointerProblem explains what was expected')

  local problemNumber = familyHelper.pointerProblem(42)
  check(contains(problemNumber, "number") and contains(problemNumber, "42"),
    'pointerProblem names both the type and the value for a number')

  local problemBool = familyHelper.pointerProblem(true)
  check(contains(problemBool, "boolean"), 'pointerProblem names the type for a boolean')

  local problemTable = familyHelper.pointerProblem({ id = 1 })
  check(contains(problemTable, "table"), 'pointerProblem names the type for a wrong-shaped table')

  local longString = string.rep("x", 100)
  local problemLong = familyHelper.pointerProblem(longString)
  check(contains(problemLong, "..."), 'pointerProblem truncates a long value rather than dumping it in full')
  check(not contains(problemLong, longString), 'the truncated value does not include the full 100-char string')
end

------------------------------------------------------------------
-- checkWrite / checkCreated (issue #111, docs/adr/0028): the write-result counterparts to
-- pointerProblem above -- checkWrite for fhSetValueAs*'s boolean bOK, checkCreated for
-- fhCreateItem's NULL-pointer failure, reusing pointerProblem's own null-detection rather
-- than a second copy of it.
------------------------------------------------------------------

do
  local ok = pcall(familyHelper.checkWrite, true, "should not fire")
  check(ok, 'checkWrite does not raise when bOK is true')

  local okFalse, errFalse = pcall(familyHelper.checkWrite, false, "some write failed")
  check(not okFalse, 'checkWrite raises when bOK is false')
  check(contains(errFalse, "some write failed"), 'checkWrite raises exactly the message it was given')

  local okNil, errNil = pcall(familyHelper.checkWrite, nil, "nil bOK also fails")
  check(not okNil, 'checkWrite treats a nil bOK the same as false')
  check(contains(errNil, "nil bOK also fails"), 'checkWrite raises its given message for a nil bOK too')
end

do
  local okCreated = pcall(familyHelper.checkCreated, ptrFor(self_), "should not fire")
  check(okCreated, 'checkCreated does not raise for a valid, non-null pointer')

  local nullPtr = newPtr()
  local okNull, errNull = pcall(familyHelper.checkCreated, nullPtr, "create failed")
  check(not okNull, 'checkCreated raises when fhCreateItem returns a NULL pointer')
  check(contains(errNull, "create failed"), 'checkCreated raises exactly the message it was given')
end

------------------------------------------------------------------
-- resolveDate (docs/adr/0030): the shared "accept several date shapes" resolver every
-- write path that sets a Date-typed field now goes through -- moved here from
-- sourceHelper.lua's own local toDate (issue #113) once factHelper.lua needed the
-- identical logic too.
------------------------------------------------------------------

do
  check(familyHelper.resolveDate(nil, "test") == nil, 'nil passes through unchanged')

  local alreadyADate = fhNewDate(1895)
  check(familyHelper.resolveDate(alreadyADate, "test") == alreadyADate,
    'an already-built Date object passes through unchanged, not re-wrapped')

  local fromTable = familyHelper.resolveDate({ year = 1895, month = 3, day = 12 }, "test")
  local fromTableFields = dateObjFields[fromTable]
  check(fromTableFields.year == 1895 and fromTableFields.month == 3 and fromTableFields.day == 12 and fromTableFields.subtype == nil,
    'the {year=,month=,day=} table shorthand converts via fhNewDate with no subtype argument')

  local withSubtype = familyHelper.resolveDate({ year = 1895, subtype = "ABT" }, "test")
  check(dateObjFields[withSubtype].subtype == "ABT", 'the table shorthand forwards an explicit subtype when given')

  local fromString = familyHelper.resolveDate("1901", "test")
  local fromStringFields = dateObjFields[fromString]
  check(fromStringFields.year == 1901 and fromStringFields.parsedFromText == "1901",
    'a recognized date string is parsed via SetValueAsText(text, false) into a real Date object')

  local okBadString, errBadString = pcall(familyHelper.resolveDate, "not a date at all", "createFact")
  check(not okBadString, 'an unrecognized date string raises rather than silently proceeding')
  check(contains(errBadString, "createFact") and contains(errBadString, "not a date at all"),
    'the rejection names the calling function and the offending string')
end


if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
