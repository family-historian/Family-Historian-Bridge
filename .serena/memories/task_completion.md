# Task completion checklist

## After editing server/src/*.ts
1. `cd server && npm run typecheck`
2. `cd server && npm test` (vitest)
3. `npm run build` if the change needs to be reflected in `dist/` (e.g. before a manual
   e2e/smoke test)

## After editing bridge/*.lua
1. Run the affected module's standalone test: `lua bridge/tests/<module>.test.lua`
2. Rebuild the bundle: `lua bridge/scripts/build.lua` (produces
   `bridge/dist/Claude MCP Bridge.fh_lua`)
3. Do NOT attempt to install/copy into the user's FH Plugins folder or touch their
   CrossOver bottle yourself — build only; the user installs it. Warn the user up front if
   verifying the change requires a live Bridge Session, before calling `run_lua`/
   `describe_project` and hitting a connection error.
4. `Claude MCP Bridge.fh_lua` itself has no automated test — manual verification inside FH
   only (bridge/README.md "Manual test" section has the exact steps).

## Docs to keep in sync when behavior changes
- `CONTEXT.md` glossary entry for any affected term/tool.
- Relevant `docs/adr/NNNN-*.md` if the change reverses or refines a past decision (or add a
  new ADR).
- `CHANGELOG.md`'s `## Unreleased` section for any user-facing change.
