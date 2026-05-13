#!/usr/bin/env bash
# tests/test_eslint_policy_check.sh
#
# Unit tests for scripts/ci/check_eslint_config_present. Covers the
# three contract cases from the script's header:
#
#   1. no root package.json                          → exit 0 (pass)
#   2. package.json present, eslint.config.js absent → exit 1 (fail)
#   3. package.json + valid eslint.config.js         → exit 0 (pass)
#   4. package.json + syntax-broken eslint.config.js → exit 1 (fail)
#
# We invoke the check against a synthetic REPO_ROOT by symlinking the
# real script into a temp tree — the script computes REPO_ROOT from
# its own location, so a symlinked copy sees the temp tree as root.
# Bash 3.2 portable. Run from scripts/ci/check_eslint_config_policy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_eslint_config_present"
SAMPLE="$ROOT/examples/eslint.config.js"

[ -x "$CHECK" ] || { echo "missing or non-executable $CHECK" >&2; exit 1; }
[ -f "$SAMPLE" ] || { echo "missing sample $SAMPLE" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — check_eslint_config_present needs node --check" >&2
  exit 0
fi

# Use the explicit `$TMPDIR/<prefix>.XXXXXX` form for cross-platform
# portability (BSD vs GNU mktemp), per the convention from #228.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/eslint-policy-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a fake repo tree where scripts/ci/check_eslint_config_present
# is a copy of the real script (NOT a symlink — the script resolves
# its own location, and a symlink would resolve back to the real
# REPO_ROOT, defeating the test). We copy the file verbatim.
make_fake_repo() {
  local target_dir="$1"
  mkdir -p "$target_dir/scripts/ci"
  cp "$CHECK" "$target_dir/scripts/ci/check_eslint_config_present"
  chmod +x "$target_dir/scripts/ci/check_eslint_config_present"
}

# Run the synthetic check; capture exit code without tripping `set -e`.
run_check() {
  local repo="$1"
  set +e
  "$repo/scripts/ci/check_eslint_config_present" >"$WORKDIR/out.txt" 2>&1
  echo $?
  set -e
}

# ---------------------------------------------------------------------------
# Test 1: no package.json → pass.
# ---------------------------------------------------------------------------
T1="$WORKDIR/case1-no-pkg"
make_fake_repo "$T1"
rc=$(run_check "$T1")
if [ "$rc" -eq 0 ] && grep -q "not applicable" "$WORKDIR/out.txt"; then
  pass "no package.json → exits 0 with not-applicable message"
else
  fail "no package.json: expected exit 0 + 'not applicable' message, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 2: package.json present, eslint.config.js absent → fail.
# ---------------------------------------------------------------------------
T2="$WORKDIR/case2-pkg-no-eslint"
make_fake_repo "$T2"
echo '{"name":"t2","version":"0.0.0"}' >"$T2/package.json"
rc=$(run_check "$T2")
if [ "$rc" -eq 1 ] && grep -q "eslint.config.js is missing" "$WORKDIR/out.txt"; then
  pass "package.json without eslint.config.js → exits 1"
else
  fail "expected exit 1 + 'eslint.config.js is missing', got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 3: package.json + valid eslint.config.js (the sample) → pass.
# We don't actually need the eslint package installed; the check just
# parse-validates the JS syntax with `node --check`. The sample uses
# `import` statements; `node --check` accepts ES module syntax in any
# .js file regardless of package "type" — it's purely a parse step.
# ---------------------------------------------------------------------------
T3="$WORKDIR/case3-pkg-and-eslint"
make_fake_repo "$T3"
echo '{"name":"t3","version":"0.0.0","type":"module"}' >"$T3/package.json"
cp "$SAMPLE" "$T3/eslint.config.js"
rc=$(run_check "$T3")
if [ "$rc" -eq 0 ] && grep -q "PASS" "$WORKDIR/out.txt"; then
  pass "package.json + valid eslint.config.js → exits 0"
else
  fail "expected exit 0, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 4: package.json + syntactically broken eslint.config.js → fail.
# Confirms the `node --check` step is wired up — a broken file must
# not slip through as a pass just because the filename exists.
# ---------------------------------------------------------------------------
T4="$WORKDIR/case4-pkg-broken-eslint"
make_fake_repo "$T4"
echo '{"name":"t4","version":"0.0.0"}' >"$T4/package.json"
# Non-JavaScript content — `node --check` exits 1 with SyntaxError.
# (Picked over a "missing-paren" snippet because Node's parser accepts
# trailing-continuation-style files; only an outright tokenization
# error reliably fails the check.)
printf 'this is not javascript &!@(*#^$\n' >"$T4/eslint.config.js"
rc=$(run_check "$T4")
if [ "$rc" -eq 1 ] && grep -q "failed Node syntax check" "$WORKDIR/out.txt"; then
  pass "package.json + broken eslint.config.js → exits 1 with parse error"
else
  fail "expected exit 1 + parse error, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "test_eslint_policy_check: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
