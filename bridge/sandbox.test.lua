-- Standalone tests for sandbox.lua. Run with: lua bridge/sandbox.test.lua
-- Pure table inspection — no FH/socket/iup dependency. Verifies both halves of the
-- allowlist: the basics are present, and nothing dangerous leaked in by accident.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '?.lua'
local sandbox = require('sandbox')

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local env = sandbox.build()

-- Allowed basics are present and are the real thing (not stand-ins).
check(env.string == string, 'string library present')
check(env.table == table, 'table library present')
check(env.math == math, 'math library present')
check(env.pairs == pairs, 'pairs present')
check(env.ipairs == ipairs, 'ipairs present')
check(env.tostring == tostring, 'tostring present')
check(env.tonumber == tonumber, 'tonumber present')
check(env.pcall == pcall, 'pcall present')
check(env.error == error, 'error present (pure control flow, same risk profile as pcall)')
check(type(env.os) == 'table' and type(env.os.date) == 'function', 'os.date present')

-- Dangerous globals must be absent — the whole point of an allowlist sandbox.
check(env.os.execute == nil, 'os.execute absent')
check(env.os.remove == nil, 'os.remove absent')
check(env.os.exit == nil, 'os.exit absent')
check(env.os.rename == nil, 'os.rename absent')
check(env.io == nil, 'io library absent')
check(env.require == nil, 'require absent')
check(env.dofile == nil, 'dofile absent')
check(env.loadfile == nil, 'loadfile absent')
check(env.load == nil, 'load absent (script cannot load further arbitrary code)')
check(env.rawset == nil, 'rawset absent')
check(env.rawget == nil, 'rawget absent')
check(env.setmetatable == nil, 'setmetatable absent')
check(env.getmetatable == nil, 'getmetatable absent')
check(env.debug == nil, 'debug library absent')
check(env.package == nil, 'package library absent')
check(env._G == nil, '_G absent (no back-door to the real global table)')

-- Two separate build() calls must not share a mutable env table.
local env2 = sandbox.build()
env2.string = nil
check(env.string == string, 'each build() call returns an independent env table')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
