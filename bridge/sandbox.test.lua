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

-- FH installs its read primitives as globals in the real host process; stand in with
-- dummies here so the test can verify sandbox.build() wires them through by reference,
-- without needing a real FH.
fhNewItemPtr = function() end
fhGetItemText = function() end
fhGetDisplayText = function() end
fhGetContextInfo = function() end
fhGetAppVersion = function() end
fhGetTag = function() end
fhCallBuiltInFunction = function() end
fhGetValueAsLink = function() end

-- fhUtils ships with FH and isn't resolvable via package.path in this plain-lua test
-- process; register a stub as a real Lua module so require('fhUtils') inside
-- sandbox.build() resolves it via package.loaded, the same mechanism it'll use for real
-- inside FH.
local fakeFhu = { records = function(tag) end }
package.loaded.fhUtils = fakeFhu

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
check(env.type == type, 'type present')
check(type(env.os) == 'table' and type(env.os.date) == 'function', 'os.date present')

-- FH's read-side primitives (raw record-iteration/field-read functions installed as
-- globals by FH's own Lua host) are wired through by reference, not reimplemented.
-- MoveToFirstRecord/MoveNext/IsNull are deliberately NOT wired here even though an
-- earlier ticket's allowlist listed them: FH exposes them only as colon-methods on the
-- pointer object fhNewItemPtr() returns (ptr:MoveToFirstRecord(tag)), never as free
-- globals, so copying a same-named global into env would only ever copy nil. Confirmed
-- against a real FH project — see #7.
check(env.fhNewItemPtr == fhNewItemPtr, 'fhNewItemPtr present')
check(env.fhGetItemText == fhGetItemText, 'fhGetItemText present')
check(env.fhGetDisplayText == fhGetDisplayText, 'fhGetDisplayText present')
check(env.fhGetContextInfo == fhGetContextInfo, 'fhGetContextInfo present')
check(env.fhGetAppVersion == fhGetAppVersion, 'fhGetAppVersion present')
check(env.fhGetTag == fhGetTag, 'fhGetTag present (needed to tell Facts apart from FAMC/FAMS/NAME/NOTE/OBJE children when walking an Individual\'s child items)')
check(env.fhCallBuiltInFunction == fhCallBuiltInFunction, 'fhCallBuiltInFunction present (needed to call FH\'s built-in report functions, e.g. FactSentence, Lifedates, from a script)')
check(env.fhGetValueAsLink == fhGetValueAsLink, 'fhGetValueAsLink present (needed to resolve a FAMS/FAMC link field to the linked Family/Individual record pointer)')

-- fhUtils (require('fhUtils')) is present, including its records(tag) iteration helper.
check(env.fhu == fakeFhu, 'fhu (require("fhUtils")) present')
check(type(env.fhu.records) == 'function', 'fhu.records present')

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
