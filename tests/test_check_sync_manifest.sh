#!/usr/bin/env bash
# tests/test_check_sync_manifest.sh
#
# Unit tests for scripts/ci/check_sync_manifest — specifically the
# new `requires:` closure invariant added in #264. The pre-existing
# manifest-shape checks (consumer set, type set, etc.) are covered
# implicitly by running the check against the live .mergepath-sync.yml
# in PR CI; this file targets the new closure logic.
#
# Pattern matches tests/test_gh_pr_guard.sh — fixture manifests
# written to a scratch dir, run check_sync_manifest via env override,
# assert on exit code + diagnostic substring.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_sync_manifest"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-sync-manifest-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Helper: build a fixture repo tree (with stub files for every path
# referenced in the manifest) and run the check against it. Sets both
# MERGEPATH_MANIFEST_PATH and MERGEPATH_REPO_ROOT so the check probes
# the fixture instead of the live repo. The pre-existing path-
# existence check requires every canonical/templated path in the
# manifest to be a real file, so the helper touches each one in the
# fixture root before invoking the check.
#
# Args: $1 = manifest YAML content, $2 = newline-separated list of
# repo-relative paths to materialize (files for non-trailing-slash
# entries, dirs for trailing-slash kit entries).
run_with_fixture() {
  local manifest_content="$1" paths="$2"
  local fix
  fix="$(mktemp -d "$WORKDIR/fix.XXXXXX")"
  printf '%s' "$manifest_content" > "$fix/manifest.yml"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      */) mkdir -p "$fix/$p" ;;
      *)  mkdir -p "$(dirname "$fix/$p")"; : > "$fix/$p" ;;
    esac
  done <<< "$paths"
  MERGEPATH_MANIFEST_PATH="$fix/manifest.yml" MERGEPATH_REPO_ROOT="$fix" bash "$CHECK" 2>&1
}

# --- Test fixture: baseline well-formed manifest --------------------
MIN_HEADER='version: 1
consumers:
  - name: example
    repo: example-org/example
    visibility: public
paths:'

# --- Case 1: requires: all satisfied by exact + kit-prefix coverage -
MANIFEST_SAT="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_kit_helper.sh\"
      - \"scripts/ci/fixtures/foo.json\"
  - path: tests/test_kit_helper.sh
    type: canonical
    consumers: all
"
PATHS_SAT="scripts/foo.sh
tests/test_foo.sh
tests/test_kit_helper.sh
scripts/ci/
scripts/ci/fixtures/foo.json"
set +e
out=$(run_with_fixture "$MANIFEST_SAT" "$PATHS_SAT"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 1: requires: satisfied by exact + kit-prefix coverage"
else
  fail "Case 1 unexpected (rc=$rc): $out"
fi

# --- Case 2: requires: pointing at an UNCOVERED path ----------------
MANIFEST_UNCOV="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"tests/missing.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_UNCOV="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_UNCOV" "$PATHS_UNCOV"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "requires 'tests/missing.sh' but that path is not covered"; then
  pass "Case 2: uncovered requires fails closed with named-path diagnostic"
else
  fail "Case 2 unexpected (rc=$rc): $out"
fi

# --- Case 3: entry WITHOUT requires: stays valid --------------------
MANIFEST_NOREQ="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_NOREQ="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_NOREQ" "$PATHS_NOREQ"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "PASS"; then
  pass "Case 3: missing requires: is valid (optional field)"
else
  fail "Case 3 unexpected (rc=$rc): $out"
fi

# --- Case 4: malformed requires: (scalar instead of sequence) ------
MANIFEST_MAL="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires: \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_MAL="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_MAL" "$PATHS_MAL"); rc=$?
set -e
# yq's `.requires[]` on a scalar errors OR splits per-char depending on
# version; either way the check must exit non-zero with FAIL output.
if [ "$rc" = "1" ] && echo "$out" | grep -q "FAIL"; then
  pass "Case 4: scalar requires: rejected (fails closed)"
else
  fail "Case 4 unexpected (rc=$rc): $out"
fi

# --- Case 5: kit-prefix boundary — adjacent dir does NOT count -----
# `scripts/ci/foo` should be covered by `scripts/ci/` kit, but
# `scripts/cinema/foo` must NOT be covered by `scripts/ci/` (the prefix
# match is slash-bounded).
MANIFEST_BOUND="$MIN_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers: all
    requires:
      - \"scripts/cinema/foo.sh\"
  - path: scripts/ci/
    type: kit
    consumers: all
"
PATHS_BOUND="scripts/foo.sh
scripts/ci/"
set +e
out=$(run_with_fixture "$MANIFEST_BOUND" "$PATHS_BOUND"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "requires 'scripts/cinema/foo.sh' but that path is not covered"; then
  pass "Case 5: kit-prefix is slash-bounded (scripts/ci/ does NOT cover scripts/cinema/)"
else
  fail "Case 5 unexpected (rc=$rc): $out"
fi

# --- Case 6: consumer-scope-aware closure (#264 r2) ----------------
#
# nathanpayne-codex Phase 4b r1 on PR #294: the original closure
# check verified that a required path was IN the manifest but did
# NOT verify that the required path's `consumers:` covered the
# requirer's `consumers:`. If a kit propagates to `consumers: all`
# but a `requires:` entry points at a path with `consumers:
# [matchline]`, the other consumers still miss the dependency at
# lint time.

# Need at least two consumers to express a non-universal subset.
MULTI_HEADER='version: 1
consumers:
  - name: matchline
    repo: org/matchline
    visibility: public
  - name: swipewatch
    repo: org/swipewatch
    visibility: public
paths:'

MANIFEST_SCOPE_GAP="$MULTI_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
"
PATHS_SCOPE_GAP="scripts/ci/
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_SCOPE_GAP" "$PATHS_SCOPE_GAP"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "does NOT cover the requirer" && \
   echo "$out" | grep -qE "requirer is consumers: all|matchline"; then
  pass "Case 6: requires: with narrower consumer scope fails closed (all → matchline gap)"
else
  fail "Case 6 unexpected (rc=$rc): $out"
fi

# Case 6b: explicit-list requirer with strict-subset required.
# Both are explicit lists; one consumer is missing from required.
MANIFEST_NAMED_GAP="$MULTI_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers:
      - matchline
      - swipewatch
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
"
PATHS_NAMED_GAP="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_NAMED_GAP" "$PATHS_NAMED_GAP"); rc=$?
set -e
if [ "$rc" = "1" ] && \
   echo "$out" | grep -q "does NOT cover" && \
   echo "$out" | grep -q "swipewatch"; then
  pass "Case 6b: named-consumer-list requires: gap fails closed and names the missing consumer (swipewatch)"
else
  fail "Case 6b unexpected (rc=$rc): $out"
fi

# Case 7: same shape but required's consumers covers requirer's.
# Should PASS.
MANIFEST_SCOPE_OK="$MULTI_HEADER
  - path: scripts/foo.sh
    type: canonical
    consumers:
      - matchline
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers:
      - matchline
      - swipewatch
"
PATHS_SCOPE_OK="scripts/foo.sh
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_SCOPE_OK" "$PATHS_SCOPE_OK"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 7: requires: covered by superset consumer scope passes"
else
  fail "Case 7 unexpected (rc=$rc): $out"
fi

# Case 8: consumers: all → all (trivial universal coverage).
MANIFEST_ALL_ALL="$MIN_HEADER
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - \"tests/test_foo.sh\"
  - path: tests/test_foo.sh
    type: canonical
    consumers: all
"
PATHS_ALL_ALL="scripts/ci/
tests/test_foo.sh"
set +e
out=$(run_with_fixture "$MANIFEST_ALL_ALL" "$PATHS_ALL_ALL"); rc=$?
set -e
if [ "$rc" = "0" ] && echo "$out" | grep -q "check_sync_manifest: PASS"; then
  pass "Case 8: consumers: all → all trivially passes"
else
  fail "Case 8 unexpected (rc=$rc): $out"
fi

# NOTE: a "live manifest" smoke case is intentionally absent. The
# live invocation of check_sync_manifest in PR CI already smoke-tests
# the live manifest; invoking it from inside this fixture suite
# recurses through the new "run regression suite" call at the bottom
# of check_sync_manifest. Trust the CI invocation to do the smoke.

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_sync_manifest: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_sync_manifest: PASS ($TOTAL tests)"
exit 0
