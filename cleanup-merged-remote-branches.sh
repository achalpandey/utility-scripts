#!/bin/bash
set -euo pipefail

# One-time cleanup: delete remote branches whose most recent PR was MERGED.
#
# For every branch on origin (except main/master/HEAD), asks GitHub for the
# most recent PR with that branch as head:
#   - MERGED  -> delete the remote branch
#   - OPEN    -> keep (work in flight)
#   - CLOSED  -> keep (closed without merge — might still matter; review manually)
#   - no PR   -> keep (never went through a PR)
#
# Runs against both repos in ~/Sandbox by default, or pass repo paths.
# Dry-run by default — pass --execute to actually delete.
#
# Usage:
#   ./cleanup-merged-remote-branches.sh [--execute] [repo-path ...]

DRY_RUN=true
REPO_PATHS=()

for arg in "$@"; do
  case "$arg" in
    --execute|-x) DRY_RUN=false ;;
    -h|--help) sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) REPO_PATHS+=("$arg") ;;
  esac
done

if [ ${#REPO_PATHS[@]} -eq 0 ]; then
  SANDBOX="${SANDBOX_DIR:-$HOME/Sandbox}"
  REPO_PATHS=("$SANDBOX/llm-gateway/main" "$SANDBOX/vachiai.com/main")
fi

command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI required" >&2; exit 1; }

total_deleted=0

for repo in "${REPO_PATHS[@]}"; do
  echo "── $repo ─────────────────────────"
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "  skip: not a git repo"; echo; continue
  fi

  git -C "$repo" fetch --prune --quiet origin

  while read -r ref; do
    branch="${ref#refs/remotes/origin/}"
    case "$branch" in HEAD|main|master) continue ;; esac

    # Most recent PR (any state) with this branch as head
    state=$(cd "$repo" && gh pr view "$branch" --json state --jq .state 2>/dev/null || echo "NONE")

    case "$state" in
      MERGED)
        if $DRY_RUN; then
          echo "  would delete: origin/$branch (PR merged)"
        else
          echo "  deleting: origin/$branch (PR merged)"
          git -C "$repo" push origin --delete "$branch"
        fi
        total_deleted=$((total_deleted + 1))
        ;;
      OPEN)   echo "  keep (open PR): $branch" ;;
      CLOSED) echo "  keep (PR closed without merge — review manually): $branch" ;;
      *)      echo "  keep (no PR found): $branch" ;;
    esac
  done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes/origin)
  echo
done

if $DRY_RUN; then
  echo "Dry run: $total_deleted branch(es) would be deleted. Re-run with --execute to apply."
else
  echo "Done: $total_deleted branch(es) deleted."
fi
