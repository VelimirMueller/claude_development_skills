# Changelog

All notable changes to **frontendskills** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new skill is a minor
bump, a fix to an existing one is a patch.

## [0.7.1] — 2026-10-09

### Changed
- `set-up-nextjs-supabase-auth`, `set-up-supabase`: session cookies are `httpOnly` (forced through `cookieOptions` and the `setAll` merge); sign-in, sign-out and the PKCE exchange run on the server only; the browser client serves Realtime and non-auth queries. Matches `set-up-auth` (no JS-readable tokens). Verified on a local Supabase stack: every `sb-*` cookie carries `HttpOnly`.
- FastAPI track: one driver, psycopg 3 (`postgresql+psycopg://`), so SQLAlchemy and procrastinate share it and a job defers inside the request transaction. OTel uses `opentelemetry-instrumentation-psycopg`. Verified: ruff, mypy strict, pytest 8/8 incl. testcontainers Postgres 18.

## [0.7.0] — 2026-10-09

### Added
- **The multi-plugin marketplace** — six plugins next to `frontendskills`: `devcore`, `backendskills`, `infraskills`, `cliskills`, `aiskills`, `gameskills`; the set now stands at **73 skills across seven plugins**.
- **`devcore`** — `set-up-stack-profile` (the wizard behind `.claude/stack-profile.md`), `extend-skillset`, `audit-toolchain`, `audit-security`, and the shared contracts every plugin links into: `engineering-principles`, `stack-profile`, `version-protocol`, `security-baseline`, `logging-contract`, `observability`, `tech-radar`.
- **`backendskills` (15 skills)** — the Hono/Go/FastAPI service scaffolds, plus `design-http-api`, `set-up-database`, `set-up-background-jobs`, `set-up-backend-auth`, `harden-backend`, `set-up-observability`, `configure-backend-tests`, `set-up-supabase`, `secure-supabase-rls`, `build-supabase-edge-function`, `build-nextjs-backend`, `set-up-nextjs-supabase-auth`.
- **`infraskills` (8 skills)** — `containerize-service`, `set-up-opentofu`, `deploy-to-vercel`, `deploy-to-hetzner`, `deploy-to-ionos`, `set-up-delivery-pipeline`, `manage-secrets`, `deploy-otel-collector`.
- **`cliskills` (3 skills)** — `build-cli`, `release-cli`, `set-up-dev-toolchain`.
- **`aiskills` (5 skills)** — `build-llm-seam`, `build-rag-pipeline`, `set-up-llm-evals`, `build-mcp-server`, `secure-llm-features`.
- **`gameskills` (5 skills)** — `scaffold-bevy-game`, `structure-bevy-app`, `manage-bevy-assets`, `test-bevy-systems`, `optimize-bevy-game`, on Bevy 0.20.
- **Dependabot** watches the GitHub Actions workflows.

### Changed
- **Every frontend and landing skill reads `.claude/stack-profile.md` first** — package manager, framework/meta, test layout, hosting and backend track come from the profile; `nuxt`/`next` metas stop the skill and point at the framework's own mechanism where it owns routing, head, i18n or PWA.
- **`configure-ci` and `set-up-security-headers` branch on hosting** — Netlify, Vercel (`vercel.json`, preview deploys) and self-hosted (Caddy, nginx, Traefik) each get their own pipeline and header set, with the CSP defined once.
- **Skill descriptions are capped at 300 characters** — the listing budget on every turn.
- **Verify steps run `pnpm typecheck`** (`tsc -b` / `vue-tsc -b`) instead of `tsc --noEmit`.
- **`configure-analytics` — consent is required by default** (TDDDG §25): cookieless is a provider preference, not an exemption, and consent is checked per request, so it can be withdrawn.
- **`set-up-pwa`** — persists an allow-listed TanStack Query cache to IndexedDB (`buster`, `removeClient()` on logout) instead of the whole cache to `localStorage`.
- **`set-up-routing`** — `routeTree.gen.ts` is committed (excluded from Biome) so the CI typecheck passes on a clean checkout.
- **`set-up-motion`** — Vue motion via `motion-v` (`@vueuse/motion` is unmaintained); reduced-motion gating through one root `<MotionConfig reducedMotion="user">`.
- **`write-commit-messages` scales to the change** — trivial commits get the subject only; `Why:` stays mandatory.
- **`scripts/validate.sh`** — validates the whole marketplace: plugin ownership of every skill, version agreement across manifests, description length and YAML-safety, unique skill names.
- **CI** — the GitHub Actions used by the workflows are pinned by commit SHA.

### Fixed
- **`tsc --noEmit` passed vacuously in the Vite 8 templates** — the root `files: []` + references meant it checked zero files and exited 0 on a real type error; the typecheck script is now `tsc -b` / `vue-tsc -b`, in 20+ files across the set.
- **The pre-paint theme script was blocked by the catalogue's own CSP** (`script-src 'self'`, no `unsafe-inline`), so dark mode flashed light in production — moved to `public/theme-init.js`.
- **`set-up-pwa` persisted `/auth/me` to `localStorage`** through the whole-cache persister, contradicting the no-sensitive-storage stance — closed by the IndexedDB allow-list above.
- **`sendDefaultPii: false` no longer compiles in Sentry 11**, and v11 collects user info, cookies, headers and bodies by default — replaced with an explicit `dataCollection` setting.
- **`baseUrl` is error TS5101 in TS 6 and removed in TS 7** — dropped from `configure-typescript`; `paths` alone works.
- **`set-up-realtime` reconnected with no subscribers** — `prev === 'reconnecting'` missed the `offline → online` recovery, and `JSON.parse('null')` crashed the message handler; fixed, with an `idle` status and a passing browser test.
- **Relative MSW handlers (`/todos`) never match in Node** ("Failed to parse URL") — now `*/todos` with the API origin in `.env.test`.
- **FAQ rich results are retired** — Google stopped showing them for all sites on 2026-05-07; `set-up-seo` states the date and stops recommending the markup.
- **Landing descriptions were 358–469 characters**, over the 300 budget — all five rewritten, still "Use when"; four frontend descriptions (312–337) likewise.
- **The installed plugin's commit/PR skills now come from `devcore`** — see Breaking.

### Breaking
- **The root `.claude-plugin/plugin.json` is removed** — a root manifest would leak every catalogue into every plugin; each plugin now owns its manifest.
- **`write-commit-messages` and `write-pull-requests` moved from `frontendskills` to `devcore`** — installed automatically as a dependency, so existing installs keep both skills.
- **`skills/workflow/` is now `skills/core/`.**

## [0.6.0] — 2026-10-09

### Added
- **`_shared/framework-idioms.md`** — Vue 3.5 (`useTemplateRef`, `defineModel`, reactive props destructure, `useId`, `MaybeRefOrGetter` composables, Vapor readiness) and React 19.3 (Compiler-first memoization, actions vs form library, `useOptimistic`, `use()`, transitions, `ref` as a prop) side by side.
- **Feature modules** — from the second domain on, `src/features/<domain>/{api,hooks|composables,components,stores,schemas}` behind one `index.ts` (`conventions.md`, `module-patterns.md`, glossary).
- **Findability table and Nuxt 4 / Next 16 mapping** in `folder-conventions.md`: the same folder names inside `app/` (Nuxt) and `src/` (Next); explicit imports for project code (`imports.scan: false`); `app/` in Next kept for routing files.
- **`server-state.md`** — `queryOptions` as the shared unit for hooks, loaders and prefetch; a per-event invalidation table; optimistic updates via the UI (default) and via the cache with rollback.
- **`set-up-design-system`** — named themes × light/dark by swapping token values through `@theme inline`.
- **`scaffold-choices.md`** — when to pick a Vite SPA vs Nuxt/Next.

### Changed
- **`configure-linting` — Biome is the only linter and formatter.** Prettier and `prettier-plugin-tailwindcss` are removed; `useSortedClasses` (with a safe fix) sorts Tailwind classes; Vue gets full SFC support (`vue` domain, template a11y, formatter); `rules.preset` replaces the deprecated `rules.recommended`. CI drops `prettier --check`.
- **`configure-accessibility`** — Vue templates are linted by Biome; `eslint-plugin-vuejs-accessibility` is no longer installed.
- **`_shared/stack-versions.md`** — verified 2026-10-09 lines (React 19.3, Vue 3.5, Vite 8.3, Vitest 5.0, Biome 2.5, Tailwind 4.3, Pinia 4, TanStack Query 5.104); TypeScript 6.x in Vue repos until `vue-tsc` supports TS 7.
- **`set-up-state-management`** — key factory gains `lists()`/`details()`; hooks export `queryOptions`; creates invalidate `lists()`; Pinia 4 installs `@vue/devtools-api`.
- **`optimize-performance`** — React Compiler 1.0 via `@rolldown/plugin-babel` + `reactCompilerPreset` (plugin-react 6 removed the inline `babel` option); keep existing manual memoization.
- **`scaffold-frontend-project`** — Vite 8 `react-compiler-ts` template; TS `~6.0` for Vue; the template's `oxlint` is replaced by Biome.
- **`set-up-routing`** — the loader prefetches with the hook's `queryOptions`.
- **`set-up-forms`** — React 19 actions as the option for one- or two-field forms (same Zod schema, same mutation).
- **`create-module`** — routes domain code into feature modules; the description no longer promises a colocated test.
- **`landing/build-landing-page/stack-pointers.md`** — Next 16.4 Cache Components and route groups, Nuxt 4 `app/` layout.

### Fixed
- **No skill loaded from the installed plugin.** Claude Code discovers `skills/<name>/SKILL.md` one level deep; the catalogues sit at `skills/<catalogue>/<name>/`, so `claude plugin details` reported `Skills (0)`. `plugin.json` now lists `./skills/frontend/`, `./skills/landing/`, `./skills/workflow/` (33 skills load), and `scripts/validate.sh` fails when a catalogue is missing from that list.
- **`set-up-i18n`** — detection is limited to `de`/`en`, and the detected catalog loads before the first render (a German visitor saw English until a manual switch). `de` + `en` is the default pair.
- **`set-up-document-head`** — `ensureQueryData` received a bare key instead of an options object.

## [0.5.3] — 2026-10-02

### Fixed
- **`set-up-auth`** — `auth-patterns.md` and step 8 said the fetcher clears the user query and redirects on a failed refresh; since 0.5.2 it throws `HttpError(401)`, `currentUserQueryOptions` maps that to `null`, and the route guard redirects. The text now matches the code, and says why the fetcher never navigates.

## [0.5.2] — 2026-10-02

### Fixed
- **The `fetcher` seam** (`set-up-state-management`, `set-up-auth`) — the snippet spread `...init` after the merged headers, so any caller `headers` replaced `Content-Type` and the CSRF token; and `...init?.headers` dropped a `Headers` instance or a tuple array. It now builds one `Headers` object from `new Headers(init?.headers)` after spreading `init`; seam defaults never override an explicit caller header.
- The `fetcher` sets `Content-Type: application/json` only for string bodies (a `FormData` upload keeps its multipart boundary), returns `undefined` on `204 No Content`, and throws a typed `HttpError` with `status`.
- **`set-up-auth`** — `currentUserQueryOptions` maps a 401 to `null`, so the route guard redirects to `/login` instead of throwing; the refresh request now carries the CSRF header and treats a network error as a failed refresh.
- `set-up-error-boundaries/error-boundaries.md` — fixed a broken glossary link, found by the wider link check.

### Changed
- The `fetcher` is defined once in **`frontend/_shared/fetcher.md`** (base and auth versions, audit greps for the pre-0.5.2 snippet); `set-up-state-management`, `set-up-auth`, `validate-env` and `auth-patterns.md` link to it instead of carrying copies.
- **`scripts/validate.sh`** — also checks `marketplace.json`, that the plugin version agrees across both manifests, the README Status line and `CHANGELOG.md`, and resolves links in every `.md` under `skills/`, not only `SKILL.md`.
- **CI** — `.github/workflows/validate.yml` runs the validator on every pull request and push to `main`.
- README — exact install commands (marketplace, local clone, team `settings.json`), the repository vs plugin name, and an illustrative skill run.

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
