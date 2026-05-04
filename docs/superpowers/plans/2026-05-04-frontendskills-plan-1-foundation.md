# Frontendskills Plugin — Implementation Plan 1: Foundation + 4 Simpler Skills

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up the plugin skeleton (`.claude-plugin/plugin.json`, README, validator script, `_shared/` references) and implement the 4 simplest content-only skills: `clean-frontend-scaffolding`, `set-up-frontend-structure`, `configure-typescript`, `set-up-error-boundaries`.

**Architecture:** Markdown-only artifacts (no runtime app code). Each skill is a folder under `skills/frontend/<name>/` with a `SKILL.md` plus one or more reference `.md` files. Frontmatter is YAML (`name`, `description`). A bash + `jq` validator script enforces structure (manifest valid, frontmatter present, every reference link resolves).

**Tech Stack:** Markdown, YAML frontmatter, Bash, `jq`, Conventional Commits.

**Spec:** [docs/superpowers/specs/2026-05-04-frontendskills-plugin-design.md](../specs/2026-05-04-frontendskills-plugin-design.md). This plan implements sections 5.3, 5.4, 5.5, 5.6 (the four content-only skills) plus §3 (layout), §4 (conventions), §6 (`_shared/`), §7 (manifest).

**Plan series:** This is Plan 1 of 3. Plans 2 and 3 will add the remaining 8 skills (4 tooling + 4 complex/orchestration).

---

## File Structure

Files this plan creates (17 total):

| Path | Purpose |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest |
| `README.md` | Plugin overview + install instructions |
| `scripts/validate.sh` | Bash validator (manifest + frontmatter + reference link resolution) |
| `.gitignore` | Ignore OS / editor cruft |
| `skills/frontend/_shared/conventions.md` | Canonical project conventions |
| `skills/frontend/_shared/stack-versions.md` | Version policy |
| `skills/frontend/_shared/glossary.md` | Atomic-design term definitions |
| `skills/frontend/clean-frontend-scaffolding/SKILL.md` | Skill |
| `skills/frontend/clean-frontend-scaffolding/boilerplate-removal.md` | Reference |
| `skills/frontend/set-up-frontend-structure/SKILL.md` | Skill |
| `skills/frontend/set-up-frontend-structure/atomic-design.md` | Reference |
| `skills/frontend/set-up-frontend-structure/folder-conventions.md` | Reference |
| `skills/frontend/configure-typescript/SKILL.md` | Skill |
| `skills/frontend/configure-typescript/tsconfig-rules.md` | Reference |
| `skills/frontend/configure-typescript/path-aliases.md` | Reference |
| `skills/frontend/set-up-error-boundaries/SKILL.md` | Skill |
| `skills/frontend/set-up-error-boundaries/error-boundaries.md` | Reference |

---

## Task 1: Plugin manifest

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: Create directory**

```bash
mkdir -p .claude-plugin
```

- [ ] **Step 2: Write `.claude-plugin/plugin.json`**

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

- [ ] **Step 3: Verify the JSON parses**

Run: `jq . .claude-plugin/plugin.json`

Expected: pretty-printed JSON output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat(plugin): add manifest"
```

---

## Task 2: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# frontendskills

Opinionated, audit-aware Claude Code skills for building scalable, maintainable frontend projects.

This plugin captures development knowledge — process and technical, blended — as situation-based skills that Claude loads on demand. Each skill is **idempotent**: it inspects the current project state first and applies only what is missing. The same skill works on a brand-new project and on an existing one being brought up to standard.

## Status

**0.1.0 — under construction.** Frontend skills first; infrastructure and backend domains will follow under the same plugin.

## What's inside

Skills live under `skills/frontend/`. Each skill is a folder containing a `SKILL.md` (the trigger + body Claude sees first) and one or more reference `.md` files for deep-dive rules with rationale.

Shared knowledge across multiple frontend skills lives in `skills/frontend/_shared/`:
- `conventions.md` — canonical project conventions (paths, naming, prefixes).
- `stack-versions.md` — version policy (Node, package manager, dep version pinning).
- `glossary.md` — atomic-design term definitions.

## Install (local)

This plugin is intended for local Claude Code use. Add the plugin's directory as a marketplace path in your Claude Code settings; Claude Code auto-discovers `skills/**/SKILL.md`.

## Validate

Run `bash scripts/validate.sh` to check that:
- `.claude-plugin/plugin.json` parses and has the required fields.
- Every `SKILL.md` has YAML frontmatter with `name` and `description` (the latter starting with `Use when`).
- Every relative reference link in a `SKILL.md` resolves to an existing file.

## Design spec

See `docs/superpowers/specs/2026-05-04-frontendskills-plugin-design.md` for the full design rationale, skill inventory, and authoring conventions.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README"
```

---

## Task 3: .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```
# OS
.DS_Store
Thumbs.db

# Editors
.idea/
.vscode/*
!.vscode/extensions.json
!.vscode/settings.json

# Logs
*.log
npm-debug.log*
yarn-debug.log*
pnpm-debug.log*

# Tooling
node_modules/
.pnpm-store/
.cache/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore"
```

---

## Task 4: Validator script

**Files:**
- Create: `scripts/validate.sh`

The validator is bash + `jq`. It runs three checks: manifest validity, SKILL.md frontmatter, and reference-link resolution. It exits non-zero on the first failure with a clear message.

- [ ] **Step 1: Create directory**

```bash
mkdir -p scripts
```

- [ ] **Step 2: Write `scripts/validate.sh`**

```bash
#!/usr/bin/env bash
# Validate plugin structure: manifest, SKILL.md frontmatter, reference link resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
fail()  { red "FAIL: $1"; exit 1; }

# Required tools
command -v jq >/dev/null 2>&1 || fail "jq not installed (apt install jq, brew install jq)"

# 1. Manifest
MANIFEST=".claude-plugin/plugin.json"
[ -f "$MANIFEST" ] || fail "missing $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "$MANIFEST is not valid JSON"
for field in name version description author; do
  jq -e ".$field" "$MANIFEST" >/dev/null || fail "$MANIFEST missing field: $field"
done

# 2. Skill files
mapfile -t SKILLS < <(find skills -type f -name SKILL.md 2>/dev/null | sort)
[ "${#SKILLS[@]}" -gt 0 ] || fail "no SKILL.md files found under skills/"

for SKILL in "${SKILLS[@]}"; do
  # Frontmatter present (file starts with ---)
  head -n 1 "$SKILL" | grep -qx -- '---' || fail "$SKILL missing YAML frontmatter opener (---)"

  # Frontmatter has name and description
  FRONTMATTER=$(awk '/^---$/{c++; if(c==2) exit; next} c==1' "$SKILL")
  echo "$FRONTMATTER" | grep -Eq '^name:\s+\S' || fail "$SKILL missing frontmatter field: name"
  echo "$FRONTMATTER" | grep -Eq '^description:\s+Use when' || fail "$SKILL description must start with 'Use when'"

  # name in frontmatter matches folder name
  NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | sed -E 's/^name:[[:space:]]+//')
  FOLDER=$(basename "$(dirname "$SKILL")")
  [ "$NAME" = "$FOLDER" ] || fail "$SKILL name '$NAME' does not match folder '$FOLDER'"
done

# 3. Reference link resolution (relative .md links)
for SKILL in "${SKILLS[@]}"; do
  DIR="$(dirname "$SKILL")"
  mapfile -t REFS < <(grep -Eo '\.{1,2}/[A-Za-z0-9_./-]+\.md' "$SKILL" | sort -u || true)
  for REF in "${REFS[@]}"; do
    TARGET="$DIR/$REF"
    [ -f "$TARGET" ] || fail "$SKILL references missing file: $REF (resolved to $TARGET)"
  done
done

green "OK: validator passed (${#SKILLS[@]} skills checked)"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x scripts/validate.sh
```

- [ ] **Step 4: Run validator (expected to fail — no skills yet)**

Run: `bash scripts/validate.sh`

Expected output: `FAIL: no SKILL.md files found under skills/` and exit code 1.

This proves the validator wires up correctly and detects missing content.

- [ ] **Step 5: Commit**

```bash
git add scripts/validate.sh
git commit -m "chore(scripts): plugin structure validator"
```

---

## Task 5: Shared — `conventions.md`

**Files:**
- Create: `skills/frontend/_shared/conventions.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/frontend/_shared
```

- [ ] **Step 2: Write `skills/frontend/_shared/conventions.md`**

```markdown
# Frontend Conventions

Canonical project conventions shared across frontend skills. When a skill needs to know "what's the path-alias prefix?" or "how do we name barrel files?", it links here.

## Rule: path-alias prefix is `@/`
**Why:** Single, short prefix avoids ambiguity (vs deep relative paths) and matches the de-facto Vite/Next/Nuxt default. Two-character prefix keeps imports compact.
**How to apply:** `@/components/atoms/Button` instead of `../../../components/atoms/Button`. Configure consistently in tsconfig, vite, vitest, playwright, and storybook (see `configure-typescript` skill, ref `path-aliases.md`).

```ts
// good
import { Button } from '@/components/atoms/Button';

// bad
import { Button } from '../../../components/atoms/Button';
```

## Rule: source root is `src/`
**Why:** Matches every modern scaffold (Vite, Next, Nuxt). Avoids debate.
**How to apply:** All app code lives under `src/`. Tests under `src/tests/` or co-located with subjects (see `folder-conventions.md`). Public assets under `public/`.

## Rule: file names match exported identifier
**Why:** Easier navigation, predictable imports.
**How to apply:**
- Component file `Button.tsx` exports a `Button` (default + named both fine; pick one and stick).
- Hook file `useToggle.ts` exports `useToggle` (named only — hooks rarely warrant default exports).
- Composable file `useToggle.ts` (Vue) — same naming as React hooks; the folder differs.
- Util file `formatDate.ts` exports `formatDate` (named export).

**Anti-example:**
```ts
// bad: file Card.tsx exports an unrelated identifier
export const Tile = () => null;
```

## Rule: barrel files (`index.ts`) re-export, never define
**Why:** A file that both defines and re-exports is doing two jobs. Split.
**How to apply:**
```ts
// skills/frontend/components/atoms/index.ts — barrel
export * from './Button';
export * from './ErrorFallback';
```

**Anti-example:**
```ts
// bad: defining inline
export const Button = () => null;
export * from './ErrorFallback';
```

## Rule: framework-specific folder for hooks vs composables
**Why:** Mirrors framework idiom. React projects say "hook"; Vue projects say "composable". Mixing terms creates cognitive overhead.
**How to apply:**
- React → `src/hooks/`
- Vue → `src/composables/`

## When to deviate

- **Path alias prefix:** if the project already uses `~/` (Nuxt convention) or `app/` (legacy), keep the existing prefix. Don't churn imports.
- **Source root:** if the project uses a non-`src/` layout (e.g., `app/` for Next.js App Router), follow what's there. Skills audit the layout before assuming.
```

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/_shared/conventions.md
git commit -m "docs(shared): conventions reference"
```

---

## Task 6: Shared — `stack-versions.md`

**Files:**
- Create: `skills/frontend/_shared/stack-versions.md`

- [ ] **Step 1: Write `skills/frontend/_shared/stack-versions.md`**

```markdown
# Stack Versions

Version policy for frontend projects scaffolded by these skills.

## Rule: Node 24 LTS
**Why:** Latest LTS at time of writing (2026-05). Matches Vercel default. Long-term support window simplifies CI choices.
**How to apply:** Pin via `.nvmrc` (`24`) and `engines.node` in `package.json` (`>=24.0.0`).

## Rule: pnpm by default; honor user choice
**Why:** pnpm has a strict dependency hoisting model that catches "phantom dep" bugs early, plus efficient disk usage via content-addressable store. Defaults matter, but the user's preference matters more.
**How to apply:** Default to pnpm; if the user picks npm/yarn/bun in the scaffold question, use that and adjust scripts/lockfiles.

## Rule: caret (^) for runtime deps; pinned (~) for build/test tooling
**Why:** Runtime deps benefit from minor-version updates (security, perf). Build/test tooling churn breaks reproducibility — pin to patch only.
**How to apply:**
- `react`, `vue`, `tanstack/query`, etc. → `^X.Y.Z`
- `vite`, `vitest`, `playwright`, `eslint`, `typescript` → `~X.Y.Z`

**Anti-example:**
```json
// bad: every dep pinned to exact version (over-tight; manual bumps for security patches)
"dependencies": { "react": "19.2.0" }

// bad: every dep on caret (test/build tooling can break minor)
"devDependencies": { "vite": "^6.0.0" }
```

## Rule: Vue 3 only; React 19+
**Why:** Vue 2 reached EOL 2023-12-31. React 19 stabilized concurrent features.
**How to apply:** Scaffold skill rejects requests for Vue 2; defaults React to 19.

## Rule: Storybook latest stable major
**Why:** Storybook major versions ship breaking config changes. Pin in lockfile but accept majors via explicit upgrade.
**How to apply:** Use `pnpm dlx storybook@latest init`. Don't fight an existing major; only upgrade as a deliberate task.

## When to deviate

- **Older Node:** if a hosting target (e.g., legacy Lambda runtime) requires Node < 24, document the constraint in the project's README and pin accordingly.
- **Yarn classic / npm:** projects with established lockfiles in another tool — keep what's there.
```

- [ ] **Step 2: Commit**

```bash
git add skills/frontend/_shared/stack-versions.md
git commit -m "docs(shared): stack versions reference"
```

---

## Task 7: Shared — `glossary.md`

**Files:**
- Create: `skills/frontend/_shared/glossary.md`

- [ ] **Step 1: Write `skills/frontend/_shared/glossary.md`**

```markdown
# Glossary

Atomic-design and frontend-specific terms used across these skills, defined to remove ambiguity.

## Atom
A UI element that cannot be broken into smaller meaningful UI parts without losing function. Examples: `Button`, `Input`, `Icon`, `Label`, `Spinner`, `ErrorFallback` (a small message + retry control).

**Test:** if you removed any internal element, would it still be a recognizable, useful UI primitive? If no, it's an atom.

## Molecule
A small, opinionated composition of atoms doing one job. Examples: `SearchInput` (Input + Button), `FormField` (Label + Input + ErrorMessage), `ErrorBoundary` (catch behavior + ErrorFallback atom).

**Test:** does it compose 2–4 atoms with one clear purpose? If yes, molecule. If it reaches into pages/layout, it's an organism.

## Organism
A larger composition that combines molecules and atoms into a meaningful interface region. Examples: `Header`, `ProductCard`, `Sidebar`, `LoginForm`.

**Test:** does it represent a recognizable section of UI a user might point at and name ("the header")? If yes, organism.

## Template
A page layout that arranges organisms into a recognizable page structure, with no specific content. Examples: `MarketingLayout`, `DashboardLayout`, `AuthLayout`.

**Test:** does the file specify *where* organisms go but not *which specific data* they show? If yes, template.

## Page
A specific instance of a template with real content and route binding. Examples: `HomePage`, `ProductDetailPage`, `LoginPage`.

**Test:** does it map to a route and pull real data? If yes, page.

## "Component-level" vs "page-level" boundary
Used in error-boundary placement.
- **Component-level:** wraps a single risky component (third-party widget, data-driven card).
- **Page-level:** wraps an entire page template so a single route's failure stays isolated.
- **App-shell:** wraps the root so a catastrophic error doesn't blank the whole app.

## Audit-first
Convention used by every skill in this plugin: before installing or modifying anything, the skill reads the current project state and decides what (if anything) needs to change. See spec section 2.5.

## Idempotent
A skill is idempotent if running it twice produces the same final state as running it once. Audit-first is the mechanism that makes skills idempotent.
```

- [ ] **Step 2: Commit**

```bash
git add skills/frontend/_shared/glossary.md
git commit -m "docs(shared): glossary"
```

---

## Task 8: Skill — `clean-frontend-scaffolding`

**Files:**
- Create: `skills/frontend/clean-frontend-scaffolding/SKILL.md`
- Create: `skills/frontend/clean-frontend-scaffolding/boilerplate-removal.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/frontend/clean-frontend-scaffolding
```

- [ ] **Step 2: Write `skills/frontend/clean-frontend-scaffolding/SKILL.md`**

```markdown
---
name: clean-frontend-scaffolding
description: Use when after scaffolding a fresh frontend project to purge default boilerplate — demo components, default styles, placeholder routes, sample assets — before laying down real structure.
---

# Clean Frontend Scaffolding

## 1. Audit current state

Detect framework from `package.json`:
- `react` in dependencies → React project.
- `vue` in dependencies → Vue project.

For each item below, check if it still has Vite scaffold default content (heuristic: file size + scaffolded import patterns):
- `src/App.tsx` (React) or `src/App.vue` (Vue)
- `src/main.tsx` / `src/main.ts`
- `src/App.css` / `src/style.css` / `src/index.css` (default Vite content)
- `public/vite.svg`, `src/assets/react.svg`, `src/assets/vue.svg`
- `index.html` (default `<title>Vite + React</title>` etc.)

If every checked file is already custom, exit early with: "Scaffold cleanup not needed — files appear customized."

## 2. Decide what to do

- All scaffold defaults present → full clean (proceed to step 3).
- Partially customized → remove only the default items still present.
- Already customized → exit.

## 3. Purge boilerplate

### React

1. Reduce `src/App.tsx` to:

   ```tsx
   export default function App() {
     return <div>App shell</div>;
   }
   ```

2. Reduce `src/main.tsx` to a clean root render:

   ```tsx
   import { StrictMode } from 'react';
   import { createRoot } from 'react-dom/client';
   import App from './App';
   import './index.css';

   createRoot(document.getElementById('root')!).render(
     <StrictMode>
       <App />
     </StrictMode>,
   );
   ```

3. Replace `src/App.css` content with a single comment: `/* Project styles (Tailwind handles most layout). */`
4. Replace `src/index.css` content with the Tailwind directives only:

   ```css
   @tailwind base;
   @tailwind components;
   @tailwind utilities;
   ```

5. Delete `src/assets/react.svg` and `public/vite.svg`.
6. Update `index.html` `<title>` to the project name (ask via AskUserQuestion if unknown).

### Vue

1. Reduce `src/App.vue` to:

   ```vue
   <script setup lang="ts"></script>
   <template>
     <div>App shell</div>
   </template>
   ```

2. Reduce `src/main.ts` to:

   ```ts
   import { createApp } from 'vue';
   import App from './App.vue';
   import './style.css';

   createApp(App).mount('#app');
   ```

3. Replace `src/style.css` with the Tailwind directives only (see React step 4).
4. Delete `src/assets/vue.svg`, `public/vite.svg`, `src/components/HelloWorld.vue` (if present).
5. Update `index.html` `<title>` to the project name.

## 4. Verify

```bash
pnpm dev
```

Expected: dev server starts; visiting the app shows the empty shell with no console errors. Stop the server.

## References
- ./boilerplate-removal.md — exact files and patterns per framework, with examples and anti-patterns.
- ../_shared/conventions.md — path alias and source-root conventions.
```

- [ ] **Step 3: Write `skills/frontend/clean-frontend-scaffolding/boilerplate-removal.md`**

```markdown
# Boilerplate Removal

Reference for `clean-frontend-scaffolding`. Enumerates every file the Vite scaffold creates with default content and what to do with each.

## Rule: leave file structure intact when possible
**Why:** Other skills (`set-up-frontend-structure`, `configure-typescript`, etc.) assume canonical file paths (`src/main.tsx`, `src/App.tsx`). Renaming or deleting these breaks downstream skills.
**How to apply:** Reduce file *content* to a minimal shell rather than deleting the file entirely.

## Rule: keep `src/index.css` (or `src/style.css`) as the Tailwind entry
**Why:** Tailwind CLI / `@tailwindcss/vite` consumes one canonical entry stylesheet. Removing it means Tailwind never loads.
**How to apply:** Replace the file *content* with the three Tailwind directives. Don't delete the file.

```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

**Anti-example:**
```bash
# bad: deletes the entry stylesheet — Tailwind generates nothing
rm src/index.css
```

## Rule: scrub the `index.html` `<title>` and meta
**Why:** `Vite + React` is a giveaway that the project is unfinished. Page title is also indexed by search engines and shown in browser tabs.
**How to apply:** Set `<title>` to the project name. Add `<meta name="description">` placeholder if absent.

## Rule: delete demo SVG assets
**Why:** `vite.svg`, `react.svg`, `vue.svg` are unused after the scaffold and silently bloat the bundle if anything references them.
**How to apply:**
```bash
rm -f public/vite.svg src/assets/react.svg src/assets/vue.svg
```

## Rule: don't carry the demo component
**Why:** Vue scaffold ships `src/components/HelloWorld.vue`; React 19 templates sometimes ship a `Counter` example. These leak into atomic-design folders later if not removed first.
**How to apply:** Delete the demo components before running `set-up-frontend-structure`.

## When to deviate

- **Project README / docs:** if the project keeps `vite.svg` as part of branding/docs (rare), document it inline and skip that step.
- **Test setup:** if `App.tsx` is referenced by an existing test, keep the export shape (`default export App`) when reducing it.

## Files referenced

| File | Action |
|---|---|
| `src/App.tsx` (React) | Reduce to minimal `App shell` component |
| `src/App.vue` (Vue) | Reduce to minimal template |
| `src/main.tsx` / `src/main.ts` | Reduce to clean root render |
| `src/App.css` | Replace with single comment |
| `src/index.css` / `src/style.css` | Replace with Tailwind directives |
| `src/assets/react.svg` | Delete |
| `src/assets/vue.svg` | Delete |
| `public/vite.svg` | Delete |
| `src/components/HelloWorld.vue` | Delete (Vue scaffold) |
| `index.html` | Update `<title>`, add `<meta name="description">` |
```

- [ ] **Step 4: Run validator**

Run: `bash scripts/validate.sh`

Expected: `OK: validator passed (1 skills checked)` and exit code 0.

If validator fails, fix the SKILL.md frontmatter or reference path before committing.

- [ ] **Step 5: Commit**

```bash
git add skills/frontend/clean-frontend-scaffolding/
git commit -m "feat(skill): clean-frontend-scaffolding"
```

---

## Task 9: Skill — `set-up-frontend-structure`

**Files:**
- Create: `skills/frontend/set-up-frontend-structure/SKILL.md`
- Create: `skills/frontend/set-up-frontend-structure/atomic-design.md`
- Create: `skills/frontend/set-up-frontend-structure/folder-conventions.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/frontend/set-up-frontend-structure
```

- [ ] **Step 2: Write `skills/frontend/set-up-frontend-structure/SKILL.md`**

```markdown
---
name: set-up-frontend-structure
description: Use when laying down folder structure for a frontend project — creates atomic-design component layout (atoms / molecules / organisms / templates / pages) plus hooks-or-composables, libs, utils, and tests folders, with index.ts barrels and one example component per atomic layer to document the pattern.
---

# Set Up Frontend Structure

## 1. Audit current state

For each folder below, check if it already exists and is non-empty:
- `src/components/atoms`
- `src/components/molecules`
- `src/components/organisms`
- `src/components/templates`
- `src/components/pages`
- `src/hooks` (React) **or** `src/composables` (Vue)
- `src/libs`
- `src/utils`
- `src/tests`

Detect framework from `package.json` (`react` vs `vue`). The hook-vs-composable folder is framework-specific — see `../_shared/conventions.md`.

If every folder exists and is non-empty, exit: "Structure already in place."

## 2. Decide what to do

- Nothing in place → full setup (steps 3–5).
- Partial → create only missing folders; do not overwrite existing files.
- Already structured → exit.

## 3. Create folder tree

Create:

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

Drop a `.gitkeep` in each empty folder so git tracks them.

## 4. Add barrel files

Create one `index.ts` per atomic layer (5 files) and one for hooks/composables, libs, utils. Each starts empty (just a header comment) and gets re-exports added as components/utilities are introduced.

```ts
// src/components/atoms/index.ts
// Barrel: re-exports every atom in this folder.
```

Repeat for molecules, organisms, templates, pages, hooks (or composables), libs, utils.

## 5. Generate one example per atomic layer

To document the convention, generate a single example component at each layer with matching `*.stories.ts` and `*.test.ts` siblings. The Storybook test runner and Vitest are configured later; the test/story files should compile but won't run yet.

### React example tree

```
src/components/atoms/Button/
├── Button.tsx
├── Button.stories.ts
├── Button.test.tsx
└── index.ts

src/components/molecules/SearchInput/
├── SearchInput.tsx
├── SearchInput.stories.ts
├── SearchInput.test.tsx
└── index.ts

src/components/organisms/Header/
├── Header.tsx
├── Header.stories.ts
├── Header.test.tsx
└── index.ts

src/components/templates/AuthLayout/
├── AuthLayout.tsx
├── AuthLayout.stories.ts
└── index.ts

src/components/pages/HomePage/
├── HomePage.tsx
├── HomePage.stories.ts
└── index.ts
```

### Example file content (React `Button` atom)

```tsx
// src/components/atoms/Button/Button.tsx
import type { ButtonHTMLAttributes, ReactNode } from 'react';

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  children: ReactNode;
};

export function Button({ children, ...rest }: ButtonProps) {
  return (
    <button
      type="button"
      className="px-3 py-1.5 rounded-md bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50"
      {...rest}
    >
      {children}
    </button>
  );
}
```

```ts
// src/components/atoms/Button/index.ts
export * from './Button';
```

```tsx
// src/components/atoms/Button/Button.test.tsx
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Button } from './Button';

describe('Button', () => {
  it('renders its children', () => {
    render(<Button>Click me</Button>);
    expect(screen.getByRole('button', { name: 'Click me' })).toBeInTheDocument();
  });
});
```

```ts
// src/components/atoms/Button/Button.stories.ts
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta: Meta<typeof Button> = {
  title: 'Atoms/Button',
  component: Button,
};
export default meta;

export const Default: StoryObj<typeof Button> = {
  args: { children: 'Click me' },
};
```

For Vue projects, mirror this structure with `.vue` SFCs and Vue testing-library.

After generating one example per layer, also update each barrel:

```ts
// src/components/atoms/index.ts
export * from './Button';
```

## 6. Verify

```bash
pnpm tsc --noEmit
```

Expected: 0 errors. The example components compile (test/story imports may resolve but not run yet — that's fine).

If tests / stories fail to resolve `@testing-library/*` or `@storybook/react`, the deps were not installed in skill `scaffold-frontend-project`. Re-run that skill first.

## References
- ./atomic-design.md — methodology, criteria for each layer, anti-patterns.
- ./folder-conventions.md — naming, barrel pattern, hooks vs composables decision.
- ../_shared/glossary.md — atomic terms (atom / molecule / organism / template / page) with the "test" question for each.
```

- [ ] **Step 3: Write `skills/frontend/set-up-frontend-structure/atomic-design.md`**

```markdown
# Atomic Design

Reference for `set-up-frontend-structure`. Adapted from Brad Frost's atomic-design methodology, with project-specific rulings on edge cases.

## Why atomic design

A flat `components/` folder grows past readability around 30 components. Atomic design imposes a hierarchy that scales with the codebase and matches how designers think: small reusable pieces compose into larger, more situational pieces.

Five layers, each with a strict criterion. The criterion is what makes the methodology useful — without it, atomic design collapses into "just folders."

## Rule: an atom has one concept and zero internal composition
**Why:** Atoms are the building blocks. If they compose other components, you've introduced a coupling that defeats the methodology.
**How to apply:**
- A `Button` (with optional icon prop accepting an Icon atom) is an atom.
- A `Button` that internally renders a `Spinner` molecule is an organism (or a refactor target).

```tsx
// good: atom takes content as children
<Button>Save</Button>

// bad: atom internally composes higher layers
<Button isLoading /> // internally renders <LoadingDots />
```

## Rule: a molecule does one thing and composes 2–4 atoms
**Why:** "One thing" keeps molecules focused. The 2–4 ceiling is heuristic — past 4, you're probably reaching organism territory.
**How to apply:**
- `SearchInput` (Input + Button) — one job: search input.
- `FormField` (Label + Input + ErrorMessage) — one job: a single labeled, error-aware input.

```tsx
// good
<SearchInput onSubmit={search} />

// bad: molecule with 7 atoms — likely an organism
<UserCard avatar="..." name="..." badge="..." actions={...} bio="..." />
```

## Rule: an organism is a recognizable region of UI
**Why:** Pointed-at-and-named is the test. "The header." "The product card." "The login form."
**How to apply:** Don't pre-extract organisms speculatively. Wait until two pages need the same region.

## Rule: a template arranges organisms; it doesn't fetch data
**Why:** Data fetching couples the layout to a specific feature. Templates are layout machines.
**How to apply:** Templates accept slots/children. Pages do the data fetching and pass content into templates.

```tsx
// good
<AuthLayout sidebar={<Login />} />

// bad
function AuthLayout() {
  const user = useQuery(...); // template should not fetch
  return ...;
}
```

## Rule: a page binds to a route and supplies data
**Why:** Pages are the "container" layer. Routing + data are page concerns.
**How to apply:** A page renders a template + organisms with real data. The page file lives at `src/components/pages/<PageName>/`.

## Anti-pattern: classifying by visual size
**Why:** "It looks small, must be an atom" — ignores composition. A small visual element that internally renders a molecule is still an organism.
**How to apply:** Classify by composition + responsibility, not pixels.

## Anti-pattern: deep folder hierarchies inside a layer
**Why:** `atoms/forms/inputs/text/Button` defeats the flat-within-layer principle. Atoms should be findable in one glance.
**How to apply:** Keep each layer flat. If a layer has 30+ items and you want subfolders, that's a sign some items belong in a higher layer.

## Anti-pattern: atoms that import from molecules/organisms
**Why:** Reverse-direction imports break the layer model and create cycles.
**How to apply:** Atoms import only from `_shared/`, `utils/`, third-party libs, or design tokens. Molecules import from atoms. Organisms from molecules + atoms. Templates from organisms + molecules + atoms. Pages from anywhere lower.

## When to deviate

- **Single-feature codebases:** for projects with < 20 components total, atomic design is overkill. A flat `src/components/` may serve. These skills create the structure regardless because the project will likely grow; if you know it won't, skip skill `set-up-frontend-structure`.
- **Design system mismatch:** if the design system uses different layer terminology (e.g., "primitives / patterns / templates"), align with the design-system terms instead of forcing atomic-design vocabulary.

## Layer summary table

| Layer | Composition | Test | Imports from |
|---|---|---|---|
| Atom | None internal | One concept, no composed components | shared, utils, tokens |
| Molecule | 2–4 atoms | One job, < 5 atoms | atoms |
| Organism | molecules + atoms | Recognizable region | molecules, atoms |
| Template | organisms + molecules + atoms | Arranges, doesn't fetch | organisms, molecules, atoms |
| Page | anything below | Route-bound, fetches data | anything below |
```

- [ ] **Step 4: Write `skills/frontend/set-up-frontend-structure/folder-conventions.md`**

```markdown
# Folder Conventions

Reference for `set-up-frontend-structure`. Naming, barrel patterns, and the React-vs-Vue split for hooks/composables.

## Rule: hooks (React) vs composables (Vue)
**Why:** Each framework's idiom. Mixing terms creates cognitive overhead.
**How to apply:**
- React → `src/hooks/`
- Vue → `src/composables/`

The skill `set-up-frontend-structure` detects framework and picks the right folder.

## Rule: each component lives in its own folder
**Why:** A component, its tests, its stories, and its barrel together — co-located, navigable.
**How to apply:**
```
src/components/atoms/Button/
├── Button.tsx           # component
├── Button.test.tsx      # unit/component test
├── Button.stories.ts    # Storybook
└── index.ts             # barrel: export * from './Button'
```

**Anti-example:**
```
src/components/atoms/
├── Button.tsx           # everything flat
├── Button.test.tsx
├── Card.tsx             # quickly becomes 50 files in one folder
```

## Rule: tests are co-located by default; e2e in `src/tests/`
**Why:** Co-located unit tests stay in sync with the subject. End-to-end tests don't have a single subject — they live separately.
**How to apply:**
- `Button.test.tsx` lives next to `Button.tsx`.
- `src/tests/` holds Playwright e2e specs and the Vitest setup file (`setup.ts`).

## Rule: `libs/` is for "third-party adapter or wrapper"; `utils/` is for "pure helpers"
**Why:** Different lifetimes and dependencies. A wrapper around `tanstack/query` belongs to libs because it depends on a third-party. A `formatDate` belongs to utils because it has no external deps.
**How to apply:**
- `libs/queryClient.ts` (wraps TanStack Query) → `libs/`
- `libs/fetcher.ts` (wraps `fetch`) → `libs/`
- `utils/formatDate.ts` (pure date formatter) → `utils/`
- `utils/clsx.ts` (pure class-string utility) → `utils/`

## Rule: barrel `index.ts` re-exports only; never defines inline
**Why:** A file that defines AND re-exports does two jobs. Splits concerns.
**How to apply:**
```ts
// src/components/atoms/index.ts
export * from './Button';
export * from './Input';
export * from './ErrorFallback';
```

## Rule: file names match the primary export's PascalCase identifier
**Why:** Predictable imports.
**How to apply:** `Button.tsx` exports `Button`. `useToggle.ts` exports `useToggle`. `formatDate.ts` exports `formatDate`.

## When to deviate

- **`pages/` for route components:** if using a file-based router (Next.js, Nuxt, TanStack Router), the routing layer dictates a `pages/` or `routes/` folder. In that case, the atomic-design `pages/` layer redundantly mirrors that — pick one. The skill audits and asks.
- **Co-located vs separate test folders:** team preference. Default is co-located. If a project has chosen otherwise, follow what's there.

## Empty-folder placeholders

Each empty folder gets a `.gitkeep` file (zero bytes). Once real content arrives, the `.gitkeep` should be deleted in the same commit that adds the first real file.
```

- [ ] **Step 5: Run validator**

Run: `bash scripts/validate.sh`

Expected: `OK: validator passed (2 skills checked)` and exit code 0.

- [ ] **Step 6: Commit**

```bash
git add skills/frontend/set-up-frontend-structure/
git commit -m "feat(skill): set-up-frontend-structure"
```

---

## Task 10: Skill — `configure-typescript`

**Files:**
- Create: `skills/frontend/configure-typescript/SKILL.md`
- Create: `skills/frontend/configure-typescript/tsconfig-rules.md`
- Create: `skills/frontend/configure-typescript/path-aliases.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/frontend/configure-typescript
```

- [ ] **Step 2: Write `skills/frontend/configure-typescript/SKILL.md`**

```markdown
---
name: configure-typescript
description: Use when setting up or hardening TypeScript in a frontend project — applies strict mode, additional safety flags (noUncheckedIndexedAccess, noImplicitOverride), and consistent path aliases (@/*) across tsconfig, vite, vitest, playwright, and storybook configs.
---

# Configure TypeScript

## 1. Audit current state

Inspect `tsconfig.json`:
- Is `compilerOptions.strict` set to `true`?
- Are `noUncheckedIndexedAccess`, `noImplicitOverride`, `noUnusedLocals`, `noUnusedParameters` set?
- Is there a `paths` mapping for `@/*`?
- Is `baseUrl` set to `.`?

Inspect alias config in (whichever exist):
- `vite.config.ts` (`resolve.alias`)
- `vitest.config.ts` (`resolve.alias` or `test.alias`)
- `playwright.config.ts` (typically uses `tsconfig-paths` or no aliases)
- `.storybook/main.ts` or `.storybook/main.js`

If every flag is in place and every config has the matching alias, exit early.

## 2. Decide what to do

- Nothing strict → apply full strict + safety set.
- Strict on but missing safety flags → add them.
- Strict + flags but missing aliases somewhere → add aliases to those configs.

## 3. Update `tsconfig.json`

Apply or merge these `compilerOptions`:

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "exactOptionalPropertyTypes": true,
    "baseUrl": ".",
    "paths": {
      "@/*": ["./src/*"]
    }
  }
}
```

If `tsconfig.app.json` (Vite split-config) exists, apply the `paths` and safety flags there instead of the root `tsconfig.json` (Vite scaffold places app-level options in `tsconfig.app.json`).

## 4. Update `vite.config.ts`

Add `resolve.alias`:

```ts
import { defineConfig } from 'vite';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  // ... existing plugins
});
```

## 5. Update `vitest.config.ts` (if present)

If Vitest extends Vite config (typical), the alias is inherited. Confirm by:

```ts
import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(viteConfig, defineConfig({
  test: { /* ... */ },
}));
```

If Vitest config is standalone (no merge), duplicate the alias block from step 4 there.

## 6. Update `.storybook/main.ts` (if Storybook installed)

Storybook 8 with Vite builder inherits Vite config. Confirm:

```ts
import type { StorybookConfig } from '@storybook/react-vite';

const config: StorybookConfig = {
  framework: '@storybook/react-vite',
  // ... existing options
};
export default config;
```

If Storybook uses a non-Vite builder, add a `viteFinal` hook that injects `resolve.alias`.

## 7. Update `playwright.config.ts` (if Playwright installed)

Playwright doesn't bundle the test files like Vite — it uses native Node module resolution. To support `@/*` imports in Playwright specs, install `tsconfig-paths` and register it via `globalSetup`:

```ts
// playwright.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './src/tests',
  // ... existing options
});
```

```ts
// src/tests/global-setup.ts
import { register } from 'tsconfig-paths';
import { compilerOptions } from '../../tsconfig.json';

register({
  baseUrl: '.',
  paths: compilerOptions.paths,
});
```

(Optional — many projects keep Playwright specs free of `@/*` and use plain relative imports there.)

## 8. Verify

```bash
pnpm tsc --noEmit
```

Expected: 0 errors.

Verify alias works by adding a temporary `src/__alias-check.ts`:

```ts
// src/__alias-check.ts
import App from '@/App';
console.log(App);
```

Run: `pnpm tsc --noEmit`

Expected: 0 errors.

Delete `src/__alias-check.ts` afterwards.

## References
- ./tsconfig-rules.md — every flag with rationale.
- ./path-aliases.md — alias snippets for every config file.
- ../_shared/conventions.md — `@/` prefix convention.
```

- [ ] **Step 3: Write `skills/frontend/configure-typescript/tsconfig-rules.md`**

```markdown
# TSConfig Rules

Reference for `configure-typescript`. Each compiler option enabled, with rationale and edge cases.

## Rule: `strict: true`
**Why:** Umbrella for all strict-family flags. The single biggest improvement to type safety in any TS project.
**How to apply:** Always on. Catches `null`/`undefined` mistakes, implicit `any`, contravariant function types, and more.

```ts
// strict catches:
function greet(name: string) { return `Hi ${name}`; }
greet(undefined); // error: Argument of type 'undefined' is not assignable to parameter of type 'string'.
```

## Rule: `noUncheckedIndexedAccess: true`
**Why:** TypeScript's default treats `arr[0]` as `T`, but the index might be out of bounds — runtime `undefined`. This flag adds `| undefined` to every indexed access, forcing the developer to handle the missing case.
**How to apply:** Always on for new projects. Existing projects may need a migration pass; do it anyway.

```ts
// without flag:
const arr: string[] = [];
const first: string = arr[0]; // compiles, runtime is undefined

// with flag:
const first: string | undefined = arr[0]; // forced to handle the maybe-undefined
```

## Rule: `noImplicitOverride: true`
**Why:** Catches subclass methods that look like overrides but don't actually override (e.g., parent renamed the method). Without the flag, the subclass silently keeps a no-longer-overriding method.
**How to apply:** Always on. Requires `override` keyword on intentional overrides.

## Rule: `noUnusedLocals: true` and `noUnusedParameters: true`
**Why:** Dead variables and parameters drift away from intent. Force their removal or `_`-prefix to keep code intentional.
**How to apply:** Use `_param` prefix for parameters that exist for interface compliance but aren't used.

```ts
// good
function callback(_e: Event, data: Data) { /* uses data */ }

// bad: silently retained, no signal of intent
function callback(e: Event, data: Data) { /* uses data only */ }
```

## Rule: `exactOptionalPropertyTypes: true`
**Why:** Distinguishes `{ x?: number }` (key may be absent) from `{ x: number | undefined }` (key always present, value may be undefined). Without the flag, both behave identically — losing precision at API boundaries.
**How to apply:** Default on. May need adjustments at REST API serialization layers.

```ts
type User = { name: string; nickname?: string };
// with flag, this is an error (assigning explicit undefined to a maybe-absent key):
const u: User = { name: 'V', nickname: undefined };
// instead, omit the key:
const u: User = { name: 'V' };
```

## Rule: `baseUrl: "."` + `paths`
**Why:** Foundation for path aliases. Without `baseUrl`, `paths` doesn't resolve.
**How to apply:** Always set both together. See `path-aliases.md`.

## When to deviate

- **Migrating an existing codebase:** turning on all flags at once produces hundreds of errors. Migration order: `strict` first, then `noUncheckedIndexedAccess`, then `exactOptionalPropertyTypes`. Tackle one flag per PR.
- **Library code targeting older TS users:** keep `strict` but consider holding off on `exactOptionalPropertyTypes` until users have upgraded compilers.

## Recommended `compilerOptions` block

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "skipLibCheck": true,
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "exactOptionalPropertyTypes": true,
    "noFallthroughCasesInSwitch": true,
    "useDefineForClassFields": true,
    "isolatedModules": true,
    "resolveJsonModule": true,
    "jsx": "react-jsx",
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src"]
}
```

(For Vue projects, replace `"jsx": "react-jsx"` with what `vue-tsc` expects, typically just omit it.)
```

- [ ] **Step 4: Write `skills/frontend/configure-typescript/path-aliases.md`**

```markdown
# Path Aliases

Reference for `configure-typescript`. The `@/*` prefix needs to be configured in *every* config that resolves modules — otherwise builds, tests, type-checks, and stories diverge.

## Rule: a single prefix, configured everywhere
**Why:** Multiple aliases (`@/`, `~/`, `@components/`) confuse readers and tooling. One prefix consistently applied is the goal.
**How to apply:** `@/*` mapping to `./src/*` everywhere. The configs that need it:

| Config | Field |
|---|---|
| `tsconfig.json` (or `tsconfig.app.json`) | `compilerOptions.paths` + `baseUrl` |
| `vite.config.ts` | `resolve.alias` |
| `vitest.config.ts` | inherited via `mergeConfig`, or duplicate `resolve.alias` |
| `.storybook/main.ts` (Vite builder) | inherited; for non-Vite builder, add `viteFinal` |
| `playwright.config.ts` | use `tsconfig-paths` `globalSetup` if specs use `@/*` |

## Snippets

### `tsconfig.json` (or `tsconfig.app.json`)

```json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  }
}
```

### `vite.config.ts`

```ts
import { defineConfig } from 'vite';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
});
```

### `vitest.config.ts` (preferred — inherit Vite config)

```ts
import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      globals: true,
      setupFiles: ['./src/tests/setup.ts'],
    },
  }),
);
```

### `.storybook/main.ts` (Vite builder — inherits)

```ts
import type { StorybookConfig } from '@storybook/react-vite';

const config: StorybookConfig = {
  framework: '@storybook/react-vite',
  stories: ['../src/**/*.stories.@(ts|tsx)'],
  addons: ['@storybook/addon-essentials'],
};
export default config;
```

### `playwright.config.ts` + `tsconfig-paths` (only if specs use `@/*`)

```ts
// playwright.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './src/tests',
  globalSetup: require.resolve('./src/tests/global-setup.ts'),
});
```

```ts
// src/tests/global-setup.ts
import { register } from 'tsconfig-paths';
import tsconfig from '../../tsconfig.json' assert { type: 'json' };

register({
  baseUrl: '.',
  paths: tsconfig.compilerOptions.paths,
});
```

## Anti-pattern: per-folder aliases

```ts
// bad: explosion of aliases that compound over time
'@components': ...
'@hooks': ...
'@utils': ...
'@libs': ...
```

A single `@/*` covers all of these (`@/components`, `@/hooks`, etc.) without the maintenance burden.

## When to deviate

- **Existing project on `~/`:** if the project already uses `~/` (Nuxt convention) or another prefix, keep it. Don't churn imports.
- **Monorepo packages:** in a workspace, each package may have its own `@/*` mapped to its own `src/`. That's fine — the prefix is project-local.
```

- [ ] **Step 5: Run validator**

Run: `bash scripts/validate.sh`

Expected: `OK: validator passed (3 skills checked)` and exit code 0.

- [ ] **Step 6: Commit**

```bash
git add skills/frontend/configure-typescript/
git commit -m "feat(skill): configure-typescript"
```

---

## Task 11: Skill — `set-up-error-boundaries`

**Files:**
- Create: `skills/frontend/set-up-error-boundaries/SKILL.md`
- Create: `skills/frontend/set-up-error-boundaries/error-boundaries.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/frontend/set-up-error-boundaries
```

- [ ] **Step 2: Write `skills/frontend/set-up-error-boundaries/SKILL.md`**

```markdown
---
name: set-up-error-boundaries
description: Use when adding error boundaries to a frontend project — wires up an app-shell boundary, page-level boundaries, and a reusable component-level boundary with user-friendly fallback UIs and a logging-hook seam (Sentry/LogRocket-ready, but not installed).
---

# Set Up Error Boundaries

## 1. Audit current state

Search for an existing `ErrorBoundary` component:
```bash
grep -r "ErrorBoundary" src/ 2>/dev/null
```

Check whether the root component (`src/main.tsx` for React, `src/main.ts` for Vue) already wraps its tree in a boundary.

If a boundary exists and is wired at the root, the audit may still find missing page-level placements; report those.

## 2. Decide what to do

- No boundary → full setup (steps 3–7).
- Boundary present but only at root → add page-level wraps.
- Boundary present at every layer → confirm fallback UI and logging seam, exit if both fine.

## 3. Detect framework

Read `package.json`. React or Vue? Branch the boundary implementation.

## 4. Generate the molecule `ErrorBoundary`

Classified as a **molecule**: composes one atom (`ErrorFallback`) with one behavior (catch + report). Rationale and alternative classification documented in `error-boundaries.md`.

### React

```tsx
// src/components/molecules/ErrorBoundary/ErrorBoundary.tsx
import { Component, type ErrorInfo, type ReactNode } from 'react';
import { reportError } from '@/libs/error-reporter';
import { ErrorFallback } from '@/components/atoms/ErrorFallback';

type Props = { children: ReactNode; fallback?: ReactNode };
type State = { hasError: boolean; error?: Error };

export class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false };

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    reportError(error, { componentStack: info.componentStack ?? undefined });
  }

  render() {
    if (this.state.hasError) {
      return this.props.fallback ?? <ErrorFallback error={this.state.error} />;
    }
    return this.props.children;
  }
}
```

```ts
// src/components/molecules/ErrorBoundary/index.ts
export * from './ErrorBoundary';
```

### Vue

```vue
<!-- src/components/molecules/ErrorBoundary/ErrorBoundary.vue -->
<script setup lang="ts">
import { ref, onErrorCaptured } from 'vue';
import { reportError } from '@/libs/error-reporter';
import ErrorFallback from '@/components/atoms/ErrorFallback/ErrorFallback.vue';

const error = ref<Error | null>(null);

onErrorCaptured((err) => {
  error.value = err as Error;
  reportError(err as Error, {});
  return false; // halt propagation
});
</script>

<template>
  <ErrorFallback v-if="error" :error="error" />
  <slot v-else />
</template>
```

```ts
// src/components/molecules/ErrorBoundary/index.ts
export { default as ErrorBoundary } from './ErrorBoundary.vue';
```

## 5. Generate the atom `ErrorFallback`

### React

```tsx
// src/components/atoms/ErrorFallback/ErrorFallback.tsx
type Props = { error?: Error; onRetry?: () => void };

export function ErrorFallback({ error, onRetry }: Props) {
  return (
    <div role="alert" className="p-4 border border-red-500 rounded-md bg-red-50 text-red-900">
      <h2 className="font-semibold">Something went wrong.</h2>
      <p className="text-sm">Please try again. If the problem persists, contact support.</p>
      {import.meta.env.DEV && error && (
        <pre className="mt-2 text-xs whitespace-pre-wrap">{error.stack ?? error.message}</pre>
      )}
      {onRetry && (
        <button type="button" onClick={onRetry} className="mt-2 px-3 py-1 bg-red-600 text-white rounded">
          Try again
        </button>
      )}
    </div>
  );
}
```

### Vue

```vue
<!-- src/components/atoms/ErrorFallback/ErrorFallback.vue -->
<script setup lang="ts">
defineProps<{ error: Error }>();
</script>

<template>
  <div role="alert" class="p-4 border border-red-500 rounded-md bg-red-50 text-red-900">
    <h2 class="font-semibold">Something went wrong.</h2>
    <p class="text-sm">Please try again. If the problem persists, contact support.</p>
    <pre v-if="import.meta.env.DEV" class="mt-2 text-xs whitespace-pre-wrap">{{ error.stack ?? error.message }}</pre>
  </div>
</template>
```

## 6. Generate the logging seam `reportError`

```ts
// src/libs/error-reporter.ts
type ErrorContext = {
  componentStack?: string;
  url?: string;
  user?: { id: string };
};

/**
 * Reports an error to the configured logging service.
 * Currently logs to console; swap implementation for Sentry/LogRocket later.
 */
export function reportError(error: Error, context: ErrorContext = {}): void {
  if (import.meta.env.PROD) {
    // Sentry.captureException(error, { contexts: { app: context } });
    console.error('[reportError]', error, context);
  } else {
    console.error('[reportError]', error, context);
  }
}
```

The commented-out Sentry call documents the integration seam. Future skill `configure-error-tracking` (Tier 2 / out of scope here) wires this to Sentry.

## 7. Wire boundaries

### React: app shell

```tsx
// src/main.tsx
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { ErrorBoundary } from '@/components/molecules/ErrorBoundary';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
);
```

For each page-level component (under `src/components/pages/`), wrap the page output in an `ErrorBoundary`. The skill scans `pages/` and adds the wrapper if missing.

### Vue: app shell

```ts
// src/main.ts
import { createApp } from 'vue';
import App from './App.vue';
import ErrorBoundary from '@/components/molecules/ErrorBoundary/ErrorBoundary.vue';
import './style.css';

const app = createApp(App);
app.component('ErrorBoundary', ErrorBoundary);
app.mount('#app');
```

Then wrap `<App />` content (or page-level components) with `<ErrorBoundary>` slots.

## 8. Generate a Playwright smoke test

```ts
// src/tests/error-boundary.spec.ts
import { test, expect } from '@playwright/test';

test('error boundary catches a render-phase error', async ({ page }) => {
  await page.goto('/');
  // App-shell boundary should render the page; if anything has thrown, ErrorFallback shows.
  // This test is a smoke check — extend with a `?throw=1` query the App reads to deliberately throw.
  await expect(page).toHaveTitle(/.+/);
});
```

(Extending the App with a deliberate-throw flag is left to the implementer; the test as-is verifies the page renders without crashing the boundary.)

## 9. Verify

```bash
pnpm tsc --noEmit
```

Expected: 0 errors.

```bash
pnpm test:e2e
```

(If Playwright not yet configured, this will fail; that's wired up in skill `configure-test-stack`. Skip if not configured.)

## References
- ./error-boundaries.md — full per-framework patterns, placement strategy, fallback design rules, logging-hook integration, anti-patterns.
- ../_shared/glossary.md — "molecule" vs "organism" criteria.
- ../_shared/conventions.md — `@/` import prefix convention.
```

- [ ] **Step 3: Write `skills/frontend/set-up-error-boundaries/error-boundaries.md`**

```markdown
# Error Boundaries

Reference for `set-up-error-boundaries`. Why try/catch isn't enough, framework-specific implementations, placement strategy, fallback UI design, and the logging seam.

## Why try/catch isn't enough

`try/catch` works for synchronous code in event handlers and effects. It does **not** catch:
- Errors thrown during the render phase.
- Errors in lifecycle hooks (`useEffect`, `componentDidMount`).
- Async errors that don't bubble back to the original `try` (Promise rejections, microtasks).

Error boundaries (React) and `errorCaptured` (Vue) bridge that gap by intercepting render-phase errors at the framework level.

## Rule: place boundaries at three depths
**Why:** A single root-level boundary catches everything but loses isolation — the whole app reverts to a fallback for any error. Multiple boundaries at strategic depths preserve as much working UI as possible.
**How to apply:**
- **App-shell boundary:** at the root (`main.tsx` / `main.ts`). Last line of defense.
- **Page-level boundary:** inside each page-template. A failing page doesn't blank the rest of the app.
- **Component-level boundary:** wrap third-party widgets, data-driven cards, or other risky regions.

```tsx
// good: nested boundaries preserve outer UI
<ErrorBoundary> {/* app-shell */}
  <Header />
  <ErrorBoundary> {/* page-level */}
    <ProductPage />
  </ErrorBoundary>
  <Footer />
</ErrorBoundary>

// bad: only an app-shell boundary — a ProductPage error blanks Header + Footer
<ErrorBoundary>
  <Header /><ProductPage /><Footer />
</ErrorBoundary>
```

## Rule: React boundaries must be class components
**Why:** `getDerivedStateFromError` and `componentDidCatch` are class lifecycle methods. As of React 19, function-component error boundaries do not exist (despite hooks elsewhere).
**How to apply:** Use a class. Wrap with a function component if needed for prop conveniences.

```tsx
import { Component, type ErrorInfo, type ReactNode } from 'react';

export class ErrorBoundary extends Component<{ children: ReactNode }, { hasError: boolean }> {
  state = { hasError: false };
  static getDerivedStateFromError() { return { hasError: true }; }
  componentDidCatch(error: Error, info: ErrorInfo) { /* report */ }
  render() { return this.state.hasError ? <Fallback /> : this.props.children; }
}
```

## Rule: Vue boundaries use `errorCaptured` and `return false`
**Why:** `errorCaptured` is the official Vue 3 hook. Returning `false` halts propagation up the parent chain — without it, the same error fires for every ancestor with a hook.
**How to apply:**
```vue
<script setup lang="ts">
import { ref, onErrorCaptured } from 'vue';

const error = ref<Error | null>(null);
onErrorCaptured((err) => {
  error.value = err as Error;
  return false; // halt propagation
});
</script>
```

## Rule: vanilla JS uses a render wrapper with safe DOM mutation
**Why:** No framework hooks, but you can still isolate render with `try/catch` around the render call. Do not write `innerHTML` with arbitrary strings — use safe DOM APIs (`textContent`, `createElement`, `replaceChildren`) so error messages can never inject markup.
**How to apply:**
```js
function renderWithErrorBoundary(renderFn) {
  try {
    renderFn();
  } catch (err) {
    console.error(err);
    document.body.replaceChildren();
    const heading = document.createElement('h1');
    heading.textContent = 'Something went wrong.';
    document.body.append(heading);
  }
}
```

(The plugin's frontend skills target React/Vue, so this is for completeness only.)

## Rule: classify boundary as molecule (with documented exception)
**Why:** A boundary composes one atom (the fallback UI) with one behavior (catch + report). That's a molecule by the methodology in `../../_shared/glossary.md`.
**Alternative classification:** some teams place boundaries at the organism layer because they wrap whole regions. Both are defensible. This plugin's convention is *molecule* because the boundary itself is small and reusable; the *organism* is the wrapped content, not the boundary.

## Rule: fallback UI is friendly + actionable
**Why:** "Something broke" with no recovery path frustrates users. A retry button (or a clear next action) recovers many transient errors.
**How to apply:**
- Friendly headline ("Something went wrong.")
- Brief explanation ("Please try again.")
- Action ("Try again" button calling a retry callback or `window.location.reload()`)
- Dev-only error detail (gated by `import.meta.env.DEV`) — never shown to users in prod.

## Rule: logging seam, not direct logging
**Why:** Logging providers come and go (Sentry, LogRocket, Datadog, Honeycomb). A `reportError` indirection means swapping providers is a one-file change, not a codebase-wide find-replace.
**How to apply:** Boundary calls `reportError(error, info)`. The function lives in `src/libs/error-reporter.ts` and currently logs to console. Future tracking-install skill (Tier 2) replaces the implementation.

## Anti-pattern: one mega-boundary at the root only

Already covered above. The user experience cost is real: a single error in a footer widget blanks the whole app instead of just the footer.

## Anti-pattern: boundaries that swallow without logging

```tsx
componentDidCatch() { /* do nothing — error vanishes */ }
```

Production errors that never reach a logger are invisible. Always call `reportError`.

## Anti-pattern: catching `null`/`undefined` access by adding boundaries

If you find yourself adding a boundary because "this component throws on missing data," fix the data layer instead. Boundaries are for unexpected errors, not for routing around missing-data branches.

## Testing the boundary itself

A boundary that's never been exercised is a boundary you can't trust. Test with a deliberately-throwing component:

```tsx
// in a Vitest test
function Bomb(): never { throw new Error('boom'); }

test('ErrorBoundary catches render-phase errors', () => {
  // expect the fallback to render and reportError to be called
});
```

## Logging integration roadmap

When the project adopts Sentry/LogRocket, replace `reportError`'s body:

```ts
import * as Sentry from '@sentry/react';

export function reportError(error: Error, context: ErrorContext = {}): void {
  Sentry.captureException(error, { contexts: { app: context } });
}
```

The boundaries don't change.
```

- [ ] **Step 4: Run validator**

Run: `bash scripts/validate.sh`

Expected: `OK: validator passed (4 skills checked)` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add skills/frontend/set-up-error-boundaries/
git commit -m "feat(skill): set-up-error-boundaries"
```

---

## Task 12: Final pass

- [ ] **Step 1: Final validator run**

Run: `bash scripts/validate.sh`

Expected: `OK: validator passed (4 skills checked)` and exit code 0.

- [ ] **Step 2: Confirm directory tree**

Run: `find . -type f -not -path './.git/*' | sort`

Expected: 19 files (the 16 created by this plan plus the 2 docs files from the previous spec/plan commits, plus `README.md` already counted). The full set:

```
./.claude-plugin/plugin.json
./.gitignore
./README.md
./docs/superpowers/plans/2026-05-04-frontendskills-plan-1-foundation.md
./docs/superpowers/specs/2026-05-04-frontendskills-plugin-design.md
./scripts/validate.sh
./skills/frontend/_shared/conventions.md
./skills/frontend/_shared/glossary.md
./skills/frontend/_shared/stack-versions.md
./skills/frontend/clean-frontend-scaffolding/SKILL.md
./skills/frontend/clean-frontend-scaffolding/boilerplate-removal.md
./skills/frontend/configure-typescript/SKILL.md
./skills/frontend/configure-typescript/path-aliases.md
./skills/frontend/configure-typescript/tsconfig-rules.md
./skills/frontend/set-up-error-boundaries/SKILL.md
./skills/frontend/set-up-error-boundaries/error-boundaries.md
./skills/frontend/set-up-frontend-structure/SKILL.md
./skills/frontend/set-up-frontend-structure/atomic-design.md
./skills/frontend/set-up-frontend-structure/folder-conventions.md
```

- [ ] **Step 3: Confirm git state**

Run: `git log --oneline | head -20`

Expected: ~12 commits (one per task), each with a `feat:` / `docs:` / `chore:` conventional prefix.

- [ ] **Step 4: Tag the milestone**

```bash
git tag -a plan-1-complete -m "Plan 1: foundation + 4 simpler skills complete"
```

This marks a clean restart point if Plan 2 introduces issues.

---

## Out of scope for Plan 1

These belong to Plan 2 or Plan 3:

- `configure-frontend-linting`, `configure-git-hooks`, `set-up-design-tokens`, `set-up-data-layer` (Plan 2).
- `configure-test-stack`, `configure-ci`, `scaffold-frontend-project`, `bootstrap-frontend-project` (Plan 3).
- Tier 2 frontend skills: routing, forms, editor config, component generator, env config.
- Infra and backend domains.

The Plan 1 deliverable is a working plugin shell — the four implemented skills can be invoked individually against an existing project right now (via the project's local Claude Code marketplace).

**Recommended invocation order** matches the umbrella's sequence (`bootstrap-frontend-project`, defined in Plan 3): clean → typescript → structure → error-boundaries. The `set-up-error-boundaries` skill writes to `src/components/molecules/` and `src/components/atoms/` (folders that `set-up-frontend-structure` creates) and uses `@/` imports (alias that `configure-typescript` configures). The audit-first pattern lets each skill run in isolation — it'll detect missing prerequisites and either fill them in or report what's needed — but the recommended order avoids that recovery path.
