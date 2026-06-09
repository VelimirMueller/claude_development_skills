# frontendskills

**Senior frontend judgment — externalized as Claude Code skills that _execute_.**

Not a template that freezes a snapshot of "best practice," but a set of audit-first
procedures that inspect what's already in front of them and apply only the senior move
that's missing. Dual-framework **React 19 / Vue 3**, every version-specific claim checked
against 2026's live tooling.

`23 skills` · `full Vite-SPA lifecycle` · `React 19 / Vue 3` · `MIT`

---

## The idea

Every senior carries a body of judgment that rarely gets written down — where server state
ends and UI state begins, why an auth token must never touch `localStorage`, what a "molecule"
is and isn't. It usually lives in one head and leaves when they do.

`frontendskills` takes that judgment out of the head and makes it executable — on demand, on
any codebase, the same way every time. Three properties make it a *tool* rather than a
template:

- **Audit-first & idempotent.** Each skill inspects what's already there and applies only the
  missing move. Point it at an empty directory and it scaffolds; point it at a three-year-old
  repo and it brings one concern up to standard; run it twice and the second run is a no-op.
- **Seams, not scattered vendor calls.** `fetcher`, `captureError`, `env`, `queryKeys`, the
  analytics and flag clients — one point of indirection each, so swapping a vendor or mocking a
  test is a one-file change.
- **Boundaries that make bugs unrepresentable.** Server data lives in the Query cache, never a
  store; tokens never touch `localStorage`. The worst recurring bugs are designed out, not
  patched.

Every rule ships with its *when to deviate*. The aim is judgment, not dogma.

## The catalogue

**Bootstrap & tooling**
- **`scaffold-frontend-project`** — Vite + TS app (React 19 / Vue 3), pnpm via Corepack, Node LTS, Tailwind v4.
- **`clean-frontend-scaffolding`** — strip the Vite demo down to a clean slate.
- **`configure-typescript`** — `strict` plus the modern flags, and the `@/` alias everywhere.
- **`validate-env`** — Zod-validate `import.meta.env` at boot; one typed `env` the seams import.
- **`configure-linting`** — Biome (lint + import sort) + Prettier (format) + a lefthook pre-commit.
- **`set-up-frontend-structure`** — atomic-design folders and barrels; tests in `tests/` by type.

**State, data & resilience**
- **`set-up-state-management`** — TanStack Query (server) beside Zustand/Pinia (UI), one hard boundary, a typed query-key factory, a `fetcher` seam.
- **`set-up-realtime`** — a transport-agnostic WebSocket seam that writes live server-push straight into the Query cache (patch the entity, invalidate the lists, re-sync on reconnect); connection status as the only UI store.
- **`set-up-error-boundaries`** — layered boundaries behind a pluggable `captureError` seam.
- **`configure-error-tracking`** — wire that seam to Sentry: tracing, masked replay, hidden source maps.

**Testing**
- **`configure-test-stack`** — Vitest (Node + real-browser), Storybook stories-as-tests, Playwright e2e, and MSW mocking the *network*, under `tests/{unit,ui,integration,e2e}`.

**Capabilities**
- **`set-up-routing`** — TanStack Router / Vue Router: typed routes, lazy splitting, loader↔Query prefetch, guards.
- **`set-up-forms`** — React Hook Form / VeeValidate + Zod: one schema is shape, rules, and types; submit → mutation.
- **`set-up-auth`** — the current user as server state, no `localStorage` tokens, route guards, single-flight 401 refresh.
- **`set-up-i18n`** — i18next / vue-i18n: typed keys, lazy locales, `Intl` for every format.
- **`set-up-document-head`** — per-route title/meta/OG and a truthful `<html lang>` (a11y + SEO).
- **`set-up-feature-flags`** — a vendor-agnostic OpenFeature seam, fail-closed defaults, targeting, flag-gated routes.

**Experience**
- **`set-up-design-system`** — Tailwind v4 `@theme` tokens, class-based dark mode applied before first paint, cva primitives.
- **`configure-accessibility`** — a11y lint, semantic/focus/reduced-motion conventions, axe in tests.
- **`optimize-performance`** — the React Compiler, route/code-splitting, a CI bundle budget, Core Web Vitals.

**Polish**
- **`set-up-motion`** — native View Transitions + the Motion library, every animation reduced-motion-gated.
- **`set-up-pwa`** — a `vite-plugin-pwa` offline shell, installable, with optional query-cache persistence.
- **`configure-analytics`** — a provider-agnostic, privacy-first analytics seam + Web Vitals RUM.

## How it composes

The skills interlock front-to-back. A greenfield project runs roughly:

```
scaffold → clean → configure-typescript → validate-env → configure-linting →
set-up-frontend-structure → set-up-state-management → set-up-error-boundaries →
configure-test-stack → set-up-routing → set-up-forms → set-up-auth → … → experience & polish
```

The router carries the `queryClient` in its context, so a route loader prefetches into the
exact cache a component's hook reads; the auth guard reads that same context; the form's submit
invalidates that same query key; realtime writes into it from a socket. Because every skill is
audit-first, this is a guide, not a constraint — run any one against an existing project to
bring just that concern up to standard.

## Install

For local Claude Code use. Add this directory as a marketplace path in your Claude Code
settings; Claude Code auto-discovers every `skills/**/SKILL.md`. A skill announces when it's
relevant — *"Use when adding state management…"* — and loads only then, so the knowledge costs
nothing until the moment it's needed.

## Validate

```bash
bash scripts/validate.sh
```

Checks that the manifest parses, every `SKILL.md` carries a `name` and a `Use when…`
description, and every relative reference link resolves.

## Further reading

- **[RATIONALE.md](RATIONALE.md)** — the design narrative: every load-bearing decision as *X over Y, for Z*.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — the house style, and how to add a skill that fits.
- **[CHANGELOG.md](CHANGELOG.md)** — what landed, and when.

## Status

**v0.2.2.** The frontend domain covers a full Vite-SPA lifecycle — bootstrap → language &
tooling → structure → state → testing → capabilities → experience → polish — in 23 composable
skills. Infrastructure (CI/CD, a security baseline) and backend domains will follow under the
same plugin.

## License

MIT © 2026 Velimir Müller.
