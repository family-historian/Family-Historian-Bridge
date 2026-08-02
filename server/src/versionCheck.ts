import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  describeBridgeConnectionError,
  interpretBridgeResponse,
  textResult,
} from "./bridgeResponse.js";

// Bridge/server version-mismatch detection (issue #45): resolved design at
// https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/45#issuecomment-354.
//
// A dedicated VERSION request/response is sent as its own connection ahead of every
// LUA/LUA_RO request (see bridgeClient.ts's queryBridgeVersion and
// bridge/requestFraming.lua) — this module is the server-side half: comparing the two
// version strings, interpreting the Bridge's raw reply (including an older Bridge that
// doesn't know the VERSION verb at all), and deciding what a caller (run_lua /
// describe_project) should do about it.

export type VersionMismatchSeverity = "match" | "warn" | "block";

// Same rule as bridge/versionCompare.lua's compare(): identical strings match; a differing
// major version blocks (inert while this project is pre-1.0, since major is 0 on both
// sides today); anything else that differs, including an unparseable version on either
// side, only warns.
function majorOf(version: string): number | null {
  const match = version.match(/^(\d+)\./);
  return match ? Number(match[1]) : null;
}

export function compareVersions(bridgeVersion: string, serverVersion: string): VersionMismatchSeverity {
  if (bridgeVersion === serverVersion) return "match";

  const bridgeMajor = majorOf(bridgeVersion);
  const serverMajor = majorOf(serverVersion);
  if (bridgeMajor === null || serverMajor === null) return "warn";

  return bridgeMajor !== serverMajor ? "block" : "warn";
}

export type VersionCheckOutcome =
  | { status: "match" }
  | { status: "warn"; bridgeVersion: string; serverVersion: string }
  | { status: "block"; bridgeVersion: string; serverVersion: string }
  // An older Bridge that predates this feature doesn't recognize the VERSION verb and
  // rejects it with the same malformed-framing error every unrecognized header gets
  // (bridge/requestFraming.lua) — this is itself the "stale Bridge" signal issue #45 exists
  // to catch, so it's treated as a distinct, expected case rather than a parse failure.
  | { status: "unsupported" }
  | { status: "unparseable" };

const OLD_BRIDGE_REJECTION_MESSAGE = "expected STOP or LUA <n>";

export function interpretVersionResponse(raw: string, serverVersion: string): VersionCheckOutcome {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { status: "unparseable" };
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { status: "unparseable" };
  }
  const obj = parsed as Record<string, unknown>;

  if (obj.error === OLD_BRIDGE_REJECTION_MESSAGE) {
    return { status: "unsupported" };
  }

  if (typeof obj.version === "string") {
    const severity = compareVersions(obj.version, serverVersion);
    if (severity === "match") return { status: "match" };
    return { status: severity, bridgeVersion: obj.version, serverVersion };
  }

  return { status: "unparseable" };
}

export type CheckBridgeVersionResult =
  // reason distinguishes why block is set: "connection-error" means the VERSION exchange
  // itself couldn't reach the Bridge (install_fh_plugin's resolvePluginsFolder treats this
  // one differently — its own subsequent Bridge call has a tailored no-Session message and
  // an explicit-path fallback, so it defers to that rather than surfacing this generic one
  // twice); "version-mismatch" is a genuine incompatibility every caller should stop for.
  | { block: CallToolResult; reason: "connection-error" | "version-mismatch" }
  | { block: null; note: string | null };

/**
 * Runs the VERSION exchange and decides what a tool handler should do: `block` is set to a
 * ready-to-return CallToolResult when the script must not run at all (a genuine major-
 * version mismatch, or the version check's own connection failing the same way the real
 * request would); otherwise `block` is null and `note` is either null (versions match) or a
 * short message to surface alongside the real request's own result.
 */
export async function checkBridgeVersion(
  queryBridgeVersion: () => Promise<string>,
  serverVersion: string,
): Promise<CheckBridgeVersionResult> {
  let raw: string;
  try {
    raw = await queryBridgeVersion();
  } catch (err) {
    return { block: describeBridgeConnectionError(err), reason: "connection-error" };
  }

  const outcome = interpretVersionResponse(raw, serverVersion);

  switch (outcome.status) {
    case "match":
      return { block: null, note: null };
    case "warn":
      return {
        block: null,
        note: `Note: the Bridge plugin's version (${outcome.bridgeVersion}) does not match the server's (${serverVersion}). This usually just means one side was updated more recently than the other.`,
      };
    case "block":
      return {
        block: textResult(
          `Bridge and server have incompatible major versions (Bridge v${outcome.bridgeVersion} vs server v${serverVersion}) — refusing to run the script. Tell the user to update the Bridge plugin and/or the server so their major versions match.`,
          true,
        ),
        reason: "version-mismatch",
      };
    case "unsupported":
      return {
        block: null,
        note: "Note: the running Bridge plugin doesn't support version reporting, so it's likely older than this server. Consider reinstalling the Bridge plugin to match.",
      };
    case "unparseable":
      return {
        block: null,
        note: "Note: could not determine the Bridge plugin's version (unexpected response to the version check) — continuing anyway.",
      };
  }
}

/** Appends a version-check note (if any) to a tool result's first text block. */
export function appendVersionNote(result: CallToolResult, note: string | null): CallToolResult {
  if (!note) return result;
  const first = result.content[0];
  if (!first || first.type !== "text") return result;

  return {
    ...result,
    content: [{ type: "text", text: `${first.text}\n\n${note}` }, ...result.content.slice(1)],
  };
}

export interface BridgeScriptDeps {
  runLuaOnBridge: (script: string) => Promise<string>;
  queryBridgeVersion: () => Promise<string>;
}

/**
 * Shared "check the Bridge's version, then run a script and interpret its response" flow —
 * used by both run_lua and describe_project, the two tools that send a script through
 * runLuaOnBridge and hand the raw response to interpretBridgeResponse unchanged.
 * install_fh_plugin's Bridge call has a different shape (it parses the response as a plain
 * JSON value itself, plus a no-Session/explicit-path fallback the other two don't have) and
 * calls checkBridgeVersion directly instead of going through this.
 */
export async function runVersionCheckedScript(
  deps: BridgeScriptDeps,
  serverVersion: string,
  script: string,
): Promise<CallToolResult> {
  const versionCheck = await checkBridgeVersion(deps.queryBridgeVersion, serverVersion);
  if (versionCheck.block) return versionCheck.block;

  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(script);
  } catch (err) {
    return describeBridgeConnectionError(err);
  }

  return appendVersionNote(interpretBridgeResponse(raw), versionCheck.note);
}
