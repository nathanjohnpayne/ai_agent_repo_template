#!/usr/bin/env bash
# scripts/sync-to-downstream.sh — propagate Mergepath template changes
# to downstream consumer repos. See #168 for the design.
#
# This script is shipping in layers (per the issue's implementation plan):
#
#   v1 (this PR):
#     --audit            Read-only drift detector across all consumers.
#     --help             Print this header.
#     --version          Print script + manifest schema version.
#
#   future:
#     <commit-ish>       Open propagation PRs for files changed at the
#                        given commit (Layer 3).
#     --from-pr <N>      Resolve PR N's merge commit and propagate
#                        (Layer 4).
#
# The manifest at .mergepath-sync.yml declares which paths are canonical
# (byte-identical) or kit (directory mirror with allow-extras), and which
# consumers opt in. Templated paths are reserved for Layer 5 and rejected
# until the substitution lib lands.
#
# Usage:
#   scripts/sync-to-downstream.sh --audit [--repos r1,r2] [--paths glob]
#   scripts/sync-to-downstream.sh --help
#   scripts/sync-to-downstream.sh --version
#
# Flags:
#   --audit            Read-only drift detection. Exit 0 (clean), 1 (drift),
#                      2 (script/usage error), 3 (consumer fetch error).
#   --repos r1,r2      Restrict to a comma-separated subset of consumer names.
#   --paths glob       Restrict to manifest paths matching the glob (e.g.
#                      "scripts/*", ".github/workflows/agent-review.yml").
#   --no-clone         Don't clone-on-demand; only audit consumers with a
#                      local sibling worktree under MERGEPATH_SIBLINGS_DIR.
#   --no-refresh       Don't `git fetch` cached consumer clones before
#                      comparing. Useful for offline/sandboxed audits;
#                      may report stale results if the cache is old.
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

SCRIPT_VERSION="0.1.0-layer1+2"
SUPPORTED_MANIFEST_VERSION=1
MANIFEST_PATH=".mergepath-sync.yml"

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
# Returns 0 if found, 1 if not. Sets $RESOLVED_FROM to "siblings" or "cache"
# so the caller knows whether to refresh-fetch (caches drift; siblings are
# the user's authoritative working tree and must not be touched).
#
# Accepts both `.git` directory (regular clone) and `.git` file (git
# worktree). Codex P2 on PR #215 caught the worktree case — the original
# `-d` test misclassified worktrees as missing.
resolve_consumer_worktree() {
  local consumer_name=$1
  local siblings_dir=${MERGEPATH_SIBLINGS_DIR:-$HOME/GitHub}
  local cache_dir=${MERGEPATH_SYNC_CACHE:-$HOME/.cache/mergepath-sync}

  if [ -e "$siblings_dir/$consumer_name/.git" ]; then
    RESOLVED_FROM="siblings"
    echo "$siblings_dir/$consumer_name"
    return 0
  fi
  if [ -e "$cache_dir/$consumer_name/.git" ]; then
    RESOLVED_FROM="cache"
    echo "$cache_dir/$consumer_name"
    return 0
  fi
  return 1
}

# Bring a cached clone up to date with the consumer's default branch.
# Skipped silently if the path was resolved from a sibling worktree —
# refreshing a user's working tree would clobber uncommitted edits.
# Codex P1 on PR #215 caught the stale-cache hazard.
refresh_cached_clone() {
  local cache_path=$1
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
    local rel="${f#$mp_full/}"
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
    RESOLVED_FROM=""
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
      RESOLVED_FROM="cache"
    fi
    # If we're reading from a stale cache (resolved on the second branch
    # of resolve_consumer_worktree), pull the latest default branch
    # before comparing. Skip for sibling worktrees; that's the user's
    # working tree and must not be auto-reset. Honors --no-refresh for
    # offline / sandboxed runs.
    if [ "$RESOLVED_FROM" = "cache" ] && [ "${AUDIT_NO_REFRESH:-0}" != "1" ]; then
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

# --- arg parsing ------------------------------------------------------------

MODE=""
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
      err "Layer 3 sync mode (positional <commit-ish>) not yet implemented — see #168."
      err "Currently supported modes: --audit, --help, --version."
      exit 2
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
  *)
    err "internal error: unknown MODE=$MODE"
    exit 2
    ;;
esac
