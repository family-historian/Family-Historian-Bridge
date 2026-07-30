-- Builds the allowlist _ENV table a run_lua script executes inside.
-- Allowlist, not denylist: start from nothing, add back only what's explicitly safe.
-- Anything not added here is simply absent to the script (nil), regardless of what
-- exists in the real global environment. See CONTEXT.md "Sandbox" and
-- docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
--
-- Read-only allowlist: basic Lua, plus FH's read-side primitives and fhUtils. Both are
-- wired through by reference from the real global environment, not reimplemented —
-- FH's own Lua host installs the primitives as globals, and fhUtils ships with every FH
-- install (require('fhUtils'), not bundled by this project). No write-side fh...
-- functions are populated here yet (Stage 1 is read-only — see CONTEXT.md "Access mode").
--
-- accessMode ("read-only" / "read-write", from the bridge dialog's toggle) is accepted
-- and threaded through here so the write-capability work (issue #14) has a seam to add
-- to — it grants no extra capability yet, so "read-write" behaves identically to
-- "read-only" for now.

local M = {}

function M.build(accessMode)
  accessMode = accessMode or "read-only"
  local env = {}

  env.string = string
  env.table = table
  env.math = math
  env.pairs = pairs
  env.ipairs = ipairs
  env.tostring = tostring
  env.tonumber = tonumber
  env.pcall = pcall
  env.error = error
  env.type = type
  env.os = { date = os.date }

  -- MoveToFirstRecord/MoveNext/IsNull are FH item-pointer methods (ptr:MoveToFirstRecord
  -- (tag)), not free globals — copying same-named globals here would only ever copy nil,
  -- so they're deliberately absent. Confirmed against a real FH project, see #7.
  env.fhNewItemPtr = fhNewItemPtr
  env.fhGetItemText = fhGetItemText
  env.fhGetDisplayText = fhGetDisplayText
  env.fhGetContextInfo = fhGetContextInfo
  env.fhGetAppVersion = fhGetAppVersion
  env.fhGetTag = fhGetTag
  env.fhCallBuiltInFunction = fhCallBuiltInFunction
  env.fhGetValueAsLink = fhGetValueAsLink

  -- Batch-populated per the read-only sandbox policy agreed 2026-07-29 (grilling
  -- session): every remaining function in FH's own API reference that reads data with
  -- no side effect, so ordinary use never again needs a mid-conversation "copy this file
  -- into FH's Plugins folder and reload" cycle. Two different kinds of exclusion below —
  -- don't conflate them:
  --
  -- (1) Excluded from Read-only, reserved for Read-write once implemented (these mutate
  -- the GEDCOM tree, or can conditionally create schema): fhCreateItem, fhDeleteItem,
  -- fhMoveItemAfter, fhMoveItemBefore, fhSrcEnableAutoTitle, fhGetFactTag, fhGetFlagTag
  -- (the latter two despite their "Get" name, via a bCreateIfNone param).
  --
  -- (2) Excluded permanently, regardless of Read-only/Read-write — Read-write means
  -- read-write to the user's tree data, not to their computer:
  --   - filesystem/OS/shell: fhShellExecute, fhLoadTextFile, fhSaveTextFile,
  --     fhGetIniFileValue, fhSetIniFileValue, fhGetClipboardData, fhGetValueAsBlob,
  --     fhSetValueAsBlob, fhGetPluginDataFileName
  --   - UI-interactive, incompatible with the headless script->JSON-return model:
  --     fhMessageBox, fhDisplayRichTextBox, fhPromptUserForDate,
  --     fhPromptUserForRecordSel, fhPromptUserForRichText, fhUpdateDisplay,
  --     fhOutputResultSetColumn, fhOutputResultSetTitles
  --   - app/session state rather than tree data: fhSetStringEncoding,
  --     fhSetConversionLossFlag, fhOverridePreference
  --   - fhSleep (blocks without executing Lua VM instructions, so watchdog.lua's
  --     instruction-count hook can't interrupt it)
  --   - fhExhibitResponsiveness/fhInitialise (message-pump/plugin bootstrap concerns,
  --     not applicable to a per-script sandbox)
  --
  -- See sandbox.test.lua for the full exclusion list, asserted absent by name.

  -- Create Objects: constructors only — the objects they return carry their own methods,
  -- same as fhNewItemPtr's item pointer.
  env.fhNewAge = fhNewAge
  env.fhNewDate = fhNewDate
  env.fhNewDatePt = fhNewDatePt
  env.fhNewRichText = fhNewRichText
  env.fhNewSection = fhNewSection

  -- Fetch Values
  env.fhGetCurrentRecordSel = fhGetCurrentRecordSel
  env.fhGetCurrentPropertyBoxRecord = fhGetCurrentPropertyBoxRecord
  env.fhGetDataClass = fhGetDataClass
  env.fhGetDataList = fhGetDataList
  env.fhGetFactTypeInfo = fhGetFactTypeInfo
  env.fhGetGedcomInfo = fhGetGedcomInfo
  env.fhGetItemPtr = fhGetItemPtr
  env.fhGetLabelledText = fhGetLabelledText
  env.fhGetQualifiedRecordId = fhGetQualifiedRecordId
  env.fhGetRecordId = fhGetRecordId
  env.fhGetRecordTypeCount = fhGetRecordTypeCount
  env.fhGetRecordTypeTag = fhGetRecordTypeTag
  env.fhGetTypeInfo = fhGetTypeInfo
  env.fhGetValueAsAge = fhGetValueAsAge
  env.fhGetValueAsDate = fhGetValueAsDate
  env.fhGetValueAsInteger = fhGetValueAsInteger
  env.fhGetValueAsRichText = fhGetValueAsRichText
  env.fhGetValueAsText = fhGetValueAsText
  env.fhGetValueType = fhGetValueType
  env.fhGetMetafieldDefinition = fhGetMetafieldDefinition
  env.fhGetMetafieldShortcut = fhGetMetafieldShortcut
  env.fhGetMetafieldType = fhGetMetafieldType

  -- Check Pointer Items
  env.fhHasChildItem = fhHasChildItem
  env.fhHasNextSibItem = fhHasNextSibItem
  env.fhHasParentItem = fhHasParentItem
  env.fhHasPrevSibItem = fhHasPrevSibItem
  env.fhIsAttribute = fhIsAttribute
  env.fhIsEvent = fhIsEvent
  env.fhIsFact = fhIsFact
  env.fhIsHidden = fhIsHidden
  env.fhIsUDF = fhIsUDF
  env.fhIsValidDataRef = fhIsValidDataRef

  -- Text Encoding (read-only half; fhSetStringEncoding/fhSetConversionLossFlag excluded)
  env.fhConvertANSItoUTF8 = fhConvertANSItoUTF8
  env.fhConvertUTF8toANSI = fhConvertUTF8toANSI
  env.fhGetStringEncoding = fhGetStringEncoding
  env.fhIsConversionLossFlagSet = fhIsConversionLossFlagSet

  -- Individual/Source Record functions (read-only half; fhSrcEnableAutoTitle excluded)
  env.fhIndGetFactList = fhIndGetFactList
  env.fhIndGetName = fhIndGetName
  env.fhSrcIsAutoTitleEnabled = fhSrcIsAutoTitleEnabled

  -- Report Helper functions
  env.fhGetNarrSentence = fhGetNarrSentence
  env.fhGetNarrSentenceTemplate = fhGetNarrSentenceTemplate

  -- Ftf Syntax
  env.fhFtfEncode = fhFtfEncode
  env.fhFtfParamEncode = fhFtfParamEncode

  -- Named List Functions
  env.fhGetNamedList = fhGetNamedList
  env.fhGetNamedListByIndex = fhGetNamedListByIndex
  env.fhGetNamedListCount = fhGetNamedListCount

  -- Miscellaneous
  env.fhBeginsWithVowel = fhBeginsWithVowel

  env.fhu = require('fhUtils')

  return env
end

return M
