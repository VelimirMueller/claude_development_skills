# Backend Tests: Code per Track

Companion to [configure-backend-tests](SKILL.md). Every file ran on 2026-10-09 inside the scaffolds of [scaffold-hono-service](../scaffold-hono-service/SKILL.md), [scaffold-go-service](../scaffold-go-service/SKILL.md) and [scaffold-fastapi-service](../scaffold-fastapi-service/SKILL.md): `tsc --noEmit`, `biome check`, `vitest run` (3 unit files + 1 integration file, all green); `go vet`, `golangci-lint`, `go test ./...` against a real Postgres 18 container; `ruff`, `mypy --strict`, `pytest` against the same. Versions: [stack-versions.md](../_shared/stack-versions.md). Paths follow [service-layout.md](../_shared/service-layout.md); `svc` is the placeholder package name.

The seams are the same in all three tracks: the container and its URL come from a support module, the IdP signs real tokens with a throwaway key, and the composition root builds the real app. Only the key source and the database are test-owned.

## TypeScript (Hono)

The scaffold ships `tests/app.test.ts` under one flat config. This skill moves it to `tests/unit/app.test.ts`: every `../src/…` import gains one more `../`, and `createApp`'s deps gain three entries (the auth-hardened app requires them), exactly as in the worked example:

```ts
    documents: createDocumentsService({
      documentsFor: () => ({ findById: async () => undefined }),
    }),
    auth: createAuth({
      keys: createLocalJWKSet({ keys: [] }),
      issuer: 'x',
      audience: 'x',
      tenantClaim: 'tenant_id',
    }),
    allowedOrigins: [],
```

### `vitest.config.ts`

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    env: { OTEL_SDK_DISABLED: 'true' },
    projects: [
      { extends: true, test: { name: 'unit', include: ['tests/unit/**/*.test.ts'] } },
      {
        extends: true,
        test: {
          name: 'integration',
          include: ['tests/integration/**/*.test.ts'],
          globalSetup: ['tests/support/global-setup.ts'],
          hookTimeout: 60_000,
        },
      },
    ],
  },
});
```

`tests.layout: colocated` changes the unit project's `include` to `src/**/*.test.ts`; the integration project stays as is.

### `tests/support/global-setup.ts`

```ts
// One Postgres container per test run, shared by every integration file. Migrated once.
import { readFileSync } from 'node:fs';
import { PostgreSqlContainer } from '@testcontainers/postgresql';
import pg from 'pg';
import type { TestProject } from 'vitest/node';

declare module 'vitest' {
  export interface ProvidedContext {
    databaseUrl: string;
  }
}

export default async function setup(project: TestProject) {
  const container = await new PostgreSqlContainer('postgres:18').start();
  const url = container.getConnectionUri();

  const client = new pg.Client({ connectionString: url });
  await client.connect();
  await client.query(readFileSync('drizzle/0000_init.sql', 'utf8')); // run your real migrations here
  await client.end();

  project.provide('databaseUrl', url);
  return () => container.stop();
}
```

### `tests/support/db.ts`

```ts
import { drizzle } from 'drizzle-orm/node-postgres';
import pg from 'pg';
import { afterAll, beforeEach, inject } from 'vitest';

/** A real database for this test file. Tables are emptied before every test, so tests stay independent. */
export function useTestDb() {
  const pool = new pg.Pool({ connectionString: inject('databaseUrl') });
  const db = drizzle(pool);

  beforeEach(async () => {
    const { rows } = await pool.query<{ tablename: string }>(
      `SELECT tablename FROM pg_tables WHERE schemaname = 'public'`,
    );
    if (rows.length > 0) {
      const names = rows.map((r) => `"${r.tablename}"`).join(', ');
      await pool.query(`TRUNCATE ${names} RESTART IDENTITY CASCADE`);
    }
  });
  afterAll(() => pool.end());

  return db;
}
```

### `tests/support/idp.ts`

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

### `tests/support/app.ts`

```ts
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { createApp } from '../../src/app.ts';
import { createAuth } from '../../src/platform/auth.ts';
import { createLogger } from '../../src/platform/logger.ts';
import { createDocumentsRepository } from '../../src/repository/documents.repository.ts';
import { createInMemoryNotesRepository } from '../../src/repository/notes.repository.ts';
import { createDocumentsService } from '../../src/service/documents.service.ts';
import { createNotesService } from '../../src/service/notes.service.ts';
import { type createTestIdp, TEST_AUDIENCE, TEST_ISSUER } from './idp.ts';

/** The real app with real parts. Only the key source and the database are test-owned. */
export function buildApp(idp: Awaited<ReturnType<typeof createTestIdp>>, db: NodePgDatabase) {
  return createApp({
    logger: createLogger({
      LOG_LEVEL: 'silent',
      OTEL_SERVICE_NAME: 'test',
      DEPLOYMENT_ENVIRONMENT: 'development',
    }),
    notes: createNotesService({ notes: createInMemoryNotesRepository() }),
    documents: createDocumentsService({
      documentsFor: (scope) => createDocumentsRepository(db, scope),
    }),
    auth: createAuth({
      keys: idp.keys,
      issuer: TEST_ISSUER,
      audience: TEST_AUDIENCE,
      tenantClaim: 'tenant_id',
    }),
    allowedOrigins: ['https://app.test'],
    readinessChecks: [],
    isShuttingDown: () => false,
  });
}
```

### `tests/support/factories.ts`

```ts
import { randomUUID } from 'node:crypto';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { documents } from '../../src/repository/documents.repository.ts';

/** Valid by default; each test overrides only what it is about. */
export async function insertDocument(
  db: NodePgDatabase,
  overrides: Partial<typeof documents.$inferInsert> = {},
) {
  const [row] = await db
    .insert(documents)
    .values({
      id: randomUUID(),
      tenantId: 't-1',
      ownerId: 'u-1',
      title: 'Quarterly plan',
      ...overrides,
    })
    .returning();
  if (!row) throw new Error('insert failed');
  return row;
}
```

### `tests/unit/documents.policy.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import type { Principal } from '../../src/platform/auth.ts';
import { documentPolicy } from '../../src/service/documents.policy.ts';

const principal = (over: Partial<Principal> = {}): Principal => ({
  sub: 'u-1',
  tenantId: 't-1',
  scopes: new Set(['documents:read']),
  ...over,
});
const doc = { tenantId: 't-1', ownerId: 'u-1' };

describe('documentPolicy.read', () => {
  it('read - same tenant with scope - allowed', () => {
    expect(documentPolicy.read(principal(), doc)).toBe(true);
  });
  it('read - other tenant - denied', () => {
    expect(documentPolicy.read(principal({ tenantId: 't-2' }), doc)).toBe(false);
  });
  it('read - no scope - denied', () => {
    expect(documentPolicy.read(principal({ scopes: new Set() }), doc)).toBe(false);
  });
});
```

### `tests/integration/documents.http.test.ts`

```ts
import { beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../support/app.ts';
import { useTestDb } from '../support/db.ts';
import { insertDocument } from '../support/factories.ts';
import { createTestIdp } from '../support/idp.ts';

const db = useTestDb();
let idp: Awaited<ReturnType<typeof createTestIdp>>;
let app: ReturnType<typeof buildApp>;

beforeAll(async () => {
  idp = await createTestIdp();
  app = buildApp(idp, db);
});

const get = (path: string, token?: string) =>
  app.request(path, { headers: token ? { authorization: `Bearer ${token}` } : {} });

describe('GET /documents/:id', () => {
  it('GET - own tenant document - 200 with the document', async () => {
    const doc = await insertDocument(db, { tenantId: 't-1' });
    const res = await get(`/documents/${doc.id}`, await idp.tokenFor());
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ id: doc.id, title: 'Quarterly plan' });
  });

  it('GET - other tenant document - 404, not 403', async () => {
    const doc = await insertDocument(db, { tenantId: 't-2' });
    expect((await get(`/documents/${doc.id}`, await idp.tokenFor())).status).toBe(404);
  });

  it('GET - same tenant without scope - 403', async () => {
    const doc = await insertDocument(db, { tenantId: 't-1' });
    const res = await get(`/documents/${doc.id}`, await idp.tokenFor({ scope: '' }));
    expect(res.status).toBe(403);
  });

  it('GET - no token - 401 with WWW-Authenticate', async () => {
    const res = await get('/documents/5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10');
    expect(res.status).toBe(401);
    expect(res.headers.get('www-authenticate')).toBe('Bearer');
  });

  it('GET - token for another audience - 401', async () => {
    const token = await idp.tokenWith({ sub: 'u-1', tenant_id: 't-1' }, { aud: 'api://other' });
    expect((await get('/documents/5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10', token)).status).toBe(401);
  });

  it('GET - malformed id - 400 problem+json', async () => {
    const res = await get('/documents/not-a-uuid', await idp.tokenFor());
    expect(res.status).toBe(400);
    expect(res.headers.get('content-type')).toContain('application/problem+json');
  });
});
```

### `drizzle/0000_init.sql`

```sql
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  owner_id text NOT NULL,
  title text NOT NULL
);
```

## Go

Unit tests sit beside the code; the container-backed tests sit in `tests/`. The two unit examples use the scaffold's `server_test.go` (`newAPI()` lives there).

### `tests/support/db.go`

```go
package support

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
)

// StartPostgres starts one real Postgres for the package, migrates it, and returns a pool.
// Call it from TestMain and call the returned stop func after m.Run().
func StartPostgres(ctx context.Context, migrationFiles ...string) (*pgxpool.Pool, func(), error) {
	ctr, err := postgres.Run(ctx, "postgres:18", postgres.BasicWaitStrategies())
	if err != nil {
		return nil, nil, err
	}
	url, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		return nil, nil, err
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, nil, err
	}
	for _, f := range migrationFiles { // run your real migrations here (goose, atlas, ...)
		sql, err := os.ReadFile(f) //nolint:gosec // test-only: paths come from the test's own code
		if err != nil {
			return nil, nil, err
		}
		if _, err := pool.Exec(ctx, string(sql)); err != nil {
			return nil, nil, err
		}
	}
	return pool, func() { pool.Close(); _ = ctr.Terminate(ctx) }, nil
}

// Truncate empties every public table. Call it at the start of each test.
func Truncate(t testing.TB, pool *pgxpool.Pool) {
	t.Helper()
	_, err := pool.Exec(context.Background(), `
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('TRUNCATE %I RESTART IDENTITY CASCADE', r.tablename);
  END LOOP;
END $$`)
	if err != nil {
		t.Fatal(err)
	}
}
```

### `tests/support/idp.go`

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

### `tests/support/factories.go`

```go
package support

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

type DocumentOpt func(*documentRow)

type documentRow struct{ ID, TenantID, OwnerID, Title string }

func WithTenant(id string) DocumentOpt { return func(d *documentRow) { d.TenantID = id } }

// InsertDocument is valid by default; each test overrides only what it is about.
func InsertDocument(t testing.TB, pool *pgxpool.Pool, opts ...DocumentOpt) string {
	t.Helper()
	d := documentRow{TenantID: "t-1", OwnerID: "u-1", Title: "Quarterly plan"}
	for _, o := range opts {
		o(&d)
	}
	var id string
	err := pool.QueryRow(context.Background(),
		`INSERT INTO documents (tenant_id, owner_id, title) VALUES ($1, $2, $3) RETURNING id`,
		d.TenantID, d.OwnerID, d.Title).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	return id
}
```

### `tests/documents_http_test.go`

```go
package tests

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"example.com/svc/internal/platform/auth"
	"example.com/svc/internal/repository"
	"example.com/svc/internal/service"
	"example.com/svc/internal/transport/httpapi"
	"example.com/svc/tests/support"
)

var pool *pgxpool.Pool

func TestMain(m *testing.M) {
	p, stop, err := support.StartPostgres(context.Background(), "../migrations/0001_init.sql")
	if err != nil {
		panic(err)
	}
	pool = p
	code := m.Run()
	stop()
	os.Exit(code)
}

func newServer(t *testing.T) (*httptest.Server, *support.IdP) {
	t.Helper()
	support.Truncate(t, pool)
	idp := support.NewIdP(t)
	api := httpapi.New(httpapi.Deps{
		Log:   slog.New(slog.DiscardHandler),
		Notes: service.NewNotes(repository.NewNotesMemory()),
		Documents: service.NewDocuments(func(tenantID string) service.DocumentStore {
			return repository.NewDocuments(pool, tenantID)
		}),
		Verifier: auth.NewVerifier(auth.Config{
			Keys: idp.Keys(), Issuer: support.Issuer, Audience: support.Audience,
			TenantClaim: "tenant_id", Skew: 30 * time.Second,
		}),
		AllowedOrigins: []string{"https://app.test"},
	})
	srv := httptest.NewServer(api.Handler())
	t.Cleanup(srv.Close)
	return srv, idp
}

// status performs the request and returns only the status code, so no body is left open.
func status(t *testing.T, srv *httptest.Server, path, token string) int {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	return res.StatusCode
}

func TestGetDocument(t *testing.T) {
	const noDoc = "/documents/5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10"
	tests := []struct {
		name  string
		setup func(t *testing.T, idp *support.IdP) (path, token string)
		want  int
	}{
		{"GET - own tenant document - 200", func(t *testing.T, idp *support.IdP) (string, string) {
			id := support.InsertDocument(t, pool, support.WithTenant("t-1"))
			return "/documents/" + id, idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1", Scope: "documents:read"})
		}, http.StatusOK},
		{"GET - other tenant document - 404 not 403", func(t *testing.T, idp *support.IdP) (string, string) {
			id := support.InsertDocument(t, pool, support.WithTenant("t-2"))
			return "/documents/" + id, idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1", Scope: "documents:read"})
		}, http.StatusNotFound},
		{"GET - no token - 401", func(*testing.T, *support.IdP) (string, string) { return noDoc, "" }, http.StatusUnauthorized},
		{"GET - wrong audience - 401", func(t *testing.T, idp *support.IdP) (string, string) {
			return noDoc, idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1", Aud: "api://other"})
		}, http.StatusUnauthorized},
		{"GET - expired beyond skew - 401", func(t *testing.T, idp *support.IdP) (string, string) {
			return noDoc, idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1", Expires: -time.Minute})
		}, http.StatusUnauthorized},
		{"GET - missing scope - 403", func(t *testing.T, idp *support.IdP) (string, string) {
			id := support.InsertDocument(t, pool)
			return "/documents/" + id, idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1"})
		}, http.StatusForbidden},
		{"GET - malformed id - 400", func(t *testing.T, idp *support.IdP) (string, string) {
			return "/documents/nope", idp.Token(t, support.Claims{Sub: "u-1", Tenant: "t-1", Scope: "documents:read"})
		}, http.StatusBadRequest},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, idp := newServer(t)
			path, token := tc.setup(t, idp)
			if got := status(t, srv, path, token); got != tc.want {
				t.Fatalf("status = %d, want %d", got, tc.want)
			}
		})
	}
}
```

### `migrations/0001_init.sql`

```sql
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  owner_id text NOT NULL,
  title text NOT NULL
);
```

### `internal/transport/httpapi/decode_test.go` (unit, beside the code)

```go
package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecodeJSON(t *testing.T) {
	type input struct {
		Title string `json:"title"`
	}
	tests := []struct {
		name, body string
		limit      int64
		want       int
	}{
		{"valid body - accepted", `{"title":"a"}`, 1 << 10, http.StatusOK},
		{"unknown field - 400", `{"title":"a","admin":true}`, 1 << 10, http.StatusBadRequest},
		{"trailing data - 400", `{"title":"a"}{"title":"b"}`, 1 << 10, http.StatusBadRequest},
		{"not JSON - 400", `nope`, 1 << 10, http.StatusBadRequest},
		{"body over the limit - 413", `{"title":"` + strings.Repeat("a", 100) + `"}`, 16, http.StatusRequestEntityTooLarge},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				r.Body = http.MaxBytesReader(w, r.Body, tc.limit)
				var in input
				if decodeJSON(w, r, &in) {
					w.WriteHeader(http.StatusOK)
				}
			})
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/x", strings.NewReader(tc.body)))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}
```

### `internal/transport/httpapi/protected_test.go` (unit, beside the code)

Uses the `newAPI()` helper from the scaffold's `server_test.go` in the same package.

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

## Python

The tests directories are packages (`__init__.py` in `tests`, `tests/unit`, `tests/integration`, `tests/support`) so `tests.support` imports resolve. The scaffold's `[tool.pytest.ini_options]` block gains the marker line:

### `pyproject.toml` (pytest section, as modified)

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["integration: needs Docker (real Postgres)"]
asyncio_mode = "auto"
asyncio_default_fixture_loop_scope = "function"
```

### `tests/conftest.py`

```python
import os

# Before any svc import: tests never export telemetry.
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
```

### `tests/integration/conftest.py`

```python
from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from testcontainers.community.postgres import PostgresContainer

from svc.app import create_app
from tests.support.idp import TestIdp
from tests.support.settings import make_settings

MIGRATIONS = Path(__file__).parents[2] / "migrations"


@pytest.fixture(scope="session")
def database_url() -> Iterator[str]:
    """One real Postgres per test run, migrated once."""
    with PostgresContainer("postgres:18", driver="psycopg") as pg:
        url = pg.get_connection_url()  # postgresql+psycopg:// — the app driver already
        sync_engine = create_engine(url)
        with sync_engine.begin() as conn:  # run your real migrations here (alembic upgrade head)
            for sql in sorted(MIGRATIONS.glob("*.sql")):
                conn.execute(text(sql.read_text()))
        sync_engine.dispose()
        yield url


@pytest.fixture
async def engine(database_url: str) -> AsyncIterator[AsyncEngine]:
    eng = create_async_engine(database_url)
    async with eng.begin() as conn:  # tests stay independent: empty tables before each one
        await conn.execute(text("TRUNCATE documents RESTART IDENTITY CASCADE"))
    yield eng
    await eng.dispose()


@pytest.fixture
def idp() -> TestIdp:
    return TestIdp()


@pytest.fixture
async def client(database_url: str, idp: TestIdp) -> AsyncIterator[AsyncClient]:
    settings = make_settings(database_url=database_url)  # any scheme: create_engine normalizes to psycopg
    app = create_app(settings, keys=idp)
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c,
    ):
        yield c
```

### `tests/support/settings.py`

```python
from svc.config import Settings


def make_settings(**overrides: object) -> Settings:
    """Valid settings without reading .env or the process environment."""
    values: dict[str, object] = {
        "oidc_issuer": "https://idp.test/",
        "oidc_audience": "api://test",
        "oidc_jwks_url": "https://idp.test/jwks",
        "cors_allowed_origins": ["https://app.test"],
        **overrides,
    }
    return Settings(_env_file=None, **values)  # type: ignore[arg-type]
```

### `tests/support/idp.py`

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

### `tests/support/factories.py`

```python
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine


async def insert_document(
    engine: AsyncEngine,
    *,
    tenant_id: str = "t-1",
    owner_id: str = "u-1",
    title: str = "Quarterly plan",
) -> str:
    """Valid by default; each test overrides only what it is about."""
    async with engine.begin() as conn:
        result = await conn.execute(
            text(
                "INSERT INTO documents (tenant_id, owner_id, title) "
                "VALUES (:tenant_id, :owner_id, :title) RETURNING id::text"
            ),
            {"tenant_id": tenant_id, "owner_id": owner_id, "title": title},
        )
        return str(result.scalar_one())
```

### `tests/integration/test_documents_http.py`

```python
import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.support.factories import insert_document
from tests.support.idp import TestIdp

pytestmark = pytest.mark.integration

NO_DOC = "/documents/5b1d6f0e-3f77-4f3e-9d6a-1f6f2b1c9a10"


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def test_get_document__own_tenant__200_with_document(
    client: AsyncClient, engine: AsyncEngine, idp: TestIdp
) -> None:
    doc_id = await insert_document(engine, tenant_id="t-1")
    res = await client.get(f"/documents/{doc_id}", headers=bearer(idp.token()))
    assert res.status_code == 200
    assert res.json() == {"id": doc_id, "title": "Quarterly plan"}


async def test_get_document__other_tenant__404_not_403(
    client: AsyncClient, engine: AsyncEngine, idp: TestIdp
) -> None:
    doc_id = await insert_document(engine, tenant_id="t-2")
    res = await client.get(f"/documents/{doc_id}", headers=bearer(idp.token(tenant="t-1")))
    assert res.status_code == 404


async def test_get_document__same_tenant_without_scope__403(
    client: AsyncClient, engine: AsyncEngine, idp: TestIdp
) -> None:
    doc_id = await insert_document(engine, tenant_id="t-1")
    res = await client.get(f"/documents/{doc_id}", headers=bearer(idp.token(scope="")))
    assert res.status_code == 403


async def test_get_document__no_token__401_with_www_authenticate(client: AsyncClient) -> None:
    res = await client.get(NO_DOC)
    assert res.status_code == 401
    assert res.headers["www-authenticate"] == "Bearer"


async def test_get_document__wrong_audience__401(client: AsyncClient, idp: TestIdp) -> None:
    res = await client.get(NO_DOC, headers=bearer(idp.token(aud="api://other")))
    assert res.status_code == 401


async def test_get_document__expired_beyond_leeway__401(client: AsyncClient, idp: TestIdp) -> None:
    res = await client.get(NO_DOC, headers=bearer(idp.token(expires_in=-60)))
    assert res.status_code == 401


async def test_get_document__malformed_id__400_problem_json(
    client: AsyncClient, idp: TestIdp
) -> None:
    res = await client.get("/documents/nope", headers=bearer(idp.token()))
    assert res.status_code == 400
    assert res.headers["content-type"].startswith("application/problem+json")
```

### `tests/unit/test_documents_policy.py`

```python
from svc.platform.auth import Principal
from svc.repository.documents import Document
from svc.service.documents_policy import can_read

DOC = Document(id="d-1", tenant_id="t-1", owner_id="u-1", title="x")
READ = frozenset({"documents:read"})


def principal(*, tenant_id: str = "t-1", scopes: frozenset[str] = READ) -> Principal:
    return Principal(sub="u-1", tenant_id=tenant_id, scopes=scopes)


def test_can_read__same_tenant_with_scope__allowed() -> None:
    assert can_read(principal(), DOC)


def test_can_read__other_tenant__denied() -> None:
    assert not can_read(principal(tenant_id="t-2"), DOC)


def test_can_read__no_scope__denied() -> None:
    assert not can_read(principal(scopes=frozenset()), DOC)
```

### `migrations/0001_init.sql`

Same SQL as the Go track's file above; the Python scaffold's `migrations/` directory uses the same numbering.

```sql
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id text NOT NULL,
  owner_id text NOT NULL,
  title text NOT NULL
);
```

## CI job

One job per track — keep the matching one, delete the other two. The pins and their version comments come from this repo's verified security workflow. The `ubuntu-latest` runners have Docker, and testcontainers starts its own Postgres: no service container, no Postgres step. Node comes with the runner; if it no longer satisfies `engines.node`, add a SHA-pinned `actions/setup-node` that reads `.nvmrc`.

```yaml
name: tests

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  hono:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413 # v6.1.0
      - run: pnpm install --frozen-lockfile
      - run: pnpm test            # unit fails fast; integration joins in the same job (Docker present)
      - run: pnpm openapi && diff openapi.json contracts/openapi.json   # spec drift

  go:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with:
          go-version-file: go.mod
      - run: go test ./...

  fastapi:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
      - run: uv sync
      - run: uv run pytest         # unit fail fast, integration after (Docker present)
```

Contract conformance appends to the matching job once the app serves `/openapi.json` (schemathesis is a Python CLI; `uvx` runs it in any job, FastAPI's own job needs no extra setup):

```yaml
      - name: contract conformance
        run: |
          cp .env.example .env      # dummy values pass config validation; the JWKS fetch is lazy
          uv run fastapi run --port 8080 &
          uvx schemathesis run http://localhost:8080/openapi.json \
            --checks all -n 25 --exclude-path '/documents/{doc_id}' --wait-for-schema 30
          # protected endpoints: add -H "Authorization: Bearer $TOKEN"
```
