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

### Codebase navigation

Activate Serena for this project at the start of a session (general Serena/code-review-graph/understand-anything selection is in `~/CLAUDE.md`). `.fh_lua` files aren't recognized by Serena's Lua language server — fall back to grep/Read for those. See `docs/agents/codebase-navigation.md`.

### Manual testing against a live FH install

After rebuilding `bridge/dist/Claude MCP Bridge.fh_lua`, ask the user to load it and confirm — don't go hunting for FH's Plugins folder or install state yourself. See `docs/agents/manual-testing.md`.

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes_tool` or `query_graph_tool` instead of Grep
- **Understanding impact**: `get_impact_radius_tool` instead of manually tracing imports
- **Code review**: `detect_changes_tool` + `get_review_context_tool` instead of reading entire files
- **Finding relationships**: `query_graph_tool` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview_tool` + `list_communities_tool`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
| ------ | ---------- |
| `detect_changes_tool` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context_tool` | Need source snippets for review — token-efficient |
| `get_impact_radius_tool` | Understanding blast radius of a change |
| `get_affected_flows_tool` | Finding which execution paths are impacted |
| `query_graph_tool` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes_tool` | Finding functions/classes by name or keyword |
| `get_architecture_overview_tool` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes_tool` for code review.
3. Use `get_affected_flows_tool` to understand impact.
4. Use `query_graph_tool` pattern="tests_for" to check coverage.
