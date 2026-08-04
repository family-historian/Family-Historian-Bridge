-- Builds the Bridge plugin's single-file, installable artifact from source.
-- Run from the repo root: lua bridge/scripts/build.lua
-- Writes bridge/dist/Claude MCP Bridge.fh_lua — see bundler.lua for the bundling logic
-- and docs/adr/0009-bundle-bridge-plugin-for-install.md for why this exists.

local scriptDir = arg[0]:match("(.*/)")
if not scriptDir then
  error("run this as `lua bridge/scripts/build.lua` from the repo root, not by bare filename")
end
package.path = package.path .. ";" .. scriptDir .. "?.lua"
local bundler = require("bundler")

local bridgeDir = arg[0]:match("(.*/)scripts/build%.lua$")
if not bridgeDir then
  error("run this as `lua bridge/scripts/build.lua` from the repo root")
end

local function readFile(path)
  local f, err = io.open(path, "rb")
  if not f then
    error("could not open " .. path .. ": " .. tostring(err))
  end
  local content = f:read("*a")
  f:close()
  return content
end

local entrySource = readFile(bridgeDir .. "Claude MCP Bridge.fh_lua")
local function readModule(name)
  return readFile(bridgeDir .. name .. ".lua")
end

local bundled = bundler.buildBundle(entrySource, readModule)

local distDir = bridgeDir .. "dist"
local isWindows = package.config:sub(1, 1) == "\\"
if isWindows then
  os.execute('mkdir "' .. distDir .. '" >NUL 2>&1')
else
  os.execute('mkdir -p "' .. distDir .. '"')
end

-- Written with a leading UTF-8 BOM so FH's own file-encoding detection recognizes this
-- as UTF-8 rather than defaulting to ANSI (same reasoning, and the same EF BB BF marker,
-- as install_fh_plugin's UTF8_BOM in server/src/installFhPluginTool.ts — see
-- docs/adr/0008 decision 5). Confirmed necessary by testing live: an unmodified checkout
-- built without this BOM still loaded into FH as ANSI even after the entry file's own
-- fhSetStringEncoding("UTF-8") call was added, because that call only sets the *runtime*
-- string encoding — it does nothing for how FH's Plugin Editor/loader detects the file's
-- on-disk encoding before any of the script's own code has run.
local UTF8_BOM = string.char(0xEF, 0xBB, 0xBF)

local outPath = distDir .. "/Claude MCP Bridge.fh_lua"
local outFile, err = io.open(outPath, "wb")
if not outFile then
  error("could not write " .. outPath .. ": " .. tostring(err))
end
outFile:write(UTF8_BOM)
outFile:write(bundled)
outFile:close()

print("Wrote " .. outPath .. " (" .. #bundled .. " bytes)")
