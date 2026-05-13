#!/usr/bin/env bash
# tests/test_gh_pr_guard.sh
#
# Unit tests for scripts/hooks/gh-pr-guard.sh — focused on the #241
# identity-check addition, plus a regression net for the existing
# Authoring-Agent / Self-Review body checks so the new check is
# additive (doesn't break the old behavior).
#
# The hook reads tool_input.command from a JSON envelope on stdin
# (PreToolUse contract). We feed it crafted envelopes and assert on
# exit code + stderr.
#
# Bash 3.2 portable. Runs from `scripts/ci/check_gh_as_author`
# (bundled with the wrapper test) and is also a useful local
# debugging entry point when fiddling with the hook.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/gh-pr-guard.sh"

[[ -x "$HOOK" ]] || { echo "missing or non-executable $HOOK" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (gh-pr-guard.sh requires python3 for tokenization)" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (gh-pr-guard.sh reads stdin via jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-guard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a fake `gh` on PATH so the hook's `gh config get -h github.com user`
# returns a configurable value. Note: the hook ALSO calls `gh pr view`
# in the merge branch; this stub handles both.
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "config get")
    if [ -n "${STUB_ACTIVE_USER:-}" ]; then
      echo "$STUB_ACTIVE_USER"
    fi
    exit 0
    ;;
  "pr view")
    # Return a labels JSON-friendly string for the merge guard.
    echo "${STUB_LABELS:-}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Build a hook-invocation envelope. The hook reads tool_input.command.
run_hook() {
  local cmd="$1"
  local stub_user="${2:-nathanjohnpayne}"
  local skip_id="${3:-0}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_ACTIVE_USER="$stub_user" \
  BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK="$skip_id" \
    bash "$HOOK" <<<"$payload"
}

# ---------------------------------------------------------------------------
# Test 1: gh pr create with correct identity + required body → exit 0
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "correct identity + valid body: hook exits 0"
else
  fail "correct identity + valid body: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 2: gh pr create with WRONG identity → exit 2 with #241 diagnostic
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' "nathanpayne-claude" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "wrong identity: exit $rc, expected 2"
elif ! echo "$out" | grep -qi "#241"; then
  fail "wrong identity: diagnostic missing #241 reference; output: $out"
elif ! echo "$out" | grep -qi "gh-as-author.sh"; then
  fail "wrong identity: diagnostic missing gh-as-author.sh reference; output: $out"
else
  pass "wrong identity: blocked with #241 + gh-as-author.sh diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 3: gh pr create with WRONG identity + escape hatch → fall through
# to existing body checks (still blocks if body missing markers, otherwise allows).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' "nathanpayne-claude" "1" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "escape hatch: identity check bypassed, body checks pass"
else
  fail "escape hatch: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 4: gh pr create with MISSING Authoring-Agent → existing check
# still fires (regression net — additive check doesn't break old behavior).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr create --title "t" --body "## Self-Review
- ok"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "missing Authoring-Agent: exit $rc, expected 2"
elif ! echo "$out" | grep -qi "Authoring-Agent:"; then
  fail "missing Authoring-Agent: diagnostic does not mention Authoring-Agent; output: $out"
else
  pass "missing Authoring-Agent: existing body check still fires"
fi

# ---------------------------------------------------------------------------
# Test 5: gh pr create with MISSING ## Self-Review → existing check fires
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr create --title "t" --body "Authoring-Agent: claude"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "missing Self-Review: exit $rc, expected 2"
elif ! echo "$out" | grep -qi "Self-Review"; then
  fail "missing Self-Review: diagnostic does not mention Self-Review; output: $out"
else
  pass "missing Self-Review: existing body check still fires"
fi

# ---------------------------------------------------------------------------
# Test 6: gh pr merge — identity check is gh pr CREATE only, so merge
# should NOT be blocked by it. Stub the labels to be empty (no
# needs-external-review) so the existing merge guard exits 0.
# ---------------------------------------------------------------------------
set +e
STUB_LABELS="" \
out=$(run_hook 'gh pr merge 123 --squash --delete-branch' "nathanpayne-claude" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "gh pr merge: identity check does NOT fire (create-only)"
else
  fail "gh pr merge: exit $rc, expected 0 (identity check should be create-only); output: $out"
fi

# ---------------------------------------------------------------------------
# Test 7: Non-gh command — hook should allow with exit 0 regardless of
# active identity.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'echo hello world' "anyone" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "non-gh command: hook allows regardless of identity"
else
  fail "non-gh command: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 8: GH_PR_GUARD_EXPECTED_AUTHOR override — custom identity matches
# active and the hook allows. Verifies the parameterization works for
# downstream repos that might want a different author identity.
# ---------------------------------------------------------------------------
set +e
payload=$(jq -n --arg c 'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' '{tool_input: {command: $c}}')
out=$(PATH="$STUB_DIR:$PATH" STUB_ACTIVE_USER="custom-author" GH_PR_GUARD_EXPECTED_AUTHOR="custom-author" bash "$HOOK" <<<"$payload" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "GH_PR_GUARD_EXPECTED_AUTHOR override: hook allows when active matches override"
else
  fail "GH_PR_GUARD_EXPECTED_AUTHOR override: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_gh_pr_guard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
