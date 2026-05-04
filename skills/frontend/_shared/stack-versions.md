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
