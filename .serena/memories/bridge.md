# bridge/ — FH Lua plugin

Files directly in `bridge/` (not `bridge/tests/`, not `bridge/scripts/`) are exactly what
`scripts/build.lua`/`bundler.lua` bundle into the single installable
`dist/AI Assistant Connector.fh_lua` — nothing filtered by name, so nothing else belongs at that
top level. `dist/` is generated + gitignored; rebuild with `lua bridge/scripts/build.lua`.

Key modules: `requestFraming.lua` (parses `STOP`/`LUA <n>`/`LUA_RO <n>`/`VERSION <v>`),
`runScript.lua` (compiles+runs inside sandbox under watchdog), `sandbox.lua` (allowlist
`_ENV`), `jsonEncode.lua` (hand-rolled, FH's Lua ships none), `watchdog.lua` (instruction-
budget abort), `timeoutDisplay.lua`, `versionCompare.lua` (match/warn/block, strict
major-only, inert pre-1.0), `sourceHelper.lua` (`fhBridge.createSourceFromTemplate`,
`citeSource`, `findSources`, `getTemplateFieldCensus`), `sessionLogHelper.lua`
(`fhBridge.logActivity`), `familyHelper.lua` (6 read-only query helpers: getFamilyGroup,
getAncestors, getDescendants, getAllDetails, findByNames, getFactsByTag — all accept
either a live pointer or a qualified-id string like `"I219"`).

`AI Assistant Connector.fh_lua` itself (IUP dialog + TCP listener + framing) has no automatable
seam — FH is proprietary, Windows/CrossOver-only — tested manually inside FH only (see
bridge/README.md "Manual test" section for the exact script).

**Never search/access the user's CrossOver bottle or FH Plugins folder yourself** after
bridge/*.lua changes — just run the build; the user handles install into FH themselves.

See `mem:suggested_commands` for exact test-run commands (plain `lua` interpreter, no FH
dependency, one file per module in `bridge/tests/`).
