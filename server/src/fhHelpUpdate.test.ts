import { describe, expect, it } from "vitest";
import { checkFhHelpUpdates } from "./fhHelpUpdate.js";
import { parseCorpus } from "./fhHelp.js";
import type { FhHelpCorpusMeta, FhHelpUpdateDeps } from "./fhHelpUpdate.js";

const ONE_TOPIC_JSONL = JSON.stringify({
  url: "/help/fh8/mapwindow.html",
  section: "fh8",
  title: "The Map Window",
  breadcrumb: ["Getting Started", "The Map Window"],
  text: "The Map Window shows places on a map.",
});

const TWO_TOPIC_JSONL = `${ONE_TOPIC_JSONL}\n${JSON.stringify({
  url: "/help/fh8/mergingpeople.html",
  section: "fh8",
  title: "Merging Duplicate People",
  breadcrumb: ["How to...", "Merging Duplicate People"],
  text: "To merge two people, select both records.",
})}`;

function fakeDeps(overrides: Partial<FhHelpUpdateDeps> = {}): FhHelpUpdateDeps {
  return {
    fetchCorpus: async () => ({ status: 304 }),
    readMeta: async () => undefined,
    writeMeta: async () => {},
    writeCorpusFile: async () => {},
    ...overrides,
  };
}

describe("checkFhHelpUpdates", () => {
  it("reports 'unchanged' and does not write a corpus file on a 304", async () => {
    let corpusWritten = false;
    const deps = fakeDeps({
      fetchCorpus: async () => ({ status: 304 }),
      writeCorpusFile: async () => {
        corpusWritten = true;
      },
    });

    const result = await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: parseCorpus(ONE_TOPIC_JSONL) },
      deps,
    );

    expect(result.status).toBe("unchanged");
    expect(corpusWritten).toBe(false);
  });

  it("sends the stored ETag/Last-Modified as conditional request headers", async () => {
    let receivedHeaders: Record<string, string> | undefined;
    const deps = fakeDeps({
      readMeta: async () => ({
        etag: '"abc123"',
        lastModified: "Wed, 01 Jul 2026 00:00:00 GMT",
        lastCheckedAt: "2026-07-01T00:00:00.000Z",
      }),
      fetchCorpus: async (_url, headers) => {
        receivedHeaders = headers;
        return { status: 304 };
      },
    });

    await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: [] },
      deps,
    );

    expect(receivedHeaders).toEqual({
      "If-None-Match": '"abc123"',
      "If-Modified-Since": "Wed, 01 Jul 2026 00:00:00 GMT",
    });
  });

  it("downloads, writes the file, and reports 'updated' with old/new topic counts on a 200", async () => {
    let writtenBody: string | undefined;
    let writtenMeta: FhHelpCorpusMeta | undefined;
    const deps = fakeDeps({
      fetchCorpus: async () => ({
        status: 200,
        body: TWO_TOPIC_JSONL,
        etag: '"new-etag"',
        lastModified: "Wed, 29 Jul 2026 00:00:00 GMT",
      }),
      writeCorpusFile: async (content) => {
        writtenBody = content;
      },
      writeMeta: async (meta) => {
        writtenMeta = meta;
      },
    });

    const result = await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: parseCorpus(ONE_TOPIC_JSONL) },
      deps,
    );

    expect(result.status).toBe("updated");
    if (result.status !== "updated") throw new Error("unreachable");
    expect(result.previousTopicCount).toBe(1);
    expect(result.newTopicCount).toBe(2);
    expect(result.newCorpus).toHaveLength(2);
    expect(writtenBody).toBe(TWO_TOPIC_JSONL);
    expect(writtenMeta).toEqual({
      etag: '"new-etag"',
      lastModified: "Wed, 29 Jul 2026 00:00:00 GMT",
      lastCheckedAt: expect.any(String),
    });
  });

  it("reports 'error' without writing anything when the fetch throws (network failure)", async () => {
    let anythingWritten = false;
    const deps = fakeDeps({
      fetchCorpus: async () => {
        throw new Error("ENOTFOUND example.com");
      },
      writeCorpusFile: async () => {
        anythingWritten = true;
      },
      writeMeta: async () => {
        anythingWritten = true;
      },
    });

    const result = await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: [] },
      deps,
    );

    expect(result.status).toBe("error");
    if (result.status !== "error") throw new Error("unreachable");
    expect(result.message).toContain("ENOTFOUND");
    expect(anythingWritten).toBe(false);
  });

  it("reports 'error' on an unexpected HTTP status without writing anything", async () => {
    let anythingWritten = false;
    const deps = fakeDeps({
      fetchCorpus: async () => ({ status: 500 }),
      writeCorpusFile: async () => {
        anythingWritten = true;
      },
    });

    const result = await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: [] },
      deps,
    );

    expect(result.status).toBe("error");
    if (result.status !== "error") throw new Error("unreachable");
    expect(result.message).toContain("500");
    expect(anythingWritten).toBe(false);
  });
});
