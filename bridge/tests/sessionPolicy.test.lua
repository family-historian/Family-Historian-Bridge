-- Standalone tests for sessionPolicy.lua. Run with: lua bridge/tests/sessionPolicy.test.lua
-- Pure decisions -- no FH/socket/iup dependency.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
local sessionPolicy = require('sessionPolicy')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

-- statusColorForMode

check(sessionPolicy.statusColorForMode('read-write') == sessionPolicy.STATUS_COLOR_READWRITE,
  'read-write mode gets the read-write colour')
check(sessionPolicy.statusColorForMode('read-only') == sessionPolicy.STATUS_COLOR_READONLY,
  'read-only mode gets the read-only colour')
check(sessionPolicy.statusColorForMode(nil) == sessionPolicy.STATUS_COLOR_READONLY,
  'an unrecognized/missing mode falls back to the read-only colour, not read-write')

check(sessionPolicy.STATUS_COLOR_STOPPED == '224 224 224', 'STATUS_COLOR_STOPPED is the documented grey')
check(sessionPolicy.STATUS_COLOR_READONLY == '212 237 218', 'STATUS_COLOR_READONLY is the documented green')
check(sessionPolicy.STATUS_COLOR_READWRITE == '255 243 205', 'STATUS_COLOR_READWRITE is the documented amber')
check(sessionPolicy.STATUS_COLOR_ERROR == '248 215 218', 'STATUS_COLOR_ERROR is the documented red')

-- shouldAutoStopForIdle (issue #34)

check(sessionPolicy.shouldAutoStopForIdle(nil, 900, 1000) == false,
  'no auto-stop when no Session is running (lastActivityTime nil)')
check(sessionPolicy.shouldAutoStopForIdle(100, 900, 500) == false,
  'no auto-stop while comfortably under the idle timeout')
check(sessionPolicy.shouldAutoStopForIdle(100, 900, 1000) == false,
  'no auto-stop at exactly the idle timeout boundary (strictly greater-than, not >=)')
check(sessionPolicy.shouldAutoStopForIdle(100, 900, 1001) == true,
  'auto-stop fires the instant elapsed time exceeds the idle timeout')

-- shouldConfirmBeforeExit (ADR 0020)

check(sessionPolicy.shouldConfirmBeforeExit(false, 100, 105, 10) == false,
  'no confirm prompt when no Session is running, regardless of lastRequestHandledTime')
check(sessionPolicy.shouldConfirmBeforeExit(true, nil, 105, 10) == false,
  'no confirm prompt when no request has been handled yet (Start-then-immediately-Exit)')
check(sessionPolicy.shouldConfirmBeforeExit(true, 100, 105, 10) == true,
  'confirm prompt fires when a Session is running and the last request was handled recently')
check(sessionPolicy.shouldConfirmBeforeExit(true, 100, 110, 10) == false,
  'no confirm prompt at exactly the confirm-window boundary (strictly less-than, not <=)')
check(sessionPolicy.shouldConfirmBeforeExit(true, 100, 111, 10) == false,
  'no confirm prompt once the last request is older than the confirm window')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
