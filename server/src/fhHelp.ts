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

const TOKEN_MIN_LENGTH = 2;

// Filler words common in a natural-language question but useless as a search signal —
// stripping them is what lets "how do I merge two individuals" reduce to the words that
// actually distinguish a topic ("merge", "individuals"), rather than requiring literally
// every word (including "how"/"do") to appear in the corpus, which would still fail for
// exactly the query this fallback exists to rescue.
const STOPWORDS = new Set([
  "a", "an", "the", "i", "to", "do", "does", "did", "of", "in", "on", "at", "for", "is",
  "are", "am", "was", "were", "be", "my", "me", "you", "your", "it", "this", "that",
  "with", "how", "what", "where", "when", "why", "can", "could", "would", "should",
  "will", "and", "or", "from", "about", "over", "all", "two", "get", "gets",
]);

function tokenize(query: string): string[] {
  const tokens = query
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length >= TOKEN_MIN_LENGTH && !STOPWORDS.has(t));
  return [...new Set(tokens)];
}

// Weights title/breadcrumb matches well above body matches so a topic that only
// mentions a query word in passing (common for generic terms like "record" or "field"
// across a real, hundreds-of-pages corpus) can't outrank one whose title or breadcrumb
// is actually about it — mirrors the primary search's title > breadcrumb > text
// ordering, rather than a flat count that treats every match location the same.
const TITLE_TOKEN_WEIGHT = 100;
const BREADCRUMB_TOKEN_WEIGHT = 10;
const TEXT_TOKEN_WEIGHT = 1;

function tokenMatchScore(topic: FhHelpTopic, tokens: string[]): number {
  const title = topic.title.toLowerCase();
  const breadcrumb = topic.breadcrumb.join(" ").toLowerCase();
  const text = topic.text.toLowerCase();
  let score = 0;
  for (const token of tokens) {
    if (title.includes(token)) score += TITLE_TOKEN_WEIGHT;
    else if (breadcrumb.includes(token)) score += BREADCRUMB_TOKEN_WEIGHT;
    else if (text.includes(token)) score += TEXT_TOKEN_WEIGHT;
  }
  return score;
}

/** Matches on title/breadcrumb/text (case-insensitive substring); title matches
 * rank above breadcrumb matches, which rank above body-text-only matches. Not a
 * relevance-ranked search engine — good enough for exact menu/feature-name
 * lookups, which is most of what this gets used for.
 *
 * A natural-language query ("how do I merge two individuals") is rarely a literal
 * contiguous substring anywhere in the corpus, so an exact-substring miss falls back to
 * scoring each topic by how many of the query's meaningful words (stopwords stripped)
 * appear in it — weighted by where (title/breadcrumb/text), same ordering as the primary
 * search — keeping anything with a nonzero score, ranked highest first. Beta feedback,
 * 2026-07-29: a bare empty array taught Claude "the corpus has nothing" rather than
 * "retry with a narrower term" — this fallback exists to make that dead end rarer. */
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

  let matches = scored;
  if (matches.length === 0) {
    const tokens = tokenize(query);
    if (tokens.length > 0) {
      matches = corpus
        .map((topic) => ({ topic, score: tokenMatchScore(topic, tokens) }))
        .filter(({ score }) => score > 0)
        .sort((a, b) => b.score - a.score)
        .map(({ topic }) => ({ topic, rank: 0 }));
    }
  }

  return matches.slice(0, limit).map(({ topic }) => ({
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

Also use this BEFORE writing a run_lua script, any time you're not certain of an FH API function's exact signature, an item-pointer method's calling convention, or a data-reference syntax detail (e.g. "MoveToFirstChildItem", "fhGetItemText data reference syntax") — the corpus includes the full function reference. Cheaper and more reliable than guessing the shape and fixing it by trial and error against the user's real, live project.

Returns a ranked list of matching topics, each with a "uri" — read that uri as an MCP resource to get the topic's full text. This search is a simple keyword match, not semantic search: try the FH feature/menu name or function name a user/API would recognize, not a paraphrase. A full-sentence query falls back to matching on individual significant words, but a single term (e.g. "merge", "MoveToFirstChildItem") is still the most reliable form.`;

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
