---
status: accepted
---

# Arbitrary sandboxed Lua execution instead of a fixed command protocol

The bridge plugin needs to answer an open-ended, growing set of natural-language
questions (e.g. "list people who died 1914–1918 in France or Belgium", "count unsourced
Facts on direct ancestors of X") without redesigning the wire protocol every time a new
kind of question comes up. We considered a fixed set of typed commands (e.g.
`QUERY_PEOPLE_BY_DEATH_DATE_PLACE`) that the MCP server would call with parameters, but
rejected it: it would need a new command (and a matching Lua implementation) for every
distinct question shape, and Stage 1's two example queries alone need materially
different traversal logic (linear scan+filter vs. ancestor-graph walk).

Instead, the MCP server exposes a single tool, `run_lua(script)`: Claude authors a fresh
Lua script per question and the bridge executes it directly inside FH's process via
`load()`. This trades a priori bounded safety (a fixed command set can only ever do what
was explicitly implemented) for flexibility (any query FH's Lua API can answer is
reachable without a protocol change) — accepted because the code executes with the same
trust level as any plugin the user would run themselves, and because the resulting risks
(unsandboxed stdlib access, runaway scripts) are separately mitigated by an allowlist
`_ENV` sandbox and an execution-instruction watchdog, rather than by constraining what a
script is allowed to *ask for* in the first place.

## Consequences

- Adding a new kind of question is a prompting concern (Claude writes different Lua), not
  a protocol or bridge-code change — the whole point of this ADR.
- The sandbox (allowlist `_ENV`) and watchdog (`debug.sethook` instruction limit) are load-
  bearing safety mechanisms, not optional hardening — removing either reopens the risk
  this ADR explicitly accepted in exchange for flexibility.
- Read-only vs read-write access is enforced per-session (at Start) by what's in the
  allowlist, not per-script — a script cannot request elevated access mid-session.
