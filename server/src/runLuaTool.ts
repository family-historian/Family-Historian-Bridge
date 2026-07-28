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

The script runs inside a restricted, allowlist-only Lua environment (no filesystem or network access beyond FH's own read API). Write a fresh script tailored to each question — there is no fixed set of predefined queries.`;

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text }], isError };
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
