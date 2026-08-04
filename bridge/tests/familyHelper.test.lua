-- Standalone tests for familyHelper.lua. Run with: lua bridge/tests/familyHelper.test.lua
-- No FH/socket dependency. Like sourceHelper.test.lua, familyHelper.lua genuinely walks a
-- record/child-item tree (MoveToFirstRecord, MoveTo with a "~.TAG" data reference,
-- MoveNext/MoveNext("SAME_TAG"), MoveToFirstChildItem), so this file builds a small
-- in-memory fake item-pointer double, scoped narrowly to only the methods/globals
-- familyHelper.lua actually calls: item-pointer methods MoveToFirstRecord/MoveTo/
-- MoveNext/MoveToFirstChildItem/IsNotNull/IsNull, plus globals fhNewItemPtr/fhGetTag/
-- fhGetItemText/fhGetRecordId/fhGetQualifiedRecordId/fhGetValueAsLink/fhGetDisplayText/
-- fhGetValueType/fhGetValueAsRichText/fhHasChildItem/fhIndGetName.
--
-- Unlike sourceHelper.test.lua's fake tree (single-tag child lists only), this module
-- walks records whose children mix several different tags as siblings (a FAM record's
-- HUSB/WIFE/CHIL, an INDI's NAME/SEX/BIRT/FAMC/FAMS, a BIRT's DATE/PLAC), so the fake
-- MoveNext must actually honor "SAME_TAG" vs the default "ANY", not just advance an index.

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
-- Qualified id string ("I<n>") accepted anywhere a pointer is, across all three
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

  local detailsById = familyHelper.getAllDetails(qualifiedId)
  check(detailsById.tag == "INDI" and detailsById.id == self_.id, 'getAllDetails accepts a qualified id string and resolves the right record')
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

  local okMissing, errMissing = pcall(familyHelper.getAllDetails, "I999999")
  check(not okMissing, 'a qualified id for a record that does not exist raises an error')
  check(contains(errMissing, "I999999"), 'the missing-record error names the id given')

  -- a FAM qualified id is a valid resolve target for getAllDetails (any record type),
  -- but getFamilyGroup/getAncestors are Individual-only -- confirms the tag check, not
  -- just the resolve step, actually runs for those two.
  local famQualifiedId = "F" .. recordsByTag["FAM"][1].id
  local famDetails = familyHelper.getAllDetails(famQualifiedId)
  check(famDetails.tag == "FAM", 'getAllDetails resolves a non-Individual qualified id fine (any record type)')

  local okWrongType, errWrongType = pcall(familyHelper.getFamilyGroup, famQualifiedId, "parents")
  check(not okWrongType, 'getFamilyGroup rejects a qualified id that resolves to a non-Individual record')
  check(contains(errWrongType, "FAM"), 'the wrong-type error names the record type actually found')

  local okWrongType2 = pcall(familyHelper.getAncestors, famQualifiedId)
  check(not okWrongType2, 'getAncestors rejects a qualified id that resolves to a non-Individual record')
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
