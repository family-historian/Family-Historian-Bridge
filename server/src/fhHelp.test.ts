import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  getFhHelpPage,
  grepFhHelp,
  loadCorpusFromFile,
  parseCorpus,
  resourceUriForUrl,
  searchFhHelp,
} from "./fhHelp.js";

const FIXTURE_JSONL = [
  JSON.stringify({
    url: "/help/fh8/mapwindow.html",
    section: "fh8",
    title: "The Map Window",
    breadcrumb: ["Getting Started", "Workspace Windows", "The Map Window"],
    text: "The Map Window shows places on a map. Use the Map Window to add shapes.",
  }),
  JSON.stringify({
    url: "/help/fh8/mergingpeople.html",
    section: "fh8",
    title: "Merging Duplicate People",
    breadcrumb: ["How to...", "Merging Duplicate People"],
    text: "To merge two people, select both records and choose Merge from the menu.",
  }),
  JSON.stringify({
    url: "/help/fh8plugins/tutorial/tutorial.htm",
    section: "fh8plugins",
    title: "How to Write Plugins",
    breadcrumb: ["How to Write Plugins"],
    text: "This tutorial explains how to write a Family Historian plugin in Lua.",
  }),
].join("\n");

describe("parseCorpus", () => {
  it("parses one topic per line", () => {
    const corpus = parseCorpus(FIXTURE_JSONL);
    expect(corpus).toHaveLength(3);
    expect(corpus[0]).toEqual({
      url: "/help/fh8/mapwindow.html",
      section: "fh8",
      title: "The Map Window",
      breadcrumb: ["Getting Started", "Workspace Windows", "The Map Window"],
      text: "The Map Window shows places on a map. Use the Map Window to add shapes.",
    });
  });

  it("skips blank lines (trailing newline in the source file)", () => {
    const corpus = parseCorpus(`${FIXTURE_JSONL}\n`);
    expect(corpus).toHaveLength(3);
  });
});

describe("searchFhHelp", () => {
  const corpus = parseCorpus(FIXTURE_JSONL);

  it("matches on title", () => {
    const results = searchFhHelp(corpus, "Map Window");
    expect(results.map((r) => r.url)).toContain("/help/fh8/mapwindow.html");
  });

  it("matches on body text even when the title doesn't contain the query", () => {
    const results = searchFhHelp(corpus, "select both records");
    expect(results.map((r) => r.url)).toEqual(["/help/fh8/mergingpeople.html"]);
  });

  it("is case-insensitive", () => {
    const results = searchFhHelp(corpus, "MERGE");
    expect(results.map((r) => r.url)).toContain("/help/fh8/mergingpeople.html");
  });

  it("ranks a title match above a body-only match", () => {
    const results = searchFhHelp(corpus, "Map");
    expect(results[0]?.url).toBe("/help/fh8/mapwindow.html");
  });

  it("returns an empty array when nothing matches, even after the token fallback", () => {
    expect(searchFhHelp(corpus, "xyzzy nonsense query")).toEqual([]);
  });

  it("falls back to individual-word matching when the full phrase isn't a literal substring anywhere", () => {
    // Beta feedback, 2026-07-29: "merge individuals" returned 0 hits pre-fallback even
    // though "merge" alone matches — a natural-language phrasing shouldn't dead-end.
    const results = searchFhHelp(corpus, "merge individuals");
    expect(results.map((r) => r.url)).toContain("/help/fh8/mergingpeople.html");
  });

  it("strips filler words so a full question still reduces to its meaningful terms", () => {
    // "how", "do", "i" are stopwords; only "write" and "plugins" should drive the match.
    const results = searchFhHelp(corpus, "how do I write plugins");
    expect(results.map((r) => r.url)).toContain("/help/fh8plugins/tutorial/tutorial.htm");
  });

  it("ranks a topic matching more of the query's words above one matching fewer", () => {
    const results = searchFhHelp(corpus, "map window shapes merge");
    // "Map Window" text contains both "map"/"window" and "shapes"; the merge page only
    // contains "merge" — the map page should rank first under the token fallback.
    expect(results[0]?.url).toBe("/help/fh8/mapwindow.html");
  });

  it("weighs a single title match above several body-only matches on other topics", () => {
    // "window" hits the Map Window page's title (one token); "select"/"records"/"choose"/
    // "menu" all hit the merging page's body only (four tokens, zero in its title). A flat
    // token count would rank the merging page first (4 hits vs 1); title/breadcrumb
    // matches must outweigh raw body-match count, mirroring the primary search's own
    // title > breadcrumb > text ordering.
    const results = searchFhHelp(corpus, "window select records choose menu");
    expect(results[0]?.url).toBe("/help/fh8/mapwindow.html");
  });

  it("returns the resource uri and an excerpt for each match", () => {
    const [result] = searchFhHelp(corpus, "merge");
    expect(result?.uri).toBe("fh-help:/help/fh8/mergingpeople.html");
    expect(result?.excerpt).toContain("merge");
    expect(result?.breadcrumb).toEqual(["How to...", "Merging Duplicate People"]);
  });

  it("caps results at the given limit", () => {
    const results = searchFhHelp(corpus, "the", 1);
    expect(results).toHaveLength(1);
  });
});

describe("getFhHelpPage", () => {
  const corpus = parseCorpus(FIXTURE_JSONL);

  it("returns the full text for a known url", () => {
    expect(getFhHelpPage(corpus, "/help/fh8/mapwindow.html")).toBe(
      "The Map Window shows places on a map. Use the Map Window to add shapes.",
    );
  });

  it("returns undefined for an unknown url", () => {
    expect(getFhHelpPage(corpus, "/help/fh8/doesnotexist.html")).toBeUndefined();
  });
});

describe("resourceUriForUrl", () => {
  it("prefixes the corpus url with the fh-help scheme", () => {
    expect(resourceUriForUrl("/help/fh8/mapwindow.html")).toBe(
      "fh-help:/help/fh8/mapwindow.html",
    );
  });
});

describe("grepFhHelp", () => {
  const corpus = parseCorpus(FIXTURE_JSONL);

  it("matches a literal substring in the body even when the title doesn't contain it", () => {
    const result = grepFhHelp(corpus, "select both records");
    expect(result.matches.map((m) => m.url)).toEqual(["/help/fh8/mergingpeople.html"]);
  });

  it("returns the entry's full text, not a truncated excerpt", () => {
    const result = grepFhHelp(corpus, "select both records");
    expect(result.matches[0]?.text).toBe(
      "To merge two people, select both records and choose Merge from the menu.",
    );
  });

  it("matches on title", () => {
    const result = grepFhHelp(corpus, "Map Window");
    expect(result.matches.map((m) => m.url)).toContain("/help/fh8/mapwindow.html");
  });

  it("matches on breadcrumb", () => {
    const result = grepFhHelp(corpus, "Workspace Windows");
    expect(result.matches.map((m) => m.url)).toContain("/help/fh8/mapwindow.html");
  });

  it("is case-insensitive by default", () => {
    const result = grepFhHelp(corpus, "MERGE");
    expect(result.matches.map((m) => m.url)).toContain("/help/fh8/mergingpeople.html");
  });

  it("returns no matches and totalMatches 0 for a pattern found nowhere", () => {
    const result = grepFhHelp(corpus, "xyzzy nonsense query");
    expect(result.matches).toEqual([]);
    expect(result.totalMatches).toBe(0);
    expect(result.truncated).toBe(false);
  });

  it("returns the resource uri, title, and breadcrumb alongside the full text", () => {
    const result = grepFhHelp(corpus, "merge");
    const match = result.matches.find((m) => m.url === "/help/fh8/mergingpeople.html");
    expect(match?.uri).toBe("fh-help:/help/fh8/mergingpeople.html");
    expect(match?.title).toBe("Merging Duplicate People");
    expect(match?.breadcrumb).toEqual(["How to...", "Merging Duplicate People"]);
  });

  it("does not require the pattern to be a literal substring anywhere when regex is requested", () => {
    const result = grepFhHelp(corpus, "select (both|all) records", { regex: true });
    expect(result.matches.map((m) => m.url)).toEqual(["/help/fh8/mergingpeople.html"]);
  });

  it("treats the pattern literally (not as regex) unless regex is requested", () => {
    // "Map." isn't literally in the corpus - the "." would only match as regex wildcard.
    const result = grepFhHelp(corpus, "Map.Window");
    expect(result.matches).toEqual([]);
  });

  it("throws a descriptive error for an invalid regex pattern", () => {
    expect(() => grepFhHelp(corpus, "(unclosed", { regex: true })).toThrow();
  });

  it("caps the number of returned matches and reports truncation", () => {
    const manyEntries = Array.from({ length: 30 }, (_, i) =>
      JSON.stringify({
        url: `/help/fh8/topic${i}.html`,
        section: "fh8",
        title: `Topic ${i}`,
        breadcrumb: ["Topics"],
        text: "Contains the word needle in every entry.",
      }),
    ).join("\n");
    const bigCorpus = parseCorpus(manyEntries);
    const result = grepFhHelp(bigCorpus, "needle", { limit: 5 });
    expect(result.matches).toHaveLength(5);
    expect(result.totalMatches).toBe(30);
    expect(result.truncated).toBe(true);
  });

  it("defaults to a sensible match cap even when no limit is given", () => {
    const manyEntries = Array.from({ length: 30 }, (_, i) =>
      JSON.stringify({
        url: `/help/fh8/topic${i}.html`,
        section: "fh8",
        title: `Topic ${i}`,
        breadcrumb: ["Topics"],
        text: "Contains the word needle in every entry.",
      }),
    ).join("\n");
    const bigCorpus = parseCorpus(manyEntries);
    const result = grepFhHelp(bigCorpus, "needle");
    expect(result.matches.length).toBeLessThan(30);
    expect(result.truncated).toBe(true);
  });

  it("caps total returned bytes so a broad pattern can't dump the whole corpus", () => {
    const bigText = "needle ".repeat(50_000); // ~350KB in one entry
    const manyEntries = Array.from({ length: 10 }, (_, i) =>
      JSON.stringify({
        url: `/help/fh8/big${i}.html`,
        section: "fh8",
        title: `Big ${i}`,
        breadcrumb: ["Topics"],
        text: bigText,
      }),
    ).join("\n");
    const bigCorpus = parseCorpus(manyEntries);
    const result = grepFhHelp(bigCorpus, "needle", { limit: 10 });
    expect(result.matches.length).toBeLessThan(10);
    expect(result.truncated).toBe(true);
  });

  it("still returns at least one match even if that single entry alone exceeds the byte cap", () => {
    const hugeText = "needle ".repeat(200_000); // ~1.4MB, larger than the byte cap alone
    const corpusWithHugeEntry = parseCorpus(
      JSON.stringify({
        url: "/help/fh8/huge.html",
        section: "fh8",
        title: "Huge",
        breadcrumb: ["Topics"],
        text: hugeText,
      }),
    );
    const result = grepFhHelp(corpusWithHugeEntry, "needle");
    expect(result.matches).toHaveLength(1);
  });
});

describe("grepFhHelp real-corpus case (issue #21)", () => {
  it("finds a sample script by a function call it contains, not by its title", () => {
    const corpus = loadCorpusFromFile(
      fileURLToPath(new URL("../data/fh-help-corpus.jsonl", import.meta.url)),
    );
    const result = grepFhHelp(corpus, "fhCallBuiltInFunction");
    const match = result.matches.find((m) => m.url === "/help/fh8plugins/Samples/AllSurnames.htm");
    expect(match).toBeDefined();
    expect(match?.title).not.toContain("fhCallBuiltInFunction");
    expect(match?.text).toContain("fhCallBuiltInFunction");
  });
});
