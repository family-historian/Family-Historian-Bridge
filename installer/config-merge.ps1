<#
.SYNOPSIS
  Adds/replaces the "fh-mcp-bridge" entry in Claude Desktop's MCP server config,
  leaving every other entry untouched. Invoked by the installer's [Code] section
  (not a declarative [Run] entry -- see fh-mcp-bridge.iss) so its exit code and log
  can be checked explicitly instead of failing silently.

.PARAMETER InstallDir
  The folder fh-mcp-bridge was installed into (contains node.exe and server\dist\index.js).

.NOTES
  Targets Windows PowerShell 5.1 (ConvertFrom-Json returns PSCustomObject, no
  -AsHashtable there), since that's the minimum guaranteed on a clean Windows machine.

  Every run appends one line to config-merge.log next to this script, whether it
  succeeds or fails, so there's always a trail even if a MsgBox gets missed or the
  install runs silently. Exits 1 on any failure so the caller can detect it.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDir
)

$logPath = Join-Path $InstallDir 'config-merge.log'

function Write-Log([string]$message) {
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $message
  Add-Content -Path $logPath -Value $line
}

try {
  $ErrorActionPreference = 'Stop'

  $configDir = Join-Path $env:APPDATA 'Claude'
  $configPath = Join-Path $configDir 'claude_desktop_config.json'

  New-Item -ItemType Directory -Force -Path $configDir | Out-Null

  if (Test-Path $configPath) {
    Copy-Item $configPath "$configPath.bak" -Force
    $raw = Get-Content -Path $configPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
      $config = New-Object PSObject
    } else {
      $config = $raw | ConvertFrom-Json
    }
  } else {
    $config = New-Object PSObject
  }

  if (-not ($config.PSObject.Properties.Name -contains 'mcpServers')) {
    $config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue (New-Object PSObject)
  }

  $nodeExe = Join-Path $InstallDir 'node.exe'
  $serverEntry = Join-Path $InstallDir 'server\dist\index.js'

  $newEntry = New-Object PSObject
  $newEntry | Add-Member -NotePropertyName 'command' -NotePropertyValue $nodeExe
  $newEntry | Add-Member -NotePropertyName 'args' -NotePropertyValue @($serverEntry)

  if ($config.mcpServers.PSObject.Properties.Name -contains 'fh-mcp-bridge') {
    $config.mcpServers.'fh-mcp-bridge' = $newEntry
  } else {
    $config.mcpServers | Add-Member -NotePropertyName 'fh-mcp-bridge' -NotePropertyValue $newEntry
  }

  $json = $config | ConvertTo-Json -Depth 10
  # Set-Content -Encoding UTF8 on Windows PowerShell 5.1 always writes a UTF-8 BOM, which
  # broke Claude Desktop's own config parser on restart (confirmed 2026-08-02: it choked
  # on the leading BOM even though the JSON itself was valid). Write BOM-less UTF-8 via
  # .NET directly instead -- utf8NoBOM as a -Encoding value isn't available before
  # PowerShell 6, so this can't just be a Set-Content flag.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)

  Write-Log "OK: updated $configPath (backed up to claude_desktop_config.json.bak)"
  exit 0
} catch {
  Write-Log "FAILED: $($_.Exception.Message)"
  Write-Log ($_.ScriptStackTrace)
  exit 1
}
