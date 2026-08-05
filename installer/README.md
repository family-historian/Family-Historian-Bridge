# Release build

Two-stage release, one stage per platform -- each script checks it's running on the
right OS and refuses otherwise:

1. **On a Mac**: `installer/release-mac.sh`
   Builds the server and bridge plugin, stages a production-only copy of the server
   (no devDependencies), and zips it as `installer/output/FH-MCP-Bridge-mac-<version>.zip`.
   Assumes the recipient already has Node.js installed; ships a `SETUP.md` with the
   manual finish steps (install the plugin into FH, add the MCP server to Claude
   Desktop's config).

2. **On Windows**: `installer/release-windows.ps1`
   Builds the server and bridge plugin, stages a production-only copy of the server
   plus a portable Node.js runtime (so the target machine needs no preinstalled
   Node), and compiles `fh-mcp-bridge.iss` with Inno Setup into
   `installer/output/FH-MCP-Bridge-Setup-<version>.exe`. That installer is closer to
   one-click: it installs per-user (no admin/UAC), auto-merges an `fh-mcp-bridge`
   entry into `claude_desktop_config.json` (replacing any previous entry under that
   key, leaving every other configured MCP server untouched), and offers to
   shell-execute the installed plugin file so Family Historian's own native prompt
   handles installing/registering it.

   Requires [Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install --id
   JRSoftware.InnoSetup -e`).

Neither script commits anything or touches the other platform's release -- run them
independently, in either order, whenever you want a fresh release artifact.

## Prototype: `.mcpb` (Claude Desktop Extension) bundle

`node installer/build-dxt.mjs [--verify]` builds a `.mcpb` bundle for the server --
`installer/output/fh-mcp-bridge-<version>.mcpb` -- installable via Claude Desktop's
Settings -> Extensions (or double-click/drag-and-drop) instead of the two scripts above.
This is issue #59's prototype, not yet wired into either release script: see
`docs/adr/0015-mcpb-bundle-manifest-is-generated-not-hand-copied.md` for why it needs no
bundled Node runtime (unlike the Windows installer) and how its manifest is generated
rather than hand-copied. `--verify` (or a separate `node installer/verify-dxt.mjs
<path>.mcpb`) extracts the built bundle and confirms its server actually starts and
registers the expected tools -- headlessly; it does not drive Claude Desktop's own install
UI, which still needs a hands-on check.
