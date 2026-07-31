import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import type { InstallFhPluginDeps } from "./installFhPluginTool.js";
import { GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, handleInstallFhPlugin } from "./installFhPluginTool.js";

const PLUGIN_SOURCE = `--[[
@Title: Surname Census
@Author: Claude MCP
@Version: 1.0
]]

fhOutputResultSetColumn("Surname", "text", {}, 0)`;

function makeDeps(overrides: Partial<InstallFhPluginDeps> = {}): InstallFhPluginDeps {
  return {
    runLuaOnBridge: async () => JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8"),
    readdir: async () => [],
    writeFile: async () => {},
    ...overrides,
  };
}

describe("resolvePluginsFolder (via handleInstallFhPlugin)", () => {
  it("queries CI_APP_DATA_FOLDER read-only and appends \\Plugins to the resolved path", async () => {
    let scriptSent: string | undefined;
    let forcedReadOnly: boolean | undefined;
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async (script, options) => {
          scriptSent = script;
          forcedReadOnly = options?.forceReadOnly;
          return JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8");
        },
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(scriptSent).toBe(GET_PLUGINS_APP_DATA_FOLDER_SCRIPT);
    expect(forcedReadOnly).toBe(true);
    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("trims a trailing separator from the live-queried app data folder before appending \\Plugins", async () => {
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8\\"),
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("falls back to the explicit path param, used as-is, when no Bridge Session is running", async () => {
    let writtenPath: string | undefined;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE, path: "C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins" },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(result.isError).toBeFalsy();
    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("errors telling the user to click Start or supply path, when no Session is running and no path given", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
      }),
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/click start/i);
    expect(text).toMatch(/path/i);
  });

  it("surfaces an unexpected bridge communication error without retrying", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new Error("ECONNRESET");
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("ECONNRESET");
  });

  it("surfaces a Lua-side error from the live path query as a tool error", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => '{"error":"boom"}',
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("boom");
  });
});
