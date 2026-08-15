import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import {
  appendVersionNote,
  checkBridgeVersion,
  compareVersions,
  interpretVersionResponse,
  runVersionCheckedScript,
} from "./versionCheck.js";

describe("compareVersions", () => {
  it("matches identical versions", () => {
    expect(compareVersions("0.4.0", "0.4.0")).toBe("match");
  });

  it("warns on a differing patch version", () => {
    expect(compareVersions("0.4.0", "0.4.1")).toBe("warn");
  });

  it("warns (not blocks) on a differing minor version pre-1.0 — only major differs block (issue #45)", () => {
    expect(compareVersions("0.4.0", "0.3.0")).toBe("warn");
  });

  it("blocks on a differing major version", () => {
    expect(compareVersions("1.4.0", "2.0.0")).toBe("block");
  });

  it("blocks regardless of which side's major is ahead", () => {
    expect(compareVersions("2.0.0", "1.9.9")).toBe("block");
  });

  it("warns when the bridge version is unparseable, rather than guessing severity", () => {
    expect(compareVersions("garbage", "0.4.0")).toBe("warn");
  });

  it("warns when the server version is unparseable, rather than guessing severity", () => {
    expect(compareVersions("0.4.0", "garbage")).toBe("warn");
  });
});

describe("interpretVersionResponse", () => {
  it("reports match with the bridge's version retained and accessMode null when the reply omits it", () => {
    expect(interpretVersionResponse('{"version":"0.4.0"}', "0.4.0")).toEqual({
      status: "match",
      bridgeVersion: "0.4.0",
      accessMode: null,
    });
  });

  it("reports warn with both versions and accessMode null attached on a minor/patch mismatch", () => {
    expect(interpretVersionResponse('{"version":"0.4.0"}', "0.4.1")).toEqual({
      status: "warn",
      bridgeVersion: "0.4.0",
      serverVersion: "0.4.1",
      accessMode: null,
    });
  });

  it("reports block with both versions and accessMode null attached on a major mismatch", () => {
    expect(interpretVersionResponse('{"version":"1.0.0"}', "2.0.0")).toEqual({
      status: "block",
      bridgeVersion: "1.0.0",
      serverVersion: "2.0.0",
      accessMode: null,
    });
  });

  it("reports unsupported when an old Bridge rejects the VERSION request with its usual malformed-framing error", () => {
    expect(
      interpretVersionResponse('{"error": "expected STOP or LUA <n>"}', "0.4.0"),
    ).toEqual({ status: "unsupported" });
  });

  it("reports unparseable on non-JSON", () => {
    expect(interpretVersionResponse("not json", "0.4.0")).toEqual({ status: "unparseable" });
  });

  it("reports unparseable when the response has neither a version nor the old-bridge error shape", () => {
    expect(interpretVersionResponse('{"unexpected":true}', "0.4.0")).toEqual({
      status: "unparseable",
    });
  });

  it("reports the accessMode a Bridge reply includes, on both match and warn (issue #109)", () => {
    expect(
      interpretVersionResponse('{"version":"0.4.0","accessMode":"read-write"}', "0.4.0"),
    ).toEqual({ status: "match", bridgeVersion: "0.4.0", accessMode: "read-write" });

    expect(
      interpretVersionResponse('{"version":"0.4.0","accessMode":"read-only"}', "0.4.1"),
    ).toEqual({
      status: "warn",
      bridgeVersion: "0.4.0",
      serverVersion: "0.4.1",
      accessMode: "read-only",
    });
  });

  it("treats an unrecognized accessMode value as null rather than passing it through", () => {
    expect(
      interpretVersionResponse('{"version":"0.4.0","accessMode":"sudo"}', "0.4.0"),
    ).toEqual({ status: "match", bridgeVersion: "0.4.0", accessMode: null });
  });
});

describe("checkBridgeVersion", () => {
  it("blocks nothing, returns no note, and reports bridgeState on a match", async () => {
    const result = await checkBridgeVersion(
      async () => '{"version":"0.4.0"}',
      "0.4.0",
    );

    expect(result).toEqual({
      block: null,
      note: null,
      bridgeState: {
        bridgeVersion: "0.4.0",
        serverVersion: "0.4.0",
        versionStatus: "match",
        accessMode: null,
      },
    });
  });

  it("returns a note (but does not block) and reports bridgeState on a minor/patch mismatch", async () => {
    const result = await checkBridgeVersion(
      async () => '{"version":"0.4.0"}',
      "0.4.1",
    );

    expect(result.block).toBeNull();
    if (result.block !== null) throw new Error("unreachable");
    expect(result.note).toContain("0.4.0");
    expect(result.note).toContain("0.4.1");
    expect(result.bridgeState).toEqual({
      bridgeVersion: "0.4.0",
      serverVersion: "0.4.1",
      versionStatus: "warn",
      accessMode: null,
    });
  });

  it("blocks with an error result on a major mismatch, naming both versions, tagged as a version-mismatch reason", async () => {
    const result = await checkBridgeVersion(
      async () => '{"version":"1.0.0"}',
      "2.0.0",
    );

    expect(result.block).not.toBeNull();
    if (result.block === null) throw new Error("unreachable");
    expect(result.reason).toBe("version-mismatch");
    expect(result.block.isError).toBe(true);
    const text = (result.block.content[0] as { text: string }).text;
    expect(text).toContain("1.0.0");
    expect(text).toContain("2.0.0");
    expect(text.toLowerCase()).toContain("major");
  });

  it("returns a note (but does not block) and reports bridgeState with a null bridgeVersion/accessMode when the Bridge doesn't support version reporting", async () => {
    const result = await checkBridgeVersion(
      async () => '{"error": "expected STOP or LUA <n>"}',
      "0.4.0",
    );

    expect(result.block).toBeNull();
    if (result.block !== null) throw new Error("unreachable");
    expect(result.note).toMatch(/doesn't support version reporting/);
    expect(result.bridgeState).toEqual({
      bridgeVersion: null,
      serverVersion: "0.4.0",
      versionStatus: "unsupported",
      accessMode: null,
    });
  });

  it("returns a generic note (but does not block) and reports bridgeState with a null bridgeVersion/accessMode on an unparseable response", async () => {
    const result = await checkBridgeVersion(async () => "garbage", "0.4.0");

    expect(result.block).toBeNull();
    if (result.block !== null) throw new Error("unreachable");
    expect(result.note).toMatch(/could not determine/i);
    expect(result.bridgeState).toEqual({
      bridgeVersion: null,
      serverVersion: "0.4.0",
      versionStatus: "unparseable",
      accessMode: null,
    });
  });

  it("blocks with the no-Session message when the version query itself can't connect, tagged as a connection-error reason", async () => {
    const result = await checkBridgeVersion(async () => {
      throw new BridgeConnectionRefusedError();
    }, "0.4.0");

    expect(result.block).not.toBeNull();
    if (result.block === null) throw new Error("unreachable");
    expect(result.reason).toBe("connection-error");
    expect(result.block.isError).toBe(true);
    const text = (result.block.content[0] as { text: string }).text;
    expect(text).toMatch(/no .*session/i);
    expect(text).toMatch(/click start/i);
  });

  it("reports the accessMode a Bridge reply includes in bridgeState (issue #109)", async () => {
    const result = await checkBridgeVersion(
      async () => '{"version":"0.4.0","accessMode":"read-write"}',
      "0.4.0",
    );

    expect(result.block).toBeNull();
    if (result.block !== null) throw new Error("unreachable");
    expect(result.bridgeState.accessMode).toBe("read-write");
  });
});

describe("runVersionCheckedScript", () => {
  it("runs the script and returns its result unmodified when versions match", async () => {
    const result = await runVersionCheckedScript(
      {
        runLuaOnBridge: async () => '{"ok":true}',
        queryBridgeVersion: async () => '{"version":"0.4.0"}',
      },
      "0.4.0",
      "return {ok=true}",
    );

    expect(result.isError).toBeFalsy();
    expect(result.content).toEqual([{ type: "text", text: '{"ok":true}' }]);
  });

  it("runs the script and appends a note on a minor/patch mismatch", async () => {
    const result = await runVersionCheckedScript(
      {
        runLuaOnBridge: async () => '{"ok":true}',
        queryBridgeVersion: async () => '{"version":"0.4.0"}',
      },
      "0.4.1",
      "return {ok=true}",
    );

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    expect(text).toContain('{"ok":true}');
    expect(text.toLowerCase()).toContain("note");
  });

  it("never runs the script on a major-version mismatch, returning the block result instead", async () => {
    let scriptRan = false;
    const result = await runVersionCheckedScript(
      {
        runLuaOnBridge: async () => {
          scriptRan = true;
          return '{"ok":true}';
        },
        queryBridgeVersion: async () => '{"version":"999.0.0"}',
      },
      "0.4.0",
      "return {ok=true}",
    );

    expect(scriptRan).toBe(false);
    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("999.0.0");
  });

  it("surfaces the script's own connection error unchanged when the version check itself succeeded", async () => {
    const result = await runVersionCheckedScript(
      {
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
        queryBridgeVersion: async () => '{"version":"0.4.0"}',
      },
      "0.4.0",
      "return {ok=true}",
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/no .*session/i);
    expect(text).toMatch(/click start/i);
  });
});

describe("appendVersionNote", () => {
  it("returns the result unchanged when there is no note", () => {
    const result = { content: [{ type: "text" as const, text: "hello" }] };
    expect(appendVersionNote(result, null)).toBe(result);
  });

  it("appends the note to the first text block, leaving the original text intact", () => {
    const result = { content: [{ type: "text" as const, text: "hello" }] };
    const withNote = appendVersionNote(result, "a note");

    expect(withNote.content).toEqual([{ type: "text", text: "hello\n\na note" }]);
  });

  it("preserves isError and any additional content blocks", () => {
    const result = {
      isError: true,
      content: [
        { type: "text" as const, text: "boom" },
        { type: "text" as const, text: "second block" },
      ],
    };
    const withNote = appendVersionNote(result, "a note");

    expect(withNote.isError).toBe(true);
    expect(withNote.content).toEqual([
      { type: "text", text: "boom\n\na note" },
      { type: "text", text: "second block" },
    ]);
  });
});
