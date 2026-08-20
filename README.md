# FH MCP Bridge

<img src="docs/fh_bridge_logo_small.png" alt="FH Bridge logo" width="150">

An MCP server, installable alongside Family Historian (FH), that lets Claude query a
user's own open FH project directly by sending Lua scripts to a companion FH plugin over a
local TCP socket. No GEDCOM export, no separate app.

## Aims

- Let Claude answer natural-language genealogy questions grounded in the user's actual,
  currently open FH data ("who died between 1914 and 1918 in France or Belgium", "how many
  Munros are in the tree", "who are so-and-so's grandparents").
- Let Claude write the user a complete, standalone FH Report or Query plugin to install
  and run themselves. This is a separate, human-reviewed path that isn't bound by the Bridge
  Session's Access mode, since the user runs it under FH's own permission model, not the
  Bridge's. On the user's explicit say-so, Claude can also write it straight into FH's
  Plugins folder for them (`install_fh_plugin`), rather than them saving it by hand.
- Keep everything local: both halves talk to each other on `127.0.0.1` only. The one
  deliberate exception is an explicit, user-triggered check for an updated copy of FH8's
  bundled help content from family-historian.co.uk.
- **Access mode**, chosen once at Session Start. **Read-only** (default): Claude can
  look up, count, cross-reference, and narrate. **Read-write** additionally lets Claude
  create, edit, and delete records in the user's tree, via the same `run_lua` tool.
  `describe_project`'s fixed census script always runs Read-only regardless of the
  Session's mode.
- Run every query as a fresh, purpose-written Lua script against FH's own API rather than
  a fixed set of canned queries, so it can answer whatever's actually asked.

See [CONTEXT.md](CONTEXT.md) for the project's glossary and terminology, and
[docs/adr/0001-arbitrary-sandboxed-lua-execution.md](docs/adr/0001-arbitrary-sandboxed-lua-execution.md)
for the design decision behind running arbitrary sandboxed Lua rather than a fixed command
set.

## How it works

Two pieces, both running on the user's own machine:

- **Bridge plugin** (`bridge/`): a Lua plugin that runs inside FH itself, with Start/Stop
  buttons. It opens a local TCP listener and executes submitted scripts inside a
  restricted, allowlist-only sandbox (FH's read API only, no filesystem or network
  access).
- **MCP server** (`server/`): runs alongside Claude Desktop, exposes the `run_lua` tool,
  and forwards Claude's scripts to the Bridge over that socket.

A user starts a **Session** in FH (clicking Start in the Bridge's dialog) before asking
Claude anything; FH's main window is locked for the session's duration, and released the
moment they click Stop (or after 5 minutes idle).

## Install (clean machine)

Full walkthrough, troubleshooting, and day-to-day usage: **[docs/user-guide.md](docs/user-guide.md)**.

**Windows end user, installer in hand?** If you were given a `FH-MCP-Bridge-Setup-X.Y.Z.exe`
file rather than this project's source, skip the build steps below and use
**[docs/windows-installer-guide.md](docs/windows-installer-guide.md)** instead. It needs
no Node.js and no command line.

Short version (building from source):

1. **Get the project files**: copy or clone this whole folder onto the machine running FH.
2. **Build the MCP server**:
   ```bash
   cd server
   npm install
   npm run build
   ```
   This produces `server/dist/index.js`.
3. **Install the Bridge plugin into FH**: build the single-file plugin, then copy just
   that one file:
   ```bash
   lua bridge/scripts/build.lua
   ```
   This produces `bridge/dist/Claude MCP Bridge.fh_lua`, a self-contained bundle of the
   plugin and its supporting modules (see
   [docs/adr/0009-bundle-bridge-plugin-for-install.md](docs/adr/0009-bundle-bridge-plugin-for-install.md)).
   Copy that one file into FH's Plugins folder:
   - Native Windows, FH8: `C:\ProgramData\Calico Pie\Family Historian 8\Plugins\`.
     Note the `8`. A same-machine FH7 install has its own `Family Historian\Plugins\`
     (no version number) sitting right next to it, already populated with real plugins,
     and it's easy to copy into the wrong one (confirmed on a beta install).
   - Mac via CrossOver: the equivalent path under CrossOver's virtual C: drive.

   Then in FH: **Tools -> Plugins -> New**, open `Claude MCP Bridge.fh_lua` from that folder, click
   **Run**.
4. **Connect Claude Desktop**: add an entry to Claude Desktop's MCP config
   (`~/Library/Application Support/Claude/claude_desktop_config.json` on Mac,
   `%APPDATA%\Claude\claude_desktop_config.json` on Windows):
   ```json
   {
     "mcpServers": {
       "fh-mcp-bridge": {
         "command": "node",
         "args": ["/absolute/path/to/server/dist/index.js"]
       }
     }
   }
   ```
   Restart Claude Desktop.

**Requirements:** Family Historian (Windows native, or via CrossOver on Mac), [Claude
Desktop](https://claude.ai/download), and [Node.js](https://nodejs.org) (any current LTS;
only needed to build the server once).

## Using it

Open the FH project, click **Start** in the "Claude MCP Bridge" dialog, then ask Claude a
genealogy question in plain English. See
[docs/user-guide.md](docs/user-guide.md#using-it) for the full walkthrough, and
[docs/user-guide.md#getting-a-standalone-plugin-written-for-you](docs/user-guide.md#getting-a-standalone-plugin-written-for-you)
for asking Claude to write you a standalone plugin instead (no Bridge Session needed).

## Privacy Policy

**Data collection:** FH MCP Bridge collects nothing itself. It has no accounts, no
telemetry, and no analytics. It doesn't sell, share, or transmit your genealogy data to
Anthropic, to us, or to any third party as part of running the software.

**Data usage:** Both halves of the Bridge (the FH plugin and the MCP server) talk to each
other only over `127.0.0.1` (localhost) — nothing leaves your machine over that channel.
When you ask Claude a question during a Bridge Session, the `run_lua` and
`describe_project` tools return records from your open FH project (names, dates, places,
relationships, etc.) to Claude Desktop so it can answer you. That exchange is then subject
to Anthropic's own [Privacy Policy](https://www.anthropic.com/legal/privacy) and
[Consumer Terms](https://www.anthropic.com/legal/consumer-terms) for whatever Claude
surface you're using it with, the same as any other prompt or tool result in your
conversation — the Bridge itself has no visibility into how Claude Desktop or Anthropic
subsequently handle that content.

The one other network call this software makes is `check_fh_help_updates`: an explicit,
user-triggered fetch of FH8's own bundled help content from family-historian.co.uk. That
request carries no genealogy data or other personal information — it just downloads
reference documentation.

**Data storage:** No genealogy data is written to disk by this software beyond FH's own
project file, which you already control. `check_fh_help_updates` caches the downloaded
help/reference corpus locally so it doesn't have to re-fetch it every time; that cache
holds FH's public documentation, not your data. `install_fh_plugin` writes a plugin file
only when you explicitly ask Claude to install one, and only into FH's own Plugins folder.

**Third-party sharing:** None, beyond the Claude Desktop / Anthropic exchange described
above (inherent to using an MCP tool with Claude at all) and the explicit,
user-triggered help-content fetch from family-historian.co.uk.

**Retention:** Nothing is retained by us, because nothing is collected by us. Locally
cached help content and any plugin files you asked Claude to write stay on your machine
under your control until you delete them yourself.

**Contact:** [fhmcp@rjt.org.uk](mailto:fhmcp@rjt.org.uk)

## License

MIT — see [LICENSE](LICENSE).

## Development

Run every test suite (server via vitest, bridge via Lua, installer via `node --test`) with
one command from the repo root:

```bash
npm test
```

There's no CI on this repo, deliberately (see issue #90). After cloning, enable the
pre-push hook that runs the suites for you instead:

```bash
npm run setup:hooks
```

That points `core.hooksPath` at the committed `.githooks/` directory (a one-time,
per-clone step; `.git/hooks/` isn't version controlled). The hook takes under two seconds;
`git push --no-verify` skips it when you really mean to.

- [bridge/README.md](bridge/README.md): Bridge plugin internals and manual test steps.
- [server/README.md](server/README.md): MCP server internals, setup, and automated tests.
- [docs/agents/domain.md](docs/agents/domain.md) and
  [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md): agent-facing notes on
  the domain docs and issue tracker for this repo.
