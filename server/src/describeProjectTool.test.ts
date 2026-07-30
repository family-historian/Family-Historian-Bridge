import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError, type RunLuaOnBridgeOptions } from "./bridgeClient.js";
import {
  DESCRIBE_PROJECT_SCRIPT,
  handleDescribeProject,
  makeDescribeProjectDeps,
} from "./describeProjectTool.js";

describe("handleDescribeProject", () => {
  it("runs the fixed built-in script rather than accepting one from the caller", async () => {
    let scriptSent: string | undefined;
    await handleDescribeProject({
      runLuaOnBridge: async (script) => {
        scriptSent = script;
        return "{}";
      },
    });

    expect(scriptSent).toBe(DESCRIBE_PROJECT_SCRIPT);
  });

  it("returns the script's result as text on success", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        '{"recordCounts":{"INDI":42},"tagCensus":{"individualAndFamily":{"BIRT":10},"source":{},"sourceTemplateFields":{}}}',
    });

    expect(result.isError).toBeFalsy();
    expect(result.content).toEqual([
      {
        type: "text",
        text: '{"recordCounts":{"INDI":42},"tagCensus":{"individualAndFamily":{"BIRT":10},"source":{},"sourceTemplateFields":{}}}',
      },
    ]);
  });

  it("surfaces a Lua-side error response as a tool error carrying the message", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        '{"error":"[string \\"run_lua\\"]:1: boom"}',
    });

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("boom");
  });

  it('tells Claude to ask the user to click Start, rather than retry, when no Session is running', async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => {
        throw new BridgeConnectionRefusedError();
      },
    });

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/no .*session/i);
    expect(text).toMatch(/click start/i);
  });

  it("surfaces an unexpected bridge communication error without retrying", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => {
        throw new Error("ECONNRESET");
      },
    });

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("ECONNRESET");
  });

  it("surfaces a malformed (non-JSON) response from the Bridge as an error", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => "not json",
    });

    expect(result.isError).toBe(true);
  });

  it("forces the Read-only sandbox regardless of the Session's Access mode (issue #16)", async () => {
    let receivedOptions: RunLuaOnBridgeOptions | undefined;
    const deps = makeDescribeProjectDeps(async (_script, options) => {
      receivedOptions = options;
      return "{}";
    });

    await handleDescribeProject(deps);

    expect(receivedOptions?.forceReadOnly).toBe(true);
  });

  it("names the stale bridge_prototype_v2 plugin when its handshake answers instead of the current Bridge", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        "PROJECT_NAME: Lichfield Memorial\nPROJECT_FILE: C:\\...\nGEDCOM_FILE: \nAPP_MODE: \nAPP_VERSION: 8\nEND\n",
    });

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/bridge_prototype_v2/);
    expect(text).toMatch(/bridge\.fh_lua/);
  });
});
