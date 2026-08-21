# Distribution strategy

Pivoted 2026-08-20 (Forgejo #131, full record; decision comment on #56; follow-up
checklist #132) away from a local `.dxt`/`.mcpb` handoff built by our own installer.

- MCP server ships via the **Claude Connectors Directory only** (Desktop Extension/MCPB).
  No local build/handoff of our own — Anthropic's install UI covers old and new Desktop.
  Old plan (#60, app-variant detection + local `.dxt` handoff in `Setup.exe`) closed as
  superseded, not revived.
- Lua bridge plugin ships via two channels: a small standalone Inno Setup installer, and
  the Family Historian Plugin Store (`family-historian.co.uk/pluginstore`, Author
  Application process). Current all-in-one `Setup.exe` (bundled node.exe +
  `config-merge.ps1`) retires.
- **Hard blocker on all of the above**: FH8 must ship publicly, and issues #115/#66/#27
  (all `upstream`, waiting on Calico Pie) must land — FH8 becomes the bridge's minimum
  supported version once they do, since the bundled help corpus already has FH8-only
  content. `docs/release.md` step 5's existing FH8-suppression logic is the same
  boundary.
- LICENSE (MIT) and `privacy.md` (split out of README's Privacy Policy section) are done
  ahead of the blocker — see `LICENSE`, `privacy.md`, `docs/mcp-connectors-directory-submission.md`.
- Public GitHub mirror: `family-historian/Family-Historian-Bridge` (dedicated GitHub
  account, deliberately separate from the user's personal ones, so ownership reads as
  "family-historian"), kept **private** until FH8 GA. Forgejo push-mirror (repo Settings →
  Mirror Settings), SSH + a deploy key Forgejo generated itself (no separately-managed
  keypair/PAT) — an initial HTTPS attempt failed since GitHub requires a PAT not a real
  password for git ops and no credentials were configured. Branch Filter is `release`, a
  branch cut only at release time (not tracking `main` commit-by-commit, so day-to-day
  dev churn / internal-only docs like LAN addresses in `docs/agents/issue-tracker.md`
  stay off GitHub). Cutting it is `docs/release.md` step 9 (`git branch -f release
  vX.Y.Z && git push origin release --force`), marked skip-until-mirror-is-configured.
  Forgejo issues never travel through a git push mirror regardless — DB-only, not git
  history.
