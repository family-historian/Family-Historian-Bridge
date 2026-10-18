-- Standalone tests for utf8Fold.lua. Run with: lua bridge/tests/utf8Fold.test.lua

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
local fold = require('utf8Fold')

local failures = 0

local function assertEqual(actual, expected, label)
  if actual ~= expected then
    failures = failures + 1
    print(string.format('FAIL %s: expected %s, got %s', label, tostring(expected), tostring(actual)))
  else
    print(string.format('PASS %s', label))
  end
end

assertEqual(fold.lower('Marcin GĘBAL'), 'marcin gębal', 'Polish Ę')
assertEqual(fold.lower('SUWAŁA'), 'suwała', 'Polish Ł')
assertEqual(fold.lower('SMOLIŃSKI'), 'smoliński', 'Polish Ń')
assertEqual(fold.lower('ĄĆĘŁŃÓŚŹŻ'), 'ąćęłńóśźż', 'all Polish capitals')
assertEqual(fold.lower('ÄÖÜ ÉÈ ÀÇ'), 'äöü éè àç', 'German/French')
assertEqual(fold.lower('×'), '×', 'multiplication sign untouched')
assertEqual(fold.lower('ČŘŽ ŠĎŤŇ'), 'čřž šďťň', 'Czech')
assertEqual(fold.lower('ĹĽŹŻŽ'), 'ĺľźżž', 'odd-upper Latin Extended-A ranges')
assertEqual(fold.lower('ẠỆ'), 'ạệ', 'Vietnamese')
assertEqual(fold.lower('ΑΒΓ ΆΈΉ'), 'αβγ άέή', 'Greek')
assertEqual(fold.lower('ПРИВЕТ Ёж'), 'привет ёж', 'Cyrillic')
assertEqual(fold.lower('already lower ęł'), 'already lower ęł', 'already lowercase')
assertEqual(fold.lower('日本語'), '日本語', 'unmapped scripts pass through')
assertEqual(fold.lower('A\x80B\xC4'), 'a\x80b\xC4', 'invalid bytes pass through')
assertEqual(fold.lower(''), '', 'empty')
assertEqual(fold.lower('Gębal') == fold.lower('GĘBAL'), true, 'query matches NAME:FULL')
assertEqual(fold.lower('Gembal') == fold.lower('GĘBAL'), false, 'Gembal does not match GĘBAL')

if failures > 0 then
  print(failures .. ' failure(s)')
  os.exit(1)
end
print('All tests passed')
