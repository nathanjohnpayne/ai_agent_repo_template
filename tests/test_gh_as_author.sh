#!/usr/bin/env bash
# tests/test_gh_as_author.sh
#
# Unit tests for scripts/gh-as-author.sh — the #241 wrapper that
# atomically switches the gh keyring's active account to the AUTHOR
# identity, runs a wrapped gh command, then restores the prior active
# account via trap EXIT.
#
# Strategy: PATH-shim `gh` with a stub that records every invocation
# in $GH_CALLS_LOG and simulates `gh auth switch` / `gh config get` /
# `gh pr create` / `gh pr view` so the script can run end-to-end
# without touching the real keyring or the network. Each test asserts
# on the contents of the call log and the script's exit code.
#
# Bash 3.2 portable. Runs from `scripts/ci/check_gh_as_author`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-author.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-author-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH-shim `gh` stub. Driven by env vars set per test:
#
#   GH_CALLS_LOG          path to a file the stub appends each call to
#   GH_INITIAL_ACTIVE     value `gh config get -h github.com user` returns
#   GH_CREATE_PR_URL      URL `gh pr create` prints on stdout
#   GH_CREATE_PR_RC       exit code for `gh pr create` (default 0)
#   GH_VIEW_AUTHOR        author.login `gh pr view` returns (default
#                         GH_INITIAL_ACTIVE — typical happy path)
#   GH_VIEW_RC            exit code for `gh pr view` (default 0)
#   GH_SWITCH_RC          exit code for `gh auth switch` (default 0)
#
# The stub also UPDATES the file backing GH_INITIAL_ACTIVE on a
# `gh auth switch -u <user>` so subsequent `gh config get` calls
# reflect the switch — important for verifying the trap-EXIT switch-
# back actually restores prior.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
ACTIVE_STATE_FILE="$WORKDIR/active-state"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Record the call. NUL-delimited args so embedded spaces / quotes
# can't confuse the test assertions.
LOG="${GH_CALLS_LOG:-/dev/null}"
printf 'gh' >> "$LOG"
for a in "$@"; do
  printf '\t%s' "$a" >> "$LOG"
done
printf '\n' >> "$LOG"

# Dispatch on the subcommand grammar this wrapper exercises.
case "$1 $2" in
  "config get")
    # Args: config get -h github.com user
    if [ -f "${ACTIVE_STATE_FILE:-/nonexistent}" ]; then
      cat "$ACTIVE_STATE_FILE"
    elif [ -n "${GH_INITIAL_ACTIVE:-}" ]; then
      echo "$GH_INITIAL_ACTIVE"
    fi
    exit 0
    ;;
  "auth switch")
    # Args: auth switch -u <user>
    rc="${GH_SWITCH_RC:-0}"
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    # #284 silent-no-op flavor: when GH_SWITCH_SILENT_NOOP=1, return 0
    # without updating the ACTIVE_STATE_FILE. This simulates the
    # observed adversarial failure mode (corrupt hosts.yml, mocked
    # gh, concurrent-switch race) that the post-switch verification
    # is designed to catch.
    if [ "${GH_SWITCH_SILENT_NOOP:-0}" = "1" ]; then
      exit 0
    fi
    # Find -u value
    shift; shift # consume `auth switch`
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
  "pr create")
    echo "${GH_CREATE_PR_URL:-https://github.com/example/repo/pull/999}"
    exit "${GH_CREATE_PR_RC:-0}"
    ;;
  "pr view")
    rc="${GH_VIEW_RC:-0}"
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    # Args: pr view <PR#> --repo <repo> --json author --jq .author.login
    echo "${GH_VIEW_AUTHOR:-${GH_INITIAL_ACTIVE:-nathanjohnpayne}}"
    exit 0
    ;;
  *)
    # Unknown command — succeed quietly so tests can pass arbitrary
    # commands through the wrapper without orchestration overhead.
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

reset_state() {
  : > "$WORKDIR/calls.log"
  echo "${GH_INITIAL_ACTIVE:-nathanpayne-claude}" > "$ACTIVE_STATE_FILE"
}

# Run the wrapper with the stubbed PATH. Args are passed verbatim.
# Returns the wrapper's exit code via the outer shell ($?).
run_wrapper() {
  PATH="$STUB_DIR:$PATH" \
  GH_CALLS_LOG="$WORKDIR/calls.log" \
  ACTIVE_STATE_FILE="$ACTIVE_STATE_FILE" \
    "$WRAPPER" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: Happy path — gh pr create switches to author, runs create,
# verifies author, switches back to prior. Five gh calls expected:
#   1. gh config get -h github.com user        (capture prior)
#   2. gh auth switch -u nathanjohnpayne       (switch to author)
#   3. gh pr create ...                        (the wrapped command)
#   4. gh pr view 999 --repo ... ...           (verification)
#   5. gh auth switch -u nathanpayne-claude    (trap EXIT switch-back)
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_URL="https://github.com/example/repo/pull/42" \
GH_VIEW_AUTHOR="nathanjohnpayne" \
reset_state

GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_URL="https://github.com/example/repo/pull/42" \
GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" --body "b" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "happy path: wrapper exited $rc, expected 0"
else
  # Verify switch-to-author happened.
  if grep -qP '^gh\tauth\tswitch\t-u\tnathanjohnpayne$' "$WORKDIR/calls.log" 2>/dev/null \
    || grep -qE $'^gh\tauth\tswitch\t-u\tnathanjohnpayne$' "$WORKDIR/calls.log"; then
    pass "happy path: switched to nathanjohnpayne"
  else
    fail "happy path: did NOT switch to nathanjohnpayne"
    cat "$WORKDIR/calls.log" >&2
  fi
  # Verify pr create happened.
  if grep -qE $'^gh\tpr\tcreate\t' "$WORKDIR/calls.log"; then
    pass "happy path: ran gh pr create"
  else
    fail "happy path: did NOT run gh pr create"
  fi
  # Verify post-create verification happened.
  if grep -qE $'^gh\tpr\tview\t42\t' "$WORKDIR/calls.log"; then
    pass "happy path: ran post-create gh pr view"
  else
    fail "happy path: did NOT run post-create gh pr view"
    cat "$WORKDIR/calls.log" >&2
  fi
  # Verify switch-back to prior happened.
  if grep -qE $'^gh\tauth\tswitch\t-u\tnathanpayne-claude$' "$WORKDIR/calls.log"; then
    pass "happy path: switched back to nathanpayne-claude (trap EXIT)"
  else
    fail "happy path: did NOT switch back to nathanpayne-claude"
    cat "$WORKDIR/calls.log" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Switch-back happens on wrapped command failure (trap EXIT).
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_RC=1 \
reset_state

set +e
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_RC=1 \
  run_wrapper -- gh pr create --title "t" --body "b" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "failure path: wrapper exited 0, expected non-zero (gh pr create failed with rc=1)"
elif grep -qE $'^gh\tauth\tswitch\t-u\tnathanpayne-claude$' "$WORKDIR/calls.log"; then
  pass "failure path: switch-back to nathanpayne-claude happened despite gh pr create failure"
else
  fail "failure path: switch-back did NOT happen on gh pr create failure"
  cat "$WORKDIR/calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 3: Post-create author verification mismatch → exit 5 with
# diagnostic. Stub returns GH_VIEW_AUTHOR != GH_AS_AUTHOR_IDENTITY.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" \
GH_VIEW_AUTHOR="nathanpayne-claude" \
reset_state

set +e
stderr_capture=$(
  GH_INITIAL_ACTIVE="nathanpayne-claude" \
  GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" \
  GH_VIEW_AUTHOR="nathanpayne-claude" \
    run_wrapper -- gh pr create --title "t" --body "b" 2>&1 1>/dev/null
)
rc=$?
set -e
if [ "$rc" -ne 5 ]; then
  fail "verification mismatch: wrapper exited $rc, expected 5"
elif ! echo "$stderr_capture" | grep -qi "ERROR PR #77.*landed under 'nathanpayne-claude'"; then
  fail "verification mismatch: missing diagnostic in stderr"
  echo "stderr was: $stderr_capture" >&2
elif ! echo "$stderr_capture" | grep -qi "#241"; then
  fail "verification mismatch: diagnostic does not reference #241"
else
  pass "verification mismatch: exit 5 with #241 diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 4: Non-gh-pr-create commands skip the verification path.
# Wrapping a `gh pr merge` (or anything else) should NOT trigger
# the extra gh pr view call.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
reset_state

GH_INITIAL_ACTIVE="nathanpayne-claude" \
  run_wrapper -- gh pr merge 123 --squash --delete-branch >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "non-create path: wrapper exited $rc, expected 0"
elif grep -qE $'^gh\tpr\tview\t' "$WORKDIR/calls.log"; then
  fail "non-create path: post-create verification SHOULD NOT run for gh pr merge"
  cat "$WORKDIR/calls.log" >&2
else
  pass "non-create path: no post-create verification ran for gh pr merge"
fi

# Same call must also have fired the trap to switch back. Without
# the fix in this round, `exec "$@"` on the non-create path would
# replace the shell process and skip the EXIT trap — see CodeRabbit
# round-1 review id 3237851481.
if grep -qE $'^gh\tauth\tswitch\t-u\tnathanpayne-claude$' "$WORKDIR/calls.log"; then
  pass "non-create path: trap EXIT switch-back fired (no exec)"
else
  fail "non-create path: trap EXIT switch-back did NOT fire — exec \"\$@\" regression?"
  cat "$WORKDIR/calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 5: Empty prior-active fails fast with exit 1, no switch, no
# wrapped command.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="" \
reset_state
# Override the active state file to be empty
: > "$ACTIVE_STATE_FILE"

set +e
PATH="$STUB_DIR:$PATH" \
GH_CALLS_LOG="$WORKDIR/calls.log" \
ACTIVE_STATE_FILE="$ACTIVE_STATE_FILE" \
GH_INITIAL_ACTIVE="" \
  "$WRAPPER" -- gh pr merge 123 --squash --delete-branch >/dev/null 2>&1
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
# Test 6: GH_AS_AUTHOR_IDENTITY env var overrides default.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
reset_state

GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_AS_AUTHOR_IDENTITY="custom-author" \
  run_wrapper -- gh pr merge 1 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "custom identity: wrapper exited $rc, expected 0"
elif ! grep -qE $'^gh\tauth\tswitch\t-u\tcustom-author$' "$WORKDIR/calls.log"; then
  fail "custom identity: did not switch to custom-author"
  cat "$WORKDIR/calls.log" >&2
else
  pass "custom identity: GH_AS_AUTHOR_IDENTITY override switched to custom-author"
fi

# ---------------------------------------------------------------------------
# Test 7 (CodeRabbit round-1 id 3237851475 + 3237851481): fail-closed
# when the PR URL cannot be extracted from gh pr create output. Prior
# to this round the wrapper silently exited 0 when `grep -oE ... |
# tail -1` returned empty, letting downstream automation treat an
# unverified create as verified. Set GH_CREATE_PR_URL to a string the
# regex can't match and assert the wrapper exits 5 with an ERROR (not
# WARNING) diagnostic mentioning the manual verification command.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_URL="created PR but no URL in output" \
reset_state

set +e
stderr_capture=$(
  GH_INITIAL_ACTIVE="nathanpayne-claude" \
  GH_CREATE_PR_URL="created PR but no URL in output" \
    run_wrapper -- gh pr create --title "t" --body "b" 2>&1 1>/dev/null
)
rc=$?
set -e
if [ "$rc" -ne 5 ]; then
  fail "fail-closed (no PR URL): wrapper exited $rc, expected 5"
elif ! echo "$stderr_capture" | grep -qi "ERROR could not extract PR URL"; then
  fail "fail-closed (no PR URL): missing ERROR diagnostic; stderr: $stderr_capture"
elif echo "$stderr_capture" | grep -qi "WARNING.*skipping post-create"; then
  fail "fail-closed (no PR URL): still emitting WARNING/skipping language; stderr: $stderr_capture"
else
  pass "fail-closed (no PR URL): exit 5 with ERROR diagnostic"
fi

# ---------------------------------------------------------------------------
# Test 8 (CodeRabbit round-1 id 3237851475 + 3237851481): fail-closed
# when gh pr view (the verification read) fails. Prior to this round
# the wrapper silently exited 0 on `gh pr view` failure, masking
# transient network blips and permission issues as verified creates.
# Set GH_VIEW_RC=1 and assert the wrapper exits 5.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
GH_CREATE_PR_URL="https://github.com/example/repo/pull/99" \
GH_VIEW_RC=1 \
reset_state

set +e
stderr_capture=$(
  GH_INITIAL_ACTIVE="nathanpayne-claude" \
  GH_CREATE_PR_URL="https://github.com/example/repo/pull/99" \
  GH_VIEW_RC=1 \
    run_wrapper -- gh pr create --title "t" --body "b" 2>&1 1>/dev/null
)
rc=$?
set -e
if [ "$rc" -ne 5 ]; then
  fail "fail-closed (gh pr view error): wrapper exited $rc, expected 5"
elif ! echo "$stderr_capture" | grep -qi "ERROR could not read PR author"; then
  fail "fail-closed (gh pr view error): missing ERROR diagnostic; stderr: $stderr_capture"
elif echo "$stderr_capture" | grep -qi "WARNING.*Skipping post-create"; then
  fail "fail-closed (gh pr view error): still emitting WARNING/skipping language; stderr: $stderr_capture"
else
  pass "fail-closed (gh pr view error): exit 5 with ERROR diagnostic"
fi

# Both fail-closed paths must STILL have fired the trap to restore
# the prior active account — verification failure must not leave
# the keyring stuck on the author identity.
if grep -qE $'^gh\tauth\tswitch\t-u\tnathanpayne-claude$' "$WORKDIR/calls.log"; then
  pass "fail-closed (gh pr view error): trap EXIT switch-back fired"
else
  fail "fail-closed (gh pr view error): trap EXIT switch-back did NOT fire"
  cat "$WORKDIR/calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 9 (#284): post-switch verification failure. The stub returns 0
# from `gh auth switch` WITHOUT updating the active-state file —
# simulating a silent-no-op switch (corrupt hosts.yml / mocked gh /
# concurrent-switch race). The wrapper must fail closed before
# running the wrapped command, NOT proceed to gh pr create under the
# wrong identity. Exit code 2 (switch failure) and a clear diagnostic.
# ---------------------------------------------------------------------------
GH_INITIAL_ACTIVE="nathanpayne-claude" \
reset_state

set +e
stderr_capture=$(
  GH_INITIAL_ACTIVE="nathanpayne-claude" \
  GH_SWITCH_SILENT_NOOP=1 \
    run_wrapper -- gh pr merge 1 --squash 2>&1 1>/dev/null
)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "post-switch verify (silent no-op): wrapper exited $rc, expected 2"
elif ! echo "$stderr_capture" | grep -qi "POST-SWITCH VERIFICATION FAILED"; then
  fail "post-switch verify (silent no-op): missing 'POST-SWITCH VERIFICATION FAILED' diagnostic; stderr: $stderr_capture"
elif grep -qE $'^gh\tpr\tmerge\t' "$WORKDIR/calls.log"; then
  fail "post-switch verify (silent no-op): wrapped gh pr merge SHOULD NOT have run"
  cat "$WORKDIR/calls.log" >&2
else
  pass "post-switch verify (silent no-op): exit 2 BEFORE wrapped command runs"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_gh_as_author: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
