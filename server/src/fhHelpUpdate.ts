import fs from "node:fs/promises";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { parseCorpus } from "./fhHelp.js";
import type { FhHelpCorpusStore, FhHelpTopic } from "./fhHelp.js";

export interface FhHelpCorpusMeta {
  etag?: string;
  lastModified?: string;
  lastCheckedAt: string;
}

interface FetchCorpusResponse {
  status: number;
  body?: string;
  etag?: string;
  lastModified?: string;
}

export interface FhHelpUpdateDeps {
  fetchCorpus: (url: string, conditionalHeaders: Record<string, string>) => Promise<FetchCorpusResponse>;
  readMeta: () => Promise<FhHelpCorpusMeta | undefined>;
  writeMeta: (meta: FhHelpCorpusMeta) => Promise<void>;
  writeCorpusFile: (content: string) => Promise<void>;
}

export type FhHelpUpdateResult =
  | { status: "unchanged"; checkedAt: string }
  | {
      status: "updated";
      previousTopicCount: number;
      newTopicCount: number;
      checkedAt: string;
      newCorpus: FhHelpTopic[];
    }
  | { status: "error"; message: string };

export function makeDefaultFhHelpUpdateDeps(corpusFilePath: string, metaFilePath: string): FhHelpUpdateDeps {
  return {
    fetchCorpus: async (url, headers) => {
      const response = await fetch(url, { headers });
      return {
        status: response.status,
        body: response.status === 200 ? await response.text() : undefined,
        etag: response.headers.get("etag") ?? undefined,
        lastModified: response.headers.get("last-modified") ?? undefined,
      };
    },
    readMeta: async () => {
      try {
        return JSON.parse(await fs.readFile(metaFilePath, "utf8")) as FhHelpCorpusMeta;
      } catch {
        return undefined;
      }
    },
    writeMeta: async (meta) => {
      await fs.writeFile(metaFilePath, JSON.stringify(meta, null, 2));
    },
    writeCorpusFile: async (content) => {
      await fs.writeFile(corpusFilePath, content);
    },
  };
}

export async function checkFhHelpUpdates(
  params: { sourceUrl: string; currentCorpus: FhHelpTopic[] },
  deps: FhHelpUpdateDeps,
): Promise<FhHelpUpdateResult> {
  const checkedAt = new Date().toISOString();
  const meta = await deps.readMeta();

  const headers: Record<string, string> = {};
  if (meta?.etag) headers["If-None-Match"] = meta.etag;
  if (meta?.lastModified) headers["If-Modified-Since"] = meta.lastModified;

  let response: FetchCorpusResponse;
  try {
    response = await deps.fetchCorpus(params.sourceUrl, headers);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { status: "error", message: `Could not reach ${params.sourceUrl}: ${message}` };
  }

  if (response.status === 304) {
    await deps.writeMeta({ ...meta, lastCheckedAt: checkedAt });
    return { status: "unchanged", checkedAt };
  }

  if (response.status !== 200 || response.body === undefined) {
    return {
      status: "error",
      message: `Unexpected response fetching ${params.sourceUrl}: HTTP ${response.status}`,
    };
  }

  let newCorpus: FhHelpTopic[];
  try {
    newCorpus = parseCorpus(response.body);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { status: "error", message: `Malformed corpus from ${params.sourceUrl}: ${message}` };
  }

  try {
    await deps.writeCorpusFile(response.body);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { status: "error", message: `Could not write corpus file: ${message}` };
  }

  await deps.writeMeta({
    etag: response.etag,
    lastModified: response.lastModified,
    lastCheckedAt: checkedAt,
  });

  return {
    status: "updated",
    previousTopicCount: params.currentCorpus.length,
    newTopicCount: newCorpus.length,
    checkedAt,
    newCorpus,
  };
}

// Steers Claude's own behavior when it uses this tool — this is the one capability in
// this server that reaches the network, so Claude must not call it silently.
export const CHECK_FH_HELP_UPDATES_DESCRIPTION = `Check family-historian.co.uk for a newer version of the bundled Family Historian 8 help corpus, and download it if one exists.

This makes an outbound network request to family-historian.co.uk — the only network access this server ever performs. Tell the user what you're about to do and why before calling this tool; do not call it as a silent side effect of answering an unrelated question. Only call it when the user has asked to check for or fetch help-content updates.`;

export function registerCheckFhHelpUpdatesTool(
  server: McpServer,
  store: FhHelpCorpusStore,
  sourceUrl: string,
  deps: FhHelpUpdateDeps,
): void {
  server.registerTool(
    "check_fh_help_updates",
    { description: CHECK_FH_HELP_UPDATES_DESCRIPTION, inputSchema: {} },
    async (): Promise<CallToolResult> => {
      const result = await checkFhHelpUpdates({ sourceUrl, currentCorpus: store.topics }, deps);

      if (result.status === "updated") {
        store.topics = result.newCorpus;
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                status: result.status,
                previousTopicCount: result.previousTopicCount,
                newTopicCount: result.newTopicCount,
                checkedAt: result.checkedAt,
              }),
            },
          ],
        };
      }

      return { content: [{ type: "text", text: JSON.stringify(result) }] };
    },
  );
}
