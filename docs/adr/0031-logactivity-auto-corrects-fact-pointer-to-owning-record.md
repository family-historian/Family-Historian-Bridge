---
status: accepted
---

# `logActivity` auto-corrects a Fact/sub-item `ptrRecord` to its owning record instead of erroring

ADR 0027's addendum added a check to `sessionLogHelper.validateLogActivity`: if `ptrRecord` is a
Fact or other sub-item (`fhHasParentItem(ptrRecord)` true) rather than a top-level record, reject
it outright, reasoning that an unnoticed Fact pointer would still reach `RichText:AddRecordLink`
and produce a "successful" log entry linking to the wrong (or a meaningless) thing, with nothing
to signal the mistake.

Confirmed live (issue #117): that check does its job correctly, but at the worst possible point
in a write script's lifetime. A `run_lua` script that had already done the real work of a
multi-step write — created an Individual, linked it into a Family, added a census Fact — passed
that just-created Fact's own pointer to `logActivity` on the script's very last call, instead of
the Individual it belonged to. `validateLogActivity` rejected it, exactly as ADR 0027 designed.
But `logActivity` is required after every write in the same script (issue #43's write-then-log
invariant), and any error escaping a write-mode script triggers ADR 0005's rollback path — FH's
own auto-undo discarded the whole script's work, not just the bad `logActivity` call. A pointer
targeting mistake in the one call that never touches the tree's own data cost the same as a real
data mistake.

## Decision

`validateLogActivity` no longer errors on a Fact/sub-item `ptrRecord`. It climbs to the item's
owning record instead, via `ptr:MoveToRecordItem(ptr)` — FH's own documented mechanism for
exactly this ("Moves this pointer to point to the record item, to which a given item belongs")
— and proceeds with the climbed-to pointer.

This is judged safe to do *silently*, reversing ADR 0027's "nothing to signal the mistake"
concern rather than just softening it, for a reason specific to what `MoveToRecordItem` actually
does: it can only ever resolve to the passed item's own real owning record — never a different
one, never a guess. It corrects a "right record, wrong item within it" mistake; it has no way to
paper over a "wrong record entirely" mistake, which remains exactly as loud a failure as before
(a wrong record's own Fact still climbs to that same wrong record — `logActivity` was never able
to detect that class of error, with or without this change). Given that ceiling on what the
correction could possibly get wrong, and given the concrete cost just observed when it fails
instead of correcting, silent correction won out over adding a signal (a note annotation, a
return-value flag) that nothing downstream was designed to consume.

Scope: applies at any depth, not just a Fact directly under a record — a citation, a `DATA`
subfield, anything `fhHasParentItem` already flagged as non-record. `MoveToRecordItem` climbs as
far as needed regardless of depth, and the same "can only resolve to that item's real owner"
safety argument holds at every depth.

As a defensive backstop — not the expected path, since `MoveToRecordItem` should always resolve
to a real record for any genuine FH item — `validateLogActivity` re-runs the same
`pointerProblem`/`fhHasParentItem` checks once more after climbing. A pointer shape bizarre
enough that the climb doesn't land on a clean, top-level record still produces this function's
own clear error, rather than reaching `AddRecordLink` with a broken pointer and failing there
with a confusing, disconnected message.

Note that `MoveToRecordItem` mutates the pointer object it's called on in place (per FH's own
docs: "Moves *this* pointer..."), not a copy — a caller that holds onto the original `ptrRecord`
object after calling `logActivity`/`validateLogActivity` will find it now pointing at the
climbed-to record, not the original item. In practice this is never observed to matter: every
`run_lua` script this project has seen passes a pointer straight into `logActivity` inline (fresh
off `fhCreateItem`/`fhGetValueAsLink`/etc.) and never reuses that same pointer object afterward.

That mutate-in-place side effect does still need to respect `validateLogActivity`'s own
long-standing contract of validating everything up front, before touching anything (its own
doc comment: the buffer is module-level state a bad call shouldn't be allowed to leave in an
inconsistent partial state). The climb is therefore ordered *after* the `action`/`media`
checks, not immediately next to the `fhHasParentItem` check that decides whether it's needed —
a call that's going to error on a bad `action`/`media` anyway must leave the caller's Fact
pointer exactly as passed, not climb it first and still fail (caught in code review, before
merge, with its own regression test in `sessionLogHelper.test.lua`).

## Consequences

- `sessionLogHelper.test.lua`'s fake `MoveToRecordItem` walks a fixture node's `.parent` chain to
  the top, the same way the real API climbs the item tree — added alongside the existing
  `fhHasParentItem`/`MoveToRecordById` fakes.
- The `fhBridge-logactivity` corpus entry and this file's own `CONTEXT.md` `logActivity` entry
  are updated to say `ptrRecord` accepts a Fact/sub-item pointer as a convenience, not just a live
  record pointer or a qualified id string.
- Scoped to `logActivity` only, same as ADR 0027's addendum was — `citeSource`'s `ptrTarget`
  already accepts a Fact deliberately (ADR 0006, a Fact-level citation is a different, valid
  target from a Whole-record citation, not a mistake to correct); `setTftfText`'s `ptr` is always
  expected to be a field, the opposite constraint. Neither of those needs or wants this climb.

## Known limitation: a Shared Fact's `_SHAR`/`_SHAN` witness pointer climbs to the wrong record

This decision's own safety argument ("`MoveToRecordItem` can only ever resolve to the passed
item's own real owning record, never a different one") is true about *storage* ownership, not
necessarily about which record the caller meant. Per the `shared-facts` corpus entry, a Shared
Fact's participants (`_SHAR`/`_SHAN`) sit as children of the *fact* item itself — which belongs
to the fact's principal(s), not to a witness participant. A script that obtained a live pointer
into that structure while working with a witness Individual (rather than the fact's principal)
and passed it to `logActivity` would have that pointer climb to the *principal's* record, not the
witness's — silently producing a record link against the wrong Individual, with nothing to signal
it, since the climb genuinely does resolve to a real, valid record.

This is a real gap in the "can't paper over a wrong-record mistake" claim above, found in code
review (issue #117) — but fixing it needs `validateLogActivity` to distinguish "the record I
climbed to" from "the record the caller was actually working with," which it has no way to know
from `ptrRecord` alone. No `run_lua` script has been observed passing a witness's own `_SHAR`
item to `logActivity` (every real script this project has seen passes a Fact pointer belonging to
its own principal, e.g. straight off `fhu.createFact`), so this is deferred rather than blocking
the fix above. Flagged for its own follow-up rather than addressed here.
