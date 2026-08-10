import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  checkFhHelpUpdates,
  makeDefaultFhHelpUpdateDeps,
  registerCheckFhHelpUpdatesTool,
} from "./fhHelpUpdate.js";
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

  it("reports 'error' using String(err) when the fetch throws something that isn't an Error", async () => {
    const deps = fakeDeps({
      fetchCorpus: async () => {
        // eslint-disable-next-line @typescript-eslint/only-throw-error -- deliberately a
        // non-Error throw, to exercise the String(err) fallback branch.
        throw "connection reset";
      },
    });

    const result = await checkFhHelpUpdates(
      { sourceUrl: "https://example.com/corpus.jsonl", currentCorpus: [] },
      deps,
    );

    expect(result.status).toBe("error");
    if (result.status !== "error") throw new Error("unreachable");
    expect(result.message).toContain("connection reset");
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

describe("makeDefaultFhHelpUpdateDeps", () => {
  let dir: string;
  let corpusFilePath: string;
  let metaFilePath: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "fh-help-update-test-"));
    corpusFilePath = join(dir, "fh-help-corpus.jsonl");
    metaFilePath = join(dir, "fh-help-corpus.meta.json");
  });

  afterEach(async () => {
    vi.unstubAllGlobals();
    await rm(dir, { recursive: true, force: true });
  });

  it("readMeta returns undefined when the meta file doesn't exist yet", async () => {
    const deps = makeDefaultFhHelpUpdateDeps(corpusFilePath, metaFilePath);
    await expect(deps.readMeta()).resolves.toBeUndefined();
  });

  it("writeMeta then readMeta round-trips the same meta object through the real filesystem", async () => {
    const deps = makeDefaultFhHelpUpdateDeps(corpusFilePath, metaFilePath);
    const meta: FhHelpCorpusMeta = {
      etag: '"abc123"',
      lastModified: "Wed, 01 Jul 2026 00:00:00 GMT",
      lastCheckedAt: "2026-07-01T00:00:00.000Z",
    };

    await deps.writeMeta(meta);

    await expect(deps.readMeta()).resolves.toEqual(meta);
  });

  it("writeCorpusFile writes the given content verbatim to the real corpus file path", async () => {
    const deps = makeDefaultFhHelpUpdateDeps(corpusFilePath, metaFilePath);

    await deps.writeCorpusFile(ONE_TOPIC_JSONL);

    await expect(readFile(corpusFilePath, "utf8")).resolves.toBe(ONE_TOPIC_JSONL);
  });

  it("fetchCorpus forwards the given headers and reports status/body/etag/lastModified on a 200", async () => {
    let receivedUrl: string | undefined;
    let receivedHeaders: Record<string, string> | undefined;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init?: { headers?: Record<string, string> }) => {
        receivedUrl = url;
        receivedHeaders = init?.headers;
        return new Response("corpus body", {
          status: 200,
          headers: { etag: '"new-etag"', "last-modified": "Wed, 29 Jul 2026 00:00:00 GMT" },
        });
      }),
    );
    const deps = makeDefaultFhHelpUpdateDeps(corpusFilePath, metaFilePath);

    const response = await deps.fetchCorpus("https://example.com/corpus.jsonl", {
      "If-None-Match": '"abc123"',
    });

    expect(receivedUrl).toBe("https://example.com/corpus.jsonl");
    expect(receivedHeaders).toEqual({ "If-None-Match": '"abc123"' });
    expect(response).toEqual({
      status: 200,
      body: "corpus body",
      etag: '"new-etag"',
      lastModified: "Wed, 29 Jul 2026 00:00:00 GMT",
    });
  });

  it("fetchCorpus omits body/etag/lastModified on a non-200 (e.g. 304)", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 304 })));
    const deps = makeDefaultFhHelpUpdateDeps(corpusFilePath, metaFilePath);

    const response = await deps.fetchCorpus("https://example.com/corpus.jsonl", {});

    expect(response).toEqual({ status: 304, body: undefined, etag: undefined, lastModified: undefined });
  });
});

describe("registerCheckFhHelpUpdatesTool", () => {
  // Registers the tool on a real McpServer and calls it over a real (in-memory) MCP client
  // connection -- the only way to exercise the handler closure registerTool is actually
  // given, as opposed to calling checkFhHelpUpdates directly the way every test above does.
  // Mirrors the pattern toolNames.test.ts uses for the same reason.
  async function connectedClient(deps: FhHelpUpdateDeps, store: { topics: ReturnType<typeof parseCorpus> }) {
    const server = new McpServer({ name: "fh-mcp-bridge", version: "0.0.0-test" });
    registerCheckFhHelpUpdatesTool(server, store, "https://example.com/corpus.jsonl", deps);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "fhHelpUpdate-test", version: "0.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    return { client, server };
  }

  it("on an update, replaces the store's topics and reports only the summary fields (not the full new corpus) in the tool result", async () => {
    const store = { topics: parseCorpus(ONE_TOPIC_JSONL) };
    const deps = fakeDeps({
      fetchCorpus: async () => ({ status: 200, body: TWO_TOPIC_JSONL }),
    });
    const { client, server } = await connectedClient(deps, store);

    try {
      const result = await client.callTool({ name: "check_fh_help_updates", arguments: {} });
      expect(result.isError).toBeFalsy();
      const parsed = JSON.parse((result.content as Array<{ text: string }>)[0].text);
      expect(parsed).toEqual({
        status: "updated",
        previousTopicCount: 1,
        newTopicCount: 2,
        checkedAt: expect.any(String),
      });
      expect(parsed.newCorpus).toBeUndefined();
      expect(store.topics).toHaveLength(2);
    } finally {
      await client.close();
      await server.close();
    }
  });

  it("on 'unchanged', leaves the store's topics alone and reports the result as-is", async () => {
    const store = { topics: parseCorpus(ONE_TOPIC_JSONL) };
    const deps = fakeDeps({ fetchCorpus: async () => ({ status: 304 }) });
    const { client, server } = await connectedClient(deps, store);

    try {
      const result = await client.callTool({ name: "check_fh_help_updates", arguments: {} });
      expect(result.isError).toBeFalsy();
      const parsed = JSON.parse((result.content as Array<{ text: string }>)[0].text);
      expect(parsed.status).toBe("unchanged");
      expect(store.topics).toHaveLength(1);
    } finally {
      await client.close();
      await server.close();
    }
  });
});
