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
  // citeSource guidance, the writeSessionRolledBack/auto-undo explanation, and the eight
  // excluded-fhu-methods list used to be asserted here directly. They now live in
  // server/data/gedcom-knowledge-corpus.jsonl instead (see gedcomKnowledge.test.ts's "run_lua
  // guidance corpus entries" block) — moved out of this description's own literal text because
  // MCP clients that load tool descriptions via deferred/lazy schema-loading truncate long
  // descriptions around ~2KB (docs/adr/0011-run-lua-description-truncation-workaround.md).
  // RUN_LUA_DESCRIPTION's own job now is just to point Claude at that corpus entry from within
  // the safe (pre-truncation) zone — see the "safe zone" tests below.

  it("keeps the safe zone (before the ~2KB deferred-tool-loading truncation point) self-sufficient with the core search-first/fhu-preference mandate", () => {
    const SAFE_ZONE_BUDGET = 2000;
    const safeZone = RUN_LUA_DESCRIPTION.slice(0, SAFE_ZONE_BUDGET).toLowerCase();
    expect(safeZone).toMatch(/search first/);
    expect(safeZone).toMatch(/fhu/);
    expect(safeZone).toMatch(/purpose-built helper/);
  });

  it("tells Claude within the safe zone that this description can be truncated, and how to fetch the rest", () => {
    const SAFE_ZONE_BUDGET = 2000;
    const safeZone = RUN_LUA_DESCRIPTION.slice(0, SAFE_ZONE_BUDGET);
    expect(safeZone.toLowerCase()).toMatch(/truncat/);
    expect(safeZone).toMatch(/search_gedcom_knowledge/);
    expect(safeZone).toContain('"run_lua guidance"');
  });

  it("stays well under the observed ~2048-char truncation point up through the truncation notice itself", () => {
    const noticeEnd = RUN_LUA_DESCRIPTION.indexOf('"run_lua guidance"') + '"run_lua guidance"'.length;
    expect(noticeEnd).toBeGreaterThan(0);
    expect(noticeEnd).toBeLessThan(2000);
  });

  it("steers Claude to call fhBridge.logActivity after every record-touching action in a Read-write Session", () => {
    expect(RUN_LUA_DESCRIPTION).toMatch(/fhBridge\.logActivity/);
    const lower = RUN_LUA_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/every record-touching action|after (every|each) (record-touching )?action/);
    expect(lower).toMatch(/research note/);
  });

  it("documents the logActivity media detail for outstanding physical/digital items never attached", () => {
    const lower = RUN_LUA_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/never (actually )?attached as media|never attached/);
    expect(lower).toMatch(/to-do|#todo/);
    expect(lower).toMatch(/photo|physical\/digital|digital item/);
  });

  it("steers Claude to compose a fact-related logActivity action from fhGetDisplayText rather than a hand-typed label", () => {
    expect(RUN_LUA_DESCRIPTION).toMatch(/fhGetDisplayText/);
    const lower = RUN_LUA_DESCRIPTION.toLowerCase();
    expect(lower).toMatch(/fact/);
    expect(lower).toMatch(/hand-typed|hand typed/);
  });

});
