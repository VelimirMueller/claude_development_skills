# Database Patterns

Reference for `set-up-database`. Snippets compiled or run on Postgres 18.6, 2026-10-09. Layer rules: [service-layout.md](../_shared/service-layout.md). Migration rules: [migration-patterns.md](migration-patterns.md).

## Rule: Postgres, current major, same major locally and in production
**Why:** One engine removes a class of "works on SQLite" bugs. Postgres 18 is the newest major (18.6); 14 reaches end of life in November 2026. A local major that differs from production hides planner and syntax differences until deploy.
**How to apply:** `postgres:18` in compose; CI service container the same tag; production on a supported major (16 to 18). Check support dates at `postgresql.org/support/versioning`.
**When to deviate:** A managed host that lags (check its list) sets the major; match it locally.

## Rule: Local Postgres is one compose file with a health check
**Why:** `docker compose up --wait` blocks until the database accepts connections, so migrations and tests never race the start. Binding to `127.0.0.1` keeps a dev database off the network.
**How to apply:**

```yaml
# compose.yaml
services:
  db:
    image: postgres:18
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app        # local only; never reuse outside this file
      POSTGRES_DB: app
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql  # Postgres 18 images store data in /var/lib/postgresql/18/docker
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 2s
      timeout: 3s
      retries: 15
volumes:
  pgdata:
```

Verified: `docker compose up -d --wait` reports Healthy; `show data_directory` is `/var/lib/postgresql/18/docker`. Mounting `/var/lib/postgresql/data` on a 18 image is the pre-18 layout and breaks `pg_upgrade` later.
**Anti-example:** A shared remote "dev database" every developer migrates by hand.

## Rule: One database seam per process; the pool is created in `main`
**Why:** Pool settings (size, timeouts, health checks) decide how the service behaves under load and during a database restart. They belong in one file, built from validated config, not in whichever module connected first.
**How to apply:** the seam exposes `transaction`/`InTx`, `ping`, `close`, and nothing table-specific.

TypeScript, `src/platform/db.ts`. `pg` over `postgres.js`: `pg-boss` uses `pg`, so jobs and the app share one driver and one set of connection settings:

```ts
import { sql } from 'drizzle-orm';
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import pg from 'pg';
import * as schema from '../repository/schema.ts';

export type Db = NodePgDatabase<typeof schema>;
export type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];
/** Repositories take a pool-backed `db` for single statements, or a `tx` inside a unit of work. */
export type Executor = Db | Tx;

export interface Database {
  db: Db;
  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T>;
  ping(): Promise<void>;
  close(): Promise<void>;
}

export function createDatabase(opts: { databaseUrl: string; poolMax?: number; onError: (err: Error) => void }): Database {
  const pool = new pg.Pool({
    connectionString: opts.databaseUrl,
    max: opts.poolMax ?? 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000, // fail a request fast instead of queueing forever
  });
  pool.on('error', opts.onError); // an idle client died; without a handler Node exits on the unhandled 'error' event
  const db = drizzle({ client: pool, schema });
  return {
    db,
    transaction: (fn) => db.transaction(fn),
    ping: async () => {
      await db.execute(sql`select 1`);
    },
    close: () => pool.end(),
  };
}
```

`onError` is the logger seam's `error`. Schema file: `src/repository/schema.ts`; `drizzle.config.ts`:

```ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'postgresql',
  schema: './src/repository/schema.ts',
  out: './drizzle',
  dbCredentials: { url: process.env.DATABASE_URL! },
});
```

Go, `internal/platform/db/db.go`. `pgx` v5 pool; sqlc generates from the migrations into `internal/repository/db/` (package `dbgen`, so it does not collide with the platform package):

```go
// Package db owns the connection pool and the unit of work. It knows no table.
package db

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Pool struct{ *pgxpool.Pool }

func New(ctx context.Context, url string, maxConns int32) (*Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.MaxConns = maxConns
	cfg.MaxConnLifetime = time.Hour
	cfg.MaxConnIdleTime = 30 * time.Minute
	cfg.HealthCheckPeriod = time.Minute
	p, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return &Pool{p}, nil
}

// InTx runs fn in one transaction: commit when fn returns nil, roll back on error or panic.
func (p *Pool) InTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, p.Pool, fn)
}
```

```yaml
# sqlc.yaml
version: "2"
sql:
  - engine: postgresql
    schema: migrations              # the goose files are the schema; sqlc ignores the Down sections
    queries: internal/repository/queries
    gen:
      go:
        package: dbgen
        out: internal/repository/db
        sql_package: pgx/v5
        emit_pointers_for_null_types: true
```

Python, `src/<pkg>/platform/db.py`. `psycopg` 3 over `asyncpg`: `procrastinate` uses psycopg 3, so the jobs library can enlist in the request's transaction through the same driver (verified in [jobs-track-patterns.md](../set-up-background-jobs/jobs-track-patterns.md)). Models live in `src/<pkg>/repository/models.py`:

```python
from collections.abc import AsyncIterator
from dataclasses import dataclass

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine


@dataclass(frozen=True)
class Database:
    engine: AsyncEngine
    sessions: async_sessionmaker[AsyncSession]

    async def ping(self) -> None:
        async with self.engine.connect() as conn:
            await conn.execute(text("select 1"))

    async def close(self) -> None:
        await self.engine.dispose()


def create_database(database_url: str, *, pool_size: int = 10) -> Database:
    url = make_url(database_url).set(drivername="postgresql+psycopg")
    engine = create_async_engine(
        url,
        pool_size=pool_size,
        max_overflow=0,        # the pool size is the limit; extra load waits
        pool_timeout=5,        # fail a request fast instead of queueing forever
        pool_pre_ping=True,    # drop connections the server or a proxy closed
        pool_recycle=1800,
    )
    return Database(engine, async_sessionmaker(engine, expire_on_commit=False))


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    """One session per request. No transaction yet: the service opens it."""
    async with request.app.state.database.sessions() as session:
        yield session
```

Build `create_database` in the app lifespan, store it on `app.state.database`, call `close()` on shutdown.
**Anti-example:** `engine = create_engine(os.environ["DATABASE_URL"])` at module import in a repository.

## Rule: The service opens the transaction; repositories join it
**Why:** A transaction is a business decision ("these writes succeed together"), so the layer that knows the use case owns it. A transaction opened per repository call cannot cover two writes; one opened in the handler leaks the database into transport.
**How to apply:**
- Service: `transaction(async (tx) => { ... repo.insert(tx, ...) ... })`. Repositories take the handle (`Executor`, `pgx.Tx` via `WithTx`, the `AsyncSession`).
- Enqueue background work in the same transaction as the write that causes it ([set-up-background-jobs](../set-up-background-jobs/SKILL.md)).
- Keep transactions short: no HTTP calls, no sleeps, no waiting on a user inside one. A transaction holds a connection and its locks.
- SQLAlchemy: `session.begin()` must be the session's first operation. Verified: after any `execute`, `async with session.begin()` raises `InvalidRequestError: A transaction is already begun on this Session`. Do reads that belong to the unit of work inside the block.
- Go: return the error from the closure to roll back. `pgx.BeginFunc` also rolls back on panic.

Go repository and service shape (sqlc rows stay inside the repository):

```go
// internal/repository/orders.go
type Order struct {
	ID     int64
	Status string
}

type Orders struct{ q *dbgen.Queries }

func NewOrders(db dbgen.DBTX) *Orders          { return &Orders{q: dbgen.New(db)} }
func (r *Orders) WithTx(tx pgx.Tx) *Orders     { return &Orders{q: r.q.WithTx(tx)} }
func (r *Orders) Insert(ctx context.Context) (Order, error) {
	row, err := r.q.InsertOrder(ctx)
	if err != nil {
		return Order{}, err
	}
	return Order{ID: row.ID, Status: row.Status}, nil
}

// internal/service/orders.go
type Transactor interface {
	InTx(ctx context.Context, fn func(tx pgx.Tx) error) error
}

func (s *Orders) Place(ctx context.Context) (repository.Order, error) {
	var out repository.Order
	err := s.tx.InTx(ctx, func(tx pgx.Tx) error {
		o, err := s.orders.WithTx(tx).Insert(ctx)
		out = o
		return err
	})
	return out, err
}
```

**Anti-example:** A handler that calls `db.transaction` and runs three repository methods inside.

## Rule: Size the pool from the database limit, and pool in front when replicas multiply
**Why:** Postgres runs one process per connection; each costs memory, and `max_connections` is a hard wall. Total demand is `replicas × pool size`. Serverless and many small replicas exceed the wall quickly.
**How to apply:**
- App pool: 5 to 10 per replica is plenty for an async service; more connections than cores on the database rarely help. Set `connectionTimeout` (`pool_timeout`, `acquire` timeout) so overload fails fast.
- Keep `replicas × pool ≤ max_connections − reserve` (reserve for migrations, admin, jobs; 10 to 20).
- Past that, or on serverless: PgBouncer or the host's pooler (Supavisor, RDS Proxy) in **transaction** mode, and the app pool shrinks.
- Transaction mode drops session state. Not allowed through it: `LISTEN/NOTIFY`, session advisory locks, `SET` outside a transaction. Run migrations and job workers on a **direct** connection.
- Prepared statements: PgBouncer 1.21+ supports protocol-level named statements when `max_prepared_statements` is non-zero (default 200 per the PgBouncer config docs). With an older PgBouncer or the setting at 0: pgx set `DefaultQueryExecMode = pgx.QueryExecModeExec` (or `default_query_exec_mode=exec` in the URL); psycopg `prepare_threshold=None`. `node-postgres` and Drizzle send unnamed statements and need nothing.
**When to deviate:** One replica of a low-traffic service needs no pooler.

## Rule: Seed data is a script, idempotent, development only
**Why:** A seed that fails on the second run makes `db:reset` a chore, and a seed that runs in production creates demo users in a real system.
**How to apply:** `db/seed.sql`, plain SQL, one file per track so the format does not change with the language:

```sql
INSERT INTO orders (id, status) VALUES
  ('00000000-0000-4000-8000-000000000001', 'paid'),
  ('00000000-0000-4000-8000-000000000002', 'pending')
ON CONFLICT (id) DO NOTHING;
```

Run it from the task, with a guard so it cannot reach a remote host:

```bash
case "$DATABASE_URL" in *127.0.0.1*|*localhost*) ;; *) echo "seed refused: not a local database" >&2; exit 1 ;; esac
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/seed.sql
```

Rows the application needs to function (roles, plans, feature defaults) are migrations, not seed.
**Anti-example:** `npm run seed` wired into the deploy pipeline.

## Rule: Never `db push`, `create_all` or auto-migrate against a shared environment
**Why:** `drizzle-kit push` diffs the live database against the schema file and applies the difference with no file to review, no record, and no rollback story; it may drop columns the code no longer mentions. `create_all` and ORM auto-sync do the same at app start, racing across replicas. A migration file is the only artifact that can be read in review, replayed on a fresh database and diffed later.
**How to apply:** local throwaway database: `push` or `create_all` is fine for a spike. Anything shared (staging, production, a teammate's long-lived database): generate a migration, read the SQL, commit it, run `db:migrate`. CI fails on `push|create_all|AutoMigrate|synchronize: true` in non-test code (`grep` in the audit step).

## Rule: Drizzle, sqlc and SQLAlchemy ORM each stay behind the repository
**Why:** A swap or a schema change touches one folder. Domain types, not ORM rows, cross the repository boundary.
**How to apply:** TS: repositories return `$inferSelect` types mapped to domain types when they differ. Go: sqlc rows are mapped to repository types (above). Python: return dataclasses or Pydantic models from the repository, not `Order` ORM instances, when the service would otherwise touch lazy attributes; with `expire_on_commit=False` returning the ORM object is acceptable inside a small service.

## When to deviate

- Supabase as the host: its CLI owns migrations (`supabase/migrations`); the ORM seam still applies.
- A spike or prototype: `push` against a local throwaway database. The first shared deploy starts with a baseline migration.
- Analytical workloads or very large tables: partitioning and read replicas are a design task, not a default.
- SQLite for a CLI or desktop app: the migration rules apply; the Postgres specifics here do not.
