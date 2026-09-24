#!/usr/bin/env bash
# Point local `release` at vX.Y.Z plus one commit that strips internal-only files
# (LAN addresses, Forgejo API recipes). Usage: scripts/build-release-branch.sh X.Y.Z [ref]
# `ref` defaults to the tag; pass `main` to also pick up doc-only commits made after tagging.
# Tags still carry the full tree; only the `release` branch head is filtered.
set -euo pipefail

VERSION="${1:?usage: build-release-branch.sh X.Y.Z}"
TAG="v${VERSION}"
REF="${2:-$TAG}"
INTERNAL_FILES=(
  docs/agents/issue-tracker.md
  docs/release.md
  .serena/memories/issue_tracker.md
)

git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || { echo "no tag ${TAG}" >&2; exit 1; }

INDEX="$(mktemp)"; rm -f "$INDEX"
trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree "${REF}^{tree}"
git update-index --force-remove -- "${INTERNAL_FILES[@]}"
TREE="$(git write-tree)"
COMMIT="$(git commit-tree "$TREE" -p "${REF}^{commit}" -m "Release ${TAG} (public tree: internal-only files removed)")"
unset GIT_INDEX_FILE

git branch -f release "$COMMIT"
echo "release -> $COMMIT (${REF} minus ${#INTERNAL_FILES[@]} internal files)"
