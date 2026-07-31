import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import { handleRunLua, RUN_LUA_DESCRIPTION } from "./runLuaTool.js";

describe("handleRunLua", () => {
  it("returns the script's result as text on success", async () => {
    const result = await handleRunLua(
      { script: "return {ok=true}" },
      { runLuaOnBridge: async () => '{"ok":true}' },
    );

    expect(result.isError).toBeFalsy();
    expect(result.content).toEqual([{ type: "text", text: '{"ok":true}' }]);
  });

  it("surfaces a Lua-side error response as a tool error carrying the message", async () => {
    const result = await handleRunLua(
      { script: "error('boom')" },
      {
        runLuaOnBridge: async () =>
          '{"error":"[string \\"run_lua\\"]:1: boom"}',
      },
    );

    expect(result.isError).toBe(true);
    expect(result.content[0]?.type).toBe("text");
    expect((result.content[0] as { text: string }).text).toContain("boom");
  });

  it("surfaces a write-mode error's writeSessionRolledBack hint by pointing at FH's own undo dialog and the ended Session, not claiming the undo already happened", async () => {
    const result = await handleRunLua(
      { script: "error('boom')" },
      {
        runLuaOnBridge: async () =>
          '{"error":"[string \\"run_lua\\"]:1: boom","writeSessionRolledBack":true}',
      },
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("boom");
    expect(text.toLowerCase()).toMatch(/plugin error/);
    expect(text.toLowerCase()).toMatch(/click yes|\byes\b/);
    expect(text.toLowerCase()).toMatch(/start a new session|session has ended/);
  });

  it('tells Claude to ask the user to click Start, rather than retry, when no Session is running', async () => {
    const result = await handleRunLua(
      { script: "return 1" },
      {
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
      },
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/no .*session/i);
    expect(text).toMatch(/click start/i);
  });

  it("surfaces an unexpected bridge communication error without retrying", async () => {
    const result = await handleRunLua(
      { script: "return 1" },
      {
        runLuaOnBridge: async () => {
          throw new Error("ECONNRESET");
        },
      },
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("ECONNRESET");
  });

  it("surfaces a malformed (non-JSON) response from the Bridge as an error", async () => {
    const result = await handleRunLua(
      { script: "return 1" },
      { runLuaOnBridge: async () => "not json" },
    );

    expect(result.isError).toBe(true);
  });

  it("names the stale bridge_prototype_v2 plugin when its handshake answers instead of the current Bridge", async () => {
    const result = await handleRunLua(
      { script: "return 1" },
      {
        runLuaOnBridge: async () =>
          "PROJECT_NAME: Lichfield Memorial\nPROJECT_FILE: C:\\...\nGEDCOM_FILE: \nAPP_MODE: \nAPP_VERSION: 8\nEND\n",
      },
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/bridge_prototype_v2/);
    expect(text).toMatch(/bridge\.fh_lua/);
  });
});

describe("RUN_LUA_DESCRIPTION", () => {
  it("names fhBridge.citeSource as the way to attach a citation, instead of hand-rolling fhCreateItem+fhSetValueAsLink", () => {
    expect(RUN_LUA_DESCRIPTION).toMatch(/fhBridge\.citeSource/);
  });

  it("instructs listing every fact a source supports and waiting for confirmation before writing any of them", () => {
    const lower = RUN_LUA_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/isn't yet (in|entered)|not yet entered|gaps?/);
    expect(lower).toMatch(/wait for the user's .*(confirmation|go-ahead)/);
  });

  it("documents write capability, FH's auto-undo safety net, and what writeSessionRolledBack means", () => {
    const lower = RUN_LUA_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/read-write/);
    expect(lower).toMatch(/auto-undo|automatic undo/);
    expect(lower).toMatch(/plugin error/);
    expect(lower).toMatch(/session has ended|session ends|click start again/);
    expect(RUN_LUA_DESCRIPTION).toMatch(/writeSessionRolledBack/);
  });
});
