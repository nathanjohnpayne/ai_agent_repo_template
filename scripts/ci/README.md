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
- `check_coderabbit_config` — validates `.coderabbit.yml` parses as YAML and (in the Mergepath template repo only) stays on `reviews.profile: chill` (the nit-suppressing profile per CodeRabbit's docs). Consumer repos inheriting this workflow via the template-mirror bootstrap get the parse + existence checks but may override `profile: assertive` locally without failing CI. Template detection prefers `GITHUB_REPOSITORY` (CI) and falls back to the `origin` remote URL for local runs; override via `MERGEPATH_TEMPLATE_CHECK=force|skip`. Requires `yq` (mikefarah/yq v4+) on the runner. See #237 and #256 P2.
- `check_coderabbit_config_tests` — unit tests for `check_coderabbit_config` itself. Drives the template-vs-consumer detection via fixture repos under `tests/test_check_coderabbit_config.sh`. See #256 P2.
- `check_sweep_unresolved_feedback` — runs unit tests for the #236 weekly feedback sweep pipeline (`scripts/sweep-unresolved-feedback/enumerate.sh`, `render.sh`). PATH-shims `gh` against synthetic fixtures; hermetic.

Inline in `repo_lint.yml` (no local script):

- `check_review_policy_exists` — verifies `.github/review-policy.yml` and `REVIEW_POLICY.md` both exist

See `rules/repo_rules.md` for the full list of enforced checks.
