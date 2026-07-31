import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  BridgeConnectionRefusedError,
  runLuaOnBridge as defaultRunLuaOnBridge,
  type RunLuaOnBridgeOptions,
} from "./bridgeClient.js";
import { describeBridgeConnectionError, interpretBridgeResponse } from "./bridgeResponse.js";

export interface InstallFhPluginDeps {
  runLuaOnBridge: (script: string, options?: RunLuaOnBridgeOptions) => Promise<string>;
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
): Promise<{ path: string } | { errorResult: CallToolResult }> {
  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, { forceReadOnly: true });
  } catch (err) {
    if (err instanceof BridgeConnectionRefusedError) {
      if (explicitPath) {
        return { path: explicitPath };
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

  const appDataFolder = JSON.parse((bridgeResult.content[0] as { text: string }).text) as string;
  return { path: joinPluginsFolder(appDataFolder) };
}

const TITLE_LINE_PATTERN = /^@Title:[ \t]*(.*)$/m;
const GENERATED_FOOTER_SEPARATOR = "\n\n---\n";

function stripGeneratedFooter(pluginSource: string): string {
  const separatorIndex = pluginSource.indexOf(GENERATED_FOOTER_SEPARATOR);
  return separatorIndex === -1 ? pluginSource : pluginSource.slice(0, separatorIndex);
}

function sanitizeFilenameBase(title: string): string {
  const trimmed = title.trim();
  const base = trimmed.length > 0 ? trimmed : "plugin";
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
  const suffix = originalTitle.trim().length > 0 ? `${originalTitle.trim()} V${version}` : `V${version}`;
  return source.replace(TITLE_LINE_PATTERN, `@Title: ${suffix}`);
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
    await deps.writeFile(fullPath, versionedSource);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Could not write the plugin file to ${fullPath}: ${message}`, true);
  }

  return textResult(
    `Installed as "${filename}" in FH's Plugins folder (${resolved.path}).\n\nFH doesn't rescan its Plugins folder live — if the Plugins Dialog (Tools -> Plugins) is currently open, close and reopen it so the new entry appears, then select it and click Run (or tick Add To Tools Menu to run it again later).`,
  );
}
