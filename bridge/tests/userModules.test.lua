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
end

-- list
do
  local listing = userModules.list('F', function()
    return {
      { path = 'F\\zeta.lua', size = 10, modified = 'm1' },
      { path = 'F\\alpha.lua', size = 20, modified = 'm2' },
      { path = 'F\\notes.md', size = 5 },
      { path = 'F\\bad name.lua', size = 5 },
      { path = 'F\\tests', size = 0 },
    }
  end)
  check(listing.folder == 'F' and #listing.modules == 2, 'list keeps only valid-named .lua files')
  check(listing.modules[1].name == 'alpha' and listing.modules[2].name == 'zeta', 'list sorts by name')
  check(listing.modules[1].size == 20 and listing.modules[1].modified == 'm2', 'list carries size and modified')
  local failed = userModules.list('F', function() error('Folder not found') end)
  check(#failed.modules == 0 and contains(failed.error, 'Folder not found'), 'list reports a listing failure without erroring')
  local noProject = userModules.list(nil)
  check(noProject.folder == nil and contains(noProject.error, 'no project'), 'list explains a missing folder')
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
