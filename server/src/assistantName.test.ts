import { describe, expect, it } from "vitest";
import { resolveAssistantName, sanitiseAssistantName } from "./assistantName.js";

describe("sanitiseAssistantName", () => {
  it("returns null for empty/blank/undefined", () => {
    expect(sanitiseAssistantName(undefined)).toBeNull();
    expect(sanitiseAssistantName("   ")).toBeNull();
  });

  it("collapses whitespace and control characters, trims, and caps at 40", () => {
    expect(sanitiseAssistantName("  Claude\n\tCode  ")).toBe("Claude Code");
    expect(sanitiseAssistantName("x".repeat(100))).toHaveLength(40);
  });
});

describe("resolveAssistantName", () => {
  it("prefers the agent-supplied name over clientInfo", () => {
    expect(resolveAssistantName("Codex", "mcp-client")).toBe("Codex");
  });

  it("falls back to clientInfo, then null", () => {
    expect(resolveAssistantName(undefined, "codex-mcp-client")).toBe("codex-mcp-client");
    expect(resolveAssistantName("", undefined)).toBeNull();
  });
});
