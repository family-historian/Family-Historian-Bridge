import { DEFAULT_BRIDGE_HOST, DEFAULT_BRIDGE_PORT } from "./bridgeClient.js";
import { SERVER_ROOT, SERVER_VERSION } from "./serverVersion.js";

export type BridgeFailureKind = "connection-failure" | "version-block" | "communication-error";

// Claude Desktop's MCP log records only what the server prints to stderr, so this is the
// only place a Bridge failure becomes diagnosable there. Never pass script text or tree
// data in: just the error class/message (socket-level, never script-derived), the tool
// name and caller-supplied detail such as a version pair.
export function logBridgeFailure(
  kind: BridgeFailureKind,
  err: unknown,
  tool: string | undefined,
  detail?: string,
): void {
  const errorText =
    err === undefined
      ? ""
      : err instanceof Error
        ? ` error=${err.name}: ${err.message}`
        : ` error=${typeof err}: ${JSON.stringify(err)}`;
  const line =
    `[fh-mcp-bridge] ${kind} tool=${tool ?? "unknown"}${errorText}` +
    `${detail ? ` ${detail}` : ""} bridge=${DEFAULT_BRIDGE_HOST}:${DEFAULT_BRIDGE_PORT}` +
    ` server=${SERVER_VERSION} path=${SERVER_ROOT}`;
  process.stderr.write(`${line.replace(/\s*[\r\n]+\s*/g, " ")}\n`);
}
