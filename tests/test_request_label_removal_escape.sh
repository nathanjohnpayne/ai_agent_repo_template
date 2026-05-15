#!/usr/bin/env bash
# tests/test_request_label_removal_escape.sh
#
# Unit tests for the AppleScript-escape helper in
# scripts/request-label-removal.sh (#287).
#
# The helper escapes a string for embedding inside an AppleScript
# double-quoted literal that is itself wrapped in a shell-double-quoted
# `osascript -e "..."` argument. The previous implementation only
# escaped double quotes, which left backslashes and newlines free to
# corrupt the AppleScript invocation (a backslash-bearing reason
# string would turn the next character into an AppleScript escape; a
# newline would terminate the source line and break parsing).
#
# Escape order is load-bearing:
#   1. Backslashes FIRST  (\  -> \\)   so later substitutions' \
#      sequences aren't re-escaped
#   2. Double quotes      ("  -> \")
#   3. Newlines           (LF -> \n)
#   4. Carriage returns   (CR -> \r)
#   5. Tabs               (TAB -> \t)
#
# We source the script in library mode (MERGEPATH_REQUEST_LABEL_REMOVAL_LIB=1)
# so the helper function is in scope without firing the main flow.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/request-label-removal.sh"

[[ -r "$SCRIPT" ]] || { echo "missing $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Source in library mode. This must run in a subshell-free context so
# the function lands in the current scope, but the library-mode `return`
# in the script only works when this file is itself executed via
# `bash tests/test_request_label_removal_escape.sh` (which we are).
# shellcheck disable=SC1090
MERGEPATH_REQUEST_LABEL_REMOVAL_LIB=1 source "$SCRIPT"

if ! declare -F applescript_escape >/dev/null; then
  echo "FAIL: applescript_escape not defined after sourcing $SCRIPT" >&2
  exit 1
fi

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc"
    printf '  expected: %q\n  actual:   %q\n' "$expected" "$actual" >&2
  fi
}

# ─── Baseline: an empty / plain string is unchanged ─────────────────
assert_eq "empty string" "" "$(applescript_escape "")"
assert_eq "plain ASCII" "hello world" "$(applescript_escape "hello world")"

# ─── Double quote: " -> \" ──────────────────────────────────────────
assert_eq 'double quote → \"' \
  'say \"hi\"' \
  "$(applescript_escape 'say "hi"')"

# ─── Backslash: \ -> \\ ─────────────────────────────────────────────
# Order-matters check: a lone backslash must become exactly two
# backslashes — not four (which would happen if a later substitution
# re-escaped the just-injected backslashes).
assert_eq 'backslash → \\' \
  'a\\b' \
  "$(applescript_escape 'a\b')"

# ─── Backslash + quote (combined) ───────────────────────────────────
# Input:    a\"b      (raw: backslash, double quote, b)
# Step 1:   a\\"b     (escape backslash)
# Step 2:   a\\\"b    (escape double quote)
# Expected: a\\\"b
assert_eq 'backslash THEN quote → \\\"' \
  'a\\\"b' \
  "$(applescript_escape 'a\"b')"

# ─── Newline: LF -> \n ──────────────────────────────────────────────
# The input contains a raw newline; the output should contain the
# two-character escape sequence `\n` (backslash, n), NOT a literal
# newline.
NL_INPUT=$'line1\nline2'
assert_eq 'newline → \n' \
  'line1\nline2' \
  "$(applescript_escape "$NL_INPUT")"

# ─── Carriage return: CR -> \r ──────────────────────────────────────
CR_INPUT=$'a\rb'
assert_eq 'carriage return → \r' \
  'a\rb' \
  "$(applescript_escape "$CR_INPUT")"

# ─── Tab: TAB -> \t ─────────────────────────────────────────────────
TAB_INPUT=$'col1\tcol2'
assert_eq 'tab → \t' \
  'col1\tcol2' \
  "$(applescript_escape "$TAB_INPUT")"

# ─── The headline mixed case from the issue ─────────────────────────
# A reason string containing backslashes, double quotes, AND newlines
# — the exact failure mode the harden was meant to close.
#
# Input:  Path C:\Users\foo failed: said "no" \nthen quit
# (literal raw string: backslashes, embedded double quotes, AND a
# literal newline character).
#
# Step-by-step:
#   raw:      'Path C:\Users\foo failed: said "no"' + LF + 'then quit'
#   step 1 (\ → \\):
#             'Path C:\\Users\\foo failed: said "no"' + LF + 'then quit'
#   step 2 (" → \"):
#             'Path C:\\Users\\foo failed: said \"no\"' + LF + 'then quit'
#   step 3 (LF → \n):
#             'Path C:\\Users\\foo failed: said \"no\"\nthen quit'
MIXED_INPUT=$'Path C:\\Users\\foo failed: said "no"\nthen quit'
MIXED_EXPECTED='Path C:\\Users\\foo failed: said \"no\"\nthen quit'
assert_eq 'mixed: backslash + quote + newline (the headline case)' \
  "$MIXED_EXPECTED" \
  "$(applescript_escape "$MIXED_INPUT")"

# ─── Regression: escape ordering ────────────────────────────────────
# If the implementation escaped quotes BEFORE backslashes, then for
# input `"\` (quote, backslash):
#   wrong order:  step 1 (" → \"):  `\"\`
#                 step 2 (\ → \\):  `\\\"\\`  ← four chars including double-escape
# The correct ordering yields `\"\\` (3 chars: backslash-quote,
# backslash-backslash). Pin this exact output to catch any future
# reordering.
assert_eq 'order: input "\\ → \\"\\\\ (backslash escaped after quote)' \
  '\"\\' \
  "$(applescript_escape '"\')"

# ─── No-op safety: a string with only safe characters ───────────────
assert_eq 'safe chars unchanged: phone-number target' \
  "+15551234567" \
  "$(applescript_escape "+15551234567")"

echo
echo "Total: $((PASS + FAIL)) — PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
