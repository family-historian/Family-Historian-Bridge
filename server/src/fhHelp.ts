import fs from "node:fs";
import { z } from "zod";
import { ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

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

const EXCERPT_RADIUS = 100;
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

function buildExcerpt(text: string, query: string): string {
  const matchIndex = text.toLowerCase().indexOf(query.toLowerCase());
  if (matchIndex === -1) {
    return text.slice(0, EXCERPT_RADIUS * 2).trim();
  }
  const start = Math.max(0, matchIndex - EXCERPT_RADIUS);
  const end = Math.min(text.length, matchIndex + query.length + EXCERPT_RADIUS);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < text.length ? "…" : "";
  return `${prefix}${text.slice(start, end).trim()}${suffix}`;
}

/** Matches on title/breadcrumb/text (case-insensitive substring); title matches
 * rank above breadcrumb matches, which rank above body-text-only matches. Not a
 * relevance-ranked search engine — good enough for exact menu/feature-name
 * lookups, which is most of what this gets used for. */
export function searchFhHelp(
  corpus: FhHelpTopic[],
  query: string,
  limit = DEFAULT_SEARCH_LIMIT,
): FhHelpSearchResult[] {
  const needle = query.toLowerCase();
  if (needle.trim().length === 0) return [];

  const scored: Array<{ topic: FhHelpTopic; rank: number }> = [];
  for (const topic of corpus) {
    const breadcrumbText = topic.breadcrumb.join(" ");
    if (topic.title.toLowerCase().includes(needle)) {
      scored.push({ topic, rank: 0 });
    } else if (breadcrumbText.toLowerCase().includes(needle)) {
      scored.push({ topic, rank: 1 });
    } else if (topic.text.toLowerCase().includes(needle)) {
      scored.push({ topic, rank: 2 });
    }
  }

  scored.sort((a, b) => a.rank - b.rank);

  return scored.slice(0, limit).map(({ topic }) => ({
    uri: resourceUriForUrl(topic.url),
    url: topic.url,
    title: topic.title,
    breadcrumb: topic.breadcrumb,
    excerpt: buildExcerpt(topic.text, query),
  }));
}

export function getFhHelpPage(corpus: FhHelpTopic[], url: string): string | undefined {
  return corpus.find((topic) => topic.url === url)?.text;
}

// Steers Claude's own behavior when it uses this tool.
export const SEARCH_FH_HELP_DESCRIPTION = `Search Family Historian 8's official help documentation (both the main FH8 help and the plugin-authoring help) for topics matching a query. Use this for questions about how Family Historian itself works — menus, features, dialogs, where something lives, how to write a plugin — as opposed to questions about the user's own tree data (use run_lua for that).

Returns a ranked list of matching topics, each with a "uri" — read that uri as an MCP resource to get the topic's full text. This search is a simple keyword match, not semantic search: try the FH feature/menu name a user would recognize, not a paraphrase.`;

function searchResult(matches: FhHelpSearchResult[]): CallToolResult {
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
    ({ query }) => searchResult(searchFhHelp(store.topics, query)),
  );

  const template = new ResourceTemplate("fh-help:{+path}", {
    list: () => ({
      resources: store.topics.map((topic) => ({
        uri: resourceUriForUrl(topic.url),
        name: topic.url,
        title: topic.title,
        description: topic.breadcrumb.join(" > "),
        mimeType: "text/plain",
      })),
    }),
  });

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
