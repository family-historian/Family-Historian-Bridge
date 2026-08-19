# Conventions

- **Terminology discipline**: the `domain/*` memories (see `mem:core`) define exact
  preferred terms with explicit avoid-notes per entry (e.g. say "Bridge plugin" not
  "Plugin"/"server" when the Lua plugin specifically is meant; "Session" not "Connection";
  "Access mode" not "Permission level"). Match these exactly in code, comments, commits,
  and issues.
- **ADR-per-decision**: any non-obvious design choice gets its own
  `docs/adr/NNNN-slug.md`. Check for a relevant one before re-deciding something; if new
  work contradicts an existing ADR, say so explicitly rather than silently overriding it.
- **fhBridge helpers over hand-rolled FH API calls**: prefer existing `fhBridge.*` /
  `fhu.*` wrapper helpers (`citeSource`, `createSourceFromTemplate`, `findSources`,
  `getTemplateFieldCensus`, `logActivity`, `familyHelper`'s six query helpers) over
  reimplementing the underlying `fhCreateItem`/`fhSetValueAsLink`/etc. dance inline.
- **Sandbox allowlist model**: `bridge/sandbox.lua`'s `_ENV` is built as an explicit
  allowlist (only added globals visible), never as "start from real env, strip dangerous
  ones" — preserve this direction when adding new exposed functions.
- **No caching in `describe_project`**: recomputes every call by design (ADR 0002) — don't
  add memoization there without revisiting that ADR.
- **write-then-log invariant**: any write script in a Read-write Session must call
  `fhBridge.logActivity` — enforced by both a static pre-scan (`runScript.lua`) and a
  runtime backstop (`sandbox.lua`'s `tracker.logged`), not just prompt steering (ADR 0012).
- Commit convention for releases: `Bump version to X.Y.Z`, `Cut CHANGELOG for X.Y.Z`.
- Solo project: commit and push straight to `main` when asked (no branch-first workflow
  expected) — but confirm before merging/pushing anything not explicitly requested.
