import { describe, expect, it } from "vitest";
import {
  getFhHelpPage,
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
