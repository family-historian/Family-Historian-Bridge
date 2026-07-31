# install_fh_plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new MCP tool, `install_fh_plugin`, that writes a plugin `author_fh_plugin` generated directly into FH's Plugins folder on the user's explicit request, with automatic never-overwrite `V1`/`V2`/... versioning — closing out Forgejo issue #24.

**Architecture:** New tool in `server/src/installFhPluginTool.ts`, registered in `server/src/index.ts` alongside the other three tools. It resolves the live Plugins-folder path through the existing Bridge socket (`runLuaOnBridge`, reusing `bridgeClient.ts`/`bridgeResponse.ts` exactly as `describeProjectTool.ts` and `runLuaTool.ts` already do), then writes the file via injected `fs` deps — the same dependency-injection pattern `fhHelpUpdate.ts` already uses for its own file writes. No changes to `bridge/` (Lua side) or to `run_lua`'s sandbox at all.

**Tech Stack:** TypeScript, `@modelcontextprotocol/sdk`, `zod` for input schemas, `vitest` for tests (`npm test` runs `vitest run` from `server/`).

## Global Constraints

- Full design rationale for every decision below is recorded on [Forgejo issue #24](https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/issues/24) (comment) and will additionally live in `docs/adr/0008-install-fh-plugin-staged-write.md` (Task 4).
- `author_fh_plugin` stays text-only — ADR 0004 is unchanged, not reversed. `install_fh_plugin` is a second, separate, explicitly-invoked tool.
- No changes to `bridge/sandbox.lua` or `authorFhPluginTool.ts`'s `SANDBOX_EXCLUDED_FUNCTIONS` list.
- Follow existing per-tool file layout: one `<name>Tool.ts` + one `<name>Tool.test.ts`, deps-injected via a `<Name>Deps` interface with a `defaultDeps` constant, matching `describeProjectTool.ts`/`runLuaTool.ts`/`fhHelpUpdate.ts`.
- Per this repo's own test convention (confirmed: none of `fhHelpUpdate.test.ts`, `describeProjectTool.test.ts`, `authorFhPluginTool.test.ts` test their `makeDefault*Deps` factory's real `fs`/network wiring), do not write a test that mocks `node:fs/promises` for the default deps — only the pure logic functions get unit tests, called with hand-rolled deps.
- Run `cd server && npm test` after every implementation step; run `npm run typecheck` before each commit.

---

### Task 1: Plugins-folder path resolution

**Files:**
- Create: `server/src/installFhPluginTool.ts`
- Test: `server/src/installFhPluginTool.test.ts`

**Interfaces:**
- Consumes: `runLuaOnBridge` / `RunLuaOnBridgeOptions` from `server/src/bridgeClient.ts` (`BridgeConnectionRefusedError` too), `describeBridgeConnectionError` / `interpretBridgeResponse` from `server/src/bridgeResponse.ts` — both already exist, unchanged.
- Produces (for Task 2 to consume, same file):
  - `export const GET_PLUGINS_APP_DATA_FOLDER_SCRIPT: string`
  - `export interface InstallFhPluginDeps { runLuaOnBridge: (script: string, options?: RunLuaOnBridgeOptions) => Promise<string>; readdir: (dirPath: string) => Promise<string[]>; writeFile: (filePath: string, content: string) => Promise<void>; }`
  - `resolvePluginsFolder(deps: InstallFhPluginDeps, explicitPath: string | undefined): Promise<{ path: string } | { errorResult: CallToolResult }>` (module-private, not exported — Task 2's `handleInstallFhPlugin` calls it directly since it lives in the same file)

- [ ] **Step 1: Write the failing tests**

Create `server/src/installFhPluginTool.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { BridgeConnectionRefusedError } from "./bridgeClient.js";
import type { InstallFhPluginDeps } from "./installFhPluginTool.js";
import { GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, handleInstallFhPlugin } from "./installFhPluginTool.js";

const PLUGIN_SOURCE = `--[[
@Title: Surname Census
@Author: Claude MCP
@Version: 1.0
]]

fhOutputResultSetColumn("Surname", "text", {}, 0)`;

function makeDeps(overrides: Partial<InstallFhPluginDeps> = {}): InstallFhPluginDeps {
  return {
    runLuaOnBridge: async () => JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8"),
    readdir: async () => [],
    writeFile: async () => {},
    ...overrides,
  };
}

describe("resolvePluginsFolder (via handleInstallFhPlugin)", () => {
  it("queries CI_APP_DATA_FOLDER read-only and appends \\Plugins to the resolved path", async () => {
    let scriptSent: string | undefined;
    let forcedReadOnly: boolean | undefined;
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async (script, options) => {
          scriptSent = script;
          forcedReadOnly = options?.forceReadOnly;
          return JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8");
        },
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(scriptSent).toBe(GET_PLUGINS_APP_DATA_FOLDER_SCRIPT);
    expect(forcedReadOnly).toBe(true);
    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("trims a trailing separator from the live-queried app data folder before appending \\Plugins", async () => {
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => JSON.stringify("C:\\ProgramData\\Calico Pie\\Family Historian 8\\"),
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("falls back to the explicit path param, used as-is, when no Bridge Session is running", async () => {
    let writtenPath: string | undefined;
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE, path: "C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins" },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(result.isError).toBeFalsy();
    expect(writtenPath).toBe("C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surname Census V1.fh_lua");
  });

  it("errors telling the user to click Start or supply path, when no Session is running and no path given", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new BridgeConnectionRefusedError();
        },
      }),
    );

    expect(result.isError).toBe(true);
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/click start/i);
    expect(text).toMatch(/path/i);
  });

  it("surfaces an unexpected bridge communication error without retrying", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => {
          throw new Error("ECONNRESET");
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("ECONNRESET");
  });

  it("surfaces a Lua-side error from the live path query as a tool error", async () => {
    const result = await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        runLuaOnBridge: async () => '{"error":"boom"}',
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toContain("boom");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && npx vitest run src/installFhPluginTool.test.ts`
Expected: FAIL — `installFhPluginTool.ts` does not exist yet (`Cannot find module './installFhPluginTool.js'`).

- [ ] **Step 3: Write the implementation**

Create `server/src/installFhPluginTool.ts`:

```typescript
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  BridgeConnectionRefusedError,
  runLuaOnBridge as defaultRunLuaOnBridge,
  type RunLuaOnBridgeOptions,
} from "./bridgeClient.js";
import { describeBridgeConnectionError, interpretBridgeResponse } from "./bridgeResponse.js";

export interface InstallFhPluginDeps {
  runLuaOnBridge: (script: string, options?: RunLuaOnBridgeOptions) => Promise<string>;
  readdir: (dirPath: string) => Promise<string[]>;
  writeFile: (filePath: string, content: string) => Promise<void>;
}

function textResult(text: string, isError = false): CallToolResult {
  return { content: [{ type: "text", text }], isError };
}

// Already unrestricted in bridge/sandbox.lua (no exclusion needed) — see
// docs/adr/0008-install-fh-plugin-staged-write.md decision 4.
export const GET_PLUGINS_APP_DATA_FOLDER_SCRIPT = `return fhGetContextInfo("CI_APP_DATA_FOLDER")`;

function joinPluginsFolder(appDataFolder: string): string {
  return `${appDataFolder.replace(/[\\/]+$/, "")}\\Plugins`;
}

async function resolvePluginsFolder(
  deps: InstallFhPluginDeps,
  explicitPath: string | undefined,
): Promise<{ path: string } | { errorResult: CallToolResult }> {
  let raw: string;
  try {
    raw = await deps.runLuaOnBridge(GET_PLUGINS_APP_DATA_FOLDER_SCRIPT, { forceReadOnly: true });
  } catch (err) {
    if (err instanceof BridgeConnectionRefusedError) {
      if (explicitPath) {
        return { path: explicitPath };
      }
      return {
        errorResult: textResult(
          "No FH Bridge Session is running, so the Plugins folder location can't be looked up live. Either ask the user to click Start in the FH Bridge dialog and retry, or ask them to confirm their Plugins folder path themselves (see docs/user-guide.md's \"Where FH's Plugins folder is\" — it differs by FH version) and pass it as the path parameter.",
          true,
        ),
      };
    }
    return { errorResult: describeBridgeConnectionError(err) };
  }

  const bridgeResult = interpretBridgeResponse(raw);
  if (bridgeResult.isError) {
    return { errorResult: bridgeResult };
  }

  const appDataFolder = JSON.parse((bridgeResult.content[0] as { text: string }).text) as string;
  return { path: joinPluginsFolder(appDataFolder) };
}

// Placeholder so Task 1's tests compile and pass — Task 2 replaces this with the full
// title-parsing/versioning/write implementation.
export async function handleInstallFhPlugin(
  input: { pluginSource: string; path?: string },
  deps: InstallFhPluginDeps,
): Promise<CallToolResult> {
  const resolved = await resolvePluginsFolder(deps, input.path);
  if ("errorResult" in resolved) {
    return resolved.errorResult;
  }

  const titleMatch = input.pluginSource.match(/^@Title:[ \t]*(.*)$/m);
  const base = (titleMatch?.[1].trim() || "plugin").replace(/[<>:"/\\|?*\x00-\x1F]/g, "_");
  const filename = `${base} V1.fh_lua`;
  const fullPath = `${resolved.path}\\${filename}`;

  await deps.writeFile(fullPath, input.pluginSource);
  return textResult(`Installed as "${filename}" in FH's Plugins folder (${resolved.path}).`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && npx vitest run src/installFhPluginTool.test.ts`
Expected: PASS (6 tests)

- [ ] **Step 5: Typecheck and commit**

Run: `cd server && npm run typecheck`
Expected: no errors

```bash
git add server/src/installFhPluginTool.ts server/src/installFhPluginTool.test.ts
git commit -m "feat: resolve FH Plugins folder path for install_fh_plugin (issue #24)"
```

---

### Task 2: Title versioning, footer stripping, and never-overwrite write

**Files:**
- Modify: `server/src/installFhPluginTool.ts` (replace Task 1's placeholder `handleInstallFhPlugin` body)
- Test: `server/src/installFhPluginTool.test.ts` (append)

**Interfaces:**
- Consumes: `InstallFhPluginDeps`, `resolvePluginsFolder`, `textResult` from Task 1 (same file).
- Produces: `handleInstallFhPlugin` gains its final behavior (versioning, title rewrite, footer stripping) — signature unchanged from Task 1: `(input: { pluginSource: string; path?: string }, deps: InstallFhPluginDeps) => Promise<CallToolResult>`.

- [ ] **Step 1: Write the failing tests**

Append to `server/src/installFhPluginTool.test.ts`:

```typescript
describe("handleInstallFhPlugin — versioning and write behaviour", () => {
  it("starts at V1 and appends the version to the @Title header, not just the filename", async () => {
    let writtenPath: string | undefined;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        writeFile: async (filePath, content) => {
          writtenPath = filePath;
          writtenContent = content;
        },
      }),
    );

    expect(writtenPath).toContain("Surname Census V1.fh_lua");
    expect(writtenContent).toMatch(/^@Title: Surname Census V1$/m);
  });

  it("increments past existing V<N> files for the same title, never overwriting", async () => {
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: PLUGIN_SOURCE },
      makeDeps({
        readdir: async () => ["Surname Census V1.fh_lua", "Surname Census V2.fh_lua", "Other Plugin V1.fh_lua"],
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toContain("Surname Census V3.fh_lua");
  });

  it("sanitizes characters invalid in a Windows filename out of the title", async () => {
    const source = PLUGIN_SOURCE.replace("@Title: Surname Census", '@Title: Surnames: A "Census"?');
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: source },
      makeDeps({
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toBe(
      "C:\\ProgramData\\Calico Pie\\Family Historian 8\\Plugins\\Surnames_ A _Census_? V1.fh_lua",
    );
  });

  it("defaults to base name 'plugin' when @Title is blank", async () => {
    const source = PLUGIN_SOURCE.replace("@Title: Surname Census", "@Title:");
    let writtenPath: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: source },
      makeDeps({
        writeFile: async (filePath) => {
          writtenPath = filePath;
        },
      }),
    );

    expect(writtenPath).toContain("plugin V1.fh_lua");
  });

  it("strips author_fh_plugin's trailing '---' install-instructions footer before writing", async () => {
    const withFooter = `${PLUGIN_SOURCE}\n\n---\nSave this as a .fh_lua file yourself and install it under FH's own permission model.`;
    let writtenContent: string | undefined;
    await handleInstallFhPlugin(
      { pluginSource: withFooter },
      makeDeps({
        writeFile: async (_filePath, content) => {
          writtenContent = content;
        },
      }),
    );

    expect(writtenContent).not.toContain("Save this as a .fh_lua file yourself");
    expect(writtenContent).toContain('fhOutputResultSetColumn("Surname", "text", {}, 0)');
  });

  it("returns a clear error and writes nothing when no @Title field is present", async () => {
    let writeCalled = false;
    const result = await handleInstallFhPlugin(
      { pluginSource: "fhOutputResultSetColumn(\"Surname\", \"text\", {}, 0)" },
      makeDeps({
        writeFile: async () => {
          writeCalled = true;
        },
      }),
    );

    expect(result.isError).toBe(true);
    expect((result.content[0] as { text: string }).text).toMatch(/@Title/);
    expect(writeCalled).toBe(false);
  });

  it("reminds the user to close and reopen the Plugins Dialog if it's open, on success", async () => {
    const result = await handleInstallFhPlugin({ pluginSource: PLUGIN_SOURCE }, makeDeps());

    expect(result.isError).toBeFalsy();
    const text = (result.content[0] as { text: string }).text;
    expect(text).toMatch(/close and reopen/i);
    expect(text).toMatch(/plugins dialog/i);
  });
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `cd server && npx vitest run src/installFhPluginTool.test.ts`
Expected: FAIL on the 7 new tests (title not versioned in header, sanitization/blank-title/footer-stripping not implemented, no `@Title` validation, no Plugins-Dialog reminder text) — the 6 Task 1 tests still PASS.

- [ ] **Step 3: Write the implementation**

In `server/src/installFhPluginTool.ts`, replace the placeholder `handleInstallFhPlugin` (and add the helper functions above it) with:

```typescript
const TITLE_LINE_PATTERN = /^@Title:[ \t]*(.*)$/m;
const GENERATED_FOOTER_SEPARATOR = "\n\n---\n";

function stripGeneratedFooter(pluginSource: string): string {
  const separatorIndex = pluginSource.indexOf(GENERATED_FOOTER_SEPARATOR);
  return separatorIndex === -1 ? pluginSource : pluginSource.slice(0, separatorIndex);
}

function sanitizeFilenameBase(title: string): string {
  const trimmed = title.trim();
  const base = trimmed.length > 0 ? trimmed : "plugin";
  return base.replace(/[<>:"/\\|?*\x00-\x1F]/g, "_");
}

function nextVersionNumber(existingNames: string[], base: string): number {
  const escapedBase = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^${escapedBase} V(\\d+)\\.fh_lua$`);
  let max = 0;
  for (const name of existingNames) {
    const match = name.match(pattern);
    if (match) {
      max = Math.max(max, Number(match[1]));
    }
  }
  return max + 1;
}

function appendVersionToTitle(source: string, version: number, originalTitle: string): string {
  const suffix = originalTitle.trim().length > 0 ? `${originalTitle.trim()} V${version}` : `V${version}`;
  return source.replace(TITLE_LINE_PATTERN, `@Title: ${suffix}`);
}

export async function handleInstallFhPlugin(
  input: { pluginSource: string; path?: string },
  deps: InstallFhPluginDeps,
): Promise<CallToolResult> {
  const source = stripGeneratedFooter(input.pluginSource);

  const titleMatch = source.match(TITLE_LINE_PATTERN);
  if (!titleMatch) {
    return textResult(
      "No @Title field found in the supplied plugin source — pass pluginSource exactly as author_fh_plugin generated it.",
      true,
    );
  }
  const originalTitle = titleMatch[1];

  const resolved = await resolvePluginsFolder(deps, input.path);
  if ("errorResult" in resolved) {
    return resolved.errorResult;
  }

  let existingNames: string[];
  try {
    existingNames = await deps.readdir(resolved.path);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Could not read the Plugins folder at ${resolved.path}: ${message}`, true);
  }

  const base = sanitizeFilenameBase(originalTitle);
  const version = nextVersionNumber(existingNames, base);
  const filename = `${base} V${version}.fh_lua`;
  const fullPath = `${resolved.path}\\${filename}`;
  const versionedSource = appendVersionToTitle(source, version, originalTitle);

  try {
    await deps.writeFile(fullPath, versionedSource);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return textResult(`Could not write the plugin file to ${fullPath}: ${message}`, true);
  }

  return textResult(
    `Installed as "${filename}" in FH's Plugins folder (${resolved.path}).\n\nFH doesn't rescan its Plugins folder live — if the Plugins Dialog (Tools -> Plugins) is currently open, close and reopen it so the new entry appears, then select it and click Run (or tick Add To Tools Menu to run it again later).`,
  );
}
```

Remove the now-superseded `titleMatch`/`base`/`filename`/`fullPath` lines and inline `deps.writeFile` call that Task 1 put directly in `handleInstallFhPlugin` — this step's version replaces that whole function body.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && npx vitest run src/installFhPluginTool.test.ts`
Expected: PASS (all 13 tests)

- [ ] **Step 5: Typecheck and commit**

Run: `cd server && npm run typecheck`
Expected: no errors

```bash
git add server/src/installFhPluginTool.ts server/src/installFhPluginTool.test.ts
git commit -m "feat: version and write installed FH plugins, never overwriting (issue #24)"
```

---

### Task 3: Register the tool, wire real fs/bridge deps, and cross-link author_fh_plugin

**Files:**
- Modify: `server/src/installFhPluginTool.ts` (add `makeDefaultInstallFhPluginDeps`, `INSTALL_FH_PLUGIN_DESCRIPTION`, `registerInstallFhPluginTool`)
- Modify: `server/src/index.ts:1-9,35-37` (import + register)
- Modify: `server/src/authorFhPluginTool.ts:187-192` (footer text)
- Test: `server/src/authorFhPluginTool.test.ts` (append one assertion)

**Interfaces:**
- Consumes: `handleInstallFhPlugin`, `InstallFhPluginDeps` from Task 2 (same file); `McpServer` from `@modelcontextprotocol/sdk/server/mcp.js`; `z` from `zod`; `runLuaOnBridge as defaultRunLuaOnBridge` from `./bridgeClient.js` (already imported in this file from Task 1).
- Produces: `export function registerInstallFhPluginTool(server: McpServer, deps: InstallFhPluginDeps = defaultDeps): void` — same registration signature shape as `registerDescribeProjectTool`/`registerRunLuaTool`, for `index.ts` to call.

- [ ] **Step 1: Write the failing test**

Append to `server/src/authorFhPluginTool.test.ts`, inside the existing `describe("handleAuthorFhPlugin", ...)` block (after the "includes install instructions..." test):

```typescript
  it("mentions install_fh_plugin as the option for the user's explicit install request", async () => {
    const text = await textOf(handleAuthorFhPlugin({ pluginType: "report", logic: "local x = 1" }));

    expect(text).toMatch(/install_fh_plugin/);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run src/authorFhPluginTool.test.ts -t "mentions install_fh_plugin"`
Expected: FAIL — footer text doesn't mention `install_fh_plugin` yet.

- [ ] **Step 3: Update author_fh_plugin's footer text**

In `server/src/authorFhPluginTool.ts`, replace lines 187-192:

```typescript
  const text = `${pluginSource}

---
Save this as a .fh_lua file yourself and install it under FH's own permission model — this tool never writes it to disk. Double-click the file to install on Windows, or use FH's own Tools -> Plugins -> New/Import option.

Any line above marked "-- FLAGGED" calls a function excluded from run_lua's sandbox. That's expected here, not a problem to fix — but review each flagged line before installing, the same way you'd review any other line in a plugin you're about to run.`;
```

with:

```typescript
  const text = `${pluginSource}

---
Save this as a .fh_lua file yourself and install it under FH's own permission model — this tool never writes it to disk. Double-click the file to install on Windows, or use FH's own Tools -> Plugins -> New/Import option. Alternatively, if the user asks you to install it, call install_fh_plugin with this output and it'll be written straight into FH's Plugins folder for them (with automatic V1/V2/... versioning so repeated installs never overwrite each other) — only do that on their explicit say-so, the same way you wouldn't save this file yourself without being asked.

Any line above marked "-- FLAGGED" calls a function excluded from run_lua's sandbox. That's expected here, not a problem to fix — but review each flagged line before installing, the same way you'd review any other line in a plugin you're about to run.`;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run src/authorFhPluginTool.test.ts`
Expected: PASS (all tests, including the new one)

- [ ] **Step 5: Add default deps, tool description, and registration function**

In `server/src/installFhPluginTool.ts`, add at the top (with the other imports) `import { z } from "zod";` and `import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";` and `import fs from "node:fs/promises";`, then append at the end of the file:

```typescript
function makeDefaultInstallFhPluginDeps(): InstallFhPluginDeps {
  return {
    runLuaOnBridge: defaultRunLuaOnBridge,
    readdir: (dirPath) => fs.readdir(dirPath),
    // "wx" refuses to overwrite an existing file — a last-line-of-defence race guard on
    // top of the version-number scan above, not a substitute for it.
    writeFile: (filePath, content) => fs.writeFile(filePath, content, { flag: "wx" }),
  };
}

const defaultDeps: InstallFhPluginDeps = makeDefaultInstallFhPluginDeps();

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's
// "install_fh_plugin" entry and docs/adr/0008-install-fh-plugin-staged-write.md.
export const INSTALL_FH_PLUGIN_DESCRIPTION = `Write a plugin author_fh_plugin generated directly into FH's Plugins folder, ready for the user to run from Tools -> Plugins, instead of them saving the file themselves.

Only call this when the user explicitly asks you to install (or "save", "add", "upload") the plugin you just generated — never automatically as a follow-up to author_fh_plugin, even when the generated plugin has no "-- FLAGGED" lines. Installing is still the user choosing to trust and run what you wrote; author_fh_plugin's flags exist so they can review it first, and calling this tool silently would remove that checkpoint. Flagged lines are expected and fine here — a Report/Query plugin genuinely needs functions run_lua's sandbox excludes (fhOutputResultSetColumn, fhMessageBox, etc.), that's the whole reason author_fh_plugin exists as a separate trust mode.

Pass pluginSource exactly as author_fh_plugin returned it (its trailing "---" install-instructions footer, if you include it, is stripped automatically — no need to trim it yourself).

Never overwrites an existing file. Each install gets the next unused "V<N>" suffix on both the filename and the plugin's own @Title header, based on how many versions of that title are already in the Plugins folder — so asking to install after tweaking the same plugin's logic again produces "<Title> V2", then "V3", etc., rather than clobbering the previous save.

Requires an active Bridge Session (same as run_lua) to look up FH's Plugins folder location live. If no Session is running, tell the user to click Start and retry, or ask them to confirm their Plugins folder path themselves (see docs/user-guide.md's "Where FH's Plugins folder is" — the location differs by FH version and is easy to get wrong) and pass it as the path parameter.

FH does not rescan its Plugins folder while its Plugins Dialog is open. After a successful install, tell the user to close and reopen Tools -> Plugins if they have it open, then select the new entry and click Run (or tick Add To Tools Menu).`;

export function registerInstallFhPluginTool(
  server: McpServer,
  deps: InstallFhPluginDeps = defaultDeps,
): void {
  server.registerTool(
    "install_fh_plugin",
    {
      description: INSTALL_FH_PLUGIN_DESCRIPTION,
      inputSchema: {
        pluginSource: z
          .string()
          .describe(
            "The plugin source exactly as author_fh_plugin returned it. Its trailing '---' install-instructions footer, if included, is stripped automatically.",
          ),
        path: z
          .string()
          .optional()
          .describe(
            "Explicit path to FH's Plugins folder, used only as a fallback when no Bridge Session is running to look the path up live. Ask the user to confirm this themselves (see docs/user-guide.md's 'Where FH's Plugins folder is') rather than guessing it.",
          ),
      },
    },
    (input) => handleInstallFhPlugin(input, deps),
  );
}
```

- [ ] **Step 6: Register the tool in index.ts**

In `server/src/index.ts`, change line 6:

```typescript
import { registerAuthorFhPluginTool } from "./authorFhPluginTool.js";
```

to:

```typescript
import { registerAuthorFhPluginTool } from "./authorFhPluginTool.js";
import { registerInstallFhPluginTool } from "./installFhPluginTool.js";
```

and change line 37:

```typescript
registerAuthorFhPluginTool(server);
```

to:

```typescript
registerAuthorFhPluginTool(server);
registerInstallFhPluginTool(server);
```

- [ ] **Step 7: Run the full test suite and typecheck**

Run: `cd server && npm test && npm run typecheck`
Expected: all tests PASS, no typecheck errors

- [ ] **Step 8: Build and commit**

Run: `cd server && npm run build`
Expected: builds cleanly to `dist/`

```bash
git add server/src/installFhPluginTool.ts server/src/index.ts server/src/authorFhPluginTool.ts server/src/authorFhPluginTool.test.ts
git commit -m "feat: register install_fh_plugin tool and cross-link it from author_fh_plugin (issue #24)"
```

---

### Task 4: Documentation — ADR, glossary, user guide, README

**Files:**
- Create: `docs/adr/0008-install-fh-plugin-staged-write.md`
- Modify: `CONTEXT.md` (insert after the `author_fh_plugin` entry, currently ending at line 89)
- Modify: `docs/user-guide.md:158-184` (the "Getting a standalone plugin written for you" section)
- Modify: `README.md:18-21` (the plugin-writing Aims bullet)

No tests apply to this task (docs-only) — verify by reading the diffs back and confirming issue #24 and #27 links resolve.

- [ ] **Step 1: Write the ADR**

Create `docs/adr/0008-install-fh-plugin-staged-write.md`:

```markdown
# install_fh_plugin writes to FH's Plugins folder directly, but only on explicit request

`install_fh_plugin` (issue #24) exists alongside `author_fh_plugin`, not as a replacement
for it. ADR 0004 keeps `author_fh_plugin` itself text-only specifically because installing
a plugin is a weaker review checkpoint than reading a chat answer, and that reasoning is
unaffected by anything below — a generated plugin can still legitimately call functions
`run_lua`'s sandbox excludes (`fhShellExecute`, filesystem functions, `fhMessageBox`, ...),
flagged inline for review.

What issue #24 asked for was removing the *mechanical* friction of that review step —
saving the returned text to a file yourself, finding FH's Plugins folder, and renaming it
by hand each time you iterate — not removing the review step itself. Four decisions follow:

1. **Staged, not automatic.** `install_fh_plugin` is a second, separate tool call, made
   only when the user explicitly asks to install what was just generated. It is never
   chained onto `author_fh_plugin` automatically, even when the generated plugin has no
   `-- FLAGGED` lines — the user still has to look at the plugin and decide to trust it,
   the same deliberate gesture ADR 0004 protects, just without the extra manual save step
   once they've decided.
2. **Stateless.** The tool takes the plugin source as an explicit input parameter, the same
   way `run_lua` has no server-side script state — Claude passes back what it generated (or
   what the user asked it to tweak), rather than the server trusting a cached "last
   generated plugin" that could silently be stale.
3. **The Node server writes the file directly**, not the Bridge/Lua side. The server
   already runs on the same machine as FH (see docs/user-guide.md's install steps) and can
   use `fs` directly — a completely separate trust boundary from `run_lua`'s sandboxed Lua
   execution, so this needs no change to `bridge/sandbox.lua`'s excluded-function list.
   `fhSaveTextFile` and friends stay excluded from `run_lua` exactly as before; this is a
   new, unrelated write path that a live Lua script can never reach.
4. **The Plugins folder location is resolved live**, via `fhGetContextInfo("CI_APP_DATA_FOLDER")`
   (already unrestricted in the sandbox) plus `\Plugins`, rather than guessed from the OS.
   docs/user-guide.md already documents a real footgun here — FH7 and FH8 keep separate
   Plugins folders side by side, "easy to copy into by mistake, and FH won't tell you if you
   do" — and a live query against whichever FH the user actually has a Session open in
   sidesteps that entirely. When no Session is running, the tool falls back to an explicit
   `path` parameter that Claude fills in only after asking the user to confirm it themselves.

Naming: never overwrites. Each install gets the next unused `V<N>` suffix on both the
filename and the plugin's own `@Title` header (not just the filename), so FH's own Tools ->
Plugins list disambiguates repeated installs of the same plugin as well as the files on
disk do.

Out of scope for this tool: triggering FH's own plugin-registration step (double-click /
Tools -> Plugins -> Import) after writing the file. That would mean the server executing a
file it just wrote via the OS shell — a meaningfully bigger capability than writing one —
for a convenience win that only saves one dialog click either way. `install_fh_plugin`'s
response instead reminds the user to close and reopen the Plugins Dialog if it's open,
since FH doesn't rescan the folder live; a proper refresh button has been raised with
Calico Pie as issue #27.
```

- [ ] **Step 2: Add the CONTEXT.md glossary entry**

In `CONTEXT.md`, insert the following new entry immediately after the existing `author_fh_plugin` entry (after the line ending `..._Avoid_: Plugin generator (alone, without the trust-model distinction from `run_lua` — that distinction is the point of this tool existing separately)`) and before the `Source template` entry:

```markdown
**install_fh_plugin**:
The MCP tool (issue #24) that writes a plugin `author_fh_plugin` generated directly into
FH's Plugins folder, so the user doesn't have to save the file and find that folder
themselves. A distinct, later step from `author_fh_plugin` — never called automatically as
its follow-up, only on the user's explicit request to install what was just generated; see
docs/adr/0008-install-fh-plugin-staged-write.md. Resolves the Plugins folder location live
via `fhGetContextInfo("CI_APP_DATA_FOLDER")` through an active Bridge Session (falling back
to a user-confirmed `path` parameter when no Session is running), and never overwrites —
each install gets the next unused `V<N>` suffix on both the filename and the plugin's own
`@Title` header. Writes via the MCP server's own filesystem access, not through the Bridge
or `run_lua`'s sandbox; `fhSaveTextFile` and the rest of `run_lua`'s excluded-function list
are unaffected by this tool's existence.
_Avoid_: Publish, upload (this project's own name for the operation is "install", matching
FH's own Tools -> Plugins terminology)
```

- [ ] **Step 3: Update the user guide**

In `docs/user-guide.md`, insert the following new paragraph between the existing bullet list (ending `...that's the entire purpose of the flag, so don't skip past them just because "an AI wrote it."`, currently line 181) and the closing line `Tell Claude which kind you want...` (currently line 183):

```markdown
Once you've reviewed it, you have two ways to install it:

- **Manual** — save the text yourself as a `.fh_lua` file and install it the normal FH way
  (double-click on Windows, or **Tools -> Plugins -> New/Import**), as described above.
- **Ask Claude to install it** — say so ("install it", "add it to my plugins") and Claude
  will call `install_fh_plugin` to write it straight into FH's Plugins folder. This needs
  an active Bridge Session (same as asking a live question) to look up where that folder
  is; if no Session is running, Claude will ask you to confirm the location instead (see
  "Where FH's Plugins folder is" above). It never overwrites an existing file — asking to
  install the same plugin again after a tweak adds "V2", then "V3", and so on, to both the
  filename and the plugin's own title. FH doesn't rescan its Plugins folder while the
  Plugins Dialog is open, so close and reopen **Tools -> Plugins** afterwards if you have it
  open, then select the new entry and click **Run**.
```

- [ ] **Step 4: Update the README**

In `README.md`, replace the Aims bullet (lines 18-21):

```markdown
- Let Claude write the user a complete, standalone FH Report or Query plugin to install
  and run themselves — a separate, human-reviewed path that isn't bound by the Bridge
  Session's Access mode, since the user runs it under FH's own permission model, not the
  Bridge's.
```

with:

```markdown
- Let Claude write the user a complete, standalone FH Report or Query plugin to install
  and run themselves — a separate, human-reviewed path that isn't bound by the Bridge
  Session's Access mode, since the user runs it under FH's own permission model, not the
  Bridge's. On the user's explicit say-so, Claude can also write it straight into FH's
  Plugins folder for them (`install_fh_plugin`), rather than them saving it by hand.
```

- [ ] **Step 5: Commit**

```bash
git add docs/adr/0008-install-fh-plugin-staged-write.md CONTEXT.md docs/user-guide.md README.md
git commit -m "docs: record install_fh_plugin design (ADR 0008) and update glossary/user guide/README"
```

---

## Self-Review Notes

- **Spec coverage:** all 7 grill-session decisions map to tasks — (1) staged/never-automatic → tool description + Task 4 docs; (2) stateless input → `pluginSource` param, no server cache; (3) Node writes directly → `fs`-backed `InstallFhPluginDeps`, no Bridge/socket write path; (4)/(5) self-contained live resolution + `path` fallback → Task 1; (6) naming/versioning incl. `@Title` rewrite → Task 2; (7) write-only scope + Plugins Dialog reminder → Task 2's success message + issue #27 cross-reference in the ADR.
- **Placeholder scan:** none — every step has complete, runnable code or a literal doc diff.
- **Type consistency:** `InstallFhPluginDeps`, `handleInstallFhPlugin`, `registerInstallFhPluginTool`, `GET_PLUGINS_APP_DATA_FOLDER_SCRIPT` are named identically everywhere they're consumed across Tasks 1-3.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-install-fh-plugin.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
