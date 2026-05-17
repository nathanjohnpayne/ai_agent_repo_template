#!/usr/bin/env bash
# scripts/lib/gh-retry-helpers.sh
#
# with_gh_retry — wrap a gh/gh-api call in 3-attempt retry with 30s backoff.
# Distinguishes transient (HTTP 5xx, rate-limit, "Resource not accessible by
# integration") from permanent (HTTP 4xx other than 429/403, malformed JSON)
# failures. Only retries the transient class.
#
# Usage:
#   with_gh_retry gh pr view 123 --json statusCheckRollup
#   with_gh_retry gh api ...
#
# Exit codes:
#   0  — call succeeded on attempt N
#   non-zero — call failed after 3 attempts or hit a permanent error
#
# Env tuning:
#   GH_RETRY_ATTEMPTS (default 3)
#   GH_RETRY_BACKOFF_SECONDS (default 30)

set -euo pipefail

with_gh_retry() {
  local attempts=${GH_RETRY_ATTEMPTS:-3}
  local backoff=${GH_RETRY_BACKOFF_SECONDS:-30}
  # Validate env knobs (CR Major #328 round 2). Non-numeric or
  # non-positive values previously could skip the loop entirely
  # (returning success with empty output) or break `sleep` under
  # `set -e`. Fall back to the defaults with a stderr warning rather
  # than silently no-op'ing.
  case "$attempts" in
    ''|*[!0-9]*|0) printf '[gh-retry] WARN: GH_RETRY_ATTEMPTS=%q invalid; using default 3\n' "$attempts" >&2; attempts=3 ;;
  esac
  case "$backoff" in
    ''|*[!0-9]*) printf '[gh-retry] WARN: GH_RETRY_BACKOFF_SECONDS=%q invalid; using default 30\n' "$backoff" >&2; backoff=30 ;;
  esac
  local attempt=1
  local rc=0
  local output=""

  while [ "$attempt" -le "$attempts" ]; do
    # Capture stdout+stderr AND the exit code in one shot. Using
    # `if output=...; then` would discard `$?` after the failed
    # `if` test (bash resets $? to 0 in that position), so we
    # invoke + check separately. `|| rc=$?` keeps `set -e` happy
    # because the `||` short-circuit consumes the non-zero exit.
    rc=0
    output=$("$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$output"
      return 0
    fi

    # Classify the failure. Permanent failures break out immediately.
    # The 4xx matcher covers the full 400-499 range (CR Minor #328
    # round 2): the prior `4(0[0-9]|1[0-9])` form only matched
    # 400-419 and silently retried 4xx like 422 / 451 as transient.
    if printf '%s' "$output" | grep -qE 'HTTP 4[0-9]{2}' \
       && ! printf '%s' "$output" | grep -qE 'HTTP (403|429)' \
       && ! printf '%s' "$output" | grep -q 'Resource not accessible by integration'; then
      printf '%s' "$output" >&2
      return "$rc"
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      printf '[gh-retry] attempt %d/%d failed (rc=%d), sleeping %ds before retry. tail: %s\n' \
        "$attempt" "$attempts" "$rc" "$backoff" "$(printf '%s' "$output" | tail -1)" >&2
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done

  printf '%s' "$output" >&2
  return "$rc"
}

export -f with_gh_retry
