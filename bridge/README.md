# Bridge plugin

The FH-side half of the MCP bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `Claude MCP Bridge.fh_lua` — the plugin itself: IUP dialog (Access-mode selector, Start/Stop, idle
  auto-Stop timer), TCP listener, request framing.
- `requestFraming.lua` — parses a request's first line (`STOP` / `LUA <n>` / `LUA_RO <n>`)
  into a structured form; `LUA_RO` forces the Read-only sandbox regardless of the
  Session's own Access mode (issue #16 — used exclusively by `describe_project`).
- `runScript.lua` — compiles and runs a submitted script inside the sandbox (guarded by
  the watchdog), returns a JSON-encoded result or error.
- `sandbox.lua` — builds the allowlist `_ENV` a script executes inside.
- `jsonEncode.lua` — hand-rolled JSON encoder (FH's Lua ships none).
- `watchdog.lua` — aborts a script that exceeds an instruction budget, so an accidental
  infinite loop can't hang FH with no recovery path.
- `sourceHelper.lua` — `fhBridge.createSourceFromTemplate(...)` (issue #18), a read-write-
  only helper that creates a fully populated templated Source record in one call instead of
  hand-assembling the `_SRCT`-link + metafield-shortcut dance every time. Wired into the
  sandbox by `sandbox.lua` alongside the rest of the write API — see
  `docs/superpowers/specs/2026-07-30-createSourceFromTemplate-design.md`. Also exposes
  `fhBridge.citeSource(ptrTarget, sourceIdOrTitle)`, attaching a `SOUR` citation to any
  target item (an INDI/FAM record for a Whole-record citation, or a Fact item) instead of
  hand-assembling `fhCreateItem("SOUR", ...)` + `fhSetValueAsLink` — see
  `docs/adr/0006-cite-every-fact-a-source-supports.md`.

`requestFraming.lua`, `runScript.lua`, `sandbox.lua`, `jsonEncode.lua`, `watchdog.lua`, and
`sourceHelper.lua` have standalone unit tests, in `tests/` (`*.test.lua`, run with a plain
`lua` interpreter — no FH dependency). Keeping tests out of this folder means every file
directly in `bridge/` is exactly what step 1 below copies — nothing to filter by name:

```bash
lua bridge/tests/jsonEncode.test.lua
lua bridge/tests/sandbox.test.lua
lua bridge/tests/watchdog.test.lua
lua bridge/tests/runScript.test.lua
lua bridge/tests/requestFraming.test.lua
lua bridge/tests/sourceHelper.test.lua
```

`Claude MCP Bridge.fh_lua` itself (the socket/IUP dialog plumbing) has no automatable seam — FH is
proprietary and Windows/CrossOver-only. It's tested manually, inside FH:

## Manual test

1. Copy every file directly in this folder (not the `tests/` subfolder) into FH's Plugins
   folder (so `require()` can find the sibling modules) —
   `C:\ProgramData\Calico Pie\Family Historian\Plugins\` on native Windows, or the
   equivalent path under CrossOver's virtual C: drive on Mac.
2. In FH: Tools -> Plugins -> New, open `Claude MCP Bridge.fh_lua` from that folder, click Run.
3. A small "FH Bridge" dialog appears with a Read-only/Read-write selector (Read-only
   selected by default) and Start/Stop buttons. Confirm the selector is clickable, then
   click Start. Confirm the selector greys out (inactive) once the Session is running, and
   the status label shows the chosen mode, e.g. "Listening on 127.0.0.1:8734 (read-only)".
   Click Stop and confirm the selector becomes clickable again. Select Read-write, click
   Start again, and confirm the status label now shows "(read-write)" — Sandbox behavior
   is unchanged either way this stage, so only the label/lock differs. Click Stop.
4. Resize: drag the dialog wider and taller. Confirm the status label's text isn't
   truncated at the new width, and that the Start/Stop buttons stay pinned to the bottom
   of the dialog rather than floating in the middle. Try shrinking it back down and
   confirm it stops shrinking while the buttons are still fully visible (the MINSIZE
   floor) instead of letting them go off-screen (issue #12).
5. From a terminal, send a trivial script and confirm the JSON comes back correctly:
   ```bash
   python3 -c "
   import socket
   script = b'return {ok=true, echoed=42}'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `{"ok":true,"echoed":42}`
6. Try a script that errors, and confirm it comes back as a JSON error instead of
   crashing the Session (the dialog should still show "Listening..." afterward):
   ```bash
   python3 -c "
   import socket
   script = b\"error('deliberate test failure')\"
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object containing `"error"` and `"deliberate test failure"`.
7. Try a deliberately runaway script and confirm the watchdog aborts it — the dialog
   should stay responsive, and this should return within a few seconds rather than
   hanging FH:
   ```bash
   python3 -c "
   import socket
   script = b'while true do end'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object containing `"error"` and `"instruction limit"`.
8. Click Stop (or send `STOP\n` the same way as the prototype's original test) — FH
   should become interactive again immediately.
9. Idle-timeout auto-Stop: temporarily lower `IDLE_TIMEOUT_SECONDS` near the top of
   `Claude MCP Bridge.fh_lua` (e.g. to `10`) for a fast test, reload the plugin, click Start, then
   leave the Session idle (no request sent) past that duration. Confirm the dialog
   auto-returns to "Not listening." and the selector becomes clickable again, with no
   request sent and without clicking Stop. Restore `IDLE_TIMEOUT_SECONDS` to its real value
   (`300`) afterward.
10. FH read allowlist: with a real FH project open and a Session started (read-only),
   confirm `fhu.records("INDI")` and the raw primitives are actually wired up against
   real data — count every `INDI` record and cross-check against FH's own count (e.g.
   Tools -> Reports, or the project's Individual count shown elsewhere in FH's UI). The
   script below assumes `fhu.records(tag)` is a for-in iterator, per fhUtils' own docs
   (this repo doesn't bundle fhUtils — it ships with every FH install, see issue #1's
   "fhUtils dependency" note) — adjust the loop shape if that's wrong:
   ```bash
   python3 -c "
   import socket
   script = b'local n = 0; for indi in fhu.records(\"INDI\") do n = n + 1 end; return n'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a bare number matching FH's own count of Individuals in the open
   project.
11. FH write allowlist (issue #14): with a real FH project open, select Read-write, click
   Start, then create an Individual and set a field on it, confirming the change lands in
   the open project (check FH's own tree/Individual list after the script runs):
   ```bash
   python3 -c "
   import socket
   script = b'''
   local ptr = fhCreateItem(nil, \"INDI\")
   fhSetValueAsText(ptr, \"NAME\", \"Test /Person/\")
   return fhGetItemText(ptr, \"~\")
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON string, and a new Individual named "Test /Person/" visible in
   FH once you look at the project (undo with Ctrl-Z to clean up — see CONTEXT.md "FH
   auto-undo"). Then repeat with Read-only selected instead and confirm the same script
   now fails with a JSON error calling a nil value (`fhCreateItem` absent).
12. `describe_project` forced Read-only (issue #16): with a Read-write Session started,
   send a `LUA_RO` request directly (this is what `describeProjectTool.ts` sends) and
   confirm it still cannot reach a write function, even though the Session itself is
   Read-write:
   ```bash
   python3 -c "
   import socket
   script = b'return fhCreateItem'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(('LUA_RO %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `null` (`fhCreateItem` is `nil` in the forced Read-only sandbox).
   Confirm a plain `LUA` request in the same Read-write Session returns something other
   than `null` for the same script, proving the two forms genuinely differ.
13. `fhBridge.createSourceFromTemplate` (issue #18): with a real FH project open that has a
   Source Template you can use (the example below uses "Civil Registration Certificate"
   with a "Type" field, per the "Civil Registration Certificate" template used for source
   #41 in this project — substitute a template name and field code/value that actually
   exist in your own project's Source Templates otherwise), select Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local result = fhBridge.createSourceFromTemplate(\"Civil Registration Certificate\", { Type = \"Birth\" }, \"Test transcription\")
   return result
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON object with `id` and `title`. Confirm in FH's own UI that a new
   Source record now exists, linked to the chosen template, with its `Type` field set to
   "Birth", a "Text from Source" of "Test transcription", and an auto-generated title
   (undo with Ctrl-Z to clean up — see CONTEXT.md "FH auto-undo"). Then repeat with
   Read-only selected instead and confirm the same script now fails calling `fhBridge` as
   nil, the same way any other write attempt does (step 11's negative case).
14. `fhBridge.citeSource` (issue #18 follow-up, ADR 0006): with a real FH project open that
   has at least one Source record (the example below cites Source #41 in this project's own
   tree — substitute a Source record id/title that actually exists in yours), select
   Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   local p = fhNewItemPtr()
   p:MoveToFirstRecord(\"INDI\")
   while p:IsNotNull() and fhGetRecordId(p) ~= 124 do p:MoveNext() end
   fhBridge.citeSource(p, 41)
   return \"ok\"
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: `"ok"`. Confirm in FH's own UI that the Individual now has a new
   Whole-record source citation to the chosen Source (undo with Ctrl-Z to clean up). Then
   repeat with Read-only selected instead and confirm the same script now fails calling
   `fhBridge` as nil (step 11's negative case).
15. Write-mode error handling / FH auto-undo (issues #15, #19, ADR 0005): with a real FH
   project open, select Read-write, click Start:
   ```bash
   python3 -c "
   import socket
   script = b'''
   fhu.createIndi(\"ZZ_MANUAL_TEST_ROLLBACK\", \"Male\")
   error(\"deliberate error after write, manual test\")
   '''
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a JSON error object containing `"writeSessionRolledBack":true`. FH
   should then pop its own "Plugin Error" dialog naming the same error, asking "Do you
   wish to rollback (i.e. undo) all changes to data records made by this plugin?" — click
   Yes and confirm the new Individual is gone. The Bridge Session ends as part of this (the
   dialog closes, the socket stops listening) — reopen the plugin via Tools -> Plugins and
   click Start again before the next step.

   Negative case (nothing written before the error): same setup, but a script that never
   calls a write function first —
   ```bash
   python3 -c "
   import socket
   script = b'error(\"boom, nothing written first\")'
   s = socket.create_connection(('127.0.0.1', 8734), timeout=15)
   s.sendall(('LUA %d\n' % len(script)).encode() + script)
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Expected output: a plain JSON error object with no `writeSessionRolledBack` field, no
   FH dialog, and the Session still listening afterward — send a trivial script (step 5)
   again on the same Session to confirm it's still up.

   Read-only case: repeat the first script (the one that calls `fhu.createIndi`) with
   Read-only selected instead of Read-write. Expected output: a JSON error calling
   `fhu.createIndi` as nil (step 11's negative case) — `fhu`'s write methods are gated the
   same way the raw write primitives are, so nothing is ever written and there's nothing
   for FH to roll back.
