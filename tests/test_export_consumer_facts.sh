#!/usr/bin/env bash
# tests/test_export_consumer_facts.sh
#
# Regression-guard for the yq filter inside
# scripts/sync-to-downstream.sh's `export_consumer_facts()`. The
# initial Phase B2 (#316) implementation used a mikefarah/yq-
# incompatible `if (tag == "!!seq") then ... else ... end` form
# that silently emitted nothing — every templated render fell
# through to the "no frameworks" baseline because
# MERGEPATH_FACT_* was never exported. Phase D's swipewatch canary
# fell-positive on the bug because swipewatch happens to declare
# `frameworks: []` (rendered output is the same with or without
# the facts loaded). device-platform-reporting's canary surfaced
# the real failure: its `frameworks: [react]` should activate the
# React block, but rendered to the JS baseline only.
#
# This test runs the EXACT yq filter from export_consumer_facts
# against three fixture consumer profiles (seq fact, scalar fact,
# empty seq fact, no facts at all) and asserts the output shape.
# The lib's yq invocation and this test's yq invocation must stay
# in sync — both carry a "keep in sync with tests/test_export_consumer_facts.sh"
# comment for the next contributor.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"
# The yq filter moved to scripts/lib/manifest-fact-helpers.sh in
# mergepath#323 so both sync-to-downstream.sh and
# scripts/workflow/verify-propagation-pr.sh can load consumer facts
# from a shared helper without duplicating the filter. The regression-
# guard greps the lib file now; we still confirm sync-to-downstream.sh
# sources the lib so the wiring can't silently drift.
LIB="$ROOT/scripts/lib/manifest-fact-helpers.sh"

[[ -r "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 1; }
[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available" >&2; exit 0; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/export-facts-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Fixture manifest with four consumers exercising the value-type matrix.
cat > "$WORKDIR/manifest.yml" <<'EOF'
version: 1
consumers:
  - name: with_seq_multi
    repo: example-org/with-seq-multi
    visibility: public
    facts:
      frameworks: [react, typescript]
      node_version: "20"
  - name: with_seq_single
    repo: example-org/with-seq-single
    visibility: public
    facts:
      frameworks: [astro]
  - name: with_empty_seq
    repo: example-org/with-empty-seq
    visibility: public
    facts:
      frameworks: []
  - name: with_no_facts
    repo: example-org/with-no-facts
    visibility: public
paths: []
EOF

# Run the yq filter that mirrors export_consumer_facts's filter.
# KEEP IN SYNC with scripts/sync-to-downstream.sh's export_consumer_facts.
run_filter() {
  local consumer_name=$1
  MERGEPATH_CONSUMER_NAME="$consumer_name" yq -r '
    env(MERGEPATH_CONSUMER_NAME) as $cn
    | .consumers[] | select(.name == $cn) | .facts // {} | to_entries[]
    | .key + "\t"
      + ((.value | select(tag == "!!seq") | join(" "))
         // (.value | tostring))
  ' "$WORKDIR/manifest.yml"
}

# Case 1: list-valued fact serializes as space-separated.
out=$(run_filter with_seq_multi)
expected="$(printf 'frameworks\treact typescript\nnode_version\t20')"
if [ "$out" = "$expected" ]; then
  pass "Case 1: list + scalar facts extract correctly (multi-element seq)"
else
  fail "Case 1: expected:\n$expected\ngot:\n$out"
fi

# Case 2: single-element list serializes to a single word.
out=$(run_filter with_seq_single)
expected="$(printf 'frameworks\tastro')"
if [ "$out" = "$expected" ]; then
  pass "Case 2: single-element list serializes to one word"
else
  fail "Case 2: expected:\n$expected\ngot:\n$out"
fi

# Case 3: empty list — join("") yields empty string; key still present.
# This was the case that masked the original bug; both broken-yq and
# correct-yq produced the same empty-string output for swipewatch's
# `frameworks: []`. Regression test pins the CORRECT behavior so a
# future broken-syntax change is caught.
out=$(run_filter with_empty_seq)
expected="$(printf 'frameworks\t')"
if [ "$out" = "$expected" ]; then
  pass "Case 3: empty-list fact yields key with empty value (masked the original bug)"
else
  fail "Case 3: expected:\n[$expected]\ngot:\n[$out]"
fi

# Case 4: consumer with no facts block at all — filter yields nothing.
out=$(run_filter with_no_facts)
if [ -z "$out" ]; then
  pass "Case 4: consumer without facts block yields no output"
else
  fail "Case 4: expected empty output, got:\n$out"
fi

# Case 5: the lib MUST contain the documented select-fallback idiom.
# If a future contributor reverts to the `if then else end` form
# (which mikefarah/yq rejects), this assertion catches it before the
# broken syntax ships. The filter moved to manifest-fact-helpers.sh
# in #323; grep the lib, not the sync script.
if grep -q 'select(tag == "!!seq") | join(" ")' "$LIB"; then
  pass "Case 5: lib helper uses the select+// idiom (not the broken if/then/else form)"
else
  fail "Case 5: scripts/lib/manifest-fact-helpers.sh no longer uses the select+// idiom — this regression-guard expects 'select(tag == \"!!seq\") | join(\" \")' in the helper"
fi

# Case 6: explicit no-regression check — the lib must NOT contain
# the broken form `if (tag == "!!seq") then`. This is the literal
# substring that caused the bug.
if ! grep -qF 'if (tag == "!!seq") then' "$LIB"; then
  pass "Case 6: lib helper does not contain the broken yq if/then/else form"
else
  fail "Case 6: lib helper contains the broken 'if (tag == \"!!seq\") then ... else ... end' form — mikefarah/yq rejects this at the lexer"
fi

# Case 7 (#323): sync-to-downstream.sh MUST source the lib so the
# wiring is not silently lost in a future refactor. A missing source
# would re-introduce the duplication this extraction was meant to
# eliminate.
if grep -q 'source "$MERGEPATH_ROOT/scripts/lib/manifest-fact-helpers.sh"' "$SCRIPT"; then
  pass "Case 7: sync-to-downstream.sh sources the manifest-fact-helpers lib"
else
  fail "Case 7: sync-to-downstream.sh no longer sources scripts/lib/manifest-fact-helpers.sh — wiring lost"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_export_consumer_facts: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_export_consumer_facts: PASS ($TOTAL tests)"
exit 0
