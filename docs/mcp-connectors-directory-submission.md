---
type: document
subtype: summary
ai_generated: true
tags: [mcp, claude-desktop, connectors, anthropic]
source: https://claude.com/docs/connectors/building/submission
---

# Getting an MCP Listed on the Claude Connectors Directory

## What You Can Submit
- **Remote MCP servers** — internet-hosted servers providing tools/data to Claude
- **Desktop extensions (MCPB)** — local MCP servers packaged as MCP Bundles for [[Claude Desktop]]
- **MCP Apps** — servers with interactive UI elements (require extra screenshots)

## Which Path Applies to This Project
FH MCP Bridge stays local/desktop (talks to FH over a local socket) → submit as a **Desktop Extension (MCPB)** via the separate desktop extension submission form, **not** the admin-settings portal.

MCPB-specific requirements on top of the general list below:
- **Open source** — non-waivable for MCPB per Anthropic's directory terms
- **Packaging** — server must be packaged per the [MCPB spec](https://claude.com/docs/connectors/building/mcpb)

## Submission Requirements
1. **Security** — must meet Anthropic's security standards
2. **Tool annotations** — every tool needs a `title` and the applicable `readOnlyHint`/`destructiveHint`
3. **Authentication** — OAuth 2.0 required for any authenticated service
4. **Privacy policy** — required for local connectors:
   - "Privacy Policy" section in `README.md`
   - `privacy_policies` array in `manifest.json` (v0.2+)
   - HTTPS links
   - Must cover: data collection, usage/storage, third-party sharing, retention, contact info
   - ⚠️ Missing or incomplete policy = **immediate rejection**
5. **Documentation** — clear setup/usage instructions, publicly accessible by publish date

### Optional: Allowed Link URIs
If the connector opens external links via `ui/open-link`, you can declare allowed HTTPS origins or custom URI schemes you own, so users skip the confirmation prompt each time.

## How to Submit
No PR/repo process — it's a form-based submission:

- **Desktop extensions (MCPB):** [Desktop extension submission form](https://clau.de/desktop-extention-submission)
- **Remote MCP servers / MCP Apps:** [MCP directory submission form](https://clau.de/mcp-directory-submission)

Run through the [pre-submission checklist](https://claude.com/docs/connectors/building/review-criteria) before submitting.

### Information Needed
- Server name, URL, tagline, description, use cases
- Auth type & transport details
- Full tool/resource/prompt list
- Documentation, privacy policy, and support channel links
- Test account with reviewer setup steps
- Launch readiness (GA date, surfaces tested — Claude.ai, Desktop, etc.)
- Branding assets (logo, favicon, screenshots for MCP Apps)

## Review Process
- Review times vary with queue volume; the form is always open
- Corporate firewall blocking the form, or need an escalation → email Anthropic (contact on the [submission page](https://claude.com/docs/connectors/building/submission))
- A self-serve status dashboard is rolling out but not fully live — don't expect proactive updates on every status change

## Notes
- Skills are **not** a standalone submission type — bundle them into a plugin to get one included
- [[MCP Apps]] specifically require 3–5 PNG carousel screenshots (≥1000px wide, cropped to app response only, no prompt text included)
