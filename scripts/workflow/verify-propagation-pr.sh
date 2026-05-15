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

  # 2. Byte-equality of the END STATE against mergepath@<sha>.
  #    Compared via git BLOB HASHES (content-addressed) rather than
  #    captured content: `$(git show ...)` strips trailing newlines,
  #    which would false-positive a "differs" on any file with a
  #    trailing newline. The consumer hash comes from its git object
  #    store; the mergepath hash is computed from the file on disk
  #    with `git hash-object` (works whether or not the mergepath
  #    checkout dir is a worktree). Both sides use git's blob hashing,
  #    so equal hash ⟺ byte-identical content.
  consumer_present=1
  consumer_hash=$(git -C "$CONSUMER_DIR" rev-parse --verify -q "$HEAD_SHA:$f") || consumer_present=0
  mergepath_present=1
  mergepath_hash=""
  if [ -f "$MERGEPATH_DIR/$f" ]; then
    mergepath_hash=$(git hash-object "$MERGEPATH_DIR/$f")
  else
    mergepath_present=0
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
  # Both present — blob hashes must match.
  if [ "$consumer_hash" != "$mergepath_hash" ]; then
    fail "$f — content differs from mergepath@<sha> (hand-edited; not a verbatim mirror)"
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
