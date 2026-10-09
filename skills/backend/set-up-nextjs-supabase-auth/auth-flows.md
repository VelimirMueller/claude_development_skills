# Auth Flows — Code

Reference for `set-up-nextjs-supabase-auth`. Every file below type-checks and builds on Next 16.4.0, `@supabase/ssr` 0.12.7 and `@supabase/supabase-js` 2.117.3 (TypeScript 7.0.2), and the redirect behaviour was exercised on a production build (`next start`): the protected route returned 307 to `/login?next=%2Fnotes`, a bad code and a bad `type` returned redirects to `/login?error=…`, and hostile `next` values collapsed to `/`. Sign-in against a live Auth server is covered in step 9 of the skill. Paths follow the folder standard (`src/libs`, `src/server`, `src/features`, `src/app`).

## Proxy

Two files. The helper owns the Supabase logic; `proxy.ts` stays thin.

```ts
// src/libs/supabase/proxy.ts
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { clientEnv } from '@/libs/env.client';
import type { Database } from './database.types';

/** Paths that need a session. A coarse redirect for UX; every data call still authorizes. */
const PROTECTED_PREFIXES = ['/notes'];

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient<Database>(
    clientEnv.NEXT_PUBLIC_SUPABASE_URL,
    clientEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(cookiesToSet, headers) {
          for (const { name, value } of cookiesToSet) request.cookies.set(name, value);
          supabaseResponse = NextResponse.next({ request });
          for (const { name, value, options } of cookiesToSet) {
            supabaseResponse.cookies.set(name, value, options);
          }
          // Cache-Control and friends stop a CDN from serving one user's refreshed session to another.
          for (const [key, value] of Object.entries(headers)) supabaseResponse.headers.set(key, value);
        },
      },
    },
  );

  // Nothing may run between createServerClient and getClaims: it refreshes the session.
  const { data } = await supabase.auth.getClaims();

  const { pathname } = request.nextUrl;
  if (!data?.claims && PROTECTED_PREFIXES.some((prefix) => pathname.startsWith(prefix))) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';
    url.search = '';
    url.searchParams.set('next', pathname);
    const redirect = NextResponse.redirect(url);
    // Keep any cookies the refresh just set.
    for (const cookie of supabaseResponse.cookies.getAll()) redirect.cookies.set(cookie);
    for (const name of ['cache-control', 'expires', 'pragma']) {
      const value = supabaseResponse.headers.get(name);
      if (value) redirect.headers.set(name, value);
    }
    return redirect;
  }

  return supabaseResponse; // return this exact object, or the browser and server sessions drift apart
}
```

```ts
// src/proxy.ts
import type { NextRequest } from 'next/server';
import { updateSession } from '@/libs/supabase/proxy';

export async function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
};
```

Five rules, each from the Supabase SSR guide and its client source:

- Create the client and call `getClaims()` with nothing in between. That call refreshes the token when it is close to expiry; code in between can cause random sign-outs.
- Write refreshed cookies to both the request (so Server Components in this request see them) and the response (so the browser replaces them).
- Apply the `headers` that `setAll` receives (`Cache-Control`, `Expires`, `Pragma`) to the response. They stop a CDN from caching a response that carries someone's `Set-Cookie`.
- Return the response `setAll` last built. A fresh `NextResponse.next()` loses the cookies; when you must return another response, copy cookies and cache headers onto it (as the redirect branch does).
- Create a new client per request, never in module scope.

## Routes

```ts
// src/app/auth/callback/route.ts
import { NextResponse, type NextRequest } from 'next/server';
import { clientEnv } from '@/libs/env.client';
import { createClient } from '@/libs/supabase/server';
import { takeNext } from '@/server/post-login';

/** OAuth (PKCE) landing: swap the one-time `code` for a session cookie. */
export async function GET(request: NextRequest) {
  const site = clientEnv.NEXT_PUBLIC_SITE_URL; // a configured origin, never the Host header
  const code = request.nextUrl.searchParams.get('code');

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(await takeNext(site), site));
  }
  return NextResponse.redirect(new URL('/login?error=auth', site));
}
```

```ts
// src/app/auth/confirm/route.ts
import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { clientEnv } from '@/libs/env.client';
import { createClient } from '@/libs/supabase/server';
import { takeNext } from '@/server/post-login';

const Query = z.object({
  token_hash: z.string().min(1),
  type: z.enum(['signup', 'invite', 'magiclink', 'recovery', 'email_change', 'email']),
});

/** Email link landing (magic link, signup, recovery): verify the token hash, set the session. */
export async function GET(request: NextRequest) {
  const site = clientEnv.NEXT_PUBLIC_SITE_URL;
  const query = Query.safeParse(Object.fromEntries(request.nextUrl.searchParams));

  if (query.success) {
    const supabase = await createClient();
    const { error } = await supabase.auth.verifyOtp(query.data);
    if (!error) return NextResponse.redirect(new URL(await takeNext(site), site));
  }
  return NextResponse.redirect(new URL('/login?error=link', site));
}
```

Why two routes: OAuth returns `?code=`, exchanged with the PKCE verifier cookie the sign-in call stored (same browser). An email link carries `?token_hash=&type=`, verified with `verifyOtp`, which needs no verifier and works when the mail is opened on another device. Both read the destination from a short-lived cookie, so the redirect URL registered with Supabase stays an exact path.

```ts
// src/server/post-login.ts
import 'server-only';
import { cookies } from 'next/headers';
import { safeNextPath } from '@/libs/safe-redirect';

const NAME = 'post_login_next';

/** Remember where to send the user after an email or OAuth round trip (10 minutes, same browser). */
export async function rememberNext(path: string): Promise<void> {
  (await cookies()).set(NAME, path, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    path: '/',
    maxAge: 600,
  });
}

/** Read and clear the remembered path. Falls back to '/' when missing or unsafe. */
export async function takeNext(siteUrl: string): Promise<string> {
  const store = await cookies();
  const raw = store.get(NAME)?.value;
  store.delete(NAME);
  return safeNextPath(raw, siteUrl);
}
```

```ts
// src/libs/safe-redirect.ts
/**
 * Turns an untrusted `next` value into a same-origin path, or '/'.
 * The URL parser resolves `//evil.com`, `/\evil.com` and tab tricks the way a browser does,
 * so the origin comparison catches all of them.
 */
export function safeNextPath(raw: string | null | undefined, siteUrl: string): string {
  if (!raw) return '/';
  try {
    const url = new URL(raw, siteUrl);
    return url.origin === new URL(siteUrl).origin ? `${url.pathname}${url.search}` : '/';
  } catch {
    return '/';
  }
}
```

## Actions and form

```ts
// src/features/auth/actions.ts
'use server';

import { redirect } from 'next/navigation';
import { z } from 'zod';
import type { ActionResult } from '@/libs/action-result';
import { clientEnv } from '@/libs/env.client';
import { safeNextPath } from '@/libs/safe-redirect';
import { createClient } from '@/libs/supabase/server';
import { rememberNext } from '@/server/post-login';

const site = clientEnv.NEXT_PUBLIC_SITE_URL;
const nextOf = (formData: FormData) => safeNextPath(formData.get('next')?.toString(), site);

const PasswordLogin = z.object({ email: z.email(), password: z.string().min(1) });
const EmailOnly = z.object({ email: z.email() });
const Provider = z.enum(['github', 'google']);

export async function signInWithPasswordAction(
  _previous: ActionResult | null,
  formData: FormData,
): Promise<ActionResult> {
  const parsed = PasswordLogin.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { ok: false, code: 'invalid', fieldErrors: z.flattenError(parsed.error).fieldErrors };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  // One message for "no such user" and "wrong password": no account enumeration.
  if (error) return { ok: false, code: 'invalid', message: 'Email or password is wrong.' };

  redirect(nextOf(formData)); // throws; keep it outside any try/catch
}

export async function signInWithMagicLinkAction(
  _previous: ActionResult | null,
  formData: FormData,
): Promise<ActionResult> {
  const parsed = EmailOnly.safeParse(Object.fromEntries(formData));
  if (!parsed.success) {
    return { ok: false, code: 'invalid', fieldErrors: z.flattenError(parsed.error).fieldErrors };
  }

  await rememberNext(nextOf(formData));
  const supabase = await createClient();
  // The email template links to /auth/confirm?token_hash=…; see supabase/templates/magic_link.html.
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data.email,
    options: { shouldCreateUser: false },
  });
  // Same answer whether or not the address has an account.
  if (error) console.error(JSON.stringify({ level: 'warn', msg: 'otp send failed', code: error.code }));
  return { ok: true, data: null };
}

export async function signInWithOAuthAction(formData: FormData): Promise<void> {
  const provider = Provider.safeParse(formData.get('provider'));
  if (!provider.success) redirect('/login?error=provider');

  await rememberNext(nextOf(formData));
  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: provider.data,
    options: { redirectTo: `${site}/auth/callback` },
  });
  // The PKCE verifier cookie was written through cookies() before this redirect.
  if (error || !data.url) redirect('/login?error=oauth');
  redirect(data.url);
}

export async function signOutAction(): Promise<void> {
  const supabase = await createClient();
  await supabase.auth.signOut({ scope: 'local' }); // this device; the default 'global' signs out every device
  redirect('/login');
}
```

```tsx
// src/features/auth/LoginForm.tsx
'use client';

import { useActionState } from 'react';
import { signInWithMagicLinkAction, signInWithOAuthAction, signInWithPasswordAction } from './actions';

export function LoginForm({ next }: { next: string }) {
  const [passwordState, passwordAction, passwordPending] = useActionState(signInWithPasswordAction, null);
  const [linkState, linkAction, linkPending] = useActionState(signInWithMagicLinkAction, null);

  return (
    <>
      <form action={passwordAction}>
        <input type="hidden" name="next" value={next} />
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" autoComplete="username" required />
        <label htmlFor="password">Password</label>
        <input id="password" name="password" type="password" autoComplete="current-password" required />
        {passwordState && !passwordState.ok && <p role="alert">{passwordState.message ?? 'Check the form.'}</p>}
        <button type="submit" disabled={passwordPending}>Sign in</button>
      </form>

      <form action={linkAction}>
        <input type="hidden" name="next" value={next} />
        <label htmlFor="link-email">Email me a sign-in link</label>
        <input id="link-email" name="email" type="email" autoComplete="email" required />
        <button type="submit" disabled={linkPending}>Send link</button>
        {linkState?.ok && <p role="status">If the address is registered, a link is on its way.</p>}
      </form>

      <form action={signInWithOAuthAction}>
        <input type="hidden" name="next" value={next} />
        <button type="submit" name="provider" value="github">Continue with GitHub</button>
        <button type="submit" name="provider" value="google">Continue with Google</button>
      </form>
    </>
  );
}
```

The login page reads `next` from `searchParams` behind `<Suspense>` and passes the sanitized value down:

```tsx
// src/app/login/page.tsx
import { Suspense } from 'react';
import { LoginForm } from '@/features/auth/LoginForm';
import { clientEnv } from '@/libs/env.client';
import { safeNextPath } from '@/libs/safe-redirect';

export default function LoginPage({ searchParams }: PageProps<'/login'>) {
  return (
    <main>
      <h1>Sign in</h1>
      <Suspense>
        <Form searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function Form({ searchParams }: { searchParams: PageProps<'/login'>['searchParams'] }) {
  const { next } = await searchParams; // request data: read it behind <Suspense>
  const target = safeNextPath(typeof next === 'string' ? next : null, clientEnv.NEXT_PUBLIC_SITE_URL);
  return <LoginForm next={target} />;
}
```

## Supabase configuration

```toml
# supabase/config.toml
[auth]
site_url = "http://localhost:3000"
additional_redirect_urls = ["http://localhost:3000/auth/callback"]

[auth.email.template.magic_link]
subject = "Your sign-in link"
content_path = "./supabase/templates/magic_link.html"
```

```html
<!-- supabase/templates/magic_link.html -->
<h2>Sign in</h2>
<p><a href="{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=email">Sign in</a></p>
```

Remote projects: set Site URL and the redirect allow-list in the Dashboard (Authentication, URL Configuration) or through `supabase config push`. Production allow-list: the exact `https://<app>/auth/callback`; `https://**` style wildcards belong to preview URLs only (Supabase recommends the exact path in production). OAuth provider secrets: `[auth.external.github] enabled = true`, `client_id = "env(GITHUB_CLIENT_ID)"`, `secret = "env(GITHUB_SECRET)"`. Mail prefetchers (Microsoft Defender Safe Links and similar) open email links and consume the one-time token; for corporate mail use the OTP variant: put `{{ .Token }}` in the template and verify with `supabase.auth.verifyOtp({ email, token, type: 'email' })` from an action.

## Tests

`safeNextPath` is the one function here with security-critical edge cases, and it is pure:

```ts
// tests/safe-redirect.test.ts
import { describe, expect, it } from 'vitest';
import { safeNextPath } from '@/libs/safe-redirect';

const SITE = 'https://app.example.com';

describe('safeNextPath', () => {
  it('keeps same-origin paths and queries', () => {
    expect(safeNextPath('/notes', SITE)).toBe('/notes');
    expect(safeNextPath('/notes?tab=1', SITE)).toBe('/notes?tab=1');
    expect(safeNextPath('https://app.example.com/notes', SITE)).toBe('/notes');
  });

  it.each(['//evil.com', '/\\evil.com', 'https://evil.com/x', '/\t/evil.com', 'javascript:alert(1)'])(
    'rejects %j',
    (raw) => {
      expect(safeNextPath(raw, SITE)).toBe('/');
    },
  );

  it('falls back to / for missing input', () => {
    expect(safeNextPath(null, SITE)).toBe('/');
    expect(safeNextPath('', SITE)).toBe('/');
  });
});
```

Run with `pnpm vitest run` (Vitest 5.0.3 passed 7 tests). Action validation is covered by the same pattern: call the action with a `FormData` and assert the returned `ActionResult`. Sign-in, refresh and sign-out are end-to-end tests against `supabase start` (Playwright), not unit tests.
