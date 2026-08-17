-- Standalone tests for factHelper.lua. Run with: lua bridge/tests/factHelper.test.lua
-- No FH/socket dependency. factHelper.lua only ever touches ptrRecord itself (no child-item
-- tree walk the way sourceHelper.lua's citation dance needs), so this fake is much smaller
-- than sourceHelper.test.lua's own: just enough to resolve a qualified id string via
-- familyHelper.resolvePointer (MoveToRecordById/IsNull/IsNotNull) and to describe a record
-- in an error message (fhGetQualifiedRecordId). fhu.createFact itself is stubbed per-test via
-- package.loaded.fhUtils, the same lazy-require pattern sessionSettings.lua/
-- sessionSettings.test.lua already use (factHelper.lua's own M.createFact calls
-- require('fhUtils') lazily, not at module top-level, for the same reason: a test that never
-- calls M.createFact needs no stub at all).

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'

local failures = 0

local function check(condition, label)
  if condition then
    print('  ok - ' .. label)
  else
    failures = failures + 1
    print('  FAIL - ' .. label)
  end
end

local function contains(haystack, needle)
  return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

------------------------------------------------------------------
-- Fake tree: records grouped by tag, each node { tag, id }. No child items at all --
-- factHelper.lua never walks into ptrRecord's children, only resolves/validates the
-- pointer itself before handing it to fhu.createFact.
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

-- Needed for familyHelper.resolvePointer's qualified-id-string resolution.
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

function PtrMethods:IsNotNull()
  return currentNode(self) ~= nil
end

function PtrMethods:IsNull()
  return currentNode(self) == nil
end

fhNewItemPtr = newPtr

local QUALIFIED_ID_PREFIX = { INDI = "I", FAM = "F" }
fhGetQualifiedRecordId = function(ptr)
  local node = currentNode(ptr)
  if not node or not node.id then return "" end
  return (QUALIFIED_ID_PREFIX[node.tag] or "?") .. tostring(node.id)
end

-- Appends a live node to recordsByTag[tag] without resetting the tree -- used both by
-- makeRecord (a fresh INDI/FAM ptrRecord fixture) and to build a "live fact pointer"
-- fhu.createFact fakes can return, which must be genuinely non-null under this fake's own
-- IsNull() (an unpositioned newPtr() reads as null, same as a real unresolved pointer would).
local function addNode(tag)
  recordsByTag[tag] = recordsByTag[tag] or {}
  local node = { tag = tag, id = nextId }
  nextId = nextId + 1
  table.insert(recordsByTag[tag], node)
  local ptr = newPtr()
  ptr.list = recordsByTag[tag]
  ptr.index = #recordsByTag[tag]
  return ptr, node
end

local function makeRecord(tag)
  resetTree()
  return addNode(tag)
end

local factHelper = require('factHelper')

------------------------------------------------------------------
-- validateCreateFact: pure validation, never calls fhu.createFact (no stub needed here at
-- all -- proves the split really is untracked/side-effect-free, same as
-- validateCreateSourceFromTemplate/validateCiteSource in sourceHelper.test.lua).
------------------------------------------------------------------

do
  local indi = makeRecord("INDI")
  local resolvedPtr = factHelper.validateCreateFact(indi, "BIRT", "Someplace")
  check(resolvedPtr == indi, 'validateCreateFact returns the resolved live pointer unchanged when already a live pointer')
end

do
  resetTree()
  recordsByTag["INDI"] = { { tag = "INDI", id = 219 } }
  local ptr = factHelper.validateCreateFact("I219", "BIRT")
  check(currentNode(ptr) ~= nil and currentNode(ptr).id == 219, 'validateCreateFact resolves a qualified id string (e.g. "I219") the same as familyHelper.resolvePointer')
end

do
  resetTree()
  recordsByTag["FAM"] = { { tag = "FAM", id = 3 } }
  local ptr = factHelper.validateCreateFact("F3", "MARR")
  check(currentNode(ptr) ~= nil and currentNode(ptr).id == 3, 'validateCreateFact resolves a FAM qualified id string too -- createFact spans both INDI and FAM')
end

do
  local ok, err = pcall(factHelper.validateCreateFact, 219, "BIRT")
  check(not ok, 'a bare number ptrRecord raises an error rather than being treated as an id')
  check(contains(err, 'qualified id'), 'the error is familyHelper.resolvePointer\'s own bare-number rejection, not a generic crash -- createFact spans INDI and FAM, so a number alone is ambiguous (issue #65 precedent)')
end

do
  local ok, err = pcall(factHelper.validateCreateFact, nil, "BIRT")
  check(not ok, 'a nil ptrRecord raises an error rather than proceeding')
  check(contains(err, 'ptrRecord'), 'the nil-ptrRecord error names ptrRecord specifically')
end

do
  local nullPtr = newPtr()
  local ok = pcall(factHelper.validateCreateFact, nullPtr, "BIRT")
  check(not ok, 'a non-nil but IsNull() ptrRecord also raises an error rather than proceeding')
end

do
  local ok = pcall(factHelper.validateCreateFact, "not a pointer shape at all that also is not a qualified id", "BIRT")
  check(not ok, 'a string that is not qualified-id-shaped raises an error rather than a raw crash')
end

do
  local indi = makeRecord("INDI")
  local ok, err = pcall(factHelper.validateCreateFact, indi, nil)
  check(not ok, 'a nil sTag raises an error')
  check(contains(err, 'sTag'), 'the nil-sTag error names sTag specifically')
end

do
  local indi = makeRecord("INDI")
  local ok, err = pcall(factHelper.validateCreateFact, indi, "")
  check(not ok, 'an empty-string sTag raises an error')
  check(contains(err, 'sTag'), 'the empty-sTag error names sTag specifically')
end

------------------------------------------------------------------
-- createFact: calls fhu.createFact (stubbed via package.loaded.fhUtils, the same lazy
-- require() pattern sessionSettings.lua/sessionSettings.test.lua already establish) and
-- returns its result unchanged -- the live fact pointer, not a qualifiedId, so a caller can
-- chain straight into fhBridge.citeSource(thatPointer, ...) (issue #113).
------------------------------------------------------------------

local function withFakeFhu(fakeFhu, fn)
  package.loaded.fhUtils = fakeFhu
  fn()
  package.loaded.fhUtils = nil
end

do
  local indi = makeRecord("INDI")
  local fakeFactPtr = addNode("BIRT")
  local capturedArgs
  withFakeFhu({
    createFact = function(...)
      capturedArgs = { ... }
      return fakeFactPtr
    end,
  }, function()
    local result = factHelper.createFact(indi, "BIRT", "Someplace", "12 Mar 1895", "1 Some Street", nil, nil)
    check(result == fakeFactPtr, 'createFact returns fhu.createFact\'s own return value unchanged (the new fact\'s live pointer)')
    check(capturedArgs[1] == indi, 'createFact forwards the resolved ptrRecord to fhu.createFact')
    check(capturedArgs[2] == "BIRT" and capturedArgs[3] == "Someplace" and capturedArgs[4] == "12 Mar 1895" and capturedArgs[5] == "1 Some Street",
      'createFact forwards sTag/sPlace/dtDate/sAddress straight through to fhu.createFact, unchanged')
  end)
end

do
  resetTree()
  recordsByTag["INDI"] = { { tag = "INDI", id = 219 } }
  local fakeFactPtr = addNode("CENS")
  withFakeFhu({
    createFact = function() return fakeFactPtr end,
  }, function()
    local result = factHelper.createFact("I219", "CENS")
    check(result == fakeFactPtr, 'createFact resolves a qualified id string ptrRecord before calling fhu.createFact, same as validateCreateFact')
  end)
end

-- fhu.createFact's own documented failure shape isn't specified beyond "Returns: new fact
-- record pointer" (unlike fhCreateItem's explicit NULL-pointer contract) -- checkCreated
-- still catches it regardless, since familyHelper.pointerProblem already treats a Lua nil,
-- a genuinely-null Item Pointer, and any other wrong-shaped return value as the same
-- "problem" case. One case per failure shape is enough to prove the wiring; pointerProblem
-- itself is unit-tested directly in familyHelper.test.lua.
do
  local indi = makeRecord("INDI")
  withFakeFhu({
    createFact = function() return nil end,
  }, function()
    local ok, err = pcall(factHelper.createFact, indi, "BIRT")
    check(not ok, 'a Lua nil return from fhu.createFact raises an error via checkCreated, not a silent nil result')
    check(contains(err, 'createFact') and contains(err, 'BIRT'), 'the error names createFact and the fact tag that failed to create')
  end)
end

do
  local indi = makeRecord("INDI")
  withFakeFhu({
    createFact = function() return newPtr() end, -- a real but IsNull() pointer
  }, function()
    local ok = pcall(factHelper.createFact, indi, "DEAT")
    check(not ok, 'a genuinely-null Item Pointer return from fhu.createFact also raises an error via checkCreated')
  end)
end

------------------------------------------------------------------
-- createFact re-validates before ever calling fhu.createFact -- an invalid ptrRecord/sTag
-- is rejected the same way as validateCreateFact, and fhu.createFact is never reached.
------------------------------------------------------------------

do
  local fhuCreateFactCalled = false
  withFakeFhu({
    createFact = function() fhuCreateFactCalled = true; return newPtr() end,
  }, function()
    local ok = pcall(factHelper.createFact, nil, "BIRT")
    check(not ok, 'createFact rejects a nil ptrRecord before ever calling fhu.createFact')
    check(not fhuCreateFactCalled, 'fhu.createFact is never called when ptrRecord validation fails')
  end)
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
