# scripts/lib/manifest-fact-helpers.sh
#
# Pure helper: export a consumer's facts:* from a .mergepath-sync.yml
# manifest as MERGEPATH_FACT_* env vars in the current (sub)shell.
# Extracted from scripts/sync-to-downstream.sh (#318) so both the sync
# script AND scripts/workflow/verify-propagation-pr.sh can load the
# same facts without duplicating the yq filter or sourcing the full
# sync script (which carries top-level argument parsing + mode
# dispatch side effects).
#
# Sourcing contract: NO top-level side effects, only function defs.
# Safe to source from any shell that needs the helper.
#
# To use:
#   source scripts/lib/manifest-fact-helpers.sh
#   export_consumer_facts <consumer_name> <manifest_path>
#
# Regression-guarded by tests/test_export_consumer_facts.sh — that
# test asserts the EXACT yq filter shape in this file and the literal
# absence of the broken `if`-then-else form that mikefarah/yq's lexer
# rejects (see the in-function NOTE on the broken-form history). The
# test greps this file directly, so we deliberately avoid writing the
# broken-form literal in any comment block.

# Export a consumer's facts:* from the manifest as MERGEPATH_FACT_*
# env vars in the current (sub)shell. Unsets any prior
# MERGEPATH_FACT_* exports first so successive callers don't see
# stale facts from a different consumer. List-valued facts (yaml
# `[a, b]`) are serialized as space-separated, matching the lib's
# `<key> contains <value>` expectations.
#
# Uses the `env(VAR)` mikefarah/yq form for consumer-name injection
# (the `--arg` jq-compat flag works too but env-var is the
# documented mikefarah idiom).
#
# KEEP IN SYNC with tests/test_export_consumer_facts.sh — that test
# pins the documented mikefarah idiom (a `select(tag == "!!seq")`
# branch combined with the `//` fallback) and rejects the broken
# `if`-then-else form that mikefarah/yq's lexer silently emits
# nothing for (#319). The test greps this file directly, so the
# broken-form literal is deliberately not written out in any comment.
export_consumer_facts() {
  local consumer_name=$1
  local manifest=$2

  # Clean slate — prior consumer's facts must not leak in.
  local var
  for var in $(env | awk -F= '/^MERGEPATH_FACT_/ {print $1}'); do
    unset "$var"
  done

  while IFS=$'\t' read -r key value; do
    [ -z "$key" ] && continue
    local upper
    upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    export "MERGEPATH_FACT_$upper=$value"
  done < <(MERGEPATH_CONSUMER_NAME="$consumer_name" yq -r '
    env(MERGEPATH_CONSUMER_NAME) as $cn
    | .consumers[] | select(.name == $cn) | .facts // {} | to_entries[]
    | .key + "\t"
      + ((.value | select(tag == "!!seq") | join(" "))
         // (.value | tostring))
  ' "$manifest")
  # NOTE on the value-typed serialization: mikefarah/yq v4 does NOT
  # accept a top-level `if`-then-else expression in this filter
  # position (the lexer rejects `if` at column-after-pipe). An
  # earlier draft of this query used that form, which silently
  # produced empty output for every fact, which caused
  # MERGEPATH_FACT_* to never get exported, which made every templated
  # render fall through to the "no frameworks" baseline. swipewatch
  # was the only consumer that didn't notice (its declared frameworks
  # are []), so the swipewatch canary in Phase D fell-positive on
  # the bug. The select+// fallback above is the documented
  # mikefarah idiom for branching on a value's YAML tag.
  #
  # The regression-guard in tests/test_export_consumer_facts.sh
  # greps THIS FILE for the broken-form literal string, so we
  # deliberately do not write it out verbatim in the comment.
}
