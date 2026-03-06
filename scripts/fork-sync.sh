#!/usr/bin/env bash
set -euo pipefail

fork_branch="${1:-glossolalia}"
upstream_remote="${UPSTREAM_REMOTE:-upstream}"
upstream_branch="${UPSTREAM_BRANCH:-main}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "worktree is dirty; commit or stash before rebasing" >&2
  exit 1
fi

git fetch "$upstream_remote" "$upstream_branch"
git fetch origin "$fork_branch"
git checkout "$fork_branch"

if ! git rebase "$upstream_remote/$upstream_branch"; then
  echo
  echo "rebase stopped on conflicts"
  echo "resolve conflicts, then run: git rebase --continue"
  echo "abort with: git rebase --abort"
  exit 1
fi

echo "rebased $fork_branch onto $upstream_remote/$upstream_branch"
