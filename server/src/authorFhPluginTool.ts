import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's
// "author_fh_plugin" entry and docs/adr/0004-author-fh-plugin-text-only-flag-risky-calls.md.
export const AUTHOR_FH_PLUGIN_DESCRIPTION = `Scaffold a standalone FH Report or Query plugin from Lua logic you author, wrapped in that plugin type's required boilerplate, and return it as plugin source text for the user to save and install themselves.

This is a distinct trust mode from run_lua, not a variant of it. run_lua executes a script immediately, live, inside the user's own open FH process, under this Bridge's sandbox allowlist (Read-only by default; Read-write during a read-write Session additionally grants FH's write API — see CONTEXT.md's "Access mode" entry — but never anything beyond that allowlist). author_fh_plugin's output is never executed by the Bridge at all — it's unreviewed-until-installed text that only ever runs once the user saves it as a .fh_lua file and installs it themselves (double-click on Windows, or FH's own Tools -> Plugins -> New/Import), under FH's own trust boundary. Because of that, functions run_lua's sandbox permanently excludes regardless of Access mode (fhShellExecute, filesystem functions like fhLoadTextFile/fhSaveTextFile, fhMessageBox, fhPromptUserForDate and the other fhPromptUserFor* dialogs, fhOutputResultSetColumn/fhOutputResultSetTitles, etc.) are fair game here — they are excluded from run_lua's sandbox, not forbidden knowledge, and this tool is exactly the other, human-reviewed path to them.

Because installing a plugin file is a weaker review checkpoint than reading an inline chat answer, any call to one of these otherwise-excluded functions is flagged inline in the returned source with a "-- FLAGGED" comment, so the user notices it even if they only skim before installing.

Plugin types (pass one as pluginType):
- "report": generates a report displayed in FH's Report Window. Wraps your logic in the required \`@Type: report\` header and an \`FH_GetRecordSectionContent(snTop, rec, index, count)\` entry-point function — build the report body with snTop:SetHeading/SetBodyText and fhNewRichText, per the bundled FH8 help corpus's "Report Plugins" and "Sample Plugin Scripts" pages. Report plugins are read-only in FH's own sense: FH will error if the logic calls fhSetValue... functions, fhCreateItem, fhDeleteItem, fhMoveItemAfter, or fhMoveItemBefore — don't supply logic that does this for a Report plugin.
- "query": produces a listing in FH's Query Window, e.g. a surname census or a list of records matching some condition. Unlike Report plugins, ordinary/query-style plugins have no required header field and no special entry-point function in FH's own plugin architecture — your logic runs top-to-bottom as the whole plugin body, ending in one or more fhOutputResultSetColumn calls (optionally preceded by fhOutputResultSetTitles) per the bundled help corpus's "Sample Plugin Scripts" page (e.g. Surname Summary, Find Date Phrases). This tool deliberately does not invent a header or entry point for this type — their absence is what makes an ordinary plugin structurally distinct from a Report plugin.

Both plugin types get the repo's standard header fields (@Title, @Author, @Version, @Keywords, @LastUpdated, @Licence, @Description) alongside whatever type-specific header content is required above — pass title/description/keywords/version to fill them in with something meaningful for what you authored, rather than leaving them blank.

This tool's output is text only — it never writes the plugin file to disk itself. The user saves it themselves wherever they want, then installs it under FH's own permission model.`;

// Functions run_lua's sandbox (bridge/sandbox.lua) excludes under its Read-only baseline
// — kept in sync by hand with bridge/tests/sandbox.test.lua's own exclusion-assertion list, the
// single authoritative enumeration of what run_lua excludes there. author_fh_plugin's
// output sits outside that trust boundary entirely (see CONTEXT.md "author_fh_plugin" and
// docs/adr/0004-author-fh-plugin-text-only-flag-risky-calls.md), so these are legitimate
// to use here — they're flagged for the user's review, not blocked. The write-API
// functions below (fhCreateItem and the fhSet* setters) are reachable via run_lua too, but
// only during a read-write Session (issue #14) — author_fh_plugin has no way to know the
// Session's Access mode, so it flags them unconditionally, erring toward review.
// fhGetFactTag/fhGetFlagTag (issue #51) are no longer a bare exclusion in Read-only —
// sandbox.lua now guards them so their pure-lookup bCreateIfNone=false branch works there
// — but their bCreateIfNone=true schema-creating branch is still excluded read-only, and
// author_fh_plugin still can't tell which branch a given call uses without evaluating it,
// so both names stay flagged here unconditionally, same reasoning as the fhSet* setters.
export const SANDBOX_EXCLUDED_FUNCTIONS = [
  "fhCreateItem",
  "fhDeleteItem",
  "fhMoveItemAfter",
  "fhMoveItemBefore",
  "fhSrcEnableAutoTitle",
  "fhGetFactTag",
  "fhGetFlagTag",
  "fhSetLabelledText",
  "fhSetValueAsAge",
  "fhSetValueAsDate",
  "fhSetValueAsInteger",
  "fhSetValueAsLink",
  "fhSetValueAsRichText",
  "fhSetValueAsText",
  "fhSetStringEncoding",
  "fhSetConversionLossFlag",
  "fhShellExecute",
  "fhLoadTextFile",
  "fhSaveTextFile",
  "fhGetIniFileValue",
  "fhSetIniFileValue",
  "fhGetClipboardData",
  "fhSleep",
  "fhOverridePreference",
  "fhMessageBox",
  "fhDisplayRichTextBox",
  "fhPromptUserForDate",
  "fhPromptUserForRecordSel",
  "fhPromptUserForRichText",
  "fhUpdateDisplay",
  "fhOutputResultSetColumn",
  "fhOutputResultSetTitles",
  "fhGetValueAsBlob",
  "fhSetValueAsBlob",
  "fhGetPluginDataFileName",
  "fhExhibitResponsiveness",
  "fhInitialise",
] as const;

// Text match, not an AST-based call-site check — can also match the name inside a string
// literal or a pre-existing comment in the supplied logic. That's an acceptable direction
// to err in: a false-positive flag just adds one harmless extra review comment, whereas a
// false negative would silently hide a real excluded call.
const EXCLUDED_CALL_PATTERN = new RegExp(
  `\\b(${SANDBOX_EXCLUDED_FUNCTIONS.join("|")})\\b`,
  "g",
);

function flagExcludedCalls(logic: string): string {
  return logic
    .split("\n")
    .flatMap((line) => {
      const matches = new Set<string>();
      for (const match of line.matchAll(EXCLUDED_CALL_PATTERN)) {
        matches.add(match[1]);
      }
      if (matches.size === 0) {
        return [line];
      }
      // A standalone comment line ahead of the match, never appended to the match's own
      // line: an excluded call's arguments can themselves span multiple physical lines
      // (a comma-continued call is valid Lua), and a trailing `--` comment on just the
      // first of those lines would silently truncate the statement.
      const indent = line.match(/^\s*/)?.[0] ?? "";
      const flag = `${indent}-- FLAGGED: excluded from run_lua's sandbox (${[...matches].join(", ")}) — reviewed here, not forbidden. See author_fh_plugin's tool description.`;
      return [flag, line];
    })
    .join("\n");
}

// Recommended standard plugin-header fields (see the repo's own Claude MCP Bridge.fh_lua
// for the same template applied by hand). @Title/@Author/@Version/@Keywords/@LastUpdated/
// @Licence/@Description are always safe to add alongside whatever @Type value (or absence
// of one) a plugin type actually requires — FH only cares about the specific fields each
// plugin type documents (e.g. Report's "@Type: report"), not about extra fields beyond that.
const LICENCE_LINE = (year: number, author: string) =>
  `This plugin is copyright (c) ${year} ${author} and contributors, and is licensed under the MIT License\nwhich is hereby incorporated by reference (see https://pluginstore.family-historian.co.uk/fh-plugin-licence)`;

interface PluginMetadata {
  title: string;
  author: string;
  version: string;
  keywords: string;
  description: string;
}

function metadataHeaderLines(meta: PluginMetadata): string[] {
  const now = new Date();
  return [
    `@Title: ${meta.title}`,
    `@Author: ${meta.author}`,
    `@Version: ${meta.version}`,
    `@Keywords: ${meta.keywords}`,
    `@LastUpdated: ${now.toISOString().slice(0, 10)}`,
    `@Licence: ${LICENCE_LINE(now.getFullYear(), meta.author)}`,
    `@Description: ${meta.description}`,
  ];
}

function buildReportPlugin(logic: string, meta: PluginMetadata): string {
  const indentedLogic = flagExcludedCalls(logic)
    .split("\n")
    .map((line) => (line.length > 0 ? `  ${line}` : line))
    .join("\n");

  const header = [`@Title: ${meta.title}`, "@Type: report", ...metadataHeaderLines(meta).slice(1)].join(
    "\n",
  );

  return `--[[
${header}
]]

function FH_GetRecordSectionContent(snTop, rec, index, count)
${indentedLogic}
end`;
}

function buildQueryPlugin(logic: string, meta: PluginMetadata): string {
  // Deliberately no @Type field here (see the tool description) — its absence, along with
  // no entry-point function, is what makes an ordinary/query plugin structurally distinct
  // from a Report plugin. Every other standard-header field is still included.
  const header = metadataHeaderLines(meta).join("\n");

  return `--[[
${header}
]]

${flagExcludedCalls(logic)}`;
}

export interface AuthorFhPluginInput {
  pluginType: "report" | "query";
  logic: string;
  title?: string;
  description?: string;
  version?: string;
  keywords?: string;
  author?: string;
}

const DEFAULT_AUTHOR = "Claude MCP";

export async function handleAuthorFhPlugin(input: AuthorFhPluginInput): Promise<CallToolResult> {
  const meta: PluginMetadata = {
    title: input.title ?? "",
    author: input.author ?? DEFAULT_AUTHOR,
    version: input.version ?? "1.0",
    keywords: input.keywords ?? "",
    description: input.description ?? "",
  };
  const pluginSource =
    input.pluginType === "report"
      ? buildReportPlugin(input.logic, meta)
      : buildQueryPlugin(input.logic, meta);

  const text = `${pluginSource}

---
Save this as a .fh_lua file yourself and install it under FH's own permission model — this tool never writes it to disk. Save it as UTF-8 (not ANSI) — most editors default to this, but check if yours doesn't — so FH loads it as Unicode rather than silently mangling any accented/non-ASCII text the script reads from or writes to the tree. Double-click the file to install on Windows, or use FH's own Tools -> Plugins -> New/Import option. Alternatively, if the user asks you to install it, call install_fh_plugin with this output and it'll be written straight into FH's Plugins folder for them (as UTF-8 automatically, with automatic V1/V2/... versioning so repeated installs never overwrite each other) — only do that on their explicit say-so, the same way you wouldn't save this file yourself without being asked.

Any line above marked "-- FLAGGED" calls a function excluded from run_lua's sandbox. That's expected here, not a problem to fix — but review each flagged line before installing, the same way you'd review any other line in a plugin you're about to run.`;

  return { content: [{ type: "text", text }] };
}

export function registerAuthorFhPluginTool(server: McpServer): void {
  server.registerTool(
    "author_fh_plugin",
    {
      description: AUTHOR_FH_PLUGIN_DESCRIPTION,
      inputSchema: {
        pluginType: z
          .enum(["report", "query"])
          .describe(
            "Which kind of standalone FH plugin to scaffold: \"report\" (displayed in the Report Window, via FH_GetRecordSectionContent) or \"query\" (a Query Window result set, via fhOutputResultSetColumn).",
          ),
        logic: z
          .string()
          .describe(
            "The plugin's query/report logic in Lua, authored by you. For pluginType \"report\", this is the body of FH_GetRecordSectionContent (snTop/rec/index/count are in scope). For pluginType \"query\", this is the whole top-level plugin body, ending in one or more fhOutputResultSetColumn calls.",
          ),
        title: z
          .string()
          .optional()
          .describe("Short plugin name for the header's @Title field, e.g. \"Surname Census\". Defaults to blank if omitted."),
        description: z
          .string()
          .optional()
          .describe("Short description of what the plugin does, for the header's @Description field. Fill this in with a suitable summary of the logic you authored — don't leave it blank."),
        keywords: z
          .string()
          .optional()
          .describe("Comma-separated keywords for the header's @Keywords field (see the bundled FH8 help corpus's Report Plugins page for the recognised set, e.g. Individual, Family, Sources). Optional."),
        version: z
          .string()
          .optional()
          .describe("Plugin version for the header's @Version field. Defaults to \"1.0\"."),
        author: z
          .string()
          .optional()
          .describe("Plugin author name for the header's @Author and @Licence fields. Defaults to the current user."),
      },
    },
    (input) => handleAuthorFhPlugin(input),
  );
}
