# Manual MCPB install as the interim distribution path, replacing the Windows exe installer

The Windows `.exe` installer (`installer/release-windows.ps1`, `docs/windows-installer-guide.md`)
exists to do one thing beyond copying files: edit `claude_desktop_config.json` so Claude
Desktop picks up the Bridge's MCP server without the user hand-editing JSON. Doing that
took real work — a `config-merge.ps1` fallback, a documented log file, SmartScreen warnings
to explain away, antivirus tools flagging the installer's bundled `node.exe` — and it's
Windows-only, so Mac users were always pointed at building from source instead
(`docs/user-guide.md`'s own install section).

Claude Desktop's own Extension installer (Settings → Extensions → Advanced Settings →
Install Extension, given a `.mcpb` file) now does the same config-registration job natively,
cross-platform, with none of that supporting machinery. It also sidesteps a gap
`docs/user-guide.md`'s Troubleshooting section already documents: newer, unified/MSIX-packaged
Claude Desktop builds don't read `claude_desktop_config.json` at all, so the exe installer's
core value — editing that file — is silently worthless on those builds already.

Issue #56 ("Windows installer: `claude_desktop_config.json` gets wiped by new unified Claude
app — needs .dxt packaging") was tracking exactly this gap. Issues #130/#132 track a further,
future pivot — full listing in the Claude Connectors Directory + FH Plugin Store, so install
becomes a directory click-through with no manual download at all — but that's blocked on FH8
GA. This decision is the interim step ahead of that, not a substitute for it.

## Decision

Adopt manual MCPB install as the one recommended, cross-platform path for the Claude
Desktop half of setup: download the `.mcpb` release asset, install it via Claude Desktop's
own Settings → Extensions → Advanced Settings → Install Extension. The FH-side half is
unaffected — downloading `Claude MCP Bridge.fh_lua` and loading it via FH's own
Tools → Plugins → New (or double-click) was already the plugin-install mechanism; MCPB only
replaces how the *Claude Desktop* end gets configured, not this.

Consequences of that, applied together:

- **Retire the Windows exe installer as the recommended path.** `docs/windows-installer-guide.md`
  is trimmed to just its uninstall instructions, kept for anyone who already has the exe
  installed, and linked from nowhere prominent. `installer/release-windows.ps1`,
  `installer/release-mac.sh`, `installer/stage.ps1`, and `installer/config-merge.ps1` stay in
  the repo — not deleted — but stop being invoked by `docs/release.md`'s checklist. Their
  removal is left for a separate follow-up issue rather than done as part of this change.
- **Release assets become exactly two**: `bridge/dist/Claude MCP Bridge.fh_lua` (shipped
  under that exact, unversioned filename — it's already the build output as-is, and keeping
  it unversioned avoids someone accumulating several differently-named copies of the same
  plugin in FH's Plugins folder/dialog across releases) and the `.mcpb` bundle (already
  produced by `installer/build-dxt.mjs`, docs/adr/0015). The hand-assembled `.zip`
  (`docs/release.md` step 7) and the `.exe` installer drop out of what a release ships.
- **Docs split three ways** instead of one README covering install, build, and usage at once:
  - `README.md` becomes a short landing page — project description plus pointers to
    `docs/install.md` (install) and `docs/user-guide.md` (usage), not the install steps
    themselves.
  - `docs/install.md` (new): the one canonical, cross-platform install doc — MCPB via
    Claude Desktop's own Extension installer, then the Bridge `.fh_lua` via FH's Plugins
    dialog.
  - `docs/build.md` (new): the build-from-source steps split out of README, for
    contributors/developers, not end users.
  - `docs/user-guide.md` drops its own duplicate Requirements/Install section; it now starts
    from "already installed," so install instructions live in exactly one place.

## Out of scope

This doesn't touch #130/#132's future Directory/Plugin Store listing — manual MCPB install
is the step ahead of that, still blocked on FH8 GA, not a replacement for it. It also doesn't
add build/release automation: `docs/release.md`'s asset-upload step stays a manual checklist
item, consistent with this project's existing deliberate no-CI stance (issue #90).

## Consequences

- Issue #56 is resolved by this decision, not merely related to it — the config-registration
  gap it tracked is what MCPB's own installer sidesteps.
- One less platform-specific artifact to build and test per release.
- The `installer/` scripts for the exe/zip path become dead code until the follow-up removal
  issue is picked up — `npm test`'s installer suite still exercises `build-dxt.mjs`'s
  manifest logic, which stays in active use, but not the exe/zip-producing scripts.
- Anyone already on the old exe-installed setup keeps a documented uninstall path
  (`docs/windows-installer-guide.md`), even though it's no longer where new installs are
  pointed.
- The "newer Claude Desktop builds ignore `claude_desktop_config.json`" gap is sidestepped
  for new installs going through MCPB, since that flow never touches the file — but this
  decision doesn't fix the underlying gap for anyone still following the old manual
  config-editing steps in `docs/build.md`.
