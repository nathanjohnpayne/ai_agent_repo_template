#!/usr/bin/env bash
# scripts/gh-as-author.sh
#
# Run a `gh` command (typically a write — pr create, pr merge, pr
# edit) under the AUTHOR identity (nathanjohnpayne by default), then
# restore the previously-active gh keyring account. Switches and
# switch-back all happen inside one bash process via `trap EXIT`, so
# even a crash or interrupt between the switch and the wrapped command
# leaves the keyring in a known-good state.
#
# Usage:
#   scripts/gh-as-author.sh -- gh pr create --title ...
#   scripts/gh-as-author.sh -- gh pr merge 123 --squash --delete-branch
#   scripts/gh-as-author.sh -- gh pr edit 123 --add-label foo
#
# The leading `--` is conventional but optional; the script strips it
# before running the wrapped command.
#
# Why this exists (#241):
#
#   The canonical pattern `gh auth switch -u <author> && gh pr create
#   && gh auth switch -u <reviewer>` is correct only when all three
#   commands run inside ONE bash invocation. When an agent splits it
#   across two Bash tool calls (switch in call A; pr create + switch-
#   back in call B), the gh keyring's active account can drift between
#   calls — observed concretely on friends-and-family-billing#262
#   where a `gh pr create` landed under `nathanpayne-claude` despite
#   a preceding `gh auth switch -u nathanjohnpayne` in the prior
#   Bash call. Wrapping the whole sequence in a single script process
#   eliminates the split-invocation failure mode.
#
#   This wrapper is the canonical pattern referenced from CLAUDE.md
#   and REVIEW_POLICY.md.
#
# Verification (#241 mitigation 2):
#
#   When the wrapped command is `gh pr create`, the script also runs
#   a post-create `gh pr view --json author` check on the created PR
#   and exits non-zero if `author.login` does not match the expected
#   author identity. This catches the "PR landed under the wrong
#   identity" failure mode immediately, instead of at the reviewer-
#   approval step ~10 min later.
#
# Environment:
#   GH_AS_AUTHOR_IDENTITY   author identity to switch to.
#                           Default: nathanjohnpayne
#
# Exit codes:
#   0    success (wrapped command exited 0 AND, for gh pr create,
#        author verification passed)
#   1    setup error (could not determine prior active account, etc.)
#   2    switch-to-author failed
#   5    post-create author verification failed (PR landed under
#        wrong identity) OR verification could not complete (PR URL
#        not extractable from gh pr create output / gh pr view failed
#        / empty author.login). Fail-closed: an unverified create
#        is NOT treated as success, so downstream automation can
#        distinguish "verified clean" from "verification skipped".
#   *    propagated from the wrapped command otherwise
#
# Bash 3.2 compatible (macOS default).

set -euo pipefail

# Clear any ambient GH_TOKEN / GITHUB_TOKEN before doing anything.
# This wrapper's entire guarantee is "the wrapped command runs under
# the AUTHOR keyring identity." But `gh` prioritizes a set GH_TOKEN /
# GITHUB_TOKEN over the account selected by `gh auth switch -u` — so
# if a caller has either exported (e.g. a preflight'd shell), the
# `gh auth switch` below would be silently overridden and the wrapped
# command would run under whatever that token resolves to. Unsetting
# them makes the keyring switch authoritative for every `gh` call in
# this process — the wrapped write AND the post-create verification
# read. (CodeRabbit Major, #271/#272.)
unset GH_TOKEN GITHUB_TOKEN

AUTHOR="${GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"

# Capture prior active via `gh config get -h github.com user`, NOT
# `gh auth status`. `gh auth status` is GH_TOKEN-poisonable — when
# GH_TOKEN is set it reports the GH_TOKEN entry as Active even though
# writes still attribute to the keyring entry. CLAUDE.md § Active-
# account convention is explicit about this.
PRIOR=$(gh config get -h github.com user 2>/dev/null || echo "")
if [ -z "$PRIOR" ]; then
  echo "gh-as-author: could not determine prior active gh account (gh config get -h github.com user returned empty)" >&2
  echo "gh-as-author: refusing to proceed; running the wrapped command without a recorded prior account would leave the keyring in an unknown state on switch-back." >&2
  exit 1
fi

# Install the switch-back trap BEFORE the switch-to-author. That way
# if the switch-to-author itself partial-fails, we still attempt to
# restore the prior account. The trap is tolerant of restore failure
# — a stuck-on-author keyring is a louder problem than the wrapped
# command's exit code, so we emit a clear diagnostic but don't
# clobber the exit code.
restore_prior() {
  if ! gh auth switch -u "$PRIOR" >/dev/null 2>&1; then
    echo "gh-as-author: WARNING failed to restore prior active account ($PRIOR). Run 'gh auth switch -u $PRIOR' manually to recover." >&2
  fi
}
trap 'restore_prior' EXIT

if ! gh auth switch -u "$AUTHOR" >/dev/null 2>&1; then
  echo "gh-as-author: gh auth switch -u $AUTHOR failed. Is $AUTHOR in the keyring? Run 'gh auth login' once for that identity." >&2
  exit 2
fi

# Post-switch verification (#284). `gh auth switch` can silently no-op
# in adversarial conditions: a corrupted hosts.yml, a concurrent
# `gh auth switch` racing with this one, or (most commonly) a CI
# environment where the keyring is mocked/stubbed and the switch is a
# no-op. The post-switch read closes the loop: if `gh config get -h
# github.com user` does NOT equal the identity we just asked for,
# fail closed BEFORE running the wrapped write command. This catches
# the silent-failure flavor of the #241 footgun that rc-check alone
# misses.
POST_SWITCH_USER=$(gh config get -h github.com user 2>/dev/null || echo "")
if [ "$POST_SWITCH_USER" != "$AUTHOR" ]; then
  echo "gh-as-author: POST-SWITCH VERIFICATION FAILED." >&2
  echo "gh-as-author:   Requested: gh auth switch -u $AUTHOR" >&2
  echo "gh-as-author:   Actual active after switch: '$POST_SWITCH_USER'" >&2
  echo "gh-as-author:   The switch returned 0 but the keyring's active account is unchanged." >&2
  echo "gh-as-author:   Likely causes: corrupt ~/.config/gh/hosts.yml, a concurrent" >&2
  echo "gh-as-author:   gh auth switch in another process, or a mock 'gh' in PATH that" >&2
  echo "gh-as-author:   silently no-ops auth switch. Investigate before retrying." >&2
  exit 2
fi

# Strip leading `--` if present so callers can use the conventional
# disambiguator `scripts/gh-as-author.sh -- gh pr create ...`.
[ "${1:-}" = "--" ] && shift

# Fail fast on an empty wrapped command. Without this, `"$@"` below
# expands to nothing, runs successfully (a no-op), and the wrapper
# exits 0 — hiding a caller bug (e.g. `gh-as-author.sh --` with the
# command accidentally dropped) behind a false success. (CodeRabbit
# Major, #272.)
if [ "$#" -eq 0 ]; then
  echo "gh-as-author: no wrapped command given." >&2
  echo "gh-as-author: usage: scripts/gh-as-author.sh -- gh pr <create|merge|edit> ..." >&2
  exit 1
fi

# Detect whether the wrapped command is `gh pr create`. argv[0] must
# be `gh` and argv[1] must be `pr` and argv[2] must be `create`. We
# don't try to handle `gh -R foo/bar pr create ...` here — agents
# should use the subcommand-scoped `--repo` flag with this wrapper
# (the gh CLI accepts both forms equivalently). Worst case: a global
# -R/--repo before `pr` slips past the detector, the wrapped command
# still runs correctly, and we just skip the post-create verification.
IS_PR_CREATE=0
if [ "${1:-}" = "gh" ] && [ "${2:-}" = "pr" ] && [ "${3:-}" = "create" ]; then
  IS_PR_CREATE=1
fi

if [ "$IS_PR_CREATE" -eq 1 ]; then
  # Capture stdout so we can extract the PR URL for verification, but
  # also tee it to the operator's terminal so they see the URL gh
  # prints. Stderr is left alone (gh emits progress + errors there).
  TMP_OUT=$(mktemp)
  # `trap` chains — append to the existing EXIT trap (the restore)
  # so the tempfile is cleaned up too.
  trap 'rm -f "$TMP_OUT"; restore_prior' EXIT
  set +e
  "$@" | tee "$TMP_OUT"
  # PIPESTATUS[0] is the wrapped gh's exit code; tee almost always
  # returns 0 so we ignore PIPESTATUS[1].
  WRAPPED_RC=${PIPESTATUS[0]}
  set -e
  if [ "$WRAPPED_RC" -ne 0 ]; then
    exit "$WRAPPED_RC"
  fi

  # Extract the PR URL from the captured output. gh pr create's last
  # line is the URL (https://github.com/owner/repo/pull/N). `basename`
  # on the URL yields the PR number. Use `grep -oE` to find the URL
  # rather than `tail -1` because gh sometimes appends `--web` open
  # diagnostics or other trailing lines.
  PR_URL=$(grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "$TMP_OUT" | tail -1 || true)
  if [ -z "$PR_URL" ]; then
    # Fail closed: a successful `gh pr create` whose URL we cannot
    # extract is NOT verified. Treating it as verified would let
    # downstream automation proceed after the safety check was
    # silently skipped — exactly the #241 footgun this wrapper
    # exists to close. Operator recovery: verify the new PR's
    # author.login manually (`gh pr list --author nathanjohnpayne`).
    echo "gh-as-author: ERROR could not extract PR URL from gh pr create output; refusing to treat the create as verified." >&2
    echo "gh-as-author: The PR may still have been created — check 'gh pr list --author $AUTHOR' and verify manually." >&2
    exit 5
  fi
  PR_NUM=$(basename "$PR_URL")
  # Repo slug is the path component between github.com/ and /pull/N.
  PR_REPO=$(echo "$PR_URL" | sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')

  # Use the active keyring (currently $AUTHOR) for the verification
  # read. We don't pin GH_TOKEN here — the read works under either
  # identity and avoiding the env-var dependency keeps the wrapper
  # standalone.
  ACTUAL_AUTHOR=$(gh pr view "$PR_NUM" --repo "$PR_REPO" --json author --jq .author.login 2>/dev/null || echo "")
  if [ -z "$ACTUAL_AUTHOR" ]; then
    # Fail closed: see PR-URL branch above. Network blips and
    # transient gh errors must NOT be confused with a verified clean
    # create.
    echo "gh-as-author: ERROR could not read PR author from gh pr view $PR_NUM --repo $PR_REPO (network? permissions?); refusing to treat the create as verified." >&2
    echo "gh-as-author: Verify manually: gh pr view $PR_NUM --repo $PR_REPO --json author" >&2
    exit 5
  fi

  if [ "$ACTUAL_AUTHOR" != "$AUTHOR" ]; then
    echo "gh-as-author: ERROR PR #$PR_NUM on $PR_REPO landed under '$ACTUAL_AUTHOR', expected '$AUTHOR'." >&2
    echo "gh-as-author: This is the #241 footgun — gh keyring active-identity glitch." >&2
    echo "gh-as-author: Recovery: close the PR and recreate from the same branch." >&2
    echo "gh-as-author:   gh pr close $PR_NUM --repo $PR_REPO --comment 'Wrong author identity (see #241). Recreating.'" >&2
    echo "gh-as-author:   scripts/gh-as-author.sh -- gh pr create --repo $PR_REPO --title '...' --body '...'" >&2
    echo "gh-as-author: See REVIEW_POLICY.md § Recovery: PR created under the wrong identity." >&2
    exit 5
  fi

  echo "gh-as-author: verified PR #$PR_NUM author=$ACTUAL_AUTHOR (matches expected $AUTHOR)" >&2
  exit 0
fi

# Non-gh-pr-create path: run the wrapped command in this shell (NOT
# exec) so the EXIT trap still fires and restores $PRIOR. Using exec
# would replace the bash process with the wrapped command, dropping
# the trap and leaving the keyring stuck on $AUTHOR — the exact
# state the wrapper exists to prevent. Capture the wrapped command's
# exit code and propagate it so callers see the same rc they would
# from running the command directly.
set +e
"$@"
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
