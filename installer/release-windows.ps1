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

Write-Host "== Stage 2a: building server, bridge, and staging payload =="
& (Join-Path $installerDir 'stage.ps1')

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
