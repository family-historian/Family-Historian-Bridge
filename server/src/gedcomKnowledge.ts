import fs from "node:fs";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { searchEntries } from "./corpusSearch.js";

export type GedcomKnowledgeConfidence = "Verified" | "Confirmed" | "Documented" | "Likely";

export interface GedcomKnowledgeEntry {
  id: string;
  title: string;
  breadcrumb: string[];
  confidence: GedcomKnowledgeConfidence;
  source: string;
  text: string;
}

/** A mutable holder so a future corpus reload is visible to already-registered tool
 * callbacks without re-registering them — same pattern as FhHelpCorpusStore, even though
 * this corpus (unlike fh-help-corpus.jsonl) has no update-check tool of its own; see
 * docs/adr/0003-gedcom-corpus-scope-live-api-only.md. */
export interface GedcomKnowledgeStore {
  entries: GedcomKnowledgeEntry[];
}

const DEFAULT_SEARCH_LIMIT = 10;

export function parseGedcomKnowledgeCorpus(jsonlContent: string): GedcomKnowledgeEntry[] {
  return jsonlContent
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as GedcomKnowledgeEntry);
}

export function loadGedcomKnowledgeFromFile(filePath: string): GedcomKnowledgeEntry[] {
  return parseGedcomKnowledgeCorpus(fs.readFileSync(filePath, "utf8"));
}

/** Unlike search_fh_help (which returns an excerpt plus a uri to fetch the full help
 * page), this returns each matching entry in full directly — entries here are compact
 * single-fact reference notes, not multi-page help topics, so there's nothing gained by
 * making Claude round-trip through a resource fetch to read one, and no separate result
 * type is needed since nothing is reshaped. */
export function searchGedcomKnowledge(
  corpus: GedcomKnowledgeEntry[],
  query: string,
  limit = DEFAULT_SEARCH_LIMIT,
): GedcomKnowledgeEntry[] {
  return searchEntries(corpus, query, limit).map(({ entry }) => entry);
}

export function getGedcomKnowledgeEntry(
  corpus: GedcomKnowledgeEntry[],
  id: string,
): GedcomKnowledgeEntry | undefined {
  return corpus.find((entry) => entry.id === id);
}

// Steers Claude's own behavior when it uses this tool.
export const SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION = `Search a reference corpus of GEDCOM/Family Historian domain knowledge that goes beyond FH's own end-user help (use search_fh_help for that): FTF rich-text markup syntax (the formatting commands stored inline in Notes and other multi-line text fields), Shared Facts (a fact's additional participants beyond its own record), the Fact Flag vs. Record Flag distinction, Source Template fields, Sentence templates, Data Reference qualifier codes (the colon-suffix on a NAME/DATE/PLACE field, e.g. "~.NAME:GIVEN_ALL" or "~.NAME:SURNAME" — query "name qualifiers", "date qualifiers", or "place and lat/long qualifiers" for the full canonical list of each, rather than reconstructing it from fh-help sample scripts), and run_lua's own behavioral guidance (query "run_lua guidance" — see below).

Use this BEFORE writing a run_lua script that reads or writes a Notes/Text field, a fact's flags, a citation's structured fields, or any Data Reference that needs a qualifier to shape its output, any time you're not sure whether the raw value you're looking at is plain text or carries markup/structure you need to account for. Also call it with the exact query "run_lua guidance" once near the start of any conversation that will use run_lua — some MCP clients truncate run_lua's own tool description around ~2KB before it ever reaches you, and this query reliably surfaces the call-shape gotchas, citeSource guidance, writeSessionRolledBack handling, the fhu-is-a-global note, the fhBridge.logActivity/session Research Note guidance, and fhBridge's read-only family/detail query helpers (getFamilyGroup/getAncestors/getAllDetails/searchByName/getFactsByTag — prefer these over hand-rolling a FAMS/FAMC walk, a NAME-field string scan, or a MoveToFirstChildItem tag scan) that live past that point (docs/adr/0011-run-lua-description-truncation-workaround.md).

Every result carries a "confidence" level (Verified/Confirmed/Documented/Likely — see each entry's "source") and a "source" citation. Documented/Likely entries describe FH's documented intent, not something this bridge has itself observed via a live run_lua call against a real project — treat them as a strong prior, not a substitute for checking the user's actual data when precision matters.

Out of scope (see docs/adr/0003-gedcom-corpus-scope-live-api-only.md): raw GEDCOM-export wire mechanics (_LINK_*/_LKID, the _PLAC/_ADDR gazetteer, character encodings) — run_lua's sandbox never reads or writes a .ged file directly, so none of that is reachable here. This does NOT include _SRCT itself: that's also a live record-type tag (Source Template record), reachable the same way as INDI/FAM/SOUR — see "Creating a templated Source record" for how to create and populate one.

This is a simple keyword match, not semantic search: try a specific term (e.g. "record link", "shared facts", "sentence template", "rejected preferred") rather than a paraphrase. A full-sentence query falls back to matching on individual significant words.`;

function searchResult(query: string, matches: GedcomKnowledgeEntry[]): CallToolResult {
  if (matches.length === 0) {
    return {
      content: [
        {
          type: "text",
          text: `No match for "${query}" in the GEDCOM knowledge corpus. This search matches contiguous substrings and individual significant words, not full-sentence meaning — retry with a single concept term (e.g. "shared facts", "record link", "sentence template").`,
        },
      ],
    };
  }
  return { content: [{ type: "text", text: JSON.stringify(matches) }] };
}

export function registerGedcomKnowledgeTools(server: McpServer, store: GedcomKnowledgeStore): void {
  server.registerTool(
    "search_gedcom_knowledge",
    {
      description: SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION,
      inputSchema: {
        query: z.string().describe("A GEDCOM/FH domain concept or FTF markup command to search for."),
      },
    },
    ({ query }) => searchResult(query, searchGedcomKnowledge(store.entries, query)),
  );
}
