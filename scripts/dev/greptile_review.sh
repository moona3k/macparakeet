#!/usr/bin/env bash
set -euo pipefail

# Run Greptile's local code review in agent-friendly plain text.
# Usage: scripts/dev/greptile_review.sh [base-branch] [extra greptile args...]
# If the first argument starts with "-", origin/main remains the base and all
# arguments are forwarded to Greptile.
#
# Greptile reviews committed branch changes only; uncommitted changes are
# ignored. Run it from the worktree/branch that owns the PR.

cd "$(dirname "$0")/../.."

if ! command -v greptile >/dev/null 2>&1; then
  echo "greptile CLI not found. Install with: npm i -g greptile" >&2
  exit 127
fi

base="origin/main"
if [[ $# -gt 0 && "$1" != -* ]]; then
  base="$1"
  shift
fi

if [[ "$base" == */* ]]; then
  remote="${base%%/*}"
  remote_branch="${base#*/}"
  if git remote get-url "$remote" >/dev/null 2>&1; then
    git fetch "$remote" "$remote_branch" \
      || echo "Warning: git fetch failed; reviewing against local $base" >&2
  else
    echo "Warning: remote '$remote' not found; reviewing against local $base" >&2
  fi
fi

printf '==> greptile review -b %q --agent --no-color' "$base"
if [[ $# -gt 0 ]]; then
  printf ' %q' "$@"
fi
printf '\n'
greptile review -b "$base" --agent --no-color "$@"
