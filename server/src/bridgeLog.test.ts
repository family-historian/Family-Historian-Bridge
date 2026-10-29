import { afterEach, describe, expect, it, vi } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import { logBridgeFailure } from "./bridgeLog.js";
import { SERVER_ROOT, SERVER_VERSION } from "./serverVersion.js";

afterEach(() => vi.restoreAllMocks());

function captureStderr(): string[] {
  const lines: string[] = [];
  vi.spyOn(process.stderr, "write").mockImplementation((chunk: string | Uint8Array) => {
    lines.push(String(chunk));
    return true;
  });
  return lines;
}

describe("logBridgeFailure", () => {
  it("writes one newline-terminated stderr line with kind, tool, error class, host:port, version and path", () => {
    const lines = captureStderr();
    logBridgeFailure("connection-failure", new BridgeConnectionRefusedError(), "run_lua");
    expect(lines).toHaveLength(1);
    const line = lines[0]!;
    expect(line.endsWith("\n")).toBe(true);
    expect(line.trimEnd().split("\n")).toHaveLength(1);
    expect(line).toContain("connection-failure");
    expect(line).toContain("tool=run_lua");
    expect(line).toContain("BridgeConnectionRefusedError");
    expect(line).toContain("127.0.0.1:8734");
    expect(line).toContain(`server=${SERVER_VERSION}`);
    expect(line).toContain(`path=${SERVER_ROOT}`);
  });

  it("collapses newlines in the error message so the log stays one line per failure", () => {
    const lines = captureStderr();
    logBridgeFailure("communication-error", new Error("a\nb\r\nc"), "describe_project");
    expect(lines[0]!.trimEnd()).not.toMatch(/[\r\n]/);
  });

  it("copes with a non-Error throw and an unknown tool", () => {
    const lines = captureStderr();
    logBridgeFailure("communication-error", "plain", undefined);
    expect(lines[0]).toContain("tool=unknown");
    expect(lines[0]).toContain("plain");
  });

  it("logs a version block without an error object", () => {
    const lines = captureStderr();
    logBridgeFailure("version-block", undefined, "run_lua", "Bridge v1.0.0 vs server v2.0.0");
    expect(lines[0]).toContain("version-block");
    expect(lines[0]).toContain("Bridge v1.0.0 vs server v2.0.0");
  });
});
