# FH MCP Bridge — Core

MCP server + companion FH (Family Historian) plugin. Lets Claude query/edit a user's open
FH project by sending Lua scripts to the plugin over a local TCP socket (127.0.0.1 only).
Solo project (Jane_t), self-hosted Forgejo issue tracker, pre-1.0 (currently 0.11.0).

## Two halves (separate languages/toolchains)
- `bridge/` — Lua plugin, runs inside FH itself. See `mem:bridge`.
- `server/` — TypeScript MCP server, runs alongside Claude Desktop. See `mem:server`.
- `installer/` — packages both into a Windows .exe / .mcpb bundle. Not yet memoried in
  depth; see `installer/README.md` and `docs/release.md` if touching it.
- `mem:distribution` — how the server/bridge actually reach users (Claude Connectors
  Directory, FH Plugin Store, GitHub mirror), and the FH8-GA blocker on all of it. Read
  before touching installer/release/submission work.

## Domain glossary (moved from CONTEXT.md into memories, split by topic — read only the
cluster relevant to what you're touching, not all of them)
- `mem:domain/naming` — the 3 distinct product/component names (Bridge plugin / Family
  Historian Bridge / FH MCP Bridge). Read when writing anything user-facing or renaming.
- `mem:domain/session_lifecycle` — Session, Exit vs Stop, Access mode, Visibility settings
  (Private/Living, issue #141, ADR 0038), Sandbox, FH auto-undo, Version check. Read when
  touching Session/dialog/sandbox behavior in `bridge/`.
- `mem:domain/mcp_tools` — domain semantics of run_lua/describe_project/author_fh_plugin/
  install_fh_plugin (file layout is in `mem:server` instead). Read when changing what a
  tool returns or its trust boundary.
- `mem:domain/sources` — Source template, citeSource, findSources,
  getTemplateFieldCensus, citation field vocabulary. Read when touching
  `sourceHelper.lua` or any SOUR/template work.
- `mem:domain/facts` — createFact, Shared Fact, Fact/Record Flag, Direct ancestor,
  Qualified id string, Clarifying question. Read when touching `factHelper.lua`/
  `familyHelper.lua` or Fact-shaped queries.
- `mem:domain/search` — findByNames (replaces searchByName, ADR 0037), word-set
  containment, its `{matches, totalMatches}` result shape. Read when touching
  `familyHelper.lua`'s name-search helper.
- `mem:domain/richtext_logging` — FTF/tFTF, getTftfText/setTftfText, logActivity,
  run_lua-guidance corpus entries. Read when touching `richTextHelper.lua`/
  `sessionLogHelper.lua`.

`CONTEXT.md` at the repo root is now a stub pointing here — new terms get memoried
directly (topic `domain/*`), not re-grown in CONTEXT.md.

## Other canonical docs (read before non-trivial work)
- `docs/adr/00NN-*.md` — one ADR per non-obvious design decision (30+ so far). Check for a
  relevant ADR before overriding past reasoning; flag contradictions rather than silently
  overriding.
- `.ua/knowledge-graph.json` — understand-anything graph; project CLAUDE.md says to prefer
  `/understand-chat`/`/understand-explain` over raw file search for "how does X work"
  questions, and code-review-graph MCP tools for diff/blast-radius/refactor work (see
  user-level CLAUDE.md at `~/CLAUDE.md`).
- `docs/agents/issue-tracker.md` — Forgejo (self-hosted, Gitea-compatible) issue tracker,
  no `gh`/`glab`/`tea` CLI; raw `curl` + `FORGEJO_TOKEN`. See `mem:issue_tracker`.
- `docs/agents/domain.md` — how to consume CONTEXT.md/ADRs when exploring (single-context
  repo layout here, no `CONTEXT-MAP.md`) — updated to point at `domain/*` memories.

## Project-wide invariants
- Everything runs local-only except one explicit user-triggered `check_fh_help_updates`
  network call to family-historian.co.uk.
- `server/package.json` is the version source of truth. Only one hand-copied second copy is
  left, the `@Version:` header in `bridge/Claude MCP Bridge.fh_lua` (issue #89);
  `serverVersion.ts`, the `.iss` `AppVersion`, the `.mcpb` manifest version and
  `package-lock.json` are all derived. The repo-root `package.json` is a dependency-free
  task runner and deliberately has no `version` field. See `docs/release.md` step 4.
- Copied-value drift is this repo's recurring defect shape (bridge file lists, `.iss`
  version, the `.mcpb` tool list — issue #85). Generate or read from one source, and test
  that the source matches reality; don't add a new hand-synced copy.
- FH8 hasn't publicly shipped yet — packaged (not committed) copies of README/user-guide
  must have FH8-specific wording genericized before a public release; see
  `docs/release.md` step 5.

See `mem:tech_stack`, `mem:suggested_commands`, `mem:conventions`, `mem:task_completion`.
