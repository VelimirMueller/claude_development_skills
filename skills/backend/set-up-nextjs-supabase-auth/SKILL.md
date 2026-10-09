---
name: set-up-nextjs-supabase-auth
description: Use when adding or fixing Supabase Auth in a Next.js 16 App Router app — @supabase/ssr cookie clients, session refresh in proxy.ts, verified getClaims() on the server, protected routes, PKCE callback and email-link routes, and sign-in by password, magic link or OAuth.
---

# Set Up Next.js + Supabase Auth

The session lives in httpOnly cookies, is refreshed in `proxy.ts`, and is **verified** on the server with `getClaims()`. Auth is server-side only: Server Actions and route handlers sign in, sign out and exchange the PKCE code, so JavaScript never reads a token. Redirects are UX; Postgres RLS is the authorization ([secure-supabase-rls](../secure-supabase-rls/SKILL.md)).

## 1. Audit current state

Read `.claude/stack-profile.md` (`frontend.meta: next`, `backend.track`). Then:

```bash
grep -n '"next"\|@supabase' package.json; ls middleware.ts src/middleware.ts proxy.ts src/proxy.ts 2>/dev/null
grep -rn "auth-helpers\|createClientComponentClient\|createServerComponentClient" src 2>/dev/null          # deprecated package
grep -rn "getSession()" src --include=*.ts --include=*.tsx | grep -v "libs/supabase"                       # server use = trusting the cookie
grep -rn "createClient(" src | grep -v "src/libs/supabase"                                                 # clients outside the seam
ls src/app/auth src/libs/supabase src/server/auth.ts 2>/dev/null
grep -n "site_url\|additional_redirect_urls\|\[auth.email.template" supabase/config.toml
```

Findings: `getSession()` or `getUser()` results trusted for authorization without verification, a Supabase client in a module variable, `middleware.ts` on Next 16, the secret key in an auth path, an unvalidated `next` redirect.

## 2. Decide what to do

- No `@supabase/ssr` → full setup (steps 4–8).
- Clients exist, no proxy refresh → add the proxy (step 6); random sign-outs follow without it.
- `getSession()` on the server → replace with `getViewer()` (step 5).
- Everything present and the checks in step 9 pass → "already in place".

## 3. Detect the sign-in methods

From existing code and `supabase/config.toml` (`[auth.external.*]`, `[auth.email]`). If nothing says which methods the app needs, ask one question: password, magic link, OAuth provider, or a mix. Each is a short block in [auth-flows.md](./auth-flows.md); install none you do not need. Next ≤ 15: the file is `middleware.ts` and the export `middleware`; the body is identical.

## 4. Install only what's missing

```bash
pnpm add @supabase/supabase-js @supabase/ssr server-only zod
```

Env (public prefix is fine: both values are public by design) and the validated env seam: [set-up-supabase](../set-up-supabase/SKILL.md), [nextjs-backend-patterns.md](../build-nextjs-backend/nextjs-backend-patterns.md) "Env". Add `NEXT_PUBLIC_SITE_URL` (the canonical origin): redirects are built from it, never from the `Host` header.

## 5. Generate the seams

`src/libs/supabase/admin.ts`: as in [set-up-supabase](../set-up-supabase/SKILL.md). There is no browser client for auth — sign-in and sign-out are Server Actions. The forced cookie options, and the per-request server client:

```ts
// src/libs/supabase/cookies.ts
import type { CookieOptions } from '@supabase/ssr';

/** Forced on every cookie the server client writes. Session cookies are httpOnly; see supabase-auth-patterns.md. */
export const AUTH_COOKIE_OPTIONS: CookieOptions = {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'lax',
  path: '/',
};
```

```ts
// src/libs/supabase/server.ts
import 'server-only';
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { clientEnv } from '@/libs/env.client';
import type { Database } from './database.types';
import { AUTH_COOKIE_OPTIONS } from './cookies';

export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    clientEnv.NEXT_PUBLIC_SUPABASE_URL,
    clientEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookieOptions: AUTH_COOKIE_OPTIONS,
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, { ...options, ...AUTH_COOKIE_OPTIONS });
            }
          } catch {
            // Called from a Server Component, which cannot write cookies.
            // Safe to ignore: proxy.ts refreshes the session on every request.
          }
        },
      },
    },
  );
}
```

The verified viewer, used by every DAL function and action:

```ts
// src/server/auth.ts
import 'server-only';
import { cache } from 'react';
import { redirect } from 'next/navigation';
import { createClient } from '@/libs/supabase/server';

export type Viewer = { id: string; email: string | null };

export const getViewer = cache(async (): Promise<Viewer | null> => {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims(); // verifies the signature on every call
  if (error || !data) return null;
  const { sub, email } = data.claims;
  return { id: sub, email: typeof email === 'string' ? email : null };
});

export async function requireViewer(): Promise<Viewer> {
  const viewer = await getViewer();
  if (!viewer) redirect('/login');
  return viewer;
}
```

`getClaims()` for identity, `getUser()` when a revoked session must be caught (password change, payments, account deletion), never `getSession()` on the server: [supabase-auth-patterns.md](./supabase-auth-patterns.md).

## 6. Wire the proxy, routes and sign-in

- `src/proxy.ts` plus `src/libs/supabase/proxy.ts` (`updateSession`): refreshes the session, forwards the new cookies to the request and the response, redirects anonymous users from `PROTECTED_PREFIXES` to `/login`. Code and the five rules for it: [auth-flows.md](./auth-flows.md), "Proxy".
- `src/app/auth/callback/route.ts`: OAuth PKCE code exchange. `src/app/auth/confirm/route.ts`: email-link `token_hash` verification. Both redirect to a configured origin and to a sanitized `next`.
- `src/features/auth/actions.ts`: `signInWithPasswordAction`, `signInWithMagicLinkAction`, `signInWithOAuthAction`, `signOutAction` (`scope: 'local'`). Login form: `src/features/auth/LoginForm.tsx`.
- `supabase/config.toml`: `site_url`, `additional_redirect_urls` (exact `https://<app>/auth/callback` in production, `http://localhost:3000/**` for dev), the `magic_link` template pointing at `/auth/confirm`, provider secrets via `env()`.

## 7. Protect routes in three layers

1. `proxy.ts`: optimistic redirect for anonymous visitors (fast, UX only).
2. The DAL: `requireViewer()` at the top of every data function, `getViewer()` at the top of every action ([build-nextjs-backend](../build-nextjs-backend/SKILL.md)).
3. Postgres RLS: the policy that decides which rows the verified user may touch.

A page needs no check of its own beyond reading through the DAL. With Cache Components, the component that calls `getViewer()` sits behind `<Suspense>` and is never inside `'use cache'`.

## 8. Test the pure parts

Unit-test `safeNextPath` (open-redirect cases) and the action validation; sign-in itself is covered end to end against the local stack. Test file: [auth-flows.md](./auth-flows.md), "Tests".

## 9. Verify

`typecheck` is `tsc --noEmit` in a Next.js app (one tsconfig); add `"typecheck": "tsc --noEmit"` to package.json if it is missing.

```bash
pnpm typecheck && pnpm build
pnpm supabase start                                   # local Auth + a local mail catcher (URL printed by `start`)
curl -si http://localhost:3000/notes | head -3        # expect 307 → /login?next=%2Fnotes
curl -si 'http://localhost:3000/auth/callback?code=bad' | grep -i location   # expect …/login?error=auth
curl -si 'http://localhost:3000/auth/confirm?token_hash=x&type=bogus' | grep -i location   # expect …/login?error=link
```

Scripted end-to-end check with a real session (local stack; the admin call needs the secret key from `supabase status`): create a user, mint a magic-link token, hit the confirm route, then call a protected page with the cookie jar.

```bash
API=http://127.0.0.1:54321
curl -s -X POST $API/auth/v1/admin/users -H "apikey: $SECRET" -H "Authorization: Bearer $SECRET" \
  -H 'content-type: application/json' -d '{"email":"owner@example.com","email_confirm":true}' >/dev/null
TH=$(curl -s -X POST $API/auth/v1/admin/generate_link -H "apikey: $SECRET" -H "Authorization: Bearer $SECRET" \
  -H 'content-type: application/json' -d '{"type":"magiclink","email":"owner@example.com"}' | jq -r .hashed_token)
curl -si -c jar.txt "http://localhost:3000/auth/confirm?token_hash=$TH&type=magiclink" > confirm.txt
grep -i '^location\|^set-cookie' confirm.txt | cut -c1-80
grep -i '^set-cookie' confirm.txt | grep -q 'sb-.*HttpOnly' && echo "HttpOnly OK"
curl -s -o /dev/null -w '%{http_code}\n' -b jar.txt http://localhost:3000/notes      # expect 200, not 307
```

Expected: a redirect to `/`, a `set-cookie: sb-…-auth-token=…; HttpOnly; SameSite=Lax`, then 200 on `/notes` (the proxy and `getViewer()` accepted the session; RLS filtered the data). Every `sb-*` cookie carries `HttpOnly` — the `grep` above fails loudly otherwise. This ran against Next 16.4.0 and CLI 2.120.0. Then sign in with each enabled method in a browser: the page behind the login loads, DevTools shows `sb-<project-ref>-auth-token` cookies marked HttpOnly, a reload keeps the session, sign-out clears it and `/notes` redirects again. Force a token refresh (set `jwt_expiry = 60` locally, wait two minutes): the user stays signed in.

## References
- [supabase-auth-patterns.md](./supabase-auth-patterns.md) — `getClaims` vs `getUser` vs `getSession`, refresh, PKCE, redirects, cookies, sign-out.
- [auth-flows.md](./auth-flows.md) — proxy, routes, actions, form, email template, tests (code).
- [../build-nextjs-backend/SKILL.md](../build-nextjs-backend/SKILL.md), [../secure-supabase-rls/SKILL.md](../secure-supabase-rls/SKILL.md), [../set-up-supabase/SKILL.md](../set-up-supabase/SKILL.md).
- [../../frontend/set-up-auth/SKILL.md](../../frontend/set-up-auth/SKILL.md) — the SPA variant (tokens, guards); this skill is its server-rendered counterpart.
- [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md) — rules 3 and 4.
