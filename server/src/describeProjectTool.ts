import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import {
  queryBridgeVersion as defaultQueryBridgeVersion,
  runLuaOnBridge as defaultRunLuaOnBridge,
  type RunLuaOnBridgeOptions,
} from "./bridgeClient.js";
import { SERVER_VERSION } from "./serverVersion.js";
import { runVersionCheckedScript, type BridgeScriptDeps } from "./versionCheck.js";

export type DescribeProjectDeps = BridgeScriptDeps;

// Forces the Bridge's Read-only sandbox regardless of the Session's own Access mode
// (issue #16) — this script is fixed and known to never call a write function, so it
// runs at least privilege rather than inheriting whatever mode the Session happens to be
// in. See bridge/requestFraming.lua's LUA_RO form and CONTEXT.md's "describe_project" entry.
// Takes the underlying runLuaOnBridge/queryBridgeVersion as parameters (rather than
// hardcoding the imports) purely so tests can verify forceReadOnly is actually passed,
// without a live Bridge.
export function makeDescribeProjectDeps(
  runLuaOnBridge: (script: string, options?: RunLuaOnBridgeOptions) => Promise<string>,
  queryBridgeVersion: () => Promise<string>,
): DescribeProjectDeps {
  return {
    runLuaOnBridge: (script) => runLuaOnBridge(script, { forceReadOnly: true }),
    queryBridgeVersion,
  };
}

const defaultDeps: DescribeProjectDeps = makeDescribeProjectDeps(
  defaultRunLuaOnBridge,
  () => defaultQueryBridgeVersion(SERVER_VERSION),
);

// Steers Claude's own behavior when it uses this tool — see CONTEXT.md's "describe_project"
// entry and docs/adr/0002-describe-project-no-server-cache.md for why it recomputes every time.
export const DESCRIBE_PROJECT_DESCRIPTION = `Return a fixed census of the currently open FH project: record counts per record type, plus how often each distinct tag/field appears — so you know the project's actual shape (including any project-specific custom facts) before writing a run_lua script against it.

Requires an active Bridge Session (the user clicks Start in the Bridge's dialog first), same as run_lua. If this tool reports that no Session is running, tell the user to click Start.

Recomputes fully on every call — there is no caching, so calling it repeatedly in one conversation just repeats the same work for no benefit. Call it once, near the start of a conversation about a project you haven't already surveyed.

Returns JSON shaped as:
{
  "recordCounts": { "<record type tag, e.g. INDI/FAM/SOUR>": <count>, ... },
  "tagCensus": {
    "individualAndFamily": { "<tag, e.g. BIRT, _ATTR-REGIMENT>": <occurrence count>, ... },
    "source": { "<tag>": <occurrence count>, ... },
    "sourceTemplateFields": { "<field code, e.g. TX-PAGE>": <occurrence count>, ... }
  },
  "flagCensus": {
    "<flag tag, e.g. __LIVING/__PRIVATE or a project-specific custom flag>": {
      "count": <occurrence count>,
      "label": "<human-readable flag name, e.g. \\"Living\\">"
    }, ...
  },
  "dataQuality": {
    "livingStatusAmbiguousCount": <count of Individuals with a resolved birth date, no
      DEAT/BURI/CREM fact, and no Living flag set — likely missing death data, not
      confirmed living; don't presume these are alive without checking further>
  },
  "contextInfo": {
    "CI_PROJECT_NAME": "<currently open project's name>",
    "CI_PROJECT_FILE": "<project file's path>",
    "CI_GEDCOM_FILE": "<GEDCOM file's path, \\"\\" in Gedcom Mode (new) — no name yet>",
    "CI_PROJECT_PUBLIC_FOLDER": "<project's public folder path>",
    "CI_PROJECT_DATA_FOLDER": "<project's data folder path>",
    "CI_PLUGIN_NAME": "<this plugin's name>",
    "CI_APP_DATA_FOLDER": "<FH's own application data folder path>",
    "CI_APP_MODE": "<\\"Project Mode\\" | \\"Gedcom Mode\\" | \\"Gedcom Mode (new)\\">",
    "CI_STRING_ENCODING": "<\\"ANSI\\" | \\"UTF-8\\">"
  },
  "fhAppVersion": "<Family Historian's own application version, e.g. \\"8.0.0\\", from fhGetAppVersion()>"
}

flagCensus covers Individual record flags only (Living/Private plus any project-specific
custom ones) — Family record flags and Fact flags (Preferred/Tentative/Rejected/Private on
a specific fact) aren't covered here.

contextInfo carries every fhGetContextInfo() value that's actually usable here: the two
window-handle values (CI_APP_HWND/CI_PARENT_HWND) and the two report/book-only values
(CI_BOOK_CONTEXT/CI_BOOK_ITEM_HEADING, meaningless outside a report plugin's book context)
are omitted — see the script's own comment for why.`;

// Fixed, built-in script (not Claude-authored — see CONTEXT.md "describe_project"). Runs
// through the same sandbox/transport as run_lua, so it's limited to the same read-only
// allowlist (see bridge/sandbox.lua) and gets no server-side cache — see
// docs/adr/0002-describe-project-no-server-cache.md.
//
// Record-type enumeration (fhGetRecordTypeCount/fhGetRecordTypeTag) and the
// MoveToFirstRecord+MoveNext record-walk are both documented, standard patterns (FH8 API
// help). INDI/FAM/SOUR are GEDCOM 5.5.1 standard tags. The source-template-field walk
// targets FH's own GEDCOM extension tags _SRCT (Source Template record, confirmed via
// CONTEXT.md's GEDCOM corpus entry and family-historian.co.uk/gedcom-extension-tags) and
// its _FIELD metafield children, whose own item value (fhGetItemText(ptr, "~")) carries
// the field's code (e.g. "TX-PAGE") — the tag itself is always "_FIELD", so tallying by
// tag alone (as done for INDI/FAM/SOUR) wouldn't distinguish one declared field from
// another.
//
// flagCensus/dataQuality (issue #51): a single combined walk over every INDI's own direct
// children, run separately from tallyChildTagsOf above (which tallies INDI+FAM together
// and doesn't look inside a _FLGS item) since both new pieces are Individual-only and both
// need a per-record view, not just an aggregate tag count:
//   - Record flags (FH help: "Record Flags can only be set on Individual records") live as
//     children of an INDI's own "_FLGS" item — a Fact's nested _FLGS (Preferred/Tentative/
//     Rejected/Private fact flags) is a separate mechanism, deliberately not walked here
//     (see fact-flag-vs-record-flag in the GEDCOM knowledge corpus). Each flag instance is
//     tallied by its own tag (e.g. "__LIVING"), with a human-readable label resolved via
//     fhGetTypeInfo(ptr, "label") the first time each tag is seen — there's no read-only
//     tag-name enumeration API (fhGetFlagTag only maps a known name to its tag, and even
//     after issue #51's other fix, only round-trips a name you already have), but
//     fhGetTypeInfo works on any item pointer, flag instances included, and returns the
//     same display label FH itself shows for that flag type.
//   - The "living status ambiguous" data-quality count targets a specific false-positive
//     in the common "no death record therefore presumed living" heuristic: an Individual
//     with a resolved birth date, no DEAT/BURI/CREM fact, and no Living flag set is exactly
//     the shape of a data gap (e.g. a 108-year-old with no death record and no Living flag
//     — almost certainly missing data, not a real living person). "~.BIRT.DATE:YEAR" is a
//     Data Reference qualifier (see data-reference-qualifiers-date in the GEDCOM knowledge
//     corpus) — it resolves to "" both when there's no BIRT fact at all and when there is
//     one but its date doesn't resolve to a value, so this only counts a *resolved* birth
//     date, not mere BIRT-tag presence.
export const DESCRIBE_PROJECT_SCRIPT = `
local recordCounts = {}
local walker = fhNewItemPtr()
local typeCount = fhGetRecordTypeCount()
for i = 1, typeCount do
  local tag = fhGetRecordTypeTag(i)
  local n = 0
  walker:MoveToFirstRecord(tag)
  while walker:IsNotNull() do
    n = n + 1
    walker:MoveNext()
  end
  recordCounts[tag] = n
end

local function tallyChildTagsOf(recordTag, tally)
  local record = fhNewItemPtr()
  local child = fhNewItemPtr()
  record:MoveToFirstRecord(recordTag)
  while record:IsNotNull() do
    child:MoveToFirstChildItem(record)
    while child:IsNotNull() do
      local tag = fhGetTag(child)
      tally[tag] = (tally[tag] or 0) + 1
      child:MoveNext()
    end
    record:MoveNext()
  end
end

local individualAndFamily = {}
tallyChildTagsOf("INDI", individualAndFamily)
tallyChildTagsOf("FAM", individualAndFamily)

local source = {}
tallyChildTagsOf("SOUR", source)

local sourceTemplateFields = {}
do
  local template = fhNewItemPtr()
  local field = fhNewItemPtr()
  template:MoveToFirstRecord("_SRCT")
  while template:IsNotNull() do
    field:MoveToFirstChildItem(template)
    while field:IsNotNull() do
      if fhGetTag(field) == "_FIELD" then
        local code = fhGetItemText(field, "~")
        sourceTemplateFields[code] = (sourceTemplateFields[code] or 0) + 1
      end
      field:MoveNext()
    end
    template:MoveNext()
  end
end

local contextInfo = {}
do
  -- issue #51's original ask ("add all values from fhGetContextInfo") was missed from
  -- the itemized follow-up plan and only caught on a later review pass. Of the 11
  -- documented CI_* keys (FH help: fhGetContextInfo), two are deliberately left out:
  --   - CI_APP_HWND / CI_PARENT_HWND return Lua light userdata (a window handle), not a
  --     string/number/bool — bridge/jsonEncode.lua has no case for "userdata" and
  --     errors ("cannot encode value of type userdata to JSON"), so including them
  --     verbatim would break this call entirely. They're also meaningless here anyway:
  --     both exist to parent a dialog you're about to show, and this script never does.
  --   - CI_BOOK_CONTEXT / CI_BOOK_ITEM_HEADING only mean anything for a report plugin
  --     running inside a book (return false/"" otherwise) — not applicable to
  --     describe_project's own fixed script, so left out rather than always-empty noise.
  local keys = {
    "CI_PROJECT_NAME",
    "CI_PROJECT_FILE",
    "CI_GEDCOM_FILE",
    "CI_PROJECT_PUBLIC_FOLDER",
    "CI_PROJECT_DATA_FOLDER",
    "CI_PLUGIN_NAME",
    "CI_APP_DATA_FOLDER",
    "CI_APP_MODE",
    "CI_STRING_ENCODING",
  }
  for _, key in ipairs(keys) do
    contextInfo[key] = fhGetContextInfo(key)
  end
end

-- fhGetAppVersion() (issue #69) returns the three version integers separately, not a
-- pre-joined string (FH help: fhGetAppVersion) — formatted here as a dotted "X.Y.Z"
-- string to match how BRIDGE_VERSION/SERVER_VERSION are already represented everywhere
-- else in this codebase (see bridge/versionCompare.lua), rather than shipping a
-- {major, minor, patch} table shape found nowhere else.
local major, minor, patch = fhGetAppVersion()
local fhAppVersion = string.format("%d.%d.%d", major, minor, patch)

local flagCensus = {}
local livingStatusAmbiguousCount = 0
do
  local record = fhNewItemPtr()
  local child = fhNewItemPtr()
  local flag = fhNewItemPtr()
  record:MoveToFirstRecord("INDI")
  while record:IsNotNull() do
    local livingFlagSeen = false
    local deathFactSeen = false
    child:MoveToFirstChildItem(record)
    while child:IsNotNull() do
      local childTag = fhGetTag(child)
      if childTag == "_FLGS" then
        flag:MoveToFirstChildItem(child)
        while flag:IsNotNull() do
          local flagTag = fhGetTag(flag)
          if flagTag == "__LIVING" then
            livingFlagSeen = true
          end
          local existing = flagCensus[flagTag]
          if existing then
            existing.count = existing.count + 1
          else
            flagCensus[flagTag] = { count = 1, label = fhGetTypeInfo(flag, "label") }
          end
          flag:MoveNext()
        end
      elseif childTag == "DEAT" or childTag == "BURI" or childTag == "CREM" then
        deathFactSeen = true
      end
      child:MoveNext()
    end

    if not deathFactSeen and not livingFlagSeen then
      local birthYear = fhGetItemText(record, "~.BIRT.DATE:YEAR")
      if birthYear ~= "" then
        livingStatusAmbiguousCount = livingStatusAmbiguousCount + 1
      end
    end

    record:MoveNext()
  end
end

return {
  recordCounts = recordCounts,
  tagCensus = {
    individualAndFamily = individualAndFamily,
    source = source,
    sourceTemplateFields = sourceTemplateFields,
  },
  flagCensus = flagCensus,
  dataQuality = {
    livingStatusAmbiguousCount = livingStatusAmbiguousCount,
  },
  contextInfo = contextInfo,
  fhAppVersion = fhAppVersion,
}
`;

export async function handleDescribeProject(
  deps: DescribeProjectDeps = defaultDeps,
): Promise<CallToolResult> {
  return runVersionCheckedScript(deps, SERVER_VERSION, DESCRIBE_PROJECT_SCRIPT);
}

export function registerDescribeProjectTool(
  server: McpServer,
  deps: DescribeProjectDeps = defaultDeps,
): void {
  server.registerTool(
    "describe_project",
    {
      description: DESCRIBE_PROJECT_DESCRIPTION,
      inputSchema: {},
    },
    () => handleDescribeProject(deps),
  );
}
