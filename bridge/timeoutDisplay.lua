-- Pure formatting/conversion helpers for the Session idle-timeout control -- no
-- socket/IUP/FH dependency, so (unlike bridge.fh_lua's dialog/timer code) this is testable
-- standalone.

local M = {}

-- Stated range for the idle-timeout spin-box control.
M.MIN_MINUTES = 5
M.MAX_MINUTES = 120

-- Formats a countdown of seconds remaining as "M:SS" (seconds zero-padded, minutes not).
-- Clamped at zero and floored so a stale or fractional reading never displays as a
-- negative or fractional countdown.
function M.formatSecondsRemaining(seconds)
  seconds = math.floor(math.max(0, seconds))
  local mins = math.floor(seconds / 60)
  local secs = seconds % 60
  return string.format('%d:%02d', mins, secs)
end

-- Converts the spin-box's minutes value (5-120) to the seconds the bridge's idle-Session
-- check compares elapsed time against.
function M.minutesToSeconds(minutes)
  return minutes * 60
end

-- Clamps a spin-box reading to [MIN_MINUTES, MAX_MINUTES], flooring any fractional value.
-- Defense-in-depth alongside the widget's own SPINMIN/SPINMAX: falls back to MIN_MINUTES
-- (rather than erroring) for a nil or non-numeric reading, e.g. if a user manually types
-- something the widget didn't intercept.
function M.clampMinutes(minutes)
  minutes = math.floor(tonumber(minutes) or M.MIN_MINUTES)
  if minutes < M.MIN_MINUTES then return M.MIN_MINUTES end
  if minutes > M.MAX_MINUTES then return M.MAX_MINUTES end
  return minutes
end

return M
