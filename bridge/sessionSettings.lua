-- Persists the bridge Session's last-used Access mode, idle-timeout minutes, and Debug
-- logging toggle across plugin reloads, via FH's supported fhUtils settings-file API
-- (fhu.loadOptions/saveOptions, LOCAL_MACHINE scope) rather than a hand-rolled file format.
--
-- Distinct from bridge/sandbox.lua's block on fhu.saveOptions/loadOptions/resetOptions:
-- that block only applies to the sandboxed proxy handed to run_lua-submitted scripts, to
-- keep filesystem access out of Claude-authored scripts. This module calls the
-- real fhUtils directly, the same way sourceHelper.lua/familyHelper.lua call real fh*
-- globals, and is only ever invoked from bridgeSession.lua's own dialog code -- never
-- reachable from a run_lua script.
--
-- Pure enough to test standalone: fhUtils is FH-shipped, not bundled here, so tests stub
-- it via package.loaded.fhUtils before requiring this module (same pattern as
-- runScript.test.lua/sandbox.test.lua). require('fhUtils') is called lazily, inside
-- load()/save() rather than at module top-level, so a test process that never calls them
-- doesn't need the stub at all.

local timeoutDisplay = require('timeoutDisplay')

local M = {}

M.SCOPE = 'LOCAL_MACHINE'

-- Matches bridgeSession.lua's own hardcoded defaults (togReadOnly starts ON,
-- DEFAULT_IDLE_TIMEOUT_MINUTES = 15, Debug logging starts OFF) -- first-run/
-- missing-file behaviour must stay identical to what it was before this module existed. A
-- fresh table each call so a caller mutating the returned defaults can't corrupt a shared
-- one.
local function defaults()
  return { accessMode = "read-only", idleTimeoutMinutes = 15, debugLogging = false }
end

-- Loads the last-saved Access mode and idle-timeout minutes. Falls back silently to
-- defaults() on a missing file, a read error (fhu.loadOptions raising), or a malformed
-- value -- this is convenience/preference data, never worth surfacing an error to the user
-- over. idleTimeoutMinutes is always run back through timeoutDisplay.clampMinutes, so an
-- out-of-range stored value (a hand-edited file, a future range change) can never reach
-- the dialog; accessMode is validated against the only two real values for the same reason.
function M.load()
  local fhu = require("fhUtils")
  local ok, loaded = pcall(fhu.loadOptions, defaults(), M.SCOPE)
  if not ok or type(loaded) ~= "table" then
    loaded = defaults()
  end

  local accessMode = loaded.accessMode
  if accessMode ~= "read-only" and accessMode ~= "read-write" then
    accessMode = "read-only"
  end

  return {
    accessMode = accessMode,
    idleTimeoutMinutes = timeoutDisplay.clampMinutes(loaded.idleTimeoutMinutes),
    -- Anything other than a real boolean (missing field from a pre-#122 settings file,
    -- hand-edited junk) falls back to the off-by-default (defaults() above).
    debugLogging = loaded.debugLogging == true,
  }
end

-- Persists settings that already took effect for a Session that just started -- call only
-- after Start's own validation/clamp has succeeded, never on every field edit
-- and never for an aborted Start. A write failure (e.g. a permissions issue on the
-- LOCAL_MACHINE plugin-data path) is swallowed silently -- the worst case is next Start not
-- remembering these values, not a reason to interrupt this one.
function M.save(settings)
  local fhu = require("fhUtils")
  pcall(fhu.saveOptions, settings, M.SCOPE)
end

return M
