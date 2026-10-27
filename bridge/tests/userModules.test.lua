-- Standalone tests for userModules.lua. Run with: lua bridge/tests/userModules.test.lua
-- No FH dependency: the file reader and folder lister are injected. runScript.test.lua
-- covers require() end to end inside a real sandbox env.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'
local userModules = require('userModules')
local t = require('testHelpers').new()
local check, contains = t.check, t.contains

local function errorOf(fn, ...)
  local ok, err = pcall(fn, ...)
  return not ok and tostring(err) or nil
end

-- folderFor
check(userModules.folderFor('C:\\Proj.fh_data') == 'C:\\Proj.fh_data\\Plugin Data\\AI Connector\\modules',
  'folderFor appends the Plugin Data modules subfolder')
check(userModules.folderFor('') == nil and userModules.folderFor(nil) == nil,
  'folderFor gives nil when there is no project data folder')

-- folderSource
do
  local asked
  local F = { { scope = 'project', folder = 'F' } }
  local source = userModules.folderSource(F, function(path) asked = path; return 'return 1' end)
  local text, where = source('lich')
  check(text == 'return 1' and where == 'F\\lich.lua' and asked == 'F\\lich.lua',
    'folderSource reads <folder>\\<name>.lua')
  local missing = userModules.folderSource(F, function() return nil end)
  local none, folder = missing('gone')
  check(none == nil and folder == 'F', 'folderSource reports the folder when the file is missing')
  local throwing = userModules.folderSource(F, function() error('disk on fire') end)
  check(throwing('x') == nil, 'folderSource treats a throwing loader as a missing file')

  local disk = { ['P\\both.lua'] = 'project copy', ['U\\both.lua'] = 'user copy', ['U\\shared.lua'] = 'shared' }
  local chained = userModules.folderSource(userModules.searchOrder({ folder = 'P', userFolder = 'U' }),
    function(path) return disk[path] end)
  check(chained('both') == 'project copy', 'folderSource prefers the first folder (the project) when both have the module')
  local sharedText, sharedPath = chained('shared')
  check(sharedText == 'shared' and sharedPath == 'U\\shared.lua', 'folderSource falls back to the user folder')
  local _, searched = chained('absent')
  check(searched == 'P or U', 'folderSource names every folder it searched')
end

-- userFolderFor / searchOrder
check(userModules.userFolderFor('C:\\Users\\me\\AppData\\Roaming\\Calico Pie\\Family Historian 8\\Plugin Data\\AI Connector (prototype)')
  == 'C:\\Users\\me\\AppData\\Roaming\\Calico Pie\\Family Historian 8\\Plugin Data\\AI Connector\\modules',
  'userFolderFor uses the fixed AI Connector folder beside whatever the plugin file is called')
check(userModules.userFolderFor('') == nil and userModules.userFolderFor(nil) == nil,
  'userFolderFor gives nil when FH returned nothing')
do
  local order = userModules.searchOrder({ userFolder = 'U' })
  check(#order == 1 and order[1].folder == 'U' and order[1].scope == 'user',
    'searchOrder skips a missing project folder without leaving a gap')
  local both = userModules.searchOrder({ folder = 'P', userFolder = 'U' })
  check(both[1].folder == 'P' and both[1].scope == 'project' and both[2].folder == 'U',
    'searchOrder puts the project before the user folder')
  check(#userModules.searchOrder(nil) == 0, 'searchOrder of nothing is empty')
end

-- foldersFromFH
do
  fhGetContextInfo = function(key) return key == 'CI_PROJECT_DATA_FOLDER' and 'C:\\Proj.fh_data' or nil end
  local askedScope
  fhGetPluginDataFileName = function(scope) askedScope = scope; return 'C:\\PD\\AI Connector' end
  local folders = userModules.foldersFromFH()
  check(folders.folder == 'C:\\Proj.fh_data\\Plugin Data\\AI Connector\\modules'
    and folders.userFolder == 'C:\\PD\\AI Connector\\modules', 'foldersFromFH asks FH for both folders')
  check(askedScope == 'CURRENT_USER', 'foldersFromFH asks for the CURRENT_USER scope, not LOCAL_MACHINE')
  fhGetPluginDataFileName = function() error('no such scope') end
  check(userModules.foldersFromFH().userFolder == nil, 'foldersFromFH leaves userFolder nil when FH raises')
  fhGetContextInfo, fhGetPluginDataFileName = nil, nil
end

-- list
do
  local listing = userModules.list({ folder = 'F', listFolder = function()
    return {
      { path = 'F\\zeta.lua', size = 10, modified = 'm1' },
      { path = 'F\\alpha.lua', size = 20, modified = 'm2' },
      { path = 'F\\notes.md', size = 5 },
      { path = 'F\\bad name.lua', size = 5 },
      { path = 'F\\tests', size = 0 },
    }
  end })
  check(listing.folder == 'F' and #listing.modules == 2, 'list keeps only valid-named .lua files')
  check(listing.modules[1].name == 'alpha' and listing.modules[2].name == 'zeta', 'list sorts by name')
  check(listing.modules[1].size == 20 and listing.modules[1].modified == 'm2', 'list carries size and modified')
  check(listing.modules[1].scope == 'project', 'list marks a project module as scope "project"')
  local failed = userModules.list({ folder = 'F', listFolder = function() error('Folder not found') end })
  check(#failed.modules == 0 and contains(failed.error, 'Folder not found'), 'list reports a listing failure without erroring')
  local nothing = userModules.list(nil)
  check(nothing.folder == nil and contains(nothing.error, 'no project'), 'list explains having no folder at all')

  local both = userModules.list({ folder = 'P', userFolder = 'U', listFolder = function(f)
    if f == 'P' then return { { path = 'P\\house.lua' } } end
    return { { path = 'U\\house.lua' }, { path = 'U\\common.lua' } }
  end })
  check(both.userFolder == 'U' and #both.modules == 3, 'list covers both the project and user folders')
  check(both.modules[1].name == 'common' and both.modules[1].scope == 'user', 'a module only in the user folder is scope "user"')
  check(both.modules[2].name == 'house' and both.modules[2].scope == 'project' and not both.modules[2].shadowed,
    'of two same-named modules the project one comes first and is used')
  check(both.modules[3].name == 'house' and both.modules[3].scope == 'user' and both.modules[3].shadowed == true,
    'the user one it overrides is marked shadowed')
  local userOnly = userModules.list({ userFolder = 'U', listFolder = function() return { { path = 'U\\x.lua' } } end })
  check(userOnly.error == nil and #userOnly.modules == 1, 'with no project open, list still lists the user folder')
  check(userOnly.modules[1].loaded == nil, 'without a require, list does not load anything')

  local required = {}
  local values = {
    house = { check = function() end, fix = function() end, _DOC = { check = 'Checks a person', [1] = 'ignored', fix = 42 } },
    plain = 'not a table',
  }
  local loader = function(name)
    table.insert(required, name)
    if values[name] == nil then error('broken.lua:3: boom', 0) end
    return values[name]
  end
  local described = userModules.list({ folder = 'P', userFolder = 'U', listFolder = function(f)
    if f == 'P' then return { { path = 'P\\house.lua' }, { path = 'P\\broken.lua' }, { path = 'P\\plain.lua' } } end
    return { { path = 'U\\house.lua' } }
  end }, loader)
  local byKey = {}
  for _, m in ipairs(described.modules) do byKey[m.name .. '/' .. m.scope] = m end
  local house = byKey['house/project']
  check(house.loaded == true and table.concat(house.exports, ',') == 'check,fix',
    'list loads a module and reports its exported names, sorted, without _DOC')
  check(house.doc.check == 'Checks a person' and house.doc.fix == nil and house.doc[1] == nil,
    'list reports _DOC, keeping only string-to-string entries')
  check(byKey['broken/project'].loaded == false and contains(byKey['broken/project'].loadError, 'broken.lua:3: boom'),
    'a module that fails to load is listed with loaded=false and its error')
  check(byKey['plain/project'].loaded == true and byKey['plain/project'].exports == nil,
    'a module returning a non-table loads but exports nothing')
  check(byKey['house/user'].shadowed and byKey['house/user'].loaded == nil,
    'a shadowed module is not loaded, since require would never reach it')
  local houseLoads = 0
  for _, name in ipairs(required) do if name == 'house' then houseLoads = houseLoads + 1 end end
  check(houseLoads == 1, 'list loads each name once')
end

-- list: the instruction budgets for loading
do
  local savedOne, savedTotal = userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT
  userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT = 20000, 30000
  local loader = function(name)
    if name:find('loop', 1, true) then while true do end end
    return { ok = true }
  end
  local listing = userModules.list({ folder = 'P', listFolder = function()
    return { { path = 'P\\c_fine.lua' }, { path = 'P\\b_loop.lua' }, { path = 'P\\a_loop.lua' } }
  end }, loader)
  userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT = savedOne, savedTotal
  local a, b, c = listing.modules[1], listing.modules[2], listing.modules[3]
  check(a.name == 'a_loop' and a.loaded == false and contains(a.loadError, 'instruction limit'),
    'a looping module fails on its own per-module budget')
  check(b.name == 'b_loop' and b.loaded == false and contains(b.loadError, 'instruction limit'),
    'a second looping module gets only what is left of the listing\'s total')
  check(c.name == 'c_fine' and c.loaded == false and contains(c.loadError, 'budget is spent'),
    'once the listing\'s total is spent, later modules are listed as not loaded, without running')
  check(debug.gethook() == nil, 'listing leaves no hook behind')
end

-- makeRequire
do
  local env = { tostring = tostring }
  local files = {
    one = 'return { value = 1 }',
    bom = '\239\187\191return "bom ok"',
    nothing = 'local x = 1',
    selfish = 'return require("selfish")',
    broken = 'return {',
  }
  env.require = userModules.makeRequire(env, function(name)
    if files[name] then return files[name], 'F\\' .. name .. '.lua' end
    return nil, 'F'
  end, function(text)
    if text:find('FORBIDDEN', 1, true) then return 'found FORBIDDEN' end
  end)
  files.forbidden = 'return FORBIDDEN'

  local one = env.require('one')
  check(one.value == 1, 'require returns the module value')
  check(env.require('one') == one, 'a second require in the same env returns the same value')
  check(env.require('bom') == 'bom ok', 'a UTF-8 BOM is stripped before compiling')
  check(env.require('nothing') == true, 'a module returning nothing yields true')
  check(contains(errorOf(env.require, '../etc'), 'letters, digits and underscores'), 'a path-like name is refused')
  check(contains(errorOf(env.require, 42), 'letters, digits and underscores'), 'a non-string name is refused')
  check(contains(errorOf(env.require, 'absent'), 'no module absent in F'), 'a missing module names the folder')
  check(contains(errorOf(env.require, 'forbidden'), 'forbidden.lua: found FORBIDDEN'), 'a pre-scan violation names the module')
  check(contains(errorOf(env.require, 'selfish'), 'requires itself'), 'a module requiring itself is caught')
  check(contains(errorOf(env.require, 'broken'), 'broken.lua'), 'a compile error names the module file')
  check(contains(errorOf(env.require, 'fhUtils'), 'fhu is already a global'), 'require of fhUtils points at the fhu global')
  check(contains(errorOf(env.require, 'caf\195\169'), 'letters, digits and underscores'),
    'a name with a non-ASCII letter is refused, whatever the locale')
  local unavailable = userModules.makeRequire({}, nil, nil)
  check(contains(errorOf(unavailable, 'one'), 'not available'), 'without a source, require says modules are unavailable')
end

-- makeRequire: modules requiring modules
do
  local env = { tostring = tostring, error = error }
  local files = {
    base = 'return { n = 2 }',
    top = 'local base = require("base")\nreturn { twice = base.n * 2 }',
    ping = 'require("pong")\nreturn "ping"',
    pong = 'require("ping")\nreturn "pong"',
    flaky = 'attempts = (attempts or 0) + 1\nif attempts == 1 then error("first try fails") end\nreturn "second try"',
  }
  env.require = userModules.makeRequire(env, function(name)
    if files[name] then return files[name], name end
    return nil, 'F'
  end)
  check(env.require('top').twice == 4, 'a module can require another module')
  check(contains(errorOf(env.require, 'ping'), 'requires itself'), 'a cycle through two modules is caught')
  files.pong = 'return "pong"'
  check(env.require('ping') == 'ping',
    'once the loop is broken, the same call loads both modules: a caught cycle leaves no stale loading flag')
  check(contains(errorOf(env.require, 'flaky'), 'flaky.lua:2: first try fails'),
    'a module that fails reports its own file and line')
  check(env.require('flaky') == 'second try',
    'a module that failed once can be required again in the same call, with no false "requires itself"')
end

-- No code path in userModules.lua writes a file: the folders are the user's, and copying a
-- module in by hand is the review checkpoint.
do
  local here = arg[0]:match("(.*[/\\])")
  local f = assert(io.open(here .. '../userModules.lua', 'r'))
  local text = f:read('a')
  f:close()
  local writers = { 'fhSaveTextFile', 'io%.', 'os%.', 'writeToTextFile', 'createFolder', 'copyFile', 'deleteFile', 'moveFile' }
  for _, pattern in ipairs(writers) do
    check(not text:find(pattern), 'userModules.lua never calls ' .. pattern:gsub('%%', ''))
  end
  for method in text:gmatch('fhfu%.([%w_]+)') do
    check(method == 'folderExists' or method == 'getFolderContents',
      'userModules.lua uses fhFileUtils only to look: ' .. method)
  end
end

t.report()
