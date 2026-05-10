#!/usr/bin/env bash
# tests/test_sync_overrides.sh
#
# Unit tests for scripts/sync/validate-overrides.sh and
# scripts/sync/apply-overrides.sh. Builds a synthetic manifest +
# overrides files in a tempdir, exercises each rule + helper.
#
# Requires: yq (mikefarah/yq v4+), bash 4+. Run manually or from
# scripts/ci/check_sync_overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/sync/validate-overrides.sh"
APPLY_LIB="$ROOT/scripts/sync/apply-overrides.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$VALIDATOR" ]] || { echo "missing or non-executable $VALIDATOR" >&2; exit 1; }
[[ -f "$APPLY_LIB" ]] || { echo "missing $APPLY_LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d -t sync-overrides-test)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

# ---------------------------------------------------------------------------
# Synthetic manifest with two canonical paths, one kit, and one templated
# path with two substitution markers (the templated entry exercises the
# substitutions validation; v1 manifest doesn't yet declare templated
# paths but the validator must support them when they land).
# ---------------------------------------------------------------------------
MANIFEST="$WORKDIR/.mergepath-sync.yml"
cat >"$MANIFEST" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
paths:
  - {path: scripts/keep-in-sync.sh,    type: canonical, consumers: all}
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
  - path: AGENTS.md
    type: templated
    consumers: all
    substitutions:
      phase_4b_default: complex-changes
      author_identity: nathanjohnpayne
YAML

# ---------------------------------------------------------------------------
# Test 1: absent overrides file → pass (the "no divergences" common case).
# ---------------------------------------------------------------------------
absent_dir="$WORKDIR/absent"
mkdir -p "$absent_dir"
cd "$absent_dir"
if "$VALIDATOR" "$absent_dir/.sync-overrides.yml" "$MANIFEST" >/dev/null 2>&1; then
  pass "absent overrides file → exits 0"
else
  fail "absent overrides file should pass; validator returned non-zero"
fi
cd "$ROOT"

# ---------------------------------------------------------------------------
# Test 2: well-formed overrides with skip + substitution → pass.
# ---------------------------------------------------------------------------
good="$WORKDIR/good.yml"
cat >"$good" <<'YAML'
version: 1
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: |
      This repo replaced keep-in-sync with a custom variant.
      Tracked in repo#42 for eventual convergence.
substitutions:
  phase_4b_default: fallback-only
YAML
if "$VALIDATOR" "$good" "$MANIFEST" >/dev/null 2>&1; then
  pass "well-formed overrides → exits 0"
else
  out=$("$VALIDATOR" "$good" "$MANIFEST" 2>&1 || true)
  fail "well-formed overrides should pass; got: $out"
fi

# ---------------------------------------------------------------------------
# Test 3: skip_paths entry with empty reason → fail (audit-trail).
# ---------------------------------------------------------------------------
empty_reason="$WORKDIR/empty-reason.yml"
cat >"$empty_reason" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: ""
YAML
if "$VALIDATOR" "$empty_reason" "$MANIFEST" >/dev/null 2>&1; then
  fail "empty reason should fail validation; validator passed"
else
  pass "empty reason → exits non-zero"
fi

# Whitespace-only reason — should also fail.
ws_reason="$WORKDIR/ws-reason.yml"
cat >"$ws_reason" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: "   "
YAML
if "$VALIDATOR" "$ws_reason" "$MANIFEST" >/dev/null 2>&1; then
  fail "whitespace-only reason should fail; validator passed"
else
  pass "whitespace-only reason → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 4: skip_paths references nonexistent manifest path → fail.
# ---------------------------------------------------------------------------
bad_path="$WORKDIR/bad-path.yml"
cat >"$bad_path" <<'YAML'
skip_paths:
  - path: scripts/does-not-exist.sh
    reason: legitimate-looking reason
YAML
if "$VALIDATOR" "$bad_path" "$MANIFEST" >/dev/null 2>&1; then
  fail "nonexistent skip path should fail; validator passed"
else
  pass "nonexistent skip path → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 5: substitution references nonexistent marker → fail.
# ---------------------------------------------------------------------------
bad_sub="$WORKDIR/bad-sub.yml"
cat >"$bad_sub" <<'YAML'
substitutions:
  marker_that_isnt_in_manifest: any-value
YAML
if "$VALIDATOR" "$bad_sub" "$MANIFEST" >/dev/null 2>&1; then
  fail "nonexistent substitution marker should fail; validator passed"
else
  pass "nonexistent substitution marker → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 6: unknown top-level key → fail.
# ---------------------------------------------------------------------------
unknown_key="$WORKDIR/unknown-key.yml"
cat >"$unknown_key" <<'YAML'
skip_paths: []
unknown_field: oops
YAML
if "$VALIDATOR" "$unknown_key" "$MANIFEST" >/dev/null 2>&1; then
  fail "unknown top-level key should fail; validator passed"
else
  pass "unknown top-level key → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 7: malformed YAML → fail.
# ---------------------------------------------------------------------------
malformed="$WORKDIR/malformed.yml"
cat >"$malformed" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
   reason: bad indentation
   extra: -
YAML
if "$VALIDATOR" "$malformed" "$MANIFEST" >/dev/null 2>&1; then
  fail "malformed YAML should fail; validator passed"
else
  pass "malformed YAML → exits non-zero"
fi

# ---------------------------------------------------------------------------
# Test 8: unsupported version → fail.
# ---------------------------------------------------------------------------
bad_version="$WORKDIR/bad-version.yml"
cat >"$bad_version" <<'YAML'
version: 999
skip_paths: []
YAML
if "$VALIDATOR" "$bad_version" "$MANIFEST" >/dev/null 2>&1; then
  fail "unsupported version should fail; validator passed"
else
  pass "unsupported version → exits non-zero"
fi

# ---------------------------------------------------------------------------
# apply-overrides.sh helper tests
# ---------------------------------------------------------------------------
# shellcheck source=../scripts/sync/apply-overrides.sh
. "$APPLY_LIB"

# Test 9: override_should_skip_path on a matching entry returns 0 with
# OVERRIDE_SKIP_REASON populated.
helper_override="$WORKDIR/helper-good.yml"
cat >"$helper_override" <<'YAML'
skip_paths:
  - path: scripts/keep-in-sync.sh
    reason: example skip
YAML
OVERRIDE_SKIP_REASON=""
if override_should_skip_path "$helper_override" "scripts/keep-in-sync.sh" \
   && [ "$OVERRIDE_SKIP_REASON" = "example skip" ]; then
  pass "override_should_skip_path matches and stores reason"
else
  fail "override_should_skip_path failed to match (reason=$OVERRIDE_SKIP_REASON)"
fi

# Test 10: override_should_skip_path on a non-matching path returns
# non-zero and clears OVERRIDE_SKIP_REASON.
OVERRIDE_SKIP_REASON="lingering"
if override_should_skip_path "$helper_override" "scripts/some-other.sh"; then
  fail "override_should_skip_path matched on non-listed path"
else
  if [ -z "$OVERRIDE_SKIP_REASON" ]; then
    pass "override_should_skip_path clears reason on miss"
  else
    fail "override_should_skip_path did not clear OVERRIDE_SKIP_REASON on miss"
  fi
fi

# Test 11: override_substitution_for returns 0 + value when key exists.
sub_override="$WORKDIR/helper-sub.yml"
cat >"$sub_override" <<'YAML'
substitutions:
  phase_4b_default: fallback-only
YAML
val=$(override_substitution_for "$sub_override" "phase_4b_default") \
  && [ "$val" = "fallback-only" ] \
  && pass "override_substitution_for returns override value" \
  || fail "override_substitution_for didn't return expected value (got '$val')"

# Test 12: override_substitution_for returns non-zero when key absent
# (caller falls back to manifest default).
if override_substitution_for "$sub_override" "missing_marker" >/dev/null 2>&1; then
  fail "override_substitution_for returned 0 for missing marker"
else
  pass "override_substitution_for returns non-zero for missing marker"
fi

# Test 13: helpers tolerate absent overrides file (return non-zero,
# don't abort the caller).
if override_should_skip_path "" "scripts/keep-in-sync.sh"; then
  fail "override_should_skip_path matched against empty file path"
else
  pass "override_should_skip_path tolerates empty file path"
fi
if override_substitution_for "/nonexistent/.sync-overrides.yml" "phase_4b_default" >/dev/null 2>&1; then
  fail "override_substitution_for matched against absent file"
else
  pass "override_substitution_for tolerates absent file"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_sync_overrides: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
