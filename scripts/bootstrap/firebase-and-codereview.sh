#!/usr/bin/env bash
# scripts/bootstrap/firebase-and-codereview.sh — bootstrap wizard stage D.
# Per #156 sub-D / #206.
#
# Responsibilities (in order):
#   1. Firebase bootstrap (skipped when BOOTSTRAP_INPUT_FIREBASE=none or
#      BOOTSTRAP_SKIP_FIREBASE=1). For each env in dev / [dev+prod]:
#        a. firebase projects:create "$REPO-$env" --display-name ...
#        b. Invoke $MERGEPATH_ROOT/scripts/firebase/op-firebase-setup
#           against the new project (if the helper exists; warn otherwise).
#      Then optionally set ANTHROPIC_API_KEY / OPENAI_API_KEY into
#      `firebase functions:secrets:set` per env. Both prompts are
#      skippable. Finally print URLs the operator needs to click through
#      for .env.local population.
#   2. CodeRabbit posture based on visibility:
#        - public:  verify .coderabbit.yml exists in TARGET_DIR; warn if not.
#        - private: yq-flip .coderabbit.enabled=false in
#                   $TARGET_DIR/.github/review-policy.yml, delete
#                   $TARGET_DIR/.coderabbit.yml, commit + push origin main.
#          The push to main on the new repo is legitimate here: sub-C
#          just created the remote, branch protection isn't on yet.
#   3. Codex App posture:
#        - n: log "Codex App: NOT requested. PRs over external_review_threshold
#             will fall to Phase 4b."
#        - y: print the 3 install URLs (chatgpt-codex-connector,
#             code-review settings, environments settings) and pause for
#             human Enter (skippable via BOOTSTRAP_AUTO_CONFIRM=1).
#
# Reads (set by the wizard):
#   $TARGET_DIR                 Local path of the new repo.
#   $BOOTSTRAP_MERGEPATH_ROOT   Path to mergepath's worktree (for
#                               locating op-firebase-setup).
#   bootstrap_input firebase    none|dev|dev+prod
#   bootstrap_input visibility  public|private
#   bootstrap_input codex_app   y|n
#   bootstrap_input repo_name   New repo's name.
#
# Env overrides for tests / non-interactive runs:
#   BOOTSTRAP_SKIP_FIREBASE=1      same as firebase=none
#   BOOTSTRAP_AUTO_CONFIRM=1       skip "press Enter" prompts
#   BOOTSTRAP_AUTO_PROMPT=skip     skip optional value prompts
#   BOOTSTRAP_FIREBASE_SECRET_ANTHROPIC_API_KEY=...  inline value (tests)
#   BOOTSTRAP_FIREBASE_SECRET_OPENAI_API_KEY=...     inline value (tests)
#   BOOTSTRAP_DRY_RUN=1            bootstrap::run honors this; stage
#                                  also short-circuits any probes that
#                                  would touch firebase / gcloud.
#
# Test discipline: every firebase / git / gh call goes through
# bootstrap::run so the test fixture's PATH-shimmed binaries record the
# invocation shape and the --dry-run path produces a plan without side
# effects.

set -euo pipefail

bootstrap::stage_firebase_and_codereview() {
  bootstrap::stage_banner "firebase-and-codereview"

  local repo_name target firebase_scope visibility codex_app
  repo_name=$(bootstrap_input repo_name)
  target=${TARGET_DIR:?TARGET_DIR not set by wizard}
  firebase_scope=$(bootstrap_input firebase)
  visibility=$(bootstrap_input visibility)
  codex_app=$(bootstrap_input codex_app)

  # Per-step rc capture so the stage propagates failures cleanly
  # (same pattern as stage B sub-#233 round 4 / stage C sub-#239 round 1).
  local step_rc=0

  # Step 1: Firebase bootstrap.
  bootstrap::_firebase_bootstrap "$repo_name" "$firebase_scope" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "firebase-and-codereview: Firebase bootstrap failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 2: CodeRabbit posture.
  bootstrap::_coderabbit_posture "$target" "$visibility" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "firebase-and-codereview: CodeRabbit posture step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  # Step 3: Codex App posture.
  bootstrap::_codex_app_posture "$repo_name" "$codex_app" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "firebase-and-codereview: Codex App posture step failed (rc=$step_rc); aborting stage"
    return "$step_rc"
  fi

  bootstrap::record_stage "firebase-and-codereview"
  return 0
}

# --- internal helpers ------------------------------------------------------

bootstrap::_firebase_bootstrap() {
  local repo_name=$1 firebase_scope=$2

  if [ "${BOOTSTRAP_SKIP_FIREBASE:-0}" = "1" ] || [ "$firebase_scope" = "none" ]; then
    bootstrap::log "Firebase: scope=none (or BOOTSTRAP_SKIP_FIREBASE=1); skipping Firebase setup"
    return 0
  fi

  # Resolve env list from the firebase scope flag. bash 3.2 portable —
  # no associative arrays, no mapfile. The two supported scopes map
  # to a space-separated list of env names.
  local envs
  case "$firebase_scope" in
    dev)       envs="dev" ;;
    dev+prod)  envs="dev prod" ;;
    *)
      bootstrap::err "Firebase: unsupported scope '$firebase_scope' (expected dev / dev+prod / none)"
      return 2
      ;;
  esac

  # Per-env loop: project create + op-firebase-setup invocation.
  # Each project create failure is treated as fatal — a globally-taken
  # project ID is a user-decision blocker (rename or skip), not a
  # silent skip.
  local env project_id step_rc=0
  for env in $envs; do
    project_id="${repo_name}-${env}"

    bootstrap::run "firebase projects:create $project_id" \
      firebase projects:create "$project_id" \
        --display-name "$repo_name ($env)" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::err "Firebase: projects:create failed for $project_id (rc=$step_rc). Project ID may be globally taken — rename via --description / repo-name change, or skip via --firebase none."
      return "$step_rc"
    fi

    # op-firebase-setup is in the mergepath worktree. If it's absent,
    # warn + continue: the firebase project exists; the operator can
    # run the setup helper later manually. Don't fail-closed because
    # that would block a re-runnable step.
    local helper="${BOOTSTRAP_MERGEPATH_ROOT:-}/scripts/firebase/op-firebase-setup"
    if [ -n "${BOOTSTRAP_MERGEPATH_ROOT:-}" ] && [ -x "$helper" ]; then
      bootstrap::run "op-firebase-setup $project_id" \
        "$helper" "$project_id" || step_rc=$?
      if [ "$step_rc" -ne 0 ]; then
        # Non-fatal: gcloud auth may be stale; the operator can
        # re-run the helper manually. Log + continue.
        bootstrap::warn "Firebase: op-firebase-setup failed for $project_id (rc=$step_rc). Try 'gcloud auth application-default login' and re-run: $helper $project_id"
        step_rc=0
      fi
    else
      bootstrap::warn "Firebase: op-firebase-setup helper not found at $helper; deployer SA setup must be run manually for $project_id"
    fi
  done

  # Optional secrets — ANTHROPIC_API_KEY + OPENAI_API_KEY into each
  # env's firebase functions:secrets store. Skippable per secret.
  bootstrap::_firebase_set_functions_secrets "$repo_name" "$envs" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    # Treat secret failures as warned-but-not-fatal — workflows can
    # be re-tried manually. Don't block the bootstrap.
    bootstrap::warn "Firebase: functions secrets provisioning hit errors (rc=$step_rc); re-run firebase functions:secrets:set manually"
    step_rc=0
  fi

  # Web-app config: Firebase console-only, can't be scripted. Print
  # the per-env console URL so the operator can click through and
  # populate .env.local manually.
  bootstrap::log "Firebase: .env.local population required from console:"
  for env in $envs; do
    bootstrap::log "  https://console.firebase.google.com/project/${repo_name}-${env}/settings/general"
  done
}

bootstrap::_firebase_set_functions_secrets() {
  local repo_name=$1 envs=$2

  # Each entry: secret_name:prompt-friendly description. Extend here
  # as new LLM secrets become standard fare for new repos.
  local llm_secrets=(
    "ANTHROPIC_API_KEY:Anthropic API key for Claude calls (sk-ant-...)"
    "OPENAI_API_KEY:OpenAI API key for Codex / Cursor calls (sk-...)"
  )

  local any_fail=0
  local secret name desc env value inline_var

  for secret in "${llm_secrets[@]}"; do
    name=${secret%%:*}
    desc=${secret#*:}

    # Inline override (tests / non-interactive runs). The env var
    # BOOTSTRAP_FIREBASE_SECRET_<NAME> short-circuits the prompt;
    # an empty value also short-circuits, signalling "skip this
    # secret entirely". bash 3.2 portable — no ${var^^}, build the
    # env var name via printf + tr.
    inline_var="BOOTSTRAP_FIREBASE_SECRET_${name}"
    eval "value=\${${inline_var}+set}"
    if [ "${value:-}" = "set" ]; then
      eval "value=\${${inline_var}}"
      if [ -z "$value" ]; then
        bootstrap::log "Firebase secret $name: explicit skip via $inline_var=''"
        continue
      fi
    elif [ "${BOOTSTRAP_AUTO_PROMPT:-prompt}" = "skip" ] \
         || [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
      bootstrap::log "Firebase secret $name: prompts skipped (dry-run or auto-prompt=skip)"
      continue
    else
      echo
      echo "Set $name as a Firebase functions secret in each env?"
      echo "  $desc"
      local set_yn
      read -r -p "Set $name? [y/N]: " set_yn
      case "${set_yn:-}" in
        y|Y|yes|YES) ;;
        *)
          bootstrap::log "Firebase secret $name: skipped"
          continue
          ;;
      esac
      read -r -s -p "Paste $name value (input hidden, blank to skip): " value
      echo
      if [ -z "$value" ]; then
        bootstrap::log "Firebase secret $name: empty value; skipping"
        continue
      fi
    fi

    for env in $envs; do
      local project_id="${repo_name}-${env}"
      # firebase functions:secrets:set reads --data-file or stdin.
      # Use --data-file with a process substitution to keep the
      # secret out of argv. bootstrap::run logs the command shape;
      # the value itself never lands in argv via this path.
      #
      # CAVEAT: dry-run mode logs the redacted command; live mode
      # streams the value into a tempfile that firebase reads,
      # then removes the tempfile.
      if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
        bootstrap::run "firebase functions:secrets:set $name ($env, len=${#value})" \
          firebase --project "$project_id" \
            functions:secrets:set "$name" \
            --data-file -
        continue
      fi

      local tmp
      tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-fb-secret.XXXXXX")
      # Restrict the tempfile to the user before writing the value
      # to it. chmod after mktemp because mktemp's default is
      # 0600 already on macOS+Linux but explicit is cheap insurance.
      chmod 600 "$tmp"
      printf '%s' "$value" >"$tmp"

      local set_rc=0
      bootstrap::run "firebase functions:secrets:set $name ($env, len=${#value})" \
        firebase --project "$project_id" \
          functions:secrets:set "$name" \
          --data-file "$tmp" || set_rc=$?

      rm -f "$tmp"

      if [ "$set_rc" -ne 0 ]; then
        bootstrap::warn "Firebase secret $name: set failed for $project_id (rc=$set_rc); continuing"
        any_fail=1
      fi
    done
  done

  return "$any_fail"
}

bootstrap::_coderabbit_posture() {
  local target=$1 visibility=$2

  case "$visibility" in
    public)
      bootstrap::log "CodeRabbit: public repo — leaving CodeRabbit enabled (template default)"
      if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
        # Skip the existence probe in dry-run — the template-mirror
        # stage's rsync didn't actually run, so the file legitimately
        # won't exist.
        return 0
      fi
      if [ ! -f "$target/.coderabbit.yml" ]; then
        bootstrap::warn "CodeRabbit: expected .coderabbit.yml at $target/.coderabbit.yml (should have been mirrored from template); not found"
      fi
      return 0
      ;;
    private)
      bootstrap::_coderabbit_disable_for_private "$target"
      return $?
      ;;
    *)
      bootstrap::err "CodeRabbit: unsupported visibility '$visibility' (expected public / private)"
      return 2
      ;;
  esac
}

bootstrap::_coderabbit_disable_for_private() {
  local target=$1
  local policy_file="$target/.github/review-policy.yml"
  local coderabbit_file="$target/.coderabbit.yml"

  bootstrap::log "CodeRabbit: private repo — disabling CodeRabbit (free tier is public-only)"

  # In dry-run mode the template-mirror stage didn't actually create
  # the files, so the existence probes would all miss. Emit the
  # planned commands instead and return.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::run "yq -i '.coderabbit.enabled = false' $policy_file" \
      yq -i '.coderabbit.enabled = false' "$policy_file"
    bootstrap::run "rm $coderabbit_file" rm -f "$coderabbit_file"
    bootstrap::run "git add review-policy.yml + .coderabbit.yml" \
      git -C "$target" add .github/review-policy.yml .coderabbit.yml
    bootstrap::run "commit CodeRabbit-disable" \
      git -C "$target" -c commit.gpgsign=false \
        commit -q -m "config: disable CodeRabbit (private repo, free tier is public-only)"
    bootstrap::run "push origin main (CodeRabbit-disable)" \
      git -C "$target" push origin main
    return 0
  fi

  local step_rc=0
  local touched_any=0

  # yq-flip the coderabbit.enabled key. The wizard's preflight requires
  # yq globally so this should always succeed; the check is defense
  # in depth.
  if [ ! -f "$policy_file" ]; then
    bootstrap::warn "CodeRabbit: $policy_file not found; cannot flip coderabbit.enabled. Skipping yq flip (manual edit needed if a future template adds the file)."
  else
    if ! command -v yq >/dev/null 2>&1; then
      bootstrap::err "CodeRabbit: yq is required to flip coderabbit.enabled but is not on PATH. Install via 'brew install yq' (mikefarah/yq, v4+)."
      return 2
    fi
    bootstrap::run "yq flip coderabbit.enabled=false in $policy_file" \
      yq -i '.coderabbit.enabled = false' "$policy_file" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::err "CodeRabbit: yq flip failed (rc=$step_rc)"
      return "$step_rc"
    fi
    touched_any=1
  fi

  # Delete .coderabbit.yml — the CodeRabbit App reads this for
  # per-repo config; with the App disabled there's no point keeping
  # the file. Absent file is fine.
  if [ -f "$coderabbit_file" ]; then
    bootstrap::run "rm $coderabbit_file" rm -f "$coderabbit_file" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::err "CodeRabbit: rm of $coderabbit_file failed (rc=$step_rc)"
      return "$step_rc"
    fi
    touched_any=1
  fi

  if [ "$touched_any" = "0" ]; then
    bootstrap::log "CodeRabbit: no files to modify (review-policy.yml + .coderabbit.yml both absent); nothing to commit"
    return 0
  fi

  # Sanity: target must have .git to commit / push. Without it (e.g.,
  # sub-B's git init didn't run), the commit will fail and the operator
  # needs to resume from earlier.
  if [ ! -d "$target/.git" ]; then
    bootstrap::err "CodeRabbit: $target has no .git/ — re-run from --resume template-mirror to retry"
    return 2
  fi

  # Stage + commit. The earlier yq-flip + rm steps each touched
  # at-most-one file, so build the add list dynamically: include each
  # path only if the working tree has it OR git already tracks it
  # (deletion case after `rm -f`). `git add --all <missing-path>`
  # exits 128 with "pathspec did not match any files" — that would
  # turn the preceding "warn and continue" misses into a hard
  # stage failure, contradicting the absent-file tolerance above.
  # Test code BOOTSTRAP_AUTHOR_NAME / BOOTSTRAP_AUTHOR_EMAIL parallels
  # stage B's pattern.
  local author_name="${BOOTSTRAP_AUTHOR_NAME:-}"
  local author_email="${BOOTSTRAP_AUTHOR_EMAIL:-}"

  # Build the list of paths that exist on disk or are tracked in git
  # (deletion needs a stage). `git ls-files --error-unmatch -- <path>`
  # exits 0 iff git tracks the path; we use the silent variant to
  # avoid spurious stderr noise on the absent-and-untracked case.
  local add_paths=()
  for rel in .github/review-policy.yml .coderabbit.yml; do
    if [ -e "$target/$rel" ] \
       || git -C "$target" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      add_paths+=("$rel")
    fi
  done

  if [ "${#add_paths[@]}" -eq 0 ]; then
    bootstrap::log "CodeRabbit: neither .github/review-policy.yml nor .coderabbit.yml present or tracked; nothing to stage"
    return 0
  fi

  bootstrap::run "git add ${add_paths[*]}" \
    git -C "$target" add --all -- "${add_paths[@]}" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "CodeRabbit: git add failed (rc=$step_rc)"
    return "$step_rc"
  fi

  # Skip commit if the working tree is clean (e.g., the files
  # were absent and nothing actually changed). `git diff --cached
  # --quiet` returns 0 when there's nothing staged.
  if git -C "$target" diff --cached --quiet 2>/dev/null; then
    bootstrap::log "CodeRabbit: no staged changes after add; skipping commit + push"
    return 0
  fi

  if [ -n "$author_name" ] && [ -n "$author_email" ]; then
    bootstrap::run "commit CodeRabbit-disable" \
      git -C "$target" \
        -c "user.name=$author_name" \
        -c "user.email=$author_email" \
        -c commit.gpgsign=false \
        commit -q -m "config: disable CodeRabbit (private repo, free tier is public-only)" || step_rc=$?
  else
    bootstrap::run "commit CodeRabbit-disable" \
      git -C "$target" \
        -c commit.gpgsign=false \
        commit -q -m "config: disable CodeRabbit (private repo, free tier is public-only)" || step_rc=$?
  fi
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "CodeRabbit: commit failed (rc=$step_rc)"
    return "$step_rc"
  fi

  # Push to origin main. Legitimate: sub-C just created the remote
  # and there's no branch protection on the new repo yet. The
  # gh-pr-guard.sh "never push to main" invariant doesn't apply
  # because no protected main exists yet.
  #
  # BOOTSTRAP_SKIP_REMOTE_PUSH=1 (tests) suppresses the push so test
  # fixtures don't need to spin up a bare remote just to satisfy
  # git push origin main. The commit still lands in the local repo;
  # only the push step is short-circuited.
  if [ "${BOOTSTRAP_SKIP_REMOTE_PUSH:-0}" = "1" ]; then
    bootstrap::log "CodeRabbit: BOOTSTRAP_SKIP_REMOTE_PUSH=1 — skipping git push origin main"
    return 0
  fi
  bootstrap::run "push origin main (CodeRabbit-disable)" \
    git -C "$target" push origin main || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "CodeRabbit: push failed (rc=$step_rc); commit is local at $target — push manually once the remote is reachable"
    return "$step_rc"
  fi
}

bootstrap::_codex_app_posture() {
  local repo_name=$1 codex_app=$2

  case "$codex_app" in
    n|"")
      bootstrap::log "Codex App: NOT requested. PRs over external_review_threshold will fall to Phase 4b."
      return 0
      ;;
    y) ;;
    *)
      bootstrap::warn "Codex App: unexpected codex_app value '$codex_app' (expected y/n); treating as 'n'"
      bootstrap::log "Codex App: NOT requested. PRs over external_review_threshold will fall to Phase 4b."
      return 0
      ;;
  esac

  # codex_app=y: print the three install URLs + wait for human Enter.
  echo
  echo "==> Codex GitHub App setup (manual, requires biometric):"
  echo
  echo "  1. Install the App for ${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}/${repo_name}:"
  echo "     https://github.com/apps/chatgpt-codex-connector"
  echo
  echo "  2. Enable Code Review for this repo:"
  echo "     https://chatgpt.com/codex/cloud/settings/code-review"
  echo
  echo "  3. Configure a Codex environment for this repo:"
  echo "     https://chatgpt.com/codex/cloud/settings/environments"
  echo
  echo "  After all three: open a small throwaway PR and verify"
  echo "  chatgpt-codex-connector[bot] auto-reviews. That's the only reliable"
  echo "  'App is review-ready' check from an agent identity"
  echo "  (per CLAUDE.md § Phase 4a verification)."
  echo

  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" = "1" ] \
     || [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::log "Codex App: auto-confirm — skipping the press-Enter pause"
    return 0
  fi

  local reply
  read -r -p "Press Enter once all three steps are complete (or 'skip' to revisit later): " reply
  if [ "${reply:-}" = "skip" ]; then
    bootstrap::warn "Codex App: setup pause skipped — Phase 4a may not be ready until the operator completes the 3 manual steps"
  fi
  return 0
}
