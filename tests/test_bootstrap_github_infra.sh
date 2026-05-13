#!/usr/bin/env bash
# tests/test_bootstrap_github_infra.sh
#
# Validates scripts/bootstrap/github-infra.sh (sub-C / #205).
#
# Strategy: a PATH-shimmed `gh` records every invocation to a log
# file and returns canned exit codes. The shim NEVER contacts the
# real GitHub API. The wizard then drives the stage end-to-end and
# we assert against the log:
#
#   1. `gh repo create` is invoked with the right flags (visibility,
#      description, source, --push).
#   2. All 10 canonical labels are seeded with --force (idempotency).
#   3. Reviewer invitations land via `gh api -X PUT` to the right
#      collaborator endpoint for each agent in BOOTSTRAP_INPUT_REVIEWERS.
#   4. REVIEWER_ASSIGNMENT_TOKEN provisioning uses the inline-PAT
#      path when BOOTSTRAP_REVIEWER_PAT_VALUE is set.
#   5. Stage failure propagates when `gh repo create` returns non-zero
#      (the state file must NOT carry a github-infra completion entry).
#
# Requires: bash, rsync (for sub-B in the chain), yq (preflight req).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"

if ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: rsync not installed" >&2; exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed" >&2; exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: non-mikefarah yq" >&2; exit 0
fi

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-github-infra.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- build fixture mergepath ----------------------------------------------
FAKE_MP="$WORKDIR/fake-mp"
TARGET="$WORKDIR/new-repo"
mkdir -p "$FAKE_MP"/{scripts/bootstrap,scripts/ci,scripts/sync,.github/workflows,docs/agents,tests}
echo "# mergepath" >"$FAKE_MP/README.md"
echo "Mergepath brand" >"$FAKE_MP/BRAND.md"
echo "ai ctx" >"$FAKE_MP/.ai_context.md"
echo "overview" >"$FAKE_MP/docs/agents/repository-overview.md"
cat >"$FAKE_MP/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
extra_top_level_dirs: [mergepath, packaging]
EOF
echo "Security" >"$FAKE_MP/SECURITY.md"

# Copy real bootstrap script + stage modules
cp "$ROOT/scripts/bootstrap/_lib.sh"                  "$FAKE_MP/scripts/bootstrap/_lib.sh"
cp "$ROOT/scripts/bootstrap/substitute.sh"            "$FAKE_MP/scripts/bootstrap/substitute.sh"
cp "$ROOT/scripts/bootstrap/template-mirror.sh"       "$FAKE_MP/scripts/bootstrap/template-mirror.sh"
cp "$ROOT/scripts/bootstrap/github-infra.sh"          "$FAKE_MP/scripts/bootstrap/github-infra.sh"
cp "$ROOT/scripts/bootstrap/firebase-and-codereview.sh" "$FAKE_MP/scripts/bootstrap/firebase-and-codereview.sh"
cp "$ROOT/scripts/bootstrap/board-and-summary.sh"     "$FAKE_MP/scripts/bootstrap/board-and-summary.sh"
cp "$ROOT/scripts/bootstrap-new-repo.sh"              "$FAKE_MP/scripts/bootstrap-new-repo.sh"
git -C "$FAKE_MP" init -q
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture"

# --- gh PATH shim ----------------------------------------------------------
# Records every invocation to $SHIM_LOG. Returns 0 by default; tests
# can override per-subcommand exit via $SHIM_EXIT_<UPPERCASE-SUBCMD>=N.
SHIM_DIR="$WORKDIR/shim-bin"
SHIM_LOG="$WORKDIR/gh-shim.log"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/gh" <<'SHIM_EOF'
#!/usr/bin/env bash
# gh PATH-shim used by tests/test_bootstrap_github_infra.sh.
# Records every invocation to $SHIM_LOG.

LOG=${SHIM_LOG:?SHIM_LOG not set}
# One line per invocation: cmd1 cmd2 args...
echo "gh $*" >>"$LOG"

# Subcommand-conditional exit code. Per-subcommand env vars let
# tests dial in specific failures (e.g., SHIM_EXIT_REPO_CREATE=1).
case "$1" in
  repo)
    case "$2" in
      create) exit "${SHIM_EXIT_REPO_CREATE:-0}" ;;
      *) exit 0 ;;
    esac
    ;;
  label)
    exit "${SHIM_EXIT_LABEL:-0}"
    ;;
  api)
    exit "${SHIM_EXIT_API:-0}"
    ;;
  secret)
    # `gh secret set --body -` reads stdin; consume it so the
    # pipe doesn't break.
    if [ "$2" = "set" ]; then
      cat >/dev/null 2>&1 || true
    fi
    exit "${SHIM_EXIT_SECRET:-0}"
    ;;
  config)
    # `gh config get -h github.com user` — return the active acct
    # used by stage B's switch-around tests. github-infra doesn't
    # use this, but other stages might be invoked in the same run.
    echo "nathanpayne-claude"
    exit 0
    ;;
  auth)
    # `gh auth switch -u X` — no-op shim.
    exit 0
    ;;
  pr)
    # Stage B's cross-repo loop may call gh pr create when anchors
    # exist (they don't in this fixture — so this is just defensive).
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SHIM_EOF
chmod +x "$SHIM_DIR/gh"

# --- run the wizard end-to-end with stages B + C exercising the shim ----
# Stage D (firebase-and-codereview) and E (board-and-summary) are
# still stubs and will run; their record_stage calls are fine.
SHIM_PATH="$SHIM_DIR:/usr/bin:/bin"
# Include yq + git + rsync from the real PATH (the shim only covers
# gh). We need bash 3.2+ on macOS to keep this portable.
for tool in bash yq git rsync sed awk grep mktemp tr cut tail head wc ls rm cat printf chmod find dirname basename; do
  src=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$src" ] && ln -sf "$src" "$SHIM_DIR/$tool"
done

run_wizard() {
  PATH="$SHIM_PATH" \
  SHIM_LOG="$SHIM_LOG" \
  BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
  BOOTSTRAP_SKIP_TOOL_CHECK=1 \
  BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
  BOOTSTRAP_AUTO_CONFIRM=1 \
  BOOTSTRAP_AUTO_PROMPT=skip \
  BOOTSTRAP_AUTHOR_NAME="test" \
  BOOTSTRAP_AUTHOR_EMAIL="t@t" \
  BOOTSTRAP_SKIP_INVITE_PAUSE=1 \
  BOOTSTRAP_REVIEWER_PAT_VALUE="fake-test-pat-1234567890" \
  "$SCRIPT" "$@"
}

# --- happy path -----------------------------------------------------------
: >"$SHIM_LOG"
rm -rf "$TARGET"
set +e
out=$(run_wizard test-repo \
        --target-dir "$TARGET" \
        --description "a test repo" \
        --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e

[ "$ec" -eq 0 ] \
  && pass "happy-path live run completes (rc=0)" \
  || fail "wizard failed; rc=$ec; out: $out"

# --- assertion 1: gh repo create invoked correctly ---
grep -q "^gh repo create nathanjohnpayne/test-repo --private --description a test repo --source=$TARGET --push$" "$SHIM_LOG" \
  && pass "gh repo create invoked with --private + --source + --push" \
  || fail "gh repo create flags wrong; log: $(grep '^gh repo create' "$SHIM_LOG")"

# --- assertion 2: all 10 labels seeded with --force ---
expected_labels=(needs-external-review needs-human-review policy-violation human-action agent-action phase-0 phase-1 phase-2 phase-3 phase-4)
seeded=0
for label in "${expected_labels[@]}"; do
  if grep -qE "^gh label create $label .* --force\$" "$SHIM_LOG"; then
    seeded=$((seeded + 1))
  else
    fail "label '$label' not seeded with --force; log: $(grep "label create $label" "$SHIM_LOG")"
  fi
done
[ "$seeded" -eq 10 ] \
  && pass "all 10 canonical labels seeded with --force" \
  || fail "expected 10 labels, got $seeded"

# --- assertion 3: reviewer collaborator invites ---
for agent in claude cursor codex; do
  login="nathanpayne-$agent"
  if grep -qF "gh api -X PUT repos/nathanjohnpayne/test-repo/collaborators/$login -f permission=write" "$SHIM_LOG"; then
    pass "reviewer collaborator invite sent to $login"
  else
    fail "no invite for $login; log: $(grep collaborator "$SHIM_LOG")"
  fi
done

# --- assertion 4: REVIEWER_ASSIGNMENT_TOKEN secret set via inline PAT ---
grep -q "^gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo nathanjohnpayne/test-repo --body -$" "$SHIM_LOG" \
  && pass "REVIEWER_ASSIGNMENT_TOKEN secret set via stdin pipe" \
  || fail "REVIEWER_ASSIGNMENT_TOKEN secret-set not logged correctly; log: $(grep secret "$SHIM_LOG")"

# --- assertion 5: stage records completion in state file ---
[ -f "$TARGET/.bootstrap-state" ] \
  && grep -q "^github-infra\$" "$TARGET/.bootstrap-state" \
  && pass "github-infra stage recorded in state file" \
  || fail "state file missing github-infra entry: $(cat "$TARGET/.bootstrap-state" 2>/dev/null)"

# --- assertion 6: dispatch ordering — template-mirror runs BEFORE github-infra ---
# Sub-B must complete first (it sets up the .git/ that sub-C pushes).
awk '
  /^template-mirror$/ { mirror = NR }
  /^github-infra$/    { infra  = NR }
  END {
    if (!mirror || !infra) { print "missing entries"; exit 1 }
    if (mirror > infra) { print "ordering wrong"; exit 1 }
  }
' "$TARGET/.bootstrap-state" \
  && pass "template-mirror recorded before github-infra in state file" \
  || fail "state-file ordering broken"

# --- assertion 7: secret skip works with BOOTSTRAP_SKIP_SECRETS=1 ---
: >"$SHIM_LOG"
TARGET2="$WORKDIR/new-repo-skipsec"
rm -rf "$TARGET2"
set +e
unset BOOTSTRAP_REVIEWER_PAT_VALUE
out=$(BOOTSTRAP_SKIP_SECRETS=1 run_wizard skipsec-repo \
        --target-dir "$TARGET2" \
        --description "d" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] \
  && pass "BOOTSTRAP_SKIP_SECRETS=1 happy path exits 0" \
  || fail "skip-secrets run failed: rc=$ec"
grep -qF "gh secret set REVIEWER_ASSIGNMENT_TOKEN" "$SHIM_LOG" \
  && fail "secret set called despite BOOTSTRAP_SKIP_SECRETS=1" \
  || pass "BOOTSTRAP_SKIP_SECRETS=1 suppresses gh secret set"

# --- assertion 8: stage fails closed when gh repo create fails ---
: >"$SHIM_LOG"
TARGET3="$WORKDIR/new-repo-fail-create"
rm -rf "$TARGET3"
set +e
out=$(SHIM_EXIT_REPO_CREATE=1 run_wizard failrepo-repo \
        --target-dir "$TARGET3" \
        --description "d" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e
[ "$ec" -ne 0 ] \
  && pass "stage fails closed when gh repo create fails (rc=$ec)" \
  || fail "stage should fail when gh repo create errors; rc=$ec"
# State file should NOT have github-infra entry (template-mirror is fine
# because that ran before the failure).
if [ -f "$TARGET3/.bootstrap-state" ] && grep -q "^github-infra\$" "$TARGET3/.bootstrap-state"; then
  fail "github-infra recorded despite gh repo create failure"
else
  pass "github-infra NOT recorded when gh repo create fails (resume can retry)"
fi

# --- assertion 9: dry-run produces plan without invoking the shim ---
: >"$SHIM_LOG"
TARGET4="$WORKDIR/new-repo-dry"
rm -rf "$TARGET4"
set +e
dry_out=$(run_wizard dry-repo \
            --target-dir "$TARGET4" \
            --description "d" --visibility private \
            --firebase none --codex-app n --project new --dry-run 2>&1)
dry_ec=$?
set -e
[ "$dry_ec" -eq 0 ] \
  && pass "stage C --dry-run exits 0" \
  || fail "dry-run failed: rc=$dry_ec"
# Dry-run must NOT actually invoke gh (the shim should not have
# recorded anything; bootstrap::run prints [DRY-RUN] instead).
if [ -s "$SHIM_LOG" ]; then
  fail "dry-run invoked gh shim ($(wc -l <"$SHIM_LOG") calls); should be 0"
else
  pass "dry-run did not invoke gh (bootstrap::run honors --dry-run)"
fi
echo "$dry_out" | grep -q "DRY-RUN" \
  && pass "dry-run output includes [DRY-RUN] tags" \
  || fail "dry-run missing [DRY-RUN] markers"

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_github_infra: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
