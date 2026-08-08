-- Builds the allowlist _ENV table a run_lua script executes inside.
-- Allowlist, not denylist: start from nothing, add back only what's explicitly safe.
-- Anything not added here is simply absent to the script (nil), regardless of what
-- exists in the real global environment. See CONTEXT.md "Sandbox" and
-- docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
--
-- Read-only allowlist: basic Lua, plus FH's read-side primitives and fhUtils. Both are
-- wired through by reference from the real global environment, not reimplemented —
-- FH's own Lua host installs the primitives as globals, and fhUtils ships with every FH
-- install (require('fhUtils'), not bundled by this project).
--
-- accessMode ("read-only" / "read-write", from the bridge dialog's toggle) is threaded
-- through from the bridge dialog's toggle. "read-write" additionally wires through FH's
-- full write API (issue #14, 2026-07-30 grilling session decision) — all of it at once,
-- with no further staging within read-write. See CONTEXT.md "Access mode". Read-write also
-- adds further env.fhBridge members from this project's own sourceHelper.lua module
-- (issue #18) and sessionLogHelper.lua's logActivity (issue #36) — neither is part of FH's
-- write API itself, but both call real fh* write globals directly, so both are gated the
-- same way. env.fhBridge itself is NOT read-write-only, though: its family/detail-query
-- members (familyHelper.lua) call only read primitives, already granted below regardless
-- of accessMode, so they're built into env.fhBridge unconditionally, before the
-- read-write block below that only ever adds further members to that same table.

local M = {}

-- Raw fh* primitives that mutate the GEDCOM tree (or can, via bCreateIfNone) -- wrapped
-- below to flip a per-build write tracker, so runScript.lua/M.run can tell whether a
-- since-failed script actually wrote anything before it errored (issue #15,
-- docs/adr/0005). fhGetFactTag/fhGetFlagTag are conservatively tracked on every call under
-- Read-write, not just a bCreateIfNone=true one -- cheaper to over-flag a possible write
-- than silently miss one. Both stay in this list (and hence in WRITE_NAMES below, so
-- runScript.lua's static pre-scan keeps flagging any script that calls either name) even
-- though, as of issue #51, they're no longer entirely excluded from Read-only -- see the
-- guarded wrappers below M.build's local-function definitions: each has a genuine
-- pure-lookup branch (bCreateIfNone=false) with no possible mutation, so only the
-- bCreateIfNone=true branch actually needs the write gate.
local WRITE_PRIMITIVE_NAMES = {
  'fhSetLabelledText', 'fhSetValueAsAge', 'fhSetValueAsDate', 'fhSetValueAsInteger',
  'fhSetValueAsLink', 'fhSetValueAsRichText', 'fhSetValueAsText', 'fhCreateItem',
  'fhDeleteItem', 'fhMoveItemAfter', 'fhMoveItemBefore', 'fhSrcEnableAutoTitle',
  'fhGetFactTag', 'fhGetFlagTag',
}

-- fhUtils (fhu) methods that write tree data, found by reading fhUtils.lua's actual
-- source rather than trusting the help corpus alone (which is missing
-- createTextFromSource entirely -- issue #22). fhu is FH-shipped and calls the real
-- global fh* primitives directly, bypassing this sandbox's env entirely -- so without this
-- list, neither the Read-only gate below nor the write tracker above would ever see a
-- write made via fhu.createIndi() and friends, which is how most scripts are told to
-- write (RUN_LUA_DESCRIPTION prefers fhu helpers over hand-rolled primitives). Every other
-- fhu method (list/string helpers, the pCite object, UI prompts) only reads tree data or
-- touches an in-memory Lua object -- see issue #22 for the two other fhu escape hatches
-- (modal dialogs, direct filesystem writes) that are out of scope here.
local FHU_WRITE_METHOD_NAMES = {
  'addFamilyAsChild', 'addFamilyAsSpouse', 'addWitness', 'createFact',
  'createFamilyAsChild', 'createFamilyAsSpouse', 'createIndi', 'createUpdateFact',
  'createUpdateItem', 'createTextFromSource',
}

local function toSet(list)
  local set = {}
  for _, name in ipairs(list) do
    set[name] = true
  end
  return set
end

local FHU_WRITE_METHODS = toSet(FHU_WRITE_METHOD_NAMES)

-- Union of both write-name lists above, exported alongside M.build so runScript.lua's
-- static pre-scan (issue #43, docs/adr/0012) reuses this exact list rather than a second,
-- driftable copy. Enforcement doesn't care *which* write function fires, only whether
-- logActivity was also called, so a flat combined list is all it needs.
local WRITE_NAMES = {}
for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
  table.insert(WRITE_NAMES, name)
end
for _, name in ipairs(FHU_WRITE_METHOD_NAMES) do
  table.insert(WRITE_NAMES, name)
end
M.WRITE_NAMES = WRITE_NAMES

-- Every bare fh* global wired into env under Read-only (issue #81) -- listed here as flat
-- data, not introspected from M.build, so it exists independently of whether M.build is
-- ever actually called (this file's own tests, and runScript.lua's pre-scan below, run
-- under plain lua with no real FH host). Kept in the same grouping/order as M.build's own
-- env.fhX = fhX assignments purely so the two stay easy to eyeball against each other; this
-- list has no other relationship to M.build beyond both needing the same names.
local READ_ONLY_FH_GLOBAL_NAMES = {
  'fhNewItemPtr', 'fhGetItemText', 'fhGetDisplayText', 'fhGetContextInfo', 'fhGetAppVersion',
  'fhGetTag', 'fhCallBuiltInFunction', 'fhGetValueAsLink',
  'fhNewAge', 'fhNewDate', 'fhNewDatePt', 'fhNewRichText', 'fhNewSection',
  'fhGetCurrentRecordSel', 'fhGetCurrentPropertyBoxRecord', 'fhGetDataClass', 'fhGetDataList',
  'fhGetFactTypeInfo', 'fhGetGedcomInfo', 'fhGetItemPtr', 'fhGetLabelledText',
  'fhGetQualifiedRecordId', 'fhGetRecordId', 'fhGetRecordTypeCount', 'fhGetRecordTypeTag',
  'fhGetTypeInfo', 'fhGetValueAsAge', 'fhGetValueAsDate', 'fhGetValueAsInteger',
  'fhGetValueAsRichText', 'fhGetValueAsText', 'fhGetValueType', 'fhGetMetafieldDefinition',
  'fhGetMetafieldShortcut', 'fhGetMetafieldType',
  'fhHasChildItem', 'fhHasNextSibItem', 'fhHasParentItem', 'fhHasPrevSibItem', 'fhIsAttribute',
  'fhIsEvent', 'fhIsFact', 'fhIsHidden', 'fhIsUDF', 'fhIsValidDataRef',
  'fhConvertANSItoUTF8', 'fhConvertUTF8toANSI', 'fhGetStringEncoding', 'fhIsConversionLossFlagSet',
  'fhIndGetFactList', 'fhIndGetName', 'fhSrcIsAutoTitleEnabled',
  'fhGetNarrSentence', 'fhGetNarrSentenceTemplate',
  'fhFtfEncode', 'fhFtfParamEncode',
  'fhGetNamedList', 'fhGetNamedListByIndex', 'fhGetNamedListCount',
  'fhBeginsWithVowel',
  -- fhGetFlagTag/fhGetFactTag (issue #51): bare names, present read-only as the guarded
  -- wrappers -- also appear in WRITE_PRIMITIVE_NAMES above, deduped below via a set.
  'fhGetFlagTag', 'fhGetFactTag',
}

-- Mode-independent union of every bare fh* global name ever assigned into env, across BOTH
-- access modes (issue #81) -- exported for runScript.lua's unrecognized-fh*-call pre-scan,
-- which needs "is this a real, known function" independent of which mode is actually
-- running (M.build only ever populates env for one mode at a time, so neither
-- READ_ONLY_FH_GLOBAL_NAMES alone nor WRITE_PRIMITIVE_NAMES alone is the right answer for a
-- pre-scan that has to run before accessMode-specific gating even matters). Deduped via a
-- set, since fhGetFactTag/fhGetFlagTag appear in both source lists.
local knownFhGlobalSet = toSet(READ_ONLY_FH_GLOBAL_NAMES)
for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
  knownFhGlobalSet[name] = true
end
local KNOWN_FH_GLOBAL_NAMES = {}
for name in pairs(knownFhGlobalSet) do
  table.insert(KNOWN_FH_GLOBAL_NAMES, name)
end
M.KNOWN_FH_GLOBAL_NAMES = KNOWN_FH_GLOBAL_NAMES

-- fhu methods that pop a real iup.Popup(dlg) modal dialog and block waiting for a human
-- to click a button, or that read/write straight to disk -- neither is survivable in
-- run_lua's headless script->JSON-return model, and both bypass this sandbox's env the
-- same way fhu's write methods do (issue #22, found by reading fhUtils.lua's actual
-- source). Unconditional: excluded in both Read-only and Read-write, since neither risk
-- has anything to do with access mode. createUpdateFact is *also* a write method
-- (FHU_WRITE_METHOD_NAMES above) -- this table takes priority over that in the proxy loop
-- below, so it never forwards to the real (hang-prone) function even under Read-write;
-- it's still absent under Read-only via the ordinary write gate, unchanged.
-- stripCommas is handled separately (buildStripCommas below): safe with just its text
-- argument, unsafe only when called with its optional sQuestion/sTitle/hParent args.
local FHU_UNSUPPORTED_REASONS = {
  getParam = 'it opens a modal dialog and would hang a headless run_lua script',
  createUpdateFact = 'it calls getParam internally, which opens a modal dialog and would hang a headless run_lua script',
  pickIndividualPrompt = 'it opens a modal dialog and would hang a headless run_lua script',
  yes = 'it opens a modal dialog and would hang a headless run_lua script',
  saveOptions = 'it writes directly to disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
  loadOptions = 'it reads directly from disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
  resetOptions = 'it writes directly to disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
}

-- Bare fh* globals permanently excluded from the sandbox regardless of access mode --
-- converted from the prose list in M.build's own comment below into a real table (issue
-- #81), so runScript.lua's unrecognized-fh*-call pre-scan can report *why* a known-but-
-- unsupported name is rejected, instead of lumping it in with a genuine typo/hallucination
-- under a generic "unrecognized function" message. Kept separate from
-- FHU_UNSUPPORTED_REASONS above: that table is for fhu.* method calls (env.fhu.getParam
-- etc.), this one is for bare fh* global calls (env.fhFoo) -- the two namespaces never
-- overlap, though several of the underlying reasons do (both hit the same
-- headless-script/filesystem-exclusion policy limits). Reason text matches
-- sandbox.test.lua's own absence-assertion comments below, kept in sync by hand.
local EXCLUDED_FH_GLOBAL_REASONS = {
  fhSetStringEncoding = 'it mutates app/session state, not tree data, which is outside this sandbox\'s tree-data write model',
  fhSetConversionLossFlag = 'it mutates app/session state, the same concern as fhSetStringEncoding',
  fhShellExecute = 'it launches arbitrary programs, which this project\'s exclusion policy does not allow over run_lua',
  fhLoadTextFile = 'it reads an arbitrary local file, which this project\'s filesystem exclusion policy does not allow over run_lua',
  fhSaveTextFile = 'it writes an arbitrary local file, which this project\'s filesystem exclusion policy does not allow over run_lua',
  fhGetIniFileValue = 'it reads an arbitrary local file, which this project\'s filesystem exclusion policy does not allow over run_lua',
  fhSetIniFileValue = 'it writes an arbitrary local file, which this project\'s filesystem exclusion policy does not allow over run_lua',
  fhGetClipboardData = 'it reads the OS clipboard, unrelated to tree data and privacy-sensitive',
  fhGetValueAsBlob = 'it writes an attached media file to an arbitrary local path, which this project\'s filesystem exclusion policy does not allow over run_lua',
  fhSetValueAsBlob = 'it reads an arbitrary local file to attach as media, the same filesystem exclusion policy as fhGetValueAsBlob',
  fhGetPluginDataFileName = 'it returns a filesystem path, inert without the excluded Load/Save functions and needlessly discloses internal paths',
  fhMessageBox = 'it opens a modal dialog and would hang a headless run_lua script',
  fhDisplayRichTextBox = 'it opens a modal dialog and would hang a headless run_lua script',
  fhPromptUserForDate = 'it opens a modal dialog and would hang a headless run_lua script',
  fhPromptUserForRecordSel = 'it opens a modal dialog and would hang a headless run_lua script',
  fhPromptUserForRichText = 'it opens a modal dialog and would hang a headless run_lua script',
  fhUpdateDisplay = 'it is a UI side effect with no return value run_lua would ever see',
  fhOutputResultSetColumn = 'it writes to FH\'s own Query Window; run_lua only reads a script\'s return value, so this is invisible to Claude',
  fhOutputResultSetTitles = 'it writes to FH\'s own Query Window, the same concern as fhOutputResultSetColumn',
  fhSleep = 'it blocks without executing Lua VM instructions, so watchdog.lua\'s instruction-count hook cannot interrupt it',
  fhOverridePreference = 'it mutates an app-wide preference, not tree data',
  fhExhibitResponsiveness = 'it pumps the Windows message queue mid-script, which could reintroduce UI reentrancy the watchdog design did not account for',
  fhInitialise = 'it is a plugin bootstrap entry point, not applicable to a per-script sandbox',
}
M.EXCLUDED_FH_GLOBAL_REASONS = EXCLUDED_FH_GLOBAL_REASONS

local function unsupportedFhu(name, reason)
  return function()
    error('fhu.' .. name .. ' is not supported over run_lua: ' .. reason)
  end
end

-- stripCommas(s, sQuestion, sTitle, hParent) (server/data/fh-help-corpus.jsonl): the
-- three optional trailing args are what make it prompt via iup.Popup -- called with just
-- s, it's pure string cleanup. Pass through to the real function when none of them are
-- present; raise the same style of error as the unconditional methods above otherwise.
local function buildStripCommas(realStripCommas)
  return function(s, sQuestion, sTitle, hParent)
    if sQuestion ~= nil or sTitle ~= nil or hParent ~= nil then
      error('fhu.stripCommas is not supported over run_lua with its optional sQuestion/sTitle/hParent arguments: it opens a modal dialog and would hang a headless run_lua script. Call it with just the text argument instead.')
    end
    return realStripCommas(s)
  end
end

-- fhGetFlagTag(strFlagName, bCreateIfNone[, bFactFlag]) (issue #51): a pure lookup when
-- bCreateIfNone is not true -- returns the existing tag, or "" if the flag type isn't
-- found, per FH's own docs (fhGetFlagTag.htm) -- but bCreateIfNone=true can create a new
-- flag-type definition, which is a real write. Guarded the same way buildStripCommas
-- guards its optional UI args: forward through on the safe branch, raise a clear error on
-- the write-capable one. Read-only only -- M.build overwrites this with the full,
-- unguarded, tracked version under Read-write (see WRITE_PRIMITIVE_NAMES's own comment).
local function buildGuardedGetFlagTag(realGetFlagTag)
  return function(strFlagName, bCreateIfNone, bFactFlag)
    if bCreateIfNone then
      error('fhGetFlagTag is not supported over run_lua with bCreateIfNone = true in a Read-only session: it can create a new flag-type definition, which is a write. Call it with bCreateIfNone = false to look up an existing flag\'s tag without creating one, or start a Read-write Session.')
    end
    return realGetFlagTag(strFlagName, bCreateIfNone, bFactFlag)
  end
end

-- fhGetFactTag(strFactName, strFactType, strRecTag, bCreateIfNone) (issue #51): same shape
-- and same reasoning as fhGetFlagTag above -- bCreateIfNone is this function's last
-- positional argument instead of its second, but the pure-lookup-vs-create split is
-- identical (fhGetFactTag.htm).
local function buildGuardedGetFactTag(realGetFactTag)
  return function(strFactName, strFactType, strRecTag, bCreateIfNone)
    if bCreateIfNone then
      error('fhGetFactTag is not supported over run_lua with bCreateIfNone = true in a Read-only session: it can create a new custom fact type, which is a write. Call it with bCreateIfNone = false to look up an existing fact type\'s tag without creating one, or start a Read-write Session.')
    end
    return realGetFactTag(strFactName, strFactType, strRecTag, bCreateIfNone)
  end
end

-- M.build's accessMode ("read-only"/"read-write") is threaded through from the bridge
-- dialog's toggle; returns the sandbox env plus a tracker table
-- ({wrote = boolean, logged = boolean}) the caller can inspect after running a script to
-- see whether any wrapped write primitive was actually called, and separately whether
-- fhBridge.logActivity was -- kept out of env itself so the sandboxed script can't read
-- or tamper with its own tracker.
function M.build(accessMode)
  accessMode = accessMode or "read-only"
  local env = {}
  local tracker = { wrote = false, logged = false }

  local function trackedWrite(fn)
    return function(...)
      tracker.wrote = true
      return fn(...)
    end
  end

  -- logActivity really does mutate the tree (creates/updates a _RNOT record), so it must
  -- still flip tracker.wrote exactly like every other write primitive -- a script that
  -- calls only logActivity and then errors must stay eligible for ADR 0005's existing
  -- rollback path. Composes trackedWrite rather than reimplementing its wrote-flip, and
  -- additionally flips tracker.logged, which trackedWrite alone can't do, since that flag
  -- needs to mean "logActivity specifically was called," not "some write happened" (issue
  -- #43, docs/adr/0012).
  local function trackedLog(fn)
    local write = trackedWrite(fn)
    return function(...)
      tracker.logged = true
      return write(...)
    end
  end

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
  -- (1) Excluded from Read-only, granted under Read-write below (these write to the
  -- GEDCOM tree, or can conditionally create schema): fhSetLabelledText, every
  -- fhSetValueAs* setter (Age/Date/Integer/Link/RichText/Text), fhCreateItem,
  -- fhDeleteItem, fhMoveItemAfter, fhMoveItemBefore, fhSrcEnableAutoTitle, fhGetFactTag,
  -- fhGetFlagTag (the latter two despite their "Get" name, via a bCreateIfNone param).
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

  -- fhGetFlagTag/fhGetFactTag (issue #51): guarded partial read-only availability -- see
  -- buildGuardedGetFlagTag/buildGuardedGetFactTag above and WRITE_PRIMITIVE_NAMES's own
  -- comment. Set here, unconditionally, so both access modes get a value; the Read-write
  -- block below overwrites both with the full, unguarded, tracked version when
  -- accessMode == "read-write", same override pattern as everything else in that block.
  env.fhGetFlagTag = buildGuardedGetFlagTag(fhGetFlagTag)
  env.fhGetFactTag = buildGuardedGetFactTag(fhGetFactTag)

  -- fhu (require('fhUtils')) is never the raw module -- always a proxy, so its write
  -- methods can be gated by accessMode and tracked the same as the raw primitives below
  -- (issue #22 found the raw module was reachable read-only, since fhu bypasses env and
  -- calls real fh* globals directly regardless of what this sandbox otherwise allows).
  -- The modal-dialog/filesystem-write check runs first and takes priority over write
  -- gating (see FHU_UNSUPPORTED_REASONS above -- this is what keeps createUpdateFact from
  -- ever forwarding, despite also being a write method). Every other method is passed
  -- through by reference, unchanged.
  do
    local realFhu = require('fhUtils')
    local fhuProxy = {}
    for name, value in pairs(realFhu) do
      if FHU_UNSUPPORTED_REASONS[name] then
        fhuProxy[name] = unsupportedFhu(name, FHU_UNSUPPORTED_REASONS[name])
      elseif name == 'stripCommas' then
        fhuProxy[name] = buildStripCommas(value)
      elseif FHU_WRITE_METHODS[name] then
        if accessMode == "read-write" then
          fhuProxy[name] = trackedWrite(value)
        end
        -- else: omitted under read-only, same treatment as the raw write primitives below
      else
        fhuProxy[name] = value
      end
    end
    env.fhu = fhuProxy
  end

  -- familyHelper.lua's getFamilyGroup/getAllDetails/getAncestors/getDescendants/
  -- searchByName/getFactsByTag call nothing but read primitives already granted above
  -- (fhNewItemPtr, item-pointer MoveToFirstRecord/MoveTo/MoveNext/
  -- MoveToFirstChildItem/IsNotNull/IsNull, fhGetValueAsLink, fhGetTag,
  -- fhGetItemText, fhGetRecordId, fhGetQualifiedRecordId, fhGetDisplayText,
  -- fhGetValueType, fhGetValueAsRichText, fhGetDataClass, fhGetValueAsText,
  -- fhHasChildItem, fhIndGetName,
  -- fhCallBuiltInFunction -- getDescendants' optional dnaLine filter, a pure
  -- lookup/query, not a write) -- unlike
  -- sourceHelper.lua's createSourceFromTemplate/citeSource below, so env.fhBridge is
  -- built here, unconditionally, rather than inside the read-write block. The read-write
  -- block only ever adds further (write) members to this same table, never replaces it.
  --
  -- sourceHelper.lua itself is also required unconditionally here (issue #65): unlike
  -- createSourceFromTemplate/citeSource, its findSources, getPopulatedTemplateFields
  -- (issue #73), and getTemplateFieldCensus (issue #74) are pure reads (they walk
  -- records/citations via familyHelper.getAllDetails and fhGetItemText Data References, no
  -- fh* write primitive), so all three are wired into env.fhBridge here too, by reference
  -- like every other read-only member -- gating tracks whether a function writes, not
  -- which file it's defined in.
  local realFamilyHelper = require('familyHelper')
  local realSourceHelper = require('sourceHelper')
  env.fhBridge = {
    getFamilyGroup = realFamilyHelper.getFamilyGroup,
    getAllDetails = realFamilyHelper.getAllDetails,
    getAncestors = realFamilyHelper.getAncestors,
    getDescendants = realFamilyHelper.getDescendants,
    searchByName = realFamilyHelper.searchByName,
    getFactsByTag = realFamilyHelper.getFactsByTag,
    findSources = realSourceHelper.findSources,
    getPopulatedTemplateFields = realSourceHelper.getPopulatedTemplateFields,
    getTemplateFieldCensus = realSourceHelper.getTemplateFieldCensus,
  }

  if accessMode == "read-write" then
    -- FH's full write API (issue #14, 2026-07-30 grilling session): granted all at once,
    -- wrapped to flip the write tracker above — no further staging within read-write. See
    -- CONTEXT.md "Access mode" for the authoritative list.
    for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
      env[name] = trackedWrite(_G[name])
    end

    -- createSourceFromTemplate/citeSource fill the one gap fhUtils itself doesn't cover
    -- (issue #18) — call the real fh* globals directly, same as fhUtils, so they must
    -- stay gated to read-write (unlike findSources above, already wired in unconditionally).
    -- logActivity (issue #36) is a separate sibling module, not part of sourceHelper.lua's
    -- own Source-record concerns, but exposed through the same env.fhBridge table and
    -- gated the same read-write-only way, since it also calls the real fh* globals
    -- directly.
    local realSessionLogHelper = require('sessionLogHelper')
    env.fhBridge.createSourceFromTemplate = trackedWrite(realSourceHelper.createSourceFromTemplate)
    env.fhBridge.citeSource = trackedWrite(realSourceHelper.citeSource)
    env.fhBridge.logActivity = trackedLog(realSessionLogHelper.logActivity)
  end

  return env, tracker
end

return M
