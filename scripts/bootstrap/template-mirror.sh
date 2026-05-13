#!/usr/bin/env bash
# scripts/bootstrap/template-mirror.sh — bootstrap wizard stage B.
#
# This is the STUB shipped with #156 sub-A's scaffold. The real
# implementation lands in #156 sub-B ("template mirror + name
# substitution + cross-repo loop update"). For now the stage prints
# what it WOULD do and records itself as completed so the wizard's
# dispatch shape can be tested end-to-end before sub-B lands.
#
# Stub responsibilities (per #156 sub-B):
#   - Clone mergepath to a working tree
#   - Copy canonical files into the new repo
#   - Apply name substitutions ({{REPO_NAME}}, etc.) to templated files
#   - Update mergepath's .mergepath-sync.yml `consumers:` list to
#     include the new repo
#   - Initialize the new repo's git history

set -euo pipefail

bootstrap::stage_template_mirror() {
  bootstrap::stage_banner "template-mirror (sub-B stub)"
  bootstrap::log "stub: would mirror mergepath template into ${BOOTSTRAP_INPUT_REPO_NAME}"
  bootstrap::log "stub: would apply name substitutions for ${BOOTSTRAP_INPUT_REPO_NAME}"
  bootstrap::log "stub: would add ${BOOTSTRAP_INPUT_REPO_NAME} to mergepath's .mergepath-sync.yml consumers list"
  bootstrap::record_stage "template-mirror"
  return 0
}
