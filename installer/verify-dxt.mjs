#!/usr/bin/env node
// Verifies a built .mcpb bundle actually runs: extracts it exactly like Claude Desktop
// would, spawns its manifest-declared server command using the bundle's own bundled
// dependencies (not this repo's dev copy), and connects a real MCP client over stdio to
// confirm the expected tools register -- issue #59's automatable half of "verify it
// actually installs and registers the MCP server correctly".
//
// What this does NOT (and can't) check: the actual Settings -> Extensions / double-click
// install UI in a real Claude Desktop -- that's the hands-on half, left to the ticket's
// wayfinder:prototype (HITL) verification step. This script only proves the bundle's
// *contents* are correct and its server starts and speaks MCP -- the same "no live FH
// needed" boundary server/scripts/smoke-test.mjs documents for its own (FH-dependent)
// checks.
//
// Usage: node installer/verify-dxt.mjs <path-to.mcpb>
//
// Deliberately has no dependency of its own on @modelcontextprotocol/sdk: installer/ isn't
// an npm package and shouldn't need to be one just for this check. Instead it writes a tiny
// runner script into the *extracted bundle's own* server/ directory, so its bare
// `@modelcontextprotocol/sdk` import resolves via that directory's own (already-verified)
// node_modules -- which also means this actually exercises the bundled SDK copy, not the
// one in this repo's server/node_modules.

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Kept in sync by hand with the identical list in installer/dxt/manifest.mjs (its `tools`
// array) and installer/dxt/manifest.test.mjs -- a third copy of the same acknowledged drift
// risk ADR 0015 already flags for the other two. If server/src/index.ts registers a new
// tool, update all three.
const EXPECTED_TOOL_NAMES = [
  "run_lua",
  "describe_project",
  "author_fh_plugin",
  "install_fh_plugin",
  "search_fh_help",
  "grep_fh_help",
  "check_fh_help_updates",
  "search_gedcom_knowledge",
];

const RUNNER_SOURCE = `
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const [, , command, ...args] = process.argv;
const client = new Client({ name: "verify-dxt", version: "0.0.0" });
const transport = new StdioClientTransport({ command, args });

await client.connect(transport);
const { tools } = await client.listTools();
await client.close();

console.log(JSON.stringify(tools.map((t) => t.name)));
`;

const mcpbPath = process.argv[2];
if (!mcpbPath || !existsSync(mcpbPath)) {
  console.error("Usage: node installer/verify-dxt.mjs <path-to.mcpb>");
  process.exit(1);
}

const extractDir = mkdtempSync(join(tmpdir(), "fh-mcp-bridge-dxt-verify-"));

try {
  console.log(`Extracting ${mcpbPath} -> ${extractDir}`);
  // A .mcpb is just a zip file (CLI.md: "unsigned MCPB files are valid ZIP archives") --
  // extracted the way each OS's own tools would open it, not a Node zip dependency this
  // project doesn't otherwise need. On Windows, called by its full System32 path rather
  // than bare "tar": a dev shell's PATH (e.g. Git Bash) can put GNU tar first, which -- unlike
  // Windows' own System32\tar.exe (bsdtar/libarchive) -- can't read zip archives at all.
  const extract =
    process.platform === "win32"
      ? spawnSync(join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe"), [
          "-xf",
          mcpbPath,
          "-C",
          extractDir,
        ])
      : spawnSync("unzip", ["-o", "-q", mcpbPath, "-d", extractDir]);
  if (extract.status !== 0) {
    throw new Error(
      `Extraction failed (${extract.error?.message ?? `exit code ${extract.status}`}): ${extract.stderr}`,
    );
  }

  const manifest = JSON.parse(readFileSync(join(extractDir, "manifest.json"), "utf-8"));
  const { command, args } = manifest.server.mcp_config;
  // Claude Desktop substitutes ${__dirname} with the installed extension's own directory
  // before spawning -- replicate that one substitution here since nothing else does it in
  // this headless check.
  const resolvedArgs = args.map((arg) => arg.replaceAll("${__dirname}", extractDir));

  const runnerPath = join(extractDir, "server", "_verify-runner.mjs");
  writeFileSync(runnerPath, RUNNER_SOURCE);

  console.log(`Spawning: ${command} ${resolvedArgs.join(" ")}`);
  const result = spawnSync("node", [runnerPath, command, ...resolvedArgs], {
    encoding: "utf-8",
  });

  if (result.status !== 0) {
    throw new Error(`Runner failed (exit ${result.status}):\n${result.stderr}`);
  }

  const gotNames = JSON.parse(result.stdout.trim()).sort();
  const wantNames = [...EXPECTED_TOOL_NAMES].sort();
  const missing = wantNames.filter((n) => !gotNames.includes(n));
  const unexpected = gotNames.filter((n) => !wantNames.includes(n));

  console.log(`Tools registered (${gotNames.length}): ${gotNames.join(", ")}`);

  if (missing.length > 0 || unexpected.length > 0) {
    if (missing.length > 0) console.error(`Missing expected tools: ${missing.join(", ")}`);
    if (unexpected.length > 0) console.error(`Unexpected extra tools: ${unexpected.join(", ")}`);
    process.exit(1);
  }

  console.log(
    "\nVerified: the packed .mcpb's server starts under its own manifest command/args, using its own bundled dependencies, and registers exactly the expected tools.",
  );
} finally {
  rmSync(extractDir, { recursive: true, force: true });
}
