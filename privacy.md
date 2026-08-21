# Privacy Policy

**Data collection:** FH MCP Bridge collects nothing itself. It has no accounts, no
telemetry, and no analytics. It doesn't sell, share, or transmit your genealogy data to
Anthropic, to us, or to any third party as part of running the software.

**Data usage:** Both halves of the Bridge (the FH plugin and the MCP server) talk to each
other only over `127.0.0.1` (localhost) — nothing leaves your machine over that channel.
When you ask Claude a question during a Bridge Session, the `run_lua` and
`describe_project` tools return records from your open FH project (names, dates, places,
relationships, etc.) to Claude Desktop so it can answer you. That exchange is then subject
to Anthropic's own [Privacy Policy](https://www.anthropic.com/legal/privacy) and
[Consumer Terms](https://www.anthropic.com/legal/consumer-terms) for whatever Claude
surface you're using it with, the same as any other prompt or tool result in your
conversation — the Bridge itself has no visibility into how Claude Desktop or Anthropic
subsequently handle that content.

The one other network call this software makes is `check_fh_help_updates`: an explicit,
user-triggered fetch of FH8's own bundled help content from family-historian.co.uk. That
request carries no genealogy data or other personal information — it just downloads
reference documentation.

**Data storage:** No genealogy data is written to disk by this software beyond FH's own
project file, which you already control. `check_fh_help_updates` caches the downloaded
help/reference corpus locally so it doesn't have to re-fetch it every time; that cache
holds FH's public documentation, not your data. `install_fh_plugin` writes a plugin file
only when you explicitly ask Claude to install one, and only into FH's own Plugins folder.

**Third-party sharing:** None, beyond the Claude Desktop / Anthropic exchange described
above (inherent to using an MCP tool with Claude at all) and the explicit,
user-triggered help-content fetch from family-historian.co.uk.

**Retention:** Nothing is retained by us, because nothing is collected by us. Locally
cached help content and any plugin files you asked Claude to write stay on your machine
under your control until you delete them yourself.

**Contact:** [fhmcp@family-historian.co.uk](mailto:fhmcp@family-historian.co.uk)
