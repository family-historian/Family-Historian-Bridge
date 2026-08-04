import fs from "node:fs/promises";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import {
  BridgeConnectionRefusedError,
  queryBridgeVersion as defaultQueryBridgeVersion,
  runLuaOnBridge as defaultRunLuaOnBridge,
  type RunLuaOnBridgeOptions,
} from "./bridgeClient.js";
import { describeBridgeConnectionError, interpretBridgeResponse } from "./bridgeResponse.js";
import { SERVER_VERSION } from "./serverVersion.js";
import { appendVersionNote, checkBridgeVersion } from "./versionCheck.js";

export interface InstallFhPluginDeps {
  runLuaOnBridge: (script: string, options?: RunLuaOnBridgeOptions) => Promise<string>;
  queryBridgeVersion: () => Promise<string>;
  readdir: (dirPath: string) => Promise<string[]>;
  writeFile: (filePath: string, content: string) => Promise<void>;
}

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text }], isError };
}

// Already unrestricted in bridge/sandbox.lua (no exclusion needed) — see
// docs/adr/0008-install-fh-plugin-staged-write.md decision 4.
export const GET_PLUGINS_APP_DATA_FOLDER_SCRIPT = `return fhGetContextInfo("CI_APP_DATA_FOLDER")`;

function joinPluginsFolder(appDataFolder: string): string {
  return `${appDataFolder.replace(/[\\/]+$/, "")}\\Plugins`;
}

async function resolvePluginsFolder(
  deps: InstallFhPluginDeps,
  explicitPath: string | undefined,
): Promise<{ path: string; versionNote: string | null } | { errorResult: CallToolResult }> {
  // issue #45: checked ahead of the live folder-lookup connection below, same as
  // run_lua/describe_project. A genuine version-mismatch block stops here, since the
  // lookup below would hit the same incompatible Bridge. A connection-error block just
  // means "couldn't reach the Bridge to check its version" — the lookup below makes the
  // exact same connection attempt and already has its own tailored no-Session message and
  // explicit-path fallback, so that's left to handle it rather than surfacing a second,
  // less specific error first.
  const versionCheck = await checkBridgeVersion(deps.queryBridgeVersion, SERVER_VERSION);
  if (versionCheck.block && versionCheck.reason === "version-mismatch") {
    return { errorResult: versionCheck.block };
  }
  const versionNote = versionCheck.block ? null : versionCheck.note;

  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, { forceReadOnly: true });
  } catch (err) {
    if (err instanceof BridgeConnectionRefusedError) {
      if (explicitPath) {
        return { path: explicitPath, versionNote: null };
      }
      return {
        errorResult: textResult(
          "No FH Bridge Session is running, so the Plugins folder location can't be looked up live. Either ask the user to click Start in the FH Bridge dialog and retry, or ask them to confirm their Plugins folder path themselves (see docs/user-guide.md's \"Where FH's Plugins folder is\" — it differs by FH version) and pass it as the path parameter.",
          true,
        ),
      };
    }
    return { errorResult: describeBridgeConnectionError(err) };
  }

  const bridgeResult = interpretBridgeResponse(raw);
  if (bridgeResult.isError) {
    return { errorResult: bridgeResult };
  }

  const appDataFolder: unknown = JSON.parse((bridgeResult.content[0] as { text: string }).text);
  if (typeof appDataFolder !== "string" || appDataFolder.trim() === "") {
    return {
      errorResult: textResult(
        "FH returned no app-data folder path — could not determine the Plugins folder location. Ask the user to confirm their Plugins folder path (see docs/user-guide.md's \"Where FH's Plugins folder is\") and pass it as the path parameter.",
        true,
      ),
    };
  }
  return { path: joinPluginsFolder(appDataFolder), versionNote };
}

const TITLE_LINE_PATTERN = /^@Title:[ \t]*(.*)$/m;
// Anchored to the generated footer's actual leading text (see author_fh_plugin's
// "Save this as a .fh_lua file..." text), not just the bare "---" rule, so a
// legitimate "---" divider inside the plugin body's own Lua (e.g. an LDoc-style
// section break) can never be mistaken for the generated footer and truncate the
// plugin's real logic.
const GENERATED_FOOTER_SEPARATOR = "\n\n---\nSave this as a .fh_lua file yourself";

// A plain-text plugin file with no encoding marker loads into FH as ANSI, not UTF-8 —
// confirmed live via describe_project's contextInfo reporting CI_STRING_ENCODING "ANSI"
// on a plugin installed without one, even though FH's own Plugin Editor defaults new
// plugins to UTF-8 (FH help: "String Encoding and Unicode"). ANSI silently mangles any
// accented/non-ASCII text a script reads from or writes to the tree — a real risk for a
// genealogy tool. Prepending the UTF-8 BOM (U+FEFF — Node's default "utf8" write encodes
// it as the 3-byte EF BB BF sequence FH's own file-encoding detection looks for, per
// fhug.org.uk's TestEncoding()) makes every plugin this tool writes load as UTF-8.
const UTF8_BOM = "\uFEFF";

function stripGeneratedFooter(pluginSource: string): string {
  const separatorIndex = pluginSource.indexOf(GENERATED_FOOTER_SEPARATOR);
  return separatorIndex === -1 ? pluginSource : pluginSource.slice(0, separatorIndex);
}

// Shared blank-@Title fallback base — used for both the filename (sanitizeFilenameBase)
// and the versioned @Title header (appendVersionToTitle) so the two always agree: a blank
// title produces filename "plugin V1.fh_lua" and header "@Title: plugin V1", never a
// header that just reads "V1" with no "plugin" prefix.
const BLANK_TITLE_FALLBACK = "plugin";

function sanitizeFilenameBase(title: string): string {
  const trimmed = title.trim();
  const base = trimmed.length > 0 ? trimmed : BLANK_TITLE_FALLBACK;
  return base.replace(/[<>:"/\\|?*\x00-\x1F]/g, "_");
}

function nextVersionNumber(existingNames: string[], base: string): number {
  const escapedBase = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^${escapedBase} V(\\d+)\\.fh_lua$`);
  let max = 0;
  for (const name of existingNames) {
    const match = name.match(pattern);
    if (match) {
      max = Math.max(max, Number(match[1]));
    }
  }
  return max + 1;
}

function appendVersionToTitle(source: string, version: number, originalTitle: string): string {
  const trimmed = originalTitle.trim();
  const effectiveTitle = trimmed.length > 0 ? trimmed : BLANK_TITLE_FALLBACK;
  return source.replace(TITLE_LINE_PATTERN, `@Title: ${effectiveTitle} V${version}`);
}

export async function handleInstallFhPlugin(
  input: { pluginSource: string; path?: string },
  deps: InstallFhPluginDeps,
): Promise<CallToolResult> {
  const source = stripGeneratedFooter(input.pluginSource);

  const titleMatch = source.match(TITLE_LINE_PATTERN);
  if (!titleMatch) {
    return textResult(
      "No @Title field found in the supplied plugin source — pass pluginSource exactly as author_fh_plugin generated it.",
      true,
    );
  }
  const originalTitle = titleMatch[1];

  const resolved = await resolvePluginsFolder(deps, input.path);
  if ("errorResult" in resolved) {
    return resolved.errorResult;
  }

  let existingNames: string[];
  try {
    existingNames = await deps.readdir(resolved.path);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Could not read the Plugins folder at ${resolved.path}: ${message}`, true);
  }

  const base = sanitizeFilenameBase(originalTitle);
  const version = nextVersionNumber(existingNames, base);
  const filename = `${base} V${version}.fh_lua`;
  const fullPath = `${resolved.path}\\${filename}`;
  const versionedSource = appendVersionToTitle(source, version, originalTitle);

  try {
    await deps.writeFile(fullPath, UTF8_BOM + versionedSource);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Could not write the plugin file to ${fullPath}: ${message}`, true);
  }

  return appendVersionNote(
    textResult(
      `Installed as "${filename}" in FH's Plugins folder (${resolved.path}).\n\nFH doesn't rescan its Plugins folder live — if the Plugins Dialog (Tools -> Plugins) is currently open, close and reopen it so the new entry appears, then select it and click Run (or tick Add To Tools Menu to run it again later).`,
    ),
    resolved.versionNote,
  );
}

function makeDefaultInstallFhPluginDeps(): InstallFhPluginDeps {
  return {
    runLuaOnBridge: defaultRunLuaOnBridge,
    queryBridgeVersion: () => defaultQueryBridgeVersion(SERVER_VERSION),
    readdir: (dirPath) => fs.readdir(dirPath),
    // "wx" refuses to overwrite an existing file — a last-line-of-defence race guard on
    // top of the version-number scan above, not a substitute for it.
    writeFile: (filePath, content) => fs.writeFile(filePath, content, { flag: "wx" }),
  };
}

const defaultDeps: InstallFhPluginDeps = makeDefaultInstallFhPluginDeps();

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's
// "install_fh_plugin" entry and docs/adr/0008-install-fh-plugin-staged-write.md.
export const INSTALL_FH_PLUGIN_DESCRIPTION = `Write a plugin author_fh_plugin generated directly into FH's Plugins folder, ready for the user to run from Tools -> Plugins, instead of them saving the file themselves.

Only call this when the user explicitly asks you to install (or "save", "add", "upload") the plugin you just generated — never automatically as a follow-up to author_fh_plugin, even when the generated plugin has no "-- FLAGGED" lines. Installing is still the user choosing to trust and run what you wrote; author_fh_plugin's flags exist so they can review it first, and calling this tool silently would remove that checkpoint. Flagged lines are expected and fine here — a Report/Query plugin genuinely needs functions run_lua's sandbox excludes (fhOutputResultSetColumn, fhMessageBox, etc.), that's the whole reason author_fh_plugin exists as a separate trust mode.

Pass pluginSource exactly as author_fh_plugin returned it (its trailing "---" install-instructions footer, if you include it, is stripped automatically — no need to trim it yourself).

Never overwrites an existing file. Each install gets the next unused "V<N>" suffix on both the filename and the plugin's own @Title header, based on how many versions of that title are already in the Plugins folder — so asking to install after tweaking the same plugin's logic again produces "<Title> V2", then "V3", etc., rather than clobbering the previous save.

Always writes the file as UTF-8 with a BOM, so FH loads it as Unicode rather than defaulting to ANSI (which silently mangles accented/non-ASCII text). No action needed on your part — this is automatic.

Requires an active Bridge Session (same as run_lua) to look up FH's Plugins folder location live. If no Session is running, tell the user to click Start and retry, or ask them to confirm their Plugins folder path themselves (see docs/user-guide.md's "Where FH's Plugins folder is" — the location differs by FH version and is easy to get wrong) and pass it as the path parameter.

FH does not rescan its Plugins folder while its Plugins Dialog is open. After a successful install, tell the user to close and reopen Tools -> Plugins if they have it open, then select the new entry and click Run (or tick Add To Tools Menu).`;

export function registerInstallFhPluginTool(
  server: McpServer,
  deps: InstallFhPluginDeps = defaultDeps,
): void {
  server.registerTool(
    "install_fh_plugin",
    {
      description: INSTALL_FH_PLUGIN_DESCRIPTION,
      inputSchema: {
        pluginSource: z
          .string()
          .describe(
            "The plugin source exactly as author_fh_plugin returned it. Its trailing '---' install-instructions footer, if included, is stripped automatically.",
          ),
        path: z
          .string()
          .optional()
          .describe(
            "Explicit path to FH's Plugins folder, used only as a fallback when no Bridge Session is running to look the path up live. Ask the user to confirm this themselves (see docs/user-guide.md's 'Where FH's Plugins folder is') rather than guessing it.",
          ),
      },
    },
    (input) => handleInstallFhPlugin(input, deps),
  );
}
