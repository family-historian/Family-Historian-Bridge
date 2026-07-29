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

-- Batch-populated read-only surface (2026-07-29 grilling session) — same stand-in
-- treatment as above.
fhNewAge = function() end
fhNewDate = function() end
fhNewDatePt = function() end
fhNewRichText = function() end
fhNewSection = function() end
fhGetCurrentRecordSel = function() end
fhGetCurrentPropertyBoxRecord = function() end
fhGetDataClass = function() end
fhGetDataList = function() end
fhGetFactTypeInfo = function() end
fhGetGedcomInfo = function() end
fhGetItemPtr = function() end
fhGetLabelledText = function() end
fhGetQualifiedRecordId = function() end
fhGetRecordId = function() end
fhGetRecordTypeCount = function() end
fhGetRecordTypeTag = function() end
fhGetTypeInfo = function() end
fhGetValueAsAge = function() end
fhGetValueAsDate = function() end
fhGetValueAsInteger = function() end
fhGetValueAsRichText = function() end
fhGetValueAsText = function() end
fhGetValueType = function() end
fhGetMetafieldDefinition = function() end
fhGetMetafieldShortcut = function() end
fhGetMetafieldType = function() end
fhHasChildItem = function() end
fhHasNextSibItem = function() end
fhHasParentItem = function() end
fhHasPrevSibItem = function() end
fhIsAttribute = function() end
fhIsEvent = function() end
fhIsFact = function() end
fhIsHidden = function() end
fhIsUDF = function() end
fhIsValidDataRef = function() end
fhConvertANSItoUTF8 = function() end
fhConvertUTF8toANSI = function() end
fhGetStringEncoding = function() end
fhIsConversionLossFlagSet = function() end
fhIndGetFactList = function() end
fhIndGetName = function() end
fhSrcIsAutoTitleEnabled = function() end
fhGetNarrSentence = function() end
fhGetNarrSentenceTemplate = function() end
fhFtfEncode = function() end
fhFtfParamEncode = function() end
fhGetNamedList = function() end
fhGetNamedListByIndex = function() end
fhGetNamedListCount = function() end
fhBeginsWithVowel = function() end

-- Excluded functions: stubbed as if FH provides them (it does), so asserting env.fhX ==
-- nil below actually proves sandbox.build() declines to wire them through, rather than
-- passing vacuously because the global itself doesn't exist in this plain-lua process.
fhCreateItem = function() end
fhDeleteItem = function() end
fhMoveItemAfter = function() end
fhMoveItemBefore = function() end
fhSrcEnableAutoTitle = function() end
fhGetFactTag = function() end
fhGetFlagTag = function() end
fhSetStringEncoding = function() end
fhSetConversionLossFlag = function() end
fhShellExecute = function() end
fhLoadTextFile = function() end
fhSaveTextFile = function() end
fhGetIniFileValue = function() end
fhSetIniFileValue = function() end
fhGetClipboardData = function() end
fhSleep = function() end
fhOverridePreference = function() end
fhMessageBox = function() end
fhDisplayRichTextBox = function() end
fhPromptUserForDate = function() end
fhPromptUserForRecordSel = function() end
fhPromptUserForRichText = function() end
fhUpdateDisplay = function() end
fhOutputResultSetColumn = function() end
fhOutputResultSetTitles = function() end
fhGetValueAsBlob = function() end
fhSetValueAsBlob = function() end
fhGetPluginDataFileName = function() end
fhExhibitResponsiveness = function() end
fhInitialise = function() end

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

-- Batch-populated read-only surface: every remaining side-effect-free FH function,
-- wired through by reference exactly like the entries above.
check(env.fhNewAge == fhNewAge, 'fhNewAge present')
check(env.fhNewDate == fhNewDate, 'fhNewDate present')
check(env.fhNewDatePt == fhNewDatePt, 'fhNewDatePt present')
check(env.fhNewRichText == fhNewRichText, 'fhNewRichText present')
check(env.fhNewSection == fhNewSection, 'fhNewSection present')
check(env.fhGetCurrentRecordSel == fhGetCurrentRecordSel, 'fhGetCurrentRecordSel present')
check(env.fhGetCurrentPropertyBoxRecord == fhGetCurrentPropertyBoxRecord, 'fhGetCurrentPropertyBoxRecord present')
check(env.fhGetDataClass == fhGetDataClass, 'fhGetDataClass present')
check(env.fhGetDataList == fhGetDataList, 'fhGetDataList present')
check(env.fhGetFactTypeInfo == fhGetFactTypeInfo, 'fhGetFactTypeInfo present')
check(env.fhGetGedcomInfo == fhGetGedcomInfo, 'fhGetGedcomInfo present')
check(env.fhGetItemPtr == fhGetItemPtr, 'fhGetItemPtr present')
check(env.fhGetLabelledText == fhGetLabelledText, 'fhGetLabelledText present')
check(env.fhGetQualifiedRecordId == fhGetQualifiedRecordId, 'fhGetQualifiedRecordId present')
check(env.fhGetRecordId == fhGetRecordId, 'fhGetRecordId present')
check(env.fhGetRecordTypeCount == fhGetRecordTypeCount, 'fhGetRecordTypeCount present')
check(env.fhGetRecordTypeTag == fhGetRecordTypeTag, 'fhGetRecordTypeTag present')
check(env.fhGetTypeInfo == fhGetTypeInfo, 'fhGetTypeInfo present')
check(env.fhGetValueAsAge == fhGetValueAsAge, 'fhGetValueAsAge present')
check(env.fhGetValueAsDate == fhGetValueAsDate, 'fhGetValueAsDate present')
check(env.fhGetValueAsInteger == fhGetValueAsInteger, 'fhGetValueAsInteger present')
check(env.fhGetValueAsRichText == fhGetValueAsRichText, 'fhGetValueAsRichText present')
check(env.fhGetValueAsText == fhGetValueAsText, 'fhGetValueAsText present')
check(env.fhGetValueType == fhGetValueType, 'fhGetValueType present')
check(env.fhGetMetafieldDefinition == fhGetMetafieldDefinition, 'fhGetMetafieldDefinition present')
check(env.fhGetMetafieldShortcut == fhGetMetafieldShortcut, 'fhGetMetafieldShortcut present')
check(env.fhGetMetafieldType == fhGetMetafieldType, 'fhGetMetafieldType present')
check(env.fhHasChildItem == fhHasChildItem, 'fhHasChildItem present')
check(env.fhHasNextSibItem == fhHasNextSibItem, 'fhHasNextSibItem present')
check(env.fhHasParentItem == fhHasParentItem, 'fhHasParentItem present')
check(env.fhHasPrevSibItem == fhHasPrevSibItem, 'fhHasPrevSibItem present')
check(env.fhIsAttribute == fhIsAttribute, 'fhIsAttribute present')
check(env.fhIsEvent == fhIsEvent, 'fhIsEvent present')
check(env.fhIsFact == fhIsFact, 'fhIsFact present')
check(env.fhIsHidden == fhIsHidden, 'fhIsHidden present')
check(env.fhIsUDF == fhIsUDF, 'fhIsUDF present')
check(env.fhIsValidDataRef == fhIsValidDataRef, 'fhIsValidDataRef present')
check(env.fhConvertANSItoUTF8 == fhConvertANSItoUTF8, 'fhConvertANSItoUTF8 present')
check(env.fhConvertUTF8toANSI == fhConvertUTF8toANSI, 'fhConvertUTF8toANSI present')
check(env.fhGetStringEncoding == fhGetStringEncoding, 'fhGetStringEncoding present')
check(env.fhIsConversionLossFlagSet == fhIsConversionLossFlagSet, 'fhIsConversionLossFlagSet present')
check(env.fhIndGetFactList == fhIndGetFactList, 'fhIndGetFactList present')
check(env.fhIndGetName == fhIndGetName, 'fhIndGetName present')
check(env.fhSrcIsAutoTitleEnabled == fhSrcIsAutoTitleEnabled, 'fhSrcIsAutoTitleEnabled present')
check(env.fhGetNarrSentence == fhGetNarrSentence, 'fhGetNarrSentence present')
check(env.fhGetNarrSentenceTemplate == fhGetNarrSentenceTemplate, 'fhGetNarrSentenceTemplate present')
check(env.fhFtfEncode == fhFtfEncode, 'fhFtfEncode present')
check(env.fhFtfParamEncode == fhFtfParamEncode, 'fhFtfParamEncode present')
check(env.fhGetNamedList == fhGetNamedList, 'fhGetNamedList present')
check(env.fhGetNamedListByIndex == fhGetNamedListByIndex, 'fhGetNamedListByIndex present')
check(env.fhGetNamedListCount == fhGetNamedListCount, 'fhGetNamedListCount present')
check(env.fhBeginsWithVowel == fhBeginsWithVowel, 'fhBeginsWithVowel present')

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

-- Excluded FH functions must be absent too, despite being stubbed as available globals
-- above (real FH provides all of these) — read/read-write sandbox policy agreed
-- 2026-07-29, see issue #9 and sandbox.lua's own comment for the full rationale.
check(env.fhCreateItem == nil, 'fhCreateItem absent (mutates the GEDCOM tree, not fhSet-named but write nonetheless — reserved for Read-write)')
check(env.fhDeleteItem == nil, 'fhDeleteItem absent (mutates the GEDCOM tree — reserved for Read-write)')
check(env.fhMoveItemAfter == nil, 'fhMoveItemAfter absent (mutates the GEDCOM tree — reserved for Read-write)')
check(env.fhMoveItemBefore == nil, 'fhMoveItemBefore absent (mutates the GEDCOM tree — reserved for Read-write)')
check(env.fhSrcEnableAutoTitle == nil, 'fhSrcEnableAutoTitle absent (mutates a Source record\'s flag — reserved for Read-write)')
check(env.fhGetFactTag == nil, 'fhGetFactTag absent (can create a new fact-type definition via bCreateIfNone — excluded entirely rather than wrapped, to keep the allowlist a flat reference-through list)')
check(env.fhGetFlagTag == nil, 'fhGetFlagTag absent (same bCreateIfNone concern as fhGetFactTag)')
check(env.fhSetStringEncoding == nil, 'fhSetStringEncoding absent (mutates app/session state, not tree data — permanently excluded, not a Read-write concern)')
check(env.fhSetConversionLossFlag == nil, 'fhSetConversionLossFlag absent (same app-state concern as fhSetStringEncoding)')
check(env.fhShellExecute == nil, 'fhShellExecute absent (launches arbitrary programs — permanently excluded)')
check(env.fhLoadTextFile == nil, 'fhLoadTextFile absent (arbitrary-path filesystem read — permanently excluded; user-guide.md promises scripts never touch the filesystem)')
check(env.fhSaveTextFile == nil, 'fhSaveTextFile absent (arbitrary-path filesystem write — permanently excluded)')
check(env.fhGetIniFileValue == nil, 'fhGetIniFileValue absent (arbitrary-path filesystem read — permanently excluded)')
check(env.fhSetIniFileValue == nil, 'fhSetIniFileValue absent (arbitrary-path filesystem write — permanently excluded)')
check(env.fhGetClipboardData == nil, 'fhGetClipboardData absent (OS clipboard, unrelated to tree data and privacy-sensitive — permanently excluded)')
check(env.fhSleep == nil, 'fhSleep absent (blocks without executing Lua VM instructions, so watchdog.lua\'s debug.sethook count-hook cannot interrupt it)')
check(env.fhOverridePreference == nil, 'fhOverridePreference absent (mutates an app-wide preference, not tree data — permanently excluded)')
check(env.fhMessageBox == nil, 'fhMessageBox absent (UI-interactive, incompatible with the headless script->JSON-return model)')
check(env.fhDisplayRichTextBox == nil, 'fhDisplayRichTextBox absent (same UI-interactive concern)')
check(env.fhPromptUserForDate == nil, 'fhPromptUserForDate absent (blocks on user input nobody is expected to give mid-script)')
check(env.fhPromptUserForRecordSel == nil, 'fhPromptUserForRecordSel absent (same blocking-UI concern)')
check(env.fhPromptUserForRichText == nil, 'fhPromptUserForRichText absent (same blocking-UI concern)')
check(env.fhUpdateDisplay == nil, 'fhUpdateDisplay absent (UI side effect with no return value run_lua would ever see)')
check(env.fhOutputResultSetColumn == nil, 'fhOutputResultSetColumn absent (writes to FH\'s own Query Window; run_lua only reads a script\'s `return` value, so this is invisible to Claude)')
check(env.fhOutputResultSetTitles == nil, 'fhOutputResultSetTitles absent (same Query Window concern as fhOutputResultSetColumn)')
check(env.fhGetValueAsBlob == nil, 'fhGetValueAsBlob absent (writes an attached media file to an arbitrary local path — permanently excluded; rare enough to just block per 2026-07-29 discussion)')
check(env.fhSetValueAsBlob == nil, 'fhSetValueAsBlob absent (reads an arbitrary local file to attach as media — same rationale as fhGetValueAsBlob)')
check(env.fhGetPluginDataFileName == nil, 'fhGetPluginDataFileName absent (returns a filesystem path; inert without the excluded Load/Save functions, and needlessly discloses internal paths)')
check(env.fhExhibitResponsiveness == nil, 'fhExhibitResponsiveness absent (pumps the Windows message queue mid-script, which could reintroduce UI reentrancy the watchdog design didn\'t account for)')
check(env.fhInitialise == nil, 'fhInitialise absent (plugin bootstrap entry point, not applicable to a per-script sandbox)')

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
