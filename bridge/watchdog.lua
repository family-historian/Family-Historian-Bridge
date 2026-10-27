-- Execution-instruction watchdog. FH's Lua is single-threaded and shares its thread with
-- FH itself (see the handover doc's findings) — an accidental infinite loop in a
-- Claude-authored script would otherwise hang FH with no recovery path, since even the
-- Bridge's own Stop button lives on that same thread. debug.sethook's count-mask fires
-- the hook every N VM instructions regardless of what the script is doing, so it
-- interrupts even a tight loop with no function calls of its own to intercept.
--
-- INSTRUCTION_LIMIT is a rough budget, not a precise cost model — tune it if real
-- queries (once the Bridge exposes FH's own read API) start tripping it legitimately.

local M = {}

M.INSTRUCTION_LIMIT = 50000000
local HOOK_GRANULARITY = 1000 -- how many VM instructions elapse between hook calls

-- Installs a count-hook that raises an error once INSTRUCTION_LIMIT VM instructions have
-- elapsed since this call. Must be paired with a stop() call after the protected
-- execution (success or failure) so the hook doesn't leak into unrelated code running on
-- the same thread afterward.
function M.start()
  local hookCalls = 0
  local maxHookCalls = math.floor(M.INSTRUCTION_LIMIT / HOOK_GRANULARITY)
  debug.sethook(function()
    hookCalls = hookCalls + 1
    if hookCalls > maxHookCalls then
      error('script aborted: exceeded the instruction limit (possible infinite loop)')
    end
  end, '', HOOK_GRANULARITY)
end

function M.stop()
  debug.sethook()
end

-- Runs fn(...) under pcall with a budget of its own, so a loop in fn fails fn alone. Needed
-- because start()'s hook, once past its limit, raises again every HOOK_GRANULARITY
-- instructions, so a caught overrun still sinks the rest of the script. Whatever hook was
-- installed is paused meanwhile and put back with its count unchanged.
-- budget = { remaining = <VM instructions> }: fn may use up to budget.remaining, and what it
-- uses (to the nearest HOOK_GRANULARITY) is taken off, so several calls can share one budget.
-- Returns pcall's results.
function M.isolated(budget, fn, ...)
  local hook, mask, count = debug.gethook()
  local hookCalls = 0
  local maxHookCalls = math.floor(budget.remaining / HOOK_GRANULARITY)
  debug.sethook(function()
    hookCalls = hookCalls + 1
    if hookCalls > maxHookCalls then
      -- Level 0: the position would be this file's, which in the bundled plugin is a long
      -- path into the .fh_lua and tells the user nothing about their module.
      error('aborted: exceeded the instruction limit (possible infinite loop)', 0)
    end
  end, '', HOOK_GRANULARITY)
  local results = table.pack(pcall(fn, ...))
  if hook then
    debug.sethook(hook, mask, count)
  else
    debug.sethook()
  end
  -- Only after the hook is swapped back: once fn has overrun, this hook raises on its next tick.
  budget.remaining = math.max(0, budget.remaining - hookCalls * HOOK_GRANULARITY)
  return table.unpack(results, 1, results.n)
end

return M
