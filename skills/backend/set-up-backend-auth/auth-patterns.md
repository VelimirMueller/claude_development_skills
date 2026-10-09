# Backend Auth Patterns

Reference for [set-up-backend-auth](SKILL.md). Each rule maps to [security-baseline.md](../../core/_shared/security-baseline.md): rule 3 (authorization at the data boundary) and rule 10 (use the platform for auth). OWASP Top 10:2025: A01 Broken Access Control, A07 Authentication Failures.

## Rule: The service verifies tokens; it does not issue them
**Why:** Login screens, MFA, password reset and federation change on the identity provider's schedule, not the API's. A service that mints its own tokens takes over every one of those problems. A resource server has one job: decide whether this bearer token is valid and who it names.
**How to apply:** Accept `Authorization: Bearer <jwt>`, verify it, build a `Principal`, hand that to the layers below. Do not add `/login` that checks a password. In the BFF case the service starts the OIDC code flow against the IdP; it still never sees a password.
**Anti-example:** `POST /login` that compares a bcrypt hash and signs a JWT with a shared secret from `.env`.
**When to deviate:** A single-tenant internal tool with no IdP can use the platform's session auth. Say so in the README; do not hand-roll JWTs.

## Rule: Verify signature, issuer, audience and expiry, and pin the algorithm
**Why:** A JWT that only decodes proves nothing. Without `aud`, a token issued for another API is accepted here. Without an algorithm allow-list, the attacker picks `none` or switches RS256 to HS256 with the public key as the secret. Without `exp`, a stolen token works forever.
**How to apply:** Pass `issuer`, `audience` and `algorithms` explicitly and require `exp`, `sub` and `iat`. `audience` is the API's identifier at the IdP, not the client ID of the frontend. Libraries: `jose` (TS), `coreos/go-oidc` (Go), `PyJWT` (Python). They verify the signature against keys, so a bad signature never reaches your claims code. Parse claims with a schema (Zod, Pydantic, a typed struct) and treat a parse failure as 401.
**Anti-example:** `jwt.decode(token, options={"verify_signature": False})` "just to read the tenant".
**When to deviate:** Opaque access tokens (not JWTs) need introspection (RFC 7662) instead; the Principal and everything below stay the same. Add `typ: 'at+jwt'` checks (RFC 9068) when the IdP emits that header.

## Rule: Allow 30 seconds of clock skew, no more
**Why:** Servers drift. Without tolerance a token that the IdP issued one second ago is "not yet valid" on a host that runs behind, and users see random 401s. A large tolerance extends the life of a stolen token.
**How to apply:** `clockTolerance: 30` (jose, seconds), `leeway=30` (PyJWT), and for go-oidc a `Now` function that returns `time.Now().Add(-skew)`, which widens the `exp` check. go-oidc applies its own fixed five-minute leeway to `nbf`; you cannot change it, so do not rely on `nbf` for security. Keep access tokens short (5 to 15 minutes) at the IdP.
**When to deviate:** Hosts with proven NTP drift beyond 30 s: fix the clocks, not the tolerance.

## Rule: Cache the JWKS, refetch on an unknown key, and treat a JWKS outage as a 5xx
**Why:** Fetching keys per request adds latency and an outage dependency to every call. Never refetching breaks on key rotation. A JWKS fetch failure is the IdP being down, not the caller sending a bad token: answering 401 sends clients into a login loop.
**How to apply:** `createRemoteJWKSet` (jose, with `cooldownDuration` so a flood of bogus `kid` values cannot hammer the IdP), `oidc.NewRemoteKeySet` (go-oidc), `PyJWKClient(cache_keys=True, lifespan=600)`. Create them lazily: the service must start while the IdP is unreachable. Map token errors to 401 and key-source outages to 503 (see [Rule: An IdP outage is a 503, not a 401](#rule-an-idp-outage-is-a-503-not-a-401)). `PyJWKClient` fetches with blocking `urllib`: call it from a sync dependency, which FastAPI runs in the threadpool, never from `async def`.
**When to deviate:** None. Pre-warming the cache at boot is fine if a failure only logs a warning.

## Rule: An IdP outage is a 503, not a 401
**Why:** A 401 says the token is bad; a well-behaved client drops the session and re-logins, or loops. A JWKS fetch failure is the IdP or the network, not the caller: answer 503 so clients retry and monitoring sees an outage instead of a login-loop storm.
**How to apply:** Map a key-source failure to `503 problem+json "Service Unavailable"` with a `Retry-After: 30` header. Keep 401 for token problems, including an unknown `kid` (that is a token problem, not an outage). The per-track code is in [auth-tracks.md](auth-tracks.md).
**When to deviate:** None. A key-source outage is never the caller's fault.

## Rule: Build a Principal once; nothing below sees the token
**Why:** A handler that reads claims from the raw token re-implements parsing and spreads trust decisions through the codebase. A `Principal` (`sub`, `tenantId`, `scopes`) is the validated fact; the token is an input to producing it.
**How to apply:** The auth module is the only one that imports the JWT library. Middleware puts the `Principal` in the request context; routes pass it to the service as an argument. Services take `Principal`, never `Request`. In tests, construct a `Principal` directly.
**Anti-example:** `c.req.header('authorization')` read inside a service, or a `tenant_id` taken from the request body.

## Rule: Browsers get an opaque session cookie, never the token
**Why:** Any script on the page can read `localStorage`, so one XSS bug becomes account takeover. A backend-for-frontend keeps the access and refresh tokens on the server and gives the browser an unreadable session ID. This is the same reasoning as the frontend [set-up-auth](../../frontend/set-up-auth/SKILL.md): tokens never in `localStorage`.
**How to apply:**
- Cookie `__Host-sid`: `HttpOnly; Secure; SameSite=Lax; Path=/`. The `__Host-` prefix makes browsers reject it unless it is Secure, host-only and `Path=/`.
- Session state (subject, tenant, tokens, expiry) in Postgres or Redis, keyed by a 256-bit random ID (`randomBytes(32)`, `secrets.token_urlsafe(32)`). Rotate the ID at login. Delete it at logout.
- CSRF: `SameSite=Lax` stops most cross-site posts. Add double-submit for the rest: a readable `csrf` cookie, echoed in `X-CSRF-Token` on POST, PUT, PATCH and DELETE, compared in constant time. This is the contract of the frontend `fetcher`.
- Refresh on the server, with the refresh token, before the access token expires. The browser sees only a longer session.
- Run the OIDC code flow with PKCE through a maintained client library; do not write the redirect and token exchange by hand.
**Anti-example:** returning `{ access_token }` from `/auth/callback` so the SPA can store it.
**When to deviate:** A native app or CLI has no cookie jar: use the system browser, PKCE, and OS secure storage. Cross-site embeds need `SameSite=None; Secure` plus CSRF tokens and a second look at the threat model.

## Rule: Authorization is a policy function at the service layer
**Why:** A check in a handler is skipped by the next entry point (a queue consumer, a CLI, a second route). A check in the UI is skipped by `curl`. A pure function `can(principal, resource)` is testable without HTTP or a database and reads as the access rules in one place.
**How to apply:** One `*.policy` file per resource with plain functions (`read`, `update`, `delete`). The service loads the resource, calls the policy, and throws a domain error (`forbidden`). Handlers only map errors to statuses. Check **ownership**, not just role: `resource.tenantId === principal.tenantId && resource.ownerId === principal.sub`. Never `if (user.isAdmin)` in a handler.
**Anti-example:** `if (principal.scopes.has('documents:read'))` in a route handler, with the same check missing from the export job.
**When to deviate:** Rules that need data the service does not hold (a relationship graph, per-document sharing) go to a policy engine (OpenFGA, Cedar, SpiceDB). The call still sits in the service layer.

## Rule: Deny by default
**Why:** "Add auth to each route" fails on the first route someone forgets. Opt-out is visible in review; opt-in is invisible in its absence.
**How to apply:** Authentication runs on the router group that holds every business route. Public routes live outside it and appear in an explicit list in a test that walks the OpenAPI document (or, in Go, a table of protected routes) and fails if any operation outside the list answers anything other than 401 without a token. A policy returns `false` unless a rule says `true`.
**Anti-example:** A per-route `requireAuth` decorator that new routes copy from the neighbour, or not.

## Rule: Scope every query to the tenant, structurally
**Why:** One `WHERE` clause forgotten in one query leaks another customer's data: A01 and the most common multi-tenant bug. A rule that depends on every developer remembering is a rule that will fail.
**How to apply:** The repository is constructed for a tenant (`createDocumentsRepository(db, principal)`, `NewDocuments(pool, tenantID)`, `DocumentsRepository(session, tenant_id)`). No method accepts a tenant argument and every query includes the tenant filter, so a query without it cannot be written through that type. Return **404** for rows of other tenants, so IDs cannot be probed. For a second layer, enable Postgres row-level security and set the tenant per transaction (`SET LOCAL app.tenant_id = ...`); see [rls-patterns.md](../secure-supabase-rls/rls-patterns.md). Add a test per resource: tenant A cannot read tenant B's row, against a real database ([configure-backend-tests](../configure-backend-tests/SKILL.md)).
**Anti-example:** `findById(id)` followed by `if (row.tenantId !== principal.tenantId) throw forbidden()`. It works until someone calls `findById` and forgets the second line, and it answers 403, which confirms the row exists.
**When to deviate:** Admin and support tooling that crosses tenants: a separate repository type and a separate role, audited, never the same type with a flag.

## Rule: Log denials, never credentials
**Why:** Attacks show up as bursts of 401 and 403. A log with the token in it is a leaked token ([security-baseline.md](../../core/_shared/security-baseline.md) rule 11).
**How to apply:** `warn` on 401 and 403 with `http.response.status_code`, `url.path` and the trace ID that the logger adds. No header values, no claims beyond the opaque `sub` (as `user.id`). The logger's redaction list covers `authorization` and `cookie`.

## When to deviate

- Platform auth is the product (Supabase, Clerk, Auth0 SDK): use its server SDK for verification, keep the policy, scoped repository and route-protection test from here.
- Service-to-service calls inside a trusted mesh may use mTLS identity instead of JWTs. The Principal and the policy stay.
- Public read-only APIs have no Principal. Say so by listing the routes in the public list, not by weakening the middleware.
