# FH MCP Bridge — Build From Source

This is the path for **developers and contributors** — building the project from its own
source rather than installing a packaged release. If you just want to use the Bridge, see
[docs/install.md](install.md) instead: download the `.mcpb` and the Bridge plugin, no
building, no command line.

## Requirements

- Family Historian, installed and working (Windows natively, or via CrossOver on a Mac).
- [Claude Desktop](https://claude.ai/download).
- [Node.js](https://nodejs.org) (any current LTS release) — only needed to build the MCP
  server; nothing to install FH-side beyond copying one file.
- A Lua interpreter (5.3.x — matches FH's own embedded runtime; see
  `docs/release.md`'s "Risks" section for why the version, not just the presence, of `lua`
  on `PATH` matters) — only needed to build the Bridge plugin bundle.

## 1. Get the project files

Copy or clone this whole project folder onto the machine running FH.

## 2. Build the MCP server

In a terminal, from the project's `server` folder:

```bash
cd server
npm install
npm run build
```

This produces `server/dist/index.js`, the file Claude Desktop will run.

## 3. Build and install the Bridge plugin into FH

Build the single-file plugin (from the project's root folder):

```bash
lua bridge/scripts/build.lua
```

This produces `bridge/dist/Claude MCP Bridge.fh_lua`, a self-contained bundle of the plugin
and its supporting modules (see
[docs/adr/0009-bundle-bridge-plugin-for-install.md](adr/0009-bundle-bridge-plugin-for-install.md)).
Copy just that one file into FH's Plugins folder.

**Where FH's Plugins folder is:**
- Native Windows, **FH8**: `C:\ProgramData\Calico Pie\Family Historian 8\Plugins\`. Note the
  `8`. If you also have FH7 installed, it has its own `Family Historian\Plugins\` (no version
  number) sitting right next to this one, already populated with real plugins. It's easy to
  copy into by mistake, and FH won't tell you if you do.
- Mac via CrossOver: the equivalent path under CrossOver's virtual C: drive.

In FH: **Tools → Plugins → New**, open `Claude MCP Bridge.fh_lua` from that folder, click
**Run**. A small "Claude MCP Bridge" dialog appears. Leave it there; you'll use it every time
you want Claude to look at your tree.

## 4. Connect Claude Desktop to the server

Open (or create) Claude Desktop's MCP config file:

- Mac: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

Add an entry for the server, using the **absolute path** to the file built in step 2:

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

Restart Claude Desktop. You should now be able to ask it to use the `run_lua` tool (it'll
usually pick it up automatically when you ask a genealogy question). If you're using Claude
Code rather than Claude Desktop, a session started *before* the server was registered in its
config won't have `run_lua` in its tool list — start a fresh session (or restart Claude
Desktop) after adding the config, not before.

**Newer, unified/MSIX-packaged Claude Desktop builds don't read
`claude_desktop_config.json` at all**, so hand-editing it does nothing on those builds — this
is a known gap in the manual-config path specifically, not something you're doing wrong.
There's no supported workaround yet for that build; if you hit it, use
[docs/install.md](install.md)'s `.mcpb` path instead, which doesn't touch this file.

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

- [../bridge/README.md](../bridge/README.md): Bridge plugin internals and manual test steps.
- [../server/README.md](../server/README.md): MCP server internals, setup, and automated tests.
- [agents/domain.md](agents/domain.md) and
  [agents/issue-tracker.md](agents/issue-tracker.md): agent-facing notes on
  the domain docs and issue tracker for this repo.

## Next steps

- [docs/user-guide.md](user-guide.md) — day-to-day usage once both halves are installed.
- [docs/release.md](release.md) — cutting a packaged release.
- [docs/agents/manual-testing.md](agents/manual-testing.md) — testing changes against a live
  FH install.
- Running the automated test suites: see README.md's "Development" section.
