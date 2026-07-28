# Bridge plugin

The FH-side half of the MCP bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `bridge.fh_lua` — the plugin itself: IUP dialog (Access-mode selector, Start/Stop, idle
  auto-Stop timer), TCP listener, request framing.
- `runScript.lua` — compiles and runs a submitted script inside the sandbox (guarded by
  the watchdog), returns a JSON-encoded result or error.
- `sandbox.lua` — builds the allowlist `_ENV` a script executes inside.
- `jsonEncode.lua` — hand-rolled JSON encoder (FH's Lua ships none).
- `watchdog.lua` — aborts a script that exceeds an instruction budget, so an accidental
  infinite loop can't hang FH with no recovery path.

`runScript.lua`, `sandbox.lua`, `jsonEncode.lua`, and `watchdog.lua` have standalone unit
tests (`*.test.lua`, run with a plain `lua` interpreter — no FH dependency):

```bash
lua bridge/jsonEncode.test.lua
lua bridge/sandbox.test.lua
lua bridge/watchdog.test.lua
lua bridge/runScript.test.lua
```

`bridge.fh_lua` itself (the socket/IUP dialog plumbing) has no automatable seam — FH is
proprietary and Windows/CrossOver-only. It's tested manually, inside FH:

## Manual test

1. Copy all five files in this folder into FH's Plugins folder (so `require()` can find
   the sibling modules) — `C:\ProgramData\Calico Pie\Family Historian\Plugins\` on native
   Windows, or the equivalent path under CrossOver's virtual C: drive on Mac.
2. In FH: Tools -> Plugins -> New, open `bridge.fh_lua` from that folder, click Run.
3. A small "FH Bridge" dialog appears with a Read-only/Read-write selector (Read-only
   selected by default) and Start/Stop buttons. Confirm the selector is clickable, then
   click Start. Confirm the selector greys out (inactive) once the Session is running, and
   the status label shows the chosen mode, e.g. "Listening on 127.0.0.1:8734 (read-only)".
   Click Stop and confirm the selector becomes clickable again. Select Read-write, click
   Start again, and confirm the status label now shows "(read-write)" — Sandbox behavior
   is unchanged either way this stage, so only the label/lock differs. Click Stop.
4. From a terminal, send a trivial script and confirm the JSON comes back correctly:
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
5. Try a script that errors, and confirm it comes back as a JSON error instead of
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
6. Try a deliberately runaway script and confirm the watchdog aborts it — the dialog
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
7. Click Stop (or send `STOP\n` the same way as the prototype's original test) — FH
   should become interactive again immediately.
8. Idle-timeout auto-Stop: temporarily lower `IDLE_TIMEOUT_SECONDS` near the top of
   `bridge.fh_lua` (e.g. to `10`) for a fast test, reload the plugin, click Start, then
   leave the Session idle (no request sent) past that duration. Confirm the dialog
   auto-returns to "Not listening." and the selector becomes clickable again, with no
   request sent and without clicking Stop. Restore `IDLE_TIMEOUT_SECONDS` to its real value
   (`300`) afterward.
9. FH read allowlist: with a real FH project open and a Session started (read-only),
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
