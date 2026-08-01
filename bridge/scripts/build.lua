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
os.execute('mkdir -p "' .. distDir .. '"')

local outPath = distDir .. "/Claude MCP Bridge.fh_lua"
local outFile, err = io.open(outPath, "wb")
if not outFile then
  error("could not write " .. outPath .. ": " .. tostring(err))
end
outFile:write(bundled)
outFile:close()

print("Wrote " .. outPath .. " (" .. #bundled .. " bytes)")
