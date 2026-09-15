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
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new()
local check, contains = t.check, t.contains

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
-- (indiDescriptor), plus findByNames' "~.NAME:FULL" qualified read -- the fake NAME
-- fixture stores the resolved full name directly as the NAME child's value (see newIndi
-- below), so NAME:FULL is just that value; it's not slash-delimited GEDCOM text, since
-- reimplementing FH's own qualifier resolution isn't this fake's job. NAME is strict about
-- which qualifier it accepts (FULL, or none) so a test typo'd to a different qualifier
-- fails loudly instead of the fake silently answering with the same value regardless.
fhGetItemText = function(ptr, dataReference)
  local node = ptr.node
  if not node then return "" end
  local tag, qualifier = dataReference:match("^~%.([%w]+):?([%w_]*)$")
  if not tag then return "" end
  if tag == "NAME" and qualifier ~= "" and qualifier ~= "FULL" then
    error("fake fhGetItemText: unexpected NAME qualifier '" .. qualifier .. "'")
  end
  for _, child in ipairs(node.children) do
    if child.tag == tag then
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
-- findByNames' lifeDates also goes through this same fake fhCallBuiltInFunction, but with
-- its own signature (strFunctionName, ptr, "STD") -- ptrB there is a string, not a
-- pointer, so it's branched off before the DNA logging/matching below ever touches it.
-- Reads a `lifeDates` field set directly on the fixture node (see newIndi's callers),
-- returning "" (the fake's stand-in for FH's own "nothing recorded" case) when absent.
local dnaCallLog = {}
fhCallBuiltInFunction = function(strFunctionName, ptrA, ptrB)
  if strFunctionName == "LifeDates" then
    return (ptrA.node and ptrA.node.lifeDates) or ""
  end
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

-- The NAME:FULL qualifier findByNames relies on reads straight off `name` (see
-- fhGetItemText's fake above), so no given/surname split is needed here -- real FH
-- qualifier resolution is exercised by search_gedcom_knowledge's "name qualifiers"
-- reference, not re-implemented in this fixture.
local function newIndi(name, sex)
  local indi = newRecord("INDI")
  indi.name = name
  indi.display = name
  addTextChild(indi, "NAME", name)
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

-- Adds a Record Flag child (e.g. "__PRIVATE"/"__LIVING") under indi's _FLGS item, creating
-- _FLGS on first use -- mirrors describe_project's own flag census shape (issue #141).
local function addFlag(indi, flagTag)
  local flgs
  for _, child in ipairs(indi.children) do
    if child.tag == "_FLGS" then flgs = child end
  end
  if not flgs then
    flgs = { tag = "_FLGS", children = {} }
    table.insert(indi.children, flgs)
  end
  table.insert(flgs.children, { tag = flagTag, children = {} })
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
  check(byRelationship.father.individual.lifeDates == nil, 'getFamilyGroup individuals carry no lifeDates -- indiDescriptor is untouched by issue #138')
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
-- getFamilyGroup/getAncestors/getDescendants: an Excluded relative comes back as a
-- redacted placeholder (relationship/family/generation/line still present -- only the
-- individual itself is opaque), never a hard error -- these are traversal results, not a
-- direct lookup of the Excluded person (issue #141).
------------------------------------------------------------------

do
  local grandpaPtr = ptrFor(grandpa)
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })
  addFlag(dad, "__PRIVATE")

  local parents = familyHelper.getFamilyGroup(ptrFor(self_), "parents")
  local dadEntry
  for _, entry in ipairs(parents) do
    if entry.relationship == "father" then dadEntry = entry end
  end
  check(dadEntry ~= nil and dadEntry.individual.redacted == true and dadEntry.individual.id == nil,
    'getFamilyGroup redacts an Excluded parent\'s individual field, but keeps the relationship entry')

  local descendants = familyHelper.getDescendants(grandpaPtr)
  local dadViaDescendants
  for _, entry in ipairs(descendants) do
    if entry.individual.redacted then dadViaDescendants = entry end
  end
  check(dadViaDescendants ~= nil and dadViaDescendants.generation ~= nil,
    'getDescendants redacts an Excluded descendant\'s individual field, but keeps generation/family')

  local ancestors = familyHelper.getAncestors(ptrFor(self_))
  local dadViaAncestors
  for _, entry in ipairs(ancestors) do
    if entry.individual.redacted then dadViaAncestors = entry end
  end
  check(dadViaAncestors ~= nil and #dadViaAncestors.line > 0,
    'getAncestors redacts an Excluded ancestor\'s individual field, but keeps generation/line')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "all" })
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
-- recordVisibility / Visibility levels (issue #141): flag tags read literally
-- ("__PRIVATE"/"__LIVING", not via fhGetFlagTag resolution), most-restrictive-wins when
-- both flags are set, and non-Individual records are always unrestricted (Record Flags
-- are Individual-only). Exercised through indiDescriptor/getAllDetails/getFactsByTag,
-- since recordVisibility itself isn't exposed on the M table.
------------------------------------------------------------------

do
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })
  local excluded = newIndi("Excluded Plugin", "Female")
  addFlag(excluded, "__PRIVATE")

  local okDetails, errDetails = pcall(familyHelper.getAllDetails, ptrFor(excluded))
  check(not okDetails and contains(errDetails, "Excluded"), 'getAllDetails on an Excluded Individual raises, naming Excluded')

  local okFacts, errFacts = pcall(familyHelper.getFactsByTag, ptrFor(excluded), { "NAME" })
  check(not okFacts and contains(errFacts, "Excluded"), 'getFactsByTag on an Excluded Individual raises, naming Excluded')

  -- A non-Individual record (e.g. a FAM) has no Record Flags of its own -- always "all".
  local fam = newRecord("FAM")
  local famDetails = familyHelper.getAllDetails(ptrFor(fam))
  check(famDetails.tag == "FAM", 'getAllDetails on a non-Individual record is never blocked by Visibility settings')

  -- linkDescriptor redacts an Excluded target reached through a link too (e.g. a FAM's
  -- HUSB), not just a direct getAllDetails/getFactsByTag call on the Excluded record
  -- itself -- otherwise a one-hop getAllDetails(fam) would leak the name straight back.
  local famWithExcludedHusb = newFamily(excluded, nil, {})
  local famDetailsWithLink = familyHelper.getAllDetails(ptrFor(famWithExcludedHusb))
  local husbNode
  for _, child in ipairs(famDetailsWithLink.children) do
    if child.tag == "HUSB" then husbNode = child end
  end
  check(husbNode ~= nil and husbNode.link ~= nil and husbNode.link.redacted == true and husbNode.link.tag == "INDI",
    'a FAM link to an Excluded Individual comes back as a redacted, non-nil link descriptor, not the name')
  check(husbNode.link.id == nil and husbNode.link.text == nil,
    'the redacted link descriptor carries no id/name -- opaque, not just missing text')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "all" })
end

do
  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "nameOnly" })
  local nameOnly = newIndi("Nameonly Plugin", "Male")
  addFlag(nameOnly, "__LIVING")

  local details = familyHelper.getAllDetails(ptrFor(nameOnly))
  check(details.tag == "INDI" and details.id == nameOnly.id and details.qualifiedId == "I" .. nameOnly.id,
    'getAllDetails under Name Only returns identity fields only')
  check(details.children == nil and details.value == nil,
    'getAllDetails under Name Only carries no facts (no children/value)')

  local facts = familyHelper.getFactsByTag(ptrFor(nameOnly), { "NAME", "BIRT" })
  check(type(facts) == 'table' and #facts == 0, 'getFactsByTag under Name Only returns an empty array, not an error')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "all" })
end

do
  -- Both flags set, different levels configured -- the more restrictive one wins.
  familyHelper.setPrivacySettings({ privateVisibility = "nameOnly", livingVisibility = "exclude" })
  local both = newIndi("Both Plugin", "Female")
  addFlag(both, "__PRIVATE")
  addFlag(both, "__LIVING")

  local ok, err = pcall(familyHelper.getAllDetails, ptrFor(both))
  check(not ok and contains(err, "Excluded"), 'Exclude (from __LIVING here) outranks Name Only (from __PRIVATE) when both flags are set')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "all" })
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
-- findByNames: word-set containment, case- and order-insensitive, single query string
------------------------------------------------------------------

do
  newIndi("Robert Henry TAUBMANONE", "Male") -- fixture only, not referenced by id below
  local robertJones = newIndi("Robert JONESONE", "Male")
  local janeTaubman = newIndi("Jane TAUBMANONE", "Female")
  local rob = newIndi("Rob TAUBMANONE", "Male")

  local byBoth = familyHelper.findByNames("Rob Taubmanone")
  local byBothNames = {}
  for _, entry in ipairs(byBoth.matches) do byBothNames[entry.name] = true end
  check(byBoth.totalMatches == 2 and byBothNames["Robert Henry TAUBMANONE"] and byBothNames["Rob TAUBMANONE"],
    'findByNames("Rob Taubmanone") matches every name containing both words as substrings, not just exact words')
  check(not byBothNames["Robert JONESONE"] and not byBothNames["Jane TAUBMANONE"],
    'findByNames("Rob Taubmanone") excludes names missing either query word')

  local reordered = familyHelper.findByNames("Taubmanone Rob")
  local reorderedNames = {}
  for _, entry in ipairs(reordered.matches) do table.insert(reorderedNames, entry.name) end
  local byBothNamesOrdered = {}
  for _, entry in ipairs(byBoth.matches) do table.insert(byBothNamesOrdered, entry.name) end
  check(reordered.totalMatches == byBoth.totalMatches and reorderedNames[1] == byBothNamesOrdered[1] and reorderedNames[2] == byBothNamesOrdered[2],
    'findByNames("Taubmanone Rob") returns the same matches in the same order as "Rob Taubmanone" -- word order never matters (issue #137 comment)')

  local caseInsensitive = familyHelper.findByNames("rob taubmanone")
  check(caseInsensitive.totalMatches == byBoth.totalMatches,
    'findByNames matches case-insensitively regardless of the query string\'s own casing')

  local noMatch = familyHelper.findByNames("Zzznomatch")
  check(type(noMatch.matches) == 'table' and #noMatch.matches == 0 and noMatch.totalMatches == 0,
    'findByNames returns {matches = {}, totalMatches = 0}, not an error, when nothing matches')

  check(byBoth.matches[1].id ~= nil and byBoth.matches[1].qualifiedId ~= nil and byBoth.matches[1].sex ~= nil,
    'a findByNames match entry is a full indiDescriptor (id/qualifiedId/name/sex), same shape as getFamilyGroup/getAncestors')

  -- silence "unused local" style nags for fixtures only referenced via search results
  check(robertJones ~= nil and janeTaubman ~= nil and rob ~= nil, 'fixtures created')
end

------------------------------------------------------------------
-- findByNames: lifeDates -- present (via fhCallBuiltInFunction("LifeDates", ...)) when
-- FH has one to report, omitted entirely (not "") when it doesn't
------------------------------------------------------------------

do
  local withDates = newIndi("Hasdates TAUBMANFIVE", "Male")
  withDates.lifeDates = "1865-1932"
  newIndi("Nodates TAUBMANFIVE", "Male") -- fake fhCallBuiltInFunction returns "" for this one

  local found = familyHelper.findByNames("Taubmanfive")
  local byName = {}
  for _, entry in ipairs(found.matches) do byName[entry.name] = entry end

  check(byName["Hasdates TAUBMANFIVE"].lifeDates == "1865-1932",
    'findByNames carries lifeDates on a match FH can compute one for')
  check(byName["Nodates TAUBMANFIVE"].lifeDates == nil,
    'findByNames omits the lifeDates key entirely (not "") when FH has nothing to report')
end

------------------------------------------------------------------
-- findByNames: Visibility levels (issue #141) -- Exclude keeps the matches[] slot as a
-- redacted placeholder (never a silent drop -- totalMatches stays honest either way);
-- Name Only drops lifeDates but keeps id/qualifiedId/name/sex.
------------------------------------------------------------------

do
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })
  local excludedMatch = newIndi("Findme TAUBMANSIX", "Female")
  addFlag(excludedMatch, "__PRIVATE")

  local found = familyHelper.findByNames("Findme Taubmansix")
  check(found.totalMatches == 1 and #found.matches == 1,
    'an Excluded match still counts toward totalMatches and still occupies a matches[] slot')
  check(found.matches[1].redacted == true and found.matches[1].id == nil and found.matches[1].name == nil,
    'the matches[] slot for an Excluded person is a redacted, non-nil placeholder -- not the name')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "nameOnly" })
  local livingMatch = newIndi("Findme TAUBMANSEVEN", "Male")
  livingMatch.lifeDates = "1990-"
  addFlag(livingMatch, "__LIVING")

  local foundLiving = familyHelper.findByNames("Findme Taubmanseven")
  check(foundLiving.matches[1].name == "Findme TAUBMANSEVEN" and foundLiving.matches[1].id == livingMatch.id,
    'Name Only still returns the ordinary indiDescriptor fields (id/qualifiedId/name/sex)')
  check(foundLiving.matches[1].lifeDates == nil,
    'Name Only drops lifeDates even though fhCallBuiltInFunction has one to report')

  familyHelper.setPrivacySettings({ privateVisibility = "all", livingVisibility = "all" })
end

------------------------------------------------------------------
-- findByNames: exactMatch requires a whole-word match, not just substring containment
------------------------------------------------------------------

do
  newIndi("Rob TAUBMANTWO", "Male")
  newIndi("Robert Henry TAUBMANTWO", "Male")

  local exact = familyHelper.findByNames("Rob Taubmantwo", true)
  local exactNames = {}
  for _, entry in ipairs(exact.matches) do exactNames[entry.name] = true end
  check(exact.totalMatches == 1 and exactNames["Rob TAUBMANTWO"],
    'findByNames("Rob Taubmantwo", true) matches only the whole-word "Rob", not "Robert" via substring')
end

------------------------------------------------------------------
-- findByNames: ranking -- exact-word match outranks substring-only, ties break by
-- closer NAME:FULL length to the query
------------------------------------------------------------------

do
  -- all three contain "taubmanthree" as an exact whole word, so ranking falls straight
  -- through to the length tie-break: closer overall length to the 12-char query
  -- "Taubmanthree" wins. "Rob TAUBMANTHREE" (16 chars) < "Jane TAUBMANTHREE" (17 chars)
  -- < "Robert Henry TAUBMANTHREE" (26 chars) in distance from 12.
  local shortest = newIndi("Rob TAUBMANTHREE", "Male")
  local middle = newIndi("Jane TAUBMANTHREE", "Female")
  local longest = newIndi("Robert Henry TAUBMANTHREE", "Male")

  local ranked = familyHelper.findByNames("Taubmanthree")
  check(ranked.totalMatches == 3, 'findByNames("Taubmanthree") matches all three fixtures')
  check(ranked.matches[1].id == shortest.id and ranked.matches[2].id == middle.id and ranked.matches[3].id == longest.id,
    'ties (all exact-word matches) break by closer NAME:FULL length to the query, shortest distance first')
end

do
  -- exactCount must dominate the length tie-break, not the other way round: moreExact has
  -- both query words as exact whole-word matches but a huge length delta from the padding;
  -- lessExact matches both words only as substrings within one run-on word, with a length
  -- delta far closer to the query. If the sort ever compared length first, lessExact would
  -- wrongly rank above moreExact.
  local moreExact = newIndi("Rob ZedQQFOUR Padding Words Here To Make This Name Much Longer Than The Query", "Male")
  local lessExact = newIndi("Xxrobxxzedqqfourxx", "Male")

  local ranked = familyHelper.findByNames("Rob ZedQQFOUR")
  check(ranked.totalMatches == 2, 'findByNames("Rob ZedQQFOUR") matches both fixtures')
  check(ranked.matches[1].id == moreExact.id and ranked.matches[2].id == lessExact.id,
    'a higher exactCount outranks a closer length delta, not the reverse')
end

------------------------------------------------------------------
-- findByNames: batch queries -- one array in, one array out, position-preserving,
-- no-match entries kept in place
------------------------------------------------------------------

do
  newIndi("Batch JONESFOUR", "Male")

  local batch = familyHelper.findByNames({ "Taubmanone", "Zzznomatch", "Jonesfour" })
  check(type(batch) == 'table' and #batch == 3, 'a list query returns one result per input entry, in order')
  check(batch[1].totalMatches > 0, 'batch[1] ("Taubmanone") has matches')
  check(batch[2].totalMatches == 0 and #batch[2].matches == 0,
    'batch[2] ("Zzznomatch") stays in place as {matches = {}, totalMatches = 0} rather than being dropped')
  check(batch[3].totalMatches > 0, 'batch[3] ("Jonesfour") has matches')

  local single = familyHelper.findByNames("Taubmanone")
  check(type(single.matches) == 'table' and type(single.totalMatches) == 'number',
    'a single string query returns one {matches, totalMatches} object, not an array -- output shape mirrors input shape')
end

------------------------------------------------------------------
-- findByNames: results capped at the top 30, totalMatches reports the true count
------------------------------------------------------------------

do
  for i = 1, 35 do
    newIndi("Capzzz Person" .. i, "Male")
  end

  local capped = familyHelper.findByNames("Capzzz")
  check(capped.totalMatches == 35, 'findByNames reports the true pre-cap totalMatches (35), never a silent slice')
  check(#capped.matches == 30, 'findByNames caps matches at the top 30 ranked entries')
end

------------------------------------------------------------------
-- findByNames: validation -- blank query entries error the whole call
------------------------------------------------------------------

do
  local okNil, errNil = pcall(familyHelper.findByNames, nil)
  check(not okNil, 'findByNames(nil) raises an error')
  check(contains(errNil, "findByNames"), 'the error names the function')

  local okEmpty, errEmpty = pcall(familyHelper.findByNames, "")
  check(not okEmpty, 'findByNames("") raises an error')
  check(contains(errEmpty, "findByNames"), 'the error names the function')

  local okWhitespace, errWhitespace = pcall(familyHelper.findByNames, "   ")
  check(not okWhitespace, 'findByNames("   ") raises an error (whitespace-only splits to zero words, same as blank)')
  check(contains(errWhitespace, "findByNames"), 'the error names the function')

  local okEmptyList, errEmptyList = pcall(familyHelper.findByNames, {})
  check(not okEmptyList, 'findByNames({}) raises an error (an empty batch has nothing to search for)')
  check(contains(errEmptyList, "findByNames"), 'the error names the function')

  local okBlankEntry, errBlankEntry = pcall(familyHelper.findByNames, { "Taubman", "" })
  check(not okBlankEntry, 'findByNames({"Taubman", ""}) raises an error -- one blank entry errors the whole batch')
  check(contains(errBlankEntry, "findByNames"), 'the error names the function')

  local okNonString, errNonString = pcall(familyHelper.findByNames, { "Taubman", 42 })
  check(not okNonString, 'findByNames({"Taubman", 42}) raises an error -- a non-string entry is invalid')
  check(contains(errNonString, "findByNames"), 'the error names the function')

  -- Guards against the old searchByName(forename, surname) two-string-argument habit:
  -- without this, findByNames("Robert", "Taubman") would silently run as exactMatch mode
  -- on just the query "Robert", never erroring.
  local okBadExactMatch, errBadExactMatch = pcall(familyHelper.findByNames, "Robert", "Taubman")
  check(not okBadExactMatch, 'findByNames("Robert", "Taubman") raises an error -- exactMatch must be a boolean, not a second name')
  check(contains(errBadExactMatch, "findByNames"), 'the error names the function')
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


t.report()
