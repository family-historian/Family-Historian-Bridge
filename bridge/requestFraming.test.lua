-- Standalone tests for requestFraming.lua. Run with: lua bridge/requestFraming.test.lua
-- Pure string parsing — no FH/socket/iup dependency.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '?.lua'
local requestFraming = require('requestFraming')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

check(requestFraming.parse("STOP").kind == "stop", 'STOP parses as a stop request')
check(requestFraming.parse("stop").kind == "stop", 'STOP is matched case-insensitively, same as bridge.fh_lua\'s prior inline check')

local lua = requestFraming.parse("LUA 42")
check(lua ~= nil, 'LUA <n> parses')
check(lua.kind == "lua", 'LUA <n> has kind "lua"')
check(lua.byteCount == 42, 'LUA <n> carries the byte count as a number')
check(lua.forceReadOnly == false, 'LUA <n> does not force read-only — uses the Session\'s own Access mode')

local luaRo = requestFraming.parse("LUA_RO 7")
check(luaRo ~= nil, 'LUA_RO <n> parses')
check(luaRo.kind == "lua", 'LUA_RO <n> has kind "lua"')
check(luaRo.byteCount == 7, 'LUA_RO <n> carries the byte count as a number')
check(luaRo.forceReadOnly == true, 'LUA_RO <n> forces read-only regardless of the Session\'s Access mode (issue #16)')

check(requestFraming.resolveAccessMode({ forceReadOnly = true }, "read-write") == "read-only",
  'resolveAccessMode forces read-only even when the Session\'s own Access mode is read-write (issue #16)')
check(requestFraming.resolveAccessMode({ forceReadOnly = true }, "read-only") == "read-only",
  'resolveAccessMode is a no-op when the Session is already read-only')
check(requestFraming.resolveAccessMode({ forceReadOnly = false }, "read-write") == "read-write",
  'resolveAccessMode uses the Session\'s own Access mode when not forced (plain LUA <n>, e.g. run_lua)')
check(requestFraming.resolveAccessMode({ forceReadOnly = false }, "read-only") == "read-only",
  'resolveAccessMode uses the Session\'s own Access mode when not forced (read-only Session)')

check(requestFraming.parse("") == nil, 'empty header is malformed')
check(requestFraming.parse("LUA") == nil, 'LUA with no byte count is malformed')
check(requestFraming.parse("LUA -1") == nil, 'LUA with a negative byte count is malformed')
check(requestFraming.parse("LUA_RO") == nil, 'LUA_RO with no byte count is malformed')
check(requestFraming.parse("GARBAGE 1") == nil, 'an unrecognized verb is malformed')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
