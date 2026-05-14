# Repository Rules

Agents must treat every entry here as a binding constraint, not a
suggestion. If a proposed change would violate a rule below, stop and
flag the conflict before proceeding.

## Structure Invariants

- Canonical root files must always exist:
  README.md, AGENTS.md, CLAUDE.md, DEPLOYMENT.md, CONTRIBUTING.md, .ai_context.md
- `CLAUDE.md` must contain only a reading-order pointer to `AGENTS.md`.
  It must never duplicate instructions from AGENTS.md or any other file.
- `AGENTS.md` is a lightweight index pointing to `docs/agents/`. Agent
  instructions live in focused sub-files under `docs/agents/`.
- Tool folders (.cursor/, .claude/, .vscode/) must contain
  configuration only—no instructions, no behavioral rules.
- No new top-level directories without justification documented in
  AGENTS.md or a plans/ entry.

## Forbidden Patterns

- Never push directly to `main`. All changes must go through a
  pull request—even single-line fixes and documentation updates.
  The only exception is if the human explicitly authorizes a
  direct push in chat as a break-glass override.
- Instructions must not be duplicated between root files and
  tool folders.
- `dist/` must not be edited manually. Regenerate through the
  build system only.
- Tests must not be deleted to force a build to pass.
- Secrets must never be committed. Use environment variables or
  a secrets manager.

## CI Enforcement

The following checks run from `scripts/ci/` locally and via `.github/workflows/repo_lint.yml` in CI.
All checks must pass before merge.

- check_required_root_files
- check_no_tool_folder_instructions
- check_no_forbidden_top_level_dirs
- check_dist_not_modified
- check_spec_test_alignment
- check_duplicate_docs
- check_review_policy_exists (inline in repo_lint.yml): .github/review-policy.yml and REVIEW_POLICY.md must both exist
- check_codex_scripts: `scripts/codex-review-request.sh` and `scripts/codex-review-check.sh` must exist and be executable in every repo. Required for `CLAUDE.md` step 8 Phase 4a (automated external review via the OpenAI Codex GitHub App) — missing either script silently forces callers to Phase 4b fallback.
- check_gh_as_author: `tests/test_gh_as_author.sh` and `tests/test_gh_pr_guard.sh` must exist and pass. Covers the #241 wrapper (`scripts/gh-as-author.sh`) and the identity-check addition to `scripts/hooks/gh-pr-guard.sh` that prevent the gh keyring active-identity glitch from landing a PR under the wrong account.
- check_coderabbit_config: when `.coderabbit.yml` is present, it must parse as YAML, and (in the Mergepath template repo only) set `reviews.profile: chill` — `assertive` re-enables 🧹 Nitpick comments per CodeRabbit's profile semantics. The file's existence is required *only* when `.github/review-policy.yml` does not have `coderabbit.enabled: false`; the sub-D wizard (#248) intentionally deletes `.coderabbit.yml` and flips `coderabbit.enabled: false` together when bootstrapping a private consumer repo (CodeRabbit's free tier is public-only), and the check honors that combined state. See #237 for the profile rationale (the 2026-05-13 sweep surfaced 56 unresolved nit threads across 9 repos, none substantive) and #256 for the private-repo scoping. Requires `yq` (mikefarah/yq v4+) on the runner.
