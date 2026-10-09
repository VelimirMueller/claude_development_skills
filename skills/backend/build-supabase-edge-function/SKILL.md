---
name: build-supabase-edge-function
description: Use when logic must run server-side next to Supabase — a webhook, a cron or database-triggered job, a third-party call with secrets, or an API for non-Next clients — and you must choose and build an Edge Function with caller auth, CORS, secrets and tests.
---

# Build a Supabase Edge Function

## 1. Audit current state

Read `.claude/stack-profile.md` (`backend.track`, `frontend.meta`, `hosting`, `observability`). Then:

```bash
ls supabase/functions 2>/dev/null; grep -n "\[functions" -A3 supabase/config.toml
grep -rn "verify_jwt" supabase/config.toml supabase/functions 2>/dev/null
grep -rln "SUPABASE_SECRET\|service_role\|sb_secret_" supabase/functions 2>/dev/null     # admin use: check each one filters by caller
git check-ignore supabase/functions/.env || echo "supabase/functions/.env is NOT ignored"
ls src/app/api src/server 2>/dev/null                                                    # a Next backend already exists?
```

Record: functions with `verify_jwt = false` and no signature or key check, admin queries without a caller filter, secrets read inline instead of at module top, CORS headers hard-coded.

## 2. Decide what to do

Pick the runtime for the logic first. Reasons in [edge-function-patterns.md](./edge-function-patterns.md):

| Logic | Put it in |
|---|---|
| Set-based data work, multi-table transaction, trigger, anything that is mostly SQL | **Database function** (`supabase.rpc`), private schema if definer ([secure-supabase-rls](../secure-supabase-rls/SKILL.md)) |
| Called only by your Next app, same deploy, needs the session | **Next Server Action / route handler** ([build-nextjs-backend](../build-nextjs-backend/SKILL.md)) |
| Called by something that is not the Next app: webhook, mobile app, Postgres cron/`pg_net`, another service | **Edge Function** |
| No other backend exists (SPA or mobile on Supabase) | **Edge Function** for every privileged step |

Existing function covers the case → extend it ("fat functions": few, routed by path or action). Otherwise continue.

## 3. Detect the caller, pick the auth mode

| Caller | `withSupabase` mode | `verify_jwt` (config.toml) | Client to use |
|---|---|---|---|
| Signed-in user (`supabase.functions.invoke`) | `{ auth: 'user' }` | `true` (default) | `ctx.supabase` (RLS) |
| Cron, worker, other function (secret key in `apikey`) | `{ auth: 'secret' }` | `false` | `ctx.supabaseAdmin` |
| Your own client apps, anonymous | `{ auth: 'publishable' }` | `false` | `ctx.supabase` (anon RLS) |
| External provider with a signature | `{ auth: 'none' }` + verify signature | `false` | `ctx.supabaseAdmin` after verifying |
| User or service | `{ auth: ['user', 'secret'] }` | `false` | switch on `ctx.authMode` |

`@supabase/server` (the `withSupabase` wrapper) is v1 and still labelled public beta; the manual fallback is in [edge-function-patterns.md](./edge-function-patterns.md). Versions: [stack-versions.md](../_shared/stack-versions.md).

## 4. Install only what's missing

Supabase CLI and Docker (for `supabase functions serve`). Deno is optional but gives editor types and `deno test`. No install step per function: dependencies are `npm:` / `jsr:` specifiers with a pinned major, for example `npm:@supabase/server@^1`. Add a per-function `deno.json` only when a function needs its own import map.

```bash
pnpm supabase functions new create-note     # kebab-case; creates supabase/functions/create-note/index.ts
```

## 5. Generate the handler

```ts
// supabase/functions/create-note/index.ts
import { withSupabase } from 'npm:@supabase/server@^1';
import { z } from 'npm:zod@^4';

const Body = z.object({ body: z.string().trim().min(1).max(2000) });

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    const parsed = Body.safeParse(await req.json().catch(() => null));
    if (!parsed.success) {
      return Response.json({ error: z.flattenError(parsed.error).fieldErrors }, { status: 400 });
    }

    // ctx.supabase runs under the caller's RLS; user_id defaults to auth.uid().
    const { data, error } = await ctx.supabase
      .from('notes')
      .insert({ body: parsed.data.body })
      .select('id, body')
      .single();

    if (error) {
      console.error(JSON.stringify({ level: 'error', msg: 'insert failed', code: error.code }));
      return Response.json({ error: 'could not create note' }, { status: 500 });
    }
    return Response.json(data, { status: 201 });
  }),
};
```

`withSupabase` checks the credential, builds the clients and answers CORS preflight. Rules the handler keeps:

- Parse input with Zod before use; return a typed `{ error }` body with the right status.
- `ctx.supabaseAdmin` bypasses RLS: filter by `ctx.userClaims` id or use `ctx.supabase`.
- Never echo secrets, tokens or raw provider errors; log a code, not the payload.
- Pure logic goes in its own module (`pricing.ts`) so tests do not need a server.

Webhook, signature check and idempotent write: [edge-function-patterns.md](./edge-function-patterns.md), "Webhooks".

## 6. Wire config, secrets, callers

`supabase/config.toml`, per function:

```toml
[functions.payments-webhook]
verify_jwt = false          # the provider sends no Supabase token; the handler verifies its signature
```

Secrets (names must not start with `SUPABASE_`; Supabase injects `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, `SUPABASE_JWKS`):

```bash
# local: supabase/functions/.env (git-ignored), read on `supabase start`
printf 'PAYMENTS_WEBHOOK_SECRET=local-dev-only\n' >> supabase/functions/.env
# remote: from an env file kept outside git, or one name at a time
pnpm supabase secrets set --env-file .env.production-secrets
pnpm supabase secrets list
```

Read secrets once at module top and throw when missing (fail fast). Shared code lives in `supabase/functions/_shared/` (folders starting with `_` are not deployed as functions). Browser callers use `supabase.functions.invoke('create-note', { body })`; it sends the session JWT and the publishable key.

## 7. Test

```bash
deno test --allow-env supabase/functions/tests/        # unit tests of pure logic and verifiers
pnpm supabase start && pnpm supabase functions serve create-note
```

Test file pattern and the `fetch`-mocking integration approach: [edge-function-patterns.md](./edge-function-patterns.md), "Tests".

## 8. Deploy

```bash
pnpm supabase functions deploy create-note            # one function; no name = all
```

With the GitHub integration, a merge deploys changed functions; with CI, run `supabase functions deploy` after `db push` (the function may depend on the migration). Deploy falls back to server-side bundling when Docker is absent (`--use-api`).

## 9. Verify

```bash
TOKEN=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H 'content-type: application/json' -d '{"email":"owner@example.com","password":"…"}' | jq -r .access_token)
curl -i "$SUPABASE_URL/functions/v1/create-note" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -d '{"body":"hi"}'                                                   # expect 401: no user JWT
curl -i "$SUPABASE_URL/functions/v1/create-note" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $TOKEN" -d '{"body":"hi"}'                 # expect 201 and the row
curl -i "$SUPABASE_URL/functions/v1/create-note" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $TOKEN" -d '{"body":""}'                   # expect 400 with fieldErrors
```

Use the local stack (`http://127.0.0.1:54321`, keys from `supabase status`) first. Expected: 401 (body code `UNUSABLE_CREDENTIAL`: an API key alone never satisfies `auth: 'user'`, whichever header carries it), 201, 400 as annotated; a webhook returns 400 for a bad signature and 200 twice for the same signed event, leaving one row.

## References
- [edge-function-patterns.md](./edge-function-patterns.md) — runtime choice, auth layers, webhooks, CORS, secrets, tests, limits.
- [../secure-supabase-rls/SKILL.md](../secure-supabase-rls/SKILL.md) — policies the user-scoped client depends on.
- [../_shared/config.md](../_shared/config.md), [../_shared/stack-versions.md](../_shared/stack-versions.md).
- [../../core/_shared/logging-contract.md](../../core/_shared/logging-contract.md), [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md).
