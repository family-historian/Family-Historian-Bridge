# Private/Living Visibility settings filter fhBridge helpers only, not raw run_lua

Issue #141 added a per-flag Visibility level (Exclude/Name Only/All) for the Private and
Living Record Flags, enforced inside every `fhBridge.*` helper (`getFamilyGroup`,
`getAncestors`, `getDescendants`, `findByNames`, `getAllDetails`, `getFactsByTag`, and the
write helpers `createFact`/`citeSource`/`logActivity`/`setTftfText`). A `run_lua` script can
still reach the same data through raw `fh*` globals or `fhu.*` — `MoveToFirstRecord`/
`MoveNext`, `fhGetItemText`, `fhu.records`/`allItems`/`indiList`, etc. — none of which
consult Visibility settings at all.

**Decision: this stays unfiltered by design, not a gap slated to close later.** Closing it
would mean proxying or auditing FH's entire native Lua API surface for every function that
can read a record's fields — the same open-ended surface ADR 0001 deliberately left
reachable so `run_lua` could answer arbitrary questions without a protocol change each time.
Filtering raw `fh*`/`fhu` calls would mean either maintaining a parallel filtered wrapper for
functions with no `fhBridge` equivalent yet, or narrowing `run_lua`'s sandbox to only the
`fhBridge` surface — both reverse ADR 0001's own trade-off, not extend it.

**Trust model stays what ADR 0001 already established.** A user who Starts a Session with
Access mode read-write has already accepted that Claude-authored Lua runs with that same
level of trust; Visibility settings shape what the *intended, documented* `fhBridge.*` API
returns for a Private/Living Individual, they are not a sandbox boundary against a
deliberately adversarial script. Same class of "mitigated, not closed" as the sandbox's own
allowlist/watchdog framing in ADR 0001 — a defense against inadvertent oversharing through
normal use, not a guarantee against a script written specifically to defeat it.

**Mitigation, not closure: `bulkEnumerationViolation`.** `runScript.lua`'s pre-scan (added
in slice 5 of #141) rejects a script outright, before `load()` ever runs, if it mentions
`MoveToFirstRecord`, `fhu.records`, `fhu.allItems`, or `fhu.indiList` while either Visibility
level is restricted — the bulk-enumeration idiom that would otherwise let a script cheaply
walk every record's raw fields regardless of Visibility. This narrows the loophole (a script
can no longer trivially enumerate the whole tree unfiltered) without pretending to close it:
a script that already knows a specific record's pointer or tag can still read its raw fields
directly, one record at a time, since the pre-scan only recognizes the enumeration idiom by
name, not by what a script does with a pointer it already has. `run_lua`'s tool description
and the `run-lua-guidance-visibility-settings` corpus entry both steer Claude toward the
filtered `fhBridge.*` helpers instead, but neither is a technical enforcement of that choice.

**`describe_project`/`install_fh_plugin`'s own fixed internal scripts are exempt from both
the pre-scan and Visibility filtering generally** (`bridgeSession.lua`'s `request.forceReadOnly`
handling — `privacySettings` is passed as `nil`, not the Session's actual setting, whenever
`forceReadOnly` is set). These are fixed source reviewed as part of this bridge, not
user-supplied `run_lua` text, so they sit outside the trust boundary this ADR is about;
`describe_project`'s own record census relies on raw `MoveToFirstRecord`, so filtering it
would break that tool outright the moment a user restricts a Visibility level, for no
safety benefit (there is no free-text script here for the setting to guard against).

## Consequences

- Reversing this decision (closing the gap for real) would mean either proxying every
  record-reading `fh*`/`fhu` function through a Visibility check, or dropping raw `fh*`/`fhu`
  access from `run_lua`'s sandbox entirely — both are direct reversals of ADR 0001's central
  trade-off, not incremental extensions of it. Flagging that cost explicitly is this ADR's
  main job: a future proposal to "just filter the rest" should read this first.
- A restricted Visibility level auto-forces Debug logging on for the Session (`bridgeSession.lua`,
  #141 slice 6) — since raw enumeration can still happen, the Session's own log stays the
  fallback record of what a script actually read/wrote while a restriction is nominally in
  effect.
- Any new `fhBridge.*` helper that reads record fields must apply `familyHelper`'s Visibility
  check the same way the existing helpers do — the guarantee this ADR describes is scoped to
  "everything under `fhBridge`", not "everything read-only". A helper added without that
  check would silently widen the unfiltered surface this ADR accepts, without the
  compensating "documented and steered against" framing raw `fh*`/`fhu` calls get.
