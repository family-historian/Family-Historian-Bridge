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
error response as normal, then re-raise the error so it escapes the timer callback
uncaught into FH's plugin host, giving FH's automatic undo a chance to roll back whatever
the script wrote. Read-only sessions are unaffected — nothing to undo, so they keep the
plain pcall-and-report path with no rethrow. The error response carries an added
`writeSessionRolledBack: true` hint field in this case, framed as a likely outcome rather
than a confirmed one (see Consequences).

## Consequences

- We implement no undo logic of our own anywhere in the bridge or server — rollback is
  entirely FH's native mechanism (Ctrl-Z, or its own automatic undo on an uncaught plugin
  error). Our only job is to not swallow the error that would trigger it.
- **Open risk, unverified**: it's untested whether FH's auto-undo covers an error
  escaping from a timer callback (`timPoll:action_cb`) the same way it covers one escaping
  from the plugin's top-level script body, and whether the Session survives the rethrow
  (timer keeps polling afterward) or FH tears down the whole plugin (ending the Session,
  same as if the user had clicked Stop). Both must be confirmed empirically once
  Read-write is implemented; update this ADR with the observed behavior once known.
- `writeSessionRolledBack: true` is sent on every write-mode script error regardless of
  whether the rethrow actually triggered FH's undo — it's a best-effort claim for Claude
  to relay to the user, not a verified fact about that particular request.
