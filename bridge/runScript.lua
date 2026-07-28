-- Executes a run_lua script inside the sandbox and returns a JSON-encoded response
-- string — either the script's own returned value, or a JSON error object on failure.
-- Ties sandbox.lua and jsonEncode.lua together; no socket/IUP/FH dependency of its own,
-- so (unlike bridge.fh_lua's dialog/socket plumbing) this is testable standalone.

local sandbox = require('sandbox')
local json = require('jsonEncode')
local watchdog = require('watchdog')

local M = {}

function M.run(scriptText)
  local env = sandbox.build()
  local chunk, loadErr = load(scriptText, 'run_lua', 't', env)
  if not chunk then
    return json.encode({ error = 'script failed to compile: ' .. tostring(loadErr) })
  end

  watchdog.start()
  local ok, result = pcall(chunk)
  watchdog.stop()

  if not ok then
    return json.encode({ error = tostring(result) })
  end

  local encodeOk, encoded = pcall(json.encode, result)
  if not encodeOk then
    return json.encode({ error = 'failed to encode result: ' .. tostring(encoded) })
  end

  return encoded
end

return M
