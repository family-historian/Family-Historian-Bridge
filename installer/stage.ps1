<#
.SYNOPSIS
  Prepares installer/staging/ with everything fh-mcp-bridge.iss needs to package:
  a production-only copy of the server, a portable Node.js runtime, and the built
  Bridge plugin. Run this before compiling the installer with ISCC.

.DESCRIPTION
  - server/dist and bridge/dist are rebuilt from source, not just reused, so the
    installer always packages what's actually in the working tree.
  - The server's node_modules is reinstalled with --omit=dev into a separate staging
    copy, so devDependencies (typescript, vitest, @types/node) never end up in the
    installer, and the developer's own server/node_modules (used for `npm test`) is
    left untouched.
  - The portable Node runtime is downloaded once from nodejs.org and cached in
    installer/cache/, keyed by version, so repeated builds don't re-download it.
#>

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  throw "stage.ps1 builds the Windows installer payload and must run on Windows (detected: $(uname 2>$null))`nFor a Mac release, use installer/release-mac.sh instead."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerDir = Join-Path $repoRoot 'installer'
$stagingDir = Join-Path $installerDir 'staging'
$cacheDir = Join-Path $installerDir 'cache'

$nodeVersion = 'v24.16.0'
$nodeArch = 'win-x64'
$nodeZipName = "node-$nodeVersion-$nodeArch.zip"
$nodeCachedZip = Join-Path $cacheDir $nodeZipName
$nodeUrl = "https://nodejs.org/dist/$nodeVersion/$nodeZipName"

Write-Host "== Building server =="
Push-Location (Join-Path $repoRoot 'server')
try {
  npm run build
  if ($LASTEXITCODE -ne 0) { throw "server build failed" }
} finally {
  Pop-Location
}

Write-Host "== Building bridge plugin =="
$luaExe = 'C:\Utils\lua\lua.exe'
if (-not (Test-Path $luaExe)) {
  throw "Lua interpreter not found at $luaExe -- see memory/reference_lua_interpreter_location.md"
}
Push-Location $repoRoot
try {
  & $luaExe 'bridge/scripts/build.lua'
  if ($LASTEXITCODE -ne 0) { throw "bridge build failed" }
} finally {
  Pop-Location
}

Write-Host "== Staging production server (npm ci --omit=dev) =="
if (Test-Path $stagingDir) { Remove-Item -Recurse -Force $stagingDir }
New-Item -ItemType Directory -Force -Path (Join-Path $stagingDir 'server') | Out-Null

Copy-Item (Join-Path $repoRoot 'server\package.json') (Join-Path $stagingDir 'server\package.json')
Copy-Item (Join-Path $repoRoot 'server\package-lock.json') (Join-Path $stagingDir 'server\package-lock.json')
Copy-Item -Recurse (Join-Path $repoRoot 'server\dist') (Join-Path $stagingDir 'server\dist')
Copy-Item -Recurse (Join-Path $repoRoot 'server\data') (Join-Path $stagingDir 'server\data')

Push-Location (Join-Path $stagingDir 'server')
try {
  npm ci --omit=dev
  if ($LASTEXITCODE -ne 0) { throw "npm ci --omit=dev failed" }
} finally {
  Pop-Location
}

Write-Host "== Fetching portable Node runtime ($nodeVersion $nodeArch) =="
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
if (-not (Test-Path $nodeCachedZip)) {
  Write-Host "Downloading $nodeUrl"
  Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeCachedZip
} else {
  Write-Host "Using cached $nodeCachedZip"
}

$nodeExtractDir = Join-Path $stagingDir 'node-extract'
Expand-Archive -Path $nodeCachedZip -DestinationPath $nodeExtractDir -Force
$extractedNodeExe = Join-Path $nodeExtractDir "node-$nodeVersion-$nodeArch\node.exe"
if (-not (Test-Path $extractedNodeExe)) {
  throw "node.exe not found after extracting $nodeCachedZip (layout may have changed)"
}
Copy-Item $extractedNodeExe (Join-Path $stagingDir 'node.exe')
Remove-Item -Recurse -Force $nodeExtractDir

Write-Host "== Staging bridge plugin =="
New-Item -ItemType Directory -Force -Path (Join-Path $stagingDir 'bridge') | Out-Null
Copy-Item (Join-Path $repoRoot 'bridge\dist\Claude MCP Bridge.fh_lua') (Join-Path $stagingDir 'bridge\Claude MCP Bridge.fh_lua')

Write-Host "== Staging config-merge script =="
Copy-Item (Join-Path $installerDir 'config-merge.ps1') (Join-Path $stagingDir 'config-merge.ps1')

Write-Host "== Writing installer version include (from server/package.json) =="
$packageJson = Get-Content (Join-Path $repoRoot 'server\package.json') -Raw | ConvertFrom-Json
$appVersion = $packageJson.version
if (-not $appVersion) { throw "Could not read a version field from server/package.json" }
$versionIssPath = Join-Path $stagingDir 'version.iss'
Set-Content -Path $versionIssPath -Value "#define AppVersion `"$appVersion`""
Write-Host "AppVersion = $appVersion ($versionIssPath)"

Write-Host "`nStaging complete: $stagingDir"
