---
type: document
subtype: summary
title: Family Historian MCP Bridge - Project Handover
project: FH MCP Bridge
status: prototype-proven
ai_generated: true
tags:
  - project-handover
  - mcp
  - family-historian
  - lua
date: 2026-07-28
---

# Family Historian MCP Bridge — Project Handover

## Goal

Build an [[MCP]] (Model Context Protocol) server that lets Claude read and write genealogy data in [[Family Historian]] (FH) — a Windows genealogy application (run here via CrossOver on macOS) that exposes a full Lua scripting API through user-written plugins.

Target capability: Claude should be able to search/query people, facts, and sources, and add/edit facts, source citations, and notes, via natural conversation, with changes reflected live in the user's open FH project.

## Environment

- **Family Historian**: running on macOS via **CrossOver** (not a VM — shares the Mac's real network stack, confirmed working for loopback TCP).
- **Claude client**: Claude Desktop, same Mac, will connect to a local MCP server via stdio.
- **MCP server**: not yet built. Language (Node vs Python) not yet decided — open question for this phase.
- Family Historian plugins are Lua scripts run via Tools → Plugins in the FH Editor/Debugger, with an FH-provided Lua API (`fh...` prefixed functions) plus preinstalled libraries including **LuaSocket** (network) and **IUP** (GUI).

## Architecture

```
Claude Desktop  ──stdio──►  MCP server (to be built)
                                   │
                                   ▼  TCP, 127.0.0.1:8734 (localhost only)
                          FH "bridge" plugin (Lua, runs inside FH)
                                   │
                                   ▼  FH Lua API (fh...)
                          Family Historian project (open database)
```

## What's been proven (prototype, working)

A Lua plugin (`bridge_prototype_v2.lua`, full source below) has been built and manually tested inside FH under CrossOver:

- **LuaSocket works as expected** for opening a local TCP listener and doing non-blocking accept/read/write inside a plugin. Confirmed with a Python one-liner test client from macOS Terminal, connecting to `127.0.0.1:8734` and receiving back live project data (`fhGetContextInfo` values + `fhGetAppVersion()`).
- **`require("socket")` must be assigned explicitly**: `socket = require("socket")`, not just `require("socket")` — the module isn't injected as an implicit global in this FH/Lua build.
- **A plain `while` loop + `fhExhibitResponsiveness()` is the wrong mechanism for staying "alive."** It stops Windows/CrossOver from flagging the app as hung, but does **not** pump FH's own message loop, so FH's main window becomes locked/unresponsive for the duration — confirmed by direct testing (clicking around FH did nothing until the loop ended).
- **IUP's own event loop is the right mechanism instead.** The working version uses `iup.dialog` + `iup.timer` (polling every 100ms) + `iup.MainLoop()`. IUP's main loop pumps messages properly for its own dialog (so Start/Stop buttons work, status label updates live), but **FH's main window is still locked while the plugin's IUP mainloop owns the thread** — this is a single-threaded-application constraint, not something we've found a way around yet.
- **Conclusion: this has to be a deliberate "session mode."** The user starts the bridge plugin (a small dialog appears with Start/Stop buttons), FH is then unavailable for normal interactive use until they click Stop (or Claude/the MCP server sends a `STOP` command over the socket, which the plugin treats identically to the Stop button). This is an accepted trade-off, not a bug to fix — similar in spirit to handing control to an agentic coding tool for a bit.
- `iup.SetGlobal("CUSTOMQUITMESSAGE", "YES")` is required — omitting it is documented (FHUG forum) to cause FH to crash when a plugin using IUP is closed via the Run command.

## Current prototype code (working, tested)

This is the full content of the currently-working plugin. It does exactly one thing: listens, and on any line of input other than `STOP`, replies with current project context (name, file path, GEDCOM path, app mode, FH version). No JSON, no command dispatch yet — deliberately minimal, to isolate "can a plugin stay alive and talk over a socket without breaking FH" from "does the actual protocol work."

```lua
-- FH MCP Bridge Prototype v2
--
-- IUP dialog with Start/Stop buttons. Start binds a local TCP listener and
-- polls it via an IUP timer (not a manual while-loop). Stop unbinds it.
-- Closing the dialog window ends the plugin and cleans up.
--
-- Confirmed in testing: while a session is running, FH's main window is
-- locked. This is a deliberate "session mode" -- start it to hand control
-- to Claude for a bit, Stop when you want FH back.

socket = require("socket")
require("iuplua")
iup.SetGlobal("CUSTOMQUITMESSAGE", "YES") -- avoids known FH/IUP interaction issue on quit

local PORT = 8734
local server = nil

local function getProjectInfo()
    local lines = {}
    table.insert(lines, "PROJECT_NAME: " .. tostring(fhGetContextInfo("CI_PROJECT_NAME")))
    table.insert(lines, "PROJECT_FILE: " .. tostring(fhGetContextInfo("CI_PROJECT_FILE")))
    table.insert(lines, "GEDCOM_FILE: "  .. tostring(fhGetContextInfo("CI_GEDCOM_FILE")))
    table.insert(lines, "APP_MODE: "     .. tostring(fhGetContextInfo("CI_APP_MODE")))
    table.insert(lines, "APP_VERSION: "  .. tostring(fhGetAppVersion()))
    table.insert(lines, "END")
    return table.concat(lines, "\n") .. "\n"
end

local lblStatus = iup.label{title="Not listening.", padding="10x10"}
local btnStart  = iup.button{title="Start", padding="4x4"}
local btnStop   = iup.button{title="Stop", padding="4x4", active="NO"}

local dlg = iup.dialog{
    iup.vbox{lblStatus, iup.hbox{btnStart, btnStop, gap="8"}, margin="10x10", gap="10"},
    title="FH Bridge (prototype)",
    resize="NO", maxbox="NO", minbox="NO",
    topmost="YES", size="220x"
}

local timPoll = iup.timer{time=100, run="NO"}

function timPoll:action_cb()
    if not server then return end
    local client = server:accept()
    if client then
        client:settimeout(5)
        local request = client:receive("*l")
        if request then
            if request:upper() == "STOP" then
                client:send("STOPPING\n")
                client:close()
                -- treat a socket STOP the same as clicking the Stop button
                return btnStop:action()
            else
                client:send(getProjectInfo())
                lblStatus.title = "Listening on 127.0.0.1:" .. PORT ..
                    "\nLast request handled at " .. os.date("%H:%M:%S")
            end
        end
        client:close()
    end
end

function btnStart:action()
    local bindErr
    server, bindErr = socket.bind("127.0.0.1", PORT)
    if not server then
        lblStatus.title = "Failed to bind port " .. PORT .. ":\n" .. tostring(bindErr)
        return
    end
    server:settimeout(0)
    timPoll.run = "YES"
    btnStart.active = "NO"
    btnStop.active = "YES"
    lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. "\nWaiting for a connection..."
end

function btnStop:action()
    timPoll.run = "NO"
    if server then
        server:close()
        server = nil
    end
    btnStart.active = "YES"
    btnStop.active = "NO"
    lblStatus.title = "Not listening."
end

function dlg:close_cb()
    if server then
        server:close()
        server = nil
    end
    return iup.CLOSE
end

dlg:show()
if (iup.MainLoopLevel() == 0) then
    iup.MainLoop()
end
dlg:destroy()
```

### How to run/test it (for reference)

1. In FH: Tools → Plugins → New, paste the script, save, click Run.
2. A small dialog appears with Start/Stop buttons. Click Start.
3. From macOS Terminal:
   ```bash
   python3 -c "
   import socket
   s = socket.create_connection(('127.0.0.1', 8734), timeout=5)
   s.sendall(b'HELLO\n')
   s.shutdown(socket.SHUT_WR)
   print(s.recv(4096).decode())
   s.close()
   "
   ```
   Should print back `PROJECT_NAME`, `PROJECT_FILE`, `GEDCOM_FILE`, `APP_MODE`, `APP_VERSION`, `END`.
4. Click Stop (or send `STOP\n` the same way as above) — FH should become interactive again immediately.

## Relevant FH API reference (confirmed from official docs)

- `fhGetContextInfo(strInfoReqd)` — project/context info. Useful values: `CI_PROJECT_NAME`, `CI_PROJECT_FILE`, `CI_GEDCOM_FILE`, `CI_PROJECT_PUBLIC_FOLDER`, `CI_PROJECT_DATA_FOLDER`, `CI_APP_MODE`, `CI_APP_HWND` (light userdata — window handle, unexplored so far), `CI_PARENT_HWND`.
- `fhGetAppVersion()` — FH version string.
- `fhExhibitResponsiveness()` — prevents "Not Responding" flagging in long-running loops; does **not** pump the UI message queue (see findings above).
- `fhNewItemPtr()`, `MoveToFirstRecord(tag)`, `MoveNext()`, `IsNull()` — the core pattern for iterating records (e.g. tag `"INDI"` for Individuals). Not yet used in the prototype.
- `fhGetItemText(ptr, strDataReference)` / `fhGetDisplayText` — read field values via Data Reference strings (e.g. `'~.NAME:SURNAME'`).
- `fhCreateItem(strTag [, ptrParent])`, `fhDeleteItem(ptr)`, `fhSetValueAsText/RichText/Date/Link(ptr, value)` — the write-side API. Not yet used.
- Full API index: https://www.family-historian.co.uk/help/fh7-plugins/api/functions/functions.htm
- Undo: FH provides "Undo Plugin Updates" / "Redo Plugin Updates" on the Edit menu, covering all plugin-made database changes (but not any files the plugin wrote outside FH's database).
- Plugins run in a single thread shared with FH itself — confirmed constraint, see findings above.

## Open questions / decisions for the next phase

1. **Message protocol**: currently plain text/newline-delimited. Need to move to a real request/response format (JSON) for multiple command types. FH's Lua doesn't ship a JSON library by default — either hand-roll a minimal encode/decode inline, or bundle something like `dkjson` as a local file (note: the FH Plugin Store disallows module dependencies, but that only matters if this is ever published there — not a constraint for personal use).
2. **Command set for v1**: agreed scope is read *and* write — specifically adding/editing facts, source citations, and notes on existing individuals. Not yet decided: whether to support creating brand-new individual/family records, or is this strictly "edit what already exists."
3. **MCP server language**: Node or Python — not yet decided.
4. **Port/config**: currently hardcoded to `8734` — fine for prototype, should probably become configurable.
5. **Security**: currently no auth, loopback-only. Should stay that way (single local user), but worth a deliberate statement in code comments rather than an accidental assumption.
6. **Session lifecycle from Claude's side**: does the MCP server auto-send a `STOP` when the conversation/tool session ends, or leave that entirely to the user clicking Stop in FH? Needs a decision once the MCP server is being built, since a stale "Listening" session left open is just an inconvenience (FH locked) rather than a data-safety issue.
7. **Backups**: no automated backup step yet. Recommendation carried over from planning: user should take an FH backup before write-testing sessions until the write path is well-exercised; consider whether the bridge plugin itself should trigger this via `fhShellExecute` or similar, or leave it manual.
8. **`CI_APP_HWND`** was noted as available but unexplored — flagged in case it offers any way to make the main window less "locked" during a session (e.g. re-enabling parts of the UI), though this may be a dead end given the single-thread constraint.

## Files in this handover

- `bridge_prototype_v2.lua` — the working prototype, full source embedded above.
- (superseded) `bridge_prototype.lua` — first version, used a manual `while` loop; superseded by the IUP-timer version once the UI-locking issue was found. Kept only for history; no need to carry forward.
