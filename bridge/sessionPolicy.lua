-- Pure session-lifecycle policy decisions extracted out of bridgeSession.lua: no
-- socket/IUP/FH dependency, so -- like timeoutDisplay.lua -- this is testable standalone,
-- unlike the file it's extracted from (that file calls require("iuplua")/require("socket")
-- at module scope, so nothing defined inside it can be required from a plain-lua test).
--
-- Deliberately narrow: stopSessionIfRunning/confirmAndStopSession (in bridgeSession.lua)
-- call server:close() and iup.Alarm(...) directly -- genuinely I/O-coupled, so they stay
-- there. What's pulled out here is the *decisions* underneath them: boolean/string
-- functions over plain values, leaving bridgeSession.lua to gather those values from its
-- own widgets/sockets and act on the decision.

local M = {}

-- Dialog background colours: a muted traffic-light so the Session's state -- and, while
-- listening, whether write access is armed -- is visible without reading the status label.
-- Read-write gets its own colour rather than sharing "listening" with read-only since it's
-- the one state where a script can actually mutate the user's data. Muted (not saturated)
-- tones so the dialog doesn't read as alarming at a glance; grey/green/amber/red differ in
-- lightness as well as hue so the states stay distinguishable under common colour-blindness.
M.STATUS_COLOR_STOPPED   = "240 240 240" -- light grey: idle, nothing listening
M.STATUS_COLOR_READONLY  = "212 237 218" -- green: listening, read-only (safe)
M.STATUS_COLOR_READWRITE = "255 243 205" -- amber: listening, read-write (can mutate data)
M.STATUS_COLOR_ERROR     = "248 215 218" -- red: failed to bind

-- dlg's bgcolor while listening -- read-write gets its own colour, see above.
function M.statusColorForMode(accessMode)
  return accessMode == "read-write" and M.STATUS_COLOR_READWRITE or M.STATUS_COLOR_READONLY
end

-- Auto-Stop rule: true once more than idleTimeoutSeconds has elapsed since
-- lastActivityTime, so a forgotten Session doesn't lock FH indefinitely. False (never
-- auto-stops) when lastActivityTime is nil -- i.e. no Session is running yet.
function M.shouldAutoStopForIdle(lastActivityTime, idleTimeoutSeconds, now)
  if not lastActivityTime then return false end
  return now - lastActivityTime > idleTimeoutSeconds
end

-- ADR 0020's freshness-confirm rule for Exit/the window's X: prompt only when a Session is
-- running *and* the last request was handled within confirmWindowSeconds of now -- the only
-- observable proxy available for "Claude might send another request any moment" (whether a
-- script is actually mid-execution is unobservable at click time -- see the ADR). False (no
-- prompt, close immediately) when sessionRunning is false, or lastRequestHandledTime is nil
-- (no request has been handled this Session yet, e.g. Start-then-immediately-Exit).
function M.shouldConfirmBeforeExit(sessionRunning, lastRequestHandledTime, now, confirmWindowSeconds)
  if not sessionRunning then return false end
  if not lastRequestHandledTime then return false end
  return now - lastRequestHandledTime < confirmWindowSeconds
end

return M
