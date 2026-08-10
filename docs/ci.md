# CI

`.forgejo/workflows/test.yml` runs all three test suites — server (vitest), bridge (Lua)
and installer (`node --test`) — on push to `main`, on pull requests, and on manual dispatch.

This is the server-side half of issue #90. The other half, `.githooks/pre-push`, is local
and bypassable (`git push --no-verify`, or simply never running `npm run setup:hooks` in a
fresh clone). CI is the backstop for exactly those cases.

## It does nothing until a runner is registered

Actions is enabled on the repo, but as of 2026-08-10 the instance has **no registered
runners**. Until one exists, pushes create workflow runs that queue forever and never
start. Check at:

`https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge/actions`

A run stuck on "Waiting" with no runner assigned means the daemon below isn't set up or
isn't reachable.

## Registering a runner

This is a one-time infrastructure step on whichever machine will execute jobs — typically
the Forgejo host itself. It needs Docker (the workflow runs in a container) and outbound
internet access (`actions/checkout` is fetched from `code.forgejo.org`).

1. **Get a registration token.** Repo → Settings → Actions → Runners → *Create new runner*.
   Site admins can instead register an instance-wide runner from Site Administration →
   Actions, which is the better choice if other repos will want CI too.

2. **Install `forgejo-runner`** on the runner host — release binaries at
   <https://code.forgejo.org/forgejo/runner/releases>. Match the major version to the
   instance (this one reports `15.0.4+gitea-1.22.0`).

3. **Register it.** The label matters: the workflow asks for `ubuntu-latest`, so the runner
   must offer that label or the job never matches.

   ```bash
   forgejo-runner register --no-interactive \
     --instance http://192.168.50.161:3000 \
     --token <REGISTRATION-TOKEN> \
     --name fh-mcp-bridge-runner \
     --labels 'ubuntu-latest:docker://node:22-bookworm'
   ```

   Use whichever instance URL the runner host can actually reach — the LAN address above,
   or `https://forgejo-direct.taubman.uk`.

4. **Run the daemon**, ideally under systemd so it survives a reboot:

   ```bash
   forgejo-runner daemon
   ```

5. **Confirm**, from the repo's Actions → Runners page, that the runner shows as idle. Then
   trigger a run — either push, or use the workflow's `workflow_dispatch` trigger from the
   Actions tab.

## Notes on the workflow itself

- **The container image is pinned** (`node:22-bookworm`) rather than left to whatever the
  runner maps `ubuntu-latest` to. The CI environment is then the same regardless of how the
  runner was configured — only the label name has to match.

- **Lua 5.4, not 5.5.** The dev Mac runs 5.5; bookworm packages 5.4. The bridge needs
  nothing newer than 5.2 (its highest requirement is `load()`'s four-argument form with an
  explicit env table, in `runScript.lua`), and none of the 5.4/5.5-only syntax (`<close>`,
  `<const>`) appears anywhere in `bridge/`. **This has not been executed on 5.4** — there
  was no Docker or 5.4 interpreter on the dev machine to try it — so treat the first CI run
  as the real verification. If it does trip on a version difference, the fix is the
  `apt-get install` line in the workflow.

- **No `.mcpb` build in CI.** `installer/build-dxt.mjs` shells out to the `mcpb` CLI and
  produces a 4 MB artifact; issue #90 is about the test suites. Release builds stay local,
  where both release scripts already run `npm test` first.

- **No dependency caching.** `npm ci` in `server/` is the slow step; the suites themselves
  take under two seconds. Worth adding a cache action only if run times become annoying.
