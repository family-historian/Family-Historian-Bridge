# Bridge plugin

The FH-side half of the MCP bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `Claude MCP Bridge.fh_lua` — the entry file, and now just a stub (issue #75, docs/adr/0018):
  the `@Title`/`@Type`/... header FH's plugin loader reads, `fhInitialise(7, 0, 0,
  "save_required")` as its very first statement, before any `require()`, so FH prompts to
  save unsaved changes the moment the plugin loads rather than partway through (issue #33)
  — Cancel there ends the plugin before the dialog is ever built — then
  `fhSetStringEncoding("UTF-8")` (also mandatorily direct here, never inside a required
  module — see `bridgeSession.lua` below), then one `require("bridgeSession")`. Nothing
  else lives here any more.
- `bridgeSession.lua` — the dialog UI (Access-mode selector, idle-timeout spin-box and
  countdown, Start/Stop, idle auto-Stop timer), TCP listener, and request framing — moved
  out of the entry file itself (issue #75, docs/adr/0018) so Serena's symbol tools can
  cover it; `.fh_lua` files can't be recognized by Serena's Lua language server, `.lua`
  files can. Also calls `fhUpdateDisplay()` after every accepted request, so any change a
  write script made is reflected on FH's own screen right away (issue #33). Like the entry
  file before it, this has no automatable seam (needs `iup`/`luasocket`/FH's own globals
  regardless of which file it lives in) — no `bridgeSession.test.lua`, tested manually
  inside FH instead (see "Manual test" below). Issue #88 proposes a second split, on ADR
  0018's reasoning, to get the policy logic (access mode, idle timeout, ADR 0020's
  freshness-confirm rule) under test.
- `requestFraming.lua` — parses a request's first line (`STOP` / `LUA <n>` / `LUA_RO <n>` /
  `VERSION <server-version>`) into a structured form; `LUA_RO` forces the Read-only sandbox
  regardless of the Session's own Access mode (issue #16 — used exclusively by
  `describe_project`). `VERSION <server-version>` (issue #45) carries no body — the
  server's version travels in the header line itself, ahead of every actual
  `LUA`/`LUA_RO` connection; see `versionCompare.lua` below and the entry file's own
  handling of `request.kind == "version"`.
- `runScript.lua` — compiles and runs a submitted script inside the sandbox (guarded by
  the watchdog), returns a JSON-encoded result or error.
- `sandbox.lua` — builds the allowlist `_ENV` a script executes inside.
- `jsonEncode.lua` — hand-rolled JSON encoder (FH's Lua ships none).
- `watchdog.lua` — aborts a script that exceeds an instruction budget, so an accidental
  infinite loop can't hang FH with no recovery path.
- `timeoutDisplay.lua` — pure formatting/conversion/clamping helpers for the Session
  idle-timeout spin-box and its live countdown label (issue #34): minutes-to-seconds
  conversion, `M:SS` formatting, and clamping a spin-box reading to the ticket's stated
  5–120 minute range.
- `versionCompare.lua` — compares this Bridge's version against the server's (issue #45),
  returning `"match"` / `"warn"` / `"block"` (strict major-version-only; inert while this
  project is pre-1.0, since major is `0` on both sides today — see the module's own
  comment). The Bridge's own version isn't hand-duplicated anywhere: `BRIDGE_VERSION` is
  injected as a runtime constant by `scripts/build.lua`/`scripts/bundler.lua`, parsed
  straight from this file's own `@Version` header at build time.
- `sourceHelper.lua` — `fhBridge.createSourceFromTemplate(...)` (issue #18), a read-write-
  only helper that creates a fully populated templated Source record in one call instead of
  hand-assembling the `_SRCT`-link + metafield-shortcut dance every time. Wired into the
  sandbox by `sandbox.lua` alongside the rest of the write API — see
  `docs/superpowers/specs/2026-07-30-createSourceFromTemplate-design.md`. Also exposes
  `fhBridge.citeSource(ptrTarget, sourceIdOrTitle)`, attaching a `SOUR` citation to any
  target item (an INDI/FAM record for a Whole-record citation, or a Fact item) instead of
  hand-assembling `fhCreateItem("SOUR", ...)` + `fhSetValueAsLink` — see
  `docs/adr/0006-cite-every-fact-a-source-supports.md`. Unlike those two, `fhBridge.findSources
  (templateNameOrId, fieldFilters)` (issue #65) is read-only and wired into the sandbox for
  both access modes, alongside `familyHelper.lua`'s members (see that entry below) — it calls
  no write primitive, only `familyHelper.getAllDetails` to build each result and to scan for
  citations. Finds every `SOUR` record linked to the given template whose populated fields
  match every `fieldFilters` entry (`{[fieldCode] = matchValue}`): case-insensitive substring
  for Text/Name/Place/Address/URL fields, exact match (against the same rendered display text
  `getAllDetails` already shows) for Enum/Date/Repository fields. Which of `fieldFilters` is
  checked against the source record's own fields vs. its citations' fields is decided per
  field by the template's own `CITN` flag (`FDEF`'s "Citation-specific" child, see
  `gedcom-knowledge-corpus`'s `source-template-fields` entry) — not something the caller
  chooses — since a citation-level field is only ever populated per-citation, not once for the
  source as a whole; a citation-level filter matches a candidate if *any* of its citations has
  a matching value. Returns an array of `{source = <getAllDetails-shape tree for the SOUR
  record>, citedBy = array of {tag, qualifiedId} for every fact/record across every INDI/FAM
  in the project that cites it}` — `citedBy` is unconditional (present with or without
  `fieldFilters`), so a caller can see how a template is actually used (e.g. "usually cited on
  `BIRT` plus a dated `OCCU`") without a second helper call. Errors on a field code the
  template doesn't define at all, same validation as `createSourceFromTemplate`; a field
  that's merely unpopulated on a given candidate source just fails to match, not an error.
- `factHelper.lua` — `fhBridge.createFact(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue,
  sAge)` (issue #113), a read-write-only helper that creates a Fact on an `INDI`/`FAM` record
  via `fhu.createFact` in one call instead of hand-assembling `fhCreateItem` +
  `fhSetValueAsText`/`Date`/etc. per field. `ptrRecord` accepts a live Item Pointer or a
  qualified id string (e.g. `"I219"`, `"F3"`), same as `familyHelper.lua`'s query helpers —
  but never a bare number, since `createFact` spans both `INDI` and `FAM` and a number alone
  can't disambiguate (same reasoning as `getAllDetails`/`getFactsByTag`, issue #65). Returns
  the new Fact's own live item Pointer, not a `qualifiedId`, so a script can chain straight
  into `fhBridge.citeSource(thatPointer, sourceNameOrId, fields)` to cite it within the same
  `run_lua` call — see `docs/adr/0006-cite-every-fact-a-source-supports.md`. Citing is a
  deliberate separate step; `createFact` itself never touches a Source or citation.
- `sessionLogHelper.lua` — `fhBridge.logActivity(ptrRecord, action, media)` (issue #36; the
  optional `media` param from issue #39), a read-write-only helper that logs a Session's
  record-creating activity into one Research Note (`_RNOT`) per Session: the first call in
  a Session creates a new note titled with a creation timestamp and writes the first log
  entry into it; every subsequent call in the same Session appends a further entry to that
  same note. Each entry's record reference is a live FTF record link
  (`RichText:AddRecordLink`), not plain text. Exploits the Bridge plugin being one
  continuously-running Lua process for a Session's lifetime: a module-level Research Note
  pointer and RichText buffer persist across every `run_lua` call via `require()`'s module
  caching, and reset on the next Session (fresh plugin load). `media` is an optional
  `{name, location}` table for media the user still needs to add by hand once the Session
  ends — when given, it appends an indented `[ ] #ToDo Media to be added <name>` sub-line
  (plain FTF text, not an interactive checkbox) under that entry, with the location in
  parentheses when one was mentioned. This never touches the media file's bytes or the
  filesystem; the user drags the file into FH themselves after the Session ends.
- `richTextHelper.lua` — `fhBridge.getTftfText(ptr)`/`fhBridge.setTftfText(ptr, text)`
  (issue #107, docs/adr/0025-tftf-full-rewrite-for-mid-document-richtext-edit.md): a safe
  way to edit IN THE MIDDLE of an existing large RichText field (Notes, Source `TEXT`,
  citation `DATA/TEXT`), not just append to the end of it the way `logActivity` above
  already does well. `GetText()`'s own eFTF text uses index-based `<rec=N,...>` tags paired
  with a `tblRecLinks` table; any hand-extension of that table for `SetText`'s eFTF path
  returns `false` silently (issue #106), and `AddText`/`AddRecordLink` on a live object
  only appends to the end. `getTftfText` sidesteps both by resolving every `<rec=N,...>`
  to a self-contained `<rec=QualifiedId,...>` one (tFTF, via `fhGetQualifiedRecordId`) —
  a plain string a caller can splice/reorder anywhere with ordinary Lua string operations
  (`string.find(text, anchor, 1, true)` for a literal, non-pattern anchor) — and
  `setTftfText` commits the whole thing back in one `SetText(text, true, true)` rewrite,
  which needs no side table at all and so cannot hit the #106 bug. `getTftfText` is a pure
  read (present under both access modes, like `findSources`); `setTftfText` is
  read-write-only. Neither function will touch a field that already has embedded source
  citations — tFTF cannot represent them, and `SetText(..., true, true)` does not error on
  one, it silently discards it (confirmed live) — `getTftfText` reports `editable = false`
  with a `reason`, and `setTftfText` re-checks and errors outright rather than risk that
  loss. Editing a citation-bearing field's interior remains an open problem, deliberately
  out of scope here; see docs/adr/0025.
- `familyHelper.lua` — six read-only query helpers, unlike the three above (each of
  `sourceHelper.lua`/`sessionLogHelper.lua`/`richTextHelper.lua` has at least one
  read-write-only member): every fh*
  function this module calls is a read primitive already granted in the Read-only half of
  the sandbox, so `sandbox.lua` wires `env.fhBridge` up with these for BOTH access modes,
  and only *adds* the read-write-only members above on top of that same table.
  `fhBridge.getFamilyGroup(indiPtr, type)` (`type`: `"all"`/`"parents"`/`"siblings"`/
  `"spouses"`, default `"all"`) walks every FAMC/FAMS record the Individual belongs to and
  returns an array of `{ relationship, individual, family }` — `relationship` is
  `"father"`/`"mother"`/`"sibling"`/`"spouse"`, and `family` identifies which FAMC/FAMS
  record the relationship came through (so a caller can tell full siblings from half-
  siblings, or one marriage from another, by comparing `.family.id`).
  `fhBridge.getAncestors(indiPtr, maxGenerations, dnaLine)` walks the same FAMC chain
  breadth-first, as far up as `maxGenerations` allows (omit/nil for unlimited), returning
  an array of `{ generation, line, individual, family }` — `line` is an array of
  `"father"`/`"mother"` steps from `indiPtr` down to that ancestor (e.g. `{"mother",
  "father"}` is the maternal grandfather), left unresolved to an English title like
  "grandfather" since that's a presentation choice, not this helper's job. Both dedupe by
  record id (pedigree collapse) and never hand back a raw Item Pointer —
  `individual`/`family` are plain descriptor tables (`id`, `qualifiedId`, plus `name`/`sex`
  for an individual), since jsonEncode.lua cannot encode a pointer at all.
  `fhBridge.getDescendants(indiPtr, maxGenerations, dnaLine)` (issue #64) is the mirror
  image of `getAncestors`: breadth-first walk down every FAMS/CHIL record instead of up
  FAMC/HUSB/WIFE, same optional generation cap and pedigree-collapse dedupe. `line` entries
  are `"son"`/`"daughter"` (read off each step's own SEX, `"child"` if unrecorded) rather
  than `getAncestors`' `"father"`/`"mother"` role labels — a CHIL item carries no
  equivalent role of its own. Both functions share an optional third argument `dnaLine`
  (`"y-chrom"`/`"mtdna"`/`"blood"`) that filters the result to ancestors/descendants
  sharing that DNA line — or, for `"blood"` (issue #78), any blood relation at all — with
  `indiPtr`, via FH's own built-in `DnaShareYChrom`/`DnaShareMtDna`/`DnaBloodRelation`
  functions (`fhCallBuiltInFunction`) rather than this module reimplementing DNA
  inheritance/relatedness rules itself — see
  `docs/adr/0016-getdescendants-defers-dna-line-logic-to-fh-builtin.md` and
  `docs/adr/0021-blood-relation-filter-shared-by-ancestors-and-descendants.md`.
  `fhBridge.getAllDetails(ptr)` works on any item pointer
  (a whole record or a single field/Fact) and recursively describes it and every child
  item beneath it as one plain tree (`tag`, `id`/`qualifiedId` for record items, `value`
  for items that store one, `link` for link-classed items — a descriptor of the linked
  record, not the record's own fields, to avoid walking back out of the record passed in —
  and `children`) — richtext fields go through `GetPlainText()` rather than raw FTF markup,
  same reasoning as `run-lua-get-plain-text-from-richtext` in the gedcom-knowledge-corpus.
  Every one of the four also accepts a qualified id string (e.g. `"I219"`, exactly the
  form each `.qualifiedId` field above already uses) anywhere it takes a pointer, resolved
  via `MoveToRecordById` — so a script can call e.g. `fhBridge.getAllDetails(entry.individual.qualifiedId)`
  directly on a `getFamilyGroup`/`getAncestors`/`getDescendants` result entry, without
  first re-resolving it to a live pointer by hand. `getFamilyGroup`/`getAncestors`/
  `getDescendants` (Individual-only) raise a clear error if the qualified id resolves to
  a non-`INDI` record (e.g. passing a family's `"F13"`
  by mistake); `getAllDetails` accepts any record type's qualified id, matching its own
  "any record pointer" contract. `fhBridge.searchByName(forename, surname)` finds every
  Individual whose given name(s) contain `forename` and whose surname contains `surname`,
  matched case-insensitively as substrings, not exact/whole-word — `searchByName("Robert",
  "Taubman")` also matches "Robert Henry TAUBMAN". Either argument may be omitted/`""` to
  skip filtering on that part of the name; at least one must be given non-empty, or it
  errors. Matches against the NAME field's `GIVEN_ALL`/`SURNAME` Data Reference qualifiers
  (not the raw stored NAME text), so it matches consistently regardless of how a given
  record orders/prefixes its name parts. Returns an array of the same descriptor shape as
  `getFamilyGroup`/`getAncestors`' own `.individual` field, in FH's own record order (not
  sorted). Unlike the other five, it doesn't take a pointer/qualified-id argument — it
  scans every Individual record in the project itself (`MoveToFirstRecord("INDI")` +
  `MoveNext()`). `fhBridge.getFactsByTag(ptr, tags)` filters `ptr`'s own direct children
  (a record's "1st level" — the level a Fact tag actually lives at) to just the ones
  matching `tags`, an exact/case-sensitive FH tag string (e.g. `"CENS"`) or an array of
  them (e.g. `{"BIRT", "DEAT"}`), and returns an array with one full `getAllDetails`-shape
  tree per match, in record order — not deduped, so a repeated tag (multiple `CENS` entries
  across census years, a Rejected + Preferred `BIRT`) is fully surfaced rather than
  collapsed. Works on any record type (`MARR`/`DIV` live on `FAM` records), accepts a
  qualified id string the same as `getAllDetails`, and returns an empty array — not an
  error — when nothing matches; it errors only on a null pointer or a missing/malformed
  `tags` argument (nil, `""`, an empty array, or a non-string entry in the array).

`requestFraming.lua`, `runScript.lua`, `sandbox.lua`, `jsonEncode.lua`, `watchdog.lua`,
`timeoutDisplay.lua`, `sourceHelper.lua`, `sessionLogHelper.lua`, `sessionSettings.lua`,
`familyHelper.lua`, `richTextHelper.lua`, and `versionCompare.lua` have standalone unit
tests, in `tests/`
(`*.test.lua`, run with a plain `lua` interpreter — no FH dependency). Keeping tests out
of this folder means every file directly in `bridge/`
is exactly what `scripts/build.lua` bundles into the single installable file (see
`docs/adr/0009-bundle-bridge-plugin-for-install.md`) — nothing to filter by name:

Run all of them at once from the repo root:

```bash
npm run test:bridge
```

That is `scripts/run-bridge-tests.mjs` — it discovers `bridge/tests/*.test.lua`, runs each
through a Lua interpreter, and stops at the first failure. It finds the interpreter via
`LUA_BIN`, then `lua` on `PATH`, then `C:\Utils\lua\lua.exe` (where `installer/stage.ps1`
expects it on Windows). To run just one file while working on it:

```bash
lua bridge/tests/sandbox.test.lua
```

`scripts/build.lua` (and its `scripts/bundler.lua` logic) bundle those sibling modules into
`dist/Claude MCP Bridge.fh_lua` — the single file that actually gets installed (step 1
below) — and also parse this file's own `@Version` header to inject a runtime
`BRIDGE_VERSION` constant (issue #45), since the header itself isn't readable by the
plugin's own running code otherwise. Both are build tooling, not part of the plugin
itself, same reason `tests/` is kept out of the top level: `dist/` is generated and
gitignored, rebuilt with `lua bridge/scripts/build.lua`.

`bridgeSession.lua` (the socket/IUP dialog plumbing, moved out of the entry file by issue #75/
docs/adr/0018) has no automatable seam — FH is proprietary and Windows/CrossOver-only. It's
tested manually, inside FH:

## Manual test

1. Build the single-file plugin (`lua bridge/scripts/build.lua` from the repo root — see
   docs/adr/0009-bundle-bridge-plugin-for-install.md) and copy the resulting
   `bridge/dist/Claude MCP Bridge.fh_lua` into FH's Plugins folder —
   `C:\ProgramData\Calico Pie\Family Historian\Plugins\` on native Windows, or the
   equivalent path under CrossOver's virtual C: drive on Mac.
2. In FH: Tools -> Plugins -> New, open `Claude MCP Bridge.fh_lua` from that folder, click Run.
   Confirm `fhInitialise`'s save-required prompt (issue #33) fires here, before the Bridge's
   own dialog appears: with unsaved changes in the open project, FH shows its own dialog
   saying saving is required, with OK/Cancel. Click OK and confirm the project is saved
   (check FH's own title bar/modified indicator) and the Bridge dialog then appears as
   normal. Reload the plugin, make another unsaved change, run it again, and this time
   click Cancel — confirm the plugin ends immediately with no Bridge dialog shown at all.
   With no unsaved changes, confirm this prompt is skipped entirely and the Bridge dialog
   appears directly (fhInitialise's documented behavior when there's nothing to save).
3. A small "Claude MCP Bridge" dialog appears with a Read-only/Read-write selector (Read-only
   selected by default on a machine with no prior settings file — issue #80, see step 3a
   below for the persisted case), an "Idle timeout (min)" spin-box (spinnable between 5 and
   120 — issue #34), and Start/Stop buttons. Confirm the selector and the spin-box are
   both clickable/editable, then click Start. Confirm the selector and the spin-box both
   grey out (inactive) once the Session is running, the status label shows the chosen mode,
   e.g. "Listening on 127.0.0.1:8734 (read-only)", and a "Time left: M:SS" label appears
   below the spin-box and counts down once per second — confirm the full text is visible,
   not clipped to a couple of characters (the label is created with an empty title, so it
   needs an explicit `expand="HORIZONTAL"`, same fix as `lblStatus`, or it maps too narrow
   for the text set into it later). Click Stop and confirm the selector
   and spin-box both become editable again, and the "Time left" label clears. Select
   Read-write, click Start again, and confirm the status label now shows "(read-write)" —
   Sandbox behavior is unchanged either way this stage, so only the label/lock differs.
   Click Stop.
3a. Settings persistence (issue #80): with the dialog still open from step 3 (Read-write/
   a non-default idle-timeout minutes last used), close the plugin (window X, no Session
   running so no confirm prompt) and reload it (Tools -> Plugins -> Run again). Confirm the
   Access-mode selector and idle-timeout spin-box both reopen with the same values you left
   them on, not reset to Read-only/15. Change the idle-timeout to a different in-range value
   without clicking Start, then reload again — confirm that unsaved change was *not*
   persisted (settings are only saved on a successful Start, per issue #80's ticket), i.e.
   the dialog still shows the value from the last successful Start. Then click Start with
   the new value, Stop, reload — confirm it now sticks.
   Click Stop.
4. Resize: drag the dialog wider and taller. Confirm the status label's text isn't
   truncated at the new width, and that the Start/Stop buttons stay pinned to the bottom
   of the dialog rather than floating in the middle. Try shrinking it back down and
   confirm it stops shrinking while the buttons are still fully visible (the MINSIZE
   floor) instead of letting them go off-screen (issue #12).
5. From a terminal, send a trivial script and confirm the JSON comes back correctly:
   ```bash
   python3 -c "
   import socket
   script = b'return {ok=true, echoed=42}'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `{"ok":true,"echoed":42}`
6. Try a script that errors, and confirm it comes back as a JSON error instead of
   crashing the Session (the dialog should still show "Listening..." afterward):
   ```bash
   python3 -c "
   import socket
   script = b\"error('deliberate test failure')\"
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object containing `"error"` and `"deliberate test failure"`.
7. Try a deliberately runaway script and confirm the watchdog aborts it — the dialog
   should stay responsive, and this should return within a few seconds rather than
   hanging FH:
   ```bash
   python3 -c "
   import socket
   script = b'while true do end'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object containing `"error"` and `"instruction limit"`.
8. Click Stop (or send `STOP\n` the same way as the prototype's original test) — FH
   should become interactive again immediately.
9. Idle-timeout auto-Stop and countdown (issue #34): the spin-box enforces a 5–120 minute
   range with no override in the UI, so for a fast test, temporarily lower
   `timeoutDisplay.MIN_MINUTES` (e.g. to `1`) — copy the modified `timeoutDisplay.lua`
   alongside the rest of `bridge/`'s files, reload the plugin, set the spin-box to its new
   minimum, click Start, then leave the Session idle (no request sent). Confirm the
   "Time left" label counts down to "0:00" and the dialog then auto-returns to "Not
   listening." with the selector and spin-box both clickable again, with no request sent
   and without clicking Stop. Restore `timeoutDisplay.MIN_MINUTES` to `5` afterward (and
   re-run `lua bridge/tests/timeoutDisplay.test.lua` to confirm the restored value still
   passes its assertions).
10. FH read allowlist: with a real FH project open and a Session started (read-only),
   confirm `fhu.records("INDI")` and the raw primitives are actually wired up against
   real data — count every `INDI` record and cross-check against FH's own count (e.g.
   Tools -> Reports, or the project's Individual count shown elsewhere in FH's UI). The
   script below assumes `fhu.records(tag)` is a for-in iterator, per fhUtils' own docs
   (this repo doesn't bundle fhUtils — it ships with every FH install, see issue #1's
   "fhUtils dependency" note) — adjust the loop shape if that's wrong:
   ```bash
   python3 -c "
   import socket
   script = b'local n = 0; for indi in fhu.records(\"INDI\") do n = n + 1 end; return n'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a bare number matching FH's own count of Individuals in the open
   project.
11. FH write allowlist (issue #14): with a real FH project open, select Read-write, click
   Start, then create an Individual and set a field on it, confirming the change lands in
   the open project (check FH's own tree/Individual list after the script runs):
   ```bash
   python3 -c "
   import socket
   script = b'''
   local ptr = fhCreateItem(nil, \"INDI\")
   fhSetValueAsText(ptr, \"NAME\", \"Test /Person/\")
   return fhGetItemText(ptr, \"~\")
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON string, and a new Individual named "Test /Person/" visible in
   FH once you look at the project (undo with Ctrl-Z to clean up — see CONTEXT.md "FH
   auto-undo"). If the Records Window or a diagram showing this record is visible
   on-screen at the time, confirm it reflects the new record without you having to click
   or switch windows yourself — that's `fhUpdateDisplay()` (issue #33) firing right after
   the response is sent. Then repeat with Read-only selected instead and confirm the same
   script now fails with a JSON error calling a nil value (`fhCreateItem` absent).
12. `describe_project` forced Read-only (issue #16): with a Read-write Session started,
   send a `LUA_RO` request directly (this is what `describeProjectTool.ts` sends) and
   confirm it still cannot reach a write function, even though the Session itself is
   Read-write:
   ```bash
   python3 -c "
   import socket
   script = b'return fhCreateItem'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA_RO %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `null` (`fhCreateItem` is `nil` in the forced Read-only sandbox).
   Confirm a plain `LUA` request in the same Read-write Session returns something other
   than `null` for the same script, proving the two forms genuinely differ.
13. `fhBridge.createSourceFromTemplate` (issue #18): with a real FH project open that has a
   Source Template you can use (the example below uses "Civil Registration Certificate"
   with a "Type" field, per the "Civil Registration Certificate" template used for source
   #41 in this project — substitute a template name and field code/value that actually
   exist in your own project's Source Templates otherwise), select Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local result = fhBridge.createSourceFromTemplate(\"Civil Registration Certificate\", { Type = \"Birth\" }, \"Test transcription\")
   return result
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object with `id` and `title`. Confirm in FH's own UI that a new
   Source record now exists, linked to the chosen template, with its `Type` field set to
   "Birth", a "Text from Source" of "Test transcription", and an auto-generated title
   (undo with Ctrl-Z to clean up — see CONTEXT.md "FH auto-undo"). Then repeat with
   Read-only selected instead and confirm the same script now fails calling `fhBridge` as
   nil, the same way any other write attempt does (step 11's negative case).
14. `fhBridge.citeSource` (issue #18 follow-up, ADR 0006): with a real FH project open that
   has at least one Source record (the example below cites Source #41 in this project's own
   tree — substitute a Source record id/title that actually exists in yours), select
   Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local p = fhNewItemPtr()
   p:MoveToFirstRecord(\"INDI\")
   while p:IsNotNull() and fhGetRecordId(p) ~= 124 do p:MoveNext() end
   fhBridge.citeSource(p, 41)
   return \"ok\"
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `"ok"`. Confirm in FH's own UI that the Individual now has a new
   Whole-record source citation to the chosen Source (undo with Ctrl-Z to clean up). Then
   repeat with Read-only selected instead and confirm the same script now fails calling
   `fhBridge` as nil (step 11's negative case).
15. Write-mode error handling / FH auto-undo (issues #15, #19, ADR 0005): with a real FH
   project open, select Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   fhu.createIndi(\"ZZ_MANUAL_TEST_ROLLBACK\", \"Male\")
   error(\"deliberate error after write, manual test\")
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON error object containing `"writeSessionRolledBack":true`. FH
   should then pop its own "Plugin Error" dialog naming the same error, asking "Do you
   wish to rollback (i.e. undo) all changes to data records made by this plugin?" — click
   Yes and confirm the new Individual is gone. The Bridge Session ends as part of this (the
   dialog closes, the socket stops listening) — reopen the plugin via Tools -> Plugins and
   click Start again before the next step.

   Negative case (nothing written before the error): same setup, but a script that never
   calls a write function first —
   ```bash
   python3 -c "
   import socket
   script = b'error(\"boom, nothing written first\")'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a plain JSON error object with no `writeSessionRolledBack` field, no
   FH dialog, and the Session still listening afterward — send a trivial script (step 5)
   again on the same Session to confirm it's still up.

   Read-only case: repeat the first script (the one that calls `fhu.createIndi`) with
   Read-only selected instead of Read-write. Expected output: a JSON error calling
   `fhu.createIndi` as nil (step 11's negative case) — `fhu`'s write methods are gated the
   same way the raw write primitives are, so nothing is ever written and there's nothing
   for FH to roll back.
16. `fhBridge.logActivity` (issue #36): with a real FH project open, select Read-write,
   click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local p = fhNewItemPtr()
   p:MoveToFirstRecord(\"INDI\")
   fhBridge.logActivity(p, \"created\")
   fhBridge.logActivity(p, \"fact added Birth\")
   return \"ok\"
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `"ok"`. Confirm in FH's own UI that exactly one new Research Note
   record now exists (View -> Research Notes), titled with a creation timestamp, containing
   two log entries, each with a working, clickable link to the Individual record (undo with
   Ctrl-Z to clean up). Send a third `fhBridge.logActivity` call on the same Session and
   confirm it appends a third entry to the SAME note rather than creating another one. Stop
   the Session, click Start again (a new Session), and send one more `fhBridge.logActivity`
   call: confirm this creates a second, separate Research Note rather than appending to the
   first Session's note. Then repeat with Read-only selected instead and confirm the same
   script now fails calling `fhBridge` as nil (step 11's negative case).
17. `fhBridge.logActivity`'s optional `media` param (issue #39): on a Read-write Session,
   send `fhBridge.logActivity(p, "fact added Birth", {name = "bc-nellie.jpg"})`. Confirm the
   note gets a new entry with an indented `[ ] #ToDo Media to be added bc-nellie.jpg`
   sub-line directly under it. Send another call with
   `{name = "cert.jpg", location = "family archive box"}` and confirm that sub-line reads
   `[ ] #ToDo Media to be added cert.jpg (family archive box)`. Send a plain two-argument
   call again and confirm it appends an entry with no sub-line at all.
18. Version mismatch reporting (issue #45): click Start, then send a `VERSION` request
   claiming a different server version than the Bridge's own, and confirm the reply and the
   dialog both reflect it:
   ```bash
   python3 -c "
   import socket
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(b'VERSION 0.0.1\n')
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object `{"version": "<the Bridge's actual version>"}`. Confirm
   the dialog's status label now also shows a "Version mismatch" line. Then send a trivial
   script (step 5) on the same Session and confirm the mismatch line is *still* shown
   alongside the normal "Last request handled at ..." line — it must not vanish the moment
   the next ordinary request is handled. Finally, send another `VERSION` request that
   matches the Bridge's own version (check the dialog title bar/`@Version` header for the
   exact string, or just send the same one back) and confirm the mismatch line disappears
   from the next status update.
19. `fhBridge.getFamilyGroup`/`getAllDetails`/`getAncestors`/`searchByName`/`getFactsByTag`
   (familyHelper.lua): with a real FH project open, select **Read-only** (not Read-write —
   the point of this step is that these five work without the write gate), click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local p = fhNewItemPtr()
   p:MoveToFirstRecord(\"INDI\")
   return {
     group = fhBridge.getFamilyGroup(p, \"all\"),
     details = fhBridge.getAllDetails(p),
     ancestors = fhBridge.getAncestors(p, 3),
     byName = fhBridge.searchByName(fhGetItemText(p, \"~.NAME:GIVEN_ALL\"), nil),
     byTag = fhBridge.getFactsByTag(p, {\"BIRT\", \"CENS\"}),
   }
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(65536).decode())
   s.close()
   "
   ```
   Expected output: a JSON object with `group` (an array of `{relationship, individual,
   family}` entries for the first Individual's parents/siblings/spouses — cross-check
   names/relationships against FH's own Family view for that person), `details` (a nested
   tree with the record's own `tag`/`id`/`qualifiedId` and a `children` array covering
   every field FH's own Property Box shows for that person), `ancestors` (an array of
   `{generation, line, individual, family}` entries no deeper than generation 3), `byName`
   (an array of `{id, qualifiedId, name, sex}` entries — every Individual whose given
   name(s) contain the first Individual's own given name(s); confirm the first Individual
   itself is in the list, and cross-check the count against FH's own Find dialog searching
   that same forename), and `byTag` (an array of full detail trees, one per `BIRT`/`CENS`
   fact recorded directly on that first Individual — cross-check the count and each entry's
   `DATE`/`PLAC` children against FH's own Facts tab for that person; an Individual with no
   census facts recorded should still get a valid, non-error result covering just their
   `BIRT`, or `[]` if they have neither). Confirm nothing in the project changed (these are
   read-only). Then repeat with Read-write selected instead and confirm the same script
   still succeeds with the same shape of result — unlike
   `fhBridge.createSourceFromTemplate`/`citeSource`/`logActivity`, these five are not
   gated to Read-write.
20. `fhBridge.createFact` (issue #113): with a real FH project open, select Read-write,
   click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local p = fhNewItemPtr()
   p:MoveToFirstRecord(\"INDI\")
   local fact = fhBridge.createFact(p, \"CENS\", \"Someplace\", \"1901\")
   return fhGetTag(fact)
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `"CENS"`. Confirm in FH's own UI that the first Individual now has a new
   Census fact with Place "Someplace" and Date "1901" (undo with Ctrl-Z to clean up). Then
   repeat with a qualified id string in place of the live pointer (e.g.
   `fhBridge.createFact("I1", "CENS", "Someplace", "1901")`, substituting a real qualified id
   from your project) and confirm it creates the fact the same way. Then repeat with
   Read-only selected instead and confirm the same script now fails calling `fhBridge` as
   nil (step 11's negative case).
