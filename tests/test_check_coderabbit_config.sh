#!/usr/bin/env bash
# tests/test_check_coderabbit_config.sh
#
# Unit tests for scripts/ci/check_coderabbit_config — the #237 gate
# that enforces reviews.profile == "chill" on the Mergepath template's
# .coderabbit.yml.
#
# Codex P2 on #256 flagged that the original gate fired in EVERY repo
# the template-mirror bootstrap copied .github/workflows/repo_lint.yml
# into, contradicting the documented "override per-repo" guarantee.
# The fix scopes the profile-value check to the Mergepath template
# repo (detected via GITHUB_REPOSITORY / origin remote / explicit
# override env var), while keeping the YAML-parse and file-existence
# checks universal.
#
# Strategy: run the real check_coderabbit_config script against
# scratch repo roots (one per case) populated with the .coderabbit.yml
# variant under test. Drive the template detection via the
# MERGEPATH_TEMPLATE_CHECK=force|skip override so we don't depend on
# the local git remote or the runner's GITHUB_REPOSITORY env var.
#
# Bash 3.2 portable. Runs from scripts/ci/check_coderabbit_config_tests.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_coderabbit_config"

[ -x "$CHECK" ] || { echo "missing or non-executable $CHECK" >&2; exit 1; }

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not on PATH — check_coderabbit_config requires yq (mikefarah/yq v4+)." >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-coderabbit-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: run the check against a scratch repo containing the given
# .coderabbit.yml body and assert on exit code + an stdout substring.
#
#   run_case <case-name> <expected-rc> <expected-stdout-substr> \
#            <MERGEPATH_TEMPLATE_CHECK value> <coderabbit.yml body>
# ---------------------------------------------------------------------------
run_case() {
  local name=$1
  local want_rc=$2
  local want_substr=$3
  local detection=$4
  local body=$5

  local case_root
  case_root="$WORKDIR/$name"
  # The check resolves REPO_ROOT as $(dirname check)/../.. — so it
  # walks up two levels from scripts/ci/check_coderabbit_config. Lay
  # out the fixture to match that expectation.
  mkdir -p "$case_root/scripts/ci"
  cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
  chmod +x "$case_root/scripts/ci/check_coderabbit_config"

  if [ -n "$body" ]; then
    printf '%s\n' "$body" > "$case_root/.coderabbit.yml"
  fi

  local out rc=0
  # Unset GITHUB_REPOSITORY so the env var leak from CI doesn't taint
  # cases that want to exercise the override path explicitly.
  out=$(
    unset GITHUB_REPOSITORY
    MERGEPATH_TEMPLATE_CHECK="$detection" \
      "$case_root/scripts/ci/check_coderabbit_config" 2>&1
  ) || rc=$?

  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name: expected rc=$want_rc, got rc=$rc"
    echo "  output: $out" >&2
    return
  fi
  case "$out" in
    *"$want_substr"*) pass "$name (rc=$rc)" ;;
    *)
      fail "$name: stdout missing '$want_substr'"
      echo "  output: $out" >&2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# Happy path on the template: profile=chill → PASS.
run_case "template_profile_chill_passes" 0 "PASS (reviews.profile=chill)" \
  "force" \
  "reviews:
  profile: chill"

# Template with profile=assertive → FAIL with the expected error message.
run_case "template_profile_assertive_fails" 1 "FAIL: reviews.profile is 'assertive'" \
  "force" \
  "reviews:
  profile: assertive"

# Template with profile missing (default) → FAIL — yq emits "" for the
# missing field; the script reports that as the observed value.
run_case "template_profile_missing_fails" 1 "FAIL: reviews.profile is ''" \
  "force" \
  "reviews:
  request_changes_workflow: false"

# Consumer repo with profile=assertive → PASS (gate scoped out).
run_case "consumer_profile_assertive_passes" 0 \
  "profile gate skipped — not the Mergepath template repo" \
  "skip" \
  "reviews:
  profile: assertive"

# Consumer repo with profile=chill → also PASS for the same reason
# (consumers may choose either profile; the template gate is skipped).
run_case "consumer_profile_chill_passes" 0 \
  "profile gate skipped — not the Mergepath template repo" \
  "skip" \
  "reviews:
  profile: chill"

# Universal: malformed YAML fails everywhere, even on consumers.
run_case "consumer_malformed_yaml_fails" 1 "does not parse as YAML" \
  "skip" \
  "reviews:
  profile: chill
  - this: is not valid yaml at this indent: [unterminated"

# Substring assertion via `case` glob — works across newlines where
# the parameter-expansion `${out#*X}` idiom is unreliable in bash 3.2.
assert_contains() {
  local label=$1
  local rc=$2
  local want_rc=$3
  local out=$4
  local substr=$5
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$label: expected rc=$want_rc, got rc=$rc"
    echo "  output: $out" >&2
    return
  fi
  case "$out" in
    *"$substr"*) pass "$label (rc=$rc)" ;;
    *)
      fail "$label: stdout missing '$substr'"
      echo "  output: $out" >&2
      ;;
  esac
}

# Universal: missing file fails everywhere.
case_root="$WORKDIR/missing_file_fails"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
missing_rc=0
out=$(
  unset GITHUB_REPOSITORY
  MERGEPATH_TEMPLATE_CHECK=force \
    "$case_root/scripts/ci/check_coderabbit_config" 2>&1
) || missing_rc=$?
assert_contains "missing_file_fails" "$missing_rc" 1 "$out" "missing at repo root"

# GITHUB_REPOSITORY-based detection: */mergepath → template scope.
case_root="$WORKDIR/github_repository_mergepath"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
printf 'reviews:\n  profile: assertive\n' > "$case_root/.coderabbit.yml"
gr_rc=0
out=$(GITHUB_REPOSITORY=somebody/mergepath \
  "$case_root/scripts/ci/check_coderabbit_config" 2>&1) || gr_rc=$?
assert_contains "github_repository_mergepath_enforces_gate" \
  "$gr_rc" 1 "$out" "FAIL: reviews.profile is 'assertive'"

# GITHUB_REPOSITORY-based detection: not mergepath → gate skipped.
case_root="$WORKDIR/github_repository_consumer"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
printf 'reviews:\n  profile: assertive\n' > "$case_root/.coderabbit.yml"
gc_rc=0
out=$(GITHUB_REPOSITORY=somebody/some-consumer-repo \
  "$case_root/scripts/ci/check_coderabbit_config" 2>&1) || gc_rc=$?
assert_contains "github_repository_consumer_skips_gate" \
  "$gc_rc" 0 "$out" "profile gate skipped"

# Local fallback: origin URL ending in /mergepath(.git) → template scope.
# Initialize a git repo with a fake origin so the script's
# `git remote get-url origin` path fires (no GITHUB_REPOSITORY set).
case_root="$WORKDIR/git_remote_mergepath"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
printf 'reviews:\n  profile: assertive\n' > "$case_root/.coderabbit.yml"
( cd "$case_root" && git init -q && \
    git remote add origin https://github.com/someone/mergepath.git ) >/dev/null
lr_rc=0
out=$(
  unset GITHUB_REPOSITORY MERGEPATH_TEMPLATE_CHECK
  "$case_root/scripts/ci/check_coderabbit_config" 2>&1
) || lr_rc=$?
assert_contains "local_remote_mergepath_enforces_gate" \
  "$lr_rc" 1 "$out" "FAIL: reviews.profile is 'assertive'"

# Local fallback: origin URL ending in something else → gate skipped.
case_root="$WORKDIR/git_remote_consumer"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
printf 'reviews:\n  profile: assertive\n' > "$case_root/.coderabbit.yml"
( cd "$case_root" && git init -q && \
    git remote add origin git@github.com:someone/friends-and-family-billing.git ) >/dev/null
lc_rc=0
out=$(
  unset GITHUB_REPOSITORY MERGEPATH_TEMPLATE_CHECK
  "$case_root/scripts/ci/check_coderabbit_config" 2>&1
) || lc_rc=$?
assert_contains "local_remote_consumer_skips_gate" \
  "$lc_rc" 0 "$out" "profile gate skipped"

# No CI env, no origin remote → gate skipped (fail-open).
case_root="$WORKDIR/no_signals"
mkdir -p "$case_root/scripts/ci"
cp "$CHECK" "$case_root/scripts/ci/check_coderabbit_config"
chmod +x "$case_root/scripts/ci/check_coderabbit_config"
printf 'reviews:\n  profile: assertive\n' > "$case_root/.coderabbit.yml"
ns_rc=0
out=$(
  unset GITHUB_REPOSITORY MERGEPATH_TEMPLATE_CHECK
  "$case_root/scripts/ci/check_coderabbit_config" 2>&1
) || ns_rc=$?
assert_contains "no_signals_skips_gate" "$ns_rc" 0 "$out" "profile gate skipped"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_check_coderabbit_config: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
