-- Luacheck config for bridge/ (issue #92-style lint gate, Lua side).
--
-- Scope: bridge/ only -- installer/ and server/ are TS/JS, covered by oxlint instead.
--
-- Line length is deliberately NOT checked: the codebase already runs long lines in
-- comments and error-message strings well past any conventional limit (290 chars in
-- bridge/sandbox.lua, for instance), and that's existing, intentional style, not lint debt.
--
-- The FH plugin API (fh*, fhu.*) is injected as globals by the FH host at runtime --
-- there's no require'd module luacheck can see, so every fh* name has to be declared
-- by hand below or luacheck flags it as an undefined global on every call site. This
-- list was generated from actual usage across bridge/*.lua and bridge/tests/*.lua
-- (see fh-lua-api-lookup.md for how new fh*/fhu.* calls should be verified before use --
-- this list is not itself an API reference).

std = "lua54"
max_line_length = false

-- IUP callback methods (function widget:action_cb() etc.) bind self implicitly, per IUP's
-- own convention, and the body legitimately never needs it. Not a real unused-arg smell.
self = false

globals = {
  -- IUP registers itself as this global as a side effect of require("iuplua") --
  -- that's the library's own convention, not something this codebase controls.
  "iup",
  -- Injected as a `local` by bridge/scripts/bundler.lua when building the bundled
  -- .fh_lua (issue #89) -- undeclared here because bridgeSession.lua itself, as
  -- checked by luacheck, is pre-bundling source.
  "BRIDGE_VERSION",
  "fhu",
  "fhBeginsWithVowel",
  "fhBridge",
  "fhCallBuiltInFunction",
  "fhCallViolation",
  "fhCommit",
  "fhConvertANSItoUTF8",
  "fhConvertUTF8toANSI",
  "fhCreateItem",
  "fhDeleteItem",
  "fhDisplayRichTextBox",
  "fhExhibitResponsiveness",
  "fhFoo",
  "fhFtfEncode",
  "fhFtfParamEncode",
  "fhGetAppVersion",
  "fhGetClipboardData",
  "fhGetContextInfo",
  "fhGetCurrentPropertyBoxRecord",
  "fhGetCurrentRecordSel",
  "fhGetDataClass",
  "fhGetDataList",
  "fhGetDisplayText",
  "fhGetFactTag",
  "fhGetFactTypeInfo",
  "fhGetFlagTag",
  "fhGetGedcomInfo",
  "fhGetIniFileValue",
  "fhGetItemPtr",
  "fhGetItemText",
  "fhGetLabelledText",
  "fhGetMetafieldDefinition",
  "fhGetMetafieldShortcut",
  "fhGetMetafieldType",
  "fhGetNamedList",
  "fhGetNamedListByIndex",
  "fhGetNamedListCount",
  "fhGetNarrSentence",
  "fhGetNarrSentenceTemplate",
  "fhGetPluginDataFileName",
  "fhGetQualifiedId",
  "fhGetQualifiedRecordId",
  "fhGetRecordId",
  "fhGetRecordLinks",
  "fhGetRecordTypeCount",
  "fhGetRecordTypeTag",
  "fhGetStringEncoding",
  "fhGetTag",
  "fhGetTypeInfo",
  "fhGetValueAsAge",
  "fhGetValueAsBlob",
  "fhGetValueAsDate",
  "fhGetValueAsInteger",
  "fhGetValueAsLink",
  "fhGetValueAsRichText",
  "fhGetValueAsText",
  "fhGetValueType",
  "fhHasChildItem",
  "fhHasNextSibItem",
  "fhHasParentItem",
  "fhHasPrevSibItem",
  "fhIndGetFactList",
  "fhIndGetName",
  "fhInitIdx",
  "fhInitialise",
  "fhIsAttribute",
  "fhIsConversionLossFlagSet",
  "fhIsEvent",
  "fhIsFact",
  "fhIsHidden",
  "fhIsUDF",
  "fhIsValidDataRef",
  "fhLoadTextFile",
  "fhMessageBox",
  "fhMoveItemAfter",
  "fhMoveItemBefore",
  "fhNewAge",
  "fhNewDate",
  "fhNewDatePt",
  "fhNewItemPtr",
  "fhNewRichText",
  "fhNewSection",
  "fhOutputNote",
  "fhOutputResultSetColumn",
  "fhOutputResultSetTitles",
  "fhOverridePreference",
  "fhPromptUserForDate",
  "fhPromptUserForRecordSel",
  "fhPromptUserForRichText",
  "fhRollback",
  "fhSaveTextFile",
  "fhSet",
  "fhSetConversionLossFlag",
  "fhSetIniFileValue",
  "fhSetLabelledText",
  "fhSetStringEncoding",
  "fhSetValueAs",
  "fhSetValueAsAge",
  "fhSetValueAsBlob",
  "fhSetValueAsDate",
  "fhSetValueAsInteger",
  "fhSetValueAsLink",
  "fhSetValueAsRichText",
  "fhSetValueAsText",
  "fhShellExecute",
  "fhSleep",
  "fhSrcEnableAutoTitle",
  "fhSrcIsAutoTitleEnabled",
  "fhUpdateDisplay",
  "fhUtils",
  "fhX",
}

exclude_files = {
  "bridge/dist/*",
}

-- Test doubles in bridge/tests/ deliberately mirror the real fh*/fhu.* function
-- signatures they're standing in for (so a signature mismatch is obvious at the call
-- site), which means many of their parameters go unused inside the fake body itself.
-- That's the point of the mock, not a lint smell -- unlike production code, where an
-- unused argument still gets flagged normally.
files["bridge/tests/*.lua"] = {
  unused_args = false,
}
