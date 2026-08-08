# Codebase navigation (project-specific Serena notes)

General Serena-vs-code-review-graph-vs-understand-anything tool selection lives in the
user-level `~/CLAUDE.md`, not here — this file only covers what's specific to this repo.

- Activate Serena for this project (`activate_project` with name "MCP for Family Historian")
  at the start of a session, then use its symbolic tools (`find_symbol`, `get_symbols_overview`,
  `find_referencing_symbols`, etc.) for codebase structure, architecture, or "how does X work"
  questions rather than searching files directly.
- Covers TypeScript (`server/`) and Lua (`bridge/*.lua`). `.fh_lua` files are **not** recognized
  by Serena's Lua language server (issue #75) — fall back to grep/Read for those specifically.
- Re-activating an already-active project is a no-op in this Serena version (doesn't reread
  `.serena/project.yml` or restart language servers), so a fresh session is needed after
  editing that file.
