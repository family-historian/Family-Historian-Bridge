## Agent skills

### Issue tracker

Forgejo issues on this repo's self-hosted instance (`jane/fh-mcp-bridge`), via `curl` + `FORGEJO_TOKEN` — no `gh`/`glab`/`tea` CLI here. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### FH/Lua API lookup order

Before writing or calling any `fh*`/`fhu.*` function whose exact signature you're unsure of
(param order, types, required-vs-optional), check in this order — never skip straight to
probing live via `run_lua`, since `fhu`/`fh*` calls can have real side effects (creating
records) even when called "just to see the error message":

1. `server/data/fh-help-corpus.jsonl` — scraped FH plugin API help (`fhUtils.lua` reference,
   `fh*` global functions). Has exact signatures like `createIndi(sName, sSex)`.
2. `server/data/gedcom-knowledge-corpus.jsonl` — concept-level domain knowledge (FTF rich
   text, Shared Facts, Source Templates, Sentence templates). See ADR 0003 for its scope.
3. Web search (`pluginstore.family-historian.co.uk`, `family-historian.co.uk/help`) if
   neither corpus has it.
4. Only as a last resort, probe live via `run_lua` — and even then, prefer functions that
   error on missing required args over ones that might execute with defaults.

### Codebase questions
Activate Serena for this project (`activate_project` with name "MCP for Family Historian") at
the start of a session, then use its symbolic tools (`find_symbol`, `get_symbols_overview`,
`find_referencing_symbols`, etc.) for codebase structure, architecture, or "how does X work"
questions rather than searching files directly. Covers TypeScript (`server/`) and Lua
(`bridge/*.lua`); `.fh_lua` files aren't recognized by Serena's Lua language server (issue #75)
— fall back to grep/Read for those. Re-activating an already-active project is a no-op in this
Serena version (doesn't reread `.serena/project.yml` or restart language servers), so a fresh
session is needed after editing that file.