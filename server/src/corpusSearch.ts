/** Generic keyword search shared by fhHelp.ts and gedcomKnowledge.ts — a plain title/
 * breadcrumb/body substring match with a stopword-stripped token-overlap fallback for
 * natural-language queries. Not a relevance-ranked search engine; good enough for exact
 * menu/feature/concept-name lookups, which is most of what either corpus gets used for. */

export interface SearchableEntry {
  title: string;
  breadcrumb: string[];
  text: string;
}

const EXCERPT_RADIUS = 100;

export function buildExcerpt(text: string, query: string): string {
  const matchIndex = text.toLowerCase().indexOf(query.toLowerCase());
  if (matchIndex === -1) {
    const slice = text.slice(0, EXCERPT_RADIUS * 2);
    const suffix = slice.length < text.length ? "…" : "";
    return `${slice.trim()}${suffix}`;
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

export function tokenize(query: string): string[] {
  const tokens = query
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length >= TOKEN_MIN_LENGTH && !STOPWORDS.has(t));
  return [...new Set(tokens)];
}

// Weights title/breadcrumb matches well above body matches so an entry that only mentions
// a query word in passing (common for generic terms like "record" or "field" across a
// real, many-entry corpus) can't outrank one whose title or breadcrumb is actually about
// it — mirrors the primary search's own title > breadcrumb > text ordering, rather than a
// flat count that treats every match location the same.
const TITLE_TOKEN_WEIGHT = 100;
const BREADCRUMB_TOKEN_WEIGHT = 10;
const TEXT_TOKEN_WEIGHT = 1;

export function tokenMatchScore(entry: SearchableEntry, tokens: string[]): number {
  const title = entry.title.toLowerCase();
  const breadcrumb = entry.breadcrumb.join(" ").toLowerCase();
  const text = entry.text.toLowerCase();
  let score = 0;
  for (const token of tokens) {
    if (title.includes(token)) score += TITLE_TOKEN_WEIGHT;
    else if (breadcrumb.includes(token)) score += BREADCRUMB_TOKEN_WEIGHT;
    else if (text.includes(token)) score += TEXT_TOKEN_WEIGHT;
  }
  return score;
}

export interface SearchMatch<T> {
  entry: T;
  excerpt: string;
}

/** Matches on title/breadcrumb/text (case-insensitive substring); title matches rank above
 * breadcrumb matches, which rank above body-text-only matches. A natural-language query is
 * rarely a literal contiguous substring anywhere in the corpus, so an exact-substring miss
 * falls back to scoring each entry by how many of the query's meaningful words (stopwords
 * stripped) appear in it — weighted by where (title/breadcrumb/text), same ordering as the
 * primary search — keeping anything with a nonzero score, ranked highest first. */
export function searchEntries<T extends SearchableEntry>(
  corpus: T[],
  query: string,
  limit: number,
): SearchMatch<T>[] {
  const needle = query.toLowerCase();
  if (needle.trim().length === 0) return [];

  const scored: Array<{ entry: T; rank: number }> = [];
  for (const entry of corpus) {
    const breadcrumbText = entry.breadcrumb.join(" ");
    if (entry.title.toLowerCase().includes(needle)) {
      scored.push({ entry, rank: 0 });
    } else if (breadcrumbText.toLowerCase().includes(needle)) {
      scored.push({ entry, rank: 1 });
    } else if (entry.text.toLowerCase().includes(needle)) {
      scored.push({ entry, rank: 2 });
    }
  }

  let matches = scored;
  if (matches.length === 0) {
    const tokens = tokenize(query);
    if (tokens.length > 0) {
      matches = corpus
        .map((entry) => ({ entry, score: tokenMatchScore(entry, tokens) }))
        .filter(({ score }) => score > 0)
        .sort((a, b) => b.score - a.score)
        .map(({ entry }) => ({ entry, rank: 0 }));
    }
  }

  return matches.slice(0, limit).map(({ entry }) => ({
    entry,
    excerpt: buildExcerpt(entry.text, query),
  }));
}

/** Shared by grepFhHelp/grepGedcomKnowledge: a case-insensitive literal-substring matcher
 * by default, or a case-insensitive regex matcher when isRegex is true. */
export function buildGrepMatcher(pattern: string, isRegex: boolean): (haystack: string) => boolean {
  if (isRegex) {
    const re = new RegExp(pattern, "i");
    return (haystack) => re.test(haystack);
  }
  const needle = pattern.toLowerCase();
  return (haystack) => haystack.toLowerCase().includes(needle);
}

export interface GrepResult<T> {
  matches: T[];
  totalMatches: number;
  truncated: boolean;
}

/** Per-caller tuning: fh-help's corpus (~1000 topics, up to ~50KB each) needs a low
 * default match count to avoid dumping most of it in one response; gedcom-knowledge's
 * corpus (~40 entries, a few KB each) can default much higher without ever approaching
 * maxTotalBytes. Kept as an explicit argument rather than a shared constant so each
 * caller's own module documents its own reasoning next to its own numbers. */
export interface GrepLimits {
  defaultLimit: number;
  maxLimit: number;
  maxTotalBytes: number;
}

/** Full-text grep across a corpus's title/breadcrumb/text (not a truncated excerpt
 * window like searchEntries) — for when the caller knows a fragment of what they're
 * looking for but not which entry holds it. Shared by grepFhHelp and
 * grepGedcomKnowledge; each maps the returned entries into its own result shape. */
export function grepEntries<T extends SearchableEntry>(
  corpus: T[],
  pattern: string,
  options: { regex?: boolean; limit?: number },
  limits: GrepLimits,
): GrepResult<T> {
  const limit = Math.min(options.limit ?? limits.defaultLimit, limits.maxLimit);
  const matcher = buildGrepMatcher(pattern, options.regex ?? false);

  const allMatches = corpus.filter(
    (entry) => matcher(entry.title) || matcher(entry.breadcrumb.join(" ")) || matcher(entry.text),
  );

  const matches: T[] = [];
  let totalBytes = 0;
  for (const entry of allMatches) {
    if (matches.length >= limit) break;
    const bytes = Buffer.byteLength(entry.text, "utf8");
    // The `matches.length > 0` guard lets a single entry through even if it alone
    // exceeds the byte cap, so one oversized entry can't turn a real match into "no results".
    if (matches.length > 0 && totalBytes + bytes > limits.maxTotalBytes) break;
    totalBytes += bytes;
    matches.push(entry);
  }

  return {
    matches,
    totalMatches: allMatches.length,
    truncated: matches.length < allMatches.length,
  };
}
