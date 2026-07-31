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

// Placeholder so Task 1's tests compile and pass — Task 2 replaces this with the full
// title-parsing/versioning/write implementation.
export async function handleInstallFhPlugin(
  input: { pluginSource: string; path?: string },
  deps: InstallFhPluginDeps,
): Promise<CallToolResult> {
  const resolved = await resolvePluginsFolder(deps, input.path);
  if ("errorResult" in resolved) {
    return resolved.errorResult;
  }

  const titleMatch = input.pluginSource.match(/^@Title:[ \t]*(.*)$/m);
  const base = (titleMatch?.[1].trim() || "plugin").replace(/[<>:"/\\|?*\x00-\x1F]/g, "_");
  const filename = `${base} V1.fh_lua`;
  const fullPath = `${resolved.path}\\${filename}`;

  await deps.writeFile(fullPath, input.pluginSource);
  return textResult(`Installed as "${filename}" in FH's Plugins folder (${resolved.path}).`);
}
