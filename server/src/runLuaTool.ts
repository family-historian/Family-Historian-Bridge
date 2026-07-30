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

If you're unsure of the exact signature, argument shape, or calling convention of an FH function or item-pointer method you're about to use (e.g. what MoveToFirstChildItem takes, whether a parameter is optional, what fhGetItemText's data-reference syntax looks like), call search_fh_help for it BEFORE writing the script — the bundled FH8 API reference documents this precisely. Guessing and then fixing the guess by running it against the user's real, live project wastes round-trips on questions the help corpus already answers; only the project's own data (custom fact tags, field values) genuinely requires probing live.

A few call shapes that never vary and are easy to get wrong on a first guess:
- fhGetItemText(ptr, dataRef) always takes two arguments — the one-arg form fails with "Invalid number of arguments". To read an item's own value directly: fhGetItemText(itemPtr, "~").
- Descend with child:MoveToFirstChildItem(parentPtr) — the parent is the argument, not the receiver you're moving.
- MoveNext() walks siblings at the same level and goes Null at the end of the record; it does not continue into the next top-level record. There is no MoveToNextSiblingItem — that name doesn't exist in FH's API.
- Custom facts are usually not reachable by a data-reference string (~.FACT[1].TYPE and similar return empty) — walk child items with MoveToFirstChildItem/MoveNext and read each one's fhGetTag() instead.
- SEX resolves to the string "Male"/"Female", not "M"/"F" — a sex == "M" test silently matches nothing.
- Family Historian resolves custom facts to their own real tags (e.g. _ATTR-REGIMENT, EVEN-ENLISTED), not a generic FACT/EVEN plus a TYPE subtag the way they'd sit in a raw GEDCOM export — walking the tree gives you the resolved tag directly.
- A fact's Rejected flag always overrides its Preferred flag — a fact flagged both Rejected and Preferred is never treated as preferred. Don't read Preferred alone as "this is the one FH would display by default."
- fhGetItemText/fhGetValueAsText on a Notes (or other rich-text) field returns raw FTF markup literally (e.g. a table shows up as \`<table="800|800|800"> <row> apple | pear </row> </table>\`), not clean prose — use fhGetValueAsRichText(ptr):GetPlainText() instead when you need readable text. Call search_gedcom_knowledge for the fuller FTF/domain reference (Shared Facts, Source Template fields, Sentence templates, etc.) beyond what's inlined here.

The script runs inside a restricted, allowlist-only Lua environment (no filesystem or network access beyond FH's own read API). Write a fresh script tailored to each question — there is no fixed set of predefined queries.`;

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
