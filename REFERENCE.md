# Reference

The full catalogue, the install commands, the team setup, the run example and the composition chains. The README keeps the short version.

## Install each plugin

One step per plugin (Claude Code 2.1.275 or later adds the marketplace on the way):

```text
/plugin install devcore --marketplace VelimirMueller/claude-skills
/plugin install frontendskills --marketplace VelimirMueller/claude-skills
/plugin install backendskills --marketplace VelimirMueller/claude-skills
/plugin install infraskills --marketplace VelimirMueller/claude-skills
/plugin install cliskills --marketplace VelimirMueller/claude-skills
/plugin install aiskills --marketplace VelimirMueller/claude-skills
/plugin install gameskills --marketplace VelimirMueller/claude-skills
```

Update with `/plugin marketplace update frontendskills`.

## The catalogue

### devcore

- **`set-up-stack-profile`** — Detects the stack, asks only the gaps, writes `.claude/stack-profile.md`.
- **`audit-security`** — Scans secrets, deps, authz, headers, CI; fixes only approved findings.
- **`audit-toolchain`** — Compares tooling to the radar and profile; reports gaps, changes nothing.
- **`extend-skillset`** — Authors a house-style skill for a tool nothing covers.
- **`write-commit-messages`** — A subject and body any developer can act on.
- **`write-pull-requests`** — A description reviewers can follow end to end.

### frontendskills

**Bootstrap & tooling**

- **`scaffold-frontend-project`** — Vite + TS SPA (React 19 / Vue 3), pnpm, Node LTS, Tailwind v4.
- **`clean-frontend-scaffolding`** — Strips the Vite demo down to a minimal shell.
- **`configure-typescript`** — Strict flags, TS 6/7-safe paths, one `@/` alias in sync.
- **`validate-env`** — Zod-validates `import.meta.env` once; exports a typed `env`.
- **`configure-linting`** — Biome as the only lint/format/sort tool, plus a pre-commit hook.
- **`set-up-frontend-structure`** — Atomic-design folders, feature modules, tests in `tests/`.
- **`create-module`** — Routes new logic to the right layer, keeping components thin.

**State, data & resilience**

- **`set-up-state-management`** — TanStack Query for server state, Zustand/Pinia for UI state.
- **`set-up-realtime`** — A WebSocket seam writing server push into the Query cache.
- **`set-up-error-boundaries`** — Layered boundaries behind a pluggable `captureError` seam.
- **`configure-error-tracking`** — Points `captureError` at Sentry; no-op without a DSN.

**Testing**

- **`configure-test-stack`** — Vitest, Storybook stories-as-tests, Playwright, MSW under `tests/`.

**Capabilities**

- **`set-up-routing`** — TanStack Router / Vue Router: typed, lazy, loader→Query prefetch, guards.
- **`set-up-forms`** — React Hook Form / VeeValidate + Zod: schema-first, submit → mutation.
- **`set-up-auth`** — Current user as server state, no `localStorage`, single-flight 401 refresh.
- **`set-up-i18n`** — i18next / vue-i18n: typed keys, lazy locales, `Intl` formats.
- **`set-up-document-head`** — Per-route title/meta/OG plus a truthful `<html lang>`.
- **`set-up-feature-flags`** — Vendor-agnostic OpenFeature seam with fail-closed defaults.

**Experience**

- **`set-up-design-system`** — Tailwind v4 `@theme` tokens, dark mode, cva primitives.
- **`configure-accessibility`** — a11y lint, semantic/focus/reduced-motion rules, axe in tests.
- **`optimize-performance`** — React Compiler, route splitting, bundle budget, Core Web Vitals.

**Polish**

- **`set-up-motion`** — Native View Transitions + Motion, reduced-motion-gated.
- **`set-up-pwa`** — `vite-plugin-pwa` offline shell, installable, optional cache persistence.
- **`configure-analytics`** — Provider-agnostic, consent-gated analytics seam + Web Vitals.

**Shipping & security**

- **`configure-ci`** — A least-privilege GitHub Actions gate and preview deploys per PR.
- **`set-up-security-headers`** — A strict CSP and headers, dependency hygiene, honest XSS surface.

**Landing & content pages (framework-agnostic)**

- **`build-landing-page`** — One job per page: section grammar, semantic skeleton, LCP/CLS budget.
- **`set-up-seo`** — The crawlability gate, metadata, JSON-LD, sitemap, robots.
- **`set-up-lead-capture`** — The destination seam, layered spam defense, consent, double opt-in.
- **`audit-content-quality`** — Scores pages against a rubric; fixes only failed criteria.
- **`audit-copy-compliance`** — Pre-publish copy gate: each violation quoted with a compliant rewrite.

These five audit *built HTML* from any stack and gate on the page-level question in
[`skills/landing/_shared/page-types.md`](skills/landing/_shared/page-types.md): readable without JS?

### backendskills

**Service scaffolds**

- **`scaffold-hono-service`** — A strict-TS Hono service with OpenAPI and health checks.
- **`scaffold-go-service`** — A stdlib `net/http` Go service: layers, slog, validated config.
- **`scaffold-fastapi-service`** — A uv src-layout FastAPI service with lifespan and problem+json.

**Contracts & data**

- **`design-http-api`** — OpenAPI 3.1 contract, RFC 9457 errors, generated typed client.
- **`set-up-database`** — Postgres via compose, ORM/sqlc, migrations, a safety gate.
- **`set-up-background-jobs`** — A Postgres-backed queue, outbox, idempotent handlers, retries.

**Security & operations**

- **`set-up-backend-auth`** — Verifies OIDC JWTs, BFF cookies, deny-by-default policies, tenant scoping.
- **`harden-backend`** — Validation, rate/size limits, CORS, SSRF-safe fetch, CI scanning.
- **`set-up-observability`** — OpenTelemetry: SDK first, HTTP/DB instrumentation, RED metrics.
- **`configure-backend-tests`** — Unit, real-Postgres integration, HTTP, and contract tests.

**Supabase & Next.js**

- **`build-nextjs-backend`** — A server-only data layer authorizing every call in Next 16.
- **`build-supabase-edge-function`** — Edge Functions with caller auth, CORS, secrets, tests.
- **`secure-supabase-rls`** — RLS on every table, per-operation policies, proven with pgTAP.
- **`set-up-nextjs-supabase-auth`** — Supabase Auth in Next 16: cookie clients, verified claims, PKCE.
- **`set-up-supabase`** — CLI local stack, migrations-only schema, generated types, secret-safe client.

### infraskills

- **`containerize-service`** — Multi-stage Dockerfile per track: non-root, pinned, scanned.
- **`deploy-otel-collector`** — One Compose collector per environment exporting to any OTLP backend.
- **`deploy-to-hetzner`** — OpenTofu VM per environment, firewall, Traefik TLS, image-digest deploys.
- **`deploy-to-ionos`** — IONOS Cloud via OpenTofu, or Deploy Now for a static site.
- **`deploy-to-vercel`** — Linking, env per environment, protected previews, rollback, gated deploys.
- **`manage-secrets`** — Decide where each secret lives; keep them out of images, logs, bundles.
- **`set-up-delivery-pipeline`** — Trunk-based CI/CD: one image, promote dev→stg→prd by digest.
- **`set-up-opentofu`** — OpenTofu layout, encrypted state, plan-as-artifact, drift detection.

### cliskills

- **`build-cli`** — Subcommands, typed args, `--json`, exit codes, `--dry-run`, tested.
- **`release-cli`** — SemVer over the CLI surface, changelog-driven notes, signed artifacts.
- **`set-up-dev-toolchain`** — mise or just, shared tasks, lefthook hooks, a doctor task.

### aiskills

- **`build-llm-seam`** — One module owns every model call: tiers, retries, structured output.
- **`build-mcp-server`** — Task-shaped tools, read-only by default, typed inputs, tested.
- **`build-rag-pipeline`** — Hybrid retrieval over pgvector, citations, an "I don't know" path.
- **`secure-llm-features`** — Prompt-injection model, least-privilege tools, mapped to OWASP LLM Top 10.
- **`set-up-llm-evals`** — Golden datasets, deterministic checks, a calibrated judge, CI gate.

### gameskills

- **`scaffold-bevy-game`** — A lib+bin cargo project with fast builds and optional wasm.
- **`structure-bevy-app`** — Plugin-per-feature layout, app states, system ordering.
- **`manage-bevy-assets`** — One asset-table seam, custom loaders, hot reload, embedded assets.
- **`test-bevy-systems`** — Headless App/World tests with MinimalPlugins and deterministic time.
- **`optimize-bevy-game`** — Measure first, then fix change detection, parallelism, allocations.

## Team setup

For a team, commit the same setup to the project's `.claude/settings.json`, so everyone who
trusts the folder gets the skills:

```json
{
  "extraKnownMarketplaces": {
    "frontendskills": {
      "source": { "source": "github", "repo": "VelimirMueller/claude-skills" }
    }
  },
  "enabledPlugins": {
    "devcore@frontendskills": true,
    "backendskills@frontendskills": true
  }
}
```

Run the wizard once per repo and commit the resulting `.claude/stack-profile.md` — it is team
knowledge, not a secret, and it is what makes the author's defaults stay defaults.

## What a run looks like

Illustrative: `set-up-state-management` on a fresh `pnpm create vite` React app. You ask *"add
state management"*; Claude matches the `Use when` line and works through it:

```text
1. Audit     no @tanstack/react-query, no zustand, no src/libs/fetcher.ts   → full setup
2. Framework react 19 detected                                                → React track
3. Install   pnpm add @tanstack/react-query zustand
             pnpm add -D @tanstack/react-query-devtools
4. Seams     src/libs/fetcher.ts  src/libs/queryKeys.ts  src/libs/queryClient.ts
5. Examples  src/hooks/useTodos.ts  src/hooks/useCreateTodo.ts  src/stores/useTodoFiltersStore.ts
6. Wire      src/main.tsx → <QueryClientProvider> + devtools in DEV only
7. Verify    pnpm typecheck
```

Run it a second time and step 1 finds everything in place: the skill exits with *"State
management already in place."* and changes nothing.

## Composition chains

The skills interlock front-to-back. A greenfield frontend runs roughly:

```text
scaffold → clean → configure-typescript → validate-env → configure-linting →
set-up-frontend-structure → set-up-state-management → set-up-error-boundaries →
configure-test-stack → set-up-routing → set-up-forms → set-up-auth → … → experience & polish
```

A backend service and its deployment compose the same way:

```text
set-up-stack-profile → scaffold-<track>-service → set-up-database → design-http-api →
set-up-backend-auth → harden-backend → set-up-observability → configure-backend-tests →
containerize-service → set-up-delivery-pipeline → deploy-to-<host> → deploy-otel-collector
```

The seams carry across the whole chain. Each service keeps its I/O vendors — db, logger, tracer,
clock — behind one `platform/` seam; the frontend reaches it through its `fetcher` seam with the
OpenAPI client `design-http-api` generated; one OpenTelemetry pipeline ships every service's
telemetry to one collector; one `deploy.sh` contract is all `deploy-to-<host>` expects.

## How it works, in full

```text
  you  ·  "add state management"  ·  "set up my stack profile"
     │  Claude matches the skill's one-line "Use when" description
     ▼
  ┌────────────────────────┐   reads first   ┌─────────────────────────────┐
  │  skill  (SKILL.md)     │ ──────────────▸ │  .claude/stack-profile.md   │
  │  one of 73, 7 plugins  │                 │  written once by the wizard │
  └───────────┬────────────┘                 └─────────────────────────────┘
              │  1 audit   what is already there?
              │  2 apply   only the missing move, behind one seam
              │  3 verify  typecheck · tests
              ▼
  ┌────────────────────────┐
  │  your repo             │   second run = no-op
  └────────────────────────┘

  devcore ◂── every other plugin depends on it (shared contracts)
```

The router carries the `queryClient` in its context, so a route loader prefetches into the exact
cache a component's hook reads; the auth guard reads that same context; the form's submit
invalidates that same query key; realtime writes into it from a socket. Because every skill is
audit-first, this is a guide, not a constraint: run any one against an existing project.
