import fs from "node:fs";
import { z } from "zod";
import { ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { searchEntries } from "./corpusSearch.js";

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

// Steers Claude's own behavior when it uses this tool.
export const SEARCH_FH_HELP_DESCRIPTION = `Search Family Historian 8's official help documentation (both the main FH8 help and the plugin-authoring help) for topics matching a query. Use this for questions about how Family Historian itself works — menus, features, dialogs, where something lives, how to write a plugin — as opposed to questions about the user's own tree data (use run_lua for that).

Also use this BEFORE writing a run_lua script, any time you're not certain of an FH API function's exact signature, an item-pointer method's calling convention, or a data-reference syntax detail (e.g. "MoveToFirstChildItem", "fhGetItemText data reference syntax") — the corpus includes the full function reference. Cheaper and more reliable than guessing the shape and fixing it by trial and error against the user's real, live project.

Returns a ranked list of matching topics, each with a "uri" that can be read as an MCP resource for the topic's full text — but resource reads are unreliable in at least one tested MCP client (see docs/adr/0007-fh-help-resource-reads-unreliable-client-side.md), so treat that path as best-effort, not guaranteed. If an excerpt is insufficient and a resource read isn't available, retry with a narrower, more specific query first — the excerpt is a window around the best match, so a more targeted term (an exact function name, not a paraphrase) often surfaces the passage you actually need. This search is a simple keyword match, not semantic search: try the FH feature/menu name or function name a user/API would recognize. A full-sentence query falls back to matching on individual significant words, but a single term (e.g. "merge", "MoveToFirstChildItem") is still the most reliable form.`;

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
