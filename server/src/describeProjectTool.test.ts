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

  it("returns the script's result merged with bridgeState as text on success", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () =>
        '{"recordCounts":{"INDI":42},"tagCensus":{"individualAndFamily":{"BIRT":10},"source":{},"sourceTemplateFieldDefinitions":{}}}',
      queryBridgeVersion: matchingVersion,
    });

    expect(result.isError).toBeFalsy();
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.recordCounts).toEqual({ INDI: 42 });
    expect(parsed.tagCensus).toEqual({
      individualAndFamily: { BIRT: 10 },
      source: {},
      sourceTemplateFieldDefinitions: {},
    });
    expect(parsed.bridgeState).toEqual({
      bridgeVersion: SERVER_VERSION,
      serverVersion: SERVER_VERSION,
      versionStatus: "match",
      accessMode: null,
      privacySettings: null,
    });
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

describe("DESCRIBE_PROJECT_DESCRIPTION contextInfo shape (issue #51)", () => {
  it("documents contextInfo and lists the CI_* keys it carries", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"contextInfo"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_PROJECT_NAME/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_APP_MODE/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_STRING_ENCODING/);
  });

  it("explains why the window-handle and book-only CI_* keys are excluded", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_APP_HWND/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_PARENT_HWND/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/CI_BOOK_CONTEXT/);
  });
});

describe("DESCRIBE_PROJECT_DESCRIPTION fhAppVersion shape (issue #69)", () => {
  it("documents fhAppVersion as a dotted version string", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"fhAppVersion"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION.toLowerCase()).toMatch(/family historian/);
  });
});

describe("DESCRIBE_PROJECT_SCRIPT fhAppVersion logic (issue #69)", () => {
  it("calls fhGetAppVersion and returns fhAppVersion alongside the existing top-level keys", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/fhGetAppVersion\(\)/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/fhAppVersion = fhAppVersion,/);
  });

  it("formats the three version integers as a dotted string, not a table of parts", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/string\.format\("%d\.%d\.%d"/);
  });
});

describe("DESCRIBE_PROJECT_SCRIPT contextInfo logic (issue #51)", () => {
  it("calls fhGetContextInfo for every documented string/bool CI_* key", () => {
    for (const key of [
      "CI_PROJECT_NAME",
      "CI_PROJECT_FILE",
      "CI_GEDCOM_FILE",
      "CI_PROJECT_PUBLIC_FOLDER",
      "CI_PROJECT_DATA_FOLDER",
      "CI_PLUGIN_NAME",
      "CI_APP_DATA_FOLDER",
      "CI_APP_MODE",
      "CI_STRING_ENCODING",
    ]) {
      expect(DESCRIBE_PROJECT_SCRIPT).toMatch(new RegExp(`"${key}"`));
    }
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/contextInfo\[key\] = fhGetContextInfo\(key\)/);
  });

  it("omits the userdata (window handle) and book-only CI_* keys", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/"CI_APP_HWND"/);
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/"CI_PARENT_HWND"/);
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/"CI_BOOK_CONTEXT"/);
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/"CI_BOOK_ITEM_HEADING"/);
  });

  it("returns contextInfo alongside the existing top-level keys", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/contextInfo = contextInfo,/);
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

describe("DESCRIBE_PROJECT_SCRIPT sourceTemplateFieldDefinitions logic (issue #74, ADR 0017, supersedes issue #67/#73's sourceTemplateFields)", () => {
  // Same "regression guard on the script text" spirit as the flagCensus/dataQuality block
  // above. issue #67/#73's sourceTemplateFields walked every SOUR record and tallied real
  // occurrence counts via fhBridge.getPopulatedTemplateFields — but that helper only ever
  // resolves record-level fields, so a Citation-specific field (CITN) silently tallied
  // zero forever, however often it was actually populated (issue #74). Rather than extend
  // that walk to also scan every citation on every INDI/FAM record (expensive, and paid on
  // every describe_project call whether or not the conversation ever touches sources), the
  // census now reports template field *definitions* only — a cheap walk bounded by how many
  // _SRCT templates the project actually has (FH only copies used templates into the
  // project) rather than by record/citation count. Actual occurrence counts, for both
  // record-level and citation-level fields, move to the new opt-in
  // fhBridge.getTemplateFieldCensus helper (bridge/sourceHelper.lua) instead — see ADR
  // 0017.
  it("walks _SRCT template records and their FDEF children directly, not fhBridge.getPopulatedTemplateFields over every SOUR", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/template:MoveToFirstRecord\("_SRCT"\)/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/childTag == "FDEF"/);
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/fhBridge\.getPopulatedTemplateFields/);
    expect(DESCRIBE_PROJECT_SCRIPT).not.toMatch(/for sour in fhu\.records\("SOUR"\)/);
  });

  it("reads each FDEF's own CODE/TYPE/CITN children, keying the definitions map by CODE", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/subTag == "CODE"/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/subTag == "TYPE"/);
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/subTag == "CITN"/);
  });

  it("nests field definitions per template name, not flattened across every template", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/sourceTemplateFieldDefinitions\[templateName\] = fields/);
  });

  it("marks a field's citation flag from its own CITN child (\"Yes\"), same convention as sourceHelper.lua's fieldDefs", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(/citation = .*== "Yes"/);
  });

  it("returns sourceTemplateFieldDefinitions alongside the existing tagCensus keys", () => {
    expect(DESCRIBE_PROJECT_SCRIPT).toMatch(
      /sourceTemplateFieldDefinitions = sourceTemplateFieldDefinitions,/,
    );
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

  it("still runs the script on a minor/patch version mismatch, without appending a text note — reflected in bridgeState.versionStatus instead (issue #109)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: async () => JSON.stringify({ version: `${SERVER_VERSION}-does-not-match` }),
    });

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    // A stray appended text note would break this parse entirely (trailing non-JSON after
    // the object) — parsing cleanly is itself proof no note was appended.
    const parsed = JSON.parse(text);
    expect(parsed.recordCounts).toEqual({});
    expect(parsed.bridgeState).toEqual({
      bridgeVersion: `${SERVER_VERSION}-does-not-match`,
      serverVersion: SERVER_VERSION,
      versionStatus: "warn",
      accessMode: null,
      privacySettings: null,
    });
  });

  it("reports versionStatus 'unsupported' and null bridgeVersion/accessMode when the Bridge doesn't support version reporting (issue #109)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: async () => JSON.stringify({ error: "expected STOP or LUA <n>" }),
    });

    expect(result.isError).toBeFalsy();
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.bridgeState).toEqual({
      bridgeVersion: null,
      serverVersion: SERVER_VERSION,
      versionStatus: "unsupported",
      accessMode: null,
      privacySettings: null,
    });
  });

  it("reports the Session's real Access mode in bridgeState when the Bridge reply includes one (issue #109)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: async () =>
        JSON.stringify({ version: SERVER_VERSION, accessMode: "read-write" }),
    });

    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.bridgeState.accessMode).toBe("read-write");
  });

  it("reports accessMode null in bridgeState when the Bridge predates accessMode-in-VERSION-reply (issue #109)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: matchingVersion,
    });

    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.bridgeState.accessMode).toBeNull();
  });

  it("reports the Session's real privacySettings in bridgeState when the Bridge reply includes them (issue #141)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: async () =>
        JSON.stringify({
          version: SERVER_VERSION,
          privacySettings: { privateVisibility: "exclude", livingVisibility: "nameOnly" },
        }),
    });

    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.bridgeState.privacySettings).toEqual({ private: "exclude", living: "nameOnly" });
  });

  it("reports privacySettings null in bridgeState when the Bridge predates privacySettings-in-VERSION-reply (issue #141)", async () => {
    const result = await handleDescribeProject({
      runLuaOnBridge: async () => '{"recordCounts":{}}',
      queryBridgeVersion: matchingVersion,
    });

    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.bridgeState.privacySettings).toBeNull();
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

describe("DESCRIBE_PROJECT_DESCRIPTION bridgeState shape (issue #109)", () => {
  it("documents bridgeState and its four fields", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"bridgeState"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"bridgeVersion"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"serverVersion"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"versionStatus"/);
    expect(DESCRIBE_PROJECT_DESCRIPTION).toMatch(/"accessMode"/);
  });

  it("distinguishes bridgeState's Access mode from the Read-only sandbox this tool's own script always runs under", () => {
    expect(DESCRIBE_PROJECT_DESCRIPTION.toLowerCase()).toMatch(/session/);
    expect(DESCRIBE_PROJECT_DESCRIPTION.toLowerCase()).toMatch(/read-only sandbox/);
  });
});
