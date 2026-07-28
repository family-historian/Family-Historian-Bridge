import net from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import {
  BridgeConnectionRefusedError,
  runLuaOnBridge,
} from "./bridgeClient.js";

// A fake Bridge: speaks the same STOP/LUA<n> request framing and send-then-close
// response shape as the real bridge.fh_lua, without needing FH itself. This is the
// spec's one automatable seam for the MCP-server side of the protocol.
function startFakeBridge(
  handleScript: (script: string) => string,
): Promise<{ port: number; close: () => Promise<void> }> {
  return new Promise((resolve) => {
    const server = net.createServer((socket) => {
      let buffered = Buffer.alloc(0);
      let expectedBytes: number | null = null;

      socket.on("data", (chunk) => {
        const chunkBuf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, "utf8");
        buffered = Buffer.concat([buffered, chunkBuf]);

        if (expectedBytes === null) {
          const newlineIndex = buffered.indexOf("\n");
          if (newlineIndex === -1) return;

          const header = buffered.subarray(0, newlineIndex).toString("utf8");
          buffered = buffered.subarray(newlineIndex + 1);

          const match = header.match(/^LUA (\d+)$/);
          if (!match) {
            socket.end(JSON.stringify({ error: "expected STOP or LUA <n>" }));
            return;
          }
          expectedBytes = Number(match[1]);
        }

        if (expectedBytes !== null && buffered.byteLength >= expectedBytes) {
          const script = buffered.subarray(0, expectedBytes).toString("utf8");
          socket.end(handleScript(script));
        }
      });
    });

    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        throw new Error("expected an AddressInfo from a TCP server");
      }
      resolve({
        port: address.port,
        close: () => new Promise((res) => server.close(() => res())),
      });
    });
  });
}

describe("runLuaOnBridge", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  it("sends a correctly-framed request and returns the response body", async () => {
    const { port, close } = await startFakeBridge(
      () => '{"ok":true,"echoed":42}',
    );
    cleanup = close;

    const result = await runLuaOnBridge("return {ok=true, echoed=42}", {
      port,
    });

    expect(result).toBe('{"ok":true,"echoed":42}');
  });

  it("frames the request using the byte length, not the character length, of the script", async () => {
    // "É" is 1 character but 2 UTF-8 bytes — a byte-length bug would truncate this.
    const script = 'return "É café"';
    let receivedScript: string | undefined;
    const { port, close } = await startFakeBridge((s) => {
      receivedScript = s;
      return '"ok"';
    });
    cleanup = close;

    await runLuaOnBridge(script, { port });

    expect(receivedScript).toBe(script);
  });

  it("surfaces a Lua-side error response body unchanged (the tool layer interprets it)", async () => {
    const { port, close } = await startFakeBridge(
      () => '{"error":"deliberate test failure"}',
    );
    cleanup = close;

    const result = await runLuaOnBridge("error('deliberate test failure')", {
      port,
    });

    expect(result).toBe('{"error":"deliberate test failure"}');
  });

  it("throws BridgeConnectionRefusedError when nothing is listening (no Session running)", async () => {
    // Bind to get a genuinely free port, then close it immediately — connecting to it
    // afterward reliably yields ECONNREFUSED on loopback, simulating "no Session".
    const { port, close } = await startFakeBridge(() => "unused");
    await close();

    await expect(runLuaOnBridge("return 1", { port })).rejects.toBeInstanceOf(
      BridgeConnectionRefusedError,
    );
  });

  it("rejects with a timeout error if the Bridge never responds", async () => {
    const openSockets: net.Socket[] = [];
    const server = net.createServer((socket) => {
      // Accept the connection but never write anything back. Still needs an error
      // listener — the client's timeout-triggered destroy() resets this socket, and an
      // unhandled 'error' on a server-side socket would otherwise crash the process.
      socket.on("error", () => {});
      openSockets.push(socket);
    });
    await new Promise<void>((res) => server.listen(0, "127.0.0.1", res));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("expected an AddressInfo from a TCP server");
    }
    cleanup = () =>
      new Promise((res) => {
        for (const socket of openSockets) socket.destroy();
        server.close(() => res());
      });

    await expect(
      runLuaOnBridge("return 1", { port: address.port, timeoutMs: 50 }),
    ).rejects.toThrow(/timed out/i);
  });
});
