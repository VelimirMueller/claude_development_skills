# Supabase Auth Patterns (Next.js)

Reference for `set-up-nextjs-supabase-auth`. Sources: Supabase "Creating a client for SSR" and "Advanced SSR" guides, the Auth JWT and signing-key guides, the `@supabase/ssr` 0.12.7 and `@supabase/auth-js` 2.117.3 package source, the Next.js 16.4 Authentication guide; checked 2026-10-09.

## Rule: on the server, verify with `getClaims()`; use `getUser()` when revocation matters; never trust `getSession()`
**Why:** The session cookie can be forged, and `getSession()` reads it back without revalidating. Rendering a page for whoever the cookie claims to be is an account takeover. The three calls answer different questions:

| Call | What it does | Use for |
|---|---|---|
| `getClaims()` | Verifies the access token's signature and expiry. With asymmetric signing keys (default for new projects) it checks locally against a cached copy of the project's public keys; with a symmetric secret it asks the Auth server. Refreshes the session first when the token is near expiry. | Identity for pages, actions and data access |
| `getUser()` | Network call to the Auth server; returns the current user record. | Sensitive actions where a revoked or changed session must be caught |
| `getSession()` | Loads the raw session from storage, no re-validation. | Forwarding the access token to another service. Never to decide who someone is |

An unexpired access token stays valid after its session was revoked (signed out on another device, password changed), so `getClaims()` alone cannot see revocation until `exp` (default 3600 s). Call `getUser()` before changing a password or email, spending money, deleting an account or granting access.
**How to apply:** `getViewer()` wraps `getClaims()`. A sensitive action adds `const { data: { user } } = await supabase.auth.getUser()` and rejects on error. Grep for `getSession()` outside `src/libs/supabase`.
**Anti-example:** `const { data: { session } } = await supabase.auth.getSession(); if (session) { … }` in a Server Component or Server Action.

## Rule: refresh the session in `proxy.ts`, because Server Components cannot write cookies
**Why:** Access tokens expire; refreshing produces new cookies. A Server Component renders after headers are sent, so its `setAll` fails (the try/catch ignores that). Only the proxy can write the refreshed cookies to both the request and the response. Without it users are signed out after the first token expiry. In Next 15 and earlier, `proxy.ts` is never called; the file is `middleware.ts` there.
**How to apply:** `updateSession` as in [auth-flows.md](./auth-flows.md). Match every route that reads the session; skip static assets.
**Anti-example:** Two places refreshing: the proxy and a Server Component that calls `getClaims()` on a stale cookie without the proxy having run. Refresh tokens are single use, with a short reuse window and a rule that presenting a token's parent returns the active one; a reuse outside those rules revokes the whole session, which looks like random sign-outs.

## Rule: one server client per request, never in module scope
**Why:** The client closes over that request's cookies. A shared instance mixes sessions between users, or serves a stale one.
**How to apply:** `createClient()` is async and called inside each DAL function, action, route handler and the proxy helper. The browser client is a singleton by design (`createBrowserClient`), so calling its factory repeatedly is cheap.

## Rule: nothing that carries a session may be publicly cached
**Why:** A response that sets a refreshed session cookie, if cached by a CDN or ISR, signs the next visitor in as someone else. `setAll` hands you the headers (`Cache-Control`, `Expires`, `Pragma`) that prevent it.
**How to apply:** Apply those headers in the proxy (and on any redirect it returns). Do not put `Cache-Control: public` or `s-maxage` on routes that call `getViewer()`. With Cache Components, `cookies()` is request-time data, so such routes stream behind `<Suspense>` and are not part of a shared cache; cached components get the cookie-less client only ([nextjs-caching-patterns.md](../build-nextjs-backend/nextjs-caching-patterns.md)).

## Rule: know that the session cookie is readable by JavaScript
**Why:** `@supabase/ssr` sets `httpOnly: false`, `sameSite: 'lax'`, `path: '/'`, `maxAge` of 400 days by default (read from the package source), because the browser client reads the session from the same cookies. An XSS bug can read the tokens, which is the opposite of the preference in [set-up-auth](../../frontend/set-up-auth/SKILL.md) for httpOnly cookies. The trade is deliberate in the library; the app has to compensate.
**How to apply:** Ship a strict Content-Security-Policy ([set-up-security-headers](../../frontend/set-up-security-headers/SKILL.md)), no `dangerouslySetInnerHTML` with untrusted input, and `secure` cookies in production (HTTPS). If the app never creates a browser Supabase client (no Realtime, no client-side queries), pass `cookieOptions: { httpOnly: true }` to the server and proxy clients so scripts cannot read the session; this option exists in `@supabase/ssr` and was not exercised end to end here. Keep claims small: browsers cap a cookie near 4 KB and the library splits long values across chunks.

## Rule: PKCE needs the same browser; email links use `token_hash`
**Why:** OAuth and the default email link return a one-time `code`, and exchanging it requires the PKCE verifier cookie stored when sign-in began. Open the link on another device and the exchange fails. A link built from `{{ .TokenHash }}` is verified with `verifyOtp` and does not need the verifier. Some mail systems open links before the user does (Microsoft Defender Safe Links) and consume the token; a typed one-time code avoids that.
**How to apply:** OAuth → `signInWithOAuth` in a Server Action (the verifier cookie is written through `cookies()` before the redirect), `exchangeCodeForSession` in `/auth/callback`. Email → custom template to `/auth/confirm?token_hash=…&type=email`, `verifyOtp` there. Corporate recipients → OTP code entry (`verifyOtp({ email, token, type: 'email' })`).
**Anti-example:** Implementing the OAuth start as a client-side redirect to a URL you assembled yourself: the verifier cookie is never set and the callback fails with a missing-verifier error.

## Rule: redirect to a configured origin, to a sanitized path
**Why:** Building the redirect from the `Host` or `X-Forwarded-Host` header lets an attacker steer a user to another site after login; an unchecked `next` is an open redirect. `//evil.com`, `/\evil.com` and a tab inside the path all slip past `startsWith('/')`.
**How to apply:** `NEXT_PUBLIC_SITE_URL` is the only origin. Resolve `next` with `new URL(next, site)` and keep it only when the origin equals the site's origin (`safeNextPath`). Keep the post-login destination in a short-lived httpOnly cookie for OAuth and email flows, so the redirect URL registered with Supabase is an exact path; production allow-list entries are exact paths, and `**` wildcards are for dev and previews.
**Anti-example:** Supabase's sample callback trusts `x-forwarded-host` to rebuild the origin. Behind a proxy you control that is fine; as a default it trusts a client-supplied header.

## Rule: failures say nothing about which accounts exist
**Why:** "No such user" versus "wrong password" lets an attacker list accounts. A magic-link form that errors for unknown emails does the same.
**How to apply:** One message for both password failures; the magic-link action always answers "if the address is registered, a link is on its way" and logs the real reason with a code only. `shouldCreateUser: false` keeps the login form from creating accounts; run sign-up as a separate flow with email confirmation on. Supabase's own rate limits cover email sends and sign-ins (`[auth.rate_limit]`); add an IP limit in front of the actions for anything costing money.

## Rule: sign-out ends this device unless you mean everywhere
**Why:** `signOut()` defaults to `scope: 'global'` and revokes every session of the account (read from the `auth-js` 2.117.3 types). A user clicking "Sign out" on a laptop should not be logged out of their phone.
**How to apply:** `signOut({ scope: 'local' })` in `signOutAction`; add an explicit "sign out everywhere" action with `scope: 'global'` (and use `getUser()` first). Sign-out is a POST (a form on an action), never a GET link.

## Rule: authorization data in `app_metadata` or tables; the JWT lags
**Why:** `getClaims()` returns the token's claims, including `app_metadata` and `user_metadata`. The user can edit `user_metadata`. Claims change only when the token refreshes, so a revoked role stays in tokens already issued.
**How to apply:** Roles and tenant membership go in tables read by RLS helper functions, or in `app_metadata` set with the admin client (and optionally the Custom Access Token Hook) when a one-hour lag is acceptable. Do not branch on `claims.user_metadata` anywhere. The authoritative check is the policy ([rls-patterns.md](../secure-supabase-rls/rls-patterns.md)); app code only decides what to render.

## Rule: environment-specific Auth settings are code
**Why:** Local defaults are permissive on purpose: email confirmations off, a 6-character minimum password, `site_url` pointing at localhost. Shipping them is a vulnerability.
**How to apply:** In `config.toml` (and the Dashboard for hosted projects): `enable_confirmations = true` for email sign-up in staging and production, `minimum_password_length = 8` or more with `password_requirements` set, exact `site_url`, no wildcard redirects in production, `enable_anonymous_sign_ins = false` unless used. Custom SMTP for production mail. MFA: require `aal2` in policies with `(select auth.jwt() ->> 'aal') = 'aal2'` on sensitive tables.

## Rule: the admin client never signs anyone in
**Why:** The secret key bypasses RLS and can create sessions and users. A sign-in path that uses it turns a missing check into total access.
**How to apply:** Sign-in uses the request-scoped client only. `supabase.auth.admin.*` runs in server-only jobs and Edge Functions, behind their own authorization.

## When to deviate
- **Server-only app without Supabase client-side features:** harden with `httpOnly: true` cookies as above, after testing sign-in, refresh and sign-out in a browser.
- **A SPA talking to a separate API:** this skill does not apply; use the SPA flow in [set-up-auth](../../frontend/set-up-auth/SKILL.md) with Supabase's browser client.
- **Third-party identity (Auth0, Clerk) in front of Supabase:** use Supabase's third-party auth configuration and keep RLS on the verified claims; the proxy and `getViewer` seams stay, with that provider's verifier.
- **Next 15 or earlier:** `middleware.ts` / `middleware()` and no Cache Components; the Supabase code is identical.
