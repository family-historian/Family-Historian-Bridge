-- Compares a Bridge version string against a server version string to decide how severe a
-- mismatch is. Pure string/number logic, no FH/socket/iup dependency, so (unlike
-- bridge.fh_lua's dialog/timer code) this is testable standalone.

local M = {}

-- Extracts the leading major-version number from an "x.y.z" string, or nil if it doesn't
-- start with digits followed by a dot (malformed/unparseable).
local function majorOf(version)
  local major = version:match("^(%d+)%.")
  return major and tonumber(major) or nil
end

-- Returns "match", "warn", or "block":
--   match — identical version strings.
--   block — major versions differ — inert while this project is pre-1.0 (major is 0 on
--           both sides today), by design; revisit once it cuts 1.0.
--   warn  — anything else that differs, including either version being unparseable
--           (can't judge severity, so default to the safe/non-blocking outcome).
function M.compare(bridgeVersion, serverVersion)
  if bridgeVersion == serverVersion then
    return "match"
  end

  local bridgeMajor = majorOf(bridgeVersion)
  local serverMajor = majorOf(serverVersion)
  if bridgeMajor == nil or serverMajor == nil then
    return "warn"
  end

  if bridgeMajor ~= serverMajor then
    return "block"
  end

  return "warn"
end

return M
