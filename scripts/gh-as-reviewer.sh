#!/usr/bin/env bash
# scripts/gh-as-reviewer.sh
#
# Run a `gh` command under the REVIEWER identity (the agent identity,
# e.g. nathanpayne-claude), then restore the previously-active gh
# keyring account. Companion to scripts/gh-as-author.sh — same trap-
# EXIT pattern, same prior-active detection via `gh config get`, but
# switches to the reviewer identity instead.
#
# Usage:
#   GH_AS_REVIEWER_IDENTITY=nathanpayne-claude \
#     scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "..."
#
# Environment:
#   GH_AS_REVIEWER_IDENTITY   reviewer identity to switch to.
#                             Default: nathanpayne-claude
#
# On most agent machines the reviewer identity is ALREADY the active
# account per the CLAUDE.md convention, so this wrapper is mostly a
# no-op (switches to itself, runs the command, switches back to
# itself). The value is for the inverse case — an agent in the
# middle of an author-identity flow (e.g. just finished a wrapped
# `gh pr create`) who needs to post a reviewer comment WITHOUT
# leaving the keyring in a wrong state on return.
#
# Exit codes mirror gh-as-author.sh except there is no post-create
# verification (the reviewer wrapper is not the canonical path for
# pr create).
#
# Bash 3.2 compatible (macOS default).

set -euo pipefail

# Clear any ambient GH_TOKEN / GITHUB_TOKEN before doing anything.
# `gh` prioritizes a set GH_TOKEN / GITHUB_TOKEN over the account
# selected by `gh auth switch -u`, so an exported token in the
# caller's shell would silently override the keyring switch below
# and run the wrapped command under the wrong identity. Unsetting
# makes the switch authoritative — same fix shape as
# scripts/gh-as-author.sh. (CodeRabbit Major, #271/#272.)
unset GH_TOKEN GITHUB_TOKEN

REVIEWER="${GH_AS_REVIEWER_IDENTITY:-nathanpayne-claude}"

PRIOR=$(gh config get -h github.com user 2>/dev/null || echo "")
if [ -z "$PRIOR" ]; then
  echo "gh-as-reviewer: could not determine prior active gh account (gh config get -h github.com user returned empty)" >&2
  echo "gh-as-reviewer: refusing to proceed; running the wrapped command without a recorded prior account would leave the keyring in an unknown state on switch-back." >&2
  exit 1
fi

restore_prior() {
  if ! gh auth switch -u "$PRIOR" >/dev/null 2>&1; then
    echo "gh-as-reviewer: WARNING failed to restore prior active account ($PRIOR). Run 'gh auth switch -u $PRIOR' manually to recover." >&2
  fi
}
trap 'restore_prior' EXIT

if ! gh auth switch -u "$REVIEWER" >/dev/null 2>&1; then
  echo "gh-as-reviewer: gh auth switch -u $REVIEWER failed. Is $REVIEWER in the keyring? Run 'gh auth login' once for that identity." >&2
  exit 2
fi

[ "${1:-}" = "--" ] && shift

# Fail fast on an empty wrapped command. Without this, `"$@"` below
# expands to nothing, runs successfully (a no-op), and the wrapper
# exits 0 — hiding a caller bug behind a false success. (CodeRabbit
# Major, #272.)
if [ "$#" -eq 0 ]; then
  echo "gh-as-reviewer: no wrapped command given." >&2
  echo "gh-as-reviewer: usage: scripts/gh-as-reviewer.sh -- gh pr review ..." >&2
  exit 1
fi

# Run the wrapped command in THIS shell (NOT exec) so the EXIT trap
# still fires and restores $PRIOR. `exec "$@"` would replace the
# bash process with the wrapped command, dropping the trap and
# leaving the keyring stuck on $REVIEWER. Capture and propagate the
# wrapped command's exit code so callers see the same rc they would
# from running the command directly. Same fix shape as
# scripts/gh-as-author.sh.
set +e
"$@"
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
