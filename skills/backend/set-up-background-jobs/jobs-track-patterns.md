# Jobs Track Patterns

Reference for `set-up-background-jobs`. One section per track: install, seam, producer, consumer, outbox relay, schema install, verify. All code compiled or ran against Postgres 18.6 on 2026-10-09. Rules and reasons: [jobs-patterns.md](jobs-patterns.md).

## TypeScript: pg-boss 12 with Drizzle

**Why pg-boss over graphile-worker:** pg-boss has queues as first-class objects (per-queue retry, backoff, expiry, dead-letter queue, policies), a Drizzle adapter that puts `send` in your transaction, `transactional` workers, tz-aware cron with a `missed` policy, and a release cadence of about 80 stable releases in the last 12 months (latest 12.37.1, 2026-10-08, Node 22.12+, Postgres 13+). `graphile-worker` 0.18 (5 releases in 12 months, Node 22.18+) is solid and has one advantage: `graphile_worker.add_job()` is a SQL function, so a database trigger can enqueue. Both have a single maintainer: pin the version, read the changelog on upgrade. Choose graphile-worker when enqueue-from-SQL matters.

Install: `pnpm add pg-boss @opentelemetry/api`. `@opentelemetry/api` is a peer that pg-boss imports at runtime; with `--legacy-peer-deps` it is skipped and `import 'pg-boss'` fails.

Seam, `src/platform/queue.ts` (the only file that imports `pg-boss`):

```ts
import { sql } from 'drizzle-orm';
import { fromDrizzle, PgBoss, type Job, type ScheduleOptions } from 'pg-boss';
import type { Executor } from './db.ts';

/** Every job the service knows: name -> payload. The only place a job name is spelled. */
export interface JobMap {
  'email.send': { orderId: string };
  'outbox.relay': Record<string, never>;
}
export type JobName = keyof JobMap;

const DEAD_LETTER = 'dead-letter';

export interface Queue {
  /** Inside a unit of work pass the `tx`: the job exists only if the transaction commits. */
  enqueue<N extends JobName>(x: Executor, name: N, data: JobMap[N], opts?: { key?: string; startAfterSeconds?: number }): Promise<string | null>;
  work<N extends JobName>(name: N, handler: (job: Job<JobMap[N]>) => Promise<void>): Promise<void>;
  schedule(name: JobName, cron: string, opts?: ScheduleOptions): Promise<void>;
  start(): Promise<void>;
  stop(): Promise<void>;
}

export function createQueue(opts: { databaseUrl: string; onError: (err: Error) => void }): Queue {
  const boss = new PgBoss({
    connectionString: opts.databaseUrl, // direct connection, not a transaction-mode pooler
    migrate: false, // the schema is installed by `pg-boss migrate` in the deploy step
    createSchema: false,
  });
  boss.on('error', opts.onError);

  return {
    enqueue: (x, name, data, o) =>
      boss.send(name, data, {
        db: fromDrizzle(x as Parameters<typeof fromDrizzle>[0], sql),
        singletonKey: o?.key, // dedupe only on a stately/singleton queue, see the pitfall below
        startAfter: o?.startAfterSeconds,
      }),
    work: async (name, handler) => {
      await boss.work<JobMap[typeof name]>(name, async ([job]) => {
        if (job) await handler(job); // throw to retry; return to complete
      });
    },
    schedule: (name, cron, o) => boss.schedule(name, cron, null, { tz: 'UTC', ...o }),
    start: async () => {
      await boss.start();
      await boss.createQueue(DEAD_LETTER);
      for (const name of ['email.send', 'outbox.relay'] satisfies JobName[]) {
        await boss.createQueue(name, {
          policy: 'standard',
          retryLimit: 6,
          retryDelay: 10,
          retryBackoff: true,
          retryDelayMax: 3600,
          expireInSeconds: 300, // a handler running longer than this is presumed dead and retried
          deadLetter: DEAD_LETTER,
        });
      }
    },
    stop: () => boss.stop({ graceful: true, timeout: 30_000 }),
  };
}
```

Verified: `start()` twice is safe (`createQueue` is idempotent); a job enqueued in a rolled-back `database.transaction` is never delivered; the committed one reaches the handler; `getQueue('email.send')` returns `retryLimit: 6` and `deadLetter: 'dead-letter'`.

Producer, in the service's unit of work:

```ts
await deps.database.transaction(async (tx) => {
  const order = await deps.orders.insert(tx);
  await deps.queue.enqueue(tx, 'email.send', { orderId: order.id });
  return order;
});
```

Consumer, `src/transport/jobs/handlers.ts`: one `queue.work` call per job, each calling a service:

```ts
export async function registerJobHandlers(queue: Queue, deps: { notifications: NotificationsService; relay: { run(): Promise<number> } }) {
  await queue.work('email.send', (job) => deps.notifications.sendOrderConfirmation(job.data.orderId, job.id)); // job.id = idempotency key
  await queue.work('outbox.relay', async () => void (await deps.relay.run()));
  await queue.schedule('outbox.relay', '* * * * *'); // every minute; the table is drained in batches
}
```

Pitfalls (verified):
- **`singletonKey` alone does not dedupe on a `standard` queue:** two `send`s with the same key created two jobs. It dedupes on a `stately` or `singleton` policy queue (second `send` returns `null`) or with `singletonSeconds`. For "enqueue once per business key", pass an explicit `id` (a UUID derived from the key, for example UUIDv5 of `order-confirmation:<orderId>`): a second `send` with the same `id` returns `null`.
- **`schedule()` needs the queue to exist:** `Queue nosuchq not found`. Create queues first (`start()` above), then schedule.
- **Permanent errors:** a thrown error retries. For a job that can never succeed, use `{ perJobResults: true }` and return `{ id, status: 'deadletter' }`; it goes straight to the dead-letter queue without retries.
- **Effects that must commit with the job:** `work(name, { transactional: true }, async (jobs, tx) => { await tx.executeSql('insert ...', [...]) })`: the writes commit with the completion.

Outbox relay: `src/service/outbox-relay.ts` (table `outbox` in `src/repository/schema.ts`: `id` identity, `topic`, `payload` jsonb, `createdAt`, `publishedAt`):

```ts
import { asc, inArray, isNull, sql } from 'drizzle-orm';
import type { Database } from '../platform/db.ts';
import { outbox } from '../repository/schema.ts';

export interface Publisher {
  /** `id` is stable: receivers dedupe on it, because delivery is at least once. */
  publish(event: { id: number; topic: string; payload: unknown }): Promise<void>;
}

export function createOutboxRelay(deps: { database: Pick<Database, 'transaction'>; publisher: Publisher; batchSize?: number }) {
  return {
    run: () =>
      deps.database.transaction(async (tx) => {
        const rows = await tx
          .select()
          .from(outbox)
          .where(isNull(outbox.publishedAt))
          .orderBy(asc(outbox.id))
          .limit(deps.batchSize ?? 100)
          .for('update', { skipLocked: true }); // two relays never take the same row
        for (const row of rows) {
          await deps.publisher.publish({ id: row.id, topic: row.topic, payload: row.payload });
        }
        if (rows.length > 0) {
          await tx.update(outbox).set({ publishedAt: sql`now()` }).where(inArray(outbox.id, rows.map((r) => r.id)));
        }
        return rows.length;
      }),
  };
}
```

Verified: two events published once each; a second run returns 0.

Schema install: `PGBOSS_DATABASE_URL=<migration-role url> pnpm exec pg-boss migrate` as the `db:migrate:pre` step (the CLI also has `version`, `doctor`, `plans --dry-run`, `rollback`). It creates schema `pgboss` (version 45 on 12.37.1). Runtime role grants:

```sql
GRANT USAGE ON SCHEMA pgboss TO app_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgboss TO app_runtime;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA pgboss TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgboss TO app_runtime;
```

Worker entry, `src/worker.ts`: build config, database, queue, services; `queue.start()`; `registerJobHandlers`; on SIGTERM `await queue.stop()` then `database.close()`.

Verify:

```bash
# atomicity + delivery + retry config: run a script like the one in this section against compose Postgres
psql "$DATABASE_URL" -c "select name, state, retry_count from pgboss.job order by created_on desc limit 5"
psql "$DATABASE_URL" -c "select name, cron, timezone from pgboss.schedule"      # expect your schedule, tz UTC
```

(`pgboss.job` and `pgboss.schedule` are the 12.x tables; run `\dt pgboss.*` first if a later major renames them.)

## Go: River

**Why River:** Go-native generics (`river.Job[Args]`), `InsertTx` with `pgx.Tx`, unique jobs, periodic jobs with leader election, `JobCancel` and `JobSnooze`, a CLI and a separate UI project; v0.49.0 released 2026-10-05, requires Go 1.26+. Pre-1.0: pin the version and read the changelog on upgrade. `asynq` needs Redis; skip it when Postgres is already there.

Install: `go get github.com/riverqueue/river github.com/riverqueue/river/riverdriver/riverpgxv5`.

Consumer and seam, `internal/transport/jobs/jobs.go`. Producers insert through `client.InsertTx`; the service sees only a small interface it defines itself:

```go
// Package jobs is the queue consumer: it turns jobs into service calls. No business rule lives here.
package jobs

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
)

type Mailer interface {
	SendOrderConfirmation(ctx context.Context, orderID int64, idempotencyKey string) error
}

type OutboxRelay interface {
	Run(ctx context.Context, batch int32) (int, error)
}

type SendEmailArgs struct {
	OrderID int64 `json:"order_id"`
}

func (SendEmailArgs) Kind() string { return "email.send" }

func (SendEmailArgs) InsertOpts() river.InsertOpts {
	return river.InsertOpts{
		MaxAttempts: 8,
		UniqueOpts:  river.UniqueOpts{ByArgs: true}, // one confirmation per order, however often it is enqueued
	}
}

type SendEmailWorker struct {
	river.WorkerDefaults[SendEmailArgs]
	Mailer Mailer
}

func (w *SendEmailWorker) Work(ctx context.Context, job *river.Job[SendEmailArgs]) error {
	// job.ID is the same on every retry: it is the idempotency key for the provider call.
	return w.Mailer.SendOrderConfirmation(ctx, job.Args.OrderID, fmt.Sprintf("email.send:%d", job.ID))
}

// NextRetry: exponential backoff, capped at one hour.
func (w *SendEmailWorker) NextRetry(job *river.Job[SendEmailArgs]) time.Time {
	d := time.Duration(1<<min(job.Attempt, 10)) * 10 * time.Second
	return time.Now().Add(min(d, time.Hour))
}

type OutboxRelayArgs struct{}

func (OutboxRelayArgs) Kind() string { return "outbox.relay" }

type OutboxRelayWorker struct {
	river.WorkerDefaults[OutboxRelayArgs]
	Relay OutboxRelay
}

func (w *OutboxRelayWorker) Work(ctx context.Context, _ *river.Job[OutboxRelayArgs]) error {
	_, err := w.Relay.Run(ctx, 100)
	return err
}

func New(pool *pgxpool.Pool, mailer Mailer, relay OutboxRelay) (*river.Client[pgx.Tx], error) {
	workers := river.NewWorkers()
	river.AddWorker(workers, &SendEmailWorker{Mailer: mailer})
	river.AddWorker(workers, &OutboxRelayWorker{Relay: relay})
	return river.NewClient(riverpgxv5.New(pool), &river.Config{
		Logger:     slog.Default(),
		JobTimeout: 5 * time.Minute, // the default is 1 minute: longer handlers are cancelled and retried
		Queues:     map[string]river.QueueConfig{river.QueueDefault: {MaxWorkers: 10}},
		Workers:    workers,
		PeriodicJobs: []*river.PeriodicJob{
			river.NewPeriodicJob(
				river.PeriodicInterval(5*time.Second),
				func() (river.JobArgs, *river.InsertOpts) { return OutboxRelayArgs{}, nil },
				&river.PeriodicJobOpts{RunOnStart: true},
			),
		},
	})
}
```

Producer: the service defines `type Jobs interface { SendEmail(ctx context.Context, tx pgx.Tx, orderID int64) error }`, implemented in `jobs` as `client.InsertTx(ctx, tx, SendEmailArgs{OrderID: id}, nil)`, and calls it inside `InTx` after the insert (see [database-patterns.md](../set-up-database/database-patterns.md)). A producer-only API process builds the client without `Queues` and `Workers`.

Outbox: `migrations/0003_outbox.sql` (table plus `CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL`), sqlc queries, repository, relay:

```sql
-- internal/repository/queries/outbox.sql
-- name: InsertOutbox :exec
INSERT INTO outbox (topic, payload) VALUES ($1, $2);

-- name: ClaimOutbox :many
SELECT id, topic, payload FROM outbox
WHERE published_at IS NULL
ORDER BY id
LIMIT $1
FOR UPDATE SKIP LOCKED;

-- name: MarkOutboxPublished :exec
UPDATE outbox SET published_at = now() WHERE id = ANY($1::bigint[]);
```

```go
// internal/service/outbox.go
type Publisher interface {
	Publish(ctx context.Context, e repository.OutboxEvent) error // e.ID is stable: receivers dedupe on it
}

func (r *OutboxRelay) Run(ctx context.Context, batch int32) (int, error) {
	var sent int
	err := r.tx.InTx(ctx, func(tx pgx.Tx) error {
		repo := r.outbox.WithTx(tx)
		events, err := repo.Claim(ctx, batch)
		if err != nil {
			return err
		}
		ids := make([]int64, 0, len(events))
		for _, e := range events {
			if err := r.publisher.Publish(ctx, e); err != nil {
				return fmt.Errorf("publish event %d: %w", e.ID, err) // rolls back: nothing is marked
			}
			ids = append(ids, e.ID)
		}
		sent = len(ids)
		return repo.MarkPublished(ctx, ids)
	})
	return sent, err
}
```

`repository.Outbox` has `Add`, `Claim`, `MarkPublished`, and `WithTx` like `repository.Orders` (sqlc rows mapped to `repository.OutboxEvent{ID, Topic, Payload}`).

Schema install: River's SQL goes through goose, so one tool owns the schema. Generate once per River upgrade:

```bash
{ echo "-- +goose Up"; echo "-- +goose StatementBegin"
  go run github.com/riverqueue/river/cmd/river@v0.49.0 migrate-get --all --exclude-version 1 --up
  echo "-- +goose StatementEnd"; } > migrations/$(date +%Y%m%d%H%M%S)_river.sql
```

Verified: goose applied it and created `river_job`, `river_leader`, `river_notification`, `river_queue`. The file contains comments saying large `river_job` indexes should be built `CONCURRENTLY` out of band; on an empty table the plain statements are fine. After a River upgrade, dump the new versions only (`--version 6,7` style, see `river migrate-get --help`) into a new file. The alternative, `rivermigrate` or `river migrate-up`, also works; it gives River a second migration history.

Verified behavior: an `InsertTx` that is rolled back leaves no row; two `Insert`s of identical args return `UniqueSkippedAsDuplicate: true` with the same job id; a worker that always errors ran 3 times for `MaxAttempts: 3` and ended in state `discarded`.

Verify:

```bash
psql "$DATABASE_URL" -c "select id, kind, state, attempt, max_attempts from river_job order by id desc limit 5"
# state 'discarded' = dead letter; retry one with client.JobRetry(ctx, id)
```

## Python: procrastinate 3

**Why procrastinate:** async-native, psycopg 3 (the driver in [database-patterns.md](../set-up-database/database-patterns.md)), `queueing_lock` for singleton scheduled tasks, `periodic` tasks, and it can defer inside your own transaction. 3.10.0, 2026-09-23, Python 3.10+. Celery needs a broker; `taskiq` 0.13 and `pgqueuer` 1.5 are younger options not evaluated here.

Install: `uv add procrastinate` (with `psycopg[binary,pool]`).

Seam, `src/<pkg>/platform/queue.py`:

```python
import random

import procrastinate
from procrastinate import BaseRetryStrategy, RetryDecision, builtin_tasks
from procrastinate.jobs import Job


class BackoffWithJitter(BaseRetryStrategy):
    """Exponential, capped, full jitter. `max_runs` counts every run, the first one included."""

    def __init__(self, max_runs: int = 6, base: int = 10, cap: int = 3600) -> None:
        self.max_runs, self.base, self.cap = max_runs, base, cap

    def get_retry_decision(self, *, exception: BaseException, job: Job) -> RetryDecision | None:
        if job.attempts + 1 >= self.max_runs:  # job.attempts counts the runs finished before this one
            return None
        ceiling = min(self.cap, self.base * 2**job.attempts)
        return RetryDecision(retry_in={"seconds": random.uniform(0, ceiling)})


def create_queue(database_url: str) -> procrastinate.App:
    app = procrastinate.App(
        connector=procrastinate.PsycopgConnector(conninfo=database_url),  # direct connection
        import_paths=["svc.transport.jobs"],  # modules whose tasks the worker must import
    )
    app.add_tasks_from(builtin_tasks.builtin, namespace="builtin")  # remove_old_jobs
    return app
```

Consumer, `src/<pkg>/transport/jobs.py`. The module defines the tasks on the app; each task calls a service:

```python
from procrastinate import builtin_tasks
from procrastinate.job_context import JobContext

from svc.config import get_settings
from svc.platform.queue import BackoffWithJitter, create_queue

queue = create_queue(get_settings().database_url)   # the worker CLI imports this object


@queue.task(
    name="email.send",
    queue="email",
    pass_context=True,
    retry=BackoffWithJitter(max_runs=6),
)
async def send_email(context: JobContext, order_id: str) -> None:
    # context.job.id is the same on every retry: the idempotency key for the provider call
    await notifications_service().send_order_confirmation(order_id, idempotency_key=f"email.send:{context.job.id}")


@queue.periodic(cron="0 * * * *")
@queue.task(name="jobs.cleanup", queueing_lock="jobs.cleanup", pass_context=True)
async def cleanup(context: JobContext, timestamp: int) -> None:
    await builtin_tasks.remove_old_jobs(context, max_hours=168, remove_failed=False)
```

`notifications_service()` is the composition-root accessor you already have; keep the task body to one call. Producer, inside the unit of work (SQLAlchemy session on psycopg 3; verified: a rolled-back transaction leaves no job, the committed one runs):

```python
async with session.begin():
    order = await orders.add()
    conn = await session.connection()
    raw = await conn.get_raw_connection()
    await send_email.configure(connection=raw.driver_connection).defer_async(order_id=str(order.id))
```

Wrap those three connection lines once, in `platform/queue.py` (`defer_in_session(session, task, **kwargs)`), so services never see `driver_connection`. A producer that is not in a transaction calls `await send_email.defer_async(order_id=...)` inside `async with queue.open_async():`.

Pitfalls (verified):
- **Built-in `RetryStrategy(max_attempts=N)` runs N+1 times** (`max_attempts=2` produced 3 attempts), and has no jitter and no cap: wait is `wait + linear_wait * attempts + exponential_wait ** (attempts + 1)`. The `BackoffWithJitter` strategy above fixes both (verified: `max_runs=3` produced 3 runs, then status `failed`). To stop retrying a permanent error, return `None` from `get_retry_decision` for that exception type.
- **Failed jobs stay `failed`** (the dead-letter state); finished jobs stay **forever** unless purged (task above or `worker --delete-jobs=successful`).
- **Worker flag:** `procrastinate --app=svc.transport.jobs.queue worker` waits for jobs; `--one-shot` processes what exists and exits (CI, verify step).
- **Alembic drops procrastinate tables** unless filtered, see [migration-patterns.md](../set-up-database/migration-patterns.md).

Outbox relay, `src/<pkg>/service/outbox.py` (model `OutboxEvent` in `repository/models.py`: `id` bigint identity, `topic`, `payload` JSONB, `created_at`, `published_at`):

```python
async def relay_outbox(session: AsyncSession, publisher: Publisher, batch_size: int = 100) -> int:
    async with session.begin():
        rows = (
            await session.scalars(
                select(OutboxEvent)
                .where(OutboxEvent.published_at.is_(None))
                .order_by(OutboxEvent.id)
                .limit(batch_size)
                .with_for_update(skip_locked=True)  # two relays never take the same row
            )
        ).all()
        for row in rows:
            await publisher.publish(id=row.id, topic=row.topic, payload=row.payload)  # at least once; receivers dedupe on id
        if rows:
            await session.execute(
                update(OutboxEvent).where(OutboxEvent.id.in_([r.id for r in rows])).values(published_at=func.now())
            )
        return len(rows)
```

Call it from a `queue.periodic` task with `queueing_lock="outbox.relay"`. Verified: two events relayed once, second run returns 0.

Schema install inside Alembic, one revision, then one revision per library upgrade:

```python
from alembic import op
from procrastinate.schema import SchemaManager

def upgrade() -> None:
    # `%` must be doubled: psycopg reads it as a placeholder, as procrastinate's own apply_schema does
    op.get_bind().exec_driver_sql(SchemaManager.get_schema().replace("%", "%%"))
```

After upgrading procrastinate, add a revision that executes the new files, in order, from `procrastinate schema --migrations-path` (the `pre`/`post` naming in the folder says when each is safe to run during a rolling deploy). Verified: the revision applied on an empty database and created the `procrastinate_*` tables; `alembic check` ignored them with the `include_object` filter.

Verify:

```bash
procrastinate --app=svc.transport.jobs.queue worker --one-shot
psql "$DATABASE_URL" -c "select id, task_name, status, attempts from procrastinate_jobs order by id desc limit 5"
# status 'failed' = dead letter; 'succeeded' = done
```

## When to deviate

- Supabase-hosted Postgres with no own server: `pgmq` and `pg_cron` are available as extensions; the outbox and idempotency rules are the same.
- You need cross-language producers: pg-boss and River enqueue from SQL too, procrastinate has `procrastinate_defer_jobs_v1`; document the function and keep payloads JSON.
- Very large single queues: pg-boss `partition: true`; River and procrastinate rely on retention and autovacuum, see "When to leave Postgres" in [jobs-patterns.md](jobs-patterns.md).
