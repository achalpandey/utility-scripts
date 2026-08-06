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
#   sandbox.sh rm   <repo> <name|path> [--keep-branch] [--force]  remove a worktree (and nested sub-worktrees)
#   sandbox.sh list                          show all worktrees for both repos
#   sandbox.sh clean [--execute]             remove worktrees whose PRs merged (dry-run by default)
#
# Examples:
#   sandbox.sh init
#   sandbox.sh new llm-gateway feat/rate-limiting
#   sandbox.sh new vachiai.com fix/nav-flicker agent-2
#   sandbox.sh rm llm-gateway feat-rate-limiting            # also removes nested agent sessions
#   sandbox.sh rm llm-gateway investigate-prod-errors --force  # discard uncommitted changes
#   sandbox.sh clean --execute
#
set -euo pipefail

SANDBOX="${SANDBOX_DIR:-$HOME/Sandbox}"

# repo-name|clone-url
REPOS=(
  "llm-gateway|https://github.com/VachiAI/llm-gateway.git"
  "vachiai.com|https://github.com/VachiAI/vachiai.com.git"
)

# Gitignored files to copy from main/ into each new worktree. Paths may be
# nested; .claude/ is gitignored, so project-scope Claude settings can only
# reach a fresh worktree by being copied here.
ENV_FILES=(.env .env.local .env.development .env.development.local .claude/settings.json)

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

worktree_paths() { git -C "$1" worktree list --porcelain | awk '/^worktree /{print $2}'; }

# Emit "<path><TAB><locked 0|1>" per worktree of the repo at $1.
worktree_meta() {
  git -C "$1" worktree list --porcelain | awk '
    /^worktree / { path=$2; locked=0 }
    /^locked/    { locked=1 }
    /^$/         { if (path != "") { print path "\t" locked; path="" } }
    END          { if (path != "") print path "\t" locked }
  '
}

# Count worktrees nested inside dir $1, reading all worktree paths on stdin.
# Agents run sessions in <worktree>/.claude/worktrees/*. Because .claude is
# gitignored, `git status` in the parent reports nothing — so a parent looks
# empty right up until removing it deletes every child on disk and orphans
# their admin entries. Nesting must be checked separately from status.
nested_count() {
  local parent="$1" p n=0
  while IFS= read -r p; do
    if [[ -n "$p" && "$p" != "$parent" && "$p" == "$parent"/* ]]; then n=$((n+1)); fi
  done
  echo "$n"
}

# Nesting depth of worktree $1 = how many of the paths in $2 (newline-separated)
# are strict path-prefixes of it. 0 = top-level worktree, 1 = nested one level
# deep (a .claude/worktrees/* agent session), etc. Used to indent the tree.
wt_depth() {
  local self="$1" all="$2" p d=0
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$self" && "$self" == "$p"/* ]] && d=$((d+1))
  done <<< "$all"
  echo "$d"
}

# Resolve a worktree of repo $1 from the user-supplied name $2, echoing its
# absolute path. Worktrees are NOT all flat siblings: agent sessions live at
# <parent>/.claude/worktrees/<name>, so the path cannot be built from the name
# — it has to be looked up in git's list. Accepts a bare name (matched against
# each worktree's basename), or an absolute/relative path to one. Errors on an
# unknown name, and on an ambiguous one rather than guessing.
resolve_worktree() {
  local main="$1" name="$2" p abs matches=() n
  abs="$(cd "$(dirname -- "$name")" 2>/dev/null && pwd)/$(basename -- "$name")" || abs=""
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$main" ]] || continue
    if [[ "$p" == "$name" || "$p" == "$abs" || "$(basename "$p")" == "$name" ]]; then
      matches+=("$p")
    fi
  done < <(worktree_paths "$main")

  n=${#matches[@]}
  if [[ "$n" -eq 1 ]]; then
    echo "${matches[0]}"
    return 0
  fi
  if [[ "$n" -gt 1 ]]; then
    {
      echo "error: '$name' is ambiguous — $n worktrees share that name:"
      printf '  %s\n' "${matches[@]}"
      echo "Pass the full path to disambiguate."
    } >&2
    exit 1
  fi
  {
    echo "error: no worktree named '$name' in $(basename "$(dirname "$main")")."
    echo "Known worktrees:"
    while IFS= read -r p; do
      [[ -n "$p" && "$p" != "$main" ]] || continue
      printf '  %-44s %s\n' "$(basename "$p")" "${p#"$SANDBOX/"}"
    done < <(worktree_paths "$main")
  } >&2
  exit 1
}

# Emit "<path><TAB><short-sha><TAB><branch>" per worktree, in git's listing
# order (parents precede the children nested under them).
worktree_rows() {
  git -C "$1" worktree list --porcelain | awk '
    /^worktree /{p=substr($0,10)}
    /^HEAD /    {h=substr($0,6,7)}
    /^branch /  {b=$2; sub("refs/heads/","",b)}
    /^detached/ {b="(detached)"}
    /^bare/     {b="(bare)"}
    /^$/        {if(p!=""){print p"\t"h"\t"b; p="";h="";b=""}}
    END         {if(p!="") print p"\t"h"\t"b}
  '
}

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
      mkdir -p "$(dirname "$wt/$f")"   # entries may be nested, e.g. .claude/settings.json
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
  local repo="${1:-}" name="${2:-}"
  shift 2 2>/dev/null || true
  local keep="" force=""
  for arg in "$@"; do
    case "$arg" in
      --keep-branch) keep="--keep-branch" ;;
      --force|-f)    force=1 ;;
      *) err "unknown option: $arg" ;;
    esac
  done
  [[ -n "$repo" && -n "$name" ]] || usage
  require_main "$repo"
  [[ "$name" != "main" ]] || err "refusing to remove the primary clone"

  local main wt
  main="$(main_dir "$repo")"
  wt="$(resolve_worktree "$main" "$name")" || exit 1

  # Collect target + any nested worktrees with their branch names in ONE pass
  # from git's list, before any removal.  Reading branches here (not later via
  # git -C <path>) means we still have them even if a directory is already gone
  # from a prior incomplete rm, or after the parent is removed first.
  local -a rm_paths=() rm_branches=()
  local _p _b
  while IFS=$'\t' read -r _p _b; do
    [[ "$_p" == "$wt" || "$_p" == "$wt"/* ]] || continue
    rm_paths+=("$_p")
    rm_branches+=("$_b")
  done < <(git -C "$main" worktree list --porcelain | awk '
    /^worktree / { p = substr($0, 10); b = "" }
    /^branch /   { b = $2; sub("refs/heads/", "", b) }
    /^$/         { if (p != "") { print p "\t" b }; p = ""; b = "" }
    END          { if (p != "") print p "\t" b }
  ')

  local n_total=${#rm_paths[@]}
  [[ "$n_total" -gt 0 ]] || err "worktree '$name' not found in git's list — run: sandbox.sh clean"
  if [[ "$n_total" -gt 1 ]]; then
    info "will remove $name and $((n_total - 1)) nested sub-worktree(s)"
  fi

  # Require --force if any worktree in the set has uncommitted changes.
  if [[ -z "$force" ]]; then
    local -a dirty=()
    local _i
    for ((_i = 0; _i < n_total; _i++)); do
      local _d="${rm_paths[$_i]}"
      [[ -d "$_d" ]] || continue
      [[ -n "$(git -C "$_d" status --porcelain 2>/dev/null)" ]] && dirty+=("$(basename "$_d")")
    done
    if [[ "${#dirty[@]}" -gt 0 ]]; then
      echo "error: the following worktree(s) have uncommitted changes:" >&2
      printf '  %s\n' "${dirty[@]}" >&2
      echo "Commit/push first, or pass --force to discard." >&2
      exit 1
    fi
  fi

  # Sort removal order deepest-first by path length so children are always
  # unregistered before their parent directory disappears — regardless of the
  # order git listed them (which is not guaranteed to be parent-before-child).
  local -a order=()
  while IFS=$'\t' read -r _ _i; do
    order+=("$_i")
  done < <(for ((_i = 0; _i < n_total; _i++)); do
    printf '%d\t%d\n' "${#rm_paths[$_i]}" "$_i"
  done | sort -rn)

  # Remove each worktree.  If the directory is already gone (prior incomplete
  # rm), skip the remove call — prune below will clean up the admin entry.
  local _i
  for _i in "${order[@]}"; do
    local _p="${rm_paths[$_i]}"
    if [[ -d "$_p" ]]; then
      # --force accepts ignored/untracked files; committed work is in the repo.
      git -C "$main" worktree remove --force "$_p" 2>/dev/null || true
    fi
    info "removed worktree $(basename "$_p")"
  done

  # Prune orphaned admin entries left by this run or any prior incomplete one.
  git -C "$main" worktree prune 2>/dev/null || true

  # Delete branches after all worktrees are gone (safe: no checkout conflict).
  if [[ "$keep" != "--keep-branch" ]]; then
    local _i
    for ((_i = 0; _i < n_total; _i++)); do
      local _b="${rm_branches[$_i]}"
      [[ -n "$_b" ]] || continue
      if git -C "$main" branch -d "$_b" 2>/dev/null; then
        info "deleted branch $_b"
      else
        info "kept branch $_b (unmerged — delete with: git -C $main branch -D $_b)"
      fi
    done
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

    # Worktrees whose directory is gone (e.g. a parent worktree holding nested
    # .claude/worktrees/* was deleted) leave behind stale admin entries. Their
    # branches survive the prune, so unmerged work is never at risk here.
    local stale
    stale="$(git -C "$main" worktree list --porcelain | grep -c '^prunable ' || true)"
    if [[ "$stale" -gt 0 ]]; then
      if $dry; then
        echo "  would prune $stale stale worktree entry(s) (directory no longer exists):"
        git -C "$main" worktree prune -n -v | sed 's/^/    /'
      else
        echo "  pruning $stale stale worktree entry(s) (directory no longer exists)"
        git -C "$main" worktree prune -v | sed 's/^/    /'
      fi
    fi

    local ahead nested locked wt_paths
    wt_paths="$(worktree_paths "$main")"

    local depth pad
    while IFS=$'\t' read -r wt locked; do
      [[ "$wt" == "$main" ]] && continue

      # Indent each entry under its parent so the output reads as a tree:
      # top-level worktrees flush-left, nested agent sessions stepped in.
      depth="$(wt_depth "$wt" "$wt_paths")"
      pad="$(printf '%*s' $((depth * 2)) '')"
      [[ "$depth" -gt 0 ]] && pad="$pad└ "

      # A missing directory means the entry is stale, not detached. Skip it
      # rather than misreporting it — the prune above is what clears these.
      if [[ ! -d "$wt" ]]; then
        echo "${pad}skip (stale entry, directory missing): $(basename "$wt")"
        continue
      fi

      branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || true)"

      # Hosting nested worktrees outranks every check below: the status check
      # cannot see them (.claude is gitignored), so an empty-looking parent may
      # still hold active agent sessions. Removing it would destroy them.
      nested="$(nested_count "$wt" <<< "$wt_paths")"
      if [[ "$nested" -gt 0 ]]; then
        echo "${pad}keep (hosts $nested nested worktree(s)): $(basename "$wt")${branch:+ [$branch]}"
        continue
      fi

      # A live claude session holds a worktree lock.
      if [[ "$locked" == "1" ]]; then
        echo "${pad}keep (locked by an active session): $(basename "$wt")${branch:+ [$branch]}"
        continue
      fi

      [[ -n "$branch" ]] || { echo "${pad}keep (detached HEAD): $(basename "$wt")"; continue; }

      # Dirty worktrees are never touched
      if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "${pad}keep (uncommitted changes): $(basename "$wt") [$branch]"
        continue
      fi

      # Commits unique to this branch vs origin/$base. 0 means the branch is
      # still sitting at base — a fresh worktree with no work yet, NOT merged.
      ahead="$(git -C "$wt" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 0)"

      # Mergeable? Prefer PR state from GitHub; fall back to ancestry check.
      state="$(cd "$wt" && gh pr view "$branch" --json state --jq .state 2>/dev/null || echo NONE)"
      reason=""
      if [[ "$state" == "MERGED" ]]; then
        reason="PR merged"
      elif [[ "$state" == "NONE" && "$ahead" == "0" ]]; then
        # No PR and no commits beyond base — brand-new branch, keep it.
        echo "${pad}keep (new branch, no commits yet): $(basename "$wt") [$branch]"
        continue
      elif [[ "$state" == "NONE" ]] && git -C "$main" merge-base --is-ancestor "$branch" "origin/$base" 2>/dev/null; then
        reason="merged into origin/$base"
      elif [[ "$state" == "NONE" ]] && [[ -z "$(git -C "$wt" diff "origin/$base" HEAD 2>/dev/null)" ]]; then
        # Squash-merged branches aren't ancestors of base (the commits differ)
        # and gh reports NONE (the PR's head was another branch). But their tree
        # is identical to origin/$base — nothing unique would be lost. An empty
        # tree-diff proves content-equality, so removal is safe.
        reason="fully merged (tree identical to origin/$base — squash-merge)"
      else
        echo "${pad}keep (PR state: $state, $ahead commit(s) ahead of origin/$base): $(basename "$wt") [$branch]"
        continue
      fi

      if $dry; then
        echo "${pad}would remove: $(basename "$wt") [$branch] ($reason)"
      else
        echo "${pad}removing: $(basename "$wt") [$branch] ($reason)"
        git -C "$main" worktree remove --force "$wt"
        git -C "$main" branch -D "$branch" 2>/dev/null || true
        # Delete remote branch if it still exists (no-op if GitHub auto-deleted)
        if git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git -C "$main" push origin --delete "$branch" 2>/dev/null || true
        fi
      fi
    done < <(worktree_meta "$main")
    echo
  done
  $dry && info "dry run — re-run with: sandbox.sh clean --execute"
  return 0
}

cmd_list() {
  local entry name main paths wt sha branch depth pad label
  for entry in "${REPOS[@]}"; do
    name="${entry%%|*}"
    main="$(main_dir "$name")"
    echo "── $name ─────────────────────────"
    if [[ ! -e "$main/.git" ]]; then
      echo "(not cloned — run: sandbox.sh init)"
      echo
      continue
    fi
    paths="$(worktree_paths "$main")"
    while IFS=$'\t' read -r wt sha branch; do
      depth="$(wt_depth "$wt" "$paths")"
      pad="$(printf '%*s' $((depth * 2)) '')"
      if [[ "$depth" -eq 0 ]]; then
        label="$(basename "$wt")"
      else
        # Nested agent sessions live under <parent>/.claude/worktrees/<name>;
        # show just the leaf and mark it as a child of the parent above.
        label="└ $(basename "$wt")"
      fi
      printf '%s%-40s %s  [%s]\n' "$pad" "$label" "$sha" "$branch"
    done < <(worktree_rows "$main")
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
