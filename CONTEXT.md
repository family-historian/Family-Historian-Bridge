# FH MCP Bridge

An MCP server, installable alongside Family Historian (FH), that lets Claude query and
edit a user's open FH project by sending Lua scripts to a companion FH plugin over a
local TCP socket.

## Language

**Bridge plugin**:
The Lua plugin (`bridge/Claude MCP Bridge.fh_lua`) that runs inside FH itself, opens the local TCP
listener, and executes scripts sent to it. Supersedes an earlier prototype
(`bridge_prototype_v2.fh_lua`, removed from this repo) — a user who never updated their
FH Plugins folder past that old prototype gets a specific error telling them to switch,
rather than a generic connection failure; see **run_lua**'s "stale plugin" handshake check
in `bridgeResponse.ts`.
_Avoid_: Plugin (alone, when the bridge specifically is meant), server (reserve "server"
for the MCP server)

**Session**:
The period between a user clicking Start and clicking Stop (or an idle timeout, or a
socket `STOP` command) on the bridge plugin's dialog. FH's main window is locked for the
whole session — a deliberate trade-off, not a bug. Access mode (read-only vs read-write)
is chosen once, at Start, and holds for the whole session.
_Avoid_: Connection (a session can span many short-lived socket connections, one per
`run_lua` call)

**Access mode**:
The read-only/read-write toggle set by the user at session Start. Read-only exposes only
FH's read API inside the sandbox; read-write additionally exposes FH's full write API —
`fhSetLabelledText`, every `fhSetValueAs*` setter (`Age`/`Date`/`Integer`/`Link`/
`RichText`/`Text`), `fhCreateItem`, `fhDeleteItem`, `fhMoveItemAfter`/`fhMoveItemBefore`,
`fhSrcEnableAutoTitle`, and `fhGetFactTag`/`fhGetFlagTag` (including their
`bCreateIfNone=true` schema-creating path) — all at once; there is no further staging
within read-write. See docs/adr/0005-write-mode-errors-rethrown-for-fh-auto-undo.md for
how a write script's own runtime errors are handled.
_Avoid_: Permission level, mode (alone)

**Sandbox**:
The restricted Lua environment (`_ENV` table passed to `load()`) that a submitted script
runs inside. Built as an allowlist — only explicitly added globals are visible — rather
than starting from the real environment and stripping known-dangerous ones. `fhu`
(`require('fhUtils')`) is exposed as a proxy, never the raw FH-shipped module, so its
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
one — returning record counts per record type plus a distinct-tag census (INDI and FAM
child items, SOUR record child items, and Source template definitions), each tag paired
with its occurrence count. Recomputed on every call; see
docs/adr/0002-describe-project-no-server-cache.md for why it isn't cached. Always executes
in the Read-only sandbox regardless of the Session's own Access mode — its script is
fixed and known to never call a write function, so there's no reason to ever run it with
write capability available even during a read-write Session.
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
are unaffected by this tool's existence.
_Avoid_: Publish, upload (this project's own name for the operation is "install", matching
FH's own Tools -> Plugins terminology)

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
fields, Sentence templates. Each entry carries a confidence tag (Verified / Confirmed /
Documented / Likely) and a citation back to its source (an FH help page, or a specific line in
the family_historian_mobile project's tag-mapping specs) — entries inherited from that sibling
project describe its raw exported-GEDCOM-file findings, not FH's live API, so each is
cross-checked against FH's own help before being trusted here. Deliberately excludes anything
that only describes the exported-file wire format (e.g. `_LINK_*`/`_LKID` mechanics, the
`_PLAC`/`_ADDR` gazetteer, encoding options) since `run_lua`'s sandbox never reads or writes a
`.ged` file directly — see docs/adr/0003-gedcom-corpus-scope-live-api-only.md. `_SRCT` itself is
*not* one of these exclusions — it's also a live record-type tag (Source Template record),
reachable the same way as INDI/FAM/SOUR; see **Source template** below and the corpus's
"Creating a templated Source record" entry for how a Source record links to one and gets its
fields populated.
_Avoid_: FH help corpus (that's the separate, official-help-site-sourced one; see
`fh-help-corpus.jsonl`)

**FTF (Family Historian Text Format)**:
The rich-text markup FH stores internally in any multi-line text field (Notes, Source `TEXT`,
citation-level `DATA/TEXT`, etc.) — inline style commands (`<b>`, `<i>`, ...), tables, web/record/
citation links, and `[[private]]` spans. Distinct from eFTF (report-only superset) and tFTF
(the `SetText` plugin API's text-only variant).
_Avoid_: Rich text (alone, when FTF's specific markup grammar is meant)

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
Source record resolved the same by-id-or-by-title way `createSourceFromTemplate` resolves
a template. See docs/adr/0006-cite-every-fact-a-source-supports.md for why this exists as
a shared helper instead of each script hand-rolling `fhCreateItem("SOUR", ...)` +
`fhSetValueAsLink`.
_Avoid_: Add source, link source (this project's own name for the operation is
`citeSource`, matching the domain term "citation")

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
_Avoid_: Audit log, history (this project's own name for the operation is `logActivity`,
and FH's own term for the record type is "Research Note")
