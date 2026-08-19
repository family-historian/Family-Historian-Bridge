# Codebase navigation (project-specific Serena notes)

General Serena-vs-code-review-graph-vs-understand-anything tool selection lives in the
user-level `~/CLAUDE.md`, not here — this file only covers what's specific to this repo.

- Activate Serena for this project (`activate_project` with name "MCP for Family Historian")
  at the start of a session, then use its symbolic tools (`find_symbol`, `get_symbols_overview`,
  `find_referencing_symbols`, etc.) for codebase structure, architecture, or "how does X work"
  questions rather than searching files directly.
- Use Serena for edits too, not just lookups, in any Serena-supported file type: symbolic
  editing tools (`replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`,
  `rename_symbol`, `safe_delete_symbol`) or `replace_content` for sub-symbol edits, instead of
  the built-in Edit/Write tools.
- Covers TypeScript (`server/`), Lua (`bridge/*.lua`), Bash, Markdown, JSON, and YAML
  (`.serena/project.yml`'s `language_servers` list). `.fh_lua` files are **not** recognized
  by Serena's Lua language server (issue #75) — fall back to grep/Read for those specifically.
- PowerShell (`installer/release-windows.ps1`) is **not** covered — can't be added while running
  on macOS. Fall back to grep/Read for it too.
- Re-activating an already-active project is a no-op in this Serena version (doesn't reread
  `.serena/project.yml` or restart language servers), so a fresh session is needed after
  editing that file.
