// Typed view over toolNames.json, the single source of truth for which MCP tools this
// server registers (issue #85). That file's own _comment explains why the list lives in
// JSON rather than here.
//
// Nothing in this module decides anything -- the register*Tool call sites still name their
// own tool, right next to its schema, where it belongs. What closes the drift gap is
// toolNames.test.ts, which stands up a real McpServer, registers every tool the way
// index.ts does, and asserts the names it actually serves are exactly ALL_TOOL_NAMES.
import toolCatalog from "./toolNames.json" with { type: "json" };

export interface ToolCatalogEntry {
  /** The MCP tool name, as passed to server.registerTool(). */
  name: string;
  /** One-line blurb for the .mcpb bundle manifest -- not the tool's real MCP description. */
  bundleDescription: string;
}

export const TOOL_CATALOG: readonly ToolCatalogEntry[] = toolCatalog.tools;

export const ALL_TOOL_NAMES: readonly string[] = TOOL_CATALOG.map((tool) => tool.name);
