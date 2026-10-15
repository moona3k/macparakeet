#!/usr/bin/env bash
# Bring the fork's main up to date with the original repository and push it.
#
#   origin = moona3k/macparakeet (upstream, read-only for the fork)
#   fork   = your GitHub fork, where all your work lives
#
# Usage (from the repository root, with no uncommitted changes):
#   scripts/dev/sync_upstream.sh
#
# On merge conflicts it stops; resolve them, `git commit`, then run
# `git push fork main`.

set -euo pipefail

UPSTREAM="${UPSTREAM:-origin}"
FORK="${FORK:-fork}"
BRANCH="${BRANCH:-main}"

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Commit or stash your changes first (git status)." >&2
  exit 1
fi

git fetch "$UPSTREAM"
git fetch "$FORK"
git checkout -q "$BRANCH"
git merge --ff-only "$FORK/$BRANCH" 2>/dev/null || true

read -r mine theirs < <(git rev-list --left-right --count "HEAD...$UPSTREAM/$BRANCH")
echo "Your commits not upstream: $mine · new upstream commits: $theirs"
if [[ "$theirs" == "0" ]]; then
  echo "Already up to date with $UPSTREAM/$BRANCH."
else
  if ! git merge --no-edit "$UPSTREAM/$BRANCH"; then
    echo >&2
    echo "Merge conflicts. Fix the files git status marks UU, then:" >&2
    echo "  git add <files> && git commit --no-edit && git push $FORK $BRANCH" >&2
    exit 1
  fi
fi

git push "$FORK" "$BRANCH"
echo "Done: $FORK/$BRANCH is up to date."
