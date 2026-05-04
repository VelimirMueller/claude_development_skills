# Frontendskills Plugin — Design Spec

**Date:** 2026-05-04
**Author:** Velimir Mueller
**Status:** Draft, awaiting user review

---

## 1. Goal & non-goals

### Goal

Build a Claude Code plugin called `frontendskills` that captures opinionated, audit-aware development knowledge as on-demand skills. The plugin starts with **frontend** content; **infra** and **backend** domains will be added later under the same plugin.

A skill in this plugin packages both *process* knowledge (how we work — phases of project setup, ordering of decisions) and *technical* knowledge (what we install, which rules apply, what the config looks like). Each skill is **situation-based**: its trigger description names a specific moment in development work (e.g., "starting a new project", "adding error boundaries", "configuring linting"), not a topic.

Every skill is **idempotent**: it audits the current project state first and applies only what is missing. The same skill works on a brand-new project and on a half-baked existing one.

### Non-goals (this first cut)

- Multi-client / cross-AI tool support (would require MCP server — out of scope; see decision 2.1).
- Tracking / observability tooling (Sentry, LogRocket) — error boundary skill leaves a logging seam but does not install a provider.
- Routing setup (TanStack Router / Vue Router) — Tier 2.
- Form library setup (react-hook-form / vee-validate + zod) — Tier 2.
- Editor config (`.editorconfig`, `.vscode/`) — Tier 2.
- Component generator CLI (`pnpm new:atom`) — Tier 2.
- Typed env config — Tier 2.
- i18n / l10n — out of scope.
- Bundle-size budgets, Renovate/Dependabot config — out of scope.
- Public web hosting / publishing of the plugin — local install only.

---

## 2. Architecture decisions

### 2.1 Claude Code plugin, not MCP server

**Decision:** Build as a Claude Code plugin with markdown skill files, not as an MCP server.

**Why:** The user uses Claude Code only and locally. Claude Code's `Skill` tool already does on-demand skill loading by matching descriptions against context — exactly what an MCP server here would be reimplementing. MCP only earns its complexity for cross-client (Cursor, Continue, Claude Desktop) or shared-team scenarios. Neither applies.

**Reversibility:** High. If cross-client need emerges later, a thin MCP server can wrap the same skill markdown files.

### 2.2 Situation-based skill granularity

**Decision:** Each skill names a specific situation in development work, not a topic.

**Why:** The `Skill` tool fires by matching a skill's `description` against current context. A topic-shaped description ("Frontend testing") matches too broadly and triggers in irrelevant contexts; a situation-shaped description ("Use when configuring Vitest + Playwright + Storybook test runner in a frontend project") triggers precisely.

**Implication:** Skill names are verb-first (`scaffold-frontend-project`, `configure-typescript`).

### 2.3 Process + technical blended

**Decision:** Each skill mixes process steps (audit, decide, sequence) and technical content (concrete configs, file contents, commands).

**Why:** The user explicitly chose blended (Question 4, Option C). The situation-based granularity (2.2) is the glue: process and tech belong together for a given moment.

### 2.4 Single plugin, domain-organized internally

**Decision:** One `plugin.json` at the repo root. Skills organized by domain subdirectory: `skills/frontend/`, future `skills/infra/`, `skills/backend/`.

**Why:** Domains are coming (user said so) but per-project enablement is not (user enables the plugin everywhere). One plugin minimizes boilerplate. Domain subdirectories preserve the option of splitting into per-domain plugins later.

### 2.5 Idempotent skills (audit-first)

**Decision:** Every skill body begins with `## 1. Audit current state` and the action steps run conditionally on what is missing. No skill blindly installs.

**Why:** The user explicitly asked for skills that work on existing projects, not just greenfield. Audit-first means the same skill brings any project to standard.

**Pattern:** See section 4.1 for the body skeleton.

---

## 3. Plugin layout

```
frontendskills/
├── .claude-plugin/
│   └── plugin.json
├── README.md
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-05-04-frontendskills-plugin-design.md   (this file)
└── skills/
    └── frontend/
        ├── _shared/
        │   ├── conventions.md
        │   ├── stack-versions.md
        │   └── glossary.md
        ├── bootstrap-frontend-project/
        │   └── SKILL.md
        ├── scaffold-frontend-project/
        │   ├── SKILL.md
        │   └── dependency-matrix.md
        ├── clean-frontend-scaffolding/
        │   ├── SKILL.md
        │   └── boilerplate-removal.md
        ├── configure-typescript/
        │   ├── SKILL.md
        │   ├── tsconfig-rules.md
        │   └── path-aliases.md
        ├── set-up-frontend-structure/
        │   ├── SKILL.md
        │   ├── atomic-design.md
        │   └── folder-conventions.md
        ├── set-up-error-boundaries/
        │   ├── SKILL.md
        │   └── error-boundaries.md
        ├── set-up-design-tokens/
        │   ├── SKILL.md
        │   ├── design-tokens.md
        │   └── dark-mode.md
        ├── set-up-data-layer/
        │   ├── SKILL.md
        │   └── data-layer.md
        ├── configure-test-stack/
        │   ├── SKILL.md
        │   ├── test-strategy.md
        │   ├── visual-regression.md
        │   └── a11y-testing.md
        ├── configure-git-hooks/
        │   ├── SKILL.md
        │   ├── git-hooks.md
        │   └── commit-conventions.md
        ├── configure-frontend-linting/
        │   ├── SKILL.md
        │   ├── eslint-config.md
        │   └── prettier-config.md
        └── configure-ci/
            ├── SKILL.md
            └── ci-workflow.md
```

---

## 4. Authoring conventions

### 4.1 SKILL.md body skeleton

```markdown
---
name: <kebab-case>
description: Use when <specific situation> — <one sentence about what it does>.
---

# <Title Case Name>

## 1. Audit current state
<Read package.json, scan src/, check config files. List what is already in place.>

## 2. Decide what to do
<Branch: nothing → install fresh; partial → fill gaps; complete → exit early.>

## 3. <Action steps, ordered, atomic, idempotent>

## 4. Verify
<Single command that proves the step worked.>

## References
- ./<reference-file>.md — <one-line description>
```

**Hard rules:**

- Audit always first; no skill blindly installs.
- Final step always a verification command (e.g., `pnpm tsc --noEmit`, `pnpm lint`, `pnpm test`, `pnpm build`).
- `description` field starts with `Use when …` and names a situation, not a topic.
- Body kept under ~150 lines. Detail goes to reference files.
- Reference links use a plain relative path (`./<file>.md` for sibling, `../_shared/<file>.md` for shared) so Claude can read them on demand.
- Each skill installs the deps it specifically needs. The scaffold skill (5.2) installs the runtime and framework core; subsequent skills add their own tooling (e.g., 5.9 installs Vitest + jsdom; 5.10 installs Husky + commitlint).

### 4.2 Reference file shape (rules-with-rationale)

```markdown
# <Topic>

## Rule: <rule statement>
**Why:** <reason — constraint, principle, or past failure mode>
**How to apply:** <when this kicks in; what to do>

```ts
// example
```

**Anti-example:**
```ts
// what NOT to do, with why
```

## Rule: <next>
…

## When to deviate
<Edge cases where deviation is sound, with criteria.>
```

**Why this shape:** The *why* and *anti-example* let Claude (and a human reader) handle edge cases the rule didn't anticipate. Rules without rationale degrade into cargo-culting.

### 4.3 Naming conventions

- Skill folders: kebab-case, verb-first (`configure-typescript`, `set-up-error-boundaries`).
- Reference files: kebab-case, noun-form (`atomic-design.md`, `eslint-config.md`).
- Skill `description` opens with `Use when …`.
- Skill `name` (frontmatter) matches its folder name.

### 4.4 Cross-skill knowledge in `_shared/`

Some content applies across multiple skills:

- `conventions.md` — canonical project conventions (path-alias prefix `@/`, src layout, file naming).
- `stack-versions.md` — version policy (Node version, package manager pin, pinned vs caret deps).
- `glossary.md` — atomic-design term definitions, "molecule" vs "organism" criteria.

Skills reference these via `@../_shared/<file>.md`. Single source of truth.

---

## 5. Skills inventory

Each subsection below specifies one skill. The format is consistent: trigger, audit checks, actions, verification, references.

### 5.1 `bootstrap-frontend-project` (umbrella)

**Trigger:**
> Use when starting a new frontend project from zero, or when bringing an existing frontend project up to standard — orchestrates scaffolding, structure, error handling, theming, data layer, tests, hooks, linting, and CI end-to-end.

**Audit:** Detect whether a `package.json` exists. If yes, treat as existing project (audit-mode); if no, treat as greenfield.

**Actions:** Sequence the 11 phase skills in this order, with a checkpoint between each ("phase X done — proceed to phase Y?"):

1. `scaffold-frontend-project`
2. `clean-frontend-scaffolding`
3. `configure-typescript`
4. `set-up-frontend-structure`
5. `set-up-error-boundaries`
6. `set-up-design-tokens`
7. `set-up-data-layer`
8. `configure-test-stack`
9. `configure-git-hooks`
10. `configure-frontend-linting`
11. `configure-ci`

**Verify:** All 11 phase verifications pass (composite).

**References:** none — orchestrator only.

---

### 5.2 `scaffold-frontend-project`

**Trigger:**
> Use when scaffolding a new frontend project — asks framework + dependency questions, runs the scaffold tool, and installs the agreed dependency set (Tailwind, TS, ESLint, Prettier, Playwright, React or Vue + testing-library, TanStack Query, Zustand, Storybook).

**Audit:**
- Is there a `package.json`? If yes, list installed deps and skip the scaffold step.
- Is `vite.config.*` present? If yes, framework is detectable from deps.

**Actions:**

1. Ask via `AskUserQuestion`:
   - Framework: Vue or React (default: React)
   - Package manager: pnpm / npm / yarn / bun (default: pnpm)
   - Confirm default dep set or customize
2. If greenfield: run `pnpm create vite` non-interactively with the chosen framework + TS template.
3. Install Tailwind (`tailwindcss`, `@tailwindcss/vite`) and run its init.
4. Install testing-library matching the framework (`@testing-library/react` + `@testing-library/jest-dom` OR `@testing-library/vue`).
5. Install Playwright, run `pnpm dlx playwright install --with-deps`.
6. Install Storybook with `pnpm dlx storybook@latest init`.
7. Install TanStack Query, Zustand.
8. Install ESLint, Prettier, framework-specific lint plugins (deferred config to skill 5.11).

**Verify:** `pnpm install` exits clean; `pnpm dev` starts the dev server (smoke test).

**References:** `dependency-matrix.md` — full table of every dep, version policy, why it's there, alternatives considered.

---

### 5.3 `clean-frontend-scaffolding`

**Trigger:**
> Use after scaffolding a fresh frontend project to purge default boilerplate — demo components, default styles, placeholder routes, sample assets — before laying down real structure.

**Audit:**
- Detect presence of `App.vue` / `App.tsx` with default Vite content (heuristic: file size + scaffolded import patterns).
- Detect default CSS (`style.css`, `App.css` with default rules).
- Detect demo assets (`vite.svg`, `react.svg`, etc.).

**Actions:**

1. Reduce `App.tsx`/`App.vue` to a minimal shell.
2. Remove default `App.css` / `style.css` content; leave the file with only Tailwind directives if applicable.
3. Delete demo assets in `public/` and `src/assets/`.
4. Reduce `index.html` to a clean shell.

**Verify:** `pnpm dev` starts and renders the empty shell (manual confirm or Playwright smoke).

**References:** `boilerplate-removal.md` — exact list of files/patterns to purge, per framework.

---

### 5.4 `configure-typescript`

**Trigger:**
> Use when setting up or hardening TypeScript in a frontend project — applies strict mode, additional safety flags (noUncheckedIndexedAccess, noImplicitOverride), and consistent path aliases across tsconfig, vite, vitest, playwright, and storybook configs.

**Audit:**
- Inspect `tsconfig.json` for `strict`, `noUncheckedIndexedAccess`, `noImplicitOverride`, `noUnusedLocals`, `noUnusedParameters`.
- Inspect `paths` mapping in tsconfig.
- Inspect `vite.config`, `vitest.config`, `playwright.config`, `.storybook/main.*` for matching alias config.

**Actions:**

1. Update `tsconfig.json` to set strict + safety flags.
2. Add `paths` mapping: `"@/*": ["./src/*"]`.
3. Update `vite.config` (`resolve.alias`) and any other config that resolves modules.
4. Add a barrel test file that imports via alias, verify it resolves.

**Verify:** `pnpm tsc --noEmit` passes; an alias import in `src/__alias-check.ts` (created and removed in this step) compiles.

**References:**
- `tsconfig-rules.md` — every flag with rationale.
- `path-aliases.md` — every config file that needs the alias and exact snippet for each.

---

### 5.5 `set-up-frontend-structure`

**Trigger:**
> Use when laying down folder structure for a frontend project — creates atomic-design component layout (atoms / molecules / organisms / templates / pages) plus hooks-or-composables, libs, utils, and tests folders, with `index.ts` barrel files at each layer.

**Audit:** Detect presence of `src/components/atoms/` (or any of the atomic layers); detect `src/hooks` / `src/composables`; detect `src/libs`, `src/utils`, `src/tests`.

**Actions:**

1. Create:
   ```
   src/
   ├── components/
   │   ├── atoms/
   │   ├── molecules/
   │   ├── organisms/
   │   ├── templates/
   │   └── pages/
   ├── hooks/        (React) OR composables/ (Vue)
   ├── libs/
   ├── utils/
   └── tests/
   ```
2. Drop `index.ts` (barrel) in each, plus a `.gitkeep` if empty.
3. Generate ONE example component per atomic layer (Button atom, SearchInput molecule, Header organism, AuthLayout template, HomePage page) with matching `*.stories.ts` and `*.test.ts` files. Documents the convention.

**Verify:** `pnpm tsc --noEmit` passes; storybook lists the example components.

**References:**
- `atomic-design.md` — full methodology, criteria for each layer, anti-patterns.
- `folder-conventions.md` — naming, barrel pattern, hooks vs composables decision.

---

### 5.6 `set-up-error-boundaries`

**Trigger:**
> Use when adding error boundaries to a frontend project — wires up an app-shell boundary, page-level boundaries, and a reusable component-level boundary with user-friendly fallback UIs and a logging-hook seam.

**Audit:**
- Search for existing `ErrorBoundary` component in `src/`.
- Check whether root component is wrapped.

**Actions:**

1. Detect framework from `package.json`.
2. Generate `src/components/molecules/ErrorBoundary/`. Classified as a molecule because it composes one atom (the fallback UI) with one behavior (catch + report); the rationale and an alternative classification are documented in `error-boundaries.md`.
   - **React:** class component with `getDerivedStateFromError` + `componentDidCatch`.
   - **Vue:** component using `errorCaptured` lifecycle hook with `return false` to halt propagation.
3. Generate fallback atom: `src/components/atoms/ErrorFallback/` — friendly message, "try again" button, dev-only error detail.
4. Wrap root component in app shell (`main.tsx` / `main.ts`) with the boundary.
5. Wrap each page-level template in a boundary.
6. Generate a `reportError(error, info)` stub in `src/libs/error-reporter.ts` — the seam for plugging in Sentry/LogRocket later. Boundary's `componentDidCatch` / `errorCaptured` calls it.
7. Generate one Playwright test: render a wrapped component that throws, assert the fallback UI shows.

**Verify:** Playwright test passes.

**References:** `error-boundaries.md` — why try/catch isn't enough (async, render-phase); React class-component pattern; Vue `errorCaptured` semantics; vanilla wrapper for completeness; placement strategy (multiple at strategic depths, not one mega-boundary); fallback-UI design rules; logging-hook integration; testing the boundary itself.

---

### 5.7 `set-up-design-tokens`

**Trigger:**
> Use when establishing design tokens for a frontend project — extends Tailwind theme with project tokens, sets up CSS variables for runtime theming, and configures light/dark mode foundation.

**Audit:**
- Inspect `tailwind.config.*` for custom theme extensions.
- Search for `:root` CSS variables in stylesheets.
- Check for dark-mode strategy (`darkMode: 'class'` or `'media'`).

**Actions:**

1. Extend Tailwind theme: tokens for color, spacing, radius, font-size, font-weight, line-height, shadow, motion.
2. Define CSS variables in `src/styles/tokens.css` for runtime-changeable tokens (color, radius).
3. Set Tailwind to consume CSS variables: `colors: { primary: 'rgb(var(--color-primary) / <alpha-value>)' }`.
4. Set up dark mode: `darkMode: 'class'` strategy. Add `light` and `dark` token sets in `tokens.css`.
5. Add a tiny `useTheme` hook (React) / `useTheme` composable (Vue) in hooks/composables that toggles a class on `<html>`.

**Verify:** Storybook shows light + dark backgrounds correctly (via Storybook's backgrounds addon or theme toggle).

**References:**
- `design-tokens.md` — token taxonomy (color/spacing/typography/etc.), naming, CSS-vars-vs-hardcoded rule.
- `dark-mode.md` — class vs media strategy trade-offs, FOUC prevention, system preference handling.

---

### 5.8 `set-up-data-layer`

**Trigger:**
> Use when wiring up the data layer of a frontend project — creates a TanStack Query client with sensible defaults, a base fetcher with error handling and retry policy, and seams for auth and global error handling.

**Audit:** Detect existing `QueryClient` instance in `src/`; detect existing fetcher in `src/libs/`.

**Actions:**

1. Create `src/libs/queryClient.ts` — a `QueryClient` with defaults: `staleTime: 30s`, `retry: 1` for queries, `retry: 0` for mutations, `refetchOnWindowFocus: false`.
2. Create `src/libs/fetcher.ts` — a thin `fetch` wrapper that:
   - Sets `Content-Type: application/json` by default.
   - Throws a typed `ApiError` on non-2xx (status, body, url).
   - Has a hook for adding an auth token (reads from a function injected by the consumer — leaves the auth implementation out of scope).
3. Wire `<QueryClientProvider client={queryClient}>` into the app root.
4. Add Devtools (`@tanstack/react-query-devtools` or Vue equivalent) gated to `import.meta.env.DEV`.
5. Generate one example query hook: `src/hooks/useExampleData.ts` — `useQuery({ queryKey: ['example'], queryFn: () => fetcher('/api/example') })`.

**Verify:** `pnpm tsc --noEmit` passes; example query hook compiles.

**References:** `data-layer.md` — why the seam pattern (auth, error handling) instead of monolithic client; query key conventions; mutation patterns; cache invalidation strategy; SSR considerations (out of scope but documented).

---

### 5.9 `configure-test-stack`

**Trigger:**
> Use when wiring up the testing stack of a frontend project — configures Vitest for unit/component, Playwright for end-to-end and visual regression, Storybook test runner for component testing, and axe-core for a11y assertions, with coverage thresholds and matching path aliases.

**Audit:**
- Detect `vitest.config.*`, `playwright.config.*`, `.storybook/test-runner.ts`.
- Detect `@axe-core/playwright` in deps.
- Check for coverage thresholds in vitest config.

**Actions:**

1. Install Vitest stack: `vitest`, `@vitest/coverage-v8`, `jsdom`, `@testing-library/jest-dom` (testing-library framework binding from 5.2 already present).
2. Create `vitest.config.ts` — extends Vite config, JSDOM env, setup file (`src/tests/setup.ts`) wiring testing-library matchers, coverage thresholds (lines 80, branches 70, functions 80).
3. Create `src/tests/setup.ts` — `expect.extend(matchers)`, cleanup after each test.
4. Create `playwright.config.ts` — projects for Chromium (and optionally Firefox/Webkit), screenshot on failure, snapshot dir for VRT.
5. Wire Storybook test runner: install `@storybook/test-runner`, add `pnpm test:storybook` script.
6. Install `@axe-core/playwright`. Generate one Playwright test that runs axe against the home route.
7. Add scripts to `package.json`: `test` (vitest), `test:e2e` (playwright), `test:storybook`, `test:vrt` (playwright with `--update-snapshots` flag note in docs).

**Verify:** `pnpm test`, `pnpm test:e2e`, `pnpm test:storybook` all pass on the example components from skill 5.5.

**References:**
- `test-strategy.md` — what to test where (the testing-trophy or pyramid stance), unit-vs-integration definitions, when to skip a test.
- `visual-regression.md` — Playwright snapshot strategy, deterministic-render patterns, flake mitigation, baseline management.
- `a11y-testing.md` — axe rules to enforce, when manual testing is still needed, page-level vs component-level a11y assertions.

---

### 5.10 `configure-git-hooks`

**Trigger:**
> Use when setting up git hooks for a frontend project — installs Husky for pre-commit and commit-msg, lint-staged to run lint and format on staged files only, and commitlint to enforce conventional commits.

**Audit:**
- Detect `.husky/` directory.
- Detect `lint-staged` config in `package.json` or `.lintstagedrc`.
- Detect `commitlint.config.*`.

**Actions:**

1. If not a git repo, run `git init`.
2. Install `husky`, `lint-staged`, `@commitlint/cli`, `@commitlint/config-conventional`.
3. Run `pnpm exec husky init`.
4. Add `pre-commit` hook calling `pnpm exec lint-staged`.
5. Add `commit-msg` hook calling `pnpm exec commitlint --edit $1`.
6. Configure `lint-staged` in `package.json`: run `eslint --fix` and `prettier --write` on staged TS/TSX/Vue files.
7. Create `commitlint.config.js` extending `@commitlint/config-conventional`.

**Verify:** Make a test commit with a non-conventional message — commitlint blocks it. Make a properly formatted commit — it passes. Roll back the test commits.

**References:**
- `git-hooks.md` — hook scope (pre-commit fast, pre-push for slow), bypass policy, CI as backstop.
- `commit-conventions.md` — full conventional-commits taxonomy with project-specific examples.

---

### 5.11 `configure-frontend-linting`

**Trigger:**
> Use when setting up or refreshing ESLint and Prettier in a frontend project — installs best-practice rule sets (eslint:recommended, typescript-eslint, framework-specific, jsx-a11y or vuejs-accessibility, import, storybook), writes flat config and Prettier config, and runs the first lint pass with auto-fix.

**Audit:**
- Detect `eslint.config.*`, `.prettierrc*`.
- Detect installed lint plugins.

**Actions:**

1. Install: `eslint`, `@typescript-eslint/parser`, `@typescript-eslint/eslint-plugin`, `eslint-plugin-import`, `eslint-plugin-storybook`, framework-specific (`eslint-plugin-react` + `eslint-plugin-react-hooks` + `eslint-plugin-jsx-a11y` OR `eslint-plugin-vue` + `eslint-plugin-vuejs-accessibility`), `eslint-config-prettier`, `prettier`.
2. Write `eslint.config.js` (flat config). Compose recommended sets; layer typed rules using `parserOptions.project`.
3. Write `.prettierrc` with project defaults: `singleQuote: true`, `trailingComma: 'all'`, `printWidth: 100`, `semi: true`.
4. Write `.prettierignore` and `.eslintignore` (or flat-config `ignores`).
5. Add scripts: `lint`, `lint:fix`, `format`, `format:check`.
6. Run `pnpm lint --fix` to apply auto-fixable rules.

**Verify:** `pnpm lint` exits 0 (or only with documented warnings); `pnpm format:check` exits 0.

**References:**
- `eslint-config.md` — every recommended rule set used, every project-specific rule override, rationale per rule.
- `prettier-config.md` — every option, why each value, and how Prettier and ESLint stop fighting (`eslint-config-prettier` last in the cascade).

---

### 5.12 `configure-ci`

**Trigger:**
> Use when setting up CI for a frontend project — generates a GitHub Actions workflow that runs install, lint, type-check, unit tests, e2e tests, build, and visual regression on every PR.

**Audit:** Detect `.github/workflows/*.yml`.

**Actions:**

1. Create `.github/workflows/ci.yml`:
   - Triggers: `pull_request`, `push` to main.
   - Job `verify`: matrix Node versions (latest LTS), install with cache, then `lint`, `tsc --noEmit`, `test`, `build`, `test:storybook`, `test:e2e`.
   - Cache: pnpm store + Playwright browsers.
   - Artifacts: upload Playwright report on failure; upload Storybook static build on success.
2. Create `.github/dependabot.yml` with weekly schedule for npm + github-actions ecosystems (lightweight; not full Renovate).

**Verify:** Workflow YAML is valid (`actionlint` if available, or schema check). The first PR exercises it end-to-end.

**References:** `ci-workflow.md` — job ordering rationale, caching strategy, when to fan out vs fan in, secrets handling, "fail fast" vs "keep going" trade-off.

---

## 6. Reference files inventory

Total reference files: 21 (18 skill-specific + 3 shared). The umbrella skill has none — it is an orchestrator, not a knowledge holder.

| File | Owner skill | Topic |
|---|---|---|
| `dependency-matrix.md` | 5.2 | every dep, version policy, alternatives |
| `boilerplate-removal.md` | 5.3 | files/patterns to purge per framework |
| `tsconfig-rules.md` | 5.4 | TS flags with rationale |
| `path-aliases.md` | 5.4 | alias config across all configs |
| `atomic-design.md` | 5.5 | methodology, criteria, anti-patterns |
| `folder-conventions.md` | 5.5 | naming, barrels, hooks vs composables |
| `error-boundaries.md` | 5.6 | per-framework patterns, placement, fallbacks, logging |
| `design-tokens.md` | 5.7 | token taxonomy, CSS-vars rule |
| `dark-mode.md` | 5.7 | class vs media, FOUC, system preference |
| `data-layer.md` | 5.8 | query keys, mutations, cache, auth seam |
| `test-strategy.md` | 5.9 | what-to-test-where stance |
| `visual-regression.md` | 5.9 | Playwright snapshots, flake mitigation |
| `a11y-testing.md` | 5.9 | axe rules, manual gaps |
| `git-hooks.md` | 5.10 | hook scope, bypass policy |
| `commit-conventions.md` | 5.10 | conventional-commits taxonomy |
| `eslint-config.md` | 5.11 | rule sets and overrides |
| `prettier-config.md` | 5.11 | options and ESLint integration |
| `ci-workflow.md` | 5.12 | job ordering, caching, secrets |
| `_shared/conventions.md` | shared | path prefixes, naming, src layout |
| `_shared/stack-versions.md` | shared | Node, package manager, dep version policy |
| `_shared/glossary.md` | shared | atomic terms, "molecule" vs "organism" |

Each follows the rules-with-rationale shape (4.2).

---

## 7. Plugin manifest

`.claude-plugin/plugin.json`:

```json
{
  "name": "frontendskills",
  "version": "0.1.0",
  "description": "Opinionated, audit-aware skills for building scalable, maintainable frontend (and later infra/backend) projects.",
  "author": {
    "name": "Velimir Mueller",
    "email": "velimir.mueller@galvany.de"
  }
}
```

No special configuration — Claude Code auto-discovers `skills/**/SKILL.md`.

---

## 8. Future expansion

### Adding more frontend skills (Tier 2 and beyond)

Drop a new folder under `skills/frontend/`. No manifest changes. Candidates already identified for Tier 2: `set-up-routing`, `set-up-forms`, `configure-editor`, `set-up-component-generator`, `set-up-env-config`, `audit-frontend-project` (a standalone "what's missing here?" report).

### Adding infra and backend domains

```
skills/
├── frontend/    (this spec)
├── infra/       (future)
│   ├── _shared/
│   ├── bootstrap-infra-project/
│   └── ...
└── backend/     (future)
    ├── _shared/
    ├── bootstrap-backend-project/
    └── ...
```

Each domain gets its own umbrella, its own `_shared/`. Cross-domain conventions (e.g., commit conventions) move up to `skills/_shared/` when needed; until then they duplicate per domain.

### Splitting into per-domain plugins

If per-project enablement becomes important, the `skills/<domain>/` subdirectory promotes cleanly to its own plugin folder with its own `plugin.json`. No content rewrites needed.

---

## 9. Out of scope (this first cut)

Already listed in section 1. Repeated here for the implementation-plan author:

- Tracking / observability install (Sentry, LogRocket).
- Routing setup.
- Form library setup.
- Editor config.
- Component generator CLI.
- Typed env config.
- i18n / l10n.
- Bundle-size budgets.
- Renovate / extended dep automation.
- Plugin publishing / public marketplace.

---

## 10. Open questions

1. **Vue version:** Vue 3 only, or also support Vue 2? **Default assumption: Vue 3 only.** Vue 2 reached EOL on 2023-12-31.
2. **React version:** React 18 minimum, prefer 19 if available. **Default assumption: React 19+.**
3. **Node version pin:** match Vercel default (Node 24 LTS). **Default assumption: Node 24.**
4. **Package manager pin:** pnpm by default; honor user's choice if they pick differently in the scaffold question. **Default assumption: pnpm.**
5. **Storybook version:** latest major (currently 8.x as of 2026). Re-evaluate when version 9 ships. **Default assumption: latest stable.**
6. **Hooks vs composables naming:** the structure skill uses `hooks/` for React, `composables/` for Vue. **Confirmed.**
7. **Commit-message scope vocabulary:** conventional-commits standard scopes plus custom ones for the atomic layers (`feat(atom): …`, `feat(molecule): …`)? **Default assumption: standard scopes only; atomic layers go in subject body, not scope.**

These are noted as defaults; the implementation plan can revisit if the user wants different choices.

---

## End of spec
