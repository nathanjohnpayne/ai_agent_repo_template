#!/usr/bin/env bash
# tests/test_sync_to_downstream.sh
#
# Validates scripts/sync-to-downstream.sh against synthetic consumer
# fixtures. Builds a temp Mergepath worktree and a temp consumer
# worktree from scratch, points the script at them via the
# MERGEPATH_SIBLINGS_DIR env var, and checks that each manifest path
# type produces the expected status (ok / drift / missing) and the
# right exit code.
#
# Requires: yq (mikefarah/yq v4+), git. Run manually or from CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d -t sync-to-downstream-test)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a minimal "mergepath" with two canonical files and one kit dir
# ---------------------------------------------------------------------------
MP="$WORKDIR/mergepath"
mkdir -p "$MP/scripts/hooks" "$MP/scripts/ci" "$MP/.github/workflows"
echo "canonical-script-v1" >"$MP/scripts/keep-in-sync.sh"
echo "canonical-hook-v1"   >"$MP/scripts/hooks/the-hook.sh"
echo "kit-file-1" >"$MP/scripts/ci/check_one"
echo "kit-file-2" >"$MP/scripts/ci/check_two"

cat >"$MP/.mergepath-sync.yml" <<'EOF'
version: 1
consumers:
  - {name: clean-consumer,  repo: x/clean-consumer}
  - {name: drifted,         repo: x/drifted}
  - {name: missing-everything, repo: x/missing-everything}
paths:
  - {path: scripts/keep-in-sync.sh,    type: canonical, consumers: all}
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
EOF

# git init each fake worktree — resolve_consumer_worktree() looks for .git/
git init -q "$MP"

SIBLINGS="$WORKDIR/siblings"
mkdir -p "$SIBLINGS"

# Consumer 1: clean (mirrors mergepath verbatim)
mkdir -p "$SIBLINGS/clean-consumer/scripts/hooks" "$SIBLINGS/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$SIBLINGS/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$SIBLINGS/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/clean-consumer/scripts/ci/check_two"
# Add a consumer-only file in the kit dir to validate the allow-extras semantic
echo "consumer-extra" >"$SIBLINGS/clean-consumer/scripts/ci/check_consumer_only"
git init -q "$SIBLINGS/clean-consumer"

# Consumer 2: drifted (one canonical drifts, kit has one drifted file)
mkdir -p "$SIBLINGS/drifted/scripts/hooks" "$SIBLINGS/drifted/scripts/ci"
echo "MUTATED"                     >"$SIBLINGS/drifted/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/drifted/scripts/hooks/the-hook.sh"
echo "DRIFT"                       >"$SIBLINGS/drifted/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/drifted/scripts/ci/check_two"
git init -q "$SIBLINGS/drifted"

# Consumer 3: missing everything (no scripts/, no .github/, just a placeholder)
mkdir -p "$SIBLINGS/missing-everything"
echo "placeholder" >"$SIBLINGS/missing-everything/README.md"
git init -q "$SIBLINGS/missing-everything"

# ---------------------------------------------------------------------------
# Run the script against the fixture and capture output + exit code
# ---------------------------------------------------------------------------
cd "$MP"
set +e
output=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone 2>&1)
exit_code=$?
set -e

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; echo "---output---" >&2; echo "$output" >&2; exit 1; }

# Exit 1 because at least one consumer drifts.
[[ "$exit_code" -eq 1 ]] || fail "expected exit 1 (drift), got $exit_code"

# Clean consumer: every line should be ✓ in sync (the consumer-only extra
# file under scripts/ci/ must NOT be flagged — kit type is allow-extras).
echo "$output" | awk '
  /^clean-consumer/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✗\|⊘' \
  && fail "clean-consumer should report no drift; got non-✓ lines"

# Drifted consumer: must show drift for keep-in-sync.sh and for the kit dir
echo "$output" | grep -q "✗ scripts/keep-in-sync.sh" \
  || fail "expected drift line for scripts/keep-in-sync.sh on drifted consumer"
echo "$output" | grep -q "✗ scripts/ci/" \
  || fail "expected drift line for scripts/ci/ kit on drifted consumer"

# Missing-everything: every path must be ⊘
echo "$output" | awk '
  /^missing-everything/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✓\|✗' \
  && fail "missing-everything should report only ⊘; got ✓ or ✗ lines"

# ---------------------------------------------------------------------------
# Filter test: --paths restriction must shrink the report
# ---------------------------------------------------------------------------
filtered=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone --paths "scripts/hooks/the-hook.sh" 2>&1 || true)
echo "$filtered" | grep -q "scripts/keep-in-sync.sh" \
  && fail "--paths filter should have excluded scripts/keep-in-sync.sh"

# ---------------------------------------------------------------------------
# --version / --help smoke
# ---------------------------------------------------------------------------
"$SCRIPT" --version | grep -q "sync-to-downstream.sh" || fail "--version output unexpected"
"$SCRIPT" --help    | grep -q "Usage:"                || fail "--help output unexpected"

echo "test_sync_to_downstream: PASS"
