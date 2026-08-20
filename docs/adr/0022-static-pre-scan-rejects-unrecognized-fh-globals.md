# Static pre-scan rejects `run_lua` scripts calling unrecognized bare `fh*` globals

A 2026-08-08 grilling session on issue #81 was prompted by a real incident: a session
called `fhGetQualifiedId(newest)` (guessed name; the real one is
`fhGetQualifiedRecordId`, already in `sandbox.lua`'s allowlist). Because the sandbox's
allowlist `_ENV` only catches an unknown name at runtime (`attempt to call a nil value`),
the script had already made two `fhBridge.logActivity` writes before erroring on the bad
call, triggering ADR 0005's write-then-rollback path and forcing a full Bridge Session
restart. This is the second occurrence of the same failure shape (issue #51's
`dt:GetDatePoint()`, closed via corpus documentation only, no code enforcement).

## Decided

1. **Scope**: v1 only checks bare `fh*` global calls (e.g. `fhGetQualifiedId(...)`), not
   `fhu.*` methods, not item-pointer `:Method()` calls. A text pre-scan can't validate a
   method call without knowing the calling object's type; that's issue #51's failure shape
   and stays unaddressed here.

2. **Location**: `runScript.lua`'s `M.run`, running **before `load()`**, alongside
   `preScanViolation` (ADR 0012's existing static pre-scan), not "after `load()`, before
   `pcall()`" as issue #81's own text originally proposed. Checking the actual code found
   neither of ADR 0012's two mechanisms lives at that spot: the static pre-scan runs before
   `load()`, and the write-then-log runtime backstop runs after `pcall()`. Running before
   `load()` inherits the same benefit `preScanViolation` already has, catching the
   violation even in a script that wouldn't otherwise compile. (Note: ADR 0012's own
   written text has the same "after `load()`, before `pcall()`" description, which is
   likewise inaccurate against the code as it stands today, a pre-existing doc/code drift,
   left uncorrected here since fixing ADR 0012's text is out of scope for this issue.)

3. **Own function, not merged into `preScanViolation`**: `unrecognizedFhCallViolation` scans
   in the opposite direction from `preScanViolation`. `preScanViolation` loops a short,
   fixed candidate list (`sandbox.WRITE_NAMES`) and asks "does any of these known-bad names
   appear in the text?". The new check has no fixed candidate list to probe, it has to
   walk the whole script text once with a generic pattern, extract every bare
   `fh<word>(`-shaped call, and check each extracted name against the known-good/
   known-excluded sets. Different mechanism, same "before `load()`" slot, kept as a
   separate function.

4. **Enforcement**: hard reject before execution, mirroring `preScanViolation`'s existing
   treatment. Script never runs; no partial write, no rollback needed.

5. **Known-names source**: `sandbox.lua` gains `KNOWN_FH_GLOBAL_NAMES` (a new
   `READ_ONLY_FH_GLOBAL_NAMES` list, unioned with the existing `WRITE_PRIMITIVE_NAMES`, deduped
   via a set), mode-independent by construction, since `M.build()` only ever populates
   `env` for one access mode at a time. Both source lists are hand-maintained flat data, not
   introspected from `M.build`, so they exist independently of whether `M.build` is ever
   called (this project's plain-lua tests, and the pre-scan itself, run with no real FH
   host).

6. **Two failure messages, distinguished**:
   - **Unrecognized** (typo/hallucination, this incident's case): `script calls an
     unrecognized function <name>`. No near-miss suggestion in v1 (explicitly deferred,
     the hard-reject behavior closes the actual incident gap; a fuzzy suggestion is a
     follow-up if it turns out to matter in practice).
   - **Known-but-permanently-excluded**: `sandbox.lua` gains `EXCLUDED_FH_GLOBAL_REASONS`, a
     real Lua table (name → reason), converted from the existing prose exclusion list in
     `M.build`'s own comment (`fhShellExecute`, `fhMessageBox`, `fhSleep`, etc.), so the
     reject message can say *why* it's blocked (`"it opens a modal dialog and would hang a
     headless run_lua script"`, `"it writes an arbitrary local file..."`, etc.) instead of a
     generic "unrecognized". Kept separate from the pre-existing `FHU_UNSUPPORTED_REASONS`
     table (that one is for `fhu.*` method calls; this one is for bare `fh*` globals, the
     two namespaces never overlap).

7. **Report both violations, not first-match-wins** (2026-08-08 grilling session follow-up):
   if a script trips both `preScanViolation` and `unrecognizedFhCallViolation` in the same
   run, both messages are surfaced, not just whichever check ran first. Rationale: an
   agent-generated script calling both a disallowed write primitive and a
   nonexistent/hallucinated function benefits more from seeing every problem at once than
   from fixing one violation only to hit the next on resubmission. Response shape is
   unchanged, `M.run` still returns `json.encode({ error = <string> })`; the two violation
   messages are concatenated (`"; "`-joined) into that one string, rather than widening the
   response contract to a structured list.

8. **Regex precision**: accepted as a fast-fail heuristic, not a security boundary, same
   known limitations as ADR 0012's pre-scan (a name inside a comment/string with a trailing
   `(` would still false-positive; a name reached via indirection like `local f =
   fhGetQualifiedId` isn't caught). Pattern is `%f[%w_](fh%w*)%f[^%w_]%s*%(`, identifier
   boundary, `fh`-prefix, optional whitespace, then a call paren. A dot immediately after
   the captured identifier breaks the match (`fhu.foo(`, `fhBridge.getFamilyGroup(`), which
   correctly keeps this check scoped to bare globals only.

## Out of scope for this issue

- `fhu.*` method validation and item-pointer `:Method()` validation (see the companion
  issue on `jane/fh-help`, which proposes a build-time diff feeding new-function issues here
  for a human to act on manually, that automation is a future data source for a v2 that
  extends this pre-scan's scope, not a dependency of v1).
- Auto-updating `KNOWN_FH_GLOBAL_NAMES`/`EXCLUDED_FH_GLOBAL_REASONS` when FH ships new
  functions, same companion issue.

## Consequences

- A hand-maintained list needs a human to update it whenever FH's own API grows (until the
  fh-help companion automation, if built, starts filing an issue here on new function
  names). Accepted as the v1 cost of a mode-independent, testable, no-FH-host-required known-
  names source.
- `runScript.lua` now performs two independent linear scans over the submitted script text
  before `load()` (the existing `preScanViolation` candidate-list scan, and the new
  extract-and-check scan). Both are cheap for a single `run_lua` submission's script size;
  not treated as a performance concern.
