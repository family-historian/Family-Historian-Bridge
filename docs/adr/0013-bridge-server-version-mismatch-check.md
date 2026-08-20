# Detect and report a Bridge/server version mismatch

The Bridge plugin (`@Version` header in `Claude MCP Bridge.fh_lua`) and the MCP server
(`server/package.json`, self-reported correctly as of docs/adr's issue #44 fix) are
versioned independently, bumped by hand in lockstep per `docs/release.md` step 4. Nothing
checked that a running Bridge and a running server actually agreed on version, a user
could easily end up with a stale Bridge plugin still installed in FH's Plugins folder
talking to a freshly upgraded server (or vice versa), silently, since a version mismatch
alone doesn't necessarily break the wire protocol.

This decision was worked out interactively (issue #45's "Design resolved (grilling
session)" comment) before implementation; this ADR records the settled shape for anyone
who wasn't in that conversation.

## Decision

**Wire protocol.** A new bodyless request kind, `VERSION <server-version>`, alongside the
existing `STOP` / `LUA <n>` / `LUA_RO <n>` framing (`bridge/requestFraming.lua`). It's sent
as its own connection ahead of every actual `LUA`/`LUA_RO` connection, stateless, checked
on every call, no session-state tracking on the server side, since the server has no other
way to observe when a Bridge Session actually started (it only sees ECONNREFUSED vs. a
successful connect). The Bridge replies with its own version string; the existing
`LUA`/`LUA_RO` response shapes are untouched (see `bridgeResponse.ts`'s "ticket #2"
precedent against redesigning an already-shipped wire response shape casually).

**Comparison and surfacing.** Both sides end up knowing both versions and compare locally:
the server surfaces a mismatch in the tool result text back to Claude
(`server/src/versionCheck.ts`); the Bridge updates its own dialog status label
(`Claude MCP Bridge.fh_lua`'s `currentVersionWarning`, made sticky across poll ticks so a
mismatch detected on its own one-tick VERSION connection doesn't get silently overwritten
by the very next tick's ordinary status update).

**Severity.** Tiered by strict semver: only a differing major version blocks the real
request from running at all; everything else (including an unparseable version on either
side) just warns and proceeds. This tier is inert today, both sides are `0.x.y`, so major
is always `0`, accepted deliberately rather than redefined against the middle version
number, since it doubles as a personal dev-workflow reminder (restart Claude Desktop after
a Bridge/server rebuild) without ever hard-blocking real use pre-1.0. Revisit once this
project cuts 1.0.

**Bridge runtime version access.** The `@Version` header lived only in a Lua comment, not
anywhere the plugin's own running code could read. `bridge/scripts/bundler.lua` now parses
it at build time and injects a `local BRIDGE_VERSION = "..."` constant into the generated
bundle (right after the `fhInitialise(...)` splice point, alongside the other bundled
content), the header stays the single source of truth, matching this project's existing
build-time-anchor-checking pattern (docs/adr/0009) rather than adding a fourth hand-synced
version spot on top of the three `docs/release.md` already tracks.

**Backward compatibility.** A Bridge that predates this feature doesn't recognize the
`VERSION` verb and replies with the same malformed-framing error every unrecognized header
gets (`{"error": "expected STOP or LUA <n>"}`). The server treats that specific rejection as
its own signal, "Bridge doesn't support version reporting, likely older, consider
reinstalling", and proceeds with the real request anyway rather than blocking on it. This
is itself the stale-plugin scenario the feature exists to catch, so it gets a dedicated,
named outcome (`"unsupported"` in `versionCheck.ts`) rather than falling into a generic
parse-failure case.

**Where it's wired in.** `run_lua` and `describe_project` share the check via
`versionCheck.ts`'s `runVersionCheckedScript` (identical shape: check version, run the
script, interpret its response, append any note). `install_fh_plugin`'s Bridge call
(`resolvePluginsFolder`'s live Plugins-folder lookup) doesn't fit that shared shape, it
already has its own no-Session/explicit-path fallback and a bespoke JSON-parsing flow, so
it calls `checkBridgeVersion` directly and folds the result into its existing fallback
logic: a genuine version-mismatch block stops it before the lookup even runs, but the
version check's own connection failure defers to the lookup's own (already tailored,
already tested) no-Session error and explicit-path fallback rather than surfacing a second,
less specific error ahead of it.

## Consequences

- Every Bridge call now costs one extra short-lived connection (the VERSION exchange)
  ahead of the real one, accepted as negligible against the benefit of catching a stale
  Bridge/server pairing, and consistent with the connection-per-request model this
  protocol already uses.
- The severity tier does nothing observable pre-1.0 beyond the warning note; don't be
  surprised finding "block" code that never fires in current testing, it's there for when
  major versions start actually diverging.
