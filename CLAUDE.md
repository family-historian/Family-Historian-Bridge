FH MCP Bridge: an MCP server, installable alongside Family Historian, that lets Claude
query a user's own open FH project directly (no GEDCOM export) by sending Lua scripts to a
companion FH plugin over a local socket.

## Agent skills

### Issue tracker

Forgejo issues on this repo's self-hosted instance (`jane/fh-mcp-bridge`), via `curl` + `FORGEJO_TOKEN` — no `gh`/`glab`/`tea` CLI here. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### FH/Lua API lookup order

Before writing or calling any `fh*`/`fhu.*` function whose exact signature you're unsure of, check corpora → web search, in that order — never probe live via `run_lua` first, since those calls can have real side effects even "just to see the error". See `docs/agents/fh-lua-api-lookup.md`.

### Codebase navigation

Activate Serena for this project at the start of a session (general Serena/code-review-graph/understand-anything selection is in `~/CLAUDE.md`). `.fh_lua` files aren't recognized by Serena's Lua language server — fall back to grep/Read for those. See `docs/agents/codebase-navigation.md`.
