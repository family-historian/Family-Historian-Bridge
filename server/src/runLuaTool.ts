import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  queryBridgeVersion as defaultQueryBridgeVersion,
  runLuaOnBridge as defaultRunLuaOnBridge,
} from "./bridgeClient.js";
import { SERVER_VERSION } from "./serverVersion.js";
import { runVersionCheckedScript, type BridgeScriptDeps } from "./versionCheck.js";

export type RunLuaDeps = BridgeScriptDeps;

const defaultDeps: RunLuaDeps = {
  runLuaOnBridge: defaultRunLuaOnBridge,
  queryBridgeVersion: () => defaultQueryBridgeVersion(SERVER_VERSION),
};

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's "Clarifying
// question" entry and docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
export const RUN_LUA_DESCRIPTION = `Execute a Lua script inside the FH Bridge's sandboxed environment, running live inside the user's own open Family Historian process, and return the script's result as JSON. No filesystem/network access beyond FH's own read API.

Requires an active Bridge Session (user clicks Start in the Bridge dialog). If no Session is running, tell the user to click Start — don't retry automatically; it can't start one.

Never guess function or method names — search first, always, reads and writes alike. Reach for fhBridge's purpose-built helper before fhu, and fhu before hand-rolling MoveToFirstRecord/MoveNext or a raw fh* write — fhBridge.getFamilyGroup/getAncestors/getDescendants/getFactsByTag/findByNames/getAllDetails for family/detail queries, fhBridge.createFact/citeSource for writes; fhu.records/allItems for iteration (already a global here, never require('fhUtils')). Before ANY write-mode script, fetch the write-helper reference (createSourceFromTemplate, getTftfText/setTftfText, logActivity too) via search_gedcom_knowledge("run_lua guidance") if you haven't this task — an unlogged write gets rolled back, not just warned about.

Resolve ambiguity (generation depth, place-name spelling, date boundary) with the user before calling — never guess.

The write-helper/gotcha detail below may not reach you — some MCP clients truncate long tool descriptions. Call search_gedcom_knowledge("run_lua guidance") once, on your first run_lua call this conversation, regardless.

Call fhBridge.logActivity(ptrRecord, action) after every record-touching action, not just once at the end, in a read-write Session — an unlogged write gets rolled back.

Write a fresh script per question — never a guessed-at reuse of a remembered API shape; no predefined query set exists.`;

export async function handleRunLua(
  input: { script: string },
  deps: RunLuaDeps = defaultDeps,
): Promise<CallToolResult> {
  return runVersionCheckedScript(deps, SERVER_VERSION, input.script);
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
