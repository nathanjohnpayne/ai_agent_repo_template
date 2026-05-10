#!/usr/bin/env bash
# scripts/sync/apply-overrides.sh — override-application library
#
# Sourced by sync-to-downstream.sh's main propagation flow (#168 sub-B).
# Defines two helpers for the per-path decision points where the
# override mechanism feeds into propagation:
#
#   override_should_skip_path  Tests whether a downstream's overrides
#                              file says to skip a given canonical/kit
#                              path. Returns 0 (skip) when matched,
#                              non-zero otherwise. Stores the matched
#                              `reason` in OVERRIDE_SKIP_REASON for
#                              the caller to log.
#
#   override_substitution_for  Looks up an override value for a
#                              templated-path substitution marker.
#                              Returns 0 when an override exists and
#                              writes the value to stdout; non-zero
#                              when the manifest default should win.
#
# Both helpers are read-only against the overrides file. They do NOT
# validate schema (call validate-overrides.sh for that, which is what
# downstream CI does on every PR per #200's design). The contract:
# helpers assume a previously-validated overrides file, treat parse
# errors as "no override" (conservative — safer to over-propagate
# than to silently skip), and never abort the caller.
#
# Sourcing convention:
#
#   # In sync-to-downstream.sh's main script:
#   . "$MERGEPATH_ROOT/scripts/sync/apply-overrides.sh"
#
#   # Then per-consumer, per-path:
#   if override_should_skip_path "$consumer_overrides_file" "$path"; then
#     log "skip $path on $consumer_name: $OVERRIDE_SKIP_REASON"
#     continue
#   fi
#
#   value=$(override_substitution_for "$consumer_overrides_file" "$marker") \
#     && rendered_value="$value" \
#     || rendered_value="$manifest_default"
#
# Globals: OVERRIDE_SKIP_REASON is set to the matched reason when
# override_should_skip_path returns 0.

# --- override_should_skip_path -------------------------------------
#
# Args:
#   $1  Path to the consumer's .sync-overrides.yml. May be empty
#       string or a missing file — both are handled as "no override."
#   $2  The path being propagated (from manifest `paths[].path`).
#
# Returns 0 if the overrides file's skip_paths declares this path,
# non-zero otherwise.

override_should_skip_path() {
  local overrides_file=$1
  local path=$2
  OVERRIDE_SKIP_REASON=""

  if [ -z "$overrides_file" ] || [ ! -f "$overrides_file" ]; then
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 1
  fi

  local reason
  reason=$(yq eval ".skip_paths[]? | select(.path == \"$path\") | .reason" "$overrides_file" 2>/dev/null | head -n 1)
  if [ -n "$reason" ] && [ "$reason" != "null" ]; then
    OVERRIDE_SKIP_REASON="$reason"
    return 0
  fi
  return 1
}

# --- override_substitution_for -------------------------------------
#
# Args:
#   $1  Path to the consumer's .sync-overrides.yml.
#   $2  Substitution marker name (the key under `substitutions:`).
#
# Returns 0 when an override exists; writes the override value to
# stdout. Returns non-zero when no override is present (caller falls
# back to the manifest default).
#
# Multi-line override values are passed through verbatim. The caller
# is responsible for any escaping required by the templating engine.

override_substitution_for() {
  local overrides_file=$1
  local marker=$2

  if [ -z "$overrides_file" ] || [ ! -f "$overrides_file" ]; then
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    return 1
  fi

  local has_key
  has_key=$(yq eval ".substitutions | has(\"$marker\")" "$overrides_file" 2>/dev/null || echo "false")
  if [ "$has_key" != "true" ]; then
    return 1
  fi

  yq eval ".substitutions.$marker" "$overrides_file" 2>/dev/null
  return 0
}
