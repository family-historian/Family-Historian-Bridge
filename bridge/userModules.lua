-- User project modules (issue #150): a sandboxed require() for run_lua scripts, loading
-- helper modules the user installs by hand: first from the open project's own modules
-- folder, then from a machine-wide one shared by every project.
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

-- Relative to FH's machine-wide Plugin Data folder (FH 8: C:\ProgramData\Calico Pie\Family
-- Historian 8\Plugin Data). Fixed, not the running plugin's own name, so a renamed plugin file
-- still finds the same modules.
M.MACHINE_SUBFOLDER = 'AI Connector\\modules'

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

-- The machine-wide modules folder, from fhGetPluginDataFileName("LOCAL_MACHINE")'s result
-- ("<machine Plugin Data>\<plugin name>"): its parent folder, then MACHINE_SUBFOLDER. nil
-- when FH returned nothing usable. (FH's help gives a Plugins\Data path for that scope; FH 8
-- in fact returns Plugin Data beside the Plugins folder, so take FH's answer, not the help's.)
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

-- The folders require() searches, in order: project, then machine-wide; either may be nil.
function M.searchOrder(modules)
  local order = {}
  if modules and modules.folder then table.insert(order, modules.folder) end
  if modules and modules.machineFolder then table.insert(order, modules.machineFolder) end
  return order
end

-- A source over folders (an array, searched in order). source(name) -> text, path  |
-- nil, "<folder> or <folder>". loadText(path) -> string|nil defaults to FH's
-- fhLoadTextFile; injectable for tests.
function M.folderSource(folders, loadText)
  if type(folders) == 'string' then
    folders = { folders }
  end
  local searched = folders
  loadText = loadText or function(path) return fhLoadTextFile(path, 'UTF-8') end
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

-- What is installed, for describe_project/fhBridge.listModules. modules = {folder=,
-- machineFolder=, listFolder=}, any of them nil; listFolder(folder) -> array of
-- {path=, size=, modified=} | false defaults to fhFileUtils.getFolderContents (tests inject).
-- Returns { folder=, machineFolder=, modules = { {name=, scope="project"|"machine", size=,
-- modified=, shadowed=true when a project module of the same name wins}, ... }, error=? }.
-- Never errors.
function M.list(modules)
  modules = modules or {}
  local result = { folder = modules.folder, machineFolder = modules.machineFolder, modules = {} }
  if not modules.folder and not modules.machineFolder then
    result.error = 'no project is open and no machine-wide folder is known, so there is nothing to list'
    return result
  end
  local listFolder = modules.listFolder or defaultListFolder
  local problems = {}
  local inProject = {}
  for _, place in ipairs({ { scope = 'project', folder = modules.folder },
                           { scope = 'machine', folder = modules.machineFolder } }) do
    if place.folder then
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
      error('require: user modules are not available here (no modules folder is known)', 2)
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
