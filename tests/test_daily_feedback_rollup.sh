#!/usr/bin/env bash
# tests/test_daily_feedback_rollup.sh
#
# Unit tests for scripts/lib/daily-feedback-rollup-helpers.sh — the
# pure-function helpers that drive classification + routing in
# scripts/daily-feedback-rollup.sh (mergepath#299).
#
# The end-to-end integration (gh shim → script → issue creation) is
# not in scope here; this test layer asserts only the deterministic
# helper functions so the spec's per-case classification matrix is
# regression-safe. Integration coverage lives in
# scripts/ci/check_daily_feedback_rollup, which runs an actual
# `--dry-run` invocation against a shimmed gh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT/scripts/lib/daily-feedback-rollup-helpers.sh"

[ -f "$HELPERS" ] || { echo "missing $HELPERS" >&2; exit 1; }

# shellcheck disable=SC1090
. "$HELPERS"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------
# classify_severity — per-case routing from spec § Two-track rollup
# ---------------------------------------------------------------------

assert_severity() {
  local body="$1" expected="$2" label="$3"
  local got
  got=$(classify_severity "$body")
  if [ "$got" = "$expected" ]; then
    pass "classify_severity: $label → $expected"
  else
    fail "classify_severity: $label → expected=$expected got=$got"
  fi
}

# Codex badges
assert_severity '**![P0 Badge]** Some critical finding' "P0"     "Codex P0 inline"
assert_severity '**![P1 Badge]** Some major finding'    "P1"     "Codex P1 inline"
assert_severity '**![P2 Badge]** Some non-blocking'     "P2"     "Codex P2 inline"
assert_severity '**![P3 Badge]** Nit / polish item'     "P3"     "Codex P3 inline"

# CodeRabbit badges
assert_severity '_⚠️ Potential issue_ | _🟠 Major_'      "Major"  "CodeRabbit Major"
assert_severity '_🟠 Major_ | _Potential issue_'         "Major"  "CodeRabbit Major (alt order)"
assert_severity 'Just a ⚠️ thing — Potential issue'      "Major"  "CodeRabbit ⚠️ alone"
assert_severity '_🧹 Nitpick (assertive)_'               "Nitpick" "CodeRabbit Nitpick"
assert_severity '_🔵 Trivial issue_ | _Minor_'           "Trivial" "CodeRabbit Trivial wins over Minor"
assert_severity 'Outside diff range comment'             "Trivial" "Outside diff range → Trivial"

# Unknown bodies surface as Unknown (the caller routes to substantive)
assert_severity 'Some opaque finding without a badge'    "Unknown" "no badge → Unknown"
assert_severity ''                                        "Unknown" "empty body → Unknown"

# Severity-anchor: a severity word DEEP in body (past the 600-char
# anchor) must NOT match. Build a body with 700 chars of padding then
# the word "Major" at the end — should still classify as Unknown.
padding=$(printf '%.0sX' $(seq 1 700))
assert_severity "${padding} Major"                       "Unknown" "anchored: Major past char 600 ignored"

# ---------------------------------------------------------------------
# severity_to_track — spec § Two-track rollup routing table
# ---------------------------------------------------------------------

assert_track() {
  local sev="$1" expected="$2"
  local got
  got=$(severity_to_track "$sev")
  if [ "$got" = "$expected" ]; then
    pass "severity_to_track: $sev → $expected"
  else
    fail "severity_to_track: $sev → expected=$expected got=$got"
  fi
}

assert_track "P0"      "substantive"
assert_track "P1"      "substantive"
assert_track "P2"      "substantive"
assert_track "P3"      "polish"
assert_track "Major"   "substantive"
assert_track "Minor"   "substantive"
assert_track "Nitpick" "polish"
assert_track "Trivial" "polish"
assert_track "Unknown" "substantive"
assert_track ""        "substantive"

# ---------------------------------------------------------------------
# item_id_for — stable + 12 chars + deterministic
# ---------------------------------------------------------------------

id1=$(item_id_for "owner/repo#123:PRT_kwAB")
id2=$(item_id_for "owner/repo#123:PRT_kwAB")
id3=$(item_id_for "owner/repo#124:PRT_kwAB")

if [ ${#id1} -eq 12 ]; then
  pass "item_id_for: produces 12-char ID"
else
  fail "item_id_for: expected 12 chars, got ${#id1} ($id1)"
fi

if [ "$id1" = "$id2" ]; then
  pass "item_id_for: same input → same ID (idempotent)"
else
  fail "item_id_for: same input gave different IDs ($id1 vs $id2)"
fi

if [ "$id1" != "$id3" ]; then
  pass "item_id_for: different inputs → different IDs"
else
  fail "item_id_for: different inputs collided ($id1 == $id3)"
fi

# ---------------------------------------------------------------------
# extract_tag_class — canonical regex + tolerant whitespace
# ---------------------------------------------------------------------

assert_tag() {
  local body="$1" expected="$2" label="$3"
  local got
  got=$(extract_tag_class "$body")
  if [ "$got" = "$expected" ]; then
    pass "extract_tag_class: $label"
  else
    fail "extract_tag_class: $label → expected=[$expected] got=[$got]"
  fi
}

assert_tag '[mergepath-resolve: deferred-to-followup] noted'   "deferred-to-followup" "canonical form"
assert_tag '[mergepath-resolve:canonical-coverage] addressed'  "canonical-coverage"   "no space after colon"
assert_tag '[mergepath-resolve:  addressed-elsewhere ] x'      "addressed-elsewhere"  "extra leading space"
assert_tag 'no tag here'                                        ""                     "no tag → empty"
assert_tag '[mergepath-resolve: deferred-to-followup] first
also has [mergepath-resolve: rebuttal-recorded]'                "deferred-to-followup" "first tag wins"
assert_tag '[mergepath-resolve: deferred-to-followup-EXTRA]'   ""                     "malformed (uppercase) → no match"

# ---------------------------------------------------------------------
# tag_class_action — the surface/skip routing matrix from spec
# ---------------------------------------------------------------------

assert_action() {
  local class="$1" expected="$2"
  local got
  got=$(tag_class_action "$class")
  if [ "$got" = "$expected" ]; then
    pass "tag_class_action: $class → $expected"
  else
    fail "tag_class_action: $class → expected=$expected got=$got"
  fi
}

assert_action "addressed-elsewhere"   "skip"
assert_action "canonical-coverage"    "skip"
assert_action "rebuttal-recorded"     "skip"
assert_action "nitpick-noted"         "surface"
assert_action "deferred-to-followup"  "surface"
assert_action "future-unknown-class"  "surface"   # spec: err on surface
assert_action ""                       ""          # caller falls through to heuristics

# ---------------------------------------------------------------------
# is_agent_author — colon-list membership, Bash 3.2 safe
# ---------------------------------------------------------------------

# Default AGENT_AUTHORS from the helper file.
if is_agent_author "nathanjohnpayne"; then
  pass "is_agent_author: nathanjohnpayne is agent"
else
  fail "is_agent_author: nathanjohnpayne should be agent"
fi

if is_agent_author "nathanpayne-claude"; then
  pass "is_agent_author: nathanpayne-claude is agent"
else
  fail "is_agent_author: nathanpayne-claude should be agent"
fi

if ! is_agent_author "coderabbitai[bot]"; then
  pass "is_agent_author: coderabbitai[bot] is not agent"
else
  fail "is_agent_author: coderabbitai[bot] should NOT be agent"
fi

if ! is_agent_author "random-external-user"; then
  pass "is_agent_author: random-external-user is not agent"
else
  fail "is_agent_author: random-external-user should NOT be agent"
fi

# Override AGENT_AUTHORS at runtime works (tests Bash 3.2-safe parsing)
(
  AGENT_AUTHORS="aliceagent:bobagent"
  # Re-source NOT needed because is_agent_author reads $AGENT_AUTHORS at
  # call time, not module load.
  if is_agent_author "aliceagent" && ! is_agent_author "nathanpayne-claude"; then
    pass "is_agent_author: AGENT_AUTHORS override applied at call time"
  else
    fail "is_agent_author: AGENT_AUTHORS override did not apply"
  fi
)

# ---------------------------------------------------------------------
# body_excerpt — single-line, length-capped
# ---------------------------------------------------------------------

# Newlines/tabs collapsed to spaces.
got=$(body_excerpt $'line1\nline2\tx')
expected="line1 line2 x"
if [ "$got" = "$expected" ]; then
  pass "body_excerpt: collapses newlines/tabs to spaces"
else
  fail "body_excerpt: expected=[$expected] got=[$got]"
fi

# Capped at default 200 chars.
long=$(printf '%.0sA' $(seq 1 500))
got=$(body_excerpt "$long")
if [ ${#got} -eq 200 ]; then
  pass "body_excerpt: default cap is 200 chars"
else
  fail "body_excerpt: expected 200 chars, got ${#got}"
fi

# Custom cap honored.
got=$(body_excerpt "$long" 50)
if [ ${#got} -eq 50 ]; then
  pass "body_excerpt: custom cap honored"
else
  fail "body_excerpt: expected 50 chars, got ${#got}"
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------

echo
if [ "$FAIL" -gt 0 ]; then
  echo "test_daily_feedback_rollup: $FAIL FAIL / $PASS PASS" >&2
  exit 1
fi
echo "test_daily_feedback_rollup: PASS ($PASS tests)"
