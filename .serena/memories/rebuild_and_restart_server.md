# Rebuilding and restarting the server + bridge

## When this is needed
- Any change under `server/src/*.ts` -> needs `npm run build` (tsc) AND a server restart
  (the compiled `dist/index.js` is what actually runs; a live process keeps running its
  OLD compiled code until restarted).
- Any change to `server/data/*.jsonl` (gedcom-knowledge-corpus.jsonl, fh-help-corpus.jsonl)
  -> no `npm run build` needed (read raw at runtime via `readFileSync`, not compiled) but
  STILL needs a server restart: `server/src/index.ts` loads these once into a module-level
  store at process startup, not per-call -- a running process keeps serving the OLD corpus
  content until restarted, even though nothing needs recompiling.
- Any change under `bridge/*.lua` -> needs `lua bridge/scripts/build.lua` (from repo root)
  to refresh `bridge/dist/Claude MCP Bridge.fh_lua`. This does NOT need a server
  restart -- the bridge runs inside Family Historian's own separate Lua process, not
  this server.

## Commands
```bash
# Server (from server/): only if server/src/*.ts changed
cd server && npm run build

# Bridge (from repo root): only if bridge/*.lua changed
lua bridge/scripts/build.lua
```

## Restarting the running server process
The MCP server (`server/dist/index.js`) runs as a child process of the omp harness itself
(`ppid` = the `omp` process), spawned over stdio -- it is NOT managed by `hub`
(`hub ps` will not show it). Find and kill it directly; the harness auto-respawns it
within about a second, picking up the freshly built `dist/index.js` and re-reading
`server/data/*.jsonl` fresh on the new process's startup. Confirmed live, twice, in the
same session (issue #113 verification): the harness reliably respawns without needing to
restart the omp session/client itself.

```bash
# Find it
ps aux | grep "server/dist/index.js" | grep -v grep

# Kill it (graceful) -- harness respawns automatically
kill -TERM <pid>

# Confirm the new pid came up (~1s later)
ps aux | grep "server/dist/index.js" | grep -v grep
```

Verify the new process is actually live and reachable (not just running) by calling a
cheap read-only fh-mcp-bridge tool, e.g. `describe_project` -- getting back its real
"No FH Bridge Session is running" error (not a connection/crash error) proves the new
process is up and correctly wired, even with no FH project open yet.

## Full sequence after changing both server and bridge code
```bash
cd server && npm run build
cd .. && lua bridge/scripts/build.lua
ps aux | grep "server/dist/index.js" | grep -v grep   # note the pid
kill -TERM <pid>
sleep 1
ps aux | grep "server/dist/index.js" | grep -v grep   # confirm new pid
```

## What this does NOT do
- Does not install `bridge/dist/Claude MCP Bridge.fh_lua` into FH's Plugins folder --
  that file is gitignored (build artifact, never committed) and, per project convention
  (`mem:task_completion`, `bridge/README.md`), this project never copies into the user's
  Plugins folder or touches their CrossOver bottle. The user installs/reloads it in FH
  themselves (Tools -> Plugins) before a bridge-side code change is actually live in
  their running FH instance -- rebuilding the bundle and restarting the server does not
  make a bridge code change live by itself.
