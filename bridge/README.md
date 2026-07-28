# Bridge plugin

The FH-side half of the MCP bridge — see the repo root `CONTEXT.md` and
`docs/adr/0001-arbitrary-sandboxed-lua-execution.md` for the concepts and decisions this
implements.

- `bridge.fh_lua` — the plugin itself: IUP dialog, TCP listener, request framing.
- `runScript.lua` — compiles and runs a submitted script inside the sandbox, returns a
  JSON-encoded result or error.
- `sandbox.lua` — builds the allowlist `_ENV` a script executes inside.
- `jsonEncode.lua` — hand-rolled JSON encoder (FH's Lua ships none).

`runScript.lua`, `sandbox.lua`, and `jsonEncode.lua` have standalone unit tests
(`*.test.lua`, run with a plain `lua` interpreter — no FH dependency):

```bash
lua bridge/jsonEncode.test.lua
lua bridge/sandbox.test.lua
lua bridge/runScript.test.lua
```

`bridge.fh_lua` itself (the socket/IUP dialog plumbing) has no automatable seam — FH is
proprietary and Windows/CrossOver-only. It's tested manually, inside FH:

## Manual test

1. Copy all four files in this folder into FH's Plugins folder (so `require()` can find
   the sibling modules) — `C:\ProgramData\Calico Pie\Family Historian\Plugins\` on native
   Windows, or the equivalent path under CrossOver's virtual C: drive on Mac.
2. In FH: Tools -> Plugins -> New, open `bridge.fh_lua` from that folder, click Run.
3. A small "FH Bridge" dialog appears with Start/Stop buttons. Click Start.
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
6. Click Stop (or send `STOP\n` the same way as the prototype's original test) — FH
   should become interactive again immediately.
