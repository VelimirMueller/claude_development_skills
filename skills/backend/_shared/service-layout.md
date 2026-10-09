# Service Layout

One layering standard for a backend service in TypeScript, Go and Python. The names differ by language; the boundaries do not.
Principles behind it: [one seam per vendor and per I/O boundary, validate at the edge, trust inside](../../core/_shared/engineering-principles.md).

```
transport (HTTP handlers)  ──▶  service (use cases)  ──▶  repository (SQL)
        │                             │                        │
        └─────────────── platform seams: db · logger · tracer · clock ───────────────┘
config: read once in main, passed down. main wires everything (composition root).
```

Dependencies point one way. `transport` imports `service`; `service` imports `repository`; nothing imports `transport`. `config` is imported only by `main`.

## Rule: Transport owns HTTP and nothing else
**Why:** Status codes, headers, JSON shapes, auth extraction and request parsing change when the API changes. Business rules change when the business changes. Mixed in one handler, a test needs a fake HTTP request to check a business rule.
**How to apply:** A handler validates input (Zod / `PathValue` + decode / Pydantic), calls one service method, maps the result or the domain error to a response. It holds no `if` about business state. One place maps domain errors to statuses and RFC 9457 `application/problem+json` (`onError` in Hono, `fail()` in Go, exception handlers in FastAPI).
**Anti-example:** A handler that queries two tables and decides whether the user may cancel an order.
**When to deviate:** A one-line pass-through (`/healthz`) needs no service.

## Rule: Service holds use cases and has no HTTP types
**Why:** A use case you cannot call from a queue consumer, a CLI or a test without building an HTTP request is welded to one transport. Importing the framework's request type into the service is how that weld starts.
**How to apply:** Service functions take plain parsed values and return plain values or throw/return a domain error (`AppError` with a numeric `status`, `ErrNoteNotFound`, `NotFoundError`). The service imports no Hono, `net/http` or FastAPI. It depends on a repository interface it defines itself (Go `NoteStore`, Python `Protocol`, TS interface) so a test passes a fake.
**Anti-example:** `service.get(c: Context)`; a service that returns `Response`.
**When to deviate:** A service that is only CRUD over one table can be thin. Keep the layer: the next rule arrives later, and moving code across layers later costs more than an empty layer now.

## Rule: Repository is the only layer that writes SQL
**Why:** SQL spread through services makes the schema impossible to change safely and transactions impossible to reason about. One layer means one place to grep for a table, add an index or swap the driver.
**How to apply:** Repositories receive the connection or session (Python `AsyncSession`, Go `pgxpool.Pool` or `sqlc` `Queries`, TS Drizzle `db`) from the composition root. They return domain types, never ORM rows or driver types. Transactions: the service decides the unit of work; the repository accepts a transaction handle.
**When to deviate:** Reporting queries that join across five aggregates can live in a `queries/` module next to the repositories. Still SQL in one layer.

## Rule: `config` is read once in `main`
**Why:** See [config.md](config.md). A module that reads the environment itself cannot be tested without mutating process state.
**How to apply:** `main` loads config, builds the platform seams, builds repositories, services and the transport, and starts the server. Layers receive values by argument or constructor.

## Rule: `platform` seams own the I/O vendors
**Why:** Each seam is a single swap point and a single test double. The logger, the database pool, the tracer and the clock are the four every service has.
**How to apply:**

| Seam | Owns | Faked in tests by |
|---|---|---|
| `db` | pool/engine creation, ping for readiness, session or tx helper | a container Postgres (not a mock) |
| `logger` | JSON shape and redaction per [logging-contract.md](../../core/_shared/logging-contract.md) | a silent or buffer logger |
| `tracer` | OTel SDK bootstrap per [observability.md](../../core/_shared/observability.md) | the no-op tracer |
| `clock` | `now()` | a fixed clock |

Add a seam when a second vendor call appears or a test needs to fake it, not before. The scaffolds ship `logger` and `clock` (TS), `logging` (Go, Python) and `db` (Python, only if `DATABASE_URL` is set).

## Rule: Composition root, no globals
**Why:** A global logger or pool makes every test share state and hides the dependency graph. A composition root shows it in one screen.
**How to apply:** `createApp(deps)` (TS), `httpapi.New(Deps{...})` (Go), `create_app(settings)` (Python) take their dependencies as arguments. Tests build the app with fakes. The linter enforces it where it can (`sloglint` `no-global: all` in Go).

## Findability table

| I look for … | TypeScript (Hono) | Go | Python (FastAPI) |
|---|---|---|---|
| Process entry, wiring, shutdown | `src/main.ts` | `cmd/<svc>/main.go` | `src/<pkg>/main.py`, `app.py` (`create_app`, lifespan) |
| Validated env | `src/config.ts` | `internal/config/config.go` | `src/<pkg>/config.py` |
| Route table | `src/transport/*.routes.ts`, mounted in `src/app.ts` | `internal/transport/httpapi/server.go` (`Handler()`) | `src/<pkg>/transport/*.py` routers, included in `app.py` |
| Request schema and validation | the route's Zod schema (`createRoute`) | decode + check in the handler | Pydantic models and `Path`/`Query` types |
| Error to HTTP mapping (problem+json) | `onError` in `src/app.ts`; `AppError` in `src/platform/problem.ts` | `fail` and `writeProblem` in `internal/transport/httpapi/` | `src/<pkg>/transport/errors.py`; `AppError` in `platform/problem.py` |
| Use case / business rule | `src/service/*.service.ts` | `internal/service/*.go` | `src/<pkg>/service/*.py` |
| SQL / table access | `src/repository/*.repository.ts` | `internal/repository/*.go` (sqlc output under `internal/repository/db/`) | `src/<pkg>/repository/*.py` |
| DB pool / session | `src/platform/db.ts` | `internal/platform/db/` | `src/<pkg>/platform/db.py` (`get_session`) |
| Logger | `src/platform/logger.ts` | `internal/platform/logging/logging.go` | `src/<pkg>/platform/logging.py` |
| Health and readiness | `src/transport/health.routes.ts` | `internal/transport/httpapi/server.go` (`live`, `ready`) | `src/<pkg>/transport/health.py` |
| OpenAPI document | generated: `GET /openapi.json`, `pnpm openapi` | not generated by the scaffold; add `oapi-codegen` or hand-write `openapi.yaml` | generated: `GET /openapi.json` |
| Tests | `tests/` (or colocated `*.test.ts` per profile) | `*_test.go` beside the code; integration tests in `tests/` | `tests/` |
| Migrations | `drizzle/` (Drizzle skill) | `migrations/` (sqlc/goose skill) | `alembic/` (Alembic skill) |

**Why this table exists:** a reader who knows one service finds the same thing in the others in one step, and an agent can navigate any backend repo without a search.

## Rule: Names say the layer
**Why:** `notes.service.ts`, `notes.go` in `internal/service/` and `service/notes.py` tell the reader the layer before opening the file. Folder-by-layer over folder-by-feature at this size: a service with under ~10 use cases reads faster when all repositories sit in one place.
**How to apply:** Layer folders first. Past ~10 use cases, group by feature *inside* each layer (`service/billing/…`), or split the service. Do not mix both at the top level.
**When to deviate:** A modular monolith with real feature teams: top-level `modules/<feature>/{transport,service,repository}` with the same inner names. The table above then applies per module.

## Rule: Go keeps tests beside the code
**Why:** `go test` runs per package, and unexported helpers are testable only from the same package. The profile's `tests-dir` layout is honored for integration and end-to-end tests (`tests/`), not for unit tests in Go.
**How to apply:** `*_test.go` in the package folder; black-box tests use the `_test` package suffix, as the scaffold does.

## When to deviate

- A tiny service (one endpoint, one table): collapse `service` into `transport` only if the logic is a single repository call. Keep the repository.
- A transport that is not HTTP (a queue consumer, a gRPC server): `transport/` holds that adapter; the service and repository stay the same.
- A framework that fixes its own layout (Next.js route handlers, Supabase Edge Functions): the layers become folders under that layout; the dependency direction still holds.
