#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|NotebookEdit): this project's CLAUDE.md requires code edits to go
# through Serena's MCP tools, not the built-in Edit/Write/NotebookEdit. Blocks those tools on code
# file extensions; markdown/docs/config files are left alone. Write is allowed for a file that
# doesn't exist yet, since Serena's symbol tools have nothing to attach a brand-new file to.
input=$(cat)
tool=$(echo "$input" | jq -r '.tool_name // empty')
file=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')

[ -z "$file" ] && exit 0

case "$file" in
  *.ts | *.tsx | *.js | *.mjs | *.lua | *.sh | *.ps1)
    if [ "$tool" = "Write" ] && [ ! -e "$file" ]; then
      exit 0
    fi
    echo "Blocked: this project requires Serena's MCP tools for code edits, not $tool. Use replace_content / replace_symbol_body / insert_after_symbol / insert_before_symbol / rename_symbol / safe_delete_symbol instead (CLAUDE.md: \"use Serena for all edits\")." >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
