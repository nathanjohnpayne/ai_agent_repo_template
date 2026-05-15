#!/usr/bin/env bash
# tests/test_deploy.sh
#
# Unit tests for scripts/deploy.sh. Covers the two guards added /
# tightened by mergepath#286:
#
#   1. Strict-bash BUILD_CMD invocation.
#      The script must run BUILD_CMD under `bash -euo pipefail -c --`
#      rather than plain `bash -c --`. The regression case is a
#      compound command like `false; echo should-not-run`: the old
#      form returns 0 (last segment succeeds), masking the failure;
#      the strict form aborts on `false`. We assert non-zero exit AND
#      that the second segment never wrote its stdout.
#
#   2. Clean-working-tree guard.
#      With a dirty fixture worktree, the script must exit non-zero,
#      print the dirty-tree diagnostic, and list the modified path.
#      With DEPLOY_ALLOW_DIRTY=1, the same dirty fixture must allow
#      the deploy to proceed (we assert by reaching the shimmed
#      op-firebase-deploy step).
#
# Strategy: build a self-contained fixture git repo per test, run
# scripts/deploy.sh inside it with --force (to bypass guards 1+2 —
# branch + freshness — which depend on `origin/main` we don't want
# to set up) and --skip-cf-purge. Where the test needs the script
# to reach the deploy step, PATH-shim `op-firebase-deploy` so the
# script's `op-firebase-deploy "${DEPLOY_ARGS[@]}"` succeeds.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-deploy.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH shim that supplies a stub `op-firebase-deploy` so the
# script can reach its deploy step in success cases. The shim records
# its invocation to a per-test log so we can assert reachability.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/op-firebase-deploy" <<'STUB'
#!/usr/bin/env bash
echo "stub-op-firebase-deploy: invoked with args: $*" >&2
: "${OFD_LOG:?OFD_LOG must be set by the test}"
{
  printf 'op-firebase-deploy'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$OFD_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/op-firebase-deploy"

# Helper: build a throwaway git repo on a non-main branch with one
# committed file. Caller sets the working dir's dirty/clean state.
init_fixture_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init --quiet -b feature/deploy-test
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "initial" > README.md
    git add README.md
    git commit --quiet -m "initial"
  )
}

# Run scripts/deploy.sh inside a fixture repo with sensible defaults.
# Args after `--` are passed to the script.
run_deploy() {
  local repo="$1"; shift
  (
    cd "$repo"
    PATH="$STUB_DIR:$PATH" \
      OFD_LOG="$WORKDIR/ofd-calls.log" \
      bash "$SCRIPT" "$@"
  )
}

# ---------------------------------------------------------------------------
# Case 1: BUILD_CMD='false; echo should-not-run' fails closed under
# strict-bash invocation.
# ---------------------------------------------------------------------------
REPO1="$WORKDIR/case1-strict-bash"
init_fixture_repo "$REPO1"
OUT1="$WORKDIR/case1.out"
ERR1="$WORKDIR/case1.err"
: >"$WORKDIR/ofd-calls.log"

set +e
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
BUILD_CMD='false; echo should-not-run' \
  bash -c "cd '$REPO1' && bash '$SCRIPT' --force --skip-cf-purge" \
  >"$OUT1" 2>"$ERR1"
RC1=$?
set -e

if [[ $RC1 -eq 0 ]]; then
  fail "strict-bash: deploy.sh returned 0 with BUILD_CMD='false; echo should-not-run' — the OLD masking behavior is still live."
# Grep only for a LINE that is exactly 'should-not-run' (the
# `echo should-not-run` output), not any line containing the
# string — the script's own `>> Building: false; echo should-not-run`
# diagnostic echoes BUILD_CMD itself and would false-positive a
# substring match.
elif grep -qE '^should-not-run$' "$OUT1" "$ERR1" 2>/dev/null; then
  fail "strict-bash: deploy.sh ran the second segment of the compound command (output contains a bare 'should-not-run' line). Strict-bash should abort on 'false'."
elif grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "strict-bash: deploy.sh reached the op-firebase-deploy step despite the failing build — build failure was masked."
else
  pass "strict-bash: compound BUILD_CMD with leading false fails closed (rc=$RC1, no bare 'should-not-run' line, no deploy)."
fi

# ---------------------------------------------------------------------------
# Case 2: Clean-working-tree guard rejects a dirty fixture worktree.
# ---------------------------------------------------------------------------
REPO2="$WORKDIR/case2-dirty-tree"
init_fixture_repo "$REPO2"
# Introduce a dirty edit so git status --porcelain reports a modified path.
echo "uncommitted change" >> "$REPO2/README.md"

OUT2="$WORKDIR/case2.out"
ERR2="$WORKDIR/case2.err"
: >"$WORKDIR/ofd-calls.log"

set +e
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
  bash -c "cd '$REPO2' && bash '$SCRIPT' --force --skip-cf-purge --skip-build" \
  >"$OUT2" 2>"$ERR2"
RC2=$?
set -e

if [[ $RC2 -eq 0 ]]; then
  fail "dirty-tree: deploy.sh returned 0 from a dirty worktree. Guard 3 missing or non-enforcing."
elif ! grep -q 'working tree is dirty' "$ERR2"; then
  fail "dirty-tree: deploy.sh exited non-zero (rc=$RC2) but did not print the 'working tree is dirty' diagnostic to stderr. stderr was:"
  cat "$ERR2" >&2
elif ! grep -q 'README.md' "$ERR2"; then
  fail "dirty-tree: deploy.sh did not list the modified path (README.md) in its diagnostic. stderr was:"
  cat "$ERR2" >&2
elif grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "dirty-tree: deploy.sh reached the op-firebase-deploy step from a dirty worktree."
else
  pass "dirty-tree: deploy.sh exits non-zero with a clear diagnostic and the dirty paths listed (rc=$RC2)."
fi

# ---------------------------------------------------------------------------
# Case 3: DEPLOY_ALLOW_DIRTY=1 break-glass override lets the dirty
# fixture worktree deploy. We use --skip-build so the test doesn't
# depend on `npm` being installed, and check that the shimmed
# op-firebase-deploy was reached.
# ---------------------------------------------------------------------------
REPO3="$WORKDIR/case3-allow-dirty"
init_fixture_repo "$REPO3"
echo "another uncommitted change" >> "$REPO3/README.md"

OUT3="$WORKDIR/case3.out"
ERR3="$WORKDIR/case3.err"
: >"$WORKDIR/ofd-calls.log"

set +e
# Pass an arg through `--` (`--only hosting`) so DEPLOY_ARGS is
# non-empty when the script reaches `op-firebase-deploy
# "${DEPLOY_ARGS[@]}"`. macOS bash 3.2 treats empty array expansion
# under `set -u` as an unbound-variable error — that's a pre-existing
# quirk in deploy.sh independent of #286 and out of scope for this
# test; non-empty args sidestep it cleanly.
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
DEPLOY_ALLOW_DIRTY=1 \
  bash -c "cd '$REPO3' && bash '$SCRIPT' --force --skip-build --skip-cf-purge -- --only hosting" \
  >"$OUT3" 2>"$ERR3"
RC3=$?
set -e

if [[ $RC3 -ne 0 ]]; then
  fail "allow-dirty: deploy.sh returned $RC3 with DEPLOY_ALLOW_DIRTY=1 from a dirty worktree. Override is broken. stderr was:"
  cat "$ERR3" >&2
elif ! grep -q 'DEPLOY_ALLOW_DIRTY=1' "$ERR3"; then
  fail "allow-dirty: deploy.sh did not log the DEPLOY_ALLOW_DIRTY=1 override banner to stderr. stderr was:"
  cat "$ERR3" >&2
elif ! grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "allow-dirty: deploy.sh did not reach the op-firebase-deploy step despite the override."
else
  pass "allow-dirty: DEPLOY_ALLOW_DIRTY=1 override permits deploy, logs the banner, reaches the deploy step."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_deploy.sh: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
