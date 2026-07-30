# FH MCP Bridge

An MCP server, installable alongside Family Historian (FH), that lets Claude query and
edit a user's open FH project by sending Lua scripts to a companion FH plugin over a
local TCP socket.

## Language

**Bridge plugin**:
The Lua plugin (`bridge_prototype_v2.fh_lua`) that runs inside FH itself, opens the local
TCP listener, and executes scripts sent to it.
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
FH's read API inside the sandbox; read-write additionally exposes FH's write API
(`fhCreateItem`, `fhSetValueAsText`, etc.).
_Avoid_: Permission level, mode (alone)

**Sandbox**:
The restricted Lua environment (`_ENV` table passed to `load()`) that a submitted script
runs inside. Built as an allowlist — only explicitly added globals are visible — rather
than starting from the real environment and stripping known-dangerous ones.
_Avoid_: Denylist, restricted mode

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
docs/adr/0002-describe-project-no-server-cache.md for why it isn't cached.
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
that only describes the exported-file wire format (e.g. `_SRCT`/`_LINK_*`/`_LKID` mechanics, the
`_PLAC`/`_ADDR` gazetteer, encoding options) since `run_lua`'s sandbox never reads or writes a
`.ged` file directly — see docs/adr/0003-gedcom-corpus-scope-live-api-only.md.
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
