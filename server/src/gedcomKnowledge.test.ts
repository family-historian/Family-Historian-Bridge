import { describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";
import {
  getGedcomKnowledgeEntry,
  loadGedcomKnowledgeFromFile,
  parseGedcomKnowledgeCorpus,
  searchGedcomKnowledge,
} from "./gedcomKnowledge.js";
import type { GedcomKnowledgeEntry } from "./gedcomKnowledge.js";
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
    expect(results.map((r) => r.id)).toContain("ftf-tables");
  });

  it("returns FTF markup entries for a private text query", () => {
    const results = searchGedcomKnowledge(corpus, "private text");
    expect(results.map((r) => r.id)).toContain("private-text");
  });

  it("returns the Fact Flag / Record Flag entry for a flag query", () => {
    const results = searchGedcomKnowledge(corpus, "record flag");
    expect(results.map((r) => r.id)).toContain("fact-flag-vs-record-flag");
  });

  it("includes confidence and source on each result", () => {
    const [result] = searchGedcomKnowledge(corpus, "table");
    expect(result?.confidence).toBe("Documented");
    expect(result?.source).toBe("FH help: /help/fh8plugins/api/ftf_syntax.htm");
  });

  it("includes the full entry text, not just an excerpt", () => {
    const [result] = searchGedcomKnowledge(corpus, "table");
    expect(result?.text).toContain("marks a table");
    expect(result?.text).toContain("cells are separated by |");
  });

  it("returns an empty array when nothing matches", () => {
    expect(searchGedcomKnowledge(corpus, "xyzzy nonsense query")).toEqual([]);
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
    expect(results.length).toBeGreaterThan(0);
  });

  it("returns FTF markup entries for a private text query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "private text");
    expect(results.length).toBeGreaterThan(0);
  });

  it("returns the Shared Facts entry for a shared facts query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "shared facts");
    expect(results.length).toBeGreaterThan(0);
  });

  it("returns the Fact Flag / Record Flag entry for a flags query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "fact flag record flag");
    expect(results.length).toBeGreaterThan(0);
  });

  it("returns a Source Template field entry for a source template field query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "source template field");
    expect(results.length).toBeGreaterThan(0);
  });

  it("returns the Sentence template entry for a sentence template query (acceptance criterion)", () => {
    const results = searchGedcomKnowledge(corpus, "sentence template");
    expect(results.length).toBeGreaterThan(0);
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
