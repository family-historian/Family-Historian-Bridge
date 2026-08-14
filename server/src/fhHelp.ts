import fs from "node:fs";
import { z } from "zod";
import { ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { grepEntries, searchEntries } from "./corpusSearch.js";

export interface FhHelpTopic {
  url: string;
  section: string;
  title: string;
  breadcrumb: string[];
  text: string;
}

export interface FhHelpSearchResult {
  uri: string;
  url: string;
  title: string;
  breadcrumb: string[];
  excerpt: string;
}

/** A mutable holder so a corpus reload (see fhHelpUpdate.ts) is visible to
 * already-registered tool/resource callbacks without re-registering them. */
export interface FhHelpCorpusStore {
  topics: FhHelpTopic[];
}

const DEFAULT_SEARCH_LIMIT = 10;

export function parseCorpus(jsonlContent: string): FhHelpTopic[] {
  return jsonlContent
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as FhHelpTopic);
}

export function loadCorpusFromFile(filePath: string): FhHelpTopic[] {
  return parseCorpus(fs.readFileSync(filePath, "utf8"));
}

export function resourceUriForUrl(url: string): string {
  return `fh-help:${url}`;
}

/** Thin wrapper around the shared search/rank/excerpt logic in corpusSearch.ts, mapping
 * its generic result shape onto FhHelpSearchResult's uri/url fields. Beta feedback,
 * 2026-07-29: a bare empty array taught Claude "the corpus has nothing" rather than
 * "retry with a narrower term" — the token-overlap fallback in searchEntries exists to
 * make that dead end rarer. */
export function searchFhHelp(
  corpus: FhHelpTopic[],
  query: string,
  limit = DEFAULT_SEARCH_LIMIT,
): FhHelpSearchResult[] {
  return searchEntries(corpus, query, limit).map(({ entry: topic, excerpt }) => ({
    uri: resourceUriForUrl(topic.url),
    url: topic.url,
    title: topic.title,
    breadcrumb: topic.breadcrumb,
    excerpt,
  }));
}

export function getFhHelpPage(corpus: FhHelpTopic[], url: string): string | undefined {
  return corpus.find((topic) => topic.url === url)?.text;
}

export interface FhHelpGrepMatch {
  uri: string;
  url: string;
  title: string;
  breadcrumb: string[];
  text: string;
}

export interface FhHelpGrepResult {
  matches: FhHelpGrepMatch[];
  totalMatches: number;
  truncated: boolean;
}

interface FhHelpGrepResponseBody extends FhHelpGrepResult {
  note?: string;
}

const GREP_DEFAULT_MATCH_LIMIT = 10;
const GREP_MAX_MATCH_LIMIT = 25;
// Same lesson as the unpaginated resources/list issue (#20): an overly broad pattern
// (e.g. a single common word) shouldn't be able to dump most of the corpus into one
// response, even under the match-count cap above.
const GREP_MAX_TOTAL_BYTES = 200_000;

/** Full-text grep across the whole corpus (title, breadcrumb, and body), returning the
 * complete text of every matching entry — not a truncated excerpt window like
 * searchFhHelp. For when the caller knows a fragment of what they're looking for (a
 * function name, a sample-script pattern) but not which page holds it. See issue #21. */
export function grepFhHelp(
  corpus: FhHelpTopic[],
  pattern: string,
  options: { regex?: boolean; limit?: number } = {},
): FhHelpGrepResult {
  const { matches, totalMatches, truncated } = grepEntries(corpus, pattern, options, {
    defaultLimit: GREP_DEFAULT_MATCH_LIMIT,
    maxLimit: GREP_MAX_MATCH_LIMIT,
    maxTotalBytes: GREP_MAX_TOTAL_BYTES,
  });
  return {
    matches: matches.map((topic) => ({
      uri: resourceUriForUrl(topic.url),
      url: topic.url,
      title: topic.title,
      breadcrumb: topic.breadcrumb,
      text: topic.text,
    })),
    totalMatches,
    truncated,
  };
}

// Steers Claude's own behavior when it uses this tool. Kept under the ~2048-byte
// deferred-tool-loading truncation point some MCP clients enforce (same failure class
// ADR 0011 found for RUN_LUA_DESCRIPTION) -- see fhHelp.test.ts's own byte-budget tests.
export const SEARCH_FH_HELP_DESCRIPTION = `Search Family Historian 8's official help documentation (both the main FH8 help and the plugin-authoring help) for topics matching a query. Use this for questions about how Family Historian itself works — menus, features, dialogs, where something lives, how to write a plugin — as opposed to questions about the user's own tree data (use run_lua for that).

Also use this BEFORE writing a run_lua script, any time you're not certain of an FH API function's exact signature, an item-pointer method's calling convention, or a data-reference syntax detail — the corpus has the full function reference, cheaper and more reliable than guessing and fixing it by trial and error against the user's real, live project. Search "fhNewItemPtr iteration" before any loop over records/child items (confusing fhNewItemPtr() with fhCreateItem() leaves junk data behind); grep_fh_help the page titled "Function Index" to sanity-check whether a bare fh* name is real at all.

If an excerpt is insufficient, retry with a narrower, more specific term first (an exact function name, not a paraphrase) — this is a simple keyword match, not semantic search. If that still doesn't surface it, use grep_fh_help next — full page text, not an excerpt — before falling back to web search for content that's already local. A ranked result's "uri" can be read as an MCP resource, but that path is unreliable in at least one tested MCP client (docs/adr/0007), so treat it as best-effort only.`;

// Steers Claude's own behavior when it uses this tool.
export const GREP_FH_HELP_DESCRIPTION = `Full-text search across the entire Family Historian help corpus (both the main FH8 help and the plugin-authoring help, including sample scripts) — matches against each entry's complete title, breadcrumb, and body text, and returns the complete text of every matching entry (not a truncated excerpt).

Use this when search_fh_help's excerpt doesn't contain enough of the page to answer the question, or when you only know a fragment of what you're looking for — a specific function name, a line from a sample script, an error string — but not which page it lives on. This is the fallback to reach for before web search: the corpus is already local, so a pattern that would find something on the FH help website will usually find it here too. To list every valid bare fh* global name in one call (e.g. before deciding a name is genuinely unknown), grep for the page titled "Function Index" — a single entry covering all of them by signature.

By default the pattern is matched as a literal, case-insensitive substring. Pass regex: true to match it as a case-insensitive regular expression instead. Results are capped (a limited number of matches, and a limited total size) so an overly broad pattern can't dump the whole corpus in one response — narrow the pattern and retry if the result reports truncation.`;

function searchResult(query: string, matches: FhHelpSearchResult[]): CallToolResult {
  if (matches.length === 0) {
    return {
      content: [
        {
          type: "text",
          text: `No match for "${query}". This search matches contiguous substrings and individual significant words, not full-sentence meaning — retry with a single keyword, e.g. a specific FH feature name or function name ("merge", "fhGetItemText").`,
        },
      ],
    };
  }
  return { content: [{ type: "text", text: JSON.stringify(matches) }] };
}

function grepResult(pattern: string, result: FhHelpGrepResult): CallToolResult {
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
  const body: FhHelpGrepResponseBody = { ...result };
  if (result.truncated) {
    body.note = `Truncated: ${result.totalMatches} entries matched "${pattern}", only ${result.matches.length} returned. Narrow the pattern to see the rest.`;
  }
  return { content: [{ type: "text", text: JSON.stringify(body) }] };
}

export function registerFhHelpTools(server: McpServer, store: FhHelpCorpusStore): void {
  server.registerTool(
    "search_fh_help",
    {
      description: SEARCH_FH_HELP_DESCRIPTION,
      inputSchema: {
        query: z.string().describe("A Family Historian feature/menu name or short phrase to search the help for."),
      },
    },
    ({ query }) => searchResult(query, searchFhHelp(store.topics, query)),
  );

  server.registerTool(
    "grep_fh_help",
    {
      description: GREP_FH_HELP_DESCRIPTION,
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
        return grepResult(pattern, grepFhHelp(store.topics, pattern, { regex, limit }));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Invalid pattern: ${message}` }],
          isError: true,
        };
      }
    },
  );

  // Deliberately no `list` callback: this SDK version's ListResourcesRequestSchema handler
  // ignores `cursor` and never emits `nextCursor` (no real pagination support at that layer),
  // so enumerating all ~1000 corpus topics in one unpaginated resources/list response risked
  // tripping client-side size/shape limits. No caller needs to browse the full list anyway —
  // search_fh_help already returns the exact uri to read, and resources/read matches by
  // URI-template pattern independent of whatever (if anything) `list` returns.
  const template = new ResourceTemplate("fh-help:{+path}", { list: undefined });

  server.registerResource(
    "fh_help_page",
    template,
    { title: "Family Historian 8 help topic", mimeType: "text/plain" },
    (uri) => {
      const text = getFhHelpPage(store.topics, uri.pathname);
      if (text === undefined) {
        throw new Error(`No FH help topic at ${uri.pathname}`);
      }
      return { contents: [{ uri: uri.href, mimeType: "text/plain", text }] };
    },
  );
}
