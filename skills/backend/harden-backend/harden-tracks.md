# Harden Backend: Code per Track

Companion to [harden-backend](SKILL.md). Every file ran on 2026-10-09 inside the scaffolds of [scaffold-hono-service](../scaffold-hono-service/SKILL.md), [scaffold-go-service](../scaffold-go-service/SKILL.md) and [scaffold-fastapi-service](../scaffold-fastapi-service/SKILL.md): `tsc --noEmit`, `biome check`, `vitest run`; `go vet`, `golangci-lint`, `go test`; `ruff`, `mypy --strict`, `pytest`. The CI workflow passes actionlint and zizmor v1.30.1 with no findings. Versions: [stack-versions.md](../_shared/stack-versions.md). Package paths follow [service-layout.md](../_shared/service-layout.md); `svc` is the placeholder package name.

## TypeScript (Hono)

### `src/transport/edge.ts`

```ts
import type { Env, Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { timeout } from 'hono/timeout';
import { rateLimiter } from 'hono-rate-limiter';
import type { AuthEnv } from '../platform/auth.ts';
import { PROBLEM_CONTENT_TYPE } from '../platform/problem.ts';

export type EdgeOptions = { allowedOrigins: string[]; maxBodyBytes?: number; timeoutMs?: number };

/** Edge defaults for an API: nothing to render, nothing to embed, bounded input and time. */
export function applyEdge<E extends Env>(app: Hono<E>, opts: EdgeOptions) {
  app.use(
    secureHeaders({
      contentSecurityPolicy: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] },
      strictTransportSecurity: 'max-age=63072000; includeSubDomains',
      referrerPolicy: 'no-referrer',
    }),
  );
  app.use(
    cors({
      origin: opts.allowedOrigins, // exact allow-list; never '*' with credentials
      credentials: true,
      allowMethods: ['GET', 'POST', 'PATCH', 'DELETE'],
      maxAge: 600,
    }),
  );
  app.use(
    bodyLimit({
      maxSize: opts.maxBodyBytes ?? 1024 * 1024,
      onError: (c) =>
        c.newResponse(
          JSON.stringify({ type: 'about:blank', title: 'Payload Too Large', status: 413 }),
          413,
          {
            'Content-Type': PROBLEM_CONTENT_TYPE,
          },
        ),
    }),
  );
  app.use(timeout(opts.timeoutMs ?? 10_000)); // throws HTTPException(504), mapped in app.onError
}

/** Per-caller limit for authenticated routes: IPs are shared behind NAT, the subject is not.
 *  The counter lives in this process. Behind N replicas the real limit is N times higher:
 *  enforce a global limit at the proxy, and keep this one as a second layer. */
export const callerRateLimit = (opts: { limit: number; windowMs: number }) =>
  rateLimiter<AuthEnv>({
    windowMs: opts.windowMs,
    limit: opts.limit,
    standardHeaders: 'draft-6',
    keyGenerator: (c) => c.get('principal').sub,
  });
```

### `src/platform/ssrf.ts`

```ts
// The only way the service fetches a URL it did not hardcode.
import { lookup as dnsLookup, type LookupAddress } from 'node:dns';
import { BlockList, isIP } from 'node:net';
import { Agent, fetch, type RequestInit } from 'undici';

const blocked = new BlockList();
for (const [net, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
] as const) {
  blocked.addSubnet(net, prefix, 'ipv4');
}
for (const [net, prefix] of [
  ['::', 128],
  ['::1', 128],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
] as const) {
  blocked.addSubnet(net, prefix, 'ipv6');
}

const isBlocked = (address: string) => {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address)?.[1]; // ::ffff:10.0.0.1 is 10.0.0.1
  return mapped
    ? blocked.check(mapped, 'ipv4')
    : blocked.check(address, isIP(address) === 6 ? 'ipv6' : 'ipv4');
};

// The check runs at connect time, on the address the socket will really use. That defeats DNS rebinding.
const dispatcher = new Agent({
  connect: {
    lookup(hostname, options, callback) {
      dnsLookup(hostname, { ...options, all: true }, (err, addresses) => {
        const list = addresses as LookupAddress[] | undefined;
        if (err || !list) return callback(err, '', 4);
        if (list.some((a) => isBlocked(a.address))) {
          return callback(new Error('ssrf: blocked address'), '', 4);
        }
        if (options.all) return callback(null, list as never, undefined as never);
        const [first] = list;
        return callback(null, first?.address ?? '', first?.family ?? 4);
      });
    },
  },
});

export async function safeFetch(
  rawUrl: string,
  allowedHosts: ReadonlySet<string>,
  init: RequestInit = {},
) {
  const url = new URL(rawUrl);
  if (url.protocol !== 'https:') throw new Error('ssrf: https only');
  // The connect-time lookup never runs for IP literals, so refuse them here.
  if (isIP(url.hostname.replace(/^\[|\]$/g, '')) !== 0)
    throw new Error('ssrf: IP literals refused');
  if (!allowedHosts.has(url.hostname)) throw new Error('ssrf: host not allow-listed');
  return fetch(url, {
    ...init,
    dispatcher,
    redirect: 'manual', // a redirect is a new URL: re-validate it, or refuse
    signal: AbortSignal.timeout(5_000),
  });
}
```

### `tests/unit/ssrf.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { safeFetch } from '../../src/platform/ssrf.ts';

const allowed = new Set(['localhost', 'example.com']);

describe('safeFetch', () => {
  it.each([
    'http://example.com/',
    'https://evil.example.org/',
    'https://127.0.0.1/',
    'https://[::ffff:127.0.0.1]/',
  ])('safeFetch - %s - refused before any request', async (url) => {
    await expect(safeFetch(url, allowed)).rejects.toThrow(/ssrf/);
  });

  it('safeFetch - allow-listed host resolving to loopback - refused at connect time', async () => {
    await expect(safeFetch('https://localhost/', allowed)).rejects.toThrow();
  });
});
```

### `tests/unit/rate-limit.test.ts`

```ts
import { Hono } from 'hono';
import { describe, expect, it } from 'vitest';
import type { AuthEnv } from '../../src/platform/auth.ts';
import { callerRateLimit } from '../../src/transport/edge.ts';

function appFor(sub: string) {
  const app = new Hono<AuthEnv>();
  app.use(async (c, next) => {
    c.set('principal', { sub, tenantId: 't-1', scopes: new Set() });
    await next();
  });
  app.use(callerRateLimit({ limit: 2, windowMs: 60_000 }));
  return app.get('/x', (c) => c.text('ok'));
}

describe('callerRateLimit', () => {
  it('GET - third request in the window - 429', async () => {
    const app = appFor('u-1');
    expect((await app.request('/x')).status).toBe(200);
    expect((await app.request('/x')).status).toBe(200);
    expect((await app.request('/x')).status).toBe(429);
  });
});
```

### Wiring

`src/config.ts` gains the CORS list — comma-separated in the environment, empty means "no browser may call":

```ts
CORS_ALLOWED_ORIGINS: z
  .string()
  .default('')
  .transform((v) =>
    v
      .split(',')
      .map((o) => o.trim())
      .filter(Boolean),
  ),
```

`AppDeps` gains `allowedOrigins: string[]`; `main.ts` passes `config.CORS_ALLOWED_ORIGINS`. In `src/app.ts` the edge goes on before any route, so its limits and headers cover everything:

```ts
app.use(routeTemplate); // tracing middleware, not a route; the edge below still covers every route
applyEdge(app, { allowedOrigins: deps.allowedOrigins });
```

The per-caller limit runs after authentication, keyed on the Principal:

```ts
app.use('/documents/*', deps.auth.authenticate);
app.use('/documents/*', callerRateLimit({ limit: 120, windowMs: 60_000 }));
```

`app.onError` gains a branch for Hono's own `HTTPException` — the edge's `timeout()` throws it with status 504:

```ts
import { HTTPException } from 'hono/http-exception';
```

```ts
if (err instanceof HTTPException) {
  return problem(c, {
    type: 'about:blank',
    title: err.message || 'Error',
    status: err.status,
    instance: c.req.path,
  });
}
```

Request bodies go through a strict schema in the `createRoute` — unknown fields are a 400, the title is bounded:

```ts
const createDocumentBody = z.object({ title: z.string().trim().min(1).max(200) }).strict();
// in the route:
// request: { body: { content: { 'application/json': { schema: createDocumentBody } } } }
```

Outbound calls with a user-influenced URL use `safeFetch(url, allowedHosts)` with the host allow-list from config; delete any bare `fetch` the audit found.

## Go

### `internal/transport/httpapi/edge.go`

```go
package httpapi

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/rs/cors"
	"golang.org/x/time/rate"
)

type middleware func(http.Handler) http.Handler

// chain applies middleware so the first argument is the outermost.
func chain(h http.Handler, mw ...middleware) http.Handler {
	for i := len(mw) - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}

// secureHeaders: an API renders nothing and embeds nothing.
func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// corsAllowList takes exact origins. Never "*" together with credentials.
func corsAllowList(origins []string) middleware {
	return cors.New(cors.Options{
		AllowedOrigins:   origins,
		AllowedMethods:   []string{http.MethodGet, http.MethodPost, http.MethodPatch, http.MethodDelete},
		AllowedHeaders:   []string{"Authorization", "Content-Type"},
		AllowCredentials: true,
		MaxAge:           600,
	}).Handler
}

// maxBody caps request bodies. A read past the limit fails with *http.MaxBytesError.
func maxBody(n int64) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, n)
			next.ServeHTTP(w, r)
		})
	}
}

// deadline puts a time limit on the request context. pgx and http clients stop work when it fires;
// fail maps context.DeadlineExceeded to 504.
func deadline(d time.Duration) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx, cancel := context.WithTimeout(r.Context(), d)
			defer cancel()
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// rateLimit keeps one token bucket per key, with no eviction: safe only for a bounded key space
// (here: authenticated principals from a trusted IdP). Keys an attacker can mint (raw IPs,
// header values) need TTL or LRU eviction, a proxy-side limit, or a Redis-backed limiter.
func rateLimit(perSecond float64, burst int, key func(*http.Request) string) middleware {
	var mu sync.Mutex
	buckets := map[string]*rate.Limiter{}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			k := key(r)
			mu.Lock()
			l, ok := buckets[k]
			if !ok {
				l = rate.NewLimiter(rate.Limit(perSecond), burst)
				buckets[k] = l
			}
			mu.Unlock()
			if !l.Allow() {
				w.Header().Set("Retry-After", "1")
				writeProblem(w, r, http.StatusTooManyRequests, "")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
```

### `internal/transport/httpapi/decode.go`

```go
package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// decodeJSON parses a request body into dst and rejects unknown fields and trailing data.
// It writes the problem response itself and reports false, so the handler just returns.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields() // a typo or a smuggled field is a 400, not silently ignored
	err := dec.Decode(dst)
	if err == nil && dec.Decode(&struct{}{}) != io.EOF {
		err = errors.New("trailing data")
	}
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeProblem(w, r, http.StatusRequestEntityTooLarge, "")
			return false
		}
		writeProblem(w, r, http.StatusBadRequest, "body must be one JSON object with known fields")
		return false
	}
	return true
}
```

### `internal/transport/httpapi/decode_test.go`

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

### `internal/platform/safehttp/ssrf.go`

```go
package safehttp

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"syscall"
	"time"
)

var blocked = func() []netip.Prefix {
	var out []netip.Prefix
	for _, s := range []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
		"192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
		"::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
	} {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}()

func isBlocked(ip netip.Addr) bool {
	ip = ip.Unmap() // ::ffff:10.0.0.1 is 10.0.0.1
	for _, p := range blocked {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

// NewSafeClient returns the only HTTP client for URLs the service did not hardcode.
// The check runs in Dialer.Control, on the address the socket really connects to,
// so DNS rebinding and IP literals are covered. Redirects are refused: each one is a new URL.
func NewSafeClient() *http.Client {
	dialer := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			ap, err := netip.ParseAddrPort(address)
			if err != nil {
				return err
			}
			if isBlocked(ap.Addr()) {
				return errors.New("ssrf: blocked address")
			}
			return nil
		},
	}
	return &http.Client{
		Timeout:       10 * time.Second,
		Transport:     &http.Transport{DialContext: dialer.DialContext, Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf("ssrf: redirects refused") },
	}
}

// CheckURL accepts https URLs to allow-listed hostnames only. IP literals never pass the allow-list.
func CheckURL(raw string, allowedHosts map[string]struct{}) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" {
		return nil, errors.New("ssrf: https URLs only")
	}
	if _, ok := allowedHosts[u.Hostname()]; !ok {
		return nil, errors.New("ssrf: host not allow-listed")
	}
	return u, nil
}
```

### `internal/platform/safehttp/ssrf_test.go`

```go
package safehttp_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"example.com/svc/internal/platform/safehttp"
)

func TestSafeClientRefusesLoopback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer srv.Close()

	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, srv.URL, nil) // 127.0.0.1 literal
	if err != nil {
		t.Fatal(err)
	}
	res, err := safehttp.NewSafeClient().Do(req)
	if err == nil {
		_ = res.Body.Close()
		t.Fatal("request to loopback must fail")
	}
}

func TestCheckURL(t *testing.T) {
	allowed := map[string]struct{}{"api.example.com": {}}
	for url, ok := range map[string]bool{
		"https://api.example.com/v1": true,
		"http://api.example.com/v1":  false,
		"https://evil.example.org/":  false,
		"https://127.0.0.1/":         false,
	} {
		if _, err := safehttp.CheckURL(url, allowed); (err == nil) != ok {
			t.Errorf("CheckURL(%q) err = %v, want ok=%v", url, err, ok)
		}
	}
}
```

### Wiring in `server.go` and `main.go`

`Deps` gains `AllowedOrigins []string`, split from `CORS_ALLOWED_ORIGINS` in `internal/config/config.go`. `Handler()` ends with the edge chain — secure headers inside CORS, body cap and deadline innermost:

```go
return chain(mux,
	routeTag(mux), a.recoverer, a.accessLog,
	secureHeaders, corsAllowList(a.deps.AllowedOrigins), maxBody(1<<20), deadline(10*time.Second),
)
```

Protected routes carry the limiter after `Authenticate`:

```go
protected := chain(http.HandlerFunc(a.getDocument), a.deps.Verifier.Authenticate, a.limiter())
mux.Handle("GET /documents/{id}", protected)
```

The limiter keys on the principal's subject:

```go
// limiter allows 2 requests per second (burst 20) per caller. IPs are shared behind NAT.
func (a *API) limiter() middleware {
	return rateLimit(2, 20, func(r *http.Request) string {
		p, _ := auth.FromContext(r.Context())
		return p.Sub
	})
}
```

`fail` maps a missed deadline to 504:

```go
case errors.Is(err, context.DeadlineExceeded):
	writeProblem(w, r, http.StatusGatewayTimeout, "")
```

`cmd/svc/main.go` sets the timeouts `net/http` does not have by default:

```go
srv := &http.Server{
	Addr:              net.JoinHostPort("", strconv.Itoa(cfg.Port)),
	Handler:           otelhttp.NewHandler(api.Handler(), "http.server"), // outermost: spans cover every middleware
	BaseContext:       func(net.Listener) context.Context { return ctx },
	ReadHeaderTimeout: 5 * time.Second,
	ReadTimeout:       15 * time.Second,
	WriteTimeout:      20 * time.Second,
	IdleTimeout:       60 * time.Second,
	MaxHeaderBytes:    1 << 16,
}
```

Handlers decode bodies with `decodeJSON` and validate path values with a regex before the service sees them (see `internal/transport/httpapi/documents.go`). Outbound calls with a user-influenced URL go through `safehttp.CheckURL` and `NewSafeClient()` only.

## Python (FastAPI)

### `src/svc/transport/edge.py`

```python
import asyncio

from fastapi import FastAPI
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from svc.platform.problem import PROBLEM_CONTENT_TYPE

MAX_BODY_BYTES = 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 10.0

SECURE_HEADERS: list[tuple[bytes, bytes]] = [
    (b"content-security-policy", b"default-src 'none'; frame-ancestors 'none'"),
    (b"strict-transport-security", b"max-age=63072000; includeSubDomains"),
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (b"cache-control", b"no-store"),
]


def _problem(status: int, title: str) -> JSONResponse:
    body = {"type": "about:blank", "title": title, "status": status}
    return JSONResponse(body, status_code=status, media_type=PROBLEM_CONTENT_TYPE)


class _BodyTooLargeError(Exception):
    pass


class EdgeMiddleware:
    """Secure headers, a body cap and a request deadline for every HTTP request."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        started = False
        received = 0

        async def capped_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if (
                    received > MAX_BODY_BYTES
                ):  # counts bytes read, so chunked uploads are capped too
                    raise _BodyTooLargeError
            return message

        async def send_with_headers(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                message["headers"] = [*message.get("headers", []), *SECURE_HEADERS]
            await send(message)

        try:
            async with asyncio.timeout(REQUEST_TIMEOUT_SECONDS):
                await self.app(scope, capped_receive, send_with_headers)
        except _BodyTooLargeError:
            if not started:
                await _problem(413, "Payload Too Large")(scope, receive, send_with_headers)
        except TimeoutError:
            # A timeout after the response started can no longer send a 504:
            # the client keeps the truncated body and the connection closes.
            if not started:
                await _problem(504, "Gateway Timeout")(scope, receive, send_with_headers)


def install_edge(app: FastAPI, *, allowed_origins: list[str]) -> None:
    app.add_middleware(EdgeMiddleware)
    # Added last = outermost: CORS answers preflights before anything else runs.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,  # exact allow-list; never "*" with credentials
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type"],
        max_age=600,
    )
```

### `src/svc/platform/outbound.py`

```python
"""The only way the service fetches a URL it did not hardcode (SSRF guard)."""

import asyncio
import ipaddress
import socket
from urllib.parse import urlsplit

import httpx


class BlockedDestinationError(Exception):
    pass


def _is_public(address: str) -> bool:
    ip = ipaddress.ip_address(address)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped  # ::ffff:10.0.0.1 is 10.0.0.1
    return ip.is_global and not ip.is_multicast


async def safe_get(
    url: str, *, allowed_hosts: frozenset[str], deadline_seconds: float = 5.0
) -> httpx.Response:
    """GET an https URL on an allow-listed host.

    Every address the name resolves to must be public. The request then goes to that exact IP,
    so the name cannot resolve to something else between the check and the connection (DNS
    rebinding). The TLS handshake and the Host header still use the original name.
    Redirects are not followed: each one is a new URL that needs the same checks.
    Only the first resolved address is connected to; if it is down, the request fails
    instead of trying the next validated address.
    """
    parts = urlsplit(url)
    host = parts.hostname or ""
    if parts.scheme != "https" or host not in allowed_hosts:
        raise BlockedDestinationError("https URLs on allow-listed hosts only")
    if parts.username is not None:
        raise BlockedDestinationError("userinfo in the URL is not supported")

    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, parts.port or 443, type=socket.SOCK_STREAM)
    addresses = [str(info[4][0]) for info in infos]
    if not addresses or not all(_is_public(a) for a in addresses):
        raise BlockedDestinationError("destination is not a public address")

    ip = f"[{addresses[0]}]" if ":" in addresses[0] else addresses[0]
    pinned = parts._replace(netloc=f"{ip}:{parts.port}" if parts.port else ip).geturl()
    async with httpx.AsyncClient(
        timeout=deadline_seconds, follow_redirects=False, trust_env=False
    ) as client:
        return await client.get(
            pinned, headers={"Host": parts.netloc}, extensions={"sni_hostname": host}
        )
```

### `tests/unit/test_outbound.py`

```python
import pytest

from svc.platform.outbound import BlockedDestinationError, safe_get

ALLOWED = frozenset({"localhost", "example.com", "127.0.0.1"})


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com/",
        "https://evil.example.org/",
        "https://127.0.0.1/",
        "https://localhost/",
    ],
)
async def test_safe_get__unsafe_destination__blocked(url: str) -> None:
    with pytest.raises(BlockedDestinationError):
        await safe_get(url, allowed_hosts=ALLOWED)
```

### Wiring

`src/svc/config.py` gains the CORS list — comma-separated in the environment, split by a validator:

```python
# Comma-separated in the environment: CORS_ALLOWED_ORIGINS=https://a.example,https://b.example
cors_allowed_origins: Annotated[list[str], NoDecode] = []


@field_validator("cors_allowed_origins", mode="before")
@classmethod
def _split_origins(cls, value: object) -> object:
    if isinstance(value, str):
        return [o.strip() for o in value.split(",") if o.strip()]
    return value
```

`create_app` sets the limiter slowapi looks for and installs the edge (CORS ends up outermost):

```python
app.state.limiter = limiter
install_error_handlers(app)
install_edge(app, allowed_origins=settings.cors_allowed_origins)
```

Two handlers in `src/svc/transport/errors.py`, as in the file — the 429 with `Retry-After`, and the 405 fix that keeps the exception's headers (found by schemathesis):

```python
@app.exception_handler(RateLimitExceeded)
async def _rate_limited(request: Request, _: RateLimitExceeded) -> JSONResponse:
    return _problem(
        request, HTTP_429_TOO_MANY_REQUESTS, "Too Many Requests", headers={"Retry-After": "1"}
    )
```

```python
@app.exception_handler(StarletteHTTPException)
async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    headers = dict(exc.headers) if exc.headers else None  # keeps Allow on 405
    return _problem(request, exc.status_code, str(exc.detail), headers=headers)
```

The limiter lives in `src/svc/transport/documents.py` — keyed per caller, one decorator per route, and `request: Request` in the signature because slowapi needs it:

```python
from slowapi.util import get_remote_address


def caller_key(request: Request) -> str:
    principal = getattr(request.state, "principal", None)
    if principal is not None:
        return principal.sub  # set by current_principal; per caller, IPs are shared behind NAT
    return get_remote_address(request)  # no principal on this request: fall back to the address


limiter = Limiter(key_func=caller_key)
```

```python
@limiter.limit("120/minute")
async def get_document(
    request: Request,  # slowapi needs the request in the signature
    doc_id: Annotated[UUID, Path()],
    principal: CurrentPrincipal,
    service: Annotated[DocumentsService, Depends(get_documents_service)],
) -> DocumentOut:
```

Request models forbid unknown fields and bound every value:

```python
class CreateDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=200)
```

Known gap, verified by reading Starlette's middleware stack: an unhandled error is answered by `ServerErrorMiddleware`, which sits outside `EdgeMiddleware`, so that one 500 response carries no secure headers. The handler still logs and returns problem+json; the next response carries the headers again.

## CI

### `.github/workflows/security.yml`

```yaml
name: security

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '17 4 * * 1' # weekly: new advisories appear without a code change

permissions:
  contents: read

jobs:
  secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0 # scan history, not just the tip
          persist-credentials: false
      - name: gitleaks
        run: |
          docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 \
            git /repo --redact --no-banner

  dependencies:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: osv-scanner (all ecosystems, lockfiles)
        run: |
          docker run --rm -v "$PWD:/repo" ghcr.io/google/osv-scanner:v2.6.0 \
            scan source -r /repo
      # Keep the native audit of the track you use; delete the other two.
      - uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413 # v6.1.0
      - name: pnpm audit
        run: pnpm audit --prod --audit-level high
      - uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with:
          go-version-file: go.mod
      - name: govulncheck
        run: go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
      - name: pip-audit
        run: |
          uv export --no-dev --no-emit-project --format requirements-txt -o requirements.audit.txt
          uvx pip-audit -r requirements.audit.txt --no-deps --disable-pip
```

The `dependencies` job carries all three native audits so the file is copy-paste ready for any track: keep the one for this repo's track, delete the other two (with their setup steps).
