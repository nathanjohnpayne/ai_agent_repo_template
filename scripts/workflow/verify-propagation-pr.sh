#!/usr/bin/env bash
set -euo pipefail

# verify-propagation-pr.sh — authoritative faithful-mirror check for
# the propagation-PR review lane (REVIEW_POLICY.md § Propagation PR
# review lane, mergepath#264 / #268).
#
# The lane exempts a sync PR from Phase 4 external review. That is
# only safe if the PR is PROVABLY a verbatim mirror of mergepath's
# canonical/kit content — not merely "confined to manifest-typed
# paths" (Codex P1 on #268: a mergepath-sync/* PR could otherwise
# hand-edit a workflow, which IS a manifest path, and skip review).
#
# This script is the teeth. It byte-compares every file the PR
# changes against the SAME path in a checkout of mergepath at the
# sync's source commit. It is TRUSTED ONLY when invoked from that
# mergepath checkout (the immutable, public commit the PR's branch
# name points at) — never from the PR's own checkout, which the PR
# could have tampered with.
#
# Usage:
#   verify-propagation-pr.sh <mergepath_dir> <consumer_dir> <base_sha> <head_sha>
#
#   mergepath_dir  a checkout of nathanjohnpayne/mergepath at the
#                  sync's source commit (the <sha> in the PR branch
#                  name mergepath-sync/[sync-all-]<sha>). Provides BOTH
#                  the authoritative manifest AND the canonical content
#                  to compare against.
#   consumer_dir   the consumer repo's PR checkout (a git work tree;
#                  base..head must be resolvable in it).
#   base_sha       PR base SHA.
#   head_sha       PR head SHA.
#
# Exit codes:
#   0  faithful mirror — every changed file is under a manifest path
#      AND its end-state byte-matches mergepath@<sha> (both-present-
#      equal, or both-absent). The PR is lane-eligible.
#   1  NOT a faithful mirror — at least one changed file is off-
#      manifest or deviates from mergepath@<sha>. The PR must go
#      through normal Phase 3/4 review. Deviations are listed on
#      stderr.
#   2  usage / environment error (bad args, missing manifest, etc.).
#
# Bash 3.2 portable: no `mapfile`, no associative arrays.

usage() {
  echo "usage: verify-propagation-pr.sh <mergepath_dir> <consumer_dir> <base_sha> <head_sha>" >&2
  exit 2
}

MERGEPATH_DIR="${1:-}"
CONSUMER_DIR="${2:-}"
BASE_SHA="${3:-}"
HEAD_SHA="${4:-}"
[ -n "$MERGEPATH_DIR" ] && [ -n "$CONSUMER_DIR" ] && [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ] || usage

MANIFEST="$MERGEPATH_DIR/.mergepath-sync.yml"
if [ ! -f "$MANIFEST" ]; then
  echo "verify-propagation-pr.sh: no .mergepath-sync.yml in mergepath checkout: $MANIFEST" >&2
  exit 2
fi

# The parser is taken from the mergepath checkout too — TRUSTED,
# same provenance as the manifest and the canonical content.
PARSE_MANIFEST="$MERGEPATH_DIR/scripts/workflow/parse_manifest_paths.sh"
MATCH_PATHS="$MERGEPATH_DIR/scripts/workflow/match_protected_paths.sh"
for h in "$PARSE_MANIFEST" "$MATCH_PATHS"; do
  if [ ! -f "$h" ]; then
    echo "verify-propagation-pr.sh: missing trusted helper in mergepath checkout: $h" >&2
    exit 2
  fi
done

# Authoritative propagation surface — from mergepath@<sha>, NOT the PR.
MAN_PATTERNS=()
while IFS= read -r p; do
  [ -n "$p" ] && MAN_PATTERNS+=("$p")
done < <(bash "$PARSE_MANIFEST" "$MANIFEST")
if [ "${#MAN_PATTERNS[@]}" -eq 0 ]; then
  echo "verify-propagation-pr.sh: manifest declares no propagation paths" >&2
  exit 2
fi

# Files the PR changes (three-dot: changes since the merge-base, the
# same range the External Review Check uses).
CHANGED_FILES=$(git -C "$CONSUMER_DIR" diff --name-only "$BASE_SHA...$HEAD_SHA")
if [ -z "$CHANGED_FILES" ]; then
  echo "verify-propagation-pr.sh: PR has no changed files — nothing to verify" >&2
  exit 1
fi

FAILURES=""
fail() { FAILURES="${FAILURES}  - $1"$'\n'; }

while IFS= read -r f; do
  [ -z "$f" ] && continue

  # 1. Path confinement: f must be under a manifest-declared path.
  if ! printf '%s\n' "$f" | bash "$MATCH_PATHS" "${MAN_PATTERNS[@]}" | grep -qxF "$f"; then
    fail "$f — not under any .mergepath-sync.yml path (off propagation surface)"
    continue
  fi

  # 2. Tree-entry equality of the END STATE against mergepath@<sha>.
  #    Compare the full git TREE ENTRY (mode + type + oid) rather
  #    than just the blob hash, so a file-mode change (exec-bit
  #    flip, regular file ↔ symlink) is caught too — a hand-edited
  #    `chmod +x` on a canonical script would otherwise pass the
  #    blob-only check while leaving the consumer's on-disk mode
  #    different from mergepath. `git ls-tree` returns
  #    `<mode> <type> <oid>\t<path>`; we drop the path field (always
  #    $f) and compare the mode+type+oid tuple. Empty output ⇒ path
  #    not present at that ref. (CodeRabbit Major, #272/#274.)
  consumer_present=1
  consumer_entry=$(git -C "$CONSUMER_DIR" ls-tree "$HEAD_SHA" -- "$f" 2>/dev/null | awk '{print $1, $2, $3}')
  [ -z "$consumer_entry" ] && consumer_present=0
  mergepath_present=1
  if [ -d "$MERGEPATH_DIR/.git" ] || [ -f "$MERGEPATH_DIR/.git" ]; then
    # mergepath_dir is a git checkout — `ls-tree HEAD` gives the
    # authoritative tree entry (mode/type from git's index, not a
    # filesystem mode that could vary by clone permissions).
    mergepath_entry=$(git -C "$MERGEPATH_DIR" ls-tree HEAD -- "$f" 2>/dev/null | awk '{print $1, $2, $3}')
    [ -z "$mergepath_entry" ] && mergepath_present=0
  else
    # Test harness fallback: mergepath_dir is a plain directory.
    # Synthesize a tree entry from the on-disk file: mode 100755 if
    # executable else 100644, type blob, oid via hash-object.
    if [ -f "$MERGEPATH_DIR/$f" ]; then
      if [ -x "$MERGEPATH_DIR/$f" ]; then mode="100755"; else mode="100644"; fi
      mp_oid=$(git hash-object "$MERGEPATH_DIR/$f")
      mergepath_entry="$mode blob $mp_oid"
    else
      mergepath_entry=""; mergepath_present=0
    fi
  fi

  if [ "$consumer_present" -eq 0 ] && [ "$mergepath_present" -eq 0 ]; then
    # Faithful delete: f removed in the PR, and absent at mergepath@<sha>.
    continue
  fi
  if [ "$consumer_present" -eq 1 ] && [ "$mergepath_present" -eq 0 ]; then
    fail "$f — present in the PR but absent at mergepath@<sha> (a faithful sync never adds/keeps a file mergepath does not have under a manifest path)"
    continue
  fi
  if [ "$consumer_present" -eq 0 ] && [ "$mergepath_present" -eq 1 ]; then
    fail "$f — deleted in the PR but still present at mergepath@<sha> (not a faithful delete-propagation)"
    continue
  fi
  # Both present — tree entries (mode + type + oid) must match.
  if [ "$consumer_entry" != "$mergepath_entry" ]; then
    fail "$f — tree entry differs from mergepath@<sha> (mode/type/oid mismatch; hand-edited or mode-flipped, not a verbatim mirror). consumer=[$consumer_entry] mergepath=[$mergepath_entry]"
    continue
  fi
done <<< "$CHANGED_FILES"

if [ -n "$FAILURES" ]; then
  echo "verify-propagation-pr.sh: NOT a faithful mirror — the PR is not lane-eligible:" >&2
  printf '%s' "$FAILURES" >&2
  echo "  → this PR must go through normal Phase 3/4 review." >&2
  exit 1
fi

echo "verify-propagation-pr.sh: faithful mirror confirmed — every changed file byte-matches mergepath@<sha> under a manifest path."
exit 0
