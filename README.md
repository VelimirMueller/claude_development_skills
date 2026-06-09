# frontendskills

Opinionated, audit-aware Claude Code skills for building scalable, maintainable frontend projects.

This plugin captures development knowledge — process and technical, blended — as situation-based skills that Claude loads on demand. Each skill is **idempotent**: it inspects the current project state first and applies only what is missing, so the same skill works on a brand-new project and on an existing one being brought up to standard. Skills are **dual-framework** (React 19 / Vue 3) and target Vite single-page apps.

## Status

**0.2.1 — the frontend domain covers a full Vite-SPA lifecycle (23 skills).** Together they cover a full Vite-SPA lifecycle: bootstrap → language & tooling → structure → state → testing → capabilities → experience → polish. Infrastructure (CI/CD) and backend domains will follow under the same plugin.

## What's inside

Skills live under `skills/frontend/`. Each is a folder with a `SKILL.md` (the trigger + body Claude sees first) and one or more reference `.md` files holding deep-dive rules with rationale. Every skill is audit-first and branches React 19 / Vue 3.

**Bootstrap & tooling**
- `scaffold-frontend-project` — Vite + TS app (React 19 / Vue 3), pnpm via Corepack, Node LTS, Tailwind v4.
- `clean-frontend-scaffolding` — strip the Vite demo boilerplate.
- `configure-typescript` — strict mode + modern flags (`verbatimModuleSyntax`, …) + the `@/` alias everywhere.
- `validate-env` — Zod-validate `import.meta.env` at startup; one typed `env` object the seams import.
- `configure-linting` — Biome (lint + import sort) + Prettier (format) + lefthook pre-commit.
- `set-up-frontend-structure` — atomic-design folders + barrel files.

**State, data & resilience**
- `set-up-state-management` — TanStack Query (server) + Zustand/Pinia (UI) with a hard boundary, query-key factory, fetch seam.
- `set-up-realtime` — transport-agnostic WebSocket seam (reconnect, offline-aware, no-op without config) that writes live server-push updates into the Query cache (patch entity + invalidate lists, re-sync on reconnect); connection status as the only UI store.
- `set-up-error-boundaries` — layered boundaries + a pluggable `captureError` seam.
- `configure-error-tracking` — wire that seam to Sentry (tracing, masked replay, hidden source maps).

**Testing**
- `configure-test-stack` — Vitest (unit/integration in Node + UI in real-browser mode) + Storybook stories-as-tests + Playwright e2e + MSW, organized under `tests/{unit,ui,integration,e2e}`.

**Capabilities**
- `set-up-routing` — TanStack Router / Vue Router: typed routes, lazy splitting, loader↔Query prefetch, guards.
- `set-up-forms` — React Hook Form / VeeValidate + Zod, schema-first, accessible, submit → mutation.
- `set-up-auth` — current user as server state, no-`localStorage` tokens, route guards, single-flight refresh.
- `set-up-i18n` — i18next / vue-i18n, typed keys, lazy locales, `Intl` formatting.
- `set-up-document-head` — per-route `<title>`/meta/OG + `<html lang>` (a11y + SEO) via TanStack Router head / Unhead.
- `set-up-feature-flags` — vendor-agnostic OpenFeature seam (`useFlag`), safe defaults, user targeting, flag-gated routes.

**Experience**
- `set-up-design-system` — Tailwind v4 `@theme` tokens, class-based dark mode, cva primitives.
- `configure-accessibility` — a11y lint + semantic/focus/reduced-motion conventions + axe in tests.
- `optimize-performance` — React Compiler, route/code-splitting, bundle budget, Core Web Vitals.

**Polish**
- `set-up-motion` — native View Transitions + the Motion library, all reduced-motion-gated.
- `set-up-pwa` — vite-plugin-pwa offline shell + installable, with optional query-cache persistence.
- `configure-analytics` — provider-agnostic analytics seam + Web Vitals RUM, privacy-first.

Shared knowledge lives in `skills/frontend/_shared/`:
- `conventions.md` — canonical conventions (`src/` root, `@/` alias, naming, `stores/`).
- `stack-versions.md` — version policy (Node LTS, pnpm, Biome/Prettier, caret-vs-pinned).
- `glossary.md` — atomic-design terms + server-state vs UI-state definitions.

## Recommended order

The skills compose front-to-back. A greenfield project runs roughly:

`scaffold-frontend-project` → `clean-frontend-scaffolding` → `configure-typescript` → `validate-env` → `configure-linting` → `set-up-frontend-structure` → `set-up-state-management` → `set-up-error-boundaries` → `configure-test-stack` → `set-up-routing` → `set-up-forms` → `set-up-auth` → … → experience & polish.

Each skill is idempotent, so this is a guide, not a constraint — run any one against an existing project to bring just that concern up to standard.

## Install (local)

This plugin is intended for local Claude Code use. Add the plugin's directory as a marketplace path in your Claude Code settings; Claude Code auto-discovers `skills/**/SKILL.md`.

## Validate

Run `bash scripts/validate.sh` to check that:
- `.claude-plugin/plugin.json` parses and has the required fields.
- Every `SKILL.md` has YAML frontmatter with `name` and `description` (the latter starting with `Use when`).
- Every relative reference link in a `SKILL.md` resolves to an existing file.
