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

## Install

Download two files from the [latest release](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/releases)
— the `.mcpb` (install via Claude Desktop's own Settings → Extensions → Advanced Settings →
Install Extension) and `AI Assistant Connector.fh_lua` (load via FH's Tools → Plugins → New, or
just double-click it). No building, no command line.

Full walkthrough: **[docs/install.md](docs/install.md)**. Building from source instead
(contributors/developers): **[docs/build.md](docs/build.md)**.

## Using it

Open the FH project, click **Start** in the "AI Assistant Connector" dialog, then ask Claude a
genealogy question in plain English. See
[docs/user-guide.md](docs/user-guide.md#using-it) for the full walkthrough, and
[docs/user-guide.md#getting-a-standalone-plugin-written-for-you](docs/user-guide.md#getting-a-standalone-plugin-written-for-you)
for asking Claude to write you a standalone plugin instead (no Bridge Session needed).

## Privacy Policy

FH MCP Bridge collects nothing itself — no accounts, no telemetry, no analytics, and
nothing is sold, shared, or transmitted to Anthropic, to us, or to any third party as part
of running the software. Full details (data usage, storage, third-party sharing,
retention, contact): see [privacy.md](privacy.md).

## License

MIT — see [LICENSE](LICENSE).

Developer docs, including running the test suites: **[docs/build.md](docs/build.md)**.
