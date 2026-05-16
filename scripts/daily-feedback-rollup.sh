#!/usr/bin/env bash
# scripts/daily-feedback-rollup.sh
#
# Daily end-of-day rollup of bot-review threads that were resolved on
# this repo's PRs in the last 24h **without** an associated fix
# commit or substantive reply. Files two GitHub Issues per day, one
# per track (substantive / polish), so the deferred-and-forgotten
# class of feedback gets surfaced while the context is still hot.
#
# Implements the first slice of mergepath#299. The follow-ups
# explicitly NOT in this slice:
#
#   - Agent-side `[mergepath-resolve:<class>]` tag emission in
#     `scripts/resolve-pr-threads.sh`. This script reads the tag if
#     present (forward-compatibility) and falls back to heuristics
#     when it isn't.
#   - Full triage-state persistence / dedupe-against-prior-rollups
#     (the `<!-- mp-id:... -->` marker + 14-day window). v1 emits
#     the stable IDs so a future PR can layer dedupe on top without
#     a data migration; the dedupe logic itself is deferred.
#
# Architecture mirrors `scripts/sweep-unresolved-feedback/enumerate.sh`
# + `render.sh` but inverted: enumerate looks for UNresolved feedback
# on closed PRs; this script looks for RESOLVED feedback on
# yesterday-merged PRs that wasn't actually addressed.
#
# Usage:
#   daily-feedback-rollup.sh                       # post issues
#   daily-feedback-rollup.sh --dry-run             # print NDJSON, no issue mutation
#   daily-feedback-rollup.sh --since YYYY-MM-DD    # explicit window start
#   daily-feedback-rollup.sh --until YYYY-MM-DD    # explicit window end
#
# Environment:
#   GH_TOKEN                  required. Reads from this repo's PRs +
#                             writes issues. PAT must have
#                             repo:public_repo or repo scope.
#   REPO                      owner/repo (default: current repo
#                             resolved via `gh repo view`).
#   ROLLUP_SUBSTANTIVE_LABEL  default: deferred-feedback-rollup
#   ROLLUP_POLISH_LABEL       default: polish-feedback-rollup
#   ROLLUP_SUBSTANTIVE_THROTTLE  default: 5 (unchecked-items threshold
#                                for appending to existing issue
#                                instead of opening a new one)
#   ROLLUP_POLISH_THROTTLE       default: 20
#   ROLLUP_MAX_PRS_PER_DAY    safety cap, default 100
#   ROLLUP_AGENT_AUTHORS      colon-separated list of agent author
#                             logins (default:
#                             nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex)
#
# Exit codes:
#   0   success (one or both rollup issues posted, or no surfaceable
#       items today)
#   1   setup error (missing dep, GH_TOKEN unset, REPO unresolvable)
#   2   API error (gh GraphQL failure, issue create failure)
#
# Bash 3.2 compatible (macOS default + ubuntu-latest).

set -euo pipefail

DRY_RUN=false
SINCE=""
UNTIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --help|-h) sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

for dep in gh jq shasum; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "daily-feedback-rollup: required dependency missing: $dep" >&2
    exit 1
  fi
done

# Source the pure-function helpers so the same classification logic
# is exercised by tests/test_daily_feedback_rollup.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/daily-feedback-rollup-helpers.sh"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "daily-feedback-rollup: GH_TOKEN not set." >&2
  exit 1
fi

REPO="${REPO:-$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || true)}"
if [ -z "$REPO" ]; then
  echo "daily-feedback-rollup: could not resolve REPO. Set REPO=owner/name or run inside a gh-aware checkout." >&2
  exit 1
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

SUBSTANTIVE_LABEL="${ROLLUP_SUBSTANTIVE_LABEL:-deferred-feedback-rollup}"
POLISH_LABEL="${ROLLUP_POLISH_LABEL:-polish-feedback-rollup}"
SUBSTANTIVE_THROTTLE="${ROLLUP_SUBSTANTIVE_THROTTLE:-5}"
POLISH_THROTTLE="${ROLLUP_POLISH_THROTTLE:-20}"
MAX_PRS_PER_DAY="${ROLLUP_MAX_PRS_PER_DAY:-100}"
AGENT_AUTHORS="${ROLLUP_AGENT_AUTHORS:-nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"

# Compute the window. Default: yesterday 00:00:00Z → today 00:00:00Z UTC.
# BSD date (macOS) and GNU date have divergent flag syntax — try GNU first.
if [ -z "$SINCE" ]; then
  if date -u -d "@0" '+%Y-%m-%d' >/dev/null 2>&1; then
    SINCE=$(date -u -d "1 day ago" '+%Y-%m-%dT00:00:00Z')
  else
    SINCE=$(date -u -v-1d '+%Y-%m-%dT00:00:00Z')
  fi
elif [ "${#SINCE}" -eq 10 ]; then
  SINCE="${SINCE}T00:00:00Z"
fi
if [ -z "$UNTIL" ]; then
  UNTIL=$(date -u '+%Y-%m-%dT00:00:00Z')
elif [ "${#UNTIL}" -eq 10 ]; then
  UNTIL="${UNTIL}T00:00:00Z"
fi

# Date stamp for the rollup issue title (uses SINCE date).
DATE_STAMP="${SINCE%T*}"

echo "daily-feedback-rollup: repo=$REPO window=[$SINCE, $UNTIL) date_stamp=$DATE_STAMP" >&2

# ---------------------------------------------------------------------
# Step 1 — fetch PRs merged in the window
# ---------------------------------------------------------------------

# Use the search API. `closed:>=$SINCE` includes both merged and
# closed-without-merge — that's intentional; closed-without-merge
# may still carry resolved-without-fix threads worth surfacing.
#
# No `|| echo '[]'` fallback: an API failure here (auth, rate limit,
# network) MUST fail the run loudly. Treating a failed call as "zero
# PRs" makes deferred feedback silently disappear, which is exactly
# the failure mode this whole script exists to prevent (CodeRabbit
# Major r1 on PR #303).
if ! prs_json=$(gh pr list \
    --repo "$REPO" \
    --state closed \
    --search "closed:>=$SINCE closed:<$UNTIL" \
    --limit "$MAX_PRS_PER_DAY" \
    --json number,title,url,mergedAt); then
  echo "daily-feedback-rollup: ERROR — gh pr list failed (auth/rate-limit/network?). Aborting rather than producing an empty rollup." >&2
  exit 2
fi

pr_count=$(printf '%s' "$prs_json" | jq 'length')
echo "daily-feedback-rollup: $pr_count PRs in window" >&2

# Counters for the methodology footer. COUNT_FIX uses the weaker
# per-PR heuristic (any agent-author commit on the PR after the
# comment's createdAt) rather than the spec's per-file variant —
# see the Heuristic 2 block below for the trade-off rationale.
COUNT_FIX=0
COUNT_REPLY=0
COUNT_STALE=0
COUNT_TAGGED_SKIP=0
COUNT_TAGGED_SURFACE=0
COUNT_DEFERRED_UNTAGGED=0

# Per-track NDJSON streams. Each surviving item gets one line.
SUBSTANTIVE_NDJSON=$(mktemp "${TMPDIR:-/tmp}/rollup-sub-XXXXXX.ndjson")
POLISH_NDJSON=$(mktemp "${TMPDIR:-/tmp}/rollup-pol-XXXXXX.ndjson")
trap 'rm -f "$SUBSTANTIVE_NDJSON" "$POLISH_NDJSON"' EXIT

# ---------------------------------------------------------------------
# Step 2 — for each PR, fetch + classify threads
# ---------------------------------------------------------------------

i=0
while [ "$i" -lt "$pr_count" ]; do
  pr_number=$(printf '%s' "$prs_json" | jq -r ".[$i].number")
  pr_title=$(printf '%s' "$prs_json" | jq -r ".[$i].title")
  pr_url=$(printf '%s' "$prs_json" | jq -r ".[$i].url")
  pr_merged_at=$(printf '%s' "$prs_json" | jq -r ".[$i].mergedAt // \"\"")
  i=$((i + 1))

  # GraphQL: pull resolved review threads with full comment chain and
  # the PR's commit list. We need the comment chain to detect
  # substantive replies + the canonical tag, and the commit list to
  # detect fix commits.
  threads_json=$(gh api graphql -f query='
    query($owner:String!,$name:String!,$pr:Int!) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          headRefOid
          commits(last: 100) {
            nodes {
              commit {
                oid
                authoredDate
                author { user { login } }
              }
            }
          }
          reviewThreads(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              originalLine
              comments(first: 50) {
                nodes {
                  databaseId
                  author { login }
                  body
                  createdAt
                  originalCommit { oid }
                  url
                }
              }
            }
          }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$NAME" -F pr="$pr_number") || {
    # Per-PR failure: log + skip rather than abort the whole rollup.
    # A single PR's GraphQL fetch can fail transiently (rate limit on
    # a specific repo, lock contention) without invalidating the rest
    # of the day's work. The per-run-level `gh pr list` above DOES
    # fail-closed because that failure means we have no data at all.
    echo "daily-feedback-rollup: WARN gh api graphql failed for $REPO#$pr_number; skipping" >&2
    continue
  }

  has_next=$(printf '%s' "$threads_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
  if [ "$has_next" = "true" ]; then
    echo "daily-feedback-rollup: WARN $REPO#$pr_number has >100 review threads; first page only" >&2
  fi

  # Per-PR commit map: SHA → authoredDate (for stale-HEAD detection +
  # touched-paths is needed at commit-detail level which the query
  # above doesn't include — we approximate via "any commit by an
  # agent author between comment.createdAt and thread.resolvedAt"
  # rather than per-file. Per-file is a documented v1 limitation in
  # the spec.)
  # (Currently unused — placeholder for future per-file fix detection.)

  thread_count=$(printf '%s' "$threads_json" | jq '.data.repository.pullRequest.reviewThreads.nodes | length // 0')

  j=0
  while [ "$j" -lt "$thread_count" ]; do
    t=$(printf '%s' "$threads_json" | jq -c ".data.repository.pullRequest.reviewThreads.nodes[$j]")
    j=$((j + 1))

    is_resolved=$(printf '%s' "$t" | jq -r '.isResolved')
    [ "$is_resolved" != "true" ] && continue

    # Only consider bot-authored original comments — agent-authored
    # top comments aren't bot review feedback. (The reply chain can
    # mix bot + agent; we look at the first comment for the original
    # finding.)
    original_author=$(printf '%s' "$t" | jq -r '.comments.nodes[0].author.login // "unknown"')
    case "$original_author" in
      coderabbitai\[bot\]|chatgpt-codex-connector\[bot\]) : ;;
      *) continue ;;
    esac

    thread_id=$(printf '%s' "$t" | jq -r '.id')
    thread_path=$(printf '%s' "$t" | jq -r '.path // ""')
    thread_line=$(printf '%s' "$t" | jq -r '.line // .originalLine // 0')
    thread_url=$(printf '%s' "$t" | jq -r '.comments.nodes[0].url // ""')
    original_body=$(printf '%s' "$t" | jq -r '.comments.nodes[0].body // ""')
    original_created=$(printf '%s' "$t" | jq -r '.comments.nodes[0].createdAt // ""')

    # Heuristic 1: tag in any agent-authored reply on this thread.
    # The reply with the canonical `[mergepath-resolve:<class>]`
    # marker takes precedence over the inferred class.
    tag_class=""
    reply_count=$(printf '%s' "$t" | jq '.comments.nodes | length')
    k=1
    while [ "$k" -lt "$reply_count" ]; do
      reply=$(printf '%s' "$t" | jq -c ".comments.nodes[$k]")
      reply_login=$(printf '%s' "$reply" | jq -r '.author.login // "unknown"')
      reply_body=$(printf '%s' "$reply" | jq -r '.body // ""')
      if is_agent_author "$reply_login"; then
        candidate=$(extract_tag_class "$reply_body")
        if [ -n "$candidate" ]; then
          tag_class="$candidate"
          break
        fi
      fi
      k=$((k + 1))
    done

    if [ -n "$tag_class" ]; then
      case "$tag_class" in
        addressed-elsewhere|canonical-coverage|rebuttal-recorded)
          COUNT_TAGGED_SKIP=$((COUNT_TAGGED_SKIP + 1))
          continue
          ;;
        nitpick-noted|deferred-to-followup)
          COUNT_TAGGED_SURFACE=$((COUNT_TAGGED_SURFACE + 1))
          # Fall through to severity-routing below.
          ;;
        *)
          # Unknown tag class → surface as substantive per spec.
          COUNT_TAGGED_SURFACE=$((COUNT_TAGGED_SURFACE + 1))
          ;;
      esac
    else
      # Heuristic 2: addressed-via-fix — any agent-author commit on
      # the PR with authoredDate > comment.createdAt. The spec's
      # per-file variant (commit must touch the comment's anchored
      # file) is more precise but requires a REST round-trip per
      # commit to fetch file lists; the GitHub GraphQL `Commit` type
      # doesn't expose changed files. The weaker per-PR heuristic
      # catches the codex P1 case ("resolved by follow-up commit, no
      # reply") but is conservative-toward-skip: an agent commit on
      # a DIFFERENT file in the same PR still marks this thread as
      # fix-addressed. The v2 agent-side
      # `[mergepath-resolve: addressed-elsewhere]` tagging closes
      # the gap more precisely than commit-introspection ever would.
      # (codex P1 r1 on PR #303.)
      addressed_via_fix=false
      commit_count=$(printf '%s' "$threads_json" | jq '.data.repository.pullRequest.commits.nodes | length')
      m=0
      while [ "$m" -lt "$commit_count" ]; do
        c_date=$(printf '%s' "$threads_json" | jq -r ".data.repository.pullRequest.commits.nodes[$m].commit.authoredDate // \"\"")
        c_login=$(printf '%s' "$threads_json" | jq -r ".data.repository.pullRequest.commits.nodes[$m].commit.author.user.login // \"\"")
        # String comparison works for ISO 8601 timestamps.
        if [ -n "$c_login" ] && [ -n "$c_date" ] && [ -n "$original_created" ] \
           && [ "$c_date" \> "$original_created" ] && is_agent_author "$c_login"; then
          addressed_via_fix=true
          break
        fi
        m=$((m + 1))
      done
      if $addressed_via_fix; then
        COUNT_FIX=$((COUNT_FIX + 1))
        continue
      fi

      # Heuristic 3: substantive reply from an agent author (≥30 chars,
      # NOT just the tag marker). If present, treat as addressed-via-
      # reply and skip.
      addressed_via_reply=false
      k=1
      while [ "$k" -lt "$reply_count" ]; do
        reply=$(printf '%s' "$t" | jq -c ".comments.nodes[$k]")
        reply_login=$(printf '%s' "$reply" | jq -r '.author.login // "unknown"')
        reply_body=$(printf '%s' "$reply" | jq -r '.body // ""')
        if is_agent_author "$reply_login"; then
          reply_len=${#reply_body}
          if [ "$reply_len" -ge 30 ]; then
            addressed_via_reply=true
            break
          fi
        fi
        k=$((k + 1))
      done
      if $addressed_via_reply; then
        COUNT_REPLY=$((COUNT_REPLY + 1))
        continue
      fi

      # Heuristic 4: thread is stale-head — its originalCommit isn't
      # in the PR's current commit history (got rebased away or force-
      # pushed off). The naive `orig_commit != head_oid` check was
      # over-broad: many bot comments anchor to intermediate commits
      # that are still in the PR history and remain valid findings.
      # Use membership against the commits list we already pulled in
      # the GraphQL query (CodeRabbit Major r1 on PR #303).
      orig_commit=$(printf '%s' "$t" | jq -r '.comments.nodes[0].originalCommit.oid // ""')
      if [ -n "$orig_commit" ]; then
        if ! printf '%s' "$threads_json" | jq -e --arg oid "$orig_commit" \
             '.data.repository.pullRequest.commits.nodes
              | any(.commit.oid == $oid)' >/dev/null; then
          COUNT_STALE=$((COUNT_STALE + 1))
          continue
        fi
      fi

      # No tag, no substantive reply, not stale → deferred-untagged.
      # SURFACE it (route by severity below).
      COUNT_DEFERRED_UNTAGGED=$((COUNT_DEFERRED_UNTAGGED + 1))
    fi

    # Severity → track.
    severity=$(classify_severity "$original_body")
    track=$(severity_to_track "$severity")

    # Item ID.
    item_id=$(item_id_for "${REPO}#${pr_number}:${thread_id}")

    # Body excerpt: first 200 chars, single-line, trimmed.
    body_excerpt_text=$(body_excerpt "$original_body")

    # Tag indicator for the rollup body (so triage knows whether the
    # agent recorded rationale or this is heuristic-fallback).
    if [ -n "$tag_class" ]; then
      tag_note="tagged: $tag_class"
    else
      tag_note="untagged — agent did not record rationale"
    fi

    item_json=$(jq -nc \
      --arg repo "$REPO" \
      --arg pr_number "$pr_number" \
      --arg pr_title "$pr_title" \
      --arg pr_url "$pr_url" \
      --arg pr_merged_at "$pr_merged_at" \
      --arg thread_id "$thread_id" \
      --arg thread_path "$thread_path" \
      --arg thread_line "$thread_line" \
      --arg thread_url "$thread_url" \
      --arg author "$original_author" \
      --arg severity "$severity" \
      --arg track "$track" \
      --arg body_excerpt "$body_excerpt_text" \
      --arg tag_note "$tag_note" \
      --arg item_id "$item_id" \
      '{
        repo:         $repo,
        pr_number:    $pr_number,
        pr_title:     $pr_title,
        pr_url:       $pr_url,
        pr_merged_at: $pr_merged_at,
        thread_id:    $thread_id,
        thread_path:  $thread_path,
        thread_line:  $thread_line,
        thread_url:   $thread_url,
        author:       $author,
        severity:     $severity,
        track:        $track,
        body_excerpt: $body_excerpt,
        tag_note:     $tag_note,
        item_id:      $item_id
      }')

    if [ "$track" = "substantive" ]; then
      printf '%s\n' "$item_json" >> "$SUBSTANTIVE_NDJSON"
    else
      printf '%s\n' "$item_json" >> "$POLISH_NDJSON"
    fi
  done
done

SUBSTANTIVE_COUNT=$(wc -l < "$SUBSTANTIVE_NDJSON" | tr -d ' ')
POLISH_COUNT=$(wc -l < "$POLISH_NDJSON" | tr -d ' ')

echo "daily-feedback-rollup: classified substantive=$SUBSTANTIVE_COUNT polish=$POLISH_COUNT" \
     "(skipped fix=$COUNT_FIX reply=$COUNT_REPLY stale=$COUNT_STALE tagged-skip=$COUNT_TAGGED_SKIP)" >&2

# ---------------------------------------------------------------------
# Dry-run short-circuit
# ---------------------------------------------------------------------

if $DRY_RUN; then
  echo "daily-feedback-rollup: --dry-run → emitting NDJSON to stdout, no issue mutation" >&2
  if [ -s "$SUBSTANTIVE_NDJSON" ]; then
    cat "$SUBSTANTIVE_NDJSON"
  fi
  if [ -s "$POLISH_NDJSON" ]; then
    cat "$POLISH_NDJSON"
  fi
  exit 0
fi

# ---------------------------------------------------------------------
# Step 3 — render and post per-track issues
# ---------------------------------------------------------------------

render_rollup_body() {
  local ndjson_file="$1" track="$2"
  local f="$ndjson_file"
  cat <<INTRO
Auto-generated rollup of bot review threads that were resolved on
${DATE_STAMP} without an associated fix commit or substantive reply.
Severity scope: ${track} (see § Two-track rollup in #299 for the
routing rule).

Triage markers (set on the checkbox below):
- \`[ ]\` open / not yet triaged
- \`[x]\` fix landed, won't-fix accepted, or follow-up issue filed
- \`[~]\` N/A — not relevant

INTRO

  # Group by PR. NDJSON is naturally per-thread; awk gives us a
  # quick group-by without re-parsing.
  jq -s -r '
    group_by(.pr_number)[] |
    "## " + .[0].repo + "#" + .[0].pr_number +
      " (merged " + (.[0].pr_merged_at // "n/a") + ", " +
      (.[0].pr_title | tostring) + ")\n" +
    (map(
      "- [ ] [" + .thread_path + ":" + .thread_line + "](" + .thread_url + ")" +
      " — `" + .author + "` " + .severity +
      " [" + .tag_note + "]: \"" + .body_excerpt + "\"" +
      " <!-- mp-id:" + .item_id + " -->"
    ) | join("\n"))
  ' "$f"

  cat <<FOOTER

---

<details>
<summary>Methodology</summary>

- Window: ${SINCE} — ${UNTIL}
- PRs scanned: ${pr_count}
- Threads classified:
  - addressed-via-fix (heuristic, per-PR): ${COUNT_FIX}
  - addressed-via-reply (heuristic): ${COUNT_REPLY}
  - stale-head (heuristic): ${COUNT_STALE}
  - tagged-skip: ${COUNT_TAGGED_SKIP}
  - tagged-surface: ${COUNT_TAGGED_SURFACE}
  - deferred-untagged (heuristic): ${COUNT_DEFERRED_UNTAGGED}

Generator: \`scripts/daily-feedback-rollup.sh\` (mergepath#299)
</details>
FOOTER
}

# Self-throttling: count unchecked items on the most recently-opened
# rollup issue with the track's label. If ≥ threshold, append today's
# items as a comment instead of opening a new issue.
unchecked_count_on() {
  # POSIX character classes — `\s` is GNU-grep-specific and not part
  # of POSIX ERE. The ubuntu-latest runner has GNU grep but the
  # downstream propagation path may not, and consistency with the
  # rest of the codebase (which uses `[[:space:]]`) keeps the
  # check_mktemp_portability-style regex audits happy
  # (CodeRabbit Major r1 on PR #303).
  local issue_number="$1"
  gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' \
    | grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]' || true
}

most_recent_open_rollup() {
  local label="$1"
  gh issue list --repo "$REPO" --state open --label "$label" \
    --limit 1 --json number,title --jq '.[0].number // ""'
}

post_or_append() {
  local ndjson_file="$1" track="$2" label="$3" throttle="$4" title="$5"
  if [ ! -s "$ndjson_file" ]; then
    echo "daily-feedback-rollup: $track — no items to surface today" >&2
    return 0
  fi

  local body
  body=$(render_rollup_body "$ndjson_file" "$track")

  local existing=""
  existing=$(most_recent_open_rollup "$label" || true)

  if [ -n "$existing" ]; then
    local unchecked
    unchecked=$(unchecked_count_on "$existing")
    if [ "$unchecked" -ge "$throttle" ]; then
      echo "daily-feedback-rollup: $track — appending to existing #$existing ($unchecked unchecked ≥ throttle $throttle)" >&2
      # shellcheck disable=SC2016
      gh issue comment "$existing" --repo "$REPO" --body "$body" >&2
      return 0
    fi
  fi

  echo "daily-feedback-rollup: $track — creating new issue '$title'" >&2
  gh issue create --repo "$REPO" --title "$title" --label "$label" --body "$body"
}

post_or_append "$SUBSTANTIVE_NDJSON" "substantive" "$SUBSTANTIVE_LABEL" \
  "$SUBSTANTIVE_THROTTLE" "${SUBSTANTIVE_LABEL} ${DATE_STAMP}"
post_or_append "$POLISH_NDJSON" "polish" "$POLISH_LABEL" \
  "$POLISH_THROTTLE" "${POLISH_LABEL} ${DATE_STAMP}"

echo "daily-feedback-rollup: done" >&2
