---
name: scaffold-fastapi-service
description: Use when starting a Python HTTP API or adding a service to a repo with no FastAPI app yet — scaffolds a uv src-layout FastAPI service with lifespan, pydantic-settings, ruff, mypy, pytest, health/readiness, problem+json errors and an async SQLAlchemy session dependency.
---

# Scaffold FastAPI Service

Rationale and rules: [fastapi-patterns.md](fastapi-patterns.md). Full file contents: [fastapi-files.md](fastapi-files.md). Shared standards: [service-layout.md](../_shared/service-layout.md), [config.md](../_shared/config.md), [stack-versions.md](../_shared/stack-versions.md).

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null   # backend.track, database.orm, tests.layout, task_runner, observability
ls pyproject.toml uv.lock .python-version ruff.toml src tests alembic.ini 2>/dev/null
grep -E 'fastapi|flask|django|litestar|sqlalchemy|pydantic' pyproject.toml requirements*.txt 2>/dev/null
uv --version; python3 --version
```

Read the profile first; detect only what it leaves open ([stack-profile.md](../../core/_shared/stack-profile.md)).
- `backend.track` is set and is not `fastapi`: stop and name the track the profile says; suggest the matching scaffold skill.
- `backend.track` is unset and `flask`, `django` or `litestar` is in the dependencies: ask one question ("add FastAPI next to it, or extend it?"). Otherwise do not ask.
- `requirements.txt` without `pyproject.toml`: the repo does not use uv. Say so and ask once before introducing it; `package_manager: uv` in the profile answers the question.

## 2. Decide

- No `pyproject.toml`: full scaffold (steps 3 to 7).
- `pyproject.toml` present, no FastAPI app: add the dependencies and the package folders; keep the existing `[project]` table, merge the tool tables by hand.
- All present and step 7 passes: report "already in place" and stop.

## 3. Detect track

| Question | Source | Default |
|---|---|---|
| Package name | folder name, snake_case | `svc` in the files becomes this name |
| Python line | `requires-python`, `.python-version` | 3.14 ([stack-versions.md](../_shared/stack-versions.md)) |
| Database | `database.orm` | `sqlalchemy`: keep `platform/db.py`, make `DATABASE_URL` required, add Alembic via the Alembic skill of this catalogue. `none`: delete `platform/db.py` and the `sessionmaker` lines in `app.py` |
| Type checker | repo config, else profile `lint_format` | `mypy` strict. `ty` is beta: add it as a second CI step only if asked |
| Tests | `tests.layout` | `tests/` always for Python; `colocated` is unusual here: ask before changing `testpaths` |
| Observability | `observability.otel` | `true`: add OTel bootstrap in `platform/` before `configure_logging` ([observability.md](../../core/_shared/observability.md)) |
| Task runner | `task_runner` | `just`: recipes `dev`, `test`, `lint`, `typecheck` calling the commands in step 7 |

## 4. Install only what is missing

```bash
uv init --package --python 3.14 --name <pkg> .        # only when pyproject.toml is missing
uv add "fastapi[standard]" pydantic-settings structlog "sqlalchemy[asyncio]" "psycopg[binary,pool]"
uv add --dev ruff mypy pytest pytest-asyncio httpx
```

`--package` gives the `src/` layout and the `uv_build` backend. Delete the generated `README.md` reference from `pyproject.toml` if you do not keep one: the build fails on a missing readme. Check each line against [stack-versions.md](../_shared/stack-versions.md). Commit `uv.lock`.

## 5. Generate the seams

Create the files from [fastapi-files.md](fastapi-files.md), skipping any that exist; merge the tool tables into `pyproject.toml`.

```
src/<pkg>/config.py                     pydantic-settings, fails fast on import of main
src/<pkg>/platform/{logging,db,problem}.py
src/<pkg>/repository/*.py               the only layer with SQL
src/<pkg>/service/*.py                  use cases, no FastAPI types
src/<pkg>/transport/{health,notes,errors,schemas}.py
src/<pkg>/app.py                        create_app(settings), lifespan
src/<pkg>/main.py                       `app = create_app(get_settings())`
tests/test_app.py                       httpx ASGITransport, in-process
pyproject.toml tool tables              fastapi, pytest, ruff, mypy
.env.example  .gitignore                .env ignored
```

Add an empty `__init__.py` to `platform/`, `repository/`, `service/`, `transport/`. Rename `notes` to the first real module.

## 6. Wire

- `[tool.fastapi] entrypoint = "svc.main:app"` lets `fastapi dev` and `fastapi run` find the app.
- Development: `uv run fastapi dev` (reload on, binds localhost). Production: `uv run uvicorn <pkg>.main:app --host 0.0.0.0 --port "${PORT:-8000}" --timeout-graceful-shutdown 10 --no-access-log`, or `fastapi run --port "${PORT:-8000}"`. Uvicorn stops accepting on SIGTERM, drains, then runs the lifespan shutdown. `--workers` only on a bare VM; in containers scale replicas.
- Readiness: append one coroutine to `app.state.readiness_checks` per dependency in the lifespan (`partial(ping, engine)`).
- Sessions: repositories take an `AsyncSession` from `Depends(get_session)`; the service never sees it. Needs a database: set `DATABASE_URL` in `.env`.
- `.python-version` and `requires-python` stay in step with `mise.toml` when the profile uses mise.
- CI, Docker and deploy are out of scope; the `devcore` and `infraskills` plugins own them (CI: `uv sync --locked`).

## 7. Verify

```bash
uv sync --locked                       # expect: no changes
uv run ruff format --check . && uv run ruff check .   # expect: "All checks passed!"
uv run mypy                            # expect: "Success: no issues found"
uv run pytest -q                       # expect: 6 passed
uv run fastapi run --port 8087 &       # expect a JSON "starting" line, then uvicorn "Application startup complete"
curl -si localhost:8087/notes/nope     # expect 404 and content-type: application/problem+json
curl -s localhost:8087/readyz          # expect {"status":"ok"}
curl -s localhost:8087/openapi.json | head -c 60   # expect {"openapi":"3.1.0",...
LOG_LEVEL=LOUD uv run python -c "import svc.main"  # expect a ValidationError naming log_level
kill -TERM %1                          # expect "stopping" in the log, exit code 0
```

A second run of this skill finds everything in place and changes nothing.

## References

- [fastapi-patterns.md](fastapi-patterns.md): why each choice, when to deviate.
- [fastapi-files.md](fastapi-files.md): the files.
- [service-layout.md](../_shared/service-layout.md), [config.md](../_shared/config.md).
- [logging-contract.md](../../core/_shared/logging-contract.md), [security-baseline.md](../../core/_shared/security-baseline.md).
