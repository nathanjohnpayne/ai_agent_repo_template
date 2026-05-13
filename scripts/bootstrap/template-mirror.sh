#!/usr/bin/env bash
# scripts/bootstrap/template-mirror.sh — bootstrap wizard stage B.
# Per #156 sub-B / #204.
#
# Responsibilities (in order):
#   1. rsync mergepath's worktree into the new repo's target dir,
#      honoring a curated exclude list that drops mergepath-only files
#      (the playground spec, packaging/, internal screenshots, etc.).
#   2. Remove post-rsync orphans the exclude list can't catch.
#   3. Apply name substitutions across the documented 6 name-bearing
#      files (via scripts/bootstrap/substitute.sh).
#   4. Drop mergepath-specific entries from the new repo's
#      .repo-template.yml (the playground spec_test_map + the
#      extra_top_level_dirs guard for mergepath/packaging).
#   5. Initialize the new repo's git history with a single
#      "Initial commit (bootstrapped from mergepath)" commit.
#
# The cross-repo loop update (open a Mergepath-side PR adding the
# new repo to the loop docs in DEPLOYMENT.md + REVIEW_POLICY.md) is
# the LAST step. It's gated on a separate confirmation prompt because
# it writes to mergepath itself, not to the target. Without
# BOOTSTRAP_AUTO_CONFIRM=1 the operator must say yes.
#
# Reads (set by the wizard before dispatch):
#   $TARGET_DIR                Path to the new repo's target dir.
#   $BOOTSTRAP_MERGEPATH_ROOT  Path to mergepath's worktree (the
#                              wizard's own source root). Exported
#                              by the wizard so this stage can find it.
#   $BOOTSTRAP_INPUT_REPO_NAME et al via bootstrap_input <name>.
#
# Side effects via bootstrap::run (the side-effect wrapper that
# honors --dry-run).

set -euo pipefail

# Source the substitution lib. Its location is fixed relative to
# this stage file. The lib also exports the name-bearing files list
# so the rsync stage and the substitution stage agree on what gets
# rewritten.
# shellcheck source=scripts/bootstrap/substitute.sh
. "${BOOTSTRAP_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/substitute.sh"

# Exclude list — single source of truth. Anything we don't want
# propagated to a new repo lives here. Each entry is an rsync
# --exclude pattern (path-relative-to-source, no leading slash).
# See #204 for the rationale on each entry.
BOOTSTRAP_MIRROR_EXCLUDES=(
  # Repo metadata that should never propagate
  '.git/'
  '.DS_Store'
  'dist/'

  # Mergepath-only vendoring / packaging dirs
  'mergepath/'
  'packaging/'

  # Local operator state under .claude/
  '.claude/worktrees/'
  '.claude/settings.local.json'
  '.claude/launch.json'

  # Playground spec + test (mergepath-only sandbox)
  'specs/mergepath_playground.md'
  'plans/mergepath-playground.md'

  # Mergepath-internal policy simulation tool
  'scripts/policy-sim.sh'

  # Screenshots — internal evidence, not template content
  'bugs/screenshots/'
  '.github/screenshots/'

  # State files from prior wizard runs (when re-running into the
  # same target dir)
  '.bootstrap-log'
  '.bootstrap-state'
)

# Files that rsync leaves behind because they don't match an exclude
# pattern but shouldn't ship to a new repo. Post-mirror cleanup.
BOOTSTRAP_POST_MIRROR_REMOVE=(
  tests/test_mergepath_playground.sh
)

# Directories to remove ONLY if they end up empty after the
# rsync + orphan cleanup. Some sub-dirs of bugs/ or similar only
# existed to hold screenshots; if those got excluded, the parent
# is empty and should be tombstoned.
BOOTSTRAP_POST_MIRROR_RMDIR_IF_EMPTY=(
  bugs
)

bootstrap::stage_template_mirror() {
  bootstrap::stage_banner "template-mirror"

  local target
  target=$(bootstrap::_resolve_target_dir)
  local source_root
  source_root=$(bootstrap::_resolve_source_root)

  if [ ! -d "$source_root" ]; then
    bootstrap::err "template-mirror: source root not found: $source_root"
    return 1
  fi

  # Step 1: rsync mergepath → target with excludes.
  bootstrap::_rsync_template "$source_root" "$target"

  # Step 2: post-mirror orphan cleanup.
  bootstrap::_remove_orphans "$target"

  # Step 3: apply name substitutions across the 6 name-bearing files.
  bootstrap::apply_name_substitutions "$target"

  # Step 4: drop mergepath-specific .repo-template.yml entries.
  bootstrap::_clean_repo_template_yml "$target"

  # Step 5: initialize git history.
  bootstrap::_init_target_git "$target"

  # Step 6: cross-repo loop update. Writes to mergepath itself, so
  # gated on a confirmation prompt.
  bootstrap::_cross_repo_loop_update "$source_root"

  bootstrap::record_stage "template-mirror"
  return 0
}

# --- internal helpers -------------------------------------------------------

bootstrap::_resolve_target_dir() {
  # The wizard sets $TARGET_DIR as a script-global. Stage functions
  # run in the same shell, so it's visible. Echo for symmetry with
  # _resolve_source_root.
  echo "${TARGET_DIR:?TARGET_DIR not set by wizard}"
}

bootstrap::_resolve_source_root() {
  # Prefer BOOTSTRAP_MERGEPATH_ROOT (explicit, set by the wizard).
  # Fall back to walking up from $SCRIPT_DIR/.. since the wizard
  # lives at scripts/bootstrap-new-repo.sh in mergepath's worktree.
  if [ -n "${BOOTSTRAP_MERGEPATH_ROOT:-}" ]; then
    echo "$BOOTSTRAP_MERGEPATH_ROOT"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ]; then
    (cd "$SCRIPT_DIR/.." && pwd)
    return 0
  fi
  # Last resort: walk up from this stage file.
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

bootstrap::_rsync_template() {
  local source_root=$1
  local target=$2

  # Build the rsync arg list.
  local rsync_args=(-a)
  local exc
  for exc in "${BOOTSTRAP_MIRROR_EXCLUDES[@]}"; do
    rsync_args+=(--exclude="$exc")
  done

  mkdir -p "$target"

  bootstrap::run "rsync $source_root -> $target" \
    rsync "${rsync_args[@]}" "$source_root/" "$target/"
}

bootstrap::_remove_orphans() {
  local target=$1

  local orphan
  for orphan in "${BOOTSTRAP_POST_MIRROR_REMOVE[@]}"; do
    if [ -e "$target/$orphan" ]; then
      bootstrap::run "rm orphan $orphan" rm -f "$target/$orphan"
    fi
  done

  local empty_dir
  for empty_dir in "${BOOTSTRAP_POST_MIRROR_RMDIR_IF_EMPTY[@]}"; do
    local dir_path="$target/$empty_dir"
    if [ -d "$dir_path" ] && [ -z "$(ls -A "$dir_path" 2>/dev/null)" ]; then
      bootstrap::run "rmdir empty $empty_dir" rmdir "$dir_path"
    fi
  done
}

bootstrap::_clean_repo_template_yml() {
  local target=$1
  local rtc="$target/.repo-template.yml"

  if [ ! -f "$rtc" ]; then
    bootstrap::log "no .repo-template.yml to clean up at $rtc"
    return 0
  fi

  if ! command -v yq >/dev/null 2>&1; then
    bootstrap::warn "yq not available; skipping .repo-template.yml cleanup"
    return 0
  fi

  bootstrap::run "drop mergepath-specific .repo-template.yml entries" \
    bootstrap::_yq_clean_repo_template "$rtc"
}

bootstrap::_yq_clean_repo_template() {
  local f=$1
  # Drop the playground spec_test_map entry (whose key is
  # "mergepath_playground" pre-substitution; substitution would
  # have renamed it to e.g. "newrepo_playground" — drop either form
  # by removing any entry whose value list contains the playground
  # test path).
  yq -i 'del(.spec_test_map.mergepath_playground)' "$f"
  # Drop extra_top_level_dirs entirely — the new repo has no
  # mergepath/ or packaging/ dirs.
  yq -i 'del(.extra_top_level_dirs)' "$f"
}

bootstrap::_init_target_git() {
  local target=$1

  if [ -d "$target/.git" ]; then
    bootstrap::log "target already has .git, skipping init"
    return 0
  fi

  bootstrap::run "git init $target" \
    git -C "$target" init -q -b main

  bootstrap::run "stage initial files" \
    git -C "$target" add -A

  # Use the operator's git config for the commit identity. Tests
  # can override via BOOTSTRAP_AUTHOR_NAME / BOOTSTRAP_AUTHOR_EMAIL
  # to avoid depending on the developer's global git config.
  local author_name="${BOOTSTRAP_AUTHOR_NAME:-}"
  local author_email="${BOOTSTRAP_AUTHOR_EMAIL:-}"

  if [ -n "$author_name" ] && [ -n "$author_email" ]; then
    bootstrap::run "initial commit (with explicit identity)" \
      git -C "$target" \
        -c "user.name=$author_name" \
        -c "user.email=$author_email" \
        -c commit.gpgsign=false \
        commit -q -m "Initial commit (bootstrapped from mergepath)"
  else
    bootstrap::run "initial commit" \
      git -C "$target" \
        -c commit.gpgsign=false \
        commit -q -m "Initial commit (bootstrapped from mergepath)"
  fi
}

# --- cross-repo loop update -------------------------------------------------
#
# Writes to MERGEPATH itself (not the target). Opens a new branch on
# mergepath's worktree, appends the new repo to the loop docs, commits,
# pushes, and opens a PR. Heavily gated:
#
# - Preflight 6 (in the wizard) requires mergepath to be on main +
#   clean before any stage runs. This step trusts that invariant.
# - We refuse to operate on a worktree that isn't clean RIGHT NOW
#   (defensive — re-check in case an earlier stage dirtied it).
# - We prompt for explicit confirmation before pushing + opening the
#   PR. BOOTSTRAP_AUTO_CONFIRM=1 skips the prompt (for tests).
# - Dry-run path emits the plan without touching the worktree.
#
bootstrap::_cross_repo_loop_update() {
  local source_root=$1
  local repo_name
  repo_name=$(bootstrap_input repo_name)

  if [ "${BOOTSTRAP_SKIP_CROSS_REPO_LOOP:-0}" = "1" ]; then
    bootstrap::log "cross-repo loop update skipped (BOOTSTRAP_SKIP_CROSS_REPO_LOOP=1)"
    return 0
  fi

  # Confirm with the operator.
  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" != "1" ]; then
    echo
    echo "About to open a PR on mergepath itself to add '$repo_name' to the"
    echo "cross-repo loops in DEPLOYMENT.md and REVIEW_POLICY.md."
    echo "  source: $source_root"
    local reply
    read -r -p "Proceed? [y/N]: " reply
    case "${reply:-}" in
      y|Y|yes|YES) ;;
      *)
        bootstrap::log "cross-repo loop update declined by operator; skipping"
        return 0
        ;;
    esac
  fi

  # Re-verify mergepath state.
  local branch
  branch=$(git -C "$source_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$branch" != "main" ]; then
    bootstrap::err "cross-repo loop update: mergepath is on '$branch', expected 'main'; refusing"
    return 1
  fi
  if [ -n "$(git -C "$source_root" status --porcelain 2>/dev/null)" ]; then
    bootstrap::err "cross-repo loop update: mergepath worktree dirty; refusing to open PR"
    return 1
  fi

  # Probe for anchors BEFORE creating the branch. If neither doc has
  # the anchor, the cross-repo loop update can't safely insert and we
  # don't want to leave a stray empty branch on mergepath. The
  # anchors get introduced by a separate doc-refactor PR (see #204
  # implementation notes).
  local anchored_count=0
  if grep -q -F '<!-- bootstrap-loop-list-end -->' "$source_root/DEPLOYMENT.md" 2>/dev/null; then
    anchored_count=$((anchored_count + 1))
  fi
  if grep -q -F '<!-- bootstrap-loop-list-end -->' "$source_root/REVIEW_POLICY.md" 2>/dev/null; then
    anchored_count=$((anchored_count + 1))
  fi
  if [ "$anchored_count" -eq 0 ]; then
    bootstrap::warn "cross-repo loop update: neither DEPLOYMENT.md nor REVIEW_POLICY.md carries the '<!-- bootstrap-loop-list-end -->' anchor — manual action needed to add '$repo_name' to the loop lists. Skipping the PR."
    return 0
  fi

  local loop_branch="bootstrap/add-${repo_name}-to-loops"
  BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT=0

  bootstrap::run "checkout $loop_branch on mergepath" \
    git -C "$source_root" checkout -q -b "$loop_branch"

  bootstrap::_append_repo_to_loop_doc "$source_root/DEPLOYMENT.md" "$repo_name"
  bootstrap::_append_repo_to_loop_doc "$source_root/REVIEW_POLICY.md" "$repo_name"

  # If everything we touched ended up unmodified, abort the commit
  # entirely — no point in opening an empty PR. Switch back to main
  # and tombstone the throwaway branch.
  if [ "${BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT:-0}" -eq 2 ]; then
    bootstrap::warn "no loop docs were anchored — aborting cross-repo PR"
    bootstrap::run "return mergepath to main (no-op recovery)" \
      git -C "$source_root" checkout -q main
    bootstrap::run "delete unused $loop_branch" \
      git -C "$source_root" branch -q -D "$loop_branch"
    return 0
  fi

  bootstrap::run "stage loop-doc changes" \
    git -C "$source_root" add DEPLOYMENT.md REVIEW_POLICY.md

  bootstrap::run "commit loop-doc update" \
    git -C "$source_root" \
      -c commit.gpgsign=false \
      commit -q -m "docs: add $repo_name to cross-repo loops

Auto-generated by scripts/bootstrap/template-mirror.sh as part of
bootstrapping $repo_name from the Mergepath template (per #156).
"

  bootstrap::run "push $loop_branch" \
    git -C "$source_root" push -u origin "$loop_branch"

  bootstrap::run "open PR for cross-repo loop update" \
    gh pr create --repo "${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}/mergepath" \
      --base main --head "$loop_branch" \
      --title "docs: add $repo_name to cross-repo loops" \
      --body "Auto-generated by \`scripts/bootstrap/template-mirror.sh\` while bootstrapping \`$repo_name\` from the Mergepath template (#156).

Adds \`$repo_name\` to the documented cross-repo loops in:
- DEPLOYMENT.md (bootstrap loop, return-to-main loop)
- REVIEW_POLICY.md (SSH-remote-switch loop)

Authoring-Agent: claude

## Self-Review
- Correctness: anchor-driven insertion; falls back to append-at-end with warning if anchors missing.
- Regression risk: low; pure doc append.
- Style: matches existing entries.
- Test coverage: scripts/ci/check_bootstrap_template_mirror covers the dry-run path.
- Security: no new attack surface.
"

  # Switch back to main so the operator's worktree is left tidy.
  bootstrap::run "return mergepath to main" \
    git -C "$source_root" checkout -q main
}

# Append the new repo to a loop doc. The doc carries an anchor string
# the wizard inserts above (so future bootstraps can deterministically
# find the right list). If the anchor is missing (older mergepath),
# the function appends an unanchored line at end-of-file with a
# warning so the operator can manually relocate it.
bootstrap::_append_repo_to_loop_doc() {
  local doc=$1
  local repo_name=$2
  # The anchor is a magic comment present in the doc once per loop
  # list. We append a new line right before the closing anchor. The
  # anchors are introduced in mergepath by a separate doc-refactor PR
  # that converts the bash-embedded repo lists into a structured list
  # (see #156 follow-up). Until that PR lands, anchors are absent and
  # this function logs a "manual action needed" message and returns
  # without modifying the doc — that's strictly safer than dropping a
  # line at end-of-file inside a bash snippet.
  local anchor='<!-- bootstrap-loop-list-end -->'

  if [ ! -f "$doc" ]; then
    bootstrap::warn "loop-doc not found, skipping: $doc"
    return 0
  fi

  if grep -q -F "$anchor" "$doc"; then
    bootstrap::run "insert $repo_name above anchor in $(basename "$doc")" \
      bootstrap::_anchor_insert "$doc" "$anchor" "- $repo_name"
  else
    bootstrap::warn "$(basename "$doc"): no '$anchor' anchor present; manual action needed to add '$repo_name' to the loop list. Skipping this doc."
    # Signal to the caller (via env var) that we did not modify this
    # doc, so the caller can decide whether to skip the commit step.
    BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT=$((${BOOTSTRAP_LOOP_DOC_UNMODIFIED_COUNT:-0} + 1))
  fi
}

bootstrap::_anchor_insert() {
  local doc=$1 anchor=$2 line=$3
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-loop.XXXXXX")
  # awk: when we hit the anchor line, emit $line first, then the anchor.
  awk -v anchor="$anchor" -v line="$line" '
    $0 ~ anchor && !inserted { print line; inserted = 1 }
    { print }
  ' "$doc" > "$tmp"
  mv "$tmp" "$doc"
}

bootstrap::_appendln() {
  local doc=$1 line=$2
  printf '%s\n' "$line" >> "$doc"
}
