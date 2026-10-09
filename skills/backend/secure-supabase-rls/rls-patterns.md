# RLS Patterns

Reference for `secure-supabase-rls`. Facts from the Supabase RLS, Securing-your-API and Storage docs, checked 2026-10-09. The SQL ran twice: against Postgres 17 with stubbed Supabase roles, then against a real local stack (CLI 2.120.0, Postgres 17.11) where the pgTAP file in `rls-test-patterns.md` passed 8 of 8 and the audit queries returned the expected rows.

## Rule: enable RLS on every table in an exposed schema, and set the grants
**Why:** A table in an exposed schema without RLS is readable and writable by any role with a grant, and the publishable key is public. Two checks run before a client touches a table: grants decide whether the role may run the operation at all, policies decide which rows. A policy does not take a grant back: a table protected only by policies still gives `anon` an insert path if the grant stays. A missing grant raises `42501` before any policy runs, so when an allowed request fails, check grants first.
**How to apply:** In the same migration as `create table`: `enable row level security`, `revoke all … from anon, authenticated`, then `grant` only the operations the app uses. Tables made in the Dashboard get RLS on by default; tables made by SQL or a migration do not.
**Anti-example:** `create table …;` with a policy added later "when the feature ships". The table is open in between, and on a preview branch it stays open.

## Rule: no automatic grants on new objects
**Why:** On existing projects a new table in `public` starts with `select, insert, update, delete` for `anon`, `authenticated` and `service_role`, and functions start with `execute`. Supabase says it is changing the platform default so that exposure becomes opt-in; until a project is on it, the migration must say so.
**How to apply:** Put this in the first migration (`baseline_privileges`), once per project. Migrations run as `postgres`, the role the docs name:

```sql
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
```

Existing objects keep their grants: revoke them per table (previous rule). With `service_role` revoked too, the admin client needs explicit grants on the tables it touches; that is intended.
**When to deviate:** Throwaway prototypes. Never for a project with users.

## Rule: one policy per operation, each scoped with `to`
**Why:** `for all` hides which operation a clause was written for, and a `using` clause is meaningless on `insert` (it needs `with check`). Without `to`, a policy applies to every role and its expression runs for `anon` too; `to authenticated` stops evaluation before the expression.
**How to apply:** `select` and `delete` take `using`; `insert` takes `with check`; `update` takes both (existing row, then resulting row). Name policies `"<table>: <who> <does what>"`. Public data: `to anon, authenticated using (true)` plus a `select`-only grant, and only for data meant to be public.
**Anti-example:**
```sql
create policy "all" on public.notes using (auth.uid() = user_id);  -- for all, to public, bare auth.uid()
```

## Rule: wrap `auth.uid()` and `auth.jwt()` in `(select …)`
**Why:** A bare function call is evaluated per row. Wrapped, Postgres plans an `initPlan` and evaluates it once per statement. The same applies to definer-function calls in a policy. It is only valid when the result does not depend on the row.
**How to apply:** `(select auth.uid()) = user_id`; `((select auth.jwt()) ->> 'aal') = 'aal2'`; `id in (select private.user_list_ids())`.
**Anti-example:** `using (auth.uid() = user_id)`.

## Rule: `auth.uid()` is null when signed out — a null compare is false, not an error
**Why:** `null = user_id` is never true, so the policy denies, which is safe. The trap is the opposite policy: `auth.uid() is distinct from owner_id` or `not (…)` over a null can allow.
**How to apply:** Keep positive checks (`= user_id`) and scope with `to authenticated`. Add `(select auth.uid()) is not null and …` where a policy inverts a comparison.

## Rule: index every column a policy filters
**Why:** Postgres evaluates the policy per candidate row, so an unindexed filter turns each read into a sequential scan. A column counts as indexed only when it is first in a btree index: a composite key `(team_id, user_id)` does not index `user_id`.
**How to apply:** `create index notes_user_id_idx on public.notes (user_id);`. For membership tables add the second column's own index. Check with `explain analyze` while impersonating the role: `set session role authenticated; set request.jwt.claims to '{"role":"authenticated","sub":"<uuid>"}';`. `Rows Removed by Filter` in the plan means a missing index.

## Rule: authorization data comes from `app_metadata` or a table — never `user_metadata`
**Why:** `raw_user_meta_data` (the JWT's `user_metadata`) can be changed by the signed-in user with `auth.updateUser`. A policy that trusts it lets users promote themselves. `raw_app_meta_data` cannot be changed by the user.
**How to apply:** Roles and tenant ids live in `app_metadata` (set with the admin client) or, better for anything revocable, in a table read through a definer function. A JWT claim is stale until the token refreshes (`jwt_expiry` default 3600 s), so a removed team member keeps access for up to an hour; a table lookup does not have that delay. Cookie-stored JWTs also must stay under about 4 KB: do not stuff claims.
**Anti-example:**
```sql
using ((select auth.jwt()) -> 'user_metadata' ->> 'role' = 'admin')   -- any user can write 'admin' into their own metadata
```

## Rule: RLS filters rows, not columns — restrict columns with grants
**Why:** A policy that lets users update their own profile row also lets them update `is_admin` or `plan` on it. Row policies cannot see which column changed.
**How to apply:** Grant update per column and revoke the table-wide privilege:
```sql
revoke update on table public.profiles from authenticated;
grant update (display_name, avatar_url) on table public.profiles to authenticated;
```
Server-controlled columns (`plan`, `role`, `owner_id` after insert) are written only by the admin client or a definer function.

## Rule: views use `security_invoker = true`
**Why:** Postgres creates views as the `postgres` user, which bypasses RLS. A view over a protected table hands out every row the table policies withhold. `security_invoker = true` (Postgres 15+) makes the view run with the caller's rights. Materialized views cannot do that: keep them out of exposed schemas, or revoke `anon`/`authenticated`.
**How to apply:**
```sql
create view public.my_notes with (security_invoker = true) as
  select id, body, created_at from public.notes;
grant select on public.my_notes to authenticated;
```
The caller also needs a grant on the underlying table.
**Anti-example:** `create view public.all_notes as select * from public.notes;` — readable by `anon` with the default grants, bypassing every policy.

## Rule: definer functions live in a non-exposed schema with a fixed `search_path`
**Why:** A `security definer` function runs with its creator's rights, so it bypasses RLS on the tables it reads; in an exposed schema it is also callable over the Data API by anyone with `execute`. An unpinned `search_path` lets a caller shadow an unqualified name with their own object and run it with the owner's privileges. RLS does not apply to functions: only `grant execute` protects them.
**How to apply:**
```sql
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create function private.is_team_member(p_team uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.team_members
    where team_id = p_team and user_id = (select auth.uid())
  );
$$;

revoke execute on function private.is_team_member(uuid) from public;
grant execute on function private.is_team_member(uuid) to authenticated;

create policy "tasks: members read" on public.tasks for select
  to authenticated using ((select private.is_team_member(team_id)));
```
`private` must not appear in `[api] schemas` (and not in the Dashboard's "Exposed schemas"). The function also breaks recursive policies (`42P17`): two tables whose policies read each other never resolve; move the lookup into a definer function. That works because the owner `postgres` has `bypassrls`; a function owned by another role, or a table with `force row level security`, stays recursive.
**Anti-example:** `create function public.is_admin() … security definer;` with no `search_path` and the default `execute` grant.

## Rule: the secret key bypasses RLS — the caller's token wins when present
**Why:** The secret key maps to `service_role`, which has `bypassrls`. A client built with the secret key but sent a user's access token runs under that user's policies; without a token it bypasses everything. A handler that queries a shared table through the admin client without filtering by the caller returns every user's rows.
**How to apply:** Use the admin client only for work that must cross policies (webhooks, jobs, admin tasks), and filter by the verified user id from the claims. Prefer the request-scoped client for anything done on a user's behalf.

## Rule: storage is RLS on `storage.objects`
**Why:** Storage denies uploads to buckets without policies. Public buckets serve objects without policies, but anyone can read them. `storage.objects` has `bucket_id`, `name`, `owner_id` and helpers such as `storage.foldername(name)`.
**How to apply:** One policy per operation, `to authenticated`, scoped by bucket and by an owner folder:
```sql
create policy "avatars: owner uploads" on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy "avatars: owner reads" on storage.objects for select
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
```
An overwrite with `upsert` needs `select` and `update` policies too. To let `anon` read an object but not list a bucket, use `storage.allow_any_operation(array['object.get_authenticated_info','object.get_authenticated'])` in the `select` policy. Bucket rows are data: create them in a migration, not through the Dashboard.

## Audit queries
Run with `pnpm supabase db query --local "<sql>"` (add `--linked` for a remote). Treat output as findings, not fixes. Replace `'public'` with each schema in `[api] schemas`.

```sql
-- Views that bypass RLS (relkind v); materialized views (m) in an exposed schema are always a finding
select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'v'
  and not coalesce((select option_value = 'true' from pg_options_to_table(c.reloptions) where option_name = 'security_invoker'), false);

-- Definer functions in an exposed schema, or without a pinned search_path
select n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef and (n.nspname = 'public'
  or not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'));

-- Client roles holding table grants (compare with what the app needs)
select table_name, grantee, string_agg(privilege_type, ',') from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon', 'authenticated') group by 1, 2 order by 1, 2;

-- Policies that evaluate auth.uid() per row (heuristic: review each hit)
select tablename, policyname from pg_policies
where (qual ~* 'auth\.uid\(\)' and qual !~* 'select auth\.uid\(\)') or (with_check ~* 'auth\.uid\(\)' and with_check !~* 'select auth\.uid\(\)');

-- Storage policies in force
select policyname, cmd, roles from pg_policies where schemaname = 'storage' and tablename = 'objects';
```

The CLI's advisors run the same lints as the Dashboard. On a local stack with a definer view and a table without RLS, both granted to `anon`, `supabase db advisors --local --type security` reported two ERRORs: `security_definer_view` (lint 0010) and `rls_disabled_in_public` (0013). The same objects with no grant to an API role were not reported: the advisor flags what the API exposes, so revoking default grants hides a mistake without fixing it. Fix the object, not only the grant. `--fail-on error` exits non-zero when an ERROR is present (checked: exit 1), which is what CI needs. Read the **Performance Advisor** too (`--type performance`): it reports unindexed foreign keys, tables without a primary key and multiple permissive policies. Re-run after every policy change.

`supabase db query` runs one statement per call: a second statement fails with "cannot insert multiple commands into a prepared statement", also from `-f`. Send multi-statement SQL through `psql` (`docker exec -i supabase_db_<project_id> psql -U postgres`) or run the audit queries one at a time.

## When to deviate
- **Server-only tables** (job queues, audit logs): no grant to `anon`/`authenticated`; RLS stays on as a backstop and the admin client or a definer function does the work.
- **The Data API is off** (the app only talks to Postgres through its own server): RLS is still defence in depth; skip the per-operation role policies only if no client library ever reaches the database.
- **Public reference data:** `to anon, authenticated using (true)` with a select-only grant is correct. Write it deliberately and test it.
- **Custom JWT claims for hot paths:** an `app_metadata` role claim is acceptable for permissions that may lag by `jwt_expiry` (for example a plan tier). Not for revocation.
