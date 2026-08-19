-- Standalone tests for debugLog.lua. Run with: lua bridge/tests/debugLog.test.lua
-- fhFileUtils ships with FH and fhSaveTextFile is a bare FH global, neither resolvable in
-- this plain-lua test process -- stub fhFileUtils via package.loaded (same mechanism
-- sessionSettings.test.lua uses for fhUtils) and fhSaveTextFile as a real global, since
-- that's how debugLog.lua itself calls it.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'

local failures = 0

local function check(condition, label)
  if condition then
    print(string.format('PASS %s', label))
  else
    failures = failures + 1
    print(string.format('FAIL %s', label))
  end
end

local function contains(haystack, needle)
  return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

-- Fresh fake fhFileUtils/fhSaveTextFile + a fresh require of debugLog for each scenario,
-- mirroring sessionSettings.test.lua's withFakeFhu helper.
local function withFakes(fakeFhfu, fakeSaveTextFile, fn)
  package.loaded.fhFileUtils = fakeFhfu
  fhSaveTextFile = fakeSaveTextFile
  package.loaded.debugLog = nil
  local debugLog = require('debugLog')
  fn(debugLog)
  package.loaded.fhFileUtils = nil
  fhSaveTextFile = nil
  package.loaded.debugLog = nil
end

local FIXED_TIME = 1755610205 -- 2025-08-19T09:30:05 UTC-ish; exact value doesn't matter, only that os.date('!...') is deterministic from it

------------------------------------------------------------------
-- Pure functions: buildLogPath / formatHeader / formatEntry
------------------------------------------------------------------

withFakes({}, function() return true end, function(debugLog)
  local path = debugLog.buildLogPath('C:\\Trees\\MyTree', FIXED_TIME)
  check(contains(path, 'C:\\Trees\\MyTree\\debug\\session-'), 'buildLogPath nests under <public folder>\\debug\\session-')
  check(path:sub(-4) == '.log', 'buildLogPath ends in .log')
  check(not path:find(':', 12, true), 'buildLogPath has no colons in the timestamp portion (Windows filename safety)')

  local header = debugLog.formatHeader(FIXED_TIME, 'read-only')
  check(header:match('^=== Session started ') ~= nil, 'formatHeader starts with the Session-started banner')
  check(contains(header, 'Access mode: Read-only'), 'formatHeader displays Read-only capitalized')
  check(contains(debugLog.formatHeader(FIXED_TIME, 'read-write'), 'Access mode: Read-write'),
    'formatHeader displays Read-write capitalized')

  local entry = debugLog.formatEntry(FIXED_TIME, 'return 1', '1', nil)
  check(contains(entry, '--- '), 'formatEntry includes a --- <timestamp> --- marker')
  check(contains(entry, 'SCRIPT:\nreturn 1'), 'formatEntry includes the script text under SCRIPT:')
  check(contains(entry, 'RESULT:\n1'), 'formatEntry includes the result text under RESULT:')
  check(not contains(entry, 'Access mode changed'), 'formatEntry omits the access-mode note when nothing changed')

  local changedEntry = debugLog.formatEntry(FIXED_TIME, 'x()', 'ok', 'read-write')
  check(contains(changedEntry, '[Access mode changed: Read-write]'), 'formatEntry prefixes an access-mode-changed note when given one')
end)

------------------------------------------------------------------
-- M.start / Session:logRunLua
------------------------------------------------------------------

-- 1. Disabled session: never touches fhFileUtils/fhSaveTextFile, logRunLua is a no-op.
withFakes({
  folderExists = function() error('should not be called when disabled') end,
}, function() error('should not be called when disabled') end, function(debugLog)
  local session = debugLog.start(false, 'C:\\Trees\\MyTree', 'read-only')
  check(session.enabled == false, 'a disabled start() produces a disabled session')
  local ok = pcall(function() session:logRunLua('return 1', '1', 'read-only') end)
  check(ok, 'logRunLua on a disabled session does not raise')
end)

-- 2. Enabled session, debug folder missing: creates it, writes the header.
do
  local created, savedPaths, savedContents = nil, {}, {}
  withFakes({
    folderExists = function() return false end,
    createFolder = function(path) created = path; return true end,
    fileExists = function() return false end,
  }, function(path, contents)
    table.insert(savedPaths, path)
    table.insert(savedContents, contents)
    return true
  end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only', function() return FIXED_TIME end)
    check(session.enabled == true, 'a successful start() enables the session')
    check(created == 'C:\\Trees\\MyTree\\debug', 'start() creates the missing debug folder')
    check(#savedPaths == 1 and contains(savedPaths[1], 'debug\\session-'), 'start() writes the header to the session log path')
    check(contains(savedContents[1], 'Session started'), 'start() writes the header banner as the file\'s initial content')

    session:logRunLua('return 1', '1', 'read-only', function() return FIXED_TIME end)
    check(#savedPaths == 2, 'logRunLua rewrites the file')
    check(contains(savedContents[2], 'Session started') and contains(savedContents[2], 'SCRIPT:\nreturn 1'),
      'logRunLua rewrites the full accumulated content, header included')
  end)
end

-- 3. Enabled session, debug folder already exists: createFolder never called.
withFakes({
  folderExists = function() return true end,
  createFolder = function() error('should not be called when the folder already exists') end,
  fileExists = function() return false end,
}, function() return true end, function(debugLog)
  local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only')
  check(session.enabled == true, 'start() succeeds when the debug folder already exists')
end)

-- 4. createFolder failure: session stays disabled, no error propagates.
withFakes({
  folderExists = function() return false end,
  createFolder = function() return false end,
}, function() return true end, function(debugLog)
  local ok, session = pcall(debugLog.start, true, 'C:\\Trees\\MyTree', 'read-only')
  check(ok, 'a createFolder failure does not raise out of start()')
  check(ok and session.enabled == false, 'a createFolder failure leaves the session disabled')
end)

-- 5. fhSaveTextFile failure on the header write: session stays disabled.
withFakes({
  folderExists = function() return true end,
  fileExists = function() return false end,
}, function() return false end, function(debugLog)
  local ok, session = pcall(debugLog.start, true, 'C:\\Trees\\MyTree', 'read-only')
  check(ok, 'a fhSaveTextFile failure on the header write does not raise out of start()')
  check(ok and session.enabled == false, 'a fhSaveTextFile failure on the header write leaves the session disabled')
end)

-- 6. fhSaveTextFile failure on a later logRunLua call: silent, in-memory content unchanged,
-- run_lua's own result is unaffected (logRunLua itself never raises or returns anything the
-- caller must check).
do
  local writeShouldFail = false
  withFakes({
    folderExists = function() return true end,
    fileExists = function() return false end,
  }, function() return not writeShouldFail end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only', function() return FIXED_TIME end)
    check(session.enabled == true, 'sanity: session starts enabled')
    writeShouldFail = true
    local ok = pcall(function() session:logRunLua('return 1', '1', 'read-only') end)
    check(ok, 'a fhSaveTextFile failure inside logRunLua does not raise')
  end)
end

-- 7. Access-mode-changed note: only fires when currentAccessMode differs from the last
-- logged value, and only once (subsequent calls at the same mode omit it again).
do
  local savedContents = {}
  withFakes({
    folderExists = function() return true end,
    fileExists = function() return false end,
  }, function(_, contents) table.insert(savedContents, contents); return true end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only', function() return FIXED_TIME end)
    session:logRunLua('a()', 'ok', 'read-only', function() return FIXED_TIME end)
    check(not contains(savedContents[#savedContents], 'Access mode changed'),
      'no access-mode-changed note when the mode matches the last logged value')

    session:logRunLua('b()', 'ok', 'read-write', function() return FIXED_TIME end)
    check(contains(savedContents[#savedContents], '[Access mode changed: Read-write]'),
      'an access-mode-changed note appears the entry a mode switch is first seen on')

    session:logRunLua('c()', 'ok', 'read-write', function() return FIXED_TIME end)
    local _, occurrences = savedContents[#savedContents]:gsub('Access mode changed', '')
    check(occurrences == 1,
      'the access-mode-changed note is not repeated on a subsequent entry at the same mode')
  end)
end

-- 8. A same-second restart (fileExists true for the plain filename) gets a disambiguating
-- -2 suffix rather than overwriting the prior Session's log.
do
  local savedPaths = {}
  withFakes({
    folderExists = function() return true end,
    fileExists = function(path) return not path:find('%-2%.log$') end,
  }, function(path, _) table.insert(savedPaths, path); return true end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only', function() return FIXED_TIME end)
    check(session.enabled == true, 'start() still enables the session when the first path is taken')
    check(contains(session.path, '-2.log'), 'start() disambiguates a same-second restart with a -2 suffix')
    check(savedPaths[1] == session.path, 'start() writes the header to the disambiguated path, not the collided one')
  end)
end

-- 9. Regression: a write failure on the access-mode-changed entry must not silently commit
-- the mode change -- the next successful write still re-emits the note.
do
  local writeShouldFail = false
  local savedContents = {}
  withFakes({
    folderExists = function() return true end,
    fileExists = function() return false end,
  }, function(_, contents)
    if writeShouldFail then return false end
    table.insert(savedContents, contents)
    return true
  end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only', function() return FIXED_TIME end)
    writeShouldFail = true
    session:logRunLua('a()', 'ok', 'read-write', function() return FIXED_TIME end)
    writeShouldFail = false
    session:logRunLua('b()', 'ok', 'read-write', function() return FIXED_TIME end)
    check(contains(savedContents[#savedContents], '[Access mode changed: Read-write]'),
      'a failed write on the mode-change entry does not suppress the note on the next successful write')
  end)
end

-- 10. Regression: the public folder itself doesn't exist yet (FH only creates it on
-- demand) -- start() must create it before attempting the debug subfolder, since
-- createFolder is not recursive (errors 'Parent folder not found' if the parent is
-- missing). Modelled here by having the fake createFolder fail for the debug path unless
-- the public folder was created first.
do
  local publicFolderCreated = false
  withFakes({
    folderExists = function() return false end,
    createFolder = function(path)
      if path == 'C:\\Trees\\MyTree' then
        publicFolderCreated = true
        return true
      end
      -- path == 'C:\Trees\MyTree\debug': only succeeds once the parent exists.
      return publicFolderCreated
    end,
    fileExists = function() return false end,
  }, function() return true end, function(debugLog)
    local session = debugLog.start(true, 'C:\\Trees\\MyTree', 'read-only')
    check(session.enabled == true,
      'start() creates a missing public folder before the debug subfolder, so both succeed')
  end)
end

if failures > 0 then
  print(string.format('\n%d assertion(s) failed', failures))
  os.exit(1)
else
  print('\nAll assertions passed')
  os.exit(0)
end
