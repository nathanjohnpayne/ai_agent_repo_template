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
"$SCRIPT" some-repo --visibility >/dev/null 2>&1
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
# Skip stages D/E so the wizard scaffold test doesn't try to do real
# firebase work or wait for the board summary. Stage D is implemented
# as of #206 and has its own dedicated test
# (tests/test_bootstrap_firebase_and_codereview.sh); stage E is still
# a stub.
out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
      BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
      BOOTSTRAP_SKIP_STAGES="firebase-and-codereview,board-and-summary" \
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
echo "$out" | grep -q "Starting stage: template-mirror" \
  && pass "stage B stub ran" \
  || fail "stage B stub didn't run; got: $out"
echo "$out" | grep -q "Starting stage: github-infra" \
  && pass "stage C stub ran" \
  || fail "stage C stub didn't run"
echo "$out" | grep -q "skip firebase-and-codereview (BOOTSTRAP_SKIP_STAGES)" \
  && pass "stage D skipped via BOOTSTRAP_SKIP_STAGES" \
  || fail "stage D skip not logged; got: $out"
echo "$out" | grep -q "skip board-and-summary (BOOTSTRAP_SKIP_STAGES)" \
  && pass "stage E skipped via BOOTSTRAP_SKIP_STAGES" \
  || fail "stage E skip not logged"

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
# Skip stage D since it's now implemented and has its own dedicated
# test fixture (the wizard's scaffold-level test stays focused on
# dispatch / resume mechanics).
resume_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
             BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
             BOOTSTRAP_SKIP_STAGES="firebase-and-codereview" \
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
echo "$resume_out" | grep -q "skip firebase-and-codereview (BOOTSTRAP_SKIP_STAGES)" \
  && pass "resume skipped firebase-and-codereview via BOOTSTRAP_SKIP_STAGES" \
  || fail "resume did not skip firebase-and-codereview"
# Stage E is now real (#207 merged); banner is the standard "Starting stage:" form.
echo "$resume_out" | grep -q "Starting stage: board-and-summary" \
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
         BOOTSTRAP_SKIP_STAGES="firebase-and-codereview" \
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
echo "$ex_out" | grep -q "skip firebase-and-codereview (BOOTSTRAP_SKIP_STAGES)" \
  && pass "explicit-resume skipped firebase-and-codereview via BOOTSTRAP_SKIP_STAGES" \
  || fail "explicit-resume did not skip firebase-and-codereview"
echo "$ex_out" | grep -q "Starting stage: template-mirror" \
  && fail "explicit-resume should have skipped template-mirror (came before github-infra)" \
  || pass "explicit-resume correctly skipped pre-target stages"

# ---------------------------------------------------------------------------
# Test 13: --skip-board suppresses the Project v2 board sub-step but
# the stage still runs (summary + PRD/spec/plan scaffolds are too
# valuable to gate on whether the operator wanted a board). The
# stage's internal skip logs "project board skipped (--skip-board)".
# ---------------------------------------------------------------------------
skip_board_target="$WORKDIR/skip-board-target"
mkdir -p "$skip_board_target"
set +e
sb_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         BOOTSTRAP_SKIP_STAGES="firebase-and-codereview" \
         "$SCRIPT" my-new-repo \
         --target-dir "$skip_board_target" \
         --description "test repo" --visibility private --firebase none \
         --codex-app n --skip-board --dry-run 2>&1)
sb_ec=$?
set -e
[ "$sb_ec" -eq 0 ] && pass "--skip-board exits 0" \
                   || fail "--skip-board should exit 0; got $sb_ec"
echo "$sb_out" | grep -q "project board skipped (--skip-board)" \
  && pass "--skip-board skipped the Project v2 board sub-step" \
  || fail "--skip-board should skip project board sub-step; got: $sb_out"
# Stage E itself still runs (banner + summary).
echo "$sb_out" | grep -q "Starting stage: board-and-summary" \
  && pass "--skip-board still runs the rest of stage E (summary)" \
  || fail "--skip-board should still run stage E for the summary; got: $sb_out"

# ---------------------------------------------------------------------------
# Test 14: --skip-firebase implies --firebase=none.
# ---------------------------------------------------------------------------
skip_fb_target="$WORKDIR/skip-fb-target"
mkdir -p "$skip_fb_target"
set +e
# Note: this test exercises that --skip-firebase routes through the
# real stage D's "Firebase: scope=none" branch. We deliberately do
# NOT add stage D to BOOTSTRAP_SKIP_STAGES here — that defeats the
# purpose. Stage E (board-and-summary) is still skipped to keep the
# test focused on the firebase branch.
sf_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         BOOTSTRAP_SKIP_STAGES="board-and-summary" \
         "$SCRIPT" my-new-repo \
         --target-dir "$skip_fb_target" \
         --description "test repo" --visibility private \
         --skip-firebase \
         --codex-app n --project new --dry-run 2>&1)
sf_ec=$?
set -e
[ "$sf_ec" -eq 0 ] && pass "--skip-firebase exits 0" \
                   || fail "--skip-firebase should exit 0; got $sf_ec"
echo "$sf_out" | grep -q "Firebase: scope=none" \
  && pass "--skip-firebase routes through Firebase scope=none branch" \
  || fail "--skip-firebase did not log Firebase scope=none; got: $sf_out"

# ---------------------------------------------------------------------------
# Test 15: Dry-run produces the transcript log but does NOT touch
# anything outside TARGET_DIR (the log file + state recording both
# live there).
# ---------------------------------------------------------------------------
log_check_target="$WORKDIR/log-check-target"
mkdir -p "$log_check_target"
BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
  BOOTSTRAP_SKIP_STAGES="firebase-and-codereview,board-and-summary" \
  "$SCRIPT" my-new-repo \
  --target-dir "$log_check_target" \
  --description "test repo" --visibility private --firebase none \
  --codex-app n --project new --dry-run >/dev/null 2>&1
# State file should exist with the 2 unskipped stages recorded
# (template-mirror + github-infra; D+E are in BOOTSTRAP_SKIP_STAGES).
# BOOTSTRAP_SKIP_STAGES does not record skipped stages — only the
# dispatched-and-completed ones land in state.
[ -f "$log_check_target/.bootstrap-state" ] \
  && pass "dry-run created state file" \
  || fail "state file missing after dry-run"
state_lines=$(wc -l <"$log_check_target/.bootstrap-state" | tr -d ' ')
[ "$state_lines" -eq 2 ] \
  && pass "state file has 2 stage entries (D+E skipped via BOOTSTRAP_SKIP_STAGES)" \
  || fail "expected 2 state-file entries; got $state_lines"

# ---------------------------------------------------------------------------
# Test 16: --project with non-digit suffix (e.g., "12abc") → exit 1.
# Codex P2 round 1 caught the `new|[0-9]*` case-glob accepting trailing
# non-digit chars.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" some-repo --project 12abc >/dev/null 2>&1
ec=$?
set -e
[ "$ec" -eq 1 ] && pass "--project 12abc → exit 1" \
                || fail "--project with non-digit suffix should exit 1; got $ec"

# Negative case: --project new and --project 7 should still pass arg validation.
set +e
new_target="$WORKDIR/proj-new-target"; mkdir -p "$new_target"
BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
  "$SCRIPT" my-new-repo --target-dir "$new_target" \
  --description d --visibility private --firebase none --codex-app n \
  --project new --dry-run >/dev/null 2>&1
new_ec=$?
set -e
[ "$new_ec" -eq 0 ] && pass "--project new → exit 0" \
                    || fail "--project new should pass; got $new_ec"

set +e
num_target="$WORKDIR/proj-num-target"; mkdir -p "$num_target"
BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
  "$SCRIPT" my-new-repo --target-dir "$num_target" \
  --description d --visibility private --firebase none --codex-app n \
  --project 42 --dry-run >/dev/null 2>&1
num_ec=$?
set -e
[ "$num_ec" -eq 0 ] && pass "--project 42 → exit 0" \
                    || fail "--project 42 should pass; got $num_ec"

# ---------------------------------------------------------------------------
# Test 17: --resume with an unknown stage name → exit 1 (Codex P1
# round 1 — without the guard, dispatch silently no-ops every stage).
# ---------------------------------------------------------------------------
unknown_resume_target="$WORKDIR/unknown-resume-target"
mkdir -p "$unknown_resume_target"
set +e
ur_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$unknown_resume_target" \
         --description d --visibility private --firebase none \
         --codex-app n --project new --dry-run \
         --resume not-a-real-stage 2>&1)
ur_ec=$?
set -e
[ "$ur_ec" -ne 0 ] && pass "--resume with unknown stage → non-zero" \
                   || fail "unknown resume stage should fail; got exit 0 silently (CODEX P1)"
echo "$ur_out" | grep -q "unknown resume stage" \
  && pass "unknown resume stage produces targeted diagnostic" \
  || fail "expected 'unknown resume stage' diagnostic; got: $ur_out"

# Resume target from a STALE state file (typo or older-version
# wizard recorded a stage that doesn't exist anymore) → same exit
# path, with a guidance line that points at the state file.
stale_state_target="$WORKDIR/stale-state-target"
mkdir -p "$stale_state_target"
echo "stage-from-a-prior-version" >"$stale_state_target/.bootstrap-state"
set +e
ss_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         BOOTSTRAP_AUTO_CONFIRM=1 BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$stale_state_target" \
         --description d --visibility private --firebase none \
         --codex-app n --project new --dry-run \
         --resume 2>&1)
ss_ec=$?
set -e
[ "$ss_ec" -ne 0 ] && pass "--resume with stale state-file stage → non-zero" \
                   || fail "stale state-file stage should fail; got 0"
echo "$ss_out" | grep -q "state file" \
  && pass "stale state-file diagnostic points at the file" \
  || fail "expected 'state file' diagnostic; got: $ss_out"

# ---------------------------------------------------------------------------
# Test 18: Firebase dep check is deferred until after prompts populate
# the input (Codex P1 round 1 — the original gating against
# `BOOTSTRAP_INPUT_FIREBASE != "none"` rejected interactive runs that
# defaulted to none). Simulate by NOT passing --firebase and NOT having
# firebase/gcloud installed (SKIP_TOOL_CHECK=0 + a tmpdir PATH).
# ---------------------------------------------------------------------------
fb_defer_target="$WORKDIR/fb-defer-target"
mkdir -p "$fb_defer_target"
# Manufactured PATH with only the absolute minimum (bash, gh, op, git).
# If `firebase` and `gcloud` aren't on this PATH AND the user supplied
# --firebase none, the deferred check should pass with exit 0.
empty_path_dir="$WORKDIR/empty-path-dir"
mkdir -p "$empty_path_dir"
# Symlink the bootstrap-required tools into the manufactured PATH
# dir so preflight's tool check passes; firebase/gcloud are
# deliberately absent. yq + rsync became required in round 3 of
# #233 (Codex P1: stage-B must fail-closed when yq is unavailable),
# so they're part of the minimum set now.
for tool in bash gh op git yq rsync; do
  src=$(command -v "$tool" || true)
  if [ -n "$src" ]; then ln -sf "$src" "$empty_path_dir/$tool"; fi
done
set +e
# Include /usr/bin and /bin so coreutils (dirname, sed, etc.) resolve.
# Crucially: NO /opt/homebrew/bin and NO ~/google-cloud-sdk/bin, so
# `firebase` and `gcloud` are NOT findable — that's the scenario under
# test (operator on a fresh machine, picks --firebase none).
fb_out=$(PATH="$empty_path_dir:/usr/bin:/bin" \
         BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 BOOTSTRAP_AUTO_CONFIRM=1 \
         BOOTSTRAP_AUTO_PROMPT=skip \
         "$SCRIPT" my-new-repo \
         --target-dir "$fb_defer_target" \
         --description d --visibility private --firebase none \
         --codex-app n --project new --dry-run 2>&1)
fb_ec=$?
set -e
[ "$fb_ec" -eq 0 ] && pass "--firebase none passes even without firebase/gcloud on PATH" \
                   || fail "--firebase none should pass when firebase/gcloud missing; got rc=$fb_ec, out: $fb_out"

# ---------------------------------------------------------------------------
# Test 19: Interactive prompt --project validation mirrors the flag
# (CodeRabbit round 2 — same `[0-9]*` glob bug existed at the
# read-loop's case statement). Pipe "12abc\n" to the wizard with no
# --project flag; the prompt should reject and exit 1.
# ---------------------------------------------------------------------------
ip_target="$WORKDIR/interactive-proj-target"
mkdir -p "$ip_target"
set +e
ip_out=$(printf '12abc\n' | BOOTSTRAP_SKIP_TOOL_CHECK=1 \
         BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
         "$SCRIPT" my-new-repo \
         --target-dir "$ip_target" \
         --description d --visibility private --firebase none \
         --codex-app n --dry-run 2>&1)
ip_ec=$?
set -e
[ "$ip_ec" -ne 0 ] && pass "interactive --project 12abc → non-zero" \
                  || fail "interactive prompt should reject '12abc'; got rc=$ip_ec, out: $ip_out"
echo "$ip_out" | grep -q "invalid project value" \
  && pass "interactive --project rejection emits 'invalid project value'" \
  || fail "expected 'invalid project value' diagnostic; got: $ip_out"

# Test 20: Interactive prompt accepts empty/new and digits-only.
ip_ok_target="$WORKDIR/interactive-proj-ok-target"
mkdir -p "$ip_ok_target"
set +e
ip_ok_out=$(printf '7\n' | BOOTSTRAP_SKIP_TOOL_CHECK=1 \
            BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
            "$SCRIPT" my-new-repo \
            --target-dir "$ip_ok_target" \
            --description d --visibility private --firebase none \
            --codex-app n --dry-run 2>&1)
ip_ok_ec=$?
set -e
[ "$ip_ok_ec" -eq 0 ] && pass "interactive --project 7 → exit 0" \
                     || fail "interactive '7' should succeed; got rc=$ip_ok_ec"
echo "$ip_ok_out" | grep -q "project: *7" \
  && pass "interactive '7' captured as project=7" \
  || fail "expected 'project: 7' summary; got: $ip_ok_out"

# ---------------------------------------------------------------------------
# Test 21: Env-provided BOOTSTRAP_INPUT_* preserved across prompt path
# (Codex P2 round 1 on #246). Pre-set BOOTSTRAP_INPUT_PROJECT=7 with
# NO --project flag and NO BOOTSTRAP_AUTO_PROMPT=skip. Before the fix,
# the FROM_FLAG_PROJECT sentinel was empty so prompt_for_inputs()
# would prompt and overwrite the env value (default "new" on empty
# input). After the fix, the env-pre-set value seeds the sentinel
# and the prompt is skipped. We pipe an empty line to confirm the
# prompt is NOT consumed; if the fix regressed, project would be
# captured as "new" instead of "7".
# ---------------------------------------------------------------------------
env_proj_target="$WORKDIR/env-proj-target"
mkdir -p "$env_proj_target"
set +e
# stdin closed (`</dev/null`) so any errant `read -r` would fail
# immediately rather than block. With the fix, no read should fire
# for the project prompt.
env_proj_out=$(BOOTSTRAP_SKIP_TOOL_CHECK=1 \
               BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
               BOOTSTRAP_INPUT_PROJECT=7 \
               "$SCRIPT" my-new-repo \
               --target-dir "$env_proj_target" \
               --description d --visibility private --firebase none \
               --codex-app n --dry-run </dev/null 2>&1)
env_proj_ec=$?
set -e
if [ "$env_proj_ec" -eq 0 ]; then
  pass "env BOOTSTRAP_INPUT_PROJECT=7 dry-run → exit 0"
else
  fail "env BOOTSTRAP_INPUT_PROJECT=7 should succeed; got rc=$env_proj_ec, out: $env_proj_out"
fi
if echo "$env_proj_out" | grep -q "project: *7"; then
  pass "env BOOTSTRAP_INPUT_PROJECT=7 preserved (not overwritten by prompt)"
else
  fail "expected 'project: 7' summary; env value was overwritten. out: $env_proj_out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_bootstrap_wizard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
