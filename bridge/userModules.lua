-- User project modules: a sandboxed require() for run_lua scripts, loading helper modules
-- the user installs by hand: first from the open project's own modules folder, then from a
-- machine-wide one shared by every project.
--
-- Each module compiles against the calling script's own sandbox env -- same allowlist, same
-- write tracker, same Visibility-filtered fhBridge helpers -- so a module can do exactly what
-- a run_lua script can, nothing more. Modules are re-read and re-compiled on every run_lua
-- call: the env (and its write tracker) is rebuilt per call, and a module bound to an earlier
-- call's env would write past the current call's tracker.
--
-- Nothing here writes to either folder, and nothing touches the filesystem from inside the
-- sandbox: the module source is read Bridge-side (fhLoadTextFile, which handles
-- extended-UTF-8 paths that plain io doesn't).

local watchdog = require('watchdog')

local M = {}

-- Relative to CI_PROJECT_DATA_FOLDER: FH's own per-project Plugin Data folder, then this
-- plugin's name.
M.SUBFOLDER = 'Plugin Data\\AI Connector\\modules'

-- Relative to FH's machine-wide Plugin Data folder. Fixed, not the running plugin's own
-- name, so a renamed plugin file still finds the same modules.
M.MACHINE_SUBFOLDER = 'AI Connector\\modules'

-- ASCII letters, digits and underscores only, so a name can never reach outside the folder.
-- Spelt out rather than %w, whose meaning follows the C locale.
M.NAME_PATTERN = '^[A-Za-z0-9_]+$'

-- Instruction budget for loading one module while listing, so a module that loops fails its
-- own entry, not the listing or the describe_project call around it.
M.LIST_LOAD_LIMIT = 5000000

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

-- The machine-wide modules folder, from fhGetPluginDataFileName("LOCAL_MACHINE")'s result
-- ("<machine Plugin Data>\<plugin name>"): its parent folder, then MACHINE_SUBFOLDER. nil
-- when FH returned nothing usable. Take FH's answer, not its help: the help's path for this
-- scope is wrong for FH 8 (ADR 0039).
function M.machineFolderFor(localMachineDataFile)
  if type(localMachineDataFile) ~= 'string' then
    return nil
  end
  local root = localMachineDataFile:match('^(.+)[\\/][^\\/]+$')
  if not root then
    return nil
  end
  return root .. '\\' .. M.MACHINE_SUBFOLDER
end

-- Both folders for the open project, asked of FH: {folder=, machineFolder=}, either nil
-- when FH can't say.
function M.foldersFromFH()
  local ok, machineDataFile = pcall(fhGetPluginDataFileName, 'LOCAL_MACHINE')
  return {
    folder = M.folderFor(fhGetContextInfo('CI_PROJECT_DATA_FOLDER')),
    machineFolder = ok and M.machineFolderFor(machineDataFile) or nil,
  }
end

-- The folders that are known, in search order: { {scope='project', folder=},
-- {scope='machine', folder=} }, skipping either one that is nil.
function M.searchOrder(modules)
  local order = {}
  if modules and modules.folder then
    table.insert(order, { scope = 'project', folder = modules.folder })
  end
  if modules and modules.machineFolder then
    table.insert(order, { scope = 'machine', folder = modules.machineFolder })
  end
  return order
end

-- A source over places (searchOrder's shape). source(name) -> text, path  |  nil,
-- "<folder> or <folder>". loadText(path) -> string|nil defaults to FH's fhLoadTextFile;
-- injectable for tests.
function M.folderSource(places, loadText)
  loadText = loadText or function(path) return fhLoadTextFile(path, 'UTF-8') end
  local searched = {}
  for _, place in ipairs(places) do
    table.insert(searched, place.folder)
  end
  return function(name)
    for _, folder in ipairs(searched) do
      local path = folder .. '\\' .. name .. '.lua'
      local ok, text = pcall(loadText, path)
      if ok and type(text) == 'string' then
        return text, path
      end
    end
    return nil, table.concat(searched, ' or ')
  end
end

local function defaultListFolder(f)
  local fhfu = require('fhFileUtils')
  if not fhfu.folderExists(f) then return {} end
  return fhfu.getFolderContents(f, false, true)
end

-- Loads entry's module through require, on its own LIST_LOAD_LIMIT budget, and records
-- loaded, and loadError or exports (the module table's string keys, sorted) and doc (its
-- _DOC table of one-line descriptions).
local function describeLoad(entry, require)
  local ok, value = watchdog.isolated(M.LIST_LOAD_LIMIT, require, entry.name)
  entry.loaded = ok
  if not ok then
    entry.loadError = tostring(value)
    return
  end
  if type(value) ~= 'table' then
    return
  end
  local exports = {}
  for key in pairs(value) do
    if type(key) == 'string' and key ~= '_DOC' then
      table.insert(exports, key)
    end
  end
  table.sort(exports)
  entry.exports = exports
  if type(value._DOC) == 'table' then
    local doc = {}
    for key, line in pairs(value._DOC) do
      if type(key) == 'string' and type(line) == 'string' then
        doc[key] = line
      end
    end
    entry.doc = doc
  end
end

-- What is installed, for describe_project/fhBridge.listModules. modules = {folder=,
-- machineFolder=, listFolder=}, any of them nil; listFolder(folder) -> array of
-- {path=, size=, modified=} | false defaults to fhFileUtils.getFolderContents (tests inject).
-- require, when given, is the calling script's own: each module that would be used is loaded
-- through it, so loading runs the module's top-level code in that script's sandbox.
-- Returns { folder=, machineFolder=, modules = { {name=, scope="project"|"machine", size=,
-- modified=, shadowed=true when a project module of the same name wins, loaded=, loadError=,
-- exports=, doc=}, ... }, error=? }. Never errors.
function M.list(modules, require)
  modules = modules or {}
  local result = { folder = modules.folder, machineFolder = modules.machineFolder, modules = {} }
  local places = M.searchOrder(modules)
  if #places == 0 then
    result.error = 'no project is open and no machine-wide folder is known, so there is nothing to list'
    return result
  end
  local listFolder = modules.listFolder or defaultListFolder
  local problems = {}
  local inProject = {}
  for _, place in ipairs(places) do
    local ok, items = pcall(listFolder, place.folder)
    if not ok or not items then
      table.insert(problems, 'could not list ' .. place.folder .. ': ' .. tostring(items))
    else
      for _, item in ipairs(items) do
        local name = tostring(item.path or ''):match('([^\\/]+)%.lua$')
        if name and name:match(M.NAME_PATTERN) then
          local entry = { name = name, scope = place.scope, size = item.size, modified = item.modified }
          if place.scope == 'project' then
            inProject[name] = true
          elseif inProject[name] then
            entry.shadowed = true
          end
          table.insert(result.modules, entry)
        end
      end
    end
  end
  if require then
    for _, entry in ipairs(result.modules) do
      if not entry.shadowed then
        describeLoad(entry, require)
      end
    end
  end
  if #problems > 0 then
    result.error = table.concat(problems, '; ')
  end
  table.sort(result.modules, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.scope == 'project' and b.scope ~= 'project'
  end)
  return result
end

-- Builds the require() a run_lua script sees.
--   env: the script's own sandbox env, which every module compiles against.
--   source: see folderSource; nil means modules are unavailable in this context.
--   preScan(text) -> violation string | nil: runScript's text pre-scans, applied to each
--     module before it compiles.
-- Within one call, a module loads once and later requires get the same value. A module
-- that returns nothing yields true, as Lua's own require does. A module that fails to load
-- is not remembered, so a script that catches the error can require it again.
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
      error('require: user modules are not available here (no modules folder is known)', 2)
    end
    if loading[name] then
      error('require: module ' .. name .. ' requires itself, directly or through another module', 2)
    end

    local text, searched = source(name)
    if not text then
      error('require: no module ' .. name .. ' in ' .. tostring(searched), 2)
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

    -- Cleared on failure too: a stuck flag would turn a caught error into a false
    -- "requires itself" on the next require. Level 0 keeps the module's own file:line.
    loading[name] = true
    local ok, value = pcall(chunk)
    loading[name] = nil
    if not ok then
      error(value, 0)
    end
    if value == nil then
      value = true
    end
    loaded[name] = value
    return value
  end
end

return M
