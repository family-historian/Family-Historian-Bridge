FH MCP Bridge: an MCP server, installable alongside Family Historian, that lets Claude
query a user's own open FH project directly (no GEDCOM export) by sending Lua scripts to a
companion FH plugin over a local socket.

## Agent skills
Be extremely concise. Sacrifice grammar for the sake of concision.

### Issue tracker

Forgejo issues on this repo's self-hosted instance (`jane/fh-mcp-bridge`), via `curl` + `FORGEJO_TOKEN` — no `gh`/`glab`/`tea` CLI here. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### FH/Lua API lookup order

Before writing or calling any `fh*`/`fhu.*` function whose exact signature you're unsure of, check corpora → web search, in that order — never probe live via `run_lua` first, since those calls can have real side effects even "just to see the error". See `docs/agents/fh-lua-api-lookup.md`.


### Manual testing against a live FH install

After rebuilding `bridge/dist/Claude MCP Bridge.fh_lua`, ask the user to load it and confirm — don't go hunting for FH's Plugins folder or install state yourself. See `docs/agents/manual-testing.md`.

### Releases

Cutting a release (versioning, build scripts, Forgejo upload) is scripted + checklist-driven. See `docs/release.md`.

### Code comments

Contract (what/params/returns) + load-bearing gotchas only. Drop bare issue-number/ADR references, "confirmed live" narration, considered-and-rejected asides — cite an ADR only when the pointer itself is the load-bearing fact. See `docs/adr/0032-comment-density-contract-plus-gotchas-only.md`.

## 🛠️ MCP Tool Requirements (MANDATORY)

- **Serena**: use its LSP tools (`find_symbol`, `get_symbols_overview`, `find_referencing_symbols`) over grep/ripgrep/full-file reads for codebase exploration. `.serena/memories/` holds persistent context — use `read_memory`, not manual search-replace.
- **code-review-graph**: use its MCP tools before planning refactors or validating changes — trace callers, graph dependents, map execution flows, surface test-coverage gaps. Don't guess blast radius or hand-parse trees.

## File Handling Rules
- **changelog.md**: Do not read or pull the existing contents of `changelog.md` into your active context or reasoning. Treat it as a write-only file. Only open or write to `changelog.md` when you need to append a new entry for changes you have just completed.
