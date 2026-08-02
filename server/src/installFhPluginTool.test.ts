import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import type { InstallFhPluginDeps } from "./installFhPluginTool.js";
import { GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, handleInstallFhPlugin } from "./installFhPluginTool.js";
import { SERVER_VERSION } from "./serverVersion.js";

const PLUGIN_SOURCE = `--[[
@Title: Surname Census
@Author: Claude MCP
@Version: 1.0
]]

fhOutputResultSetColumn("Surname", "text", {}, 0)`;

function makeDeps(overrides: Partial<InstallFhPluginDeps> = {}): InstallFhPluginDeps {
  return {
    runLuaOnBridge: async () => JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8"),
    queryBridgeVersion: async () => JSON.stringify({ version: SERVER_VERSION }),
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

  it("errors clearly, without calling writeFile, when the bridge resolves an empty-string app data folder", async () => {
    let writeCalled = false;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => JSON.stringify(""),
        writeFile: async () => {
          writeCalled = true;
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text.length).toBeGreaterThan(0);
    expect(writeCalled).toBe(false);
  });

  it("errors clearly, without calling writeFile, when the bridge resolves a null app data folder", async () => {
    let writeCalled = false;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => JSON.stringify(null),
        writeFile: async () => {
          writeCalled = true;
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text.length).toBeGreaterThan(0);
    expect(writeCalled).toBe(false);
  });
});

describe("handleInstallFhPlugin — versioning and write behaviour", () => {
  it("starts at V1 and appends the version to the @Title header, not just the filename", async () => {
    let writtenPath: string | undefined;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        writeFile: async (filePath, content) => {
          writtenPath = filePath;
          writtenContent = content;
        },
      }),
    );

    expect(writtenPath).toContain("Surname Census V1.fh_lua");
    expect(writtenContent).toMatch(/^@Title: Surname Census V1$/m);
  });

  it("increments past existing V<N> files for the same title, never overwriting", async () => {
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        readdir: async () => ["Surname Census V1.fh_lua", "Surname Census V2.fh_lua", "Other Plugin V1.fh_lua"],
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toContain("Surname Census V3.fh_lua");
  });

  it("sanitizes characters invalid in a Windows filename out of the title", async () => {
    const source = PLUGIN_SOURCE.replace("@Title: Surname Census", '@Title: Surnames: A "Census"?');
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: source },
      makeDeps({
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toBe(
      "C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surnames_ A _Census__ V1.fh_lua",
    );
  });

  it("defaults to base name 'plugin' when @Title is blank, consistently in filename and header", async () => {
    const source = PLUGIN_SOURCE.replace("@Title: Surname Census", "@Title:");
    let writtenPath: string | undefined;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: source },
      makeDeps({
        writeFile: async (filePath, content) => {
          writtenPath = filePath;
          writtenContent = content;
        },
      }),
    );

    expect(writtenPath).toContain("plugin V1.fh_lua");
    expect(writtenContent).toMatch(/^@Title: plugin V1$/m);
  });

  it("strips author_fh_plugin's trailing '---' install-instructions footer before writing", async () => {
    const withFooter = `${PLUGIN_SOURCE}\n\n---\nSave this as a .fh_lua file yourself and install it under FH's own permission model.`;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: withFooter },
      makeDeps({
        writeFile: async (_filePath, content) => {
          writtenContent = content;
        },
      }),
    );

    expect(writtenContent).not.toContain("Save this as a .fh_lua file yourself");
    expect(writtenContent).toContain('fhOutputResultSetColumn("Surname", "text", {}, 0)');
  });

  it("does not truncate on a bare '---' divider inside the plugin body itself", async () => {
    // A plausible Claude-authored Lua section divider (LDoc-style), not the real
    // author_fh_plugin generated footer — must survive stripGeneratedFooter intact.
    const withBodyDivider = `${PLUGIN_SOURCE}\n\n---\n-- a section divider, not the generated footer\nlocal x = 1\n`;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: withBodyDivider },
      makeDeps({
        writeFile: async (_filePath, content) => {
          writtenContent = content;
        },
      }),
    );

    expect(writtenContent).toContain("-- a section divider, not the generated footer");
    expect(writtenContent).toContain("local x = 1");
  });

  it("returns a clear error and writes nothing when no @Title field is present", async () => {
    let writeCalled = false;
    const result = await handleInstallFhPlugin(
      { pluginSource: "fhOutputResultSetColumn(\"Surname\", \"text\", {}, 0)" },
      makeDeps({
        writeFile: async () => {
          writeCalled = true;
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toMatch(/@Title/);
    expect(writeCalled).toBe(false);
  });

  it("reminds the user to close and reopen the Plugins Dialog if it's open, on success", async () => {
    const result = await handleInstallFhPlugin({ pluginSource: PLUGIN_SOURCE }, makeDeps());

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/close and reopen/i);
    expect(text).toMatch(/plugins dialog/i);
  });
});

describe("handleInstallFhPlugin version check (issue #45)", () => {
  it("never looks up the Plugins folder and errors when the Bridge's major version differs from the server's", async () => {
    let folderLookupRan = false;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          folderLookupRan = true;
          return JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8");
        },
        queryBridgeVersion: async () => JSON.stringify({ version: "999.0.0" }),
      }),
    );

    expect(folderLookupRan).toBe(false);
    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("999.0.0");
    expect(text.toLowerCase()).toContain("major");
  });

  it("appends a version-mismatch note to the success message on a minor/patch mismatch", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        queryBridgeVersion: async () => JSON.stringify({ version: `${SERVER_VERSION}-does-not-match` }),
      }),
    );

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/close and reopen/i);
    expect(text.toLowerCase()).toContain("note");
  });

  it("falls back to the explicit path, with no error, when the version check itself can't connect (same as the folder lookup's own fallback)", async () => {
    let writtenPath: string | undefined;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE, path: "C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins" },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
        queryBridgeVersion: async () => {
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

  it("still surfaces the folder lookup's own tailored no-Session error when the version check also can't connect and no path was given", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
        queryBridgeVersion: async () => {
          throw new BridgeConnectionRefusedError();
        },
      }),
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/click start/i);
    expect(text).toMatch(/path/i);
  });
});
