#!/usr/bin/env bash
# tests/test_bootstrap_wizard.sh
#
# Validates scripts/bootstrap-new-repo.sh's scaffold (arg parsing,
# preflight, prompts, dispatch, resume). Each subsystem stage is
# stubbed (records its own completion + logs what it would do) so the
# dispatch shape can be exercised before sub-issues B/C/D/E ship their
# real stage implementations.
#
# The wizard is run under BOOTSTRAP_SKIP_TOOL_CHECK=1 (skips
# missing-dependency checks) + BOOTSTRAP_SKIP_MERGEPATH_GUARD=1
# (skips the mergepath-must-be-on-main-and-clean check, since the
# branch this test runs on isn't main) + BOOTSTRAP_AUTO_CONFIRM=1
# (skips the "y to proceed" prompt) + BOOTSTRAP_AUTO_PROMPT=skip
# (skips interactive prompts entirely — all inputs must come from
# flags) so the test runs non-interactively under CI.
#
# Requires: bash 3.2+ (macOS default). Run manually or from
# scripts/ci/check_bootstrap_wizard.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-wizard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

run_wizard() {
  # Wrapper for the test environment: skip every preflight check that
  # depends on real on-disk state, drive prompts via flags, auto-confirm.
  BOOTSTRAP_SKIP_TOOL_CHECK=1 \
  BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 \
  BOOTSTRAP_AUTO_PROMPT=skip \
    "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: --help renders without crashing.
# ---------------------------------------------------------------------------
if "$SCRIPT" --help 2>&1 | grep -q "Usage:"; then
  pass "--help renders"
else
  fail "--help did not include Usage:"
fi

# ---------------------------------------------------------------------------
# Test 2: --version emits the version string.
# ---------------------------------------------------------------------------
if "$SCRIPT" --version 2>&1 | grep -q "bootstrap-new-repo.sh"; then
  pass "--version renders"
else
  fail "--version did not include script name"
fi

# ---------------------------------------------------------------------------
# Test 3: Missing required positional → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" --dry-run >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "missing repo-name → exit 1" \
                || fail "missing repo-name should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 4: Unknown flag → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --not-a-real-flag >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "unknown flag → exit 1" \
                || fail "unknown flag should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 5: Invalid --visibility → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --visibility invalid >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "invalid --visibility → exit 1" \
                || fail "invalid visibility should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 6: Invalid --firebase → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --firebase invalid >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "invalid --firebase → exit 1" \
                || fail "invalid firebase scope should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 7: Invalid --project (non-numeric, not 'new') → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --project banana >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "invalid --project → exit 1" \
                || fail "invalid project should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 8: Missing argument for a value-taking flag → exit 1.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --visibility 2>&1 >/dev/null
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "--visibility with no value → exit 1" \
                || fail "missing flag arg should exit 1; got $ec"

# ---------------------------------------------------------------------------
# Test 9: Dirty target dir → preflight fails with exit 2.
# ---------------------------------------------------------------------------
dirty_target="$WORKDIR/dirty-target"
mkdir -p "$dirty_target"
echo "existing content" >"$dirty_target/README.md"
set +e
out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
      BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
      "$SCRIPT" my-new-repo \
      --target-dir "$dirty_target" \
      --description "desc" --visibility private --firebase none \
      --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 2 ] && echo "$out" | grep -q "not empty" \
  && pass "dirty target dir → exit 2 with diagnostic" \
  || fail "dirty target dir should exit 2 with 'not empty' diagnostic; got rc=$ec, out: $out"

# ---------------------------------------------------------------------------
# Test 10: Empty target dir + all flags set → preflight + dispatch
# completes; state file shows all stage completions; dry-run produces
# no real side-effects (all stages just stub-print).
# ---------------------------------------------------------------------------
clean_target="$WORKDIR/clean-target"
mkdir -p "$clean_target"
set +e
out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
      BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
      "$SCRIPT" my-new-repo \
      --target-dir "$clean_target" \
      --description "test repo" --visibility private --firebase none \
      --codex-app n --project new --dry-run 2>&1)
ec=$?
set -e
if [ "$ec" -ne 0 ]; then
  fail "dry-run with all flags should exit 0; got rc=$ec, out: $out"
else
  pass "dry-run with all flags completes (exit 0)"
fi
echo "$out" | grep -q "template-mirror (sub-B stub)" \
  && pass "stage B stub ran" \
  || fail "stage B stub didn't run; got: $out"
echo "$out" | grep -q "github-infra (sub-C stub)" \
  && pass "stage C stub ran" \
  || fail "stage C stub didn't run"
echo "$out" | grep -q "firebase-and-codereview (sub-D stub)" \
  && pass "stage D stub ran" \
  || fail "stage D stub didn't run"
echo "$out" | grep -q "board-and-summary (sub-E stub)" \
  && pass "stage E stub ran" \
  || fail "stage E stub didn't run"

# ---------------------------------------------------------------------------
# Test 11: Resume mechanism. Pre-seed the state file with the first
# two stages, run with --resume, verify only stages C/D/E run.
# ---------------------------------------------------------------------------
resume_target="$WORKDIR/resume-target"
mkdir -p "$resume_target"
cat >"$resume_target/.bootstrap-state" <<'EOF'
template-mirror
github-infra
EOF
set +e
resume_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
             BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
             "$SCRIPT" my-new-repo \
             --target-dir "$resume_target" \
             --description "test repo" --visibility private --firebase none \
             --codex-app n --project new --dry-run --resume 2>&1)
resume_ec=$?
set -e
[ "$resume_ec" -eq 0 ] && pass "resume run exits 0" \
                       || fail "resume should exit 0; got $resume_ec"
echo "$resume_out" | grep -q "skip template-mirror (already completed)" \
  && pass "resume skipped template-mirror" \
  || fail "resume did not skip template-mirror; got: $resume_out"
echo "$resume_out" | grep -q "skip github-infra (already completed)" \
  && pass "resume skipped github-infra" \
  || fail "resume did not skip github-infra"
echo "$resume_out" | grep -q "firebase-and-codereview (sub-D stub)" \
  && pass "resume ran firebase-and-codereview" \
  || fail "resume did not run firebase-and-codereview"
echo "$resume_out" | grep -q "board-and-summary (sub-E stub)" \
  && pass "resume ran board-and-summary" \
  || fail "resume did not run board-and-summary"

# ---------------------------------------------------------------------------
# Test 12: --resume <explicit-stage> overrides the state-file lookup.
# Pre-seed the state file with nothing; pass --resume github-infra;
# verify only stages D/E run.
# ---------------------------------------------------------------------------
explicit_resume_target="$WORKDIR/explicit-resume-target"
mkdir -p "$explicit_resume_target"
set +e
ex_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$explicit_resume_target" \
         --description "test repo" --visibility private --firebase none \
         --codex-app n --project new --dry-run \
         --resume github-infra 2>&1)
ex_ec=$?
set -e
[ "$ex_ec" -eq 0 ] && pass "--resume <stage> exits 0" \
                   || fail "--resume <stage> should exit 0; got $ex_ec"
echo "$ex_out" | grep -q "skip github-infra (already completed)" \
  && pass "explicit-resume skipped github-infra" \
  || fail "explicit-resume did not skip github-infra"
echo "$ex_out" | grep -q "firebase-and-codereview (sub-D stub)" \
  && pass "explicit-resume ran firebase-and-codereview" \
  || fail "explicit-resume did not run firebase-and-codereview"
echo "$ex_out" | grep -q "template-mirror (sub-B stub)" \
  && fail "explicit-resume should have skipped template-mirror (came before github-infra)" \
  || pass "explicit-resume correctly skipped pre-target stages"

# ---------------------------------------------------------------------------
# Test 13: --skip-board skips stage E.
# ---------------------------------------------------------------------------
skip_board_target="$WORKDIR/skip-board-target"
mkdir -p "$skip_board_target"
set +e
sb_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$skip_board_target" \
         --description "test repo" --visibility private --firebase none \
         --codex-app n --skip-board --dry-run 2>&1)
sb_ec=$?
set -e
[ "$sb_ec" -eq 0 ] && pass "--skip-board exits 0" \
                   || fail "--skip-board should exit 0; got $sb_ec"
echo "$sb_out" | grep -q "skip board-and-summary (--skip-board)" \
  && pass "--skip-board skipped board-and-summary" \
  || fail "--skip-board should skip board-and-summary; got: $sb_out"

# ---------------------------------------------------------------------------
# Test 14: --skip-firebase implies --firebase=none.
# ---------------------------------------------------------------------------
skip_fb_target="$WORKDIR/skip-fb-target"
mkdir -p "$skip_fb_target"
set +e
sf_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$skip_fb_target" \
         --description "test repo" --visibility private \
         --skip-firebase \
         --codex-app n --project new --dry-run 2>&1)
sf_ec=$?
set -e
[ "$sf_ec" -eq 0 ] && pass "--skip-firebase exits 0" \
                   || fail "--skip-firebase should exit 0; got $sf_ec"
echo "$sf_out" | grep -q "firebase=none, skipping Firebase setup" \
  && pass "--skip-firebase routes through firebase=none branch" \
  || fail "--skip-firebase did not log firebase=none; got: $sf_out"

# ---------------------------------------------------------------------------
# Test 15: Dry-run produces the transcript log but does NOT touch
# anything outside TARGET_DIR (the log file + state recording both
# live there).
# ---------------------------------------------------------------------------
log_check_target="$WORKDIR/log-check-target"
mkdir -p "$log_check_target"
BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
  "$SCRIPT" my-new-repo \
  --target-dir "$log_check_target" \
  --description "test repo" --visibility private --firebase none \
  --codex-app n --project new --dry-run >/dev/null 2>&1
# State file should exist with all four stages recorded.
[ -f "$log_check_target/.bootstrap-state" ] \
  && pass "dry-run created state file" \
  || fail "state file missing after dry-run"
state_lines=$(wc -l <"$log_check_target/.bootstrap-state" | tr -d ' ')
[ "$state_lines" -eq 4 ] \
  && pass "state file has 4 stage entries" \
  || fail "expected 4 state-file entries; got $state_lines"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_bootstrap_wizard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
