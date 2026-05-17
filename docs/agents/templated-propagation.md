# Templated propagation — Layer 5 substitution lib

Status: **lib landed; sync integration pending in follow-up PR.**

This doc covers `scripts/lib/template-substitution.sh` — the rendering engine that activates `type: templated` entries in `.mergepath-sync.yml`. It exists ahead of integration so the lib's contract can be reviewed and stabilized before code paths in `scripts/sync-to-downstream.sh`, `scripts/workflow/verify-propagation-pr.sh`, and `scripts/ci/check_sync_manifest` depend on it.

## What the lib does

Renders a source template to per-consumer output using two surfaces:

1. **Variable substitution** — anywhere in the file, `{{key}}` is replaced by the value of `MERGEPATH_FACT_KEY` (uppercased, hyphens → underscores).
2. **Conditional blocks** — `>>> if <expr> ... <<<` markers gate body lines on per-consumer facts. Marker lines are **always stripped** from output regardless of the expression; only the body lines between them are conditional. If `<expr>` is true, body lines are emitted verbatim; if false, body lines are dropped.

Sync-side integration (follow-up PR) is responsible for exporting per-consumer facts from the manifest before invoking the lib. The lib itself reads facts only from the environment.

## Syntax reference

### Variables

```text
hello {{name}}!
ts version {{node_version}}
```

- Missing facts render as empty string in lenient mode (default).
- Set `MERGEPATH_TEMPLATE_STRICT=1` to make a reference-to-unset-fact a hard error (exit code 3).
- Unclosed `{{` (no matching `}}`) is emitted verbatim — no error. The lib is permissive here so accidental token-like sequences in real source files don't false-fail.

### Conditional blocks

```js
// >>> if frameworks contains react
import react from "eslint-plugin-react";
// <<<
```

The leading comment prefix on a marker line is **stripped on parse** — the lib accepts any run of non-alphanumeric characters before the `>>>`/`<<<` sigil, so all of these work:

- `// >>> if ...` / `// <<<` — JS, TS, C, C++, Rust, Go
- `# >>> if ...` / `# <<<` — bash, YAML, Python, TOML
- `-- >>> if ...` / `-- <<<` — SQL, Lua, Haskell
- `<!-- >>> if ... -->` / `<!-- <<< -->` — HTML, XML
- Leading whitespace before the comment chars is allowed.

A kept block's body lines survive verbatim (including their own leading whitespace, comments, etc.). A skipped block drops every line between the markers — the markers themselves never appear in output.

### Expression forms (v1)

Inside `>>> if <expr>`, the lib supports:

| Form | True when |
|---|---|
| `<key>` | `MERGEPATH_FACT_KEY` is set and non-empty |
| `!<key>` | `MERGEPATH_FACT_KEY` is unset or empty |
| `<key> contains <value>` | `<value>` appears as a space-separated word in `MERGEPATH_FACT_KEY` |
| `<key> == <value>` | string equality |
| `<key> != <value>` | string inequality |

`contains` matches at word boundaries — `frameworks contains react` is false when `MERGEPATH_FACT_FRAMEWORKS="react-native"`, true when it's `"react typescript"`. Use distinct values for distinct concepts; don't rely on substring matching.

Anything else in the expression slot is a malformed-template error (exit code 1) with a diagnostic listing the supported forms.

### v1 deliberately omits

- **Nested conditionals.** A second `>>> if` while another is still open is an error. The first real templated source (`examples/eslint.config.js` after Phase C) doesn't need nesting; relax later if a real source does.
- **`else` / `elif`.** Express the alternative as a second top-level block with the negated condition.
- **Loops or iteration.** Out of scope. Per-consumer expansion happens at the sync-call layer, not inside templates.
- **Block-comment-only languages (JSON, CSS-without-`//`).** Templates must be in a language that supports the `<comment-chars> >>> ... <comment-chars> <<<` shape on its own line. Most config-as-code files satisfy this; JSON does not (workaround: use JSON5 or move the templated piece into a `.js` wrapper).

## API

Source the lib, then call:

```bash
source "scripts/lib/template-substitution.sh"

# Render to stdout. Exit 0 success, 1 malformed template, 2 source-file
# missing, 3 unknown fact in strict mode.
template_substitution::render path/to/template.tpl

# Atomic write via mktemp + mv. Same exit codes as render.
template_substitution::render_to path/to/template.tpl path/to/dest

# Expression evaluator exposed for direct testing.
template_substitution::eval_expr "frameworks contains react"
# Returns 0 (true), 1 (false), or 2 (malformed expression).
```

The lib is `set -euo pipefail` internally but does not toggle global `set` state during rendering — callers can use the standard `|| rc=$?` pattern to capture the exit code without their own `set -e` being clobbered.

## Why this syntax — design rationale

This section records the decisions taken so a future reader (or a reviewer asking "why didn't you just use Mustache?") doesn't have to reconstruct the trade-offs.

### Why comment-prefix-agnostic markers, not `{{#if}}…{{/if}}`

Mustache-style conditional markers (`{{#if frameworks.react}}…{{/if}}`) would have been the obvious choice — they're familiar and unambiguous. We picked comment-prefix markers instead because:

1. **A source template that's valid in its target language stays editor-friendly.** `examples/eslint.config.js` with comment markers parses, lints, and previews exactly like a real ESLint config. Mustache `{{#if}}` would break syntax highlighting and prevent in-place evaluation. Templates that look like real code are easier to maintain.
2. **No new dependency.** Pure bash, no vendored renderer, no shell-out to node. Matches the rest of `scripts/lib/`.
3. **Mergepath already considered and rejected `{{TOKEN}}` markers for bootstrap-time name substitution** (`scripts/bootstrap/substitute.sh:19-27`). The rationale there was "markers visible to direct readers — bad UX." The constraint is weaker for templated propagation (template files clearly live under `examples/`, readers expect templating), but the precedent informed the syntax choice — line-comment markers are even more invisible to direct readers than Mustache tokens.

`{{var}}` substitution is retained for the variable-replacement surface because it's the same shape `scripts/bootstrap/substitute.sh` already uses for `MERGEPATH_DESCRIPTION_HERE`-style markers, and conflating two syntaxes for "replace this with a value" is unnecessary churn.

### Why facts in env vars, not a manifest sub-block

The lib is invoked once per `<consumer × templated path>` combination by the sync script. The sync script reads `.mergepath-sync.yml`, extracts the consumer's facts, exports them as `MERGEPATH_FACT_<KEY>=<value>`, then forks the renderer. Passing facts via env is the most-portable way to hand structured data to a bash subprocess without a tempfile or stdin dance. It also keeps the lib trivially testable — tests just export the env and source the lib directly, with no manifest fixture needed.

### Why no nested conditionals in v1

The forcing function (`eslint.config.js` per consumer) has at most one layer of conditionals — independent framework blocks. Allowing nesting from day one would have added a stack-management state machine to the renderer for zero current benefit. The v1 lib explicitly fails on a second open marker so a future need surfaces loud rather than silently producing wrong output.

### Why strict-mode is opt-in, not the default

Real templates will accumulate optional-fact references over time (`{{node_version}}`, `{{lint_glob}}`, etc.) and not every consumer will set every fact. Lenient default avoids forcing every fact to be declared on every consumer just to satisfy the renderer. Strict mode is available for CI checks that want hard-fail behavior (e.g., "every consumer with `frameworks contains typescript` must declare `node_version`").

## Limits and known gaps

- **The lib alone produces no output anywhere yet.** It's wired into `repo_lint.yml` via `scripts/ci/check_template_substitution` so its tests run on every PR, but no manifest entry uses `type: templated` yet. The follow-up integration PR adds that.
- **The lib doesn't know about consumer name or repo.** Facts must be uniform across consumers (e.g., `frameworks`, `node_version`); per-consumer name substitution (`mergepath` → `<consumer>`) still goes through `scripts/bootstrap/substitute.sh`'s allow-list-driven path. Long-term, both should share a single substitution lib (per [#168 Layer 5's original sketch](https://github.com/nathanjohnpayne/mergepath/issues/168) — "factor the substitution logic into `scripts/lib/template-substitution.sh` so bootstrap and sync share the lib"), but that consolidation is non-trivial because the two callers have different semantics (literal name allow-list vs. fact-driven substitution). Tracked as future work.
- **No `--audit`-side rendering yet.** Until the integration PR lands, `--audit` will continue to print "templated (deferred — Layer 5, #168)" for `type: templated` entries.

## What the follow-up PR adds

The next PR builds on this lib to:

1. Add `facts:` schema to consumer entries in `.mergepath-sync.yml`, plus `source:` + `dest:` fields on path entries (so `examples/eslint.config.js` can land at consumer-root `eslint.config.js`).
2. Extend `scripts/sync-to-downstream.sh` to handle `type: templated` — render per consumer using their facts, write to `dest`, commit/PR via the propagation lane.
3. Extend `scripts/ci/check_sync_manifest` to validate the new schema (facts vocabulary, source/dest mapping consistency).
4. Extend `scripts/workflow/verify-propagation-pr.sh` to re-render the source against `mergepath@<sha>` with consumer facts and byte-verify the PR content — closes the propagation-lane gate for templated paths.
5. First templated entry: `examples/eslint.config.js` → `eslint.config.js` across the 6 consumers with non-empty JS/TS surface area, unblocking the [mergepath#250](https://github.com/nathanjohnpayne/mergepath/issues/250) ESLint rollout backlog.
