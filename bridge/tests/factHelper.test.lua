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
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'

local t = require('testHelpers').new({ passFmt = '  ok - %s', failFmt = '  FAIL - %s' })
local check, contains = t.check, t.contains

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

-- Minimal child-item walk, needed only for familyHelper.recordVisibility's _FLGS walk
-- (issue #141) -- a node's own .children array (nil/empty for every pre-#141 fixture) is
-- reused as the pointed-to list, the same way a top-level recordsByTag[tag] list already is.
function PtrMethods:MoveToFirstChildItem(parentPtr)
  local parentNode = currentNode(parentPtr)
  self.list = (parentNode and parentNode.children) or {}
  self.index = 1
end

function PtrMethods:MoveNext()
  self.index = self.index + 1
end

fhNewItemPtr = newPtr

fhGetTag = function(ptr)
  local node = currentNode(ptr)
  return node and node.tag
end

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

-- Adds a Record Flag child (e.g. "__PRIVATE"/"__LIVING") under node's _FLGS item, creating
-- _FLGS on first use -- mirrors familyHelper.test.lua's own addFlag (issue #141).
local function addFlag(node, flagTag)
  node.children = node.children or {}
  local flgs
  for _, c in ipairs(node.children) do
    if c.tag == "_FLGS" then flgs = c end
  end
  if not flgs then
    flgs = { tag = "_FLGS", children = {} }
    table.insert(node.children, flgs)
  end
  table.insert(flgs.children, { tag = flagTag, children = {} })
end

-- fhNewDate fake (issue #113, docs/adr/0030): validateCreateFact now resolves dtDate via
-- familyHelper.resolveDate, which calls dt:SetValueAsText(...) on a fhNewDate()-built
-- object -- same coroutine-as-userdata-stand-in fake, and the same reasoning, as
-- sourceHelper.test.lua/familyHelper.test.lua already use (a coroutine's type() is
-- 'thread', genuinely distinct from a plain table, matching real FH's userdata Date
-- object -- see resolveDate's own type(value) == "table" branch). debug.setmetatable on a
-- thread sets ONE shared metatable for every coroutine in this process. Succeeds only for
-- a bare 4-digit-year string, matching resolveDate's own bAllowPhrase=false call.
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

local factHelper = require('factHelper')
local familyHelper = require('familyHelper')

------------------------------------------------------------------
-- validateCreateFact: pure validation, never calls fhu.createFact (no stub needed here at
-- all -- proves the split really is untracked/side-effect-free, same as
-- validateCreateSourceFromTemplate/validateCiteSource in sourceHelper.test.lua).
------------------------------------------------------------------

do
  local indi = makeRecord("INDI")
  local resolvedPtr = factHelper.validateCreateFact(indi, "BIRT")
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
-- validateCreateFact: an Excluded Individual's own record blocks the write (issue #141).
------------------------------------------------------------------

do
  local indi, node = makeRecord("INDI")
  addFlag(node, "__PRIVATE")
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })
  local ok, err = pcall(factHelper.validateCreateFact, indi, "BIRT")
  familyHelper.setPrivacySettings(nil)
  check(not ok, 'validateCreateFact raises for an Excluded Individual')
  check(contains(err, 'Excluded'), 'the error names the Excluded reason')
end

do
  local fam = makeRecord("FAM")
  familyHelper.setPrivacySettings({ privateVisibility = "exclude", livingVisibility = "all" })
  local ok = pcall(factHelper.validateCreateFact, fam, "MARR")
  familyHelper.setPrivacySettings(nil)
  check(ok, 'a FAM record is never blocked -- Record Flags are Individual-only')
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

-- dtDate here is a plain, recognized date string ("1895") -- proves createFact resolves it
-- via familyHelper.resolveDate into a real Date object BEFORE forwarding to fhu.createFact,
-- not the raw string unchanged -- the fix for the live bug this test used to warn about
-- instead (issue #113, docs/adr/0030): a raw string handed straight to fhSetValueAsDate
-- previously only failed after the Fact item had already been created.
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
    local result = factHelper.createFact(indi, "BIRT", "Someplace", "1895", "1 Some Street", nil, nil)
    check(result == fakeFactPtr, 'createFact returns fhu.createFact\'s own return value unchanged (the new fact\'s live pointer)')
    check(capturedArgs[1] == indi, 'createFact forwards the resolved ptrRecord to fhu.createFact')
    check(capturedArgs[2] == "BIRT" and capturedArgs[3] == "Someplace" and capturedArgs[5] == "1 Some Street",
      'createFact forwards sTag/sPlace/sAddress straight through to fhu.createFact, unchanged')
    local resolvedDate = capturedArgs[4]
    check(dateObjFields[resolvedDate] ~= nil and dateObjFields[resolvedDate].year == 1895,
      'createFact resolves a plain dtDate string into a real Date object (via familyHelper.resolveDate) before forwarding it to fhu.createFact')
  end)
end

-- Regression test (live-caught, Family Historian Sample Project 8): sandbox.lua's
-- validatedTrackedWrite wrapper calls validateFn(...) and fn(...) with the SAME raw
-- positional args a real fhBridge.createFact(...) call receives -- NOT via M.createFact's
-- own internal call, which always had dtDate correctly bound to its own local variable
-- regardless of validateCreateFact's declared parameter positions. A real call once bound
-- dtDate to sPlace's value instead (M.validateCreateFact's old (ptrRecord, sTag, dtDate)
-- signature put dtDate at position 3, but the real call signature has sPlace there and
-- dtDate at position 4) -- silently validating "Newtown" as a date and dropping "1905"
-- entirely, undetected by every other test in this file since none of them called
-- M.validateCreateFact with the full raw 7-argument list the way the real wrapper does.
-- This test exists specifically to catch any future positional drift between
-- M.validateCreateFact's and M.createFact's own signatures the same way.
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
    -- Mirrors sandbox.lua's validatedTrackedWrite(validateFn, fn) exactly: both called with
    -- the identical raw args, positionally -- not routed through M.createFact's own call.
    local rawArgs = { indi, "CENS", "Newtown", "1905" }
    factHelper.validateCreateFact(table.unpack(rawArgs))
    local result = factHelper.createFact(table.unpack(rawArgs))
    check(result == fakeFactPtr, 'the wrapper-simulated call still succeeds')
    check(capturedArgs[3] == "Newtown", 'sPlace ("Newtown") is forwarded to fhu.createFact as sPlace, not consumed as dtDate')
    local resolvedDate = capturedArgs[4]
    check(dateObjFields[resolvedDate] ~= nil and dateObjFields[resolvedDate].year == 1905,
      'dtDate ("1905") resolves from its real 4th-argument position, not sPlace\'s 3rd-argument position')
  end)
end

-- An already-built Date object passes through resolveDate unchanged, not re-wrapped --
-- same familyHelper.resolveDate contract createSourceFromTemplate/citeSource already rely on.
do
  local indi = makeRecord("INDI")
  local fakeFactPtr = addNode("CENS")
  local capturedArgs
  local dateObj = fhNewDate(1900, 1, 1)
  withFakeFhu({
    createFact = function(...)
      capturedArgs = { ... }
      return fakeFactPtr
    end,
  }, function()
    factHelper.createFact(indi, "CENS", nil, dateObj)
    check(capturedArgs[4] == dateObj, 'an already-built Date object is forwarded unchanged, not re-wrapped')
  end)
end

-- An unrecognized dtDate string is rejected by validateCreateFact -- inside M.createFact,
-- reached before fhu.createFact ever runs -- rather than being forwarded and only failing
-- (with a real Fact item already created) deep inside fhu.createFact's own implementation.
do
  local indi = makeRecord("INDI")
  local fhuCreateFactCalled = false
  withFakeFhu({
    createFact = function() fhuCreateFactCalled = true; return addNode("BIRT") end,
  }, function()
    local ok, err = pcall(factHelper.createFact, indi, "BIRT", nil, "not a date")
    check(not ok, 'an unrecognized dtDate string raises rather than proceeding')
    check(contains(err, "createFact") and contains(err, "not a date"), 'the rejection names createFact and the offending string')
    check(not fhuCreateFactCalled, 'fhu.createFact is never called when dtDate fails to resolve')
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

t.report()
