-- The Bridge plugin's dialog UI and Session lifecycle (issue #75, docs/adr/0018): the IUP
-- dialog (Access-mode selector, idle-timeout spin-box and countdown, Start/Stop), the TCP
-- listener and its poll-timer callback, and request-framing dispatch. Split out of
-- `Claude MCP Bridge.fh_lua` itself so Serena's symbol tools (find_symbol,
-- find_referencing_symbols, etc.) can cover it — `.fh_lua` files can't be recognized by
-- Serena's installed Lua language server integration, `.lua` files can. See CONTEXT.md's
-- "Session" and "Bridge plugin" entries.
--
-- Required, not run standalone: the entry file (`Claude MCP Bridge.fh_lua`) calls
-- `fhInitialise(...)` and `fhSetStringEncoding("UTF-8")` itself, before requiring this
-- module — both must stay direct calls in the entry file, never inside a required module
-- (fhSetStringEncoding: FH's own docs say it "should never be used by modules"; fhInitialise:
-- FH's own docs say it "should be the first function called in the plugin"). This module
-- inherits the current string encoding fhSetStringEncoding already set, per FH's "Special
-- Handling for Modules".
--
-- Has no automatable seam, same as the entry file did before this split — FH is proprietary
-- and Windows/CrossOver-only, so this is tested manually inside FH (see bridge/README.md's
-- "Manual test" section), not with a *.test.lua file like the rest of bridge/.
--
-- IUP dialog with an Access-mode selector, an idle-timeout spin-box (issue #34), and
-- Start/Stop buttons. Start binds a local TCP listener and polls it via an IUP timer (not
-- a manual while-loop — see docs/adr's prototype-era findings on why
-- fhExhibitResponsiveness()+while-loop doesn't work). Stop unbinds it. Closing the dialog
-- window ends the plugin and cleans up. The same poll timer also watches for an idle
-- Session (no accepted request for the configured idle-timeout, see
-- currentIdleTimeoutSeconds() below) and auto-Stops it, so a forgotten Session doesn't
-- lock FH indefinitely; a live countdown to that auto-Stop is shown in lblTimeLeft.
--
-- Confirmed in testing (prototype phase): while a session is running, FH's main window
-- is locked. This is a deliberate "Session" (see CONTEXT.md) — start it to hand control
-- to Claude for a bit, Stop when you want FH back.
--
-- Access mode (read-only / read-write) is chosen once at Start and fixed for the whole
-- Session (see CONTEXT.md "Access mode"), and threaded through to the sandbox via
-- runScript.run(script, currentAccessMode()) — read-write additionally wires through FH's
-- full write API (issue #14). describe_project's fixed script instead forces the
-- Read-only sandbox regardless of the Session's access mode, via the LUA_RO request form
-- (issue #16) — see requestFraming.lua.
--
-- The Access-mode and idle-timeout selections a Start succeeds with are persisted (issue
-- #80, sessionSettings.lua) via FH's supported fhu.loadOptions/saveOptions settings-file
-- API, LOCAL_MACHINE scope, so the dialog reopens with last time's choices instead of
-- always resetting to read-only/15 minutes. This is a different code path from
-- bridge/sandbox.lua's block on the same fhu functions for run_lua-submitted scripts
-- (issue #22) — that block is about keeping filesystem access out of Claude-authored
-- scripts, not about this file's own dialog code, which calls fhUtils directly.

socket = require("socket")
require("iuplua")
iup.SetGlobal("CUSTOMQUITMESSAGE", "YES") -- avoids known FH/IUP interaction issue on quit

local runScript = require("runScript")
local json = require("jsonEncode")
local requestFraming = require("requestFraming")
local timeoutDisplay = require("timeoutDisplay")
local versionCompare = require("versionCompare")
local sessionSettings = require("sessionSettings")

local PORT = 8734
-- Last-used Access mode and idle-timeout minutes (issue #80), loaded once here so the
-- widgets below can seed themselves from it. sessionSettings.load() already falls back to
-- (read-only, 15) -- matching this file's own former hardcoded defaults -- on a missing or
-- unreadable settings file, so this is safe to use unconditionally, first run or not.
local lastSettings = sessionSettings.load()
local DEFAULT_IDLE_TIMEOUT_MINUTES = lastSettings.idleTimeoutMinutes
-- Issue #77 / docs/adr/0020: Exit (and the window's X, which shares Exit's teardown) only
-- prompts to confirm closing a running Session when the last request was handled this
-- recently -- the only observable proxy for "Claude might send another request any
-- moment," since a script actually executing can never overlap with a button click (IUP's
-- mainloop is single-threaded). Hardcoded, not exposed on the dialog like the idle
-- timeout -- this is a safety-net nudge, not a per-user tunable. Measured against
-- lastRequestHandledTime, not lastActivityTime -- lastActivityTime is also stamped at
-- Start itself (for the idle-timeout clock), so using it here would warn on a Start-then-
-- immediately-Exit even though no request was ever handled.
local RECENT_ACTIVITY_CONFIRM_SECONDS = 10

-- Dialog background colours: a muted traffic-light so the Session's state -- and, while
-- listening, whether write access is armed -- is visible without reading the status label.
-- Read-write gets its own colour rather than sharing "listening" with read-only since it's
-- the one state where a script can actually mutate the user's data. Muted (not saturated)
-- tones so the dialog doesn't read as alarming at a glance; grey/green/amber/red differ in
-- lightness as well as hue so the states stay distinguishable under common colour-blindness.
-- Set on the dialog itself (dlg.bgcolor), not lblStatus -- IUP native labels don't reliably
-- honour BGCOLOR, confirmed not working live.
local STATUS_COLOR_STOPPED   = "224 224 224" -- grey: idle, nothing listening
local STATUS_COLOR_READONLY  = "212 237 218" -- green: listening, read-only (safe)
local STATUS_COLOR_READWRITE = "255 243 205" -- amber: listening, read-write (can mutate data)
local STATUS_COLOR_ERROR     = "248 215 218" -- red: failed to bind
local server = nil
local lastActivityTime = nil
-- Distinct from lastActivityTime above: only stamped when a real request (stop/version/lua)
-- is actually handled, never at Start -- see RECENT_ACTIVITY_CONFIRM_SECONDS above for why.
local lastRequestHandledTime = nil
-- Set by a VERSION request (issue #45), cleared on a match or a fresh Start. A VERSION
-- check arrives on its own connection, handled and closed within a single poll tick — a
-- mismatch noted only in that tick's own status update would be overwritten by the very
-- next tick's normal "Last request handled..." line before a user ever saw it. Appending
-- this to every subsequent status update instead keeps a real mismatch visible for the
-- rest of the Session, not just the one tick it was detected on.
local currentVersionWarning = nil

local lblStatus = iup.label{title="Not listening.", padding="10x10"}
-- Seeded from lastSettings (issue #80) rather than always "Read-only" -- ON goes on
-- whichever toggle matches the last-saved Access mode, so a read-write habit is restored
-- too, not just clamped back to the safer default every reload.
local togReadOnly  = iup.toggle{title="Read-only", value=(lastSettings.accessMode == "read-only") and "ON" or "OFF"}
local togReadWrite = iup.toggle{title="Read-write", value=(lastSettings.accessMode == "read-write") and "ON" or "OFF"}
local radAccessMode = iup.radio{iup.hbox{togReadOnly, togReadWrite, gap="8"}}
-- Idle-timeout control (issue #34): minutes, 5-120 per the ticket's stated range, editable
-- only while the Session is stopped (locked the same way togReadOnly/togReadWrite are —
-- see btnStart/btnStop below). SPINMIN/SPINMAX are the widget's own guard;
-- timeoutDisplay.clampMinutes is a second, defensive clamp applied when the value is
-- actually read, in case a manually typed value slips past the widget.
local txtIdleTimeout = iup.text{
    spin="YES", spinmin=timeoutDisplay.MIN_MINUTES, spinmax=timeoutDisplay.MAX_MINUTES,
    value=tostring(DEFAULT_IDLE_TIMEOUT_MINUTES), visiblecolumns=4
}
local lblTimeLeft = iup.label{title="", padding="0x4"}
local btnStart  = iup.button{title="Start", padding="4x4"}
local btnStop   = iup.button{title="Stop", padding="4x4", active="NO"}
-- Always active, Session running or not -- mirrors the window's X, which is likewise
-- clickable regardless of Session state (issue #77, docs/adr/0020).
local btnExit   = iup.button{title="Exit", padding="4x4"}

lblStatus.expand = "HORIZONTAL"
-- Same fix as lblStatus: this label is created with an empty title, so without an
-- explicit expand it maps at near-zero width and never grows to fit the "Time left:
-- M:SS" text set into it later — IUP sizes a label once, at map time, from whatever
-- title it had then.
lblTimeLeft.expand = "HORIZONTAL"

local dlg = iup.dialog{
    iup.vbox{
        lblStatus,
        -- normalizesize="HORIZONTAL" makes both frames the same width (the wider of the
        -- two, i.e. Mode's), so the row reads as one balanced settings panel rather than
        -- two mismatched boxes.
        iup.hbox{
            iup.frame{radAccessMode, title="Mode", padding="8x8"},
            iup.frame{
                iup.hbox{iup.label{title="Minutes:"}, txtIdleTimeout, gap="8"},
                title="Idle timeout", padding="8x8"
            },
            gap="10", normalizesize="HORIZONTAL"
        },
        -- lblTimeLeft rides alongside the buttons rather than owning its own row -- it's
        -- blank whenever the Session isn't running (i.e. most of the time this dialog is
        -- on screen), and a dedicated row for it was costing a full row height plus two
        -- gaps even while empty. expand="HORIZONTAL" (still set where lblTimeLeft is
        -- created, above) is still needed for the same reason as before -- an
        -- empty-titled label maps at near-zero width and won't regrow to fit the "Time
        -- left: M:SS" text set into it later -- it just now expands within this row
        -- instead of its own.
        iup.hbox{btnStart, btnStop, btnExit, lblTimeLeft, gap="10"},
        margin="10x10", gap="10"
    },
    title="Claude MCP Bridge",
    resize="YES", maxbox="NO", minbox="NO",
    bgcolor=STATUS_COLOR_STOPPED
}
-- Parent to FH's own window (per FH's help: "Ensuring your Window stays on top") rather
-- than a system-wide topmost -- this keeps the dialog above Family Historian specifically,
-- not above every other application on screen.
iup.SetAttribute(dlg, "NATIVEPARENT", fhGetContextInfo("CI_PARENT_HWND"))
-- Map first so RASTERSIZE is populated (both dimensions now come from the children's own
-- natural layout -- no explicit SIZE is set on the dialog any more, since the horizontal
-- frame row's width depends on Mode's own natural width), then use that as the floor for
-- MINSIZE -- otherwise a user could resize the dialog small enough to push the Start/Stop
-- buttons off-screen, the same failure this fix is for.
dlg:map()
dlg.minsize = dlg.rastersize

local function currentAccessMode()
    return togReadWrite.value == "ON" and "read-write" or "read-only"
end

-- dlg's bgcolor while listening -- see the STATUS_COLOR_* comment above for why read-write
-- gets its own colour.
local function statusColorForMode(accessMode)
    return accessMode == "read-write" and STATUS_COLOR_READWRITE or STATUS_COLOR_READONLY
end

-- Read live rather than snapshotted at Start, same as currentAccessMode() above — safe
-- because txtIdleTimeout is locked (active="NO") for the whole Session, just like
-- togReadOnly/togReadWrite.
local function currentIdleTimeoutSeconds()
    return timeoutDisplay.minutesToSeconds(timeoutDisplay.clampMinutes(txtIdleTimeout.value))
end

local function updateTimeLeftLabel(secondsLeft)
    lblTimeLeft.title = "Time left: " .. timeoutDisplay.formatSecondsRemaining(secondsLeft)
end

local timPoll = iup.timer{time=100, run="NO"}

-- Set just before ending the plugin on a genuine write-mode error (see action_cb below) --
-- checked once iup.MainLoop() returns, so the error can be re-raised truly at the top
-- level, past this whole script's remaining statements, uncaught. docs/adr/0005: an error
-- raised from inside a callback alone never reaches that far -- IUP's own callback
-- dispatch swallows it before it can escape the plugin, confirmed empirically. Ending the
-- plugin this way (rather than just Stopping the Session) is deliberate and only happens
-- when a write-mode script actually wrote something before erroring (issue #15).
local pendingRethrow = nil

-- Request framing: the bridge reads one line first, parsed by requestFraming.lua.
--   STOP           -- ends the Session immediately, same as clicking Stop.
--   LUA <n>        -- followed by exactly n bytes: the script body, read via receive(n).
--                     Runs under the Session's own current Access mode.
--   LUA_RO <n>     -- same, but forces the Read-only sandbox regardless of the Session's
--                     Access mode (issue #16 — used exclusively by describe_project).
--   VERSION <v>    -- issue #45: no body. Replies with this Bridge's own version and
--                     compares it against the server's, surfacing a mismatch via
--                     currentVersionWarning (see above) rather than the LUA/LUA_RO
--                     response shape.
-- This replaces the prototype's single-line-only receive("*l") read, which could not
-- carry a multi-line Lua script.
function timPoll:action_cb()
    if not server then return end

    if lastActivityTime and os.time() - lastActivityTime > currentIdleTimeoutSeconds() then
        return btnStop:action()
    end

    -- Live countdown (issue #34) -- updated every poll tick, not just when a request
    -- arrives, so it counts down even while idle.
    if lastActivityTime then
        updateTimeLeftLabel(currentIdleTimeoutSeconds() - (os.time() - lastActivityTime))
    end

    local client = server:accept()
    if not client then return end

    client:settimeout(5)
    local header = client:receive("*l")
    if not header then
        client:close()
        return
    end

    local request = requestFraming.parse(header)
    if not request then
        -- malformed framing, not an accepted request — doesn't reset the idle timer
        client:send(json.encode({ error = "expected STOP or LUA <n>" }) .. "\n")
        client:close()
        return
    end

    if request.kind == "stop" then
        lastActivityTime = os.time()
        lastRequestHandledTime = lastActivityTime
        client:send("STOPPING\n")
        client:close()
        -- treat a socket STOP the same as clicking the Stop button
        return btnStop:action()
    end

    if request.kind == "version" then
        lastActivityTime = os.time()
        lastRequestHandledTime = lastActivityTime
        local severity = versionCompare.compare(BRIDGE_VERSION, request.serverVersion)
        client:send(json.encode({ version = BRIDGE_VERSION }) .. "\n")
        client:close()
        if severity == "match" then
            currentVersionWarning = nil
        else
            currentVersionWarning = "\nVersion mismatch: Bridge " .. BRIDGE_VERSION .. " vs server " ..
                request.serverVersion .. (severity == "block" and " (major version differs)" or "")
        end
        return
    end

    lastActivityTime = os.time()
    lastRequestHandledTime = lastActivityTime

    local script = client:receive(request.byteCount)
    if not script then
        client:send(json.encode({ error = "expected " .. request.byteCount .. " script bytes but the read failed (timeout or connection closed early)" }) .. "\n")
        client:close()
        return
    end

    local accessMode = requestFraming.resolveAccessMode(request, currentAccessMode())
    local response, rethrowErr = runScript.run(script, accessMode)
    client:send(response .. "\n")
    client:close()

    -- Give FH a chance to redraw anything a write script changed (issue #33) --
    -- unconditional, regardless of access mode or whether this particular script
    -- actually wrote anything: cheap when nothing changed, per fhUpdateDisplay's own docs.
    fhUpdateDisplay()

    dlg.bgcolor = statusColorForMode(currentAccessMode())
    lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. " (" .. currentAccessMode() .. ")" ..
        "\nLast request handled at " .. os.date("%H:%M:%S") .. (currentVersionWarning or "")

    -- Send-then-rethrow (docs/adr/0005): a write-mode runtime error is already reported to
    -- the client above. To give FH's own auto-undo an actual chance to fire, the whole
    -- plugin has to end with the error uncaught -- ending the network side the same way a
    -- manual Stop does, then returning iup.CLOSE (the documented way a callback ends
    -- iup.MainLoop(), same effect as ExitLoop -- confirmed safe here since only this
    -- plugin's own process owns the loop; FH itself isn't IUP-based) so the code below can
    -- re-raise pendingRethrow once MainLoop() returns, truly at the top level. The Session
    -- does not survive this -- the user has to reopen the plugin (Tools -> Plugins, or the
    -- Tools-menu entry) to start a new one.
    if rethrowErr ~= nil then
        pendingRethrow = rethrowErr
        btnStop:action()
        return iup.CLOSE
    end
end

function btnStart:action()
    local bindErr
    server, bindErr = socket.bind("127.0.0.1", PORT)
    if not server then
        dlg.bgcolor = STATUS_COLOR_ERROR
        lblStatus.title = "Failed to bind port " .. PORT .. ":\n" .. tostring(bindErr)
        return
    end
    server:settimeout(0)
    lastActivityTime = os.time()
    currentVersionWarning = nil
    -- Persist the values that just took effect (issue #80) -- only here, after the bind
    -- above has already succeeded, never on every toggle/spin-box edit and never for a
    -- Start that failed. currentIdleTimeoutSeconds() isn't used here since that returns
    -- seconds for the idle-Session clock -- clampMinutes(txtIdleTimeout.value) is the
    -- minutes figure this settings file actually stores. A write failure inside save() is
    -- swallowed silently and never blocks Start (see sessionSettings.lua).
    sessionSettings.save({
        accessMode = currentAccessMode(),
        idleTimeoutMinutes = timeoutDisplay.clampMinutes(txtIdleTimeout.value),
    })
    timPoll.run = "YES"
    btnStart.active = "NO"
    btnStop.active = "YES"
    togReadOnly.active = "NO"
    togReadWrite.active = "NO"
    txtIdleTimeout.active = "NO"
    updateTimeLeftLabel(currentIdleTimeoutSeconds())
    dlg.bgcolor = statusColorForMode(currentAccessMode())
    lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. " (" .. currentAccessMode() .. ")" ..
        "\nWaiting for a connection..."
end

-- Shared by btnStop, Exit and the window's X (docs/adr/0020) so the socket/timer teardown
-- can't drift between the three -- issue #77 flagged that close_cb previously skipped most
-- of this. Only the socket/timer/activity state; the "return dialog to Start-ready" UI
-- reset stays in btnStop:action() below, since it's meaningless when the dialog is about
-- to close (Exit/X) rather than staying open (Stop).
local function stopSessionIfRunning()
    timPoll.run = "NO"
    if server then
        server:close()
        server = nil
    end
    lastActivityTime = nil
    lastRequestHandledTime = nil
end

function btnStop:action()
    stopSessionIfRunning()
    btnStart.active = "YES"
    btnStop.active = "NO"
    togReadOnly.active = "YES"
    togReadWrite.active = "YES"
    txtIdleTimeout.active = "YES"
    lblTimeLeft.title = ""
    dlg.bgcolor = STATUS_COLOR_STOPPED
    lblStatus.title = "Not listening."
end

-- Exit and the window's X both funnel through here (docs/adr/0020). Confirms only when a
-- Session is running and the last request was handled within
-- RECENT_ACTIVITY_CONFIRM_SECONDS -- otherwise closes straight away, silently. Returns
-- false (and leaves the Session untouched) if the user declines the prompt.
local function confirmAndStopSession()
    if server and lastRequestHandledTime and os.time() - lastRequestHandledTime < RECENT_ACTIVITY_CONFIRM_SECONDS then
        local pressed = iup.Alarm("Confirm Exit", "A request was just handled -- close anyway?", "Yes", "No")
        if pressed ~= 1 then
            return false
        end
    end
    stopSessionIfRunning()
    return true
end

function btnExit:action()
    if confirmAndStopSession() then
        return iup.CLOSE
    end
end

function dlg:close_cb()
    if confirmAndStopSession() then
        return iup.CLOSE
    end
    return iup.IGNORE
end

dlg:show()
if (iup.MainLoopLevel() == 0) then
    iup.MainLoop()
end
dlg:destroy()

-- Re-raise a write-mode script's error here, past every other statement in this file,
-- genuinely uncaught -- see the pendingRethrow comment above and docs/adr/0005.
if pendingRethrow ~= nil then
    error(pendingRethrow)
end
