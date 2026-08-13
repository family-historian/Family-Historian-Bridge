# Manual testing against a live FH install

Only `bridge/*.lua` changes ever need live exercising — the MCP server (`server/`) is
already reachable through whatever `fh-mcp-bridge` MCP connection this session has, and
rebuilding it doesn't require anything from the user.

After `lua bridge/scripts/build.lua` produces a fresh `bridge/dist/Claude MCP Bridge.fh_lua`:

- **Ask the user to load it, then stop and wait.** Don't go looking for FH's Plugins
  folder, a CrossOver bottle, or a running Bridge socket (127.0.0.1:8734) to figure out
  install state yourself — FH may not even be running on this machine, and only the user
  knows where their real install lives and what state it's in. Say the file's ready and
  ask them to copy it in, reload the plugin (Tools -> Plugins -> reopen the file — FH
  doesn't hot-reload an already-open plugin off a changed file), and click Start.
- Once they confirm it's loaded and Started, drive `run_lua`/`describe_project`/etc.
  directly — the MCP tools already point at this checkout's `server/dist/index.js` (see
  root `.mcp.json`), so no further setup is needed on that side.
