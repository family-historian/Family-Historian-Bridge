import { describe, expect, it } from "vitest";
import {
  buildExcerpt,
  buildGrepMatcher,
  grepEntries,
  searchEntries,
  tokenize,
  tokenMatchScore,
  type SearchableEntry,
} from "./corpusSearch.js";

function entry(overrides: Partial<SearchableEntry>): SearchableEntry {
  return {
    title: "",
    breadcrumb: [],
    text: "",
    ...overrides,
  };
}

describe("tokenize", () => {
  it("lowercases and splits on non-alphanumeric runs", () => {
    // "two" is itself a stopword (see the next test), so this uses a query without one.
    expect(tokenize("Merge Some People!")).toEqual(["merge", "some", "people"]);
  });

  it("drops stopwords", () => {
    // "how do i merge two individuals" — a realistic natural-language query —
    // should reduce to the words that actually distinguish the topic.
    expect(tokenize("how do i merge two individuals")).toEqual(["merge", "individuals"]);
  });

  it("drops tokens shorter than TOKEN_MIN_LENGTH (2)", () => {
    expect(tokenize("a bc d ef")).toEqual(["bc", "ef"]);
  });

  it("de-duplicates repeated tokens", () => {
    expect(tokenize("merge merge merge")).toEqual(["merge"]);
  });

  it("returns an empty array when the whole query is stopwords", () => {
    expect(tokenize("how do i")).toEqual([]);
  });
});

describe("tokenMatchScore", () => {
  it("scores a title match higher than a breadcrumb match", () => {
    const titleHit = entry({ title: "Merging records" });
    const breadcrumbHit = entry({ breadcrumb: ["How to...", "Merging records"] });
    const tokens = tokenize("merging");
    expect(tokenMatchScore(titleHit, tokens)).toBeGreaterThan(
      tokenMatchScore(breadcrumbHit, tokens),
    );
  });

  it("scores a breadcrumb match higher than a body-text-only match", () => {
    const breadcrumbHit = entry({ breadcrumb: ["Merging records"] });
    const textHit = entry({ text: "This page explains merging records in detail." });
    const tokens = tokenize("merging");
    expect(tokenMatchScore(breadcrumbHit, tokens)).toBeGreaterThan(
      tokenMatchScore(textHit, tokens),
    );
  });

  it("only counts a token once, at its best (title > breadcrumb > text) location", () => {
    const titleAndText = entry({
      title: "Merging records",
      text: "merging merging merging merging",
    });
    const textOnly = entry({ text: "merging" });
    const tokens = tokenize("merging");
    // If text-location hits were also counted, titleAndText's repeated "merging" in the
    // body would inflate its score further — this pins that each token contributes once.
    expect(tokenMatchScore(titleAndText, tokens)).toBe(
      tokenMatchScore(entry({ title: "Merging records" }), tokens),
    );
    expect(tokenMatchScore(textOnly, tokens)).toBeGreaterThan(0);
  });

  it("scores zero when no token appears anywhere", () => {
    const noHit = entry({ title: "Unrelated topic" });
    expect(tokenMatchScore(noHit, tokenize("merging records"))).toBe(0);
  });

  it("sums scores across multiple matching tokens", () => {
    const bothInTitle = entry({ title: "Merge Individuals" });
    const oneInTitle = entry({ title: "Merge tool" });
    const tokens = tokenize("merge individuals");
    expect(tokenMatchScore(bothInTitle, tokens)).toBeGreaterThan(
      tokenMatchScore(oneInTitle, tokens),
    );
  });
});

describe("buildExcerpt", () => {
  it("returns the whole text untouched when it's short and matches", () => {
    expect(buildExcerpt("Merge two people here.", "merge")).toBe("Merge two people here.");
  });

  it("windows around a match in the middle of a long text, with ellipses both sides", () => {
    const text = `${"a".repeat(150)} NEEDLE ${"b".repeat(150)}`;
    const excerpt = buildExcerpt(text, "NEEDLE");
    expect(excerpt.startsWith("…")).toBe(true);
    expect(excerpt.endsWith("…")).toBe(true);
    expect(excerpt).toContain("NEEDLE");
  });

  it("omits the leading ellipsis when the match is near the start", () => {
    const text = `NEEDLE ${"b".repeat(150)}`;
    const excerpt = buildExcerpt(text, "NEEDLE");
    expect(excerpt.startsWith("…")).toBe(false);
    expect(excerpt.endsWith("…")).toBe(true);
  });

  it("omits the trailing ellipsis when the match is near the end", () => {
    const text = `${"a".repeat(150)} NEEDLE`;
    const excerpt = buildExcerpt(text, "NEEDLE");
    expect(excerpt.startsWith("…")).toBe(true);
    expect(excerpt.endsWith("…")).toBe(false);
  });

  it("is case-insensitive when locating the match", () => {
    const excerpt = buildExcerpt("The Map Window shows places.", "map window");
    expect(excerpt).toContain("Map Window");
  });

  it("falls back to a leading slice, marked with a trailing ellipsis, when there's no match", () => {
    const text = "x".repeat(500);
    const excerpt = buildExcerpt(text, "needle not present anywhere");
    expect(excerpt.length).toBeLessThan(text.length);
    expect(excerpt.endsWith("…")).toBe(true);
  });

  it("falls back without a trailing ellipsis when the no-match text is already short", () => {
    const text = "short text, no needle here";
    const excerpt = buildExcerpt(text, "absent");
    expect(excerpt).toBe(text);
    expect(excerpt.endsWith("…")).toBe(false);
  });
});

describe("searchEntries", () => {
  const corpus: SearchableEntry[] = [
    entry({
      title: "The Map Window",
      breadcrumb: ["Getting Started", "Workspace Windows", "The Map Window"],
      text: "The Map Window shows places on a map. Use the Map Window to add shapes.",
    }),
    entry({
      title: "Merging Duplicate People",
      breadcrumb: ["How to...", "Merging Duplicate People"],
      text: "To merge two people, select both records and choose Merge from the menu.",
    }),
    entry({
      title: "How to Write Plugins",
      breadcrumb: ["How to Write Plugins"],
      text: "This tutorial explains how to write a Family Historian plugin in Lua, and mentions merging only in passing.",
    }),
  ];

  it("returns an empty array for a blank query", () => {
    expect(searchEntries(corpus, "", 5)).toEqual([]);
    expect(searchEntries(corpus, "   ", 5)).toEqual([]);
  });

  it("ranks an exact title substring match first", () => {
    const results = searchEntries(corpus, "map window", 5);
    expect(results[0]?.entry.title).toBe("The Map Window");
  });

  it("sorts a titled match ahead of an earlier body-only match, regardless of raw corpus order", () => {
    // The titled entry is deliberately placed after the body-only and breadcrumb-only
    // entries in raw corpus order, so this only passes if `scored` is actually sorted
    // by rank before truncating to `limit`.
    const rankOrderCorpus: SearchableEntry[] = [
      entry({
        title: "Unrelated Topic",
        breadcrumb: ["Unrelated"],
        text: "This page mentions sourcing only in passing, as an aside.",
      }),
      entry({
        title: "Another Unrelated Topic",
        breadcrumb: ["How to...", "Sourcing Basics"],
        text: "This page doesn't discuss the term itself.",
      }),
      entry({
        title: "Sourcing Records",
        breadcrumb: ["How to...", "Sourcing Records"],
        text: "This page explains sourcing records.",
      }),
    ];

    const results = searchEntries(rankOrderCorpus, "sourcing", 1);
    expect(results[0]?.entry.title).toBe("Sourcing Records");
  });

  it("ranks a breadcrumb substring match above a body-only substring match", () => {
    const results = searchEntries(corpus, "merging duplicate", 5);
    expect(results[0]?.entry.title).toBe("Merging Duplicate People");
  });

  it("falls back to token scoring for a natural-language query with no exact substring", () => {
    // No entry literally contains "how do i merge two people" as a substring, so this
    // exercises the tokenize()+tokenMatchScore() fallback path.
    const results = searchEntries(corpus, "how do i merge two people", 5);
    expect(results[0]?.entry.title).toBe("Merging Duplicate People");
  });

  it("excludes entries that score zero in the fallback path", () => {
    const results = searchEntries(corpus, "how do i merge two people", 5);
    expect(results.map((r) => r.entry.title)).not.toContain("The Map Window");
  });

  it("respects the limit", () => {
    const results = searchEntries(corpus, "how to", 1);
    expect(results).toHaveLength(1);
  });

  it("attaches a matching excerpt to each result", () => {
    const results = searchEntries(corpus, "map window", 5);
    expect(results[0]?.excerpt).toContain("Map Window");
  });
});

describe("buildGrepMatcher", () => {
  it("matches a literal substring case-insensitively by default", () => {
    const matcher = buildGrepMatcher("Map Window", false);
    expect(matcher("the map window shows places")).toBe(true);
    expect(matcher("no match here")).toBe(false);
  });

  it("treats the pattern literally, not as regex, unless isRegex is true", () => {
    const matcher = buildGrepMatcher("Map.Window", false);
    expect(matcher("Map Window")).toBe(false);
    expect(matcher("Map.Window")).toBe(true);
  });

  it("matches as a case-insensitive regex when isRegex is true", () => {
    const matcher = buildGrepMatcher("select (both|all) records", true);
    expect(matcher("please SELECT BOTH RECORDS now")).toBe(true);
  });

  it("throws a descriptive error for an invalid regex pattern", () => {
    expect(() => buildGrepMatcher("(unclosed", true)).toThrow();
  });
});

const GREP_LIMITS = { defaultLimit: 10, maxLimit: 25, maxTotalBytes: 200_000 };

function grepFixture(count: number, text = "Contains the word needle in every entry."): SearchableEntry[] {
  return Array.from({ length: count }, (_, i) => entry({ title: `Topic ${i}`, breadcrumb: ["Topics"], text }));
}

describe("grepEntries", () => {
  it("matches a literal substring in the body even when the title doesn't contain it", () => {
    const corpus = [entry({ title: "Unrelated", text: "select both records to merge" })];
    const result = grepEntries(corpus, "select both records", {}, GREP_LIMITS);
    expect(result.matches).toEqual(corpus);
  });

  it("returns no matches and totalMatches 0 for a pattern found nowhere", () => {
    const corpus = [entry({ title: "Unrelated", text: "nothing relevant" })];
    const result = grepEntries(corpus, "xyzzy nonsense query", {}, GREP_LIMITS);
    expect(result.matches).toEqual([]);
    expect(result.totalMatches).toBe(0);
    expect(result.truncated).toBe(false);
  });

  it("caps the number of returned matches at the given limit and reports truncation", () => {
    const corpus = grepFixture(30);
    const result = grepEntries(corpus, "needle", { limit: 5 }, GREP_LIMITS);
    expect(result.matches).toHaveLength(5);
    expect(result.totalMatches).toBe(30);
    expect(result.truncated).toBe(true);
  });

  it("defaults to the configured defaultLimit when no limit is given", () => {
    const corpus = grepFixture(30);
    const result = grepEntries(corpus, "needle", {}, GREP_LIMITS);
    expect(result.matches).toHaveLength(10);
    expect(result.truncated).toBe(true);
  });

  it("clamps a caller-supplied limit above maxLimit down to maxLimit", () => {
    const corpus = grepFixture(30);
    const result = grepEntries(corpus, "needle", { limit: 1000 }, GREP_LIMITS);
    expect(result.matches).toHaveLength(25);
  });

  it("caps total returned bytes so a broad pattern can't dump the whole corpus", () => {
    const bigText = "needle ".repeat(50_000); // ~350KB in one entry
    const corpus = grepFixture(10, bigText);
    const result = grepEntries(corpus, "needle", { limit: 10 }, GREP_LIMITS);
    expect(result.matches.length).toBeLessThan(10);
    expect(result.truncated).toBe(true);
  });

  it("still returns at least one match even if that single entry alone exceeds the byte cap", () => {
    const hugeText = "needle ".repeat(200_000); // ~1.4MB, larger than the byte cap alone
    const corpus = [entry({ title: "Huge", text: hugeText })];
    const result = grepEntries(corpus, "needle", {}, GREP_LIMITS);
    expect(result.matches).toHaveLength(1);
  });

  it("supports a regex pattern via options.regex", () => {
    const corpus = [entry({ title: "Unrelated", text: "select both records to merge" })];
    const result = grepEntries(corpus, "select (both|all) records", { regex: true }, GREP_LIMITS);
    expect(result.matches).toEqual(corpus);
  });

  it("respects independently configured limits per caller (e.g. a smaller corpus wanting a higher default)", () => {
    const corpus = grepFixture(30);
    const result = grepEntries(corpus, "needle", {}, { defaultLimit: 25, maxLimit: 25, maxTotalBytes: 200_000 });
    expect(result.matches).toHaveLength(25);
  });
});
