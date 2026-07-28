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
