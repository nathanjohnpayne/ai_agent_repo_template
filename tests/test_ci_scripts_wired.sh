#!/usr/bin/env bash
# tests/test_ci_scripts_wired.sh
#
# Unit tests for scripts/ci/check_ci_scripts_wired — the structural
# guard added in #269 that fails closed when an executable
# scripts/ci/check_* file is missing from .github/workflows/repo_lint.yml.
#
# Each case sets up a scratch directory with a synthetic
# scripts/ci/ tree + a minimal .github/workflows/repo_lint.yml and
# invokes the real check script with REPO_ROOT pointing at the
# scratch dir (the script computes REPO_ROOT relative to its own
# location, so we copy the script into the scratch dir for each
# case).
#
# Bash 3.2 portable. Follows the test_gh_pr_guard.sh scaffolding
# pattern.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_ci_scripts_wired"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-scripts-wired-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a scratch fake-repo and copy the real check script into the
# matching scripts/ci/ location so REPO_ROOT resolves correctly.
# Args:
#   $1 — case name (subdir under WORKDIR)
# Returns the scratch repo root via stdout.
make_scratch_repo() {
  local case_name="$1"
  local repo="$WORKDIR/$case_name"
  mkdir -p "$repo/scripts/ci" "$repo/.github/workflows"
  cp "$CHECK" "$repo/scripts/ci/check_ci_scripts_wired"
  chmod +x "$repo/scripts/ci/check_ci_scripts_wired"
  printf '%s' "$repo"
}

# Write an executable check_* stub at scripts/ci/<name>.
mk_check() {
  local repo="$1"
  local name="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/ci/$name"
  chmod +x "$repo/scripts/ci/$name"
}

# Write a non-executable check_* file at scripts/ci/<name>.
mk_check_nonexec() {
  local repo="$1"
  local name="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/ci/$name"
  chmod -x "$repo/scripts/ci/$name"
}

# Write a workflow file from a heredoc-passed body.
mk_workflow() {
  local repo="$1"
  local body="$2"
  printf '%s\n' "$body" >"$repo/.github/workflows/repo_lint.yml"
}

run_check() {
  local repo="$1"
  ( cd "$repo" && bash "$repo/scripts/ci/check_ci_scripts_wired" )
}

# ---------------------------------------------------------------------------
# Case 1: all wired → pass.
# Two checks on disk, both have explicit `run:` lines in the workflow.
# Note: check_ci_scripts_wired itself is always on disk in the scratch
# repo, so the workflow must also wire it.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case1_all_wired)"
mk_check "$repo" check_foo
mk_check "$repo" check_bar
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
      - name: check_bar
        run: ./scripts/ci/check_bar
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "all wired: exit 0"
else
  fail "all wired: exit $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 2: one missing → fail with the specific missing name in output.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case2_one_missing)"
mk_check "$repo" check_foo
mk_check "$repo" check_bar
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "one missing: expected nonzero exit, got 0; output: $out"
elif ! echo "$out" | grep -q "check_bar"; then
  fail "one missing: diagnostic does not name check_bar; output: $out"
else
  pass "one missing: fails closed and names check_bar"
fi

# ---------------------------------------------------------------------------
# Case 3: duplicate workflow entry → pass (not an error).
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case3_duplicate)"
mk_check "$repo" check_foo
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
      - name: check_foo_again
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "duplicate entry: pass (inefficient but not a correctness failure)"
else
  fail "duplicate entry: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 4: comment-only mention of a script → NOT counted as wired.
# The workflow references check_foo only inside a comment line; the
# check must still flag it as missing.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case4_comment_only)"
mk_check "$repo" check_foo
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      # The next step covers ./scripts/ci/check_foo behavior — note
      # this is a COMMENT, not a real wiring.
      - name: something_else
        run: echo unrelated
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "comment-only mention: expected fail, comment should not count as wired; output: $out"
elif ! echo "$out" | grep -q "check_foo"; then
  fail "comment-only mention: diagnostic does not name check_foo; output: $out"
else
  pass "comment-only mention: NOT counted as wired"
fi

# ---------------------------------------------------------------------------
# Case 5: non-executable check file → excluded from the on-disk set.
# A check_* file that exists but is not executable should not be
# required to be wired (it's typically a WIP or fixture).
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case5_nonexec)"
mk_check "$repo" check_foo
mk_check_nonexec "$repo" check_not_ready_yet
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "non-executable check file: excluded from on-disk set"
else
  fail "non-executable check file: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_ci_scripts_wired: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
