# Changelog

All notable changes to **frontendskills** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new skill is a minor
bump, a fix to an existing one is a patch.

## [0.5.1] — 2026-06-11

### Changed
- **`write-pull-requests`** — both PR shapes now close with a fixed **Before merge** checklist (Manual review, Smoke tested, Pipeline green), posted unticked and ticked by whoever verified each gate. It survives even the trivial-diff deviation; only bot-bodied PRs go without.

## [0.5.0] — 2026-06-11

### Added
- **The workflow catalogue** (`skills/workflow/`) — two framework-agnostic skills for delivery: commits and pull requests:
  - **`write-commit-messages`** — a subject and body any developer from junior to CTO can read and act on.
  - **`write-pull-requests`** — a bug-fix or feature description reviewers from junior to CTO can follow end to end.
- **`workflow/_shared/audience.md`** — the shared writing contract: one text for three readers, each with an operational test — the junior follows it without tribal knowledge, the senior finds every claim next to its evidence, the CTO reads outcome and risk in the first lines.

### Changed
- README catalogue adds "Workflow: commits & pull requests"; the set now stands at **33 skills**.
- `plugin.json` / `marketplace.json` → `0.5.0`; descriptions add the workflow catalogue; keywords add `commits`, `pull-requests`, `workflow`.

## [0.4.0] — 2026-06-10

### Added
- **The landing catalogue** (`skills/landing/`) — five framework-agnostic skills for public pages, auditing built HTML from any stack:
  - **`build-landing-page`** — one conversion goal per page, the section grammar (hero → social proof → benefits → pricing → FAQ → final CTA), a semantic skeleton, and a hero LCP/CLS budget.
  - **`set-up-seo`** — the crawlability gate (view-source test), per-page metadata, JSON-LD structured data by page type (with the mid-2026 FAQ-rich-result reality), sitemap.xml + robots.txt (Disallow ≠ noindex), and answer-engine-readable content structure.
  - **`set-up-lead-capture`** — the destination seam, invisible-first spam defenses (honeypot + per-load time-trap, escalation to Turnstile), consent recorded at capture, double opt-in.
  - **`audit-content-quality`** — rubric-driven scoring with quoted evidence and knockout criteria; fixes only failed criteria.
  - **`audit-copy-compliance`** — pre-publish copy gate against a rules file; each violation reported with quoted text, rule, and compliant rewrite.
- **`landing/_shared/page-types.md`** — the public-page gate (page-level, empirical via the view-source test) and the priority-inversion table (public page: LCP/CLS = ranking + revenue; app surface: INP = UX).
- **`landing/_shared/rubric-convention.md`** — audit rules as a seam: bundled default, total override via the project's `.claude/rubrics/<topic>.md`, malformed-rubric stop rule, with an install offer.

### Changed
- Cross-links between the catalogues: `set-up-document-head` (SPA caveat → `landing/set-up-seo`), `set-up-forms` ↔ `set-up-lead-capture`, `optimize-performance` ↔ `landing/build-landing-page`; `frontend/_shared/architecture.md` notes the second catalogue.
- README catalogue adds "Landing & content pages"; the set now stands at **31 skills**.
- `plugin.json` / `marketplace.json` → `0.4.0`; descriptions now name both catalogues; keywords add `landing-page`, `seo`, `leads`.

## [0.3.0] — 2026-06-09

### Added
- **`create-module`** — authoring skill that keeps UI components thin by routing new logic to the right layer (utils / libs / hooks / composables / stores) behind a typed boundary, with a decision table, a barrel + colocated-test step, and a graduation rule.
- **`set-up-security-headers`** — a Content-Security-Policy and standard security headers delivered via Netlify, with `connect-src` wired from the validated env (API + realtime origins), Dependabot dependency hygiene, and an XSS-surface note.
- **`configure-ci`** — a GitHub Actions pipeline (lint → typecheck → test → build → e2e + bundle budget) that makes "CI is the real gate" literal, plus Netlify preview deploys per pull request.
- **`_shared/architecture.md`** — a seam map tracing how one `queryClient` threads router → hooks → forms → auth → realtime, with the boundary rules.

### Changed
- README catalogue adds a "Shipping & security" group and `create-module`; the set now stands at **26 skills**.
- `plugin.json` version → `0.3.0`.

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
- README rewritten (editorial) and updated to register `set-up-realtime` — the set now stands at
  **23 skills**.
- `plugin.json` version → `0.2.1`.

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
