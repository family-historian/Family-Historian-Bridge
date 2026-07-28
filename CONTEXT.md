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
