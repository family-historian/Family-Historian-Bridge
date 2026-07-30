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
 * Sends a Lua script to the Bridge under the LUA <n> / LUA_RO <n> length-prefixed framing
 * (see bridge/bridge.fh_lua, bridge/requestFraming.lua) and resolves with the raw response
 * body once the Bridge closes the connection. Does not parse the response — the caller
 * (the run_lua / describe_project tool) decides how to interpret it.
 */
export function runLuaOnBridge(
  script: string,
  options: RunLuaOnBridgeOptions = {},
): Promise<string> {
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
      const scriptBytes = Buffer.from(script, "utf8");
      const verb = options.forceReadOnly ? "LUA_RO" : "LUA";
      const header = Buffer.from(`${verb} ${scriptBytes.byteLength}\n`, "utf8");
      socket.end(Buffer.concat([header, scriptBytes]));
    });

    socket.on("data", (chunk) => {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, "utf8"));
    });

    socket.on("close", () => {
      succeed(Buffer.concat(chunks).toString("utf8"));
    });
  });
}
