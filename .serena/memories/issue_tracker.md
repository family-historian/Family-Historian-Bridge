# Forgejo issue tracker

Self-hosted Forgejo (Gitea-compatible REST API), repo `jane/fh-mcp-bridge`. No `gh`/`glab`/
`tea` CLI available — raw `curl` + `FORGEJO_TOKEN` (sourced from `~/.zshrc`; run
`source ~/.zshrc` first if a fresh shell doesn't have it exported).

- API base: `http://192.168.50.161:3000/api/v1/repos/jane/fh-mcp-bridge` (LAN address, no
  auth-redirect issues)
- Web base (for links shown to user): `https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge`
- Create issue: POST `$API/issues` with `{"title","body","labels":[<numeric ids>]}` —
  labels are ids, not name strings; resolve via GET `$API/labels` first.
- Read: GET `$API/issues/<n>` and `$API/issues/<n>/comments`.
- List: GET `$API/issues?state=open&type=issue`, optional `&labels=<id>,<id>` (AND
  semantics).
- Comment: POST `$API/issues/<n>/comments` with `{"body"}`.
- Clickable file links in an issue body/comment need the full `src/branch/<branch>/<path>`
  (or `raw/branch/...`) URL — plain relative paths (`[x](LICENSE)`) don't resolve, since
  the issue page's URL isn't the repo root.

Full doc: `docs/agents/issue-tracker.md`. For POST bodies, write JSON to a file first and
`curl -d @file` rather than inlining — and verify before retrying a call that looked like
it failed, to avoid duplicate-creating issues (a known duplicate-creation footgun with this
API).

**Don't `source ~/.zshrc` to get `FORGEJO_TOKEN`** — it also sources `luaver`, which prints
its full help banner to stdout on every shell invocation in this session, contaminating any
`curl`/`python3` command substitution downstream (breaks JSON parsing in confusing ways).
Instead export the token directly: `grep FORGEJO_TOKEN ~/.zshrc` once to get the value, then
`export FORGEJO_TOKEN=...` per-command.
