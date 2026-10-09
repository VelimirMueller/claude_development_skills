# Supabase Patterns

Reference for `set-up-supabase`. Facts verified 2026-10-09 against the Supabase docs and CLI reference and by running CLI 2.120.0 (`init`, `migration new`, `start`, `db reset`-equivalent migration apply, `test db`, `db advisors`, `gen types`, `functions serve`) against a local stack. Re-verify before scaffolding; see [stack-versions.md](../_shared/stack-versions.md).

## Rule: migration files are the only way schema reaches a remote
**Why:** A change made in the Dashboard or SQL editor exists in one database and nowhere in git. The next environment, the next preview branch and the next `db reset` all diverge from it. Files in `supabase/migrations/` replay the same history everywhere, and `db push` records what it applied in `supabase_migrations.schema_migrations`.
**How to apply:** Change the schema locally, commit the migration, let CI push it. `supabase db push --dry-run` shows the pending list. Once a migration is pushed, never edit it: add a new one. If someone changed a remote by hand, `supabase db pull` captures the drift as a migration.
**Anti-example:** Running `alter table` in the production SQL editor "just this once".

## Rule: plain migrations by default; declarative schemas are opt-in
**Why:** Supabase's current local-development guide offers declarative schemas (`supabase/schemas/*.sql` → `supabase db schema declarative sync -f <name>` → a migration) as "recommended for new projects". The commands run on the `pg-delta` engine, which the docs still describe as pre-1.0 under `[experimental.pgdelta]`. A hand-written migration is plain SQL with no engine in between, so it is the boring choice. Declarative wins on readability: one file per table, edit in place, review the diff of intent.
**How to apply:** Default to `supabase migration new <name>`. Opt in to declarative when the team accepts the experimental engine: `supabase init` on a recent CLI already writes `[experimental.pgdelta] enabled = true`. Rules once on declarative:
- Edit `supabase/schemas/`, then `supabase db schema declarative sync -f <name>`. Pass `--apply` or `--no-apply` in scripts; without one, a non-interactive run writes the file and skips applying.
- Never `db diff` to generate from declarative files, and remove `[db.migrations].schema_paths` (ignored under `pg-delta`, the CLI warns).
- Data changes (`insert`, `update`, storage bucket rows) are not captured: write them as a separate migration.
- Never mix: one project, one workflow. Studio edits are invisible to `sync`.
- `-- pg-delta: transaction=false` migrations work with `db push` but fail under the branching GitHub integration, which runs each migration in a transaction.
**Anti-example:** Keeping both `supabase/schemas/` and hand-written migrations that edit the same tables.

## Rule: one project per environment; branching or CI, not both
**Why:** Two environments in one project share auth users, storage and keys. A preview environment per pull request catches a broken migration before merge.
**How to apply:** Local stack for development; a staging project (a new one, not a copy that already has the production schema: the CLI would reapply history); production. Pick one deploy path:
- **Supabase GitHub integration with branching.** Every PR gets a preview branch with its own API credentials, cloned config, no data by default (seed via `[db.seed]` and `seed.sql`). On merge the deploy runs: pull, health, configure, migrate, seed, functions. Persistent branches (staging) need an entry under `[remotes.<name>]` in `config.toml` with `project_id`.
- **GitHub Actions + CLI.** `ci.yml` on `pull_request`; `staging.yml` on `develop`; `production.yml` on `main`, each running `supabase link --project-ref $ID` then `supabase db push`. Env: `SUPABASE_ACCESS_TOKEN` (a scoped personal access token, read access to Project Settings, API Keys and API Key Secrets because `link` needs them), `SUPABASE_DB_PASSWORD`, project id; all as encrypted repository secrets. Pin third-party actions per [security-baseline.md](../../core/_shared/security-baseline.md).
**Never** pass `--include-seed` to production, and treat `supabase db reset --linked` as destructive: throwaway projects only.

## Rule: new API keys; legacy anon/service_role only while migrating
**Why:** The publishable key (`sb_publishable_…`, role `anon` or `authenticated`) and secret key (`sb_secret_…`, role `service_role`, bypasses RLS) are not JWTs, can be rotated on their own, and one secret key per backend component limits a leak to that component. Supabase states the legacy JWT-based `anon` / `service_role` keys are deprecated "by the end of 2026". Creating new keys does not revoke the legacy ones: disable legacy keys in the Dashboard as a separate step. Asymmetric JWT signing keys (the default for new projects) make `getClaims()` verify locally and let signing keys rotate without signing users out.
**How to apply:** New code reads `*_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY`. Send API keys in the `apikey` header, never `Authorization: Bearer` (they are not JWTs). A secret key sent from a browser is rejected with HTTP 401 (matched on `User-Agent`), including on localhost. To rotate a leaked secret key: create the new key, replace it everywhere, confirm, then delete the old one (deletion cannot be undone). On a project still on the legacy secret, use the Dashboard's JWT signing keys page to migrate; it needs no downtime.

## Rule: one client seam per context; the secret key is server-only by construction
**Why:** A secret key in a module that a client component can import ships to every browser. `import 'server-only'` turns that mistake into a build error instead of a leak. Three contexts behave differently: the browser client has no secret and cannot read the session (its cookie is httpOnly, see [set-up-nextjs-supabase-auth](../set-up-nextjs-supabase-auth/SKILL.md)); the server acts as the signed-in user per request; the admin acts as the system and bypasses RLS.
**How to apply:** `browser.ts` (Realtime and non-auth client queries only), `server.ts` (per request, from `@supabase/ssr` cookies), `admin.ts` (`server-only`, `persistSession: false`). Nothing else calls `createClient`. Create server and admin clients with `Database` generics. Do not cache a server client in a module variable: it holds one request's cookies. After `pnpm build`, grep the client output for `sb_secret_` (see Verify in the skill).
**Anti-example:** `const supabase = createClient(url, process.env.NEXT_PUBLIC_SUPABASE_SERVICE_KEY!)` — the `NEXT_PUBLIC_` prefix publishes it.

## Rule: generated types are committed and checked in CI
**Why:** `Database` types make a renamed column a compile error instead of a runtime 400. A stale file does the opposite: it lies.
**How to apply:** `supabase gen types --lang typescript --local > src/libs/supabase/database.types.ts` after each migration (`--linked` or `--project-id` from a remote). Use the generated helpers (`Tables<'x'>`, `Enums<'x'>`) instead of hand-written row types. In CI regenerate and `git diff --exit-code` the file. The `Json` columns stay `Json`: narrow them with Zod at the seam, not with a cast.

## Rule: local stack is development only
**Why:** `supabase start` has default credentials, no TLS and no rate limiting; the docs say never expose it.
**How to apply:** Bind to localhost, never forward its ports. `seed.sql` holds invented users and rows. `config.toml` is committed and holds no secret: sensitive values use `env(NAME)`, for example `password = "env(SMTP_PASSWORD)"`. `supabase config push` sends `config.toml` to the linked project; run it from CI for the environment it targets, and check what it overwrites in the Dashboard first.

## Rule: scripts and agents give the CLI a closed stdin and one SQL statement
**Why:** Two CLI behaviours bit during verification (CLI 2.120.0). `supabase migration new <name>` reads stdin when it is not a terminal and waits for it, so a script or an agent shell hangs. `supabase db query` executes one statement per call, with `-f` too; a second statement fails with "cannot insert multiple commands into a prepared statement". `supabase start` and `supabase status` print JSON in an agent shell, with `PUBLISHABLE_KEY`, `SECRET_KEY`, `API_URL`, `DB_URL` and the local mail catcher URL (`MAILPIT_URL`).
**How to apply:** `supabase migration new add_x < /dev/null` in non-interactive shells. Multi-statement SQL: put it in a migration, or pipe it to `psql` against `DB_URL` (`postgresql://postgres:postgres@127.0.0.1:54322/postgres` locally). Read keys from `supabase status`, never copy them into git: the local keys are fixed per stack but look like real ones to a secret scanner.

## Rule: migrations are reviewed SQL, small and reversible by a new migration
**Why:** `db diff` and `db pull` output can contain statements you did not intend (default-privilege `grant`/`revoke`, `drop extension`). A merged migration runs against production.
**How to apply:** Read every generated file. Prefer additive steps (add nullable column, backfill, then constrain) over a single locking change. Name files by intent (`add_due_date_to_todos`). Put `enable row level security`, grants and policies in the same migration as the `create table`.

## When to deviate
- **Dashboard-only prototype with no repo:** skip the CLI until it has users; then run `db pull` once and follow this skill.
- **Self-hosted Supabase:** same migrations; keys and endpoints differ, and `supabase link` does not apply. Use `--db-url`.
- **A team already on declarative schemas:** keep it; do not churn. Make sure `pg-delta` is enabled and `schema_paths` is gone.
- **Drizzle (or another ORM) owns DDL by team decision:** then Supabase migrations hold only what the ORM cannot express (RLS, grants, functions, triggers). Document the split in the repo README.
