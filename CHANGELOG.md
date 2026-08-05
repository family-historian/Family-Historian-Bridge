# Changelog

## Unreleased

### Bridge dialog: colour by Session state
- The Bridge plugin dialog's background now colours itself by state instead of relying
  solely on the status label's text: grey while stopped, green while listening
  read-only, amber while listening read-write (the one state where a script can mutate
  the project), red on a failed port bind.
- Set via `dlg.bgcolor`, not the status label — IUP native labels don't reliably honour
  `BGCOLOR`, confirmed not working live.

### `fhBridge.getFactsByTag` (issue #62)
- New helper in `bridge/familyHelper.lua`, alongside `getFamilyGroup`/`getAllDetails`/
  `getAncestors`/`searchByName`: `fhBridge.getFactsByTag(ptr, tags)` filters a record's
  own direct ("1st level") children down to the ones matching `tags` — an exact,
  case-sensitive FH tag string (e.g. `"CENS"`) or an array of them (e.g. `{"BIRT",
  "DEAT"}`) — and returns an array with one full `getAllDetails`-shape tree per match.
- Returns every match, not deduped/collapsed — a repeated tag (multiple `CENS` entries
  across census years, a Rejected + Preferred `BIRT`) is exactly what this exists to
  surface, so e.g. `getFactsByTag(indi, "CENS")` returns every census fact recorded on
  that Individual with its own `DATE`/`PLAC`/sources intact.
- Works on any record type, not just Individuals (`MARR`/`DIV` live on `FAM` records),
  and accepts a qualified id string the same way `getAllDetails` does.
- Returns an empty array — not an error — when nothing matches (same philosophy as
  `searchByName`'s no-results case); errors only on a null pointer or a malformed
  `tags` argument (nil, `""`, an empty array, or a non-string entry in the array).
- Wired into `env.fhBridge` unconditionally (both access modes), same as the other four
  read-only query helpers.

### `fhBridge.searchByName` (issue #62)
- New helper in `bridge/familyHelper.lua`, alongside `getFamilyGroup`/`getAllDetails`/
  `getAncestors`: `fhBridge.searchByName(forename, surname)` finds every Individual whose
  given name(s) contain `forename` and whose surname contains `surname`, matched
  case-insensitively as substrings, not exact/whole-word — `searchByName("Robert",
  "Taubman")` also matches "Robert Henry TAUBMAN". Either argument may be omitted/`""`
  to skip filtering on that part of the name; passing neither raises an error rather
  than silently scanning every Individual in the project.
- Matches against the NAME field's `GIVEN_ALL`/`SURNAME` Data Reference qualifiers, not
  the raw stored NAME text or `fhIndGetName`'s display string, so it matches consistently
  regardless of how a given record orders/prefixes its name parts.
- Returns an array of the same `{id, qualifiedId, name, sex}` descriptor shape as
  `getFamilyGroup`/`getAncestors`'s own `.individual` field, in FH's own record order.
  Unlike the other three helpers it takes no pointer/qualified-id argument — it scans
  every Individual record in the project itself.
- Wired into `env.fhBridge` unconditionally (both access modes), same as the other three
  read-only query helpers.

### `fhBridge.getFamilyGroup`/`getAllDetails`/`getAncestors` (issue #62)
- New `bridge/familyHelper.lua` module, three read-only tree-walking helpers so a
  `run_lua` script doesn't have to hand-roll the FAMS/FAMC/HUSB/WIFE/CHIL "SAME_TAG"
  MoveTo/MoveNext dance every time: `fhBridge.getFamilyGroup(indiPtr, type)` (`type`:
  `all`/`parents`/`siblings`/`spouses`, default `all`) returns every relative reachable
  through any of the Individual's FAMC/FAMS records as `{relationship, individual,
  family}`; `fhBridge.getAncestors(indiPtr, maxGenerations)` walks the same FAMC chain
  breadth-first as `{generation, line, individual, family}`, deduped by record id
  (pedigree collapse) so a malformed cyclic project can't loop it forever;
  `fhBridge.getAllDetails(ptr)` recursively describes any item pointer — a whole
  record or a single field/Fact — as one plain tree of tag/value/link/children.
- Unlike `sourceHelper.lua`/`sessionLogHelper.lua`, every fh* function this module
  calls is a read primitive already granted in the sandbox's Read-only half, so
  `sandbox.lua` now builds `env.fhBridge` unconditionally (both access modes) with
  these three, and only *adds* the write-gated `createSourceFromTemplate`/
  `citeSource`/`logActivity` members on top under Read-write — `env.fhBridge` is no
  longer Read-write-only itself.
- Every function returns plain JSON-safe descriptor tables (id/qualifiedId/name/etc.),
  never a raw Item Pointer — jsonEncode.lua can't encode one, so a helper that handed
  one back would break the first time a script returned it.
- All three also accept a qualified id string (e.g. `"I219"`, exactly the form every
  `.qualifiedId` field they return already uses) anywhere they take a pointer, resolved
  via `MoveToRecordById` — so a script can call `fhBridge.getAllDetails(entry.individual.qualifiedId)`
  straight off a `getFamilyGroup`/`getAncestors` result entry, without re-resolving it to
  a live pointer by hand first. `getFamilyGroup`/`getAncestors` raise a clear error if the
  id resolves to a non-Individual record.
- Verified live against a real ~4000-Individual project (multiple FAMS records, custom
  facts, shared facts, richtext notes with private-text markers): all three walk real
  multi-marriage/multi-sibling families correctly and every error path (bad `type`, null
  pointer, malformed/unresolvable qualified id, wrong record type) returns a clean,
  catchable error rather than crashing the Session.
- New `run-lua-guidance-family-query-helpers` entry in `gedcom-knowledge-corpus.jsonl`
  (the same `search_gedcom_knowledge("run_lua guidance")`-bundled family as the
  call-shape-gotchas/citeSource/writeSessionRolledBack/fhu-global/logActivity entries)
  documents all three functions' call shapes, the qualified-id-string shortcut, and that
  they're available under Read-only too — so a session using this MCP actually discovers
  them instead of hand-rolling the FAMS/FAMC walk itself. `RUN_LUA_DESCRIPTION`'s and
  `SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION`'s own enumeration sentences updated to name it,
  both still within their respective truncation-safe-zone byte budgets.

### logActivity guidance moved to the corpus, tool description shrunk
- `fhBridge.logActivity`'s call shape, media/`#ToDo` detail, and the `fhGetDisplayText`
  action-composition tip — previously inline in `RUN_LUA_DESCRIPTION`, past the ~2KB point
  MCP clients truncate at — now live in a new `gedcom-knowledge-corpus.jsonl` entry
  alongside `logActivity`'s own missing piece: that it produces an ordinary `_RNOT` record,
  visible in FH's Research Notes and readable back via `fhu.records("_RNOT")`. A session
  that called `logActivity` correctly had no documented way to confirm what it did or where
  the result went. (#55)
- `RUN_LUA_DESCRIPTION` shrunk from 3697 to under 1900 bytes overall (previously ended its
  safe zone at byte 1936, only 112 bytes under the ~2048 truncation point); every paragraph
  now sits safely inside the cutoff instead of just the truncation notice itself.

## 0.6.0

### Force UTF-8 string encoding, in the Bridge plugin and in generated plugins
- The Bridge plugin now calls `fhSetStringEncoding("UTF-8")` at startup, right after
  `fhInitialise` and before any `require()`. Confirmed live (via `describe_project`'s new
  `contextInfo`) that an unmodified install otherwise runs in ANSI, which silently mangles
  accented/non-ASCII names, places, etc. as they cross the FH API — a real risk for a
  genealogy tool.
- `bridge/scripts/build.lua` now also prepends a UTF-8 BOM (`EF BB BF`) to the
  `bridge/dist/Claude MCP Bridge.fh_lua` artifact it writes. Needed in addition to the
  `fhSetStringEncoding` call above — confirmed live that a build without the BOM still
  loaded into FH as ANSI, since `fhSetStringEncoding` only sets the encoding at runtime,
  after the file's already been loaded, and doesn't affect how FH detects the file's
  on-disk encoding in the first place.
- `install_fh_plugin` now writes every plugin file as UTF-8 with the same leading BOM,
  which FH's own file-encoding detection looks for — a plain file with no marker loads as
  ANSI even though FH's Plugin Editor defaults new plugins to UTF-8. `author_fh_plugin`'s
  install-instructions footer now also tells the user to save as UTF-8 themselves, for the
  manual-save path this tool doesn't cover.

### `fhGetFlagTag`/`fhGetFactTag` read-only lookup
- `run_lua`'s Read-only sandbox no longer excludes `fhGetFlagTag`/`fhGetFactTag`
  entirely — their pure `bCreateIfNone=false` lookup branch now works read-only
  (returning an existing flag/fact type's tag, or `""` if not found), while the
  `bCreateIfNone=true` schema-creating branch still raises a clear error there. Both
  functions were previously blocked outright even for a lookup that can never mutate
  the tree. (#51)

### describe_project: flag census and a data-quality signal
- `describe_project` now returns `flagCensus` — a per-tag breakdown of Individual record
  flags (`__LIVING`/`__PRIVATE` and any project-specific custom ones), each with its
  occurrence count and a human-readable label — instead of only the single aggregate
  `_FLGS` count `tagCensus` already gave. Answering "how many living people are in this
  project" previously required a full `run_lua` script; it's now a direct read of
  `flagCensus.__LIVING`.
- Also returns `dataQuality.livingStatusAmbiguousCount`: Individuals with a resolved
  birth date, no `DEAT`/`BURI`/`CREM` fact, and no Living flag set — the shape of a
  missing-data gap that the common "no death record therefore presumed living" heuristic
  would otherwise silently get wrong. See
  docs/adr/0014-describe-project-flag-census-and-data-quality-namespace.md. (#51)

### describe_project: contextInfo (issue #51 follow-up)
- `describe_project` now also returns `contextInfo` — every documented `fhGetContextInfo`
  `CI_*` value that's a plain string/boolean (`CI_PROJECT_NAME`, `CI_PROJECT_FILE`,
  `CI_GEDCOM_FILE`, `CI_PROJECT_PUBLIC_FOLDER`, `CI_PROJECT_DATA_FOLDER`,
  `CI_PLUGIN_NAME`, `CI_APP_DATA_FOLDER`, `CI_APP_MODE`, `CI_STRING_ENCODING`). This was
  part of the original #51 request but was missed from the itemized implementation plan;
  caught on a later review pass. `CI_APP_HWND`/`CI_PARENT_HWND` (window handles — Lua
  light userdata, which the Bridge's JSON encoder can't represent) and the report/book-only
  `CI_BOOK_CONTEXT`/`CI_BOOK_ITEM_HEADING` are deliberately left out. (#51)

### GEDCOM knowledge corpus Date/DatePoint guidance
- Added two entries to `run-lua-guidance-call-shape-gotchas`: `Date`/`DatePoint` objects
  have no `GetDatePoint()` method (`dt:GetDatePt1()`/`dt:GetDatePt2()` are the correct
  names), and a Data Reference qualifier (e.g. `fhGetItemText(ptr, "~.BIRT.DATE:YEAR")`)
  is the simpler default for extracting a date component, with the Date/DatePoint object
  chain reserved for `dt:Compare()`/`dp:Compare()` needs. (#51)

## 0.5.0

### Server version reporting
- Fixed the MCP server's self-reported `version` (seen by clients in the `initialize`
  handshake), which was hardcoded to `0.1.0` and never tracked `server/package.json`'s
  actual version across the 0.2.0-0.4.0 releases. It now reads `version` from
  `package.json` at startup. (#44)

### Bridge/server version-mismatch detection
- The server now sends a `VERSION` request over its own connection ahead of every
  `run_lua`/`describe_project`/`install_fh_plugin` call, comparing the Bridge's and
  server's versions: a major-version mismatch refuses the real request, anything else
  just appends a note. An old Bridge that doesn't know the `VERSION` verb gets a
  specific "reinstall the Bridge plugin" message instead of a generic error.
  `BRIDGE_VERSION` is now injected into the Bridge bundle at build time from the
  existing `@Version` header, so it's readable at runtime without a hand-synced
  duplicate. Design worked out interactively in issue #45's comments; see
  `docs/adr/0013-bridge-server-version-mismatch-check.md`. (#45)

### fh-help and GEDCOM knowledge corpus guidance
- `RUN_LUA_DESCRIPTION` and the truncation-safe call-shape-gotchas corpus entry both
  scoped the "check `fhu` first" reminder to write mutations only, steering an LLM to
  hand-roll `MoveToFirstRecord`/`MoveNext` instead of `fhu.records(type)` for a
  read-only iteration; the guidance now covers reads too. Also documents that `fhu` is
  already a global in this sandbox — `require('fhUtils')` returns `nil` here, unlike in
  an ordinary FH plugin. Fixes the same misleading phrasing in `CONTEXT.md`'s Sandbox
  entry. (#46, #47, #48)
- `search_gedcom_knowledge`'s own topic list, and the run-lua-guidance bundle, now
  surface the Data Reference qualifier codes (name/date/place-latlong) that already
  existed in the corpus but had no cue pointing to them — a session had previously
  rediscovered qualifiers like `:GIVEN_ALL` indirectly via fh-help sample scripts
  instead. (#49)
- Synced the bundled fh-help corpus (993 -> 994 topics) after upstream fh-help fixes:
  `fhu.<name>` title aliases so exact-name grep works, and a dedicated "Iterating over
  records" entry that outranks the raw sample scripts for iteration-flavored queries.
- Added a help-corpus entry documenting the `fhNewItemPtr()` vs `fhCreateItem()`
  iteration gotcha, after a session used `fhCreateItem()` to set up iteration when
  `fhNewItemPtr()` was needed — `fhCreateItem()` creates real database records while
  `fhNewItemPtr()` creates an empty pointer for navigation, so the mistake left unwanted
  items in the database and triggered write-protection errors.
- Trimmed `RUN_LUA_DESCRIPTION`, which had grown to 3.59 KB and exceeded the MCP
  client's 2KB truncation limit, back within budget: the iteration-gotcha guidance now
  lives only in the help corpus (discoverable via
  `search_fh_help("fhNewItemPtr iteration")`), not duplicated in the tool description.

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
