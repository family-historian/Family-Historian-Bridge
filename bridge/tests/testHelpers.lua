-- Shared assertion/report helpers for the standalone bridge/tests/*.test.lua files (no FH/socket
-- dependency, each run as its own `lua ...` process via scripts/run-bridge-tests.mjs). new()
-- returns a fresh {check, contains, report} triple per file so failure counts never leak between
-- test files sharing this module.

local M = {}

function M.new(opts)
  opts = opts or {}
  local passFmt = opts.passFmt or 'PASS %s'
  local failFmt = opts.failFmt or 'FAIL %s'
  local failures = 0

  local function check(condition, label)
    if condition then
      print(string.format(passFmt, label))
    else
      failures = failures + 1
      print(string.format(failFmt, label))
    end
  end

  local function contains(haystack, needle)
    return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
  end

  -- Prints the pass/fail summary and exits with the process code scripts/run-bridge-tests.mjs
  -- checks (0 = all assertions passed, 1 = at least one failed).
  local function report()
    if failures > 0 then
      print(string.format('\n%d assertion(s) failed', failures))
      os.exit(1)
    else
      print('\nAll assertions passed')
      os.exit(0)
    end
  end

  return { check = check, contains = contains, report = report }
end

-- Fakes the FH file functions userModules.lua reads with: the fhLoadTextFile global and
-- fhFileUtils's fileExists, folderExists and getFolderContents. In the returned state,
-- files maps a full path to its text (false: the file is there but unreadable) and folders
-- maps a folder to its listing ({path=, size=, modified=} entries), to a function returning
-- one, or to a message getFolderContents raises. Both tables may be replaced or changed at
-- any time. restore() puts back whatever was there before.
function M.fakeFhFiles()
  local state = { files = {}, folders = {} }
  local savedLoad, savedFileUtils = fhLoadTextFile, package.loaded['fhFileUtils']
  fhLoadTextFile = function(path)
    local text = state.files[path]
    return type(text) == 'string' and text or nil
  end
  package.loaded['fhFileUtils'] = {
    fileExists = function(path) return state.files[path] ~= nil end,
    folderExists = function(folder) return state.folders[folder] ~= nil end,
    getFolderContents = function(folder)
      local listing = state.folders[folder]
      if type(listing) == 'string' then error(listing) end
      if type(listing) == 'function' then return listing() end
      return listing
    end,
  }
  function state.restore()
    fhLoadTextFile, package.loaded['fhFileUtils'] = savedLoad, savedFileUtils
  end
  return state
end

return M
