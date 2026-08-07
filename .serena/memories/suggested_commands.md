# Suggested commands

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
  `bridge/dist/Claude MCP Bridge.fh_lua` (gitignored, generated — copy this into FH's
  Plugins folder to install, but the user does that step themselves, never you).
- Run one module's unit tests (plain `lua`, no FH dependency):
  `lua bridge/tests/<module>.test.lua` — e.g. `lua bridge/tests/sandbox.test.lua`. No
  aggregate "run all" script observed; run each file individually or loop over
  `bridge/tests/*.test.lua`.
- No automated test for `Claude MCP Bridge.fh_lua` itself (the IUP dialog/socket plumbing)
  — manual-only, inside FH (see bridge/README.md "Manual test" section).

## Darwin-specific gotchas
- `ls` is aliased/shadowed in this shell in a way that rejects `--icons` args used by some
  wrapper — prefer `/bin/ls` or `find`/`fd` over bare `ls` when scripting from Bash tool.
