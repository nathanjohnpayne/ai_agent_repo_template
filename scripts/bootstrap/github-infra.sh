#!/usr/bin/env bash
# scripts/bootstrap/github-infra.sh — bootstrap wizard stage C.
# Per #156 sub-C / #205.
#
# Responsibilities (in order):
#   1. `gh repo create --source=. --push` against the target dir
#      (sub-B already ran `git init` + initial commit; this step
#      creates the remote and pushes the bootstrap commit). Legitimate
#      push to main on a greenfield remote — the `gh-pr-guard.sh`
#      "never push to main" hook does NOT apply because there's no
#      `main` to protect yet.
#   2. Seed the 10 canonical labels (needs-external-review,
#      needs-human-review, policy-violation, human-action,
#      agent-action, phase-0..4). Eliminates the first-PR
#      "label not found" friction.
#   3. Invite reviewer-identity collaborators (claude / cursor /
#      codex per BOOTSTRAP_INPUT_REVIEWERS). Each invite is async;
#      the wizard pauses for the human to accept the biometric on
#      each agent's GitHub session.
#   4. Provision the REVIEWER_ASSIGNMENT_TOKEN repo secret. Two
#      paths: reuse an existing 1Password item if present, OR
#      prompt the human to mint a fine-grained PAT.
#   5. Prompt for and provision other LLM secrets
#      (ANTHROPIC_API_KEY, OPENAI_API_KEY) with skip option.
#
# Test discipline:
#   Every gh / op / git call goes through bootstrap::run. Tests
#   exercise this stage via a PATH-shimmed `gh` that records its
#   invocations to a log file, so the test fixture can assert the
#   exact command shape + flag set without contacting GitHub.
#
# Reads (set by the wizard):
#   $TARGET_DIR                Local path of the new repo.
#   $BOOTSTRAP_REPO_OWNER      GitHub owner (default: nathanjohnpayne).
#   $BOOTSTRAP_INPUT_REPO_NAME New repo name.
#   $BOOTSTRAP_INPUT_DESCRIPTION One-line description for gh repo create.
#   $BOOTSTRAP_INPUT_VISIBILITY public|private.
#   $BOOTSTRAP_INPUT_REVIEWERS Comma-separated agent names (claude,cursor,codex).
#
# Env overrides for tests:
#   BOOTSTRAP_SKIP_SECRETS=1            skip steps 4+5 (no live PAT lookup)
#   BOOTSTRAP_REVIEWER_PAT_VALUE=...    supply the PAT inline (path c) for tests
#   BOOTSTRAP_SKIP_INVITE_PAUSE=1       don't wait for "press enter to continue"
#
# Side effects via bootstrap::run (so --dry-run is correct).

set -euo pipefail

# Canonical label set. Each entry: name:hex-color:description.
# Format kept consistent with the existing matchline / mergepath
# label conventions. Colors picked to be distinguishable in the
# GitHub UI light + dark themes.
BOOTSTRAP_LABELS=(
  "needs-external-review:bf0606:External review required before merge"
  "needs-human-review:7057ff:Awaiting human triage or decision"
  "policy-violation:b60205:Blocked by review-policy.yml violation"
  "human-action:0e8a16:Requires human attention"
  "agent-action:1d76db:Agent task — not blocked on human"
  "phase-0:c5def5:Phase 0: foundations"
  "phase-1:bfd4f2:Phase 1: core"
  "phase-2:bfd4f2:Phase 2"
  "phase-3:bfd4f2:Phase 3"
  "phase-4:bfd4f2:Phase 4"
)

# 1Password item ID for the REVIEWER_ASSIGNMENT_TOKEN PAT. If this
# item exists in the operator's vault, sub-step 4 reuses it. Override
# via BOOTSTRAP_REVIEWER_PAT_OP_REF for tests / alternate vaults.
BOOTSTRAP_REVIEWER_PAT_OP_REF="${BOOTSTRAP_REVIEWER_PAT_OP_REF:-op://Private/REVIEWER_ASSIGNMENT_PAT/token}"

bootstrap::stage_github_infra() {
  bootstrap::stage_banner "github-infra"

  local repo_name owner full_repo target visibility description reviewers
  repo_name=$(bootstrap_input repo_name)
  owner="${BOOTSTRAP_REPO_OWNER:-nathanjohnpayne}"
  full_repo="$owner/$repo_name"
  target=${TARGET_DIR:?TARGET_DIR not set by wizard}
  visibility=$(bootstrap_input visibility)
  description=$(bootstrap_input description)
  reviewers=$(bootstrap_input reviewers)

  # Per-step rc capture so the stage propagates failures cleanly
  # (same pattern as stage B sub-#233 round 4).
  local step_rc=0

  # Step 1: create the remote + push the bootstrap commit.
  bootstrap::_create_remote_and_push \
    "$full_repo" "$visibility" "$description" "$target" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: gh repo create / push failed (rc=$step_rc)"
    return "$step_rc"
  fi

  # Step 2: seed labels.
  bootstrap::_seed_labels "$full_repo" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: label seeding failed (rc=$step_rc)"
    return "$step_rc"
  fi

  # Step 3: invite reviewer collaborators.
  bootstrap::_invite_reviewers "$full_repo" "$reviewers" || step_rc=$?
  if [ "$step_rc" -ne 0 ]; then
    bootstrap::err "github-infra: reviewer invitations failed (rc=$step_rc)"
    return "$step_rc"
  fi

  # Step 4+5: provision secrets (REVIEWER_ASSIGNMENT_TOKEN + optional
  # LLM keys). Skippable in tests / for repos that don't need them.
  if [ "${BOOTSTRAP_SKIP_SECRETS:-0}" = "1" ]; then
    bootstrap::log "secret provisioning skipped (BOOTSTRAP_SKIP_SECRETS=1)"
  else
    bootstrap::_provision_reviewer_assignment_token "$full_repo" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      # Secret failures are warned-but-not-fatal — workflows will
      # fail loudly on the first PR if the token isn't set, surfacing
      # the issue. We don't want to block the bootstrap on the human
      # finding a PAT.
      bootstrap::warn "github-infra: REVIEWER_ASSIGNMENT_TOKEN provisioning failed (rc=$step_rc); workflows will require manual secret-set on first PR"
      step_rc=0
    fi

    bootstrap::_provision_llm_secrets "$full_repo" || step_rc=$?
    if [ "$step_rc" -ne 0 ]; then
      bootstrap::warn "github-infra: LLM secret provisioning hit errors (rc=$step_rc); the affected workflows can be re-tried manually"
      step_rc=0
    fi
  fi

  bootstrap::record_stage "github-infra"
  return 0
}

# --- internal helpers ------------------------------------------------------

bootstrap::_create_remote_and_push() {
  local full_repo=$1 visibility=$2 description=$3 target=$4

  # Sanity: sub-B's _init_target_git must have run. If the target has
  # no .git/ we can't push.
  #
  # Skip the existence check in dry-run mode — sub-B's `git init`
  # call also doesn't actually run under --dry-run (bootstrap::run
  # prints instead of executing), so the `.git/` directory wouldn't
  # exist in the dry-run plan either. The check is a safety net for
  # live runs where sub-B SHOULD have created it.
  if [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ] && [ ! -d "$target/.git" ]; then
    bootstrap::err "github-infra: $target has no .git/ — did stage B (template-mirror) run? Use --resume template-mirror to retry."
    return 2
  fi

  # The visibility flag maps to gh's --public / --private / --internal.
  local vis_flag
  case "$visibility" in
    public)   vis_flag="--public"   ;;
    private)  vis_flag="--private"  ;;
    internal) vis_flag="--internal" ;;
    *)
      bootstrap::err "github-infra: unsupported visibility '$visibility' (expected public/private/internal)"
      return 2
      ;;
  esac

  # `gh repo create --source=. --push` legitimately populates main
  # on a greenfield remote. gh-pr-guard.sh's "never push to main"
  # invariant doesn't apply because there's no protected main yet —
  # we're creating it. (The hook only fires on pre-existing repos.)
  bootstrap::run "create remote + push: gh repo create $full_repo $vis_flag --source=$target --push" \
    gh repo create "$full_repo" \
      "$vis_flag" \
      --description "$description" \
      --source="$target" \
      --push
}

bootstrap::_seed_labels() {
  local full_repo=$1
  local spec name color desc

  for spec in "${BOOTSTRAP_LABELS[@]}"; do
    # Field-split on ':' — name:color:description. `description` can
    # contain colons; capture only the first two splits and let the
    # rest be the description.
    name=${spec%%:*}
    local rest=${spec#*:}
    color=${rest%%:*}
    desc=${rest#*:}

    # --force makes the operation idempotent: existing labels get
    # their color/description updated instead of erroring.
    bootstrap::run "label create: $name" \
      gh label create "$name" \
        --repo "$full_repo" \
        --color "$color" \
        --description "$desc" \
        --force \
      || {
        # Single label failure is non-fatal — log and continue with
        # the rest. The summary collects the count.
        bootstrap::warn "github-infra: label '$name' create failed (continuing with remaining labels)"
      }
  done
}

bootstrap::_invite_reviewers() {
  local full_repo=$1 reviewers_csv=$2
  local agent login

  # Split CSV into individual agent names.
  local IFS=','
  set -- $reviewers_csv
  unset IFS

  for agent in "$@"; do
    agent=$(printf '%s' "$agent" | tr -d ' ')
    [ -z "$agent" ] && continue
    login="nathanpayne-$agent"

    bootstrap::run "invite collaborator: $login (write)" \
      gh api -X PUT "repos/$full_repo/collaborators/$login" \
        -f permission=write \
      || {
        # Non-existent agent identity, permission issue, etc. — log
        # and continue. The summary surfaces the gap.
        bootstrap::warn "github-infra: invitation to '$login' failed (continuing)"
      }
  done

  # Pause for the operator to accept each invite via the agent
  # account's GitHub UI. Skippable in tests + non-interactive runs.
  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" != "1" ] \
     && [ "${BOOTSTRAP_SKIP_INVITE_PAUSE:-0}" != "1" ] \
     && [ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ]; then
    echo
    echo "Reviewer-identity collaborator invitations sent."
    echo "Each invitee account needs to accept via:"
    echo "  https://github.com/$full_repo/invitations"
    local reply
    read -r -p "Press Enter once all invitations are accepted (or 'skip' to continue): " reply
    if [ "${reply:-}" = "skip" ]; then
      bootstrap::warn "github-infra: invite-acceptance pause was skipped — subsequent agent-review steps may fail until invitations are accepted"
    fi
  fi
}

bootstrap::_provision_reviewer_assignment_token() {
  local full_repo=$1
  local pat=""

  # Path c (tests / explicit override): caller supplied the PAT
  # inline via env var.
  if [ -n "${BOOTSTRAP_REVIEWER_PAT_VALUE:-}" ]; then
    pat="$BOOTSTRAP_REVIEWER_PAT_VALUE"
    bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: using inline value from BOOTSTRAP_REVIEWER_PAT_VALUE"
  fi

  # Path a (preferred): look up an existing PAT in 1Password.
  if [ -z "$pat" ] && command -v op >/dev/null 2>&1; then
    bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: probing 1Password at $BOOTSTRAP_REVIEWER_PAT_OP_REF"
    # Tolerate op timeouts — fall through to the prompt path if
    # 1Password is locked or the item doesn't exist.
    pat=$(op read "$BOOTSTRAP_REVIEWER_PAT_OP_REF" 2>/dev/null || true)
    if [ -n "$pat" ]; then
      bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN: reusing existing 1Password item"
    fi
  fi

  # Path b: prompt the human to paste a fine-grained PAT. Skipped in
  # auto-prompt=skip mode + dry-run.
  if [ -z "$pat" ]; then
    if [ "${BOOTSTRAP_AUTO_PROMPT:-prompt}" = "skip" ] \
       || [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
      bootstrap::warn "REVIEWER_ASSIGNMENT_TOKEN: no PAT available + prompts skipped; not setting secret"
      return 0
    fi
    echo
    echo "REVIEWER_ASSIGNMENT_TOKEN not found in 1Password."
    echo "Generate a fine-grained PAT at https://github.com/settings/tokens/new"
    echo "  Scopes: Contents:RW, Issues:RW, Pull Requests:RW, Metadata:R"
    echo "  Repository: $full_repo (scoped, not org-wide)"
    read -r -s -p "Paste the PAT (input hidden, blank to skip): " pat
    echo
    if [ -z "$pat" ]; then
      bootstrap::warn "REVIEWER_ASSIGNMENT_TOKEN: human declined to provide a PAT; first PR will fail until manually set"
      return 0
    fi
  fi

  # Set the repo secret. `gh secret set` reads stdin when --body is
  # omitted, so we pipe the PAT in to avoid putting it on the
  # command line (where it could show in process listings + the
  # bootstrap log transcript).
  if [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
    bootstrap::run "set REVIEWER_ASSIGNMENT_TOKEN secret" \
      gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo "$full_repo" --body "<redacted-len=${#pat}>"
    return 0
  fi
  printf '%s' "$pat" | gh secret set REVIEWER_ASSIGNMENT_TOKEN --repo "$full_repo" --body - >&2
  local set_rc=$?
  if [ "$set_rc" -ne 0 ]; then
    return "$set_rc"
  fi
  bootstrap::log "REVIEWER_ASSIGNMENT_TOKEN set on $full_repo (len=${#pat})"
}

bootstrap::_provision_llm_secrets() {
  local full_repo=$1

  # The full set of optional LLM secrets the wizard knows how to
  # provision. Each entry: secret_name:prompt-friendly-description.
  # Add new entries here as upstream tooling needs them.
  local llm_secrets=(
    "ANTHROPIC_API_KEY:Anthropic API key for Claude calls (sk-ant-...)"
    "OPENAI_API_KEY:OpenAI API key for Codex / Cursor calls (sk-...)"
  )

  local secret
  for secret in "${llm_secrets[@]}"; do
    local name=${secret%%:*}
    local desc=${secret#*:}

    if [ "${BOOTSTRAP_AUTO_PROMPT:-prompt}" = "skip" ] \
       || [ "${BOOTSTRAP_DRY_RUN:-0}" = "1" ]; then
      bootstrap::log "LLM secret $name: prompts skipped (dry-run or auto-prompt=skip)"
      continue
    fi

    echo
    echo "$desc"
    local value
    read -r -s -p "Paste $name (input hidden, blank to skip): " value
    echo
    if [ -z "$value" ]; then
      bootstrap::log "LLM secret $name: skipped"
      continue
    fi
    printf '%s' "$value" | gh secret set "$name" --repo "$full_repo" --body - >&2
    bootstrap::log "$name set on $full_repo (len=${#value})"
  done
}
