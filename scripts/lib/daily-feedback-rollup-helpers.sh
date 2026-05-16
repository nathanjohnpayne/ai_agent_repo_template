# scripts/lib/daily-feedback-rollup-helpers.sh
#
# Pure helper functions for daily-feedback-rollup.sh, split out so the
# unit tests in tests/test_daily_feedback_rollup.sh can source them
# directly without running the script's main body (which assumes
# GH_TOKEN + a live gh shim). Each function takes simple string args
# and produces stdout — no GitHub I/O, no temp files.
#
# To use:
#   source scripts/lib/daily-feedback-rollup-helpers.sh
#
# AGENT_AUTHORS is the only piece of state the helpers need at module
# load. Set it before sourcing or accept the canonical default.

: "${AGENT_AUTHORS:=nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"

# classify_severity <comment-body> → P0|P1|P2|P3|Major|Minor|Nitpick|Trivial|Unknown
#
# Anchored on the first ~600 chars of body — enough to catch the
# CodeRabbit/Codex severity badge near the top, not enough to false-
# match severity words deeper in quoted context. Order matters: pick
# the highest-confidence match first.
#
# CodeRabbit canonical badges: `🟠 Major` / `Potential issue` / `⚠️` /
#                              `🧹 Nitpick` / `🔵 Trivial`
# Codex canonical badges:      `![P0 Badge]` … `![P3 Badge]`
classify_severity() {
  local body_head
  body_head=$(printf '%s' "$1" | head -c 600)
  case "$body_head" in
    *"![P0 Badge]"*|*"P0 Badge"*) echo "P0"; return ;;
    *"![P1 Badge]"*|*"P1 Badge"*) echo "P1"; return ;;
    *"![P2 Badge]"*|*"P2 Badge"*) echo "P2"; return ;;
    *"![P3 Badge]"*|*"P3 Badge"*) echo "P3"; return ;;
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*) echo "Major"; return ;;
    *"🧹 Nitpick"*|*Nitpick*) echo "Nitpick"; return ;;
    *"🔵 Trivial"*|*Trivial*) echo "Trivial"; return ;;
    *"Outside diff range"*) echo "Trivial"; return ;;
    *Minor*) echo "Minor"; return ;;
  esac
  echo "Unknown"
}

# severity_to_track <severity> → substantive|polish
#
# Spec routing: P0/P1/P2/Major → substantive; P3/Nitpick/Trivial →
# polish; Minor → substantive (closer to Major in CodeRabbit's badge
# semantics); Unknown → substantive (err on surface).
severity_to_track() {
  case "$1" in
    P0|P1|P2|Major|Minor) echo "substantive" ;;
    P3|Nitpick|Trivial)   echo "polish" ;;
    *)                    echo "substantive" ;;
  esac
}

# item_id_for <stable-key> → 12-char SHA1 prefix
#
# Used to build the `<!-- mp-id:... -->` marker on each rollup line
# item. The key should be the canonical `<repo>#<pr>:<thread_id>`
# per spec so the same thread always gets the same ID across days.
item_id_for() {
  printf '%s' "$1" | shasum -a 1 | cut -c1-12
}

# extract_tag_class <reply-body> → class string or empty
#
# Greps for the canonical `[mergepath-resolve: <class>]` tag that
# agent-side resolve-pr-threads.sh emits (mergepath#299 follow-up).
# Returns the class string (lowercase, hyphenated) or empty if no
# tag present. The regex is intentionally tolerant of surrounding
# whitespace.
extract_tag_class() {
  # grep -oE exits 1 on no-match, which under `set -e` + `pipefail`
  # would kill the caller. We squash to empty stdout on no-match so
  # callers can rely on `[ -z "$class" ]` semantics regardless of the
  # caller's shell options. Also: the regex requires a `]` immediately
  # after the class name; we strip surrounding whitespace via the sed
  # capture group so `[mergepath-resolve:  foo ]` and `[mergepath-resolve:foo]`
  # both parse to `foo`.
  printf '%s' "$1" \
    | grep -oE '\[mergepath-resolve:[[:space:]]*[a-z-]+[[:space:]]*\]' 2>/dev/null \
    | head -n1 \
    | sed -E 's/\[mergepath-resolve:[[:space:]]*([a-z-]+)[[:space:]]*\]/\1/' \
    || true
}

# tag_class_action <class> → skip|surface
#
# Maps a parsed tag class to whether the rollup should surface or
# skip the thread. Unknown classes route to "surface" per the spec
# (err on surface — future class additions are additive).
tag_class_action() {
  case "$1" in
    addressed-elsewhere|canonical-coverage|rebuttal-recorded) echo "skip" ;;
    nitpick-noted|deferred-to-followup) echo "surface" ;;
    "") echo "" ;;  # no tag → caller falls through to heuristics
    *)  echo "surface" ;;  # unknown → surface
  esac
}

# is_agent_author <login> → exit 0 if agent, 1 otherwise
#
# Used to recognize "addressed via reply" (must be from an agent
# author) and to filter who's allowed to emit a `[mergepath-resolve:]`
# tag. Reads AGENT_AUTHORS (colon-separated). Bash 3.2 compatible —
# avoids associative arrays.
is_agent_author() {
  local login="$1"
  local oldIFS="$IFS"
  IFS=':'
  set -- $AGENT_AUTHORS
  IFS="$oldIFS"
  for a; do
    [ "$login" = "$a" ] && return 0
  done
  return 1
}

# body_excerpt <body> [max_chars]
#
# Single-line, trimmed excerpt suitable for the rollup checklist
# item. Default max is 200 chars. Replaces newlines/tabs with spaces
# so the markdown rendering doesn't break.
body_excerpt() {
  local max="${2:-200}"
  printf '%s' "$1" | tr '\n\r\t' '   ' | head -c "$max"
}
