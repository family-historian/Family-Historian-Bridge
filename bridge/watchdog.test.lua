-- Standalone tests for watchdog.lua. Run with: lua bridge/watchdog.test.lua
-- Pure Lua debug.sethook behavior — no FH dependency (the VM instruction-counting hook
-- works identically in a plain lua interpreter as it does inside FH's embedded Lua 5.3).

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '?.lua'
local watchdog = require('watchdog')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

-- A fast, bounded script must complete normally under the watchdog.
watchdog.start()
local ok1, result1 = pcall(function()
  local sum = 0
  for i = 1, 1000 do
    sum = sum + i
  end
  return sum
end)
watchdog.stop()
check(ok1 and result1 == 500500, 'bounded loop completes normally under the watchdog')

-- An unbounded loop must be aborted, not left to run forever.
local savedLimit = watchdog.INSTRUCTION_LIMIT
watchdog.INSTRUCTION_LIMIT = 10000 -- keep the test itself fast
watchdog.start()
local startClock = os.clock()
local ok2, err2 = pcall(function()
  while true do end
end)
local elapsed = os.clock() - startClock
watchdog.stop()
watchdog.INSTRUCTION_LIMIT = savedLimit

check(ok2 == false, 'infinite loop is aborted rather than hanging')
check(tostring(err2):find('instruction limit', 1, true) ~= nil, 'abort error names the instruction limit')
check(elapsed < 5, 'infinite loop is aborted quickly, not after a long wall-clock delay')

-- The hook must not leak into code running after stop() — a plain, unhooked script
-- after a previous watchdog run must not carry over any instruction count.
local ok3, result3 = pcall(function()
  local sum = 0
  for i = 1, 1000 do
    sum = sum + i
  end
  return sum
end)
check(ok3 and result3 == 500500, 'code after stop() runs unaffected by a prior watchdog run')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
