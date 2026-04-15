#!/usr/bin/env bash
# gh-pr-guard.sh — PreToolUse hook for Claude Code
#
# Gates three operations:
#   1. gh pr create — blocks unless the command text includes
#      "Authoring-Agent:" and "## Self-Review"
#   2. gh pr merge --admin — blocks unless BREAK_GLASS_ADMIN=1
#      (human must explicitly authorize in chat)
#   3. gh pr merge (non-admin) — blocks when the target PR carries
#      the `needs-external-review` label unless CODEX_CLEARED=1
#      (agent must have just run scripts/codex-review-check.sh
#      successfully). This enforces REVIEW_POLICY.md § Phase 4a
#      merge gate at the hook layer so an agent can't accidentally
#      merge past Label Gate by removing the label without running
#      the gate check first.
#
# Exit codes:
#   0 = allow
#   2 = block (hard stop)
#
# Design notes:
#   - The CODEX_CLEARED check is a hook-layer defense-in-depth. The
#     authoritative merge gate is scripts/codex-review-check.sh; the
#     hook only verifies the agent claims to have run it. An agent
#     that sets CODEX_CLEARED=1 without actually running the check
#     is violating policy — the hook is not an integrity check, it
#     is an ordering check.
#   - PR number is parsed from the command tokens: first positional
#     argument after `merge`. If no positional is present (i.e.,
#     `gh pr merge` with no number, which uses the current branch),
#     the hook falls back to `gh pr view --json labels` with no
#     arguments so it still resolves the label set.
#   - Label lookup calls the GitHub API. This is a new side effect
#     of the hook but consistent with the agent's own label-check
#     behavior elsewhere in the policy flow. Failure to reach the
#     API (e.g., offline, auth issue) fails CLOSED: the hook blocks
#     the merge with a diagnostic message, and the agent must fix
#     the underlying issue before retrying.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only inspect gh pr commands
if ! echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+(create|merge)'; then
  exit 0
fi

# --- gh pr create ---
if echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+create'; then
  MISSING=""

  if ! echo "$COMMAND" | grep -qi 'Authoring-Agent:'; then
    MISSING="${MISSING}  - Missing 'Authoring-Agent:' in PR body\n"
  fi

  if ! echo "$COMMAND" | grep -qi '## Self-Review'; then
    MISSING="${MISSING}  - Missing '## Self-Review' section in PR body\n"
  fi

  if [[ -n "$MISSING" ]]; then
    echo "BLOCKED: PR description is missing required sections per REVIEW_POLICY.md:" >&2
    echo -e "$MISSING" >&2
    echo "Add these to the PR body before creating." >&2
    exit 2
  fi

  exit 0
fi

# --- gh pr merge ---
if echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+merge'; then
  # --admin sub-guard: break-glass only.
  if echo "$COMMAND" | grep -q '\-\-admin'; then
    if [[ "${BREAK_GLASS_ADMIN:-}" == "1" ]]; then
      echo "BREAK-GLASS: --admin merge authorized by human." >&2
      exit 0
    fi
    echo "BLOCKED: --admin merge requires explicit human authorization." >&2
    echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1." >&2
    exit 2
  fi

  # Non-admin merge sub-guard: if the target PR has
  # `needs-external-review`, require CODEX_CLEARED=1.
  #
  # Step 1: Tokenize the command with shell-quote awareness.
  #
  # An earlier iteration used `TOKENS=( $COMMAND )` which performs
  # bash word splitting on whitespace WITHOUT respecting shell
  # quotes. nathanpayne-codex caught the resulting bug on PR #66
  # round 2: `gh pr merge --body "hello world" 65` would split into
  # (gh, pr, merge, --body, "hello, world", 65), and the SKIP_NEXT
  # logic for value-taking flags would consume `"hello` as the
  # body value while `world"` would leak through as the
  # PR_SELECTOR — wrong PR's labels inspected, false-clear / false-
  # block possible.
  #
  # Fix: use `xargs -n 1` which honors POSIX single/double quoting
  # when splitting input into args. The same command above
  # tokenizes to (gh, pr, merge, --body, hello world, 65) — quotes
  # stripped, value preserved as one token — which the value-flag
  # SKIP logic then consumes correctly.
  #
  # Fails CLOSED on tokenization error (unmatched quote, bad
  # backslash escape, etc.). The agent should fix the malformed
  # command and retry.
  TOKENS_OUTPUT=""
  if ! TOKENS_OUTPUT=$(printf '%s' "$COMMAND" | xargs -n 1 2>&1); then
    echo "BLOCKED: gh-pr-guard could not tokenize the merge command (malformed shell quoting)." >&2
    echo "  command: $COMMAND" >&2
    echo "  xargs error: $TOKENS_OUTPUT" >&2
    echo "  Fix the quoting and retry, or use BREAK_GLASS_ADMIN=1 + --admin." >&2
    exit 2
  fi
  # `mapfile` would be cleaner but is a bash 4+ builtin; macOS ships
  # bash 3.2 by default, so use a portable read loop instead.
  #
  # Empty lines are PRESERVED (not skipped). xargs emits an empty
  # line for legitimate empty-string args like `--body ""`, and the
  # SKIP_NEXT_AS logic below needs to consume that empty value as
  # the flag's value — otherwise the next token (the actual
  # selector) would be wrongly captured as the flag value.
  TOKENS=()
  while IFS= read -r line; do
    TOKENS+=("$line")
  done <<<"$TOKENS_OUTPUT"

  # Step 2: Extract PR_SELECTOR and REPO_ARG in one pass over the
  # tokenized command.
  #
  # `gh pr merge` accepts `<number> | <url> | <branch>` per the gh
  # CLI grammar, so the selector can be any of:
  #
  #   - A bare integer:      gh pr merge 65
  #   - A full PR URL:       gh pr merge https://github.com/foo/bar/pull/65
  #   - A branch name:       gh pr merge feat/my-branch
  #
  # Walk the tokens after `merge` looking for the first non-flag
  # token (PR_SELECTOR), skipping value-taking flags and their
  # values. Simultaneously capture --repo / -R values into
  # REPO_ARG so the label lookup is unambiguous when invoked
  # outside the target repo's working copy. CodeRabbit caught the
  # earlier `-R`-not-handled bug on PR #66 round 2.
  #
  # Value-taking flags handled here mirror the `gh pr merge --help`
  # flag list. Boolean flags (--squash, --merge, --rebase, --admin,
  # --auto, --delete-branch, --disable-auto) do NOT need entries —
  # they don't consume the next token.
  #
  # Inline-value forms (`--body=text`, `-b=text`, `--repo=foo/bar`,
  # `-R=foo/bar`) are single tokens after xargs and are matched by
  # explicit case branches below.
  #
  # If no selector is present (i.e., `gh pr merge` with only flags
  # or no arguments at all), the hook falls back to `gh pr view`
  # with no positional argument so gh resolves the PR from the
  # current branch, matching gh's own default behavior.
  PR_SELECTOR=""
  REPO_ARG=""
  FOUND_MERGE=0
  SKIP_NEXT_AS=""  # "" | "skip" | "repo"
  for tok in "${TOKENS[@]}"; do
    if [[ "$SKIP_NEXT_AS" == "skip" ]]; then
      SKIP_NEXT_AS=""
      continue
    fi
    if [[ "$SKIP_NEXT_AS" == "repo" ]]; then
      REPO_ARG="$tok"
      SKIP_NEXT_AS=""
      continue
    fi
    if [[ "$FOUND_MERGE" -eq 1 ]]; then
      case "$tok" in
        --repo|-R)
          SKIP_NEXT_AS="repo"
          continue
          ;;
        --repo=*)
          REPO_ARG="${tok#--repo=}"
          continue
          ;;
        -R=*)
          REPO_ARG="${tok#-R=}"
          continue
          ;;
        --body|-b|--body-file|-F|--subject|-t|--author-email|-A|--match-head-commit)
          SKIP_NEXT_AS="skip"
          continue
          ;;
      esac
      if [[ "$tok" == -* ]]; then
        continue
      fi
      # First non-flag token after `merge` is the selector. Don't
      # `break` — keep walking so a `--repo` / `-R` flag appearing
      # AFTER the selector still gets captured into REPO_ARG.
      if [[ -z "$PR_SELECTOR" ]]; then
        PR_SELECTOR="$tok"
      fi
      continue
    fi
    if [[ "$tok" == "merge" ]]; then
      FOUND_MERGE=1
    fi
  done

  # Fetch labels. `gh pr view` with no positional argument resolves
  # the PR from the current branch; with a positional argument it
  # accepts number / URL / branch forms identically to gh pr merge.
  GH_ARGS=(pr view --json labels --jq '[.labels[].name] | join(",")')
  if [[ -n "$PR_SELECTOR" ]]; then
    GH_ARGS=(pr view "$PR_SELECTOR" --json labels --jq '[.labels[].name] | join(",")')
  fi
  if [[ -n "$REPO_ARG" ]]; then
    GH_ARGS+=(--repo "$REPO_ARG")
  fi

  if ! LABELS=$(gh "${GH_ARGS[@]}" 2>&1); then
    echo "BLOCKED: gh-pr-guard could not fetch PR labels to verify merge-gate clearance." >&2
    echo "  error: $LABELS" >&2
    echo "  command: gh ${GH_ARGS[*]}" >&2
    echo "  Fix the underlying gh/auth issue and retry, or set BREAK_GLASS_ADMIN=1 + use --admin if this is a break-glass merge." >&2
    exit 2
  fi

  case ",$LABELS," in
    *,needs-external-review,*)
      if [[ "${CODEX_CLEARED:-}" != "1" ]]; then
        echo "BLOCKED: PR carries 'needs-external-review' and CODEX_CLEARED is not set." >&2
        echo "  Phase 4a merge gate: run 'scripts/codex-review-check.sh <PR#>' first." >&2
        echo "  When it exits 0, retry this merge with CODEX_CLEARED=1 prefixed." >&2
        echo "  See REVIEW_POLICY.md § Phase 4a for the full flow." >&2
        exit 2
      fi
      echo "CODEX_CLEARED=1 set; PR is labeled needs-external-review but agent claims merge-gate has passed." >&2
      ;;
  esac
fi

exit 0
