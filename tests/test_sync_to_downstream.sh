#!/usr/bin/env bash
# tests/test_sync_to_downstream.sh
#
# Validates scripts/sync-to-downstream.sh against synthetic consumer
# fixtures. Builds a temp Mergepath worktree and a temp consumer
# worktree from scratch, points the script at them via the
# MERGEPATH_SIBLINGS_DIR env var, and checks that each manifest path
# type produces the expected status (ok / drift / missing) and the
# right exit code.
#
# Requires: yq (mikefarah/yq v4+), git. Run manually or from CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d -t sync-to-downstream-test)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a minimal "mergepath" with two canonical files and one kit dir
# ---------------------------------------------------------------------------
MP="$WORKDIR/mergepath"
mkdir -p "$MP/scripts/hooks" "$MP/scripts/ci" "$MP/.github/workflows"
echo "canonical-script-v1" >"$MP/scripts/keep-in-sync.sh"
echo "canonical-hook-v1"   >"$MP/scripts/hooks/the-hook.sh"
echo "kit-file-1" >"$MP/scripts/ci/check_one"
echo "kit-file-2" >"$MP/scripts/ci/check_two"

cat >"$MP/.mergepath-sync.yml" <<'EOF'
version: 1
consumers:
  - {name: clean-consumer,  repo: x/clean-consumer}
  - {name: drifted,         repo: x/drifted}
  - {name: missing-everything, repo: x/missing-everything}
paths:
  - {path: scripts/keep-in-sync.sh,    type: canonical, consumers: all}
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
EOF

# git init each fake worktree — resolve_consumer_worktree() looks for .git/
git init -q "$MP"

SIBLINGS="$WORKDIR/siblings"
mkdir -p "$SIBLINGS"

# Consumer 1: clean (mirrors mergepath verbatim)
mkdir -p "$SIBLINGS/clean-consumer/scripts/hooks" "$SIBLINGS/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$SIBLINGS/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$SIBLINGS/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/clean-consumer/scripts/ci/check_two"
# Add a consumer-only file in the kit dir to validate the allow-extras semantic
echo "consumer-extra" >"$SIBLINGS/clean-consumer/scripts/ci/check_consumer_only"
git init -q "$SIBLINGS/clean-consumer"

# Consumer 2: drifted (one canonical drifts, kit has one drifted file)
mkdir -p "$SIBLINGS/drifted/scripts/hooks" "$SIBLINGS/drifted/scripts/ci"
echo "MUTATED"                     >"$SIBLINGS/drifted/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/drifted/scripts/hooks/the-hook.sh"
echo "DRIFT"                       >"$SIBLINGS/drifted/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/drifted/scripts/ci/check_two"
git init -q "$SIBLINGS/drifted"

# Consumer 3: missing everything (no scripts/, no .github/, just a placeholder)
mkdir -p "$SIBLINGS/missing-everything"
echo "placeholder" >"$SIBLINGS/missing-everything/README.md"
git init -q "$SIBLINGS/missing-everything"

# ---------------------------------------------------------------------------
# Run the script against the fixture and capture output + exit code
# ---------------------------------------------------------------------------
cd "$MP"
set +e
output=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone 2>&1)
exit_code=$?
set -e

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; echo "---output---" >&2; echo "$output" >&2; exit 1; }

# Exit 1 because at least one consumer drifts.
[[ "$exit_code" -eq 1 ]] || fail "expected exit 1 (drift), got $exit_code"

# Per-consumer header presence checks (#216). The awk block-parsers
# below use `/^<consumer-name>/` to extract a section, then grep for
# ✓/✗/⊘ markers and `&& fail` on a hit. If the header line ever changes
# shape (e.g., gains a leading prefix or a trailing suffix that breaks
# the literal awk regex), the awk filter produces an empty stream, the
# grep finds nothing, and the test silently passes — drift goes
# undetected. These three explicit header presence assertions turn that
# silent-pass into a loud failure.
echo "$output" | grep -q "^clean-consumer" \
  || fail "clean-consumer block missing from --audit output"
echo "$output" | grep -q "^drifted" \
  || fail "drifted block missing from --audit output"
echo "$output" | grep -q "^missing-everything" \
  || fail "missing-everything block missing from --audit output"

# Clean consumer: every line should be ✓ in sync (the consumer-only extra
# file under scripts/ci/ must NOT be flagged — kit type is allow-extras).
echo "$output" | awk '
  /^clean-consumer/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✗\|⊘' \
  && fail "clean-consumer should report no drift; got non-✓ lines"

# Drifted consumer: must show drift for keep-in-sync.sh and for the kit dir
echo "$output" | grep -q "✗ scripts/keep-in-sync.sh" \
  || fail "expected drift line for scripts/keep-in-sync.sh on drifted consumer"
echo "$output" | grep -q "✗ scripts/ci/" \
  || fail "expected drift line for scripts/ci/ kit on drifted consumer"

# Missing-everything: every path must be ⊘
echo "$output" | awk '
  /^missing-everything/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✓\|✗' \
  && fail "missing-everything should report only ⊘; got ✓ or ✗ lines"

# ---------------------------------------------------------------------------
# Filter test: --paths restriction must shrink the report
# ---------------------------------------------------------------------------
filtered=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone --paths "scripts/hooks/the-hook.sh" 2>&1 || true)
echo "$filtered" | grep -q "scripts/keep-in-sync.sh" \
  && fail "--paths filter should have excluded scripts/keep-in-sync.sh"

# ---------------------------------------------------------------------------
# Missing-arg validation (CodeRabbit P-Minor on PR #215). Without the
# guard, --repos / --paths with no value crashes under set -u.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" --audit --repos 2>/dev/null
arg_exit=$?
set -e
[[ "$arg_exit" -eq 2 ]] || fail "--repos with no arg should exit 2; got $arg_exit"

set +e
"$SCRIPT" --audit --paths 2>/dev/null
arg_exit=$?
set -e
[[ "$arg_exit" -eq 2 ]] || fail "--paths with no arg should exit 2; got $arg_exit"

# ---------------------------------------------------------------------------
# .git-as-file (worktree) detection (Codex P2 on PR #215). The script
# must accept consumer worktrees whose .git is a file, not a directory.
# ---------------------------------------------------------------------------
worktree_siblings="$WORKDIR/worktree-siblings"
mkdir -p "$worktree_siblings/clean-consumer/scripts/hooks" \
         "$worktree_siblings/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$worktree_siblings/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$worktree_siblings/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$worktree_siblings/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$worktree_siblings/clean-consumer/scripts/ci/check_two"
# Real worktrees write a `gitdir: <path>` line into a `.git` file.
# A regular file with any content is enough for the existence-test;
# we don't need git's actual worktree machinery for this assertion.
echo "gitdir: $WORKDIR/fake.git" >"$worktree_siblings/clean-consumer/.git"

set +e
output=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$worktree_siblings" \
  "$SCRIPT" --audit --no-clone --repos clean-consumer 2>&1)
worktree_exit=$?
set -e
[[ "$worktree_exit" -eq 0 ]] \
  || fail "worktree (.git as file) should be accepted as a sibling; got exit $worktree_exit, output: $output"
echo "$output" | grep -q "no local worktree" \
  && fail "worktree (.git as file) misclassified as missing"

# ---------------------------------------------------------------------------
# Symlink guard on cache refresh (cursor CHANGES_REQUESTED on PR #215).
# If MERGEPATH_SYNC_CACHE/<consumer> resolves outside the cache dir
# (because it's symlinked at a sibling clone), refresh_cached_clone
# must refuse to `git reset --hard` and return error.
# ---------------------------------------------------------------------------
hostile_cache="$WORKDIR/hostile-cache"
hostile_user_tree="$WORKDIR/hostile-user-tree"
mkdir -p "$hostile_cache" "$hostile_user_tree/scripts/hooks" "$hostile_user_tree/scripts/ci"
git init -q "$hostile_user_tree"
# Set up a fake origin so git fetch / git reset have something to point at,
# and seed user-only content so a hard reset would clobber observable state.
( cd "$hostile_user_tree" \
    && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "user-only commit" )
# Symlink the cache entry at the user's tree.
ln -s "$hostile_user_tree" "$hostile_cache/clean-consumer"
echo "USER_LOCAL_EDIT" >"$hostile_user_tree/scripts/keep-in-sync.sh"

set +e
hostile_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$WORKDIR/no-siblings-here" \
  MERGEPATH_SYNC_CACHE="$hostile_cache" \
  "$SCRIPT" --audit --repos clean-consumer 2>&1)
hostile_exit=$?
set -e
[[ "$hostile_exit" -eq 3 ]] \
  || fail "expected exit 3 (fetch error from refusing symlinked cache), got $hostile_exit"
echo "$hostile_output" | grep -qE "it is a symbolic link|resolves outside MERGEPATH_SYNC_CACHE" \
  || fail "expected symlink-guard error message; got: $hostile_output"
# The user's working tree must NOT have been touched — this is the
# load-bearing assertion. The exit code and error message are
# observable proxies; what actually matters is that the user's local
# edits survive.
[[ "$(cat "$hostile_user_tree/scripts/keep-in-sync.sh")" == "USER_LOCAL_EDIT" ]] \
  || fail "symlink-guarded cache path was reset, clobbering the user's working tree"

# ---------------------------------------------------------------------------
# Sync mode (Layer 3 first slice): dry-run end-to-end.
#
# Build a fresh Mergepath fixture with two canonical paths, one kit
# path, one templated path, three consumers. Make a commit at HEAD~1
# that touches one canonical and one kit and one templated path; HEAD
# touches the other canonical only. Then exercise --dry-run modes to
# assert the planning logic is sane.
# ---------------------------------------------------------------------------
sync_workdir="$WORKDIR/sync"
SYNC_MP="$sync_workdir/mergepath"
mkdir -p "$SYNC_MP/scripts/hooks" "$SYNC_MP/scripts/ci" "$SYNC_MP/.github"
cat >"$SYNC_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
  - {name: beta,  repo: example/beta}
  - {name: gamma, repo: example/gamma}
paths:
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/coderabbit-wait.sh, type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
  - {path: AGENTS.md,                  type: templated, consumers: all}
YAML
echo "v1" >"$SYNC_MP/scripts/hooks/the-hook.sh"
echo "v1" >"$SYNC_MP/scripts/coderabbit-wait.sh"
echo "v1" >"$SYNC_MP/scripts/ci/check_one"
echo "v1" >"$SYNC_MP/AGENTS.md"
git -C "$SYNC_MP" init -q
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t commit -q -m "initial"

# Commit A — multi-type touch (canonical + kit + templated)
echo "v2" >"$SYNC_MP/scripts/hooks/the-hook.sh"
echo "v2" >"$SYNC_MP/scripts/ci/check_one"
echo "v2" >"$SYNC_MP/AGENTS.md"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t commit -q -m "multi-type-touch"
sha_A=$(git -C "$SYNC_MP" rev-parse HEAD)

# Commit B — single canonical touch
echo "v3" >"$SYNC_MP/scripts/coderabbit-wait.sh"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t commit -q -m "single-canonical-touch"
sha_B=$(git -C "$SYNC_MP" rev-parse HEAD)

# Commit C — only an unrelated file (no manifest path touched)
echo "noise" >"$SYNC_MP/.github/UNRELATED"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t commit -q -m "unrelated-only"
sha_C=$(git -C "$SYNC_MP" rev-parse HEAD)

# 1) Multi-type touch: canonical lands, kit + templated are deferred with
#    a per-consumer note. All 3 consumers get a planned PR.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run 2>&1)
echo "$sync_out" | grep -q "would open PR on branch mergepath-sync/${sha_A:0:7}" \
  || fail "multi-type sync did not produce planned PRs; output: $sync_out"
[[ "$(echo "$sync_out" | grep -c 'would open PR')" -eq 3 ]] \
  || fail "expected 3 planned PRs (one per consumer); got: $sync_out"
echo "$sync_out" | grep -q "+ scripts/hooks/the-hook.sh" \
  || fail "canonical target scripts/hooks/the-hook.sh missing from plan"
echo "$sync_out" | grep -q "deferred this slice: kit=scripts/ci/" \
  || fail "kit deferred-note missing from plan"
echo "$sync_out" | grep -q "templated=AGENTS.md" \
  || fail "templated deferred-note missing from plan"

# 2) --repos filter restricts consumer set.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_B" --dry-run --repos beta 2>&1)
[[ "$(echo "$sync_out" | grep -c 'would open PR')" -eq 1 ]] \
  || fail "--repos filter did not restrict to one consumer; got: $sync_out"
echo "$sync_out" | grep -q "beta — would open PR" \
  || fail "expected beta in --repos filter output; got: $sync_out"
echo "$sync_out" | grep -q "alpha\|gamma" \
  && fail "non-filtered consumer leaked into output: $sync_out"

# 3) --paths filter restricts target set within the planned PR.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --paths "scripts/hooks/the-hook.sh" 2>&1)
echo "$sync_out" | grep -q "+ scripts/hooks/the-hook.sh" \
  || fail "--paths filter excluded the requested path"
echo "$sync_out" | grep -q "+ scripts/coderabbit-wait.sh" \
  && fail "--paths filter did not exclude scripts/coderabbit-wait.sh"

# 4) Commit that only touches kit + templated → no canonical targets,
#    summary marks each consumer as ⊘ (skipped, deferred-only).
deferred_only_sha=$(git -C "$SYNC_MP" rev-list HEAD --reverse | sed -n '2p')  # commit A
# Re-derive: we want a commit that is kit-only or templated-only, not
# the multi-type one. Make a fresh commit just for this case.
echo "v4" >"$SYNC_MP/scripts/ci/check_one"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t commit -q -m "kit-only"
sha_D=$(git -C "$SYNC_MP" rev-parse HEAD)

sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_D" --dry-run 2>&1)
echo "$sync_out" | grep -q "no canonical targets" \
  || fail "kit-only commit should report 'no canonical targets' per consumer; got: $sync_out"
echo "$sync_out" | grep -q "would open PR" \
  && fail "kit-only commit should not plan any PRs (canonical-only slice)"

# 5) Commit that touches no manifest path at all → "no manifest paths touched".
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_C" --dry-run 2>&1)
echo "$sync_out" | grep -q "no manifest paths touched" \
  || fail "unrelated-only commit should report 'no manifest paths touched'; got: $sync_out"

# 6) Resolution of an unknown commit-ish exits 2 cleanly.
set +e
"$SCRIPT" deadbeefdeadbeefdeadbeef --dry-run 2>/dev/null
unknown_exit=$?
set -e
[[ "$unknown_exit" -eq 2 ]] || fail "unknown commit-ish should exit 2; got $unknown_exit"

# ---------------------------------------------------------------------------
# Live-mode active-account guard (cursor CHANGES_REQUESTED on PR #217).
# Without the guard, a careless live invocation under a reviewer-identity
# `gh` keyring would create downstream PRs under that identity, violating
# the author/reviewer separation. The guard refuses to proceed unless the
# active gh account matches author_identity. Tested by overriding the
# expected actor to a value the live `gh config get` will not match.
# ---------------------------------------------------------------------------
guard_workdir="$WORKDIR/guard"
GUARD_MP="$guard_workdir/mergepath"
mkdir -p "$GUARD_MP/scripts" "$GUARD_MP/.github"
cat >"$GUARD_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example-bogus/alpha}
paths:
  - {path: scripts/the-script.sh, type: canonical, consumers: all}
YAML
cat >"$GUARD_MP/.github/review-policy.yml" <<'YAML'
author_identity: definitely-not-a-real-user-9999
YAML
echo "v1" >"$GUARD_MP/scripts/the-script.sh"
git -C "$GUARD_MP" init -q
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t add -A
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t commit -q -m initial
echo "v2" >"$GUARD_MP/scripts/the-script.sh"
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t add -A
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t commit -q -m bump
guard_sha=$(git -C "$GUARD_MP" rev-parse HEAD)

# Live mode (no --dry-run) with the wrong active account should refuse.
# We don't have access to consumer repos in tests anyway; the guard
# fires BEFORE any clone, so the failure is the guard's, not the
# clone's.
set +e
guard_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" "$SCRIPT" "$guard_sha" --repos alpha 2>&1)
guard_exit=$?
set -e
echo "$guard_out" | grep -q "refusing to run live sync" \
  || fail "active-account guard did not fire; got: $guard_out"
echo "$guard_out" | grep -q "definitely-not-a-real-user-9999" \
  || fail "active-account guard did not name the expected actor"
[[ "$guard_exit" -ne 0 ]] \
  || fail "active-account guard should exit non-zero; got $guard_exit"

# Dry-run with the same wrong active account should still PASS — the
# guard only applies to live mode.
set +e
dr_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" "$SCRIPT" "$guard_sha" --dry-run --repos alpha 2>&1)
dr_exit=$?
set -e
[[ "$dr_exit" -eq 0 ]] \
  || fail "dry-run should not be blocked by active-account guard; got exit $dr_exit, output: $dr_out"
echo "$dr_out" | grep -q "would open PR" \
  || fail "dry-run should still plan a PR; got: $dr_out"

# MERGEPATH_SYNC_ACTOR_OVERRIDE escape hatch: setting it to the current
# active actor makes the guard pass. We can't actually run live mode
# (no real consumer repo), but we can assert the guard accepts the
# override and the failure mode shifts to "could not clone" rather than
# "refusing to run live sync."
current_actor=$(gh config get -h github.com user 2>/dev/null || echo "")
if [ -n "$current_actor" ]; then
  set +e
  override_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" \
    MERGEPATH_SYNC_ACTOR_OVERRIDE="$current_actor" \
    "$SCRIPT" "$guard_sha" --repos alpha 2>&1)
  set -e
  echo "$override_out" | grep -q "refusing to run live sync" \
    && fail "actor override should bypass the guard; got: $override_out"
fi

# ---------------------------------------------------------------------------
# Mode-mirror correctness (cursor CHANGES_REQUESTED on PR #217).
# Live copy should NOT only add +x; it must also CLEAR +x when the
# Mergepath source is 100644. We can't easily exercise sync_open_pr's
# full path here without stubbing gh, but we can unit-check the mode
# logic by sourcing the script with a guard and calling the relevant
# git commands directly. Simpler: assert the script source contains
# both `chmod +x` and `chmod -x` branches.
# ---------------------------------------------------------------------------
grep -q 'chmod -x "$consumer_target"' "$SCRIPT" \
  || fail "sync_open_pr is missing the 'chmod -x' branch — mode drift would persist on 100644 sources"
grep -q 'chmod +x "$consumer_target"' "$SCRIPT" \
  || fail "sync_open_pr is missing the 'chmod +x' branch"

# ---------------------------------------------------------------------------
# Deletion propagation + tmpdir portability (cursor CHANGES_REQUESTED on
# PR #217). Two source-grep assertions because the live cycle isn't
# unit-testable without stubbing gh:
#
# 1. The materialization loop must check `git ls-tree` for a path
#    BEFORE trying `git show`, and if the path is absent at the sha,
#    rm the consumer copy instead of failing on a missing blob.
# 2. The mktemp invocation must use the explicit `$TMPDIR/<X-pattern>`
#    form (portable across BSD/macOS and GNU/Linux), not `mktemp -d -t
#    "literal-prefix"` (BSD-specific behavior).
# ---------------------------------------------------------------------------
grep -q 'ls-tree "$sha" -- "$target"' "$SCRIPT" \
  || fail "materialization loop is missing the ls-tree pre-check; deletes would fail on git show"
grep -q '\[ -z "\$src_mode" \]' "$SCRIPT" \
  || fail "materialization loop is missing the absent-at-sha branch (rm consumer copy on delete propagation)"
grep -q 'rm -f "\$consumer_target"' "$SCRIPT" \
  || fail "materialization loop is missing 'rm -f \$consumer_target' for delete propagation"
grep -q 'mktemp -d "\$tmp_root/mergepath-sync-' "$SCRIPT" \
  || fail "mktemp invocation is missing the portable \$TMPDIR/<prefix>.XXXXXX form"
grep -q 'mktemp -d -t "mergepath-sync' "$SCRIPT" \
  && fail "mktemp invocation still uses the BSD-specific '-t literal-prefix' form (not GNU portable)"

# ---------------------------------------------------------------------------
# --version / --help smoke
# ---------------------------------------------------------------------------
"$SCRIPT" --version | grep -q "sync-to-downstream.sh" || fail "--version output unexpected"
"$SCRIPT" --help    | grep -q "Usage:"                || fail "--help output unexpected"

echo "test_sync_to_downstream: PASS"
