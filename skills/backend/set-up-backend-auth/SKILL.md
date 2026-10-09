---
name: set-up-backend-auth
description: Use when a backend service must authenticate callers or enforce access. Verifies OIDC JWTs against JWKS, adds BFF session cookies for browsers, puts authorization in service-layer policies, denies by default and scopes every query to the tenant (Hono, Go, FastAPI).
---

# Set Up Backend Auth

The service is an OIDC **resource server**: it verifies tokens, it does not log users in. Rules and rationale: [auth-patterns.md](auth-patterns.md). Code for each track: [auth-tracks.md](auth-tracks.md). Baseline: [security-baseline.md](../../core/_shared/security-baseline.md) rules 3 and 10. Seam paths: [service-layout.md](../_shared/service-layout.md). Browser counterpart: [set-up-auth](../../frontend/set-up-auth/SKILL.md) (no tokens in `localStorage`).

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null     # backend.track, database, tests.layout, observability
ls src/platform/auth.ts internal/platform/auth src/*/platform/auth.py 2>/dev/null
grep -rnE "jsonwebtoken|python-jose|jwt\.decode|golang-jwt|go-oidc|PyJWT|jose|authlib" package.json go.mod pyproject.toml 2>/dev/null
grep -rnE "tenant_id|tenantId|TenantID" --include=*.ts --include=*.go --include=*.py -l . 2>/dev/null | head
grep -rnE "(isAdmin|is_admin|role ==)" --include=*.ts --include=*.go --include=*.py . 2>/dev/null | head   # checks living in handlers
```

Read the profile first; detect only what it leaves open ([stack-profile.md](../../core/_shared/stack-profile.md)). You need four facts from the identity provider. Take them from config, `.env.example` or the IdP's discovery document, and ask once only if none has them:

```bash
curl -s "$OIDC_ISSUER/.well-known/openid-configuration" | jq '{issuer, jwks_uri}'
```

Issuer URL (exact string, including any trailing slash), audience (the API's identifier, not a client ID), JWKS URL, and the claim that carries the tenant.

## 2. Decide

- No auth module: full setup, steps 3 to 7.
- A verifier exists but skips `aud`, accepts any `alg`, or uses `jsonwebtoken` / `python-jose`: fix it in place with the delta from [auth-tracks.md](auth-tracks.md). Do not rewrite what works.
- The verifier is sound but role checks sit in handlers: add the policy and tenant-scoped repository (step 5), move the checks, and delete the old ones.
- Verifier, policy, scoped repository and route-protection test all exist and step 7 passes: report "already in place" and stop.

## 3. Detect track

| `backend.track` | Do |
|---|---|
| `hono`, `go`, `fastapi` | Continue. |
| `nextjs` | Stop. Use [build-nextjs-backend](../build-nextjs-backend/SKILL.md). |
| `supabase` | Stop. Use [secure-supabase-rls](../secure-supabase-rls/SKILL.md) and [set-up-nextjs-supabase-auth](../set-up-nextjs-supabase-auth/SKILL.md): Supabase Auth issues the token, RLS is the authorization. |
| `none` or unset | Run `set-up-stack-profile`, then a `scaffold-*-service` skill. |

Two more questions, answered from the repo:

- Does a **browser** call this service with cookies (an SPA on the same site)? Then add the BFF session in step 6. Services, mobile apps and CLIs send `Authorization: Bearer` and need no cookie.
- Is there a database yet? Tenant-scoped repositories need one: run [set-up-database](../set-up-database/SKILL.md) first.

## 4. Install only what is missing

```bash
pnpm add jose                                  # hono: ES-module JOSE, zero dependencies
go get github.com/coreos/go-oidc/v3@latest     # go: JWKS cache, iss/aud/exp checks
go get github.com/go-jose/go-jose/v4           # go, tests only: sign test tokens
uv add 'pyjwt[crypto]'                         # fastapi: PyJWT with cryptography for RS256/ES256
```

Use the profile's package manager. Verify each line in [stack-versions.md](../_shared/stack-versions.md) before you write it.

## 5. Generate the seams

Create from [auth-tracks.md](auth-tracks.md), skipping files that exist:

```
platform/auth        verifier + Principal + authenticate middleware (the only code that sees a JWT)
service/*.policy     pure functions of (principal, resource); one file per resource
repository/*         constructed for one tenant; no method takes a tenant argument
service/*            load, then authorize with the policy, then act
transport/*          authenticate on the router group; map errors to 401, 403, 404
```

Paths follow [service-layout.md](../_shared/service-layout.md). The `documents` module is a worked example of the pattern. Rename it, or delete it once a real module uses the same shape.

## 6. Wire

1. **Config.** Add `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL` (required, no default) and `OIDC_TENANT_CLAIM` (default `tenant_id`) to the config module ([config.md](../_shared/config.md)). Add them to `.env.example`. Errors name the key, never the value.
2. **Composition root.** The verifier is a dependency of `createApp` / `httpapi.New` / `create_app`. It is built once in `main` from config. Tests pass a local key source ([auth-tracks.md](auth-tracks.md)).
3. **Deny by default.** Mount authentication on the router group, so a new route is protected without anyone remembering to protect it. Public routes (health, readiness, docs) sit outside that group and are listed by name in the route-protection test.
4. **Errors.** Missing or bad token: 401 with `WWW-Authenticate: Bearer`. Valid token, no permission: 403. Another tenant's row: **404**, so IDs cannot be probed. Log 401 and 403 at `warn` with the path and status, never the token or its claims ([logging-contract.md](../../core/_shared/logging-contract.md)).
5. **OpenAPI.** Declare the bearer scheme and mark protected operations. The Hono scaffold does this with `registerComponent` and `security` on the route.
6. **BFF (browser callers only).** The service performs the OIDC code flow with PKCE using its own session, keeps the access and refresh tokens server-side, and gives the browser two cookies: `__Host-sid` (HttpOnly, Secure, SameSite=Lax) and a readable `csrf` cookie that the frontend `fetcher` echoes in `X-CSRF-Token`. Endpoints match the frontend contract: `/auth/login`, `/auth/callback`, `/auth/logout`, `/auth/me`, `/auth/refresh`. Use a maintained client for the flow itself (`openid-client` in TypeScript, `golang.org/x/oauth2` with go-oidc, Authlib in Python). The cookie and CSRF code is in [auth-tracks.md](auth-tracks.md); [Rule: BFF](auth-patterns.md#rule-browsers-get-an-opaque-session-cookie-never-the-token) explains why.

## 7. Verify

```bash
pnpm typecheck && pnpm vitest run          # hono
go vet ./... && go test ./...                 # go
uv run mypy && uv run pytest                  # fastapi
```

Expected: all green, including these cases (names match the examples in [auth-tracks.md](auth-tracks.md)):

- no token: 401 with `WWW-Authenticate: Bearer`;
- token for another audience, an expired token (older than the skew), a token signed by an unknown key: 401;
- valid token without the scope: 403;
- valid token for tenant A reading tenant B's row: 404;
- the route-protection test: every operation outside the public list answers 401 without a token.

Then one manual check against a real IdP in staging: `curl -i -H "Authorization: Bearer $TOKEN" $URL/documents/<id>` returns 200, and the same call after the token expires returns 401.

## References

- [auth-patterns.md](auth-patterns.md): resource-server rules, JWT checks, skew, JWKS outage, BFF cookies, policies, tenant scoping.
- [auth-tracks.md](auth-tracks.md): files for Hono, Go and FastAPI, wiring deltas, session and CSRF code.
- [../harden-backend/SKILL.md](../harden-backend/SKILL.md): rate limit per caller, CORS, error shape.
- [../configure-backend-tests/SKILL.md](../configure-backend-tests/SKILL.md): the test IdP and the real-database tests that prove tenant isolation.
