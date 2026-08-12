// Builds the manifest.json object for fh-mcp-bridge's .mcpb (MCPB/DXT) bundle -- issue #59,
// part of the wayfinder map at issue #56. Pure and file-I/O-free by design (installer/build-
// dxt.mjs does the staging/writing) so its shape can be unit-tested directly; see
// manifest.test.mjs.
//
// The version is deliberately the one field this module takes as a parameter rather than
// hardcoding, generated at build time from server/package.json -- the same "don't add a
// fourth hand-synced copy" lesson server/src/serverVersion.ts and installer/stage.ps1's
// version.iss generation already apply to this project's other version copies (see
// docs/release.md step 4 and its "Risks" section). See docs/adr/0015-mcpb-bundle-manifest-
// is-generated-not-hand-copied.md for the full decision.
//
// manifest_version "0.4" targets the current MCPB manifest schema
// (schemas/mcpb-manifest-v0.4.schema.json in modelcontextprotocol/mcpb) -- validated against
// the real schema by `mcpb validate` in build-dxt.mjs, not just this module's own tests.
//
// The `tools` array is likewise generated, from server/src/toolNames.json, rather than
// hand-listed here -- issue #85, which found the test that claimed to guard this list was
// only comparing it to a literal copy in the test file itself. server/src/toolNames.test.ts
// pins that JSON to what the server really registers, so this file now follows the server
// by construction. Read from src/ rather than dist/ deliberately: dist/ is gitignored, so
// depending on it would break `npm run test:installer` on a fresh clone.

import { readFileSync } from "node:fs";

const TOOL_CATALOG_PATH = new URL("../../server/src/toolNames.json", import.meta.url);

/** @returns {{ name: string, bundleDescription: string }[]} */
export function readToolCatalog() {
  const { tools } = JSON.parse(readFileSync(TOOL_CATALOG_PATH, "utf-8"));
  if (!Array.isArray(tools) || tools.length === 0) {
    throw new Error(`${TOOL_CATALOG_PATH.pathname} has no "tools" array`);
  }
  return tools;
}

/**
 * @param {{ version: string }} opts
 * @returns {object} the manifest.json object, ready to JSON.stringify to the bundle root.
 */
export function buildManifest({ version }) {
  if (!version) {
    throw new Error("buildManifest requires a non-empty version (from server/package.json)");
  }

  return {
    manifest_version: "0.4",
    name: "fh-mcp-bridge",
    display_name: "Family Historian Bridge",
    version,
    description:
      "Lets Claude query and edit your open Family Historian project via a companion FH plugin.",
    author: { name: "Jane Taubman" },
    server: {
      type: "node",
      // Relative to the bundle root -- build-dxt.mjs stages the built server here.
      entry_point: "server/dist/index.js",
      mcp_config: {
        command: "node",
        args: ["${__dirname}/server/dist/index.js"],
      },
    },
    // No user_config: server/src/index.ts takes no env vars or CLI args today -- every
    // request goes through the single run_lua tool instead of build-time configuration.
    tools: readToolCatalog().map(({ name, bundleDescription }) => ({
      name,
      description: bundleDescription,
    })),
    keywords: ["genealogy", "family-historian", "gedcom"],
    license: "ISC",
    compatibility: {
      // docs/release.md only documents release-mac.sh and release-windows.ps1 -- no native
      // Linux release path exists yet, so don't claim support for it here.
      platforms: ["darwin", "win32"],
      runtimes: { node: ">=18.0.0" },
    },
  };
}
