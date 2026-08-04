import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  AUTHOR_FH_PLUGIN_DESCRIPTION,
  handleAuthorFhPlugin,
  SANDBOX_EXCLUDED_FUNCTIONS,
} from "./authorFhPluginTool.js";

async function textOf(result: ReturnType<typeof handleAuthorFhPlugin>): Promise<string> {
  return ((await result).content[0] as { text: string }).text;
}

describe("handleAuthorFhPlugin", () => {
  it("wraps Report-type logic in the required @Type: report header and FH_GetRecordSectionContent entry point", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "report",
        logic: 'snTop:SetBodyText(fhNewRichText())',
      }),
    );

    expect(text).toMatch(/@Type:\s*report/);
    expect(text).toMatch(/function FH_GetRecordSectionContent\(snTop, rec, index, count\)/);
    expect(text).toContain("snTop:SetBodyText(fhNewRichText())");
  });

  it("gives Query-type logic a distinct header/entry-point shape from Report's", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "query",
        logic: 'fhOutputResultSetColumn("Surname", "text", {}, 0)',
      }),
    );

    expect(text).not.toMatch(/@Type:/);
    expect(text).not.toContain("FH_GetRecordSectionContent");
    expect(text).toContain('fhOutputResultSetColumn("Surname", "text", {}, 0)');
  });

  it("flags a sandbox-excluded call in Report-type logic on a standalone comment line, not appended to the call's own line", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "report",
        logic: 'fhShellExecute("notepad.exe")',
      }),
    );

    const lines = text.split("\n");
    const callIndex = lines.findIndex((line) => line.includes('fhShellExecute("notepad.exe")'));
    expect(callIndex).toBeGreaterThan(-1);
    // The call's own line must survive untouched — the flag lives on the line before it.
    expect(lines[callIndex]).not.toMatch(/FLAGGED/);
    expect(lines[callIndex - 1]).toMatch(/FLAGGED/);
    expect(lines[callIndex - 1]).toContain("fhShellExecute");
  });

  it("never truncates a call whose arguments span multiple physical lines", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "query",
        logic: 'fhOutputResultSetColumn("Surname",\n  "text", {}, 0)',
      }),
    );

    // Both continuation lines of the original call must appear verbatim and unbroken.
    expect(text).toContain('fhOutputResultSetColumn("Surname",');
    expect(text).toContain('"text", {}, 0)');
  });

  it("flags every distinct sandbox-excluded call named on one line", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "query",
        logic: 'fhMessageBox(fhGetClipboardData())',
      }),
    );

    const lines = text.split("\n");
    const callIndex = lines.findIndex((line) => line.includes("fhMessageBox(fhGetClipboardData())"));
    expect(callIndex).toBeGreaterThan(-1);
    expect(lines[callIndex - 1]).toMatch(/FLAGGED/);
    expect(lines[callIndex - 1]).toContain("fhMessageBox");
    expect(lines[callIndex - 1]).toContain("fhGetClipboardData");
  });

  it("does not flag lines with no sandbox-excluded call", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "query",
        logic: 'local pi = fhNewItemPtr()\npi:MoveToFirstRecord("INDI")',
      }),
    );

    expect(text).not.toContain("-- FLAGGED:");
  });

  it("never writes to the filesystem itself — the plugin source comes back as text content only", async () => {
    const result = await handleAuthorFhPlugin({ pluginType: "query", logic: "local x = 1" });

    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe("text");
  });

  it("includes install instructions pointing at manual save + FH's own install path", async () => {
    const text = await textOf(handleAuthorFhPlugin({ pluginType: "report", logic: "local x = 1" }));

    expect(text).toMatch(/\.fh_lua/);
    expect(text).toMatch(/double-click|Import/i);
  });

  it("mentions install_fh_plugin as the option for the user's explicit install request", async () => {
    const text = await textOf(handleAuthorFhPlugin({ pluginType: "report", logic: "local x = 1" }));

    expect(text).toMatch(/install_fh_plugin/);
  });

  it("tells the user to save manually as UTF-8, not ANSI, since this tool can't control that path itself", async () => {
    const text = await textOf(handleAuthorFhPlugin({ pluginType: "report", logic: "local x = 1" }));

    expect(text).toMatch(/UTF-8/);
    expect(text).toMatch(/ANSI/);
  });

  it("fills the standard header fields from the caller-supplied metadata, for both plugin types", async () => {
    const text = await textOf(
      handleAuthorFhPlugin({
        pluginType: "report",
        logic: "local x = 1",
        title: "Surname Census",
        description: "Counts occurrences of each surname across selected Individuals.",
        keywords: "Individual, Sources",
        version: "1.2",
        author: "Jane_t",
      }),
    );

    expect(text).toMatch(/@Title: Surname Census/);
    expect(text).toMatch(/@Author: Jane_t/);
    expect(text).toMatch(/@Version: 1\.2/);
    expect(text).toMatch(/@Keywords: Individual, Sources/);
    expect(text).toMatch(/@LastUpdated: \d{4}-\d{2}-\d{2}/);
    expect(text).toMatch(/@Description: Counts occurrences of each surname across selected Individuals\./);
    expect(text).toMatch(
      /@Licence: This plugin is copyright \(c\) \d{4} Jane_t and contributors, and is licensed under the MIT License/,
    );
  });

  it("defaults author to Claude MCP and still includes the standard header fields when metadata is omitted", async () => {
    const text = await textOf(handleAuthorFhPlugin({ pluginType: "query", logic: "local x = 1" }));

    expect(text).toMatch(/@Author: Claude MCP/);
    expect(text).toMatch(/@Version: 1\.0/);
    expect(text).toMatch(/@LastUpdated: \d{4}-\d{2}-\d{2}/);
    expect(text).not.toMatch(/@Type:/);
  });
});

describe("SANDBOX_EXCLUDED_FUNCTIONS", () => {
  it("matches every function bridge/tests/sandbox.test.lua asserts is absent or partially guarded under run_lua's Read-only sandbox", () => {
    const sandboxTestLuaPath = fileURLToPath(
      new URL("../../bridge/tests/sandbox.test.lua", import.meta.url),
    );
    const sandboxTestLua = readFileSync(sandboxTestLuaPath, "utf-8");

    // sandbox.test.lua asserts each hard-excluded FH function absent with `env.fhX == nil`;
    // allowed functions are instead asserted `== <realGlobal>`, so this pattern picks out
    // exactly the hard-excluded set without needing to parse the whole file. fhBridge is
    // gated the same read-write-only way (env.fhBridge == nil under read-only, issue #18)
    // but isn't a real FH API function — it's this project's own sourceHelper.lua module
    // alias, never something a hand-authored plugin would call — so it doesn't belong in
    // SANDBOX_EXCLUDED_FUNCTIONS and must be filtered back out here.
    const hardExcludedInLua = [...sandboxTestLua.matchAll(/env\.(fh\w+) == nil/g)]
      .map((m) => m[1])
      .filter((name) => name !== "fhBridge");

    // fhGetFactTag/fhGetFlagTag (issue #51) aren't a hard `== nil` exclusion any more —
    // sandbox.lua guards them instead, so their pure-lookup bCreateIfNone=false branch
    // works read-only while bCreateIfNone=true still errors. author_fh_plugin can't tell
    // which branch a given call uses without evaluating it, so it still flags both names
    // unconditionally (see authorFhPluginTool.ts's own comment) — same treatment as a hard
    // exclusion from this test's point of view. Picked out by the distinguishing phrase in
    // sandbox.test.lua's own assertion label, rather than the `== nil` pattern above.
    const guardedInLua = [
      ...sandboxTestLua.matchAll(/env\.(fh\w+) ~= fh\w+.*guarded wrapper, not the raw function/g),
    ].map((m) => m[1]);

    const excludedInLua = [...hardExcludedInLua, ...guardedInLua];

    expect(hardExcludedInLua.length).toBeGreaterThan(0);
    expect(guardedInLua.length).toBe(2);
    expect(new Set(SANDBOX_EXCLUDED_FUNCTIONS)).toEqual(new Set(excludedInLua));
  });
});

describe("AUTHOR_FH_PLUGIN_DESCRIPTION", () => {
  it("states this is a distinct trust mode from run_lua, not forbidden knowledge", () => {
    expect(AUTHOR_FH_PLUGIN_DESCRIPTION).toMatch(/run_lua/);
    expect(AUTHOR_FH_PLUGIN_DESCRIPTION.toLowerCase()).toMatch(/not forbidden|fair game/);
  });

  it("states the tool never writes the plugin to disk itself", () => {
    expect(AUTHOR_FH_PLUGIN_DESCRIPTION.toLowerCase()).toMatch(/never write|text only|text-only/);
  });
});
