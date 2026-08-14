# Changelog

## Unreleased

## 0.13.0

### GEDCOM knowledge corpus: typed getter dispatch, Source duplicate detection, corrected save/rollback mechanics, unsolved mid-document RichText edit (issue #107)
- `run-lua-guidance-call-shape-gotchas` gains a bullet on `fhGetValueType`/`fhGetDataClass`-
  driven dispatch across the 7 typed `fhGetValueAs*` getters — `fhGetValueAsText` is not
  universal and silently returns `""` on a Date-class item rather than erroring;
  `fhGetDisplayText` is a display-formatting helper, not a raw-value substitute.
- `run-lua-guidance-write-session-rolled-back` corrects the save-cadence mitigation added
  for #105: stopping the Session (`btnStop`) leaves the Bridge dialog open and does not
  unlock Family Historian's main window or reset the rollback boundary — confirmed against
  `bridge/bridgeSession.lua` (Stop only unbinds the listener; `fhInitialise`'s
  save-required gate only fires at plugin load). Only closing the plugin window
  (Exit/window X) and reopening it does either.
- `duplicate-individual-detection-no-builtin-api` generalized to cover Source-record
  duplicates too (real case: S28/S351, two records for one certificate), with the
  title-substring scan that found it.
- New entry `run-lua-guidance-mid-document-richtext-edit-unconfirmed` (confidence:
  Likely, i.e. unverified live): documents that editing inside an existing large RichText
  field is unsolved — `SetText`/`tblRecLinks` and `Add*`-append are both known
  insufficient — and records the untested `Empty()`+full-rebuild-via-`Add*` hypothesis for
  a future session to verify before relying on it.

### GEDCOM knowledge corpus: writeSessionRolledBack blast radius, SetText/tblRecLinks limitation, full Item Pointer nav method list (issues #104, #105, #106)
- `run-lua-guidance-write-session-rolled-back` clarifies that a `writeSessionRolledBack`
  undo is FH's own document-level Undo, discarding every unsaved write in the Session (not
  just the failing script's own), plus a save-cadence mitigation (issue #105; corrected by
  the #107 entry above).
- New entry `run-lua-guidance-settext-reclinks-cannot-add-new-links`:
  `RichText:SetText`'s `tblRecLinks` parameter only works as an exact passthrough of
  `GetText()`'s own result; a brand-new or extended table returns false silently.
  `AddRecordLink` on a live RichText object (per `bridge/sessionLogHelper.lua`'s own
  working pattern) is the actual way to add a new record link (issue #106).
- `run-lua-guidance-call-shape-gotchas` gains the full Item Pointer navigation method list
  (`MoveToFirstChildItem`, `MoveToParentItem`, `MoveNext`/`MovePrev`, `MoveToRecordItem`,
  `MoveTo`, `MoveToRecordById`, `MoveToFirstRecord`, `MoveNextSpecial`) so sibling/parent/
  record moves don't get guessed by analogy (issue #104).

### fhBridge/fhu discoverability: no index/catalog of helper functions in the corpus (issue #102)
- `fhBridge.*` (12 functions across `familyHelper.lua`/`sourceHelper.lua`/
  `sessionLogHelper.lua`) had zero corpus entries anywhere, unlike raw `fh*` globals
  (fh-help's "Function Index") or `fhu.*` (fully documented, just unindexed). Added one
  compact entry per function — Description/Parameters/Returns, matching the style of the
  existing `fhu.md`-derived entries — to `gedcom-knowledge-corpus.jsonl`, under a new
  `"Bridge project conventions" > "fhBridge API reference"` breadcrumb family alongside
  the existing `"run_lua guidance"` family (docs/adr/0024). All 12 are reachable in one
  `search_gedcom_knowledge("fhBridge API reference")` or `grep_gedcom_knowledge` call.
- New test (`gedcomKnowledge.test.ts`) asserts this family's function names exactly match
  `sandbox.lua`'s own `env.fhBridge` table, parsed from the real file rather than a
  hand-kept list — so a 13th `fhBridge` function fails a test until documented, instead of
  silently repeating this issue.
- `fhu.*` (42 methods as of this writing, already fully documented in
  `fh-help-corpus.jsonl`) got a discoverability-only fix instead of new corpus content,
  matching the precedent set for the analogous `fh*` Function Index gap: `grep_fh_help`
  the `"fhUtils.md"` breadcrumb to list every entry across 2 calls.
- `docs/agents/fh-lua-api-lookup.md` and the `grep_fh_help`/`grep_gedcom_knowledge` tool
  descriptions now point at both (kept within the ~2048-byte deferred-tool-loading
  budget — `RUN_LUA_DESCRIPTION`/`SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION` were already full,
  so the new pointers went on the two `grep_*` descriptions instead, which had headroom).

### `grep_gedcom_knowledge` tool, mirroring `grep_fh_help` (issue #101)
- New MCP tool: literal-substring-by-default full-text search over the GEDCOM/FH
  domain-knowledge corpus, with a `regex: true` option, returning complete matching
  entries — the same shape `search_gedcom_knowledge` already returns, just without that
  tool's natural-language token-overlap ranking, which can bury an exact match (e.g. a
  literal function name) under unrelated entries sharing common words. Default/max match
  limit is 25 (not `grep_fh_help`'s 10/25) since this corpus is ~40 entries totaling well
  under 100KB, versus fh-help's ~1000 entries/2.7MB — no real risk of dumping "most of the
  corpus" the low default guards against there.
- The shared literal/regex matcher and capped-collection loop behind both grep tools moved
  into `corpusSearch.ts` (`buildGrepMatcher`/`grepEntries`), generic over either corpus's
  entry shape — `grep_fh_help` now delegates to the same shared function instead of a
  second, parallel implementation.
- `SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION` and `SEARCH_FH_HELP_DESCRIPTION` now point Claude
  at the matching grep tool when natural-language ranking doesn't surface what's needed.

### Re-safe-zoned `search_fh_help`/`search_gedcom_knowledge` tool descriptions
- Both descriptions had grown past the ~2048-byte deferred-tool-loading truncation point
  some MCP clients enforce (the same failure class docs/adr/0011 found and fixed for
  `RUN_LUA_DESCRIPTION` alone) — `search_gedcom_knowledge`'s had reached 3001 bytes,
  `search_fh_help`'s 2419, with no safe-zoning of their own. Both trimmed back under the
  observed cutoff while adding the new grep-tool fallback mention above, rather than
  growing either further unchecked.

### `RUN_LUA_DESCRIPTION` names `fhBridge` alongside `fhu` as a purpose-built helper to check before hand-rolling (issue #101 follow-up)
- The existing "before hand-rolling a tree walk, check for a helper" mandate only ever
  named `fhu`'s helpers — `fhBridge`'s own read-only family/detail query helpers
  (`getFamilyGroup`/`getAncestors`/etc.) were reachable only via the `"run_lua guidance"`
  corpus call, not this inline nudge. Widened within the existing ~2KB safe-zone budget.

### GEDCOM knowledge corpus: `MoveTo`'s bare-leading-dot Data Reference gotcha (issue #103)
- New bullet on `run-lua-guidance-call-shape-gotchas`: a Data Reference passed to `MoveTo`
  (or `fhGetItemPtr`/`fhGetItemText`/`fhGetDisplayText`) that starts with a bare `.` instead
  of `~` is neither valid form and silently resolves to "not found" (a Null pointer or an
  empty string, per call) rather than erroring — cross-references
  `run-lua-guidance-write-session-rolled-back` for what happens when this surfaces after an
  earlier write in the same script. Root-caused against a real incident: a birth-certificate
  transcription session's `child:MoveTo(otherPtr, '.DATE')` (missing the `~`) left a
  Null-forever pointer, and the resulting "not found" error after an earlier successful
  write triggered a full write-session rollback the user had to manually confirm past.

### Static pre-scan rejects a literal bare-leading-dot Data Reference (issue #103, docs/adr/0023)
- `runScript.lua` gains a third pre-scan (alongside the existing write-without-log and
  unrecognized-fh*-call checks, docs/adr/0012/0022), rejecting a `run_lua` script before
  execution if it passes a literal Data Reference string starting with a bare `.` to any of
  `MoveTo`/`fhGetItemPtr`/`fhGetItemText`/`fhGetDisplayText` — the four call shapes FH's
  plugin API accepts one on, none of which error on this input. Same literal-argument-only
  heuristic limitation as the existing pre-scans (a reference built into a variable first
  isn't caught); all three pre-scans' violations are still reported together in one
  response, not first-match-wins.

## 0.12.0

### Teaching workspace: MCP Bridge course for end-user genealogy workflows
- Five lessons covering Sessions/Access mode safety, asking trustworthy research questions,
  a first Read-write edit routine, standalone plugins, and the regular
  transcribe-create-cite source-entry workflow — kept in sync with issue #98/#99 as
  `citeSource` gained field support.

### `citeSource` supports standard citation fields and template CITN fields (issue #99)
- `citeSource(ptrTarget, sourceNameOrId, fields)` now takes an optional `fields` argument,
  mirroring `createSourceFromTemplate`, covering two families in one flat table: the 4
  GEDCOM/FH generic citation fields (Page/Text/EntryDate/Assessment — always valid
  regardless of whether the source is templated; Assessment is validated against FH's
  fixed 4-axis QUAY vocabulary, Text/EntryDate nest under a shared DATA child per GEDCOM
  5.5.1's SOURCE_CITATION structure), and a template's own citation-specific (CITN)
  fields, valid only when the resolved source is templated — a record-level field code
  passed here now errors clearly, symmetric with `createSourceFromTemplate`'s own #98 fix.
- A reserved standard-field name always wins over a same-named template CITN field
  (rejected as a clear collision); a record-level field sharing a reserved name isn't
  flagged, since it was never reachable through `citeSource` regardless.
- `citeSource` now returns the citation's own live item Pointer, not a `qualifiedId` — a
  citation isn't a standalone record with one.
- Fixed a pre-existing bug in `toDate()` found while live-testing this feature: FH's
  `fhNewDate` binding rejects an explicit `nil` in its optional 4th (`strSubType`) slot
  rather than treating it the same as the argument being omitted — `createSourceFromTemplate`'s
  own Date fields shared `toDate()` and were equally exposed. The unit-test fake was
  rewritten to use varargs so it can distinguish "called with 3 args" from "called with 4
  args, the 4th explicitly nil," which would have caught this.

### Reject citation-specific fields in `createSourceFromTemplate` (issue #98)
- `validateFields` used to silently no-op a citation-specific field code (`CITN="Yes"`)
  passed to `createSourceFromTemplate`'s record-level fields arg. Now it errors, naming the
  offending field. The check runs before any `fhCreateItem` call, so a mix of valid and
  invalid fields still creates nothing at all.

### Lint gate: oxlint (server) and luacheck (bridge) (issue #92)
- `typescript-eslint` is capped at `typescript <6.1.0` and has closed TS7 support as "not
  planned" upstream, so it's incompatible with this repo's `typescript@^7` pin. Adopted
  `oxlint`'s type-aware mode instead, which runs on `oxlint-tsgolint` — built directly on
  typescript-go/TS7 and version-locked to match this repo's compiler version. `npm run
  lint` (server/) runs `oxlint --type-aware src`, clean except one pre-existing
  false-positive (`no-control-regex` on an intentional filename sanitizer), now suppressed
  with a rationale comment rather than left to be re-noticed on every run.
- Added `luacheck` for `bridge/`: `.luacheckrc` scoped to `bridge/`, declaring the
  `fh*`/`fhu.*`/`iup`/`BRIDGE_VERSION` globals the FH host and build inject at runtime;
  `self=false` for IUP's implicit-self callback idiom; `unused_args` relaxed only in
  `bridge/tests/`, where mocks intentionally mirror real `fh*` signatures.
  `scripts/run-bridge-lint.mjs` resolves `luacheck` the same way
  `run-bridge-tests.mjs` resolves `lua` (`LUACHECK_BIN`, then `PATH`). The root `npm run
  lint` now runs oxlint then luacheck; `.githooks/pre-push` runs lint as a second step
  after the test suites (warnings exit 0 and don't block the push, only real lint errors
  do).
- Fixed what luacheck found before wiring it in: two missing `local`s in
  `bridgeSession.lua`/`familyHelper.test.lua` that were leaking as real globals — the
  exact bug class this exists to catch — plus assorted dead code left behind by issues
  #88 and #97, an unused parameter in `sourceHelper.lua`, and unused `pcall` error
  captures across `bridge/tests/*.lua`.

### Split validate/mutate so the write tracker doesn't arm on a rejected call (issue #97)
- `sandbox.lua` wrapped the entire `fhBridge.createSourceFromTemplate`/`citeSource`/
  `logActivity` call with `trackedWrite`/`trackedLog`, which flip `tracker.wrote`
  (and, for `logActivity`, `tracker.logged`) the instant the function is *entered* — before
  any of the validation issues #95/#96 added ever runs. Confirmed live against Family
  Historian Sample Project 8: a rejected `createSourceFromTemplate` call still ended the
  Bridge Session with FH's own Plugin Error/undo dialog, even though nothing was ever
  written and the caller's own `pcall` caught the error.
- Each of the three composite functions is now split into a pure validate half
  (`validateCreateSourceFromTemplate`/`validateCiteSource`/`validateLogActivity`) and the
  existing mutate half, which each now calls first — preserving the existing single-call
  contract for direct callers/tests. `sandbox.lua` gains two new wrapper builders,
  `validatedTrackedWrite`/`validatedTrackedLog`, which call the validate function
  untracked and only arm the tracker once validation has actually passed.

### Validate `ptrTarget` up front in `sourceHelper.citeSource` (issue #96)
- Follow-up audit after issue #95: `citeSource` validated `sourceNameOrId` but never
  `ptrTarget`, which went straight into `fhCreateItem("SOUR", ptrTarget")`. Since
  `sandbox.lua`'s `trackedWrite` flips the write tracker before the wrapped `fh*` call even
  runs, an invalid `ptrTarget` armed ADR 0005's rollback/Session-death path for a caller
  mistake that wrote nothing — same shape as the `logActivity` bug, via a different write
  primitive. Now checked with the same `not ptr or ptr:IsNull()` idiom `familyHelper.lua`
  uses throughout, before `fhCreateItem`.

### Validate `ptrRecord`/`action` up front in `sessionLogHelper.logActivity` (issue #95)
- Live-testing the Bridge against the sample project turned up a real gap: `logActivity`
  already validated `media.name` before touching the buffer, but never applied the same
  validate-before-mutate discipline to `ptrRecord`/`action` themselves. A bad `ptrRecord`
  (nil, or any invalid pointer) sailed past into `fhCreateItem`/`AddRecordLink` for real,
  flipping the write tracker and triggering ADR 0005's full write-mode-error rollback —
  ending the Bridge Session and prompting FH's own Plugin Error/undo dialog — for what was
  actually just a caller mistake with nothing legitimate on the tree to undo. Now checked
  up front, so a bad call fails fast on a plain Lua error: no tree write, no rollback, no
  dead Session.

### Extract pure session-lifecycle decisions into `sessionPolicy.lua` (issue #88)
- Pulled the pure decisions underneath `bridgeSession.lua`'s session-lifecycle logic out
  as boolean/string functions over plain values, with no socket/IUP/FH dependency:
  `statusColorForMode(accessMode)`, `shouldAutoStopForIdle(lastActivityTime,
  idleTimeoutSeconds, now)` (issue #34's auto-Stop rule), and
  `shouldConfirmBeforeExit(sessionRunning, lastRequestHandledTime, now,
  confirmWindowSeconds)` (ADR 0020's freshness-confirm rule). `bridgeSession.lua`'s own
  call sites are unchanged in behavior. The socket accept/receive/send loop and the real
  IUP widget construction stay untested, same as before — still only exercised manually
  inside FH.

### Raised server test coverage on `fhHelp`, `fhHelpUpdate`, `runLuaTool` (issue #94)
- Added tests for the previously-uncovered "MCP wiring" layer in each file — the
  `register*Tool` functions and the handler closures passed to `server.registerTool` — via
  a real `McpServer` + in-memory client connection: `runLuaTool.ts` (67% → 100% lines),
  `fhHelpUpdate.ts` (61% → 100% lines, 100% branches), `fhHelp.ts` (66% → 100% lines, 96%
  branches, including the empty-match, truncation, and invalid-regex-error paths). No
  behavior change. Overall server coverage: 83.45% → 91.48% statements.

### Pruned stale versioned artifacts from `installer/output/` before each build (issue #93)
- Each of the three release outputs (mac `.zip`, Windows `.exe`, `.mcpb` bundle) now
  deletes other-version files matching its own naming pattern right before writing the new
  one, scoped per-artifact-type rather than a wholesale clear of `output/` (the two-stage
  release runs `release-mac.sh` and `release-windows.ps1` against the same `output/` dir,
  so a broad wipe on either side would destroy the other stage's just-built file).

### Added coverage measurement to the server test suite (issue #91)
- `@vitest/coverage-v8` + a `vitest.config.ts` turning it on. `npm run test:coverage`
  (server/) runs the suite with a text+html report; plain `npm test` is unaffected.
  `coverage/` is gitignored as build output.

### Added direct tests for `corpusSearch.ts` and `bridgeResponse.ts` (issue #87)
- Neither had a test file of its own before — only exercised indirectly through other
  suites — so a search-ranking regression (a changed weight, an added stopword) could pass
  every existing test while making results worse. `corpusSearch.test.ts` covers
  `tokenize`, `tokenMatchScore`, `buildExcerpt`, `searchEntries`; `bridgeResponse.test.ts`
  covers `textResult`, `describeBridgeConnectionError`, `interpretBridgeResponse`. Found and
  fixed while writing the excerpt tests: `buildExcerpt`'s no-match fallback silently
  truncated long text with no "…" indicator, inconsistent with the match-found branch.

### FH help corpus sync and Function Index discoverability
- Synced the bundled fh-help corpus (995 → 999 topics), adding `fhu.createTextFromSource`.
- A grilling session concluded a new MCP resource/tool for function discovery was
  unwarranted: `sandbox.lua`'s known-name allowlist exactly matches the corpus's "Function
  Index" page, already fetchable in one `grep_fh_help` call. The real gap was that nothing
  told a session this page exists — fixed in the lookup-order doc and both help tool
  descriptions.

### Bridge `@Version:` header now generated, not hand-maintained (issue #89)
- `bridge/scripts/build.lua` now reads `server/package.json`'s version and passes it into
  `bundler.buildBundle`, which stamps the Bridge's `@Version:` header with it — the same
  way it already stamps `@LastUpdated:` with the build date — instead of trusting whatever
  version was last typed into the header by hand.
- `server/package.json` is now the only hand-maintained version copy in the repo (see
  `docs/release.md` step 4); the header was the last one.
- `bridge/tests/build.test.lua` covers the new `extractPackageVersion` helper and asserts
  the stamped header/injected `BRIDGE_VERSION` reflect the given package version even when
  the source entry file's own header says something else.

### `docs/release.md` brought back in line with how releases are actually cut (issue #86)
- The doc predated `installer/release-mac.sh`, `installer/release-windows.ps1` and
  `installer/build-dxt.mjs`, mentioned none of them, never mentioned the `.mcpb` flow at
  all, and its Risks section still asserted *"No full packaging script exists."*
- It now opens with what actually ships (as of 0.11.0: the hand-assembled
  `fh-mcp-bridge-X.Y.Z.zip` **and** `fh-mcp-bridge-X.Y.Z.mcpb`) and a table of the three
  build scripts and their outputs — including the awkward part worth knowing: the platform
  artifacts those scripts build are *not* what has been attached to Forgejo releases, so
  the scripted path and the released path currently produce different artifacts.
- Step 4 no longer claims three hand-maintained version copies with no source of truth.
  Two are hand-maintained (`server/package.json`, the Bridge's `@Version:` header, the
  latter tracked as issue #89); `serverVersion.ts`, the `.iss` `AppVersion`, the `.mcpb`
  manifest version and `package-lock.json` are all derived.
- Step 6 now runs the aggregate `npm test` and builds the `.mcpb`; step 9 uploads both
  assets rather than just the zip; the Risks section names the hand-assembled zip as the
  real remaining gap instead of denying the scripts exist.

### One source of truth for the MCP tool list, and a test that actually checks it (issue #85)
- The tool list existed as four hand-synced copies — the `register*Tool` call sites,
  `installer/dxt/manifest.mjs`, `installer/dxt/manifest.test.mjs` and
  `installer/verify-dxt.mjs`. The test named *"buildManifest lists every tool
  server/src/index.ts currently registers, and no others"* did not do that: it compared the
  manifest to a literal array declared in the test file itself, never reading the server. A
  ninth tool could be added and every suite would still pass while the shipped `.mcpb`
  silently under-declared it.
- `server/src/toolNames.json` is now the single source: tool names plus the one-line blurbs
  the bundle manifest shows. JSON rather than TypeScript so the installer's plain-Node
  scripts read it with no build step and no dependency on the gitignored `server/dist`.
  `manifest.mjs` generates its `tools` array from it, and `verify-dxt.mjs` reads it too.
- `server/src/toolNames.test.ts` is what makes the guarantee real: it stands up a real
  `McpServer`, registers every tool the way `index.ts` does, connects an MCP client over
  `InMemoryTransport`, and asserts the served `tools/list` is exactly that JSON's list. The
  server is asked what it registers rather than parsed for it, so the TypeScript AST walk
  ADR 0015 assumed would be needed isn't.
- ADR 0015's "tool list is a static array" section is marked superseded, with the original
  reasoning kept.
- No change to what the server serves or what the bundle declares — the eight tools are
  the same eight.

### Pre-push hook runs the aggregate suite (issue #90)
- With no CI on this repo (no `.github/`, no `.forgejo/`), nothing stood between a broken
  suite and `main`. `.githooks/pre-push` now runs the repo-root `npm test` before every
  push — the whole aggregate takes under two seconds, so it's unobtrusive enough not to
  invite habitual bypassing.
- Enabled per clone with `npm run setup:hooks`, which points `core.hooksPath` at the
  committed `.githooks/` directory; `.git/hooks/` isn't version controlled, so that
  indirection is what lets the hook live in the repo. No new dependencies — the root
  `package.json` stays dependency-free rather than pulling in a hook manager.
- Skips pushes that only delete remote refs (nothing local to test), fails with a clear
  message if Node isn't on PATH, and `git push --no-verify` bypasses it.
- No CI, deliberately. A Forgejo Actions workflow was tried and backed out: this is a
  one-developer, one-machine project, the hook already covers the only realistic gap, and a
  runner would have meant putting Docker (or a permanent Node + Lua install) inside the
  small LXC that hosts Forgejo. Issue #90 is closed `wontfix` with the reasoning.

### One `npm test` runs every suite, and releases are gated on it (issue #84)
- The repo had three test runners with three invocation styles and no command that ran them
  all: `cd server && npm test` (vitest) covered roughly a third of the tested surface, the
  12 `bridge/tests/*.test.lua` files had to be looped over by hand, and
  `installer/dxt/manifest.test.mjs` was wired into nothing at all — no npm script, neither
  release script, not `docs/release.md` — so a release could be cut with it failing and
  nothing would say so.
- A new root `package.json` exposes `test:server`, `test:bridge`, `test:installer` and an
  aggregate `test` that runs all three, stopping at the first failure. It is `private`, has
  no dependencies, and deliberately carries **no** `version` field: `server/package.json`
  remains the single version source of truth (issue #44).
- `scripts/run-bridge-tests.mjs` is the new aggregate Lua runner — Node rather than a shell
  loop so it behaves the same from bash on the Mac and PowerShell on Windows, where the
  release scripts also run it. It finds an interpreter via `LUA_BIN`, then `lua` on `PATH`,
  then `C:\Utils\lua\lua.exe` (`installer/stage.ps1`'s fixed location), and reports a clear
  "not a working Lua interpreter" error rather than failing all 12 files.
- `installer/release-mac.sh` and `installer/release-windows.ps1` now run the aggregate
  `npm test` before building anything, so a release cannot be built over a failing suite.

### `run_lua` rejects scripts calling unrecognized `fh*` globals (issue #81)
- A new static pre-scan in `runScript.lua`, run before `load()` alongside the existing
  write-then-log pre-scan (docs/adr/0012), rejects a script that calls a bare `fh*` global
  this sandbox doesn't recognize — before the script ever executes, catching a
  typo'd/hallucinated function name (e.g. `fhGetQualifiedId` instead of
  `fhGetQualifiedRecordId`) that would otherwise only fail at runtime, potentially after a
  partial write. A known-but-permanently-excluded name (e.g. `fhMessageBox`, `fhSleep`)
  gets a specific reason instead of a generic "unrecognized" message. `sandbox.lua` gains
  `KNOWN_FH_GLOBAL_NAMES` (mode-independent) and `EXCLUDED_FH_GLOBAL_REASONS`. If a script
  also trips the existing write-then-log pre-scan, both violation messages are reported
  together, not just the first. Out of scope for v1: `fhu.*` method calls and item-pointer
  `:Method()` calls. See docs/adr/0022-static-pre-scan-rejects-unrecognized-fh-globals.md.

### `.mcpb` bundle wired into the standard release scripts (issue #59)
- `installer/release-mac.sh` and `installer/release-windows.ps1` now each run
  `installer/build-dxt.mjs --verify` as their last step, so a single script invocation
  produces the platform installer/zip *and* the cross-platform `installer/output/fh-mcp-bridge-<version>.mcpb`,
  instead of the `.mcpb` needing a separate manual build. Both scripts abort early with
  an install hint if Node isn't on PATH, matching the existing Lua-interpreter check in
  `release-mac.sh`. No change to `build-dxt.mjs`/`verify-dxt.mjs` themselves. Windows
  `.mcpb` installs still have an open, unresolved upstream risk (Claude Desktop's MSIX
  build failing on all three documented install methods) — see issue #60 and
  `installer/README.md`'s "Known risk" note; this change only wires up building the
  artifact, not the install/handoff itself.

## 0.11.0

### Bridge dialog remembers Access mode and idle timeout (issue #80)
- The bridge dialog's Access-mode selector and idle-timeout minutes now survive a plugin
  reload, via FH's supported `fhu.loadOptions`/`fhu.saveOptions` settings-file API
  (`LOCAL_MACHINE` scope) in new module `bridge/sessionSettings.lua`. Loaded on dialog
  init to seed both widgets' defaults; saved only after a Start succeeds, with the values
  that actually took effect. A missing/corrupt settings file falls back silently to
  today's prior hardcoded defaults (read-only, 15 minutes); a stored timeout is re-clamped
  through the existing `timeoutDisplay.clampMinutes` on load. A settings-file write failure
  is silent and never blocks Start. Distinct from `bridge/sandbox.lua`'s unrelated block on
  the same `fhu` functions for `run_lua`-submitted scripts (issue #22) — that block doesn't
  reach this dialog code, which calls `fhUtils` directly.

### Blood-relatives-only filter on getAncestors/getDescendants (issue #78)
- `dnaLine` (the DNA-line filter already on `getDescendants`) gains a `"blood"` value,
  backed by FH's `DnaBloodRelation` built-in — weeds an adoptive/step FAMC link out of
  an ancestor list, or FAMS link out of a descendant list. The same `dnaLine` parameter
  (all three values: `"y-chrom"`/`"mtdna"`/`"blood"`) is now also available on
  `getAncestors`, which previously had no third argument. `DnaHalfBlood` ("half-blood")
  was considered and deliberately excluded — FH's own docs say a direct
  ancestor/descendant is never a "half blood" relation, so it would always return empty
  for these two helpers specifically. See
  `docs/adr/0021-blood-relation-filter-shared-by-ancestors-and-descendants.md`.

## 0.10.0

### Exit button on the Bridge dialog (issue #77)
- New third button, "Exit", always active regardless of whether a Session is running —
  equivalent to closing the dialog via the window's X. Both now share one teardown path
  (`stopSessionIfRunning()`) rather than X's previous, narrower `server:close()`-only
  handling, which skipped stopping the poll timer and clearing session state.
- Closing via Exit/X prompts to confirm (Yes/No) only when a request was actually handled
  within the last 10 seconds — the only real proxy for "Claude might send another request
  imminently," tracked via a new `lastRequestHandledTime`, deliberately separate from the
  pre-existing `lastActivityTime` (also stamped at Start, for the idle-timeout clock) so a
  plain Start-then-Exit with no request in flight doesn't trigger a spurious warning.
  Declining the prompt leaves the Session running untouched. See
  `docs/adr/0020-exit-button-shared-teardown-freshness-confirm.md`.

### FTF table column widths computed from content (issue #76)
- Every `run_lua`-built FTF table now sizes each column from its actual cell content
  (`ceil(max_chars/0.011) + 200` twips, no minimum-width floor) instead of the flat
  800-twip default used in prior practice, so generated tables render proportioned to
  their content rather than uniformly wide. Constants are a ballpark estimate, not
  measured against FH's own rendering. Also documents the leading-blank-line rule for a
  table placed at the very top of a rich-text field. See
  `docs/adr/0019-ftf-table-widths-computed-from-content-not-fh-default.md`.
- `run_lua` guidance corpus also gained the `fhNewItemPtr()`/`MoveTo` idiom for getting a
  blank Item Pointer to jump straight to a named child item, found while building this.

### Bridge entry file split into a stub plus `bridgeSession.lua`, for Serena coverage (issue #75)
- `bridge/Claude MCP Bridge.fh_lua` — the repo's only source `.fh_lua` file, unrecognized by
  Serena's installed Lua language server integration (no `file_filter` hook, unlike its
  perl/php equivalents) — held 359 lines of real logic (dialog UI, TCP listener, request
  dispatch, Session lifecycle), all invisible to Serena's symbol tools.
- Moved everything but the two FH-mandated setup calls into a new `bridge/bridgeSession.lua`:
  the entry file is now just the `@Title`/... header, `fhInitialise(...)`,
  `fhSetStringEncoding("UTF-8")`, and one `require("bridgeSession")`. Both setup calls must
  stay direct calls in the entry file (FH's own docs: `fhSetStringEncoding` "should never be
  used by modules"; `fhInitialise` "should be the first function called in the plugin") —
  confirmed against `fh-help-corpus.jsonl` before ruling out a one-line stub.
- `bundler.lua`'s `MODULE_NAMES` gains `"bridgeSession"`, using the same `package.preload`
  splice mechanism ADR 0009 built for the other 8 sibling modules. `BRIDGE_VERSION` (injected
  by the bundler right after `fhInitialise(...)`) needed no bundler change to stay visible
  inside `bridgeSession`'s `package.preload` closure — Lua closures capture enclosing locals
  lexically — verified with a new runtime test in `bridge/tests/build.test.lua`, not just
  reasoned about.
- See ADR 0018 for the full design rationale, including why this isn't folded into ADR 0009
  (different motivation: Serena coverage, not standalone unit-testability).

## 0.9.0

### `describe_project`: split structural field definitions from occurrence counting (issue #74)
- `sourceTemplateFields` (issue #67/#73) silently gave zero for every citation-specific
  (CITN) field, since those populate on a citation, not the SOUR record itself. Extending
  the walk to cover citations would mean scanning every citation across every INDI/FAM
  record on every `describe_project` call (no caching, ADR 0002) whether or not the
  conversation ever touches sources.
- `describe_project`'s census key is renamed `sourceTemplateFieldDefinitions` and made
  structural only: walks `_SRCT` template records and their `FDEF` children directly,
  reporting each field's CODE/TYPE/CITN, nested per template name. Cheap and bounded by
  template count, not record/citation count.
- All occurrence counting (record-level and citation-level) moves to a new opt-in
  `fhBridge.getTemplateFieldCensus(templateNameOrId)` helper in `bridge/sourceHelper.lua`,
  single-template scoped like `findSources`/`getPopulatedTemplateFields`, wired into
  `sandbox.lua`'s `env.fhBridge` unconditionally (pure read, both access modes). Only pays
  for the whole-project citation walk when the template actually has a citation-level
  field to count.
- See ADR 0017 for the full design rationale.

## 0.8.0

### New `fhBridge.getPopulatedTemplateFields`; `findSources` field-matching fix, record AND citation level (issue #73)
- Extracted issue #67's field-resolution fix out of `describe_project`'s own script into a
  reusable, read-only `fhBridge.getPopulatedTemplateFields(sourPtr)` in
  `bridge/sourceHelper.lua` (wired into both Session modes, same as `findSources`):
  resolves a `SOUR` record's linked `_SRCT` template and returns `{code = value}` for every
  record-level field populated on it. `describe_project` now just calls this once per
  source instead of duplicating the `FDEF`/shortcut-prefix logic inline.
- Found and fixed a related bug while extracting: `findSources`' own field matching checked
  a populated field's raw tag against its `~PREFIX-CODE` shortcut string, but a populated
  field's real tag is always `_FIELD` (same root cause as issue #67) — so `findSources`
  likely never correctly matched a `fieldFilters` entry against a real (non-bridge-authored)
  source's fields, citation-level fields included: live-verified against a real citation
  (a "Civil Registration Index" entry with several citation-level fields populated) that it
  carries the same generic `_FIELD` tag as record-level fields. `findSources` now retains
  each citation's own live pointer while walking (`collectCitations` rewritten to walk the
  live tree directly, since a pre-built `getAllDetails` JSON tree can't carry a live
  pointer) and resolves both record-level and citation-level `fieldFilters` entries through
  one shared shortcut-Data-Reference resolution function.
- Shortcut strings are now derived via FH's own `fhGetMetafieldShortcut` (also usable
  directly on a field *definition* item, not just a populated metafield) instead of a
  hand-built `"~" .. prefix .. "-" .. code` from a maintained TYPE→prefix table —
  guaranteed to match FH's real internal form (live-confirmed: actually uppercased on the
  code portion, e.g. `~TX-REFERENCE`, though Data Reference resolution turned out to be
  case-insensitive there so the old hand-built form still happened to work).
- New `gedcom-knowledge-corpus` entry `source-template-field-resolution` documents why
  matching by raw tag and by position both fail, and corrects `source-template-fields`'
  now-outdated advice to walk a populated field's children by tag.

### `describe_project`: fix `sourceTemplateFields` always returning `{}` (issue #67)
- `describe_project`'s `tagCensus.sourceTemplateFields` census was always empty: the
  original script looked for a `_FIELD` child on each `_SRCT` template record, but a
  template's field *definitions* are `FDEF` children of the template — `_FIELD` is the tag
  used for a field's *populated value* on the `SOUR` records that use that template. A
  positional fix (matching a source's Nth `_FIELD` child to the template's Nth `FDEF`) was
  tried and rejected after live testing showed it mismatches as soon as a field partway
  through a source's field list is left unpopulated, shifting every later field's answer.
  The shipped fix resolves each field directly off the `SOUR` record by its own
  `~PREFIX-CODE` shortcut Data Reference (FH's own field-addressing mechanism), which
  correctly skips an unpopulated field without disturbing any other field's answer.
  `sourceTemplateFields` is now keyed by each field's own `CODE` (e.g. `Reference`,
  `Page_no`), not the placeholder `TX-PAGE`-style example the tool's own description used
  to show; the description's example has been corrected to match.

### `describe_project`: report Family Historian's own app version (issue #69)
- `describe_project` now returns `fhAppVersion` — Family Historian's own application
  version (e.g. `"8.0.0"`), read via `fhGetAppVersion()` (already wired into the
  Read-only sandbox) and formatted as a dotted string, matching how
  `BRIDGE_VERSION`/`SERVER_VERSION` are already represented elsewhere in this codebase
  rather than the three separate integers that function returns. Lets a session know
  which FH version it's actually talking to without a separate `run_lua` round-trip.

## 0.7.0

### `fhBridge.findSources`, clearer bad-id errors, and rollback-scoping guidance (issue #65)
- New helper `fhBridge.findSources(templateNameOrId, fieldFilters)` in
  `bridge/sourceHelper.lua`: finds every `SOUR` record linked to a given template whose
  populated fields match `fieldFilters` (case-insensitive substring for Text/Name/Place/
  Address/URL fields, exact match for Enum/Date/Repository fields). A field's own `CITN`
  ("Citation-specific") flag on the template decides whether a filter is checked against
  the source record's own fields or against its citations' fields instead — a
  citation-level filter matches if *any* of the source's citations has a matching value.
  Read-only (unlike `createSourceFromTemplate`/`citeSource`) and wired into `env.fhBridge`
  unconditionally, same as `familyHelper.lua`'s read helpers. Returns an array of
  `{source = <getAllDetails-shape tree>, citedBy = [{tag, qualifiedId}, ...]}`, so "find a
  comparable existing source and see how it's normally cited" is one call.
- `familyHelper.lua`'s `resolvePointer` now raises a specific error when given a bare
  number instead of a qualified id string (e.g. `.id` grabbed where `.qualifiedId` was
  needed) — `"expected a qualified id string like 'I219', got the number 136 -- pass the
  .qualifiedId field..., not .id"` — instead of a raw Lua `"attempt to index a number
  value"` several calls later. Uniform across every `fhBridge.*` function; none accept a
  bare number (ambiguous across record types for the generic ones).
- New `gedcom-knowledge-corpus` entry (`run_lua guidance` family): never combine a write
  call with read-only verification logic in the same `run_lua` script — a bug in the
  verification half can otherwise trigger FH's whole-Session rollback (docs/adr/0005) even
  though the verification itself changed nothing, since the write tracker was already
  flipped by the write half earlier in the same script.
- `source-template-fields`/`source-template-creating-a-templated-source` corpus entries
  now document `FDEF`'s `CITN` subfield and lead with `fhBridge.getAllDetails
  (templateQualifiedId)` as the one-call way to discover a template's fields, keeping the
  manual `FDEF` walk as a documented fallback.
- `search_gedcom_knowledge`'s default result limit raised 10 → 20: the `run_lua guidance`
  family had already grown past 10 members, so the single-query-surfaces-everything
  promise that family's own design relies on was silently broken (no caller-settable
  `limit` on this tool).

### GEDCOM knowledge corpus guidance from issue #63 exploration
- Three empirically-found gotchas added to `gedcom-knowledge-corpus.jsonl`:
  `MoveToFirstChildItem`/`MoveNext` return `nil` on end-of-list, not a boolean — a
  return-value `while` loop silently never runs, so check `IsNotNull()` instead; there's
  no built-in duplicate-individual finder in the plugin API, so a name+birth-year
  grouping heuristic is documented instead (same name+year is a strong signal, same
  name+different generation usually isn't); and `getFactsByTag(ptr, "SOUR")` only sees
  whole-record citations, not fact-level ones, so a naive "has any source" check
  overcounts.
- Corrected an earlier wrong finding: a raw `CHAN` data-reference probe returning nothing
  had been reported as "no change-date tracking", but `fhCallBuiltInFunction("LastUpdated",
  ptr)` on the same project returns real record change dates — user caught this live.
- Two more patterns from the user's #63 follow-up: generation counts just need a chosen
  start point (`getAncestors` + `getDescendants` + `getFamilyGroup` spouses, mirroring
  FH's All Relatives report), and detecting a move between birth/death is cleaner via
  `PLAC` lat/long distance than parsing county/country out of free text.

### `fhBridge.getDescendants` (issue #64)
- New helper in `bridge/familyHelper.lua`, alongside `getFamilyGroup`/`getAllDetails`/
  `getAncestors`/`searchByName`/`getFactsByTag`: `fhBridge.getDescendants(ptr,
  maxGenerations, dnaLine)` walks down every `FAMS`/`CHIL` record from `ptr` — the
  mirror image of `getAncestors`' walk up `FAMC` — with the same optional generation
  cap and pedigree-collapse dedupe. `line` entries are `"son"`/`"daughter"` (read off
  each step's own `SEX`), not `getAncestors`' `"father"`/`"mother"` role labels.
- Optional third argument `dnaLine` (`"y-chrom"` or `"mtdna"`) filters the result to
  descendants sharing that DNA line with `ptr`, via FH's own built-in
  `DnaShareYChrom`/`DnaShareMtDna` functions (`fhCallBuiltInFunction`) rather than
  this module reimplementing Y-DNA/mitochondrial inheritance rules itself — see
  `docs/adr/0016-getdescendants-defers-dna-line-logic-to-fh-builtin.md`.
- Wired into `env.fhBridge` unconditionally (both access modes), same as the other
  read-only query helpers.

### Prototype: `.mcpb` (Claude Desktop Extension) bundle for the server (issue #59)
- `node installer/build-dxt.mjs` builds `installer/output/fh-mcp-bridge-<version>.mcpb` —
  a Claude Desktop Extension installable via Settings → Extensions (or double-click/
  drag-and-drop), for the newer unified/MSIX Claude Desktop build that no longer honors
  `claude_desktop_config.json` (issue #56). Not yet wired into either release script —
  see docs/adr/0015-mcpb-bundle-manifest-is-generated-not-hand-copied.md.
- `installer/verify-dxt.mjs` (or `--verify`) extracts a built bundle and confirms its
  server actually starts under its own manifest command/args and registers the expected
  tools, headlessly — the Claude Desktop install UI itself still needs a hands-on check.

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

### Windows installer end-user guide
- New `docs/windows-installer-guide.md`, targeting Windows 10/11 users installing via
  `FH-MCP-Bridge-Setup-X.Y.Z.exe` rather than building from source: no Node.js, no
  command line. Covers SmartScreen, the no-admin install, the automatic Claude Desktop
  config merge, loading the plugin via FH's own install prompt, and installer-specific
  troubleshooting (`config-merge.ps1` failures, antivirus flagging the bundled
  `node.exe`, uninstall leaving the Claude Desktop config entry and plugin file behind).
  `README.md` and `docs/user-guide.md` now point installer users at it.
- The installer's `AppVersion` is now generated at build time by `installer/stage.ps1`
  from `server/package.json` instead of hand-maintained — it had drifted to 0.5.0 while
  the other three tracked version copies were already at 0.6.0. See docs/release.md's
  "Three-way version drift" section.

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
