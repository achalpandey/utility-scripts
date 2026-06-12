#!/usr/bin/env bash
#
# sandbox.sh — multi-agent git worktree manager for ~/Sandbox
#
# Layout it creates/manages:
#   ~/Sandbox/
#     llm-gateway/
#       main/        <- primary clone (stays on default branch)
#       <agent>/     <- one worktree per agent task
#     vachiai.com/
#       main/
#       <agent>/
#
# Usage:
#   sandbox.sh init                          clone both repos into ~/Sandbox
#   sandbox.sh new  <repo> <branch> [name]   create agent worktree off origin/<default>
#   sandbox.sh rm   <repo> <name> [--keep-branch]   remove a worktree (and its branch)
#   sandbox.sh list                          show all worktrees for both repos
#   sandbox.sh clean [--execute]             remove worktrees whose PRs merged (dry-run by default)
#
# Examples:
#   sandbox.sh init
#   sandbox.sh new llm-gateway feat/rate-limiting
#   sandbox.sh new vachiai.com fix/nav-flicker agent-2
#   sandbox.sh rm llm-gateway feat-rate-limiting
#   sandbox.sh clean --execute
#
set -euo pipefail

SANDBOX="${SANDBOX_DIR:-$HOME/Sandbox}"

# repo-name|clone-url
REPOS=(
  "llm-gateway|https://github.com/VachiAI/llm-gateway.git"
  "vachiai.com|https://github.com/VachiAI/vachiai.com.git"
)

# Gitignored files to copy from main/ into each new worktree
ENV_FILES=(.env .env.local .env.development .env.development.local)

err()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

repo_url() {
  local entry
  for entry in "${REPOS[@]}"; do
    [[ "${entry%%|*}" == "$1" ]] && { echo "${entry##*|}"; return 0; }
  done
  err "unknown repo '$1' (known: $(printf '%s ' "${REPOS[@]%%|*}"))"
}

main_dir() { echo "$SANDBOX/$1/main"; }

require_main() {
  [[ -e "$(main_dir "$1")/.git" ]] || err "$1 not cloned yet — run: sandbox.sh init"
}

default_branch() {
  # e.g. "main" or "master", taken from origin/HEAD
  git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^origin/||' || echo main
}

copy_env_files() {
  local main="$1" wt="$2" f copied=0
  for f in "${ENV_FILES[@]}"; do
    if [[ -f "$main/$f" && ! -f "$wt/$f" ]]; then
      cp "$main/$f" "$wt/$f"
      info "copied $f"
      copied=1
    fi
  done
  [[ $copied -eq 1 ]] && info "NOTE: check ports/credentials in copied env files if agents run services concurrently"
  return 0
}

install_deps() {
  local dir="$1"
  if   [[ -f "$dir/pnpm-lock.yaml"    ]]; then info "installing deps (pnpm)"; (cd "$dir" && pnpm install)
  elif [[ -f "$dir/package-lock.json" ]]; then info "installing deps (npm)";  (cd "$dir" && npm ci)
  elif [[ -f "$dir/yarn.lock"         ]]; then info "installing deps (yarn)"; (cd "$dir" && yarn install)
  elif [[ -f "$dir/package.json"      ]]; then info "installing deps (npm)";  (cd "$dir" && npm install)
  fi
  if [[ -f "$dir/uv.lock" ]] && command -v uv >/dev/null; then
    info "installing deps (uv)"; (cd "$dir" && uv sync)
  else
    # Python apps may live at the root or nested (e.g. apps/*/requirements.txt).
    # Create a gitignored venv/ next to each requirements.txt found.
    local req app
    while IFS= read -r req; do
      app="$(dirname "$req")"
      # Prefer requirements-dev.txt (includes test deps) when present
      [[ -f "$app/requirements-dev.txt" ]] && req="$app/requirements-dev.txt"
      if [[ ! -x "$app/venv/bin/python" ]]; then
        info "creating venv + installing $(basename "$req") in ${app#"$dir"/}"
        python3 -m venv "$app/venv"
        "$app/venv/bin/pip" install -q -r "$req"
      fi
    done < <(find "$dir" -maxdepth 3 -name requirements.txt \
               -not -path '*/node_modules/*' -not -path '*/venv/*' -not -path '*/.venv/*' 2>/dev/null)
  fi
}

cmd_init() {
  mkdir -p "$SANDBOX"
  local entry name url dir
  for entry in "${REPOS[@]}"; do
    name="${entry%%|*}" url="${entry##*|}" dir="$SANDBOX/$name/main"
    if [[ -e "$dir/.git" ]]; then
      info "$name already cloned, skipping"
    else
      info "cloning $name"
      git clone "$url" "$dir"
    fi
    install_deps "$dir"
  done
  info "done. Sandbox ready at $SANDBOX"
}

cmd_new() {
  local repo="${1:-}" branch="${2:-}" name="${3:-}"
  [[ -n "$repo" && -n "$branch" ]] || usage
  repo_url "$repo" >/dev/null
  require_main "$repo"

  # worktree dir name defaults to branch with '/' -> '-'
  [[ -n "$name" ]] || name="${branch//\//-}"
  [[ "$name" != "main" ]] || err "'main' is reserved for the primary clone"

  local main wt base
  main="$(main_dir "$repo")"
  wt="$SANDBOX/$repo/$name"
  [[ ! -e "$wt" ]] || err "$wt already exists"

  info "fetching origin"
  git -C "$main" fetch origin --prune
  base="$(default_branch "$main")"

  if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    info "branch '$branch' exists, checking it out in new worktree"
    git -C "$main" worktree add "$wt" "$branch"
  else
    info "creating worktree '$name' on new branch '$branch' from origin/$base"
    git -C "$main" worktree add "$wt" -b "$branch" "origin/$base"
  fi

  copy_env_files "$main" "$wt"
  install_deps "$wt"

  info "ready: $wt  (branch: $branch)"
  echo "    cd $wt"
}

cmd_rm() {
  local repo="${1:-}" name="${2:-}" keep="${3:-}"
  [[ -n "$repo" && -n "$name" ]] || usage
  require_main "$repo"
  [[ "$name" != "main" ]] || err "refusing to remove the primary clone"

  local main wt branch
  main="$(main_dir "$repo")"
  wt="$SANDBOX/$repo/$name"
  [[ -d "$wt" ]] || err "no worktree at $wt"

  branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"

  # Block if there are modified or untracked (non-ignored) files
  if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
    err "$name has uncommitted or untracked changes — commit/push them first, or remove manually with: git -C $main worktree remove --force $wt"
  fi

  # --force is needed because ignored files (node_modules, .env) are expected;
  # committed work is safe regardless — it lives in the shared repo.
  git -C "$main" worktree remove --force "$wt"
  info "removed worktree $name"

  if [[ -n "$branch" && "$keep" != "--keep-branch" ]]; then
    if git -C "$main" branch -d "$branch" 2>/dev/null; then
      info "deleted branch $branch"
    else
      info "kept branch $branch (not fully merged — delete with: git -C $main branch -D $branch)"
    fi
  fi
}

cmd_clean() {
  # Remove worktrees whose branch's PR is merged (or whose branch is fully
  # merged into the default branch), then delete local + stale remote refs.
  # Dry-run unless --execute is passed.
  local dry=true
  [[ "${1:-}" == "--execute" || "${1:-}" == "-x" ]] && dry=false
  command -v gh >/dev/null || err "gh CLI required for clean"

  local entry repo main base wt branch state reason
  for entry in "${REPOS[@]}"; do
    repo="${entry%%|*}"
    main="$(main_dir "$repo")"
    [[ -e "$main/.git" ]] || continue
    echo "── $repo ─────────────────────────"
    git -C "$main" fetch origin --prune --quiet
    base="$(default_branch "$main")"

    while read -r wt; do
      [[ "$wt" == "$main" ]] && continue
      branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"
      [[ -n "$branch" ]] || { echo "  keep (detached HEAD): $(basename "$wt")"; continue; }

      # Dirty worktrees are never touched
      if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "  keep (uncommitted changes): $(basename "$wt") [$branch]"
        continue
      fi

      # Mergeable? Prefer PR state from GitHub; fall back to ancestry check.
      state="$(cd "$wt" && gh pr view "$branch" --json state --jq .state 2>/dev/null || echo NONE)"
      reason=""
      if [[ "$state" == "MERGED" ]]; then
        reason="PR merged"
      elif [[ "$state" == "NONE" ]] && git -C "$main" merge-base --is-ancestor "$branch" "origin/$base" 2>/dev/null; then
        reason="merged into origin/$base"
      else
        echo "  keep (PR state: $state): $(basename "$wt") [$branch]"
        continue
      fi

      if $dry; then
        echo "  would remove: $(basename "$wt") [$branch] ($reason)"
      else
        echo "  removing: $(basename "$wt") [$branch] ($reason)"
        git -C "$main" worktree remove --force "$wt"
        git -C "$main" branch -D "$branch" 2>/dev/null || true
        # Delete remote branch if it still exists (no-op if GitHub auto-deleted)
        if git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git -C "$main" push origin --delete "$branch" 2>/dev/null || true
        fi
      fi
    done < <(git -C "$main" worktree list --porcelain | awk '/^worktree /{print $2}')
    echo
  done
  $dry && info "dry run — re-run with: sandbox.sh clean --execute"
  return 0
}

cmd_list() {
  local entry name
  for entry in "${REPOS[@]}"; do
    name="${entry%%|*}"
    echo "── $name ─────────────────────────"
    if [[ -e "$(main_dir "$name")/.git" ]]; then
      git -C "$(main_dir "$name")" worktree list
    else
      echo "(not cloned — run: sandbox.sh init)"
    fi
    echo
  done
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  new)  shift; cmd_new  "$@" ;;
  rm)   shift; cmd_rm   "$@" ;;
  list) shift; cmd_list "$@" ;;
  clean) shift; cmd_clean "$@" ;;
  *) usage ;;
esac
