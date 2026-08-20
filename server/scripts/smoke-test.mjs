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

// fh-help's ResourceTemplate is registered with {list: undefined} on purpose (avoids an
// unpaginated resources/list response over ~1000 topics), so listResources() is expected
// to come back empty here — this asserts that deliberate behavior, not a real listing.
const resources = await client.listResources();
if (resources.resources.length !== 0) {
  throw new Error(
    `Expected listResources() to be empty (fh-help opts out via {list: undefined}), got ${resources.resources.length}`,
  );
}
console.log("FH help resources list is empty, as expected.");

const searchResult = await client.callTool({
  name: "search_fh_help",
  arguments: { query: "merge" },
});
console.log("search_fh_help result:", searchResult.content[0].text);

// search_fh_help returns a plain-English "No match for ..." string (not JSON) when nothing
// matches — checked for explicitly, not via a catch-all JSON.parse try/catch, so a real
// malformed-response regression still fails this script instead of reading as "no match".
const searchText = searchResult.content[0].text;
let firstMatch;
if (searchText.startsWith("No match for")) {
  firstMatch = undefined;
} else {
  [firstMatch] = JSON.parse(searchText);
}
if (firstMatch) {
  const page = await client.readResource({ uri: firstMatch.uri });
  console.log(
    `Read resource ${firstMatch.uri}: ${page.contents[0].text.length} chars`,
  );
} else {
  console.log('No match for "merge" — skipping resource read.');
}

const result = await client.callTool({
  name: "run_lua",
  arguments: { script: "return {ok=true, echoed=42}" },
});

console.log("run_lua result:", JSON.stringify(result, null, 2));

await client.close();
