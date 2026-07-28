-- Standalone tests for runScript.lua. Run with: lua bridge/runScript.test.lua
-- No FH/socket/iup dependency — exercises the full compile/execute/encode path a
-- run_lua request goes through, minus the socket framing (covered manually — see the
-- spec's Testing Decisions).

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '?.lua'
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

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
