import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { runLuaOnBridge as defaultRunLuaOnBridge } from "./bridgeClient.js";
import { describeBridgeConnectionError, interpretBridgeResponse } from "./bridgeResponse.js";

export interface RunLuaDeps {
  runLuaOnBridge: (script: string) => Promise<string>;
}

const defaultDeps: RunLuaDeps = { runLuaOnBridge: defaultRunLuaOnBridge };

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's "Clarifying
// question" entry and docs/adr/0001-arbitrary-sandboxed-lua-execution.md.
export const RUN_LUA_DESCRIPTION = `Execute a Lua script inside the FH Bridge's sandboxed environment, running live inside the user's own open Family Historian process, and return the script's result as JSON.

Requires an active Bridge Session (the user clicks Start in the Bridge's dialog first). If this tool reports that no Session is running, tell the user to click Start — do not retry automatically; there is no way for this tool to start a Session itself.

Before calling this tool, resolve any ambiguity in the user's question yourself: an unspecified generation depth, an ambiguous place-name spelling, or an unclear date boundary should be confirmed with the user first, rather than guessing and running a script against an assumed interpretation.

Before writing ANY script, search first — not optional, even for calls that feel familiar. Call search_fh_help (and search_gedcom_knowledge for domain/FTF concepts) for every FH function, item-pointer method, or fhUtils call you haven't already confirmed this conversation, rather than guessing and fixing it against the user's real project. This matters most for a read-write Session's tree mutations: before hand-rolling fhCreateItem/fhSetValueAsLink/fhDeleteItem, search_fh_help for whether fhu (require('fhUtils')) already has a purpose-built helper — e.g. fhu.createIndi, fhu.createFact, fhu.addFamilyAsChild/addFamilyAsSpouse — before reaching for low-level primitives.

This description may be truncated by your MCP client before it reaches you — some deferred tool-loading implementations cut long tool descriptions around 2KB. If this is your first run_lua call this conversation, call search_gedcom_knowledge("run_lua guidance") once regardless — it returns the call-shape gotchas, citeSource guidance, and writeSessionRolledBack handling that live past this point.

In a read-write Session, call \`fhBridge.logActivity(ptrRecord, action)\` after every record-touching action — creating an Individual, Family, or Source, adding or updating a Fact, anything that changes the tree — not just once at the end of the conversation. \`action\` is a short free-text description of what just happened, e.g. \`"created"\`. For an action about a specific Fact, compose \`action\` from \`fhGetDisplayText(ptrFact)\` on the Fact's own item pointer rather than a hand-typed label — e.g. \`action = "fact added " .. fhGetDisplayText(ptrFact)\` reads as something like \`"fact added Birth: 12 Jun 2010, London"\`, carrying the date/place FH already knows about instead of just the fact type. Each call appends one more entry to a single Research Note for the whole Session; the note itself is created automatically on the first call, so never create or manage one yourself, and never call \`logActivity\` in a Read-only Session or after a script that made no writes. When a source you discussed was backed by a physical or digital item (a photo, a certificate, a scanned document) that the user never actually attached as media in this Session, pass a third argument describing it — \`{name = "...", location = "..."}\` (location optional) — so that entry gets an indented \`#ToDo\` sub-line reminding the user to add it by hand afterwards; this project never touches the media file itself, only records the reminder.

The script runs inside a restricted, allowlist-only Lua environment (no filesystem or network access beyond FH's own read API). Write a fresh script tailored to each question — there is no fixed set of predefined queries — but "fresh" means newly composed for this question, not newly guessed at the API level.`;

export async function handleRunLua(
  input: { script: string },
  deps: RunLuaDeps = defaultDeps,
): Promise<CallToolResult> {
  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(input.script);
  } catch (err) {
    return describeBridgeConnectionError(err);
  }

  return interpretBridgeResponse(raw);
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
