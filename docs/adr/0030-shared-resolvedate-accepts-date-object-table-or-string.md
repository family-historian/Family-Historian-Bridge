---
status: accepted
---

# Every write path that sets a Date field shares one resolver, `familyHelper.resolveDate`, accepts a Date object, a table shorthand, or a plain string

`factHelper.createFact` (issue #113) originally required `dtDate` to be a pre-built
`fhNewDate(...)` object, matching `fhu.createFact`'s own raw signature exactly and
documented as such. Live end-to-end verification against Family Historian Sample Project 8
found the obvious failure mode: a plain string like `"1901"`, the natural thing to type,
reached `fhu.createFact`'s own `fhSetValueAsDate(fDate, dtDate)` call unconverted and raised
`"bad argument #2 to 'fhSetValueAsDate' (fh.DATE expected, got string)"`, but only *after*
`fhu.createFact` had already created the Fact item itself. A real write, so it armed ADR
0005's rollback tracker and ended the Session for what should have been a caught-before-
writing input error.

`sourceHelper.lua` already had a partial answer to this: a local `toDate(value)` used by
`createSourceFromTemplate`'s Date-typed template fields and `citeSource`'s `EntryDate`
standard field, accepting either an already-built Date object or a `{year=, month=, day=[,
subtype=]}` table shorthand, but not a string, and not exported for `factHelper.lua` to
reuse.

Decisions:

1. **Widen to accept a plain string too, parsed via FH's own Date object parser.**
   `Date:SetValueAsText(strText, bAllowPhrase)` (confirmed via `fh-help`) parses arbitrary
   text into a real Date value, returning `false` rather than raising on unrecognized input.
   Called with `bAllowPhrase = false` deliberately, an unrecognized string is rejected
   outright, not silently accepted as a free-text date Phrase with no computable date value.
   This is the same class of fix `SetValueAsText`'s existence was already presumably
   designed for, and lets a caller type `"1901"` directly instead of hand-building
   `fhNewDate(1901)`, closing the exact gap that caused the live failure.
2. **Move `toDate` out of `sourceHelper.lua` into `familyHelper.lua`, exported as
   `resolveDate(value, callerName)`.** Same reasoning as `resolvePointer`/`pointerProblem`/
   `checkWrite`/`checkCreated` already living there (docs/adr/0027, docs/adr/0028): a helper
   needed by more than one module belongs in the shared home, not duplicated per module.
   `sourceHelper.lua`'s own two call sites (`setField`'s Date-typed template fields,
   `setStandardField`'s `EntryDate`) switch to `familyHelper.resolveDate`, gaining string
   support for free with no behavior change to their existing Date-object/table inputs.
3. **`factHelper.validateCreateFact` resolves `dtDate` before `M.createFact` ever calls
   `fhu.createFact`**, returning the resolved value alongside the resolved pointer (same
   "validate once, mutate reuses the result" contract `validateCreateSourceFromTemplate`/
   `validateCiteSource` already establish). This is what actually fixes the live bug's
   failure *mode*, not just its input-shape gap: a malformed `dtDate` string now rejects
   cleanly, untracked, before any write, instead of creating the Fact item first and only
   discovering the problem, and rolling back, when `fhu.createFact` itself tries to set the
   `DATE` subfield.
4. **`sourceHelper.lua`'s two call sites do *not* get the same "validate before any write"
   ordering fix.** `setField`/`setStandardField` create their field item via `fhCreateItem`
   *before* calling `resolveDate` inside the same expression that writes it
   (`fhSetValueAsDate(item, familyHelper.resolveDate(value, callerName))`), a pre-existing
   characteristic of `createSourceFromTemplate`/`citeSource`'s per-field create-then-set loop,
   not something this change introduces or was asked to fix. A rejected Date string there
   still leaves the `SOUR` record (or citation) already created, just missing that field and
   any field after it in the loop, confirmed by the new tests covering this case explicitly,
   rather than silently asserting the stronger (and false) "no mutation at all" claim.
5. **`sAge` is out of scope here.** `fhu.createFact`'s own `sAge` parameter is a plain string
   written via `fhSetValueAsText` with no Date-style object involved at all internally
   (confirmed by reading `fhUtils.fh_lua`'s real `createFact` source), a structurally
   different problem from `dtDate`'s wrong-Lua-type risk, deferred for separate handling.

## Consequences

- `factHelper.lua`'s own `createFact` doc comment, `bridge/README.md`'s manual test step 20,
  `CONTEXT.md`'s `createFact` glossary entry, and the `fhbridge-createfact` /
  `run-lua-guidance-createfact-dtdate-must-be-date-object` corpus entries all previously
  stated "`dtDate` must be a real Date object, never a plain string", all four/five now
  say the opposite (a string is accepted, parsed via FH's own parser) and needed correcting,
  not just extending.
- `bridge/tests/familyHelper.test.lua`/`sourceHelper.test.lua`/`factHelper.test.lua` each
  gained a `fhNewDate` fake supporting `dt:SetValueAsText(...)` via `debug.setmetatable` on
  a coroutine (a thread's `type()` stays `'thread'`, genuinely distinct from a plain table,
  the same distinction `resolveDate`'s own `type(value) == "table"` branch, and the original
  `toDate`'s live-confirmed issue #99 fix, both depend on).
