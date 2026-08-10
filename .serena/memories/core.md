# FH MCP Bridge — Core

MCP server + companion FH (Family Historian) plugin. Lets Claude query/edit a user's open
FH project by sending Lua scripts to the plugin over a local TCP socket (127.0.0.1 only).
Solo project (Jane_t), self-hosted Forgejo issue tracker, pre-1.0 (currently 0.11.0).

## Two halves (separate languages/toolchains)
- `bridge/` — Lua plugin, runs inside FH itself. See `mem:bridge`.
- `server/` — TypeScript MCP server, runs alongside Claude Desktop. See `mem:server`.
- `installer/` — packages both into a Windows .exe / .mcpb bundle. Not yet memoried in
  depth; see `installer/README.md` and `docs/release.md` if touching it.

## Canonical docs (read before non-trivial work)
- `CONTEXT.md` (repo root) — full domain glossary, one entry per term (Session, Access
  mode, Sandbox, run_lua, describe_project, Source template, FTF, Shared Fact, Fact/Record
  Flag, findSources, getTemplateFieldCensus, logActivity, etc.). Authoritative vocabulary —
  match it exactly in issues/commits/code, don't drift to synonyms it explicitly avoids.
- `docs/adr/00NN-*.md` — one ADR per non-obvious design decision (22 so far). Check for a
  relevant ADR before overriding past reasoning; flag contradictions rather than silently
  overriding.
- `.ua/knowledge-graph.json` — understand-anything graph; project CLAUDE.md says to prefer
  `/understand-chat`/`/understand-explain` over raw file search for "how does X work"
  questions, and code-review-graph MCP tools for diff/blast-radius/refactor work (see
  user-level CLAUDE.md at `~/CLAUDE.md`).
- `docs/agents/issue-tracker.md` — Forgejo (self-hosted, Gitea-compatible) issue tracker,
  no `gh`/`glab`/`tea` CLI; raw `curl` + `FORGEJO_TOKEN`. See `mem:issue_tracker`.
- `docs/agents/domain.md` — how to consume `CONTEXT.md`/ADRs when exploring (single-context
  repo layout here, no `CONTEXT-MAP.md`).

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
