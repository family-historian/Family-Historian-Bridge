# FH MCP Bridge

An MCP server, installable alongside Family Historian (FH), that lets Claude query a
user's own open FH project directly — no GEDCOM export, no separate app — by sending Lua
scripts to a companion FH plugin over a local TCP socket.

## Aims

- Let Claude answer natural-language genealogy questions grounded in the user's actual,
  currently open FH data ("who died between 1914 and 1918 in France or Belgium", "how many
  Munros are in the tree", "who are so-and-so's grandparents", "write a narrative report
  for this person with sources").
- Keep everything local: both halves talk to each other on `127.0.0.1` only. The one
  deliberate exception is an explicit, user-triggered check for an updated copy of FH8's
  bundled help content from family-historian.co.uk.
- Stage 1 (current): **read-only**. Claude can look up, count, cross-reference, and
  narrate — it cannot create, edit, or delete anything in the user's tree yet.
- Run every query as a fresh, purpose-written Lua script against FH's own API rather than
  a fixed set of canned queries, so it can answer whatever's actually asked.

See [CONTEXT.md](CONTEXT.md) for the project's glossary and terminology, and
[docs/adr/0001-arbitrary-sandboxed-lua-execution.md](docs/adr/0001-arbitrary-sandboxed-lua-execution.md)
for the design decision behind running arbitrary sandboxed Lua rather than a fixed command
set.

## How it works

Two pieces, both running on the user's own machine:

- **Bridge plugin** (`bridge/`) — a Lua plugin that runs inside FH itself, with Start/Stop
  buttons. It opens a local TCP listener and executes submitted scripts inside a
  restricted, allowlist-only sandbox (FH's read API only — no filesystem or network
  access).
- **MCP server** (`server/`) — runs alongside Claude Desktop, exposes the `run_lua` tool,
  and forwards Claude's scripts to the Bridge over that socket.

A user starts a **Session** in FH (clicking Start in the Bridge's dialog) before asking
Claude anything; FH's main window is locked for the session's duration, and released the
moment they click Stop (or after 5 minutes idle).

## Install (clean machine)

Full walkthrough, troubleshooting, and day-to-day usage: **[docs/user-guide.md](docs/user-guide.md)**.

Short version:

1. **Get the project files** — copy or clone this whole folder onto the machine running FH.
2. **Build the MCP server**:
   ```bash
   cd server
   npm install
   npm run build
   ```
   This produces `server/dist/index.js`.
3. **Install the Bridge plugin into FH** — copy `bridge.fh_lua`, `jsonEncode.lua`,
   `sandbox.lua`, `runScript.lua`, and `watchdog.lua` (all five, together) from `bridge/`
   into FH's Plugins folder:
   - Native Windows: `C:\ProgramData\Calico Pie\Family Historian\Plugins\`
   - Mac via CrossOver: the equivalent path under CrossOver's virtual C: drive.

   Then in FH: **Tools -> Plugins -> New**, open `bridge.fh_lua` from that folder, click
   **Run**.
4. **Connect Claude Desktop** — add an entry to Claude Desktop's MCP config
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
Desktop](https://claude.ai/download), and [Node.js](https://nodejs.org) (any current LTS —
only needed to build the server once).

## Using it

Open the FH project, click **Start** in the "FH Bridge" dialog, then ask Claude a
genealogy question in plain English. See
[docs/user-guide.md](docs/user-guide.md#using-it) for the full walkthrough.

## Development

- [bridge/README.md](bridge/README.md) — Bridge plugin internals and manual test steps.
- [server/README.md](server/README.md) — MCP server internals, setup, and automated tests.
- [docs/agents/domain.md](docs/agents/domain.md) and
  [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md) — agent-facing notes on
  the domain docs and issue tracker for this repo.
