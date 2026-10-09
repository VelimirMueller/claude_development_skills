# FastAPI Service Patterns

Reference for [scaffold-fastapi-service](SKILL.md). Each rule was checked against the scaffold in [fastapi-files.md](fastapi-files.md) on 2026-10-09 (Python 3.14, FastAPI 0.143, Pydantic 2.14, SQLAlchemy 2.1, mypy 2.4, ruff 0.16).

## Rule: `uv` project with `src/` layout
**Why:** One tool resolves, locks, installs and runs (`uv sync`, `uv run`). The `src/` layout means tests import the installed package, not the working directory, so a missing `__init__.py` or a bad import fails locally and not only in production.
**How to apply:** `uv init --package` writes `src/<pkg>/` and `uv_build`. Commit `uv.lock`; CI runs `uv sync --locked`. Dev tools sit in the `dev` dependency group (`uv add --dev`). Runtime pin in `.python-version` and `requires-python`.
**Anti-example:** `requirements.txt` plus `pip install -r` in the Dockerfile: no lock, no dev group, and a different resolver than local.
**Gotcha:** `uv init` writes `readme = "README.md"`. If you delete the README, delete that line, or `uv run` fails building the project.
**When to deviate:** A repo on Poetry or pip-tools stays on it; do not switch tools inside a scaffold task.

## Rule: `create_app(settings)` factory plus a lifespan, no import-time side effects
**Why:** Module-level `app = FastAPI()` with a global engine runs I/O on import and forces tests to patch globals. A factory takes `Settings` and builds the app; the lifespan opens resources on startup and closes them on shutdown.
**How to apply:** `app.py` defines `create_app(settings)`. `main.py` is the only module that builds the real app (`create_app(get_settings())`), so importing `svc.main` fails fast on bad config and nothing else triggers it. Resources live on `app.state` and are created in the `lifespan` context manager; the `finally` block closes them. Tests call `create_app(Settings(_env_file=None, ...))` and enter `app.router.lifespan_context(app)`.
**Anti-example:** `@app.on_event("startup")`: deprecated in favor of lifespan.
**When to deviate:** None. The factory costs five lines.

## Rule: `pydantic-settings` for config; secrets typed `SecretStr`
**Why:** See [config.md](../_shared/config.md). `BaseSettings` reads the environment and `.env`, coerces and validates, and raises one `ValidationError` listing every bad key. `frozen=True` makes the object read-only.
**How to apply:** Required values have no default (`database_url: PostgresDsn`). `extra="ignore"` lets other tools share `.env`. `get_settings()` is `lru_cache`d for dependency use. The port is not a setting: `fastapi run --port` and `uvicorn --port` own it.
**When to deviate:** Several services share many settings: put the common base class in a shared package.

## Rule: Layers as packages: `transport`, `service`, `repository`, `platform`
**Why:** See [service-layout.md](../_shared/service-layout.md). In FastAPI the temptation is to put SQL and rules in the path function because `Depends` makes it easy. That welds the rule to HTTP.
**How to apply:** A path function declares typed inputs, calls one service method, returns a response model. The service raises `AppError` subclasses with a numeric status and imports no FastAPI or Starlette type. It depends on a `Protocol` it defines (`NotesStore`), so tests pass a fake. The repository takes an `AsyncSession` and returns dataclasses, never ORM rows. Name the package `platform`: a folder named `platform` inside a package does not shadow the stdlib module, because imports are absolute (`svc.platform`).
**When to deviate:** A route that only reads one table through a query function may skip the service; keep the repository.

## Rule: RFC 9457 problem+json from exception handlers
**Why:** One error shape for clients and logs. FastAPI's default `{"detail": …}` differs between validation errors and `HTTPException`.
**How to apply:** `install_error_handlers(app)` registers handlers for `AppError`, `RequestValidationError` (400 with an `errors` list), Starlette's `HTTPException` (so unknown routes and 405s are problems too) and `Exception` (log once, return a 500 with a fixed body). Responses use `media_type="application/problem+json"`. Declare the problem model in `responses=` so it appears in OpenAPI. Do not return `str(exc)` of unknown exceptions.
**Gotcha:** FastAPI returns 422 for validation errors by default; this scaffold maps them to 400 to match the other backends. If clients expect 422, change one constant in `errors.py`.
**When to deviate:** A public API with a published error envelope: map to it in `errors.py`, keep `AppError` inside.

## Rule: One driver: psycopg 3
**Why:** SQLAlchemy and the procrastinate job queue ([set-up-background-jobs](../set-up-background-jobs/SKILL.md)) then share one driver, so a job can be deferred inside the request's transaction — the queue row is the outbox and commits or rolls back with the business write. One driver also means one set of connection settings: one dependency line, one URL scheme, one pool tuning. With two drivers the job needs a second connection and can survive a rolled-back request; the outbox guarantee is gone.
**How to apply:** Install `psycopg[binary,pool]` (the `pool` extra pools procrastinate's worker connections). The SQLAlchemy URL scheme is `postgresql+psycopg://`; `create_engine` in `platform/db.py` sets it with `make_url(url).set(drivername=...)`, so a plain `postgresql://` URL works in settings, tests and CI. Driver errors are `psycopg.errors.*` (`UniqueViolation`), never `asyncpg.exceptions.*`. The same driver serves the sync migration pass and the async engine.
**Anti-example:** `postgresql+asyncpg://` for the app plus psycopg for the worker: two connection settings to tune, and a deferred job that commits on a second connection after the request rolled back.
**When to deviate:** asyncpg only for a service with no job queue that measured a driver-level bottleneck — a deliberate swap of `platform/db.py`, documented in the repo.

## Rule: Async SQLAlchemy: one engine per process, one session per request
**Why:** An engine owns the pool and is expensive; a session is a unit of work and is cheap. A session shared across requests leaks state and transactions.
**How to apply:** `create_engine` (psycopg 3 driver, `pool_pre_ping=True`) and `create_sessionmaker` (`expire_on_commit=False`, so returned objects stay readable after commit) run in the lifespan when `DATABASE_URL` is set. `get_session` is a dependency that yields a session inside `async with`. Dispose the engine in the lifespan `finally`. Readiness pings with `SELECT 1`.
**Anti-example:** A module-level `engine = create_async_engine(os.environ["DATABASE_URL"])`.
**When to deviate:** Sync SQLAlchemy with `def` routes is fine for a small internal tool; FastAPI runs those in a thread pool. Do not mix blocking calls into `async def` routes.

## Rule: Liveness and readiness are separate
**Why:** A load balancer that restarts a process because the database is slow turns a blip into an outage.
**How to apply:** `/healthz` returns 200 and checks nothing. `/readyz` awaits every check in `app.state.readiness_checks` and returns 503 if one raises.
**Shutdown:** On SIGTERM, uvicorn stops accepting connections, waits for in-flight requests (bounded by `--timeout-graceful-shutdown`), then runs the lifespan shutdown. An ASGI app cannot return 503 from `/readyz` after the listener has closed, so a pre-stop delay belongs to the orchestrator (a Kubernetes `preStop` sleep), not to the app.

## Rule: Log with structlog in the contract shape
**Why:** One JSON shape across TypeScript, Go and Python ([logging-contract.md](../../core/_shared/logging-contract.md)). The processors rename the keys to `timestamp` and `message`, and `bind_contextvars` adds `service.name` and `deployment.environment.name` to every line.
**How to apply:** `configure_logging(level, service, env)` in the lifespan; `get_logger(__name__)` at module level in code that logs. Log at the boundary that handles the error, once. Use OTel field names for HTTP (`url.path`).
**Gap:** Uvicorn's own startup lines and the access log are plain text. Pass `--no-access-log` in production (the OTel HTTP instrumentation records requests), and accept the few lifecycle lines, or supply a `--log-config` that routes `uvicorn` loggers through structlog's `ProcessorFormatter`.
**When to deviate:** A repo on stdlib `logging` only: use a JSON formatter with the same field names; do not run two loggers.

## Rule: ruff for lint and format, mypy strict for types
**Why:** `ruff` replaces flake8, isort, pyupgrade and black in one fast tool. The rule set `E F I B UP S ASYNC SIM RUF` covers errors, imports, bugbear, modern syntax, security (`S`), async mistakes and simplifications. `mypy --strict` with the Pydantic plugin checks the models and the services for real; `ty` is still beta (`0.0.x`, "currently in beta" in its docs), so it is not the only gate yet.
**How to apply:** Tool tables in `pyproject.toml`. `S101` (assert) is allowed in `tests/`. Pin `ruff` with `~=`; it is pre-1.0 and adds rules in minors. Type every function; `Annotated[..., Depends(...)]` for dependencies, which also keeps ruff's `B008` quiet.
**When to deviate:** A large untyped legacy codebase: start mypy with `strict = false` on the new package only.

## Rule: Test in-process with httpx; real Postgres for the repository
**Why:** `AsyncClient(transport=ASGITransport(app=app))` runs routing, validation and error handlers with no port. With `asyncio_mode = "auto"` async tests and fixtures need no decorator. Repository tests against a mock prove nothing about SQL.
**How to apply:** `tests/` at the repo root. Unit tests use in-memory repositories through `create_app`. Integration tests use `testcontainers` (`PostgresContainer`) and a real session. `httpx` stays a dev dependency.
**When to deviate:** `tests.layout: colocated` in the profile: ask before moving; the Python convention is `tests/`.

## When to deviate

- Needs background jobs: add a worker process with its own entry in `transport/` (a queue consumer); the service layer is reused.
- Needs auth: add a dependency that resolves the actor and passes it into the service; do not read headers in services ([security-baseline.md](../../core/_shared/security-baseline.md)).
- Needs migrations: add Alembic with an async `env.py`; keep model definitions next to the repositories.
- Many workers on one VM: `uvicorn --workers N` only there. In containers, run one process per container and scale replicas.
