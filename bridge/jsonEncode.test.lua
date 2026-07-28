-- Standalone tests for jsonEncode.lua. Run with: lua bridge/jsonEncode.test.lua
-- No FH/socket/iup dependency — this is the one piece of the Bridge pure enough to
-- automate outside FH itself (see the spec's Testing Decisions).

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '?.lua'
local json = require('jsonEncode')

local failures = 0

local function assertEqual(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print(string.format('FAIL %s: expected %s, got %s', label, tostring(expected), tostring(actual)))
  else
    print(string.format('PASS %s', label))
  end
end

assertEqual(json.encode(nil), 'null', 'nil -> null')
assertEqual(json.encode(true), 'true', 'true -> true')
assertEqual(json.encode(false), 'false', 'false -> false')
assertEqual(json.encode(42), '42', 'integer -> 42')
assertEqual(json.encode(3.5), '3.5', 'float -> 3.5')
assertEqual(json.encode('hello'), '"hello"', 'plain string')
assertEqual(json.encode('a "quote" and \\backslash\\'), '"a \\"quote\\" and \\\\backslash\\\\"', 'quote/backslash escaping')
assertEqual(json.encode('line1\nline2\ttab'), '"line1\\nline2\\ttab"', 'newline/tab escaping')
assertEqual(json.encode({}), '{}', 'empty table -> empty object')
assertEqual(json.encode({ 'a', 'b', 'c' }), '["a","b","c"]', 'array of strings')
assertEqual(json.encode({ 1, 2, 3 }), '[1,2,3]', 'array of numbers')
assertEqual(json.encode({ { name = 'Ian' }, { name = 'Munro' } }), '[{"name":"Ian"},{"name":"Munro"}]', 'array of objects')

-- Single-key objects have deterministic output; multi-key object order is not
-- guaranteed by Lua's pairs(), so check structurally instead of exact string match.
assertEqual(json.encode({ ok = true }), '{"ok":true}', 'single-key object')

local multiKey = json.encode({ name = 'Ian', count = 3 })
local hasName = multiKey:find('"name":"Ian"', 1, true) ~= nil
local hasCount = multiKey:find('"count":3', 1, true) ~= nil
local looksLikeObject = multiKey:match('^{.*}$') ~= nil
assertEqual(hasName and hasCount and looksLikeObject, true, 'multi-key object contains both fields')

local ok, err = pcall(json.encode, 0 / 0)
assertEqual(ok, false, 'NaN raises an error rather than emitting invalid JSON')

local ok2, err2 = pcall(json.encode, 1 / 0)
assertEqual(ok2, false, 'Infinity raises an error rather than emitting invalid JSON')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
