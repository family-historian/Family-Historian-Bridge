# Bundle the Bridge plugin's sibling Lua modules into one file at build time

FH plugins are conventionally shipped as a single file, except for the handful that ship
with FH itself. `bridge/Claude MCP Bridge.fh_lua` doesn't follow that: it `require()`s eight
sibling modules (`jsonEncode.lua`, `requestFraming.lua`, `runScript.lua`, `sandbox.lua`,
`sessionLogHelper.lua`, `sourceHelper.lua`, `timeoutDisplay.lua`, `watchdog.lua`), and its
own header comment says all eight files have to be copied together into FH's Plugins folder
for `require()` to find them. A code review of the whole component (2026-08-01) flagged two
consequences of that split:

1. It's a real, if justified, deviation from FH's own single-file convention. The
   justification is genuine — `bridge/tests/*.test.lua` runs each module standalone with a
   plain `lua` interpreter, no FH dependency, which matters because FH itself can't run in
   CI — but the justification only covers the *source tree*, not what actually needs to
   ship.
2. `install_fh_plugin` (docs/adr/0008) writes exactly one file per call. As written, the
   Bridge plugin could never be installed through it — a latent incompatibility, not
   currently exercised by anything, but a trap for whenever installing the Bridge itself
   through the MCP server comes up.

## Decision

Keep the source split — the testing rationale above still holds, untouched — and add a
build step that produces a single, self-contained file for everything downstream of
"write source code": manual install, packaging (docs/release.md), and any future use of
`install_fh_plugin` against the Bridge itself.

`bridge/scripts/bundler.lua` (pure string logic, no file I/O) and `bridge/scripts/build.lua`
(the CLI, `lua bridge/scripts/build.lua`) inline each sibling module into the entry file as

```lua
package.preload["moduleName"] = function()
  <module source, verbatim>
end
```

right after `fhInitialise(...)` — which per FH's own docs must be the first function this
plugin calls, before even `require()`, so the splice point has to come after it. Every
`require("moduleName")` call already in the code, at any call site, keeps working
completely unmodified: Lua's `require` checks `package.preload` before ever touching the
filesystem, so `sandbox.lua`'s own `require('sourceHelper')` (called lazily, from inside a
function body, not at module load time) resolves correctly with no textual changes to
`sandbox.lua` itself. `require('fhUtils')` — FH's own shipped module, not one of ours — is
left alone entirely; only the eight names in `bundler.lua`'s `MODULE_NAMES` get a preload
entry. This is why `package.preload` was chosen over rewriting each `require(...)`
call site directly: it needed no call-site detection logic at all, so it's correct
regardless of whether a `require` is at module top level or buried in a function.

The build fails loudly rather than silently shipping something wrong: `bundler.lua` checks
for the entry file's exact Install-comment text and its `fhInitialise(...)` line before
splicing, and raises an error naming which anchor moved if either has drifted since the
bundler was last updated. `bridge/tests/build.test.lua` covers this, plus the shape of the
bundled output and that it parses as valid Lua.

`bridge/dist/Claude MCP Bridge.fh_lua` is the generated artifact (gitignored, like
`server/dist/`, and rebuilt with `lua bridge/scripts/build.lua`) — this is now the one
supported install path. Manually copying all eight source files into FH's Plugins folder
still works mechanically (nothing prevents it) but is no longer documented as a supported
route, to avoid two install paths silently drifting apart the way the header's own
file-list once drifted from `bridge/README.md`'s.

`build.lua` also prepends a UTF-8 BOM (`EF BB BF`) to the artifact — added after testing
live turned up that a build without one loads into FH as ANSI, even with the entry file's
own `fhSetStringEncoding("UTF-8")` call (added the same round): that call only sets the
*runtime* string encoding once the script is already running, and does nothing for how
FH's Plugin Editor/loader detects the file's on-disk encoding beforehand. Same BOM byte
sequence and rationale as `install_fh_plugin`'s (docs/adr/0008 decision 5) — Lua's own
loader skips a leading BOM transparently, so this has no effect on parsing.

## Out of scope

This ADR makes the artifact *structurally* compatible with `install_fh_plugin` — one file
— but does not wire the Bridge through it. `install_fh_plugin`'s trust model (ADR 0004,
ADR 0008) and its never-overwrite `<Title> V<N>.fh_lua` naming scheme are built for
Claude-authored plugins reviewed once in chat before installing, not a fixed,
security-sensitive, repo-shipped component meant to be updated in place under one
canonical filename. Routing the Bridge through it as-is would mean a fresh
`Claude MCP Bridge V1.fh_lua`, `V2.fh_lua`, ... on every install, rather than replacing the
running one. Whether and how to support installing/updating the Bridge itself via an MCP
tool is a separate decision, deliberately left open.

## Consequences

- Day-to-day module development and testing are unaffected — edit and test
  `bridge/*.lua` exactly as before; only building the shippable artifact changed.
- Release packaging (docs/release.md) now runs the bundler and ships the single
  `bridge/dist/Claude MCP Bridge.fh_lua` instead of listing all eight source files.
- `bundler.lua`'s anchor checks are deliberately brittle: any future edit to the entry
  file's Install comment or its `fhInitialise(...)` line must also update the matching
  constant in `bundler.lua`, or the build stops instead of shipping stale bundled text.
