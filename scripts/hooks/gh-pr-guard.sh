#!/usr/bin/env bash
# gh-pr-guard.sh — PreToolUse hook for Claude Code
#
# Gates four operations:
#   1. gh pr create — blocks unless (a) the keyring's active gh
#      account is the AUTHOR identity (nathanjohnpayne by default;
#      override via GH_PR_GUARD_EXPECTED_AUTHOR), AND (b) the command
#      text includes "Authoring-Agent:" and "## Self-Review". The
#      identity check (#241) prevents the split-invocation footgun
#      where a `gh auth switch` in one Bash tool call drifts before
#      the `gh pr create` in a subsequent call, landing the PR under
#      the wrong account. Canonical fix is to use
#      scripts/gh-as-author.sh which wraps switch + create + switch-
#      back in one bash process.
#   2. gh pr merge --admin — blocks unless BREAK_GLASS_ADMIN=1
#      (human must explicitly authorize in chat)
#   3. gh pr merge (any flavor) — blocks when the target PR's
#      `mergeStateStatus` is BLOCKED / DIRTY / UNSTABLE / BEHIND /
#      DRAFT (or any unrecognized future value) unless
#      BREAK_GLASS_MERGE_STATE=1. This is the defense-in-depth
#      layer behind GitHub branch protection — see #170 / #171 for
#      the merge-gate gap this closes (a PR can otherwise be merged
#      with failing CI because nothing in the merge path actually
#      blocks). Originated downstream (matchline #170/#171) and is
#      unified into the canonical hook here so propagation no longer
#      clobbers the feature — see the propagation-wave retro.
#   4. gh pr merge (non-admin) — blocks when the target PR carries
#      the `needs-external-review` label unless CODEX_CLEARED=1
#      (agent must have just run scripts/codex-review-check.sh
#      successfully). This enforces REVIEW_POLICY.md § Phase 4a
#      merge gate at the hook layer so an agent can't accidentally
#      merge past Label Gate by removing the label without running
#      the gate check first.
#
# The identity check (1a) honors a
# BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1 escape hatch for tests
# that PATH-shim gh and have no real keyring. Production code should
# never set this — the wrapper script gh-as-author.sh switches to the
# author identity BEFORE the gh pr create call lands, so the check
# passes naturally without the bypass.
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
# Inline environment assignments:
#
#   The bash form `VAR=value command args` sets VAR in the spawned
#   command's environment but NOT in the hook process. The PreToolUse
#   hook fires before bash executes the command, so it can't read
#   inline-prefixed env vars from its own ${VAR} expansion. The
#   documented happy paths use exactly this form:
#
#     CODEX_CLEARED=1 gh pr merge 65 --squash --delete-branch
#     BREAK_GLASS_ADMIN=1 gh pr merge --admin 65 ...
#
#   So the hook must parse env assignments out of the command string
#   before the `gh` token and treat them as if they were exported.
#   nathanpayne-codex caught the bypass on PR #66 round 4: with the
#   round-3 hook, both forms hit the early `^\s*gh(\s|$)` matcher,
#   missed it, and exited 0 before any guard ran.
#
#   Round 4 fix: the early matcher now allows leading prefix material
#   before `gh`, and the top-level token walk captures CODEX_CLEARED
#   and BREAK_GLASS_ADMIN from the pre-gh tokens into INLINE_ vars.
#   The merge guard then uses these as fallbacks if the hook's own
#   environment doesn't have the corresponding variable set via
#   `export`.
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
#
#   - Other env vars in the inline prefix (anything other than
#     CODEX_CLEARED and BREAK_GLASS_ADMIN) are skipped without
#     interpretation. This is fine because no other env var is
#     consulted by hook policy decisions.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit if there's no `gh` token in the command at all. This
# uses a whitespace-bounded match rather than `^\s*gh` so that
# leading prefix material (env assignments, `eval`, `time`, `sudo`,
# compound separators like `;` followed by a space) doesn't bypass
# the hook entirely. False positives where `gh` appears in the
# middle of an unrelated command are caught downstream by the token
# walk, which exits 0 if no `gh pr (create|merge)` subcommand is
# present.
if ! echo "$COMMAND" | grep -qE '(^|\s)gh(\s|$)'; then
  exit 0
fi

# --- tokenize the command with shell-quote awareness ---
#
# Use python3 shlex.split which honors POSIX single and double
# quoting AND handles multi-line quoted strings. `gh pr merge
# --body "hello world" 65` tokenizes correctly to (gh, pr, merge,
# --body, hello world, 65), and `gh pr create --body "Authoring-
# Agent: claude\n## Self-Review\nok"` (with literal newlines in
# the body) also tokenizes correctly because shlex.split treats
# newlines inside quotes as literal characters, not as token
# separators.
#
# Earlier versions used `xargs -n 1` (with the implicit `echo`
# command), which:
#   - Silently drops -n / -e / -E (echo's own flags). Codex caught
#     this on PR #66 round 6 and the workaround was `xargs -n 1
#     printf '%s\n'`.
#   - Treats embedded newlines as token separators, breaking
#     valid `gh pr create --body "...multiline..."` invocations.
#     Codex caught this on nathanpaynedotcom propagation PR #180
#     round 4. xargs has no flag to disable this behavior; the
#     fix is to switch tokenizers entirely.
#
# python3 is available on macOS 12+ by default and on every Linux
# distro the agent flow runs on. Python startup cost is ~50ms per
# invocation; acceptable for a hook that already does an API call.
#
# Fails CLOSED on tokenization error (unmatched quote, bad escape).
# An agent should fix the malformed command and retry.
#
# python3 emits tokens NUL-delimited so bash's read -d '' can
# preserve embedded newlines. The output goes via a tempfile
# rather than $(...) command substitution because bash command
# substitution silently strips NUL bytes from its capture buffer,
# which would re-jam all tokens together. Earlier versions used
# newline-delimited output via print(tok), which silently SPLIT
# any token containing a literal newline (e.g., the body of a
# `gh pr create --body "Authoring-Agent: claude\n## Self-Review
# \nok"`) into multiple bash tokens. Codex caught the bash-side
# split on nathanpaynedotcom propagation PR #180 round 5.
TMP_TOKENS=$(mktemp)
TMP_TOKENS_ERR=$(mktemp)
trap 'rm -f "$TMP_TOKENS" "$TMP_TOKENS_ERR"' EXIT
# The python preprocessor first converts UNQUOTED newlines into `;`
# command separators (so that multi-command inputs like
# `echo ok\ngh pr merge 123 --admin` are split into two commands)
# while preserving QUOTED newlines as literal characters in the
# token (so that `gh pr create --body "line1\nline2"` keeps the
# body as one token). Codex caught the unquoted-newline collapse
# on swipewatch propagation PR #33 round 6 — privilege escalation
# via newline-separated prefix command was the same shape as the
# round-5 echo-prefix env spoof, just on a different separator.
if ! printf '%s' "$COMMAND" | python3 -c '
import sys, shlex

def normalize_unquoted_newlines(cmd):
    """Replace newlines OUTSIDE of single/double quotes with `; `.
    Preserves newlines inside quoted strings as literal characters."""
    out = []
    in_single = False
    in_double = False
    i = 0
    while i < len(cmd):
        c = cmd[i]
        # Handle backslash-escaped char in double quotes / unquoted
        if c == "\\" and not in_single and i + 1 < len(cmd):
            out.append(c)
            out.append(cmd[i + 1])
            i += 2
            continue
        # chr(39) is a single quote; using chr() avoids embedding a
        # literal single quote inside the bash heredoc (which would
        # break the python3 -c '...' surrounding quote).
        if c == chr(39) and not in_double:
            in_single = not in_single
        elif c == chr(34) and not in_single:
            in_double = not in_double
        elif c == "\n" and not in_single and not in_double:
            # Pad with spaces on BOTH sides so shlex parses the
            # `;` as its own token rather than gluing it to the
            # preceding word (e.g. "ok;" instead of "ok" + ";").
            out.append(" ; ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)

try:
    cmd = sys.stdin.read()
    cmd = normalize_unquoted_newlines(cmd)
    for tok in shlex.split(cmd):
        sys.stdout.buffer.write(tok.encode("utf-8", errors="replace") + b"\x00")
except ValueError as e:
    print(f"shlex error: {e}", file=sys.stderr)
    sys.exit(1)
' > "$TMP_TOKENS" 2> "$TMP_TOKENS_ERR"; then
  echo "BLOCKED: gh-pr-guard could not tokenize the gh command (malformed shell quoting)." >&2
  echo "  command: $COMMAND" >&2
  echo "  shlex error: $(cat "$TMP_TOKENS_ERR")" >&2
  echo "  Fix the quoting and retry, or use BREAK_GLASS_ADMIN=1 + --admin." >&2
  exit 2
fi
# Read NUL-delimited tokens from the tempfile. `read -d ''` means
# "read until NUL". Each iteration appends one whole token,
# preserving any embedded newlines.
TOKENS=()
while IFS= read -r -d '' tok; do
  TOKENS+=("$tok")
done < "$TMP_TOKENS"

# --- detect the pr subcommand, capturing any global -R/--repo ---
#
# Walk tokens to find `gh` IN COMMAND POSITION, then identify the
# subcommand and any global -R/--repo. The pre-gh walk runs as a
# small state machine so we don't blindly skip ANY pre-gh token —
# round 5 had that bug, and nathanpayne-codex caught that
# `echo gh pr merge 66` and `printf %s gh pr merge 66` were treated
# as real merges.
#
# State machine:
#
#   AT_COMMAND_POSITION (initial state):
#     The next token is either the command name or a continuation
#     that keeps us in command position. Allowed continuations:
#       - env assignments         VAR=value
#       - prefix commands         sudo, eval, time, nohup, env,
#                                 command, exec, nice, ionice
#       - flags of those prefixes -X
#       - compound separators     ;  &&  ||  |  &  (
#       - gh                      → transition to phase 2
#     Any other token is treated as the START of a non-gh command,
#     and we transition to IN_UNRELATED_ARGS to skip its arguments.
#
#   IN_UNRELATED_ARGS:
#     We're walking the arguments of a non-gh command. Skip
#     everything until we hit a compound separator, at which point
#     we're back in command position. End-of-input without finding
#     gh in command position falls through to the post-walk check
#     and exits 0.
#
# Tokens BEFORE `gh` (in either state) that match an env assignment
# pattern are also captured into INLINE_CODEX_CLEARED /
# INLINE_BREAK_GLASS_ADMIN, even when in IN_UNRELATED_ARGS — the
# inline-env-prefix support from round 5 should keep working
# regardless of whether the env assignment turns out to be for a
# gh command or some other command. (Capturing for non-gh commands
# is harmless: the EFFECTIVE_* values are only consulted by the
# create/merge guards, which only run when SAW_GH=1.)
#
# Tokens BETWEEN `gh` and `pr` are global gh flags. The only global
# value-taking flag we explicitly handle is -R/--repo; everything
# else starting with - is assumed boolean and skipped.
INLINE_CODEX_CLEARED=""
INLINE_BREAK_GLASS_ADMIN=""
INLINE_BREAK_GLASS_MERGE_STATE=""
GLOBAL_REPO=""
PR_SUBCOMMAND=""
PR_SUBCOMMAND_INDEX=-1    # index in TOKENS where the gh pr subcommand was found
SAW_GH=0
SAW_PR=0
SKIP_GLOBAL_AS=""        # "" | "repo"
AT_COMMAND_POSITION=1    # 1 = at command position, 0 = walking unrelated-command args
SEGMENT_HAS_COMMAND=0    # 1 = this segment has seen a non-assignment command (echo, cat, etc.)
SKIP_PREFIX_VALUE=0      # 1 = next token is the value of a prefix-command flag
CURRENT_PREFIX=""        # name of the most recently seen prefix command (sudo/time/etc.)
for i in "${!TOKENS[@]}"; do
  tok="${TOKENS[$i]}"
  # --- phase 2: walking after gh, looking for pr + subcommand ---
  if [ "$SAW_GH" -eq 1 ]; then
    if [ "$SKIP_GLOBAL_AS" = "repo" ]; then
      GLOBAL_REPO="$tok"
      SKIP_GLOBAL_AS=""
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
          # Unknown global flag — assume boolean (--help,
          # --version, etc.) and skip. See "Limitations" in the
          # header for the caveat about future value-taking
          # globals.
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
    PR_SUBCOMMAND_INDEX=$i
    break
  fi

  # --- phase 1: walking pre-gh, looking for gh in command position ---

  # Consume the value of a prefix-command flag (e.g. the `user`
  # in `sudo -u user gh ...`). Stays in command position because
  # the prefix command may have additional flags or transition
  # straight to the actual command.
  if [ "$SKIP_PREFIX_VALUE" -eq 1 ]; then
    SKIP_PREFIX_VALUE=0
    continue
  fi

  # Compound separators always reset us to command position,
  # whether we were in command position or skipping unrelated
  # args. Only standalone `&&` / `||` / `;` / `|` / `&` / `(`
  # tokens count — separators glommed onto adjacent words by
  # missing whitespace (e.g. `foo;`) are NOT detected, which is
  # an acceptable limitation for the agent flow.
  #
  # IMPORTANT: separator handling MUST run before the env-assignment
  # capture below. Otherwise `echo CODEX_CLEARED=1 ; gh pr merge 65`
  # would capture the literal `CODEX_CLEARED=1` arg of `echo` as a
  # spoofed inline env var even though it never actually gets exported
  # to the gh process. nathanpayne-codex caught this on swipewatch
  # propagation PR #33 round 5 — privilege escalation potential.
  case "$tok" in
    "&&"|"||"|";"|"|"|"&"|"("|")")
      AT_COMMAND_POSITION=1
      CURRENT_PREFIX=""
      # Clear inline env vars ONLY when the segment that just ended
      # contained a non-assignment command. That means the assignment
      # was a PREFIX scoped to that command, not a standalone
      # assignment that persists in the shell:
      #
      #   BREAK_GLASS_ADMIN=1 echo ok ; gh pr merge --admin 65
      #     → segment had `echo` (SEGMENT_HAS_COMMAND=1)
      #     → assignment was prefix to echo → CLEAR at `;`
      #
      #   CODEX_CLEARED=1 && gh pr merge 76 --squash
      #     → segment was ONLY the assignment (SEGMENT_HAS_COMMAND=0)
      #     → standalone assignment → DON'T clear at `&&`
      #
      # nathanpayne-codex caught the over-clearing on template PR #76
      # round 1 — `CODEX_CLEARED=1 && gh pr merge` was being cleared
      # even though the assignment was standalone.
      if [ "$SEGMENT_HAS_COMMAND" -eq 1 ]; then
        INLINE_CODEX_CLEARED=""
        INLINE_BREAK_GLASS_ADMIN=""
        INLINE_BREAK_GLASS_MERGE_STATE=""
      fi
      SEGMENT_HAS_COMMAND=0
      continue
      ;;
  esac

  # Capture inline env assignments ONLY when AT_COMMAND_POSITION=1.
  # Tokens in IN_UNRELATED_ARGS are arguments to an unrelated
  # command (e.g., `echo BREAK_GLASS_ADMIN=1 ; gh pr merge --admin
  # 65`) and do NOT export to the spawned gh process — capturing
  # them would let an agent spoof guard variables by prefixing the
  # command with an echo. Only assignments that are themselves in
  # command position (e.g., `CODEX_CLEARED=1 gh pr merge 65` or
  # `CODEX_CLEARED=1 sudo gh pr merge 65`) count.
  if [ "$AT_COMMAND_POSITION" -eq 1 ]; then
    case "$tok" in
      CODEX_CLEARED=*)
        INLINE_CODEX_CLEARED="${tok#CODEX_CLEARED=}"
        ;;
      BREAK_GLASS_ADMIN=*)
        INLINE_BREAK_GLASS_ADMIN="${tok#BREAK_GLASS_ADMIN=}"
        ;;
      BREAK_GLASS_MERGE_STATE=*)
        INLINE_BREAK_GLASS_MERGE_STATE="${tok#BREAK_GLASS_MERGE_STATE=}"
        ;;
    esac
  fi

  if [ "$AT_COMMAND_POSITION" -eq 0 ]; then
    # Skipping arguments of an unrelated command. Stay until a
    # separator resets us above.
    continue
  fi

  case "$tok" in
    [A-Za-z_]*=*)
      # Env assignment. Stay in command position.
      continue
      ;;
    sudo|eval|time|nohup|env|command|exec|nice|ionice)
      # Known prefix command. Stay in command position so the
      # next non-flag token is still treated as the command.
      # Track which prefix we're parsing flags for so we can
      # tell value-taking flags from boolean ones — short flags
      # like `-p` mean different things to different commands
      # (boolean for time, value-taking for ionice/sudo).
      CURRENT_PREFIX="$tok"
      continue
      ;;
    gh)
      SAW_GH=1
      continue
      ;;
    -*)
      # Flag of the most recently seen prefix command. Whether
      # the next token is a value depends on which prefix command
      # this flag belongs to. Without this distinction, putting
      # `-p` on a generic value-flag list would consume `gh` as
      # the value of `time -p` (which is actually the POSIX
      # boolean format flag), and putting `-p` on a generic
      # boolean list would let `ionice -p PID gh ...` walk past
      # `PID` thinking it's the next command.
      #
      # Per-prefix value-flag map. nathanpayne-codex caught the
      # original bug (sudo -u, time -f, nice -n) on PR #66
      # round 6; the per-prefix scoping prevents the obvious
      # over-fix from breaking `time -p`.
      case "$CURRENT_PREFIX:$tok" in
        sudo:-u|sudo:-g|sudo:-U|sudo:-h|sudo:-p|sudo:-r|sudo:-s|sudo:-t|sudo:-c|sudo:-D)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        time:-f|time:-o)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        nice:-n)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        ionice:-c|ionice:-n|ionice:-p)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        env:-u|env:-S)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
      esac
      # Otherwise: boolean flag of the current prefix (or a flag
      # of an unknown prefix, which we conservatively assume is
      # boolean to avoid eating `gh`). Stay in command position.
      continue
      ;;
    *)
      # An unrelated command (echo, printf, cat, find, etc.).
      # gh-as-an-argument should NOT trigger the hook;
      # transition to skip mode and walk past the args.
      # Mark the segment as having a real command so that
      # separator-clearing of inline env vars fires correctly.
      AT_COMMAND_POSITION=0
      SEGMENT_HAS_COMMAND=1
      continue
      ;;
  esac
done

# Effective env values: hook process env wins (set via `export`),
# inline-prefix value falls back. Both forms are documented; both
# must work.
EFFECTIVE_CODEX_CLEARED="${CODEX_CLEARED:-${INLINE_CODEX_CLEARED:-}}"
EFFECTIVE_BREAK_GLASS_ADMIN="${BREAK_GLASS_ADMIN:-${INLINE_BREAK_GLASS_ADMIN:-}}"
EFFECTIVE_BREAK_GLASS_MERGE_STATE="${BREAK_GLASS_MERGE_STATE:-${INLINE_BREAK_GLASS_MERGE_STATE:-}}"

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
  # Identity check (#241): the keyring's active account must be the
  # AUTHOR identity (nathanjohnpayne) at the moment of `gh pr create`,
  # otherwise the PR is authored by whatever identity IS active —
  # observed concretely on friends-and-family-billing#262 where a
  # split switch / pr-create across two Bash tool calls landed a PR
  # under the wrong identity. The canonical fix is to wrap the entire
  # sequence in `scripts/gh-as-author.sh` so the switch and the create
  # share one bash process.
  #
  # The check uses `gh config get -h github.com user`, NOT `gh auth
  # status`. The latter is GH_TOKEN-poisonable: when GH_TOKEN is set
  # it reports the GH_TOKEN entry as Active, but the keyring entry is
  # still the one that signs writes. `gh config get` reads the
  # keyring config file directly and is the authoritative read for
  # "who will this write attribute to".
  #
  # Escape hatch: `BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1` lets
  # tests and edge cases bypass this check. The check is additive
  # defense-in-depth on top of gh-as-author.sh — when an agent runs
  # `scripts/gh-as-author.sh -- gh pr create ...` correctly, the
  # wrapper has already switched to the author identity by the time
  # this hook fires, so the check passes naturally without the
  # escape. The escape exists for test harnesses that PATH-shim `gh`
  # and have no real keyring to read.
  EXPECTED_AUTHOR="${GH_PR_GUARD_EXPECTED_AUTHOR:-nathanjohnpayne}"
  if [ "${BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK:-0}" != "1" ]; then
    ACTIVE_GH_USER=$(gh config get -h github.com user 2>/dev/null || echo "")
    if [ -z "$ACTIVE_GH_USER" ]; then
      echo "BLOCKED: gh-pr-guard could not read the active gh account from 'gh config get -h github.com user'." >&2
      echo "  Either gh is not installed/authenticated, or the keyring config is corrupt." >&2
      echo "  Run 'gh auth login' for the $EXPECTED_AUTHOR identity, then retry via scripts/gh-as-author.sh." >&2
      exit 2
    fi
    if [ "$ACTIVE_GH_USER" != "$EXPECTED_AUTHOR" ]; then
      echo "BLOCKED: gh pr create is about to run under active account '$ACTIVE_GH_USER', not the expected author identity '$EXPECTED_AUTHOR'." >&2
      echo "" >&2
      echo "  This is the #241 footgun. A PR created right now would be authored by '$ACTIVE_GH_USER'," >&2
      echo "  which breaks self-approval (Can not approve your own pull request) and inverts the" >&2
      echo "  Authoring-Agent: fingerprint in the PR body." >&2
      echo "" >&2
      echo "  Canonical fix: wrap the call in scripts/gh-as-author.sh, which switches to" >&2
      echo "  $EXPECTED_AUTHOR, runs gh pr create, then restores the prior active account via" >&2
      echo "  trap EXIT — all inside one bash process so the switch and the create can't drift apart:" >&2
      echo "" >&2
      echo "    scripts/gh-as-author.sh -- gh pr create --title '...' --body '...'" >&2
      echo "" >&2
      echo "  See REVIEW_POLICY.md § Recovery: PR created under the wrong identity for the case" >&2
      echo "  where a PR already landed under the wrong account." >&2
      exit 2
    fi
  fi

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
# (PR_SUBCOMMAND must be "merge" and PR_SUBCOMMAND_INDEX must point
# to the actual `merge` subcommand token in TOKENS by this point.)
#
# Walk tokens AFTER the literal `merge` subcommand token to extract:
#   - PR_SELECTOR (first non-flag positional)
#   - REPO_ARG (--repo / -R value if present)
#   - ADMIN_REQUESTED (--admin flag)
#
# All three are derived from the SAME tokenized walk so that
# value-taking flags (--body / --body-file / --subject /
# --author-email / --match-head-commit / --repo / -R) correctly
# consume their next token as the value. An earlier round used
# `grep -q -- --admin` on the raw command string for the admin
# check, which over-matched any `--admin` substring inside a
# quoted flag value (e.g., `--subject "--admin follow-up"`).
# nathanpayne-codex caught that on PR #66 round 6.
#
# An even earlier version of this walk used a separate `FOUND_MERGE`
# scan that latched onto the FIRST `merge` token anywhere in the
# command, not specifically the gh-context one. With chained inputs
# like `echo merge ; gh pr merge 65`, the walk would latch onto the
# echo arg and then capture `;` as the selector. Codex caught that
# on the swipewatch propagation PR #33; the fix is to use the
# PR_SUBCOMMAND_INDEX captured during phase 1 as the starting point
# of the merge walk, eliminating the FOUND_MERGE state entirely.
#
# `gh pr merge` accepts the selector as <number> | <url> | <branch>;
# we don't parse or validate the form, just pass it through to
# `gh pr view` which accepts the same grammar.
PR_SELECTOR=""
REPO_ARG=""
ADMIN_REQUESTED=0
SKIP_NEXT_AS=""  # "" | "skip" | "repo"
merge_walk_start=$((PR_SUBCOMMAND_INDEX + 1))
for j in "${!TOKENS[@]}"; do
  if [ "$j" -lt "$merge_walk_start" ]; then
    continue
  fi
  tok="${TOKENS[$j]}"
  if [ "$SKIP_NEXT_AS" = "skip" ]; then
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$SKIP_NEXT_AS" = "repo" ]; then
    REPO_ARG="$tok"
    SKIP_NEXT_AS=""
    continue
  fi
  case "$tok" in
    --admin)
      ADMIN_REQUESTED=1
      continue
      ;;
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
  # First non-flag token after the gh-context `merge` is the
  # selector. Don't break — keep walking so a `--repo`/`-R` flag or
  # `--admin` flag appearing AFTER the selector still gets captured.
  if [ -z "$PR_SELECTOR" ]; then
    PR_SELECTOR="$tok"
  fi
done

# Subcommand-scoped REPO_ARG wins over global GLOBAL_REPO (mirrors
# gh's typical "more specific flag wins" behavior). Fall back to
# the global value only if the subcommand didn't specify one.
if [ -z "$REPO_ARG" ] && [ -n "$GLOBAL_REPO" ]; then
  REPO_ARG="$GLOBAL_REPO"
fi

# Fetch labels AND mergeStateStatus in a single API call. `gh pr
# view` with no positional argument resolves the PR from the
# current branch; with a positional argument it accepts number /
# URL / branch forms identically to gh pr merge.
#
# Output format: mergeStateStatus on line 1, then one label name
# per line (zero or more lines). The `--jq` filter is
# `.mergeStateStatus, .labels[].name` — jq emits each result on
# its own line. NEWLINE-delimited, NOT comma-joined: GitHub label
# names may legally contain commas (and spaces), so a CSV join
# would make the later exact-match label gate ambiguous — a label
# literally named `team,needs-external-review` would be parsed as
# two labels and false-match the real `needs-external-review`
# gate (CodeRabbit caught this on PR #263). Label names cannot
# contain newlines, so one-label-per-line is unambiguous.
#
# #171 / #170 retrospective: pre-this-change the hook fetched
# only labels and let `gh pr merge` run even when GitHub's
# `mergeStateStatus` was BLOCKED (failing CI / active
# CHANGES_REQUESTED). A PR could merge with red CI on every
# matrix cell because nothing in the merge path actually
# blocked. The new check is defense-in-depth behind branch
# protection: even if branch protection is misconfigured or
# disabled for an emergency hotfix, the hook will still refuse
# to dispatch the merge.
GH_JQ='.mergeStateStatus, .labels[].name'
GH_ARGS=(pr view --json labels,mergeStateStatus --jq "$GH_JQ")
if [ -n "$PR_SELECTOR" ]; then
  GH_ARGS=(pr view "$PR_SELECTOR" --json labels,mergeStateStatus --jq "$GH_JQ")
fi
if [ -n "$REPO_ARG" ]; then
  GH_ARGS+=(--repo "$REPO_ARG")
fi

# Capture stdout and stderr separately. Codex P1 on matchline PR
# #174 r2: a `2>&1` form would prepend ANY non-fatal stderr gh
# emitted (update notifier, deprecation warnings, etc.) to the
# stdout payload, then the line-1 `MERGE_STATE` extraction would
# parse that noise as MERGE_STATE — corrupting a CLEAN PR into the
# unrecognized-state block path. Routing stderr to a tempfile
# keeps MERGE_STATE pure. We still surface stderr in the error
# path for diagnostics.
GH_STDERR=$(mktemp)
# Re-declare the EXIT trap so $GH_STDERR is also cleaned up. The
# trap call replaces (not appends) any prior trap; keep all three
# tempfile names listed here so a future edit doesn't drop one.
trap 'rm -f "$TMP_TOKENS" "$TMP_TOKENS_ERR" "$GH_STDERR"' EXIT
if ! GH_OUTPUT=$(gh "${GH_ARGS[@]}" 2>"$GH_STDERR"); then
  echo "BLOCKED: gh-pr-guard could not fetch PR metadata to verify merge-gate clearance." >&2
  if [ -s "$GH_STDERR" ]; then
    echo "  stderr: $(cat "$GH_STDERR")" >&2
  fi
  echo "  command: gh ${GH_ARGS[*]}" >&2
  # The metadata fetch is unconditional and runs BEFORE any break-
  # glass override, so a BREAK_GLASS_* env var cannot bypass this
  # failure — the only fix is restoring gh/auth connectivity. Once
  # that's restored, BREAK_GLASS_MERGE_STATE / BREAK_GLASS_ADMIN
  # are still available downstream if the PR's merge state or admin
  # gate need to be overridden.
  echo "  Fix the underlying gh/auth issue and retry." >&2
  exit 2
fi

# Line 1 is mergeStateStatus; lines 2..N are label names (one per
# line, possibly zero). Empty/missing MERGE_STATE (e.g. transient
# API state) falls into the `*` case below and fails closed.
# LABELS keeps the newline-delimited remainder for the exact-match
# gate further down — never re-join it into a delimited string.
MERGE_STATE=$(printf '%s\n' "$GH_OUTPUT" | sed -n '1p')
LABELS=$(printf '%s\n' "$GH_OUTPUT" | sed -n '2,$p')

# mergeStateStatus check (#171 layer 2). API enum (full set per
# GitHub GraphQL `MergeStateStatus`):
#   CLEAN       — checks pass, no merge conflicts, ready to merge
#   HAS_HOOKS   — branch has post-commit hooks (legacy state)
#   UNKNOWN     — state not yet determined (often transient; allow
#                 rather than wedge on slow API responses)
#   BLOCKED     — required check failing OR active CHANGES_REQUESTED
#                 review
#   DIRTY       — merge conflict
#   UNSTABLE    — non-required check failed
#   BEHIND      — base has commits the head lacks (with "Require
#                 branches to be up to date" enabled)
#   DRAFT       — PR is in draft mode (covered explicitly so the
#                 diagnostic points at the right fix, "mark draft
#                 as ready," not at "update the case statement for
#                 a future state")
#
# Unknown future states (anything not in the case below) fail
# CLOSED — a new GitHub API state shouldn't silently bypass the
# guard. Override with BREAK_GLASS_MERGE_STATE=1 if needed.
case "$MERGE_STATE" in
  CLEAN|HAS_HOOKS|UNKNOWN)
    ;;  # allow
  DRAFT)
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge of draft PR authorized by human." >&2
    else
      echo "BLOCKED: PR is a draft (mergeStateStatus=DRAFT)." >&2
      echo "  Mark the PR as ready for review before merging (gh pr ready <PR#>)." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix)." >&2
      exit 2
    fi
    ;;
  BLOCKED|DIRTY|UNSTABLE|BEHIND)
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge with mergeStateStatus=$MERGE_STATE authorized by human." >&2
    else
      echo "BLOCKED: PR mergeStateStatus is $MERGE_STATE." >&2
      echo "  Resolve required checks / merge conflicts / change requests first." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix; must be authorized by human in chat)." >&2
      echo "  See #170 / #171 for the regression this guard closes." >&2
      exit 2
    fi
    ;;
  *)
    # Unknown state — fail closed with a hint pointing to the
    # case statement above. New API states should be classified
    # explicitly, not absorbed into a default-allow.
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge with unrecognized mergeStateStatus=$MERGE_STATE authorized by human." >&2
    else
      echo "BLOCKED: PR mergeStateStatus=$MERGE_STATE is not recognized by gh-pr-guard." >&2
      echo "  Update the case statement in scripts/hooks/gh-pr-guard.sh to classify it." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix)." >&2
      exit 2
    fi
    ;;
esac

# --admin sub-guard: break-glass only. Now token-based: the walk
# above sets ADMIN_REQUESTED=1 only when `--admin` appears as a
# REAL flag of `merge`, not as a substring of another flag's value.
#
# Ordering note (#171): this guard is evaluated AFTER the
# mergeStateStatus check above. Pre-this-ordering, `--admin +
# BREAK_GLASS_ADMIN=1` exited before the merge-state guard ran —
# meaning an emergency `--admin` merge would silently bypass the
# BLOCKED/DIRTY/UNSTABLE/BEHIND refusal. The two break-glass
# overrides are independent decisions: BREAK_GLASS_ADMIN authorizes
# admin-flag use, BREAK_GLASS_MERGE_STATE authorizes merging despite
# a failing merge state. Requiring both for the worst-case merge
# (admin AND failing CI) is intentional.
if [ "$ADMIN_REQUESTED" -eq 1 ]; then
  if [ "$EFFECTIVE_BREAK_GLASS_ADMIN" = "1" ]; then
    echo "BREAK-GLASS: --admin merge authorized by human." >&2
    exit 0
  fi
  echo "BLOCKED: --admin merge requires explicit human authorization." >&2
  echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1 (export or inline prefix)." >&2
  exit 2
fi

# Exact-match the label gate against the newline-delimited LABELS
# list. `grep -Fxq` = fixed-string, whole-line, quiet — so a label
# literally named `team,needs-external-review` (commas are legal in
# GitHub label names) is its own line and does NOT false-match the
# real `needs-external-review` gate.
if printf '%s\n' "$LABELS" | grep -Fxq "needs-external-review"; then
  if [ "$EFFECTIVE_CODEX_CLEARED" != "1" ]; then
    echo "BLOCKED: PR carries 'needs-external-review' and CODEX_CLEARED is not set." >&2
    echo "  Phase 4a merge gate: run 'scripts/codex-review-check.sh <PR#>' first." >&2
    echo "  When it exits 0, retry this merge with CODEX_CLEARED=1 (export or inline prefix)." >&2
    echo "  See REVIEW_POLICY.md § Phase 4a for the full flow." >&2
    exit 2
  fi
  echo "CODEX_CLEARED=1 set; PR is labeled needs-external-review but agent claims merge-gate has passed." >&2
fi

exit 0
