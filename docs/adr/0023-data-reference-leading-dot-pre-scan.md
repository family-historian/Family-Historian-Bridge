# Static pre-scan rejects a literal bare-leading-dot Data Reference

A 2026-08-14 grilling session on issues #101/#103 traced a real incident: transcribing a
birth certificate, a session looped `child:MoveTo(otherPtr, '.DATE')` (missing the leading
`~`) to find a specific `OCCU` fact's date. `MoveTo` doesn't error on a bare leading-dot
Data Reference — it silently leaves the pointer Null, same failure shape as any other "not
found" case — so `datePtr:IsNotNull()` was false every iteration, the loop ran to
completion, and the script errored on `not found` only *after* an earlier `TEXT`
transcription in the same script had already written, triggering a full
`writeSessionRolledBack` (docs/adr/0005) the user had to manually confirm past in FH's own
Plugin Error dialog.

This is the third occurrence of the same general failure shape this project has already
named twice in its own history: issue #51 (`dt:GetDatePoint()`, a guessed method name that
doesn't exist) and issue #81 (`fhGetQualifiedId`, a guessed bare-global typo,
docs/adr/0022) — both closed via corpus documentation alone the first time, docs/adr/0022
escalating the second to a static pre-scan. This one is worse than either: not a Lua error
at all, a silently wrong value that only surfaces much later (or never, if the loop happens
to still behave correctly by coincidence).

docs/adr/0022 deliberately scoped its own pre-scan to bare `fh*` global calls only,
excluding `fhu.*` methods and item-pointer `:Method()` calls, because "a text pre-scan can't
validate a method call without knowing the calling object's type." That reasoning doesn't
apply here: this check isn't about resolving what kind of object a method call's receiver
is — it's about validating the *shape of a literal string argument* passed to a known call
site, which needs no type resolution at all.

## Decided

1. **Scope: four call shapes, not just `MoveTo`.** `strDataReference`-taking functions
   reachable from `run_lua`'s sandbox share the exact same grammar rule and the exact same
   "no error, just a wrong result" failure family:
   - `ptr:MoveTo(otherPtr, strDataReference)` — Null pointer (FH help, `MoveTo.htm`).
   - `fhGetItemPtr(ptr, strDataReference)` — Null pointer ("Null if the Data Reference is
     not found", FH help, `fhGetItemPtr.htm`).
   - `fhGetItemText(ptr, strDataReference)` — empty string ("The string will be empty (but
     not nil) if the data reference does not resolve", FH help, `fhGetItemText.htm`).
   - `fhGetDisplayText(ptr, strDataReference[, strDisplayOption])` — empty string
     ("fhGetDisplayText will always return a string, although it may be an empty one", FH
     help, `fhGetDisplayText.htm`).

   Scoping to `MoveTo` alone (the one call site the reported incident actually hit) would
   leave three call sites with the identical footgun live and undetected — the detection
   rule is identical for all four, so covering all four costs no extra mechanism.

2. **Detection rule: a literal 2nd-argument string starting with a bare `.`.** FH's own
   grammar (corpus `data-references-syntax`, confirmed against `MoveTo.htm`) has exactly two
   valid forms — a `~`-relative reference (`~.DATE`) or a full path from a record-level tag
   (`INDI.BIRT.DATE`) — neither of which can ever start with a literal `.`. This makes the
   check unambiguous: no legitimate call ever has a 2nd-argument string literal beginning
   with `.`, so there is no false-positive risk from the rule itself (only from the
   text-heuristic limitation in the next point).

3. **Literal-argument-only, same heuristic limitation as every existing pre-scan.** A script
   that builds the reference in a variable first (`local ref = '.DATE'; ptr:MoveTo(x, ref)`)
   isn't caught — matches `unrecognizedFhCallViolation`'s own accepted "fast-fail heuristic,
   not a security boundary" stance (docs/adr/0022, point 8). Going further (constant-folding,
   data-flow analysis) is out of proportion to the problem.

4. **Enforcement: hard reject before `load()`**, mirroring every existing pre-scan
   (`preScanViolation`, `unrecognizedFhCallViolation`). Zero false-positive risk per point 2
   means there's no legitimate script this could ever incorrectly block — strictly better
   than today's silent-Null-then-possible-rollback outcome.

5. **Own function (`dataReferenceViolation`), reported alongside the other two pre-scans.**
   Same "own function, not merged into an existing one" pattern as docs/adr/0022 (different
   regex shape per call type, needs its own loop over `DATA_REF_CALL_SHAPES`). `M.run` joins
   all three pre-scans' messages with `; ` into the existing single `error` string, extending
   the "report every violation at once" policy from docs/adr/0022 point 7 to three checks
   instead of two — a script tripping more than one hears about everything wrong with it in
   one round-trip.

6. **Message names the offending call, the bad value, and the fix**, distinguishing the two
   symptom families (Null pointer vs. empty string) per call shape, and suggesting both valid
   forms (`~`-prefixed and a record-level-tag path) rather than just the one the script
   happened to get wrong.

## Out of scope for this issue

- Any Data Reference syntax validation beyond "starts with a bare `.`" (e.g. malformed
  qualifiers, non-existent tags) — those already surface as a legitimate "not found" empty
  result, which is correct behavior, not this bug.
- Extending the corpus's `run-lua-guidance-call-shape-gotchas` bullet (added the same
  session) to a fifth call shape if FH ever adds one — tracked if/when it happens, not
  speculatively here.

## Consequences

- `runScript.lua` now performs three independent linear scans over the submitted script text
  before `load()` (the existing two, plus this one). Cheap for a single `run_lua`
  submission's script size; not treated as a performance concern, same conclusion
  docs/adr/0022 reached for its own second scan.
- A future fifth `strDataReference`-taking call site (if FH's plugin API grows one) needs a
  human to add it to `DATA_REF_CALL_SHAPES` by hand — same accepted v1 cost docs/adr/0022
  took for its own hand-maintained `KNOWN_FH_GLOBAL_NAMES`.
