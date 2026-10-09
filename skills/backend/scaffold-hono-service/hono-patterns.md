# Hono Service Patterns

Reference for [scaffold-hono-service](SKILL.md). Each rule was checked against the scaffold in [hono-files.md](hono-files.md) on 2026-10-09.

## Rule: The app is a fetch handler; the server is an adapter
**Why:** Hono implements the Web Standards `fetch` contract. `createApp(deps)` returns an object whose `app.fetch` runs on Node, Bun, Cloudflare Workers, Vercel and Deno. Binding the app to `serve()` inside the same module would weld it to Node and make tests start a port.
**How to apply:** `app.ts` exports `createApp(deps)` and never imports `@hono/node-server`. `main.ts` is the Node adapter and the composition root. Another runtime gets its own entry that calls `createApp` and exports it as that platform expects (Hono's docs show `export default app` for Cloudflare Workers, Bun and Vercel).
**Anti-example:** `serve(...)` at the bottom of `app.ts`.
**When to deviate:** A service that will only ever run on Node may keep a single file; the cost of the split is one small file.

## Rule: Hono over Express and Fastify for a new service
**Why:** Hono is typed end to end (route params, validated input, response), small, and portable by default. Express has no built-in types for handlers and is not portable. Fastify is fast and mature on Node, but it is Node-only and its types for schema-driven routes need more setup. Boring-technology rule: if the repo already runs Express or Fastify, extend that and do not add a second framework ([engineering-principles.md](../../core/_shared/engineering-principles.md)).
**How to apply:** Use this skill only for new services. In a repo with an existing framework, the audit asks before adding Hono.
**When to deviate:** A team with deep Fastify or Nest experience and no portability need.

## Rule: OpenAPI is generated from the route schemas
**Why:** A hand-written `openapi.yaml` drifts from the code within a sprint. `createRoute` holds the Zod schema for params, body and each response; the same object validates at runtime and produces the document. One source cannot disagree with itself.
**How to apply:** Define each endpoint with `createRoute({ method, path, request, responses })` and register it with `app.openapi(route, handler)`. Expose `app.doc31('/openapi.json', …)` for OpenAPI 3.1. `pnpm openapi` writes the file for clients and diffs in CI. Declare every status the handler can return, including the `application/problem+json` error responses: the handler's return type is checked against them.
**Why `@hono/zod-openapi`:** It is Zod 4 native (`peerDependencies: zod ^4, hono >=4.10`) and maintained in the Hono org. `hono-openapi` (Standard Schema, any validator) is the alternative when the repo standardizes on Valibot or ArkType. Plain `@hono/zod-validator` validates but documents nothing.
**Anti-example:** Handlers that call `schema.parse(await c.req.json())` themselves: no document, and error shapes differ per handler.
**Gotcha:** Return literals for statuses and enums (`{ status: 'ok' as const }`, `c.json(body, 200)`); a widened `string` fails the response type check.
**When to deviate:** A service with no external clients and no docs need can use `@hono/zod-validator` on plain `Hono`.

## Rule: One error handler, RFC 9457 problem+json
**Why:** Clients and logs can handle one error shape. RFC 9457 defines it (`type`, `title`, `status`, `detail`, `instance`) and the media type `application/problem+json`. Handlers that build their own error JSON drift.
**How to apply:**
- Services throw `AppError(status, title, { detail })`: a plain class with a number, no Hono type.
- `app.onError` maps `AppError` to its status, and anything else to a 500 with a fixed body. It logs the unknown error once, with its cause.
- `app.notFound` returns a 404 problem. `defaultHook` on `OpenAPIHono` turns validation failures into a 400 problem with an `errors` array.
- The 500 body contains no message, stack or SQL. Detail for humans goes to the log.
- Expected client errors (404, validation) are not `error` level in logs ([logging-contract.md](../../core/_shared/logging-contract.md)).
**When to deviate:** A public API that already publishes another error envelope: map to it at `onError`, keep `AppError` inside.

## Rule: Liveness and readiness are different endpoints
**Why:** A load balancer that restarts a pod because the database is slow turns a dependency blip into an outage. Liveness answers "is the process stuck"; readiness answers "should it receive traffic".
**How to apply:** `/healthz` returns 200 and checks nothing. `/readyz` runs every registered check with `Promise.allSettled` and returns 503 if any fails or if shutdown has begun. Add a per-check timeout when you register a network check (`AbortSignal.timeout(2000)`).
**When to deviate:** A platform that offers a single health URL (some PaaS): point it at `/readyz`.

## Rule: Shut down in a fixed order, with a deadline
**Why:** Kubernetes and systemd send SIGTERM, then SIGKILL after a grace period. Requests cut mid-flight become 5xx for users. A hang with no deadline becomes a SIGKILL anyway, without the cleanup.
**How to apply:** On SIGTERM or SIGINT: set `shuttingDown` (readiness now 503), start a `SHUTDOWN_TIMEOUT_MS` timer with `.unref()`, call `server.close()` (stops accepting, closes idle keep-alive sockets, waits for in-flight requests), then close pools and flush telemetry in the callback, then exit. Ignore a second signal. Set the orchestrator's grace period above `SHUTDOWN_TIMEOUT_MS`.
**When to deviate:** Serverless: no process to stop; skip.

## Rule: Strict TypeScript, erasable syntax only
**Why:** `strict` plus `noUncheckedIndexedAccess` and `exactOptionalPropertyTypes` removes whole bug classes (`arr[0]` being `undefined`, `{ x: undefined }` passing as "absent"). `erasableSyntaxOnly` and `verbatimModuleSyntax` keep the code runnable by Node's own type stripping and by every bundler, because no enums, namespaces or parameter properties need a transform.
**How to apply:** The `tsconfig.json` in [hono-files.md](hono-files.md). Import with the `.ts` extension (`allowImportingTsExtensions`), which Node, `tsx` and `tsdown` all resolve. `noEmit`: `tsc` only type-checks; `tsdown` builds.
**Anti-example:** `enum Status {}`, `constructor(private x: string)`: both need a transform and fail `erasableSyntaxOnly`.
**When to deviate:** A repo on TypeScript 6 (Vue toolchains): the options exist there too; verify with `tsc --noEmit`.

## Rule: Biome is the only lint and format tool
**Why:** One tool, one config, one pass in milliseconds. ESLint plus Prettier plus plugins is three configs and a version matrix.
**How to apply:** `biome.json` with `rules.preset: "recommended"` (Biome 2.5 deprecates `recommended: true`). Pin Biome exactly (`-E`): a new rule must not fail CI unannounced ([version-protocol.md](../../core/_shared/version-protocol.md)).
**When to deviate:** A rule Biome lacks and the team needs (a custom ESLint plugin): add ESLint for that rule only.

## Rule: Test through `app.request`, not a port
**Why:** `app.request('/path')` runs the full middleware and routing stack in-process, fast and without port clashes. The seams (`createApp(deps)`) take fakes.
**How to apply:** Build the app with in-memory repositories in unit tests. Run integration tests against a real Postgres from `@testcontainers/postgresql`, not a mock. Layout follows `tests.layout`.
**When to deviate:** A test of real socket behavior (keep-alive, shutdown): start `serve()` on port 0.

## Rule: Bundle for production, run the bundle
**Why:** `node dist/main.mjs` starts in tens of milliseconds, needs no TypeScript loader in the image, and ships one file plus a source map. `tsx` stays a dev tool.
**How to apply:** `tsdown` with `platform: 'node'`, `target: 'node24'`, `sourcemap: true`. Run with `node --enable-source-maps` when you read production stack traces. `tsdown` is pre-1.0: pin with `~`.
**When to deviate:** A Docker image that installs production dependencies and runs `node src/main.ts` with Node's type stripping is acceptable for small services.

## When to deviate

- Needs an RPC-style typed client (`hc`) between a TypeScript frontend and this API: add Hono's RPC client alongside the OpenAPI route style; both rest on the same route objects.
- Needs auth, CORS, rate limiting, request IDs: Hono ships middleware (`hono/cors`, `hono/secure-headers`, `hono/request-id`); add them in `createApp` before the routes. See [security-baseline.md](../../core/_shared/security-baseline.md).
- OpenTelemetry on: start the SDK in a file imported first by `main.ts`, before `createLogger`, so log lines carry `trace_id` ([observability.md](../../core/_shared/observability.md)).
