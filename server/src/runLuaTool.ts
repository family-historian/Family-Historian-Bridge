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

Before writing ANY script, search first — this is not optional and not just for cases where you notice you're unsure. Call search_fh_help (and search_gedcom_knowledge for domain/FTF concepts) for every FH function, item-pointer method, or fhUtils call you're about to use that you have not already confirmed in this same conversation, even ones that feel familiar or "obviously" work the way an equivalent in another API would. The bundled FH8 API reference documents exact signatures, argument counts, and calling conventions precisely; guessing and fixing the guess by running it against the user's real, live project wastes round-trips on questions the help corpus already answers outright. Only the project's own data (custom fact tags, field values, record counts) genuinely requires probing live — never the shape of a function call.

This matters most, not least, for anything that creates, links, deletes, or reorders records (a read-write Session) — those calls are the hardest to verify after the fact and the least reversible to get wrong. Before hand-rolling a tree mutation with the low-level primitives (fhCreateItem, fhSetValueAsLink, fhDeleteItem, fhMoveItemAfter/Before), search_fh_help for whether fhUtils (require('fhUtils'), exposed in the sandbox as fhu) already has a purpose-built helper for exactly this operation — e.g. fhu.addFamilyAsChild/addFamilyAsSpouse, fhu.createFamilyAsChild/createFamilyAsSpouse, fhu.createIndi, fhu.createFact, fhu.createUpdateItem, fhu.addWitness. fhUtils' full function reference (fhFileUtils/fhSQL/fhUtils, ~39 fhUtils entries including PCite's methods) is in the bundled corpus under search_fh_help, indexed by function name — search for the operation you're about to do (e.g. "add child to family") before assuming no helper exists and reaching for the low-level primitives yourself.

A few call shapes that never vary and are easy to get wrong on a first guess — searching would have caught each of these, they're listed here only so the same mistake isn't repeated twice:
- fhGetItemText(ptr, dataRef) always takes two arguments — the one-arg form fails with "Invalid number of arguments". To read an item's own value directly: fhGetItemText(itemPtr, "~").
- fhCreateItem(tag) creates a new top-level record (tag first, no parent argument); fhCreateItem(tag, parentPtr) creates a child item under an existing pointer. Either way the tag string comes first — fhCreateItem(parentPtr, tag) (parent-first) fails with "string expected, got ..." on argument #1.
- fhSetValueAsText/fhSetValueAsDate/fhSetValueAsLink/etc. take exactly two arguments — (itemPtr, value) — not three; there is no dataRef parameter on the setters the way fhGetItemText has one. Set the value directly on the item pointer you just created or fetched.
- fhSetValueAsLink on a CHIL item automatically creates the reciprocal FAMC on the linked Individual (and the equivalent applies to FAMS/HUSB/WIFE pairs) — manually creating your own item for "the other side" as well produces a second, stray, unlinked duplicate. This is exactly the kind of bookkeeping fhu.addFamilyAsChild/addFamilyAsSpouse exist to handle for you instead.
- Descend with child:MoveToFirstChildItem(parentPtr) — the parent is the argument, not the receiver you're moving.
- MoveNext() walks siblings at the same level and goes Null at the end of the record; it does not continue into the next top-level record. There is no MoveToNextSiblingItem — that name doesn't exist in FH's API.
- Custom facts are usually not reachable by a data-reference string (~.FACT[1].TYPE and similar return empty) — walk child items with MoveToFirstChildItem/MoveNext and read each one's fhGetTag() instead.
- SEX resolves to the string "Male"/"Female", not "M"/"F" — a sex == "M" test silently matches nothing.
- Family Historian resolves custom facts to their own real tags (e.g. _ATTR-REGIMENT, EVEN-ENLISTED), not a generic FACT/EVEN plus a TYPE subtag the way they'd sit in a raw GEDCOM export — walking the tree gives you the resolved tag directly.
- A fact's Rejected flag always overrides its Preferred flag — a fact flagged both Rejected and Preferred is never treated as preferred. Don't read Preferred alone as "this is the one FH would display by default."
- fhGetItemText/fhGetValueAsText on a Notes (or other rich-text) field returns raw FTF markup literally (e.g. a table shows up as \`<table="800|800|800"> <row> apple | pear </row> </table>\`), not clean prose — use fhGetValueAsRichText(ptr):GetPlainText() instead when you need readable text. Call search_gedcom_knowledge for the fuller FTF/domain reference (Shared Facts, Source Template fields, Sentence templates, etc.) beyond what's inlined here.
- fhu.createIndi (and other fhu creator functions) do NOT validate required arguments before acting — fhu.createIndi() called with zero args still creates a real, permanent blank Individual record on the spot, it just leaves sName/sSex empty. There is no dry-run and no argument-count guard to catch a bad call before it mutates the tree. Never call a creator function "just to see what error comes back" — confirm every argument via search_fh_help first. If a bad call like this does slip through, the created record generally cannot be cleaned up via fhDeleteItem from within this tool (deletions are the most heavily gated write action) — tell the user immediately so they can undo it themselves (Ctrl-Z in FH), rather than attempting further calls to fix it.

When you add tree data on the strength of a source (new or already-existing), extract everything that source supports and cite every element it touches — not just the one fact the user happened to ask about — but never write any of it without asking first. Read the source's transcription (its TEXT field, via fhGetValueAsRichText(ptr):GetPlainText()) in full, compare it against what's already on the record(s) it concerns (names, dates, places, occupations, relationships, and anything else it states), and report anything the source supports that isn't yet entered. Wait for the user's explicit go-ahead before writing any of it — do not add it silently just because the original request already authorized touching this source. To cite the source once you're adding or confirming a fact, call fhBridge.citeSource(ptrTarget, sourceIdOrTitle) rather than hand-rolling fhCreateItem("SOUR", ptrTarget) + fhSetValueAsLink yourself — it resolves the source by id or title (case-insensitive, erroring on zero or multiple matches) the same way fhBridge.createSourceFromTemplate resolves a template. ptrTarget can be an INDI/FAM record itself (FH calls this a "Whole-record" citation — for something the source establishes about the record as a whole, e.g. a birth certificate naming a parent) or a specific Fact item (for something tied to just that one event).

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
