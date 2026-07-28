-- Builds the allowlist _ENV table a run_lua script executes inside.
-- Allowlist, not denylist: start from nothing, add back only what's explicitly safe.
-- Anything not added here is simply absent to the script (nil), regardless of what
-- exists in the real global environment. See CONTEXT.md "Sandbox" and
-- docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
--
-- Read-only allowlist: basic Lua, plus FH's read-side primitives and fhUtils. Both are
-- wired through by reference from the real global environment, not reimplemented —
-- FH's own Lua host installs the primitives as globals, and fhUtils ships with every FH
-- install (require('fhUtils'), not bundled by this project). No write-side fh...
-- functions are populated here yet (Stage 1 is read-only — see CONTEXT.md "Access mode").

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

  env.fhNewItemPtr = fhNewItemPtr
  env.MoveToFirstRecord = MoveToFirstRecord
  env.MoveNext = MoveNext
  env.IsNull = IsNull
  env.fhGetItemText = fhGetItemText
  env.fhGetDisplayText = fhGetDisplayText
  env.fhGetContextInfo = fhGetContextInfo
  env.fhGetAppVersion = fhGetAppVersion

  env.fhu = require('fhUtils')

  return env
end

return M
