# Changelog

All notable changes to **frontendskills** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new skill is a minor
bump, a fix to an existing one is a patch.

## [0.2.2] — 2026-06-09

### Changed
- **README rewritten** in an editorial voice, with the skill catalogue as the centrepiece.
- `plugin.json` version → `0.2.2`.

### Added
- **`CHANGELOG.md`** (this file) and **`CONTRIBUTING.md`** — the house style and how to add a
  skill that fits.

## [0.2.1] — 2026-06-09

### Added
- **`set-up-realtime`** — live server→client updates, done through the existing state boundary
  rather than beside it. A transport-agnostic WebSocket seam (`realtime.ts`) with
  reconnect-and-backoff, offline awareness, and a clean no-op when unconfigured; a
  `useRealtimeSync` hook/composable that writes pushed data into the TanStack Query cache (patch
  the entity, invalidate the lists, re-sync on reconnect); and connection status as the one
  piece of UI state realtime owns. React 19 / Vue 3, with a companion `realtime-patterns.md`
  covering the cache-not-store rule and the SSE / vendor / high-volume / collaborative
  deviations.

### Changed
- README registers `set-up-realtime` — the set now stands at **23 skills**.

## [0.2.0] — 2026-06-08

### Added
The set grows from the four-skill foundation to **22 skills covering a full Vite-SPA lifecycle**
— bootstrap → language & tooling → structure → state → testing → capabilities → experience →
polish:

- **Bootstrap & tooling** — `scaffold-frontend-project`, `validate-env`, `configure-linting`.
- **State, data & resilience** — `set-up-state-management` (the server/UI boundary, a typed
  query-key factory, the `fetcher` seam) and `configure-error-tracking`.
- **Testing** — `configure-test-stack` (Vitest browser mode, Storybook, Playwright, MSW).
- **Capabilities** — `set-up-routing`, `set-up-forms`, `set-up-auth`, `set-up-i18n`,
  `set-up-document-head`, `set-up-feature-flags`.
- **Experience** — `set-up-design-system`, `configure-accessibility`, `optimize-performance`.
- **Polish** — `set-up-motion`, `set-up-pwa`, `configure-analytics`.

### Changed
- Tests moved to a top-level `tests/` tree organised by type, rather than co-located.
- The toolchain settled on pnpm + Biome (lint) + Prettier (format) + Node LTS, with a versioning
  policy of caret (`^`) for runtime deps and tilde (`~`) for build/test tooling.

## [0.1.0] — 2026-05-04

### Added
- Plugin foundation: the manifest, a structure validator (`scripts/validate.sh`), and the shared
  references under `skills/frontend/_shared/` (conventions, stack versions, glossary).
- The first four skills: `clean-frontend-scaffolding`, `configure-typescript`,
  `set-up-frontend-structure`, and `set-up-error-boundaries`.
- The plugin's core stance: audit-first, idempotent, dual-framework skills built on seams and
  boundaries, with progressive-disclosure reference files.
