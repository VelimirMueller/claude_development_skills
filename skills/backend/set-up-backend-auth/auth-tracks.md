# Backend Auth: Code per Track

Companion to [set-up-backend-auth](SKILL.md). Every file ran on 2026-10-09 inside the scaffolds of [scaffold-hono-service](../scaffold-hono-service/SKILL.md), [scaffold-go-service](../scaffold-go-service/SKILL.md) and [scaffold-fastapi-service](../scaffold-fastapi-service/SKILL.md): `tsc --noEmit`, `biome check`, `vitest run`; `go vet`, `golangci-lint`, `go test` against Postgres 18; `ruff`, `mypy --strict`, `pytest` against Postgres 18. Versions: [stack-versions.md](../_shared/stack-versions.md). Package paths follow [service-layout.md](../_shared/service-layout.md); `svc` is the placeholder package name.

The test seam in all three tracks is the same: the verifier takes its **key source** as an argument. Production passes the remote JWKS, tests pass a local key and sign real tokens, so the verification code under test is the code that runs in production.

## TypeScript (Hono)

Add to `src/config.ts`, to the schema:

```ts
DATABASE_URL: z.url(),
OIDC_ISSUER: z.url(),
OIDC_AUDIENCE: z.string().min(1),
OIDC_JWKS_URL: z.url(),
OIDC_TENANT_CLAIM: z.string().min(1).default('tenant_id'),
```

Append to `src/platform/problem.ts` (the scaffold's `AppError` stays as is):

```ts
export const unauthenticated = () => new AppError(401, 'Unauthorized');
export const forbidden = () => new AppError(403, 'Forbidden');
```

### `src/platform/auth.ts`

```ts
import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, errors, type JWTVerifyGetKey, jwtVerify } from 'jose';
import { z } from 'zod';
import { unauthenticated } from './problem.ts';

/** Who is calling. Built once here; routes and services never see the raw token. */
export type Principal = {
  readonly sub: string;
  readonly tenantId: string;
  readonly scopes: ReadonlySet<string>;
};

export type AuthConfig = {
  keys: JWTVerifyGetKey; // remote JWKS in production, a local key set in tests
  issuer: string;
  audience: string;
  tenantClaim: string;
};

/** Production key source. Refetches on an unknown `kid`, at most once per cooldown. */
export const remoteKeys = (jwksUrl: string) =>
  createRemoteJWKSet(new URL(jwksUrl), { cooldownDuration: 30_000, cacheMaxAge: 600_000 });

const claims = z.object({ sub: z.string().min(1), scope: z.string().default('') });
const tenantClaim = z.string().min(1);

export type AuthEnv = { Variables: { principal: Principal } };

export function createAuth(config: AuthConfig) {
  async function verifyAccessToken(token: string): Promise<Principal> {
    try {
      const { payload } = await jwtVerify(token, config.keys, {
        issuer: config.issuer,
        audience: config.audience,
        algorithms: ['RS256', 'ES256'], // allow-list; never trust the token's own `alg`
        clockTolerance: 30, // seconds of drift on exp and nbf
        requiredClaims: ['sub', 'exp', 'iat'],
      });
      const parsed = claims.parse(payload);
      return {
        sub: parsed.sub,
        tenantId: tenantClaim.parse(payload[config.tenantClaim]),
        scopes: new Set(parsed.scope.split(' ').filter(Boolean)),
      };
    } catch (err) {
      if (err instanceof errors.JOSEError || err instanceof z.ZodError) throw unauthenticated();
      throw err; // a JWKS fetch failure is an outage, not a bad token: let it become a 5xx
    }
  }

  const authenticate = createMiddleware<AuthEnv>(async (c, next) => {
    const token = /^Bearer (\S+)$/i.exec(c.req.header('authorization') ?? '')?.[1];
    if (!token) throw unauthenticated();
    c.set('principal', await verifyAccessToken(token));
    await next();
  });

  return { verifyAccessToken, authenticate };
}

export type Auth = ReturnType<typeof createAuth>;
```

### `src/service/documents.policy.ts`

```ts
import type { Principal } from '../platform/auth.ts';
import { forbidden } from '../platform/problem.ts';

export type DocumentAccess = { readonly tenantId: string; readonly ownerId: string };

/** Policies are pure functions of (principal, resource). Nothing is allowed unless one says so. */
export const documentPolicy = {
  read: (p: Principal, d: DocumentAccess) =>
    p.tenantId === d.tenantId && p.scopes.has('documents:read'),
  update: (p: Principal, d: DocumentAccess) =>
    p.tenantId === d.tenantId && p.scopes.has('documents:write') && d.ownerId === p.sub,
} as const;

export function assertAllowed(allowed: boolean): asserts allowed {
  if (!allowed) throw forbidden();
}
```

### `src/repository/documents.repository.ts`

```ts
import { and, eq } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { pgTable, text, uuid } from 'drizzle-orm/pg-core';

export const documents = pgTable('documents', {
  id: uuid('id').primaryKey().defaultRandom(),
  tenantId: text('tenant_id').notNull(),
  ownerId: text('owner_id').notNull(),
  title: text('title').notNull(),
});

export type Document = typeof documents.$inferSelect;
export type TenantScope = { readonly tenantId: string };

export interface DocumentsRepository {
  findById(id: string): Promise<Document | undefined>;
}

/** A repository exists for one tenant. It has no method that takes a tenant, so a query cannot forget it. */
export function createDocumentsRepository(
  db: NodePgDatabase,
  scope: TenantScope,
): DocumentsRepository {
  return {
    async findById(id) {
      const [row] = await db
        .select()
        .from(documents)
        .where(and(eq(documents.tenantId, scope.tenantId), eq(documents.id, id)))
        .limit(1);
      return row;
    },
  };
}
```

### `src/service/documents.service.ts`

```ts
import type { Principal } from '../platform/auth.ts';
import { AppError } from '../platform/problem.ts';
import type {
  Document,
  DocumentsRepository,
  TenantScope,
} from '../repository/documents.repository.ts';
import { assertAllowed, documentPolicy } from './documents.policy.ts';

export interface DocumentsService {
  get(principal: Principal, id: string): Promise<Document>;
}

export function createDocumentsService(deps: {
  documentsFor: (scope: TenantScope) => DocumentsRepository;
}): DocumentsService {
  return {
    async get(principal, id) {
      const doc = await deps.documentsFor(principal).findById(id);
      // Another tenant's row is simply absent: 404, never 403.
      if (!doc) throw new AppError(404, 'Not Found', { detail: 'Document does not exist' });
      assertAllowed(documentPolicy.read(principal, doc));
      return doc;
    },
  };
}
```

### `src/transport/documents.routes.ts`

```ts
import { createRoute, OpenAPIHono, z } from '@hono/zod-openapi';
import type { AuthEnv } from '../platform/auth.ts';
import { PROBLEM_CONTENT_TYPE, problemSchema } from '../platform/problem.ts';
import type { DocumentsService } from '../service/documents.service.ts';

const documentSchema = z.object({ id: z.uuid(), title: z.string() }).openapi('Document');
const problem = (description: string) => ({
  description,
  content: { [PROBLEM_CONTENT_TYPE]: { schema: problemSchema } },
});

const getDocument = createRoute({
  method: 'get',
  path: '/documents/{id}',
  tags: ['documents'],
  security: [{ bearerAuth: [] }],
  request: { params: z.object({ id: z.uuid() }) },
  responses: {
    200: {
      description: 'The document',
      content: { 'application/json': { schema: documentSchema } },
    },
    401: problem('Missing or invalid token'),
    403: problem('Authenticated, but not allowed'),
    404: problem('No such document in your tenant'),
  },
});

export function documentsRoutes(service: DocumentsService) {
  return new OpenAPIHono<AuthEnv>().openapi(getDocument, async (c) => {
    const { id } = c.req.valid('param');
    const doc = await service.get(c.get('principal'), id);
    return c.json({ id: doc.id, title: doc.title }, 200);
  });
}
```

### Wiring in `src/app.ts`

`AppDeps` gains `documents: DocumentsService`, `auth: Auth` and `allowedOrigins: string[]`. The router becomes `new OpenAPIHono<AuthEnv>(...)`. After the scaffold's public routes, mount the protected group:

```ts
app.openAPIRegistry.registerComponent('securitySchemes', 'bearerAuth', {
  type: 'http',
  scheme: 'bearer',
  bearerFormat: 'JWT',
});

app.route('/', healthRoutes(deps.readinessChecks, deps.isShuttingDown)); // public: no token
app.route('/', notesRoutes(deps.notes));

// Everything below needs a token. A new route under /documents is protected without a thought.
app.use('/documents/*', deps.auth.authenticate);
app.route('/', documentsRoutes(deps.documents));
```

In `app.onError`, give a 401 its challenge header and log denials:

```ts
if (err instanceof AppError) {
  if (err.status === 401 || err.status === 403) {
    deps.logger.warn(
      { event: 'auth.denied', 'http.response.status_code': err.status, 'url.path': c.req.path },
      'access denied',
    );
  }
  return problem(
    c,
    { type: err.type, title: err.title, status: err.status, detail: err.message, instance: c.req.path },
    err.status === 401 ? { 'WWW-Authenticate': 'Bearer' } : {},
  );
}
```

`problem()` takes a third argument, `headers: Record<string, string> = {}`, spread into the response headers. `main.ts` builds the verifier once:

```ts
auth: createAuth({
  keys: remoteKeys(config.OIDC_JWKS_URL),
  issuer: config.OIDC_ISSUER,
  audience: config.OIDC_AUDIENCE,
  tenantClaim: config.OIDC_TENANT_CLAIM,
}),
documents: createDocumentsService({ documentsFor: (scope) => createDocumentsRepository(db, scope) }),
```

### BFF session: `src/platform/session.ts`

Use it with `openid-client` for the code flow. The store (`SessionStore`) is Postgres or Redis; it holds the tokens, the browser never does.

```ts
// BFF: the browser holds an opaque session id; tokens stay on the server.
import { randomBytes, timingSafeEqual } from 'node:crypto';
import type { Context } from 'hono';
import { deleteCookie, getCookie, setCookie } from 'hono/cookie';
import { createMiddleware } from 'hono/factory';
import { AppError } from './problem.ts';

export type SessionData = { sub: string; tenantId: string };

export interface SessionStore {
  create(data: SessionData, ttlSeconds: number): Promise<string>;
  read(id: string): Promise<SessionData | undefined>;
  destroy(id: string): Promise<void>;
}

const COOKIE = '__Host-sid'; // the __Host- prefix forces Secure, Path=/ and no Domain
const TTL_SECONDS = 8 * 60 * 60;

export const newSessionId = () => randomBytes(32).toString('base64url');

export function setSessionCookie(c: Context, id: string) {
  setCookie(c, COOKIE, id, {
    httpOnly: true,
    secure: true,
    sameSite: 'Lax',
    path: '/',
    maxAge: TTL_SECONDS,
  });
}

export const readSessionCookie = (c: Context) => getCookie(c, COOKIE);
export const clearSessionCookie = (c: Context) =>
  deleteCookie(c, COOKIE, { path: '/', secure: true });

const UNSAFE = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

/** Double-submit CSRF, matching the frontend `fetcher`: the readable `csrf` cookie must equal the
 *  `X-CSRF-Token` header on unsafe methods. Only cookie-authenticated routes need it. */
export const csrfDoubleSubmit = createMiddleware(async (c, next) => {
  if (UNSAFE.has(c.req.method)) {
    const cookie = getCookie(c, 'csrf') ?? '';
    const header = c.req.header('x-csrf-token') ?? '';
    const a = Buffer.from(cookie);
    const b = Buffer.from(header);
    if (a.length === 0 || a.length !== b.length || !timingSafeEqual(a, b)) {
      throw new AppError(403, 'Forbidden', { detail: 'CSRF token missing or wrong' });
    }
  }
  await next();
});

/** Set next to the session cookie at login. JS must read this one, so it is not HttpOnly. */
export function setCsrfCookie(c: Context) {
  setCookie(c, 'csrf', randomBytes(32).toString('base64url'), {
    secure: true,
    sameSite: 'Lax',
    path: '/',
    maxAge: TTL_SECONDS,
  });
}
```

### Tests

`tests/support/idp.ts` signs real tokens with a throwaway key:

```ts
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';

export const TEST_ISSUER = 'https://idp.test/';
export const TEST_AUDIENCE = 'api://test';

/** Real signatures, real verification path: only the key source differs from production. */
export async function createTestIdp() {
  const { publicKey, privateKey } = await generateKeyPair('ES256');
  const keys = createLocalJWKSet({
    keys: [{ ...(await exportJWK(publicKey)), kid: 'test', alg: 'ES256' }],
  });

  const sign = (claims: Record<string, unknown>, opts: { aud?: string; exp?: string } = {}) =>
    new SignJWT(claims)
      .setProtectedHeader({ alg: 'ES256', kid: 'test' })
      .setIssuer(TEST_ISSUER)
      .setAudience(opts.aud ?? TEST_AUDIENCE)
      .setIssuedAt()
      .setExpirationTime(opts.exp ?? '5m')
      .sign(privateKey);

  return {
    keys,
    tokenFor: (p: { sub?: string; tenantId?: string; scope?: string } = {}) =>
      sign({
        sub: p.sub ?? 'u-1',
        tenant_id: p.tenantId ?? 't-1',
        scope: p.scope ?? 'documents:read',
      }),
    tokenWith: sign,
  };
}
```

The route-protection test. It fails when an operation outside the public list answers anything but 401 without a token:

```ts
import { createLocalJWKSet } from 'jose';
import { describe, expect, it } from 'vitest';
import { createApp } from '../../src/app.ts';
import { createAuth } from '../../src/platform/auth.ts';
import { createLogger } from '../../src/platform/logger.ts';
import { createInMemoryNotesRepository } from '../../src/repository/notes.repository.ts';
import { createDocumentsService } from '../../src/service/documents.service.ts';
import { createNotesService } from '../../src/service/notes.service.ts';

// The complete list of routes that may be called without a token. Adding one is a reviewed change.
const PUBLIC = new Set(['GET /healthz', 'GET /readyz', 'GET /notes/{id}', 'GET /openapi.json']);

const app = createApp({
  logger: createLogger({
    LOG_LEVEL: 'silent',
    OTEL_SERVICE_NAME: 't',
    DEPLOYMENT_ENVIRONMENT: 'development',
  }),
  notes: createNotesService({ notes: createInMemoryNotesRepository() }),
  documents: createDocumentsService({ documentsFor: () => ({ findById: async () => undefined }) }),
  auth: createAuth({
    keys: createLocalJWKSet({ keys: [] }),
    issuer: 'x',
    audience: 'x',
    tenantClaim: 'tenant_id',
  }),
  allowedOrigins: [],
  readinessChecks: [],
  isShuttingDown: () => false,
});

describe('route protection', () => {
  it('every operation outside the public list answers 401 without a token', async () => {
    const spec = (await (await app.request('/openapi.json')).json()) as {
      paths: Record<string, Record<string, unknown>>;
    };
    const unprotected: string[] = [];
    for (const [path, methods] of Object.entries(spec.paths)) {
      for (const method of Object.keys(methods)) {
        const key = `${method.toUpperCase()} ${path}`;
        if (PUBLIC.has(key)) continue;
        // Templated params are filled with a UUID: every path parameter in this app is one.
        const url = path.replace(/\{[^}]+\}/g, '5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10');
        const res = await app.request(url, { method: method.toUpperCase() });
        if (res.status !== 401) unprotected.push(`${key} -> ${res.status}`);
      }
    }
    expect(unprotected).toEqual([]);
  });
});
```

The tenant-isolation and error cases run against a real Postgres: see `tests/integration/documents.http.test.ts` in [test-tracks.md](../configure-backend-tests/test-tracks.md).

## Go

Add to `internal/config/config.go`: fields `DatabaseURL`, `OIDCIssuer`, `OIDCAudience`, `OIDCJWKSURL`, `OIDCTenantClaim`, and a `require` helper so a missing key is reported with all the others:

```go
require := func(key string) string {
	v := get(key, "")
	if v == "" {
		errs = append(errs, errors.New(key+": required"))
	}
	return v
}
// in the Config literal:
//   DatabaseURL: require("DATABASE_URL"), OIDCIssuer: require("OIDC_ISSUER"),
//   OIDCAudience: require("OIDC_AUDIENCE"), OIDCJWKSURL: require("OIDC_JWKS_URL"),
//   OIDCTenantClaim: get("OIDC_TENANT_CLAIM", "tenant_id"),
```

The scaffold's `TestDefaults` now needs the required keys in its lookup map.

### `internal/platform/auth/auth.go`

```go
// Package auth is the only package that knows about JWTs.
package auth

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Principal is who is calling. Built here once; handlers and services never see the raw token.
type Principal struct {
	Sub      string
	TenantID string
	Scopes   map[string]struct{}
}

func (p Principal) HasScope(s string) bool { _, ok := p.Scopes[s]; return ok }

var ErrUnauthenticated = errors.New("unauthenticated")

type Config struct {
	Keys        oidc.KeySet // oidc.NewRemoteKeySet in production, oidc.StaticKeySet in tests
	Issuer      string
	Audience    string
	TenantClaim string
	Skew        time.Duration // tolerated clock drift on exp
}

type Verifier struct {
	v           *oidc.IDTokenVerifier
	tenantClaim string
}

func NewVerifier(c Config) *Verifier {
	return &Verifier{
		tenantClaim: c.TenantClaim,
		v: oidc.NewVerifier(c.Issuer, c.Keys, &oidc.Config{
			ClientID:             c.Audience,                                          // checked against `aud`
			SupportedSigningAlgs: []string{"RS256", "ES256"},                          // allow-list; never trust the token's own alg
			Now:                  func() time.Time { return time.Now().Add(-c.Skew) }, // widens the exp check by Skew
		}),
	}
}

func (a *Verifier) Verify(ctx context.Context, raw string) (Principal, error) {
	tok, err := a.v.Verify(ctx, raw) // signature, iss, aud, exp
	if err != nil {
		return Principal{}, ErrUnauthenticated
	}
	var claims map[string]any
	if err := tok.Claims(&claims); err != nil {
		return Principal{}, ErrUnauthenticated
	}
	tenant, _ := claims[a.tenantClaim].(string)
	if tok.Subject == "" || tenant == "" {
		return Principal{}, ErrUnauthenticated
	}
	scopes := map[string]struct{}{}
	if s, ok := claims["scope"].(string); ok {
		for _, f := range strings.Fields(s) {
			scopes[f] = struct{}{}
		}
	}
	return Principal{Sub: tok.Subject, TenantID: tenant, Scopes: scopes}, nil
}

type ctxKey struct{}

// FromContext returns the caller. ok is false on a route that skipped Authenticate.
func FromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(ctxKey{}).(Principal)
	return p, ok
}

// Authenticate rejects any request without a valid bearer token.
func (a *Verifier) Authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || raw == "" {
			unauthorized(w)
			return
		}
		p, err := a.Verify(r.Context(), raw)
		if err != nil {
			unauthorized(w)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, p)))
	})
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"type":"about:blank","title":"Unauthorized","status":401}`))
}
```

### `internal/service/documents_policy.go`

```go
package service

import (
	"example.com/svc/internal/platform/auth"
	"example.com/svc/internal/repository"
)

// Policies are pure functions of (principal, resource). Nothing is allowed unless one says so.
func CanReadDocument(p auth.Principal, d repository.Document) bool {
	return p.TenantID == d.TenantID && p.HasScope("documents:read")
}

func CanUpdateDocument(p auth.Principal, d repository.Document) bool {
	return p.TenantID == d.TenantID && p.HasScope("documents:write") && d.OwnerID == p.Sub
}
```

### `internal/repository/documents.go`

```go
package repository

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Document struct {
	ID       string
	TenantID string
	OwnerID  string
	Title    string
}

// Documents exists for one tenant. It has no constructor without a tenant ID and no method that
// takes one, so a query cannot forget the tenant filter.
type Documents struct {
	db       *pgxpool.Pool
	tenantID string
}

func NewDocuments(db *pgxpool.Pool, tenantID string) Documents {
	return Documents{db: db, tenantID: tenantID}
}

func (r Documents) FindByID(ctx context.Context, id string) (Document, error) {
	var d Document
	err := r.db.QueryRow(ctx,
		`SELECT id, tenant_id, owner_id, title FROM documents WHERE tenant_id = $1 AND id = $2`,
		r.tenantID, id,
	).Scan(&d.ID, &d.TenantID, &d.OwnerID, &d.Title)
	if errors.Is(err, pgx.ErrNoRows) {
		return Document{}, ErrNotFound
	}
	return d, err
}
```

With `sqlc` the query lives in `queries/documents.sql` and takes both parameters; the tenant stays a field of the repository wrapper, not a parameter of its methods:

```sql
-- name: GetDocument :one
SELECT id, tenant_id, owner_id, title FROM documents WHERE tenant_id = $1 AND id = $2;
```

### `internal/service/documents.go`

```go
package service

import (
	"context"
	"errors"
	"fmt"

	"example.com/svc/internal/platform/auth"
	"example.com/svc/internal/repository"
)

var (
	ErrDocumentNotFound = errors.New("document not found")
	ErrForbidden        = errors.New("forbidden")
)

// DocumentStore is the tenant-scoped repository. The factory takes the tenant from the principal.
type DocumentStore interface {
	FindByID(ctx context.Context, id string) (repository.Document, error)
}

type Documents struct {
	storeFor func(tenantID string) DocumentStore
}

func NewDocuments(storeFor func(tenantID string) DocumentStore) *Documents {
	return &Documents{storeFor: storeFor}
}

func (s *Documents) Get(ctx context.Context, p auth.Principal, id string) (repository.Document, error) {
	d, err := s.storeFor(p.TenantID).FindByID(ctx, id)
	switch {
	case errors.Is(err, repository.ErrNotFound):
		// Another tenant's row is simply absent: 404, never 403.
		return repository.Document{}, fmt.Errorf("document %q: %w", id, ErrDocumentNotFound)
	case err != nil:
		return repository.Document{}, fmt.Errorf("find document: %w", err)
	}
	if !CanReadDocument(p, d) {
		return repository.Document{}, ErrForbidden
	}
	return d, nil
}
```

### `internal/transport/httpapi/documents.go`

```go
package httpapi

import (
	"context"
	"net/http"
	"regexp"

	"example.com/svc/internal/platform/auth"
	"example.com/svc/internal/repository"
)

// DocumentsService is what the handlers need. The concrete *service.Documents satisfies it.
type DocumentsService interface {
	Get(ctx context.Context, p auth.Principal, id string) (repository.Document, error)
}

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (a *API) getDocument(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !uuidRe.MatchString(id) { // validate at the edge; the service trusts its input
		writeProblem(w, r, http.StatusBadRequest, "id must be a UUID")
		return
	}
	p, ok := auth.FromContext(r.Context())
	if !ok { // a route wired without Authenticate: fail closed
		writeProblem(w, r, http.StatusUnauthorized, "")
		return
	}
	d, err := a.deps.Documents.Get(r.Context(), p, id)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": d.ID, "title": d.Title})
}
```

### Wiring in `server.go` and `main.go`

`Deps` gains `Documents DocumentsService` and `Verifier *auth.Verifier`. Protected routes go through one helper, so none is registered bare:

```go
// Everything that needs a token goes through `protected`. Deny by default: wire new routes here.
protected := chain(http.HandlerFunc(a.getDocument), a.deps.Verifier.Authenticate)
mux.Handle("GET /documents/{id}", protected)
```

`fail` maps the new domain errors, and `accessLog` logs 401 and 403 at `warn`:

```go
case errors.Is(err, service.ErrNoteNotFound), errors.Is(err, service.ErrDocumentNotFound):
	writeProblem(w, r, http.StatusNotFound, err.Error())
case errors.Is(err, service.ErrForbidden):
	writeProblem(w, r, http.StatusForbidden, "")
```

```go
level := slog.LevelInfo
if rec.status == http.StatusUnauthorized || rec.status == http.StatusForbidden {
	level = slog.LevelWarn // security events are warn or above (logging contract)
}
a.deps.Log.Log(r.Context(), level, "request", /* same attributes as before */)
```

`main.go` builds the verifier once. `oidc.NewRemoteKeySet` fetches lazily, so startup does not depend on the IdP. It keeps the context it is given and uses it for every later JWKS fetch, so pass a process-lifetime context, never one tied to startup or signals:

```go
verifier := auth.NewVerifier(auth.Config{
	Keys:        oidc.NewRemoteKeySet(context.Background(), cfg.OIDCJWKSURL),
	Issuer:      cfg.OIDCIssuer,
	Audience:    cfg.OIDCAudience,
	TenantClaim: cfg.OIDCTenantClaim,
	Skew:        30 * time.Second,
})
```

### BFF session: `internal/transport/httpapi/session.go`

Pair it with `golang.org/x/oauth2` and `oidc.Provider` for the code flow. Wire `setSessionCookies` into `/auth/callback` and wrap cookie-authenticated routes with `csrfDoubleSubmit`. Go 1.25 also ships `http.NewCrossOriginProtection()` (it rejects cross-origin unsafe requests by `Sec-Fetch-Site` and `Origin`); use it as a second layer, not instead of the token the frontend sends.

```go
package httpapi

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"time"
)

const sessionTTL = 8 * time.Hour

// setSessionCookies is called at login. The session ID is opaque and maps to server-side state
// that holds the tokens. The csrf cookie must be readable by JS, so it is not HttpOnly.
func setSessionCookies(w http.ResponseWriter, sessionID string) {
	http.SetCookie(w, &http.Cookie{
		Name: "__Host-sid", Value: sessionID, Path: "/", // __Host-: Secure, Path=/, no Domain
		HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode, MaxAge: int(sessionTTL.Seconds()),
	})
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // double-submit: JS must read this cookie, so no HttpOnly
		Name: "csrf", Value: base64.RawURLEncoding.EncodeToString(b), Path: "/",
		Secure: true, SameSite: http.SameSiteLaxMode, MaxAge: int(sessionTTL.Seconds()),
	})
}

// csrfDoubleSubmit matches the frontend fetcher: the csrf cookie must equal the X-CSRF-Token header
// on unsafe methods. Wrap only cookie-authenticated routes with it.
func csrfDoubleSubmit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			next.ServeHTTP(w, r)
			return
		}
		c, err := r.Cookie("csrf")
		header := r.Header.Get("X-CSRF-Token")
		if err != nil || c.Value == "" || subtle.ConstantTimeCompare([]byte(c.Value), []byte(header)) != 1 {
			writeProblem(w, r, http.StatusForbidden, "CSRF token missing or wrong")
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

### Tests

`tests/support/idp.go` signs real tokens with a throwaway ES256 key and returns a static key set:

```go
// Package support holds test-only helpers: containers, tokens, factories.
package support

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

const (
	Issuer   = "https://idp.test/"
	Audience = "api://test"
)

// IdP signs real tokens. Production verification code runs unchanged; only the key source differs.
type IdP struct{ key *ecdsa.PrivateKey }

func NewIdP(t testing.TB) *IdP {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &IdP{key: k}
}

func (i *IdP) Keys() oidc.KeySet {
	return &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{i.key.Public()}}
}

type Claims struct {
	Sub, Tenant, Scope, Aud string
	Expires                 time.Duration
}

func (i *IdP) Token(t testing.TB, c Claims) string {
	t.Helper()
	if c.Aud == "" {
		c.Aud = Audience
	}
	if c.Expires == 0 {
		c.Expires = 5 * time.Minute
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: i.key}, (&jose.SignerOptions{}).WithType("JWT"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	raw, err := jwt.Signed(signer).Claims(jwt.Claims{
		Issuer: Issuer, Subject: c.Sub, Audience: jwt.Audience{c.Aud},
		IssuedAt: jwt.NewNumericDate(now), Expiry: jwt.NewNumericDate(now.Add(c.Expires)),
	}).Claims(map[string]any{"tenant_id": c.Tenant, "scope": c.Scope}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
```

The route-protection table lives next to the handler tests:

```go
package httpapi_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Every route that needs a token, listed by hand: ServeMux cannot be enumerated.
// Add a protected route here in the same change that registers it.
var protectedRoutes = []struct{ method, path string }{
	{http.MethodGet, "/documents/5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10"},
}

func TestProtectedRoutesRejectMissingToken(t *testing.T) {
	for _, r := range protectedRoutes {
		t.Run(r.method+" "+r.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newAPI().Handler().ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), r.method, r.path, nil))
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", rec.Code)
			}
		})
	}
}
```

The tenant-isolation and error cases run against a real Postgres: `tests/documents_http_test.go` in [test-tracks.md](../configure-backend-tests/test-tracks.md).

## Python (FastAPI)

Add to `src/svc/config.py`, to `Settings`:

```python
oidc_issuer: HttpUrl
oidc_audience: str
oidc_jwks_url: HttpUrl
oidc_tenant_claim: str = "tenant_id"
```

Append to `src/svc/platform/problem.py`:

```python
def unauthenticated() -> AppError:
    return AppError(401, "Unauthorized")


def forbidden() -> AppError:
    return AppError(403, "Forbidden")
```

### `src/svc/platform/auth.py`

```python
from dataclasses import dataclass
from typing import Annotated, Protocol

import jwt
from fastapi import Depends, Request
from jwt import PyJWKClient, PyJWTError

from svc.platform.problem import unauthenticated


@dataclass(frozen=True, slots=True)
class Principal:
    """Who is calling. Built once here; routes and services never see the raw token."""

    sub: str
    tenant_id: str
    scopes: frozenset[str]

    def has_scope(self, scope: str) -> bool:
        return scope in self.scopes


class SigningKey(Protocol):
    @property
    def key(self) -> object: ...


class KeySource(Protocol):
    """PyJWKClient in production; a static key in tests."""

    def get_signing_key_from_jwt(self, token: str) -> SigningKey: ...


def remote_keys(jwks_url: str) -> PyJWKClient:
    return PyJWKClient(jwks_url, cache_keys=True, lifespan=600)


class Verifier:
    def __init__(self, *, keys: KeySource, issuer: str, audience: str, tenant_claim: str) -> None:
        self._keys = keys
        self._issuer = issuer
        self._audience = audience
        self._tenant_claim = tenant_claim

    def verify(self, token: str) -> Principal:
        """Blocking: PyJWKClient fetches the JWKS over urllib; call it from a sync dependency.
        Keys are cached for 600 s (see remote_keys), so only the first request per new key
        pays the fetch — size the threadpool for a concurrent key rotation."""
        key = self._keys.get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,  # type: ignore[arg-type]
            algorithms=["RS256", "ES256"],  # allow-list; never trust the token's own alg
            audience=self._audience,
            issuer=self._issuer,
            leeway=30,  # seconds of clock drift on exp, nbf and iat
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )
        tenant = claims.get(self._tenant_claim)
        if not isinstance(tenant, str) or not tenant:
            raise PyJWTError("missing tenant claim")
        scopes = frozenset(str(claims.get("scope", "")).split())
        return Principal(sub=str(claims["sub"]), tenant_id=tenant, scopes=scopes)


def current_principal(request: Request) -> Principal:
    # A plain `def`: FastAPI runs it in the threadpool, so the JWKS fetch cannot block the loop.
    scheme, _, token = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise unauthenticated()
    verifier: Verifier = request.app.state.verifier
    try:
        principal = verifier.verify(token)
    except PyJWTError:
        raise unauthenticated() from None
    request.state.principal = principal  # for the rate limiter key
    return principal


CurrentPrincipal = Annotated[Principal, Depends(current_principal)]
```

### `src/svc/service/documents_policy.py`

```python
from svc.platform.auth import Principal
from svc.repository.documents import Document


# Policies are pure functions of (principal, resource). Nothing is allowed unless one says so.
def can_read(p: Principal, d: Document) -> bool:
    return p.tenant_id == d.tenant_id and p.has_scope("documents:read")


def can_update(p: Principal, d: Document) -> bool:
    return p.tenant_id == d.tenant_id and p.has_scope("documents:write") and d.owner_id == p.sub
```

### `src/svc/repository/documents.py`

```python
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


@dataclass(frozen=True, slots=True)
class Document:
    id: str
    tenant_id: str
    owner_id: str
    title: str


class DocumentsRepository:
    """Exists for one tenant: no constructor without a tenant ID, and no method that takes one."""

    def __init__(self, session: AsyncSession, tenant_id: str) -> None:
        self._session = session
        self._tenant_id = tenant_id

    async def find_by_id(self, doc_id: str) -> Document | None:
        row = (
            await self._session.execute(
                text(
                    "SELECT id::text, tenant_id, owner_id, title FROM documents "
                    "WHERE tenant_id = :tenant_id AND id = :id"
                ),
                {
                    "tenant_id": self._tenant_id,
                    "id": UUID(doc_id),
                },  # bound parameters, never string-built SQL
            )
        ).one_or_none()
        return Document(*row) if row else None
```

### `src/svc/service/documents.py`

```python
from typing import Protocol

from svc.platform.auth import Principal
from svc.platform.problem import AppError, forbidden
from svc.repository.documents import Document
from svc.service.documents_policy import can_read


class DocumentStore(Protocol):
    async def find_by_id(self, doc_id: str) -> Document | None: ...


class DocumentsService:
    """Use cases. Imports no FastAPI or Starlette types."""

    def __init__(self, store: DocumentStore) -> None:
        self._store = store

    async def get(self, principal: Principal, doc_id: str) -> Document:
        doc = await self._store.find_by_id(doc_id)
        if doc is None:
            # Another tenant's row is simply absent: 404, never 403.
            raise AppError(404, "Not Found", "Document does not exist")
        if not can_read(principal, doc):
            raise forbidden()
        return doc
```

### `src/svc/transport/documents.py`

The router-level dependency is the deny-by-default switch: every route added to this router needs a valid token.

```python
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Path, Request
from slowapi import Limiter
from slowapi.util import get_remote_address
from sqlalchemy.ext.asyncio import AsyncSession

from svc.platform.auth import CurrentPrincipal, current_principal
from svc.platform.db import get_session
from svc.platform.problem import PROBLEM_CONTENT_TYPE, Problem
from svc.repository.documents import DocumentsRepository
from svc.service.documents import DocumentsService
from svc.transport.schemas import DocumentOut

# Router-level dependency: every route added here needs a valid token. Deny by default.
router = APIRouter(tags=["documents"], dependencies=[Depends(current_principal)])

problem = {"model": Problem, "content": {PROBLEM_CONTENT_TYPE: {}}}


def caller_key(request: Request) -> str:
    principal = getattr(request.state, "principal", None)
    if principal is not None:
        return principal.sub  # set by current_principal; per caller, IPs are shared behind NAT
    return get_remote_address(request)  # no principal on this request: fall back to the address


limiter = Limiter(key_func=caller_key)


def get_documents_service(
    session: Annotated[AsyncSession, Depends(get_session)], principal: CurrentPrincipal
) -> DocumentsService:
    return DocumentsService(DocumentsRepository(session, principal.tenant_id))


@router.get(
    "/documents/{doc_id}",
    response_model=DocumentOut,
    responses={401: problem, 403: problem, 404: problem, 429: problem},
)
@limiter.limit("120/minute")
async def get_document(
    request: Request,  # slowapi needs the request in the signature
    doc_id: Annotated[UUID, Path()],
    principal: CurrentPrincipal,
    service: Annotated[DocumentsService, Depends(get_documents_service)],
) -> DocumentOut:
    doc = await service.get(principal, str(doc_id))
    return DocumentOut(id=doc.id, title=doc.title)
```

### Wiring

`create_app` builds the verifier and takes the key source as an argument, so tests do not touch the network:

```python
def create_app(settings: Settings, *, keys: KeySource | None = None) -> FastAPI:
    ...
    app.state.verifier = Verifier(
        keys=keys or remote_keys(str(settings.oidc_jwks_url)),
        issuer=str(settings.oidc_issuer),
        audience=settings.oidc_audience,
        tenant_claim=settings.oidc_tenant_claim,
    )
    ...
    app.include_router(documents.router)
```

In `transport/errors.py`, the `AppError` handler adds the challenge header and logs denials. structlog reserves the `event` key for the message, so the log carries status and path only:

```python
@app.exception_handler(AppError)
async def _app_error(request: Request, exc: AppError) -> JSONResponse:
    if exc.status in (HTTP_401_UNAUTHORIZED, HTTP_403_FORBIDDEN):
        log.warning(
            "access denied",
            **{"http.response.status_code": exc.status, "url.path": request.url.path},
        )
    headers = {"WWW-Authenticate": "Bearer"} if exc.status == HTTP_401_UNAUTHORIZED else None
    return _problem(request, exc.status, exc.title, exc.detail, headers)
```

`_problem` takes a `headers` argument and passes it to `JSONResponse`.

### BFF session: `src/svc/platform/session.py`

Pair it with Authlib's Starlette client for the code flow. Add `Depends(csrf_double_submit)` to cookie-authenticated routers.

```python
import secrets

from fastapi import Request, Response

from svc.platform.problem import forbidden

SESSION_TTL_SECONDS = 8 * 60 * 60
UNSAFE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def set_session_cookies(response: Response, session_id: str) -> None:
    """Called at login. The session ID is opaque; the tokens stay in server-side state.
    The csrf cookie must be readable by JS, so it is not HttpOnly."""
    response.set_cookie(
        "__Host-sid",  # __Host-: Secure, Path=/, no Domain
        session_id,
        max_age=SESSION_TTL_SECONDS,
        path="/",
        secure=True,
        httponly=True,
        samesite="lax",
    )
    response.set_cookie(
        "csrf",
        secrets.token_urlsafe(32),
        max_age=SESSION_TTL_SECONDS,
        path="/",
        secure=True,
        httponly=False,
        samesite="lax",
    )


def csrf_double_submit(request: Request) -> None:
    """Dependency, matching the frontend fetcher: the csrf cookie must equal X-CSRF-Token on
    unsafe methods. Add it only to cookie-authenticated routers."""
    if request.method not in UNSAFE_METHODS:
        return
    cookie = request.cookies.get("csrf", "")
    header = request.headers.get("x-csrf-token", "")
    if not cookie or not secrets.compare_digest(cookie, header):
        raise forbidden()
```

### Tests

`tests/support/idp.py` signs real tokens with a throwaway key and satisfies the `KeySource` protocol:

```python
import time
from dataclasses import dataclass

import jwt
from cryptography.hazmat.primitives.asymmetric import ec

ISSUER = "https://idp.test/"
AUDIENCE = "api://test"


@dataclass(frozen=True)
class _Key:
    key: object


class TestIdp:
    """Signs real tokens. Only the key source differs: `svc.platform.auth` runs unchanged."""

    __test__ = False

    def __init__(self) -> None:
        self._private = ec.generate_private_key(ec.SECP256R1())

    def get_signing_key_from_jwt(self, token: str) -> _Key:  # the KeySource protocol
        return _Key(self._private.public_key())

    def token(
        self,
        *,
        sub: str = "u-1",
        tenant: str = "t-1",
        scope: str = "documents:read",
        aud: str = AUDIENCE,
        expires_in: int = 300,
    ) -> str:
        now = int(time.time())
        claims = {
            "iss": ISSUER, "aud": aud, "sub": sub, "iat": now, "exp": now + expires_in,
            "tenant_id": tenant, "scope": scope,
        }  # fmt: skip
        return jwt.encode(claims, self._private, algorithm="ES256", headers={"kid": "test"})
```

The route-protection test (in `tests/unit/test_app.py`, with `import re`) walks the generated OpenAPI document:

```python
async def test_every_operation_outside_the_public_list_requires_a_token(
    client: AsyncClient,
) -> None:
    # The complete list of routes callable without a token. Adding one is a reviewed change.
    public = {"GET /healthz", "GET /readyz", "GET /notes/{note_id}"}
    spec = (await client.get("/openapi.json")).json()
    unprotected: list[str] = []
    for path, methods in spec["paths"].items():
        for method in methods:
            key = f"{method.upper()} {path}"
            if key in public:
                continue
            url = re.sub(r"\{[^}]+\}", "5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10", path)
            status = (await client.request(method.upper(), url)).status_code
            if status != 401:
                unprotected.append(f"{key} -> {status}")
    assert unprotected == []
```

The tenant-isolation and error cases run against a real Postgres: `tests/integration/test_documents_http.py` in [test-tracks.md](../configure-backend-tests/test-tracks.md).
