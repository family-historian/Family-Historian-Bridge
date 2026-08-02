-- Executes a run_lua script inside the sandbox and returns a JSON-encoded response
-- string — either the script's own returned value, or a JSON error object on failure.
-- Ties sandbox.lua and jsonEncode.lua together; no socket/IUP/FH dependency of its own,
-- so (unlike bridge.fh_lua's dialog/socket plumbing) this is testable standalone.
--
-- accessMode defaults to "read-only" here (mirroring sandbox.build()'s own default) since
-- M.run needs a resolved value for the pre-scan below before sandbox.build ever runs; the
-- resolved value is then forwarded straight through to sandbox.build() as before — see
-- CONTEXT.md "Access mode" and sandbox.lua's own comment for what it does and doesn't
-- unlock yet.

local sandbox = require('sandbox')
local json = require('jsonEncode')
local watchdog = require('watchdog')

local M = {}

-- Word-boundary match, not naive substring search: 'createIndi' must not match inside a
-- longer identifier like 'createIndiOld'. Lua's %f frontier pattern treats %w_ as "word"
-- characters and anything else (including string start/end) as a boundary, which is
-- exactly the identifier-boundary semantics an unquoted Lua call site has.
local function containsName(scriptText, name)
  return scriptText:find('%f[%w_]' .. name .. '%f[^%w_]') ~= nil
end

-- Static pre-scan (issue #43, docs/adr/0012): a best-effort heuristic over the script's
-- raw source text, not a security boundary -- the runtime backstop in M.run below is what
-- actually guarantees no write escapes detection. Runs before load() is even attempted, so
-- it catches a violation even in a script that wouldn't otherwise compile.
local function preScanViolation(scriptText, accessMode)
  local writeName = nil
  for _, name in ipairs(sandbox.WRITE_NAMES) do
    if containsName(scriptText, name) then
      writeName = name
      break
    end
  end
  if not writeName then
    return nil
  end

  if accessMode == 'read-only' then
    return 'script calls ' .. writeName .. ', a write-capable function, but the bridge is in Read-only mode'
  end

  if accessMode == 'read-write' and not containsName(scriptText, 'logActivity') then
    return 'script calls ' .. writeName .. ', a write-capable function, but never calls fhBridge.logActivity to log the write'
  end

  return nil
end

-- Shared shape for a write-mode response that FH's own auto-undo should act on (docs/adr/0005):
-- a JSON error carrying writeSessionRolledBack: true, plus the original error/message as a
-- second return value the caller re-raises after sending. Both the write-mode-runtime-error
-- path and the write-then-log runtime backstop (issue #43, docs/adr/0012) build this same
-- shape, so it's constructed in one place rather than two.
local function rollbackResponse(message)
  return json.encode({ error = tostring(message), writeSessionRolledBack = true }), message
end

function M.run(scriptText, accessMode)
  accessMode = accessMode or 'read-only'

  local violation = preScanViolation(scriptText, accessMode)
  if violation then
    return json.encode({ error = violation })
  end

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

  if ok and accessMode == 'read-write' and tracker.wrote and not tracker.logged then
    -- Runtime backstop (issue #43, docs/adr/0012): the ground truth for what the pre-scan
    -- can't see -- text presence isn't proof of execution (dead code, indirection, partial
    -- logging). Same response shape as the write-mode-runtime-error path below, feeding
    -- the same ADR 0005 rethrow/auto-undo mechanism, since an unlogged write is exactly as
    -- much a problem to roll back as a script that errored mid-write.
    return rollbackResponse('script wrote to the tree without logging the activity via fhBridge.logActivity')
  end

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
      return rollbackResponse(result)
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
