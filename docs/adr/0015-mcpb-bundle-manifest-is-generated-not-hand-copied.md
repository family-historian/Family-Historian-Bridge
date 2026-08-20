# The .mcpb bundle's manifest.json is generated at build time, not a hand-copied file

Issue #59 (part of the wayfinder map at issue #56; the new unified/MSIX Claude Desktop
build no longer honors `claude_desktop_config.json`, so app-wide install now needs a
Claude Desktop Extension) asked for a working `.mcpb`/`.dxt` package for `fh-mcp-bridge`'s
server: `manifest.json` plus bundled server + runtime, verified to actually install and
register the MCP server. Issue #58's research
(`docs/research/claude-app-variant-and-dxt-install-trigger.md`) had already confirmed the
mechanism (double-click/shellexec opens Claude Desktop's own install UI, same OS-level
shape as this repo's existing `.fh_lua` shellexec) but left the packaging itself open.

## Decisions

**No bundled Node runtime for this path, unlike the Setup.exe installer.** The Windows
Setup.exe installer (`installer/fh-mcp-bridge.iss`, `installer/stage.ps1`) bundles a
portable `node.exe` because it assumes the target machine has no Node preinstalled and
`claude_desktop_config.json`'s `command` field has to point at a real executable. A `.mcpb`
is different: Anthropic's own MCPB docs state Node.js "ships with Claude Desktop on macOS
and Windows" for a `"type": "node"` server, so the manifest's `mcp_config.command: "node"`
resolves against Claude Desktop's own bundled Node. Nothing in this bundle needs to ship
a `node.exe` of its own. This is a real difference between the two install paths, not an
oversight; the eventual installer work (the wayfinder map's Ticket C) branches on exactly
this axis (per issue #58's Squirrel-vs-MSIX findings) to decide which of the two payloads
to build.

**`node_modules` is staged production-only before packing, not left to `mcpb pack`.**
Anthropic's own MCPB bundling guidance is explicit: run `npm install --production` (or
`npm ci --omit=dev`) to create `node_modules`, then bundle the whole directory. `mcpb
pack` itself does not install dependencies, it only zips what's already on disk (its
default exclusions cover dev cruft like `node_modules/.cache`, not `node_modules` itself).
`installer/build-dxt.mjs` mirrors `installer/stage.ps1`'s identical reasoning for the
Setup.exe installer's own server copy: a fresh `npm ci --omit=dev` into the staging
copy keeps devDependencies (`typescript`, `vitest`, `@types/node`) out of the shipped
bundle, and never touches the developer's own `server/node_modules` (used for `npm test`).

**`manifest.json` is generated at build time from `server/package.json`'s version, not a
second hand-maintained copy.** `docs/release.md` step 4 already tracks three
independent, hand-bumped copies of the version string (the Bridge's `@Version` header,
`server/package.json`, `server/package-lock.json`) and documents, in its own Risks
section, that a *fourth* copy (`installer/fh-mcp-bridge.iss`'s `AppVersion`) silently drifted
out of sync before `installer/stage.ps1` started generating it at build time instead.
Adding a static, checked-in `manifest.json` with its own `"version"` field would repeat
that exact mistake a fifth time. Instead, `installer/dxt/manifest.mjs` exports a pure
`buildManifest({ version })` function. It takes no file I/O, so it can be unit-tested directly
(`manifest.test.mjs`), and `installer/build-dxt.mjs` calls it with the version read live
from `server/package.json`, writing the result into the staging directory just before
packing. This is the same "single source of truth, generated not copied" shape as
`server/src/serverVersion.ts` (issue #44) and `installer/stage.ps1`'s `version.iss`
generation.

**No `user_config`.** `server/src/index.ts` takes no environment variables or CLI
arguments; every request goes through the single `run_lua` tool rather than build-time
configuration. So the manifest declares no `user_config` section. Revisit if the server
ever gains a genuine install-time setting.

**Tool list is generated from `server/src/toolNames.json`.** *(Superseded 2026-08-10 by
issue #85; the original decision is kept below, since the reasoning that made it wrong is
the point.)*

Originally the manifest's `tools` field (shown in Claude Desktop's install UI) listed all
eight tools by hand in `manifest.mjs`, "cross-checked by `manifest.test.mjs` against that
same fixed list". This was accepted as a small drift risk since the tool set changes rarely, and
introspecting `index.ts`'s registrations at build time looked like it would need a real
TypeScript AST walk for a UI-only field.

Two things were wrong with that. First, the cross-check was circular: `manifest.test.mjs`
compared `buildManifest()`'s output to a literal array declared inside the test file, so it
could only ever confirm that two hand-written lists in the installer agreed with each
other, never that either matched the server. The test was nonetheless *named* "buildManifest
lists every tool server/src/index.ts currently registers, and no others", which is worse
than no test at all, because it reads like coverage during review. Second, there were by
then four copies, not two: the `register*Tool` call sites, `manifest.mjs`,
`manifest.test.mjs`, and `verify-dxt.mjs` (whose own comment called itself "a third copy of
the same acknowledged drift").

Now: `server/src/toolNames.json` holds the names (plus the one-line blurbs the manifest
needs), and all three consumers read it. `manifest.mjs` generates its `tools` array from
it, `manifest.test.mjs` asserts against it, `verify-dxt.mjs` compares a packed bundle's real
`tools/list` to it. JSON rather than TypeScript so the installer's plain-Node scripts can
read it with no build step and no dependency on the gitignored `server/dist`.

The AST walk turned out to be unnecessary. `server/src/toolNames.test.ts` stands up a real
`McpServer`, registers every tool the way `index.ts` does, connects a real MCP client over
`InMemoryTransport`, and asserts the served `tools/list` is exactly the JSON's list. The
server is asked what it registers rather than parsed for it. That is the check the old test
claimed to be.

**Verification splits into an automatable half and a hands-on half.** `installer/verify-
dxt.mjs` extracts the packed `.mcpb` (it's just a zip, `unzip` on macOS/Linux, and
explicitly Windows' own `System32\tar.exe`/bsdtar rather than a bare `tar`, since a dev
shell's PATH can put GNU tar first and GNU tar can't read zip archives at all), then
spawns the manifest's own `server.mcp_config.command`/`args` (substituting `${__dirname}`
the same way Claude Desktop would) and connects a real MCP client over stdio to confirm
`tools/list` returns exactly the tools `server/src/toolNames.json` declares. This proves the bundle's *contents*
are correct and the server starts and speaks MCP under its own bundled dependencies, all
without a live FH instance (same "no live FH needed" boundary
`server/scripts/smoke-test.mjs` already documents for its own checks), but it cannot, and
doesn't try to, drive Claude Desktop's actual Settings → Extensions install UI or a real
double-click. That hands-on confirmation is issue #59's own `wayfinder:prototype` (HITL)
step, left to whoever runs this end to end on a real machine.

The MCP client used by `verify-dxt.mjs` is not `@modelcontextprotocol/sdk` imported from
this repo's own `server/node_modules`. It's dynamically resolved from the *extracted
bundle's own* `server/node_modules` (a tiny runner script is written into the extraction
directory itself so the bare `@modelcontextprotocol/sdk` import naturally resolves there).
This both avoids adding `installer/` as a new npm package just for one dev script, and
means the check exercises the actual bundled dependency copy, not this repo's separate dev
copy.

## Consequences

- `installer/dxt/manifest.mjs` is the only place the manifest's shape lives; changing a
  declared tool, description, or `compatibility` entry means editing it there, not a
  generated `manifest.json` (which is gitignored, like `installer/staging/` and
  `installer/output/`).
- `installer/build-dxt.mjs` (`node installer/build-dxt.mjs --verify`) is cross-platform
  Node, not a `.ps1`/`.sh` split like `installer/stage.ps1`/`installer/release-mac.sh`.
  This is deliberate, since nothing about staging a `.mcpb` is platform-specific the way bundling
  a portable Windows `node.exe` is.
- This ADR only covers producing and headlessly verifying a working `.mcpb` (issue #59).
  Wiring it into the real installer (detecting Squirrel vs. MSIX Claude Desktop and
  branching between `config-merge.ps1` and a `.mcpb` handoff) is the wayfinder map's
  separate Ticket C, deliberately out of scope here.
