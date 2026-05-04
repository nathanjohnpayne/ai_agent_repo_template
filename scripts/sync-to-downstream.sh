#!/usr/bin/env bash
# scripts/sync-to-downstream.sh — propagate Mergepath template changes
# to downstream consumer repos. See #168 for the design.
#
# This script is shipping in layers (per the issue's implementation plan):
#
#   v1 (PR #215):
#     --audit            Read-only drift detector across all consumers.
#
#   v2 (this PR — Layer 3 first slice):
#     <commit-ish>       Open propagation PRs for canonical files changed
#                        at the given commit. Kit and templated paths are
#                        skipped with a warning (deferred to slice 2/3).
#
#   future:
#     --from-pr <N>      Resolve PR N's merge commit and propagate
#                        (Layer 4).
#     templated paths    Three-way merge for review-policy.yml; substitution
#                        rules for AGENTS.md / CLAUDE.md (Layer 5, shared
#                        with bootstrap-new-repo.sh #156).
#     kit paths          Directory mirror with allow-extras semantics in
#                        sync mode (slice 2 — already supported in audit).
#
# The manifest at .mergepath-sync.yml declares which paths are canonical
# (byte-identical) or kit (directory mirror with allow-extras), and which
# consumers opt in. Templated paths are reserved for Layer 5 and rejected
# until the substitution lib lands.
#
# Usage:
#   scripts/sync-to-downstream.sh --audit [--repos r1,r2] [--paths glob]
#   scripts/sync-to-downstream.sh <commit-ish> [--dry-run] [--repos r1,r2] [--paths glob]
#   scripts/sync-to-downstream.sh --help
#   scripts/sync-to-downstream.sh --version
#
# Flags:
#   --audit            Read-only drift detection. Exit 0 (clean), 1 (drift),
#                      2 (script/usage error), 3 (consumer fetch error).
#   --dry-run          Sync mode only. Print the per-consumer plan
#                      (branch name, files) without cloning, committing,
#                      pushing, or creating PRs. Idempotency check is
#                      skipped because it probes the consumer repo via
#                      `gh api`; a dry-run plan may show "would open PR"
#                      even when a PR already exists, but the live run
#                      will catch and skip it.
#   --repos r1,r2      Restrict to a comma-separated subset of consumer names.
#   --paths glob       Restrict to manifest paths matching the glob (e.g.
#                      "scripts/*", ".github/workflows/agent-review.yml").
#   --no-clone         Audit only: don't clone-on-demand; only audit
#                      consumers with a local sibling worktree under
#                      MERGEPATH_SIBLINGS_DIR.
#   --no-refresh       Audit only: don't `git fetch` cached consumer clones
#                      before comparing. Useful for offline/sandboxed
#                      audits; may report stale results if the cache is old.
#   --help, -h         Show this help.
#   --version          Print version info.
#
# Environment:
#   MERGEPATH_SIBLINGS_DIR  Default: $HOME/GitHub. If a `.git` entry at
#                           $MERGEPATH_SIBLINGS_DIR/<consumer-name>/.git
#                           exists (directory OR file — git worktrees use
#                           a `.git` file), the audit reads from that
#                           local clone (using the working tree as-is —
#                           drift against your uncommitted edits is
#                           intentional behavior; run `git stash` first
#                           if you want main only). Sibling clones are
#                           never auto-fetched/reset; that's the user's
#                           working tree.
#                           If the local clone is missing, the script
#                           falls back to a cache clone under
#                           MERGEPATH_SYNC_CACHE.
#   MERGEPATH_SYNC_CACHE    Default: $HOME/.cache/mergepath-sync. Cache dir
#                           for clone-on-demand. Per-consumer subdir holds
#                           a depth=1 fetch of the consumer's default
#                           branch. Cached clones are refreshed via
#                           `git fetch && git reset --hard origin/HEAD`
#                           before each audit (suppress with --no-refresh).
#
# Prerequisites:
#   yq (mikefarah/yq, v4+)  brew install yq
#   git, gh                 standard mergepath agent prerequisites
#
# Exit codes:
#   0   Audit clean OR help/version printed.
#   1   Audit found drift on at least one consumer × path.
#   2   Usage error or missing prerequisite (yq, manifest, etc.).
#   3   Fetch error (could not access a consumer's repo).

set -euo pipefail

# --- constants --------------------------------------------------------------

SCRIPT_VERSION="0.2.0-layer3-canonical"
SUPPORTED_MANIFEST_VERSION=1
MANIFEST_PATH=".mergepath-sync.yml"
SYNC_BRANCH_PREFIX="mergepath-sync"

# Resolve the Mergepath worktree root from the script's location (works
# regardless of cwd). Two `dirname`s: scripts/sync-to-downstream.sh →
# scripts/ → repo root. Tests can override with MERGEPATH_ROOT_OVERRIDE
# to point the script at a synthetic fixture worktree.
MERGEPATH_ROOT="${MERGEPATH_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- logging ----------------------------------------------------------------

log() { echo "[sync-to-downstream] $*" >&2; }
warn() { echo "[sync-to-downstream] WARN: $*" >&2; }
err() { echo "[sync-to-downstream] ERROR: $*" >&2; }

usage() {
  # Print everything between the first `# Usage:` line and the next blank
  # comment-divider line. Keeps the help text and the script header in
  # lockstep — there's exactly one place to edit when flags change.
  sed -n '
    /^# Usage:/,/^$/{
      /^# */{
        s/^# *//
        p
      }
    }
  ' "${BASH_SOURCE[0]}"
}

# --- prerequisite check -----------------------------------------------------

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    err "yq is required but not installed."
    err "  brew install yq"
    err "(uses mikefarah/yq v4+. Pure-Python yq from kislyuk/yq is NOT compatible — different syntax.)"
    exit 2
  fi
  # Sanity check: mikefarah/yq prints "yq (https://github.com/mikefarah/yq/) version vX.Y.Z"
  # while kislyuk/yq (pip-installed Python version) prints "yq <semver>" with no URL.
  # Reject the wrong yq early to avoid mysterious parse failures later.
  if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
    err "Detected yq from a non-mikefarah source. Install via 'brew install yq' for the Go binary."
    err "  yq --version: $(yq --version 2>&1)"
    exit 2
  fi
}

require_manifest() {
  local f="$MERGEPATH_ROOT/$MANIFEST_PATH"
  if [ ! -f "$f" ]; then
    err "manifest missing: $MANIFEST_PATH"
    exit 2
  fi
  local v
  v=$(yq '.version' "$f")
  if [ "$v" != "$SUPPORTED_MANIFEST_VERSION" ]; then
    err "manifest version $v not supported by this script (supports: $SUPPORTED_MANIFEST_VERSION)"
    err "Either upgrade scripts/sync-to-downstream.sh or pin the manifest schema."
    exit 2
  fi
}

# --- consumer worktree resolution -------------------------------------------

# Echo the path on disk where we should read the consumer's working tree.
# Returns 0 if found, 1 if not. The caller distinguishes cache vs.
# sibling by comparing the returned path's prefix against
# MERGEPATH_SYNC_CACHE — see the helper `path_is_in_cache` below.
# (An earlier draft used a $RESOLVED_FROM global, but the function is
# called via command substitution which runs in a subshell, swallowing
# the assignment. Encoding the answer in the path is subshell-safe.)
#
# Accepts both `.git` directory (regular clone) and `.git` file (git
# worktree). Codex P2 on PR #215 caught the worktree case — the original
# `-d` test misclassified worktrees as missing.
resolve_consumer_worktree() {
  local consumer_name=$1
  local siblings_dir=${MERGEPATH_SIBLINGS_DIR:-$HOME/GitHub}
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  if [ -e "$siblings_dir/$consumer_name/.git" ]; then
    echo "$siblings_dir/$consumer_name"
    return 0
  fi
  if [ -e "$cache_dir/$consumer_name/.git" ]; then
    echo "$cache_dir/$consumer_name"
    return 0
  fi
  return 1
}

# Lexical prefix check: does $1 live under MERGEPATH_SYNC_CACHE?
# Trailing slash on the cache root makes the prefix unambiguous so a
# sibling dir whose name happens to match the cache-dir prefix can't
# false-match.
path_is_in_cache() {
  local p=$1
  local cache_root=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}
  [[ "$p" == "$cache_root"/* ]]
}

# Bring a cached clone up to date with the consumer's default branch.
# Skipped silently if the path was resolved from a sibling worktree —
# refreshing a user's working tree would clobber uncommitted edits.
# Codex P1 on PR #215 caught the stale-cache hazard.
#
# Symlink guard (cursor CHANGES_REQUESTED on PR #215): a user who
# symlinks $MERGEPATH_SYNC_CACHE/<consumer> at their sibling clone
# (or vice versa) would otherwise have their working tree reset by
# the `git reset --hard` below. Resolve the physical path of the
# cache entry and the cache root, then refuse to refresh if the
# entry escapes the cache root. This catches both direct symlinks
# (cache_path itself is a symlink) and indirect symlinks
# (any ancestor in the path is symlinked elsewhere).
refresh_cached_clone() {
  local cache_path=$1
  local cache_root=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  # Direct-symlink guard: if the cache entry itself is a symlink, the
  # `git reset --hard` below would clobber whatever it points at. Refuse.
  if [ -L "$cache_path" ]; then
    err "refusing to refresh $cache_path — it is a symbolic link."
    err "       \`git reset --hard\` would clobber the symlink target,"
    err "       which is likely a sibling/user clone. Remove the symlink"
    err "       (the script will re-clone into the cache) or run with"
    err "       --no-refresh."
    return 3
  fi

  # Ancestor-symlink guard: if `cd && pwd -P` resolves to a path
  # outside the cache root, an ancestor in the path is symlinked
  # elsewhere. `pwd -P` is POSIX and resolves all symlinks; macOS
  # `realpath` lacks `-P` so we don't use it. cursor's
  # CHANGES_REQUESTED on PR #215 found this attack surface.
  local phys_path phys_root
  phys_path=$(cd "$cache_path" 2>/dev/null && pwd -P) || phys_path=""
  phys_root=$(cd "$cache_root" 2>/dev/null && pwd -P) || phys_root="$cache_root"

  if [ -z "$phys_path" ] || [[ "$phys_path" != "$phys_root"/* && "$phys_path" != "$phys_root" ]]; then
    err "refusing to refresh $cache_path — physical path ($phys_path)"
    err "       resolves outside MERGEPATH_SYNC_CACHE ($phys_root)."
    err "       Some ancestor of the cache entry is symlinked elsewhere."
    err "       Run with --no-refresh, or rebuild MERGEPATH_SYNC_CACHE"
    err "       without symlinks."
    return 3
  fi

  log "refreshing cached clone at $cache_path"
  # `origin/HEAD` is set by `gh repo clone`'s underlying `git clone` to
  # the consumer's default branch. Resetting hard is safe here: this
  # directory is the script's cache, not the user's worktree.
  if ! git -C "$cache_path" fetch --depth=1 --quiet origin >&2; then
    err "git fetch failed for cached clone $cache_path"
    return 3
  fi
  if ! git -C "$cache_path" reset --hard --quiet origin/HEAD >&2; then
    err "git reset --hard origin/HEAD failed for $cache_path"
    return 3
  fi
}

# Clone-on-demand into the cache. Depth=1 is fine for audit; we only
# need HEAD content. Returns the resolved path on stdout.
clone_consumer_to_cache() {
  local consumer_name=$1
  local consumer_repo=$2
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}
  local target="$cache_dir/$consumer_name"

  mkdir -p "$cache_dir"
  log "cloning $consumer_repo into $target (depth=1)"
  if ! gh repo clone "$consumer_repo" "$target" -- --depth=1 --quiet >&2; then
    err "could not clone $consumer_repo — check gh auth and repo permissions"
    return 3
  fi
  echo "$target"
}

# --- path-type-aware comparison --------------------------------------------

# Compare a single canonical (byte-for-byte) file. Outputs a status line
# tag in $REPLY: "ok" / "drift:<lines>" / "missing".
compare_canonical() {
  local mp_path=$1
  local consumer_root=$2
  local consumer_path="$consumer_root/$mp_path"
  local mp_full="$MERGEPATH_ROOT/$mp_path"

  if [ ! -e "$consumer_path" ]; then
    REPLY="missing"
    return 0
  fi
  if cmp -s "$mp_full" "$consumer_path"; then
    REPLY="ok"
    return 0
  fi
  # `diff` exits 1 when files differ — combined with `set -o pipefail` that
  # would kill the script. Mask the exit code so the pipeline succeeds.
  local lines
  lines=$( { diff "$mp_full" "$consumer_path" || true; } | wc -l | tr -d ' ')
  REPLY="drift:$lines"
}

# Compare a kit directory: every file under Mergepath's path must
# exist (byte-identical) in the consumer; consumer-only files are
# allowed and ignored. Outputs a status tag in $REPLY:
#   "ok"
#   "missing"           — consumer dir doesn't exist at all
#   "drift:N+M"         — N drifted files, M missing files
compare_kit() {
  local mp_path=$1
  local consumer_root=$2
  local mp_full="$MERGEPATH_ROOT/$mp_path"
  local consumer_full="$consumer_root/$mp_path"

  # Strip trailing slash for find consistency.
  mp_full="${mp_full%/}"
  consumer_full="${consumer_full%/}"

  if [ ! -d "$consumer_full" ]; then
    REPLY="missing"
    return 0
  fi

  local drift_count=0
  local missing_count=0
  # Walk every file under the Mergepath kit. Ignore symlinks and
  # special files — kits are plain script directories.
  while IFS= read -r -d '' f; do
    # Quote inside the expansion so shell glob metacharacters in the
    # path (improbable in this repo, but cheap to be correct) are
    # treated as literals. CodeRabbit nitpick on PR #215.
    local rel="${f#"$mp_full/"}"
    local target="$consumer_full/$rel"
    if [ ! -e "$target" ]; then
      missing_count=$((missing_count + 1))
    elif ! cmp -s "$f" "$target"; then
      drift_count=$((drift_count + 1))
    fi
  done < <(find "$mp_full" -type f -print0)

  if [ "$drift_count" -eq 0 ] && [ "$missing_count" -eq 0 ]; then
    REPLY="ok"
  else
    REPLY="drift:${drift_count}+${missing_count}"
  fi
}

# --- audit driver -----------------------------------------------------------

# Pretty-print one line for a consumer × path result.
emit_status_line() {
  local mp_path=$1
  local status=$2

  local sym detail
  case "$status" in
    ok)
      sym="✓"; detail="in sync"
      ;;
    missing)
      sym="⊘"; detail="missing entirely"
      ;;
    drift:*)
      sym="✗"
      local payload="${status#drift:}"
      if [[ "$payload" == *"+"* ]]; then
        local d="${payload%+*}"
        local m="${payload#*+}"
        detail="drift: $d file(s) drifted, $m file(s) missing"
      else
        detail="drift: $payload diff line(s)"
      fi
      ;;
    *)
      sym="?"; detail="unknown status: $status"
      ;;
  esac
  printf "  %s %-50s %s\n" "$sym" "$mp_path" "$detail"
}

# Filter helpers — return 0 (truthy) if the entry passes the filter,
# 1 otherwise. FILTER_REPOS / FILTER_PATHS are global vars set from CLI.
in_repo_filter() {
  local name=$1
  [ -z "${FILTER_REPOS:-}" ] && return 0
  local re=",$FILTER_REPOS,"
  [[ "$re" == *",$name,"* ]]
}

in_path_filter() {
  local p=$1
  [ -z "${FILTER_PATHS:-}" ] && return 0
  # shellcheck disable=SC2053
  [[ "$p" == ${FILTER_PATHS} ]]
}

# Run the audit. Sets $AUDIT_DRIFT_FOUND=1 if any non-OK status seen.
# Sets $AUDIT_FETCH_ERROR=1 if a consumer was unreachable.
run_audit() {
  AUDIT_DRIFT_FOUND=0
  AUDIT_FETCH_ERROR=0
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  # Pull the consumer list as TSV: name<TAB>repo
  local consumers
  consumers=$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$manifest")

  while IFS=$'\t' read -r consumer_name consumer_repo; do
    [ -z "$consumer_name" ] && continue
    if ! in_repo_filter "$consumer_name"; then
      continue
    fi

    echo "$consumer_name ($consumer_repo)"

    local consumer_root
    if ! consumer_root=$(resolve_consumer_worktree "$consumer_name"); then
      if [ "${AUDIT_NO_CLONE:-0}" = "1" ]; then
        echo "  ! no local worktree for $consumer_name (set MERGEPATH_SIBLINGS_DIR or drop --no-clone)"
        AUDIT_FETCH_ERROR=1
        continue
      fi
      if ! consumer_root=$(clone_consumer_to_cache "$consumer_name" "$consumer_repo"); then
        echo "  ! could not fetch $consumer_repo"
        AUDIT_FETCH_ERROR=1
        continue
      fi
    fi
    # If we're reading from a cache path (vs. a sibling worktree),
    # pull the latest default branch before comparing. Skip for
    # sibling worktrees; that's the user's working tree and must not
    # be auto-reset. Honors --no-refresh for offline / sandboxed runs.
    if path_is_in_cache "$consumer_root" && [ "${AUDIT_NO_REFRESH:-0}" != "1" ]; then
      if ! refresh_cached_clone "$consumer_root"; then
        echo "  ! could not refresh cached clone for $consumer_name"
        AUDIT_FETCH_ERROR=1
        continue
      fi
    fi

    # Walk the manifest's paths. yq emits TSV: path<TAB>type<TAB>consumers_csv
    # where consumers_csv is "all" or a comma-joined list. Per-path
    # exclusions land in Layer 3; for v1 the exclusions block is
    # treated as advisory (still fully audited) so no consumer × path
    # is silently skipped.
    #
    # mikefarah/yq doesn't support jq-style `if/then/else` expressions —
    # we get the same effect via `select(tag == "!!str") // <fallback>`,
    # which yields the original scalar when consumers is a string and
    # the join'd list otherwise.
    local paths
    paths=$(yq -r '
      .paths[]
      | (.path + "\t" + .type + "\t"
         + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
    ' "$manifest")

    while IFS=$'\t' read -r mp_path mp_type mp_consumers; do
      [ -z "$mp_path" ] && continue
      if ! in_path_filter "$mp_path"; then
        continue
      fi
      # Consumer opt-in check
      if [ "$mp_consumers" != "all" ]; then
        local re=",$mp_consumers,"
        if [[ "$re" != *",$consumer_name,"* ]]; then
          continue
        fi
      fi

      case "$mp_type" in
        canonical)
          compare_canonical "$mp_path" "$consumer_root"
          emit_status_line "$mp_path" "$REPLY"
          [ "$REPLY" != "ok" ] && AUDIT_DRIFT_FOUND=1
          ;;
        kit)
          compare_kit "$mp_path" "$consumer_root"
          emit_status_line "$mp_path" "$REPLY"
          [ "$REPLY" != "ok" ] && AUDIT_DRIFT_FOUND=1
          ;;
        templated)
          # Layer 5 territory. Skip with a clear marker so the human
          # sees these entries are intentionally deferred, not silently
          # in-sync.
          printf "  %s %-50s %s\n" "·" "$mp_path" "templated (deferred — Layer 5, #168)"
          ;;
        *)
          err "unknown path type '$mp_type' for $mp_path"
          AUDIT_DRIFT_FOUND=1
          ;;
      esac
    done <<< "$paths"
    echo
  done <<< "$consumers"
}

# --- sync mode --------------------------------------------------------------

# Resolve a Mergepath commit-ish to a full SHA. Errors out if the commit
# isn't reachable. Output: full SHA on stdout.
sync_resolve_commit() {
  local commit_ish=$1
  local sha
  sha=$(git -C "$MERGEPATH_ROOT" rev-parse --verify "$commit_ish^{commit}" 2>/dev/null) || {
    err "could not resolve commit-ish '$commit_ish' in Mergepath worktree"
    return 2
  }
  echo "$sha"
}

# List files that changed at the given commit. Output: one path per line,
# relative to the Mergepath repo root.
sync_changed_files() {
  local sha=$1
  git -C "$MERGEPATH_ROOT" show --name-only --pretty=format: "$sha" \
    | grep -v '^$' || true
}

# Intersect changed files with manifest canonical paths for one consumer.
# Echoes one canonical path per line that (a) exists in the changed-set
# AND (b) the consumer opts in to.
#
# Kit and templated paths are intentionally skipped in this slice. The
# audit mode already reports drift for those; sync mode for them lands in
# slice 2 (kit) and slice 5 (templated). Skipping here is silent per
# manifest path; the per-consumer summary calls out the deferral.
sync_consumer_canonical_targets() {
  local consumer_name=$1
  local changed_files=$2  # newline-separated
  local manifest=$3

  yq -r '
    .paths[]
    | select(.type == "canonical")
    | (.path + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest" | while IFS=$'\t' read -r mp_path mp_consumers; do
    # Path filter
    if ! in_path_filter "$mp_path"; then continue; fi
    # Consumer opt-in
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    # Changed at the commit?
    if grep -Fxq "$mp_path" <<< "$changed_files"; then
      echo "$mp_path"
    fi
  done
}

# Count manifest paths skipped (kit + templated) so the summary can name
# them. Echoes "kit_count\ttemplated_count\tkit_paths\ttemplated_paths".
sync_consumer_skipped_targets() {
  local consumer_name=$1
  local changed_files=$2
  local manifest=$3

  local kit_paths=()
  local templated_paths=()
  while IFS=$'\t' read -r mp_path mp_type mp_consumers; do
    [ -z "$mp_path" ] && continue
    if ! in_path_filter "$mp_path"; then continue; fi
    if [ "$mp_consumers" != "all" ]; then
      local re=",$mp_consumers,"
      [[ "$re" != *",$consumer_name,"* ]] && continue
    fi
    # Did the change touch this path / its directory?
    case "$mp_type" in
      kit)
        local mp_dir="${mp_path%/}"
        if grep -E "^${mp_dir}/" <<< "$changed_files" >/dev/null; then
          kit_paths+=("$mp_path")
        fi
        ;;
      templated)
        if grep -Fxq "$mp_path" <<< "$changed_files"; then
          templated_paths+=("$mp_path")
        fi
        ;;
    esac
  done < <(yq -r '
    .paths[]
    | (.path + "\t" + .type + "\t"
       + (.consumers | (select(tag == "!!str") // (join(","))) | tostring))
  ' "$manifest")

  local kp tp
  kp=$(IFS=,; echo "${kit_paths[*]:-}")
  tp=$(IFS=,; echo "${templated_paths[*]:-}")
  echo -e "${#kit_paths[@]}\t${#templated_paths[@]}\t${kp}\t${tp}"
}

# Compute the deterministic branch name. Same commit-ish always produces
# the same branch — that's how we get idempotency on re-runs.
sync_branch_name() {
  local sha=$1
  echo "${SYNC_BRANCH_PREFIX}/${sha:0:7}"
}

# Idempotency check: does a PR already exist on this consumer's repo from
# the deterministic sync branch? Echoes one of:
#   "open:<pr_number>"     PR is open — skip, "already in flight"
#   "closed:<pr_number>"   PR exists but closed (merged or abandoned)
#   "none"                 No prior PR; safe to open
# On API error, echoes "error" and returns non-zero.
sync_check_existing_pr() {
  local consumer_repo=$1
  local branch=$2
  local prs
  prs=$(gh api "repos/$consumer_repo/pulls?state=all&head=$(echo "$consumer_repo" | cut -d/ -f1):$branch" \
    --jq '.[] | "\(.state)\t\(.number)"' 2>/dev/null) || {
    echo "error"
    return 1
  }
  if [ -z "$prs" ]; then
    echo "none"
    return 0
  fi
  # Take the most recent (last) — gh api returns newest first by default.
  local first
  first=$(echo "$prs" | head -1)
  local state num
  state=$(echo "$first" | cut -f1)
  num=$(echo "$first" | cut -f2)
  if [ "$state" = "open" ]; then
    echo "open:$num"
  else
    echo "closed:$num"
  fi
}

# Per-consumer sync. Echoes a summary line on stdout. Sets
# SYNC_PR_OPENED, SYNC_SKIPPED, SYNC_FAILED counters in the parent.
sync_one_consumer() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local short_sha=${sha:0:7}
  local commit_subject=$4
  local changed_files=$5
  local dry_run=${6:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  local branch
  branch=$(sync_branch_name "$sha")

  local targets
  targets=$(sync_consumer_canonical_targets "$consumer_name" "$changed_files" "$manifest")

  local skipped
  skipped=$(sync_consumer_skipped_targets "$consumer_name" "$changed_files" "$manifest")
  local kit_count=$(echo "$skipped" | cut -f1)
  local templated_count=$(echo "$skipped" | cut -f2)
  local kit_list=$(echo "$skipped" | cut -f3)
  local templated_list=$(echo "$skipped" | cut -f4)

  if [ -z "$targets" ]; then
    if [ "$kit_count" -gt 0 ] || [ "$templated_count" -gt 0 ]; then
      printf "  ⊘ %s (no canonical targets; deferred: kit=%s templated=%s)\n" \
        "$consumer_name" "${kit_list:-none}" "${templated_list:-none}"
    else
      printf "  · %s (no manifest paths touched by %s)\n" "$consumer_name" "$short_sha"
    fi
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    return 0
  fi

  # Idempotency check before any write. Skipped in dry-run mode: the
  # check probes the consumer repo via `gh api` and dry-run is meant to
  # have zero side effects + zero network dependency. The trade-off:
  # a dry-run plan may show a "would open PR" line even when a PR
  # already exists; the live run will catch and skip it.
  if [ "$dry_run" != "1" ]; then
    local pr_state
    pr_state=$(sync_check_existing_pr "$consumer_repo" "$branch") || {
      printf "  ✗ %s — could not query existing PRs from %s\n" "$consumer_name" "$consumer_repo"
      SYNC_FAILED=$((SYNC_FAILED + 1))
      return 0
    }
    case "$pr_state" in
      open:*)
        printf "  · %s already in flight (PR #%s on branch %s)\n" \
          "$consumer_name" "${pr_state#open:}" "$branch"
        SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
        return 0
        ;;
      closed:*)
        printf "  · %s already done (PR #%s closed/merged on branch %s)\n" \
          "$consumer_name" "${pr_state#closed:}" "$branch"
        SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
        return 0
        ;;
    esac
  fi

  local target_count
  target_count=$(echo "$targets" | wc -l | tr -d ' ')

  if [ "$dry_run" = "1" ]; then
    printf "  ⤷ %s — would open PR on branch %s (%d canonical file(s))\n" \
      "$consumer_name" "$branch" "$target_count"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf "      + %s\n" "$p"
    done <<< "$targets"
    if [ "$kit_count" -gt 0 ] || [ "$templated_count" -gt 0 ]; then
      printf "      (deferred this slice: kit=%s templated=%s)\n" \
        "${kit_list:-none}" "${templated_list:-none}"
    fi
    SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
    return 0
  fi

  # Live mode: clone, branch, commit, push, PR.
  if ! sync_open_pr "$consumer_name" "$consumer_repo" "$sha" "$commit_subject" \
                    "$branch" "$targets" "$kit_list" "$templated_list"; then
    SYNC_FAILED=$((SYNC_FAILED + 1))
    return 0
  fi
  SYNC_PR_OPENED=$((SYNC_PR_OPENED + 1))
}

# Live PR-open. Clones the consumer repo into a tmpdir (writeable
# workspace, never reuses the cache or sibling worktree), copies canonical
# files from the Mergepath worktree at $sha, commits with the standard
# self-review body, pushes the branch, and creates a PR.
#
# Returns 0 on success, non-zero on failure (caller increments
# SYNC_FAILED). Stdout: human-readable progress lines.
sync_open_pr() {
  local consumer_name=$1
  local consumer_repo=$2
  local sha=$3
  local commit_subject=$4
  local branch=$5
  local targets=$6  # newline-separated paths
  local kit_list=$7
  local templated_list=$8
  local short_sha=${sha:0:7}

  # Portable mktemp: `-t TEMPLATE` semantics differ between BSD (macOS)
  # and GNU coreutils. macOS treats TEMPLATE as a literal prefix and
  # appends random chars; GNU treats it as a TMPDIR-rooted basename
  # but ONLY if the value contains no slash, AND the trailing X-pattern
  # rules differ. Use the explicit-path form `mktemp -d "$TMPDIR/<X...>"`
  # which both implementations honor identically. cursor CHANGES_REQUESTED
  # on PR #217 caught the GNU/Linux portability gap.
  local tmp_root=${TMPDIR:-/tmp}
  local workspace
  workspace=$(mktemp -d "$tmp_root/mergepath-sync-${consumer_name}.XXXXXX") || {
    err "could not create workspace tmpdir"
    return 1
  }
  trap "rm -rf '$workspace'" RETURN

  printf "  ⤷ %s — cloning %s\n" "$consumer_name" "$consumer_repo"
  if ! gh repo clone "$consumer_repo" "$workspace/repo" -- --depth=10 --quiet >&2; then
    err "$consumer_name: gh repo clone failed for $consumer_repo"
    return 1
  fi

  # Materialize Mergepath's $sha worktree state for the target files.
  # Using `git show $sha:<path>` is robust against the working tree
  # having other uncommitted edits.
  #
  # Deletion handling: when Mergepath drops a canonical file at $sha,
  # `git ls-tree $sha <path>` returns empty (the path no longer exists
  # in the tree). Treat that as a delete propagation: rm the consumer
  # copy if present. cursor CHANGES_REQUESTED on PR #217 caught the
  # missing delete propagation — without this branch, deletes would
  # fail noisily on `git show` and the script would abort the entire
  # consumer rather than mirroring the delete.
  local target
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    local consumer_target="$workspace/repo/$target"
    local src_mode
    src_mode=$(git -C "$MERGEPATH_ROOT" ls-tree "$sha" -- "$target" | awk '{print $1}')

    if [ -z "$src_mode" ]; then
      # Path absent at $sha → delete propagation.
      if [ -e "$consumer_target" ]; then
        rm -f "$consumer_target"
      fi
      # No mode-mirror for deletes; the path is gone in both trees.
      continue
    fi

    mkdir -p "$(dirname "$consumer_target")"
    if ! git -C "$MERGEPATH_ROOT" show "$sha:$target" >"$consumer_target" 2>/dev/null; then
      err "$consumer_name: could not read $target from mergepath@$short_sha"
      return 1
    fi
    # Mirror the executable bit from the source. Both directions matter:
    # if the source is 100755 the target must be +x (so a hook stays
    # runnable in the consumer); if the source is 100644 the target
    # must NOT be +x (otherwise mode drift accumulates whenever a
    # consumer historically had +x set on a file Mergepath later
    # decided should be plain). cursor's CHANGES_REQUESTED on PR #217
    # caught the one-way version that only added +x.
    case "$src_mode" in
      100755) chmod +x "$consumer_target" ;;
      100644) chmod -x "$consumer_target" ;;
      *)
        err "$consumer_name: unexpected git mode '$src_mode' for $target at $short_sha"
        return 1
        ;;
    esac
  done <<< "$targets"

  # Sanity: did the copy actually change anything? If the consumer was
  # already in sync (someone hand-propagated it before us, or a prior
  # sync ran but the PR was never opened), don't push an empty commit.
  if ! git -C "$workspace/repo" diff --quiet HEAD --; then
    :
  else
    printf "  · %s already in sync at HEAD (no diff after copy)\n" "$consumer_name"
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    SYNC_PR_OPENED=$((SYNC_PR_OPENED - 1))  # caller incremented eagerly
    return 0
  fi

  # Branch + commit. Use git config from the consumer clone (or
  # mergepath's, since `gh repo clone` inherits the user's local
  # git identity).
  if ! git -C "$workspace/repo" checkout -q -b "$branch"; then
    err "$consumer_name: git checkout -b $branch failed"
    return 1
  fi
  git -C "$workspace/repo" add -A
  local target_lines
  target_lines=$(while IFS= read -r p; do [ -z "$p" ] && continue; echo "  - $p"; done <<< "$targets")
  local deferred_note=""
  if [ -n "$kit_list" ] || [ -n "$templated_list" ]; then
    deferred_note="
Deferred this propagation (sync-to-downstream.sh ${SCRIPT_VERSION}
only handles canonical paths; kit + templated land in slices 2 and 5):
  kit:       ${kit_list:-none}
  templated: ${templated_list:-none}
"
  fi
  if ! git -C "$workspace/repo" commit -q -m "$(cat <<EOF
sync from mergepath@${short_sha}: ${commit_subject}

Source: https://github.com/nathanjohnpayne/mergepath/commit/${sha}
Files:
${target_lines}
${deferred_note}
Authoring-Agent: claude

## Self-Review
- Correctness: mirrors mergepath@${short_sha} verbatim per .mergepath-sync.yml
- Regression risk: low; same change has been reviewed in the upstream PR
- Style: N/A (verbatim mirror)
- Test coverage: relies on the consumer repo CI
- Security: no new attack surface

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"; then
    err "$consumer_name: git commit failed"
    return 1
  fi

  # Push. The active gh keyring account ('gh config get -h github.com user')
  # is what gh uses for write operations. The author identity is what
  # commits and PR creation should attribute to. Per the active-account
  # convention (CLAUDE.md), agents wrap author-identity writes in a
  # switch-around. Here we let the caller pre-arrange that — sync_open_pr
  # is invoked under the agent's normal active account, so PR creation
  # bylines as that account. To get nathanjohnpayne attribution on the
  # PR (matching the standard policy), the caller must switch first.
  printf "  ⤷ %s — pushing branch %s\n" "$consumer_name" "$branch"
  if ! git -C "$workspace/repo" push -q -u origin "$branch" 2>&1; then
    err "$consumer_name: git push failed"
    return 1
  fi

  # Open the PR.
  printf "  ⤷ %s — opening PR\n" "$consumer_name"
  local pr_url
  pr_url=$(gh pr create --repo "$consumer_repo" --base main --head "$branch" \
    --title "sync: ${commit_subject} (mergepath@${short_sha})" \
    --body "$(cat <<EOF
Auto-propagated from [mergepath@${short_sha}](https://github.com/nathanjohnpayne/mergepath/commit/${sha}) by \`scripts/sync-to-downstream.sh\` (v${SCRIPT_VERSION}, see [#168](https://github.com/nathanjohnpayne/mergepath/issues/168)).

## Files synced
${target_lines}
${deferred_note}
## Source

${commit_subject}

https://github.com/nathanjohnpayne/mergepath/commit/${sha}

Authoring-Agent: claude

## Self-Review
- Correctness: mirrors mergepath@${short_sha} verbatim per the upstream manifest. The change has already been reviewed in the upstream Mergepath PR.
- Regression risk: low. Verbatim mirror of an already-reviewed upstream change.
- Style: N/A (mirror).
- Test coverage: relies on the consumer repo CI. No test changes shipped.
- Security: no new attack surface; the sync script never ran with elevated privileges in this consumer.
EOF
)" 2>&1) || {
    err "$consumer_name: gh pr create failed: $pr_url"
    return 1
  }
  printf "  ✓ %s — opened %s\n" "$consumer_name" "$pr_url"
}

# Run the sync driver against a single Mergepath commit-ish.
run_sync() {
  local commit_ish=$1
  local dry_run=${2:-0}
  local manifest="$MERGEPATH_ROOT/$MANIFEST_PATH"

  SYNC_PR_OPENED=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0

  local sha
  sha=$(sync_resolve_commit "$commit_ish") || exit 2
  local short_sha=${sha:0:7}
  local subject
  subject=$(git -C "$MERGEPATH_ROOT" show -s --format=%s "$sha")

  local changed_files
  changed_files=$(sync_changed_files "$sha")

  if [ -z "$changed_files" ]; then
    err "no files changed at mergepath@${short_sha} — nothing to propagate"
    exit 0
  fi

  # Active-account guard for LIVE mode (skipped in --dry-run since
  # dry-run is meant to be safe to run from any identity). Refuses to
  # proceed unless the gh keyring's active account matches the
  # manifest's author_identity. Without this guard, downstream PRs
  # would be created under whatever reviewer identity happens to be
  # active, violating the author/reviewer separation in
  # REVIEW_POLICY.md.
  #
  # Read via `gh config get -h github.com user` (NOT `gh auth status`,
  # which is GH_TOKEN-poisonable per CLAUDE.md "Active-account
  # convention"). Author identity is read from .github/review-policy.yml's
  # `author_identity` field; falls back to "nathanjohnpayne" if missing.
  # Override with MERGEPATH_SYNC_ACTOR_OVERRIDE for tests / break-glass.
  # cursor's CHANGES_REQUESTED on PR #217 caught the missing guard.
  if [ "$dry_run" != "1" ]; then
    local expected_actor active_actor
    expected_actor=$(awk '/^author_identity:/ {sub(/^[^:]+:[[:space:]]*/, ""); gsub(/[[:space:]"#].*$/, ""); print; exit}' \
      "$MERGEPATH_ROOT/.github/review-policy.yml" 2>/dev/null || echo "")
    expected_actor=${expected_actor:-nathanjohnpayne}
    expected_actor=${MERGEPATH_SYNC_ACTOR_OVERRIDE:-$expected_actor}
    active_actor=$(gh config get -h github.com user 2>/dev/null || echo "")
    if [ "$active_actor" != "$expected_actor" ]; then
      err "refusing to run live sync — active gh account is '$active_actor', expected '$expected_actor'"
      err "       Switch first: gh auth switch -u $expected_actor"
      err "       Then re-run. (Set MERGEPATH_SYNC_ACTOR_OVERRIDE for tests.)"
      exit 2
    fi
  fi

  echo "Sync from mergepath@${short_sha}: ${subject}"
  echo "Changed files at this commit:"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "  $f"
  done <<< "$changed_files"
  echo

  # Per-consumer
  local consumers
  consumers=$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$manifest")
  while IFS=$'\t' read -r consumer_name consumer_repo; do
    [ -z "$consumer_name" ] && continue
    if ! in_repo_filter "$consumer_name"; then continue; fi
    sync_one_consumer "$consumer_name" "$consumer_repo" "$sha" "$subject" \
                      "$changed_files" "$dry_run"
  done <<< "$consumers"

  echo
  echo "Summary: PRs opened/planned: $SYNC_PR_OPENED  skipped: $SYNC_SKIPPED  failed: $SYNC_FAILED"
  if [ "$SYNC_FAILED" -gt 0 ]; then return 1; fi
  return 0
}

# --- arg parsing ------------------------------------------------------------

MODE=""
SYNC_COMMIT_ISH=""
SYNC_DRY_RUN=0
FILTER_REPOS=""
FILTER_PATHS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --audit)
      MODE="audit"
      shift
      ;;
    --repos)
      [ -z "${2:-}" ] && { err "missing argument for --repos"; usage; exit 2; }
      FILTER_REPOS="$2"
      shift 2
      ;;
    --paths)
      [ -z "${2:-}" ] && { err "missing argument for --paths"; usage; exit 2; }
      FILTER_PATHS="$2"
      shift 2
      ;;
    --no-clone)
      AUDIT_NO_CLONE=1
      shift
      ;;
    --no-refresh)
      AUDIT_NO_REFRESH=1
      shift
      ;;
    --dry-run)
      SYNC_DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "sync-to-downstream.sh $SCRIPT_VERSION (manifest schema v$SUPPORTED_MANIFEST_VERSION)"
      exit 0
      ;;
    --)
      shift; break
      ;;
    -*)
      err "unknown flag: $1"
      usage
      exit 2
      ;;
    *)
      # Positional argument = commit-ish. Sync mode.
      if [ -n "$SYNC_COMMIT_ISH" ]; then
        err "multiple positional commit-ish args not supported (got '$SYNC_COMMIT_ISH' and '$1')"
        exit 2
      fi
      SYNC_COMMIT_ISH="$1"
      MODE="sync"
      shift
      ;;
  esac
done

if [ -z "$MODE" ]; then
  usage
  exit 2
fi

require_yq
require_manifest

case "$MODE" in
  audit)
    run_audit
    if [ "${AUDIT_FETCH_ERROR:-0}" = "1" ]; then
      exit 3
    elif [ "${AUDIT_DRIFT_FOUND:-0}" = "1" ]; then
      exit 1
    else
      exit 0
    fi
    ;;
  sync)
    if ! run_sync "$SYNC_COMMIT_ISH" "$SYNC_DRY_RUN"; then
      exit 1
    fi
    exit 0
    ;;
  *)
    err "internal error: unknown MODE=$MODE"
    exit 2
    ;;
esac
