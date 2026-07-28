import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerRunLuaTool } from "./runLuaTool.js";

const server = new McpServer({
  name: "fh-mcp-bridge",
  version: "0.1.0",
});

registerRunLuaTool(server);

const transport = new StdioServerTransport();
await server.connect(transport);
