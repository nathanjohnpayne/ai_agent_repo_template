# scripts/ci/

CI enforcement scripts for this repository.

The checks defined here mirror the steps in `.github/workflows/repo_lint.yml`
and can also be run locally before pushing.

Local scripts:

- `check_required_root_files`
- `check_no_tool_folder_instructions`
- `check_no_forbidden_top_level_dirs`
- `check_dist_not_modified`
- `check_spec_test_alignment`
- `check_duplicate_docs`
- `check_codex_scripts` — verifies `scripts/codex-review-request.sh` and `scripts/codex-review-check.sh` exist and are executable (Phase 4a helper-script presence check)
- `check_sync_manifest` — validates `.mergepath-sync.yml` (manifest read by `scripts/sync-to-downstream.sh`): schema version, consumer shape, every referenced path exists, every path type is recognized. Requires `yq` (mikefarah/yq v4+) on the runner. See #168.
- `check_eslint_config_present` — enforces the ESLint flat-config policy (`rules/repo_rules.md` § ESLint policy). If a root `package.json` exists, `eslint.config.js` must exist at the repo root and parse under `node --check`. Repos without a root `package.json` (mergepath itself) pass via an early-out. See #250.
- `check_eslint_config_policy` — runs `tests/test_eslint_policy_check.sh` (unit tests for the policy check).

Inline in `repo_lint.yml` (no local script):

- `check_review_policy_exists` — verifies `.github/review-policy.yml` and `REVIEW_POLICY.md` both exist

See `rules/repo_rules.md` for the full list of enforced checks.
