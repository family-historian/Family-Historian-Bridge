-- The Bridge plugin's dialog UI and Session lifecycle: the IUP dialog (Access-mode
-- selector, idle-timeout countdown, Start/Stop/Settings; the idle-timeout spin-box itself
-- lives in the Settings popup), the TCP listener and its
-- poll-timer callback, and request-framing dispatch. Split out of `Claude MCP Bridge.fh_lua`
-- itself so Serena's symbol tools can cover it -- `.fh_lua` files aren't recognized by
-- Serena's Lua language server, `.lua` files are. See CONTEXT.md's "Session" and "Bridge
-- plugin" entries.
--
-- Required, not run standalone: the entry file calls fhInitialise(...) and
-- fhSetStringEncoding("UTF-8") itself before requiring this module -- both must stay
-- direct calls in the entry file, never inside a required module (FH's own docs:
-- fhSetStringEncoding "should never be used by modules"; fhInitialise "should be the
-- first function called in the plugin").
--
-- No automatable test -- FH is proprietary and Windows/CrossOver-only, so this is tested
-- manually inside FH (see bridge/README.md's "Manual test" section).
--
-- Start binds a local TCP listener and polls it via an IUP timer (not a manual while-loop
-- -- fhExhibitResponsiveness()+while-loop doesn't work, per the prototype-era ADR
-- findings). Stop unbinds it. Closing the dialog ends the plugin and cleans up. The same
-- poll timer also watches for an idle Session (no accepted request for the configured
-- idle-timeout) and auto-Stops it, with a live countdown shown in lblTimeLeft.
--
-- While a session is running, FH's main window is locked -- a deliberate "Session" (see
-- CONTEXT.md): start it to hand control to Claude, Stop when you want FH back.
--
-- Access mode (read-only/read-write) is chosen once at Start and fixed for the whole
-- Session, threaded through to the sandbox via runScript.run(script, currentAccessMode()).
-- describe_project's fixed script instead always forces the Read-only sandbox, via the
-- LUA_RO request form -- see requestFraming.lua.
--
-- The Access-mode, idle-timeout and Debug logging selections a Start succeeds with are
-- persisted (sessionSettings.lua) via fhu.loadOptions/saveOptions, so the dialog reopens
-- with last time's choices. This is a different code path from bridge/sandbox.lua's block
-- on those same fhu functions for run_lua-submitted scripts -- that block is about keeping
-- filesystem access out of Claude-authored scripts, not this file's own dialog code.
--
-- Debug logging (debugLog.lua) records every run_lua call's script/result to a log file
-- under the project's public folder, for the Session's own lifetime -- entirely
-- outside runScript.lua's sandbox, same "not the sandboxed script's own I/O" distinction as
-- sessionSettings.lua above.

local socket = require("socket")
require("iuplua")
iup.SetGlobal("CUSTOMQUITMESSAGE", "YES") -- avoids known FH/IUP interaction issue on quit

local runScript = require("runScript")
local json = require("jsonEncode")
local requestFraming = require("requestFraming")
local sessionPolicy = require("sessionPolicy")
local timeoutDisplay = require("timeoutDisplay")
local versionCompare = require("versionCompare")
local sessionSettings = require("sessionSettings")
local debugLog = require("debugLog")
local sessionLogHelper = require("sessionLogHelper")

local PORT = 8734
-- Last-used Access mode and idle-timeout minutes, loaded once here so the widgets below
-- can seed themselves from it. sessionSettings.load() falls back to (read-only, 15) on a
-- missing/unreadable settings file, so this is safe to use unconditionally.
local lastSettings = sessionSettings.load()
local DEFAULT_IDLE_TIMEOUT_MINUTES = lastSettings.idleTimeoutMinutes
-- Exit (and the window's X) only prompts to confirm closing a running Session when the
-- last request was handled this recently -- the only observable proxy for "Claude might
-- send another request any moment," since IUP's mainloop is single-threaded so a script
-- actually executing can never overlap with a button click. Hardcoded, not exposed on the
-- dialog -- a safety-net nudge, not a per-user tunable. Measured against
-- lastRequestHandledTime, not lastActivityTime, since lastActivityTime is also stamped at
-- Start itself -- using it here would warn on a Start-then-immediately-Exit with no
-- request ever handled.
local RECENT_ACTIVITY_CONFIRM_SECONDS = 10

-- Dialog background colours (see sessionPolicy.lua for the palette): a muted
-- traffic-light so the Session's state -- and, while listening, whether write access is
-- armed -- is visible without reading the status label. Set on the dialog itself
-- (dlg.bgcolor), not lblStatus -- IUP native labels don't reliably honour BGCOLOR.
local STATUS_COLOR_STOPPED   = sessionPolicy.STATUS_COLOR_STOPPED
local STATUS_COLOR_ERROR     = sessionPolicy.STATUS_COLOR_ERROR
local server = nil
local lastActivityTime = nil
-- Distinct from lastActivityTime above: only stamped when a real request is actually
-- handled, never at Start -- see RECENT_ACTIVITY_CONFIRM_SECONDS above.
local lastRequestHandledTime = nil
-- Set by a VERSION request, cleared on a match or a fresh Start. A VERSION check is
-- handled and closed within a single poll tick -- appending this to every subsequent
-- status update (rather than noting it only in that tick) keeps a real mismatch visible
-- for the rest of the Session, not just the tick it was detected on.
local currentVersionWarning = nil

local lblStatus = iup.label{title="Not listening.", padding="10x10"}
-- Seeded from lastSettings rather than always "Read-only" -- restores a read-write habit
-- too, not just the safer default.
local togReadOnly  = iup.toggle{title="Read-only", value=(lastSettings.accessMode == "read-only") and "ON" or "OFF"}
local togReadWrite = iup.toggle{title="Read-write", value=(lastSettings.accessMode == "read-write") and "ON" or "OFF"}
local radAccessMode = iup.radio{iup.hbox{togReadOnly, togReadWrite, gap="8"}}
-- Debug logging: records every run_lua script/result to a log file under the project's
-- public folder for the Session's lifetime. Off by default, editable only while
-- stopped -- same rule as Access mode/idle timeout -- and persisted the same way. Lives in
-- the Settings popup below (dlgSettings), not the main dialog -- built here as a standalone
-- widget so currentDebugLogging() can keep reading togDebugLogging.value regardless of
-- whether the popup is currently open.
local togDebugLogging = iup.toggle{title="Logging", value=lastSettings.debugLogging and "ON" or "OFF"}

-- Visibility levels for the Private/Living Record Flags (issue #141): Exclude < Name Only <
-- All, index-mapped 1/2/3 to match iup.list's 1-based VALUE. Two dropdowns, same shape,
-- built via newVisibilityList below.
local VISIBILITY_LABELS = {"Exclude", "Name Only", "All"}
local VISIBILITY_VALUES = {"exclude", "nameOnly", "all"}

local function visibilityListIndex(value)
    for i, v in ipairs(VISIBILITY_VALUES) do
        if v == value then return i end
    end
    return 3 -- "all"
end

local function newVisibilityList(initialValue)
    local list = iup.list{dropdown="YES", visiblecolumns=10}
    for i, label in ipairs(VISIBILITY_LABELS) do
        list[tostring(i)] = label
    end
    list.value = tostring(visibilityListIndex(initialValue))
    return list
end

local lstPrivateVisibility = newVisibilityList(lastSettings.privateVisibility)
local lstLivingVisibility = newVisibilityList(lastSettings.livingVisibility)
local btnSettings = iup.button{title="Settings...", padding="4x4"}
local btnSettingsOk = iup.button{title="OK", padding="4x4"}
-- Idle-timeout control: minutes, 5-120, editable only while the Session is stopped.
-- SPINMIN/SPINMAX are the widget's own guard; timeoutDisplay.clampMinutes is a second,
-- defensive clamp applied when the value is read, in case a manually typed value slips
-- past the widget.
local txtIdleTimeout = iup.text{
    spin="YES", spinmin=timeoutDisplay.MIN_MINUTES, spinmax=timeoutDisplay.MAX_MINUTES,
    value=tostring(DEFAULT_IDLE_TIMEOUT_MINUTES), visiblecolumns=4
}
local lblTimeLeft = iup.label{title="", padding="0x4"}
local btnStart  = iup.button{title="Start", padding="4x4"}
local btnStop   = iup.button{title="Stop", padding="4x4", active="NO"}
-- Always active, Session running or not -- mirrors the window's X, likewise clickable
-- regardless of Session state.
local btnExit   = iup.button{title="Exit", padding="4x4"}

lblStatus.expand = "HORIZONTAL"
-- Without an explicit expand this label maps at near-zero width and never grows to fit
-- text set into it later -- IUP sizes a label once, at map time, from whatever title it
-- had then.
lblTimeLeft.expand = "HORIZONTAL"

local dlg = iup.dialog{
    iup.vbox{
        -- Mode frame above the status text. The trailing iup.fill{} gives the frame a
        -- horizontally-expanding child so it stretches to the full dialog width --
        -- expand="HORIZONTAL" on the frame alone, and normalizesize, both left it at its
        -- natural (narrow) width.
        iup.frame{
            iup.hbox{radAccessMode, iup.fill{}},
            title="Mode", padding="8x8", expand="HORIZONTAL"
        },
        lblStatus,
        -- Expanding filler: soaks up any extra height so the button row stays pinned to the
        -- bottom edge when the dialog is resized taller.
        iup.fill{},
        -- lblTimeLeft rides alongside the buttons rather than owning its own row -- it's
        -- blank most of the time this dialog is on screen, and a dedicated row costs a
        -- full row height even while empty.
        iup.hbox{btnStart, btnStop, btnSettings, btnExit, lblTimeLeft, gap="10"},
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
-- lblStatus can later grow to 3 lines ("Listening.../Last request.../a version-mismatch
-- line) but starts as a single short line ("Not listening.") -- if MINSIZE below is
-- captured from *that* rastersize, the dialog can never grow to fit the 3-line case later
-- (IUP doesn't auto-grow past a fixed MINSIZE), truncating the status text. Seed a
-- worst-case 3-line placeholder before mapping, purely so MINSIZE reserves enough height/
-- width, then reset it to the real initial text once MINSIZE is captured. Widens/heightens
-- the dialog's floor permanently (even when no mismatch is in play), which is the deliberate
-- trade-off here.
lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. " (read-write)" ..
    "\nLast request handled at 00:00:00" ..
    "\nVersion mismatch: Bridge 99.99.99 vs server 99.99.99 (major version differs)"
-- Map first so RASTERSIZE is populated, then use that as the floor for MINSIZE --
-- otherwise a user could resize the dialog small enough to push the Start/Stop buttons
-- off-screen.
dlg:map()
dlg.minsize = dlg.rastersize
lblStatus.title = "Not listening."

-- Settings popup (issues #141, #142): the Idle-timeout spin-box, the two Visibility
-- dropdowns and the relocated Debug-logging toggle. Built once, shown modally via :popup() each time btnSettings is clicked (rather
-- than build/destroy per click) so currentPrivacySettings/currentDebugLogging can always
-- read the live widget values even while the popup itself is closed. No Cancel button --
-- whatever's selected when the popup closes (OK or the window's own X) is already live in
-- the widgets; there's nothing to revert.
local dlgSettings = iup.dialog{
    iup.vbox{
        -- The frames sit in their own vbox with normalizesize so all three take the widest
        -- one's width (expand="HORIZONTAL" alone didn't stretch them); OK stays outside it
        -- so it keeps its natural size.
        iup.vbox{
            iup.frame{
                iup.hbox{iup.label{title="Minutes:"}, txtIdleTimeout, gap="8", alignment="ACENTER"},
                title="Idle timeout", padding="8x8"
            },
            -- gridbox (not two hboxes) so the labels and dropdowns line up as two columns.
            iup.frame{
                iup.gridbox{
                    iup.label{title="Private:"}, lstPrivateVisibility,
                    iup.label{title="Living:"}, lstLivingVisibility,
                    numdiv=2, orientation="HORIZONTAL", gapcol=8, gaplin=8, alignmentlin="ACENTER"
                },
                title="Visibility", padding="8x8"
            },
            -- The inner vbox's margin gives the toggle breathing room -- the frame's own
            -- padding leaves it tight against the bottom border, and (x) indents it to
            -- line up with the Private/Living/Minutes labels, which IUP insets from the
            -- frame edge more than a bare toggle.
            iup.frame{iup.vbox{togDebugLogging, margin="16x4"}, title="Debug", padding="8x8"},
            gap="10", normalizesize="HORIZONTAL"
        },
        btnSettingsOk,
        margin="10x10", gap="10"
    },
    title="Settings"
}
-- Parented to dlg (the main dialog), not FH's own window directly -- dlg is itself
-- NATIVEPARENT'd above FH, and a child also parented straight to FH could render behind dlg.
dlgSettings.parentdialog = dlg

function btnSettingsOk:action()
    return iup.CLOSE
end

function btnSettings:action()
    dlgSettings:popup(iup.CENTER, iup.CENTER)
end

local function currentAccessMode()
    return togReadWrite.value == "ON" and "read-write" or "read-only"
end

-- Read live from the Settings popup's two dropdowns, same "live widget, not snapshotted"
-- pattern as currentAccessMode() above. `or "all"` guards iup.list's VALUE=="0" (nothing
-- selected) case -- without it this would return {privateVisibility=nil, ...}, a non-nil
-- table that skips runScript.lua's own default-to-"all" fallback while still failing every
-- =='all' check, so bulkEnumerationViolation would reject *every* script, not none.
local function currentPrivacySettings()
    return {
        privateVisibility = VISIBILITY_VALUES[tonumber(lstPrivateVisibility.value)] or "all",
        livingVisibility = VISIBILITY_VALUES[tonumber(lstLivingVisibility.value)] or "all",
    }
end

local function currentDebugLogging()
    return togDebugLogging.value == "ON"
end

-- The active debug-log session -- see debugLog.lua. Always a Session object once a Session
-- has started (never nil then), including when Debug logging is off: Session:logRunLua is a
-- no-op on a disabled session, so callers below never need to check this for nil.
local debugLogSession = nil

-- dlg's bgcolor while listening -- lives in sessionPolicy.lua so it's testable standalone
-- (this file can't be require()'d from a plain-lua test).
local statusColorForMode = sessionPolicy.statusColorForMode

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
-- checked once iup.MainLoop() returns, so the error can be re-raised at the top level,
-- uncaught. An error raised from inside a callback alone never reaches that far -- IUP's
-- own callback dispatch swallows it first. Ending the plugin this way (rather than just
-- Stopping the Session) only happens when a write-mode script's own rollback attempt
-- itself fails (see docs/INTERNAL-commit-rollback-plan.md, issue #133).
local pendingRethrow = nil

-- Session-scoped commit counter (issue #133): counts one per committed read-write run_lua
-- call, never decrements on a rollback, resets at Start (a fresh dialog/plugin load, same
-- lifetime as every other module-level local here). sessionLogHelper.setCommitCount is
-- given commitCount + 1 (the optimistic "count so far including this pending call") before
-- every read-write call, since the true post-commit value isn't known until after the
-- script -- and any logActivity call inside it -- has already run; see runScript.run's own
-- transactionResult return value for how this gets confirmed/adjusted afterward.
local commitCount = 0

-- Request framing: the bridge reads one line first, parsed by requestFraming.lua.
--   STOP           -- ends the Session immediately, same as clicking Stop.
--   LUA <n>        -- followed by exactly n bytes: the script body, read via receive(n).
--                     Runs under the Session's own current Access mode.
--   LUA_RO <n>     -- same, but forces the Read-only sandbox regardless of the Session's
--                     Access mode (used exclusively by describe_project).
--   VERSION <v>    -- no body. Replies with this Bridge's own version and current Access
--                     mode, compares the version against the server's, surfacing a
--                     mismatch via currentVersionWarning rather than the LUA/LUA_RO
--                     response shape.
function timPoll:action_cb()
    if not server then return end

    -- Auto-Stop rule lives in sessionPolicy.lua so it's testable standalone.
    if sessionPolicy.shouldAutoStopForIdle(lastActivityTime, currentIdleTimeoutSeconds(), os.time()) then
        return btnStop:action()
    end

    -- Live countdown -- updated every poll tick, not just when a request arrives, so it
    -- counts down even while idle.
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
        -- also reports the Session's real Access mode, so the server's describe_project
        -- bridgeState can surface it without a second connection.
        client:send(json.encode({ version = BRIDGE_VERSION, accessMode = currentAccessMode(),
            privacySettings = currentPrivacySettings() }) .. "\n")
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
    -- Optimistic count-so-far, set before the script runs so a logActivity call inside it
    -- reports the right total -- see commitCount's own comment above. Harmless to set on
    -- every call regardless of access mode: sessionLogHelper.logActivity only ever runs
    -- during a read-write call anyway (sandbox.lua only wires fhBridge.logActivity through
    -- then), and a read-only call never reaches it.
    sessionLogHelper.setCommitCount(commitCount + 1)
    -- forceReadOnly (describe_project/install_fh_plugin's fixed, internal scripts) always
    -- gets unfiltered "all"/"all" privacySettings, never the Session's actual restriction:
    -- these scripts are fixed source reviewed as part of this bridge, not user-supplied
    -- run_lua text, and describe_project's own census walk relies on raw MoveToFirstRecord
    -- -- passing a restricted level here would trip runScript.lua's own bulkEnumerationViolation
    -- pre-scan and break describe_project outright the moment a Visibility level is restricted.
    local privacySettings = not request.forceReadOnly and currentPrivacySettings() or nil
    local response, rethrowErr, transactionResult = runScript.run(script, accessMode, privacySettings)
    client:send(response .. "\n")
    client:close()

    if transactionResult == "committed" then
        commitCount = commitCount + 1
        -- Tells sessionLogHelper this call's note writes (if any) are now durable, so a
        -- later rollback in this Session knows the note itself survives rather than having
        -- been created in that later, uncommitted call. See noteConfirmed's own comment.
        sessionLogHelper.markNoteCommitted()
    elseif transactionResult == "rolledback" then
        -- Resyncs this module's cached note state with what the rollback actually left on
        -- disk -- either the existing note's buffer (if it was already committed), or a
        -- clean slate for a brand-new note next call (if the rollback undid the note's own
        -- creation too). See sessionLogHelper.recoverAfterRollback's own comment.
        sessionLogHelper.recoverAfterRollback()
    end

    -- Only a plain "LUA <n>" request is run_lua's own -- "LUA_RO <n>"
    -- (describe_project/install_fh_plugin's fixed, internal scripts) is never logged.
    if debugLogSession and not request.forceReadOnly then
        debugLogSession:logRunLua(script, response, currentAccessMode())
    end

    -- Give FH a chance to redraw anything a write script changed -- unconditional,
    -- regardless of access mode or whether this particular script actually wrote
    -- anything: cheap when nothing changed, per fhUpdateDisplay's own docs.
    fhUpdateDisplay()

    dlg.bgcolor = statusColorForMode(currentAccessMode())
    lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. " (" .. currentAccessMode() .. ")" ..
        "\nLast request handled at " .. os.date("%H:%M:%S") .. (currentVersionWarning or "")

    -- Send-then-rethrow: a write-mode runtime error is already reported to the client
    -- above. To give FH's own auto-undo an actual chance to fire, the whole plugin has to
    -- end with the error uncaught -- ending the network side the same way a manual Stop
    -- does, then returning iup.CLOSE (the documented way a callback ends iup.MainLoop())
    -- so the code below can re-raise pendingRethrow once MainLoop() returns, truly at the
    -- top level. The Session does not survive this -- the user has to reopen the plugin to
    -- start a new one.
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
    commitCount = 0
    -- Persist the values that just took effect -- only here, after the bind above has
    -- already succeeded, never on every toggle/spin-box edit and never for a failed Start.
    -- clampMinutes(txtIdleTimeout.value) is the minutes figure the settings file stores
    -- (not currentIdleTimeoutSeconds(), which is seconds for the idle-Session clock). A
    -- write failure inside save() is swallowed silently and never blocks Start.
    local privacySettings = currentPrivacySettings()
    -- Persist the user's own choice, not the auto-forced value below -- the force is a
    -- session-scoped safety net for *this* Session's restricted Visibility, not a standing
    -- preference change; persisting the forced value would leave logging silently stuck on
    -- next time, after Visibility's back to "all", with no toggle the user ever touched.
    local userDebugLogging = currentDebugLogging()
    sessionSettings.save({
        accessMode = currentAccessMode(),
        idleTimeoutMinutes = timeoutDisplay.clampMinutes(txtIdleTimeout.value),
        debugLogging = userDebugLogging,
        privateVisibility = privacySettings.privateVisibility,
        livingVisibility = privacySettings.livingVisibility,
    })
    -- Auto-force Debug logging ON for this Session whenever a Visibility level is
    -- restricted (deferred from slice 5 to here, where the toggle now lives): a restricted
    -- level silently narrows what run_lua sees, so the Session's own log should always
    -- capture what actually happened while that's true. Applied after the save above (and
    -- before debugLog.start below, so it actually takes effect for the Session about to
    -- start) -- enforced live, can't be bypassed by leaving it off in the Settings popup.
    if privacySettings.privateVisibility ~= "all" or privacySettings.livingVisibility ~= "all" then
        togDebugLogging.value = "ON"
    end
    -- CI_PROJECT_PUBLIC_FOLDER queried once here, not re-queried per script.
    -- debugLog.start is itself a no-op (a disabled session) when Debug logging is off.
    debugLogSession = debugLog.start(currentDebugLogging(), fhGetContextInfo("CI_PROJECT_PUBLIC_FOLDER"), currentAccessMode())
    timPoll.run = "YES"
    btnStart.active = "NO"
    btnStop.active = "YES"
    togReadOnly.active = "NO"
    togReadWrite.active = "NO"
    btnSettings.active = "NO"
    txtIdleTimeout.active = "NO"
    updateTimeLeftLabel(currentIdleTimeoutSeconds())
    dlg.bgcolor = statusColorForMode(currentAccessMode())
    lblStatus.title = "Listening on 127.0.0.1:" .. PORT .. " (" .. currentAccessMode() .. ")" ..
        "\nWaiting for a connection..."
end

-- Shared by btnStop, Exit and the window's X so the socket/timer teardown can't drift
-- between the three. Only the socket/timer/activity state; the "return dialog to
-- Start-ready" UI reset stays in btnStop:action() below, since it's meaningless when the
-- dialog is about to close rather than staying open.
local function stopSessionIfRunning()
    timPoll.run = "NO"
    if server then
        server:close()
        server = nil
    end
    lastActivityTime = nil
    lastRequestHandledTime = nil
    debugLogSession = nil
end

function btnStop:action()
    stopSessionIfRunning()
    btnStart.active = "YES"
    btnStop.active = "NO"
    togReadOnly.active = "YES"
    togReadWrite.active = "YES"
    btnSettings.active = "YES"
    txtIdleTimeout.active = "YES"
    lblTimeLeft.title = ""
    dlg.bgcolor = STATUS_COLOR_STOPPED
    lblStatus.title = "Not listening."
end

-- Exit and the window's X both funnel through here. Confirms only when a Session is
-- running and the last request was handled within RECENT_ACTIVITY_CONFIRM_SECONDS --
-- otherwise closes straight away, silently. Returns false (and leaves the Session
-- untouched) if the user declines the prompt.
local function confirmAndStopSession()
    -- Freshness-confirm rule lives in sessionPolicy.lua so it's testable standalone.
    -- `server ~= nil` is this file's own "is a Session running" check.
    if sessionPolicy.shouldConfirmBeforeExit(server ~= nil, lastRequestHandledTime, os.time(), RECENT_ACTIVITY_CONFIRM_SECONDS) then
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
-- dlgSettings.parentdialog = dlg (above) makes IUP cascade-destroy dlgSettings and its
-- children as part of destroying dlg -- an explicit dlgSettings:destroy() here would hit an
-- already-destroyed C handle ("destroyed iupHandle in C but not in Lua", confirmed live).
dlg:destroy()

-- Show this plugin load's log note on close (FH 8 beta's fhOutputNote): only when
-- logActivity actually created one, no write-mode error is about to trigger FH's own
-- rollback prompt (ADR 0005 -- that undoes this whole plugin load's writes, including the
-- note itself, so popping it first would be wrong), and FH's own major version supports
-- fhOutputNote (FH-8-beta-only). fhGetAppVersion() returns its 3 version numbers as
-- separate return values, not a dotted string, so only the first (the major) is read here.
local sessionNotePtr = sessionLogHelper.getNotePtr()
local appVersionMajor = fhGetAppVersion()
if sessionNotePtr ~= nil and pendingRethrow == nil and appVersionMajor ~= nil and appVersionMajor >= 8 then
    fhOutputNote(sessionNotePtr)
end

-- Re-raise a write-mode script's error here, past every other statement in this file,
-- genuinely uncaught.
if pendingRethrow ~= nil then
    error(pendingRethrow)
end
