#!/usr/bin/env bash
# tests/test_template_substitution.sh
#
# Unit tests for scripts/lib/template-substitution.sh. Covers v1 syntax:
# variable substitution, conditional blocks across the four expression
# forms, comment-prefix flexibility, error paths (unclosed/nested/
# unexpected markers, malformed expressions), strict-mode fact-miss,
# atomic render_to.
#
# Bash 3.2 portable. Runs without network. Invoked by
# scripts/ci/check_template_substitution (which the lib's introduction
# PR also wires up).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/template-substitution.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/template-sub-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Reset all MERGEPATH_FACT_* env vars before each test so prior cases
# can't bleed in.
reset_facts() {
  local var
  for var in $(env | awk -F= '/^MERGEPATH_FACT_/ {print $1}'); do
    unset "$var"
  done
  unset MERGEPATH_TEMPLATE_STRICT
}

# Source the lib in a subshell so test failures don't poison later
# tests. Each render_case is its own subshell.
render_case() {
  # $1: template content (heredoc-friendly), $2..: KEY=VALUE env exports
  local template_content=$1
  shift
  local src="$WORKDIR/src.$$.tpl"
  local out="$WORKDIR/out.$$.txt"
  local err="$WORKDIR/err.$$.txt"
  printf '%s' "$template_content" > "$src"
  (
    reset_facts
    for kv in "$@"; do
      export "$kv"
    done
    # shellcheck disable=SC1090
    source "$LIB"
    local render_rc=0
    template_substitution::render "$src" > "$out" 2> "$err" || render_rc=$?
    echo "$render_rc" > "$WORKDIR/rc.$$.txt"
  )
  local rc
  rc=$(cat "$WORKDIR/rc.$$.txt")
  rm -f "$src" "$WORKDIR/rc.$$.txt"
  # Echo: <rc>\t<stdout-file>\t<stderr-file>
  printf '%s\t%s\t%s\n' "$rc" "$out" "$err"
}

# Helper: assert rendered output matches expected.
expect_output() {
  local label=$1 result=$2 expected=$3
  local rc out_file err_file
  rc=$(printf '%s' "$result" | cut -f1)
  out_file=$(printf '%s' "$result" | cut -f2)
  err_file=$(printf '%s' "$result" | cut -f3)
  if [ "$rc" != "0" ]; then
    fail "$label: expected rc=0, got rc=$rc; stderr:"
    sed 's/^/    /' "$err_file" >&2
    return
  fi
  local actual
  actual=$(cat "$out_file")
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: output mismatch"
    echo "  expected:" >&2
    printf '%s\n' "$expected" | sed 's/^/    /' >&2
    echo "  actual:" >&2
    printf '%s\n' "$actual" | sed 's/^/    /' >&2
  fi
}

expect_rc() {
  local label=$1 result=$2 want_rc=$3
  local rc err_file
  rc=$(printf '%s' "$result" | cut -f1)
  err_file=$(printf '%s' "$result" | cut -f3)
  if [ "$rc" = "$want_rc" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label: expected rc=$want_rc, got rc=$rc; stderr:"
    sed 's/^/    /' "$err_file" >&2
  fi
}

# ---------------------------------------------------------------------------
# 1. Variable substitution
# ---------------------------------------------------------------------------

r=$(render_case "hello {{name}}!
" "MERGEPATH_FACT_NAME=world")
expect_output "1a {{key}} basic substitution" "$r" "hello world!"

r=$(render_case "{{a}}-{{b}}-{{a}}
" "MERGEPATH_FACT_A=foo" "MERGEPATH_FACT_B=bar")
expect_output "1b multiple substitutions per line, repeats" "$r" "foo-bar-foo"

r=$(render_case "plain line, no markers
")
expect_output "1c no markers passes through" "$r" "plain line, no markers"

r=$(render_case "missing: <{{nope}}>
")
expect_output "1d lenient mode: missing fact = empty" "$r" "missing: <>"

r=$(render_case "missing: <{{nope}}>
" "MERGEPATH_TEMPLATE_STRICT=1")
expect_rc "1e strict mode: missing fact = rc 3" "$r" 3

r=$(render_case "unclosed: {{key
")
expect_output "1f unclosed {{ left verbatim" "$r" "unclosed: {{key"

r=$(render_case "hyphen key: {{node-version}}
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "1g hyphenated fact key → underscored env var" "$r" "hyphen key: 20"

# ---------------------------------------------------------------------------
# 2. Bare conditional: >>> if <key>
# ---------------------------------------------------------------------------

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_FACT_HAS_TS=1")
expect_output "2a bare conditional, truthy fact" "$r" "before
typescript line
after"

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
")
expect_output "2b bare conditional, unset fact (lenient)" "$r" "before
after"

r=$(render_case "before
// >>> if has_ts
typescript line
// <<<
after
" "MERGEPATH_FACT_HAS_TS=")
expect_output "2c bare conditional, empty fact = falsy" "$r" "before
after"

# ---------------------------------------------------------------------------
# 3. Negation: >>> if !<key>
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if !has_ts
no typescript
// <<<
")
expect_output "3a negation, unset fact = true" "$r" "no typescript"

r=$(render_case "// >>> if !has_ts
no typescript
// <<<
" "MERGEPATH_FACT_HAS_TS=1")
expect_output "3b negation, set fact = false" "$r" ""

# ---------------------------------------------------------------------------
# 4. List membership: >>> if <key> contains <value>
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if frameworks contains react
react block
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react typescript")
expect_output "4a contains, present" "$r" "react block"

r=$(render_case "// >>> if frameworks contains vue
vue block
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react typescript")
expect_output "4b contains, absent" "$r" ""

# Word-boundary safety: "react" must NOT match "react-native".
r=$(render_case "// >>> if frameworks contains react
matched react
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react-native")
expect_output "4c contains, word-boundary (react ≠ react-native)" "$r" ""

r=$(render_case "// >>> if frameworks contains react-native
matched native
// <<<
" "MERGEPATH_FACT_FRAMEWORKS=react-native react")
expect_output "4d contains, hyphenated value matches" "$r" "matched native"

# ---------------------------------------------------------------------------
# 5. Equality / inequality
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if node_version == 20
node 20
// <<<
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "5a equality, match" "$r" "node 20"

r=$(render_case "// >>> if node_version == 20
node 20
// <<<
" "MERGEPATH_FACT_NODE_VERSION=18")
expect_output "5b equality, no match" "$r" ""

r=$(render_case "// >>> if node_version != 18
modern node
// <<<
" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "5c inequality, match" "$r" "modern node"

r=$(render_case "// >>> if node_version != 18
modern node
// <<<
" "MERGEPATH_FACT_NODE_VERSION=18")
expect_output "5d inequality, no match" "$r" ""

# ---------------------------------------------------------------------------
# 6. Comment-prefix flexibility (each comment style must be recognized)
# ---------------------------------------------------------------------------

for prefix_label_pair in \
    "// js-line" \
    "# shell-yaml" \
    "-- sql-lua" \
    "<!-- html-open"; do
  prefix=${prefix_label_pair% *}
  label=${prefix_label_pair#* }
  # html close needs trailing -->; handle separately for marker close
  if [ "$label" = "html-open" ]; then
    template=$(printf '%s >>> if frameworks contains react\nreact-only\n%s <<< -->\n' "$prefix" "$prefix")
  else
    template=$(printf '%s >>> if frameworks contains react\nreact-only\n%s <<<\n' "$prefix" "$prefix")
  fi
  r=$(render_case "$template" "MERGEPATH_FACT_FRAMEWORKS=react")
  expect_output "6 prefix '$prefix' ($label) — block kept" "$r" "react-only"
done

# Mixed leading whitespace on marker.
r=$(render_case "    // >>> if frameworks contains react
react-only
  // <<<
" "MERGEPATH_FACT_FRAMEWORKS=react")
expect_output "6e leading whitespace on markers" "$r" "react-only"

# ---------------------------------------------------------------------------
# 7. Variable substitution INSIDE a kept block (and skipped block)
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if has_ts
ts version {{node_version}}
// <<<
" "MERGEPATH_FACT_HAS_TS=1" "MERGEPATH_FACT_NODE_VERSION=20")
expect_output "7a {{vars}} substituted inside kept block" "$r" "ts version 20"

r=$(render_case "// >>> if has_ts
ts version {{node_version}}
// <<<
")
expect_output "7b {{vars}} inside skipped block are not substituted" "$r" ""

# ---------------------------------------------------------------------------
# 8. Malformed templates → rc 1
# ---------------------------------------------------------------------------

r=$(render_case "// >>> if has_ts
unclosed body
")
expect_rc "8a unclosed if marker -> rc 1" "$r" 1

r=$(render_case "before
// <<<
after
")
expect_rc "8b unexpected close marker -> rc 1" "$r" 1

r=$(render_case "// >>> if outer
outer body
// >>> if inner
nested body
// <<<
// <<<
")
expect_rc "8c nested if -> rc 1 (v1 doesnt support nesting)" "$r" 1

r=$(render_case "// >>> if foo bar baz quux
body
// <<<
")
expect_rc "8d unknown expression form → rc 1" "$r" 1

# ---------------------------------------------------------------------------
# 9. eval_expr direct (drives the expression evaluator in isolation)
# ---------------------------------------------------------------------------

(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="react typescript"
  export MERGEPATH_FACT_HAS_TS=1
  # shellcheck disable=SC1090
  source "$LIB"
  set +e
  template_substitution::eval_expr "has_ts"; r1=$?
  template_substitution::eval_expr "!has_ts"; r2=$?
  template_substitution::eval_expr "frameworks contains react"; r3=$?
  template_substitution::eval_expr "frameworks contains vue"; r4=$?
  template_substitution::eval_expr "node_version == 20"; r5=$?
  template_substitution::eval_expr ""; r6=$?
  set -e
  if [ "$r1" = "0" ] && [ "$r2" = "1" ] && [ "$r3" = "0" ] && \
     [ "$r4" = "1" ] && [ "$r5" = "1" ] && [ "$r6" = "2" ]; then
    echo "PASS: 9 eval_expr direct (truthy/falsy/match/miss/empty)"
  else
    echo "FAIL: 9 eval_expr direct: got $r1/$r2/$r3/$r4/$r5/$r6 (expected 0/1/0/1/1/2)" >&2
    exit 1
  fi
) && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ---------------------------------------------------------------------------
# 10. render_to atomic write
# ---------------------------------------------------------------------------

src="$WORKDIR/atomic-src.tpl"
dest="$WORKDIR/atomic-dest.txt"
cat > "$src" <<'EOF'
rendered: {{key}}
EOF
(
  reset_facts
  export MERGEPATH_FACT_KEY=value
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render_to "$src" "$dest"
)
if [ -f "$dest" ] && [ "$(cat "$dest")" = "rendered: value" ]; then
  pass "10a render_to writes destination file"
else
  fail "10a render_to: expected 'rendered: value', got: $(cat "$dest" 2>/dev/null || echo MISSING)"
fi

# render_to failure: malformed template → no partial write of dest.
src="$WORKDIR/atomic-bad.tpl"
dest="$WORKDIR/atomic-bad-dest.txt"
echo "// >>> if has_ts" > "$src"
echo "body" >> "$src"
# (no <<<)
(
  reset_facts
  # shellcheck disable=SC1090
  source "$LIB"
  exit_rc=0
  template_substitution::render_to "$src" "$dest" || exit_rc=$?
  echo "$exit_rc" > "$WORKDIR/atomic-rc.txt"
)
exit_rc=$(cat "$WORKDIR/atomic-rc.txt")
if [ "$exit_rc" = "1" ] && [ ! -f "$dest" ]; then
  pass "10b render_to atomic: malformed template leaves no partial dest"
else
  fail "10b render_to: expected rc=1 + no dest, got rc=$exit_rc, dest exists: $([ -f "$dest" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 11. End-to-end: ESLint-config-shaped template (the forcing function)
# ---------------------------------------------------------------------------

src="$WORKDIR/eslint.config.js.tpl"
cat > "$src" <<'EOF'
import js from "@eslint/js";
import globals from "globals";

// >>> if frameworks contains typescript
import tseslint from "typescript-eslint";
// <<<
// >>> if frameworks contains astro
import astro from "eslint-plugin-astro";
// <<<
// >>> if frameworks contains react
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
// <<<

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
// >>> if frameworks contains typescript
  ...tseslint.configs.recommended,
// <<<
// >>> if frameworks contains astro
  ...astro.configs.recommended,
// <<<
// >>> if frameworks contains react
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: { react, "react-hooks": reactHooks },
    rules: {
      ...react.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
    },
  },
// <<<
];
EOF

# Case 11a: swipewatch profile (JS-only, no frameworks)
expected_swipewatch='import js from "@eslint/js";
import globals from "globals";


export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS=""
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/swipewatch.out"
)
if [ "$(cat "$WORKDIR/swipewatch.out")" = "$expected_swipewatch" ]; then
  pass "11a ESLint template, swipewatch profile (JS-only)"
else
  fail "11a swipewatch profile mismatch:"
  diff <(printf '%s\n' "$expected_swipewatch") "$WORKDIR/swipewatch.out" | sed 's/^/    /' >&2
fi

# Case 11b: matchline profile (TS + React)
expected_matchline='import js from "@eslint/js";
import globals from "globals";

import tseslint from "typescript-eslint";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: { react, "react-hooks": reactHooks },
    rules: {
      ...react.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
    },
  },
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="react typescript"
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/matchline.out"
)
if [ "$(cat "$WORKDIR/matchline.out")" = "$expected_matchline" ]; then
  pass "11b ESLint template, matchline profile (TS+React)"
else
  fail "11b matchline profile mismatch:"
  diff <(printf '%s\n' "$expected_matchline") "$WORKDIR/matchline.out" | sed 's/^/    /' >&2
fi

# Case 11c: nathanpaynedotcom profile (TS + Astro)
expected_npc='import js from "@eslint/js";
import globals from "globals";

import tseslint from "typescript-eslint";
import astro from "eslint-plugin-astro";

export default [
  { ignores: ["node_modules/**", "dist/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...astro.configs.recommended,
];'
(
  reset_facts
  export MERGEPATH_FACT_FRAMEWORKS="astro typescript"
  # shellcheck disable=SC1090
  source "$LIB"
  template_substitution::render "$src" > "$WORKDIR/npc.out"
)
if [ "$(cat "$WORKDIR/npc.out")" = "$expected_npc" ]; then
  pass "11c ESLint template, nathanpaynedotcom profile (TS+Astro)"
else
  fail "11c nathanpaynedotcom profile mismatch:"
  diff <(printf '%s\n' "$expected_npc") "$WORKDIR/npc.out" | sed 's/^/    /' >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "PASS: $PASS   FAIL: $FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ]
