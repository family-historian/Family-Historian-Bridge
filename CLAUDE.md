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

This project utilizes custom Model Context Protocol (MCP) tooling. You MUST prioritize these specific semantic tools before using any fallback shell commands:

### 1. Code Intelligence & Discovery (Serena)
* **Rule:** NEVER run broad `grep`, `ripgrep`, or full-file reads to explore the codebase or search for components.
* **Action:** You must use **Serena**'s LSP tools (`find_symbol`, `get_symbols_overview`, `find_referencing_symbols`) to structurally navigate variables, classes, and language server types.
* **Context:** Persistent context memories are tracked locally in `.serena/memories/`. Use Serena's `read_memory` or structural editing capabilities over manual regex search-and-replace text blocks.

### 2. Impact Tracing & PR Reviews (code-review-graph)
* **Rule:** Do not guess the blast-radius of code changes or parse standard text trees manually to write reviews.
* **Action:** ALWAYS utilize `code-review-graph` MCP tools before planning structural refactors or validating code changes. 
* **Task:** Query the local SQLite database to trace callers, graph dependents, map execution flows, and explicitly surface test-coverage gaps before code commits.

## File Handling Rules
- **changelog.md**: Do not read or pull the existing contents of `changelog.md` into your active context or reasoning. Treat it as a write-only file. Only open or write to `changelog.md` when you need to append a new entry for changes you have just completed.
