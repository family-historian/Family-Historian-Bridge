// Unit tests for the pure manifest-building logic behind installer/build-dxt.mjs (issue
// #59). No file I/O, no npx/mcpb CLI invocation here -- see installer/verify-dxt.mjs for
// the end-to-end check that a packed .mcpb actually runs. Run with:
//   node --test installer/dxt/manifest.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildManifest, readToolCatalog } from "./manifest.mjs";

// Every top-level key the MCPB v0.4 manifest schema
// (schemas/mcpb-manifest-v0.4.schema.json in modelcontextprotocol/mcpb) actually declares --
// kept here as a cheap regression guard so a typo'd field name fails fast, locally, instead
// of only surfacing later via `mcpb validate`.
const SCHEMA_V0_4_TOP_LEVEL_KEYS = new Set([
  "$schema",
  "dxt_version",
  "manifest_version",
  "name",
  "display_name",
  "version",
  "description",
  "long_description",
  "author",
  "repository",
  "homepage",
  "documentation",
  "support",
  "icon",
  "icons",
  "screenshots",
  "localization",
  "server",
  "tools",
  "tools_generated",
  "prompts",
  "prompts_generated",
  "keywords",
  "license",
  "privacy_policies",
  "compatibility",
  "user_config",
  "_meta",
]);

test("buildManifest requires a version", () => {
  assert.throws(() => buildManifest({}), /version/i);
  assert.throws(() => buildManifest({ version: "" }), /version/i);
});

test("buildManifest only uses top-level keys the v0.4 schema declares", () => {
  const manifest = buildManifest({ version: "0.6.0" });
  for (const key of Object.keys(manifest)) {
    assert.ok(
      SCHEMA_V0_4_TOP_LEVEL_KEYS.has(key),
      `"${key}" is not a top-level key in the MCPB v0.4 manifest schema`,
    );
  }
});

test("buildManifest sets the required fields the v0.4 schema demands", () => {
  const manifest = buildManifest({ version: "0.6.0" });
  assert.equal(manifest.manifest_version, "0.4");
  assert.equal(manifest.name, "fh-mcp-bridge");
  assert.equal(manifest.version, "0.6.0");
  assert.equal(typeof manifest.description, "string");
  assert.ok(manifest.description.length > 0);
  assert.equal(manifest.author.name, "Jane");
  assert.ok(manifest.server);
});

test("buildManifest threads the given version through unchanged", () => {
  assert.equal(buildManifest({ version: "1.2.3" }).version, "1.2.3");
  assert.equal(buildManifest({ version: "0.0.1-alpha" }).version, "0.0.1-alpha");
});

test("buildManifest's server section runs the bundled server with Claude Desktop's own Node", () => {
  const { server } = buildManifest({ version: "0.6.0" });
  assert.equal(server.type, "node");
  // Relative to the bundle root -- this is where build-dxt.mjs stages server/dist/index.js.
  assert.equal(server.entry_point, "server/dist/index.js");
  assert.equal(server.mcp_config.command, "node");
  assert.deepEqual(server.mcp_config.args, ["${__dirname}/server/dist/index.js"]);
  // No user_config today (server/src/index.ts takes no env/args), so mcp_config shouldn't
  // reference one.
  assert.equal(server.mcp_config.env, undefined);
});

test("buildManifest declares only the platforms this project actually ships a release for", () => {
  const { compatibility } = buildManifest({ version: "0.6.0" });
  // docs/release.md only documents release-mac.sh and release-windows.ps1 -- no native
  // Linux release path exists, so don't claim one here.
  assert.deepEqual(compatibility.platforms, ["darwin", "win32"]);
});

// What this can and can't prove: it pins the manifest to server/src/toolNames.json, the
// single source of truth (issue #85). Proving that JSON matches what the server *actually*
// registers is server/src/toolNames.test.ts's job -- it stands up a real McpServer and reads
// back its tools/list. The two together give the guarantee this test's previous name claimed
// on its own while comparing the manifest to a literal array declared right here.
test("buildManifest declares exactly the tools in server/src/toolNames.json, in order", () => {
  const { tools } = buildManifest({ version: "0.6.0" });
  assert.deepEqual(
    tools.map((t) => t.name),
    readToolCatalog().map((t) => t.name),
  );
});

test("buildManifest gives every declared tool a non-empty description", () => {
  const { tools } = buildManifest({ version: "0.6.0" });
  assert.ok(tools.length > 0);
  for (const tool of tools) {
    assert.equal(typeof tool.description, "string", `${tool.name} description must be a string`);
    assert.ok(tool.description.length > 0, `${tool.name} needs a non-empty description`);
  }
});

test("buildManifest has no user_config (the server takes no configuration today)", () => {
  const manifest = buildManifest({ version: "0.6.0" });
  assert.equal(manifest.user_config, undefined);
});
