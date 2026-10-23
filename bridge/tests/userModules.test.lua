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
  local source = userModules.folderSource('F', function(path) asked = path; return 'return 1' end)
  local text, where = source('lich')
  check(text == 'return 1' and where == 'F\\lich.lua' and asked == 'F\\lich.lua',
    'folderSource reads <folder>\\<name>.lua')
  local missing = userModules.folderSource('F', function() return nil end)
  local none, folder = missing('gone')
  check(none == nil and folder == 'F', 'folderSource reports the folder when the file is missing')
  local throwing = userModules.folderSource('F', function() error('disk on fire') end)
  check(throwing('x') == nil, 'folderSource treats a throwing loader as a missing file')

  local disk = { ['P\\both.lua'] = 'project copy', ['M\\both.lua'] = 'machine copy', ['M\\shared.lua'] = 'shared' }
  local chained = userModules.folderSource({ 'P', 'M' }, function(path) return disk[path] end)
  check(chained('both') == 'project copy', 'folderSource prefers the first folder (the project) when both have the module')
  local sharedText, sharedPath = chained('shared')
  check(sharedText == 'shared' and sharedPath == 'M\\shared.lua', 'folderSource falls back to the machine-wide folder')
  local _, searched = chained('absent')
  check(searched == 'P or M', 'folderSource names every folder it searched')
end

-- machineFolderFor / searchOrder
check(userModules.machineFolderFor('C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugin Data\\AI Connector (prototype)')
  == 'C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugin Data\\AI Connector\\modules',
  'machineFolderFor uses the fixed AI Connector folder beside whatever the plugin file is called')
check(userModules.machineFolderFor('') == nil and userModules.machineFolderFor(nil) == nil,
  'machineFolderFor gives nil when FH returned nothing')
do
  local order = userModules.searchOrder({ machineFolder = 'M' })
  check(#order == 1 and order[1] == 'M', 'searchOrder skips a missing project folder without leaving a gap')
  local both = userModules.searchOrder({ folder = 'P', machineFolder = 'M' })
  check(both[1] == 'P' and both[2] == 'M', 'searchOrder puts the project before the machine-wide folder')
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

  local both = userModules.list({ folder = 'P', machineFolder = 'M', listFolder = function(f)
    if f == 'P' then return { { path = 'P\\house.lua' } } end
    return { { path = 'M\\house.lua' }, { path = 'M\\common.lua' } }
  end })
  check(both.machineFolder == 'M' and #both.modules == 3, 'list covers both the project and machine-wide folders')
  check(both.modules[1].name == 'common' and both.modules[1].scope == 'machine', 'a machine-only module is scope "machine"')
  check(both.modules[2].name == 'house' and both.modules[2].scope == 'project' and not both.modules[2].shadowed,
    'of two same-named modules the project one comes first and is used')
  check(both.modules[3].name == 'house' and both.modules[3].scope == 'machine' and both.modules[3].shadowed == true,
    'the machine-wide one it overrides is marked shadowed')
  local machineOnly = userModules.list({ machineFolder = 'M', listFolder = function() return { { path = 'M\\x.lua' } } end })
  check(machineOnly.error == nil and #machineOnly.modules == 1, 'with no project open, list still lists the machine-wide folder')
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

  local unavailable = userModules.makeRequire({}, nil, nil)
  check(contains(errorOf(unavailable, 'one'), 'not available'), 'without a source, require says modules are unavailable')
end

t.report()
