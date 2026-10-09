---
name: set-up-database
description: Use when a backend needs Postgres, or its schema changes by hand or by `db push` — sets up local Postgres via compose, the ORM or sqlc, pooling, service-layer transactions, versioned reviewed migrations, seed data, and a migration-safety gate.
---

# Set Up Database

Rules and per-track seam code: [database-patterns.md](database-patterns.md). Migration workflow, safety checklist, per-tool recipes: [migration-patterns.md](migration-patterns.md). Layer paths: [service-layout.md](../_shared/service-layout.md). Config: [config.md](../_shared/config.md). Versions: [stack-versions.md](../_shared/stack-versions.md).

Postgres only. Schema changes are versioned SQL files in git, reviewed in the PR, applied forward-only to shared environments.

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null   # backend.track, database.{engine,orm,host}, task_runner
ls compose.yaml docker-compose.yml drizzle.config.ts drizzle sqlc.yaml migrations alembic alembic.ini db/seed.sql 2>/dev/null
ls src/platform/db.ts internal/platform/db src/*/platform/db.py 2>/dev/null
grep -rnE "drizzle-kit push|db push|create_all\(|AutoMigrate|synchronize: *true" . --include=* -I 2>/dev/null | grep -v node_modules | head
grep -rnE "DATABASE_URL" .env.example src internal 2>/dev/null | head -5
git ls-files | grep -E "\.env($|\.)" | grep -v example           # committed env file = finding
```

Findings to record: a `push`/`create_all`/auto-migrate call anywhere that can reach a shared environment, a connection created outside the seam, SQL strings in services, no `.env.example` key for `DATABASE_URL`, migrations edited after merge.

## 2. Decide

- `backend.track: supabase` or `database.host: supabase`: the Supabase CLI owns migrations. Run [set-up-supabase](../set-up-supabase/SKILL.md) and use this skill only for the ORM seam and the migration-safety checklist.
- `backend.track: nextjs`: the seam path is the app's `src/db/`; follow `build-nextjs-backend`, apply the rules here.
- No database seam, no migrations: full setup (steps 3 to 7).
- Seam exists, migrations are tool-generated and reviewed: add only the gaps (pooling, transaction helper, seed, safety gate).
- A `push` or auto-migrate call reaches a shared environment: replace it with the migration command (step 6) before anything else.
- All present and step 7 passes: report "already in place" and stop.

## 3. Detect track

| `backend.track` / `database.orm` | Stack | Migration tool | Why this pair |
|---|---|---|---|
| `hono` / `drizzle` | Drizzle ORM + `pg` | `drizzle-kit generate` + `migrate` | Schema in TypeScript, SQL files generated and editable |
| `go` / `sqlc` | `pgx` v5 + `sqlc` | `goose` (SQL files) | sqlc reads goose files as its schema; SQL stays the source |
| `fastapi` / `sqlalchemy` | SQLAlchemy 2 async + `psycopg` 3 | Alembic | Standard tool; autogenerate plus hand edit |

`orm: none` or unset: ask one question only if the track does not decide it. Defaults are the table's row for the track.

## 4. Install only what is missing

```bash
# hono
pnpm add drizzle-orm pg && pnpm add -D drizzle-kit @types/pg
# go
go get github.com/jackc/pgx/v5
go get -tool github.com/sqlc-dev/sqlc/cmd/sqlc@latest
go get -modfile=tools.mod -tool github.com/pressly/goose/v3/cmd/goose@latest   # keeps goose's dependencies out of go.mod
# fastapi
uv add "sqlalchemy[asyncio]" "psycopg[binary,pool]" alembic
```

Pin `drizzle-orm` and `drizzle-kit` to the stable `latest` line (0.45 / 0.31 today); 1.0 is rc, see [stack-versions.md](../_shared/stack-versions.md). Use the `[asyncio]` extra: without `greenlet`, importing `sqlalchemy.ext.asyncio` fails.

## 5. Generate the seams

1. `compose.yaml`: Postgres 18, health check, named volume at `/var/lib/postgresql` (Postgres 18 images keep the data in a versioned subfolder; the old `/var/lib/postgresql/data` mount is wrong). File in [database-patterns.md](database-patterns.md).
2. `.env.example`: `DATABASE_URL=postgres://app:app@127.0.0.1:5432/app`. Add the key to the config schema ([config.md](../_shared/config.md)); no default.
3. DB seam, one per track (code in [database-patterns.md](database-patterns.md)):
   - TS `src/platform/db.ts`: pool, `transaction`, `ping`, `close`; schema in `src/repository/schema.ts`.
   - Go `internal/platform/db/db.go`: `pgxpool`, `InTx`, ping; sqlc output in `internal/repository/db/`.
   - Python `src/<pkg>/platform/db.py`: async engine, `get_session`.
4. Repositories take a connection or transaction handle; services open the transaction ([service-layout.md](../_shared/service-layout.md)). One repository per aggregate.
5. Migration tool config: `drizzle.config.ts` + `drizzle/`, or `sqlc.yaml` + `migrations/`, or `alembic/` (template `pyproject_async`).
6. `db/seed.sql`: idempotent development data (`INSERT ... ON CONFLICT DO NOTHING`). Reference data the app needs in production goes into a migration, not the seed.
7. Readiness: the service's `/readyz` calls `ping` ([observability.md](../../core/_shared/observability.md)).

## 6. Wire

Four commands per project, named in the profile's `task_runner` (`just`, `mise`, package scripts or `make`):

| Task | TS | Go | Python |
|---|---|---|---|
| `db:up` | `docker compose up -d --wait db` | same | same |
| `db:generate` | `drizzle-kit generate --name <what>` | `goose create <name> sql` (write SQL) then `sqlc generate` | `alembic revision --autogenerate -m "<what>"` |
| `db:migrate` | `drizzle-kit migrate` | `goose up` (`GOOSE_DRIVER=postgres`, `GOOSE_DBSTRING`, `GOOSE_MIGRATION_DIR=migrations`) | `alembic upgrade head` |
| `db:check` | `drizzle-kit check` | `goose validate` and `sqlc generate` then `git diff --exit-code` | `alembic check` |

Rules for the commands:
- `db:migrate` runs as a separate deploy step before the new app version starts, never inside app startup (two replicas race; a failed migration should stop the deploy, not crash-loop the app).
- No `push`, no `create_all`, no auto-migrate in any command that accepts a shared `DATABASE_URL`. Local throwaway databases may reset and re-migrate.
- The migration role differs from the runtime role: runtime has DML only; the migration role has DDL and `lock_timeout`/`statement_timeout` set on the role ([migration-patterns.md](migration-patterns.md)).
- CI: start Postgres (service container), `db:migrate` on an empty database, `db:check`, then the tests against it. Test against real Postgres, not a mock.

## 7. Verify

```bash
docker compose up -d --wait db && <db:migrate>      # applies on an empty database
<db:check>                                          # TS: "Everything's fine"; Python: exit 0; Go: no diff
psql "$DATABASE_URL" -c '\dt'                       # expect your tables
<db:migrate>                                        # second run: nothing to apply, exit 0
```

Then the safety gate: for each new migration file, walk the checklist in [migration-patterns.md](migration-patterns.md) and write the lock level of every statement in the PR description. A transaction test: force an error after an insert inside a service call and confirm zero rows persist.

## References
- [database-patterns.md](database-patterns.md): compose, pooling, transactions, seed, per-track seam code.
- [migration-patterns.md](migration-patterns.md): forward-only, expand and contract, safety checklist, tool pitfalls.
- [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md): least-privilege roles, secrets.
