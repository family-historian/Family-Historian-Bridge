# Tech stack

- `server/`: Node.js + TypeScript, ESM (`"type": "module"`), `@modelcontextprotocol/sdk`
  ^1.30, `zod` ^4. Test runner: `vitest`. Build: `tsc` (see `server/tsconfig.json`).
- `bridge/`: Lua (FH's bundled Lua runtime — proprietary, Windows/CrossOver-only).
  Standalone modules tested with a plain system `lua` interpreter (no FH dependency, no
  busted/luaunit framework — tests are hand-rolled `*.test.lua` files that run standalone).
- `installer/`: Node (`build-dxt.mjs`, `verify-dxt.mjs`) + PowerShell (`stage.ps1`,
  `release-windows.ps1`, `config-merge.ps1`) + Inno Setup (`fh-mcp-bridge.iss`) for the
  Windows installer, plus `release-mac.sh`.
- Knowledge tooling in repo but not part of the shipped product: `.ua/` (understand-
  anything graph), `.code-review-graph/` (code-review-graph DB) — both maintained by
  Claude Code hooks/skills, not by project code.
