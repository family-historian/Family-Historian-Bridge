# Enforce write-then-log via a static pre-scan plus a runtime backstop, not auto-wrapping

ADR 0010 steers Claude to call `fhBridge.logActivity` after every record-touching action
in a Read-write Session, purely from `run_lua`'s tool description. Testing that feature on
a fresh Claude instance (issue #42) found it never called `logActivity` at all, not a
partial miss, a full no-show. ADR 0011 shrank the tool description to work around one
cause (deferred-loading MCP clients silently truncating long descriptions), but left the
underlying problem untouched: prompt-text steering is inherently optional, since it only
fires if the model reads and acts on it. Issue #42 explored baking the logging call
directly into the sandbox layer (auto-wrapping every `fhu` write method so a log entry is
produced mechanically, with zero dependence on any instruction surviving) as the fix.

A 2026-08-02 grilling session on issue #42 decided against that. Auto-wrapping guarantees
*a* log entry exists, but it can only ever be mechanical ("createIndi called" + a record
pointer), it cannot supply the "rich" part of a rich research log, which is inherently
Claude's own reasoning about *why* a record was created or what source justified it, not
something a generic per-function wrapper can derive. Auto-wrapping was also the source of
issue #42's two open sub-questions (scope: `fhu` write methods only, or also the raw `fh*`
write primitives; and a per-function "describer," since each write method's argument shape
differs), both of which only exist because auto-wrapping needs to manufacture a
description at all.

## Decided

Enforce the write-then-log invariant instead of auto-generating the log entry, in two
layers:

1. **Static pre-scan**, in `runScript.lua`'s `M.run`, run on `scriptText` right after
   `load()` succeeds and before `pcall(chunk)`, i.e. before any write can possibly reach
   the live FH tree. Pattern-matches the script's source text against the union of
   `sandbox.lua`'s existing `FHU_WRITE_METHOD_NAMES` and `WRITE_PRIMITIVE_NAMES` lists (no
   new list needed, enforcement doesn't care *which* write function fires, only whether
   `logActivity` was also called). Rejects the script outright, before it ever runs, when:
   - `accessMode == "read-only"` and any write name appears in the text, replacing
     today's unhelpful failure mode (those names are simply absent from `env` under
     Read-only, so a call currently fails as a raw `attempt to call a nil value` Lua error)
     with a clear "this script calls write functions while the bridge is read-only"
     message.
   - `accessMode == "read-write"`, a write name appears in the text, and `logActivity`
     never appears anywhere in the text.
   This catches the common case, a full no-show, exactly issue #42's original bug, for
   free, with no rollback needed, since nothing has executed yet.

2. **Runtime end-of-script check**, as the ground-truth backstop for what the static scan
   can't see (text presence isn't proof of execution, dead code, e.g. `logActivity`
   inside an `if false then` branch; partial logging, e.g. three `createIndi` calls but
   only one `logActivity` call; indirection through a variable). `sandbox.lua`'s tracker
   gains a second flag, `tracker.logged`, set by a dedicated wrapper around
   `fhBridge.logActivity`, split out from the generic `trackedWrite` wrapper it currently
   shares with every other write primitive, which conflates "wrote to the tree" with
   "called `logActivity`" and can't currently tell them apart. After the script finishes,
   if `tracker.wrote` is true and `tracker.logged` is false, `error()`, feeding the
   existing ADR 0005 path (error re-thrown after responding, ending the plugin, giving
   FH's own auto-undo a chance to fire; response carries `writeSessionRolledBack: true`).

`fhBridge.logActivity` stays directly callable by Claude regardless, the outstanding-media
`#ToDo` case (ADR 0010, point 4) needs Claude's own judgment about the conversation (was a
photo mentioned but never attached?), which no write-tracking mechanism can derive from the
write API alone.

## Consequences

- Issue #42's two open sub-questions dissolve rather than needing further decisions:
  scope is now "every write name in both lists, uniformly," since enforcement doesn't
  branch by function; per-function description derivation no longer applies, since there
  is no auto-generated description, every log entry stays Claude-authored, and richness
  is preserved rather than trading it away for mechanical guarantees.
- A write that lands but goes unlogged is not merely warned about, it costs the user a
  full plugin Session restart (ADR 0005's existing rollback cost), same as any other
  write-mode script error. Accepted as the price of the guarantee; expected to become rare
  as the pre-scan already screens out the common full-no-show case before execution.
- Not decided here, left to implementation: the exact Lua pattern(s) used for name
  matching in the static scan (needs care to avoid false positives on a write-function
  name appearing inside a comment or string literal, and false negatives from
  indirection, accepted as a fast-fail heuristic layer, not a security boundary, since
  the runtime check is the actual ground truth).
