# Suggested commands

## Repo root — all suites at once
- `npm test` — server (vitest) + bridge (lua) + installer (`node --test`), in that order,
  stopping at the first failure. This is what `installer/release-mac.sh` and
  `installer/release-windows.ps1` run before building anything (issue #84).
- Individually: `npm run test:server` / `npm run test:bridge` / `npm run test:installer`.
- `npm run setup:hooks` — one-time per clone; points `core.hooksPath` at the committed
  `.githooks/`, enabling a pre-push hook that runs the aggregate suite (issue #90). Takes
  ~2s; `git push --no-verify` bypasses it.
- **No CI, by decision** (issue #90, closed `wontfix` 2026-08-10). A Forgejo Actions
  workflow was written and backed out: one developer, one machine, and the pre-push hook
  already covers the only realistic gap. Forgejo runs on a small LXC, so a runner would have
  meant Docker-in-LXC or a permanent Node + Lua install there. Don't re-propose CI without
  new reasons — and check with the user first, since the infrastructure constraint isn't
  visible from the repo.
- The root `package.json` is a dependency-free task runner and deliberately has **no**
  `version` field — `server/package.json` is the single version source of truth (issue #44).

## server/ (run from `server/`)
- `npm install` — first-time setup
- `npm run build` — `tsc` compile to `dist/`
- `npm run typecheck` — `tsc --noEmit`
- `npm test` — `vitest run`
- `npm run start` — run built server (`node dist/index.js`)
- Manual e2e (needs a real running Bridge Session in FH): `npm run build && node
  scripts/smoke-test.mjs`

## bridge/ (run from repo root)
- Build single-file plugin: `lua bridge/scripts/build.lua` → writes
  `bridge/dist/AI Assistant Connector.fh_lua` (gitignored, generated — copy this into FH's
  Plugins folder to install, but the user does that step themselves, never you).
- Run all of them: `npm run test:bridge` from the repo root
  (`scripts/run-bridge-tests.mjs` — discovers `bridge/tests/*.test.lua`, stops at the first
  failure; finds the interpreter via `LUA_BIN`, then `lua` on PATH, then
  `C:\Utils\lua\lua.exe`).
- Run one module's unit tests while working on it (plain `lua`, no FH dependency):
  `lua bridge/tests/<module>.test.lua` — e.g. `lua bridge/tests/sandbox.test.lua`.
- No automated test for `AI Assistant Connector.fh_lua` itself (the IUP dialog/socket plumbing)
  — manual-only, inside FH (see bridge/README.md "Manual test" section).

## Darwin-specific gotchas
- `ls` is aliased/shadowed in this shell in a way that rejects `--icons` args used by some
  wrapper — prefer `/bin/ls` or `find`/`fd` over bare `ls` when scripting from Bash tool.
