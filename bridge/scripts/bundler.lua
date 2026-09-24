-- Bundling logic for the Bridge plugin: inlines its sibling Lua modules into the entry
-- file via package.preload, so the shipped/installed artifact is one self-contained file
-- per FH's own single-file plugin convention, while the source tree stays split for
-- standalone per-module testing (see docs/adr/0009-bundle-bridge-plugin-for-install.md).
--
-- Pure string logic, no file I/O of its own — see build.lua for the CLI that reads
-- bridge/*.lua from disk and writes bridge/dist/AI Assistant Connector.fh_lua.
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

-- The sibling modules the entry file requires, directly or transitively (sandbox.lua
-- requires sourceHelper.lua and sessionLogHelper.lua from inside a function body, not at
-- module load time). Order here is arbitrary — see the note above.
M.MODULE_NAMES = {
  "bridgeSession", "debugLog", "factHelper", "familyHelper", "jsonEncode", "requestFraming", "richTextHelper",
  "runScript", "sandbox", "sessionLogHelper", "sessionPolicy", "sessionSettings",
  "sourceHelper", "timeoutDisplay", "versionCompare", "watchdog",
}

-- Must match bridge/AI Assistant Connector.fh_lua's Install comment byte-for-byte — if that
-- comment changes, update this (buildBundle errors loudly instead of silently shipping a
-- bundle with the stale, dev-only install text).
local INSTALL_COMMENT_SOURCE = [[-- Install: this source form is split into sibling modules (require()'d below, including
-- bridgeSession.lua) purely so each one can be unit-tested standalone outside FH where
-- possible (see bridge/README.md) and, for bridgeSession.lua, so Serena can navigate it.
-- It is not itself the installable artifact — FH's own plugin convention expects one
-- file, and install_fh_plugin can only write one file per call (see docs/adr/0009). Build
-- the single-file artifact with:
--   lua bridge/scripts/build.lua
-- then copy just bridge/dist/AI Assistant Connector.fh_lua into FH's Plugins folder and load
-- it via Tools -> Plugins, same as any other plugin.]]

local INSTALL_COMMENT_BUNDLED = [[-- Install: this is a generated, self-contained build (docs/adr/0009) — every sibling
-- module below is bundled in via package.preload, so this one file is all FH's Plugins
-- folder needs. Do not hand-edit it — edit the source modules in bridge/ and rebuild
-- with: lua bridge/scripts/build.lua]]

-- Anchors where the bundle gets spliced in: right after fhInitialise(...), which per FH's
-- own docs (and this file's own comment above it) must be the first function this plugin
-- calls, before even require() — so the splice point has to come after it, never before.
local FH_INITIALISE_LINE = 'fhInitialise(8, 0, 0, "save_required")\n'

local function replaceOnce(haystack, needle, replacement, label)
  local startIdx, endIdx = haystack:find(needle, 1, true)
  if not startIdx then
    error(label .. ": expected text not found in the entry source — it changed since " ..
      "bundler.lua was last updated; update the matching constant in bundler.lua")
  end
  return haystack:sub(1, startIdx - 1) .. replacement .. haystack:sub(endIdx + 1)
end

-- server/package.json is the single source of truth for the Bridge's version (issue #89;
-- previously the @Version header itself was authoritative, per issue #45, which meant a
-- release could silently ship BRIDGE_VERSION out of sync with server/package.json if
-- whoever bumped the version forgot the header — see docs/release.md's version-drift
-- note). Pulled out of the raw package.json text with a plain pattern match rather than a
-- full JSON parser, matching this project's existing no-JSON-library stance (see
-- jsonEncode.lua's header comment: FH's Lua ships no JSON library, so JSON handling here
-- is hand-rolled rather than a dependency).
function M.extractPackageVersion(packageJsonContent)
  local version = packageJsonContent:match('"version"%s*:%s*"([^"]+)"')
  if not version then
    error("could not find a \"version\" field in server/package.json's content — " ..
      "its format changed or the file is empty; update bundler.lua or restore the field")
  end
  return version
end

-- The @Version header is now a stamped mirror of server/package.json's version (issue
-- #89), same pattern as stampLastUpdated below: fail loudly if the header is missing so a
-- changed/removed header can't silently stop being stamped, rather than shipping a bundle
-- whose header just goes stale.
local function stampVersion(entrySource, version)
  local existing = entrySource:match("@Version:%s*(%S+)")
  if not existing then
    error("could not find an @Version header in the entry source to stamp with the " ..
      "server/package.json version — the header changed or is missing; update bundler.lua " ..
      "or restore the header")
  end
  local stamped = entrySource:gsub("(@Version:%s*)%S+", "%1" .. version, 1)
  return stamped
end

-- The header's @LastUpdated date is hand-maintained in the source entry file but should
-- reflect when the shipped artifact was actually built, not when someone last remembered
-- to bump the comment by hand — so buildBundle stamps it with today's date on every build.
-- todayDate is injectable (defaults to os.date here) so tests can assert against a fixed
-- value instead of the real current date.
local function stampLastUpdated(entrySource, todayDate)
  local existing = entrySource:match("@LastUpdated:%s*(%S+)")
  if not existing then
    error("could not find an @LastUpdated header in the entry source to stamp with today's " ..
      "date — the header changed or is missing; update bundler.lua or restore the header")
  end
  local stamped = entrySource:gsub("(@LastUpdated:%s*)%S+", "%1" .. todayDate, 1)
  return stamped
end

-- entrySource: raw text of bridge/AI Assistant Connector.fh_lua.
-- readModule(name): function(name) -> raw text of bridge/<name>.lua.
-- packageVersion: server/package.json's version (see extractPackageVersion) — stamped into
--   the @Version header and injected as BRIDGE_VERSION below. Required; buildBundle errors
--   loudly rather than silently shipping an unversioned or stale-versioned bundle.
-- todayDate: optional "YYYY-MM-DD" override for the @LastUpdated stamp (default: today).
-- Returns the bundled source as a string.
function M.buildBundle(entrySource, readModule, packageVersion, todayDate)
  if not packageVersion or packageVersion == "" then
    error("buildBundle requires packageVersion (see extractPackageVersion) — got " ..
      tostring(packageVersion))
  end
  local out = stampVersion(entrySource, packageVersion)
  out = stampLastUpdated(out, todayDate or os.date("%Y-%m-%d"))
  out = replaceOnce(out, INSTALL_COMMENT_SOURCE, INSTALL_COMMENT_BUNDLED, "Install comment")

  local splitIdx = out:find(FH_INITIALISE_LINE, 1, true)
  if not splitIdx then
    error("could not find the fhInitialise(...) call to anchor the bundle splice point — " ..
      "the entry file changed; update FH_INITIALISE_LINE in bundler.lua")
  end
  local splitPoint = splitIdx + #FH_INITIALISE_LINE
  local before = out:sub(1, splitPoint - 1)
  local after = out:sub(splitPoint)

  local pieces = { before, "\n-- Bundled sibling modules (generated — see bridge/scripts/build.lua)\n" }
  table.insert(pieces, string.format("local BRIDGE_VERSION = %q -- injected from server/package.json (issue #89)\n", packageVersion))
  for _, name in ipairs(M.MODULE_NAMES) do
    table.insert(pieces, string.format("package.preload[%q] = function()\n%s\nend\n", name, readModule(name)))
  end
  table.insert(pieces, "-- End bundled sibling modules\n")
  table.insert(pieces, after)

  return table.concat(pieces)
end

return M
