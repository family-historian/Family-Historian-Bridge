# Changelog

## Unreleased

### Server version reporting
- Fixed the MCP server's self-reported `version` (seen by clients in the `initialize`
  handshake), which was hardcoded to `0.1.0` and never tracked `server/package.json`'s
  actual version across the 0.2.0-0.4.0 releases. It now reads `version` from
  `package.json` at startup. (#44)

## 0.4.0

### Session-log helper
- Added `bridge/sessionLogHelper.lua`, exposing `fhBridge.logActivity(ptrRecord, action)`
  (read-write only): logs a Session's record-creating activity into one Research Note
  (`_RNOT`) per Session, creating it (titled with a creation timestamp) on the first call
  and appending further entries to the same note on every subsequent call in that Session.
  Each entry's record reference is a live, clickable FTF record link, not plain text. (#36)

### Bundled build for installation
- Fixed the Bridge plugin's own install-file-list comment, which had drifted out of sync
  with `bridge/README.md`'s list (missing `requestFraming.lua` and `sourceHelper.lua`) —
  the same drift already caught once in the 0.2.0 entry below, recurred.
- Added `bridge/scripts/build.lua`, bundling the plugin's seven source files into one
  self-contained `bridge/dist/Claude MCP Bridge.fh_lua` via `package.preload`, so the
  installed artifact matches FH's own single-file plugin convention instead of requiring
  seven files copied together. The source tree stays split for standalone per-module
  testing (`bridge/tests/*.test.lua`, now including `build.test.lua` for the bundler
  itself). See `docs/adr/0009-bundle-bridge-plugin-for-install.md`. Install docs
  (`README.md`, `docs/user-guide.md`, `bridge/README.md`) and `docs/release.md` now point
  at the bundled file instead of listing all seven source files.

### Save prompt and display refresh
- The Bridge plugin now calls `fhInitialise(7, 0, 0, "save_required")` as its first
  statement, before any `require()`, so FH prompts to save unsaved changes the moment the
  plugin loads rather than silently leaving the project unsaved for the whole Session.
  Cancelling the prompt ends the plugin before its own dialog ever appears. (#33)
- The Bridge now calls `fhUpdateDisplay()` after every accepted `LUA`/`LUA_RO` request, so
  a write script's changes show up on FH's own screen immediately instead of only after
  the user next interacts with FH. (#33)

### Idle-timeout control
- The Session idle auto-Stop timeout, previously a hardcoded 300s (5 min) constant, is now
  a spin-box in the Bridge dialog (5–120 minutes, matching the previous default), editable
  only while the Session is stopped. A live "Time left: M:SS" countdown label shows the
  time remaining before auto-Stop. Pure formatting/conversion/clamping logic lives in the
  new `bridge/timeoutDisplay.lua`, with its own standalone tests. The value is not
  persisted between plugin loads — it resets to 5 minutes each time. (#34)
- Deliberately deferred to a follow-up issue: including timeout information in the
  client's `run_lua` response, and letting a client request a longer timeout — both would
  require redesigning the run_lua wire response shape, which a prior decision (see
  `bridgeResponse.ts`'s "ticket #2" comment) already chose not to do for a smaller case.
  (#35)

## 0.3.0

### fhu sandbox escape hatches
- Eight `fhu` (`fhUtils`) methods that bypassed the sandbox entirely are now replaced
  with an error-raising wrapper, in both Read-only and Read-write: `getParam`,
  `createUpdateFact`, `pickIndividualPrompt`, and `yes` open a real modal dialog inside
  FH via `iup.Popup` and would hang a headless `run_lua` call; `saveOptions`,
  `loadOptions`, and `resetOptions` read/write a plugin-data file on disk directly,
  bypassing this project's filesystem exclusion policy. `stripCommas` is the one
  conditional case — safe called with just its text argument, and now raises the same
  error only when its optional `sQuestion`/`sTitle`/`hParent` arguments are present.
  `createUpdateFact` is also a write method, but the new check takes priority, so it
  never forwards to the real (hang-prone) function even under Read-write. Raising a
  named error rather than leaving these silently absent (nil, like the raw `fh*`
  exclusions) gives Claude a self-correctable message instead of a generic "attempt to
  call a nil value". (#22)

### GEDCOM knowledge corpus
- Added Data Reference qualifier codes (Date, Name, Place/lat-long) to
  `gedcom-knowledge-corpus.jsonl`, transcribed from an FH developer-supplied source
  header (`g_QualArr`) and cross-checked against the Date/Name/Place Formats help
  pages and Understanding Data References. Fills in canonical qualifier name
  strings, aliases (COMPACT/SHORT, ABBREV/MEDIUM), record-type restrictions, and
  gotchas (undocumented LONG_FS/COMPACT_FS; the 'NUMERIC' qualifier name being
  reused, unrelated, for both lat/long and custom-attribute editing).
- Added a `data-references-syntax` entry covering the general Data Reference
  grammar (%TAG.FIELD:QUALIFIER% dot/chevron/index/shortcut/contextual-ref
  syntax) that the qualifier codes above, and Sentence Templates, both sit on
  top of — qualifiers are a Data Reference feature, not a Sentence-Template-only
  one; the entries above were corrected mid-session after initially mislabeling
  them as sentence-template-specific.

### fh-help resource reads
- `fh_help_page`'s resource template no longer implements `list` — `resources/list` was
  returning all ~993 corpus topics unpaginated (~258 KB, no `nextCursor`; this SDK version
  doesn't support cursor pagination at that layer regardless). No caller needs to browse
  the full corpus: `search_fh_help` already returns the exact `uri` to read, and
  `resources/read` matches by URI-template pattern independent of `list`. (#20)
- Investigated why an MCP client failed to read `fh-help:` resource uris despite the
  server advertising and correctly serving them at the protocol level — root cause is
  client-side, not fixable here. `search_fh_help`'s description no longer promises
  resource reads as a reliable path to full text. See ADR 0007. (#20)

### Write-mode error handling
- A read-write Session's script errors, when the script actually wrote something
  first, now end the whole Bridge plugin with the error uncaught, giving FH's own
  auto-undo a real chance to undo the partial write — confirmed against a real
  FH8/CrossOver install: FH shows its own "Plugin Error" dialog with a Yes/No undo
  prompt, and clicking Yes actually removes the written record. A write-mode script
  that errors before writing anything, and every Read-only script error, are
  unaffected (reported normally, Session stays up).
- Getting here took two iterations. The first attempt just re-raised the error inside
  the polling timer's callback and left the Session running — empirically, this never
  triggered FH's auto-undo at all (IUP swallows an error raised inside a callback
  before it escapes the plugin) and always left the write in place. The working
  version instead ends the whole plugin: the callback tears down the network side (the
  same path STOP uses) and returns `iup.CLOSE` (IUP's documented way for a callback to
  end its `iup.MainLoop()`), and the error is re-raised once `MainLoop()` returns,
  genuinely at the plugin's top level. Safe here because FH itself isn't IUP-based —
  only plugins are — so this plugin process is always the sole owner of any loop it
  starts. `docs/adr/0005-write-mode-errors-rethrown-for-fh-auto-undo.md` has the full
  history and both test results.
- Whether a script "actually wrote something" is now tracked precisely
  (`sandbox.lua`), not inferred from access mode alone: every raw write primitive
  (`fhCreateItem`, `fhSetValueAs*`, etc.) and every `fhUtils` (`fhu`) method that
  writes tree data (`createIndi`, `addFamilyAsChild`, `createFact`, and 7 others —
  found by reading `fhUtils.lua`'s actual source, since the help corpus doesn't
  document all of them) is wrapped to flip a per-script tracker. This closed a
  pre-existing gap found along the way: `fhu`'s write methods were reachable from a
  Read-only Session too, since `fhu` is FH's real, unsandboxed module and bypasses this
  project's `env` allowlist entirely — folded into this same fix rather than filed
  separately, since it needed the same write-method list either way. Two remaining
  `fhu` escape hatches (modal dialogs that would hang a headless `run_lua` call;
  `saveOptions`/`loadOptions`/`resetOptions` writing straight to disk) are out of scope
  here and tracked as #22.
- `writeSessionRolledBack: true`'s wording (`RUN_LUA_DESCRIPTION` and the Bridge's own
  error-response hint) matches the confirmed behavior: FH's auto-undo needs a human to
  click Yes on its own dialog, and the Bridge Session has ended and needs restarting —
  neither of which run_lua can do on the user's behalf. (#15)

### Plugin headers
- Bridge plugin renamed `bridge.fh_lua` -> `Claude MCP Bridge.fh_lua` and given the
  standard `@Title`/`@Type`/`@Author`/`@Version`/`@Keywords`/`@LastUpdated`/`@Licence`/
  `@Description` header block FH's plugin store expects.
- `author_fh_plugin` tool now generates that same standard header for both Report and
  Query plugins it authors, filled in from new optional `title`/`description`/
  `keywords`/`version`/`author` inputs (sensible defaults when omitted).
- Bridge dialog's title bar now reads "Claude MCP Bridge", matching the plugin's
  `@Title` instead of the old "FH Bridge". (#25)

### install_fh_plugin tool
- New `install_fh_plugin` tool writes a plugin `author_fh_plugin` generated directly
  into FH's Plugins folder, on the user's explicit request only — staged as a second,
  separate tool call, never chained on automatically. Never overwrites an existing
  file: each install gets the next unused `V<N>` suffix on both the filename and the
  plugin's own `@Title` header. The Plugins folder location is resolved live via
  `fhGetContextInfo("CI_APP_DATA_FOLDER")` (falling back to an explicit `path` param
  when no Bridge Session is running), avoiding the FH7/FH8 side-by-side Plugins-folder
  footgun documented in docs/user-guide.md. (#24, ADR 0008)

### Packaging
- Version bumped to 0.3.0 (0.2.0 already released on Forgejo).

## 0.2.0

### Read-write Access mode wired end-to-end
- Bridge dialog's Access mode (Read-only / Read-write) now threads through
  to the sandbox: `bridge.fh_lua` passes `currentAccessMode()` into
  `runScript.run`, which passes it into `sandbox.build`. (#13)
- Read-write sandbox builds now expose FH's full write API — every
  `fhSetValueAs*` setter, `fhSetLabelledText`, `fhCreateItem`,
  `fhDeleteItem`, `fhMoveItemAfter/Before`, `fhSrcEnableAutoTitle`,
  `fhGetFactTag`/`fhGetFlagTag` — gated behind Read-write, absent under
  Read-only. `describe_project`'s fixed census script is forced Read-only
  regardless of the Session's mode. (#14, #16)
- Documented the full write-API surface and why write-mode script errors
  are re-thrown rather than swallowed, so FH's own undo history stays
  usable (ADR 0005).

### Source citation tooling
- New `fhBridge.createSourceFromTemplate(templateNameOrId, fields, transcription)`
  bridge helper (`bridge/sourceHelper.lua`) — one call replaces hand-rolled
  `fhCreateItem("SOUR", ...)` + per-field `fhSetValueAsLink` sequences for
  template-based Source creation. (#18)
- New `fhBridge.citeSource(ptrTarget, sourceIdOrTitle)` helper — cites an
  existing Source against a Fact or whole record by id or by title, same
  by-id-or-by-title resolution as `createSourceFromTemplate`.
- `run_lua`'s tool description now steers Claude to cite *every* Fact a
  Source actually supports (not just the one asked about), and to list
  any gaps found and wait for confirmation before writing them.
- Documented templated Source creation in the gedcom-knowledge corpus
  (`_SRCT` link, FDEF field definitions, `~PREFIX-CODE` field syntax) and
  fixed a `_SRCT` scope conflation in that write-up.

### Safety and guidance hardening
- `run_lua`'s tool description now requires searching FH help / the
  gedcom-knowledge corpus before hand-rolling low-level primitives —
  prompted by a live script that hand-rolled a CHIL/FAMC link instead of
  using the existing helper. (#17)
- Documented that `fhu.*` creator functions (e.g. `fhu.createIndi`) don't
  validate their arguments — a missing/wrong arg still creates a real,
  permanent record instead of erroring.

### Cleanup
- Removed the superseded `bridge_prototype_v2.fh_lua` and its stale
  handover doc.
- Moved bridge Lua unit tests into `bridge/tests/`, so everything directly
  in `bridge/` is exactly what gets copied into FH's Plugins folder.
- Fixed README/user-guide install instructions to list all seven bridge
  files (`requestFraming.lua`, `sourceHelper.lua` were missing).
- Fixed a sandbox test that over-matched `fhBridge` itself as an excluded
  primitive.

### Packaging
- Version bumped to 0.2.0 (0.1.0 already released on Forgejo).

## 0.1.0

First packaged release. Bridge plugin + MCP server (`run_lua`,
`describe_project`, FH help search/update-check), sandboxed script
execution, Session Access-mode selector and idle-timeout auto-Stop.
