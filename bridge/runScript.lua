-- Executes a run_lua script inside the sandbox and returns a JSON-encoded response
-- string — either the script's own returned value, or a JSON error object on failure.
-- Ties sandbox.lua and jsonEncode.lua together; no socket/IUP/FH dependency of its own,
-- so (unlike bridge.fh_lua's dialog/socket plumbing) this is testable standalone.
--
-- accessMode is forwarded straight through to sandbox.build() — see CONTEXT.md "Access
-- mode" and sandbox.lua's own comment for what it does and doesn't unlock yet.

local sandbox = require('sandbox')
local json = require('jsonEncode')
local watchdog = require('watchdog')

local M = {}

function M.run(scriptText, accessMode)
  local envOk, env, tracker = pcall(sandbox.build, accessMode)
  if not envOk then
    return json.encode({ error = 'failed to build sandbox: ' .. tostring(env) })
  end

  local chunk, loadErr = load(scriptText, 'run_lua', 't', env)
  if not chunk then
    return json.encode({ error = 'script failed to compile: ' .. tostring(loadErr) })
  end

  watchdog.start()
  local ok, result = pcall(chunk)
  watchdog.stop()

  if not ok then
    -- Only a write-mode script that actually called a tracked write primitive before
    -- erroring (sandbox.lua's tracker) can have partially mutated the tree -- a script
    -- that errored before writing anything, or a compile/sandbox-build failure above, has
    -- nothing for FH's auto-undo to act on. When the tracker did fire, report the error
    -- as normal but also hand the caller the raw error, to be re-raised after sending in
    -- a way that actually ends the whole plugin -- the only way confirmed (docs/adr/0005)
    -- to give FH's own auto-undo a real chance to fire, unlike an error raised from
    -- inside a timer callback alone, which IUP swallows before it ever escapes the plugin.
    if accessMode == 'read-write' and tracker.wrote then
      return json.encode({ error = tostring(result), writeSessionRolledBack = true }), result
    end
    return json.encode({ error = tostring(result) })
  end

  local encodeOk, encoded = pcall(json.encode, result)
  if not encodeOk then
    return json.encode({ error = 'failed to encode result: ' .. tostring(encoded) })
  end

  return encoded
end

return M
