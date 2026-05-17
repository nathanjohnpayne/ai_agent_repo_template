// eslint.config.js
//
// Auto-generated from nathanjohnpayne/mergepath's templated source
// at examples/eslint.config.js (per the Mergepath ESLint standard,
// mergepath#250). Edit upstream, not this rendered copy — local
// edits will be overwritten on the next propagation run.
//
// >>> if _template_only_notes
// Template-author notes (this block is stripped from every
// rendered consumer copy because no consumer sets
// `facts._template_only_notes`):
//
// Rendered per consumer by scripts/lib/template-substitution.sh
// (#313) using the consumer's `facts.frameworks` from
// `.mergepath-sync.yml`, then propagated to the consumer repo's
// root as `eslint.config.js` via the templated path-type in
// scripts/sync-to-downstream.sh (Phase B2, #316).
//
// Per-consumer facts.frameworks vocabulary (closed set):
//   typescript  → enables typescript-eslint baseline + TS parsing
//   astro       → enables eslint-plugin-astro
//   react       → enables eslint-plugin-react + react-hooks
//
// A consumer with no frameworks (e.g., swipewatch — pure Node +
// vitest) gets the JS baseline only. Multiple frameworks stack in
// declaration order.
// <<<

import js from "@eslint/js";
import globals from "globals";

// >>> if frameworks contains typescript
import tseslint from "typescript-eslint";
// <<<
// >>> if frameworks contains astro
import astro from "eslint-plugin-astro";
// <<<
// >>> if frameworks contains react
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
// <<<

export default [
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
