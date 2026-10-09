# FastAPI Service: File Contents

Canonical contents for [SKILL.md](SKILL.md). Every file here ran clean on 2026-10-09 (`ruff format`, `ruff check`, `mypy` strict, `pytest`, `fastapi run` with a live `curl` and SIGTERM) on Python 3.14 and the lines in [stack-versions.md](../_shared/stack-versions.md). Replace the package name `svc`. Also create empty `__init__.py` in `platform/`, `repository/`, `service/` and `transport/`. The `notes` module is a worked example of the layering: delete it once a real module exists.

## `pyproject.toml`

```toml
[project]
name = "svc"
version = "0.1.0"
description = "svc"
requires-python = ">=3.14"
dependencies = [
    "asyncpg>=0.32.0",
    "fastapi[standard]>=0.143.0",
    "pydantic-settings>=2.15.0",
    "sqlalchemy[asyncio]>=2.1.4",
    "structlog>=26.1.0",
]

[build-system]
requires = ["uv_build>=0.11.30,<0.12.0"]
build-backend = "uv_build"

[dependency-groups]
dev = [
    "httpx>=0.28.1",
    "mypy>=2.4.0",
    "pytest>=9.1.1",
    "pytest-asyncio>=1.4.0",
    "ruff>=0.16.10",
]

[tool.fastapi]
entrypoint = "svc.main:app"

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"
asyncio_default_fixture_loop_scope = "function"

[tool.ruff]
line-length = 100
target-version = "py314"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "S", "ASYNC", "SIM", "RUF"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101"]

[tool.mypy]
strict = true
plugins = ["pydantic.mypy"]
python_version = "3.14"
files = ["src", "tests"]
```

## `.env.example`

```bash
DEPLOYMENT_ENVIRONMENT=development
OTEL_SERVICE_NAME=svc
LOG_LEVEL=INFO
# DATABASE_URL=postgresql://user:password@localhost:5432/app
```

## `src/svc/config.py`

```python
from functools import lru_cache
from typing import Literal

from pydantic import PostgresDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Validated environment. Instantiation fails fast with every invalid key."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore", frozen=True)

    deployment_environment: Literal["development", "staging", "production"] = "development"
    otel_service_name: str = "svc"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    # Optional until a repository needs it; make it required (no default) when it does.
    database_url: PostgresDsn | None = None
    # Secrets: type them SecretStr so logs and tracebacks never print them.


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

## `src/svc/platform/logging.py`

```python
import logging

import structlog


def configure_logging(level: str, service: str, environment: str) -> None:
    """Log shape follows core/_shared/logging-contract.md: JSON lines to stdout."""
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True, key="timestamp"),
            structlog.processors.format_exc_info,
            structlog.processors.EventRenamer("message"),
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.getLevelNamesMapping()[level]),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
    structlog.contextvars.clear_contextvars()
    structlog.contextvars.bind_contextvars(
        **{"service.name": service, "deployment.environment.name": environment}
    )


def get_logger(name: str) -> structlog.typing.FilteringBoundLogger:
    logger: structlog.typing.FilteringBoundLogger = structlog.get_logger(name)
    return logger
```

## `src/svc/platform/db.py`

```python
from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)


def create_engine(database_url: str) -> AsyncEngine:
    # asyncpg driver; pool_pre_ping drops dead connections after a database restart.
    url = database_url.replace("postgresql://", "postgresql+asyncpg://", 1)
    return create_async_engine(url, pool_pre_ping=True)


def create_sessionmaker(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)


async def ping(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    """One session per request. Repositories receive it; services never see it."""
    sessionmaker: async_sessionmaker[AsyncSession] | None = request.app.state.sessionmaker
    if sessionmaker is None:
        raise RuntimeError("DATABASE_URL is not configured")
    async with sessionmaker() as session:
        yield session
```

## `src/svc/platform/problem.py`

```python
from pydantic import BaseModel, ConfigDict

PROBLEM_CONTENT_TYPE = "application/problem+json"


class Problem(BaseModel):
    """RFC 9457 problem details."""

    model_config = ConfigDict(extra="allow")

    type: str = "about:blank"
    title: str
    status: int
    detail: str | None = None
    instance: str | None = None


class AppError(Exception):
    """Domain error raised by services. Carries a status number, no HTTP framework types."""

    def __init__(self, status: int, title: str, detail: str | None = None) -> None:
        super().__init__(detail or title)
        self.status = status
        self.title = title
        self.detail = detail


class NotFoundError(AppError):
    def __init__(self, detail: str) -> None:
        super().__init__(404, "Not Found", detail)
```

## `src/svc/repository/notes.py`

```python
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Note:
    id: str
    body: str


class InMemoryNotesRepository:
    """Stand-in. Replace with a SQLAlchemy-backed class taking an AsyncSession."""

    def __init__(self, seed: list[Note] | None = None) -> None:
        self._rows = {n.id: n for n in seed or []}

    async def find_by_id(self, note_id: str) -> Note | None:
        return self._rows.get(note_id)
```

## `src/svc/service/notes.py`

```python
from typing import Protocol

from svc.platform.problem import NotFoundError
from svc.repository.notes import Note


class NotesStore(Protocol):
    async def find_by_id(self, note_id: str) -> Note | None: ...


class NotesService:
    """Use cases. Imports no FastAPI or Starlette types."""

    def __init__(self, store: NotesStore) -> None:
        self._store = store

    async def get(self, note_id: str) -> Note:
        note = await self._store.find_by_id(note_id)
        if note is None:
            raise NotFoundError(f"Note {note_id} does not exist")
        return note
```

## `src/svc/transport/schemas.py`

```python
from pydantic import BaseModel


class NoteOut(BaseModel):
    id: str
    body: str


class StatusOut(BaseModel):
    status: str
```

## `src/svc/transport/health.py`

```python
from collections.abc import Awaitable, Callable

from fastapi import APIRouter, Request, Response, status

from svc.transport.schemas import StatusOut

router = APIRouter(tags=["ops"])

ReadinessCheck = Callable[[], Awaitable[None]]


@router.get("/healthz", response_model=StatusOut)
async def live() -> StatusOut:
    """Liveness: never touches dependencies."""
    return StatusOut(status="ok")


@router.get("/readyz", response_model=StatusOut, responses={503: {"model": StatusOut}})
async def ready(request: Request, response: Response) -> StatusOut:
    """Readiness: fails when a dependency is down."""
    checks: list[ReadinessCheck] = request.app.state.readiness_checks
    for check in checks:
        try:
            await check()
        except Exception:
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return StatusOut(status="unavailable")
    return StatusOut(status="ok")
```

## `src/svc/transport/notes.py`

```python
from typing import Annotated

from fastapi import APIRouter, Depends, Path, Request

from svc.platform.problem import Problem
from svc.service.notes import NotesService
from svc.transport.schemas import NoteOut

router = APIRouter(tags=["notes"])


def get_notes_service(request: Request) -> NotesService:
    service: NotesService = request.app.state.notes_service
    return service


@router.get(
    "/notes/{note_id}",
    response_model=NoteOut,
    responses={404: {"model": Problem}},
)
async def get_note(
    note_id: Annotated[str, Path(min_length=1)],
    service: Annotated[NotesService, Depends(get_notes_service)],
) -> NoteOut:
    note = await service.get(note_id)
    return NoteOut(id=note.id, body=note.body)
```

## `src/svc/transport/errors.py`

```python
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.status import HTTP_400_BAD_REQUEST, HTTP_500_INTERNAL_SERVER_ERROR

from svc.platform.logging import get_logger
from svc.platform.problem import PROBLEM_CONTENT_TYPE, AppError, Problem

log = get_logger(__name__)


def _problem(
    request: Request,
    status: int,
    title: str,
    detail: str | None = None,
    headers: dict[str, str] | None = None,
    **extra: object,
) -> JSONResponse:
    body = Problem(title=title, status=status, detail=detail, instance=request.url.path, **extra)
    return JSONResponse(
        body.model_dump(exclude_none=True),
        status_code=status,
        media_type=PROBLEM_CONTENT_TYPE,
        headers=headers,
    )


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(request: Request, exc: AppError) -> JSONResponse:
        return _problem(request, exc.status, exc.title, exc.detail)

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        errors = [
            {"path": ".".join(str(p) for p in e["loc"]), "message": e["msg"]} for e in exc.errors()
        ]
        return _problem(
            request, HTTP_400_BAD_REQUEST, "Bad Request", "Request validation failed", errors=errors
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        return _problem(request, exc.status_code, str(exc.detail), headers=exc.headers)

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        log.error("unhandled error", exc_info=exc, **{"url.path": request.url.path})
        return _problem(request, HTTP_500_INTERNAL_SERVER_ERROR, "Internal Server Error")
```

## `src/svc/app.py`

```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from functools import partial

from fastapi import FastAPI

from svc.config import Settings
from svc.platform.db import create_engine, create_sessionmaker, ping
from svc.platform.logging import configure_logging, get_logger
from svc.repository.notes import InMemoryNotesRepository, Note
from svc.service.notes import NotesService
from svc.transport import health, notes
from svc.transport.errors import install_error_handlers


def problem_json_media_type(schema: dict) -> dict:
    """`model=` error responses are documented as application/json; ours are problem+json."""
    for path in schema["paths"].values():
        for op in path.values():
            if not isinstance(op, dict) or "responses" not in op:
                continue  # path-level "parameters"/"summary", not an operation
            for status, resp in op["responses"].items():
                content = resp.get("content", {})
                if status.isdigit() and int(status) >= 400 and "application/json" in content:
                    content["application/problem+json"] = content.pop("application/json")
    return schema


def install_openapi(app: FastAPI) -> None:
    def custom_openapi() -> dict:
        if app.openapi_schema is None:
            app.openapi_schema = problem_json_media_type(FastAPI.openapi(app))
        return app.openapi_schema

    app.openapi = custom_openapi  # type: ignore[method-assign]


def create_app(settings: Settings) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        configure_logging(
            settings.log_level, settings.otel_service_name, settings.deployment_environment
        )
        app.state.sessionmaker = None
        app.state.readiness_checks = []
        log = get_logger(__name__)
        log.info("starting", database=settings.database_url is not None)
        engine = None
        if settings.database_url is not None:
            engine = create_engine(str(settings.database_url))
            app.state.sessionmaker = create_sessionmaker(engine)
            app.state.readiness_checks.append(partial(ping, engine))
        app.state.notes_service = NotesService(InMemoryNotesRepository([Note("1", "hello")]))
        try:
            yield
        finally:
            # Uvicorn has stopped accepting connections and drained in-flight requests by now.
            log.info("stopping")
            if engine is not None:
                await engine.dispose()

    app = FastAPI(title="svc", version="0.1.0", lifespan=lifespan)
    install_error_handlers(app)
    install_openapi(app)
    app.include_router(health.router)
    app.include_router(notes.router)
    return app
```

## `src/svc/main.py`

```python
"""ASGI entrypoint: `fastapi run` and `uvicorn svc.main:app` import `app` from here."""

from svc.app import create_app
from svc.config import get_settings

app = create_app(get_settings())
```

## `tests/test_app.py`

```python
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from svc.app import create_app
from svc.config import Settings


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    app = create_app(Settings(_env_file=None))
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c,
    ):
        yield c


async def test_liveness(client: AsyncClient) -> None:
    assert (await client.get("/healthz")).status_code == 200


async def test_readiness_ok_without_dependencies(client: AsyncClient) -> None:
    assert (await client.get("/readyz")).status_code == 200


async def test_missing_note_is_problem_json(client: AsyncClient) -> None:
    res = await client.get("/notes/nope")
    assert res.status_code == 404
    assert res.headers["content-type"].startswith("application/problem+json")
    assert res.json()["title"] == "Not Found"


async def test_get_note(client: AsyncClient) -> None:
    assert (await client.get("/notes/1")).json() == {"id": "1", "body": "hello"}


async def test_unknown_route_is_problem_json(client: AsyncClient) -> None:
    res = await client.get("/nope")
    assert res.status_code == 404
    assert res.headers["content-type"].startswith("application/problem+json")


async def test_disallowed_method_reports_allow_header(client: AsyncClient) -> None:
    res = await client.post("/healthz")
    assert res.status_code == 405
    assert res.headers["content-type"].startswith("application/problem+json")
    assert "allow" in res.headers
```
