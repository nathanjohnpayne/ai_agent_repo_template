#!/usr/bin/env bash
# tests/test_eslint_policy_check.sh
#
# Unit tests for scripts/ci/check_eslint_config_present. Covers the
# contract cases from the script's header plus the policy-floor and
# unique-tempfile regressions added in CodeRabbit round 1 on #253:
#
#   1. no root package.json                          → exit 0 (pass)
#   2. package.json present, eslint.config.js absent → exit 1 (fail)
#   3. package.json + valid eslint.config.js         → exit 0 (pass)
#   4. package.json + syntax-broken eslint.config.js → exit 1 (fail)
#   5. package.json + parseable eslint.config.js but
#      missing @eslint/js recommended baseline       → exit 1 (fail)
#   6. concurrent runs do not clobber each other's
#      parse-error tempfile (no fixed /tmp path)     → both fail with
#                                                       distinct error
#                                                       output
#   7. package.json + config that ONLY references
#      `@eslint/js` and `.configs.recommended` from
#      inside a `//` comment                         → exit 1 (fail)
#                                                       — codex CR
#                                                       comment-bypass
#   8. package.json + config that references the
#      tokens from inside a `/* … */` block comment  → exit 1 (fail)
#                                                       — codex CR
#                                                       block-comment
#                                                       bypass
#   9. package.json + config that imports `@eslint/js`
#      and spreads `js.configs.recommended` in the
#      exported array (no comment noise)             → exit 0 (pass)
#                                                       — sanity case
#                                                       for the
#                                                       comment-stripper
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
# Test 5: package.json + parseable eslint.config.js that omits the
# @eslint/js recommended baseline → fail. Regression guard for the
# policy-floor finding (CodeRabbit round 1 on #253): before the fix,
# any syntactically-valid file passed even if it didn't import the
# required ruleset.
# ---------------------------------------------------------------------------
T5="$WORKDIR/case5-pkg-missing-baseline"
make_fake_repo "$T5"
echo '{"name":"t5","version":"0.0.0","type":"module"}' >"$T5/package.json"
cat >"$T5/eslint.config.js" <<'EOF'
// Parseable but DOES NOT include @eslint/js recommended.
// The policy floor must reject this.
export default [
  {
    rules: {
      "no-unused-vars": "warn",
    },
  },
];
EOF
rc=$(run_check "$T5")
if [ "$rc" -eq 1 ] && grep -q "@eslint/js recommended" "$WORKDIR/out.txt"; then
  pass "package.json + config missing @eslint/js baseline → exits 1"
else
  fail "expected exit 1 + '@eslint/js recommended' message, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 6: concurrent runs do not clobber each other's parse-error
# tempfile. Regression guard for the unique-tempfile finding
# (CodeRabbit round 1 on #253): before the fix, both runs wrote to a
# fixed `/tmp/eslint_config_parse.err` and could race.
#
# We launch two parse-failing runs in parallel, then assert both
# emit their parse-error message in their respective output. If a
# fixed tempfile were still in use, one run could see an empty or
# truncated error block depending on race ordering. We also assert
# no `eslint_config_parse.err` file (the old fixed name) lingers in
# $TMPDIR after both runs complete.
# ---------------------------------------------------------------------------
T6A="$WORKDIR/case6a-concurrent"
T6B="$WORKDIR/case6b-concurrent"
make_fake_repo "$T6A"
make_fake_repo "$T6B"
echo '{"name":"t6a","version":"0.0.0"}' >"$T6A/package.json"
echo '{"name":"t6b","version":"0.0.0"}' >"$T6B/package.json"
printf 'this is not javascript &!@(*#^$\n' >"$T6A/eslint.config.js"
printf 'this is also not javascript $#@!\n' >"$T6B/eslint.config.js"

set +e
"$T6A/scripts/ci/check_eslint_config_present" >"$WORKDIR/out6a.txt" 2>&1 &
PID_A=$!
"$T6B/scripts/ci/check_eslint_config_present" >"$WORKDIR/out6b.txt" 2>&1 &
PID_B=$!
wait $PID_A; RC_A=$?
wait $PID_B; RC_B=$?
set -e

if [ "$RC_A" -eq 1 ] && [ "$RC_B" -eq 1 ] \
   && grep -q "failed Node syntax check" "$WORKDIR/out6a.txt" \
   && grep -q "failed Node syntax check" "$WORKDIR/out6b.txt"; then
  pass "concurrent parse-failure runs both report a parse error (unique tempfile)"
else
  fail "concurrent runs: expected both rc=1 + 'failed Node syntax check', got rc=$RC_A/$RC_B"
  echo "--- out6a ---" >&2; sed 's/^/    /' "$WORKDIR/out6a.txt" >&2
  echo "--- out6b ---" >&2; sed 's/^/    /' "$WORKDIR/out6b.txt" >&2
fi

# No fixed-name leftover should exist (would indicate the old
# `/tmp/eslint_config_parse.err` path is still in use somewhere).
if [ -e "${TMPDIR:-/tmp}/eslint_config_parse.err" ]; then
  fail "fixed-name tempfile ${TMPDIR:-/tmp}/eslint_config_parse.err still in use"
else
  pass "no fixed-name parse-error tempfile leftover"
fi

# ---------------------------------------------------------------------------
# Test 7: package.json + parseable eslint.config.js where the @eslint/js
# import and the `.configs.recommended` token appear ONLY inside `//`
# line comments → fail. Regression guard for the codex CR comment-
# bypass on #253: before the fix, the grep matched comment text and
# returned PASS, even though the exported config didn't actually use
# the recommended ruleset.
# ---------------------------------------------------------------------------
T7="$WORKDIR/case7-pkg-comment-bypass-line"
make_fake_repo "$T7"
echo '{"name":"t7","version":"0.0.0","type":"module"}' >"$T7/package.json"
cat >"$T7/eslint.config.js" <<'EOF'
// Reproduces the codex CR comment-bypass: tokens appear ONLY in
// comments. The exported config does not actually apply the
// recommended ruleset.
// import js from "@eslint/js";
// using ...tseslint.configs.recommended in the future
export default [
  {
    rules: {
      "no-unused-vars": "warn",
    },
  },
];
EOF
rc=$(run_check "$T7")
if [ "$rc" -eq 1 ] && grep -q "@eslint/js recommended" "$WORKDIR/out.txt"; then
  pass "comment-only @eslint/js tokens (// line comments) → exits 1"
else
  fail "expected exit 1 + '@eslint/js recommended' message, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 8: same as Test 7 but the tokens are inside a `/* … */` block
# comment. The comment-stripper must handle both line and block forms.
# ---------------------------------------------------------------------------
T8="$WORKDIR/case8-pkg-comment-bypass-block"
make_fake_repo "$T8"
echo '{"name":"t8","version":"0.0.0","type":"module"}' >"$T8/package.json"
cat >"$T8/eslint.config.js" <<'EOF'
/*
 * Reproduces the codex CR bypass via block comment.
 * import js from "@eslint/js";
 * spreads ...tseslint.configs.recommended somewhere
 */
export default [
  {
    rules: {
      "no-unused-vars": "warn",
    },
  },
];
EOF
rc=$(run_check "$T8")
if [ "$rc" -eq 1 ] && grep -q "@eslint/js recommended" "$WORKDIR/out.txt"; then
  pass "comment-only @eslint/js tokens (/* */ block comments) → exits 1"
else
  fail "expected exit 1 + '@eslint/js recommended' message, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
# Test 9: legitimate flat config with `@eslint/js` imported and
# `js.configs.recommended` spread in the exported array → pass. This
# is the positive sanity case for the comment-stripper — confirms the
# stripper doesn't accidentally strip real code positions when the
# file legitimately uses the policy floor.
# ---------------------------------------------------------------------------
T9="$WORKDIR/case9-pkg-real-recommended"
make_fake_repo "$T9"
echo '{"name":"t9","version":"0.0.0","type":"module"}' >"$T9/package.json"
cat >"$T9/eslint.config.js" <<'EOF'
import js from "@eslint/js";
export default [
  js.configs.recommended,
  {
    rules: {
      "no-unused-vars": "warn",
    },
  },
];
EOF
rc=$(run_check "$T9")
if [ "$rc" -eq 0 ] && grep -q "PASS" "$WORKDIR/out.txt"; then
  pass "import + js.configs.recommended spread → exits 0"
else
  fail "expected exit 0, got rc=$rc / output:"
  sed 's/^/    /' "$WORKDIR/out.txt" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "test_eslint_policy_check: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
