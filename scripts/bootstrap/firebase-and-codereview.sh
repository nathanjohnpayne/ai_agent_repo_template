#!/usr/bin/env bash
# scripts/bootstrap/firebase-and-codereview.sh — bootstrap wizard stage D.
#
# Stub shipped with #156 sub-A's scaffold. Real implementation lands
# in #156 sub-D ("Firebase + CodeRabbit posture + Codex App posture").
#
# Stub responsibilities (per #156 sub-D):
#   - Firebase project creation (when BOOTSTRAP_INPUT_FIREBASE != "none")
#   - op-firebase-setup invocation per DEPLOYMENT.md
#   - Mint per-project Firebase deployer SA key, store in 1Password
#   - CodeRabbit App install URL printout (skip if BOOTSTRAP_INPUTS
#     opts out)
#   - Codex App install URL printout (display only; CLAUDE.md notes
#     this can't be fully automated since environment config is
#     manual at chatgpt.com/codex/cloud/settings)
#   - Wire up .github/review-policy.yml's coderabbit/codex blocks per
#     the operator's choices

set -euo pipefail

bootstrap::stage_firebase_and_codereview() {
  bootstrap::stage_banner "firebase-and-codereview (sub-D stub)"
  local fb=${BOOTSTRAP_INPUT_FIREBASE:-none}
  if [ "$fb" = "none" ]; then
    bootstrap::log "stub: firebase=none, skipping Firebase setup"
  else
    bootstrap::log "stub: would create Firebase project (${fb}) + mint deployer SA key"
  fi
  bootstrap::log "stub: would print CodeRabbit App install URL"
  if [ "${BOOTSTRAP_INPUT_CODEX_APP:-prompt}" = "y" ]; then
    bootstrap::log "stub: would print Codex App install URL + environment setup steps"
  else
    bootstrap::log "stub: codex_app=n, skipping Codex App URL printout"
  fi
  bootstrap::record_stage "firebase-and-codereview"
  return 0
}
