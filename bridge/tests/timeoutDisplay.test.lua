-- Standalone tests for timeoutDisplay.lua. Run with: lua bridge/tests/timeoutDisplay.test.lua
-- Pure formatting — no FH/socket/iup dependency.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
local timeoutDisplay = require('timeoutDisplay')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

check(timeoutDisplay.formatSecondsRemaining(0) == '0:00', 'zero seconds formats as 0:00')
check(timeoutDisplay.formatSecondsRemaining(5) == '0:05', 'sub-minute seconds are zero-padded')
check(timeoutDisplay.formatSecondsRemaining(59) == '0:59', 'fifty-nine seconds formats as 0:59')
check(timeoutDisplay.formatSecondsRemaining(60) == '1:00', 'sixty seconds rolls over to 1:00')
check(timeoutDisplay.formatSecondsRemaining(125) == '2:05', 'minutes and seconds both render (125s = 2:05)')
check(timeoutDisplay.formatSecondsRemaining(7200) == '120:00', 'the full 120-minute ceiling formats with an unpadded minutes part')
check(timeoutDisplay.formatSecondsRemaining(-5) == '0:00', 'a negative (stale) reading clamps to 0:00 rather than showing a negative countdown')
check(timeoutDisplay.formatSecondsRemaining(1.9) == '0:01', 'a fractional second reading floors rather than rounds')

check(timeoutDisplay.minutesToSeconds(5) == 300, 'minutesToSeconds converts the 5-minute floor')
check(timeoutDisplay.minutesToSeconds(120) == 7200, 'minutesToSeconds converts the 120-minute ceiling')

check(timeoutDisplay.MIN_MINUTES == 5, 'MIN_MINUTES matches issue #34\'s stated floor')
check(timeoutDisplay.MAX_MINUTES == 120, 'MAX_MINUTES matches issue #34\'s stated ceiling')

check(timeoutDisplay.clampMinutes(30) == 30, 'an in-range value passes through unchanged')
check(timeoutDisplay.clampMinutes(1) == 5, 'a below-range value clamps up to the 5-minute floor')
check(timeoutDisplay.clampMinutes(500) == 120, 'an above-range value clamps down to the 120-minute ceiling')
check(timeoutDisplay.clampMinutes(12.9) == 12, 'a fractional value floors before clamping')
check(timeoutDisplay.clampMinutes(nil) == 5, 'a missing value falls back to the 5-minute floor rather than erroring')
check(timeoutDisplay.clampMinutes('not a number') == 5, 'a non-numeric value falls back to the 5-minute floor rather than erroring')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
