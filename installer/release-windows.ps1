<#
.SYNOPSIS
  Stage two of the two-stage release: builds FH-MCP-Bridge-Setup-<version>.exe for
  Windows end users. Run installer/release-mac.sh first, on a Mac, for stage one.

.DESCRIPTION
  Runs stage.ps1 (rebuild + production-only server + portable Node runtime), then
  compiles fh-mcp-bridge.iss with Inno Setup's ISCC.exe. Aborts early if run on
  anything other than Windows, or if Inno Setup isn't installed.
#>

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  throw "release-windows.ps1 must run on Windows (detected: $(uname 2>$null)). For the Mac release, use installer/release-mac.sh on a Mac instead."
}

$installerDir = $PSScriptRoot

$isccCandidates = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
  throw "ISCC.exe (Inno Setup 6) not found. Install it first, e.g.:`n  winget install --id JRSoftware.InnoSetup -e"
}

$repoRoot = Split-Path -Parent $installerDir

$packageJson = Get-Content (Join-Path $repoRoot 'server\package.json') -Raw | ConvertFrom-Json
$version = $packageJson.version
if (-not $version) { throw "Could not read a version field from server/package.json" }

Write-Host "== Running all test suites =="
# Aggregate target at the repo root: server (vitest) + bridge (lua) + installer
# (node --test). Runs first so a release can't be built over a failing suite.
# stage.ps1 knows where lua.exe lives on this machine; tell the bridge runner too.
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js not found on PATH. Install it first (e.g. 'winget install --id OpenJS.NodeJS.LTS -e')."
}
Push-Location $repoRoot
try {
  & npm install --prefix server
  if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
  $env:LUA_BIN = 'C:\Utils\lua\lua.exe'
  & npm test
  if ($LASTEXITCODE -ne 0) { throw "test suites failed -- aborting release" }
} finally {
  Pop-Location
}

Write-Host "== Stage 2a: building server, bridge, and staging payload =="
& (Join-Path $installerDir 'stage.ps1')

# Prune Setup.exe installers left behind by earlier versions -- issue #93. Only this
# script's own naming pattern is touched -- release-mac.sh's .zip and build-dxt.mjs's
# .mcpb share this same output/ dir (the two-stage release runs on separate machines)
# and are left alone.
$outputDir = Join-Path $installerDir 'output'
if (Test-Path $outputDir) {
  Get-ChildItem $outputDir -Filter 'FH-MCP-Bridge-Setup-*.exe' |
    Where-Object { $_.Name -ne "FH-MCP-Bridge-Setup-$version.exe" } |
    ForEach-Object {
      Write-Host "== Pruning stale installer: $($_.Name) =="
      Remove-Item $_.FullName -Force
    }
}

Write-Host "== Stage 2b: compiling installer with $iscc =="
& $iscc (Join-Path $installerDir 'fh-mcp-bridge.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC compile failed" }

$outputExe = Get-ChildItem (Join-Path $installerDir 'output\*.exe') | Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Host "== Stage 2c: building .mcpb bundle (Claude Desktop Extension) =="
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js not found on PATH. Install it first (e.g. 'winget install --id OpenJS.NodeJS.LTS -e')."
}
node (Join-Path $installerDir 'build-dxt.mjs') --verify
if ($LASTEXITCODE -ne 0) { throw "build-dxt.mjs failed" }
$outputMcpb = Get-ChildItem (Join-Path $installerDir 'output\*.mcpb') | Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Host "`nWindows installer ready: $($outputExe.FullName)"
Write-Host ".mcpb bundle ready: $($outputMcpb.FullName)"
