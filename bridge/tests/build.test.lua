-- Standalone tests for bridge/scripts/bundler.lua. Run with: lua bridge/tests/build.test.lua
-- No FH/socket/iup dependency, same as the rest of bridge/tests/.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../scripts/?.lua'
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
local realEntryPath = arg[0]:match("(.*[/\\])") .. '../AI Assistant Connector.fh_lua'
local realEntrySource = readFile(realEntryPath)

local function fakeReadModule(name)
  return '-- FAKE BODY FOR ' .. name
end

-- Deliberately different from whatever @Version the real entry file's header currently
-- carries, so tests that check the stamped/injected version actually prove buildBundle
-- overrides it from packageVersion, rather than coincidentally matching what was already
-- there (issue #89).
local TEST_PACKAGE_VERSION = '9.9.9'

local bundled = bundler.buildBundle(realEntrySource, fakeReadModule, TEST_PACKAGE_VERSION)

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

-- BRIDGE_VERSION (issue #45) is injected from packageVersion (issue #89), not from
-- whatever the source entry's own @Version header said.
local versionIdx = bundled:find('local BRIDGE_VERSION = ' .. string.format('%q', TEST_PACKAGE_VERSION), 1, true)
assertTrue(versionIdx ~= nil, 'bundled output injects BRIDGE_VERSION from the given packageVersion')
assertTrue(fhInitIdx ~= nil and versionIdx ~= nil and firstPreloadIdx ~= nil and
  fhInitIdx < versionIdx and versionIdx < firstPreloadIdx,
  'BRIDGE_VERSION is injected after fhInitialise(...) and before the bundled modules, so it is in scope for the rest of the file')

-- extractPackageVersion (issue #89): pulls "version" out of raw package.json text with a
-- plain pattern match (no JSON parser — matches this project's existing no-JSON-library
-- stance).
assertEqual(
  bundler.extractPackageVersion('{\n  "name": "fh-mcp-bridge-server",\n  "version": "1.2.3",\n  "private": true\n}'),
  '1.2.3',
  'extractPackageVersion parses the version field out of realistic package.json text')

local extractOk, extractErr = pcall(bundler.extractPackageVersion, '{"name": "no-version-field"}')
assertEqual(extractOk, false, 'extractPackageVersion fails loudly when the version field is missing')
assertTrue(extractOk == false and tostring(extractErr):find('version', 1, true) ~= nil,
  'extractPackageVersion error message mentions the missing field')

-- The @Version header is a stamped mirror of packageVersion (issue #89): it must reflect
-- packageVersion even when the source entry file's own header still says something else —
-- proving this is an override, not a passthrough of whatever was already there.
local originalHeaderVersion = realEntrySource:match('@Version:%s*(%S+)')
assertTrue(originalHeaderVersion ~= nil, 'test setup: real entry source must carry an @Version header')
assertTrue(originalHeaderVersion ~= TEST_PACKAGE_VERSION,
  'test setup: TEST_PACKAGE_VERSION must differ from the real header, or the override test below proves nothing')
assertTrue(bundled:find('@Version: ' .. TEST_PACKAGE_VERSION, 1, true) ~= nil,
  '@Version header is stamped with the given packageVersion')
assertTrue(bundled:find('@Version: ' .. originalHeaderVersion, 1, true) == nil,
  '@Version header no longer carries the source entry file\'s original version')

-- A missing/changed @Version header must fail loudly, not silently ship a bundle with no
-- runtime-readable version (defeats the whole point of issue #45/#89).
local entryMissingVersion = realEntrySource:gsub('@Version:%s*%S+', '@NoVersionHeader: nope', 1)
local versionOk = pcall(bundler.buildBundle, entryMissingVersion, fakeReadModule, TEST_PACKAGE_VERSION)
assertEqual(versionOk, false, 'a missing @Version header makes buildBundle fail loudly, not silently')

-- buildBundle must not silently build an unversioned/misversioned bundle if it's ever
-- called without a packageVersion (e.g. a caller forgetting to wire up the new parameter).
local noVersionOk = pcall(bundler.buildBundle, realEntrySource, fakeReadModule, nil)
assertEqual(noVersionOk, false, 'buildBundle fails loudly when packageVersion is nil')
local emptyVersionOk = pcall(bundler.buildBundle, realEntrySource, fakeReadModule, '')
assertEqual(emptyVersionOk, false, 'buildBundle fails loudly when packageVersion is empty')

-- @LastUpdated is stamped with the build date (default: today, but overridable here so the
-- assertion doesn't depend on the real current date), not left at whatever date the source
-- entry file happened to carry.
local existingLastUpdated = realEntrySource:match('@LastUpdated:%s*(%S+)')
assertTrue(existingLastUpdated ~= nil, 'test setup: real entry source must carry an @LastUpdated header')
local bundledWithFixedDate = bundler.buildBundle(realEntrySource, fakeReadModule, TEST_PACKAGE_VERSION, '2099-01-02')
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
local lastUpdatedOk = pcall(bundler.buildBundle, entryMissingLastUpdated, fakeReadModule, TEST_PACKAGE_VERSION)
assertEqual(lastUpdatedOk, false, 'a missing @LastUpdated header makes buildBundle fail loudly, not silently')

-- The rest of the entry file — now just the require() for bridgeSession.lua (issue #75,
-- docs/adr/0018) — must survive untouched.
assertTrue(bundled:find('require("bridgeSession")', 1, true) ~= nil,
  'bridgeSession require survives after the bundled modules')

-- bridgeSession's package.preload closure must actually see BRIDGE_VERSION as an upvalue
-- at runtime, not just at the right text position (docs/adr/0018) — FH only ever loads the
-- bundled artifact, never the raw split source, so this is what actually has to work.
-- fhInitialise/fhSetStringEncoding are stubbed as no-ops (real FH globals, not part of this
-- module's own responsibility) so the bundled stub can actually run in a plain interpreter.
local versionCaptureBundled = bundler.buildBundle(realEntrySource, function(name)
  if name == 'bridgeSession' then
    return 'assert(BRIDGE_VERSION == ' .. string.format('%q', TEST_PACKAGE_VERSION) ..
      ', "BRIDGE_VERSION not visible inside bridgeSession module: " .. tostring(BRIDGE_VERSION))\n' ..
      'return true'
  end
  return fakeReadModule(name)
end, TEST_PACKAGE_VERSION)
local versionCaptureChunk, versionCaptureLoadErr = load(versionCaptureBundled)
assertTrue(versionCaptureChunk ~= nil, 'BRIDGE_VERSION-capture bundle parses' ..
  (versionCaptureChunk == nil and (' (' .. tostring(versionCaptureLoadErr) .. ')') or ''))
if versionCaptureChunk then
  local previousFhInitialise, previousFhSetStringEncoding = _G.fhInitialise, _G.fhSetStringEncoding
  _G.fhInitialise = function() end
  _G.fhSetStringEncoding = function() end
  local execOk, execErr = pcall(versionCaptureChunk)
  assertTrue(execOk, 'bridgeSession package.preload closure sees BRIDGE_VERSION as an upvalue' ..
    (execOk and '' or (' (' .. tostring(execErr) .. ')')))
  _G.fhInitialise, _G.fhSetStringEncoding = previousFhInitialise, previousFhSetStringEncoding
end

-- A stale entry source (anchors no longer match) must fail loudly, not silently ship a
-- bundle with the wrong install note or no splice point.
local staleEntry = realEntrySource:gsub('Install:', 'Installation notes:', 1)
local ok = pcall(bundler.buildBundle, staleEntry, fakeReadModule, TEST_PACKAGE_VERSION)
assertEqual(ok, false, 'a changed Install comment makes buildBundle fail loudly, not silently')

-- Full integration: bundle the real modules from disk (same as build.lua's CLI) and check
-- the result is syntactically valid Lua.
local function realReadModule(name)
  return readFile(arg[0]:match("(.*[/\\])") .. '../' .. name .. '.lua')
end
local realBundled = bundler.buildBundle(realEntrySource, realReadModule, TEST_PACKAGE_VERSION)
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
