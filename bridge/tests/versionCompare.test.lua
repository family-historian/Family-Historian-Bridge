-- Standalone tests for versionCompare.lua. Run with: lua bridge/tests/versionCompare.test.lua
-- Pure string/number comparison — no FH/socket/iup dependency.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'
local versionCompare = require('versionCompare')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

check(versionCompare.compare("0.4.0", "0.4.0") == "match", 'identical versions match')
check(versionCompare.compare("0.4.0", "0.4.1") == "warn", 'differing patch warns, does not block')
check(versionCompare.compare("0.4.0", "0.3.0") == "warn",
  'differing minor warns rather than blocks — pre-1.0, only the major (always 0 today) blocks (issue #45)')
check(versionCompare.compare("1.4.0", "2.0.0") == "block", 'differing major blocks')
check(versionCompare.compare("2.0.0", "1.9.9") == "block", 'differing major blocks regardless of which side is ahead')

check(versionCompare.compare("garbage", "0.4.0") == "warn",
  'an unparseable bridge version cannot be judged for severity, so it only warns')
check(versionCompare.compare("0.4.0", "garbage") == "warn",
  'an unparseable server version cannot be judged for severity, so it only warns')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
