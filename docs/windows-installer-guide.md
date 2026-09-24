# FH MCP Bridge — Windows Installer (legacy): uninstalling

This installer (`FH-MCP-Bridge-Setup-X.Y.Z.exe`) is no longer the recommended way to install
FH MCP Bridge — see [docs/install.md](install.md) instead (see
[docs/adr/0035-manual-mcpb-install-as-interim-distribution-path.md](adr/0035-manual-mcpb-install-as-interim-distribution-path.md)
for why). This page only covers removing it if you already installed it this way.

## Uninstalling

Use Windows **Settings → Apps →** find **"FH MCP Bridge"** → **Uninstall**. This removes the
installed program files, but it does **not** remove the `fh-mcp-bridge` entry it added to
Claude Desktop's configuration, or the plugin file already loaded into FH — remove those
yourself if you want a completely clean removal:

- **Claude Desktop config**: open `%APPDATA%\Claude\claude_desktop_config.json` in Notepad
  and delete the `"fh-mcp-bridge"` entry under `"mcpServers"` (leave any other entries
  alone), then restart Claude Desktop.
- **FH plugin**: in Family Historian, open **Tools → Plugins**, find **"AI Assistant Connector"**,
  and remove it from there.

Once removed, see [docs/install.md](install.md) if you'd like to reinstall via the current,
supported path instead.
