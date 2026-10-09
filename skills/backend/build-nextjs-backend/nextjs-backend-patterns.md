# Next.js Backend Patterns

Reference for `build-nextjs-backend`. Facts from the Next.js 16.4 docs (Data Security, Authentication, Server Actions, Proxy, Error Handling, Environment Variables) checked 2026-10-09. All code here type-checks and builds on Next 16.4.0, React 19.3.0, Zod 4.6.5, `@supabase/ssr` 0.12.7 and TypeScript 7.0.2; behaviours marked "run" were exercised against a production build (`next start`) with a stub API.

## Rule: one server-only data access layer, authorization on every call
**Why:** Server Components move data access next to rendering, so a database call can appear in any component and any prop can carry a whole row to the browser. A single `server-only` layer gives one place to authorize, one place to shape output and one place for auditors to read. Next recommends a Data Access Layer for new projects and says to pick one data-fetching approach and not mix them.
**How to apply:** `src/server/data/<domain>.ts`, first line `import 'server-only'`. Each exported function: (1) establish the viewer (`requireViewer()`), (2) query with the request-scoped client so RLS applies, or filter by `viewer.id` when there is no RLS, (3) return a DTO with only the fields the UI renders. Pages and actions call the DAL; nothing else imports the database or the SDK. Only the DAL and the env modules read `process.env` secrets. Without RLS, the actor is part of every query:

```ts
import { and, eq } from 'drizzle-orm';

export async function getNote(id: string): Promise<NoteDTO> {
  const viewer = await requireViewer();
  const [row] = await db.select().from(notes).where(and(eq(notes.id, id), eq(notes.userId, viewer.id)));
  if (!row) notFound();
  return { id: row.id, body: row.body, createdAt: row.createdAt.toISOString() };
}
```
**Anti-example:** `const note = await supabase.from('notes').select('*')` inside a page, then `<NoteCard note={note} />` where `NoteCard` is a client component: every column crosses to the browser, and the page-level check is the only guard.

## Rule: a Server Action is a public POST endpoint
**Why:** An exported `'use server'` function can be called with a direct POST, whether or not your UI uses it. Next hides it behind an encrypted action ID and removes unused actions from the client bundle, but the docs say to treat actions as reachable and verify in each one: a page-level check does not extend to the actions defined within it, and encryption is not authorization. Origin is compared with Host (or `X-Forwarded-Host`), which blocks most cross-site form posts; `serverActions.allowedOrigins` widens that list for proxies.
**How to apply:** Every action does four things in order: authenticate (`getViewer()`), validate (Zod), authorize (the DAL, on the specific resource, not only "is logged in"), act. Then return a typed result. Keep the action thin; the DAL holds the logic.
**Anti-example:** `export async function deletePost(id: string) { await db.delete(posts).where(eq(posts.id, id)) }` — any signed-in user, or anyone, deletes any post (IDOR).

## Rule: expected failures are return values; `redirect` and `notFound` must escape any `try`
**Why:** `useActionState` renders a returned value; a thrown error goes to the error boundary and loses the form state. `redirect()` and `notFound()` work by throwing, so a `catch` that swallows everything turns a redirect into a silent "failed".
**How to apply:** One result type for all actions; failures carry a code and a safe message, never an upstream error string. In `catch`, call `unstable_rethrow(error)` first. Use `redirect()` after the `try`.

```ts
// src/libs/action-result.ts
/** What every Server Action returns. Expected failures are values, not exceptions. */
export type ActionResult<T = null> =
  | { ok: true; data: T }
  | {
      ok: false;
      code: 'unauthenticated' | 'invalid' | 'failed';
      /** Safe to show to the user. Never an upstream error message. */
      message?: string;
      fieldErrors?: Record<string, string[] | undefined>;
    };
```

The client side of the same contract:

```tsx
// src/features/notes/NoteForm.tsx
'use client';

import { useActionState } from 'react';
import { createNoteAction } from './actions';

export function NoteForm() {
  const [state, formAction, pending] = useActionState(createNoteAction, null);
  const bodyErrors = state && !state.ok ? state.fieldErrors?.body : undefined;

  return (
    <form action={formAction}>
      <label htmlFor="body">Note</label>
      <textarea id="body" name="body" required maxLength={2000} />
      {bodyErrors && <p role="alert">{bodyErrors.join(' ')}</p>}
      {state && !state.ok && state.code === 'failed' && <p role="alert">Could not save the note.</p>}
      <button type="submit" disabled={pending}>Save</button>
    </form>
  );
}
```

## Rule: validate every input at the edge — form data, params, search params, headers
**Why:** All of it is attacker-controlled. `searchParams.isAdmin === 'true'` as an authorization check is a vulnerability, and dynamic route segments (`[id]`) are user input too.
**How to apply:** `schema.safeParse(...)` at the top of each action and route handler; `z.flattenError(error).fieldErrors` for the response. Zod 4 spellings: `z.email()`, `z.url()`, `z.uuid()`, `z.coerce.number()` (the older `error.flatten()` still works but is deprecated). Check ownership against the database, not against a hidden form field.

## Rule: revalidate after the write, in the action
**Why:** A mutation that does not invalidate leaves the UI showing the old state. Per-user data read through the cookie-bound client is never in the server cache, so `refresh()` (re-render the current route) is enough; tagged public data needs `updateTag` or `revalidateTag`. Details: [nextjs-caching-patterns.md](./nextjs-caching-patterns.md).
**How to apply:** Last statement of the success path; never during render (Next blocks setting cookies and revalidating inside render on purpose).

## Rule: route handlers are for webhooks and non-Next clients — verify, then write idempotently
**Why:** A provider calls from outside your app: no session, no action ID, no Origin check (that comparison is documented for Server Actions). The signature is the only credential, and it covers the exact bytes sent. Providers retry, so a replay must be harmless. Only `GET` handlers prerender under Cache Components; `POST` runs per request.
**How to apply:** `src/app/api/webhooks/<provider>/route.ts` exporting `POST`. Read `await request.text()` (never `request.json()` first), verify an HMAC with `timingSafeEqual`, return 400 on a bad signature, upsert on the event id, return 5xx when storage fails so the provider retries, then invalidate:

```ts
// src/app/api/webhooks/payments/route.ts
import { createHmac, timingSafeEqual } from 'node:crypto';
import { revalidateTag } from 'next/cache';
import { supabaseAdmin } from '@/libs/supabase/admin';
import { serverEnv } from '@/server/env';

function validSignature(body: string, signatureHex: string): boolean {
  const expected = createHmac('sha256', serverEnv.PAYMENTS_WEBHOOK_SECRET).update(body).digest();
  const received = Buffer.from(signatureHex, 'hex');
  return received.length === expected.length && timingSafeEqual(received, expected);
}

export async function POST(request: Request) {
  const body = await request.text(); // raw bytes: the signature covers exactly these
  if (!validSignature(body, request.headers.get('x-signature') ?? '')) {
    return new Response('bad signature', { status: 400 });
  }

  const event = JSON.parse(body) as { id: string; type: string };
  const { error } = await supabaseAdmin
    .from('webhook_events')
    .upsert({ id: event.id, type: event.type }, { onConflict: 'id', ignoreDuplicates: true });
  if (error) return new Response('storage error', { status: 500 }); // the provider retries

  revalidateTag('posts', 'max'); // stale-while-revalidate for everyone reading the 'posts' cache
  return Response.json({ received: true });
}
```

Run: a bad signature returned 400 and a correct HMAC returned 200. A provider with an SDK (Stripe): use its verifier on the raw text. A route handler for your own mobile or partner clients authenticates with a bearer token (`Authorization`), not a cookie, so it needs no CSRF defence; add CORS headers only for browser callers on other origins.
**Anti-example:** `const event = await request.json(); await verify(event, signature)` — the re-serialized body no longer matches the signature.

## Rule: validate env at startup; only the env modules read `process.env`
**Why:** A missing variable should fail the boot, not the first request. `NEXT_PUBLIC_*` values are inlined into the browser bundle at `next build` and frozen: a build promoted from staging to production keeps staging's values. Inlining only happens for literal `process.env.NEXT_PUBLIC_NAME` reads: `const env = process.env; env.NEXT_PUBLIC_X` is not inlined and is `undefined` in the browser.
**How to apply:** Two modules. Public values, literal reads:

```ts
// src/libs/env.client.ts
import { z } from 'zod';

const schema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(1),
  NEXT_PUBLIC_SITE_URL: z.url(),
});

// Literal reads on purpose: Next inlines `process.env.NEXT_PUBLIC_X` at build time,
// but not `process.env` passed around as an object.
const parsed = schema.safeParse({
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
});

if (!parsed.success) {
  throw new Error(`Invalid public env: ${JSON.stringify(z.flattenError(parsed.error).fieldErrors)}`);
}

/** Public values only. Safe to import from client code. */
export const clientEnv = parsed.data;
```

Secrets, `server-only`; importing it from a client module is a build error:

```ts
// src/server/env.ts
import 'server-only';
import { z } from 'zod';

const schema = z.object({
  SUPABASE_SECRET_KEY: z.string().startsWith('sb_secret_'), // rejects a pasted legacy service_role JWT
  PAYMENTS_WEBHOOK_SECRET: z.string().min(16),
});

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  throw new Error(`Invalid server env: ${JSON.stringify(z.flattenError(parsed.error).fieldErrors)}`);
}

/** Secrets. `server-only` makes importing this from a client module a build error. */
export const serverEnv = parsed.data;
```

Build once per environment when a public value differs. CI needs dummy values for every variable the build touches (the server module parses at import). `startsWith('sb_secret_')` rejects a pasted legacy `service_role` JWT.
**Anti-example:** `process.env.SUPABASE_SECRET_KEY!` in a component file: `undefined` in the browser, and one `NEXT_PUBLIC_` prefix away from public.

## Rule: error boundaries exist at the root and never show server messages
**Why:** Server errors are redacted in production and carry a `digest` that matches the server log line; the message would leak internals if shown. A missing boundary shows a blank error page. `not-found` is the correct response for a row the viewer may not see: a 403 would confirm it exists.
**How to apply:** `app/error.tsx` (client component; `retry()` re-fetches and re-renders the segment, stable since 16.3), `app/global-error.tsx` (replaces the root layout, so it renders `<html>` and `<body>`), `app/not-found.tsx`. Log server-side with structured JSON ([logging-contract.md](../../core/_shared/logging-contract.md)).

```tsx
// src/app/error.tsx
'use client';

import { useEffect } from 'react';

export default function ErrorBoundary({
  error,
  retry,
}: {
  error: Error & { digest?: string };
  retry: () => void;
}) {
  useEffect(() => {
    // `digest` links this to the server log line; the message itself is redacted in production.
    console.error({ digest: error.digest });
  }, [error]);

  return (
    <main>
      <h1>Something went wrong</h1>
      <button type="button" onClick={() => retry()}>Try again</button>
    </main>
  );
}
```

```tsx
// src/app/global-error.tsx
'use client';

export default function GlobalError({ retry }: { error: Error & { digest?: string }; retry: () => void }) {
  return (
    <html lang="en">
      <body>
        <h1>Something went wrong</h1>
        <button type="button" onClick={() => retry()}>Try again</button>
      </body>
    </html>
  );
}
```

## Rule: `proxy.ts` redirects and refreshes; it is never the only check
**Why:** Proxy runs before the request completes, on the Node.js runtime in Next 16 (setting `runtime` there throws), and Next states it is not meant for slow data fetching or full authorization. `fetch` cache options have no effect in it, and `revalidateTag` cannot be called from it. A matcher mistake, a new route outside the matcher or a direct call to an action all bypass it.
**How to apply:** Session refresh plus optimistic redirects to `/login`. Keep one file at `src/proxy.ts`; split logic into modules it imports. Every DAL call still authorizes. Simple static redirects belong in `redirects` in `next.config.ts`. Supabase specifics: [set-up-nextjs-supabase-auth](../set-up-nextjs-supabase-auth/SKILL.md).
**Anti-example:** Protecting `/admin` only through the matcher, with no check in `getAllUsers()`.

## Rule: no mutations while rendering, and GET never changes state
**Why:** Prefetching, crawlers and retries issue GETs. Logging out via `?logout=1` or inserting a row in a page body is a CSRF and side-effect bug. Next blocks cookie writes and revalidation in render for this reason.
**How to apply:** Mutations are actions (POST) or `POST`/`PUT`/`DELETE` handlers. Sign-out is a form posting to an action.

## Rule: rate-limit actions that cost money or send mail
**Why:** An action is a public endpoint; an unbounded `sendInvite` is a spam relay. In-memory counters do not work across serverless instances.
**How to apply:** Limit at a shared layer: the platform firewall, or a counter in Redis or Postgres keyed by viewer id and IP, checked inside the DAL function before the side effect. Supabase Auth already rate-limits its own email and sign-in endpoints.

## When to deviate
- **An existing large backend (REST or GraphQL) behind Next:** keep calling it with `fetch` from Server Components and forward the session cookie or token; the DAL becomes a thin client that still returns DTOs. Zero-trust: that API authorizes, not Next.
- **A prototype:** component-level queries are acceptable for a throwaway; they still use the request-scoped client so RLS protects the data.
- **Several domains in one action file:** split by feature (`features/<domain>/actions.ts`) when the file passes about 150 lines.
- **Edge runtime:** not available with Cache Components, and `proxy.ts` runs on Node. Move any `runtime = 'edge'` route to Node.
