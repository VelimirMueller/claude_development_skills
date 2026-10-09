# API Contract Patterns

Reference for `design-http-api`. Each rule is one decision a client team would otherwise argue about per endpoint. Principles: [validate at the edge](../../core/_shared/engineering-principles.md), consistency over local optimum.

## Rule: The OpenAPI 3.1 file is the contract, and it is committed
**Why:** A spec that exists only at runtime (`GET /openapi.json`) cannot be reviewed in a PR, diffed for breaking changes, or used to generate a client in CI before the server deploys. OpenAPI 3.1 over 3.0 because 3.1 is JSON Schema 2020-12 (`type: [string, "null"]`, `const`), which Zod 4 and Pydantic emit natively. OpenAPI 3.2 was released 2025-09-19 but generators lag (`openapi-typescript` documents 3.0 and 3.1 only); stay on 3.1 until your generator lists 3.2.
**How to apply:** Emit to `openapi.json` (TS, Python) or write `openapi.yaml` (Go). Commit it. CI regenerates and fails on `git diff --exit-code`. Set `operationId` on every operation: it names the client method and survives path changes.
**Anti-example:** Frontend developers copy types from a Swagger UI page by hand.

## Rule: Code-first where one schema can do all three jobs; spec-first in Go
**Why:** In TypeScript and Python a single schema validates input, types the handler and documents the route, so the spec cannot drift (Zod via `@hono/zod-openapi`, Pydantic via FastAPI). Go has no such schema: struct tags cannot express enums, numeric bounds or nullable-versus-omitted. Spec-first with `oapi-codegen` makes the spec the reviewed artifact and the strict server interface makes a missing or mistyped handler a compile error. `huma` (code-first, OpenAPI 3.1) is the alternative if the team prefers it; it needs its own router adapter.
**How to apply:** Per track in [api-codegen-patterns.md](api-codegen-patterns.md).
**Anti-example:** Hand-written spec next to a code-first framework: two sources, silent drift.

## Rule: Errors are RFC 9457 problem details, declared in the spec
**Why:** One error shape means the client has one error path, and `type` is a stable key it can switch on. RFC 9457 (obsoletes 7807) defines `type`, `title`, `status`, `detail`, `instance` and allows extension members. A spec that says errors are `application/json` while the server sends `application/problem+json` makes the generated client type errors as `unknown`.
**How to apply:**
- Content type `application/problem+json` on every 4xx and 5xx, including 404 for unknown routes and 500 from the panic/exception handler.
- `type`: an absolute URI under your domain that you control (`https://api.example.com/problems/validation`), stable and documented. `about:blank` only when the status code says it all (a plain 404).
- `title` is the same for every occurrence of a `type`; `detail` is specific and never contains secrets, SQL or stack traces.
- Validation errors: 400 (not 422; one status for "your request is wrong") with an `errors` array of `{ pointer, message }`, `pointer` a JSON Pointer (`/body/email`, `/query/limit`).
- Add `code` only if clients need a machine key finer than `type`. Do not add both by habit.
- Declare the `Problem` schema once in `components` and reference it from every error response.
- Log the `instance` and the trace ID (see [logging-contract.md](../../core/_shared/logging-contract.md)); return the trace ID as an extension member `traceId` so a user report maps to a trace.
**Anti-example:** `{ "error": "bad" }` on one route and `{ "message": "...", "code": 12 }` on the next.

## Rule: Cursor pagination, never offset
**Why:** `OFFSET n` scans and discards n rows (slow at depth) and returns duplicates or skips rows when data changes between pages. Keyset pagination is index-seekable and stable under inserts.
**How to apply:** Request `?limit=25&cursor=<opaque>`; response `{ "items": [...], "nextCursor": "..." | null }`. `limit` has a default and a hard cap (100). The cursor is base64url of the last row's sort key plus ID; clients treat it as opaque. Query:

```sql
SELECT * FROM orders
WHERE (created_at, id) < ($1, $2)       -- omit on the first page
ORDER BY created_at DESC, id DESC
LIMIT $3 + 1;                           -- one extra row says whether a next page exists
```

The sort key needs a unique tiebreaker (`id`) and an index on `(created_at DESC, id DESC)`. Decode the cursor strictly; a malformed cursor is a 400, never a 500. Do not return a total count by default: `count(*)` over a large table is a full scan. Offer `?include=total` only if a screen needs it.
**When to deviate:** Small, bounded, static lists (countries, roles) return a plain array. Admin tables that need "jump to page 40" may use offset with a hard cap.

## Rule: Unsafe retries carry an `Idempotency-Key`
**Why:** Networks fail after the server committed. A client that retries a `POST /payments` without a key charges twice. `PUT` and `DELETE` are idempotent by definition; `POST` and often `PATCH` are not. The IETF header draft (`draft-ietf-httpapi-idempotency-key-header`, rev 07, not yet an RFC) matches common practice; the semantics below are stable even if the header text changes.
**How to apply:** For `POST` endpoints that create, charge or send, accept `Idempotency-Key: <uuid>` (required for payments and sends, optional elsewhere; a missing required key is a 400 problem). Store `(scope, key)` where scope is the authenticated principal, with a hash of the request body and the stored response, in Postgres:

```sql
CREATE TABLE idempotency_keys (
  scope        text        NOT NULL,
  key          text        NOT NULL,
  request_hash bytea       NOT NULL,
  status_code  integer,
  response     jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (scope, key)
);
```

Flow, in the same transaction as the business write:
1. `INSERT ... ON CONFLICT DO NOTHING`. Inserted: run the handler, store status and body, commit.
2. Conflict and `status_code IS NULL`: another request holds the key; return 409 problem (`in-progress`), with `Retry-After: 1`.
3. Conflict, complete, same `request_hash`: replay the stored response with the original status.
4. Conflict, different `request_hash`: 422 problem (`idempotency-key-reuse`). A key is bound to one request.
Delete rows older than 24 hours with a scheduled job ([set-up-background-jobs](../set-up-background-jobs/SKILL.md)).
**Why in Postgres:** the key row and the business row commit or roll back together. Redis cannot give that.
**Anti-example:** Deduplicating by "same body within 5 seconds". Two legitimate identical orders collapse into one.

## Rule: Additive changes only; `/v2` only for a breaking change that cannot be avoided
**Why:** Every version you ship is a version you maintain. Adding optional request fields, new response fields, new endpoints and new enum values the client already tolerates is not breaking. A URL version prefix on day one buys nothing and costs a router, a spec and a test suite per version.
**How to apply:**
- Allowed: new optional fields, new endpoints, new optional query parameters, new response fields.
- Breaking: removing or renaming a field, tightening validation, changing a type, a status code or a default, making an optional field required.
- Clients must ignore unknown response fields. State this in the spec description.
- CI gate: `oasdiff breaking origin/main:openapi.json openapi.json` fails the PR on a breaking change. Intentional breaks go through the deprecation path.
- Deprecation path: mark the operation `deprecated: true`, send `Deprecation: @<unix-seconds>` (RFC 9745) and `Sunset: <HTTP date>` (RFC 8594) headers, log callers still using it, remove after the sunset date. When it cannot be avoided, `/v2/...` for the changed resources only, not the whole API.
**Anti-example:** `/api/v1/` in every path from the first commit, never followed by a v2.

## Rule: Conditional requests where they pay: `If-Match` for writes, `ETag` for heavy reads
**Why:** Two users editing the same record produce a lost update unless the server can detect it; `If-Match` makes the check part of HTTP, not a custom field. `ETag` with `If-None-Match` lets a client skip downloading a large unchanged resource (304). On small, fast reads the extra header logic is cost without benefit.
**How to apply:**
- Resources edited by people (documents, settings, orders in progress): return a strong `ETag` derived from a `version` integer or `updated_at` column. `PUT`/`PATCH` require `If-Match`; mismatch is 412 problem; a missing header is 428 (`Precondition Required`).
- Large or expensive GETs (reports, exports, catalogues): `ETag` from a content hash or version; honor `If-None-Match` with 304 and an empty body.
- Update with the version in the `WHERE` clause (`UPDATE ... SET ..., version = version + 1 WHERE id = $1 AND version = $2`), zero rows updated means 412. Do not read-then-write.
**When to deviate:** Write-rare, single-owner resources need neither. Skip.

## Rule: Naming is mechanical
**Why:** A client developer should predict the URL and field name without opening the spec.
**How to apply:**
- Paths: plural nouns, kebab-case, nesting at most one level (`/orders/{id}/items`). Actions that are not CRUD are sub-resources with `POST` (`POST /orders/{id}/cancellation`), not verbs in the path.
- JSON fields `camelCase` (the frontend's native shape). In Python, set the Pydantic alias generator to camel and `populate_by_name=True`; in Go the generated struct tags handle it.
- IDs: strings in the API even when the column is a bigint (JavaScript loses precision above 2^53).
- Timestamps: RFC 3339 UTC with `Z` (`2026-10-09T10:00:00Z`), field names ending in `At`; dates `YYYY-MM-DD`; money as integer minor units plus a currency code.
- Enums: lowercase strings; clients must tolerate unknown values on responses.
- Status codes: 200 read/update, 201 create (with `Location`), 204 no body, 400 invalid, 401 no or bad credentials, 403 not allowed, 404 missing (also for resources the caller may not know exist), 409 state conflict, 412 precondition failed, 429 rate limited (`Retry-After`).

## Rule: The typed client is generated, never written
**Why:** A hand-written client duplicates every path and type, and the compiler cannot see when the server changes. A generated one turns a breaking server change into a frontend type error in the PR that causes it. `openapi-typescript` emits only types (no runtime), and `openapi-fetch` is a ~2 kB `fetch` wrapper typed by them; there is no generated code to review or to bloat the bundle.
**How to apply:** [api-codegen-patterns.md](api-codegen-patterns.md), section "Wire into the fetcher seam".
**Anti-example:** `fetcher<Order[]>('/orders')` with a hand-typed `Order`, drifting from the server.

## When to deviate

- Public APIs with external integrators that cannot update often: version in the URL from the start and document the support window. That is a product decision, not a default.
- GraphQL or tRPC when one TypeScript team owns both ends and no outside client exists: the contract is the type system. This skill then does not apply to those routes.
- Webhooks you send are API surface too: sign them, put the payload schema in the spec under `webhooks:` (3.1), and include an event ID receivers can dedupe on.
