# Stack Versions (backend)

Verified lines for the backend toolchain, checked **2026-10-09**. Re-verify before scaffolding; this is a floor, not a pin.
Lookup commands and the four status words (stable, rc/beta, announced, unverified) are defined in [version-protocol.md](../../core/_shared/version-protocol.md).

Other backend skills append their rows at the end of the matching table. Keep one row per tool: `tool | line | verified-from | note`.

## TypeScript

| Tool | Line | Verified from | Note |
|---|---|---|---|
| Node.js | 24 (LTS "Krypton", 24.21.0) | `nodejs.org/dist/index.json`, first entry with `lts` set | Node 26 is Current and becomes LTS on 2026-10-28 (endoflife.date); move after that date, not before |
| `hono` | 4.13 | `npm view hono version`; dist-tags `next` = 5.0.0-rc.0 | v5 is **rc**: stay on 4.x |
| `@hono/node-server` | 2.1 | `npm view @hono/node-server version` | 2.x is `latest`; 1.19 is the `latest-1` line. `engines.node >=16.9` |
| `@hono/zod-openapi` | 1.6 | `npm view @hono/zod-openapi peerDependencies` → `zod ^4`, `hono >=4.10` | The route + OpenAPI 3.1 library used by the scaffold. Alternative: `hono-openapi` 1.3.5 (Standard Schema, any validator); not used, see [service-layout.md](service-layout.md) |
| `zod` | 4.6.5 | npm view; ran (docs/agent-reports/backend-supabase-next.md) | `z.url()`, `.loose()` are v4 API |
| `drizzle-orm` | 0.45.4 (stable) | `npm view drizzle-orm dist-tags`: `latest` 0.45.4, `rc` 1.0.0-rc.4, `beta` 1.0.0-beta.22 | 1.0 is **rc**, not latest |
| `drizzle-kit` | 0.31.11 (stable) | `npm view drizzle-kit dist-tags`: `latest` 0.31.11, `rc` 1.0.0-rc.4 | Keep orm and kit on the same channel |
| `postgres` (postgres.js) | 3.4.9 | `npm view postgres version` | |
| `pg` (node-postgres) | 8.23 | `npm view pg version` | Default driver choice is set in the Drizzle skill, not here |
| `typescript` | 7.0.2 | npm view; `next build` 16.4.0 type-check and `tsc --noEmit` both worked (docs/agent-reports/backend-supabase-next.md) | Native compiler; no programmatic API, so tools that import `typescript` may need 6.x |
| `tsx` | 4.23 | `npm view tsx version` | Dev runner (`tsx watch`). Node 24 also strips types natively, but `tsx` handles `.ts` import paths and watch mode |
| `tsdown` | 0.23 | `npm view tsdown version`; `engines` `^22.18 \|\| ^24.11 \|\| >=26` | Bundles `src/main.ts` to `dist/main.mjs`. Pre-1.0: pin with `~` |
| `@biomejs/biome` | 2.5.15 | `npm view @biomejs/biome version` | `rules.preset: "recommended"` replaces the deprecated `recommended: true` |
| `vitest` | 5.0.3 | installed; 7 tests passed (docs/agent-reports/backend-supabase-next.md) | |
| `pino` | 10.4 | `npm view pino version` | Logger per [logging-contract.md](../../core/_shared/logging-contract.md) |
| `testcontainers` / `@testcontainers/postgresql` | 12.2 | `npm view testcontainers version` | Real Postgres in integration tests |
| `pnpm` | 12.10 | `npm view pnpm version` | pnpm 12 blocks dependency build scripts until approved (`pnpm approve-builds`); the scaffold needs none |
| `openapi-typescript` | 7.13.0 | `npm view` | Types only. Peer `typescript ^5.x`: npm ERESOLVE with TS 6/7; pnpm warns. The generated `.d.ts` type-checks under TS 6.0.3. Supports OpenAPI 3.0/3.1, not 3.2 |
| `openapi-fetch` | 0.17.0 | `npm view` | No `throwOnError` option; `fetch?: (input: Request) => Promise<Response>`; `use()` middleware |
| `pg-boss` | 12.37.1 | `npm view`, tarball d.ts read, run on PG 18.6 | Node >=22.12, Postgres 13+; peer `@opentelemetry/api ^1.9.0` is imported at runtime; ~80 stable releases in 12 months; single maintainer; CLI `pg-boss migrate` |
| `graphile-worker` | 0.18.0 | `npm view` | Node >=22.18; 5 releases in 12 months; alternative, not run |
| `@opentelemetry/api` | 1.9.1 | `npm ls` | Needed by pg-boss |
| `@scalar/hono-api-reference` | 0.12.11 | `npm view` | Docs UI, not used |
| `@stoplight/spectral-cli` | 6.17.0 | `npm view` | Mentioned nowhere; optional |
| `jose` | 6.2.12 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `hono-rate-limiter` | 0.5.4 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Peer `hono ^4.10` |
| `undici` | 8.11.2 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@hono/otel` | 1.2.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Not used |
| `@opentelemetry/sdk-node` | 0.223.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@opentelemetry/auto-instrumentations-node` | 0.81.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@opentelemetry/core` | 2.12.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@opentelemetry/sdk-metrics` | 2.12.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@opentelemetry/exporter-metrics-otlp-http` | 0.223.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `@opentelemetry/instrumentation-pg` | 0.75.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `openid-client` | 6.8.8 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Named, not run |

## Supabase and Next.js

Rows from the Supabase and Next.js backend skills (verified 2026-10-09, docs/agent-reports/backend-supabase-next.md). The `typescript`, `zod` and `vitest` rows of that report update the TypeScript table above.

| Tool | Line | Verified from | Note |
|---|---|---|---|
| Supabase CLI (npm `supabase`) | 2.120.0 | npm view; GitHub release v2.120.0 published 2026-10-06; ran it | local Postgres major_version 17 in config template, image postgres 17.11.0.004; `supabase init` writes [experimental.pgdelta] enabled = true |
| @supabase/supabase-js | 2.117.3 | npm view; installed | corsHeaders export at `@supabase/supabase-js/cors` from 2.95.0 |
| @supabase/ssr | 0.12.7 | npm view; installed, source read | default cookie options httpOnly false, sameSite lax, maxAge 400 days |
| @supabase/server | 1.9.1 | npm view; type-checked and ran in Edge runtime | README: v1 public beta; `withSupabase`, `createSupabaseContext` |
| next | 16.4.0 | npm view; GitHub release 2026-10-07; built and ran | Node >= 20.9; TypeScript >= 5.1; Turbopack default; proxy.ts replaces middleware.ts, Node runtime; error.tsx `retry` prop stable since 16.3.0 |
| react / react-dom | 19.3.0 | npm view; installed | |
| server-only | 0.0.1 | npm view | Next resolves it internally |
| Deno (local CLI used for checks) | 2.9.7 and 2.1.4 | docker images; deno check + deno test passed on both | Supabase Edge Runtime 1.77.4 reports compatibility with Deno v2.1.4 |

## Go

| Tool | Line | Verified from | Note |
|---|---|---|---|
| Go | 1.27 (1.27.2) | `curl -s 'https://go.dev/dl/?mode=json'`; 1.26.9 also supported, 1.25 EOL 2026-08-19 (endoflife.date) | `go mod init` writes `go 1.27.1`; keep the `go` line at the oldest release you test in CI |
| `net/http` ServeMux | stdlib, method + `{wildcard}` patterns since 1.22 | Ran `GET /notes/{id}` with `r.PathValue("id")` on 1.27.1 | Default router; `chi` stays an option, see [service-layout.md](service-layout.md) |
| `go-chi/chi` | v5.3.2 | GitHub `go-chi/chi` releases/latest | Only when you need its middleware set or sub-router grouping |
| `sqlc` | v1.31.1 | GitHub `sqlc-dev/sqlc` releases/latest | Not installed on the verifying machine: version verified, binary not run |
| `jackc/pgx` | v5.11.0 | GitHub `jackc/pgx` releases/latest | `pgxpool` is the pool |
| `golangci-lint` | v2.14.0 | `golangci-lint --version` (built with go1.27.1, 2026-09-24); GitHub releases/latest | Config needs `version: "2"`; `golangci-lint config verify` passes on the scaffold |
| `testcontainers-go` | v0.44.0 | GitHub `testcontainers/testcontainers-go` releases/latest | Postgres module is `modules/postgres` at the same tag |
| `oapi-codegen` | v2.8.0 | proxy.golang.org; ran with `go get -tool` | Supports OpenAPI 3.1 (type arrays -> `*string`); README says 3.0 and 3.1 |
| `oapi-codegen/nethttp-middleware` | v1.2.0 | proxy.golang.org; ran | Request validator; enforces min/max, generated server does not |
| `oapi-codegen/runtime` | v1.7.0 | proxy.golang.org | |
| `pressly/goose/v3` | v3.28.0 | proxy.golang.org; ran `up`, `validate`, `create` on PG 18.6 | `-- +goose NO TRANSACTION` verified for `CREATE INDEX CONCURRENTLY` |
| `golang-migrate/migrate/v4` | v4.20.1 | proxy.golang.org | Not chosen |
| `riverqueue/river` (+ `riverdriver/riverpgxv5`, `rivermigrate`, CLI `cmd/river`) | v0.49.0 | proxy.golang.org; compiled and ran | go.mod `go 1.26.0`; pre-1.0 |
| `coreos/go-oidc/v3` | v3.21.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Chosen over `jwx` / `golang-jwt`: JWKS cache, iss/aud/exp, alg allow-list in one small API |
| `lestrrat-go/jwx/v3` | v3.3.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Not chosen |
| `golang-jwt/jwt/v5` | v5.3.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Not chosen |
| `go.opentelemetry.io/otel` | v1.47.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` | v0.72.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `go.opentelemetry.io/contrib/bridges/otelslog` | v0.21.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Bridge not run |
| `go.opentelemetry.io/contrib/exporters/autoexport` | v0.72.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `exaring/otelpgx` | v0.13.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `rs/cors` | v1.11.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Last release 2024-08, dormant |
| `golang.org/x/time` | v0.16.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `go-jose/v4` | v4.1.4 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `govulncheck` | v1.8.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |

## Python

| Tool | Line | Verified from | Note |
|---|---|---|---|
| Python | 3.14 (3.14.8) | endoflife.date/api/python.json; `python3 --version` = 3.14.7 | Supported to 2030-10-31; 3.13 supported to 2029-10-31 |
| `uv` | 0.12.24 | PyPI JSON `info.version`; local 0.11.30 also ran the scaffold | `uv init --package` writes `uv_build` as the backend, bounded to the minor of your uv |
| `fastapi` | 0.143 | PyPI JSON | `[tool.fastapi] entrypoint` is read by `fastapi run` / `fastapi dev` |
| `pydantic` | 2.14 | PyPI JSON | |
| `pydantic-settings` | 2.15 | PyPI JSON | |
| `sqlalchemy` | 2.1.4 | PyPI JSON | `sqlalchemy[asyncio]`; `async_sessionmaker`, `AsyncSession` |
| `alembic` | 1.20 | PyPI JSON | |
| `asyncpg` | 0.32 | PyPI JSON | Async driver for SQLAlchemy (`postgresql+asyncpg://`) |
| `psycopg` | 3.3.6 | PyPI JSON | Alternative async driver |
| `uvicorn` | 0.54 | PyPI JSON | Pulled in by `fastapi[standard]` |
| `structlog` | 26.1 | PyPI JSON | Logger per [logging-contract.md](../../core/_shared/logging-contract.md) |
| `ruff` | 0.16.10 | PyPI JSON | Lint and format. Pre-1.0: pin with `~=` |
| `mypy` | 2.4 | PyPI JSON | Type gate in the scaffold, `strict = true` with the Pydantic plugin |
| `ty` | 0.0.85 (**beta**) | PyPI JSON; docs.astral.sh/ty and the repo README say "ty is currently in beta", `0.0.x` versioning | Run it in CI as a second opinion; do not make it the only gate yet |
| `pytest` | 9.1 | PyPI JSON | |
| `pytest-asyncio` | 1.4 | PyPI JSON | `asyncio_mode = "auto"` |
| `httpx` | 0.28.1 | PyPI JSON | `ASGITransport` for in-process tests |
| `testcontainers` (Python) | 4.15 | PyPI JSON; `requires_python >=3.10` | |
| `procrastinate` | 3.10.0 | PyPI; ran worker, retry, periodic, atomic defer | Python >=3.10, psycopg 3 |
| `pgqueuer` / `taskiq` | 1.5.0 / 0.13.0 | PyPI | Not evaluated |
| `pyjwt` | 2.15.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `slowapi` | 0.1.10 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Released 2026-06-13 |
| `opentelemetry-distro` | 0.66b1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `opentelemetry-instrumentation-fastapi` / `-asyncpg` / `-sqlalchemy` | 0.66b1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | `-sqlalchemy` supports sqlalchemy <2.1 (scaffold pins 2.1.4) and silently instruments nothing; use `-asyncpg` |
| `opentelemetry-sdk` | 1.45.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `schemathesis` | 4.30.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `pip-audit` | 2.10.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md | |
| `starlette` | 1.7.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md | Observed |

## Shared

Cross-language tools and specs.

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `squawk-cli` | 2.68.0 | `npm view`, ran on a sample migration (exit 1) | Migration linter |
| `oasdiff` | v1.33.0 | proxy.golang.org, `brew info oasdiff` | Not run |
| PostgreSQL | 18.6 current; 14 EOL Nov 2026 | postgresql.org/support/versioning | Image `postgres:18` mounts `/var/lib/postgresql` (data in `18/docker`) |
| PgBouncer | 1.26.0 latest in changelog; protocol prepared statements since 1.21 | pgbouncer.org changelog/config, pgx `doc.go` | `max_prepared_statements` default 200 per config page |
| OpenAPI | 3.2.0 released 2025-09-19, tooling lags | openapis.org, openapi-typescript README/issue #2577 | Skills stay on 3.1 |
| IETF Idempotency-Key | draft rev 07, not an RFC | datatracker | RFC 9457 (obsoletes 7807), RFC 9745 Deprecation, RFC 8594 Sunset verified as RFCs |
| `gitleaks` | v8.30.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md; images/commands run | |
| `osv-scanner` | v2.6.0 | docs/agent-reports/backend-auth-sec-o11y-tests.md; images/commands run | Flagged real advisories (`golang.org/x/net`) in a fresh Go service's transitive deps: first CI run may be red |
| `zizmor` | v1.30.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md; images/commands run | |
| GitHub Actions (`checkout`, `setup-node`, `pnpm/action-setup`, `setup-go`, `setup-uv`, `mise-action`) | v7.0.1 / v7.1.0 / v6.1.0 / v7.0.0 / v10.2.0 / v5.1.1 | docs/agent-reports/backend-auth-sec-o11y-tests.md; Action SHAs via gh | SHA-pinned in the CI skills |

## Rules

## Rule: Floors, not pins
**Why:** A table is a snapshot; readers treat it as a pin and ship stale software.
**How to apply:** Run the lookup from [version-protocol.md](../../core/_shared/version-protocol.md) before scaffolding and write the number you get. Where the table says rc, beta or unverified, say so to the user.

## Rule: One Node line, one Go line, one Python line per repo
**Why:** CI, Docker and local runs that differ by a major version produce bugs that only appear in one of them.
**How to apply:** Pin the runtime in one source: `mise.toml` (or the profile's `runtime_manager`), plus `engines.node`, the `go` line in `go.mod`, `requires-python` and `.python-version`. CI reads the same source.

## When to deviate

- A host that fixes the runtime (Vercel functions, Cloudflare Workers) wins over the table. Check its supported versions.
- A library you publish keeps wide `engines` / `requires-python` ranges and tests the edges.
- An rc or beta line (Hono 5, Drizzle 1.0, `ty`) is fine when the owner opts in. Say so in the PR.
