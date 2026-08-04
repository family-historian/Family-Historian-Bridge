import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError, type RunLuaOnBridgeOptions } from "./bridgeClient.js";
import {
  DESCRIBE_PROJECT_DESCRIPTION,
  DESCRIBE_PROJECT_SCRIPT,
  handleDescribeProject,
  makeDescribeProjectDeps,
  type DescribeProjectDeps,
} from "./describeProjectTool.js";
import { SERVER_VERSION } from "./serverVersion.js";

// A queryBridgeVersion stub that reports a Bridge on the exact same version as the
// server — i.e. "match", so version-check tests below don't have to think about it.
const matchingVersion: DescribeProjectDeps["queryBridgeVersion"] = async () =>
  JSON.stringify({ version: SERVER_VERSION });

describe("handleDescribeProject", () => {
  it("runs the fixed built-in script rather than accepting one from the caller", async () => {
    let scriptSent: string | undefined;
    await handleDescribeProject({
      runLuaOnBridge: async (script) => {
        scriptSent = script;
        return "{}";
      },
      queryBridgeVersion: matchingVersion,
    });

    expect(scriptSent).toBe(DESCRIBE_PROJECT_SCRIPT);
  });

  it("returns the script's result as text on success", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        '{"recordCounts":{"INDI":42},"tagCensus":{"individualAndFamily":{"BIRT":10},"source":{},"sourceTemplateFields":{}}}',
      queryBridgeVersion: matchingVersion,
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
      queryBridgeVersion: matchingVersion,
    });

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("boom");
  });

  it('tells Claude to ask the user to click Start, rather than retry, when no Session is running', async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => {
        throw new BridgeConnectionRefusedError();
      },
      queryBridgeVersion: matchingVersion,
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
      queryBridgeVersion: matchingVersion,
    });

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("ECONNRESET");
  });

  it("surfaces a malformed (non-JSON) response from the Bridge as an error", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => "not json",
      queryBridgeVersion: matchingVersion,
    });

    expect(result.isError).toBe(true);
  });

  it("forces the Read-only sandbox regardless of the Session's Access mode (issue #16)", async () => {
    let receivedOptions: RunLuaOnBridgeOptions | undefined;
    const deps = makeDescribeProjectDeps(async (_script, options) => {
      receivedOptions = options;
      return "{}";
    }, matchingVersion);

    await handleDescribeProject(deps);

    expect(receivedOptions?.forceReadOnly).toBe(true);
  });

  it("names the stale bridge_prototype_v2 plugin when its handshake answers instead of the current Bridge", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        "PROJECT_NAME: Lichfield Memorial\nPROJECT_FILE: C:\\...\nGEDCOM_FILE: \nAPP_MODE: \nAPP_VERSION: 8\nEND\n",
      queryBridgeVersion: matchingVersion,
    });

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/bridge_prototype_v2/);
    expect(text).toMatch(/bridge\.fh_lua/);
  });
});

describe("DESCRIBE_PROJECT_DESCRIPTION flagCensus/dataQuality shape (issue #51)", () => {
  it("documents flagCensus as a per-tag {count, label} map, not a bare aggregate", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"flagCensus"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"count"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"label"/);
  });

  it("scopes flagCensus to Individual record flags, explicitly excluding Family/Fact flags", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION.toLowerCase()).toMatch(/individual record flags/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/Fact flags/);
  });

  it("documents dataQuality.livingStatusAmbiguousCount and its DEAT/BURI/CREM/Living-flag criteria", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"dataQuality"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"livingStatusAmbiguousCount"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/DEAT\/BURI\/CREM/);
    expect(DESCRIBE_PROJECT_DESCRIPTION.toLowerCase()).toMatch(/living flag/);
  });
});

describe("DESCRIBE_PROJECT_SCRIPT flagCensus/dataQuality logic (issue #51)", () => {
  // Full traversal correctness against a fake FH item-pointer tree was checked manually
  // (no fake-tree fixture exists in this repo for the Lua side — bridge/tests/*.test.lua
  // tests sandbox.lua's allowlist plumbing, not this script's own traversal logic). These
  // are lightweight regression guards on the script text itself, same spirit as the exact
  // equality check in "runs the fixed built-in script" above, just narrower — catching an
  // accidental deletion/rename of a key piece of the new logic, not full behavior.
  it("walks INDI's own _FLGS children only, not FAM's (record flags are Individual-only)", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/record:MoveToFirstRecord\("INDI"\)/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/childTag == "_FLGS"/);
  });

  it("requires a resolved birth date via the DATE:YEAR qualifier, not just BIRT-tag presence", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/"~\.BIRT\.DATE:YEAR"/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/birthYear ~= ""/);
  });

  it("checks all three death-indicating fact tags, and the Living flag, before counting a record as ambiguous", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(
      /childTag == "DEAT" or childTag == "BURI" or childTag == "CREM"/,
    );
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/flagTag == "__LIVING"/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/not deathFactSeen and not livingFlagSeen/);
  });

  it("resolves each flag tag's human label via fhGetTypeInfo only once per tag, not once per instance", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/fhGetTypeInfo\(flag, "label"\)/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/existing\.count = existing\.count \+ 1/);
  });

  it("returns flagCensus and dataQuality alongside the existing recordCounts/tagCensus keys", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/flagCensus = flagCensus,/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/dataQuality = \{/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/livingStatusAmbiguousCount = livingStatusAmbiguousCount,/);
  });
});

describe("handleDescribeProject version check (issue #45)", () => {
  it("never runs the script and returns an error when the Bridge's major version differs from the server's", async () => {
    let scriptRan = false;
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => {
        scriptRan = true;
        return "{}";
      },
      queryBridgeVersion: async () => JSON.stringify({ version: "999.0.0" }),
    });

    expect(scriptRan).toBe(false);
    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain("999.0.0");
    expect(text.toLowerCase()).toContain("major");
  });

  it("still runs the script and appends a note on a minor/patch version mismatch", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: async () => JSON.stringify({ version: `${SERVER_VERSION}-does-not-match` }),
    });

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain('{"recordCounts":{}}');
    expect(text.toLowerCase()).toContain("note");
  });

  it("tells Claude to ask the user to click Start when the version check itself can't connect, without ever attempting the script", async () => {
    let scriptRan = false;
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => {
        scriptRan = true;
        return "{}";
      },
      queryBridgeVersion: async () => {
        throw new BridgeConnectionRefusedError();
      },
    });

    expect(scriptRan).toBe(false);
    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/no .*session/i);
    expect(text).toMatch(/click start/i);
  });
});
