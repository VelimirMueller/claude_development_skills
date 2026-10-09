---
name: configure-backend-tests
description: Use when a backend service needs a test setup or its tests mock the database. Builds the pyramid - pure unit tests, real-Postgres integration via testcontainers, HTTP-level tests, OpenAPI contract tests, factories and CI-ready layout (Vitest, go test, pytest).
---

# Configure Backend Tests

Rules and rationale: [test-patterns.md](test-patterns.md). Code per track: [test-tracks.md](test-tracks.md). Layout follows the tests rows of [service-layout.md](../_shared/service-layout.md). The principle behind it all: "Tests at the boundary that pays" in [engineering-principles.md](../../core/_shared/engineering-principles.md).

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null   # backend.track, tests.layout (tests-dir|colocated), database.engine
ls tests tests/unit tests/integration vitest.config.ts pyproject.toml 2>/dev/null
grep -rnE "vi\.mock\('pg|jest\.mock|sqlsmock|DATA-DOG/go-sqlmock" --include=*.ts --include=*.go . 2>/dev/null | grep -v node_modules
grep -rnE "unittest\.mock" --include=*.py . 2>/dev/null | grep -iE "patch.*(session|engine|pool)"
grep -rnE "sleep\(" --include=*.ts --include=*.go --include=*.py tests src internal 2>/dev/null   # sleep-based waits
docker info >/dev/null 2>&1 && echo "docker: ok" || echo "docker: missing"
```

- The DB-mock grep (`vi.mock('pg`, `jest.mock`, `sqlsmock`, `DATA-DOG/go-sqlmock`, `unittest.mock` patching a session) is the main finding: those tests verify an assumption about the SQL, not the SQL. They move to real-Postgres integration tests.
- Sleep-based waits are the second finding: they are the flake source in CI.
- `docker info` failing means the container runtime is absent: the integration suites cannot run on this machine. Install everything; verify unit tests only, and say so.
- The support modules assume `database.engine: postgres` (`TRUNCATE` over `pg_tables`, the testcontainers Postgres module). Another engine means adapting the reset, not the pattern.

## 2. Decide

- No test config and no `tests/`: full setup, steps 3 to 7.
- Tests exist but mock the database or sleep: delta. Add the support modules from [test-tracks.md](test-tracks.md), move the DB-touching tests into the integration project or suite, replace sleeps with condition waits. Keep sound unit tests where they are.
- Vitest `projects` (unit, integration), Go `TestMain` with a container and the pytest `integration` marker all present, no DB mocks, step 7 green: report "already in place" and stop.

## 3. Detect track and layout

| `backend.track` | Test stack |
|---|---|
| `hono` | Vitest 5 `projects`: `unit`, `integration` |
| `go` | `go test`: unit tests beside the code (`*_test.go`), integration and HTTP tests in `tests/` |
| `fastapi` | pytest with `tests/unit`, `tests/integration`, marker `integration` |
| `nextjs` | Stop. Use [build-nextjs-backend](../build-nextjs-backend/SKILL.md). |
| `supabase` | Stop. Use [secure-supabase-rls](../secure-supabase-rls/SKILL.md); its test side is [rls-test-patterns.md](../secure-supabase-rls/rls-test-patterns.md). |
| `none` or unset | Run `set-up-stack-profile`, then a `scaffold-*-service` skill. |

`tests.layout` decides where unit tests live: `tests-dir` (default) -> `tests/{unit,integration,support}`; `colocated` -> TS unit tests in `src/**/*.test.ts` (change the unit project's `include`), integration stays in `tests/integration`. Go keeps unit tests beside the code whatever the profile says ([service-layout.md](../_shared/service-layout.md)). The worked example is the `documents` module of [set-up-backend-auth](../set-up-backend-auth/SKILL.md); rename it or delete it once a real module uses the shape.

## 4. Install only what is missing

```bash
pnpm add -D vitest @testcontainers/postgresql   # hono; add @types/pg too when the app uses pg
go get github.com/testcontainers/testcontainers-go/modules/postgres github.com/go-jose/go-jose/v4   # go: container + test-token signing
uv add --dev testcontainers "psycopg[binary]"     # fastapi: plain testcontainers, no [postgres] extra
```

Python imports the container from `testcontainers.community.postgres` (`testcontainers.postgres` is deprecated). `psycopg` is the one driver: the container URL (`postgresql+psycopg://`) drives the migration pass and the app engine unchanged — no URL rewriting between them. Use the profile's package manager. Versions: [stack-versions.md](../_shared/stack-versions.md).

## 5. Generate

Create from [test-tracks.md](test-tracks.md), skipping files that exist:

```
tests/support/      container start, db reset, IdP tokens, app builder, factories
config              vitest projects / pytest markers (Go needs none: TestMain)
first unit test     a policy or pure service function
first integration   one resource through HTTP against real Postgres
```

The container is migrated with the repo's real migrations — [set-up-database](../set-up-database/SKILL.md) owns them; the worked example ships its own `drizzle/0000_init.sql` / `migrations/0001_init.sql`.

Scripts — unit tests are the fast loop, integration joins on demand or in CI:

- TS `package.json`: `"test": "vitest run"`, `"test:unit": "vitest run --project unit"`, `"test:integration": "vitest run --project integration"`.
- Go: `go test ./internal/...` for the fast loop; `go test ./...` for all of it, `tests/` included.
- Python: `uv run pytest -m "not integration"` for units; `uv run pytest` for everything.

## 6. Wire into CI and contract checks

One job per track: unit tests first (fail fast), then integration in the same job — the `ubuntu-latest` runners have Docker, and testcontainers starts its own Postgres, so no service container is needed. The workflow with SHA-pinned actions is in [test-tracks.md](test-tracks.md) ("CI job").

Contract tests, two kinds:

1. **Spec drift.** Generate the OpenAPI document and compare with the committed copy at `contracts/openapi.json`; fail the step when they differ. TS: `pnpm openapi` (via `scripts/print-openapi.ts`), then `diff openapi.json contracts/openapi.json`. Python: dump `app.openapi()`. Go: `openapi.yaml` is hand-written or the oapi-codegen source, so drift is a regenerate-and-diff. The Hono scaffold git-ignores `openapi.json`; that is why the committed copy uses the `contracts/` name.
2. **Conformance.** Run schemathesis against the running app:

```bash
schemathesis run http://localhost:PORT/openapi.json --checks all -n 25 --exclude-path '/documents/{doc_id}'
```

Verified on the FastAPI scaffold: 55 generated, 55 passed — but only after the first run found a real bug (a 405 without an `Allow` header). Protected endpoints: add `-H "Authorization: Bearer $TOKEN"`. In CI, start the app in the background and pass `--wait-for-schema 30`.

## 7. Verify

```bash
pnpm test       # hono
go test ./...   # go
uv run pytest   # fastapi
```

Expected: all green. The worked example: 3 unit files + 1 integration file (TS), and 6 integration cases per track — own tenant 200, other tenant 404, missing scope 403, no token 401, wrong audience 401, malformed id 400; the Go and Python files add an expired-token 401 case. The first integration run pulls the `postgres:18` image and is slower; with the image cached, the full suite took 15-16 s locally. A second run of this skill changes nothing.

## References

- [test-patterns.md](test-patterns.md): the pyramid, real Postgres over mocks, HTTP-level tests, fakes, naming, CI rules, what not to test.
- [test-tracks.md](test-tracks.md): every file for Vitest, go test and pytest, plus the CI job.
- [auth-patterns.md](../set-up-backend-auth/auth-patterns.md): the policies and tenant scoping these tests prove.
- [configure-test-stack](../../frontend/configure-test-stack/SKILL.md): the frontend side; browser-level tests live there.
