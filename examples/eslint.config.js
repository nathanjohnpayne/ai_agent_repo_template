// examples/eslint.config.js
//
// Sample ESLint flat-config that consumer repos can copy to satisfy
// the Mergepath ESLint policy (rules/repo_rules.md § ESLint policy).
//
// This file is NOT loaded by ESLint at the Mergepath repo itself —
// Mergepath has no package.json and is exempt from the policy. The
// file lives under examples/ so it can be copied verbatim, then
// customized per consumer.
//
// Layout:
//
//   - Baseline JS recommended ruleset (eslint/js) — required by the
//     Mergepath policy floor.
//   - Three optional, framework-specific blocks (TypeScript, Astro,
//     React). DELETE the ones that don't apply to your repo and
//     install the packages listed in their leading comment.
//
// Install (minimum):
//
//   npm install --save-dev eslint @eslint/js globals
//
// Then, per framework you keep below, add the matching packages
// (the comment above each block lists them).
//
// Run:
//
//   npx eslint .
//
// Format note: this file is intentionally a `.js` (NOT `.mjs`) flat
// config. The `eslint.config.js` filename is the only spelling the
// Mergepath CI check accepts; if you have a strong reason to use
// `.mjs`/`.cjs`/`.ts`, file an exception in `.sync-overrides.yml`
// with a `reason:` per docs/agents/code-modification-rules.md.

import js from "@eslint/js";
import globals from "globals";

// --- Optional: TypeScript ---------------------------------------------------
// npm install --save-dev typescript typescript-eslint
// import tseslint from "typescript-eslint";

// --- Optional: Astro --------------------------------------------------------
// npm install --save-dev eslint-plugin-astro
// import astro from "eslint-plugin-astro";

// --- Optional: React + React Hooks ------------------------------------------
// npm install --save-dev eslint-plugin-react eslint-plugin-react-hooks
// import react from "eslint-plugin-react";
// import reactHooks from "eslint-plugin-react-hooks";

export default [
  // Ignore generated / vendored output. Customize per repo.
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

  // Baseline JS recommended — required by the policy.
  js.configs.recommended,

  // Apply browser + node globals to all JS sources by default. Narrow
  // these per-file-pattern if your repo has a clean split.
  //
  // `*.cjs` files are split out so ESLint parses them as CommonJS
  // (`sourceType: "commonjs"`) rather than ES modules — otherwise
  // top-level `require`/`module.exports` and CommonJS scope rules
  // produce false-positive parse errors. The defaults ESLint applies
  // by extension are: `module` for `.js`/`.mjs`, `commonjs` for
  // `.cjs`; we make that explicit here so the policy is self-documenting.
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

  // ----- TypeScript ---------------------------------------------------------
  // Uncomment the `import tseslint` line above and the spread below.
  // typescript-eslint exposes a flat-compatible `configs.recommended`
  // array; spread it into the top-level config.
  //
  // ...tseslint.configs.recommended,

  // ----- Astro --------------------------------------------------------------
  // Uncomment the `import astro` line above and the spread below.
  // eslint-plugin-astro v1+ exports a flat-compatible `configs` map.
  //
  // ...astro.configs.recommended,

  // ----- React + React Hooks ------------------------------------------------
  // Uncomment the React imports above and the block below.
  //
  // {
  //   files: ["**/*.{jsx,tsx}"],
  //   plugins: {
  //     react,
  //     "react-hooks": reactHooks,
  //   },
  //   languageOptions: {
  //     parserOptions: {
  //       ecmaFeatures: { jsx: true },
  //     },
  //   },
  //   rules: {
  //     ...react.configs.recommended.rules,
  //     ...reactHooks.configs.recommended.rules,
  //     // React 17+ JSX transform: not needed.
  //     "react/react-in-jsx-scope": "off",
  //   },
  //   settings: {
  //     react: { version: "detect" },
  //   },
  // },
];
