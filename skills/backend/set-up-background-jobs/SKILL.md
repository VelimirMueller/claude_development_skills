---
name: set-up-background-jobs
description: Use when a backend must do work outside the request (email, webhooks, imports, schedules) or publish events reliably — adds a Postgres-backed queue (pg-boss, River, procrastinate), the transactional outbox, idempotent handlers, retries with dead letter, cron jobs.
---

# Set Up Background Jobs

Rules and rationale: [jobs-patterns.md](jobs-patterns.md). Code per track and migrations: [jobs-track-patterns.md](jobs-track-patterns.md). Database seam and transactions: [set-up-database](../set-up-database/SKILL.md). Layer paths: [service-layout.md](../_shared/service-layout.md). Versions: [stack-versions.md](../_shared/stack-versions.md).

Default: a queue that lives in the Postgres you already run. A job is inserted in the same transaction as the write that causes it, so both exist or neither does.

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null     # backend.track, database.{engine,orm,host}, observability, hosting
ls src/platform/queue.ts internal/transport/jobs src/*/transport/jobs.py src/worker.ts cmd/*/worker* 2>/dev/null
grep -rnE "\"(bullmq|bull|agenda|pg-boss|graphile-worker|bee-queue)\"" package.json 2>/dev/null
grep -nE "riverqueue|asynq|machinery" go.mod 2>/dev/null
grep -nE "celery|rq|arq|dramatiq|procrastinate|taskiq" pyproject.toml requirements*.txt 2>/dev/null
grep -rnE "setTimeout\(|setInterval\(|time\.AfterFunc|asyncio\.create_task|BackgroundTasks|go func\(" src internal 2>/dev/null | head   # work done after the response, unrecorded
grep -rniE "redis|sqs|nats|rabbit|kafka" compose.yaml docker-compose.yml .env.example 2>/dev/null | head
```

Record: fire-and-forget work in a handler (lost on restart), cron implemented in an OS crontab or `setInterval`, an existing broker and who runs it, writes followed by a publish in the same function (dual write).

## 2. Decide

- No queue, no outbox: full setup (steps 3 to 7).
- A Postgres-backed queue exists: add only the missing parts (retry config, dead letter, idempotency, retention, outbox).
- Redis or a broker exists and is already operated by the team: keep it for existing flows; use the outbox so new events leave Postgres reliably; do not add a second queue system without a reason.
- `backend.track: supabase` with no own server: `pgmq` and `pg_cron` extensions or Edge Function triggers apply; see [set-up-supabase](../set-up-supabase/SKILL.md). Next.js on serverless hosting cannot run a long-lived worker: use the host's cron plus a separate worker service.
- Everything present and step 7 passes: report "already in place" and stop.

Graduate beyond Postgres only on the triggers in [jobs-patterns.md](jobs-patterns.md), section "When to leave Postgres".

## 3. Detect track

| `backend.track` | Queue | Why this one |
|---|---|---|
| `hono` | `pg-boss` | Typed, dead-letter queues, backoff, tz-aware cron, Drizzle adapter; 80 releases in 12 months, latest 2026-10-08. `graphile-worker` (0.x, 5 releases) is the alternative when jobs are enqueued from SQL triggers |
| `go` | `River` | Go-native, `InsertTx` with `pgx`, unique jobs, periodic jobs, typed args; v0.49 active |
| `fastapi` | `procrastinate` | Async, psycopg 3, can enlist in the request's transaction, periodic tasks; 3.10 active. `pgqueuer` 1.5 is the younger alternative |

All three need a **direct** Postgres connection for workers (no transaction-mode pooler): they use `LISTEN/NOTIFY` and locks that a pooler drops.

## 4. Install only what is missing

```bash
pnpm add pg-boss @opentelemetry/api               # hono: pg-boss imports @opentelemetry/api at runtime (peer)
go get github.com/riverqueue/river github.com/riverqueue/river/riverdriver/riverpgxv5   # go: v0.49 needs Go 1.26+
uv add procrastinate                               # fastapi (psycopg[binary,pool] is already installed: scaffold and set-up-database ship it)
```

If the package manager skips peers (npm `--legacy-peer-deps`), install `@opentelemetry/api` by hand: without it `import 'pg-boss'` throws `ERR_MODULE_NOT_FOUND`.

## 5. Generate the seams

1. Queue seam, one file owns the vendor: TS `src/platform/queue.ts`, Go `internal/transport/jobs/`, Python `src/<pkg>/platform/queue.py`. A typed registry of job names and payloads lives there, nowhere else.
2. Consumer (a non-HTTP transport): TS `src/transport/jobs/*.ts`, Go `internal/transport/jobs/jobs.go`, Python `src/<pkg>/transport/jobs.py`. A handler parses the payload, calls one service method, returns or throws. No business rule inside.
3. Producers call the seam with the open transaction handle (`enqueue(tx, ...)`, `InsertTx`, `configure(connection=...)`). Code per track in [jobs-track-patterns.md](jobs-track-patterns.md).
4. Outbox, only for events that leave the service (broker, webhook, another system): `outbox` table, relay job, `Publisher` interface. A job for this service's own work needs no outbox: the queue row is the outbox.
5. Queue settings, one place: retry limit and backoff, expiry, dead-letter queue, retention. Defaults and why: [jobs-patterns.md](jobs-patterns.md).
6. Schedules: declared in code next to the queue config, with an explicit time zone (`UTC` unless a business rule says otherwise).
7. Schema install belongs to the migration step ([migration-patterns.md](../set-up-database/migration-patterns.md)), not to app startup: `pg-boss migrate` (set `migrate: false` at runtime), River SQL dumped into goose with `river migrate-get`, procrastinate schema inside an Alembic revision.

## 6. Wire

- Worker is a separate entry point of the same image (`node dist/worker.mjs`, `cmd/<svc>/worker`, `procrastinate worker`), scaled and deployed apart from the API. A tiny service may run the worker in the API process; then give the pool enough connections for both.
- Graceful shutdown: on SIGTERM stop fetching, wait for running jobs up to a timeout shorter than the platform's kill timeout, then exit.
- Config via [config.md](../_shared/config.md): `DATABASE_URL` (direct URL for the worker), concurrency, timeouts. Runtime role grants: [jobs-track-patterns.md](jobs-track-patterns.md).
- Observability: log job name, id, attempt and outcome with the trace id ([logging-contract.md](../../core/_shared/logging-contract.md)); alert on dead-letter growth and on the oldest ready job's age ([observability.md](../../core/_shared/observability.md)).
- Cleanup: retention for finished jobs and a scheduled purge of the idempotency table.

## 7. Verify

```bash
# 1. atomicity: enqueue inside a transaction that rolls back -> no job
# 2. retries: a handler that throws runs again, with growing delay; after the limit the job is in the dead-letter state
# 3. idempotency: run one job twice on purpose -> one external effect
# 4. schedule: next run is listed in the queue's schedule table with the right time zone
```

Per track the exact commands are in [jobs-track-patterns.md](jobs-track-patterns.md), section "Verify". Pass criteria: a rolled-back enqueue leaves zero jobs; a failing handler ends in the dead-letter state (`dead-letter` queue, `discarded`, `failed`); the second run of the same job id changes nothing; `SELECT` on the queue table shows the schedule.

## References
- [jobs-patterns.md](jobs-patterns.md): why Postgres first, outbox, idempotency, retries, schedules, retention, graduation.
- [jobs-track-patterns.md](jobs-track-patterns.md): pg-boss, River, procrastinate code and install steps.
- [../design-http-api/api-contract-patterns.md](../design-http-api/api-contract-patterns.md): idempotency keys on the HTTP side.
