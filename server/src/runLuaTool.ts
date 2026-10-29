import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  queryBridgeVersion as defaultQueryBridgeVersion,
  runLuaOnBridge as defaultRunLuaOnBridge,
} from "./bridgeClient.js";
import { resolveAssistantName } from "./assistantName.js";
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

Never guess function or method names — search first, always, reads and writes alike. Reach for fhBridge's purpose-built helper before fhu, and fhu before hand-rolling MoveToFirstRecord/MoveNext or a raw fh* write — fhBridge.getFamilyGroup/getAncestors/getDescendants/getFactsByTag/getPersonEvents/findByNames/getAllDetails for family/detail queries, fhBridge.createFact/citeSource for writes (fhu is already a global here; require() loads user modules). fhBridge helpers apply the Session's Private/Living Visibility settings; fhu.records/allItems and raw MoveToFirstRecord don't, and are rejected while either is restricted. Before ANY write-mode script, fetch the write-helper reference (createSourceFromTemplate, getTftfText/setTftfText, logActivity too) via search_gedcom_knowledge("run_lua guidance") if you haven't this task — an unlogged write gets rolled back, not just warned about.

Resolve ambiguity (generation depth, place spelling, date boundary) with the user before calling — never guess.

The write-helper/gotcha detail below may not reach you — some MCP clients truncate long tool descriptions. Call search_gedcom_knowledge("run_lua guidance") once, on your first run_lua call this conversation, regardless.

Call fhBridge.logActivity(ptrRecord, action) after every record-touching action, not just once at the end, in a read-write Session — an unlogged write gets rolled back.

Write a fresh script per question.

If a person is redacted/Excluded, stop. Never get their data another way.`;

export async function handleRunLua(
  input: { script: string; assistant?: string },
  deps: RunLuaDeps = defaultDeps,
  clientName?: string | null,
): Promise<CallToolResult> {
  const assistant = resolveAssistantName(input.assistant, clientName);
  return runVersionCheckedScript(deps, SERVER_VERSION, input.script, assistant, "run_lua");
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
        assistant: z
          .string()
          .optional()
          .describe(
            "Your own name as an AI assistant (e.g. Claude, Codex, ChatGPT, Gemini). Titles the session's Research Note log; pass it on every call.",
          ),
      },
    },
    (input) => handleRunLua(input, deps, server.server.getClientVersion()?.name),
  );
}
