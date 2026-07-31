-- Standalone tests for runScript.lua. Run with: lua bridge/tests/runScript.test.lua
-- No FH/socket/iup dependency — exercises the full compile/execute/encode path a
-- run_lua request goes through, minus the socket framing (covered manually — see the
-- spec's Testing Decisions).

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'
local runScript = require('runScript')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

-- Sandbox construction is now fallible (it requires fhUtils, an FH-shipped module not
-- resolvable on this plain-lua test process's package.path) — a build failure must
-- surface as a JSON error, not crash the caller, same as a compile/runtime error does.
local buildFailure = runScript.run('return 1')
check(contains(buildFailure, '"error"') and contains(buildFailure, 'fhUtils'),
  'a sandbox construction failure (e.g. missing fhUtils) surfaces as a JSON error, not a crash')

-- Stub fhUtils via package.loaded so require('fhUtils') inside sandbox.build() resolves
-- without a real FH install, the same mechanism it'll use for real inside FH. Needed as a
-- prerequisite for every assertion below, not something under test itself. createIndi is
-- included so the send-then-rethrow tests further down have a real write path to call
-- through fhu (sandbox.lua's write tracker, issue #15, only fires on an actual call).
package.loaded.fhUtils = {
  records = function(tag) end,
  createIndi = function(sName) return 'indi:' .. tostring(sName) end,
}

check(runScript.run('return {ok=true}') == '{"ok":true}', 'trivial script returns encoded result')
check(runScript.run('return 42') == '42', 'script returning a bare number')
check(runScript.run('return nil') == 'null', 'script returning nil')
check(runScript.run('') == 'null', 'empty script (implicit nil return)')

local compileErr = runScript.run('this is not valid lua (')
check(contains(compileErr, '"error"') and contains(compileErr, 'failed to compile'), 'syntax error surfaces as a compile error')

local runtimeErr = runScript.run("error('boom')")
check(contains(runtimeErr, '"error"') and contains(runtimeErr, 'boom'), 'runtime error surfaces the error message')

local sandboxedAway = runScript.run("return os.execute('echo hi')")
check(contains(sandboxedAway, '"error"') and contains(sandboxedAway, 'nil value'),
  'calling a sandboxed-away function (os.execute) fails as calling nil, not silently succeeding')

local usesAllowed = runScript.run("return { doubled = 21 * 2, greeting = string.upper('hi') }")
check(contains(usesAllowed, '"doubled":42') and contains(usesAllowed, '"greeting":"HI"'),
  'script can use allowlisted math/string operations')

-- Integration-level watchdog check, using the real default INSTRUCTION_LIMIT (not
-- lowered, unlike watchdog.test.lua's own unit tests) — proves the wiring in runScript
-- itself, not just watchdog.lua in isolation. Bounded by this file's own wall-clock
-- check, plus the caller's process-level timeout as a hard backstop.
local watchdogStart = os.clock()
local runaway = runScript.run('while true do end')
local watchdogElapsed = os.clock() - watchdogStart
check(contains(runaway, '"error"') and contains(runaway, 'instruction limit'),
  'an infinite-loop script is aborted with a JSON error instead of hanging')
check(watchdogElapsed < 10, 'the watchdog aborts within a bounded wall-clock time')

-- A normal script run immediately after a watchdog abort must be unaffected — proves
-- the hook is cleared, not just that the aborted script itself terminated.
check(runScript.run('return 99') == '99', 'a normal script after a watchdog abort still runs correctly')

-- Access mode plumbing (issue #13): run() accepts and forwards an accessMode argument to
-- sandbox.build(). Read-write additionally grants the full write API (issue #14) — see
-- sandbox.test.lua for that allowlist's own present/absent assertions; here we only check
-- that both modes still behave identically for the basics every script can use.
check(runScript.run('return {ok=true}', 'read-write') == '{"ok":true}',
  'accessMode is accepted and forwarded without changing behavior (read-write)')
check(runScript.run('return {ok=true}', 'read-only') == '{"ok":true}',
  'accessMode is accepted and forwarded without changing behavior (explicit read-only)')
check(runScript.run("return os.execute('echo hi')", 'read-write'):find('"error"', 1, true) ~= nil,
  'a read-write run still cannot reach a permanently-excluded function (os.execute)')

-- Send-then-rethrow (issue #15, docs/adr/0005): a write-mode runtime error is still
-- reported to the caller as a normal JSON error response (the "send" half), but M.run's
-- second return value carries the original error so the caller can re-raise it after
-- sending -- giving FH's own auto-undo a chance to undo a partial write. This only
-- applies when the script actually wrote something before erroring (sandbox.lua's write
-- tracker) -- a write-mode script that errors without ever calling a write function has
-- nothing for FH's auto-undo to act on, so it behaves the same as read-only. Read-only
-- never has anything to undo at all, so it never returns a second value either way.
do
  local response, rethrow = runScript.run("fhu.createIndi('X'); error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error after a tracked write still sends a normal JSON error response')
  check(contains(response, '"writeSessionRolledBack":true'),
    'write-mode runtime error after a tracked write carries the writeSessionRolledBack hint')
  check(rethrow ~= nil, 'write-mode runtime error after a tracked write returns a non-nil second value to re-raise')
end

do
  local response, rethrow = runScript.run("error('boom')", 'read-write')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'write-mode runtime error with no prior write still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'write-mode runtime error with no prior write carries no writeSessionRolledBack hint (nothing was written)')
  check(rethrow == nil, 'write-mode runtime error with no prior write returns no second value (nothing to undo)')
end

do
  local response, rethrow = runScript.run("error('boom')", 'read-only')
  check(contains(response, '"error"') and contains(response, 'boom'),
    'read-only runtime error still sends a normal JSON error response')
  check(not contains(response, 'writeSessionRolledBack'),
    'read-only runtime error response carries no writeSessionRolledBack hint')
  check(rethrow == nil, 'read-only runtime error returns no second value (nothing to undo)')
end

do
  local response, rethrow = runScript.run("error('boom')")
  check(rethrow == nil, 'a runtime error with no accessMode argument (defaults read-only) returns no second value')
end

-- A compile error or sandbox-build failure means the script never executed at all, so
-- there's nothing a write could have partially done -- these never rethrow even in
-- read-write, unlike a runtime error from a script that started running.
do
  local response, rethrow = runScript.run('this is not valid lua (', 'read-write')
  check(contains(response, 'failed to compile'), 'a compile error is still reported as such in write mode')
  check(rethrow == nil, 'a compile error never rethrows, even in write mode (the script never ran)')
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
