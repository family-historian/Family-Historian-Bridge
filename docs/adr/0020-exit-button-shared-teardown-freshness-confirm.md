# Exit button: shared teardown with the window X, confirm only on recent activity

Issue #77 asked for a third "Exit" button on the Bridge dialog, equivalent to clicking the
window's X, and asked to double-check the X already closes the socket gracefully. It didn't;
`close_cb` only called `server:close()` directly, skipping the rest of `btnStop:action()`'s
teardown (stopping `timPoll`, clearing `lastActivityTime`, resetting the toggle/timeout
controls). Rather than have Exit duplicate that gap or fix it in one path but not the other,
both X and Exit now call one shared `stopSessionIfRunning()` — the session-ending part of
`btnStop:action()`, minus the "return to Start-ready UI" reset that's pointless when the whole
plugin is about to close.

We also considered a confirmation prompt before Exit/X closes a running Session, so a Session
isn't yanked away while Claude might still be mid-conversation. The original ask was to confirm
whenever "a script is active." That state is unobservable at click time: `runScript.run()`
executes synchronously inside `timPoll:action_cb()`, and IUP's mainloop dispatches one callback
to completion before the next, so a button click can never be processed while a script is
running — the UI is simply unresponsive for that stretch. We use a freshness heuristic instead:
prompt (Yes/No, cancel-on-No) only if a Session is running *and* `now - lastRequestHandledTime`
is under a hardcoded 10s (`RECENT_ACTIVITY_CONFIRM_SECONDS`) — the only real proxy available for
"a request just finished, another might be coming." Session-idle-but-running, or no Session at
all, closes immediately with no prompt. The gate applies only to Exit/X, not to the existing
Stop button, which was out of scope for issue #77 and already a known, low-ceremony action.

`lastRequestHandledTime` is a second, deliberately separate clock from the pre-existing
`lastActivityTime` (used for the idle-timeout auto-Stop). `lastActivityTime` is also stamped at
Start itself, before any request has arrived; reusing it for the confirm check would have warned
on Start-then-immediately-Exit with no request ever handled. `lastRequestHandledTime` is stamped
only inside the three real request branches (`stop`/`version`/`lua`) in `timPoll:action_cb`, and
cleared alongside `lastActivityTime` in `stopSessionIfRunning()`.

Hardcoded rather than a configurable field like the idle timeout: this is a safety-net nudge,
not a session parameter users need to tune.
