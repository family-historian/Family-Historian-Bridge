-- Standalone tests for bridge/scripts/bundler.lua. Run with: lua bridge/tests/build.test.lua
-- No FH/socket/iup dependency, same as the rest of bridge/tests/.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../scripts/?.lua'
local bundler = require('bundler')

local failures = 0

local function assertEqual(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print(string.format('FAIL %s: expected %s, got %s', label, tostring(expected), tostring(actual)))
  else
    print(string.format('PASS %s', label))
  end
end

local function assertTrue(condition, label)
  assertEqual(condition and true or false, true, label)
end

local function readFile(path)
  local f = assert(io.open(path, 'rb'))
  local content = f:read('*a')
  f:close()
  return content
end

-- Real entry file, so the splice-point and install-comment anchors are exercised against
-- the actual text they have to match in production — but with fake, easy-to-assert module
-- bodies standing in for the real (large) module files.
local realEntryPath = arg[0]:match("(.*/)") .. '../Claude MCP Bridge.fh_lua'
local realEntrySource = readFile(realEntryPath)

local function fakeReadModule(name)
  return '-- FAKE BODY FOR ' .. name
end

local bundled = bundler.buildBundle(realEntrySource, fakeReadModule)

assertTrue(bundled:find('Do not hand-edit it', 1, true) ~= nil,
  'bundled output carries the generated/bundled install note')
assertTrue(bundled:find('must all be copied together', 1, true) == nil,
  'bundled output no longer carries the dev-only multi-file install note')

local preloadCount = 0
for _ in bundled:gmatch('package%.preload%[') do
  preloadCount = preloadCount + 1
end
assertEqual(preloadCount, #bundler.MODULE_NAMES, 'one package.preload assignment per module')

for _, name in ipairs(bundler.MODULE_NAMES) do
  assertTrue(bundled:find('package.preload["' .. name .. '"] = function()', 1, true) ~= nil,
    'preload assignment present for ' .. name)
  assertTrue(bundled:find('-- FAKE BODY FOR ' .. name, 1, true) ~= nil,
    'module body inlined for ' .. name)
end

-- The bundle must be spliced in after fhInitialise(...), never before it (FH requires
-- fhInitialise to be the first function this plugin calls, before even require()).
local fhInitIdx = bundled:find('fhInitialise(7, 0, 0, "save_required")', 1, true)
local firstPreloadIdx = bundled:find('package.preload[', 1, true)
assertTrue(fhInitIdx ~= nil and firstPreloadIdx ~= nil and fhInitIdx < firstPreloadIdx,
  'bundle is spliced in after the fhInitialise(...) call')

-- BRIDGE_VERSION (issue #45): extracted from the real entry's own @Version header, so this
-- assertion doesn't need updating on every version bump.
local expectedVersion = realEntrySource:match('@Version:%s*(%S+)')
assertTrue(expectedVersion ~= nil, "test setup: real entry source must carry an @Version header")
local versionIdx = bundled:find('local BRIDGE_VERSION = ' .. string.format('%q', expectedVersion), 1, true)
assertTrue(versionIdx ~= nil, 'bundled output injects BRIDGE_VERSION parsed from the @Version header')
assertTrue(fhInitIdx ~= nil and versionIdx ~= nil and firstPreloadIdx ~= nil and
  fhInitIdx < versionIdx and versionIdx < firstPreloadIdx,
  'BRIDGE_VERSION is injected after fhInitialise(...) and before the bundled modules, so it is in scope for the rest of the file')

-- A missing/changed @Version header must fail loudly, not silently ship a bundle with no
-- runtime-readable version (defeats the whole point of issue #45).
local entryMissingVersion = realEntrySource:gsub('@Version:%s*%S+', '@NoVersionHeader: nope', 1)
local versionOk = pcall(bundler.buildBundle, entryMissingVersion, fakeReadModule)
assertEqual(versionOk, false, 'a missing @Version header makes buildBundle fail loudly, not silently')

-- @LastUpdated is stamped with the build date (default: today, but overridable here so the
-- assertion doesn't depend on the real current date), not left at whatever date the source
-- entry file happened to carry.
local existingLastUpdated = realEntrySource:match('@LastUpdated:%s*(%S+)')
assertTrue(existingLastUpdated ~= nil, 'test setup: real entry source must carry an @LastUpdated header')
local bundledWithFixedDate = bundler.buildBundle(realEntrySource, fakeReadModule, '2099-01-02')
assertTrue(bundledWithFixedDate:find('@LastUpdated: 2099-01-02', 1, true) ~= nil,
  '@LastUpdated header is stamped with the supplied build date')
assertTrue(existingLastUpdated == '2099-01-02' or
  bundledWithFixedDate:find('@LastUpdated: ' .. existingLastUpdated, 1, true) == nil,
  '@LastUpdated header no longer carries the stale source-file date')
assertTrue(bundled:find('@LastUpdated: ' .. os.date('%Y-%m-%d'), 1, true) ~= nil,
  'buildBundle defaults the @LastUpdated stamp to the real current date when no override is given')

-- A missing/changed @LastUpdated header must fail loudly, not silently ship a bundle with
-- a stale or absent build-date stamp.
local entryMissingLastUpdated = realEntrySource:gsub('@LastUpdated:%s*%S+', '@NoLastUpdatedHeader: nope', 1)
local lastUpdatedOk = pcall(bundler.buildBundle, entryMissingLastUpdated, fakeReadModule)
assertEqual(lastUpdatedOk, false, 'a missing @LastUpdated header makes buildBundle fail loudly, not silently')

-- The rest of the entry file (the actual dialog/socket logic) must survive untouched.
assertTrue(bundled:find('socket = require("socket")', 1, true) ~= nil,
  'socket require survives after the bundled modules')
assertTrue(bundled:find('function btnStart:action()', 1, true) ~= nil,
  'dialog logic after the module requires survives untouched')

-- A stale entry source (anchors no longer match) must fail loudly, not silently ship a
-- bundle with the wrong install note or no splice point.
local staleEntry = realEntrySource:gsub('Install:', 'Installation notes:', 1)
local ok = pcall(bundler.buildBundle, staleEntry, fakeReadModule)
assertEqual(ok, false, 'a changed Install comment makes buildBundle fail loudly, not silently')

-- Full integration: bundle the real modules from disk (same as build.lua's CLI) and check
-- the result is syntactically valid Lua.
local function realReadModule(name)
  return readFile(arg[0]:match("(.*/)") .. '../' .. name .. '.lua')
end
local realBundled = bundler.buildBundle(realEntrySource, realReadModule)
local chunk, loadErr = load(realBundled)
assertTrue(chunk ~= nil, 'bundle of the real modules parses as valid Lua' ..
  (chunk == nil and (' (' .. tostring(loadErr) .. ')') or ''))

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
