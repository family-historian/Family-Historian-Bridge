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
-- prerequisite for every assertion below, not something under test itself.
package.loaded.fhUtils = { records = function(tag) end }

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

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
