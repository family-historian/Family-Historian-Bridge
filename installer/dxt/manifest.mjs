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
    display_name: "FH MCP Bridge",
    version,
    description:
      "Lets Claude query and edit your open Family Historian project via a companion FH plugin.",
    author: { name: "Jane" },
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
    tools: [
      {
        name: "run_lua",
        description: "Run a freshly-authored Lua script against the open FH project via the Bridge plugin.",
      },
      {
        name: "describe_project",
        description: "Fixed, built-in census of the open FH project (record counts, flag/tag breakdowns).",
      },
      {
        name: "author_fh_plugin",
        description: "Scaffold a standalone FH Report/Query plugin for the user to save and install.",
      },
      {
        name: "install_fh_plugin",
        description: "Write a plugin author_fh_plugin generated into FH's own Plugins folder.",
      },
      {
        name: "search_fh_help",
        description: "Search FH's own help corpus.",
      },
      {
        name: "grep_fh_help",
        description: "Full-text search over FH's own help corpus.",
      },
      {
        name: "check_fh_help_updates",
        description: "Check for and pull down updated FH help content.",
      },
      {
        name: "search_gedcom_knowledge",
        description: "Search the GEDCOM/FH domain-knowledge corpus (FTF, Shared Facts, Source Templates, ...).",
      },
    ],
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
