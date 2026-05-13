#!/usr/bin/env bash
# scripts/sweep-unresolved-feedback/render.sh
#
# Consume the NDJSON enumeration emitted by enumerate.sh, render a
# per-repo "Unresolved reviewer feedback backlog" rollup, and post it
# to a SINGLE issue in this repo (mergepath) as the cross-repo
# clearinghouse. Idempotent on its own output:
#
#   - First run: opens a new issue titled
#       "Unresolved reviewer feedback backlog — <YYYY-MM-DD>"
#     with label `post-review`.
#   - Subsequent runs (existing open issue with exact title prefix
#       "Unresolved reviewer feedback backlog" and label `post-review`):
#     compute a content hash of the rollup body. If unchanged since
#     the prior run (matched via the hidden HTML comment marker the
#     script writes), do nothing — no duplicate comment. If the
#     rollup changed materially, post a delta comment listing NEW
#     items only and update the issue body.
#
# Design notes (#236):
#
#   - Single rollup issue per sweep target (mergepath itself), NOT one
#     per scanned target repo. The issue body has a per-target-repo
#     section so the human can navigate. This keeps cross-repo
#     remediation visible in one place — the 2026-05-13 manual sweep
#     proved this is the right ergonomic (#234).
#   - Idempotency is anchored by a hidden HTML comment in the issue
#     body containing the prior enumeration's content hash AND the
#     sorted list of thread_ids. Delta detection diffs the current
#     thread_id set against the prior — items in current-only get
#     posted as the delta comment; items in prior-only are recorded
#     as "resolved between sweeps" (informational, no separate
#     comment).
#   - Counts the rollup as "still requiring fix" only after the
#     validation pass classifies items. v1 of this script just
#     enumerates — the validation pass is a follow-up issue. The
#     rollup body is honest about this: it labels the counts as
#     "raw, pre-validation".
#
# Inputs:
#   $1   path to NDJSON enumeration file (default: /dev/stdin)
#
# Environment:
#   GH_TOKEN              required. Write-path? NO — issue create /
#                         comment on THIS repo only. In CI the
#                         default GITHUB_TOKEN suffices because the
#                         workflow runs in this repo.
#   SWEEP_TARGET_REPO     repo to post the rollup to. Default:
#                         nathanjohnpayne/mergepath. Override in
#                         tests or for a dry-run staging issue.
#   SWEEP_ROLLUP_TITLE    title for the rollup issue. Default
#                         "Unresolved reviewer feedback backlog".
#                         The first creation appends " — <date>"
#                         for human readability; subsequent runs
#                         match on the prefix.
#   SWEEP_DRY_RUN         "1" to print the would-be issue body /
#                         delta comment to stderr and exit without
#                         calling the API. Used by the unit tests.
#   SWEEP_TODAY           override the date stamp (YYYY-MM-DD). Used
#                         by the unit tests for deterministic output.
#
# Exit codes:
#   0   success (no-op, new issue, or delta comment posted)
#   1   setup error (no input, GH_TOKEN unset, malformed JSON)
#   2   API error (gh exited non-zero on issue create/comment)
#
# Bash 3.2 compatible.

set -euo pipefail

INPUT="${1:-/dev/stdin}"

if [ -z "${GH_TOKEN:-}" ] && [ -z "${SWEEP_DRY_RUN:-}" ]; then
  echo "render: GH_TOKEN not set (and SWEEP_DRY_RUN not set)" >&2
  exit 1
fi

for dep in gh jq sha256sum_or_shasum; do
  case "$dep" in
    sha256sum_or_shasum)
      if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        echo "render: required dependency missing: sha256sum or shasum" >&2
        exit 1
      fi
      ;;
    *)
      if ! command -v "$dep" >/dev/null 2>&1; then
        echo "render: required dependency missing: $dep" >&2
        exit 1
      fi
      ;;
  esac
done

# Portable hash helper. sha256sum is GNU; shasum is BSD.
_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

TARGET_REPO="${SWEEP_TARGET_REPO:-nathanjohnpayne/mergepath}"
TITLE_PREFIX="${SWEEP_ROLLUP_TITLE:-Unresolved reviewer feedback backlog}"

if [ -n "${SWEEP_TODAY:-}" ]; then
  TODAY="$SWEEP_TODAY"
else
  TODAY=$(date -u '+%Y-%m-%d')
fi

# ---------------------------------------------------------------------------
# Read NDJSON into a working file. We need to make two passes (counts
# + body render + delta-detect), so a tmp file is simpler than
# re-reading stdin.
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sweep-render.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

NDJSON="$WORKDIR/findings.ndjson"
if [ "$INPUT" = "/dev/stdin" ] || [ "$INPUT" = "-" ]; then
  cat > "$NDJSON"
else
  cp "$INPUT" "$NDJSON"
fi

# Validate each line is JSON before going further.
LINE_COUNT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    echo "render: malformed JSON line in input (line $((LINE_COUNT + 1)))" >&2
    exit 1
  fi
  LINE_COUNT=$((LINE_COUNT + 1))
done < "$NDJSON"

echo "render: $LINE_COUNT findings ingested" >&2

# ---------------------------------------------------------------------------
# Sorted thread-id list (used for the idempotency marker AND for delta
# detection against the prior body).
# ---------------------------------------------------------------------------
SORTED_IDS="$WORKDIR/sorted-ids.txt"
if [ "$LINE_COUNT" -gt 0 ]; then
  jq -r '.thread_id' "$NDJSON" | sort -u > "$SORTED_IDS"
else
  : > "$SORTED_IDS"
fi

CONTENT_HASH=$(_hash < "$SORTED_IDS")
echo "render: content hash = $CONTENT_HASH" >&2

# Render the body. Sections grouped by repo, ordered by repo name; per
# repo, items grouped by severity (P0, P1, P2, P3, Unknown).
BODY="$WORKDIR/body.md"
{
  echo "<!-- sweep-unresolved-feedback v1 -->"
  echo "<!-- content-hash: $CONTENT_HASH -->"
  echo "<!-- last-run: $TODAY -->"
  echo ""
  echo "# Unresolved reviewer feedback backlog"
  echo ""
  echo "Automated weekly sweep — see #236. Last run **$TODAY** found **$LINE_COUNT** unresolved review threads on closed PRs across configured target repos."
  echo ""
  echo "**Counts below are raw (pre-validation).** A separate validation pass (see issue rubric in #236) is required to classify each item as VALID / ALREADY-FIXED / REJECTED / MOOT / AMBIGUOUS before treating the count as actionable backlog."
  echo ""
  echo "Lookback window: closed PRs in the last \`SWEEP_LOOKBACK_DAYS\` days (default 90)."
  echo ""

  if [ "$LINE_COUNT" -eq 0 ]; then
    echo "## No unresolved threads found"
    echo ""
    echo "All scanned repos came back clean. Either the merge gate is doing its job, the lookback window expired everything, or all target repos are quiet."
  else
    echo "## By repo"
    echo ""
    # Per-repo aggregate counts.
    jq -r '.repo' "$NDJSON" | sort -u | while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      n=$(jq -r --arg r "$repo" 'select(.repo == $r) | .thread_id' "$NDJSON" | wc -l | tr -d ' ')
      printf -- '- **%s** — %s items\n' "$repo" "$n"
    done
    echo ""

    echo "## Findings"
    echo ""
    jq -r '.repo' "$NDJSON" | sort -u | while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      echo "### $repo"
      echo ""
      for sev in P0 P1 P2 P3 Unknown; do
        count=$(jq -r --arg r "$repo" --arg s "$sev" '
          select(.repo == $r and .severity == $s) | .thread_id
        ' "$NDJSON" | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
          echo "<details>"
          echo "<summary>$sev ($count)</summary>"
          echo ""
          jq -r --arg r "$repo" --arg s "$sev" '
            select(.repo == $r and .severity == $s)
            | "- [#\(.pr_number) · \(.pr_title // "(no title)")](\(.thread_url)) — `\(.author_login)`: \(.body_excerpt)"
          ' "$NDJSON"
          echo ""
          echo "</details>"
          echo ""
        fi
      done
    done
  fi
} > "$BODY"

# ---------------------------------------------------------------------------
# Dry-run short-circuit. Print the body and exit. Tests use this.
# ---------------------------------------------------------------------------
if [ -n "${SWEEP_DRY_RUN:-}" ]; then
  echo "render: SWEEP_DRY_RUN=1 — printing body to stdout and exiting 0" >&2
  cat "$BODY"
  exit 0
fi

# ---------------------------------------------------------------------------
# Find existing rollup issue. Match on label `post-review` AND title
# prefix. Take the most recent open match.
# ---------------------------------------------------------------------------
EXISTING_JSON=$(gh issue list \
  --repo "$TARGET_REPO" \
  --state open \
  --label post-review \
  --search "$TITLE_PREFIX in:title" \
  --json number,title,body \
  --limit 20 2>/dev/null || echo "[]")

EXISTING_NUMBER=$(printf '%s' "$EXISTING_JSON" | jq -r --arg p "$TITLE_PREFIX" '
  [ .[] | select(.title | startswith($p)) ] | (.[0].number // empty)
')

if [ -z "$EXISTING_NUMBER" ]; then
  echo "render: no existing rollup issue found — creating new one" >&2
  NEW_TITLE="$TITLE_PREFIX — $TODAY"
  if ! gh issue create \
    --repo "$TARGET_REPO" \
    --title "$NEW_TITLE" \
    --label post-review \
    --body-file "$BODY" >&2; then
    echo "render: gh issue create failed" >&2
    exit 2
  fi
  echo "render: created new rollup issue" >&2
  exit 0
fi

echo "render: found existing rollup issue #$EXISTING_NUMBER" >&2

# Extract the prior content-hash marker. If unchanged, no-op.
PRIOR_BODY=$(printf '%s' "$EXISTING_JSON" | jq -r --arg n "$EXISTING_NUMBER" '
  [ .[] | select((.number|tostring) == $n) ] | .[0].body // ""
')
PRIOR_HASH=$(printf '%s' "$PRIOR_BODY" | sed -nE 's|.*<!-- content-hash: ([a-f0-9]+) -->.*|\1|p' | head -1)

if [ -n "$PRIOR_HASH" ] && [ "$PRIOR_HASH" = "$CONTENT_HASH" ]; then
  echo "render: content unchanged since prior run (hash $CONTENT_HASH) — no-op" >&2
  exit 0
fi

# Delta detection: extract the prior sorted thread-id list from a
# hidden marker block in the body (we write it on every update).
PRIOR_IDS="$WORKDIR/prior-ids.txt"
printf '%s' "$PRIOR_BODY" | awk '
  /<!-- thread-ids-begin -->/ { capture=1; next }
  /<!-- thread-ids-end -->/   { capture=0 }
  capture==1                  { print }
' | sed -E 's/^<!-- //; s/ -->$//' | sort -u > "$PRIOR_IDS" || true

NEW_IDS="$WORKDIR/new-ids.txt"
comm -23 "$SORTED_IDS" "$PRIOR_IDS" > "$NEW_IDS" 2>/dev/null || true

RESOLVED_IDS="$WORKDIR/resolved-ids.txt"
comm -13 "$SORTED_IDS" "$PRIOR_IDS" > "$RESOLVED_IDS" 2>/dev/null || true

NEW_COUNT=$(wc -l < "$NEW_IDS" | tr -d ' ')
RESOLVED_COUNT=$(wc -l < "$RESOLVED_IDS" | tr -d ' ')

# Append the marker block so the next run can compute the delta.
{
  cat "$BODY"
  echo ""
  echo "<!-- thread-ids-begin -->"
  if [ -s "$SORTED_IDS" ]; then
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      printf '<!-- %s -->\n' "$tid"
    done < "$SORTED_IDS"
  fi
  echo "<!-- thread-ids-end -->"
} > "$BODY.with-marker"
mv "$BODY.with-marker" "$BODY"

# Update the body in place.
echo "render: updating issue #$EXISTING_NUMBER body (new=$NEW_COUNT, resolved=$RESOLVED_COUNT)" >&2
if ! gh issue edit "$EXISTING_NUMBER" \
  --repo "$TARGET_REPO" \
  --body-file "$BODY" >&2; then
  echo "render: gh issue edit failed" >&2
  exit 2
fi

# Post the delta comment if there are new items. Resolved-only changes
# update the body but don't get a comment — that's informational.
if [ "$NEW_COUNT" -gt 0 ]; then
  COMMENT="$WORKDIR/comment.md"
  {
    echo "## Sweep delta — $TODAY"
    echo ""
    echo "**$NEW_COUNT new** unresolved thread(s) since the last sweep. **$RESOLVED_COUNT** prior thread(s) cleared (resolved, marked outdated, or PR deleted)."
    echo ""
    echo "### New items"
    echo ""
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      jq -r --arg t "$tid" '
        select(.thread_id == $t)
        | "- **\(.repo) #\(.pr_number)** · `\(.severity)` · [\(.pr_title // "(no title)")](\(.thread_url)) — `\(.author_login)`: \(.body_excerpt)"
      ' "$NDJSON"
    done < "$NEW_IDS"
  } > "$COMMENT"

  if ! gh issue comment "$EXISTING_NUMBER" \
    --repo "$TARGET_REPO" \
    --body-file "$COMMENT" >&2; then
    echo "render: gh issue comment failed" >&2
    exit 2
  fi
  echo "render: posted delta comment ($NEW_COUNT new items)" >&2
fi

exit 0
