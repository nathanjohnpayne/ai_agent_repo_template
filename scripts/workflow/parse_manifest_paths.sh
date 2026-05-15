#!/usr/bin/env bash
set -euo pipefail

# Extract the propagation surface from `.mergepath-sync.yml` — every
# path the manifest declares as canonical / kit / templated — and
# print it as a list of glob patterns suitable for piping into
# scripts/workflow/match_protected_paths.sh.
#
# Usage: scripts/workflow/parse_manifest_paths.sh [manifest_path]
#   manifest_path defaults to .mergepath-sync.yml
#
# Output: one pattern per line.
#   - canonical / templated entries  → the exact path
#   - kit entries (directory mirror) → "<dir>/**" so every file
#     under the kit directory matches
#
# Example:
#   $ scripts/workflow/parse_manifest_paths.sh
#   scripts/op-preflight.sh
#   scripts/hooks/gh-pr-guard.sh
#   ...
#   scripts/ci/**
#   scripts/gh-projects/**
#
# Why this exists: the propagation-PR review lane
# (.github/workflows/pr-review-policy.yml § propagation_prs) needs to
# verify that a sync PR's diff is CONFINED to the declared
# propagation surface — a sync PR touching a non-manifest path is not
# a faithful mirror and must fall back to normal external review.
# This parser produces the allow-list the path-confinement check
# matches against.
#
# Why an awk parser (not yq): same rationale as parse_policy_list.sh —
# GitHub Actions ubuntu-latest runners have bash+awk reliably; a YAML
# dependency is less reliable across minimal images. The manifest's
# `paths:` block uses a fixed, simple shape (one `- path:` line and a
# `type:` line per entry), and this parser is scoped to exactly that
# shape. .mergepath-sync.yml is validated by scripts/ci/check_sync_manifest.

CONFIG="${1:-.mergepath-sync.yml}"

if [ ! -f "$CONFIG" ]; then
  echo "parse_manifest_paths.sh: manifest file not found: $CONFIG" >&2
  exit 1
fi

awk '
  # Enter the paths: block at column 0.
  /^paths:/ { in_paths = 1; next }
  # Any other column-0, non-comment line ends the block (next
  # top-level key, e.g. `exclusions:`).
  in_paths && /^[^[:space:]#]/ { in_paths = 0 }
  !in_paths { next }

  # A "- path:" line starts a new entry. Capture the path; reset
  # the pending type so a malformed entry without a type emits
  # nothing rather than inheriting the previous entrys type.
  /^[[:space:]]*-[[:space:]]*path:/ {
    line = $0
    sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", line)
    sub(/[[:space:]]*#.*$/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    gsub(/^"|"$/, "", line)
    cur_path = line
    next
  }

  # A "type:" line completes the current entry.
  /^[[:space:]]*type:/ && cur_path != "" {
    line = $0
    sub(/^[[:space:]]*type:[[:space:]]*/, "", line)
    sub(/[[:space:]]*#.*$/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line == "kit") {
      # Kit = directory mirror. Emit a "<dir>/**" glob so every
      # file under the kit directory is recognized as in-surface.
      dir = cur_path
      sub(/\/$/, "", dir)
      print dir "/**"
    } else if (line == "canonical" || line == "templated") {
      # canonical / templated = exact file path.
      print cur_path
    } else {
      # Unknown type — a typo (e.g. "canoncial") or a future
      # unsupported type. Do NOT emit it: silently widening the
      # propagation-lane allow-list to an unvalidated path could
      # let a PR skip external review for a path that is not
      # guaranteed propagation surface (Codex P2 on #268). Warn
      # loudly to stderr and drop the entry. check_sync_manifest
      # is the hard gate that rejects unknown types outright; this
      # is the defense-in-depth in the parser the lane trusts.
      printf "parse_manifest_paths.sh: WARNING: dropping path %s with unknown type %s (expected canonical/kit/templated)\n", cur_path, line > "/dev/stderr"
    }
    cur_path = ""
  }
'  "$CONFIG"
