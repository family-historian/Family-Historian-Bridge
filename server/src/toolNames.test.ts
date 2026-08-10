// The test that makes the tool list honest -- issue #85.
//
// installer/dxt/manifest.test.mjs used to carry a test named "buildManifest lists every tool
// server/src/index.ts currently registers, and no others" which did nothing of the kind: it
// compared the manifest against a literal array declared in that same test file, so a ninth
// tool could be added to the server and every suite would still pass while the shipped .mcpb
// silently under-declared it.
//
// Here we stand up a real McpServer, register every tool exactly the way index.ts does, and
// ask it over a real MCP client connection what it serves. That answer -- not a hand-kept
// list -- is what gets compared to toolNames.json. index.ts itself can't be imported (it
// connects a stdio transport at module scope), so the registration block below is the one
// thing that must be kept in step with it; a tool registered there but not here would show
// up as a name missing from this server's tools/list, which is exactly what this asserts.
import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerRunLuaTool } from "./runLuaTool.js";
import { registerDescribeProjectTool } from "./describeProjectTool.js";
import { registerAuthorFhPluginTool } from "./authorFhPluginTool.js";
import { registerInstallFhPluginTool } from "./installFhPluginTool.js";
import { registerFhHelpTools } from "./fhHelp.js";
import { registerCheckFhHelpUpdatesTool } from "./fhHelpUpdate.js";
import type { FhHelpUpdateDeps } from "./fhHelpUpdate.js";
import { registerGedcomKnowledgeTools } from "./gedcomKnowledge.js";
import { ALL_TOOL_NAMES, TOOL_CATALOG } from "./toolNames.js";

// Registration is all this test exercises, so the corpora are empty and the update deps
// never fire -- no file I/O, no network, and no live Bridge needed.
const noopUpdateDeps: FhHelpUpdateDeps = {
  fetchCorpus: async () => ({ status: 304 }),
  readMeta: async () => undefined,
  writeMeta: async () => {},
  writeCorpusFile: async () => {},
};

async function registeredToolNames(): Promise<string[]> {
  const server = new McpServer({ name: "fh-mcp-bridge", version: "0.0.0-test" });

  registerRunLuaTool(server);
  registerDescribeProjectTool(server);
  registerAuthorFhPluginTool(server);
  registerInstallFhPluginTool(server);

  const fhHelpStore = { topics: [] };
  registerFhHelpTools(server, fhHelpStore);
  registerCheckFhHelpUpdatesTool(server, fhHelpStore, "https://example.invalid/corpus.jsonl", noopUpdateDeps);

  registerGedcomKnowledgeTools(server, { entries: [] });

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "toolNames-test", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  try {
    const { tools } = await client.listTools();
    return tools.map((tool) => tool.name);
  } finally {
    await client.close();
    await server.close();
  }
}

describe("tool catalogue", () => {
  it("serves exactly the tools toolNames.json declares, and no others", async () => {
    const served = await registeredToolNames();
    expect([...served].sort()).toEqual([...ALL_TOOL_NAMES].sort());
  });

  it("declares the tools in the order the catalogue lists them", async () => {
    // Order isn't semantically meaningful to MCP, but the .mcpb manifest is generated from
    // this same list, so pinning it keeps generated manifests diff-stable between releases.
    const served = await registeredToolNames();
    expect(served).toEqual([...ALL_TOOL_NAMES]);
  });

  it("gives every tool a non-empty bundle description for the .mcpb manifest", () => {
    for (const entry of TOOL_CATALOG) {
      expect(entry.name, "tool name must be non-empty").toBeTruthy();
      expect(entry.bundleDescription.length, `${entry.name} needs a bundleDescription`).toBeGreaterThan(0);
    }
  });

  it("has no duplicate tool names", () => {
    expect(new Set(ALL_TOOL_NAMES).size).toBe(ALL_TOOL_NAMES.length);
  });
});
