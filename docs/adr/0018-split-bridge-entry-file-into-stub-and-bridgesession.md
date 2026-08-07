# Split the Bridge plugin's entry file into a stub plus `bridgeSession.lua`, for Serena coverage

Issue #75: Serena's installed Lua language server integration (`solidlsp/language_servers/lua_ls.py`,
v1.6.2.dev0) has no `file_filter` hook — unlike `perl_language_server.py`/`intelephense.py`, which both
support one — so it can't be taught to treat `.fh_lua` as Lua. `.lua` files get full symbol-tool
coverage (`find_symbol`, `find_referencing_symbols`, etc.) once the `lua` language server is active;
`.fh_lua` files fall back to grep/Read, same as before.

Unlike the 8 sibling modules ADR 0009 already split out of `bridge/Claude MCP Bridge.fh_lua`, the entry
file itself wasn't just boilerplate: it held 359 lines of real logic — the IUP dialog, the socket poll
loop, request-framing dispatch, Start/Stop handlers, the whole Session lifecycle — all invisible to
Serena. It's also the repo's *only* source `.fh_lua` file (`bridge/dist/Claude MCP Bridge.fh_lua` is a
gitignored build artifact, not source), so this is a one-off fix, not a pattern needed elsewhere in the
repo.

## Decision

Move everything after `fhSetStringEncoding("UTF-8")` out of the entry file into a new
`bridge/bridgeSession.lua` — named for what it owns (the dialog UI and the Session's lifecycle, matching
`CONTEXT.md`'s **Session** term), not a generic "main"/"core" name. `bundler.lua`'s `MODULE_NAMES` gains
`"bridgeSession"`, using the exact `package.preload` splice mechanism ADR 0009 already established — no
new bundling logic needed.

`bridge/Claude MCP Bridge.fh_lua` becomes, in full:

```lua
--[[ ...@Title/@Type/... header, unchanged... ]]

fhInitialise(7, 0, 0, "save_required")
fhSetStringEncoding("UTF-8")
require("bridgeSession")
```

### Why not a one-line stub

FH's own help docs are explicit that `fhSetStringEncoding` "should never be used by modules (scripts
that provide functions designed to be called by other scripts)" — confirmed via `fh-help-corpus.jsonl`,
not just inferred from the existing code comment. It must stay a direct call in the entry file, before
any `require()`. `fhInitialise`'s own doc wording is softer ("it should be the first function called in
the plugin") and doesn't explicitly forbid a `require()` running first, but there's no reason to test
that boundary: the stub is invisible to Serena regardless of whether it's 1 line or 3, so the 3-line form
is kept and both FH-documented ordering constraints stay satisfied with no ambiguity.

### Different rationale from ADR 0009

0009's split bought standalone unit-testability outside FH (`bridge/tests/*.test.lua` runs each sibling
module with a plain `lua` interpreter, no FH dependency). This split can't offer that — `bridgeSession.lua`
still needs `iup`, `luasocket`, and FH's own globals (`fhGetContextInfo`, `fhUpdateDisplay`, etc.)
regardless of which file it lives in. The only benefit here is Serena/symbol-tool coverage. Recorded as
its own ADR rather than folded into 0009 because the rationale genuinely differs — a future reader
shouldn't have to infer "coverage, not testability" from 0009's testability-focused text.

### `BRIDGE_VERSION` needs no bundler change

`bundler.lua`'s `buildBundle` injects `local BRIDGE_VERSION = <version>` immediately after the
`fhInitialise(...)` line, textually *before* every `package.preload[name] = function() ... end` block it
generates — including the new `bridgeSession` one. FH only ever loads `bridge/dist/Claude MCP Bridge.fh_lua`
(the bundled artifact); the raw split source is never executed by FH, only read/edited and (for the other
8 modules) unit-tested standalone. Lua closures capture enclosing locals lexically regardless of when
they're invoked later, so `bridgeSession`'s `package.preload` closure resolves `BRIDGE_VERSION` correctly
as an upvalue with no change to the injection itself. This is a genuinely new use of the mechanism though
— none of ADR 0009's modules referenced an outer local from the bundled chunk — so add a dedicated case to
`bridge/tests/build.test.lua` asserting it resolves correctly, rather than relying on reasoning alone.

### Considered and rejected

- **File a `file_filter`-support feature request against `oraios/serena`.** Would be the fully general
  fix (benefits any FH-plugin project keeping logic directly in a `.fh_lua` entry file), and the research
  is already done (comparing `lua_ls.py` against `perl_language_server.py`/`intelephense.py`). Rejected
  for now: this repo's own gap is closed by this ADR's split, so the request wouldn't change anything
  locally, and nobody's picked up the cost of filing/maintaining it upstream.
- **Patch/fork the installed `lua_ls.py` locally.** Rejected in the original issue #75 write-up —
  needs reapplying on every Serena upgrade, for a gap this ADR closes structurally instead.

## Consequences

- `bridge/README.md`'s list of files to copy for a manual (unbundled) install needs `bridgeSession.lua`
  added, alongside the existing 9 (the original 8 from ADR 0009 plus `versionCompare`/`familyHelper`,
  added since).
- Day-to-day editing of the dialog/socket/Session logic now happens in `bridge/bridgeSession.lua`, not
  the `.fh_lua` entry file — Serena's symbol tools cover it like any other `bridge/*.lua` module.
- The entry file stays the single place FH-mandated ordering (`fhInitialise` before `fhSetStringEncoding`
  before any `require()`) is enforced; nothing about that ordering is negotiable regardless of future
  refactors here.
