// eslint.config.js (CommonJS variant)
//
// Auto-generated from nathanjohnpayne/mergepath's templated source
// at examples/eslint.config.cjs.js (per the Mergepath ESLint
// standard, mergepath#250). Edit upstream, not this rendered copy
// — local edits will be overwritten on the next propagation run.
//
// This is the CommonJS variant. It's rendered for consumers whose
// package.json does NOT declare `"type": "module"` (default CJS
// resolution). ESM consumers get the sibling examples/
// eslint.config.js (ESM variant) instead — see .mergepath-sync.yml
// for the consumers: partitioning.
//
// >>> if _template_only_notes
// Template-author notes (this block is stripped from every
// rendered consumer copy because no consumer sets
// `facts._template_only_notes`):
//
// Rendered per consumer by scripts/lib/template-substitution.sh
// (#313) using the consumer's `facts.frameworks` from
// `.mergepath-sync.yml`. The CJS variant exists because ESM-syntax
// `eslint.config.js` in a CJS package fails to load (Codex P1 on
// PR #318 by chatgpt-codex-connector caught this gap). Module-
// format partitioning lives in the manifest's consumers: lists
// rather than a per-consumer fact, so the template-author only
// edits one variant at a time and the rendered output is
// trivially CommonJS for every entry in this template's consumers
// list.
//
// Per-consumer facts.frameworks vocabulary (closed set, same as
// ESM variant):
//   typescript  → enables typescript-eslint baseline + TS parsing
//   astro       → enables eslint-plugin-astro
//   react       → enables eslint-plugin-react + react-hooks
//
// A consumer with no frameworks (e.g., swipewatch — pure Node +
// vitest) gets the JS baseline only. Multiple frameworks stack in
// declaration order. Keep this template's body byte-identical (modulo
// import/export syntax) to the ESM variant — divergence between the
// two would render differently for nominally-equivalent CJS vs ESM
// consumers, which is a misfeature.
// <<<

const js = require("@eslint/js");
const globals = require("globals");

// >>> if frameworks contains typescript
const tseslint = require("typescript-eslint");
// <<<
// >>> if frameworks contains astro
const astro = require("eslint-plugin-astro");
// <<<
// >>> if frameworks contains react
const react = require("eslint-plugin-react");
const reactHooks = require("eslint-plugin-react-hooks");
// <<<

module.exports = [
  // Ignore generated / vendored output. Customize per-consumer via
  // a follow-up commit on the propagation PR if a repo needs extras
  // (e.g., functions/lib for cloud-functions repos).
  {
    ignores: [
      "node_modules/**",
      "dist/**",
      "build/**",
      "coverage/**",
      ".astro/**",
      ".next/**",
      ".vercel/**",
    ],
  },

  // Baseline JS recommended — required by the Mergepath policy floor.
  js.configs.recommended,

  // Apply browser + node globals to all JS sources by default. Narrow
  // these per-file-pattern in a follow-up commit if the repo has a
  // clean split (e.g., scripts/* node-only, src/* browser-only).
  //
  // `*.cjs` files are split out so ESLint parses them as CommonJS
  // (`sourceType: "commonjs"`) rather than ES modules — otherwise
  // top-level `require`/`module.exports` and CommonJS scope rules
  // produce false-positive parse errors. The defaults ESLint applies
  // by extension are: `module` for `.js`/`.mjs`, `commonjs` for
  // `.cjs`; we make that explicit here so the policy is
  // self-documenting.
  {
    files: ["**/*.{js,mjs,jsx}"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
  },
  {
    files: ["**/*.cjs"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },
  },

// >>> if frameworks contains typescript
  // TypeScript recommended ruleset — applied to .ts / .tsx via the
  // typescript-eslint plugin's flat-config preset. Includes the
  // parser, the recommended rule set, and the file-glob targeting.
  ...tseslint.configs.recommended,
// <<<

// >>> if frameworks contains astro
  // Astro recommended ruleset — applied to .astro files. The plugin
  // exposes its flat-config-compatible preset under .configs.recommended.
  ...astro.configs.recommended,
// <<<

// >>> if frameworks contains react
  // React + React Hooks recommended rulesets — applied to .jsx / .tsx.
  // Detect the React version automatically from package.json. The
  // React 17+ JSX transform makes `react/react-in-jsx-scope` obsolete;
  // turn it off explicitly so the rule doesn't flag every component.
  {
    files: ["**/*.{jsx,tsx}"],
    plugins: {
      react,
      "react-hooks": reactHooks,
    },
    languageOptions: {
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    rules: {
      ...react.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react/react-in-jsx-scope": "off",
    },
    settings: {
      react: { version: "detect" },
    },
  },
// <<<
];
