; Inno Setup script for the FH MCP Bridge installer.
; Run installer\stage.ps1 first to populate installer\staging\, then compile this with
; ISCC.exe (Inno Setup 6). Keep AppVersion below in sync with server/package.json's version.
;
; What this installs (per-user, no admin/UAC required):
;   - A portable Node.js runtime (node.exe only) and the production-only server build,
;     so the target machine needs no preinstalled Node -- see docs/adr for why.
;   - The single-file Bridge plugin (Claude MCP Bridge.fh_lua).
;   - Merges an "fh-mcp-bridge" entry into Claude Desktop's config (config-merge.ps1),
;     replacing any previous entry under that same key rather than duplicating it.
;     Run from [Code] (not a declarative [Run] entry) so a failure is never silent --
;     see RunConfigMerge below and config-merge.ps1's own log file.
;
; Deliberately does NOT try to detect FH's Plugins folder and copy the file there itself:
; shell-executing the .fh_lua file (the optional last step below) makes Family Historian
; offer to install it via its own native prompt, which handles that placement -- see
; bridge/README.md and docs/user-guide.md ("double-click it on Windows... FH's own
; Tools -> Plugins -> New (or Import)").

#define AppVersion "0.5.0"

[Setup]
AppId={{B6C6C6D1-6F0E-4B3F-9C7B-2A6D6C6F5E10}
AppName=FH MCP Bridge
AppVersion={#AppVersion}
AppPublisher=Jane
DefaultDirName={localappdata}\Programs\FH MCP Bridge
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=output
OutputBaseFilename=FH-MCP-Bridge-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
Uninstallable=yes

[Files]
Source: "staging\node.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "staging\config-merge.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "staging\server\package.json"; DestDir: "{app}\server"; Flags: ignoreversion
Source: "staging\server\dist\*"; DestDir: "{app}\server\dist"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "staging\server\data\*"; DestDir: "{app}\server\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "staging\server\node_modules\*"; DestDir: "{app}\server\node_modules"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "staging\bridge\Claude MCP Bridge.fh_lua"; DestDir: "{app}\bridge"; Flags: ignoreversion

[Run]
Filename: "{app}\bridge\Claude MCP Bridge.fh_lua"; \
  Description: "Open the Bridge plugin in Family Historian now"; \
  Flags: postinstall shellexec skipifsilent

[Messages]
FinishedLabel=Setup has finished installing FH MCP Bridge.%n%nClaude Desktop's configuration has been updated to use it -- restart Claude Desktop if it was already running. If you leave the box below checked, Family Historian will open next and offer to install the Bridge plugin.

[Code]
// Runs config-merge.ps1 explicitly (rather than via a declarative [Run] entry) so a
// failure -- of the kind that happened silently once already, with no error shown and
// no trace left behind -- is always visible and always leaves a diagnosable trail.
procedure RunConfigMerge();
var
  ResultCode: Integer;
  Params: String;
  LogPath: String;
  PowerShellExe: String;
begin
  PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\config-merge.ps1') +
    '" -InstallDir "' + ExpandConstant('{app}') + '"';

  if not Exec(PowerShellExe, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    MsgBox('FH MCP Bridge installed, but could not launch PowerShell to configure Claude Desktop (Windows error ' +
      IntToStr(ResultCode) + ').' + #13#10 +
      'You can run this step yourself afterwards: ' + ExpandConstant('{app}\config-merge.ps1'),
      mbError, MB_OK);
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    LogPath := ExpandConstant('{app}\config-merge.log');
    MsgBox('FH MCP Bridge installed, but updating Claude Desktop''s configuration failed (exit code ' +
      IntToStr(ResultCode) + ').' + #13#10#13#10 +
      'See the log for details: ' + LogPath + #13#10#13#10 +
      'You can re-run it yourself afterwards: ' + ExpandConstant('{app}\config-merge.ps1'),
      mbError, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RunConfigMerge();
end;
