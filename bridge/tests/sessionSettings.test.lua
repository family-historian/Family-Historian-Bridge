-- Standalone tests for sessionSettings.lua. Run with: lua bridge/tests/sessionSettings.test.lua
-- fhUtils ships with FH and isn't resolvable via package.path in this plain-lua test
-- process; stub it via package.loaded the same way runScript.test.lua/sandbox.test.lua do,
-- so require('fhUtils') inside sessionSettings.load()/save() resolves to the stub instead.

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

-- Fresh fake fhUtils + a fresh require of sessionSettings for each scenario below, since
-- sessionSettings.lua doesn't cache its own require('fhUtils') result -- each call to
-- load()/save() re-resolves package.loaded.fhUtils, so swapping the stub between checks is
-- enough; no need to package.loaded[...] = nil the module under test itself.
local function withFakeFhu(fakeFhu, fn)
  package.loaded.fhUtils = fakeFhu
  package.loaded.sessionSettings = nil
  local sessionSettings = require('sessionSettings')
  fn(sessionSettings)
  package.loaded.fhUtils = nil
  package.loaded.sessionSettings = nil
end

-- 1. Normal load: fhu.loadOptions returns a well-formed table, both fields pass through
-- (in-range timeout, valid accessMode).
withFakeFhu({
  loadOptions = function(defaults, scope)
    check(scope == 'LOCAL_MACHINE', 'load() calls fhu.loadOptions with LOCAL_MACHINE scope')
    check(type(defaults) == 'table' and defaults.accessMode == 'read-only' and defaults.idleTimeoutMinutes == 15
      and defaults.debugLogging == false,
      'load() passes today\'s hardcoded values (read-only, 15, debug logging off) as the defaults argument')
    return { accessMode = 'read-write', idleTimeoutMinutes = 45, debugLogging = true }
  end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.accessMode == 'read-write', 'a valid stored accessMode passes through unchanged')
  check(settings.idleTimeoutMinutes == 45, 'an in-range stored idleTimeoutMinutes passes through unchanged')
  check(settings.debugLogging == true, 'a stored debugLogging of true passes through unchanged')
end)

-- 2. First run / missing file: fhu.loadOptions itself returns the defaults table it was
-- given (its own documented behaviour when there's nothing stored yet).
withFakeFhu({
  loadOptions = function(defaults, scope) return defaults end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.accessMode == 'read-only', 'first run defaults to read-only, matching today\'s hardcoded default')
  check(settings.idleTimeoutMinutes == 15, 'first run defaults to 15 minutes, matching today\'s hardcoded default')
  check(settings.debugLogging == false, 'first run defaults to debug logging off, matching today\'s hardcoded default')
end)

-- 2b. Stored debugLogging isn't a real boolean (pre-#122 settings file missing the field
-- entirely, or hand-edited junk) -- falls back to off.
withFakeFhu({
  loadOptions = function() return { accessMode = 'read-only', idleTimeoutMinutes = 15 } end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.debugLogging == false, 'a missing debugLogging field falls back to off')
end)
withFakeFhu({
  loadOptions = function() return { accessMode = 'read-only', idleTimeoutMinutes = 15, debugLogging = 'yes' } end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.debugLogging == false, 'a non-boolean debugLogging value falls back to off')
end)

-- 3. fhu.loadOptions raises (corrupt file, read error) -- falls back to defaults silently,
-- no error propagates out of load().
withFakeFhu({
  loadOptions = function() error('simulated disk read failure') end,
}, function(sessionSettings)
  local ok, settings = pcall(sessionSettings.load)
  check(ok, 'load() does not propagate a fhu.loadOptions error')
  check(ok and settings.accessMode == 'read-only' and settings.idleTimeoutMinutes == 15,
    'a fhu.loadOptions error falls back to defaults (read-only, 15)')
end)

-- 4. fhu.loadOptions returns something malformed (not a table) -- falls back to defaults.
withFakeFhu({
  loadOptions = function() return 'not a table' end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.accessMode == 'read-only' and settings.idleTimeoutMinutes == 15,
    'a non-table return from fhu.loadOptions falls back to defaults')
end)

-- 5. Stored timeout out of range -- clamped via timeoutDisplay.clampMinutes, same as a
-- live spin-box edit.
withFakeFhu({
  loadOptions = function() return { accessMode = 'read-only', idleTimeoutMinutes = 9999 } end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.idleTimeoutMinutes == 120, 'a stored timeout above the range clamps down to 120')
end)
withFakeFhu({
  loadOptions = function() return { accessMode = 'read-only', idleTimeoutMinutes = 0 } end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.idleTimeoutMinutes == 5, 'a stored timeout below the range clamps up to 5')
end)

-- 6. Stored accessMode is neither valid value (hand-edited file) -- falls back to
-- read-only rather than passing through a value the dialog doesn't understand.
withFakeFhu({
  loadOptions = function() return { accessMode = 'sudo', idleTimeoutMinutes = 20 } end,
}, function(sessionSettings)
  local settings = sessionSettings.load()
  check(settings.accessMode == 'read-only', 'an invalid stored accessMode falls back to read-only')
  check(settings.idleTimeoutMinutes == 20, 'a valid stored idleTimeoutMinutes alongside an invalid accessMode still passes through')
end)

-- 7. save() forwards the settings and LOCAL_MACHINE scope to fhu.saveOptions.
withFakeFhu({
  saveOptions = function(settings, scope)
    check(settings.accessMode == 'read-write' and settings.idleTimeoutMinutes == 60,
      'save() forwards the given settings table to fhu.saveOptions unchanged')
    check(scope == 'LOCAL_MACHINE', 'save() calls fhu.saveOptions with LOCAL_MACHINE scope')
  end,
}, function(sessionSettings)
  sessionSettings.save({ accessMode = 'read-write', idleTimeoutMinutes = 60 })
end)

-- 8. save() swallows a fhu.saveOptions error rather than propagating it (e.g. a
-- permissions failure writing to the LOCAL_MACHINE plugin-data path).
withFakeFhu({
  saveOptions = function() error('simulated disk write failure') end,
}, function(sessionSettings)
  local ok = pcall(sessionSettings.save, { accessMode = 'read-only', idleTimeoutMinutes = 15 })
  check(ok, 'save() does not propagate a fhu.saveOptions error')
end)

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
