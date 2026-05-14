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

## ESLint policy

Any repo with a root `package.json` MUST ship an `eslint.config.js`
flat config at the repo root with at least the `@eslint/js`
recommended ruleset, plus framework plugins appropriate to the stack
(e.g., `typescript-eslint` for TypeScript, `eslint-plugin-astro` for
Astro, `eslint-plugin-react` + `eslint-plugin-react-hooks` for React).

Repos without a root `package.json` (Mergepath itself is shell-only,
for example) are exempt. The CI check
(`scripts/ci/check_eslint_config_present`) early-outs with a
not-applicable log line in that case.

Use the flat config format (`eslint.config.js`); legacy
`.eslintrc.*` formats do not satisfy this rule. A starter config that
covers JS + TS + Astro + React lives at `examples/eslint.config.js`.
See `docs/agents/code-modification-rules.md` § ESLint flat-config
policy for the rationale and the per-framework setup notes.

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
- check_codex_p1_gate: `scripts/codex-p1-gate.sh` + `.github/workflows/codex-p1-gate.yml` + `tests/test_codex_p1_gate.sh` must exist and the fixture-driven test suite must pass. Enforces the Codex P1 unresolved-thread merge gate from #235. Gate is OFF by default (`codex.p1_gate.enabled: false`) everywhere except mergepath, which sets it `true` as the v1 narrow-start enforcement target.
- check_gh_as_author: `tests/test_gh_as_author.sh` and `tests/test_gh_pr_guard.sh` must exist and pass. Covers the #241 wrapper (`scripts/gh-as-author.sh`) and the identity-check addition to `scripts/hooks/gh-pr-guard.sh` that prevent the gh keyring active-identity glitch from landing a PR under the wrong account.
- check_eslint_config_present: enforces the ESLint policy above. If `package.json` exists at the repo root, `eslint.config.js` must exist at the repo root and parse cleanly under `node --check`. Repos without a root `package.json` pass with a log line.
- check_eslint_config_policy: runs `tests/test_eslint_policy_check.sh` — unit tests for the policy check itself.
