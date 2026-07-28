# MCP server

The Claude-facing half of the bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `src/bridgeClient.ts` — the socket client: frames a request as `LUA <n>\n` + script
  bytes, reads the response until the Bridge closes the connection.
- `src/runLuaTool.ts` — the `run_lua` MCP tool: translates a Bridge response (or a
  connection failure) into a tool result Claude can act on.
- `src/index.ts` — entry point; registers the tool and connects over stdio.

## Setup

```bash
npm install
npm run build
```

## Testing

```bash
npm run typecheck
npm test
```

`bridgeClient.test.ts` and `runLuaTool.test.ts` are fully automated — no FH dependency.
`bridgeClient`'s tests use a fake TCP server that speaks the same `STOP`/`LUA <n>` framing
as the real Bridge (see the spec's Testing Decisions); `runLuaTool`'s tests inject a fake
`runLuaOnBridge` function directly.

## Manual end-to-end check

Requires a real FH Bridge Session running (see `bridge/README.md`):

```bash
npm run build
node scripts/smoke-test.mjs
```

Spawns the built server and calls `run_lua` through a real MCP client, the same way
Claude Desktop would.

## Connecting from Claude Desktop

Add to Claude Desktop's MCP server config:

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
