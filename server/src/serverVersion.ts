import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

// Single source of truth for the server's own version (this used to be a
// hardcoded literal separate from package.json's version; the Bridge-side
// version-mismatch check needs this same string).
const PACKAGE_JSON_PATH = fileURLToPath(new URL("../package.json", import.meta.url));

export const SERVER_VERSION = (
  JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf-8")) as { version: string }
).version;

// The running server's install root (the folder holding its package.json). Reported so a
// user with more than one install (Claude Desktop extension, Claude Code registration) can
// tell which one answered.
export const SERVER_ROOT = dirname(PACKAGE_JSON_PATH);
