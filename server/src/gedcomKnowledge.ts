import fs from "node:fs";
import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { grepEntries, searchEntries } from "./corpusSearch.js";

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

// 20, not 10 (issue #65): the "run_lua guidance" family (breadcrumb ["Bridge project
// conventions", "run_lua guidance", ...]) already has 11 members as of this comment and
// keeps growing (gedcom-corpus-pattern memory: extend this family rather than growing
// RUN_LUA_DESCRIPTION) -- search_gedcom_knowledge exposes no caller-settable limit
// (query is its only parameter), so a too-low default silently truncates the family a
// caller was told relies on "one search call" (RUN_LUA_DESCRIPTION/run-lua-guidance-*'s
// own promise) to see everything. 20 gives headroom well past the largest family today
// while staying far below the corpus's total entry count, so an accidentally-broad query
// still doesn't return everything.
const DEFAULT_SEARCH_LIMIT = 20;

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

export interface GedcomKnowledgeGrepResult {
  matches: GedcomKnowledgeEntry[];
  totalMatches: number;
  truncated: boolean;
}

interface GedcomKnowledgeGrepResponseBody extends GedcomKnowledgeGrepResult {
  note?: string;
}

// Unlike grep_fh_help's 10/25 (tuned for a ~1000-topic, up to ~50KB-per-entry corpus),
// this corpus is ~40 entries totaling well under 100KB, so the match-count default is set
// to the same value as the max -- there's no real risk of dumping "most of the corpus" the
// way a low default guards against for fh-help, and a caller who wants everything a
// pattern matches shouldn't have to pass limit explicitly to get it. The byte cap stays
// generous rather than being tightened to match, since it's already far larger than this
// corpus could ever fill.
const GREP_DEFAULT_MATCH_LIMIT = 25;
const GREP_MAX_MATCH_LIMIT = 25;
const GREP_MAX_TOTAL_BYTES = 200_000;

/** Full-text grep across the whole corpus (title, breadcrumb, and body), returning the
 * complete matching entries -- not a truncated excerpt window like searchGedcomKnowledge's
 * own token-overlap fallback for natural-language queries. For when the caller knows a
 * fragment of what they're looking for (a function name, an exact phrase) but a
 * sentence-style search buries it under unrelated matches. See issue #101. */
export function grepGedcomKnowledge(
  corpus: GedcomKnowledgeEntry[],
  pattern: string,
  options: { regex?: boolean; limit?: number } = {},
): GedcomKnowledgeGrepResult {
  return grepEntries(corpus, pattern, options, {
    defaultLimit: GREP_DEFAULT_MATCH_LIMIT,
    maxLimit: GREP_MAX_MATCH_LIMIT,
    maxTotalBytes: GREP_MAX_TOTAL_BYTES,
  });
}

// Steers Claude's own behavior when it uses this tool.
export const GREP_GEDCOM_KNOWLEDGE_DESCRIPTION = `Full-text search across the entire GEDCOM/FH domain-knowledge corpus -- matches against each entry's complete title, breadcrumb, and body text, and returns the complete matching entries (search_gedcom_knowledge already returns full entries too, but ranks a natural-language query by word-overlap, which can bury an exact match under unrelated entries sharing common words).

Use this when search_gedcom_knowledge's natural-language ranking doesn't surface what you need, or when you only know a fragment of what you're looking for -- an exact function name (e.g. "getFamilyGroup"), a Data Reference qualifier code, an exact phrase -- but a sentence-style query keeps returning something else first.

By default the pattern is matched as a literal, case-insensitive substring. Pass regex: true to match it as a case-insensitive regular expression instead. Results are capped (a limited number of matches, and a limited total size) so an overly broad pattern can't dump the whole corpus in one response -- narrow the pattern and retry if the result reports truncation.`;

// Steers Claude's own behavior when it uses this tool. Kept under the ~2048-byte
// deferred-tool-loading truncation point some MCP clients enforce (same failure class
// ADR 0011 found for RUN_LUA_DESCRIPTION) -- see gedcomKnowledge.test.ts's own byte-budget
// tests. Grew past that point once already (3001 bytes) before this re-zoning (issue #101).
export const SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION = `Search a reference corpus of GEDCOM/Family Historian domain knowledge that goes beyond FH's own end-user help (use search_fh_help for that): FTF rich-text markup syntax, Shared Facts, the Fact Flag vs. Record Flag distinction, Source Template fields, Sentence templates, Data Reference qualifier codes (e.g. "~.NAME:GIVEN_ALL" — query "name qualifiers"/"date qualifiers"/"place and lat/long qualifiers" for each qualifier code's full canonical list, rather than reconstructing it from fh-help sample scripts), and run_lua's own behavioral guidance (query "run_lua guidance" — see below).

Use this BEFORE writing a run_lua script that reads/writes a Notes/Text field, a fact's flags, a citation's structured fields, or any Data Reference needing a qualifier. Also call it with the exact query "run_lua guidance" once near the start of any conversation using run_lua — tool descriptions can be truncated around ~2KB before reaching you (docs/adr/0011), and this query reliably surfaces the call-shape gotchas, citeSource/rollback/fhu-is-a-global guidance, and fhBridge's read-only family/detail query helpers.

If a query's natural-language ranking buries what you need under unrelated matches, or you only know a fragment (an exact function name, a qualifier code) but not which entry holds it, use grep_gedcom_knowledge next — literal substring match, full matching entries, no ranking noise.

Every result carries a "confidence" level (Verified/Confirmed/Documented/Likely) and a "source" citation — Documented/Likely entries describe FH's documented intent, not something observed live, so treat as a strong prior, not a substitute for checking the user's actual data.

Out of scope (docs/adr/0003): raw GEDCOM-export wire mechanics (_LINK_*/_LKID, the _PLAC/_ADDR gazetteer, character encodings) — run_lua's sandbox never touches a .ged file directly. Simple keyword match, not semantic search: try a specific term, not a paraphrase.`;

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

function grepResult(pattern: string, result: GedcomKnowledgeGrepResult): CallToolResult {
  if (result.matches.length === 0) {
    return {
      content: [
        {
          type: "text",
          text: `No match for "${pattern}" anywhere in the corpus (title, breadcrumb, or body).`,
        },
      ],
    };
  }
  const body: GedcomKnowledgeGrepResponseBody = { ...result };
  if (result.truncated) {
    body.note = `Truncated: ${result.totalMatches} entries matched "${pattern}", only ${result.matches.length} returned. Narrow the pattern to see the rest.`;
  }
  return { content: [{ type: "text", text: JSON.stringify(body) }] };
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

  server.registerTool(
    "grep_gedcom_knowledge",
    {
      description: GREP_GEDCOM_KNOWLEDGE_DESCRIPTION,
      inputSchema: {
        pattern: z.string().describe("Literal substring, or regex if regex: true, to search the full corpus text for."),
        regex: z.boolean().optional().describe("Match pattern as a regular expression instead of a literal substring. Default false."),
        limit: z
          .number()
          .int()
          .positive()
          .max(GREP_MAX_MATCH_LIMIT)
          .optional()
          .describe(`Max number of matching entries to return (default ${GREP_DEFAULT_MATCH_LIMIT}, max ${GREP_MAX_MATCH_LIMIT}).`),
      },
    },
    ({ pattern, regex, limit }) => {
      try {
        return grepResult(pattern, grepGedcomKnowledge(store.entries, pattern, { regex, limit }));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Invalid pattern: ${message}` }],
          isError: true,
        };
      }
    },
  );
}
