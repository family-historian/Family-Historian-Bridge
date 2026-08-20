---
status: accepted
---

# Write-result checks share two helpers, `checkWrite`/`checkCreated`, alongside `pointerProblem`

Every `fhSetValueAs*` call across `sourceHelper.lua`/`sessionLogHelper.lua`/`richTextHelper.lua`
(11 sites) and every `fhCreateItem` call in the same three modules (6 sites) discarded its own
failure signal, FH's own documented, non-throwing way of reporting that a write silently didn't
happen. ADR 0027 found and named this exact gap while fixing a related-but-distinct problem
(pointer-*argument*-shape validation) and explicitly deferred it: "needs its own scoping decision,
not folded in here." Issue #111 is that scoping decision.

Confirmed from FH's own docs: `fhSetValueAsText`/`Date`/`Link`/`RichText` return `bOK` (`true` on
success, `false` on failure, never a thrown error); `fhCreateItem` returns "a NULL pointer if the
create fails for any reason", a real Item Pointer whose `:IsNull()` is true, not a Lua `nil`.
Both classes were checked across every call site inside the four write-capable composite
functions these three modules expose (`createSourceFromTemplate`, `citeSource`, `logActivity`,
`setTftfText`), cross-checked against `sandbox.lua`'s write wiring, this is already every
`fhSetValueAs*`/`fhCreateItem` call these three modules make, so there was no unreachable call to
exclude and no scope split needed between "every call" and "only Claude-reachable calls."
`fhSrcEnableAutoTitle` (also write-tracked, called once in `sourceHelper.lua`) is excluded, per
its own docs it returns nothing at all, so there is no failure signal to check.

## Decided

Two small helpers in `familyHelper.lua`, next to `pointerProblem`:

- `familyHelper.checkWrite(bOK, message)`, `if not bOK then error(message) end`, for the four
  boolean-returning setters.
- `familyHelper.checkCreated(item, message)`, reuses `pointerProblem`'s existing `pcall`-guarded
  null detection (a NULL Item Pointer is exactly the shape `pointerProblem` already recognizes)
  and raises `message` if it fires, for `fhCreateItem`.

Unlike `pointerProblem`, neither helper returns a suffix to append to a pre-existing message,
there is no separate base message these failures would otherwise need for another reason, so each
owns its whole message, built at the call site to name the field/code being written and, where the
target is identifiable, what it was being written to: a record's own qualified id when the target
is a real record, or the item's own tag when it's a citation/sub-item with no qualified id of its
own (`sourceHelper.lua`'s new local `describeTarget` helper).

Every failure aborts the whole composite call outright via `error()`, with no partial-success
path, matching this codebase's existing validate-then-mutate convention
(`createSourceFromTemplate`'s own design already refuses to leave a partially-created record
behind) rather than introducing a new, first-of-its-kind tolerate-a-partial-write contract.
Because every affected call already lives inside a Read-write-only, `validatedTrackedWrite`-wrapped
function, this `error()` automatically reaches ADR 0005's existing rethrow-for-auto-undo path and
ADR 0012's write tracker (`writeSessionRolledBack: true`), no new rollback plumbing.

## Consequences

- `sourceHelper.lua`'s `setField`/`setStandardField` gain a `code` (and, for `setField`, a
  `callerName`) parameter purely so their shared write-result messages can name which field failed
  and which of the two callers (`createSourceFromTemplate`/`citeSource`) was writing it.
- Every `bridge/tests/*.test.lua` fake for the four `fhSetValueAs*` setters and `fhCreateItem` now
  returns a truthy success value by default (several previously returned nothing, which reads as
  `bOK=false`/a failing `pointerProblem` check the instant a check is added), a pre-existing gap
  in the fakes' fidelity to FH's real contract, exposed rather than caused by this fix. Each
  affected test file gains new fixtures/cases exercising the `false`/NULL failure path.
