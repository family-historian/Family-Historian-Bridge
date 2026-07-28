-- Builds the allowlist _ENV table a run_lua script executes inside.
-- Allowlist, not denylist: start from nothing, add back only what's explicitly safe.
-- Anything not added here is simply absent to the script (nil), regardless of what
-- exists in the real global environment. See CONTEXT.md "Sandbox" and
-- docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
--
-- This ticket populates only the basic-Lua subset. FH's own read API (fhNewItemPtr,
-- fhGetItemText, etc.) and fhUtils are added by a later ticket (Bridge: real FH read
-- allowlist) once the sandbox mechanism itself is proven.

local M = {}

function M.build()
  local env = {}

  env.string = string
  env.table = table
  env.math = math
  env.pairs = pairs
  env.ipairs = ipairs
  env.tostring = tostring
  env.tonumber = tonumber
  env.pcall = pcall
  env.error = error
  env.os = { date = os.date }

  return env
end

return M
