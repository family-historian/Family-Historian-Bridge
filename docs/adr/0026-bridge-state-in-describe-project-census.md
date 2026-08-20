# describe_project reports Bridge version and Access mode as structured bridgeState, not just a text note

Issue #109 asked for "the current state of the Bridge" to be added to the Project census
table, the title arrived with no description. Resolved interactively (grilling session,
2026-08-15) before implementation; this ADR records the settled shape for anyone who
wasn't in that conversation.

## Decision

**Referent and surface.** "The Bridge" means the **Bridge plugin** specifically
(CONTEXT.md's three-way name split between Bridge plugin / Family Historian Bridge / FH MCP
Bridge), the only one of the three with actual runtime state to report. "The Project
census table" is `describe_project`'s existing JSON response. The new data lands as its own
top-level namespace, `bridgeState`, following the `dataQuality`/`contextInfo`/`flagCensus`
precedent (docs/adr/0014) of one section per concern rather than flattening into
`recordCounts`/`tagCensus`.

**Fields in scope.** Three: the Bridge plugin's own version (`bridgeVersion`), the
version-mismatch verdict already computed for every call (`versionStatus`, reusing
`VersionCheckOutcome.status` verbatim, `match`/`warn`/`unsupported`/`unparseable`; `block`
never reaches here, see below), and the Session's real Access mode (`accessMode`). An
idle-timeout/time-to-auto-Stop field was considered and dropped, nothing else in the
census is about future/pending state, only what's actually true now.

**Shape:**
```json
"bridgeState": {
  "bridgeVersion": "0.4.2",
  "serverVersion": "0.4.2",
  "versionStatus": "match",
  "accessMode": "read-only"
}
```
`serverVersion` is always known (the server's own constant). `bridgeVersion`/`accessMode`
are `null`, not an omitted key, when genuinely unknown, keeps the shape fixed for Claude to
read rather than conditional. `block` (major-version mismatch) and a VERSION-exchange
connection failure both already short-circuit `checkBridgeVersion` with an error
`CallToolResult` before any script runs, no JSON body exists at that point, so
`bridgeState` never appears for those two outcomes; nothing to design there.

**No new wire connection.** Both `bridgeVersion` and `versionStatus` are already fetched by
the `VERSION` exchange every `describe_project` call already makes
(`checkBridgeVersion`/`queryBridgeVersion`, docs/adr/0013), merging them into the JSON body
instead of discarding them into a text-only note is free. `accessMode` piggybacks on the
same exchange: the Bridge's `VERSION` reply grows from `{version}` to
`{version, accessMode}` (`bridgeSession.lua`'s `currentAccessMode()`), rather than adding a
second connection or exposing new sandbox globals. The sandbox-globals alternative was
rejected: `describe_project`'s script runs through the exact same allowlist as `run_lua`
today (stated in its own source comment), and reaching for Bridge-process globals there
would be the first departure from that symmetry, while still leaving `versionStatus`
unsolved, since the Lua sandbox has no way to know `SERVER_VERSION` at all.

**`interpretVersionResponse`'s match case starts retaining `bridgeVersion`.** Previously
`{ status: "match" }` discarded the parsed version string entirely (there was no consumer
that needed it before this issue). Fixed as part of this change, since
`bridgeState.bridgeVersion` is meaningless without it, the common case (versions agree)
was the one case guaranteed to lose the value.

**A Bridge that predates this change.** One that already supports `VERSION` (post-#45) but
not yet `accessMode` in the reply responds with valid JSON containing `version` but no
`accessMode`, a third gap distinct from `unsupported` (pre-#45, doesn't know the `VERSION`
verb at all) and `unparseable` (garbage reply). `accessMode` reads as `null` in that case;
`bridgeVersion`/`versionStatus` are still populated normally, since those came from the
pre-existing field.

**Text note dropped for `describe_project`, kept for `run_lua`.**
`appendVersionNote`'s free-text mismatch sentence is shared by both tools today.
`describe_project` stops calling it now that `bridgeState.versionStatus` is a structured,
strictly-better home for the same fact, keeping both would duplicate the same information
in two formats with no benefit, only drift risk. `run_lua`'s result has no fixed schema to
merge structured data into (it's an arbitrary Claude-authored script's own return value), so
it keeps the note unchanged.

## Consequences

- Every `run_lua`/`describe_project` call's `VERSION` exchange now also carries
  `accessMode` on the wire, even though only `describe_project` consumes it today,
  negligible, consistent with docs/adr/0013's already-accepted "one extra connection per
  call" cost.
- A future caller wanting Bridge state from `run_lua` has no structured place to read it
  from (only the shared text note), deliberately out of scope; `run_lua`'s
  arbitrary-script-result shape isn't a good fit for merged structured data, and nothing
  asked for it.
