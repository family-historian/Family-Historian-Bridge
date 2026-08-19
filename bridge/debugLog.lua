-- Debug logging mode: records every run_lua script and its result to a plain-text log
-- file, so a user can review what Claude actually ran without digging through Claude's UI.
--
-- Entirely Bridge-side, called only from bridgeSession.lua -- must never run inside
-- runScript.lua's sandboxed script environment; sandbox.lua's EXCLUDED_FH_GLOBAL_REASONS
-- deliberately keeps filesystem access out of Claude-authored scripts, and this module must
-- stay outside that boundary. Only plain "LUA <n>" requests (run_lua's own calls) are
-- logged -- bridgeSession.lua decides that itself, by checking request.forceReadOnly before
-- calling Session:logRunLua; "LUA_RO <n>" (describe_project/install_fh_plugin's fixed,
-- internal scripts) is never passed in here.
--
-- fhSaveTextFile/fhFileUtils rather than plain io/lfs: FH's own docs note extended-UTF-8
-- paths aren't well supported by plain io/lfs on Windows, and a project's public folder can
-- be named with any character the user's own OS allows.
--
-- Full-file rewrite per entry, not append: fhSaveTextFile has no append mode and there's no
-- fh* append primitive -- a Session's run_lua call count is small enough that rewriting the
-- accumulated text each time is cheap.
--
-- Any failure (folder uncreatable, disk full, permissions, etc.) is swallowed silently, on
-- every call, not just the first -- run_lua must always execute and return normally
-- regardless of logging state or write success.

local M = {}

-- Local time, not UTC ('!' prefix) -- matches the rest of the dialog (e.g. lblStatus's own
-- os.date("%H:%M:%S") in bridgeSession.lua), so a user reconciling the log against what
-- they just watched happen in the dialog sees the same clock in both places.
local function isoTimestamp(t)
  return os.date('%Y-%m-%dT%H:%M:%S', t)
end

-- Same clock, but colons replaced with dashes -- ':' isn't valid inside a Windows filename.
local function filenameTimestamp(t)
  return (isoTimestamp(t):gsub(':', '-'))
end

local ACCESS_MODE_DISPLAY = {
  ['read-only'] = 'Read-only',
  ['read-write'] = 'Read-write',
}

local function displayAccessMode(accessMode)
  return ACCESS_MODE_DISPLAY[accessMode] or accessMode
end

-- Pure, testable path-building: <public folder>\debug\session-<filename-safe timestamp>.log.
-- Backslash-joined to match FH's own Windows path convention (fhGetContextInfo's folder
-- values are themselves Windows paths). suffix, when given, disambiguates a same-second
-- restart (see M.start) -- <path>-2.log, <path>-3.log, etc.
function M.buildLogPath(publicFolder, startTime, suffix)
  local path = publicFolder .. '\\debug\\session-' .. filenameTimestamp(startTime)
  if suffix then
    path = path .. '-' .. suffix
  end
  return path .. '.log'
end

function M.formatHeader(startTime, accessMode)
  return '=== Session started ' .. isoTimestamp(startTime) .. ', Access mode: ' ..
    displayAccessMode(accessMode) .. ' ===\n'
end

-- accessModeChanged is nil, or the new accessMode -- when set, prefixes the entry with a
-- "[Access mode changed: <mode>]" line rather than repeating Access mode on every entry.
-- Access mode is currently fixed for a Session's whole lifetime (see CONTEXT.md's
-- "Session" entry), so Session:logRunLua below can never actually pass a changed value
-- today -- this stays correct as-is if that ever changes.
function M.formatEntry(entryTime, scriptText, resultText, accessModeChanged)
  local lines = { '', '--- ' .. isoTimestamp(entryTime) .. ' ---' }
  if accessModeChanged then
    table.insert(lines, '[Access mode changed: ' .. displayAccessMode(accessModeChanged) .. ']')
  end
  table.insert(lines, 'SCRIPT:')
  table.insert(lines, scriptText)
  table.insert(lines, 'RESULT:')
  table.insert(lines, resultText)
  return table.concat(lines, '\n') .. '\n'
end

local Session = {}
Session.__index = Session

-- Starts a debug-log session -- a no-op (disabled) object unless `enabled` is true. Ensures
-- the `debug` subfolder exists and writes the header immediately; either step failing just
-- leaves the session disabled for its lifetime rather than raising. `now` defaults to
-- os.time, overridable for tests.
function M.start(enabled, publicFolder, accessMode, now)
  now = now or os.time
  local session = setmetatable({
    enabled = false,
    lastLoggedAccessMode = accessMode,
    content = '',
  }, Session)

  if not enabled then
    return session
  end

  local ok = pcall(function()
    -- One timestamp for both the filename and the header -- calling now() twice here could
    -- let a clock tick between them put a different second in each.
    local startTime = now()
    local fhfu = require('fhFileUtils')
    local debugFolder = publicFolder .. '\\debug'
    if not fhfu.folderExists(debugFolder) and not fhfu.createFolder(debugFolder) then
      error('failed to create debug folder')
    end
    -- A Stop+Start within the same wall-clock second would otherwise reuse the prior
    -- Session's exact filename and silently overwrite its already-recorded transcript.
    session.path = M.buildLogPath(publicFolder, startTime)
    local suffix = 2
    while fhfu.fileExists(session.path) do
      session.path = M.buildLogPath(publicFolder, startTime, suffix)
      suffix = suffix + 1
    end
    session.content = M.formatHeader(startTime, accessMode)
    if not fhSaveTextFile(session.path, session.content, 'UTF-8') then
      error('fhSaveTextFile failed')
    end
  end)

  session.enabled = ok
  return session
end

-- Appends one run_lua entry and rewrites the file. No-op when disabled. currentAccessMode
-- is the Session's live Access mode at the moment this script ran, compared against the
-- last logged value to decide whether to prefix an "[Access mode changed]" note.
function Session:logRunLua(scriptText, resultText, currentAccessMode, now)
  if not self.enabled then
    return
  end
  now = now or os.time
  local changed = nil
  if currentAccessMode ~= self.lastLoggedAccessMode then
    changed = currentAccessMode
  end
  local entry = M.formatEntry(now(), scriptText, resultText, changed)
  local newContent = self.content .. entry
  local ok = pcall(function()
    if not fhSaveTextFile(self.path, newContent, 'UTF-8') then
      error('fhSaveTextFile failed')
    end
  end)
  if ok then
    self.content = newContent
    -- Only commit the new mode once its entry is actually on disk -- otherwise a failed
    -- write on the change entry would leave lastLoggedAccessMode already updated, and the
    -- next successful entry would never re-emit the note this call failed to record.
    if changed then
      self.lastLoggedAccessMode = changed
    end
  end
end

return M
