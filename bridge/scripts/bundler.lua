-- Bundling logic for the Bridge plugin: inlines its sibling Lua modules into the entry
-- file via package.preload, so the shipped/installed artifact is one self-contained file
-- per FH's own single-file plugin convention, while the source tree stays split for
-- standalone per-module testing (see docs/adr/0009-bundle-bridge-plugin-for-install.md).
--
-- Pure string logic, no file I/O of its own — see build.lua for the CLI that reads
-- bridge/*.lua from disk and writes bridge/dist/Claude MCP Bridge.fh_lua.
--
-- package.preload[name] = function() <module body> end works because Lua's require()
-- checks package.preload before ever touching the filesystem — so every require(name)
-- call already in the entry file and in the bundled modules themselves (e.g. sandbox.lua
-- requiring sourceHelper.lua) keeps working completely unmodified, textually untouched.
-- Load order among the preload entries below doesn't matter: assigning
-- package.preload[name] just registers a closure, it doesn't run the module body — that
-- only happens the first time something actually calls require(name), same as with real
-- files.

local M = {}

-- The eight sibling modules the entry file requires, directly or transitively (sandbox.lua
-- requires sourceHelper.lua and sessionLogHelper.lua from inside a function body, not at
-- module load time). Order here is arbitrary — see the note above.
M.MODULE_NAMES = {
  "jsonEncode", "requestFraming", "runScript", "sandbox", "sessionLogHelper", "sourceHelper",
  "timeoutDisplay", "watchdog",
}

-- Must match bridge/Claude MCP Bridge.fh_lua's Install comment byte-for-byte — if that
-- comment changes, update this (buildBundle errors loudly instead of silently shipping a
-- bundle with the stale, dev-only install text).
local INSTALL_COMMENT_SOURCE = [[-- Install: this source form is split into sibling modules (require()'d below) purely so
-- each one can be unit-tested standalone outside FH (see bridge/README.md). It is not
-- itself the installable artifact — FH's own plugin convention expects one file, and
-- install_fh_plugin can only write one file per call (see docs/adr/0009). Build the
-- single-file artifact with:
--   lua bridge/scripts/build.lua
-- then copy just bridge/dist/Claude MCP Bridge.fh_lua into FH's Plugins folder and load
-- it via Tools -> Plugins, same as any other plugin.]]

local INSTALL_COMMENT_BUNDLED = [[-- Install: this is a generated, self-contained build (docs/adr/0009) — every sibling
-- module below is bundled in via package.preload, so this one file is all FH's Plugins
-- folder needs. Do not hand-edit it — edit the source modules in bridge/ and rebuild
-- with: lua bridge/scripts/build.lua]]

-- Anchors where the bundle gets spliced in: right after fhInitialise(...), which per FH's
-- own docs (and this file's own comment above it) must be the first function this plugin
-- calls, before even require() — so the splice point has to come after it, never before.
local FH_INITIALISE_LINE = 'fhInitialise(7, 0, 0, "save_required")\n'

local function replaceOnce(haystack, needle, replacement, label)
  local startIdx, endIdx = haystack:find(needle, 1, true)
  if not startIdx then
    error(label .. ": expected text not found in the entry source — it changed since " ..
      "bundler.lua was last updated; update the matching constant in bundler.lua")
  end
  return haystack:sub(1, startIdx - 1) .. replacement .. haystack:sub(endIdx + 1)
end

-- entrySource: raw text of bridge/Claude MCP Bridge.fh_lua.
-- readModule(name): function(name) -> raw text of bridge/<name>.lua.
-- Returns the bundled source as a string.
function M.buildBundle(entrySource, readModule)
  local out = replaceOnce(entrySource, INSTALL_COMMENT_SOURCE, INSTALL_COMMENT_BUNDLED, "Install comment")

  local splitIdx = out:find(FH_INITIALISE_LINE, 1, true)
  if not splitIdx then
    error("could not find the fhInitialise(...) call to anchor the bundle splice point — " ..
      "the entry file changed; update FH_INITIALISE_LINE in bundler.lua")
  end
  local splitPoint = splitIdx + #FH_INITIALISE_LINE
  local before = out:sub(1, splitPoint - 1)
  local after = out:sub(splitPoint)

  local pieces = { before, "\n-- Bundled sibling modules (generated — see bridge/scripts/build.lua)\n" }
  for _, name in ipairs(M.MODULE_NAMES) do
    table.insert(pieces, string.format("package.preload[%q] = function()\n%s\nend\n", name, readModule(name)))
  end
  table.insert(pieces, "-- End bundled sibling modules\n")
  table.insert(pieces, after)

  return table.concat(pieces)
end

return M
