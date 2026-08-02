import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Single source of truth for the server's own version — see issue #44 (this used to be a
// hardcoded literal separate from package.json's version) and issue #45 (the Bridge-side
// version-mismatch check needs this same string).
const PACKAGE_JSON_PATH = fileURLToPath(new URL("../package.json", import.meta.url));

export const SERVER_VERSION = (
  JSON.parse(readFileSync(PACKAGE_JSON_PATH, "utf-8")) as { version: string }
).version;
