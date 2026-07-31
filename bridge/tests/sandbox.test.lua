-- Standalone tests for sandbox.lua. Run with: lua bridge/tests/sandbox.test.lua
-- Pure table inspection — no FH/socket/iup dependency. Verifies both halves of the
-- allowlist: the basics are present, and nothing dangerous leaked in by accident.

package.path = package.path .. ';' .. arg[0]:match("(.*/)") .. '../?.lua'
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

-- Read-write write API (issue #14): stubbed the same way as the read-only surface above,
-- so the read-write assertions below (present, by reference) and the read-only exclusion
-- assertions further down (absent) each prove something real, rather than either passing
-- vacuously.
fhSetLabelledText = function() end
fhSetValueAsAge = function() end
fhSetValueAsDate = function() end
fhSetValueAsInteger = function() end
fhSetValueAsLink = function() end
fhSetValueAsRichText = function() end
fhSetValueAsText = function() end

-- Excluded-from-Read-only functions: stubbed as if FH provides them (it does), so the
-- read-only absence assertions below actually prove sandbox.build() declines to wire
-- them through under read-only, rather than passing vacuously because the global itself
-- doesn't exist in this plain-lua process. Also part of the read-write write API above.
fhCreateItem = function(tag) return 'created:' .. tostring(tag) end
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
-- inside FH. Includes one stub per fhu write method (issue #15/#22 — found by reading
-- fhUtils.lua's actual source, not just the help corpus) so the read-only absence checks
-- and read-write wrapping checks below each prove something real, not vacuous nils.
-- createIndi additionally records its call and returns an identifiable value, to prove
-- the read-write proxy actually forwards through to the real function and its arguments,
-- not just that a callable of some kind is present.
local fhuCalls = {}
local fakeFhu = {
  records = function(tag) end,
  createIndi = function(sName, sSex)
    table.insert(fhuCalls, { 'createIndi', sName, sSex })
    return 'indi:' .. tostring(sName)
  end,
  addFamilyAsChild = function() end,
  addFamilyAsSpouse = function() end,
  addWitness = function() end,
  createFact = function() end,
  createFamilyAsChild = function() end,
  createFamilyAsSpouse = function() end,
  createUpdateFact = function() end,
  createUpdateItem = function() end,
  createTextFromSource = function() end,
}
package.loaded.fhUtils = fakeFhu

-- sourceHelper.lua (issue #18) ships as a sibling module in this project (unlike fhUtils),
-- but is stubbed the same way here so this test stays a pure allowlist check, independent
-- of sourceHelper.lua's own behavior (covered by sourceHelper.test.lua). citeSource
-- returns an identifiable value for the same forwarding-proof reason as fakeFhu.createIndi
-- above.
local fakeSourceHelper = {
  createSourceFromTemplate = function() end,
  citeSource = function(ptrTarget, sourceNameOrId) return 'cited:' .. tostring(sourceNameOrId) end,
}
package.loaded.sourceHelper = fakeSourceHelper

local env, tracker = sandbox.build()

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

-- fhUtils (require('fhUtils')) is present via a proxy, not the raw module — its
-- non-write methods (e.g. records) are still the real thing, by reference.
check(env.fhu ~= fakeFhu, 'fhu is a proxy, not the raw fhUtils module')
check(env.fhu.records == fakeFhu.records, 'fhu.records (non-write) present by reference')

-- fhu's write methods (issue #15/#22) are absent under read-only, same treatment as the
-- raw fh* write primitives below — fhu bypasses env and calls the real globals directly,
-- so without this proxy gate a Read-only Session could write for real via fhu.createIndi.
check(env.fhu.createIndi == nil, 'fhu.createIndi absent under read-only')
check(env.fhu.addFamilyAsChild == nil, 'fhu.addFamilyAsChild absent under read-only')
check(env.fhu.addFamilyAsSpouse == nil, 'fhu.addFamilyAsSpouse absent under read-only')
check(env.fhu.addWitness == nil, 'fhu.addWitness absent under read-only')
check(env.fhu.createFact == nil, 'fhu.createFact absent under read-only')
check(env.fhu.createFamilyAsChild == nil, 'fhu.createFamilyAsChild absent under read-only')
check(env.fhu.createFamilyAsSpouse == nil, 'fhu.createFamilyAsSpouse absent under read-only')
check(env.fhu.createUpdateFact == nil, 'fhu.createUpdateFact absent under read-only')
check(env.fhu.createUpdateItem == nil, 'fhu.createUpdateItem absent under read-only')
check(env.fhu.createTextFromSource == nil, 'fhu.createTextFromSource absent under read-only (undocumented in the help corpus, found by reading fhUtils.lua itself — issue #22)')

-- fhBridge (require('sourceHelper'), issue #18) is read-write only — same gating as
-- fhCreateItem/fhSetValueAsLink below, since it calls those globals directly.
check(env.fhBridge == nil, 'fhBridge absent under read-only (calls real fh* globals directly — must not be reachable without the write gate)')

-- Write tracker (issue #15): present on every build(), starts false, independent of
-- accessMode (a read-only script can never flip it, since it has no write functions).
check(type(tracker) == 'table' and tracker.wrote == false, 'read-only build returns a tracker with wrote = false')

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
check(env.fhSetLabelledText == nil, 'fhSetLabelledText absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsAge == nil, 'fhSetValueAsAge absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsDate == nil, 'fhSetValueAsDate absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsInteger == nil, 'fhSetValueAsInteger absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsLink == nil, 'fhSetValueAsLink absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsRichText == nil, 'fhSetValueAsRichText absent under read-only (reserved for Read-write)')
check(env.fhSetValueAsText == nil, 'fhSetValueAsText absent under read-only (reserved for Read-write)')
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

-- Access mode plumbing (issue #13) + write API (issue #14): build() accepts an accessMode
-- argument, threaded through from the bridge dialog's toggle. "read-write" carries every
-- read-only capability plus the full write API, granted all at once. Every write primitive
-- is now wrapped (issue #15, to track whether a script actually wrote before erroring), so
-- these are functional forwarding checks instead of reference-identity checks — proving
-- the wrapper still calls through to the real function with the same arguments/return.
local envReadWrite, trackerReadWrite = sandbox.build("read-write")
check(envReadWrite.string == string, 'read-write build still has the read-only basics')
check(envReadWrite.fhGetItemText == fhGetItemText, 'read-write build still has read-only FH primitives')
check(type(envReadWrite.fhSetLabelledText) == 'function' and envReadWrite.fhSetLabelledText ~= fhSetLabelledText, 'read-write build includes a wrapped fhSetLabelledText')
check(type(envReadWrite.fhSetValueAsAge) == 'function', 'read-write build includes a wrapped fhSetValueAsAge')
check(type(envReadWrite.fhSetValueAsDate) == 'function', 'read-write build includes a wrapped fhSetValueAsDate')
check(type(envReadWrite.fhSetValueAsInteger) == 'function', 'read-write build includes a wrapped fhSetValueAsInteger')
check(type(envReadWrite.fhSetValueAsLink) == 'function', 'read-write build includes a wrapped fhSetValueAsLink')
check(type(envReadWrite.fhSetValueAsRichText) == 'function', 'read-write build includes a wrapped fhSetValueAsRichText')
check(type(envReadWrite.fhSetValueAsText) == 'function', 'read-write build includes a wrapped fhSetValueAsText')
check(type(envReadWrite.fhDeleteItem) == 'function', 'read-write build includes a wrapped fhDeleteItem')
check(type(envReadWrite.fhMoveItemAfter) == 'function', 'read-write build includes a wrapped fhMoveItemAfter')
check(type(envReadWrite.fhMoveItemBefore) == 'function', 'read-write build includes a wrapped fhMoveItemBefore')
check(type(envReadWrite.fhSrcEnableAutoTitle) == 'function', 'read-write build includes a wrapped fhSrcEnableAutoTitle')
check(type(envReadWrite.fhGetFactTag) == 'function', 'read-write build includes a wrapped fhGetFactTag')
check(type(envReadWrite.fhGetFlagTag) == 'function', 'read-write build includes a wrapped fhGetFlagTag')

check(trackerReadWrite.wrote == false, 'read-write tracker starts false')
check(envReadWrite.fhCreateItem('INDI') == 'created:INDI', 'wrapped fhCreateItem still forwards its argument and return value through to the real function')
check(trackerReadWrite.wrote == true, 'calling a wrapped raw write primitive flips the tracker')

-- fhu's write methods, under read-write: present, wrapped, forward through to the real
-- fhu method (fakeFhu.createIndi records its call and returns an identifiable value).
local envReadWrite2, trackerReadWrite2 = sandbox.build("read-write")
check(type(envReadWrite2.fhu.createIndi) == 'function' and envReadWrite2.fhu.createIndi ~= fakeFhu.createIndi, 'read-write fhu.createIndi is wrapped, not the raw function')
check(envReadWrite2.fhu.createIndi('Jane /Doe/', 'Female') == 'indi:Jane /Doe/', 'wrapped fhu.createIndi forwards its arguments and return value through to the real fhu.createIndi')
check(#fhuCalls == 1 and fhuCalls[1][1] == 'createIndi' and fhuCalls[1][2] == 'Jane /Doe/' and fhuCalls[1][3] == 'Female', 'the real fhu.createIndi actually ran with the original arguments')
check(trackerReadWrite2.wrote == true, 'calling a wrapped fhu write method flips that build\'s own tracker')
check(envReadWrite2.fhu.records == fakeFhu.records, 'fhu.records (non-write) is still present by reference under read-write')

-- fhBridge (require('sourceHelper')), under read-write: present, wrapped, forwards through
-- and flips the same tracker as the raw primitives and fhu above.
local envReadWrite3, trackerReadWrite3 = sandbox.build("read-write")
check(type(envReadWrite3.fhBridge) == 'table', 'read-write build includes fhBridge (require("sourceHelper"))')
check(envReadWrite3.fhBridge.citeSource('ptr', 'my-source') == 'cited:my-source', 'wrapped fhBridge.citeSource forwards through to the real sourceHelper.citeSource')
check(trackerReadWrite3.wrote == true, 'calling a wrapped fhBridge method flips the tracker too')

-- Two read-write build() calls must not share a tracker: a fourth build with no write call
-- at all must stay false, proving trackerReadWrite/2/3 above went true from their own
-- calls, not a single table shared across every build().
local _, trackerReadWriteUntouched = sandbox.build("read-write")
check(trackerReadWriteUntouched.wrote == false, 'a read-write build with no write call keeps its own tracker false, proving trackers are not shared across build() calls')

local envExplicitReadOnly = sandbox.build("read-only")
check(envExplicitReadOnly.string == string, 'explicit "read-only" behaves the same as the no-argument default')

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
