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
# Architecture notes:
#
#   The hook does ALL its parsing on a tokenized form of the
#   command produced by `xargs -n 1`, which honors POSIX shell
#   quoting. Earlier iterations used substring `grep` on the raw
#   command string and were buggy in two correlated ways:
#
#     1. nathanpayne-codex caught (PR #66 round 2) that
#        `TOKENS=( $COMMAND )` performed bash word splitting that
#        ignored shell quotes — `gh pr merge --body "hello world"
#        65` would split into (gh, pr, merge, --body, "hello,
#        world", 65) and confuse the value-flag SKIP logic.
#
#     2. nathanpayne-codex caught (PR #66 round 3) that the
#        top-level matcher `^\s*gh\s+pr\s+(create|merge)` only
#        recognized the bare form. gh accepts a global -R/--repo
#        flag BEFORE the subcommand: `gh -R foo/bar pr merge 65`
#        and `gh --repo foo/bar pr create ...` would bypass the
#        hook entirely.
#
#   Both bugs trace to the same shape — substring matching on a
#   string of unknown structure. The fix is to tokenize once at
#   the top with quote awareness, walk the tokens to identify the
#   pr subcommand (capturing any global -R/--repo along the way),
#   and reuse the same TOKENS array in the create and merge
#   branches.
#
# Design notes:
#
#   - The CODEX_CLEARED check is a hook-layer defense-in-depth.
#     The authoritative merge gate is scripts/codex-review-check.sh;
#     the hook only verifies the agent claims to have run it. An
#     agent that sets CODEX_CLEARED=1 without actually running the
#     check is violating policy — the hook is not an integrity
#     check, it is an ordering check.
#
#   - PR selector is parsed from the command tokens: first non-flag
#     positional argument after `merge`. Accepts <number> | <url> |
#     <branch> per the gh CLI grammar. If no selector is present,
#     the hook falls back to `gh pr view --json labels` with no
#     positional so gh resolves the PR from the current branch.
#
#   - Label lookup calls the GitHub API. This is a side effect of
#     the hook but consistent with the agent's own label-check
#     behavior elsewhere in the policy flow. Failure to reach the
#     API (offline, auth issue) fails CLOSED with a diagnostic.
#
#   - Bash 3.2 portability: macOS ships bash 3.2 by default. The
#     hook avoids bash 4+ features (no `mapfile`, no `[[ =~ ]]` in
#     places where `[[ == ]]` works, etc.).
#
# Limitations (documented as known gaps):
#
#   - Backslash escapes inside double-quoted strings (`"with
#     \"escape\""`) are not handled by xargs and will fail closed
#     with the tokenization error.
#
#   - Custom gh aliases (`gh alias set merge ...`) that expand
#     `merge` to something else are not recognized — the hook
#     guards a specific literal command grammar.
#
#   - Unknown global flags (anything other than `-R/--repo` and
#     boolean flags like `--help`/`--version`) are assumed boolean.
#     If gh adds new value-taking globals, the hook needs an
#     update; misclassifying them as boolean would let the next
#     token leak through as the subcommand.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit if not a gh command at all.
if ! echo "$COMMAND" | grep -qE '^\s*gh(\s|$)'; then
  exit 0
fi

# --- tokenize the command with shell-quote awareness ---
#
# xargs honors POSIX single and double quoting. `gh pr merge
# --body "hello world" 65` tokenizes correctly to (gh, pr, merge,
# --body, hello world, 65) instead of being naively split into
# (gh, pr, merge, --body, "hello, world", 65).
#
# Fails CLOSED on tokenization error (unmatched quote, bad escape).
# An agent should fix the malformed command and retry.
TOKENS_OUTPUT=""
if ! TOKENS_OUTPUT=$(printf '%s' "$COMMAND" | xargs -n 1 2>&1); then
  echo "BLOCKED: gh-pr-guard could not tokenize the gh command (malformed shell quoting)." >&2
  echo "  command: $COMMAND" >&2
  echo "  xargs error: $TOKENS_OUTPUT" >&2
  echo "  Fix the quoting and retry, or use BREAK_GLASS_ADMIN=1 + --admin." >&2
  exit 2
fi
# Portable read loop in lieu of bash 4+ `mapfile`. Empty lines
# preserved so legitimate empty arg values like `--body ""` are
# consumed correctly by downstream SKIP_NEXT_AS logic.
TOKENS=()
while IFS= read -r line; do
  TOKENS+=("$line")
done <<<"$TOKENS_OUTPUT"

# --- detect the pr subcommand, capturing any global -R/--repo ---
#
# Walk tokens from `gh` looking for `pr`. Tokens between `gh` and
# `pr` are global flags. The only global value-taking flag we
# explicitly handle is `-R/--repo`; everything else starting with
# `-` is assumed boolean and skipped. Once `pr` is found, the very
# next token is the subcommand (`create`, `merge`, `view`, etc.).
GLOBAL_REPO=""
PR_SUBCOMMAND=""
SAW_GH=0
SAW_PR=0
SKIP_GLOBAL_AS=""  # "" | "repo"
for tok in "${TOKENS[@]}"; do
  if [ "$SKIP_GLOBAL_AS" = "repo" ]; then
    GLOBAL_REPO="$tok"
    SKIP_GLOBAL_AS=""
    continue
  fi
  if [ "$SAW_GH" -eq 0 ]; then
    if [ "$tok" = "gh" ]; then
      SAW_GH=1
    fi
    continue
  fi
  if [ "$SAW_PR" -eq 0 ]; then
    case "$tok" in
      pr)
        SAW_PR=1
        continue
        ;;
      -R|--repo)
        SKIP_GLOBAL_AS="repo"
        continue
        ;;
      -R=*)
        GLOBAL_REPO="${tok#-R=}"
        continue
        ;;
      --repo=*)
        GLOBAL_REPO="${tok#--repo=}"
        continue
        ;;
      -*)
        # Unknown global flag — assume boolean (--help, --version,
        # etc.) and skip. See "Limitations" in the header for the
        # caveat about future value-taking globals.
        continue
        ;;
      *)
        # Non-flag, non-pr token before `pr`. Either gh aliases
        # are in play (out of scope) or the command isn't a `gh
        # pr` invocation. Allow.
        exit 0
        ;;
    esac
  fi
  # SAW_PR=1 — this token IS the pr subcommand.
  PR_SUBCOMMAND="$tok"
  break
done

# Not a pr create/merge command? Allow.
if [ "$PR_SUBCOMMAND" != "create" ] && [ "$PR_SUBCOMMAND" != "merge" ]; then
  exit 0
fi

# --- gh pr create ---
#
# Substring grep on the raw command is fine here — the body markers
# `Authoring-Agent:` and `## Self-Review` are content checks, not
# structural ones, and they don't depend on argument positions or
# global flags.
if [ "$PR_SUBCOMMAND" = "create" ]; then
  MISSING=""

  if ! echo "$COMMAND" | grep -qi 'Authoring-Agent:'; then
    MISSING="${MISSING}  - Missing 'Authoring-Agent:' in PR body\n"
  fi

  if ! echo "$COMMAND" | grep -qi '## Self-Review'; then
    MISSING="${MISSING}  - Missing '## Self-Review' section in PR body\n"
  fi

  if [ -n "$MISSING" ]; then
    echo "BLOCKED: PR description is missing required sections per REVIEW_POLICY.md:" >&2
    echo -e "$MISSING" >&2
    echo "Add these to the PR body before creating." >&2
    exit 2
  fi

  exit 0
fi

# --- gh pr merge ---
#
# (PR_SUBCOMMAND must be "merge" by this point.)

# --admin sub-guard: break-glass only. We grep the raw command for
# `--admin` because the position doesn't matter and the token walk
# below would also catch it; substring is simpler.
if echo "$COMMAND" | grep -q '\-\-admin'; then
  if [ "${BREAK_GLASS_ADMIN:-}" = "1" ]; then
    echo "BREAK-GLASS: --admin merge authorized by human." >&2
    exit 0
  fi
  echo "BLOCKED: --admin merge requires explicit human authorization." >&2
  echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1." >&2
  exit 2
fi

# Non-admin merge sub-guard: extract PR_SELECTOR and subcommand-
# scoped REPO_ARG by walking tokens AFTER the literal `merge`
# subcommand token. This walk handles value-taking flags
# (--body / --body-file / --subject / --author-email /
# --match-head-commit / --repo) so their values are not mistaken
# for the selector.
#
# `gh pr merge` accepts the selector as <number> | <url> | <branch>;
# we don't parse or validate the form, just pass it through to
# `gh pr view` which accepts the same grammar.
PR_SELECTOR=""
REPO_ARG=""
FOUND_MERGE=0
SKIP_NEXT_AS=""  # "" | "skip" | "repo"
for tok in "${TOKENS[@]}"; do
  if [ "$SKIP_NEXT_AS" = "skip" ]; then
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$SKIP_NEXT_AS" = "repo" ]; then
    REPO_ARG="$tok"
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$FOUND_MERGE" -eq 1 ]; then
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
    case "$tok" in
      -*)
        continue
        ;;
    esac
    # First non-flag token after `merge` is the selector. Don't
    # break — keep walking so a `--repo`/`-R` flag appearing AFTER
    # the selector still gets captured into REPO_ARG.
    if [ -z "$PR_SELECTOR" ]; then
      PR_SELECTOR="$tok"
    fi
    continue
  fi
  if [ "$tok" = "merge" ]; then
    FOUND_MERGE=1
  fi
done

# Subcommand-scoped REPO_ARG wins over global GLOBAL_REPO (mirrors
# gh's typical "more specific flag wins" behavior). Fall back to
# the global value only if the subcommand didn't specify one.
if [ -z "$REPO_ARG" ] && [ -n "$GLOBAL_REPO" ]; then
  REPO_ARG="$GLOBAL_REPO"
fi

# Fetch labels. `gh pr view` with no positional argument resolves
# the PR from the current branch; with a positional argument it
# accepts number / URL / branch forms identically to gh pr merge.
GH_ARGS=(pr view --json labels --jq '[.labels[].name] | join(",")')
if [ -n "$PR_SELECTOR" ]; then
  GH_ARGS=(pr view "$PR_SELECTOR" --json labels --jq '[.labels[].name] | join(",")')
fi
if [ -n "$REPO_ARG" ]; then
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
    if [ "${CODEX_CLEARED:-}" != "1" ]; then
      echo "BLOCKED: PR carries 'needs-external-review' and CODEX_CLEARED is not set." >&2
      echo "  Phase 4a merge gate: run 'scripts/codex-review-check.sh <PR#>' first." >&2
      echo "  When it exits 0, retry this merge with CODEX_CLEARED=1 prefixed." >&2
      echo "  See REVIEW_POLICY.md § Phase 4a for the full flow." >&2
      exit 2
    fi
    echo "CODEX_CLEARED=1 set; PR is labeled needs-external-review but agent claims merge-gate has passed." >&2
    ;;
esac

exit 0
