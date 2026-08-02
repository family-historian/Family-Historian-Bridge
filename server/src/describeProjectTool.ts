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
  }
}`;

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

return {
  recordCounts = recordCounts,
  tagCensus = {
    individualAndFamily = individualAndFamily,
    source = source,
    sourceTemplateFields = sourceTemplateFields,
  },
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
