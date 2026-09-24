# Domain naming — product/component names

Three distinct names, deliberately kept apart — don't use interchangeably:
- **Bridge plugin**: the Lua plugin running inside FH (entry: `bridge/AI Assistant Connector.fh_lua`
  stub → `bridge/bridgeSession.lua`). Avoid "Plugin" alone or "server" (reserve "server" for
  the MCP server).
- **Family Historian Bridge**: user-facing product name (Claude Desktop extension list,
  Windows Start Menu entry).
- **FH MCP Bridge**: this repo/package's own dev-facing name (also Windows installer's
  `DefaultDirName`, kept stable for in-place upgrades).

The Bridge plugin's own FH-dialog `@Title` is "AI Assistant Connector" — a fourth, narrower
label, not to be confused with any of the above three.
