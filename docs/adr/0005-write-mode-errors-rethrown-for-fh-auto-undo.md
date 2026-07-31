---
status: accepted
---

# Write-mode script errors are re-thrown after responding, so FH's own auto-undo can fire

`runScript.lua` currently `pcall`s every script and converts any error into a clean JSON
response — the right behavior for Read-only, where a failed script can't have mutated
anything. Read-write changes that: a script can fail partway through a sequence of writes
(e.g. `fhCreateItem` succeeds, a later `fhSetValueAsText` throws), leaving a partial,
inconsistent edit in the user's tree. FH itself audits every project-data change a Lua
plugin makes and automatically undoes that plugin's changes when an uncaught Lua error
escapes it — but only if the error actually escapes uncaught. Swallowing it in `pcall`, as
today's code does unconditionally, means that safety net never engages; only the user's
manual Ctrl-Z would clean up the partial write, and only if they notice.

Decided: in a read-write Session, after a script error is caught, build and send the JSON
error response as normal, then end the whole plugin with the error uncaught, giving FH's
automatic undo a chance to undo whatever the script wrote. This only happens when the
script actually called a tracked write primitive before erroring (`sandbox.lua`'s write
tracker, added during the design of this ADR's fix — see History below); a write-mode
script that errors before writing anything behaves exactly like Read-only. Read-only
Sessions never have anything to undo, so they always keep the plain
pcall-and-report path with no rethrow, no tracker, no plugin-ending. The error response
carries an added `writeSessionRolledBack: true` hint field when a tracked write did
happen (see Consequences for what that field actually promises).

## History: what "escapes uncaught" actually required

The first implementation just re-raised the error from inside the polling timer's
callback (`timPoll:action_cb`) and left the Session running. Verified empirically
(2026-07-31, issue #15, against a real FH8/CrossOver install) that this **does not**
work: FH's auto-undo never triggered, the written record stayed in the tree, and the
Session survived the error untouched — IUP's own callback dispatch swallows an error
raised inside a callback before it ever reaches whatever wraps the plugin's own top-level
execution, which is what FH's auto-undo actually watches.

The fix: end the whole plugin. `timPoll:action_cb` stops the network side (the same path
STOP already uses) and returns `iup.CLOSE`, which is IUP's documented way for a callback
to end `iup.MainLoop()` — safe here specifically because FH itself is not IUP-based (only
plugins are), so this plugin process is always the sole owner of any loop it starts.
Control then falls through to the code after `iup.MainLoop()`, which re-raises the saved
error there — genuinely at the top level, uncaught, past every other statement in the
plugin file.

Re-verified against the same real FH8/CrossOver install with this redesign: **it works**.
FH shows its own "Plugin Error" dialog naming the exact error, with a Yes/No prompt —
*"Do you wish to rollback (i.e. undo) all changes to data records made by this
plugin?"*. Clicking Yes removed the test record; a record count taken before and after
confirmed it (110 → 111 → 110). The Session does not survive this — ending the plugin
this way is equivalent to the user closing it, and a new Session has to be started from
Tools -> Plugins (or the FH Tools-menu entry) afterward.

## Consequences

- We implement no undo logic of our own anywhere in the bridge or server — undoing a
  partial write is entirely FH's native mechanism (Ctrl-Z, or its own automatic undo on an
  uncaught plugin error, confirmed above). Our only job is to not swallow the error that
  would trigger it, and to actually let it reach the plugin's top level rather than dying
  inside a callback.
- FH's "automatic" undo is not silent — it's a Yes/No confirmation dialog on FH's own
  screen. A human has to be present to click it, same caveat as any other write-mode
  script error (a live, attended read-write Session is already assumed).
- Ending the whole plugin on a write-mode error-with-a-write is a real cost (the user has
  to reopen the Bridge to start a new Session), accepted deliberately (2026-07-31
  grilling session) because it's the only way that actually reaches FH's real safety net —
  the alternative (keep the Session alive, as the first implementation did) provably never
  gives FH's auto-undo a chance to fire at all.
- `writeSessionRolledBack: true` is sent whenever the write tracker fired, and the
  mechanism that triggers it (ending the plugin with the error uncaught) is now confirmed
  to reach FH's real auto-undo prompt. It is not a guarantee the write was actually undone
  for that particular request, though — FH's undo is a human-driven Yes/No dialog, not a
  silent action, so the field is Claude's cue to tell the user to go look for that dialog
  and click Yes, not a claim that the undo has already happened on its own.
