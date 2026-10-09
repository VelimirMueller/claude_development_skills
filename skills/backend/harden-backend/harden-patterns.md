# Harden Backend Patterns

Reference for [harden-backend](SKILL.md). Implements [security-baseline.md](../../core/_shared/security-baseline.md) rules 4 (validate at the edge), 6 (scan), 7 (Actions hardening), 8 (headers and transport) and 13 (handle errors on purpose). Each control maps to the OWASP Top 10:2025; SSRF is part of A01 in 2025.

| # | Control | OWASP Top 10:2025 |
|---|---|---|
| 1 | Validate at the edge, reject unknown fields | A05 Injection, A06 Insecure Design |
| 2 | Parameterized SQL only | A05 Injection |
| 3 | Rate limit per caller | A06 Insecure Design, A07 Authentication Failures |
| 4 | Size and time limits at every layer | A06 Insecure Design, A10 Mishandling of Exceptional Conditions |
| 5 | CORS exact allow-list | A02 Security Misconfiguration |
| 6 | Security headers for an API | A02 Security Misconfiguration |
| 7 | SSRF-safe outbound fetch | A01 Broken Access Control (includes SSRF) |
| 8 | Safe error responses | A10 Mishandling of Exceptional Conditions, A09 Security Logging and Alerting Failures |
| 9 | Supply chain scanning in CI | A03 Software Supply Chain Failures, A08 Software or Data Integrity Failures |

## Rule: Validate at the edge with a schema, reject unknown fields, bound every value

**Why:** Untrusted input is the raw material of A05 and A06 ([security-baseline.md](../../core/_shared/security-baseline.md) rule 4). One schema at the transport edge turns "hopefully valid" into checked values once; everything below trusts its inputs ([service-layout.md](../_shared/service-layout.md)). Rejecting unknown fields over ignoring them: an unknown key is a typo or a smuggled field (`admin: true`); ignoring it hides both. Unbounded strings are unbounded memory, database pressure and log noise.
**How to apply:** TypeScript: a `.strict()` Zod object in the `createRoute` `request.body`; the same schema feeds the OpenAPI document. Go: `decodeJSON` with `DisallowUnknownFields` (trailing data rejected too) plus a regex on each path value. Python: `model_config = ConfigDict(extra="forbid")` with `Field(min_length=1, max_length=200)`. Bound every string, array and number. Validation errors are 400 problem+json carrying field paths only, never echoed values: a rejected value can be a password attempt or an attack payload, and the path plus the constraint say enough.
**Anti-example:** `const body = await c.req.json()` followed by `if` checks in the service; a Pydantic model without `extra="forbid"` silently dropping `{"title": "x", "owner_id": "me"}`.
**When to deviate:** A documented bulk-import format that must tolerate extra keys: one versioned module with a loose schema, `.strict()` everywhere else.

## Rule: Parameterized SQL only

**Why:** String-built SQL is the direct route to A05: when statement and data arrive in one string, the interpreter cannot tell them apart. A parameterized statement sends them as separate things, so a value can never change the statement's shape. ORMs do not protect raw fragments: `sql.raw`, interpolated `text()` and `Sprintf` all build strings.
**How to apply:** The three verified forms:

```ts
const [row] = await db
  .select()
  .from(documents)
  .where(and(eq(documents.tenantId, scope.tenantId), eq(documents.id, id)))
  .limit(1);
```

```go
err := r.db.QueryRow(ctx,
	`SELECT id, tenant_id, owner_id, title FROM documents WHERE tenant_id = $1 AND id = $2`,
	r.tenantID, id,
).Scan(&d.ID, &d.TenantID, &d.OwnerID, &d.Title)
```

```python
await session.execute(
	text("SELECT id, tenant_id, owner_id, title FROM documents WHERE tenant_id = :tenant_id AND id = :id"),
	{"tenant_id": tenant_id, "id": doc_id},
)
```

Dynamic identifiers (sort column, table) are not values and cannot be bound: choose them from an allow-list map — `const SORTABLE = { createdAt: 'created_at' }`, then `SORTABLE[input.sort] ?? SORTABLE.createdAt` — so an unknown key falls back instead of reaching SQL. Audit with the step 1 grep; every hit must be gone or justified:

```bash
grep -rnE '(SELECT |INSERT INTO|UPDATE |DELETE FROM)' --include='*.ts' --include='*.py' --include='*.go' src internal | grep -E '\$\{|f"|Sprintf'
```

**Anti-example:** `` db.execute(sql.raw(`SELECT * FROM documents ORDER BY ${input.sort}`)) ``.
**When to deviate:** None for values. For identifiers, the allow-list map is the ceiling: if the key space is unbounded, the design is wrong.

## Rule: Rate limit per caller, not per IP, and layer it

**Why:** Addresses are shared behind NAT and corporate proxies — one abuser gets an office blocked, one office looks like an abuser — and rotate freely in IPv6. The authenticated subject is stable and costs the attacker an account. Layered over single-layer: the global limit at the proxy covers every replica and every path including unknown ones; the per-subject limit in the app is precise and follows the principal. Login and token endpoints get a tighter limit, because that is where credential stuffing lives (A07). 429 with `Retry-After`, so well-behaved clients back off instead of retrying in a tight loop.
**How to apply:** `hono-rate-limiter` with `keyGenerator` on the principal's `sub`; `x/time/rate` as a token bucket per key; slowapi with `key_func=caller_key`. State it plainly in the ops notes: in-process counters are per replica, so N replicas means N times the limit — the proxy's global limit is the real bound. Move to a shared store (Redis) only when the bound must be exact.
**Anti-example:** `keyGenerator: (c) => c.req.header('x-forwarded-for')` — spoofable unless the proxy overwrites it, and shared by every device behind one NAT.
**When to deviate:** A public API without accounts: key on the API key or the proxy's fingerprint, and keep the proxy's global limit.

## Rule: Size and time limits at every layer

**Why:** Every resource a request can hold is a DoS multiplier: memory (the parsed body), a connection, a database pool slot, a goroutine or task. `net/http` ships without any timeout — a slow client holds a connection forever (slowloris), and the same class of bug exists wherever a read or call is unbounded (A06, A10). Limits at every layer over one layer, because the proxy is not always yours and each layer fails differently.
**How to apply:** Body cap of 1 MiB by default, counted on the bytes actually read so chunked uploads without a `Content-Length` are capped too: `bodyLimit` (Hono, checks header and stream), `http.MaxBytesReader` (Go), the `capped_receive` counter (Python). A request deadline on the context (10 s): pgx, HTTP clients and fetches abort when it fires, and `context.DeadlineExceeded` maps to 504. Server timeouts in main: `ReadHeaderTimeout` 5 s, `ReadTimeout` 15 s, `WriteTimeout` 20 s, `IdleTimeout` 60 s, `MaxHeaderBytes` 64 KiB. A short timeout (5 s) on every outbound call.
**Anti-example:** `http.ListenAndServe(":8080", mux)` — no timeouts at all; `fetch(url)` without an `AbortSignal`.
**When to deviate:** Uploads and long polls: an explicit per-route cap or streaming to object storage, not a global raise. A genuinely slow batch endpoint: its own longer deadline, still finite.

## Rule: CORS is an exact allow-list from config

**Why:** `*` together with credentials is rejected by browsers, so someone "fixes" it by reflecting the request's Origin — which allows every origin. An exact list from config over a list in code, because it differs per environment and is reviewable and diffable. And CORS is a browser rule, not an auth control: it stops other sites' pages from reading responses with the user's credentials; `curl` ignores it entirely. The actual control is [set-up-backend-auth](../set-up-backend-auth/auth-patterns.md).
**How to apply:** `CORS_ALLOWED_ORIGINS` (comma-separated) split into exact origins; credentials only together with that explicit list, never `*`; preflight cache 600 s so OPTIONS round-trips stay cheap.
**Anti-example:** `cors({ origin: (origin) => origin })` — reflect whatever is asked.
**When to deviate:** No browser callers at all: leave the list empty; preflights are then answered with no origin allowed, which is the correct answer.

## Rule: Security headers sized for an API

**Why:** Cheap defences with a large payoff (A02), and an API can be far stricter than a page: it renders no HTML, loads no scripts, and is framed by nobody — so `default-src 'none'; frame-ancestors 'none'` breaks nothing. `X-Content-Type-Options: nosniff` stops a mislabelled JSON error from being sniffed as HTML. `Cache-Control: no-store` keeps token-bearing or personal responses out of shared caches. HSTS of two years with `includeSubDomains` makes the browser refuse a downgrade after the first clean visit. The browser-facing set (nonce CSP, `Permissions-Policy`, framing rules for pages) is [security-baseline.md](../../core/_shared/security-baseline.md) rule 8; an API takes the subset above and needs nothing relaxed.
**How to apply:** Set on every response at the edge: CSP `default-src 'none'`; `frame-ancestors 'none'`; `Strict-Transport-Security: max-age=63072000; includeSubDomains`; `X-Content-Type-Options: nosniff`; `Referrer-Policy: no-referrer`; `Cache-Control: no-store`.
**Anti-example:** A frontend CSP with `unsafe-inline` copied into the API "to be safe".
**When to deviate:** None that widens these for a JSON API. Docs UIs mounted under the same origin (Scalar, Swagger UI) need scripts: host them on a separate origin instead of loosening the API's CSP.

## Rule: Outbound calls to user-influenced URLs go through one SSRF seam

**Why:** A URL taken from a request can name the cloud metadata endpoint (169.254.169.254), loopback services or private ranges — the request runs with the service's network position, not the user's. SSRF is part of A01 in 2025. One seam over scattered guards, because the checks must be identical everywhere or the weakest call site wins.
**How to apply:** Allow-list hosts from config; https only. Refuse IP literals up front: verified finding — Node's connect-time lookup never runs for IP literals, so a literal `127.0.0.1` connected until literals were refused before the request. Check the address the socket really connects to, which also defeats DNS rebinding: an undici `Agent` with a custom `connect.lookup` (TypeScript), `net.Dialer.Control` (Go), resolve-then-pin — connect to the resolved IP, send the original name as `Host` header and `sni_hostname` (Python). No redirects: each one is a new URL that needs the same checks. Short timeout (5 s). Block private, loopback, link-local (including metadata), CGNAT (100.64.0.0/10), multicast and IPv4-mapped IPv6 (`::ffff:10.0.0.1` is 10.0.0.1). Residual risk, stated plainly: the egress firewall or proxy is the real control; the application-level seam is defence in depth, not the boundary.
**Anti-example:** `fetch(body.url)` "just to check the link exists".
**When to deviate:** A fixed partner endpoint hardcoded in config: the same seam with a one-entry allow-list, not a bare `fetch`.

## Rule: Errors leave as problem+json, unknown errors as a generic 500

**Why:** A raw driver error carries version strings, SQL fragments and internal hostnames into the response (an A10 leak); an error swallowed instead of handled leaves half-written state and fails open. RFC 9457 `application/problem+json` gives every client one parseable error shape with a stable status (baseline rule 13).
**How to apply:** One error mapper per service (`onError`, `fail`, exception handlers). Known domain errors map to their status; the unknown error becomes a generic 500; its detail goes to the logger exactly once, at `error`, with the trace id the logger adds ([logging-contract.md](../../core/_shared/logging-contract.md)). Never a stack, SQL or `err.message` in a response. Another tenant's row is a 404, so IDs cannot be probed ([auth-patterns.md](../set-up-backend-auth/auth-patterns.md)). A 405 keeps its `Allow` header — schemathesis found a scaffold that dropped it. Auth and authorization failures fail closed.
**Anti-example:** `catch (e) { return c.json({ error: (e as Error).message }, 500) }`.
**When to deviate:** A consumer contract that mandates its own error envelope: map problem+json to it at the edge and keep the internal shape.

## Rule: Scan secrets and dependencies in CI, weekly

**Why:** Known-bad is the cheapest finding: the advisory and usually the fix already exist ([security-baseline.md](../../core/_shared/security-baseline.md) rule 6). A dependency is code you run without having read it (A03, A08); a workflow's token is a secret with a job attached, so the workflow itself is attack surface. A weekly schedule over push-only, because advisories land without any code change.
**How to apply:** Secrets: gitleaks v8.30.1 in a pinned container, `git /repo --redact --no-banner`, with `fetch-depth: 0` so history is scanned and output redacted. Dependencies: osv-scanner v2.6.0 with `scan source -r /repo` across ecosystems, plus the native audit of the track — `pnpm audit --prod --audit-level high`; govulncheck v1.8.0 via `go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...`; `uvx pip-audit -r requirements.audit.txt --no-deps --disable-pip`. Workflow hygiene: every `uses:` SHA-pinned, `permissions: contents: read`, `persist-credentials: false` (baseline rule 7); the verified workflow passes actionlint and zizmor v1.30.1 with no findings. Fail CI on high or above when a fix is available; record exceptions with an expiry. Verified note: osv-scanner reported real advisories in transitive Go modules of a fresh service (golang.org/x/net) — expect a red first run and budget time to update dependencies.
**Anti-example:** `pnpm audit` alone, in a workflow with `permissions: write-all` and tag-pinned third-party actions.
**When to deviate:** A finding with no fix and no reachable path: an expiring exception in the repo with the reason, per baseline rule 6.

## When to deviate

- A service behind a gateway that already owns CORS, headers and the global rate limit: keep the app-level controls where they are free (defence in depth), but name the proxy as the policy owner in the README.
- An endpoint that takes large uploads: a larger, explicit body cap for that route only, with the file size and type checked again after parse.
- A partners API with negotiated quotas: rate limits per contract, still per client identity, never per IP.
- Local development: nothing here is switched off; the scaffolds ship it on by default, and a dev machine behind no proxy still gets correct behaviour.
