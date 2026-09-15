# Domain — Session lifecycle terms

- **Session**: period between Start and Stop (or idle timeout / socket STOP / dialog
  close) on the Bridge plugin dialog. Access mode is fixed at Start for the whole Session.
  Avoid "Connection" — one Session spans many short-lived socket connections (one per
  run_lua call).
- **Exit** vs **Stop**: Exit closes the whole Bridge plugin (releases FH's main-window
  lock); Stop only ends the Session, plugin stays loaded, lock stays held. FH's main
  window is locked from plugin-load through Exit, not just Start-to-Stop — deliberate.
  Never use "Stop" when Exit is meant.
- **Access mode**: read-only/read-write toggle set once at Start. Read-write adds the full
  write API (`fhSetLabelledText`, `fhSetValueAs*`, `fhCreateItem`, `fhDeleteItem`,
  `fhMoveItemAfter/Before`, `fhSrcEnableAutoTitle`, unguarded `fhGetFactTag/fhGetFlagTag`).
  Avoid "Permission level" / bare "mode".
- **Visibility settings** (issue #141): two independent levels, one for the Private Record
  Flag and one for the Living Record Flag, each `"exclude"`/`"nameOnly"`/`"all"`, set once
  at Start in the same Settings popup as Debug logging (`bridgeSession.lua`'s
  `currentPrivacySettings()`, persisted via `sessionSettings.lua`). Filters every
  `fhBridge.*` helper (most-restrictive flag wins per record) — does **not** filter raw
  `fh*`/`fhu` calls inside a `run_lua` script, by design, see ADR 0038. A restricted level
  auto-forces Debug logging on for that Session. `runScript.lua`'s `bulkEnumerationViolation`
  pre-scan rejects a script outright (before it runs) if it mentions the raw record-
  enumeration idiom (`MoveToFirstRecord`, `fhu.records`/`allItems`/`indiList`) while either
  level is restricted — narrows, doesn't close, the raw-access gap ADR 0038 documents.
  `describe_project`/`install_fh_plugin`'s fixed internal scripts are exempt from all of
  this (`request.forceReadOnly`) — reviewed source, not user-supplied `run_lua` text.
- **Sandbox**: `bridge/sandbox.lua`'s allowlisted `_ENV` — see `mem:conventions` for the
  allowlist-not-denylist rule. `fhu` is a proxied `fhUtils`, not the raw module (`require`
  isn't in the allowlist). 8 `fhu` methods are always blocked regardless of Access mode
  (pop real modal dialogs, or touch disk directly): getParam, createUpdateFact,
  pickIndividualPrompt, yes, stripCommas (UI-arg form), saveOptions, loadOptions,
  resetOptions.
- **FH auto-undo**: FH's own native undo (Ctrl-Z, or automatic on an uncaught Lua error).
  This project implements no undo logic of its own — `run_lua` deliberately re-throws a
  write script's runtime error rather than swallowing it, so this safety net fires (ADR
  0005). Avoid "Rollback" for this mechanism.
- **Version check**: a `VERSION` request sent ahead of every Bridge-talking call, comparing
  server/Bridge versions (ADR 0013). Major mismatch blocks the call; minor/patch mismatch
  only surfaces as a warning (`bridgeState.versionStatus` in describe_project, or result
  text elsewhere). Not a persistent handshake — every check is its own bodyless connection.
