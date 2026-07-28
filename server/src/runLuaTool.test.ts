import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import { handleRunLua } from "./runLuaTool.js";

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
});
