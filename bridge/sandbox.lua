-- Builds the allowlist _ENV table a run_lua script executes inside. Allowlist, not
-- denylist: start from nothing, add back only what's explicitly safe. See CONTEXT.md
-- "Sandbox" and docs/adr/0001.
--
-- Read-only: basic Lua, plus FH's read-side primitives and fhUtils, wired through by
-- reference from the real global environment.
--
-- accessMode ("read-only"/"read-write") also gates FH's full write API, plus
-- sourceHelper.lua's createSourceFromTemplate/citeSource and sessionLogHelper.lua's
-- logActivity (neither part of FH's write API, but both call real fh* write globals
-- directly, so both are gated the same way). env.fhBridge itself is NOT read-write-only:
-- its family/detail-query members only call read primitives, so they're built
-- unconditionally, before the read-write block adds further members.

local M = {}

-- Raw fh* primitives that mutate the GEDCOM tree (or can, via bCreateIfNone) -- wrapped
-- below to flip a per-build write tracker, so runScript.lua/M.run can tell whether a
-- since-failed script actually wrote anything before it errored (ADR 0005).
-- fhGetFactTag/fhGetFlagTag are tracked on every call under Read-write, even though only
-- their bCreateIfNone=true branch is a real write -- see the guarded wrappers below, which
-- give each a genuine pure-lookup path under Read-only.
local WRITE_PRIMITIVE_NAMES = {
  'fhSetLabelledText', 'fhSetValueAsAge', 'fhSetValueAsDate', 'fhSetValueAsInteger',
  'fhSetValueAsLink', 'fhSetValueAsRichText', 'fhSetValueAsText', 'fhCreateItem',
  'fhDeleteItem', 'fhMoveItemAfter', 'fhMoveItemBefore', 'fhSrcEnableAutoTitle',
  'fhGetFactTag', 'fhGetFlagTag',
}

-- fhUtils (fhu) methods that write tree data, found by reading fhUtils.lua's actual
-- source (the help corpus is missing some, e.g. createTextFromSource). fhu calls the real
-- global fh* primitives directly, bypassing this sandbox's env -- so without this list,
-- neither the Read-only gate nor the write tracker would ever see a write made via
-- fhu.createIndi() and friends. Every other fhu method only reads tree data or touches an
-- in-memory Lua object.
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

-- Union of both write-name lists above, exported so runScript.lua's static pre-scan
-- (ADR 0012) reuses this exact list rather than a second, driftable copy.
local WRITE_NAMES = {}
for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
  table.insert(WRITE_NAMES, name)
end
for _, name in ipairs(FHU_WRITE_METHOD_NAMES) do
  table.insert(WRITE_NAMES, name)
end
M.WRITE_NAMES = WRITE_NAMES

-- Every bare fh* global wired into env under Read-only -- listed here as flat data so it
-- exists independently of whether M.build is ever called (this file's tests, and
-- runScript.lua's pre-scan, run under plain lua with no real FH host).
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
  -- Links (issue #134): fhGetRecordLinks takes a record item pointer and returns a table
  -- of item pointers linking to it -- pure read, no bCreateIfNone-style write branch.
  'fhGetRecordLinks',
  -- fhGetFlagTag/fhGetFactTag: bare names, present read-only as the guarded wrappers below
  -- -- also appear in WRITE_PRIMITIVE_NAMES above, deduped via a set.
  'fhGetFlagTag', 'fhGetFactTag',
}

-- Mode-independent union of every bare fh* global name ever assigned into env, across both
-- access modes -- exported for runScript.lua's unrecognized-fh*-call pre-scan, which needs
-- "is this a real, known function" independent of which mode is running.
local knownFhGlobalSet = toSet(READ_ONLY_FH_GLOBAL_NAMES)
for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
  knownFhGlobalSet[name] = true
end
local KNOWN_FH_GLOBAL_NAMES = {}
for name in pairs(knownFhGlobalSet) do
  table.insert(KNOWN_FH_GLOBAL_NAMES, name)
end
M.KNOWN_FH_GLOBAL_NAMES = KNOWN_FH_GLOBAL_NAMES

-- fhu methods that pop a real modal dialog and block for a human click, or read/write
-- straight to disk -- neither survivable in run_lua's headless model, and both bypass this
-- sandbox's env the same way fhu's write methods do. Unconditional in both access modes.
-- createUpdateFact is also a write method (FHU_WRITE_METHOD_NAMES above) -- this table
-- takes priority in the proxy loop below, so it never forwards to the real (hang-prone)
-- function even under Read-write.
-- stripCommas is handled separately (buildStripCommas below): safe with just its text
-- argument, unsafe only with its optional sQuestion/sTitle/hParent args.
local FHU_UNSUPPORTED_REASONS = {
  getParam = 'it opens a modal dialog and would hang a headless run_lua script',
  createUpdateFact = 'it calls getParam internally, which opens a modal dialog and would hang a headless run_lua script',
  pickIndividualPrompt = 'it opens a modal dialog and would hang a headless run_lua script',
  yes = 'it opens a modal dialog and would hang a headless run_lua script',
  saveOptions = 'it writes directly to disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
  loadOptions = 'it reads directly from disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
  resetOptions = 'it writes directly to disk, which this project\'s filesystem exclusion policy does not allow over run_lua',
}

-- Bare fh* globals permanently excluded from the sandbox regardless of access mode, so
-- runScript.lua's unrecognized-fh*-call pre-scan can report *why* a known-but-unsupported
-- name is rejected, rather than lumping it in with a genuine typo/hallucination. Separate
-- from FHU_UNSUPPORTED_REASONS above: that's for fhu.* method calls, this is for bare fh*
-- global calls -- the namespaces never overlap. Reason text is kept in sync by hand with
-- sandbox.test.lua's own absence assertions.
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
  fhOutputNote = 'it writes to FH\'s own Note Window; run_lua only reads a script\'s return value, so this is invisible to Claude',
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

-- fhGetFlagTag(strFlagName, bCreateIfNone[, bFactFlag]): a pure lookup when bCreateIfNone
-- is not true -- returns the existing tag, or "" if not found -- but bCreateIfNone=true can
-- create a new flag-type definition, a real write. Forwards on the safe branch, raises a
-- clear error on the write-capable one. Read-only only -- M.build overwrites this with the
-- full, unguarded, tracked version under Read-write.
local function buildGuardedGetFlagTag(realGetFlagTag)
  return function(strFlagName, bCreateIfNone, bFactFlag)
    if bCreateIfNone then
      error('fhGetFlagTag is not supported over run_lua with bCreateIfNone = true in a Read-only session: it can create a new flag-type definition, which is a write. Call it with bCreateIfNone = false to look up an existing flag\'s tag without creating one, or start a Read-write Session.')
    end
    return realGetFlagTag(strFlagName, bCreateIfNone, bFactFlag)
  end
end

-- fhGetFactTag(strFactName, strFactType, strRecTag, bCreateIfNone): same shape and
-- reasoning as fhGetFlagTag above -- bCreateIfNone is just in a different argument
-- position.
local function buildGuardedGetFactTag(realGetFactTag)
  return function(strFactName, strFactType, strRecTag, bCreateIfNone)
    if bCreateIfNone then
      error('fhGetFactTag is not supported over run_lua with bCreateIfNone = true in a Read-only session: it can create a new custom fact type, which is a write. Call it with bCreateIfNone = false to look up an existing fact type\'s tag without creating one, or start a Read-write Session.')
    end
    return realGetFactTag(strFactName, strFactType, strRecTag, bCreateIfNone)
  end
end

-- accessMode ("read-only"/"read-write") comes from the bridge dialog's toggle. Returns the
-- sandbox env plus a tracker table ({wrote, logged}) the caller can inspect after running a
-- script -- kept out of env itself so the sandboxed script can't read or tamper with it.
-- privacySettings ({privateVisibility=, livingVisibility=}, issue #141) defaults to
-- unfiltered "all"/"all", mirroring accessMode's own default -- see runScript.lua's own
-- default for why callers predating #141 need no changes.
function M.build(accessMode, privacySettings)
  accessMode = accessMode or "read-only"
  privacySettings = privacySettings or { privateVisibility = "all", livingVisibility = "all" }
  local env = {}
  local tracker = { wrote = false, logged = false }

  local function trackedWrite(fn)
    return function(...)
      tracker.wrote = true
      return fn(...)
    end
  end

  -- validatedTrackedWrite(validateFn, fn) / validatedTrackedLog(validateFn, fn): for the
  -- fhBridge.* composite functions (createSourceFromTemplate/citeSource/logActivity/
  -- setTftfText/createFact) that each expose their own pure validation half. Calls
  -- validateFn(...) first, untracked, so a call it rejects never arms the tracker; only
  -- calls the real fn(...) once validation passes. Plain trackedWrite above flips the
  -- tracker purely from being entered -- correct for a raw fh* write primitive (the call
  -- itself IS the mutation), but wrong for these: a call rejected during their own
  -- validation phase never reached fhCreateItem, and must not arm ADR 0005's rollback path.
  local function validatedTrackedWrite(validateFn, fn)
    return function(...)
      validateFn(...)
      tracker.wrote = true
      return fn(...)
    end
  end

  local function validatedTrackedLog(validateFn, fn)
    return function(...)
      validateFn(...)
      tracker.logged = true
      tracker.wrote = true
      return fn(...)
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
  -- (tag)), not free globals -- deliberately absent here.
  env.fhNewItemPtr = fhNewItemPtr
  env.fhGetItemText = fhGetItemText
  env.fhGetDisplayText = fhGetDisplayText
  env.fhGetContextInfo = fhGetContextInfo
  env.fhGetAppVersion = fhGetAppVersion
  env.fhGetTag = fhGetTag
  env.fhCallBuiltInFunction = fhCallBuiltInFunction
  env.fhGetValueAsLink = fhGetValueAsLink

  -- Every remaining read-only-safe function in FH's own API reference, wired through by
  -- reference so ordinary use doesn't need a "copy this file into FH's Plugins folder and
  -- reload" cycle for something already known to be safe. Two categories of function are
  -- deliberately absent from this whole batch: writes (see WRITE_PRIMITIVE_NAMES above,
  -- granted under Read-write below) and permanently-excluded ones (see
  -- EXCLUDED_FH_GLOBAL_REASONS above, e.g. filesystem/OS access, modal UI, app/session
  -- state). See sandbox.test.lua for the full exclusion list, asserted absent by name.

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

  -- Links
  env.fhGetRecordLinks = fhGetRecordLinks

  -- Miscellaneous
  env.fhBeginsWithVowel = fhBeginsWithVowel

  -- Guarded partial read-only availability (see buildGuardedGetFlagTag/
  -- buildGuardedGetFactTag above) -- set here so both access modes get a value; the
  -- Read-write block below overwrites both with the full, unguarded, tracked version.
  env.fhGetFlagTag = buildGuardedGetFlagTag(fhGetFlagTag)
  env.fhGetFactTag = buildGuardedGetFactTag(fhGetFactTag)

  -- fhu (require('fhUtils')) is never the raw module -- always a proxy, so its write
  -- methods can be gated by accessMode and tracked the same as the raw primitives (the raw
  -- module is reachable read-only otherwise, since fhu bypasses env and calls real fh*
  -- globals directly). The modal-dialog/filesystem-write check runs first and takes
  -- priority over write gating -- this is what keeps createUpdateFact from ever
  -- forwarding, despite also being a write method. Every other method passes through by
  -- reference, unchanged.
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

  -- familyHelper.lua's query helpers, sourceHelper.lua's findSources/
  -- getPopulatedTemplateFields/getTemplateFieldCensus, and richTextHelper.lua's
  -- getTftfText all call nothing but read primitives already granted above, so
  -- env.fhBridge is built here unconditionally, before the read-write block below --
  -- gating tracks whether a function writes, not which file it's defined in. The
  -- read-write block only ever adds further members to this same table, never replaces it.
  local realFamilyHelper = require('familyHelper')
  local realSourceHelper = require('sourceHelper')
  local realRichTextHelper = require('richTextHelper')
  -- Module-level, not threaded through every fhBridge.* call's own parameters: FH's IUP
  -- mainloop is single-threaded (one script runs to completion before the next starts, same
  -- reasoning documented elsewhere for why Start/Stop can't race a running script), so
  -- setting this once per M.build call is safe and keeps getFamilyGroup(ptrRecord, ...)
  -- etc.'s public signatures unchanged.
  realFamilyHelper.setPrivacySettings(privacySettings)
  env.fhBridge = {
    getFamilyGroup = realFamilyHelper.getFamilyGroup,
    getAllDetails = realFamilyHelper.getAllDetails,
    getAncestors = realFamilyHelper.getAncestors,
    getDescendants = realFamilyHelper.getDescendants,
    findByNames = realFamilyHelper.findByNames,
    getFactsByTag = realFamilyHelper.getFactsByTag,
    findSources = realSourceHelper.findSources,
    getPopulatedTemplateFields = realSourceHelper.getPopulatedTemplateFields,
    getTemplateFieldCensus = realSourceHelper.getTemplateFieldCensus,
    getTftfText = realRichTextHelper.getTftfText,
  }

  if accessMode == "read-write" then
    -- FH's full write API: granted all at once, wrapped to flip the write tracker -- no
    -- further staging within read-write. See CONTEXT.md "Access mode" for the
    -- authoritative list.
    for _, name in ipairs(WRITE_PRIMITIVE_NAMES) do
      env[name] = trackedWrite(_G[name])
    end

    -- createSourceFromTemplate/citeSource/logActivity/setTftfText/createFact each call
    -- real fh* write globals directly (not via fhu), so each stays gated to read-write
    -- here. validatedTrackedWrite/validatedTrackedLog (not plain trackedWrite) for these,
    -- since each has its own pure validation phase worth running before the tracker arms
    -- -- see their own comment above. A bare fhu.createFact is also separately reachable
    -- via env.fhu (see FHU_WRITE_METHOD_NAMES above), but without this wrapper's
    -- pointer/tag validation or checkCreated failure check.
    local realSessionLogHelper = require('sessionLogHelper')
    local realFactHelper = require('factHelper')
    env.fhBridge.createSourceFromTemplate = validatedTrackedWrite(
      realSourceHelper.validateCreateSourceFromTemplate, realSourceHelper.createSourceFromTemplate)
    env.fhBridge.citeSource = validatedTrackedWrite(
      realSourceHelper.validateCiteSource, realSourceHelper.citeSource)
    env.fhBridge.logActivity = validatedTrackedLog(
      realSessionLogHelper.validateLogActivity, realSessionLogHelper.logActivity)
    env.fhBridge.setTftfText = validatedTrackedWrite(
      realRichTextHelper.validateSetTftfText, realRichTextHelper.setTftfText)
    env.fhBridge.createFact = validatedTrackedWrite(
      realFactHelper.validateCreateFact, realFactHelper.createFact)
  end

  return env, tracker
end

return M
