#!/usr/bin/env bash
# tests/test_gh_pr_guard.sh
#
# Unit tests for scripts/hooks/gh-pr-guard.sh — covers the #241
# identity-check on `gh pr create`, the #170/#171 mergeStateStatus
# guard on `gh pr merge`, and a regression net for the existing
# Authoring-Agent / Self-Review body checks + needs-external-review
# label check so the newer checks are additive (don't break old
# behavior).
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

# Build a fake `gh` on PATH so the hook's `gh config get -h github.com
# user` returns a configurable value. The hook ALSO calls `gh pr view
# --json labels,mergeStateStatus` in the merge branch; this stub
# handles both. The merge-branch call emits the `MERGE_STATE|LABELS`
# single-line format the unified hook parses.
#
# For the #284 self-approve sub-guard, the stub also handles `pr view
# --json body,additions,deletions,files` — driven by STUB_PR_BODY,
# STUB_PR_ADDITIONS, STUB_PR_DELETIONS env vars. The stub returns the
# fields the hook's --jq filter expects.
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
    # Dispatch based on the --json flag value so both the merge guard's
    # labels+mergeStateStatus fetch AND the self-approve guard's
    # body+additions+deletions fetch can coexist in one stub.
    json_fields=""
    for ((i=1; i<=$#; i++)); do
      if [ "${!i}" = "--json" ]; then
        next=$((i+1))
        json_fields="${!next}"
        break
      fi
    done
    case "$json_fields" in
      *body*)
        # Self-approve sub-guard fetch: emits a single JSON-ish blob.
        # The hook's --jq filter projects it into {body, additions,
        # deletions, files} but our stub returns the same shape the
        # hook then greps. Just emit raw fields the hook looks for.
        body_safe="${STUB_PR_BODY:-}"
        additions="${STUB_PR_ADDITIONS:-0}"
        deletions="${STUB_PR_DELETIONS:-0}"
        # The hook parses additions/deletions via regex on the
        # "additions": NUM pattern, and reads PR_AUTHORING_AGENT from
        # a body grep. Emit both in a single buffer.
        printf '%s\n' "$body_safe"
        printf '"additions": %s\n' "$additions"
        printf '"deletions": %s\n' "$deletions"
        exit 0
        ;;
      *)
        # Default: merge-guard labels+mergeStateStatus fetch.
        echo "${STUB_MERGE_STATE:-CLEAN}"
        if [ -n "${STUB_LABELS:-}" ]; then
          echo "$STUB_LABELS" | tr ';' '\n'
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Build a hook-invocation envelope. The hook reads tool_input.command.
# merge_state / labels feed the `gh pr view` stub for merge-branch
# tests; they're inert for create-branch tests (the create path
# never calls `gh pr view`).
run_hook() {
  local cmd="$1"
  local stub_user="${2:-nathanjohnpayne}"
  local skip_id="${3:-0}"
  local merge_state="${4:-CLEAN}"
  local labels="${5:-}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_ACTIVE_USER="$stub_user" \
  STUB_MERGE_STATE="$merge_state" \
  STUB_LABELS="$labels" \
  BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK="$skip_id" \
    bash "$HOOK" <<<"$payload"
}

# Run the hook with explicit self-approve-guard fixtures. Used for the
# #284 byline + self-approve tests on `gh pr review`. Passes extra env
# vars the stub above reads when satisfying the body+additions+deletions
# `gh pr view` call.
run_hook_review() {
  local cmd="$1"
  local stub_user="${2:-nathanjohnpayne}"
  local skip_id="${3:-0}"
  local pr_body="${4:-}"
  local additions="${5:-0}"
  local deletions="${6:-0}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_ACTIVE_USER="$stub_user" \
  STUB_PR_BODY="$pr_body" \
  STUB_PR_ADDITIONS="$additions" \
  STUB_PR_DELETIONS="$deletions" \
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
# should NOT be blocked by it. mergeStateStatus=CLEAN + no labels so
# the merge guard exits 0.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash --delete-branch' "nathanpayne-claude" "0" "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "gh pr merge: identity check does NOT fire (create-only); CLEAN merge allowed"
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
# Test 9: gh pr merge with mergeStateStatus=BLOCKED → exit 2 with the
# #170/#171 merge-state diagnostic. This is the regression the
# propagation wave surfaced — the canonical hook had lost this guard.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash --delete-branch' "nathanjohnpayne" "0" "BLOCKED" "" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "merge BLOCKED: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "mergeStateStatus is BLOCKED"; then
  fail "merge BLOCKED: diagnostic missing 'mergeStateStatus is BLOCKED'; output: $out"
elif ! echo "$out" | grep -qi "BREAK_GLASS_MERGE_STATE"; then
  fail "merge BLOCKED: diagnostic missing BREAK_GLASS_MERGE_STATE override hint; output: $out"
else
  pass "merge BLOCKED: blocked with #170/#171 merge-state diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 10: gh pr merge BLOCKED + inline BREAK_GLASS_MERGE_STATE=1 →
# exit 0 with BREAK-GLASS notice. Exercises the inline-env capture
# path for the new override variable.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'BREAK_GLASS_MERGE_STATE=1 gh pr merge 123 --squash' "nathanjohnpayne" "0" "BLOCKED" "" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "merge BLOCKED + break-glass: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -qi "BREAK-GLASS"; then
  fail "merge BLOCKED + break-glass: missing BREAK-GLASS notice; output: $out"
else
  pass "merge BLOCKED + inline BREAK_GLASS_MERGE_STATE=1: allowed with notice"
fi

# ---------------------------------------------------------------------------
# Test 11: gh pr merge with mergeStateStatus=DIRTY → exit 2 (covers
# the BLOCKED|DIRTY|UNSTABLE|BEHIND set beyond just BLOCKED).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash' "nathanjohnpayne" "0" "DIRTY" "" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "merge DIRTY: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "mergeStateStatus is DIRTY"; then
  fail "merge DIRTY: diagnostic missing 'mergeStateStatus is DIRTY'; output: $out"
else
  pass "merge DIRTY: blocked"
fi

# ---------------------------------------------------------------------------
# Test 12: gh pr merge with mergeStateStatus=DRAFT → exit 2 with the
# draft-specific diagnostic (gh pr ready hint, not "update the case
# statement").
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash' "nathanjohnpayne" "0" "DRAFT" "" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "merge DRAFT: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "draft"; then
  fail "merge DRAFT: diagnostic missing draft-specific hint; output: $out"
else
  pass "merge DRAFT: blocked with draft-specific diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 13: gh pr merge with an unrecognized future mergeStateStatus →
# fail CLOSED (exit 2). A new GitHub API state must not silently pass.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash' "nathanjohnpayne" "0" "FUTURE_STATE" "" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "merge unknown-state: exit $rc, expected 2 (fail closed); output: $out"
elif ! echo "$out" | grep -qi "not recognized"; then
  fail "merge unknown-state: diagnostic missing 'not recognized'; output: $out"
else
  pass "merge unknown-state: fails closed"
fi

# ---------------------------------------------------------------------------
# Test 14: gh pr merge CLEAN but carrying needs-external-review with no
# CODEX_CLEARED → exit 2. Regression net: the label guard still fires
# AFTER the merge-state check passes (the two guards are independent).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash' "nathanjohnpayne" "0" "CLEAN" "needs-external-review" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "merge CLEAN + needs-external-review: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "needs-external-review"; then
  fail "merge CLEAN + needs-external-review: diagnostic missing label reference; output: $out"
else
  pass "merge CLEAN + needs-external-review (no CODEX_CLEARED): label guard still fires"
fi

# ---------------------------------------------------------------------------
# Test 15: gh pr merge CLEAN + needs-external-review + CODEX_CLEARED=1
# inline → exit 0. The merge-state check passed and the label guard is
# satisfied by the clearance claim.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'CODEX_CLEARED=1 gh pr merge 123 --squash' "nathanjohnpayne" "0" "CLEAN" "needs-external-review" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "merge CLEAN + needs-external-review + CODEX_CLEARED=1: exit $rc, expected 0; output: $out"
else
  pass "merge CLEAN + needs-external-review + CODEX_CLEARED=1: allowed"
fi

# ---------------------------------------------------------------------------
# Test 16: a label literally NAMED `team,needs-external-review` (commas
# are legal in GitHub label names) must NOT false-match the real
# `needs-external-review` gate. Regression net for the CSV-join
# ambiguity CodeRabbit caught on PR #263 — the gate is now an
# exact whole-line match, not a substring/CSV-membership test.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr merge 123 --squash' "nathanjohnpayne" "0" "CLEAN" "team,needs-external-review" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "label 'team,needs-external-review' does NOT false-match the needs-external-review gate"
else
  fail "comma-in-label false-match: exit $rc, expected 0 (the label is not literally 'needs-external-review'); output: $out"
fi

# ===========================================================================
# #284 — byline-sensitive command coverage (gh pr comment / gh pr review /
# gh issue comment / self-approve sub-guard)
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 17: gh pr comment with AUTHOR identity active → blocked (the
# byline guard rejects nathanjohnpayne for reviewer-byline commands).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr comment 123 --body "ping"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "pr comment + author identity: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "gh pr comment"; then
  fail "pr comment + author identity: diagnostic missing 'gh pr comment'; output: $out"
elif ! echo "$out" | grep -qi "REVIEWER identity"; then
  fail "pr comment + author identity: missing reviewer hint; output: $out"
else
  pass "pr comment + author identity: blocked with reviewer-byline diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 18: gh pr comment with REVIEWER identity active → allowed.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr comment 123 --body "ping"' "nathanpayne-claude" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "pr comment + reviewer identity: allowed"
else
  fail "pr comment + reviewer identity: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 19: gh pr review --comment with AUTHOR identity → blocked.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr review 123 --comment --body "review"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "pr review --comment + author identity: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "gh pr review"; then
  fail "pr review + author identity: diagnostic missing 'gh pr review'; output: $out"
else
  pass "pr review --comment + author identity: blocked"
fi

# ---------------------------------------------------------------------------
# Test 20: gh pr review --comment with REVIEWER identity → allowed.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr review 123 --comment --body "review"' "nathanpayne-claude" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "pr review --comment + reviewer identity: allowed"
else
  fail "pr review --comment + reviewer identity: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 21: gh issue comment with AUTHOR identity → blocked.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh issue comment 7 --body "thanks"' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "issue comment + author identity: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "gh issue comment"; then
  fail "issue comment + author identity: diagnostic missing 'gh issue comment'; output: $out"
else
  pass "issue comment + author identity: blocked"
fi

# ---------------------------------------------------------------------------
# Test 22: gh issue comment with REVIEWER identity → allowed.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh issue comment 7 --body "thanks"' "nathanpayne-claude" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "issue comment + reviewer identity: allowed"
else
  fail "issue comment + reviewer identity: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 23: gh issue close (non-comment issue subcommand) → allowed.
# Regression: the issue parent recognizer must NOT swallow `close`,
# `view`, etc.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh issue close 7' "nathanjohnpayne" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "issue close: allowed (only 'issue comment' is guarded)"
else
  fail "issue close: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 24: gh pr review --approve self-approve on over-threshold PR
# (Authoring-Agent: claude + active=nathanpayne-claude + size > threshold)
# → blocked. Uses a synthetic body that names claude as the authoring
# agent and 5000 additions to ensure over-threshold regardless of the
# config-file lookup.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook_review 'gh pr review 123 --approve --body "lgtm"' "nathanpayne-claude" "0" \
  "Authoring-Agent: claude" "5000" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "self-approve over-threshold: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "self-approve detected"; then
  fail "self-approve over-threshold: missing 'self-approve detected' diagnostic; output: $out"
elif ! echo "$out" | grep -qi "No-self-approve scoping"; then
  fail "self-approve over-threshold: missing policy pointer; output: $out"
else
  pass "self-approve over-threshold: blocked"
fi

# ---------------------------------------------------------------------------
# Test 25: gh pr review --approve where active identity does NOT match
# the PR's Authoring-Agent (cross-agent approve = the intended path
# for above-threshold). Should be allowed.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook_review 'gh pr review 123 --approve --body "lgtm"' "nathanpayne-codex" "0" \
  "Authoring-Agent: claude" "5000" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "cross-agent approve (codex approves claude's PR): allowed"
else
  fail "cross-agent approve: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 26: gh pr review --approve from author identity (nathanjohnpayne)
# is blocked by the byline guard BEFORE the self-approve sub-guard
# even runs. Sanity check that the layered guards stack correctly.
# ---------------------------------------------------------------------------
set +e
out=$(run_hook_review 'gh pr review 123 --approve --body "lgtm"' "nathanjohnpayne" "0" \
  "Authoring-Agent: claude" "5000" "0" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "approve from author identity: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "REVIEWER identity"; then
  fail "approve from author identity: byline guard should fire first; output: $out"
else
  pass "approve from author identity: byline guard fires before self-approve"
fi

# ---------------------------------------------------------------------------
# Test 27: gh pr review --approve, agent-author + agent-reviewer + same
# agent, but PR is UNDER threshold (small change). Should be allowed:
# under-threshold PRs are exactly the case where reviewer-identity
# --approve is the intended path.
# ---------------------------------------------------------------------------
# Create a fake review-policy.yml so the threshold parse succeeds.
# We want the heuristic to compute total < threshold.
ORIG_DIR="$(pwd)"
mkdir -p "$WORKDIR/repo-with-policy/.github"
cat >"$WORKDIR/repo-with-policy/.github/review-policy.yml" <<'YML'
external_review_threshold: 500
YML
cd "$WORKDIR/repo-with-policy"
set +e
out=$(run_hook_review 'gh pr review 123 --approve --body "small change"' "nathanpayne-claude" "0" \
  "Authoring-Agent: claude" "10" "5" 2>&1)
rc=$?
set -e
cd "$ORIG_DIR"
if [ "$rc" -eq 0 ]; then
  pass "self-approve UNDER-threshold (10+5 lines vs 500 threshold): allowed"
else
  fail "self-approve under-threshold: exit $rc, expected 0; output: $out"
fi

# ---------------------------------------------------------------------------
# Test 28: BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1 bypasses BOTH
# the byline guard and the self-approve sub-guard. Verifies the escape
# hatch still applies to the new checks (downstream test harnesses rely
# on it for the existing create/merge guards; the new guards should
# honor the same knob).
# ---------------------------------------------------------------------------
set +e
out=$(run_hook 'gh pr comment 123 --body "ping"' "nathanjohnpayne" "1" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "byline guard: BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1 bypasses pr comment block"
else
  fail "byline guard bypass: exit $rc, expected 0; output: $out"
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
