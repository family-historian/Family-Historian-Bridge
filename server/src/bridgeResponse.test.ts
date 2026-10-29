import { afterEach, describe, expect, it, vi } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import {
  describeBridgeConnectionError,
  interpretBridgeResponse,
  textResult,
} from "./bridgeResponse.js";

describe("textResult", () => {
  it("wraps text as a non-error CallToolResult by default", () => {
    expect(textResult("hello")).toEqual({
      content: [{ type: "text", text: "hello" }],
      isError: false,
    });
  });

  it("sets isError when passed true", () => {
    expect(textResult("bad", true)).toEqual({
      content: [{ type: "text", text: "bad" }],
      isError: true,
    });
  });
});

describe("describeBridgeConnectionError", () => {
  afterEach(() => vi.restoreAllMocks());

  it("tells Claude not to retry a generic error and to report the message to the user", () => {
    const result = describeBridgeConnectionError(new Error("socket reset"));
    const text = result.content[0]?.text ?? "";
    expect(text).toContain("Bridge communication error: socket reset");
    expect(text).toMatch(/do not retry/i);
    expect(text).toMatch(/report .*to the user/i);
  });

  it("logs each failure to stderr with the tool name", () => {
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    describeBridgeConnectionError(new BridgeConnectionRefusedError(), "run_lua");
    describeBridgeConnectionError(new Error("socket reset"), "describe_project");
    expect(write).toHaveBeenCalledTimes(2);
    expect(String(write.mock.calls[0]?.[0])).toContain("tool=run_lua");
    expect(String(write.mock.calls[1]?.[0])).toContain("tool=describe_project");
  });

  it("gives a specific 'no Session running' message for BridgeConnectionRefusedError", () => {
    const result = describeBridgeConnectionError(new BridgeConnectionRefusedError());
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain("No FH Bridge Session is running");
  });

  it("wraps a generic Error's message", () => {
    const result = describeBridgeConnectionError(new Error("socket reset"));
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain("Bridge communication error: socket reset");
  });

  it("stringifies a thrown non-Error value", () => {
    const result = describeBridgeConnectionError("plain string failure");
    expect(result.content[0]?.text).toContain("Bridge communication error: plain string failure");
  });
});

describe("interpretBridgeResponse", () => {
  it("returns the parsed JSON, stringified, as a non-error result for an ordinary response", () => {
    const result = interpretBridgeResponse('{"individuals": 42}');
    expect(result.isError).toBe(false);
    expect(result.content[0]?.text).toBe('{"individuals":42}');
  });

  it("passes through a JSON array response unchanged", () => {
    const result = interpretBridgeResponse("[1,2,3]");
    expect(result.isError).toBe(false);
    expect(result.content[0]?.text).toBe("[1,2,3]");
  });

  it("reports a Lua script error shape as an error, without an undo hint", () => {
    const result = interpretBridgeResponse('{"error": "boom"}');
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toBe("Script error: boom");
  });

  it("adds the undo hint when writeSessionRolledBack is true", () => {
    const result = interpretBridgeResponse(
      '{"error": "boom", "writeSessionRolledBack": true}',
    );
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain("Script error: boom");
    expect(result.content[0]?.text).toContain("click Yes to undo");
  });

  it("does not treat an {error, ...unrelated} shape as a Lua error", () => {
    // Only `error` alone, or `error` + `writeSessionRolledBack: true`, are recognized as
    // the Lua error wire shape (see docs/adr/0005) — a script that legitimately returns an
    // object with an `error` field plus some other key is passed through as ordinary data.
    const result = interpretBridgeResponse('{"error": "not really", "otherField": 1}');
    expect(result.isError).toBe(false);
    expect(result.content[0]?.text).toBe('{"error":"not really","otherField":1}');
  });

  it("reports an unparseable, non-handshake response as a JSON parse error", () => {
    const result = interpretBridgeResponse("not json at all");
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toBe(
      "Bridge returned a response that could not be parsed as JSON: not json at all",
    );
  });

  it("recognizes the stale bridge_prototype_v2 handshake and names the fix", () => {
    const result = interpretBridgeResponse("PROJECT_NAME: Smith Family\nsome details\nEND");
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain("bridge_prototype_v2");
    expect(result.content[0]?.text).toContain("bridge.fh_lua");
  });
});

describe("interpretBridgeResponse mergeIntoResult (issue #109)", () => {
  it("merges extra fields into a successful object response", () => {
    const result = interpretBridgeResponse('{"individuals":42}', {
      bridgeState: { versionStatus: "match" },
    });
    expect(result.isError).toBe(false);
    expect(result.content[0]?.text).toBe(
      '{"individuals":42,"bridgeState":{"versionStatus":"match"}}',
    );
  });

  it("does not merge extra fields into a Lua script error result", () => {
    const result = interpretBridgeResponse('{"error": "boom"}', {
      bridgeState: { versionStatus: "match" },
    });
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toBe("Script error: boom");
  });

  it("does not merge extra fields into an unparseable-response error", () => {
    const result = interpretBridgeResponse("not json at all", {
      bridgeState: { versionStatus: "match" },
    });
    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).not.toContain("bridgeState");
  });

  it("leaves the response unchanged when no extra fields are given", () => {
    const result = interpretBridgeResponse('{"individuals":42}');
    expect(result.content[0]?.text).toBe('{"individuals":42}');
  });
});

describe("interpretBridgeResponse reshape", () => {
  it("reshapes a successful object result before mergeIntoResult, which still wins", () => {
    const result = interpretBridgeResponse(
      '{"a":1,"b":2}',
      { b: "merged" },
      (r) => ({ ...r, a: (r.a as number) + 10, b: "reshaped", c: true }),
    );
    expect(JSON.parse((result.content[0] as { text: string }).text)).toEqual({ a: 11, b: "merged", c: true });
  });

  it("never reshapes an error, an array or a non-object result", () => {
    let calls = 0;
    const reshape = (r: Record<string, unknown>) => {
      calls += 1;
      return r;
    };
    expect(interpretBridgeResponse('{"error":"boom"}', undefined, reshape).isError).toBe(true);
    interpretBridgeResponse("[1,2]", undefined, reshape);
    interpretBridgeResponse("42", undefined, reshape);
    expect(calls).toBe(0);
  });
});
