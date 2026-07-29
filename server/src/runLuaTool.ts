import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  BridgeConnectionRefusedError,
  runLuaOnBridge as defaultRunLuaOnBridge,
} from "./bridgeClient.js";

export interface RunLuaDeps {
  runLuaOnBridge: (script: string) => Promise<string>;
}

const defaultDeps: RunLuaDeps = { runLuaOnBridge: defaultRunLuaOnBridge };

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's "Clarifying
// question" entry and docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
export const RUN_LUA_DESCRIPTION = `Execute a Lua script inside the FH Bridge's sandboxed environment, running live inside the user's own open Family Historian process, and return the script's result as JSON.

Requires an active Bridge Session (the user clicks Start in the Bridge's dialog first). If this tool reports that no Session is running, tell the user to click Start — do not retry automatically; there is no way for this tool to start a Session itself.

Before calling this tool, resolve any ambiguity in the user's question yourself: an unspecified generation depth, an ambiguous place-name spelling, or an unclear date boundary should be confirmed with the user first, rather than guessing and running a script against an assumed interpretation.

If you're unsure of the exact signature, argument shape, or calling convention of an FH function or item-pointer method you're about to use (e.g. what MoveToFirstChildItem takes, whether a parameter is optional, what fhGetItemText's data-reference syntax looks like), call search_fh_help for it BEFORE writing the script — the bundled FH8 API reference documents this precisely. Guessing and then fixing the guess by running it against the user's real, live project wastes round-trips on questions the help corpus already answers; only the project's own data (custom fact tags, field values) genuinely requires probing live.

A few call shapes that never vary and are easy to get wrong on a first guess:
- fhGetItemText(ptr, dataRef) always takes two arguments — the one-arg form fails with "Invalid number of arguments". To read an item's own value directly: fhGetItemText(itemPtr, "~").
- Descend with child:MoveToFirstChildItem(parentPtr) — the parent is the argument, not the receiver you're moving.
- MoveNext() walks siblings at the same level and goes Null at the end of the record; it does not continue into the next top-level record. There is no MoveToNextSiblingItem — that name doesn't exist in FH's API.
- Custom facts are usually not reachable by a data-reference string (~.FACT[1].TYPE and similar return empty) — walk child items with MoveToFirstChildItem/MoveNext and read each one's fhGetTag() instead.
- SEX resolves to the string "Male"/"Female", not "M"/"F" — a sex == "M" test silently matches nothing.
- Family Historian resolves custom facts to their own real tags (e.g. _ATTR-REGIMENT, EVEN-ENLISTED), not a generic FACT/EVEN plus a TYPE subtag the way they'd sit in a raw GEDCOM export — walking the tree gives you the resolved tag directly.

The script runs inside a restricted, allowlist-only Lua environment (no filesystem or network access beyond FH's own read API). Write a fresh script tailored to each question — there is no fixed set of predefined queries.`;

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text }], isError };
}

// bridge_prototype_v2.fh_lua (an earlier, superseded prototype plugin) answers any
// connection on the same port with a "PROJECT_NAME: ...\n...\nEND" handshake block
// instead of the current Bridge's JSON framing. Left running, it silently steals the
// port from bridge.fh_lua and every run_lua call fails with a raw JSON-parse error that
// doesn't name the actual cause — beta feedback, 2026-07-29.
function isStalePrototypeHandshake(raw: string): boolean {
  const trimmed = raw.trim();
  return trimmed.startsWith("PROJECT_NAME:") && trimmed.endsWith("END");
}

function isLuaErrorShape(value: unknown): value is { error: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.keys(value).length === 1 &&
    typeof (value as Record<string, unknown>).error === "string"
  );
}

export async function handleRunLua(
  input: { script: string },
  deps: RunLuaDeps = defaultDeps,
): Promise<CallToolResult> {
  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(input.script);
  } catch (err) {
    if (err instanceof BridgeConnectionRefusedError) {
      return textResult(
        "No FH Bridge Session is running — ask the user to click Start in the FH Bridge dialog before retrying.",
        true,
      );
    }
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Bridge communication error: ${message}`, true);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    if (isStalePrototypeHandshake(raw)) {
      return textResult(
        "This is the old bridge_prototype_v2 plugin answering on port 8734, not the current Bridge. Tell the user to Stop and close its dialog (it's modal, so it blocks Tools -> Plugins until closed), then load and Run bridge.fh_lua instead.",
        true,
      );
    }
    return textResult(
      `Bridge returned a response that could not be parsed as JSON: ${raw}`,
      true,
    );
  }

  // A script's own error path (compile error, runtime error) is wrapped by the Bridge
  // as exactly {"error": "<message>"} — see bridge/runScript.lua. A script that
  // legitimately returns a single-key {error: "..."} object as its own data would be
  // (mis)read the same way; accepted as a rare edge case of this wire shape rather than
  // a reason to redesign an already-shipped, manually-verified protocol (ticket #2).
  if (isLuaErrorShape(parsed)) {
    return textResult(`Script error: ${parsed.error}`, true);
  }

  return textResult(JSON.stringify(parsed));
}

export function registerRunLuaTool(
  server: McpServer,
  deps: RunLuaDeps = defaultDeps,
): void {
  server.registerTool(
    "run_lua",
    {
      description: RUN_LUA_DESCRIPTION,
      inputSchema: {
        script: z
          .string()
          .describe(
            "A Lua script to run inside the FH Bridge's sandbox. Must end with a `return` of the value to report back.",
          ),
      },
    },
    (input) => handleRunLua(input, deps),
  );
}
