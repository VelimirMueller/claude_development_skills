# Migration Patterns

Reference for `set-up-database`. Postgres 18.6; tool behavior verified 2026-10-09 with `drizzle-kit` 0.31.11, `goose` 3.28.0, `alembic` 1.20.0, `squawk` 2.68.0. Principle: [reversible by default](../../core/_shared/engineering-principles.md), meaning the *deploy* is reversible, not the SQL.

## Rule: A migration is a reviewed SQL file, immutable after merge
**Why:** A file in git can be read in review, replayed on a fresh database and compared across environments. Editing a merged migration makes staging and production disagree with new databases and the tool's checksum or history table can no longer be trusted.
**How to apply:** generate (`drizzle-kit generate`, `alembic revision --autogenerate`) or write (`goose create ... sql`), **read the SQL**, edit it if needed, commit. Autogenerate is a draft: it cannot see data moves, renames (it emits drop and add), or lock cost. After merge, a mistake gets a new migration.
**Anti-example:** Editing `0003_add_status.sql` after it ran in staging.

## Rule: Forward-only in shared environments
**Why:** A down migration is code that runs once, under stress, against data the author never tested; dropping a column in `down` loses what was written since. The reliable rollback is to redeploy the previous app version, which works only if the schema is compatible with both versions (next rule).
**How to apply:** no `down` in production. Drizzle has none. Goose: write `-- +goose Up` only. Alembic: leave `downgrade()` as `pass` and never run it outside a local database. A bad migration is fixed by the next migration.
**When to deviate:** Local development may use down or a full reset.

## Rule: Expand, migrate, contract: every breaking schema change takes at least two deploys
**Why:** During a rolling deploy, old and new app versions run against the same database. A schema the old version cannot read breaks it for the minutes the rollout takes, and rollback becomes impossible once the old column is gone.
**How to apply:** Example, rename `users.name` to `users.full_name`:
1. **Expand** (migration + deploy 1): `ADD COLUMN full_name text` (nullable). App writes both columns, still reads `name`. A trigger is optional; dual writes in the repository are explicit and testable.
2. **Migrate** (script, between deploys): backfill `full_name` from `name` in batches (below). Verify `count(*) WHERE full_name IS NULL` is 0.
3. Deploy 2: app reads `full_name`, still writes both.
4. Deploy 3: app stops writing `name`.
5. **Contract** (migration + deploy 4): `DROP COLUMN name` (and add `NOT NULL` to `full_name` through the safe path below), only after nothing reads `name`, including reports and jobs.

The same shape covers: changing a column type (new column), splitting a table, replacing an enum, moving a constraint. Never `RENAME COLUMN` or `RENAME TABLE` on a live table: it is instant for Postgres and instantly breaks every old-version pod.
**Anti-example:** One migration that renames the column, shipped with the app change that uses the new name.

## Rule: Set lock and statement timeouts on the migration role
**Why:** `ALTER TABLE` needs a lock. If a long query holds a conflicting lock, the `ALTER` waits, and every query behind it waits for the `ALTER`: one slow report turns a one-line migration into an outage. A `lock_timeout` makes the migration fail fast and retry instead.
**How to apply:** a dedicated role for migrations, with the timeouts on the role so no tool needs a hook:

```sql
CREATE ROLE app_migrator LOGIN PASSWORD '<from the secret store>';
ALTER ROLE app_migrator SET lock_timeout = '5s';
ALTER ROLE app_migrator SET statement_timeout = '60s';
```

Verified: `show lock_timeout` returns `5s` for that role; `?options=-c%20lock_timeout%3D3s` in the URL does it per run. A `lock_timeout` failure is normal: re-run the migration off-peak. Raise `statement_timeout` for a specific long statement with `SET LOCAL` inside that migration, not globally. Runtime role (`app_runtime`): DML only, no DDL.
**When to deviate:** A database with no concurrent traffic (a new project, a nightly-only system) can skip the timeouts.

## Rule: Run the safety checklist on every migration, write the lock level in the PR
**Why:** The dangerous statements look harmless in a diff. Naming the lock for each statement forces the question "who is blocked, for how long".

| Statement | Lock / cost | Safe form |
|---|---|---|
| `ADD COLUMN x type` | ACCESS EXCLUSIVE, instant | Fine (nullable) |
| `ADD COLUMN x type NOT NULL DEFAULT <constant>` | instant since Postgres 11 | Fine; a **volatile** default (`gen_random_uuid()`, `random()`) rewrites the table: add nullable, backfill, then constrain |
| `ALTER COLUMN x SET NOT NULL` | ACCESS EXCLUSIVE + full scan | `ADD CONSTRAINT x_nn CHECK (x IS NOT NULL) NOT VALID;` → `VALIDATE CONSTRAINT x_nn;` → `SET NOT NULL` (Postgres 12+ skips the scan using the validated check) → `DROP CONSTRAINT x_nn`. Postgres 18 also accepts `ADD CONSTRAINT x_nn NOT NULL x NOT VALID` then `VALIDATE` (verified on 18.6) |
| `CREATE INDEX` | SHARE: blocks writes | `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, outside a transaction |
| `CREATE UNIQUE INDEX` for a constraint | SHARE | `CREATE UNIQUE INDEX CONCURRENTLY`, then `ADD CONSTRAINT ... UNIQUE USING INDEX` (verified) |
| `ADD FOREIGN KEY` | SHARE ROW EXCLUSIVE on both tables, scans | `ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID;` then `VALIDATE CONSTRAINT` (takes a weaker lock) |
| `ADD CHECK` | ACCESS EXCLUSIVE + scan | `NOT VALID` then `VALIDATE` |
| `ALTER COLUMN TYPE` | ACCESS EXCLUSIVE, usually a rewrite | New column, expand and contract. Exceptions that skip the rewrite (`varchar(n)` to larger `n`, to `text`) |
| `DROP COLUMN` / `DROP TABLE` | ACCESS EXCLUSIVE, instant | Only in the contract step, after the code stopped using it |
| `RENAME ...` | instant, breaks old code | Never on live objects; expand and contract |
| `ALTER TYPE ... ADD VALUE` (enum) | fine | The new value cannot be used in the same transaction. Prefer `text` + `CHECK` for sets that change |
| `UPDATE` over many rows | row locks, bloat, long transaction | Batched backfill, outside the DDL transaction |
| `CREATE INDEX CONCURRENTLY` failed | leaves an INVALID index | `DROP INDEX CONCURRENTLY` it, then retry |

**How to apply:** automate the mechanical part, review the rest. `squawk` flags missing `lock_timeout`, non-concurrent index creation, `SET NOT NULL`, adding a required column and more:

```bash
npx squawk-cli@2.68.0 --pg-version=18 migrations/*.sql     # exit 1 on findings
```

Drizzle and Alembic folders: point it at the SQL (`drizzle/*.sql`) or at `alembic upgrade head --sql` output. Exclude a rule with `--exclude=<rule>` only with a comment in the migration saying why (an empty new table makes `require-concurrent-index-creation` noise).

## Rule: Backfill in batches, outside the DDL transaction
**Why:** One `UPDATE` over ten million rows holds a transaction open for minutes, bloats the table, and blocks vacuum. Batches commit often and can be stopped and resumed.
**How to apply:** a script or a background job ([set-up-background-jobs](../set-up-background-jobs/SKILL.md)), keyset-batched and idempotent:

```sql
-- repeat until it updates 0 rows; sleep 100 ms between batches
WITH batch AS (
  SELECT id FROM users WHERE full_name IS NULL ORDER BY id LIMIT 1000 FOR UPDATE SKIP LOCKED
)
UPDATE users u SET full_name = u.name FROM batch WHERE u.id = batch.id;
```

Run it under the runtime-like role with a statement timeout. Log the count per batch. The migration file that *adds* the column and the script that *fills* it are separate steps.

## Tool pitfalls (verified)

### Drizzle: `CREATE INDEX CONCURRENTLY` fails inside `drizzle-kit migrate`, and the error is not printed
**Why it happens:** the migrator applies pending files inside a transaction, and Postgres refuses `CONCURRENTLY` in one. `drizzle-kit migrate` exits 1 and shows only the spinner (`applying migrations...`), no message.
**How to apply:**
1. Declare the index in `schema.ts` so snapshots stay accurate.
2. `drizzle-kit generate` (or `--custom --name=<what>`), then edit the SQL file to the *idempotent, non-concurrent* form: `CREATE INDEX IF NOT EXISTS "orders_status_idx" ON "orders" ("status");`.
3. Before `drizzle-kit migrate` in the deploy, run the concurrent build once, out of band, on large tables: `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c 'CREATE INDEX CONCURRENTLY IF NOT EXISTS "orders_status_idx" ON "orders" ("status")'`. The migration is then a no-op (verified: migrate succeeds, index present). Keep these statements in `drizzle/concurrent/*.sql` and run them in a `db:migrate:pre` step.
4. When a Drizzle migration fails with no text, run the file with `psql -v ON_ERROR_STOP=1 -f drizzle/<file>.sql` against a scratch database to see the real error.
Small tables and new tables can use the plain `CREATE INDEX` in the generated file.

### Drizzle: `generate` diffs the schema file against its snapshot, not the live database
Other tools' tables (`pgboss.*`) never appear in a generated migration. `drizzle-kit push` and `pull` do read the live database: another reason for the no-push rule ([database-patterns.md](database-patterns.md)). Pin `drizzle-orm` and `drizzle-kit` to the same channel; 1.0 is rc.

### goose: transactions per file, opt out per file
Each file runs in a transaction. For `CONCURRENTLY` put `-- +goose NO TRANSACTION` as the first line (verified: applied, index present):

```sql
-- +goose NO TRANSACTION
-- +goose Up
CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_status_idx ON orders (status);
```

Statements containing semicolons (functions) need `-- +goose StatementBegin` / `StatementEnd`. `goose validate` checks the files parse; `goose create <name> sql` names them with a timestamp (sorted order; two branches adding migrations merge without renumbering). sqlc reads the same folder as its schema and ignores `Down` sections. Keep `goose` out of `go.mod` with `go get -modfile=tools.mod -tool ...` and `go tool -modfile=tools.mod goose` (verified).

### Alembic: autogenerate will drop tables that other tools own
If `procrastinate_*` or `river_*` tables share the `public` schema, `alembic revision --autogenerate` emits `drop_table` for all of them (verified). Add to `alembic/env.py`:

```python
FOREIGN_PREFIXES = ("procrastinate_", "river_")

def include_object(obj, name, type_, reflected, compare_to):
    if type_ == "table" and reflected and name and name.startswith(FOREIGN_PREFIXES):
        return False
    return True
# context.configure(connection=connection, target_metadata=target_metadata,
#                   compare_type=True, include_object=include_object)
```

Other points, all verified:
- Template: `alembic init -t pyproject_async alembic` (config in `pyproject.toml`, async `env.py`). The generated `env.py` has `target_metadata = None`: set it to `Base.metadata`, and set the URL from your config module, not `alembic.ini`.
- `CONCURRENTLY`: `with op.get_context().autocommit_block(): op.create_index("orders_status_idx", "orders", ["status"], postgresql_concurrently=True, if_not_exists=True)`.
- `alembic check` exits non-zero when models and migrations differ (it caught an index added in a migration but missing from the model): put the index in `__table_args__` too. It is the `db:check` gate.
- Autogenerate does not detect `server_default` changes unless `compare_server_default=True`; it detects type changes only with `compare_type=True`.

## Rule: CI proves the migrations from zero, and the app against the result
**Why:** A migration that works on the developer's long-lived database may fail on an empty one (missing prerequisite) or the reverse.
**How to apply:** a CI job with a Postgres service container: empty database → `db:migrate` → `db:check` → `squawk` → test suite. A second run of `db:migrate` must be a no-op. Seed is not part of it.

## When to deviate

- A pre-production prototype with no data worth keeping: squash migrations into a baseline before the first shared deploy, not after.
- Zero-downtime is not required (internal tool with a maintenance window): expand and contract collapses into one deploy; keep `lock_timeout` and the checklist.
- A tiny table (under ~10k rows) makes a plain `CREATE INDEX` or `SET NOT NULL` instant; the checklist still names the lock, the unsafe form is allowed.
- Atlas or another declarative tool: acceptable if it still emits reviewed SQL files and the same safety gate. Not evaluated here.
