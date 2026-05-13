#!/usr/bin/env bash
# scripts/bootstrap/board-and-summary.sh — bootstrap wizard stage E.
#
# Stub shipped with #156 sub-A's scaffold. Real implementation lands
# in #156 sub-E ("Project v2 board + summary + bootstrap runbook").
#
# Stub responsibilities (per #156 sub-E):
#   - Create a Project v2 board (or attach to existing #) per
#     BOOTSTRAP_INPUT_PROJECT
#   - Add the new repo to the board
#   - Configure default board views matching mergepath's project layout
#   - Generate a per-run summary report: URLs, next steps, the
#     hand-off checklist for things the wizard couldn't fully
#     automate (Codex environment setup, CodeRabbit app install on
#     non-org repos, etc.)
#   - Ship/update docs/bootstrap-new-repo.md as the operator runbook

set -euo pipefail

bootstrap::stage_board_and_summary() {
  bootstrap::stage_banner "board-and-summary (sub-E stub)"
  local project=${BOOTSTRAP_INPUT_PROJECT:-new}
  if [ "$project" = "new" ]; then
    bootstrap::log "stub: would create a new Project v2 board for ${BOOTSTRAP_INPUT_REPO_NAME}"
  else
    bootstrap::log "stub: would attach ${BOOTSTRAP_INPUT_REPO_NAME} to existing project #${project}"
  fi
  bootstrap::log "stub: would generate the per-run summary + hand-off checklist"
  bootstrap::record_stage "board-and-summary"
  return 0
}
