# Jobs Patterns

Reference for `set-up-background-jobs`. Behavior claims marked "verified" were run on Postgres 18.6 with `pg-boss` 12.37.1, River 0.49.0 and `procrastinate` 3.10.0 on 2026-10-09. Principles: [boring technology](../../core/_shared/engineering-principles.md), [one seam per vendor](../../core/_shared/engineering-principles.md).

## Rule: A Postgres-backed queue before a broker
**Why:** The failure that matters in job systems is the dual write: update the database, then publish to the queue, and the process dies between the two. With the queue in the same database, enqueueing is one more `INSERT` in the business transaction, so the job exists if and only if the write committed. A broker cannot join your transaction. Beyond atomicity:
- One system fewer to run, upgrade, secure, back up, restore and monitor. The database already has all five.
- Inspect and repair with SQL: requeue, cancel, count by state, find the oldest job.
- `SELECT ... FOR UPDATE SKIP LOCKED` lets many workers claim distinct rows without blocking each other; this is what pg-boss, River and procrastinate use. It carries ordinary workloads (email, webhooks, imports, report generation) comfortably.
- Local development and tests need only the Postgres you already start.
**Costs, stated so the choice is honest:** queue tables churn (insert, update, delete), which stresses autovacuum; jobs share capacity and connections with the application; no fan-out to many independent consumers; no replayable log. The triggers for leaving are below.
**How to apply:** pg-boss (TypeScript), River (Go), procrastinate (Python). Track table and reasons: [SKILL.md](SKILL.md).
**Anti-example:** Adding Redis only to run a queue for a service that already has Postgres and sends a few thousand emails a day.

## Rule: The enqueue joins the business transaction
**Why:** See above. Verified on all three: a job enqueued with the transaction handle and then rolled back never runs; the committed one does.
**How to apply:** the queue seam accepts the transaction handle and refuses to enqueue without one inside a unit of work:

| Track | Enqueue in the transaction |
|---|---|
| TS | `boss.send(name, data, { db: fromDrizzle(tx, sql) })` through `queue.enqueue(tx, ...)` |
| Go | `client.InsertTx(ctx, tx, Args{...}, nil)` |
| Python | `task.configure(connection=raw_psycopg_connection).defer_async(...)`, the connection taken from the session |

Code in [jobs-track-patterns.md](jobs-track-patterns.md). Enqueue after the business write, inside the same `transaction(...)`, so a failing write skips the enqueue and a failing enqueue rolls back the write.
**Anti-example:** `await db.insert(order); await queue.send(...)` in two separate steps, or `setTimeout(sendEmail, 0)` after the response.

## Rule: Use an outbox table only when the event leaves the service
**Why:** A queue row *is* an outbox for work this service performs itself. A separate `outbox` table earns its place when the consumer is outside the transaction boundary: a message broker, a webhook endpoint, another service. There the relay must publish at least once and mark the row after, because no transaction spans Postgres and the broker. Adding the table for in-process jobs duplicates the queue.
**How to apply:**
1. Business transaction writes the state change and an `outbox` row (`topic`, `payload`, stable `id`).
2. A relay job claims unpublished rows with `FOR UPDATE SKIP LOCKED`, publishes each, sets `published_at`, commits (code in [jobs-track-patterns.md](jobs-track-patterns.md), all three verified).
3. A crash after publishing and before commit republishes the row. Delivery is at least once; **receivers dedupe on the event `id`**.
4. Index for the claim query: `CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL`.
5. Delete published rows after a retention window with a scheduled job.
Ordering: parallel relays do not preserve global order. Per-aggregate order needs one relay instance, or a partition key and one relay per partition.
**Why polling and not `LISTEN/NOTIFY` alone:** notifications are lost when no one listens. Poll on an interval; add `NOTIFY` only to cut latency.

## Rule: Handlers are idempotent; the queue delivers at least once
**Why:** Every queue, Postgres or broker, can run a job twice: a worker dies after the side effect and before the completion, or a job outlives its expiry and is retried. "Exactly once" exists only inside one database transaction. Everything that touches the outside world has to tolerate repeats.
**How to apply:** pick the strongest tool that fits, in this order:
1. **Make the write naturally idempotent:** `INSERT ... ON CONFLICT DO NOTHING`, `UPDATE ... WHERE status = 'pending'`, set-to-value instead of increment.
2. **Pass the job id as the idempotency key** to the external call (payment provider, email API). The job id is the same on every retry (verified in all three), so the provider collapses repeats.
3. **Record the effect and the dedupe key in one transaction:** `INSERT INTO processed (job_id) ... ON CONFLICT DO NOTHING`; if zero rows inserted, return. pg-boss also offers `transactional: true` workers: the handler's writes (through the `tx` it receives) commit with the job's completion (verified), which gives exactly-once for database effects.
4. **Check state first:** load the order, return if already `emailed`. Fine for single-worker flows; races without a lock.
Handlers receive IDs, not copies of data: load current state inside the handler so a stale payload cannot overwrite newer data. Keep payloads small and JSON-only; never put secrets in them (they sit in a table and in logs).
**Anti-example:** A handler that increments a counter and sends an email, with no key. A retry doubles both.

## Rule: Retry with exponential backoff and jitter, then dead-letter; classify the error
**Why:** An immediate retry hits the same outage; fixed delays make every failed job retry together and overload the recovering dependency. A job that fails forever must stop and be visible, not loop.
**How to apply:**

| Setting | Default to use | pg-boss (verified) | River | procrastinate |
|---|---|---|---|---|
| Attempts | 6 to 8 | `retryLimit: 6` (retries after the first run) | `MaxAttempts: 8` (total runs; library default 25) | custom `BaseRetryStrategy` (built-in `RetryStrategy(max_attempts=N)` runs **N+1 times**, verified) |
| Backoff | exponential, capped at 1 h | `retryDelay: 10, retryBackoff: true, retryDelayMax: 3600` (jitter built in) | `NextRetry` on the worker; default policy is exponential | `BackoffWithJitter` in [jobs-track-patterns.md](jobs-track-patterns.md) (the built-in has no jitter and no cap) |
| Timeout | longer than the slowest normal run | `expireInSeconds: 300` | `Config.JobTimeout` (**default 1 minute**: set it) | none per job; use `asyncio.timeout` in the task |
| Dead letter | a place to look | `deadLetter: 'dead-letter'` queue (create it first) | state `discarded`, kept 7 days (`DiscardedJobRetentionPeriod`) | status `failed`, kept until you delete it |

- Retry transient errors only (network, 5xx, 429 with `Retry-After`). Validation errors and 4xx will never succeed: stop retrying at once. pg-boss: `perJobResults: true` and return `{ id, status: 'deadletter' }` (verified: lands in the dead-letter queue with no retries). River: return `river.JobCancel(err)`. procrastinate: return `None` from `get_retry_decision` for that exception type.
- Dead letters are an alert, not a graveyard: alert when the count grows, review weekly, redrive after the fix (`boss.redrive(queue)` in pg-boss; `client.JobRetry(ctx, id)` in River; `queue.job_manager.retry_job_by_id_async(id, schedule_at)` in procrastinate).
**Anti-example:** `retryLimit: 1000, retryDelay: 0`.

## Rule: Schedules are declared in code, in UTC, and tolerate being skipped or doubled
**Why:** A cron job in an OS crontab runs on every replica or on none. A queue-native schedule is claimed by one instance and recorded in the database. A deploy or outage can skip an occurrence; two instances can race at the boundary.
**How to apply:**
- pg-boss: `boss.schedule(queue, '0 6 * * *', null, { tz: 'UTC' })`; the queue must exist first (verified: `Queue nosuchq not found`). `missed: 'skip'` (default) or `'once'` decides what happens to occurrences missed while down.
- River: `PeriodicJobs` in `Config`: `river.PeriodicInterval(d)`, or a cron expression through `cron.ParseStandard("0 6 * * *")` from `github.com/robfig/cron/v3` (compiles as a `river.PeriodicSchedule`); one elected leader enqueues them.
- procrastinate: `@app.periodic(cron="0 6 * * *")` on a task with `queueing_lock="<name>"` so a backed-up queue holds at most one waiting instance; the task takes a `timestamp` argument.
- The scheduled job body must be idempotent and derive its window from the scheduled time, not from "now" minus a day.
- Use a business time zone only when the rule is a business rule ("08:00 Berlin"); then DST makes one day 23 or 25 hours long: test it.

## Rule: Finished jobs have a retention policy
**Why:** Queue tables are write-heavy. Completed rows left forever bloat the table and slow claim queries; deleting them too early removes your evidence.
**How to apply:** completed: 1 to 7 days; failed or dead-letter: 7 to 30 days, alerted on before expiry.
- pg-boss: `deleteAfterSeconds` (default 7 days), `retentionSeconds` for never-started jobs (default 14 days).
- River: `CompletedJobRetentionPeriod` (default 24 h), `DiscardedJobRetentionPeriod` (7 days).
- procrastinate keeps finished jobs **forever** by default: schedule the built-in `remove_old_jobs` task (verified: `add_tasks_from(builtin_tasks.builtin, namespace="builtin")` plus a periodic wrapper with `max_hours=168`), or start the worker with `--delete-jobs=successful`.
- Idempotency-key and outbox tables: scheduled purge, 24 hours and 7 days.

## Rule: Workers use a direct connection and their own role
**Why:** Workers hold `LISTEN` sessions and advisory locks; a transaction-mode pooler drops both. A separate role limits what a bug in a handler can touch.
**How to apply:** worker `DATABASE_URL` points at Postgres (or the pooler's session mode). The runtime role needs DML on the queue schema only; schema installation uses the migration role ([migration-patterns.md](../set-up-database/migration-patterns.md)). Grants verified for pg-boss: `USAGE` on schema `pgboss`, `SELECT, INSERT, UPDATE, DELETE` on its tables, `USAGE` on its sequences, `EXECUTE` on its functions; with `migrate: false` and `createSchema: false` the worker started, created a queue and sent a job.

## Rule: Keep the queue's schema out of the ORM's migrations, and the ORM out of the queue's
**Why:** Verified: Alembic autogenerate emitted `drop_table` for every `procrastinate_*` table. Drizzle's `generate` ignores tables not in its schema file; `drizzle-kit push` does not. River's tables live in `public` beside yours.
**How to apply:** filter foreign tables in Alembic (`include_object`, see [migration-patterns.md](../set-up-database/migration-patterns.md)); give the queue its own schema where the library allows (`pg-boss` uses `pgboss`; pg-boss `schema` option); never `push` against a database that holds queue tables.

## When to leave Postgres

Move to NATS JetStream, SQS or Kafka when one of these is true, measured and not feared:
1. **Fan-out:** several independent services consume the same event. A queue row serves one consumer group; copying rows per consumer reimplements a broker.
2. **Cross-service messaging without a shared database:** services must not read each other's tables.
3. **Replay or stream semantics:** consumers need retained history, offsets, reprocessing (Kafka, JetStream).
4. **Database health:** queue churn shows in the database: autovacuum cannot keep up (pg-boss emits `xmin_horizon` and `index_bloat` warnings), claim queries slow down, or the queue's share of IOPS or connections hurts the application. First fix: partition the busy queue (pg-boss `partition: true`), shorten retention, raise autovacuum. Then leave.
5. **Throughput beyond one database's headroom** for jobs alone. Measure jobs per second against your instance; do not decide from a blog post.
6. **Managed convenience wins:** the platform already offers SQS and the team has no Postgres on-call; operations cost, not features, drives the choice.

The outbox makes this a swap, not a rewrite: the relay's `Publisher` publishes to the broker instead of calling a webhook; producers do not change. Keep handlers idempotent and keyed by event `id` and consumers survive the move.

## When to deviate

- Sub-second latency or very high job rates for in-memory work (cache warming, fan-out inside one process): an in-process worker pool is simpler. Anything that must survive a restart still goes through the queue.
- A team that already runs and understands Redis or RabbitMQ in production: keep it for what it does; adopt the outbox for new events.
- Serverless platforms with their own queue (SQS plus Lambda, Cloud Tasks, Vercel Queues): use it, still behind the same queue seam and with the same idempotency rules.
- Workflows with long-running state, human steps or compensation (days, many steps): a workflow engine (Temporal, Inngest) fits better than a job queue. Not evaluated here.
