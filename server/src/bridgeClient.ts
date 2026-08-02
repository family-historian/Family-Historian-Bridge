import net from "node:net";

// Matches the Bridge's hardcoded port (bridge/bridge.fh_lua) — see the spec's
// "Port" decision: not configurable in Stage 1.
export const DEFAULT_BRIDGE_HOST = "127.0.0.1";
export const DEFAULT_BRIDGE_PORT = 8734;

/** Thrown when the Bridge isn't listening — i.e. no FH Session is running. */
export class BridgeConnectionRefusedError extends Error {
  constructor() {
    super("Connection refused — no FH Bridge Session is listening");
    this.name = "BridgeConnectionRefusedError";
  }
}

export interface RunLuaOnBridgeOptions {
  host?: string;
  port?: number;
  timeoutMs?: number;
  /**
   * Forces the Bridge to run this script under its Read-only sandbox regardless of the
   * Session's own Access mode, via the LUA_RO request form (see bridge/requestFraming.lua
   * and issue #16). Used exclusively by describeProjectTool.ts — run_lua's own requests
   * always leave this unset, so they use the Session's actual Access mode.
   */
  forceReadOnly?: boolean;
}

/**
 * Opens a connection to the Bridge, sends `payload` verbatim, and resolves with the raw
 * response body once the Bridge closes the connection. Shared low-level plumbing for both
 * the LUA/LUA_RO framing (runLuaOnBridge) and the bodyless VERSION framing
 * (queryBridgeVersion) — connect/timeout/error handling is identical between them, only
 * the bytes sent differ.
 */
function sendRawToBridge(payload: Buffer, options: RunLuaOnBridgeOptions = {}): Promise<string> {
  const host = options.host ?? DEFAULT_BRIDGE_HOST;
  const port = options.port ?? DEFAULT_BRIDGE_PORT;
  const timeoutMs = options.timeoutMs ?? 30_000;

  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    const chunks: Buffer[] = [];
    let settled = false;

    const fail = (err: Error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(err);
    };

    const succeed = (value: string) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    socket.setTimeout(timeoutMs, () => {
      fail(new Error(`Timed out waiting for the FH Bridge after ${timeoutMs}ms`));
    });

    socket.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ECONNREFUSED") {
        fail(new BridgeConnectionRefusedError());
      } else {
        fail(err);
      }
    });

    socket.on("connect", () => {
      socket.end(payload);
    });

    socket.on("data", (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, "utf8"));
    });

    socket.on("close", () => {
      succeed(Buffer.concat(chunks).toString("utf8"));
    });
  });
}

/**
 * Sends a Lua script to the Bridge under the LUA <n> / LUA_RO <n> length-prefixed framing
 * (see bridge/bridge.fh_lua, bridge/requestFraming.lua) and resolves with the raw response
 * body once the Bridge closes the connection. Does not parse the response — the caller
 * (the run_lua / describe_project tool) decides how to interpret it.
 */
export function runLuaOnBridge(
  script: string,
  options: RunLuaOnBridgeOptions = {},
): Promise<string> {
  const scriptBytes = Buffer.from(script, "utf8");
  const verb = options.forceReadOnly ? "LUA_RO" : "LUA";
  const header = Buffer.from(`${verb} ${scriptBytes.byteLength}\n`, "utf8");
  return sendRawToBridge(Buffer.concat([header, scriptBytes]), options);
}

/**
 * Sends this server's own version to the Bridge under the bodyless VERSION <server-version>
 * framing (see bridge/requestFraming.lua, issue #45) and resolves with the Bridge's raw
 * response — a `{"version": "..."}` JSON object from a Bridge that supports this, or the
 * older `{"error": "expected STOP or LUA <n>"}` rejection from one that predates it. Sent
 * as its own connection ahead of every LUA/LUA_RO request, not cached — the server has no
 * other way to observe when a Bridge Session actually started or restarted.
 */
export function queryBridgeVersion(
  serverVersion: string,
  options: RunLuaOnBridgeOptions = {},
): Promise<string> {
  const header = Buffer.from(`VERSION ${serverVersion}\n`, "utf8");
  return sendRawToBridge(header, options);
}
