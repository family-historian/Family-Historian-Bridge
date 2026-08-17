# FH MCP Bridge

An MCP server, installable alongside Family Historian (FH), that lets Claude query and
edit a user's open FH project by sending Lua scripts to a companion FH plugin over a
local TCP socket.

## Language

**Bridge plugin**:
The Lua plugin that runs inside FH itself, opens the local TCP listener, and executes
scripts sent to it. Its entry file, `bridge/Claude MCP Bridge.fh_lua`, is a stub — header
comment, `fhInitialise(...)`, `fhSetStringEncoding("UTF-8")`, then `require("bridgeSession")`
— with the dialog UI, socket poll loop, and Session lifecycle living in `bridge/bridgeSession.lua`
instead, so Serena's symbol tools can cover it (issue #75, docs/adr/0018-split-bridge-entry-file
-into-stub-and-bridgesession.md); `.fh_lua` files aren't recognized by Serena's Lua language
server, `.lua` files are. Supersedes an earlier prototype (`bridge_prototype_v2.fh_lua`, removed
from this repo) — a user who never updated their FH Plugins folder past that old prototype gets
a specific error telling them to switch, rather than a generic connection failure; see
**run_lua**'s "stale plugin" handshake check in `bridgeResponse.ts`.
_Avoid_: Plugin (alone, when the bridge specifically is meant), server (reserve "server"
for the MCP server), Family Historian Bridge (that's the product's install-time/user-facing
display name — see **Family Historian Bridge** below — not this specific Lua component)

**Family Historian Bridge**:
The product's user-facing display name — the Claude Desktop extension list entry and the
Windows Start Menu entry (`installer/dxt/manifest.mjs`'s `display_name`,
`installer/fh-mcp-bridge.iss`'s `AppName`) — and the name a user may reasonably say or write
when referring to the installed product as a whole. Distinct from **FH MCP Bridge** (this
repo/package's own dev-facing name, the title of this file) and from **Claude MCP Bridge**
(the FH-side plugin's own `@Title`, shown inside FH's Plugins dialog — see **Bridge
plugin**). Deliberately narrow in scope when introduced: the rename touched only these two
install-time surfaces, not the repo/package name, docs prose, or the FH-side plugin's
`@Title`. The Windows installer's `DefaultDirName` deliberately stayed `FH MCP Bridge` so a
future build upgrades an existing install in place rather than orphaning it at a new path.
_Avoid_: FH MCP Bridge, Claude MCP Bridge (interchangeably with this — three related names
now exist for three different surfaces; keep them distinct)

**Session**:
The period between a user clicking Start and clicking Stop (or an idle timeout, a
socket `STOP` command, or closing the dialog via Exit or the window's X) on the bridge
plugin's dialog. Access mode (read-only vs read-write) is chosen once, at Start, and
holds for the whole session. Distinct from the main-window lock (see **Exit**) — Stop
ends the Session but does not release the lock, so "locked for the whole session" is not
quite right; the lock's real scope is "for as long as the plugin is loaded," not "for as
long as a Session is running."
_Avoid_: Connection (a session can span many short-lived socket connections, one per
`run_lua` call), "locked for the whole session" (see above — that's the plugin's
lifetime, not the Session's)

**Exit**:
Closes the whole Bridge plugin (not just the Session) — the Exit button and the dialog's
own window X are equivalent and share the same teardown. If a Session is running, it's
torn down first; the user is prompted to confirm only when a request was actually handled
within the last 10 seconds (a hardcoded freshness heuristic, not user-configurable, and
distinct from merely having clicked Start) — the only observable signal that Claude might
be about to send another request. See
docs/adr/0020-exit-button-shared-teardown-freshness-confirm.md.

FH's main window is locked for as long as the plugin is loaded — from Start through Exit
— not just for the Session's own Start-to-Stop span, a deliberate trade-off, not a bug.
Confirmed against `bridge/bridgeSession.lua`: `btnStop:action` only unbinds the Session's
TCP listener, it never calls `iup.CLOSE` or destroys the dialog, so Stop alone leaves the
lock in place. FH's own `fhInitialise(..., "save_required")` gate only fires once, at
plugin load, so a Stop-then-Start cycle within the same still-open dialog never
re-triggers it either. This is why a user has to Exit (not just Stop) before they can
File > Save in FH — see `run-lua-guidance-write-session-rolled-back`'s save-cadence
mitigation in the GEDCOM knowledge corpus (issue #107).
_Avoid_: Stop (alone, when Exit specifically is meant — Stop only ends the Session and
leaves the plugin open, main-window lock included; Exit ends the plugin itself and is
what actually releases the lock)

**Access mode**:
The read-only/read-write toggle set by the user at session Start. Read-only exposes only
FH's read API inside the sandbox — plus, as of issue #51, a guarded partial exposure of
`fhGetFactTag`/`fhGetFlagTag`: their pure-lookup branch (`bCreateIfNone=false`) works
read-only, while their `bCreateIfNone=true` schema-creating branch raises a clear error
instead. Read-write additionally exposes FH's full write API — `fhSetLabelledText`, every
`fhSetValueAs*` setter (`Age`/`Date`/`Integer`/`Link`/`RichText`/`Text`), `fhCreateItem`,
`fhDeleteItem`, `fhMoveItemAfter`/`fhMoveItemBefore`, `fhSrcEnableAutoTitle`, and the full,
unguarded `fhGetFactTag`/`fhGetFlagTag` (including their `bCreateIfNone=true`
schema-creating path) — all at once; there is no further staging within read-write. See
docs/adr/0005-write-mode-errors-rethrown-for-fh-auto-undo.md for how a write script's own
runtime errors are handled.
_Avoid_: Permission level, mode (alone)

**Sandbox**:
The restricted Lua environment (`_ENV` table passed to `load()`) that a submitted script
runs inside. Built as an allowlist — only explicitly added globals are visible — rather
than starting from the real environment and stripping known-dangerous ones. `fhu` is
exposed as a preloaded global (a proxy over what `require('fhUtils')` returns in an
ordinary, non-sandboxed FH plugin), never the raw FH-shipped module — `require` itself
isn't in the allowlist, so `require('fhUtils')` returns nil inside this sandbox; always
reference `fhu.<method>` directly. Being a proxy also means its
methods can be gated the same way: besides the write-gating in **Access mode**, eight
`fhu` methods (`getParam`, `createUpdateFact`, `pickIndividualPrompt`, `yes`,
`stripCommas` when called with its optional UI arguments, `saveOptions`, `loadOptions`,
`resetOptions`) are replaced with an error-raising wrapper in both Read-only and
Read-write — unconditionally, regardless of access mode — because they either pop a real
modal dialog (hanging a headless `run_lua` call) or read/write a file on disk directly,
bypassing this project's filesystem exclusion below (issue #22). See `bridge/sandbox.lua`
for the authoritative list and reasons.
_Avoid_: Denylist, restricted mode

**FH auto-undo**:
FH's own native safety net for project-data changes any Lua plugin makes — entirely
outside this project's code. The user can always manually revert via FH's Ctrl-Z; FH also
automatically undoes a plugin's changes if an uncaught Lua error escapes the plugin. This
project implements no undo logic of its own anywhere in the bridge or server — see
docs/adr/0005-write-mode-errors-rethrown-for-fh-auto-undo.md for how `run_lua` avoids
swallowing a write script's error so this safety net gets a chance to fire.
_Avoid_: Rollback (this project has no rollback code of its own — the mechanism is FH's,
not ours)

**run_lua**:
The one MCP tool this server exposes to Claude. Takes a freshly-authored Lua script per
call; there is no fixed set of query/write commands beyond this single entry point.
_Avoid_: Query tool, command (there is no fixed command set — every call is a bespoke
script)

**describe_project**:
The MCP tool (issue #10) that runs a fixed, built-in Lua script — not a Claude-authored
one — returning record counts per record type plus a distinct-tag census: INDI and FAM
child items and SOUR record child items, each tag paired with its occurrence count, plus
`sourceTemplateFieldDefinitions` — every Source Template's own field CODEs (with `TYPE` and
whether each is Citation-specific), not an occurrence count. That last one used to be
`sourceTemplateFields`, an occurrence count of populated record-level fields (issue #67/
#73) — issue #74 (ADR 0017) found it silently gave zero for every Citation-specific field
(`CITN`) instead, since those populate on a citation, not the SOUR record itself, and a
real fix would mean walking every citation across every INDI/FAM record on every
`describe_project` call, which recomputes on every call with no caching (see below). So
this section became structural-only instead — cheap and bounded by how many templates the
project actually has (FH only copies templates it's actually used into the project) rather
than by record/citation count — and actual occurrence counts, for both record-level and
citation-level fields, moved to the new **getTemplateFieldCensus** helper (below). Also
returns `flagCensus` (issue #51) — a per-tag breakdown of
Individual record flags (`__LIVING`/`__PRIVATE` plus any project-specific custom ones),
each with its occurrence count and a human-readable label resolved via
`fhGetTypeInfo(ptr, "label")` — and `dataQuality` (issue #51), a namespace for data-gap
signals, currently just `livingStatusAmbiguousCount` (Individuals with a resolved birth
date, no `DEAT`/`BURI`/`CREM` fact, and no Living flag — likely a missing-data gap, not a
confirmed living person). See
docs/adr/0014-describe-project-flag-census-and-data-quality-namespace.md for why
`flagCensus` is Individual-record-flags-only (Fact Flags are a separate mechanism, not
covered) and why `dataQuality` is its own namespace rather than a bare top-level count.
Also returns `contextInfo` (issue #51 — this half of the ask was missed from the first
pass and added on a later review) — the 9 documented `fhGetContextInfo` `CI_*` keys that
are plain strings/booleans (`CI_PROJECT_NAME`, `CI_PROJECT_FILE`, `CI_GEDCOM_FILE`,
`CI_PROJECT_PUBLIC_FOLDER`, `CI_PROJECT_DATA_FOLDER`, `CI_PLUGIN_NAME`,
`CI_APP_DATA_FOLDER`, `CI_APP_MODE`, `CI_STRING_ENCODING`). `CI_APP_HWND`/`CI_PARENT_HWND`
are excluded — they return Lua light userdata, which `bridge/jsonEncode.lua` can't encode
at all — as are the report/book-only `CI_BOOK_CONTEXT`/`CI_BOOK_ITEM_HEADING`, which are
meaningless outside a report plugin's book context.
Also returns `fhAppVersion` (issue #69) — Family Historian's own application version
(e.g. `"8.0.0"`), read via `fhGetAppVersion()` and formatted as a dotted string to match
how `BRIDGE_VERSION`/`SERVER_VERSION` are already represented elsewhere in this codebase
(`bridge/versionCompare.lua`), rather than the three separate integers that function
actually returns.
Recomputed on every call; see docs/adr/0002-describe-project-no-server-cache.md for why
it isn't cached. Always executes in the Read-only sandbox regardless of the Session's own
Access mode — its script is fixed and known to never call a write function, so there's no
reason to ever run it with write capability available even during a read-write Session.
Also returns `bridgeState` (issue #109, docs/adr/0026-bridge-state-in-describe-project-
census.md) — the running Bridge plugin's own state, not the FH project's:
`bridgeVersion`/`serverVersion`/`versionStatus` (the same match/warn/unsupported/
unparseable verdict every call's VERSION exchange already computes, reused verbatim rather
than re-derived) and `accessMode` (the Session's real read-only/read-write toggle — distinct
from the Read-only sandbox this script itself always executes under, described just above).
Any field genuinely unknown (an old Bridge predating `accessMode` on the wire, or a version
reply that didn't parse) is `null`, not an omitted key. Merged in server-side from the same
VERSION exchange every call already makes (see **Version check** below) — no second
connection, no new sandbox globals.

_Avoid_: Census tool, project summary (there is exactly one tool with this name and shape)

**author_fh_plugin**:
The MCP tool (issue #9) that scaffolds a standalone FH Report/Query plugin: Claude authors
the query/report logic, the tool wraps it in the plugin type's required boilerplate, and
returns it as text for the user to save themselves as a `.fh_lua` file. The two plugin
types get different treatment, not just different headers: a Report plugin gets the
required `@Type: report` header plus an `FH_GetRecordSectionContent` entry-point function
wrapped around the logic; a Query plugin gets neither, since ordinary/query-style plugins
have no required header field or entry-point function in FH's own plugin architecture —
that absence is what structurally distinguishes it from a Report plugin, not an
oversight. Distinct trust model from `run_lua`: this output is never executed by the
bridge — it's unreviewed-until-installed, run under FH's own trust boundary once the user
installs it (double-click on Windows, or FH's Import option), so functions `run_lua`'s
sandbox excludes (`fhShellExecute`, filesystem functions, `fhMessageBox`,
`fhPromptUserFor*`, `fhOutputResultSetColumn`/`fhOutputResultSetTitles`, etc.) are fair
game here. Any such function used in the generated script is flagged inline in the
output, since installing a plugin is a weaker review step than reviewing an inline chat
answer.
_Avoid_: Plugin generator (alone, without the trust-model distinction from `run_lua` —
that distinction is the point of this tool existing separately)

**install_fh_plugin**:
The MCP tool (issue #24) that writes a plugin `author_fh_plugin` generated directly into
FH's Plugins folder, so the user doesn't have to save the file and find that folder
themselves. A distinct, later step from `author_fh_plugin` — never called automatically as
its follow-up, only on the user's explicit request to install what was just generated; see
docs/adr/0008-install-fh-plugin-staged-write.md. Resolves the Plugins folder location live
via `fhGetContextInfo("CI_APP_DATA_FOLDER")` through an active Bridge Session (falling back
to a user-confirmed `path` parameter when no Session is running), and never overwrites —
each install gets the next unused `V<N>` suffix on both the filename and the plugin's own
`@Title` header. Writes via the MCP server's own filesystem access, not through the Bridge
or `run_lua`'s sandbox; `fhSaveTextFile` and the rest of `run_lua`'s excluded-function list
are unaffected by this tool's existence. Always writes as UTF-8 with a leading BOM (`U+FEFF`)
so FH loads the file as Unicode rather than defaulting to ANSI — see docs/adr/0008's
decision 5.
_Avoid_: Publish, upload (this project's own name for the operation is "install", matching
FH's own Tools -> Plugins terminology)

**Version check**:
A `VERSION` request the server sends over its own connection ahead of every
`run_lua`/`describe_project`/`install_fh_plugin` call that talks to the Bridge, comparing
its own version against the running Bridge's (issue #45) — catches a stale Bridge plugin
left installed against a freshly upgraded server, or vice versa, since a mismatch doesn't
necessarily break the wire protocol on its own. A matching or minor/patch-differing version
always gets noted in the Bridge's own dialog, and in the tool's result text for
`run_lua`/`install_fh_plugin` — `describe_project` surfaces the same verdict as a
structured `bridgeState.versionStatus` field instead (issue #109,
docs/adr/0026-bridge-state-in-describe-project-census.md), not a second copy as text; see
**describe_project**'s own entry above. Issue #109 also grew the Bridge's `VERSION` reply
from `{version}` to `{version, accessMode}`, so `describe_project`'s `bridgeState` can
report the Session's real Access mode without a second connection. A differing major
version blocks the call entirely with an error instead of running the real request (inert
today, pre-1.0 — see docs/adr/0013-bridge-server-version-mismatch-check.md for the full
wire protocol, severity policy, and the backward-compatible handling of a Bridge that
predates this check).
_Avoid_: Handshake (there's no persistent per-Session handshake — every check is its own
bodyless connection, same connection-per-request model as every other request; see
**Session**'s own _Avoid_ note)

**Source template**:
An FH template definition (e.g. "Census Record", "Birth Certificate") that declares the
citation field/subfield names a SOUR record created from it will have. Distinct from a
SOUR record itself: a template declares what fields are *possible*; a SOUR record's own
child items are whichever of those fields this project actually populated.
_Avoid_: Source (alone, when the template specifically is meant, not a record instance)

**GEDCOM knowledge corpus**:
A searchable reference (own JSONL file, separate from the FH-help corpus so a
`check_fh_help_updates` sync can't overwrite it) of domain facts about FH's live data model —
GEDCOM 5.5.1 core concepts, FTF rich text, Shared Facts, Fact/Record Flags, Source Template
fields, Sentence templates — plus, under its own `"Bridge project conventions"` top-level
breadcrumb (distinct from the domain-facts entries above), this project's own first-party
operational guidance: the `"run_lua guidance"` family gathers behavioral gotchas moved out of
`RUN_LUA_DESCRIPTION` once it outgrew the ~2KB safe zone (docs/adr/0011), and the
`"fhBridge API reference"` family (issue #102, docs/adr/0024) sits alongside it — one compact
entry per `fhBridge.*` function (Description/Parameters/Returns only; no design history or
issue numbers — that stays in this file's own per-function entries and in bridge/README.md).
Despite this file's name, it is not GEDCOM-domain-scoped only — "GEDCOM knowledge" describes
its original seed content, not a hard boundary on what it now holds. Each entry carries a
confidence tag (Verified / Confirmed / Documented / Likely) and a citation back to its source
(an FH help page, a specific line in the family_historian_mobile project's tag-mapping specs,
or — for the Bridge-project-conventions family — this repo's own source/ADRs, always tagged
Verified) — entries inherited from that sibling project describe its raw exported-GEDCOM-file
findings, not FH's live API, so each is cross-checked against FH's own help before being
trusted here. Deliberately excludes anything that only describes the exported-file wire format
(e.g. `_LINK_*`/`_LKID` mechanics, the `_PLAC`/`_ADDR` gazetteer, encoding options) since
`run_lua`'s sandbox never reads or writes a `.ged` file directly — see
docs/adr/0003-gedcom-corpus-scope-live-api-only.md; that exclusion is about the exported-file
format specifically, not a bar on first-party Bridge content generally (the
`"Bridge project conventions"` family predates and sits outside it). `_SRCT` itself is *not*
one of the exported-file-format exclusions — it's also a live record-type tag (Source Template
record), reachable the same way as INDI/FAM/SOUR; see **Source template** below and the
corpus's "Creating a templated Source record" entry for how a Source record links to one and
gets its fields populated.
_Avoid_: FH help corpus (that's the separate, official-help-site-sourced one; see
`fh-help-corpus.jsonl`)

**FTF (Family Historian Text Format)**:
The rich-text markup FH stores internally in any multi-line text field (Notes, Source `TEXT`,
citation-level `DATA/TEXT`, etc.) — inline style commands (`<b>`, `<i>`, ...), tables, web/record/
citation links, and `[[private]]` spans. Distinct from eFTF (report-only superset) and tFTF
(the `SetText` plugin API's text-only variant, and the basis for **getTftfText**/
**setTftfText** below).
_Avoid_: Rich text (alone, when FTF's specific markup grammar is meant)

**getTftfText** / **setTftfText**:
The `fhBridge` helper pair (`richTextHelper.lua`, issue #107,
docs/adr/0025-tftf-full-rewrite-for-mid-document-richtext-edit.md) for editing IN THE
MIDDLE of an existing large RichText field, not just appending to the end of it (the
append-only case `logActivity` already handles well via a live-object
`AddText`/`AddRecordLink` buffer). `getTftfText(ptr)` fetches a field's content and
rewrites every index-based `<rec=N,...>` reference (eFTF, as `GetText()` itself returns)
into a self-contained `<rec=QualifiedId,...>` one (tFTF) — safe to splice/reorder/insert
into with ordinary Lua string operations, since a qualified id needs no companion table
the way an index does. `setTftfText(ptr, text)` commits an edited tFTF string back in one
full-document `SetText(text, true, true)` rewrite. Neither function will touch a field
that has embedded source citations — tFTF cannot represent a citation at all, and,
confirmed live, `SetText(..., true, true)` does not error on one; it silently discards it.
`getTftfText` reports such a field `editable = false` with a `reason`; `setTftfText`
re-checks and errors outright rather than risk that loss. Editing a citation-bearing
field's interior remains an open problem — deliberately out of scope for this pair; see
docs/adr/0025.
_Avoid_: A hand-rolled `GetText()`/extended-`tblRecLinks`/`SetText()` round trip for a
record-link edit — proven broken for anything beyond an exact passthrough (issue #106,
`run-lua-guidance-settext-reclinks-cannot-add-new-links` in the gedcom-knowledge-corpus)

**Shared Fact**:
A Fact (Individual or Family event/attribute) with participants beyond the record it's attached
to — e.g. other residents of a household, a wedding's best man. Each participant carries a free-
text `ROLE` (not a fixed enum) and either resolves to an existing Person or is a name-only
mention with no Person record.
_Avoid_: Witness (a Shared Fact's participant role, not a separate mechanism)

**Fact Flag** / **Record Flag**:
Two distinct flag mechanisms that happen to share some names. A Record Flag marks an Individual
record as a whole (only 2 built-in: Private, Living); a Fact Flag marks one specific fact (4
built-in: Private, Preferred, Tentative, Rejected — Rejected always overrides Preferred on the
same fact, confirmed against FH's own help). Both support unlimited custom flags. A "Private"
Record Flag and a "Private" Fact Flag are always distinct, even on the same person.
_Avoid_: Flag (alone, without saying which kind — the distinction matters for correctness)

**Source Template field**:
One structured, populated value on a SOUR record or citation, created from a Source template's
field definition (code, type, prompt). Distinct from the Source template definition itself,
which only declares what fields are possible — see **Source template**.
_Avoid_: Custom field (this project reserves "custom" for user-defined Facts, not Source
template fields, which come from a template FH or the user has already defined)

**Direct ancestor**:
For a given person, every person reachable by walking `FAMC` (family-as-child) links
upward — following *all* of a person's `FAMC` links where more than one exists (e.g. an
adoptive line alongside a biological one), not just a designated "primary" one, since FH's
data has no reliable field marking one as primary. Walks back with no generation limit
unless the user's own question specifies one. Excludes the named person themselves.
_Avoid_: Ancestor (alone, when the "direct" — i.e. FAMC-only — walk specifically is meant,
as opposed to some broader/looser notion)

**Clarifying question**:
When a natural-language query has ambiguous scope (e.g. an unspecified generation depth,
an ambiguous place spelling), Claude asks the user rather than silently picking a default
and running a `run_lua` script against a guessed interpretation.

**Whole-record citation**:
A `SOUR` citation attached directly to an `INDI` or `FAM` record itself, rather than to
one specific Fact belonging to it. FH's own help calls this a "citation for the record as
a whole" — distinct from (and additional to) citing the individual Facts a source
supports. Used when a source establishes the record itself (e.g. a birth certificate
naming a father and mother makes them each a source for their own Individual record and
for the parent-child Family relationship), not just one dated event on it.
_Avoid_: Record citation (alone — "whole-record" is FH's own distinguishing term, since a
Fact-level citation is also, informally, "a citation on the record")

**citeSource**:
The `fhBridge` helper (`sourceHelper.lua`) that attaches a `SOUR` citation to any target
item — an `INDI`/`FAM` record (a Whole-record citation) or a specific Fact item — given a
Source record resolved the same by-id, by-qualified-id-string, or by-title way
`createSourceFromTemplate` resolves a template (issue #100: a qualified id string like
"S1186" always resolves as an id, never attempted against Title, even on the coincidence
of a Title reading the same way). See docs/adr/0006-cite-every-fact-a-source-supports.md
for why this exists as
a shared helper instead of each script hand-rolling `fhCreateItem("SOUR", ...)` +
`fhSetValueAsLink`. Takes an optional third `fields` argument (issue #99, follow-up to
#98's own closing comment, which left this deliberately untracked until a real need
materialized) mirroring `createSourceFromTemplate`'s own `fields`, covering two families in
one flat table: the 4 reserved **standard citation fields** below (always valid, templated
or not) and a template's own **Citation-specific field** codes (only valid when the
resolved source is actually templated — a record-level template field code is rejected the
same way `createSourceFromTemplate` rejects a citation-specific one, just the mirror image).
A reserved standard-field name always wins over a same-named template field code, which is
rejected outright as a collision rather than silently misrouted. Returns the created
citation's own live item Pointer (not a `qualifiedId` — a citation is a child item nested
under a record/Fact, not a standalone record with one of its own), so a script can keep
working on it directly within the same `run_lua` call.
_Avoid_: Add source, link source (this project's own name for the operation is
`citeSource`, matching the domain term "citation")

**createFact**:
The `fhBridge` helper (`factHelper.lua`, issue #113) that creates a Fact (an event or
attribute — `BIRT`, `CENS`, `OCCU`, etc.) on an `INDI` or `FAM` record via `fhu.createFact`,
instead of hand-assembling `fhCreateItem` + `fhSetValueAsText`/`Date`/etc. per field. Accepts
`ptrRecord` as a live Item Pointer or a qualified id string (e.g. `"I219"`, `"F3"`) — never a
bare number, since it spans both `INDI` and `FAM` and a number alone can't disambiguate which
(same reasoning as `getAllDetails`/`getFactsByTag`, issue #65). Returns the new Fact's own
live item Pointer (not a `qualifiedId` — a Fact is a sub-item of its record, not a standalone
record with one of its own), so a script can chain straight into `citeSource(thatPointer,
sourceNameOrId, fields)` to cite the new Fact within the same `run_lua` call — see
`docs/adr/0006-cite-every-fact-a-source-supports.md`. Citing is always a separate, deliberate
step; `createFact` itself never touches a Source or citation. `dtDate` must be a real Date
value (`fhNewDate(...)`), never a plain string — live-confirmed (issue #113): a string raises
`fhSetValueAsDate`'s own type error from inside `fhu.createFact`, after the Fact item has
already been created, ending the Session via the usual write-then-error rollback flow.
_Avoid_: Add fact (this project's own name for the operation is `createFact`, matching
`fhUtils.createFact`'s own name)

**Standard citation field**:
One of the 4 generic citation-specific fields FH's own help documents as available on
every `SOUR` citation, templated source or not (`sourcesandsourcetemplates.html`): Entry
date (GEDCOM `DATA.DATE`), Assessment (`QUAY`), Where within Source (`PAGE`), Text from
Source (`DATA.TEXT`). `citeSource`'s `fields` argument exposes these under the reserved
keys `EntryDate`/`Assessment`/`Page`/`Text` respectively — `Page`/`Text` named after their
GEDCOM tag directly, `EntryDate`/`Assessment` after FH's own dialog label since
`DATA.DATE`/`QUAY` have no single-word tag a caller would recognize unaided. `Text` and
`EntryDate` both nest under one shared `DATA` child of the citation, per GEDCOM 5.5.1's own
`SOURCE_CITATION` structure — cross-confirmed against the separate `fhUtils.createTextFromSource`
helper's own doc ("attaches...to a source or citation DATA"), a different Lua API surface
than this bridge uses but the same live data model underneath. `Page`/`Assessment` are
direct citation children instead (`PAGE`/`QUAY`, GEDCOM siblings of `DATA`, not nested under
it). Assessment is validated against FH's fixed 4-axis vocabulary — see **Citation quality
assessment (QUAY)** in the gedcom-knowledge corpus. Distinct from a **Source Template
field**: a standard citation field exists independent of any template; a template's own
**Citation-specific field** only exists when the source is linked to one.
_Avoid_: Generic citation field (FH's own help uses this phrase for the same 4 fields, but
this project already reserves "generic" for a **Source template**'s own generic/free-form/
templated 3-way distinction — "standard" avoids that collision)

**findSources**:
The `fhBridge` helper (`sourceHelper.lua`) that finds every `SOUR` record linked to a given
Source template whose populated fields match a set of filters — unlike `createSourceFromTemplate`/
`citeSource`, it's read-only, wired into `run_lua`'s sandbox for both access modes (issue
#65). Matching a filter against a candidate source's own fields or against its citations'
fields instead is decided per field by the template's own **Citation-specific field** flag
(below), not chosen by the caller. Always returns `citedBy` (which facts/records cite each
match, across the whole project), so "find a comparable existing source and see how it's
normally cited" is one call, not a hand-rolled scan over every `SOUR` record.
_Avoid_: searchSources, findSource (this project's own name for the operation is
`findSources`, plural, matching that it can return more than one)

**getTemplateFieldCensus**:
The `fhBridge` helper (`sourceHelper.lua`, issue #74, ADR 0017) that returns occurrence
counts for one Source template's fields: `{ recordFields = {code = countOfSourRecords
Populated}, citationFields = {code = countOfCitationsPopulated} }` — every field the
template defines, whether populated or not (0, not omitted), so "never populated" reads
differently from "not a field on this template" (the latter still errors, same as
`findSources`/`createSourceFromTemplate`). `citationFields` counts individual citations, not
distinct sources — matching how issue #74's own evidence was framed ("1,108 of 1,196
citations"). Read-only, wired into `run_lua`'s sandbox for both access modes, same as
`findSources`/`getPopulatedTemplateFields`. Exists because `describe_project`'s own census
(see above) dropped occurrence counting entirely rather than pay for it on every call
regardless of need — this helper is where that cost lives instead, opt-in, single-template
scoped. Only pays for the whole-project citation walk (the same one `findSources` uses)
when the template actually has a Citation-specific field to count.
_Avoid_: templateFieldStats, censusTemplate (this project's own name for the operation is
`getTemplateFieldCensus`)

**Citation-specific field**:
A Source Template field whose `FDEF` (field definition) is marked "Citation-specific" in
FH's own Source Template Field Definition Dialog — populated per-citation instead of once
on the Source record as a whole (e.g. a GRO Index template's Registration District, which
varies citation to citation even though the Source record itself is shared). Live-confirmed
(issue #65) as directly readable via the plugin API: the field's `FDEF` node carries a
`CITN` child with value `"Yes"`; a Source-record-level field simply has no `CITN` child at
all. Same record-vs-citation distinction as `QUAY` and a citation's `AUTH`/`TITL`
overrides — see the `gedcom-knowledge-corpus`'s `source-template-fields` entry.
_Avoid_: Record-level field (as the unmarked default without contrasting it against this —
the point of the term is the *citation* side of the distinction)

**logActivity**:
The `fhBridge` helper (`sessionLogHelper.lua`) that logs a Read-write Session's
record-creating activity into one Research Note (`_RNOT` record) per Session — creating it
on the first call in a Session, titled with a creation timestamp, and appending a further
entry to that same note on every subsequent call in the same Session. Distinct from a
Whole-record citation or any other `SOUR`-citation concept above: a Research Note here is a
Claude-authored activity log for the user to review, not a source attached to the data
itself. Optionally takes a still-needs-media detail (a name and, if mentioned, a location),
which it renders as an indented `[ ] #ToDo Media to be added <name>` sub-line under the
entry — plain FTF text the user ticks off by hand in FH, never touching the media file's
bytes or the filesystem itself (issue #39, 2026-08-01 grilling session on issue #23).
Steered from `run_lua`'s tool description, not a Skill (issue #40) — see
docs/adr/0010-automatic-session-log-steered-from-run-lua.md for the full design. Prompt
steering alone proved optional in practice (issue #42: a fresh Claude instance wrote
records and never called `logActivity` at all), so the write-then-log invariant is now
also enforced by the sandbox itself — a static pre-scan in `runScript.lua` plus a runtime
backstop via `sandbox.lua`'s `tracker.logged` flag, rejecting or rolling back a script that
writes without logging (issue #43) — see
docs/adr/0012-enforce-write-then-log-via-pre-scan-and-runtime-check.md.

The note's opening bold heading + static intro paragraph is being replaced (issue #112,
2026-08-16 grilling session) by a labelled-field block — `Title:`/`Type:`/`Status:`/
`Date:` — using FH's own labelled-paragraph convention (the mechanism behind
`fhGetLabelledText`/`fhSetLabelledText`, see those entries below). This isn't cosmetic: FH
derives a `_RNOT` record's `fhGetDisplayText` and its name in the Records Window from a
`Title:`-labelled first paragraph, so `Title`'s value (still "Claude session log -
<timestamp>") becomes the record's actual name everywhere in FH, not just a heading
inside the note. Only the `Title:` line keeps the existing bold + `+2` heading styling —
`Type:`/`Status:`/`Date:` are plain — confirmed live by the user (issue #112) that FH's
`Title:`-paragraph detection still works with FTF rich markup around/inside the labelled
text, so there was no need to drop it for safety. `Type` (`"mcp-log"`) and `Status`
(`"closed"`) are both fixed constants on every note this helper creates — not
session/action-varying — specifically so the user can target these notes with a Smart
Folder or query once reviewed, for quick bulk cleanup. `Date` carries its own
human-scannable, date-only format (e.g. "16 Aug 2026"), distinct from the
`timestamp()`/`timeOnly()` helpers already used elsewhere in this file — it's meant for a
person scanning the Records Window, not for re-parsing. A blank paragraph still separates
the header block from the first bulleted entry, the same visual gap issue #79 established
between "header stuff" and entries, just with the (now-removed) static intro line no
longer sitting in between. No backfill: notes already created by Sessions before this
change keeps their old bold-heading layout; only notes from Sessions started after the
change ships get the new block. See
docs/adr/0029-logactivity-labelled-title-type-status-date-header.md for the full decision,
including why the plain-text-only alternative was rejected.

**run_lua guidance (corpus entries)**:
The `"run_lua guidance"`-titled entries in the GEDCOM knowledge corpus (call-shape
gotchas, `citeSource` guidance, `writeSessionRolledBack` handling) — content that used to
live directly in `run_lua`'s tool description until it was found that MCP clients loading
tool descriptions via deferred/lazy schema-loading truncate long descriptions around ~2KB,
silently. `RUN_LUA_DESCRIPTION` now keeps only a self-sufficient "safe zone" under that
cutoff, plus an explicit instruction to call `search_gedcom_knowledge("run_lua guidance")`
once per conversation to fetch the rest — a tool *result*, unlike a tool *schema
description*, isn't subject to the same truncation. See
docs/adr/0011-run-lua-description-truncation-workaround.md.
_Avoid_: Assuming `RUN_LUA_DESCRIPTION`'s full text always reaches Claude — for any client
using deferred tool loading, it doesn't, by design of this workaround as much as by the
truncation itself.
_Avoid_: Audit log, history (this project's own name for the operation is `logActivity`,
and FH's own term for the record type is "Research Note")
