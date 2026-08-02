#!/usr/bin/env bash
# Stage one of the two-stage release: builds a FH-MCP-Bridge-mac-<version>.zip for Mac
# users (Family Historian via CrossOver). Run this on a Mac, then run
# installer/release-windows.ps1 on Windows for stage two.
#
# Unlike the Windows installer, this does NOT vendor a portable Node runtime or
# auto-merge Claude Desktop's config -- it assumes the recipient already has Node (a
# safe assumption for anyone already running FH under CrossOver) and ships a short
# SETUP.md with the same manual finish steps as the main README.
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "release-mac.sh must run on a Mac (detected: $(uname)). For the Windows installer, use installer/release-windows.ps1 on Windows instead." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALLER_DIR="$REPO_ROOT/installer"

LUA_BIN="${LUA_BIN:-lua}"
if ! command -v "$LUA_BIN" >/dev/null 2>&1; then
  echo "Lua interpreter not found on PATH (looked for '$LUA_BIN')." >&2
  echo "Install one (e.g. 'brew install lua') or set LUA_BIN to its full path." >&2
  exit 1
fi

echo "== Building server =="
(cd "$REPO_ROOT/server" && npm install && npm run build)

echo "== Building bridge plugin =="
(cd "$REPO_ROOT" && "$LUA_BIN" bridge/scripts/build.lua)

VERSION="$(node -p "require('$REPO_ROOT/server/package.json').version")"

echo "== Staging production server (npm ci --omit=dev) =="
STAGE_DIR="$INSTALLER_DIR/mac-staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/server" "$STAGE_DIR/bridge"

cp "$REPO_ROOT/server/package.json" "$STAGE_DIR/server/"
cp "$REPO_ROOT/server/package-lock.json" "$STAGE_DIR/server/"
cp -R "$REPO_ROOT/server/dist" "$STAGE_DIR/server/dist"
cp -R "$REPO_ROOT/server/data" "$STAGE_DIR/server/data"

(cd "$STAGE_DIR/server" && npm ci --omit=dev)

echo "== Staging bridge plugin =="
cp "$REPO_ROOT/bridge/dist/Claude MCP Bridge.fh_lua" "$STAGE_DIR/bridge/Claude MCP Bridge.fh_lua"

echo "== Writing SETUP.md =="
cat > "$STAGE_DIR/SETUP.md" <<EOF
# FH MCP Bridge $VERSION -- Mac setup

This zip contains a pre-built copy of both halves of the Bridge -- no \`npm install\` or
lua build step needed. Requires Node.js (any current LTS) already installed.

1. Install the Bridge plugin into Family Historian (via CrossOver):
   copy \`bridge/Claude MCP Bridge.fh_lua\` into FH's Plugins folder under CrossOver's
   virtual C: drive, then in FH: Tools -> Plugins -> New, open it, click Run.
2. Add to Claude Desktop's MCP config
   (\`~/Library/Application Support/Claude/claude_desktop_config.json\`):
   \`\`\`json
   {
     "mcpServers": {
       "fh-mcp-bridge": {
         "command": "node",
         "args": ["/absolute/path/to/server/dist/index.js"]
       }
     }
   }
   \`\`\`
   Point \`args\` at the \`server/dist/index.js\` inside this unzipped folder, then
   restart Claude Desktop.

See the project's docs/user-guide.md for the full walkthrough.
EOF

echo "== Zipping release =="
mkdir -p "$INSTALLER_DIR/output"
ZIP_PATH="$INSTALLER_DIR/output/FH-MCP-Bridge-mac-$VERSION.zip"
rm -f "$ZIP_PATH"
(cd "$STAGE_DIR" && zip -r -X "$ZIP_PATH" . -x ".*")

echo ""
echo "Mac release ready: $ZIP_PATH"
