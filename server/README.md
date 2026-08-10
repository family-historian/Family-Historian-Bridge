# MCP server

The Claude-facing half of the bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `src/bridgeClient.ts` — the socket client: frames a request as `LUA <n>\n` + script
  bytes (or `LUA_RO <n>\n` to force the Bridge's Read-only sandbox regardless of the
  Session's Access mode — see `forceReadOnly`, used by `describeProjectTool.ts`), reads
  the response until the Bridge closes the connection.
- `src/runLuaTool.ts` — the `run_lua` MCP tool: translates a Bridge response (or a
  connection failure) into a tool result Claude can act on.
- `src/fhHelp.ts` — the bundled FH8 help corpus: `search_fh_help` tool and one MCP
  Resource per help topic, served from `data/fh-help-corpus.jsonl`.
- `src/fhHelpUpdate.ts` — `check_fh_help_updates`, the one tool that reaches the network:
  fetches a fresh corpus from family-historian.co.uk if one exists, explicit-trigger only.
- `src/index.ts` — entry point; registers the tools/resources and connects over stdio.
- `data/fh-help-corpus.jsonl` — bundled copy of the FH8 help corpus (built by the sibling
  `fh-help/fh8-help-site` project). `data/fh-help-corpus.meta.json` (gitignored) tracks
  the ETag/Last-Modified of the last successful update check.

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

`npm test` from the repo root runs this suite plus the bridge (Lua) and installer
(`node --test`) suites — that is the one the release scripts gate on.

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
