# Edge Function Patterns

Reference for `build-supabase-edge-function`. Facts from the Supabase Edge Functions docs checked 2026-10-09. The code on this page was type-checked and its unit test run with Deno 2.9.7 and with Deno 2.1.4 (the version the local Edge Runtime 1.77.4 reports compatibility with), against `@supabase/server` 1.9.1 and `@supabase/supabase-js` 2.117.3. It also ran on a local stack (`supabase start` + `supabase functions serve`, CLI 2.120.0): no credential returned 401, a user JWT returned 201 and wrote a row owned by that user, an empty body returned 400, a bad webhook signature returned 400, a good one returned 200 and a replay left one row, and a browser preflight was answered. The Supabase runtime is not the Deno CLI and does not type-check: type-check locally, then confirm with `serve`.

## Rule: choose the runtime by what the logic does and who calls it
**Why:** Each runtime costs something. A database function runs next to the data in one transaction and needs no network hop. A Next route shares the app's deploy, session and types. An Edge Function is a separate deploy unit with its own limits, but it is the only one that is reachable by non-Next callers and callable from inside Postgres (cron, `pg_net`). Supabase's own guidance: data-intensive work in database functions, latency-sensitive global work in Edge Functions.
**How to apply:** Use the table in the skill (step 2). Tie-break: if a Next app exists and is the only caller, write a Server Action; two pipelines for one caller is cost without benefit. Edge limits to design around (hosted): 256 MB memory, 2 s CPU time per request (async I/O does not count), wall clock 150 s on the free plan and 400 s on paid plans, request idle timeout 150 s, 20 MB bundled size, outbound ports 25 and 587 blocked. Work beyond that goes to a queue.
**Anti-example:** An Edge Function that loops over 10,000 rows with one query each. Write one SQL function and call it with `rpc`.

## Rule: two auth layers — the platform check is not authentication
**Why:** `verify_jwt` (default on) makes the platform reject requests whose `Authorization` header is not a valid JWT, before your code runs. It also accepts publishable and secret keys in either header for migration compatibility, so it does not by itself authenticate a caller that sent only an API key. Turning it off to silence a 401 removes the platform check, and then only your handler stands between the internet and the function.
**How to apply:** Leave `verify_jwt` on for functions called with a user session. Turn it off per function (`[functions.<name>] verify_jwt = false`, or `--no-verify-jwt` for `serve`/`deploy`) only for webhooks and key-authenticated service calls, and in the same change add the check in code: `withSupabase({ auth: 'secret' })`, or a signature check. User tokens go in `Authorization: Bearer`; API keys go in `apikey`, never as a bearer token (they are not JWTs).
**Anti-example:** `verify_jwt = false` and a handler with no auth check "because the function is not linked anywhere".

## Rule: user-scoped client by default; the admin client only after authorization
**Why:** `ctx.supabase` carries the caller's JWT, so RLS limits every query to what that user may do, even if the handler has a bug. `ctx.supabaseAdmin` bypasses RLS: a query on a shared table without a caller filter returns every user's rows.
**How to apply:** Use `ctx.supabase` for work on behalf of the user. Use `ctx.supabaseAdmin` for webhooks, jobs and steps that must cross policies, and then filter by the verified id (`ctx.userClaims`) or by the provider-verified entity. A named secret key per caller (`auth: 'secret:automations'`) limits a leak to that caller.

## Rule: webhooks verify the raw body, then write idempotently
**Why:** A provider signs the exact bytes it sent; parsing and re-serializing JSON changes them. Providers retry, so the same event arrives more than once. An unauthenticated endpoint that writes with the admin client is an open door.
**How to apply:** `auth: 'none'`, `verify_jwt = false`, read `await req.text()`, verify an HMAC in constant time (`crypto.subtle.verify`), return 400 on a bad signature, then upsert on the event id.

```ts
// supabase/functions/_shared/signature.ts
import { decodeHex } from 'jsr:@std/encoding@^1/hex';

const encoder = new TextEncoder();

function parseHex(hex: string) {
  try {
    return decodeHex(hex);
  } catch {
    return null; // not valid hex
  }
}

/** Verifies `hex(HMAC-SHA256(secret, body))` in constant time. */
export async function verifyHmacSha256(
  secret: string,
  body: string,
  signatureHex: string,
): Promise<boolean> {
  const signature = parseHex(signatureHex);
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify('HMAC', key, signature, encoder.encode(body));
}
```

```ts
// supabase/functions/payments-webhook/index.ts
import { withSupabase } from 'npm:@supabase/server@^1';
import { verifyHmacSha256 } from '../_shared/signature.ts';

const secret = Deno.env.get('PAYMENTS_WEBHOOK_SECRET');
if (!secret) throw new Error('PAYMENTS_WEBHOOK_SECRET is not set');

export default {
  fetch: withSupabase({ auth: 'none' }, async (req, ctx) => {
    if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });

    const body = await req.text(); // raw body: the signature covers the exact bytes
    const signature = req.headers.get('x-signature') ?? '';
    if (!(await verifyHmacSha256(secret, body, signature))) {
      return new Response('bad signature', { status: 400 });
    }

    const event = JSON.parse(body) as { id: string; type: string };
    const { error } = await ctx.supabaseAdmin
      .from('webhook_events')
      .upsert({ id: event.id, type: event.type }, { onConflict: 'id', ignoreDuplicates: true });
    if (error) return new Response('storage error', { status: 500 });
    return Response.json({ received: true });
  }),
};
```

A provider with its own SDK (Stripe): use the SDK's async verifier. Stripe on Deno needs `constructEventAsync` with `Stripe.createSubtleCryptoProvider()`; the synchronous `constructEvent` throws on this runtime. The table `webhook_events` has RLS on, no grant to `anon`/`authenticated`, and `grant select, insert, update on public.webhook_events to service_role`: with the baseline-privileges migration in place the admin client has no automatic grants either (the upsert failed until that grant existed).

## Rule: CORS only for browser callers, from one place
**Why:** Preflight failures look like network errors in the browser and cost hours. Functions called only by servers, cron or webhooks need no CORS at all.
**How to apply:** `withSupabase` answers preflight and adds the headers itself. Without it, import the SDK's list so new client headers are covered automatically (supabase-js 2.95.0 and later; the list includes the trace headers since 2.112.3), and answer `OPTIONS` yourself:

```ts
// supabase/functions/_shared/cors.ts
import { corsHeaders } from 'npm:@supabase/supabase-js@^2/cors';

export { corsHeaders };
```

Redeploy functions after upgrading the SDK so the allow-list refreshes. `Access-Control-Allow-Origin: *` is acceptable here because the credential is a bearer token in a header, not a cookie; never use it for a cookie-authenticated endpoint.

## Rule: without `@supabase/server`, verify the JWT with `getClaims`
**Why:** `@supabase/server` v1 is labelled public beta. A function that must not depend on it can do the same job with supabase-js. Decoding a JWT yourself, or calling `getSession`, trusts unverified input.
**How to apply:** Build the client with the publishable key and the caller's token in `global.headers`, verify with `getClaims(token)` (local signature check on projects with asymmetric signing keys), and use the same client for queries so RLS applies:

```ts
import { createClient } from 'npm:@supabase/supabase-js@^2';
import { corsHeaders } from '../_shared/cors.ts';

const url = Deno.env.get('SUPABASE_URL')!;
const publishableKey = (JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS')!) as Record<string, string>)['default'];

export default {
  fetch: async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });

    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer /i, '');
    if (!token) return Response.json({ error: 'unauthorized' }, { status: 401, headers: corsHeaders });

    const supabase = createClient(url, publishableKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false },
    });
    const { data, error } = await supabase.auth.getClaims(token);
    if (error || !data) return Response.json({ error: 'unauthorized' }, { status: 401, headers: corsHeaders });

    return Response.json({ userId: data.claims.sub }, { headers: corsHeaders });
  },
};
```

## Rule: secrets live in `supabase secrets`, are read once, and never start with `SUPABASE_`
**Why:** A secret in the repo is leaked forever. A secret read inside the handler fails on the first request instead of at deploy. The `SUPABASE_` prefix is reserved for what the platform injects (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, `SUPABASE_JWKS`); the Dashboard and API reject it.
**How to apply:** Local: `supabase/functions/.env`, git-ignored, loaded on `supabase start` (or `serve --env-file`). Remote: `supabase secrets set --env-file <file>` or `NAME=value`; functions read a new secret immediately, no redeploy. Setting needs the Owner or Administrator role. Limits: 100 secrets per project, 256-character names, 48 KiB each; bundle many small ones as one JSON value. A root `.env` feeds `config.toml` `env()`, not functions: a variable both need goes in both files.
**Anti-example:** Returning `Deno.env.get('KEY')` from a debug route to "check it arrived". Return `{ configured: Boolean(value) }`.

## Rule: shared code in `_shared`, few fat functions, kebab-case names
**Why:** Each function is a deploy and a cold start; many tiny functions multiply both and duplicate auth code. Folders prefixed `_` are shared and not deployed. Hyphens are the most URL-friendly name form.
**How to apply:** One function per capability area, routed by path or an `action` field, with the pure logic in modules beside it. `supabase/functions/_shared/` holds verifiers and helpers; keep clients and CORS here too. Use full `npm:`/`jsr:` specifiers in `_shared` files so they resolve regardless of which function's `deno.json` is active.

## Rule: test the pure logic, mock `fetch` for the function, serve for the smoke test
**Why:** Verifiers and business rules are pure and fast to test. The function as a whole talks to Supabase over HTTP, so replacing `globalThis.fetch` tests the real code path without changing production code. A running stack catches wiring errors (config, secrets, CORS).
**How to apply:** Tests live in `supabase/functions/tests/` (Supabase's layout; it is not a function because it has no `index.ts`). Run `deno test --allow-env supabase/functions/tests/`. Use `@std/testing/bdd` and `@std/testing/mock` for the integration style. A minimal unit test:

```ts
import { assert, assertFalse } from 'jsr:@std/assert@^1';
import { encodeHex } from 'jsr:@std/encoding@^1/hex';
import { verifyHmacSha256 } from '../_shared/signature.ts';

async function sign(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return encodeHex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)));
}

Deno.test('accepts a correct signature', async () => {
  assert(await verifyHmacSha256('s3cret', '{"id":"1"}', await sign('s3cret', '{"id":"1"}')));
});

Deno.test('rejects a tampered body, a wrong secret and non-hex input', async () => {
  const sig = await sign('s3cret', '{"id":"1"}');
  assertFalse(await verifyHmacSha256('s3cret', '{"id":"2"}', sig));
  assertFalse(await verifyHmacSha256('other', '{"id":"1"}', sig));
  assertFalse(await verifyHmacSha256('s3cret', '{"id":"1"}', 'zz'));
});
```

Add a `test` task to the repo's task runner (`task_runner` in the stack profile) so CI runs it.

## Rule: log one JSON line, never the payload
**Why:** Function logs are searchable by anyone with project access. Tokens and bodies in them are a leak. Platform limits apply: 10,000 characters per message, 100 events per 10 seconds.
**How to apply:** `console.error(JSON.stringify({ level, msg, code }))` following [logging-contract.md](../../core/_shared/logging-contract.md): fixed field names, a code or id instead of content. Return generic error bodies to callers.

## When to deviate
- **Heavy native dependencies** (image processing with `sharp`, multithreaded libraries) do not run here: use a container service or a queue worker.
- **Long jobs** over the CPU or wall-clock limit: accept the request, enqueue, and process elsewhere.
- **Self-hosted Supabase:** same code; keys and the `verify_jwt` platform check depend on your setup, so test the 401 and 201 cases explicitly.
- **A team standardised on a Hono API:** a Hono app inside one Edge Function is fine; keep the auth wrapper at the top and the same secret rules.
