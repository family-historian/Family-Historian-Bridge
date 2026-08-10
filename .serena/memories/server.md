# server/ — TypeScript MCP server

Node/TS, `"type": "module"` (ESM), package name `fh-mcp-bridge-server`. `package.json`'s
version is the release source of truth; only the Bridge's `@Version:` header is still
hand-copied from it (see `mem:core` and issue #89).

Source layout (`server/src/`, one concern per file, `*.test.ts` siblings):
- `bridgeClient.ts` — TCP client, frames requests (`LUA <n>` / `LUA_RO <n>` to force
  Bridge's Read-only sandbox regardless of Session's Access mode).
- `runLuaTool.ts` — the one Claude-facing `run_lua` MCP tool.
- `describeProjectTool.ts` — fixed built-in census script, always Read-only regardless of
  Session mode, recomputed every call (no cache — ADR 0002).
- `authorFhPluginTool.ts`, `installFhPluginTool.ts` — plugin-scaffolding / install-to-disk
  tools, distinct trust model from `run_lua` (see CONTEXT.md **author_fh_plugin**).
- `fhHelp.ts` / `fhHelpUpdate.ts` — bundled FH8 help corpus + explicit-trigger network
  update check.
- `corpusSearch.ts`, `gedcomKnowledge.ts` — GEDCOM domain-knowledge corpus search (see
  `mem:corpora`).
- `versionCheck.ts`, `serverVersion.ts` — Bridge/server version-mismatch handshake (ADR
  0013).
- `index.ts` — entry point, registers tools/resources, connects over stdio. Can't be
  imported by tests: it registers and connects a stdio transport at module scope.
- `toolNames.json` / `toolNames.ts` — single source of truth for the 8 MCP tool names
  (issue #85), read by `installer/dxt/manifest.mjs` and `installer/verify-dxt.mjs` as well.
  JSON so plain-Node installer scripts read it without a build or the gitignored `dist/`.
  `toolNames.test.ts` stands up a real `McpServer`, registers everything the way `index.ts`
  does, and asserts `tools/list` over `InMemoryTransport` matches the JSON exactly — add a
  tool to the server and forget the JSON (or vice versa) and that test fails.

Data: `server/data/fh-help-corpus.jsonl` (scraped FH help, source of truth is sibling
`fh-help/fh8-help-site` project) and `server/data/gedcom-knowledge-corpus.jsonl` (own
domain-knowledge corpus, kept separate so `check_fh_help_updates` can't clobber it — see
`mem:corpora` and ADR 0003 for its scope).

`RUN_LUA_DESCRIPTION` truncation: MCP clients with deferred/lazy tool-schema loading
silently truncate long tool descriptions around ~2KB, so `run_lua`'s description only keeps
a self-sufficient "safe zone" — the rest lives in the gedcom-knowledge-corpus under
`"run_lua guidance"`-titled entries, fetched via one `search_gedcom_knowledge` call per
conversation. See ADR 0011. This pattern generalizes: extend that corpus-entry family
rather than growing `RUN_LUA_DESCRIPTION` further.
