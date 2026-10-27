-- User project modules: a sandboxed require() for run_lua scripts, loading helper modules
-- the user installs by hand: first from the open project's own modules folder, then from the
-- user folder, shared by all that user's projects.
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

-- Relative to FH's per-user Plugin Data folder. Fixed, not the running Bridge plugin's own
-- name, so a renamed Bridge plugin file still finds the same modules.
M.USER_SUBFOLDER = 'AI Connector\\modules'

-- Relative to CI_PROJECT_DATA_FOLDER: FH's own per-project Plugin Data folder, then
-- USER_SUBFOLDER.
M.PROJECT_SUBFOLDER = 'Plugin Data\\' .. M.USER_SUBFOLDER

-- ASCII letters, digits and underscores only, so a name can never reach outside the folder.
-- Spelt out rather than %w, whose meaning follows the C locale.
M.NAME_PATTERN = '^[A-Za-z0-9_]+$'

-- Instruction budgets for loading modules while listing, as fractions of the script's own
-- watchdog.INSTRUCTION_LIMIT: LIST_LOAD_LIMIT for any one module, so a module that loops fails
-- its own entry, not the listing or the describe_project call around it; LIST_TOTAL_LIMIT for
-- the whole listing, so however many modules loop, a listing adds at most a fifth.
M.LIST_LOAD_LIMIT = watchdog.INSTRUCTION_LIMIT // 10
M.LIST_TOTAL_LIMIT = watchdog.INSTRUCTION_LIMIT // 5

-- FH-shipped libraries a script might reach for by habit, keyed in lower case since module
-- names are matched ignoring case. The sandbox already provides fhu; the rest are
-- deliberately unavailable over run_lua.
local FH_LIBRARY_HINTS = {
  fhutils = 'fhu is already a global in run_lua -- use it directly',
  fhfileutils = 'filesystem access is not available over run_lua',
}

function M.projectFolderFor(projectDataFolder)
  if type(projectDataFolder) ~= 'string' or projectDataFolder == '' then
    return nil
  end
  return projectDataFolder .. '\\' .. M.PROJECT_SUBFOLDER
end

-- The user folder, from fhGetPluginDataFileName("CURRENT_USER")'s result ("<user's Plugin
-- Data>\<plugin name>"): its parent folder, then USER_SUBFOLDER. nil when FH returned nothing
-- usable. Take FH's answer, not its help: the help's paths for these scopes don't match
-- FH 8.
function M.userFolderFor(currentUserDataFile)
  if type(currentUserDataFile) ~= 'string' then
    return nil
  end
  local root = currentUserDataFile:match('^(.+)[\\/][^\\/]+$')
  if not root then
    return nil
  end
  return root .. '\\' .. M.USER_SUBFOLDER
end

-- Both folders for the open project, asked of FH: {folder=, userFolder=}, either nil when
-- FH can't say.
function M.foldersFromFH()
  local ok, userDataFile = pcall(fhGetPluginDataFileName, 'CURRENT_USER')
  return {
    folder = M.projectFolderFor(fhGetContextInfo('CI_PROJECT_DATA_FOLDER')),
    userFolder = ok and M.userFolderFor(userDataFile) or nil,
  }
end

-- The folders that are known, in search order: { {scope='project', folder=},
-- {scope='user', folder=} }, skipping either one that is nil.
function M.searchOrder(modules)
  local order = {}
  if modules and modules.folder then
    table.insert(order, { scope = 'project', folder = modules.folder })
  end
  if modules and modules.userFolder then
    table.insert(order, { scope = 'user', folder = modules.userFolder })
  end
  return order
end

local function fileExists(path)
  local ok, exists = pcall(function()
    local fhfu = require('fhFileUtils')
    return fhfu.fileExists(path)
  end)
  return ok and exists == true
end

-- A source over places (searchOrder's shape), reading with fhLoadTextFile. source(name) ->
-- {text=, path=} when found, {unreadable=path} when the file is there but fhLoadTextFile
-- couldn't read it, or {searched="<folder> or <folder>"} when it is in neither folder.
-- fhLoadTextFile gives nil for a missing and an unreadable file alike, so an unreadable
-- project module would otherwise fall through, silently, to a same-named one in the user
-- folder.
function M.folderSource(places)
  local searched = {}
  for _, place in ipairs(places) do
    table.insert(searched, place.folder)
  end
  return function(name)
    for _, folder in ipairs(searched) do
      local path = folder .. '\\' .. name .. '.lua'
      local ok, text = pcall(fhLoadTextFile, path, 'UTF-8')
      if ok and type(text) == 'string' then
        return { text = text, path = path }
      end
      if fileExists(path) then
        return { unreadable = path }
      end
    end
    return { searched = table.concat(searched, ' or ') }
  end
end

local function listFolder(folder)
  local fhfu = require('fhFileUtils')
  if not fhfu.folderExists(folder) then return {} end
  return fhfu.getFolderContents(folder, false, true)
end

-- Loads entry's module through loader.require on loader.budget, and records loaded, and
-- loadError or exports (the module table's string keys, sorted) and doc (its _DOC table of
-- one-line descriptions). A module this call has already loaded (loader.loadedValue) is
-- reported from that, at no cost. Once the budget is spent, any other module is reported as
-- not loaded without being run.
local function describeLoad(entry, loader)
  local ok, value = true, loader.loadedValue and loader.loadedValue(entry.name)
  if value == nil then
    if loader.budget.remaining <= 0 then
      entry.loaded = false
      entry.loadError = 'not loaded for the listing: the listing\'s instruction budget is spent'
      return
    end
    ok, value = watchdog.pcallWithBudget(loader.budget, loader.require, entry.name)
  end
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

-- The instruction budget for loading modules while listing: LIST_TOTAL_LIMIT in all, at most
-- LIST_LOAD_LIMIT for any one module.
function M.newListingBudget()
  return watchdog.newBudget(M.LIST_TOTAL_LIMIT, M.LIST_LOAD_LIMIT)
end

-- What is installed, for describe_project/fhBridge.listModules. modules = {folder=,
-- userFolder=}, either nil; each folder is listed with fhFileUtils.
-- loader, when given, is {require=, loadedValue=, budget=}: makeRequire's two functions for
-- the calling script, through which every module that isn't shadowed is loaded, in name order, so loading runs the module's
-- top-level code in that script's sandbox, outside the script's own watchdog count but
-- within budget (newListingBudget). Pass the same budget to every listing in one run_lua
-- call: a module that fails to load isn't remembered, so a fresh budget per listing would let
-- a script that lists in a loop run a looping module without limit. Without loader nothing
-- is loaded.
-- Returns { folder=, userFolder=, modules = { {name=, scope="project"|"user", size=,
-- modified=, shadowed=true when a project module of the same name wins, loaded=, loadError=,
-- exports=, doc=}, ... }, error=? }. Never errors.
function M.list(modules, loader)
  modules = modules or {}
  local result = { folder = modules.folder, userFolder = modules.userFolder, modules = {} }
  local places = M.searchOrder(modules)
  if #places == 0 then
    result.error = 'no project is open and no user folder is known, so there is nothing to list'
    return result
  end
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
          -- Windows file names ignore case, so House.lua in the project hides house.lua.
          if place.scope == 'project' then
            inProject[name:lower()] = true
          elseif inProject[name:lower()] then
            entry.shadowed = true
          end
          table.insert(result.modules, entry)
        end
      end
    end
  end
  if #problems > 0 then
    result.error = table.concat(problems, '; ')
  end
  table.sort(result.modules, function(a, b)
    local aKey, bKey = a.name:lower(), b.name:lower()
    if aKey ~= bKey then return aKey < bKey end
    if a.scope ~= b.scope then return a.scope == 'project' end
    return a.name < b.name
  end)
  if loader then
    for _, entry in ipairs(result.modules) do
      if not entry.shadowed then
        describeLoad(entry, loader)
      end
    end
  end
  return result
end

-- The levels, counted as its caller counts them, of fn's frames on the stack from level
-- `from` outwards.
local function framesOf(fn, from)
  local levels = {}
  local level = from
  while true do
    local info = debug.getinfo(level + 1, 'f')
    if not info then
      return levels
    end
    if info.func == fn then
      table.insert(levels, level)
    end
    level = level + 1
  end
end

-- The keys (the `key` local) of calls to requireFn still running up the stack, from `level`
-- outwards. Read from the stack rather than kept as flags, so an abort landing between a
-- module finishing and a flag being cleared can't leave a module marked as loading; and a
-- module's `return require(...)` tail call leaves that require's own frame in place.
-- require passes level 3: level 1 is this function and level 2 the require asking, whose own
-- key is already set, so starting lower would report every load as requiring itself.
local function requiresOnStack(requireFn, level)
  local keys = {}
  for _, at in ipairs(framesOf(requireFn, level)) do
    local i = 1
    repeat
      local localName, value = debug.getlocal(at, i)
      if localName == 'key' then
        keys[value] = true
      end
      i = i + 1
    until localName == nil
  end
  return keys
end

-- Whether fn has a call still running further up the stack than the function asking: frames
-- from level 3 outwards, since level 1 is this function and level 2 its caller, which may be
-- fn itself. From the stack, not a flag, for the reason given on requiresOnStack.
function M.isRunning(fn)
  return #framesOf(fn, 3) > 0
end

-- Builds the require() a run_lua script sees.
--   env: the script's own sandbox env, which every module compiles against.
--   source: see folderSource; nil means modules are unavailable in this context.
--   preScan(text) -> violation string | nil: runScript's text pre-scans, applied to each
--     module before it compiles.
-- Returns require, and loadedValue(name) -> the value require has already loaded for name in
-- this call, or nil.
-- Within one call, a module loads once and later requires get the same value, whatever the
-- case of the name, since Windows finds the same file either way. A module that returns
-- nothing yields true, as Lua's own require does. A module that fails to load is not
-- remembered, so a script that catches the error can require it again.
function M.makeRequire(env, source, preScan)
  local loaded = {}

  -- Level 3: the error belongs to whoever called require, not to require or to this.
  local function fail(message)
    error('require: ' .. message, 3)
  end

  local require
  function require(name)
    if type(name) ~= 'string' or not name:match(M.NAME_PATTERN) then
      fail('module names are letters, digits and underscores only, got ' .. tostring(name))
    end
    -- Named `key` on purpose: requiresOnStack reads this local to find cycles.
    local key = name:lower()
    if loaded[key] ~= nil then
      return loaded[key]
    end
    if FH_LIBRARY_HINTS[key] then
      fail(name .. ' -- ' .. FH_LIBRARY_HINTS[key])
    end
    if not source then
      fail('user project modules are not available here (no modules folder is known)')
    end
    if requiresOnStack(require, 3)[key] then
      fail('module ' .. name .. ' requires itself, directly or through another module')
    end

    local found = source(name)
    if found.unreadable then
      fail(found.unreadable .. ' is there but could not be read as UTF-8 text')
    end
    if not found.text then
      fail('no module ' .. name .. ' in ' .. tostring(found.searched))
    end
    local text = found.text
    -- A file saved by Notepad and friends starts with a UTF-8 BOM, which load() rejects.
    text = text:gsub('^\239\187\191', '')

    local violation = preScan and preScan(text)
    if violation then
      fail(name .. '.lua: ' .. violation)
    end

    local chunk, compileErr = load(text, '@' .. name .. '.lua', 't', env)
    if not chunk then
      fail(tostring(compileErr))
    end

    -- Level 0 keeps the module's own file:line.
    local ok, value = pcall(chunk)
    if not ok then
      error(value, 0)
    end
    if value == nil then
      value = true
    end
    loaded[key] = value
    return value
  end

  local function loadedValue(name)
    return loaded[name:lower()]
  end

  return require, loadedValue
end

return M
