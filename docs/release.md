# Cutting a release

There's no script for this yet — every release so far (0.1.0, 0.2.0, 0.3.0) has been done
by hand, in the order below, reconstructed from git/Forgejo history rather than written
down in advance. Treat this doc as the checklist until it's worth automating.

See `docs/agents/issue-tracker.md` for the Forgejo API base URL and `FORGEJO_TOKEN` auth
used in step 6.

## 1. Finish the CHANGELOG's `Unreleased` section

Make sure every user-facing change since the last release is described under
`## Unreleased` in `CHANGELOG.md`, grouped by theme (not by commit) the way existing
sections are.

## 2. Pick the version number

Semver, bumped by hand — no tool infers this. Every release so far has been a minor bump
(0.1.0 -> 0.2.0 -> 0.3.0); nothing has needed a major or patch bump yet.

## 3. Cut the CHANGELOG

Rename `## Unreleased` to `## X.Y.Z`, and add a fresh, empty `## Unreleased` header above
it. (Commit message convention so far: `Cut CHANGELOG for X.Y.Z`.)

## 4. Bump the version in three places

These are three independent copies with no single source of truth — bump all three or
they drift:

- `bridge/Claude MCP Bridge.fh_lua` — the `@Version:` header field (near the top of the
  file).
- `server/package.json` — the `"version"` field.
- `server/package-lock.json` — **two** occurrences: the top-level `"version"` field and
  the nested `"packages"[""]["version"]` field.

(`installer/fh-mcp-bridge.iss`'s `AppVersion` is *not* a fourth copy to bump here: it's
generated at build time by `installer/stage.ps1` from `server/package.json`, into a
gitignored `installer/staging/version.iss` that the `.iss` file includes. This closed a
real, previously-undocumented drift — see the Risks section below.)

(Commit message convention so far: `Bump version to X.Y.Z`.)

## 5. Public-release check: strip FH8-specific wording

**Before packaging**, if this release will be public (or you're not sure), check whether
Family Historian 8 has shipped publicly yet. If it hasn't, the *packaged* copies of
`README.md` and `docs/user-guide.md` need their FH8-specific install-path wording
generalized before they go in the zip — e.g. `Family Historian 8\Plugins\` and "note the
`8`" language needs to become version-neutral ("your Family Historian install's own
Plugins folder... check you're copying into the one that matches the version you're
running"). The git-committed copies of these files keep the FH8-specific wording as-is —
only the packaged copies change, and only for this release.

Find every mention first:
```bash
grep -rn "Family Historian 8\|FH8" README.md docs/user-guide.md
```
Every release so far (0.1.0–0.3.0) has done this generalization by hand when assembling
the zip; it has never been scripted, and the substitution text above is what's actually
been used each time.

## 6. Build the server and the Bridge bundle

```bash
cd server
npm install
npm run build
cd ..
lua bridge/scripts/build.lua
```
This produces `server/dist/` and `bridge/dist/Claude MCP Bridge.fh_lua` — the latter is a
single self-contained file bundling all seven source modules (see
docs/adr/0009-bundle-bridge-plugin-for-install.md). Ship that one file, not the loose
`bridge/*.lua` sources.

## 7. Assemble the release folder

Create `fh-mcp-bridge-vX.Y.Z/` containing:

- `bridge/Claude MCP Bridge.fh_lua` — the bundled file from `bridge/dist/` (step 6), not
  the source directory. Plus `bridge/README.md` for reference. **Excludes** the loose
  `bridge/*.lua` source modules, `bridge/tests/`, `bridge/scripts/`, and `.DS_Store` (if
  present) — none of those ship; the bundle is the only artifact end users need.
- `server/dist/`, `server/package.json`, `server/package-lock.json`,
  the whole `server/data/` directory — not just the two corpus `.jsonl` files, but also
  `fh-help-corpus.meta.json` (read at runtime by `server/src/index.ts`; easy to miss
  since it's not a corpus file itself, but the server won't start without it — this doc
  undercounted it until caught while packaging 0.6.0). **Excludes** `server/src/` and
  `server/node_modules/` — the zip ships runtime deps only, installed fresh by the end
  user (step 8 below), not the dev/build toolchain.
- `docs/user-guide.md`
- `README.md` — the FH8-generalized copy from step 5, if this is a public release.
- `INSTALL.txt` — a short file, not committed to the repo, written fresh each time. The
  wording was identical release-to-release through 0.3.0 (before the Bridge was bundled
  into a single file); use this updated version from 0.4.0 onward:

  ```
  FH MCP Bridge vX.Y.Z — packaged release

  This archive ships the built server (server/dist/) and its data files, plus
  the bundled Bridge plugin (bridge/Claude MCP Bridge.fh_lua). It does NOT
  include server/node_modules (runtime deps only, no dev/build toolchain
  needed).

  1. Install server runtime dependencies:
       cd server
       npm install --omit=dev

  2. Install the Bridge plugin into FH:
     Copy bridge/Claude MCP Bridge.fh_lua (a single, self-contained file) into
     FH's Plugins folder. See bridge/README.md and README.md for exact paths.
     In FH: Tools -> Plugins -> New -> open Claude MCP Bridge.fh_lua -> Run.

  3. Point Claude Desktop's MCP config at server/dist/index.js (absolute path).
     See README.md, "Connect Claude Desktop".

  Full docs: README.md and docs/user-guide.md in this archive.
  ```

Zip it as `fh-mcp-bridge-X.Y.Z.zip` (note: the zip *filename* has no `v` prefix even
though the folder inside it does — `fh-mcp-bridge-vX.Y.Z/` — that inconsistency is just
how it's been done so far, not a deliberate convention worth preserving if you're
scripting this).

## 8. Commit, tag, push

Commit the CHANGELOG cut and version bumps (as separate commits, per existing
convention), then:
```bash
git tag -a vX.Y.Z -m "vX.Y.Z: <Nth> packaged release"
git push origin main
git push origin vX.Y.Z
```

## 9. Create the Forgejo release and upload the zip

```bash
source ~/.zshrc   # FORGEJO_TOKEN
API="http://192.168.50.161:3000/api/v1/repos/jane/fh-mcp-bridge"

# Body is the CHANGELOG section for this version, as raw markdown.
curl -sS -X POST "$API/releases" \
  -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"tag_name": sys.argv[1], "name": sys.argv[1], "body": sys.argv[2]}))' "vX.Y.Z" "$(sed -n '/## X.Y.Z/,/## /p' CHANGELOG.md | sed '1d;$d')")"

# Note the release id from the response, then attach the zip:
curl -sS -X POST "$API/releases/<release-id>/assets?name=fh-mcp-bridge-X.Y.Z.zip" \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -F "attachment=@fh-mcp-bridge-X.Y.Z.zip"
```

## Risks in this process worth knowing about

- **Three-way version drift** (step 4) already bit this repo once in a different but
  structurally identical way: the Bridge plugin's own install-file-list comment drifted
  out of sync with `bridge/README.md`'s list (missing `requestFraming.lua` and
  `sourceHelper.lua`), caught and partially fixed in the 0.2.0 changelog entry, then
  recurred and was fixed again 2026-08-01. Any hand-maintained list/value copied in more
  than one place is a standing risk — the version bump is the same shape of problem,
  just currently small enough (3 files) to get away with doing by hand. It actually bit a
  *fourth*, undocumented copy the same way: `installer/fh-mcp-bridge.iss`'s `AppVersion`
  sat at `0.5.0` while the three tracked copies had already moved to `0.6.0`, because it
  wasn't in this checklist for anyone to remember. That copy is now generated at build
  time (see step 4) instead of hand-maintained, which is probably the right fix for the
  three remaining copies too, once the release cadence justifies the scripting effort.
- **The FH8-suppression step (5) has never been written down before this doc.** It's been
  done correctly for all three releases so far, but only because whoever cut the release
  remembered to do it — nothing would have caught a miss.
- **No full packaging script exists, though step 6's Bridge half now is.**
  `bridge/scripts/build.lua` (docs/adr/0009) removes the exact list-drift risk described
  above for the Bridge plugin itself — there's no longer a hand-maintained list of bridge
  files to keep in sync, just one generated file. Step 7's overall folder assembly and the
  server side of step 6 are still entirely manual, though: nothing enforces that
  `server/src/` stays excluded from the zip, or that `bridge/scripts/`/`bridge/tests/`
  don't get included by mistake instead of just `bridge/dist/`'s one file. Worth scripting
  once the release cadence picks up.
