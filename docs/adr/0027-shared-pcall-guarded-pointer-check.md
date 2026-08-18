---
status: accepted
---

# Pointer-argument validation shares one pcall-guarded check, reused across every helper module

`familyHelper.lua`, `richTextHelper.lua`, `sourceHelper.lua`, and `sessionLogHelper.lua` each
validate a caller-supplied pointer argument with the same copy-pasted idiom: `if not ptr or
ptr:IsNull() then error("<fn>: <arg> must point to ...") end`. Ten call sites share it —
`familyHelper.getFamilyGroup`/`getAncestors`/`getDescendants`/`getAllDetails`/`getFactsByTag`,
`richTextHelper.getTftfText`/`validateSetTftfText`, `sourceHelper.validateCiteSource`/
`getPopulatedTemplateFields`, and `sessionLogHelper.validateLogActivity`. The idiom assumes
that any non-nil value is pointer-shaped enough to support `:IsNull()`. It isn't: a plain
string, a number, a boolean, or a wrong-shaped table (e.g. one of `getFamilyGroup`'s own
`{id, qualifiedId, ...}` descriptor tables, handed back to a function expecting a live pointer)
all raise Lua's own raw "attempt to call/index a ... value" error instead of the function's own
intended message.

Confirmed live (issue #110, 2026-08-15, E40 source-transcription session): a `run_lua` call
passed the action-description string as `fhBridge.logActivity`'s `ptrRecord` (a wrong-arg-shape
mistake, only 1 of the 3 expected args given), and `validateLogActivity` crashed with
`"attempt to call a nil value (method 'IsNull')"` instead of its own "`ptrRecord` must point to
the record this activity concerns" — indistinguishable, from the error text alone, from an
internal bridge crash, and initially misdiagnosed as one. Because an earlier `setTftfText` call
in the same script had already succeeded, this also triggered ADR 0005's full write-session
rollback, discarding that unrelated, otherwise-successful write — the rollback mechanism itself
worked exactly as designed (issue #97's `validatedTrackedWrite`/`validatedTrackedLog` correctly
runs the untracked write's own tracker before `logActivity`'s own validation, so `logActivity`
being wrong didn't *cause* the rollback here); the confusing message is the whole bug.

Decided: one shared `familyHelper.pointerProblem(v)`, reused at all ten sites in place of the
copy-pasted idiom, replacing `if not ptr or ptr:IsNull() then error(msg) end` with `local
problem = familyHelper.pointerProblem(ptr); if problem then error(msg .. problem) end`. Lives in
`familyHelper.lua` because that module already exports `resolvePointer`/`parseQualifiedId` as
shared utilities the other three modules already reuse (`sourceHelper.lua` already
`require()`s it) — the established pattern for this class of helper, not a new one.

`pointerProblem` decides "is this usable?" by `pcall`ing `v:IsNull()`, not by `type()`-checking
`v`. Two alternatives were live-tested (Lua 5.5, empirically, not just reasoned about) against
every bad-type case this fix needs to cover:

- **Bare duck-typing** (`if ptr and ptr.IsNull then ...`, as first proposed in the grilling
  session): field access alone (`ptr.IsNull`) still raises Lua's own raw error for a `number` or
  `boolean` `ptr` — the exact bug class this fix exists to close, just moved to a different
  wrong-typed input than the string in the actual repro.
- **`type()`-gated duck-typing** (`type(v) == "table" or type(v) == "userdata"`, then
  `type(v.IsNull) == "function"`, then call): can be made fully robust, but needs three
  conditions to reach the same coverage `pcall` gets in one, at all 10 call sites — and a real
  Item Pointer's actual Lua type differs between production (`userdata`, FH's own C-side object)
  and this project's own test doubles (Lua tables with an `__index` metatable — every
  `*.test.lua` fake pointer), so the type gate has to allow both anyway.

`pcall` handles every case (string, number, boolean, wrong-shaped table, real pointer, fake
test-double pointer) uniformly with no branching, and is already this codebase's established
idiom for "don't let this specific risky call surface a raw error" (`sessionSettings.lua`'s
`loadOptions`/`saveOptions`).

`pointerProblem` returns `nil` for a valid, non-null pointer; otherwise a string to append to
the caller's own "X must point to Y" message — `""` when `v` is `nil` or a genuinely-null
pointer (the right shape, just empty; the existing plain message already says everything useful
here, and echoing a null pointer's own address teaches the caller nothing), or `" -- got
<type> (<value, truncated to 60 chars>), not a live Item Pointer"` when `v` is any other
wrong-shaped value — the case this fix actually targets, naming what was actually passed so the
mistake is diagnosable from the error text alone. This distinction matters: collapsing both
cases into one enriched message would print a Lua table's raw memory address
(`table: 0x97ac04c60`) for the ordinary, already-well-understood null-pointer case, which is
noise, not diagnostic value.

## Consequences

- Every one of the ten call sites keeps its own existing message wording (`"getFamilyGroup:
  indiPtr must point to an Individual record"`, `"logActivity: ptrRecord must point to the
  record this activity concerns"`, etc.) unchanged — `pointerProblem` only supplies the
  optional suffix, so no existing test asserting on a message substring (e.g. `contains(err,
  "getAncestors")`) needed to change.
- `richTextHelper.lua` and `sessionLogHelper.lua` now `require('familyHelper')`, a new
  dependency edge each (previously neither required it). `familyHelper.lua` itself has no
  `require`s of its own, so this introduces no cycle.
- The `gedcom-knowledge-corpus`'s `run-lua-guidance-call-shape-gotchas` entry gets one new
  bullet naming this failure mode, since `run-lua-guidance-log-activity`/`fhbridge-logactivity`
  already documented `ptrRecord`'s type contract correctly before this issue was filed — the
  issue's claim of a missing/dangling corpus entry was stale, not a real gap.

## Addendum: `logActivity`'s `ptrRecord` must be a record, not a Fact/sub-item

**Superseded in part by docs/adr/0031-logactivity-auto-corrects-fact-pointer-to-owning-record.md**:
a live incident (issue #117) showed this addendum's outright rejection landing on the very last
call of a multi-step write, triggering ADR 0005's full rollback for what was really just a
targeting mistake. ADR 0031 replaces the `error(...)` this addendum added with a silent climb to
the owning record via `ptr:MoveToRecordItem(ptr)`. The rest of this addendum — *why* a bare pointer
check isn't the whole contract, and `fhHasParentItem`'s role in telling a record apart from a
Fact/sub-item — still describes the mechanism ADR 0031 builds on, so it's left as history below
rather than rewritten.

A live pointer isn't the whole contract for `sessionLogHelper.logActivity(ptrRecord, ...)` —
its own doc comment already said `ptrRecord` is always "the record" an action concerns (a Fact
goes in the `action` string instead, e.g. `action = "fact added " ..
fhGetDisplayText(ptrFact)`, per the existing `run-lua-guidance-log-activity` corpus entry), but
nothing enforced it. A caller passing a Fact/sub-item pointer by mistake would still reach
`RichText:AddRecordLink`, which accepts any live pointer — producing a "successful" call and a
real, permanently-saved log entry, just linking to the wrong (or a meaningless) thing, with
nothing to signal the mistake.

`fhHasParentItem(ptr)` is FH's own documented mechanism for this exact distinction ("record
items do not have parent items, but all other items (i.e. field items) do"). Added as a second
check in `validateLogActivity`, after `pointerProblem`: `if fhHasParentItem(ptrRecord) then
error(...) end`. Scoped to `logActivity` only — `citeSource`'s `ptrTarget` is deliberately
polymorphic (an INDI/FAM record *or* any Fact item, ADR 0006), so the same check would reject
valid calls there; `setTftfText`'s `ptr` is always expected to be a field (never a record), the
opposite constraint.

Considered and deferred to a separate issue: none of this project's `fhSetValueAs*` write calls
(`fhSetValueAsRichText`/`fhSetValueAsText`/`fhSetValueAsDate`/`fhSetValueAsLink`, ~15 call sites
across `sourceHelper.lua`/`sessionLogHelper.lua`/`richTextHelper.lua`) check their own `bOK`
return value — FH's documented, non-throwing way of reporting a write that silently didn't
happen (confirmed by this project's own history: `sessionLogHelper.lua`'s own comment records
`fhSetValueAsRichText(notePtr, ...)` once silently returning `false` and writing nothing, before
the code was fixed to target the right child item instead). That's a separate, systemic finding
— broader than a pointer-shape check, and needs its own scoping decision — not folded in here.
