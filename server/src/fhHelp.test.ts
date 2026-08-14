import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  getFhHelpPage,
  GREP_FH_HELP_DESCRIPTION,
  grepFhHelp,
  loadCorpusFromFile,
  parseCorpus,
  registerFhHelpTools,
  resourceUriForUrl,
  searchFhHelp,
  SEARCH_FH_HELP_DESCRIPTION,
} from "./fhHelp.js";
import type { FhHelpCorpusStore } from "./fhHelp.js";

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

describe("SEARCH_FH_HELP_DESCRIPTION byte budget (issue #101 follow-up)", () => {
  // Same failure class ADR 0011 found for RUN_LUA_DESCRIPTION: MCP clients that load tool
  // descriptions via deferred/lazy schema-loading truncate around ~2048 bytes. This
  // description had grown past that point with no safe-zoning of its own -- re-zoned here
  // while adding the grep_fh_help fallback mention below, rather than growing it further.
  it("stays under the observed ~2048-byte truncation point", () => {
    expect(Buffer.byteLength(SEARCH_FH_HELP_DESCRIPTION, "utf8")).toBeLessThan(2000);
  });

  it("still tells Claude to use grep_fh_help when an excerpt or narrower query isn't enough", () => {
    expect(SEARCH_FH_HELP_DESCRIPTION).toMatch(/grep_fh_help/);
  });

  it("still tells Claude to search before writing a run_lua script when uncertain of an API shape", () => {
    const lower = SEARCH_FH_HELP_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/before writing a run_lua script/);
  });
});

describe("GREP_FH_HELP_DESCRIPTION byte budget and fhu.* discoverability (issue #102)", () => {
  // Same ~2048-byte deferred-tool-loading truncation risk docs/adr/0011 found for
  // RUN_LUA_DESCRIPTION -- this description had headroom to spare (unlike
  // RUN_LUA_DESCRIPTION/SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION, both already near their own
  // tested ceilings), so the new fhu.* discoverability pointer landed here instead.
  it("stays under the observed ~2048-byte truncation point", () => {
    expect(Buffer.byteLength(GREP_FH_HELP_DESCRIPTION, "utf8")).toBeLessThan(2000);
  });

  it('still tells Claude to grep the "Function Index" page for every bare fh* global name', () => {
    expect(GREP_FH_HELP_DESCRIPTION).toMatch(/Function Index/);
  });

  it('tells Claude to grep the "fhUtils.md" breadcrumb to list every fhu.* entry, since fhu.* has no single-entry index of its own', () => {
    expect(GREP_FH_HELP_DESCRIPTION).toContain('"fhUtils.md"');
    expect(GREP_FH_HELP_DESCRIPTION.toLowerCase()).toMatch(/fhu\.\* .*no single-entry index/);
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

describe("registerFhHelpTools", () => {
  // Registers the tools/resource on a real McpServer and calls them over a real
  // (in-memory) MCP client connection -- the only way to exercise searchResult/grepResult
  // and the registered handler closures themselves, as opposed to the pure functions
  // (searchFhHelp, grepFhHelp, getFhHelpPage) every test above calls directly.
  async function connectedClient(store: FhHelpCorpusStore) {
    const server = new McpServer({ name: "fh-mcp-bridge", version: "0.0.0-test" });
    registerFhHelpTools(server, store);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "fhHelp-test", version: "0.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    return { client, server };
  }

  describe("search_fh_help tool", () => {
    it("returns the matches as JSON when the query matches something", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({ name: "search_fh_help", arguments: { query: "merge" } });
        expect(result.isError).toBeFalsy();
        const text = (result.content as Array<{ text: string }>)[0].text;
        expect(JSON.parse(text)).toEqual(searchFhHelp(parseCorpus(FIXTURE_JSONL), "merge"));
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("returns a retry hint (not an error, not an empty array) when the query matches nothing", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "search_fh_help",
          arguments: { query: "xyzzynonexistentterm" },
        });
        expect(result.isError).toBeFalsy();
        const text = (result.content as Array<{ text: string }>)[0].text;
        expect(text).toContain('No match for "xyzzynonexistentterm"');
        expect(text).toContain("retry with a single keyword");
      } finally {
        await client.close();
        await server.close();
      }
    });
  });

  describe("grep_fh_help tool", () => {
    it("returns matches as JSON, untruncated, when everything fits under the limit", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({ name: "grep_fh_help", arguments: { pattern: "Map Window" } });
        expect(result.isError).toBeFalsy();
        const body = JSON.parse((result.content as Array<{ text: string }>)[0].text);
        expect(body.matches).toHaveLength(1);
        expect(body.truncated).toBe(false);
        expect(body.note).toBeUndefined();
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("returns a no-match message (not an error) when the pattern matches nothing", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "grep_fh_help",
          arguments: { pattern: "xyzzynonexistentterm" },
        });
        expect(result.isError).toBeFalsy();
        const text = (result.content as Array<{ text: string }>)[0].text;
        expect(text).toContain('No match for "xyzzynonexistentterm" anywhere in the corpus');
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("adds a truncation note when limit caps the returned matches below the total", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        // "How to" matches both the merging-people and plugin-tutorial breadcrumbs.
        const result = await client.callTool({
          name: "grep_fh_help",
          arguments: { pattern: "How to", limit: 1 },
        });
        const body = JSON.parse((result.content as Array<{ text: string }>)[0].text);
        expect(body.matches).toHaveLength(1);
        expect(body.totalMatches).toBe(2);
        expect(body.truncated).toBe(true);
        expect(body.note).toContain("Narrow the pattern");
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("reports an invalid regex pattern as a tool error instead of throwing through the handler", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "grep_fh_help",
          arguments: { pattern: "(unclosed", regex: true },
        });
        expect(result.isError).toBe(true);
        const text = (result.content as Array<{ text: string }>)[0].text;
        expect(text).toContain("Invalid pattern:");
      } finally {
        await client.close();
        await server.close();
      }
    });
  });

  describe("fh_help_page resource", () => {
    it("returns the topic's full text for a uri matching a topic in the store", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.readResource({ uri: resourceUriForUrl("/help/fh8/mapwindow.html") });
        expect(result.contents).toEqual([
          {
            uri: resourceUriForUrl("/help/fh8/mapwindow.html"),
            mimeType: "text/plain",
            text: "The Map Window shows places on a map. Use the Map Window to add shapes.",
          },
        ]);
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("rejects a uri with no matching topic in the store", async () => {
      const { client, server } = await connectedClient({ topics: parseCorpus(FIXTURE_JSONL) });
      try {
        await expect(
          client.readResource({ uri: resourceUriForUrl("/help/fh8/does-not-exist.html") }),
        ).rejects.toThrow();
      } finally {
        await client.close();
        await server.close();
      }
    });
  });
});
