---
status: accepted
---

# fh-help resource reads are unreliable in at least one MCP client, treat as best-effort, not a guaranteed path to full text

`search_fh_help` returns a truncated excerpt per match, plus a `fh-help:{path}` resource
`uri` the tool description tells the LLM to read for the topic's full text
(`server/src/fhHelp.ts`'s `fh_help_page` resource, registered via `ResourceTemplate`).
During a 2026-07-31 session, an LLM using this server via Claude Code hit
`Server "fh-mcp-bridge" does not support resources` when attempting that read, and fell
back to web search for content already present locally in
`server/data/fh-help-corpus.jsonl`, several redundant round-trips the resource-read path
was supposed to make unnecessary.

## Investigation

Verified directly against the compiled server over the raw MCP stdio protocol (bypassing
Claude Code's client entirely), in order:

1. **`initialize` response capabilities** correctly include `"resources": {"listChanged":
   true}`, the server does advertise resource support.
2. **`resources/read`** for a real fh-help uri returns the full topic text correctly.
3. **`resources/templates/list`** correctly returns the registered `fh_help_page`
   template.
4. **`resources/list`** originally returned all ~993 corpus topics unpaginated in one
   ~258 KB response, with no `nextCursor`, this SDK version's
   `ListResourcesRequestSchema` handler ignores any request `cursor` and never emits one,
   so true pagination isn't available at that layer regardless of what a template's `list`
   callback does. Hypothesized this size/shape could be tripping a client-side limit.
5. Removed the `list` callback from the `fh_help_page` `ResourceTemplate` entirely,
   `resources/read` matches by URI-template pattern independent of `list` (confirmed by
   reading the SDK source), and no caller needs to *browse* the full corpus: every LLM
   caller already knows the exact uri to read from `search_fh_help`'s own result. Rebuilt,
   reverified over raw protocol: `resources/list` now returns `{"resources": []}`, reads
   still work.
6. Retested against Claude Code (process confirmed restarted after the rebuild) with the
   fix live: **same client-side error**. The list-size hypothesis is disproven, not just
   unconfirmed.

Every resource-related RPC this server exposes, capability advertisement, template
listing, list, and read, is spec-correct at the protocol level. The failure is in Claude
Code's own MCP client (general resource-capability handling, or specifically its
`ReadMcpResourceTool` wrapper), not in this server. No further server-side change was
found that resolves it.

Decided: keep the `resources/list` fix (still correct behavior, no downside, no reason to
ship an unbounded 993-entry list response regardless of whether it was the actual cause),
but stop treating the resource-read path as a reliable fallback for full text. It may work
in some MCP clients; it did not in the one tested. `SEARCH_FH_HELP_DESCRIPTION` no longer
tells the LLM to rely on it as the way to get full text, see the full-text search
(grep-style) tool tracked separately (issue #21), which works over the plain tool-call
channel every client already supports, with no resource-capability dependency at all.

## Consequences

- The `fh_help_page` resource and its `uri` values stay in place (harmless, and may work
  for other MCP clients) but are no longer the documented/primary path to full text.
- Full-text access for `search_fh_help` results now depends on issue #21 shipping; until
  then, an LLM hitting an insufficient excerpt has no reliable non-web fallback through
  this server alone.
- Not filed upstream against Claude Code itself, out of scope for this repo. Worth
  revisiting if a future MCP client shows the same failure, to build a stronger repro.
