#!/usr/bin/env bash
# scripts/lib/template-substitution.sh — render templated propagation
# sources with per-consumer facts.
#
# v1 syntax (intentionally minimal — see docs/agents/templated-
# propagation.md § Why this syntax for the rationale):
#
#   1. Variable substitution. Anywhere in the file:
#        {{key}}                 → ${MERGEPATH_FACT_KEY:-""}
#      Missing fact = empty string in lenient mode (default), hard
#      fail in strict mode (MERGEPATH_TEMPLATE_STRICT=1).
#
#   2. Conditional blocks. Lines matching:
#        >>> if <expr>
#        ...body...
#        <<<
#      The leading comment prefix on the marker line is stripped (the
#      lib accepts any non-alnum run before the `>>>`/`<<<` sigil so
#      `//`, `#`, `--`, `<!-- … -->`, `/* … */` all work). Body lines
#      survive verbatim if <expr> is true; the entire block (markers
#      included) is omitted otherwise.
#
#      <expr> forms accepted in v1:
#        - <key>                  truthy iff env MERGEPATH_FACT_KEY is set
#                                 and non-empty
#        - !<key>                 inverse of the above
#        - <key> contains <value> for space-separated list facts
#        - <key> == <value>       string equality
#        - <key> != <value>       string inequality
#
#      Nesting is NOT supported in v1. Two `>>> if` opens without an
#      intervening `<<<` is a malformed-template error (exit 1). Add
#      nesting later if a real source file needs it.
#
# Facts source: environment variables. Each fact key (lowercase,
# possibly with hyphens) maps to `MERGEPATH_FACT_<KEY>` (uppercase,
# hyphens → underscores). List facts are space-separated. Sync
# integration (scripts/sync-to-downstream.sh) is responsible for
# extracting per-consumer facts from .mergepath-sync.yml and
# exporting them before invoking this lib.
#
# API:
#   template_substitution::render <source_file>
#       Renders to stdout. Exit 0 success, 1 malformed template, 2
#       source-file missing, 3 unknown fact in strict mode.
#
#   template_substitution::render_to <source_file> <dest_file>
#       Atomic write via mktemp + mv. Same exit codes as render.
#
#   template_substitution::eval_expr <expr>
#       Returns 0 if expr is true, 1 if false, 2 if expr is malformed.
#       Exposed so tests can drive it directly.
#
# Bash 3.2 portable (no associative arrays, no ${var^^}). Matches
# scripts/bootstrap/substitute.sh's portability bar.

set -euo pipefail

# Convert a lowercase-with-hyphens fact name to its env var form:
# "frameworks" → "MERGEPATH_FACT_FRAMEWORKS"
# "node-version" → "MERGEPATH_FACT_NODE_VERSION"
template_substitution::_fact_var() {
  local key=$1
  local upper
  upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  printf 'MERGEPATH_FACT_%s' "$upper"
}

# Look up a fact value. Echoes the value (empty string if unset).
# In strict mode, prints a diagnostic to stderr and returns 3 if the
# fact is referenced but unset.
template_substitution::_fact_value() {
  local key=$1
  local var
  var=$(template_substitution::_fact_var "$key")
  # bash 3.2 indirect expansion via eval.
  local value
  eval "value=\${$var-__MERGEPATH_FACT_UNSET__}"
  if [ "$value" = "__MERGEPATH_FACT_UNSET__" ]; then
    if [ "${MERGEPATH_TEMPLATE_STRICT:-0}" = "1" ]; then
      printf 'template: strict mode: fact %s (env %s) is not set\n' \
        "$key" "$var" >&2
      return 3
    fi
    printf ''
    return 0
  fi
  printf '%s' "$value"
}

# Evaluate a conditional expression. Returns 0 (true), 1 (false), or
# 2 (malformed).
template_substitution::eval_expr() {
  local expr=$1
  # Trim leading/trailing whitespace.
  expr=$(printf '%s' "$expr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  case "$expr" in
    "")
      printf 'template: empty conditional expression\n' >&2
      return 2
      ;;
    "!"*)
      local inner=${expr#!}
      inner=$(printf '%s' "$inner" | sed -e 's/^[[:space:]]*//')
      local v
      v=$(template_substitution::_fact_value "$inner") || return 3
      if [ -z "$v" ]; then return 0; else return 1; fi
      ;;
    *" contains "*)
      local key=${expr%% contains *}
      local needle=${expr#* contains }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      needle=$(printf '%s' "$needle" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local haystack
      haystack=$(template_substitution::_fact_value "$key") || return 3
      # Space-padded match so "react" doesn't match "react-native".
      case " $haystack " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *" == "*)
      local key=${expr%% == *}
      local want=${expr#* == }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      want=$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local have
      have=$(template_substitution::_fact_value "$key") || return 3
      if [ "$have" = "$want" ]; then return 0; else return 1; fi
      ;;
    *" != "*)
      local key=${expr%% != *}
      local want=${expr#* != }
      key=$(printf '%s' "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      want=$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      local have
      have=$(template_substitution::_fact_value "$key") || return 3
      if [ "$have" != "$want" ]; then return 0; else return 1; fi
      ;;
    *" "*)
      printf 'template: malformed conditional expression: %s\n' "$expr" >&2
      printf 'template: supported forms: <key>, !<key>, <key> contains <value>, <key> == <value>, <key> != <value>\n' >&2
      return 2
      ;;
    *)
      # Bare key — truthy iff non-empty.
      local v
      v=$(template_substitution::_fact_value "$expr") || return 3
      if [ -n "$v" ]; then return 0; else return 1; fi
      ;;
  esac
}

# Apply {{key}} substitutions to a single line. Echoes the rewritten
# line. In strict mode, an unset fact reference returns 3 (caller
# handles).
template_substitution::_substitute_vars() {
  local line=$1
  # Fast path: no `{{` on the line.
  case "$line" in
    *"{{"*) ;;
    *) printf '%s' "$line"; return 0 ;;
  esac

  # Walk left-to-right, replacing each {{key}} occurrence.
  local out=""
  local remaining=$line
  while :; do
    case "$remaining" in
      *"{{"*)
        local before=${remaining%%\{\{*}
        local rest=${remaining#*\{\{}
        case "$rest" in
          *"}}"*)
            local key=${rest%%\}\}*}
            local after=${rest#*\}\}}
            local value
            value=$(template_substitution::_fact_value "$key") || return 3
            out="$out$before$value"
            remaining=$after
            ;;
          *)
            # Unclosed {{: emit as-is, stop.
            out="$out$remaining"
            remaining=""
            break
            ;;
        esac
        ;;
      *)
        out="$out$remaining"
        remaining=""
        break
        ;;
    esac
  done
  printf '%s' "$out"
}

# Regex helpers — POSIX BREs, anchored, comment-prefix-agnostic.
# Marker line pattern: optional whitespace, optional non-alnum prefix
# (the comment chars), optional whitespace, then the sigil, then space-
# separated payload. We use grep -E with explicit anchors.
template_substitution::_is_if_open() {
  # $1: line. Returns 0 if it's a `>>> if ...` marker, echoing the
  # expression on stdout. Returns 1 otherwise (no output).
  local line=$1
  printf '%s' "$line" | grep -E '^[[:space:]]*[^[:alnum:]{]*[[:space:]]*>>>[[:space:]]+if[[:space:]]+' >/dev/null || return 1
  # Extract the expression after `>>> if `.
  printf '%s' "$line" | sed -E 's/^[[:space:]]*[^[:alnum:]{]*[[:space:]]*>>>[[:space:]]+if[[:space:]]+//' \
    | sed -e 's/[[:space:]]*$//' \
    | sed -E 's,[[:space:]]*(\*/|-->)[[:space:]]*$,,'
  return 0
}

template_substitution::_is_close() {
  # $1: line. Returns 0 if it's a `<<<` marker line, 1 otherwise.
  local line=$1
  printf '%s' "$line" | grep -E '^[[:space:]]*[^[:alnum:]{]*[[:space:]]*<<<[[:space:]]*([^[:alnum:]{]*[[:space:]]*)?$' >/dev/null
}

# Render a template file to stdout. Implements the v1 syntax.
template_substitution::render() {
  local source=$1
  if [ ! -f "$source" ]; then
    printf 'template: source file not found: %s\n' "$source" >&2
    return 2
  fi

  local in_conditional=0      # 0 outside, 1 inside (active), 2 inside (skipped)
  local conditional_lineno=0  # for error diagnostics on unclosed `if`
  local lineno=0
  local line
  # IFS= + -r preserves leading whitespace and backslashes. The trailing
  # `|| [ -n "$line" ]` catches a file without a final newline.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # `<<<` close marker?
    if template_substitution::_is_close "$line"; then
      if [ "$in_conditional" = "0" ]; then
        printf 'template: %s:%d: unexpected `<<<` (no open `>>> if`)\n' \
          "$source" "$lineno" >&2
        return 1
      fi
      in_conditional=0
      continue
    fi

    # `>>> if ...` open marker?
    local expr
    if expr=$(template_substitution::_is_if_open "$line"); then
      if [ "$in_conditional" != "0" ]; then
        printf 'template: %s:%d: nested `>>> if` is not supported in v1 (open at line %d)\n' \
          "$source" "$lineno" "$conditional_lineno" >&2
        return 1
      fi
      conditional_lineno=$lineno
      local rc=0
      template_substitution::eval_expr "$expr" || rc=$?
      case $rc in
        0) in_conditional=1 ;;
        1) in_conditional=2 ;;
        2) return 1 ;;  # malformed expr → malformed template
        3) return 3 ;;  # strict-mode fact-miss
        *) printf 'template: eval_expr returned unexpected rc=%d\n' "$rc" >&2; return 1 ;;
      esac
      continue
    fi

    # Body line.
    if [ "$in_conditional" = "2" ]; then
      # Inside a skipped block — drop the line.
      continue
    fi

    local rendered
    local rc=0
    rendered=$(template_substitution::_substitute_vars "$line") || rc=$?
    if [ "$rc" != "0" ]; then
      return $rc
    fi
    printf '%s\n' "$rendered"
  done < "$source"

  if [ "$in_conditional" != "0" ]; then
    printf 'template: %s: unclosed `>>> if` (opened at line %d)\n' \
      "$source" "$conditional_lineno" >&2
    return 1
  fi
}

# Render to a destination file atomically.
template_substitution::render_to() {
  local source=$1
  local dest=$2
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/template-render.XXXXXX")
  local rc=0
  template_substitution::render "$source" >"$tmp" || rc=$?
  if [ "$rc" != "0" ]; then
    rm -f "$tmp"
    return $rc
  fi
  mv "$tmp" "$dest"
}

# Inline self-check: if invoked directly as a script (not sourced),
# emit a usage hint. Matches the convention used by other lib files
# under scripts/lib/.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cat >&2 <<EOF
$(basename "$0") is a library. Source it from another bash script:

  source "scripts/lib/template-substitution.sh"
  template_substitution::render path/to/source.template

See docs/agents/templated-propagation.md for the syntax reference.
EOF
  exit 2
fi
