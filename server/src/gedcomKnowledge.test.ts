import { describe, expect, it } from "vitest";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  getGedcomKnowledgeEntry,
  GREP_GEDCOM_KNOWLEDGE_DESCRIPTION,
  grepGedcomKnowledge,
  loadGedcomKnowledgeFromFile,
  parseGedcomKnowledgeCorpus,
  registerGedcomKnowledgeTools,
  searchGedcomKnowledge,
  SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION,
} from "./gedcomKnowledge.js";
import type { GedcomKnowledgeEntry, GedcomKnowledgeStore } from "./gedcomKnowledge.js";
import { checkFhHelpUpdates } from "./fhHelpUpdate.js";
import { parseCorpus as parseFhHelpCorpus } from "./fhHelp.js";

const FIXTURE_JSONL = [
  JSON.stringify({
    id: "ftf-tables",
    title: "FTF tables",
    breadcrumb: ["FTF rich text", "Tables"],
    confidence: "Documented",
    source: "FH help: /help/fh8plugins/api/ftf_syntax.htm",
    text: "<table=\"w1|w2|...\"> ... </table> marks a table; <row>...</row> marks a row; cells are separated by |.",
  }),
  JSON.stringify({
    id: "private-text",
    title: "Private text markers",
    breadcrumb: ["FTF rich text", "Private text"],
    confidence: "Documented",
    source: "FH help: /help/fh8/privatenotes.html",
    text: "Doubled square brackets [[like this]] mark a span of text as private.",
  }),
  JSON.stringify({
    id: "fact-flag-vs-record-flag",
    title: "Fact Flag vs Record Flag",
    breadcrumb: ["Flags"],
    confidence: "Documented",
    source: "FH help: /help/fh8/howto_flagafact.html",
    text: "Record flags mark a whole Individual record; fact flags mark one specific fact. Rejected always overrides Preferred on the same fact.",
  }),
].join("\n");

describe("parseGedcomKnowledgeCorpus", () => {
  it("parses one entry per line", () => {
    const corpus = parseGedcomKnowledgeCorpus(FIXTURE_JSONL);
    expect(corpus).toHaveLength(3);
    expect(corpus[0]).toEqual({
      id: "ftf-tables",
      title: "FTF tables",
      breadcrumb: ["FTF rich text", "Tables"],
      confidence: "Documented",
      source: "FH help: /help/fh8plugins/api/ftf_syntax.htm",
      text: "<table=\"w1|w2|...\"> ... </table> marks a table; <row>...</row> marks a row; cells are separated by |.",
    });
  });

  it("skips blank lines (trailing newline in the source file)", () => {
    const corpus = parseGedcomKnowledgeCorpus(`${FIXTURE_JSONL}\n`);
    expect(corpus).toHaveLength(3);
  });
});

describe("searchGedcomKnowledge", () => {
  const corpus = parseGedcomKnowledgeCorpus(FIXTURE_JSONL);

  it("returns FTF markup entries for a table query", () => {
    const results = searchGedcomKnowledge(corpus, "table");
    expect(results.matches.map((r) => r.id)).toContain("ftf-tables");
  });

  it("returns FTF markup entries for a private text query", () => {
    const results = searchGedcomKnowledge(corpus, "private text");
    expect(results.matches.map((r) => r.id)).toContain("private-text");
  });

  it("returns the Fact Flag / Record Flag entry for a flag query", () => {
    const results = searchGedcomKnowledge(corpus, "record flag");
    expect(results.matches.map((r) => r.id)).toContain("fact-flag-vs-record-flag");
  });

  it("includes confidence and source on each result", () => {
    const [result] = searchGedcomKnowledge(corpus, "table").matches;
    expect(result?.confidence).toBe("Documented");
    expect(result?.source).toBe("FH help: /help/fh8plugins/api/ftf_syntax.htm");
  });

  it("includes the full entry text, not just an excerpt", () => {
    const [result] = searchGedcomKnowledge(corpus, "table").matches;
    expect(result?.text).toContain("marks a table");
    expect(result?.text).toContain("cells are separated by |");
  });

  it("returns an empty matches array and truncated: false when nothing matches", () => {
    const result = searchGedcomKnowledge(corpus, "xyzzy nonsense query");
    expect(result.matches).toEqual([]);
    expect(result.truncated).toBe(false);
    expect(result.index).toBeUndefined();
  });

  it("caps total result size, naming the rest in a compact index rather than dropping them (issue #135)", () => {
    // Each entry's serialized text is ~1KB; more than SEARCH_MAX_TOTAL_BYTES (20,000) worth
    // of matches must truncate, not silently overflow the client's own response-size ceiling
    // the way a bare "run_lua guidance" search once did (issue #135).
    const bigText = "x".repeat(1000);
    const manyEntries = Array.from({ length: 30 }, (_, i) =>
      JSON.stringify({
        id: `topic-${i}`,
        title: `Topic ${i}`,
        breadcrumb: ["Topics"],
        confidence: "Documented",
        source: "test",
        text: `Contains the word needle. ${bigText}`,
      }),
    ).join("\n");
    const bigCorpus = parseGedcomKnowledgeCorpus(manyEntries);

    const result = searchGedcomKnowledge(bigCorpus, "needle", 30);

    expect(result.truncated).toBe(true);
    expect(result.matches.length).toBeGreaterThan(0);
    expect(result.matches.length).toBeLessThan(30);
    const totalBytes = result.matches.reduce((sum, e) => sum + Buffer.byteLength(JSON.stringify(e), "utf8"), 0);
    expect(totalBytes).toBeLessThanOrEqual(20_000);
    // Every ranked match -- including ones whose full text didn't fit -- is still named.
    expect(result.index).toHaveLength(30);
    expect(result.index?.map((e) => e.id)).toEqual(expect.arrayContaining(result.matches.map((e) => e.id)));
  });

  it("reports truncation and names every match even when the default limit -- not the byte cap -- is what cuts the result short", () => {
    // 25 small matching entries, well under 20,000 bytes combined even in full, so the
    // byte-cap loop alone wouldn't drop anything -- the DEFAULT_SEARCH_LIMIT (20) is what
    // has to be the thing that bounds `matches` here. Regression for the index/truncated
    // math being keyed off the limit-bound slice instead of the true total match count.
    const smallText = "small body";
    const manyEntries = Array.from({ length: 25 }, (_, i) =>
      JSON.stringify({
        id: `small-topic-${i}`,
        title: `Small Topic ${i}`,
        breadcrumb: ["Topics"],
        confidence: "Documented",
        source: "test",
        text: `Contains the word needle. ${smallText}`,
      }),
    ).join("\n");
    const corpus = parseGedcomKnowledgeCorpus(manyEntries);

    const result = searchGedcomKnowledge(corpus, "needle"); // default limit

    expect(result.truncated).toBe(true);
    expect(result.matches.length).toBe(20);
    expect(result.index).toHaveLength(25);
    expect(result.index?.map((e) => e.id).sort()).toEqual(
      Array.from({ length: 25 }, (_, i) => `small-topic-${i}`).sort(),
    );
  });

  it("still returns a single oversized entry alone rather than turning a real match into 'no results'", () => {
    const hugeText = "x".repeat(25_000);
    const oneHugeEntry = JSON.stringify({
      id: "huge-entry",
      title: "Huge entry",
      breadcrumb: ["Topics"],
      confidence: "Documented",
      source: "test",
      text: hugeText,
    });
    const corpusWithHugeEntry = parseGedcomKnowledgeCorpus(oneHugeEntry);

    const result = searchGedcomKnowledge(corpusWithHugeEntry, "huge entry");

    expect(result.matches.map((e) => e.id)).toEqual(["huge-entry"]);
    expect(result.truncated).toBe(false);
  });
});

describe("grepGedcomKnowledge", () => {
  const corpus = parseGedcomKnowledgeCorpus(FIXTURE_JSONL);

  it("matches a literal substring in the body even when the title doesn't contain it", () => {
    const result = grepGedcomKnowledge(corpus, "Rejected always overrides Preferred");
    expect(result.matches.map((m) => m.id)).toEqual(["fact-flag-vs-record-flag"]);
  });

  it("returns the complete matching entry, not an excerpt", () => {
    const result = grepGedcomKnowledge(corpus, "private");
    const match = result.matches.find((m) => m.id === "private-text");
    expect(match).toEqual(corpus.find((e) => e.id === "private-text"));
  });

  it("is case-insensitive by default", () => {
    const result = grepGedcomKnowledge(corpus, "TABLE");
    expect(result.matches.map((m) => m.id)).toContain("ftf-tables");
  });

  it("returns no matches and totalMatches 0 for a pattern found nowhere", () => {
    const result = grepGedcomKnowledge(corpus, "xyzzy nonsense query");
    expect(result.matches).toEqual([]);
    expect(result.totalMatches).toBe(0);
    expect(result.truncated).toBe(false);
  });

  it("does not require the pattern to be a literal substring anywhere when regex is requested", () => {
    const result = grepGedcomKnowledge(corpus, "mark(s)? a (whole|specific)", { regex: true });
    expect(result.matches.map((m) => m.id)).toEqual(["fact-flag-vs-record-flag"]);
  });

  it("treats the pattern literally (not as regex) unless regex is requested", () => {
    const result = grepGedcomKnowledge(corpus, "table.");
    expect(result.matches).toEqual([]);
  });

  it("throws a descriptive error for an invalid regex pattern", () => {
    expect(() => grepGedcomKnowledge(corpus, "(unclosed", { regex: true })).toThrow();
  });

  it("defaults to a higher match cap than grep_fh_help, matching this corpus's own small size", () => {
    const manyEntries = Array.from({ length: 30 }, (_, i) =>
      JSON.stringify({
        id: `topic-${i}`,
        title: `Topic ${i}`,
        breadcrumb: ["Topics"],
        confidence: "Documented",
        source: "test",
        text: "Contains the word needle in every entry.",
      }),
    ).join("\n");
    const bigCorpus = parseGedcomKnowledgeCorpus(manyEntries);
    const result = grepGedcomKnowledge(bigCorpus, "needle");
    expect(result.matches).toHaveLength(25);
    expect(result.totalMatches).toBe(30);
    expect(result.truncated).toBe(true);
  });
});

describe("grepGedcomKnowledge real-corpus case (issue #101)", () => {
  it("finds fhBridge.getFamilyGroup's documented contract by the literal function name, unburied by the token-overlap fallback a natural-language query falls back to", () => {
    const corpus = loadGedcomKnowledgeFromFile(
      fileURLToPath(new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url)),
    );
    const result = grepGedcomKnowledge(corpus, "getFamilyGroup");
    const match = result.matches.find((m) => m.id === "run-lua-guidance-family-query-helpers");
    expect(match).toBeDefined();
    expect(match?.text).toContain("fhBridge.getFamilyGroup(indiPtr, type)");
  });
});

describe("getGedcomKnowledgeEntry", () => {
  const corpus = parseGedcomKnowledgeCorpus(FIXTURE_JSONL);

  it("returns the entry for a known id", () => {
    expect(getGedcomKnowledgeEntry(corpus, "private-text")?.title).toBe("Private text markers");
  });

  it("returns undefined for an unknown id", () => {
    expect(getGedcomKnowledgeEntry(corpus, "does-not-exist")).toBeUndefined();
  });
});

describe("the real bundled corpus", () => {
  const CORPUS_PATH = fileURLToPath(new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url));
  const corpus = loadGedcomKnowledgeFromFile(CORPUS_PATH);
  const VALID_CONFIDENCE_LEVELS = new Set(["Verified", "Confirmed", "Documented", "Likely"]);

  it("has every entry carrying a confidence level and a source citation", () => {
    for (const entry of corpus) {
      expect(VALID_CONFIDENCE_LEVELS.has(entry.confidence), `${entry.id} has a valid confidence level`).toBe(true);
      expect(entry.source.trim().length, `${entry.id} has a non-empty source`).toBeGreaterThan(0);
    }
  });

  it("has unique ids", () => {
    const ids = corpus.map((e: GedcomKnowledgeEntry) => e.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("returns FTF markup entries for a table query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "table");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns FTF markup entries for a private text query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "private text");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns the Shared Facts entry for a shared facts query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "shared facts");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns the Fact Flag / Record Flag entry for a flags query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "fact flag record flag");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns a Source Template field entry for a source template field query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "source template field");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns the Sentence template entry for a sentence template query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "sentence template");
    expect(results.matches.length).toBeGreaterThan(0);
  });

  it("returns the canonical Name/Date/Place qualifier-code entries for their respective queries, not just fh-help scraps (acceptance criterion)", () => {
    // Before this, an agent asked to filter individuals by a name part (e.g. "find everyone
    // named Stephen") had no reason to search this corpus for the qualifier and instead
    // rediscovered ":GIVEN_ALL" indirectly by grepping fh-help sample scripts — see the new
    // bullet on run-lua-guidance-call-shape-gotchas below.
    const nameResults = searchGedcomKnowledge(corpus, "name qualifiers");
    expect(nameResults.matches.map((r) => r.id)).toContain("data-reference-qualifiers-name");
    const nameEntry = nameResults.matches.find((r) => r.id === "data-reference-qualifiers-name")!;
    expect(nameEntry.text).toMatch(/GIVEN_ALL/);
    expect(nameEntry.text).toMatch(/SURNAME/);

    const dateResults = searchGedcomKnowledge(corpus, "date qualifiers");
    expect(dateResults.matches.map((r) => r.id)).toContain("data-reference-qualifiers-date");

    const placeResults = searchGedcomKnowledge(corpus, "place and lat/long qualifiers");
    expect(placeResults.matches.map((r) => r.id)).toContain("data-reference-qualifiers-place-latlong");
  });

  it("does not contain excluded raw-export wire mechanics (ADR 0003 scope)", () => {
    // _SRCT is deliberately not in this list: it's also a live record-type tag (Source
    // Template record), reachable via run_lua the same way as INDI/FAM/SOUR — see
    // describeProjectTool.ts's own script and the "Creating a templated Source record"
    // corpus entry. ADR 0003 excludes the exported-.ged wire format, not this tag itself.
    const excludedTerms = ["_link_", "_lkid", "_plac gazetteer", "ansel"];
    for (const entry of corpus) {
      const haystack = `${entry.title} ${entry.text}`.toLowerCase();
      for (const term of excludedTerms) {
        expect(haystack.includes(term), `${entry.id} should not mention "${term}"`).toBe(false);
      }
    }
  });
});

describe("run_lua guidance corpus entries (docs/adr/0011-run-lua-description-truncation-workaround.md)", () => {
  // These entries hold content that used to live directly in RUN_LUA_DESCRIPTION
  // (runLuaTool.ts) but was moved out because MCP clients that load tool descriptions via
  // deferred/lazy schema-loading truncate long descriptions around ~2KB — see
  // runLuaTool.test.ts's "safe zone" tests for the pointer instruction that survives
  // truncation and tells Claude to fetch this content via search_gedcom_knowledge.
  const CORPUS_PATH = fileURLToPath(new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url));
  const corpus = loadGedcomKnowledgeFromFile(CORPUS_PATH);
  // The family's combined text (~52KB as of this comment) is well past SEARCH_MAX_TOTAL_BYTES
  // (20,000 -- issue #135), so search_gedcom_knowledge("run_lua guidance") always truncates
  // to a handful of full matches plus an index naming the rest; that's the documented,
  // intended behavior (SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION says as much), not a bug to work
  // around here. grep_gedcom_knowledge has a much higher byte cap (200,000) and is what the
  // description itself points a caller at once ranking buries something, so tests that need
  // every family member's full text pull it from there instead.
  const grepResult = grepGedcomKnowledge(corpus, "run_lua guidance");
  const combinedText = grepResult.matches.map((r) => r.text).join("\n");

  it('finds every "run_lua guidance" family entry with a single query, via breadcrumb match', () => {
    // The family has grown past its original six run-lua-guidance-*-prefixed entries
    // (e.g. checking-for-any-source-citation-is-recursive-not-getfactsbytag,
    // generation-number-needs-a-start-point) — sibling entries that share the
    // ["Bridge project conventions", "run_lua guidance", ...] breadcrumb but don't
    // follow the id-prefix naming convention (gedcom-corpus-pattern memory: extend this
    // family rather than growing RUN_LUA_DESCRIPTION). A hardcoded id list here goes
    // stale every time a new sibling is added — derive the expected set from the
    // corpus's own breadcrumb instead, so this test asserts the invariant that actually
    // matters, not a snapshot of which ones existed when this test was last touched.
    //
    // The family is bigger than SEARCH_MAX_TOTAL_BYTES (issue #135), so a direct
    // search_gedcom_knowledge call truncates -- the invariant that still must hold is that
    // every family member is named somewhere in the response (full text in matches, or
    // named in index), never silently missing from both.
    const expectedIds = corpus
      .filter((entry) => entry.breadcrumb.includes("run_lua guidance"))
      .map((entry) => entry.id)
      .sort();
    expect(expectedIds.length).toBeGreaterThanOrEqual(6);

    const searchResult = searchGedcomKnowledge(corpus, "run_lua guidance");
    const namedIds = new Set([
      ...searchResult.matches.map((r) => r.id),
      ...(searchResult.index?.map((r) => r.id) ?? []),
    ]);
    for (const id of expectedIds) {
      expect(namedIds.has(id), `${id} should be named in matches or index`).toBe(true);
    }

    // grep_gedcom_knowledge, meanwhile, is uncapped enough to return every family member's
    // full text in one call -- the fallback the tool descriptions point callers at.
    expect(grepResult.matches.map((r) => r.id).sort()).toEqual(expectedIds);
  });

  it("lists fhu.records/fhu.allItems/fhu.indiList as the check-first iteration helpers, alongside the mutation helpers (issue #47)", () => {
    expect(combinedText).toMatch(/fhu\.records/);
    expect(combinedText).toMatch(/fhu\.allItems/);
    expect(combinedText).toMatch(/fhu\.indiList/);
    expect(combinedText.toLowerCase()).toMatch(/movetofirstrecord\/movenext/);
  });

  it("tells Claude fhu is already a global in this sandbox and require('fhUtils') returns nil here (issue #48)", () => {
    expect(combinedText).toMatch(/require\('fhUtils'\)|require\("fhUtils"\)/);
    expect(combinedText.toLowerCase()).toMatch(/already a global/);
    expect(combinedText.toLowerCase()).toMatch(/nil/);
    // Distinguishes this from an ordinary FH plugin (e.g. author_fh_plugin output), where
    // require('fhUtils') genuinely is correct — this fact is bridge-sandbox-specific, not
    // a general FH one, which is why it lives here and not in the scraped fh-help corpus.
    expect(combinedText).toMatch(/author_fh_plugin/);
  });

  it("carries the eight excluded fhu methods (modal-dialog and filesystem-writing) so Claude doesn't suggest them", () => {
    for (const name of [
      "fhu.getParam",
      "fhu.createUpdateFact",
      "fhu.pickIndividualPrompt",
      "fhu.yes",
      "fhu.stripCommas",
      "fhu.saveOptions",
      "fhu.loadOptions",
      "fhu.resetOptions",
    ]) {
      expect(combinedText).toContain(name);
    }
    expect(combinedText.toLowerCase()).toMatch(/modal dialog/);
    expect(combinedText.toLowerCase()).toMatch(/hang/);
  });

  it("names fhBridge.citeSource as the way to attach a citation, instead of hand-rolling fhCreateItem+fhSetValueAsLink", () => {
    expect(combinedText).toMatch(/fhBridge\.citeSource/);
  });

  it("points at the Name/Date/Place qualifier-code entries instead of leaving them to be rediscovered via fh-help sample scripts (issue #49)", () => {
    expect(combinedText).toMatch(/name qualifiers/);
    expect(combinedText).toMatch(/data-reference-qualifiers-name/);
    expect(combinedText).toMatch(/GIVEN_ALL/);
  });

  it("instructs listing every fact a source supports and waiting for confirmation before writing any of them", () => {
    const lower = combinedText.toLowerCase();
    expect(lower).toMatch(/isn't yet (in|entered)|not yet entered|gaps?/);
    expect(lower).toMatch(/wait for the user's .*(confirmation|go-ahead)/);
  });

  it("documents FH's auto-undo safety net and what writeSessionRolledBack means", () => {
    const lower = combinedText.toLowerCase();
    expect(lower).toMatch(/auto-undo|automatic undo/);
    expect(lower).toMatch(/plugin error/);
    expect(lower).toMatch(/session has ended|session ends|click start again/);
    expect(combinedText).toMatch(/writeSessionRolledBack/);
  });

  it("documents fhBridge.logActivity's call shape, the per-Session Research Note it creates, and where to find it (issue #55)", () => {
    // The call shape and media/#ToDo detail used to live inline in RUN_LUA_DESCRIPTION;
    // moved here 2026-08-04 alongside the missing piece that actually caused issue #55 — a
    // session that called logActivity correctly had no documented way to confirm what it
    // did or where the result went.
    expect(combinedText).toMatch(/fhBridge\.logActivity\(ptrRecord, action, media\)/);
    expect(combinedText).toMatch(/fhGetDisplayText/);
    expect(combinedText).toMatch(/_RNOT/);
    expect(combinedText.toLowerCase()).toMatch(/research notes\)|browse to research notes/);
    expect(combinedText).toMatch(/fhu\.records\("_RNOT"\)/);
    expect(combinedText.toLowerCase()).toMatch(/#todo/);
  });

  it("documents fhBridge's read-only family/detail query helpers (getFamilyGroup/getAncestors/getAllDetails) by signature, that they're available under Read-only too, and that they accept a qualified id string as well as a pointer (issue #62)", () => {
    // The helpers' own parameter/return/edge-case detail (pedigree collapse, DIRECT children,
    // etc.) now lives in their individual fhbridge-* reference entries -- see the "fhBridge
    // API reference corpus entries" describe block below for those.
    expect(combinedText).toMatch(/fhBridge\.getFamilyGroup\(indiPtr, type\)/);
    expect(combinedText).toMatch(/fhBridge\.getAncestors\(indiPtr, maxGenerations, dnaLine\)/);
    expect(combinedText).toMatch(/fhBridge\.getAllDetails\(ptr\)/);
    expect(combinedText.toLowerCase()).toMatch(/both read-only and read-write/);
    expect(combinedText).toMatch(/qualified id string/);
  });

  it("documents that Date has no GetDatePoint() method, naming the correct GetDatePt1()/GetDatePt2() (issue #51)", () => {
    // Before this, a session guessed dt:GetDatePoint() based on plausible naming (the
    // DatePoint object's own name) — it doesn't exist and throws a Lua error. The correct
    // methods are dt:GetDatePt1()/dt:GetDatePt2().
    expect(combinedText).toMatch(/GetDatePoint/);
    expect(combinedText).toMatch(/GetDatePt1/);
    expect(combinedText).toMatch(/GetDatePt2/);
    expect(combinedText.toLowerCase()).toMatch(/doesn't exist|does not exist/);
  });

  it("recommends Data Reference qualifiers over the Date/DatePoint object chain for simple date extraction (issue #51)", () => {
    // fhGetItemText(ptr, "~.BIRT.DATE:YEAR") and similar qualifiers return structured date
    // values directly with no Date/DatePoint object chain and no IsNull() checks needed —
    // simpler than the object-based approach, and not what fh-help search for "get birth
    // year from date field" surfaces first.
    expect(combinedText).toMatch(/:YEAR/);
    expect(combinedText.toLowerCase()).toMatch(/dt:compare\(\)|dp:compare\(\)/);
  });

  it("documents that a bare leading-dot MoveTo data reference silently leaves the pointer Null instead of erroring, and cross-references the writeSessionRolledBack risk if it happens after an earlier write (issue #103)", () => {
    expect(combinedText).toMatch(/MoveTo\(otherPtr, strDataReference\)/);
    expect(combinedText).toMatch(/~\.DATE/);
    expect(combinedText.toLowerCase()).toMatch(/bare leading-dot/);
    expect(combinedText.toLowerCase()).toMatch(/silently leaves the pointer null|silently null/);
    expect(combinedText).toMatch(/writeSessionRolledBack/);
  });

  it("documents fhBridge's write helpers (createFact/citeSource/createSourceFromTemplate/getTftfText/setTftfText/logActivity) by signature, and that they're Read-write-Session only unlike the read-only query helpers (issue #133 follow-up)", () => {
    // Mirrors the read-only family/detail query helpers test above — the write side's own
    // parameter/return/edge-case detail lives in each function's individual fhbridge-*
    // reference entry, not repeated here.
    expect(combinedText).toMatch(/fhBridge\.createFact\(ptrRecord, sTag, sPlace, dtDate, sAddress, sValue, sAge\)/);
    expect(combinedText).toMatch(/fhBridge\.citeSource\(ptrTarget, sourceNameOrId, fields\)/);
    expect(combinedText).toMatch(/fhBridge\.createSourceFromTemplate\(templateNameOrId, fields, transcription\)/);
    expect(combinedText).toMatch(/fhBridge\.getTftfText\(ptr\)/);
    expect(combinedText).toMatch(/fhBridge\.setTftfText\(ptr, text\)/);
    expect(combinedText).toMatch(/fhBridge\.logActivity\(ptrRecord, action, media\)/);
    expect(combinedText.toLowerCase()).toMatch(/read-write-session only/);
  });
});

describe("fhBridge API reference corpus entries (issue #102, docs/adr/0024-fhbridge-api-reference-lives-in-gedcom-knowledge-corpus.md)", () => {
  // One compact entry per fhBridge.* function -- Description/Parameters/Returns, matching
  // fhu.md-derived fh-help-corpus.jsonl entries' style, not the discursive run_lua
  // guidance family above. The drift-safety invariant that matters: this set must exactly
  // match sandbox.lua's own env.fhBridge table (the single source of truth for which
  // fhBridge functions actually exist), derived here from the real file -- not a
  // hand-kept list that could silently fall behind a 13th function the same way this
  // issue found fhBridge had zero corpus entries at all.
  const CORPUS_PATH = fileURLToPath(new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url));
  const corpus = loadGedcomKnowledgeFromFile(CORPUS_PATH);
  const fhBridgeEntries = corpus.filter((entry) => entry.breadcrumb.includes("fhBridge API reference"));
  const combinedText = fhBridgeEntries.map((e) => `${e.title}\n${e.text}`).join("\n");

  // Unlike toolNames.test.ts's own "derive the expected set from the real thing" pattern
  // (which registers real TS modules against a live MCP client -- a behavioral check
  // immune to source formatting), there's no such behavioral seam across the Lua/TS
  // boundary here without standing up a Lua interpreter in this test process. This
  // regex-parses the actual env.fhBridge table literal instead -- weaker than a
  // behavioral check (a stylua reformat or brace-style change to sandbox.lua could break
  // it), but still derives from the real file rather than a hand-kept list, which is the
  // property that actually matters: a 13th fhBridge function fails this test, it doesn't
  // silently pass one that forgot to update it.
  function fhBridgeMemberNamesFromSandbox(): string[] {
    const sandboxPath = fileURLToPath(new URL("../../bridge/sandbox.lua", import.meta.url));
    const source = fs.readFileSync(sandboxPath, "utf8");
    const names = new Set<string>();

    // Base table (env.fhBridge = { ... }), built unconditionally -- every read-only member.
    const tableMatch = source.match(/env\.fhBridge = \{([\s\S]*?)\n {2}\}/);
    if (!tableMatch) throw new Error("env.fhBridge table literal not found in bridge/sandbox.lua");
    for (const line of tableMatch[1].split("\n")) {
      const nameMatch = line.match(/^\s*(\w+) = /);
      if (nameMatch) names.add(nameMatch[1]);
    }

    // Read-write-only additions (env.fhBridge.<name> = ...), inside the accessMode block.
    for (const nameMatch of source.matchAll(/env\.fhBridge\.(\w+) = /g)) {
      names.add(nameMatch[1]);
    }

    return [...names].sort();
  }

  it("has exactly one entry per fhBridge.* function sandbox.lua actually exposes -- no more, no fewer", () => {
    const expectedNames = fhBridgeMemberNamesFromSandbox();
    const documentedNames = fhBridgeEntries.map((entry) => entry.breadcrumb[2]).sort();
    expect(expectedNames.length).toBeGreaterThanOrEqual(12);
    expect(documentedNames).toEqual(expectedNames);
  });

  it("names each entry's title after its real call signature", () => {
    for (const entry of fhBridgeEntries) {
      expect(entry.title.startsWith(`fhBridge.${entry.breadcrumb[2]}(`), `${entry.id}'s title should start with its fhBridge.<fn>( signature`).toBe(true);
    }
  });

  it('finds every fhBridge API reference entry with a single query, via breadcrumb match', () => {
    // Whether this family's combined size still fits under SEARCH_MAX_TOTAL_BYTES (so
    // truncated: false) or has grown past it (truncated: true, spilling into `index`) isn't
    // pinned here -- that's expected to flip as more fhBridge functions are documented, and
    // isn't itself a defect. What matters is every entry still shows up somewhere: in
    // `matches` if it fit, in `index` if it didn't.
    const results = searchGedcomKnowledge(corpus, "fhBridge API reference");
    const foundIds = new Set([
      ...results.matches.map((r) => r.id),
      ...(results.index?.map((r) => r.id) ?? []),
    ]);
    expect([...foundIds].sort()).toEqual(fhBridgeEntries.map((e) => e.id).sort());
  });

  it("carries no example call snippets or design-history prose -- compact reference only (grilling decision, issue #102)", () => {
    for (const entry of fhBridgeEntries) {
      expect(entry.text).toMatch(/Parameters:/);
      expect(entry.text).toMatch(/Returns:/);
    }
  });

  it("documents getAncestors' pedigree-collapse dedupe (issue #62, moved here from run-lua-guidance-family-query-helpers)", () => {
    expect(combinedText).toMatch(/pedigree collapse/);
  });

  it("documents fhBridge.searchByName's contains-not-exact name matching, that either argument is optional, and which Data Reference qualifiers it matches against (issue #62)", () => {
    expect(combinedText).toMatch(/fhBridge\.searchByName\(forename, surname\)/);
    expect(combinedText.toLowerCase()).toMatch(/not exact\/whole-word/);
    expect(combinedText).toMatch(/GIVEN_ALL\/SURNAME/);
    expect(combinedText).toMatch(/searchByName\("Robert", "Taubman"\)/);
  });

  it("documents fhBridge.getFactsByTag's 1st-level-only tag filtering, that it accepts a single tag or an array, and that it works on any record type (issue #62)", () => {
    expect(combinedText).toMatch(/fhBridge\.getFactsByTag\(ptr, tags\)/);
    expect(combinedText).toMatch(/DIRECT children/);
    expect(combinedText).toMatch(/\{"BIRT", "DEAT"\}/);
    expect(combinedText.toLowerCase()).toMatch(/not just (an )?individual/);
  });

  it("documents dnaLine=\"blood\" (DnaBloodRelation), shared by getAncestors and getDescendants, and that half-blood was considered and excluded (issue #78)", () => {
    expect(combinedText).toMatch(/DnaBloodRelation/);
    expect(combinedText.toLowerCase()).toMatch(/dnaline="blood"/);
    expect(combinedText.toLowerCase()).toMatch(/does not support|deliberately does not/);
    expect(combinedText).toMatch(/DnaHalfBlood/);
  });
});

describe("SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION topic list (issue #49)", () => {
  it("lists Data Reference qualifier codes as a searchable topic, so an agent has a cue to look here before grepping fh-help sample scripts", () => {
    const lower = SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/qualifier code/);
    expect(lower).toMatch(/name qualifiers/);
  });
});

describe("SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION byte budget (issue #101 follow-up)", () => {
  // Same failure class ADR 0011 found for RUN_LUA_DESCRIPTION: MCP clients that load tool
  // descriptions via deferred/lazy schema-loading truncate around ~2048 bytes. This
  // description had grown past that point (3001 bytes) with no safe-zoning of its own --
  // re-zoned here while adding the grep_gedcom_knowledge fallback mention (issue #101),
  // rather than growing it further.
  it("stays under the observed ~2048-byte truncation point", () => {
    expect(Buffer.byteLength(SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION, "utf8")).toBeLessThan(2000);
  });

  it("tells Claude to use grep_gedcom_knowledge when natural-language ranking buries a match", () => {
    expect(SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION).toMatch(/grep_gedcom_knowledge/);
  });

  it("still tells Claude to call search_gedcom_knowledge('run_lua guidance') once near the start of a run_lua conversation", () => {
    expect(SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION).toContain('"run_lua guidance"');
  });
});

describe("GREP_GEDCOM_KNOWLEDGE_DESCRIPTION byte budget and fhBridge.* discoverability (issue #102)", () => {
  // Same ~2048-byte deferred-tool-loading truncation risk docs/adr/0011 found for
  // RUN_LUA_DESCRIPTION -- this description had headroom to spare (unlike
  // RUN_LUA_DESCRIPTION/SEARCH_GEDCOM_KNOWLEDGE_DESCRIPTION above, both already near
  // their own tested ceilings), so the new fhBridge.* discoverability pointer landed
  // here instead.
  it("stays under the observed ~2048-byte truncation point", () => {
    expect(Buffer.byteLength(GREP_GEDCOM_KNOWLEDGE_DESCRIPTION, "utf8")).toBeLessThan(2000);
  });

  it('tells Claude to grep the "fhBridge API reference" breadcrumb to list every fhBridge.* function in one call', () => {
    expect(GREP_GEDCOM_KNOWLEDGE_DESCRIPTION).toContain('"fhBridge API reference"');
  });
});

describe("file separation from check_fh_help_updates (acceptance criterion)", () => {
  it("leaves the gedcom knowledge corpus untouched when the fh-help corpus is synced/updated", async () => {
    const CORPUS_PATH = fileURLToPath(new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url));
    const before = loadGedcomKnowledgeFromFile(CORPUS_PATH);

    // Simulate check_fh_help_updates downloading a brand-new fh-help corpus — this only
    // ever reads/writes fhHelpUpdateDeps' own corpus/meta paths, which are wired (see
    // index.ts) to fh-help-corpus.jsonl, an entirely different file/store than the one
    // gedcom-knowledge-corpus.jsonl is loaded into.
    let fhHelpCorpusFileWritten = "";
    await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: parseFhHelpCorpus("") },
      {
        fetchCorpus: async () => ({
          status: 200,
          body: JSON.stringify({ url: "/x", section: "fh8", title: "X", breadcrumb: [], text: "new content" }),
        }),
        readMeta: async () => undefined,
        writeMeta: async () => {},
        writeCorpusFile: async (content) => {
          fhHelpCorpusFileWritten = content;
        },
      },
    );

    expect(fhHelpCorpusFileWritten.length).toBeGreaterThan(0);
    const after = loadGedcomKnowledgeFromFile(CORPUS_PATH);
    expect(after).toEqual(before);
  });
});

describe("registerGedcomKnowledgeTools", () => {
  // Registers the tools on a real McpServer and calls them over a real (in-memory) MCP
  // client connection -- the only way to exercise the registered handler closures
  // themselves (searchResult/grepResult mapping, error handling), as opposed to the pure
  // functions (searchGedcomKnowledge, grepGedcomKnowledge) every test above calls
  // directly. Mirrors fhHelp.test.ts's registerFhHelpTools pattern.
  async function connectedClient(store: GedcomKnowledgeStore) {
    const server = new McpServer({ name: "fh-mcp-bridge", version: "0.0.0-test" });
    registerGedcomKnowledgeTools(server, store);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "gedcomKnowledge-test", version: "0.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    return { client, server };
  }

  describe("search_gedcom_knowledge tool", () => {
    it("returns matches as JSON, untruncated, when everything fits under the cap", async () => {
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "search_gedcom_knowledge",
          arguments: { query: "table" },
        });
        expect(result.isError).toBeFalsy();
        const body = JSON.parse((result.content as Array<{ text: string }>)[0].text);
        expect(body.matches.map((m: { id: string }) => m.id)).toContain("ftf-tables");
        expect(body.truncated).toBe(false);
        expect(body.note).toBeUndefined();
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("returns a no-match message (not an error) when the query matches nothing", async () => {
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "search_gedcom_knowledge",
          arguments: { query: "xyzzy nonsense query" },
        });
        expect(result.isError).toBeFalsy();
        const text = (result.content as Array<{ text: string }>)[0].text;
        expect(text).toContain('No match for "xyzzy nonsense query"');
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("adds an index and truncation note when the byte cap is exceeded (issue #135)", async () => {
      const bigText = "x".repeat(1000);
      const manyEntries = Array.from({ length: 30 }, (_, i) =>
        JSON.stringify({
          id: `topic-${i}`,
          title: `Topic ${i}`,
          breadcrumb: ["Topics"],
          confidence: "Documented",
          source: "test",
          text: `Contains the word needle. ${bigText}`,
        }),
      ).join("\n");
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(manyEntries) });
      try {
        const result = await client.callTool({
          name: "search_gedcom_knowledge",
          arguments: { query: "needle" },
        });
        expect(result.isError).toBeFalsy();
        const body = JSON.parse((result.content as Array<{ text: string }>)[0].text);
        expect(body.truncated).toBe(true);
        expect(body.matches.length).toBeGreaterThan(0);
        expect(body.matches.length).toBeLessThan(30);
        expect(Array.isArray(body.index)).toBe(true);
        expect(body.index.length).toBeGreaterThanOrEqual(body.matches.length);
        expect(body.note).toContain("index");
      } finally {
        await client.close();
        await server.close();
      }
    });
  });

  describe("grep_gedcom_knowledge tool", () => {
    it("returns matches as JSON, untruncated, when everything fits under the limit", async () => {
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "grep_gedcom_knowledge",
          arguments: { pattern: "Rejected always overrides Preferred" },
        });
        expect(result.isError).toBeFalsy();
        const body = JSON.parse((result.content as Array<{ text: string }>)[0].text);
        expect(body.matches).toHaveLength(1);
        expect(body.matches[0].id).toBe("fact-flag-vs-record-flag");
        expect(body.truncated).toBe(false);
        expect(body.note).toBeUndefined();
      } finally {
        await client.close();
        await server.close();
      }
    });

    it("returns a no-match message (not an error) when the pattern matches nothing", async () => {
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "grep_gedcom_knowledge",
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
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        // "text" appears in every fixture entry's field name once serialized, but "Doubled"
        // only appears in private-text and "table" only in ftf-tables -- use breadcrumb
        // "FTF rich text" instead, shared by exactly two of the three fixture entries.
        const result = await client.callTool({
          name: "grep_gedcom_knowledge",
          arguments: { pattern: "FTF rich text", limit: 1 },
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
      const { client, server } = await connectedClient({ entries: parseGedcomKnowledgeCorpus(FIXTURE_JSONL) });
      try {
        const result = await client.callTool({
          name: "grep_gedcom_knowledge",
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
});
