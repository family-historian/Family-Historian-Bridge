-- User project modules (issue #150): a sandboxed require() for run_lua scripts, loading
-- helper modules the user installs by hand in one folder of the open project's data folder.
--
-- Each module compiles against the calling script's own sandbox env -- same allowlist, same
-- write tracker, same Visibility-filtered fhBridge helpers -- so a module can do exactly what
-- a run_lua script can, nothing more. Modules are re-read and re-compiled on every run_lua
-- call: the env (and its write tracker) is rebuilt per call, and a module bound to an earlier
-- call's env would write past the current call's tracker.
--
-- Nothing here touches the filesystem from inside the sandbox: the module source is read
-- Bridge-side (fhLoadTextFile, which handles extended-UTF-8 paths that plain io doesn't).

local M = {}

-- Relative to CI_PROJECT_DATA_FOLDER: FH's own per-project Plugin Data folder, then this
-- plugin's name.
M.SUBFOLDER = 'Plugin Data\\AI Connector\\modules'

-- Letters, digits and underscores only, so a name can never reach outside the folder.
M.NAME_PATTERN = '^[%w_]+$'

-- FH-shipped libraries a script might reach for by habit. The sandbox already provides fhu;
-- the rest are deliberately unavailable over run_lua.
local FH_LIBRARY_HINTS = {
  fhUtils = 'fhu is already a global in run_lua -- use it directly',
  fhFileUtils = 'filesystem access is not available over run_lua',
}

function M.folderFor(projectDataFolder)
  if type(projectDataFolder) ~= 'string' or projectDataFolder == '' then
    return nil
  end
  return projectDataFolder .. '\\' .. M.SUBFOLDER
end

-- A source over folder: source(name) -> text, path  |  nil, folder.
-- loadText(path) -> string|nil defaults to FH's fhLoadTextFile; injectable for tests.
function M.folderSource(folder, loadText)
  loadText = loadText or function(path) return fhLoadTextFile(path, 'UTF-8') end
  return function(name)
    local path = folder .. '\\' .. name .. '.lua'
    local ok, text = pcall(loadText, path)
    if ok and type(text) == 'string' then
      return text, path
    end
    return nil, folder
  end
end

-- What is installed, for describe_project/fhBridge.listModules:
-- { folder = <path or nil>, modules = { {name=, size=, modified=}, ... }, error = <string|nil> }.
-- listFolder(folder) -> array of {path=, size=, modified=} | false, defaults to
-- fhFileUtils.getFolderContents; injectable for tests. Never errors.
function M.list(folder, listFolder)
  local result = { folder = folder, modules = {} }
  if not folder then
    result.error = 'no project is open, so there is no modules folder'
    return result
  end
  listFolder = listFolder or function(f)
    local fhfu = require('fhFileUtils')
    if not fhfu.folderExists(f) then return {} end
    return fhfu.getFolderContents(f, false, true)
  end
  local ok, items = pcall(listFolder, folder)
  if not ok or not items then
    result.error = 'could not list ' .. folder .. ': ' .. tostring(items)
    return result
  end
  for _, item in ipairs(items) do
    local name = tostring(item.path or ''):match('([^\\/]+)%.lua$')
    if name and name:match(M.NAME_PATTERN) then
      table.insert(result.modules, { name = name, size = item.size, modified = item.modified })
    end
  end
  table.sort(result.modules, function(a, b) return a.name < b.name end)
  return result
end

-- Builds the require() a run_lua script sees.
--   env: the script's own sandbox env, which every module compiles against.
--   source: see folderSource; nil means modules are unavailable in this context.
--   preScan(text) -> violation string | nil: runScript's text pre-scans, applied to each
--     module before it compiles.
-- Within one call, a module loads once and later requires get the same value. A module
-- that returns nothing yields true, as Lua's own require does.
function M.makeRequire(env, source, preScan)
  local loaded = {}
  local loading = {}

  return function(name)
    if type(name) ~= 'string' or not name:match(M.NAME_PATTERN) then
      error('require: module names are letters, digits and underscores only, got ' .. tostring(name), 2)
    end
    if loaded[name] ~= nil then
      return loaded[name]
    end
    if FH_LIBRARY_HINTS[name] then
      error('require: ' .. name .. ' -- ' .. FH_LIBRARY_HINTS[name], 2)
    end
    if not source then
      error('require: user modules are not available here (no project data folder)', 2)
    end
    if loading[name] then
      error('require: module ' .. name .. ' requires itself, directly or through another module', 2)
    end

    local text, where = source(name)
    if not text then
      error('require: no module ' .. name .. ' in ' .. tostring(where), 2)
    end
    -- A file saved by Notepad and friends starts with a UTF-8 BOM, which load() rejects.
    text = text:gsub('^\239\187\191', '')

    local violation = preScan and preScan(text)
    if violation then
      error('require: ' .. name .. '.lua: ' .. violation, 2)
    end

    local chunk, compileErr = load(text, '@' .. name .. '.lua', 't', env)
    if not chunk then
      error('require: ' .. tostring(compileErr), 2)
    end

    loading[name] = true
    local value = chunk()
    loading[name] = nil
    if value == nil then
      value = true
    end
    loaded[name] = value
    return value
  end
end

return M
