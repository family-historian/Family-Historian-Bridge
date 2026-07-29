// Manual end-to-end check: spawns the built MCP server and calls run_lua through a real
// MCP client, exactly like Claude Desktop would — against a real FH Bridge Session
// (Start it first). Run with: node scripts/smoke-test.mjs
//
// There's no automated seam for this (it needs a live FH instance) — same "manual only"
// boundary as bridge/README.md's tests. This just saves re-typing the client setup by
// hand each time a ticket needs re-verifying end-to-end.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const client = new Client({ name: "smoke-test", version: "0.0.0" });
const transport = new StdioClientTransport({
  command: "node",
  args: ["dist/index.js"],
});

await client.connect(transport);

const tools = await client.listTools();
console.log(
  "Tools registered:",
  tools.tools.map((t) => t.name),
);

const resources = await client.listResources();
console.log(`FH help resources listed: ${resources.resources.length}`);
console.log("First resource:", resources.resources[0]);

const searchResult = await client.callTool({
  name: "search_fh_help",
  arguments: { query: "merge" },
});
console.log("search_fh_help result:", searchResult.content[0].text);

const [firstMatch] = JSON.parse(searchResult.content[0].text);
if (firstMatch) {
  const page = await client.readResource({ uri: firstMatch.uri });
  console.log(
    `Read resource ${firstMatch.uri}: ${page.contents[0].text.length} chars`,
  );
}

const result = await client.callTool({
  name: "run_lua",
  arguments: { script: "return {ok=true, echoed=42}" },
});

console.log("run_lua result:", JSON.stringify(result, null, 2));

await client.close();
