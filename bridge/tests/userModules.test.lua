-- Standalone tests for userModules.lua. Run with: lua bridge/tests/userModules.test.lua
-- No FH dependency: fhLoadTextFile and fhFileUtils are faked (testHelpers.fakeFhFiles).
-- runScript.test.lua covers require() end to end inside a real sandbox env.

package.path = package.path .. ';' .. arg[0]:match("(.*[/\\])") .. '../?.lua'
  .. ';' .. arg[0]:match("(.*[/\\])") .. '?.lua'
local userModules = require('userModules')
local watchdog = require('watchdog')
local testHelpers = require('testHelpers')
local t = testHelpers.new()
local check, contains = t.check, t.contains

local function errorOf(fn, ...)
  local ok, err = pcall(fn, ...)
  return not ok and tostring(err) or nil
end

local fake = testHelpers.fakeFhFiles()

-- projectFolderFor
check(userModules.projectFolderFor('C:\\Proj.fh_data') == 'C:\\Proj.fh_data\\Plugin Data\\AI Connector\\modules',
  'projectFolderFor appends the Plugin Data modules subfolder')
check(userModules.projectFolderFor('') == nil and userModules.projectFolderFor(nil) == nil,
  'projectFolderFor gives nil when there is no project data folder')

-- folderSource
do
  fake.files = { ['F\\lich.lua'] = 'return 1', ['F\\locked.lua'] = false }
  local source = userModules.folderSource({ { scope = 'project', folder = 'F' } })
  local found = source('lich')
  check(found.text == 'return 1' and found.path == 'F\\lich.lua', 'folderSource reads <folder>\\<name>.lua with fhLoadTextFile')
  local gone = source('gone')
  check(gone.text == nil and gone.searched == 'F', 'folderSource reports the folder when the file is missing')
  check(source('locked').unreadable == 'F\\locked.lua',
    'folderSource reports a file that is there but unreadable, not a missing one')

  local realLoad = fhLoadTextFile
  fhLoadTextFile = function() error('disk on fire') end
  check(source('gone').searched == 'F', 'folderSource treats fhLoadTextFile raising on an absent file as missing')
  fhLoadTextFile = realLoad

  fake.files = {
    ['P\\both.lua'] = 'project copy', ['U\\both.lua'] = 'user copy', ['U\\shared.lua'] = 'shared',
    ['P\\locked.lua'] = false, ['U\\locked.lua'] = 'user copy of locked',
  }
  local chained = userModules.folderSource(userModules.searchOrder({ folder = 'P', userFolder = 'U' }))
  check(chained('both').text == 'project copy', 'folderSource prefers the first folder (the project) when both have the module')
  local shared = chained('shared')
  check(shared.text == 'shared' and shared.path == 'U\\shared.lua', 'folderSource falls back to the user folder')
  check(chained('absent').searched == 'P or U', 'folderSource names every folder it searched')
  local locked = chained('locked')
  check(locked.text == nil and locked.unreadable == 'P\\locked.lua',
    'an unreadable project module is reported, not silently replaced by the user folder\'s copy')
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
  local found = userModules.foldersFromFH()
  check(found.folder == 'C:\\Proj.fh_data\\Plugin Data\\AI Connector\\modules'
    and found.userFolder == 'C:\\PD\\AI Connector\\modules', 'foldersFromFH asks FH for both folders')
  check(askedScope == 'CURRENT_USER', 'foldersFromFH asks for the CURRENT_USER scope, not LOCAL_MACHINE')
  fhGetPluginDataFileName = function() error('no such scope') end
  check(userModules.foldersFromFH().userFolder == nil, 'foldersFromFH leaves userFolder nil when FH raises')
  fhGetContextInfo, fhGetPluginDataFileName = nil, nil
end

-- list
do
  fake.folders = { F = {
    { path = 'F\\zeta.lua', size = 10, modified = 'm1' },
    { path = 'F\\alpha.lua', size = 20, modified = 'm2' },
    { path = 'F\\notes.md', size = 5 },
    { path = 'F\\bad name.lua', size = 5 },
    { path = 'F\\tests', size = 0 },
  } }
  local listing = userModules.list({ folder = 'F' })
  check(listing.folder == 'F' and #listing.modules == 2, 'list keeps only valid-named .lua files')
  check(listing.modules[1].name == 'alpha' and listing.modules[2].name == 'zeta', 'list sorts by name')
  check(listing.modules[1].size == 20 and listing.modules[1].modified == 'm2', 'list carries size and modified')
  check(listing.modules[1].scope == 'project', 'list marks a project module as scope "project"')
  fake.folders = {}
  local notYet = userModules.list({ folder = 'F' })
  check(#notYet.modules == 0 and notYet.error == nil, 'a folder that doesn\'t exist yet adds nothing and is not an error')
  fake.folders = { F = 'Folder not found' }
  local failed = userModules.list({ folder = 'F' })
  check(#failed.modules == 0 and contains(failed.error, 'Folder not found'), 'list reports a listing failure without erroring')
  local nothing = userModules.list(nil)
  check(nothing.folder == nil and contains(nothing.error, 'no project'), 'list explains having no folder at all')

  fake.folders = { P = { { path = 'P\\house.lua' } }, U = { { path = 'U\\house.lua' }, { path = 'U\\common.lua' } } }
  local both = userModules.list({ folder = 'P', userFolder = 'U' })
  check(both.userFolder == 'U' and #both.modules == 3, 'list covers both the project and user folders')
  check(both.modules[1].name == 'common' and both.modules[1].scope == 'user', 'a module only in the user folder is scope "user"')
  check(both.modules[2].name == 'house' and both.modules[2].scope == 'project' and not both.modules[2].shadowed,
    'of two same-named modules the project one comes first and is used')
  check(both.modules[3].name == 'house' and both.modules[3].scope == 'user' and both.modules[3].shadowed == true,
    'the user-folder one it overrides is marked shadowed')
  fake.folders = { P = { { path = 'P\\House.lua' } }, U = { { path = 'U\\house.lua' } } }
  local cased = userModules.list({ folder = 'P', userFolder = 'U' })
  local userHouse
  for _, m in ipairs(cased.modules) do if m.scope == 'user' then userHouse = m end end
  check(userHouse and userHouse.shadowed == true,
    'shadowing ignores case, as Windows does: a project House.lua hides a user-folder house.lua')
  fake.folders = { P = { { path = 'P\\house.lua' } }, U = { { path = 'U\\House.lua' }, { path = 'U\\alpha.lua' } } }
  local sorted = userModules.list({ folder = 'P', userFolder = 'U' })
  check(sorted.modules[1].name == 'alpha' and sorted.modules[2].scope == 'project' and sorted.modules[3].scope == 'user',
    'the list sorts ignoring case, with the project copy before a user-folder one that differs only in case')
  fake.folders = { U = { { path = 'U\\x.lua' } } }
  local userOnly = userModules.list({ userFolder = 'U' })
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
  fake.folders = {
    P = { { path = 'P\\house.lua' }, { path = 'P\\broken.lua' }, { path = 'P\\plain.lua' } },
    U = { { path = 'U\\house.lua' } },
  }
  local described = userModules.list({ folder = 'P', userFolder = 'U' }, { require = loader, budget = userModules.newListingBudget() })
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
  fake.folders = { P = { { path = 'P\\c_fine.lua' }, { path = 'P\\b_loop.lua' }, { path = 'P\\a_loop.lua' } } }
  local listing = userModules.list({ folder = 'P' }, { require = loader, budget = userModules.newListingBudget() })
  userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT = savedOne, savedTotal
  local a, b, c = listing.modules[1], listing.modules[2], listing.modules[3]
  check(a.name == 'a_loop' and a.loaded == false and contains(a.loadError, 'instruction limit'),
    'a looping module fails on its own per-module budget')
  check(b.name == 'b_loop' and b.loaded == false and contains(b.loadError, 'instruction limit'),
    'a second looping module gets only what is left of the listing\'s total')
  check(c.name == 'c_fine' and c.loaded == false and contains(c.loadError, 'budget is spent'),
    'once the listing\'s total is spent, later modules are listed as not loaded, without running')
  check(debug.gethook() == nil, 'listing leaves no hook behind')

  userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT = 20000, 30000
  local shared = userModules.newListingBudget()
  fake.folders = { P = { { path = 'P\\a_loop.lua' } } }
  local first = userModules.list({ folder = 'P' }, { require = loader, budget = shared })
  local second = userModules.list({ folder = 'P' }, { require = loader, budget = shared })
  local third = userModules.list({ folder = 'P' }, { require = loader, budget = shared })
  userModules.LIST_LOAD_LIMIT, userModules.LIST_TOTAL_LIMIT = savedOne, savedTotal
  check(contains(first.modules[1].loadError, 'instruction limit') and contains(second.modules[1].loadError, 'instruction limit'),
    'listings sharing a budget each run a looping module only on what is left of it')
  check(contains(third.modules[1].loadError, 'budget is spent'),
    'so listing again and again in one call can\'t run a looping module beyond the one total')

  local env = {}
  local loadedValue
  env.require, loadedValue = userModules.makeRequire(env, function(name)
    if name:lower() == 'ready' then return { text = 'return { go = true }', path = 'P\\ready.lua' } end
    return { searched = 'P' }
  end)
  env.require('ready')
  fake.folders = { P = { { path = 'P\\ready.lua' } } }
  local spent = userModules.list({ folder = 'P' },
    { require = env.require, loadedValue = loadedValue, budget = watchdog.newBudget(0, 0) })
  check(spent.modules[1].loaded == true and spent.modules[1].exports[1] == 'go',
    'a module this call has already loaded is listed as loaded, even with the listing\'s budget spent')
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
    if name == 'locked' then return { unreadable = 'F\\locked.lua' } end
    if files[name] then return { text = files[name], path = 'F\\' .. name .. '.lua' } end
    return { searched = 'F' }
  end, function(text)
    if text:find('FORBIDDEN', 1, true) then return 'found FORBIDDEN' end
  end)
  files.forbidden = 'return FORBIDDEN'

  local one = env.require('one')
  check(one.value == 1, 'require returns the module value')
  check(env.require('one') == one, 'a second require in the same env returns the same value')
  check(env.require('ONE') == one, 'a require differing only in case returns the same value, as Windows finds the same file')
  check(env.require('bom') == 'bom ok', 'a UTF-8 BOM is stripped before compiling')
  check(env.require('nothing') == true, 'a module returning nothing yields true')
  check(contains(errorOf(env.require, '../etc'), 'letters, digits and underscores'), 'a path-like name is refused')
  check(contains(errorOf(env.require, 42), 'letters, digits and underscores'), 'a non-string name is refused')
  check(contains(errorOf(env.require, 'absent'), 'no module absent in F'), 'a missing module names the folder')
  check(contains(errorOf(env.require, 'locked'), 'F\\locked.lua is there but could not be read'),
    'an unreadable module names the file, rather than saying it is missing')
  check(contains(errorOf(env.require, 'forbidden'), 'forbidden.lua: found FORBIDDEN'), 'a pre-scan violation names the module')
  check(contains(errorOf(env.require, 'selfish'), 'requires itself'), 'a module requiring itself is caught')
  check(contains(errorOf(env.require, 'broken'), 'broken.lua'), 'a compile error names the module file')
  check(contains(errorOf(env.require, 'fhUtils'), 'fhu is already a global'), 'require of fhUtils points at the fhu global')
  check(contains(errorOf(env.require, 'fhutils'), 'fhu is already a global'), 'the fhUtils hint ignores case too')
  check(userModules.LIST_LOAD_LIMIT == 5000000 and userModules.LIST_TOTAL_LIMIT == 10000000,
    'the listing budgets are a tenth and a fifth of the script\'s instruction limit')
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
    pingcase = 'require("PINGCASE")\nreturn "pingcase"',
    flaky = 'attempts = (attempts or 0) + 1\nif attempts == 1 then error("first try fails") end\nreturn "second try"',
  }
  env.require = userModules.makeRequire(env, function(name)
    local text = files[name:lower()]
    if text then return { text = text, path = name } end
    return { searched = 'F' }
  end)
  check(env.require('top').twice == 4, 'a module can require another module')
  check(contains(errorOf(env.require, 'ping'), 'requires itself'), 'a cycle through two modules is caught')
  check(contains(errorOf(env.require, 'pingcase'), 'requires itself'),
    'a module requiring itself under a different case is caught at once')
  files.pong = 'return "pong"'
  check(env.require('ping') == 'ping',
    'once the loop is broken, the same call loads both modules: a caught cycle leaves no stale loading flag')
  check(contains(errorOf(env.require, 'flaky'), 'flaky.lua:2: first try fails'),
    'a module that fails reports its own file and line')
  check(env.require('flaky') == 'second try',
    'a module that failed once can be required again in the same call, with no false "requires itself"')

  files.spin = 'while true do end'
  local _, firstErr = watchdog.pcallWithBudget(watchdog.newBudget(20000, 20000), env.require, 'spin')
  local _, secondErr = watchdog.pcallWithBudget(watchdog.newBudget(20000, 20000), env.require, 'spin')
  check(contains(tostring(firstErr), 'instruction limit') and contains(tostring(secondErr), 'instruction limit'),
    'a module stopped by its budget is never left marked as loading: a second try fails the same way, not as "requires itself"')
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
  local looks = { folderExists = true, getFolderContents = true, fileExists = true }
  for method in text:gmatch('fhfu%.([%w_]+)') do
    check(looks[method], 'userModules.lua uses fhFileUtils only to look: ' .. method)
  end
end

t.report()
