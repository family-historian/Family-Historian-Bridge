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

Requires an active Bridge Session (user clicks Start in the Bridge dialog). If no Session is running, tell the user to click Start — don't retry automatically; this tool can't start a Session itself.

Resolve ambiguity in the user's question before calling this tool — an unspecified generation depth, ambiguous place-name spelling, or unclear date boundary gets confirmed with the user first, not guessed at.

Search first, not optional — call search_fh_help/search_gedcom_knowledge for any FH function, item-pointer method, or fhUtils call not yet confirmed this conversation, for reads and writes alike. Before hand-rolling MoveToFirstRecord/MoveNext or fhCreateItem/fhSetValueAsLink/fhDeleteItem, check whether fhu (already a global here — never require('fhUtils')) has a purpose-built helper: fhu.records/fhu.allItems for iteration, fhu.createIndi/createFact/addFamilyAsChild/addFamilyAsSpouse for mutation.

This description may be truncated by your MCP client around 2KB. On your first run_lua call this conversation, call search_gedcom_knowledge("run_lua guidance") once regardless — it returns the gotchas, citeSource, writeSessionRolledBack, fhu-global, and logActivity/session-log guidance living past this point.

In a read-write Session, call \`fhBridge.logActivity(ptrRecord, action)\` after every record-touching action, not just once at the end — an unlogged write gets rolled back (see the corpus entry above for call shape, the Research Note it creates, and the media/#ToDo option).

Write a fresh script per question, newly composed — not a guessed-at reuse of a remembered API shape; there is no fixed set of predefined queries.`;

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
