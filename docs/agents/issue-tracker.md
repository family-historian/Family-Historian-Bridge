# Issue tracker: Forgejo

Issues live as Forgejo issues on this repo's self-hosted instance. No `gh`/`glab`/`tea` CLI is
available here — use `curl` directly against the Forgejo REST API (Gitea-compatible), authenticated
with `FORGEJO_TOKEN` (sourced from `~/.zshrc` — `source ~/.zshrc` first if a fresh shell doesn't
have it exported).

- **API base**: `http://192.168.50.161:3000/api/v1/repos/jane/fh-mcp-bridge` (LAN address; works directly, no auth redirect issues)
- **Web base** (for links shown to the user): `https://forgejo-direct.taubman.uk/jane/fh-mcp-bridge`
- **Owner/repo**: `jane` / `fh-mcp-bridge`

All calls below assume:
```bash
export FORGEJO_TOKEN=...   # already in ~/.zshrc
API="http://192.168.50.161:3000/api/v1/repos/jane/fh-mcp-bridge"
```

## Conventions

- **Create an issue**:
  ```bash
  curl -sS -X POST "$API/issues" \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    -d '{"title": "...", "body": "...", "labels": [<label-id>, ...]}'
  ```
  Labels are passed as numeric ids, not name strings — resolve names to ids first (see below).

- **Read an issue**: `curl -sS -H "Authorization: token $FORGEJO_TOKEN" "$API/issues/<number>"`, and
  `curl -sS -H "Authorization: token $FORGEJO_TOKEN" "$API/issues/<number>/comments"` for its comments.

- **List issues**:
  ```bash
  curl -sS -H "Authorization: token $FORGEJO_TOKEN" \
    "$API/issues?state=open&type=issue"
  ```
  Add `&labels=<id>,<id>` to filter by label id (comma-separated, AND semantics).

- **Comment on an issue**:
  ```bash
  curl -sS -X POST "$API/issues/<number>/comments" \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    -d '{"body": "..."}'
  ```

- **List labels / resolve name -> id**:
  `curl -sS -H "Authorization: token $FORGEJO_TOKEN" "$API/labels"` — returns `[{id, name, ...}]`.

- **Create a label**:
  ```bash
  curl -sS -X POST "$API/labels" \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    -d '{"name": "...", "color": "#ededed"}'
  ```

- **Apply / remove labels**:
  ```bash
  curl -sS -X POST "$API/issues/<number>/labels" \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    -d '{"labels": [<label-id>, ...]}'
  curl -sS -X DELETE "$API/issues/<number>/labels/<label-id>" \
    -H "Authorization: token $FORGEJO_TOKEN"
  ```

- **Close**:
  ```bash
  curl -sS -X PATCH "$API/issues/<number>" \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    -d '{"state": "closed"}'
  ```
  Post a closing comment first if one is warranted — Forgejo's PATCH doesn't accept a comment body.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Flip to yes if this repo starts treating external PRs as
feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

Create a Forgejo issue via the `POST $API/issues` call above.

## When a skill says "fetch the relevant ticket"

`GET $API/issues/<number>` plus `GET $API/issues/<number>/comments`.

## Wayfinding operations

This Forgejo instance (v15.0.4) has issue *dependencies* enabled but no sub-issue/parent-child
API (`/issues/<n>/sub_issues` 404s even though the web UI may show a sub-issues feature) — so
the wayfinder skill's constructs map onto plain issues, labels, and the dependencies API:

- **Map**: an issue labelled `wayfinder:map`.
- **Ticket**: a child issue of a map. Since there's no native parent/child link, a ticket's body
  opens with `Part of #<map-number>` (Forgejo auto-creates a visible cross-reference on both
  issues from this) and carries the label `wayfinder:ticket` plus exactly one type label —
  `wayfinder:research` / `wayfinder:prototype` / `wayfinder:grilling` / `wayfinder:task`.
  All six `wayfinder:*` labels already exist in this repo (created 2026-07-31); reuse them,
  don't recreate.
- **Blocking**: native issue dependencies. `POST $API/issues/<ticket>/dependencies` with
  `{"index": <blocking-ticket>, "owner": "jane", "repo": "fh-mcp-bridge"}` makes `<ticket>`
  depend on (blocked by) `<blocking-ticket>` — the `owner`/`repo` fields are required even
  though they're redundant with the URL, or Forgejo 500s with `IsErrRepoNotExist`.
  `GET $API/issues/<ticket>/dependencies` lists what blocks it; a ticket is unblocked when
  every entry there has `"state": "closed"`.
- **Claim**: `PATCH $API/issues/<ticket>` with `{"assignees": ["<username>"]}`.
- **Frontier query**: the `labels=` filter on `GET $API/issues` does **not** actually filter
  on this Forgejo instance (v15.0.4) — confirmed 2026-07-31: `?state=open&type=issue&labels=14`
  returned every open issue in the repo, including ones with no such label. Don't rely on it.
  Instead: `GET $API/issues?state=open&type=issue` (all open issues), then filter client-side
  for `wayfinder:ticket` in each issue's own `labels` array. From that set, a ticket is on the
  frontier if `assignees` is empty/null and `GET $API/issues/<n>/dependencies` comes back empty
  or every entry has `"state": "closed"`. If more than one map is ever active at once,
  disambiguating "part of which map" needs a per-map label (e.g. `wayfinder:map-28`) or a body
  check for `Part of #<map-number>` — not needed yet since this repo has had only one map so far.
