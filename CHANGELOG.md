# Changelog

## 0.2.0

### Read-write Access mode wired end-to-end
- Bridge dialog's Access mode (Read-only / Read-write) now threads through
  to the sandbox: `bridge.fh_lua` passes `currentAccessMode()` into
  `runScript.run`, which passes it into `sandbox.build`. (#13)
- Read-write sandbox builds now expose FH's full write API — every
  `fhSetValueAs*` setter, `fhSetLabelledText`, `fhCreateItem`,
  `fhDeleteItem`, `fhMoveItemAfter/Before`, `fhSrcEnableAutoTitle`,
  `fhGetFactTag`/`fhGetFlagTag` — gated behind Read-write, absent under
  Read-only. `describe_project`'s fixed census script is forced Read-only
  regardless of the Session's mode. (#14, #16)
- Documented the full write-API surface and why write-mode script errors
  are re-thrown rather than swallowed, so FH's own undo history stays
  usable (ADR 0005).

### Source citation tooling
- New `fhBridge.createSourceFromTemplate(templateNameOrId, fields, transcription)`
  bridge helper (`bridge/sourceHelper.lua`) — one call replaces hand-rolled
  `fhCreateItem("SOUR", ...)` + per-field `fhSetValueAsLink` sequences for
  template-based Source creation. (#18)
- New `fhBridge.citeSource(ptrTarget, sourceIdOrTitle)` helper — cites an
  existing Source against a Fact or whole record by id or by title, same
  by-id-or-by-title resolution as `createSourceFromTemplate`.
- `run_lua`'s tool description now steers Claude to cite *every* Fact a
  Source actually supports (not just the one asked about), and to list
  any gaps found and wait for confirmation before writing them.
- Documented templated Source creation in the gedcom-knowledge corpus
  (`_SRCT` link, FDEF field definitions, `~PREFIX-CODE` field syntax) and
  fixed a `_SRCT` scope conflation in that write-up.

### Safety and guidance hardening
- `run_lua`'s tool description now requires searching FH help / the
  gedcom-knowledge corpus before hand-rolling low-level primitives —
  prompted by a live script that hand-rolled a CHIL/FAMC link instead of
  using the existing helper. (#17)
- Documented that `fhu.*` creator functions (e.g. `fhu.createIndi`) don't
  validate their arguments — a missing/wrong arg still creates a real,
  permanent record instead of erroring.

### Cleanup
- Removed the superseded `bridge_prototype_v2.fh_lua` and its stale
  handover doc.
- Moved bridge Lua unit tests into `bridge/tests/`, so everything directly
  in `bridge/` is exactly what gets copied into FH's Plugins folder.
- Fixed README/user-guide install instructions to list all seven bridge
  files (`requestFraming.lua`, `sourceHelper.lua` were missing).
- Fixed a sandbox test that over-matched `fhBridge` itself as an excluded
  primitive.

### Packaging
- Version bumped to 0.2.0 (0.1.0 already released on Forgejo).

## 0.1.0

First packaged release. Bridge plugin + MCP server (`run_lua`,
`describe_project`, FH help search/update-check), sandboxed script
execution, Session Access-mode selector and idle-timeout auto-Stop.
