#!/usr/bin/env bash
# tests/test_gh_as_reviewer.sh
#
# Unit tests for scripts/gh-as-reviewer.sh — companion to
# scripts/gh-as-author.sh. Same trap-EXIT shape, no post-create
# verification.
#
# CodeRabbit round-1 on #245 flagged that `exec "$@"` at the end of
# the wrapper replaces the bash process before the EXIT trap can
# fire, leaving the gh keyring stuck on the reviewer identity. The
# fix (this round) runs the wrapped command in-process and exits
# with the wrapped command's rc. This test exists primarily to
# regression-net that change (see CodeRabbit review id 3237851494).
#
# Strategy: identical to test_gh_as_author.sh — PATH-shim gh,
# record each call, assert on the call log + exit code.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-reviewer.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-reviewer-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH-shim `gh` stub. Same shape as the gh-as-author tests.
#
#   GH_CALLS_LOG          path to a file the stub appends each call to
#   GH_INITIAL_ACTIVE     value `gh config get -h github.com user` returns
#   GH_SWITCH_RC          exit code for `gh auth switch` (default 0)
#   GH_PR_REVIEW_RC       exit code for `gh pr review` (default 0)
#
# Stub UPDATES the file backing GH_INITIAL_ACTIVE on `gh auth switch
# -u <user>` so subsequent `gh config get` calls reflect the switch.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
ACTIVE_STATE_FILE="$WORKDIR/active-state"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
printf 'gh' >> "$LOG"
for a in "$@"; do
  printf '\t%s' "$a" >> "$LOG"
done
printf '\n' >> "$LOG"

case "$1 $2" in
  "config get")
    if [ -f "${ACTIVE_STATE_FILE:-/nonexistent}" ]; then
      cat "$ACTIVE_STATE_FILE"
    elif [ -n "${GH_INITIAL_ACTIVE:-}" ]; then
      echo "$GH_INITIAL_ACTIVE"
    fi
    exit 0
    ;;
  "auth switch")
    rc="${GH_SWITCH_RC:-0}"
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    # #284 silent-no-op flavor: when GH_SWITCH_SILENT_NOOP=1, return 0
    # without updating the ACTIVE_STATE_FILE. Simulates the observed
    # adversarial failure mode the post-switch verification catches.
    if [ "${GH_SWITCH_SILENT_NOOP:-0}" = "1" ]; then
      exit 0
    fi
    shift; shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-u" ]; then
        shift
        echo "$1" > "$ACTIVE_STATE_FILE"
        exit 0
      fi
      shift
    done
    exit 0
    ;;
  "pr review")
    exit "${GH_PR_REVIEW_RC:-0}"
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

reset_state() {
  : > "$WORKDIR/calls.log"
  echo "${GH_INITIAL_ACTIVE:-nathanjohnpayne}" > "$ACTIVE_STATE_FILE"
}

run_wrapper() {
  PATH="$STUB_DIR:$PATH" \
  GH_CALLS_LOG="$WORKDIR/calls.log" \
  ACTIVE_STATE_FILE="$ACTIVE_STATE_FILE" \
    "$WRAPPER" "$@"
}

# ---------------------------------------------------------------------------
# Test 1 (CodeRabbit id 3237851494): EXIT trap fires on the success
# path. The wrapper must NOT `exec` the wrapped command — that would
# replace the bash process and skip the trap, leaving the keyring
# stuck on the reviewer identity. Starting from nathanjohnpayne as
# the prior active account, after a successful `gh pr review` we
# expect to see a switch-back to nathanjohnpayne in the call log.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanjohnpayne" \
reset_state

GH_INITIAL_ACTIVE="nathanjohnpayne" \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "happy path: wrapper exited $rc, expected 0"
else
  if grep -qE $'^gh\tauth\tswitch\t-u\tnathanpayne-claude$' "$WORKDIR/calls.log"; then
    pass "happy path: switched to nathanpayne-claude"
  else
    fail "happy path: did NOT switch to nathanpayne-claude"
    cat "$WORKDIR/calls.log" >&2
  fi
  if grep -qE $'^gh\tpr\treview\t123\t' "$WORKDIR/calls.log"; then
    pass "happy path: ran gh pr review"
  else
    fail "happy path: did NOT run gh pr review"
  fi
  if grep -qE $'^gh\tauth\tswitch\t-u\tnathanjohnpayne$' "$WORKDIR/calls.log"; then
    pass "happy path: switched back to nathanjohnpayne (trap EXIT fired — no exec regression)"
  else
    fail "happy path: did NOT switch back to nathanjohnpayne — exec \"\$@\" regression?"
    cat "$WORKDIR/calls.log" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: switch-back happens even when the wrapped command fails.
# Confirms the trap fires on the non-zero-exit path too.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanjohnpayne" \
GH_PR_REVIEW_RC=1 \
reset_state

set +e
GH_INITIAL_ACTIVE="nathanjohnpayne" \
GH_PR_REVIEW_RC=1 \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "failure path: wrapper exited 0, expected non-zero"
elif grep -qE $'^gh\tauth\tswitch\t-u\tnathanjohnpayne$' "$WORKDIR/calls.log"; then
  pass "failure path: switch-back to nathanjohnpayne happened despite wrapped failure"
else
  fail "failure path: switch-back did NOT happen"
  cat "$WORKDIR/calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 3: empty prior-active fails fast with exit 1, no switch.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="" \
reset_state
: > "$ACTIVE_STATE_FILE"

set +e
PATH="$STUB_DIR:$PATH" \
GH_CALLS_LOG="$WORKDIR/calls.log" \
ACTIVE_STATE_FILE="$ACTIVE_STATE_FILE" \
GH_INITIAL_ACTIVE="" \
  "$WRAPPER" -- gh pr review 1 --comment --body "x" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "empty prior: wrapper exited $rc, expected 1"
elif grep -qE $'^gh\tauth\tswitch\t' "$WORKDIR/calls.log"; then
  fail "empty prior: gh auth switch SHOULD NOT have run when prior is empty"
  cat "$WORKDIR/calls.log" >&2
else
  pass "empty prior: failed fast without switching"
fi

# ---------------------------------------------------------------------------
# Test 4: GH_AS_REVIEWER_IDENTITY env var overrides default.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanjohnpayne" \
reset_state

GH_INITIAL_ACTIVE="nathanjohnpayne" \
GH_AS_REVIEWER_IDENTITY="custom-reviewer" \
  run_wrapper -- gh pr review 1 --comment --body "x" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "custom identity: wrapper exited $rc, expected 0"
elif ! grep -qE $'^gh\tauth\tswitch\t-u\tcustom-reviewer$' "$WORKDIR/calls.log"; then
  fail "custom identity: did not switch to custom-reviewer"
  cat "$WORKDIR/calls.log" >&2
else
  pass "custom identity: GH_AS_REVIEWER_IDENTITY override switched to custom-reviewer"
fi

# ---------------------------------------------------------------------------
# Test 5 (#284): post-switch verification failure. The stub returns 0
# from `gh auth switch` WITHOUT updating the active-state file —
# simulating a silent-no-op switch (corrupt hosts.yml / mocked gh /
# concurrent-switch race). The wrapper must fail closed before
# running the wrapped command. Exit code 2 with a clear diagnostic.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanjohnpayne" \
reset_state

set +e
stderr_capture=$(
  GH_INITIAL_ACTIVE="nathanjohnpayne" \
  GH_SWITCH_SILENT_NOOP=1 \
    run_wrapper -- gh pr review 1 --comment --body "x" 2>&1 1>/dev/null
)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "post-switch verify (silent no-op): wrapper exited $rc, expected 2"
elif ! echo "$stderr_capture" | grep -qi "POST-SWITCH VERIFICATION FAILED"; then
  fail "post-switch verify (silent no-op): missing 'POST-SWITCH VERIFICATION FAILED' diagnostic; stderr: $stderr_capture"
elif grep -qE $'^gh\tpr\treview\t' "$WORKDIR/calls.log"; then
  fail "post-switch verify (silent no-op): wrapped gh pr review SHOULD NOT have run"
  cat "$WORKDIR/calls.log" >&2
else
  pass "post-switch verify (silent no-op): exit 2 BEFORE wrapped command runs"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_gh_as_reviewer: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
