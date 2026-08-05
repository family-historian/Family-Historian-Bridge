#!/usr/bin/env node
// Builds a .mcpb (MCPB/DXT) bundle for fh-mcp-bridge's server -- issue #59, part of the
// wayfinder map at issue #56 (docs/research/claude-app-variant-and-dxt-install-trigger.md's
// Q2 confirmed double-click/shellexec-opening a .mcpb is Claude Desktop's own documented
// install trigger). Cross-platform (Node, not PowerShell/bash) since, unlike the Setup.exe
// installer (installer/fh-mcp-bridge.iss, Windows-only), a .mcpb doesn't need a bundled
// node.exe -- Claude Desktop supplies its own Node runtime for a "type": "node" server, so
// there's nothing platform-specific about staging this bundle. See
// docs/adr/0015-mcpb-bundle-manifest-is-generated-not-hand-copied.md.
//
// Usage: node installer/build-dxt.mjs
// Produces: installer/output/fh-mcp-bridge-<version>.mcpb
//
// Run installer/verify-dxt.mjs afterwards (or pass --verify) to actually spawn the staged
// server and confirm its tools register -- the automatable half of "verify it actually
// installs" from issue #59; the Claude Desktop Settings -> Extensions install itself is
// hands-on, see that ticket's HITL note.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, cpSync, writeFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { buildManifest } from "./dxt/manifest.mjs";

const installerDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(installerDir);
const serverDir = join(repoRoot, "server");
const stagingDir = join(installerDir, "dxt-staging");
const outputDir = join(installerDir, "output");

function run(command, args, opts = {}) {
  console.log(`+ ${command} ${args.join(" ")}${opts.cwd ? ` (in ${opts.cwd})` : ""}`);
  // shell:true resolves npm/npx (.cmd shims on Windows) consistently on both Windows and
  // macOS. Passed as a single pre-quoted command-line string, not a separate args array --
  // an args array under shell:true is passed through unescaped (Node's own DEP0190
  // deprecation warning), and separately this repo's own path ("...\MCP for Family
  // Historian\...") contains spaces that would otherwise silently split into multiple
  // arguments.
  const commandLine = [command, ...args]
    .map((part) => (typeof part === "string" && part.includes(" ") ? `"${part}"` : part))
    .join(" ");
  const result = spawnSync(commandLine, { stdio: "inherit", shell: true, ...opts });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with code ${result.status}`);
  }
}

function readServerVersion() {
  const pkg = JSON.parse(readFileSync(join(serverDir, "package.json"), "utf-8"));
  if (!pkg.version) throw new Error("server/package.json has no version field");
  return pkg.version;
}

console.log("== Building server ==");
run("npm", ["run", "build"], { cwd: serverDir });

console.log("== Staging dxt bundle ==");
if (existsSync(stagingDir)) rmSync(stagingDir, { recursive: true, force: true });
mkdirSync(join(stagingDir, "server"), { recursive: true });

cpSync(join(serverDir, "package.json"), join(stagingDir, "server", "package.json"));
cpSync(join(serverDir, "package-lock.json"), join(stagingDir, "server", "package-lock.json"));
cpSync(join(serverDir, "dist"), join(stagingDir, "server", "dist"), { recursive: true });
cpSync(join(serverDir, "data"), join(stagingDir, "server", "data"), { recursive: true });

console.log("== Installing production-only server dependencies (npm ci --omit=dev) ==");
// Per Anthropic's own MCPB bundling guidance: "Run npm install --production to create
// node_modules" and "Bundle the entire node_modules directory with your bundle" -- `mcpb
// pack` does NOT install dependencies itself, only zips what's already on disk (its own
// exclusion list covers dev cruft like node_modules/.cache, not node_modules itself). This
// mirrors installer/stage.ps1's identical reasoning for the Setup.exe installer's server
// copy: devDependencies (typescript, vitest, @types/node) never end up in the shipped
// bundle, and the developer's own server/node_modules (used for `npm test`) is untouched.
run("npm", ["ci", "--omit=dev"], { cwd: join(stagingDir, "server") });

const version = readServerVersion();
console.log(`== Writing manifest.json (version ${version}) ==`);
writeFileSync(join(stagingDir, "manifest.json"), JSON.stringify(buildManifest({ version }), null, 2));

console.log("== Validating manifest ==");
run("npx", ["--yes", "@anthropic-ai/mcpb", "validate", stagingDir]);

mkdirSync(outputDir, { recursive: true });
const outputPath = join(outputDir, `fh-mcp-bridge-${version}.mcpb`);
if (existsSync(outputPath)) rmSync(outputPath);

console.log("== Packing ==");
run("npx", ["--yes", "@anthropic-ai/mcpb", "pack", stagingDir, outputPath]);

console.log(`\nBuilt: ${outputPath}`);

if (process.argv.includes("--verify")) {
  console.log("\n== Verifying (installer/verify-dxt.mjs) ==");
  run("node", [join(installerDir, "verify-dxt.mjs"), outputPath]);
}
