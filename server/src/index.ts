import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerRunLuaTool } from "./runLuaTool.js";
import { loadCorpusFromFile, registerFhHelpTools } from "./fhHelp.js";
import type { FhHelpCorpusStore } from "./fhHelp.js";
import { makeDefaultFhHelpUpdateDeps, registerCheckFhHelpUpdatesTool } from "./fhHelpUpdate.js";

// The corpus.jsonl produced by the sibling fh-help/fh8-help-site project. Bundled here,
// kept up to date via the check_fh_help_updates tool (see fhHelpUpdate.ts) rather than
// fetched at build time.
const FH_HELP_CORPUS_PATH = fileURLToPath(new URL("../data/fh-help-corpus.jsonl", import.meta.url));
const FH_HELP_CORPUS_META_PATH = fileURLToPath(
  new URL("../data/fh-help-corpus.meta.json", import.meta.url),
);
const FH_HELP_CORPUS_SOURCE_URL = "https://family-historian.co.uk/help/fh8/corpus.jsonl";

const server = new McpServer({
  name: "fh-mcp-bridge",
  version: "0.1.0",
});

registerRunLuaTool(server);

const fhHelpStore: FhHelpCorpusStore = { topics: loadCorpusFromFile(FH_HELP_CORPUS_PATH) };
registerFhHelpTools(server, fhHelpStore);
registerCheckFhHelpUpdatesTool(
  server,
  fhHelpStore,
  FH_HELP_CORPUS_SOURCE_URL,
  makeDefaultFhHelpUpdateDeps(FH_HELP_CORPUS_PATH, FH_HELP_CORPUS_META_PATH),
);

const transport = new StdioServerTransport();
await server.connect(transport);
