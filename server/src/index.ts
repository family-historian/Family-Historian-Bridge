import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerRunLuaTool } from "./runLuaTool.js";
import { registerDescribeProjectTool } from "./describeProjectTool.js";
import { registerAuthorFhPluginTool } from "./authorFhPluginTool.js";
import { registerInstallFhPluginTool } from "./installFhPluginTool.js";
import { loadCorpusFromFile, registerFhHelpTools } from "./fhHelp.js";
import type { FhHelpCorpusStore } from "./fhHelp.js";
import { makeDefaultFhHelpUpdateDeps, registerCheckFhHelpUpdatesTool } from "./fhHelpUpdate.js";
import { loadGedcomKnowledgeFromFile, registerGedcomKnowledgeTools } from "./gedcomKnowledge.js";
import type { GedcomKnowledgeStore } from "./gedcomKnowledge.js";
import { SERVER_VERSION } from "./serverVersion.js";

// The corpus.jsonl produced by the sibling fh-help/fh8-help-site project. Bundled here,
// kept up to date via the check_fh_help_updates tool (see fhHelpUpdate.ts) rather than
// fetched at build time.
const FH_HELP_CORPUS_PATH = fileURLToPath(new URL("../data/fh-help-corpus.jsonl", import.meta.url));
const FH_HELP_CORPUS_META_PATH = fileURLToPath(
  new URL("../data/fh-help-corpus.meta.json", import.meta.url),
);
const FH_HELP_CORPUS_SOURCE_URL = "https://family-historian.co.uk/help/fh8/corpus.jsonl";

// Own file, deliberately separate from fh-help-corpus.jsonl so check_fh_help_updates'
// wholesale overwrite of that file can never touch this one — see issue #11 and
// docs/adr/0003-gedcom-corpus-scope-live-api-only.md. Not synced from anywhere; there is
// no update-check tool for this corpus.
const GEDCOM_KNOWLEDGE_CORPUS_PATH = fileURLToPath(
  new URL("../data/gedcom-knowledge-corpus.jsonl", import.meta.url),
);

const server = new McpServer({
  name: "fh-mcp-bridge",
  version: SERVER_VERSION,
});

registerRunLuaTool(server);
registerDescribeProjectTool(server);
registerAuthorFhPluginTool(server);
registerInstallFhPluginTool(server);

const fhHelpStore: FhHelpCorpusStore = { topics: loadCorpusFromFile(FH_HELP_CORPUS_PATH) };
registerFhHelpTools(server, fhHelpStore);
registerCheckFhHelpUpdatesTool(
  server,
  fhHelpStore,
  FH_HELP_CORPUS_SOURCE_URL,
  makeDefaultFhHelpUpdateDeps(FH_HELP_CORPUS_PATH, FH_HELP_CORPUS_META_PATH),
);

const gedcomKnowledgeStore: GedcomKnowledgeStore = {
  entries: loadGedcomKnowledgeFromFile(GEDCOM_KNOWLEDGE_CORPUS_PATH),
};
registerGedcomKnowledgeTools(server, gedcomKnowledgeStore);

const transport = new StdioServerTransport();
await server.connect(transport);
