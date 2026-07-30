import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";

// Shared response handling for any tool that sends a script to the Bridge over
// runLuaOnBridge and gets back its raw wire response — currently run_lua and
// describe_project. Both go through the same socket/JSON-framing protocol, so a
// connection failure or a malformed response means the same thing regardless of which
// tool triggered it.

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text }], isError };
}

// bridge_prototype_v2.fh_lua (an earlier, superseded prototype plugin) answers any
// connection on the same port with a "PROJECT_NAME: ...\n...\nEND" handshake block
// instead of the current Bridge's JSON framing. Left running, it silently steals the
// port from bridge.fh_lua and every call fails with a raw JSON-parse error that doesn't
// name the actual cause — beta feedback, 2026-07-29.
function isStalePrototypeHandshake(raw: string): boolean {
  const trimmed = raw.trim();
  return trimmed.startsWith("PROJECT_NAME:") && trimmed.endsWith("END");
}

function isLuaErrorShape(value: unknown): value is { error: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.keys(value).length === 1 &&
    typeof (value as Record<string, unknown>).error === "string"
  );
}

/** Maps a thrown error from runLuaOnBridge to the tool result Claude should see. */
export function describeBridgeConnectionError(err: unknown): CallToolResult {
  if (err instanceof BridgeConnectionRefusedError) {
    return textResult(
      "No FH Bridge Session is running — ask the user to click Start in the FH Bridge dialog before retrying.",
      true,
    );
  }
  const message = err instanceof Error ? err.message : String(err);
  return textResult(`Bridge communication error: ${message}`, true);
}

// A script's own error path (compile error, runtime error) is wrapped by the Bridge
// as exactly {"error": "<message>"} — see bridge/runScript.lua. A script that
// legitimately returns a single-key {error: "..."} object as its own data would be
// (mis)read the same way; accepted as a rare edge case of this wire shape rather than
// a reason to redesign an already-shipped, manually-verified protocol (ticket #2).
export function interpretBridgeResponse(raw: string): CallToolResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    if (isStalePrototypeHandshake(raw)) {
      return textResult(
        "This is the old bridge_prototype_v2 plugin answering on port 8734, not the current Bridge. Tell the user to Stop and close its dialog (it's modal, so it blocks Tools -> Plugins until closed), then load and Run bridge.fh_lua instead.",
        true,
      );
    }
    return textResult(
      `Bridge returned a response that could not be parsed as JSON: ${raw}`,
      true,
    );
  }

  if (isLuaErrorShape(parsed)) {
    return textResult(`Script error: ${parsed.error}`, true);
  }

  return textResult(JSON.stringify(parsed));
}
