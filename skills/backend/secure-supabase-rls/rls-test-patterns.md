# RLS Test Patterns

Reference for `secure-supabase-rls`, step 6. pgTAP runs through `supabase test db` against the local stack; each file runs in its own transaction and rolls back. Pattern follows the Supabase RLS guide (checked 2026-10-09). The example file below passed (`Result: PASS`, 8 tests) on a local stack with the two migrations from `secure-supabase-rls`.

## Rule: one test file per table, named `<table>_rls.test.sql`
**Why:** A policy nobody tested is a guess. A file per table makes a missing test visible in review (`ls supabase/tests`).
**How to apply:** `pnpm supabase test new notes_rls.test`. Keep files under `supabase/tests/`. Use fixed UUIDs for users, inserted into `auth.users`, and invented data only.

## Rule: switch role and identity with `set local`
**Why:** The API request runs as `anon` or `authenticated` with the user id in the JWT claims. `set local` reverts at the end of the transaction, so one test cannot leak into the next.
**How to apply:** `set local role authenticated; set local request.jwt.claim.sub = '<uuid>';`. A policy that reads other claims (`auth.jwt() ->> 'aal'`, `app_metadata`) needs `set local request.jwt.claims = '{"role":"authenticated","sub":"<uuid>","app_metadata":{…}}';` instead. Switch back with `reset role` before inserting fixtures that the test role may not insert.

## Rule: match the assertion to how the request is denied
**Why:** Postgres signals a denial in three ways, and only two raise an error. An assertion of the wrong kind passes for the wrong reason.

| Denied by | Postgres | Assert with |
|---|---|---|
| A missing grant | raises `42501` | `throws_ok` |
| A `with check` violation | raises `42501` | `throws_ok` |
| A `using` clause filtering the row out | no error, zero rows | `is_empty` on the statement with `returning`, then a read proving the row is intact |

**How to apply:** `throws_ok($$…$$, '42501', null, 'description')`. For a denied `update` or `delete`: `is_empty($$update notes set body = 'x' returning id$$, 'stranger updates nothing')`, followed by `results_eq` on the owner's row.
**Anti-example:** `lives_ok($$update notes set body = 'x'$$)` as proof that an update is allowed. It passes when the update matched zero rows. Add `returning` and assert the value.

## Rule: test allow and deny for each operation and each actor
**Why:** The bugs are in the cells you skipped: `anon` can insert, a stranger can delete, an owner cannot update their own row.
**How to apply:** Matrix per table: `select`, `insert`, `update`, `delete` × `anon`, owner, stranger (and member vs non-member for tenant tables). Pair every denied write with an owner-side read of the row it targeted; scope that read to the row, so the file does not break when the table grows. Do the owner's `delete` last so earlier cases still have a row.

```sql
begin;
select plan(8);

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'owner@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'stranger@example.com');

set local role anon;
select throws_ok($$select * from public.notes$$, '42501', null, 'anon cannot read notes');

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select results_eq(
  $$insert into public.notes (body) values ('mine') returning body$$,
  array['mine'], 'owner inserts a note');
select results_eq(
  $$select body from public.notes$$, array['mine'], 'owner reads the note');

set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select is_empty($$select * from public.notes$$, 'stranger reads nothing');
select is_empty($$update public.notes set body = 'x' returning id$$, 'stranger updates nothing');
select is_empty($$delete from public.notes returning id$$, 'stranger deletes nothing');
select throws_ok(
  $$insert into public.notes (user_id, body) values ('11111111-1111-1111-1111-111111111111', 'forged')$$,
  '42501', null, 'stranger cannot insert a note for the owner');

set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select results_eq(
  $$select body from public.notes$$, array['mine'], 'the denied writes left the owner row intact');

select * from finish();
rollback;
```

## Rule: test views, definer functions and column grants too
**Why:** These are the layers a table test does not touch. A view without `security_invoker`, or a definer function granted to `public`, passes every table test.
**How to apply:** Views: as a stranger, `select` from the view and `is_empty`. Functions: `select ok(not has_function_privilege('anon', 'private.is_team_member(uuid)', 'execute'), …)`. Columns: `throws_ok($$update public.profiles set plan = 'pro'$$, '42501', null, 'owner cannot change plan')`. Cross-table checks: `select tests.rls_enabled('public')` from `supabase-test-helpers` fails when any table in the schema lacks RLS; install it through dbdev per the Supabase "Advanced pgTAP testing" guide if you want that single assertion.

## When to deviate
- **Many tables, same shape:** generate the file from a template, but keep one file per table so failures name the table.
- **Policies that depend on time or external state:** inject the state in the fixture (`insert`) rather than mocking functions.
- **No Docker in CI:** run the tests against a Supabase preview branch only if you accept that fixtures write to a real (preview) database; otherwise fix CI first.
