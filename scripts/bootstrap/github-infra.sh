#!/usr/bin/env bash
# scripts/bootstrap/github-infra.sh — bootstrap wizard stage C.
#
# Stub shipped with #156 sub-A's scaffold. Real implementation lands
# in #156 sub-C ("GitHub repo creation + labels + collaborators +
# secrets").
#
# Stub responsibilities (per #156 sub-C):
#   - `gh repo create` (with visibility from BOOTSTRAP_INPUT_VISIBILITY)
#   - Create the canonical labels (needs-external-review, observation,
#     risk, post-review, etc.)
#   - Invite reviewer-identity collaborators (claude / cursor / codex)
#   - Configure required secrets (REVIEWER_ASSIGNMENT_TOKEN, etc.)
#   - Set up branch protection on main per REVIEW_POLICY.md

set -euo pipefail

bootstrap::stage_github_infra() {
  bootstrap::stage_banner "github-infra (sub-C stub)"
  bootstrap::log "stub: would gh repo create ${BOOTSTRAP_INPUT_REPO_NAME} (${BOOTSTRAP_INPUT_VISIBILITY})"
  bootstrap::log "stub: would create canonical labels"
  bootstrap::log "stub: would invite reviewers: ${BOOTSTRAP_INPUT_REVIEWERS}"
  bootstrap::log "stub: would configure required secrets + branch protection"
  bootstrap::record_stage "github-infra"
  return 0
}
