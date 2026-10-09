# Backend Test Patterns

Reference for [configure-backend-tests](SKILL.md). Implements "Tests at the boundary that pays" from [engineering-principles.md](../../core/_shared/engineering-principles.md); layout terms from [service-layout.md](../_shared/service-layout.md). The code: [test-tracks.md](test-tracks.md). The behaviour under test comes from [set-up-backend-auth](../set-up-backend-auth/SKILL.md).

## Rule: Build the pyramid
**Why:** The cheap bugs live in pure logic (policies, calculations, mapping) and the expensive ones in SQL and HTTP wiring. Everything-as-end-to-end is slow, flaky and debugs far from the cause; everything-mocked verifies assumptions, not behaviour.
**How to apply:** Many pure unit tests of service logic and policies — no I/O, no container, milliseconds each. Fewer integration tests against real Postgres through the repository and HTTP layers. A few contract and fuzz checks. No browser-level tests here; the frontend [configure-test-stack](../../frontend/configure-test-stack/SKILL.md) owns those. Proportions are guidance, not quotas — let the bug history decide where the next test goes.
**Anti-example:** 200 tests that each build the whole app over a mocked database; a missing tenant filter in one query passes all of them.

## Rule: Real Postgres via testcontainers, never a mock of the DB
**Why:** A mock verifies your assumption about the SQL, not the SQL. Tenant filters, constraints, casts and `id::text` comparisons behave differently in Postgres than in a hand-written row set — that is the exact class of bug these tests exist to catch.
**How to apply:** One container per test run — started in vitest `globalSetup`, Go `TestMain`, a pytest session fixture — image `postgres:18`. Migrated once with the real migrations, never with a hand-written schema. Tables truncated before each test (`TRUNCATE ... RESTART IDENTITY CASCADE` over `pg_tables`), so tests are independent and can run in any order. Do not share state across tests; do not rely on order.
**Anti-example:** `DATA-DOG/go-sqlmock` expectations that spell out the query string; a tenant-isolation test that passes against a fake repository and leaks rows in production.

## Rule: HTTP tests exercise the real app, without a socket
**Why:** Routing, middleware, auth extraction and error-to-status mapping are what callers experience; a handler invoked directly skips all of it. A real port adds conflicts and slow teardown and catches nothing more.
**How to apply:** Hono `app.request(path, init)`; Go `httptest.NewServer(handler)` or `ServeHTTP` into a recorder; FastAPI `httpx.ASGITransport` inside `app.router.lifespan_context(app)` so lifespan code runs. This works because the composition root (`createApp(deps)`, `httpapi.New(Deps{...})`, `create_app(settings)`) takes dependencies as arguments — tests build the real app with real parts ([service-layout.md](../_shared/service-layout.md)).
**Anti-example:** `curl` against a separately started server on a fixed port; a handler function called with a fabricated context object.

## Rule: Fake only what you own or cannot run
**Why:** A fake of code you do not own encodes your guesses about it and breaks on its release schedule. Everything you can run for real, run for real.
**How to apply:** Fake the clock (fixed `now()`), the logger (silent), the IdP key source — sign real tokens with a throwaway key so the verification code runs unchanged, only the key source differs — and route outbound HTTP through a local in-process server. Never fake the repository in integration tests.
**Anti-example:** an in-memory `DocumentsRepository` used to "test" tenant isolation; decoding tokens with signature verification disabled so the production verify path never runs.

## Rule: Names say method - condition - outcome
**Why:** The failing name is the first line of the bug report and often the only line a reviewer reads. `test_3` sends the reader into the code to learn nothing.
**How to apply:** `it('GET - own tenant document - 200 with the document')` (TS); the same words as Go subtest names (`"GET - own tenant document - 200"`); Python spells it `test_get_document__own_tenant__200_with_document`, because function names cannot hold spaces.

## Rule: The layout honours the profile
**Why:** `tests-dir` vs `colocated` is a team decision recorded in the profile; a skill that overrides it makes every later diff fight the convention.
**How to apply:** Default `tests/{unit,integration,support}`. Go keeps unit tests beside the code (`*_test.go`) and integration plus HTTP tests in `tests/` — `go test` runs per package and unexported helpers need the same package ([service-layout.md](../_shared/service-layout.md)). `tests.layout: colocated` moves TS unit tests to `src/**/*.test.ts` (change the unit project's `include`); integration stays in `tests/integration`, because it needs the container setup.

## Rule: Factories build valid rows; tests override one field
**Why:** A shared fixtures file full of rows couples every test to every other: one new `NOT NULL` column breaks the seed, and each test reads past the rows it cares about.
**How to apply:** `insertDocument(db, { tenantId: 't-2' })` — valid by default, override only what the test is about. No shared fixtures files full of rows.
**Anti-example:** a `conftest.py` that seeds users, tenants and documents for the whole suite; deleting one row in a test fails three others.

## Rule: Security tests are first-class
**Why:** Broken access control is the top OWASP Top 10:2025 category; tenant isolation and token checks are behaviour with production consequences, not decoration.
**How to apply:** Per resource: tenant A cannot read tenant B — expect 404, not 403, so IDs cannot be probed. 401 for no token, wrong audience or an expired token; 403 for a missing scope; one route-protection test over the public list. The rules under test: [auth-patterns.md](../set-up-backend-auth/auth-patterns.md).
**Anti-example:** a "security" suite that only exercises the happy path; the one repository method without the tenant filter ships.

## Rule: Contract tests pin the API surface
**Why:** Consumers code against the published spec. A route edit that silently changes the OpenAPI document breaks them without failing any behaviour test — and hand-written examples miss inputs a fuzzer finds.
**How to apply:** Two checks: a spec-drift snapshot (generate the document, diff against the committed copy at `contracts/openapi.json`, fail on difference) and schemathesis conformance against an ephemeral service in CI. The fuzzer earned its keep on its first run here: a 405 response without an `Allow` header — a real bug, found only by the fuzzer.

## Rule: CI runs are deterministic and fast to fail
**Why:** Sleeps and shared state are the two roots of flaky pipelines; both come from guessing how long an asynchronous thing takes.
**How to apply:** No sleeps — wait on conditions. Deterministic data from factories. Unit tests first and fail fast; integration in the same job after them (Docker is present on the runner). Caching image pulls is the runner's job, not the workflow's. Timeouts stay explicit — vitest `hookTimeout: 60_000` covers the container start. JUnit reports and coverage are optional and not specified here.
**Anti-example:** `time.Sleep(2 * time.Second)` before the first query "so Postgres is up"; a pipeline that is red one run in five for no code change.

## Rule: Know what not to test
**Why:** Every test costs writing, runtime and upkeep. Tests of code you do not own break on its release schedule and never catch your bugs.
**How to apply:** Skip framework behaviour (Hono routing, FastAPI validation basics), getters and DTO mapping with no logic, private helpers called directly, the ORM itself, third-party library internals, exact log lines, whole-response snapshots that change on every field addition. Treat coverage numbers as a gauge, not a goal.
**Anti-example:** a test asserting the exact text of a validation message; a snapshot of a full API response that fails on every harmless field addition.

## When to deviate

- No Docker on a dev machine: start a Postgres with the profile's task runner and point the suite at it through `DATABASE_URL_TEST`; keep the same truncate strategy so local and CI behave the same.
- Very large suites: one container per run stops paying. Use a template database per worker — create and migrate once, clone per worker.
- CI without Docker: embedded Postgres runs in-process and needs no runtime, but it differs from production Postgres. Say so in the PR, and keep a container-based job somewhere in the pipeline.
