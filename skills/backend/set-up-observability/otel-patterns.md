# Observability Patterns

Reference for [set-up-observability](SKILL.md). Each rule maps to [observability.md](../../core/_shared/observability.md) (one seam, exporter by env, auto-instrument first, head-sample in the SDK) and [logging-contract.md](../../core/_shared/logging-contract.md) (JSON to stdout, fixed fields, trace correlation). Status checked 2026-10-09; versions in [stack-versions.md](../_shared/stack-versions.md).

## Rule: The SDK starts before any app code imports

**Why:** Instrumentation works by patching modules at load time. A module that was imported before the SDK started keeps the unpatched original, so its HTTP and DB calls produce no spans — silently.

**How to apply:** Start the SDK before anything else in the process: TS preloads it with `node --import` (`tsx watch --import ./src/platform/telemetry.ts` in dev, `node --import ./dist/platform/telemetry.mjs` in prod); Go calls `telemetry.Setup(ctx)` as the first statement in `run()`; Python calls `init_telemetry()` as the first lines of `main.py`, before `fastapi` is imported.

**Anti-example:** importing `http`, `fastapi` or `pg` in the composition root, then starting the SDK "for the rest".

**When to deviate:** None. This is the one rule that cannot be relaxed.

## Rule: Configure only through the standard `OTEL_*` variables

**Why:** Endpoints, protocols, headers and sampler are deployment facts, not code. Hard-coding them in the seam means a staging→production swap edits source instead of environment. The exporter is the backend switch ([observability.md](../../core/_shared/observability.md) "Backends are exporters only").

**How to apply:** No endpoint, header or protocol string in code. `NodeSDK` builds the trace exporter from `OTEL_EXPORTER_OTLP_*` itself; the metrics exporter is constructed with no arguments (`new OTLPMetricExporter()`) so it reads the env. Go uses `autoexport.NewSpanExporter(ctx)` / `NewMetricReader(ctx)`. Python `initialize()` (from the distro) uses the configurators. `NodeSDK` takes `metricReaders` (an array); `metricReader` (singular) is deprecated (verified 2026-10-09).

**Anti-example:** `traceExporter: new OTLPTraceExporter({ url: 'https://otel.example.com' })` in the bootstrap.

**When to deviate:** A vendor agent at the edge (serverless) with no OTLP; keep the API calls, drop the SDK exporter.

## Rule: Auto-instrument HTTP and DB; hand-write spans only at use-case boundaries

**Why:** Auto-instrumentation covers HTTP, DB and queue calls for free. A hand-written span on every function is noise. A span per use case is the unit you actually investigate.

**How to apply:** Enable the HTTP-server, DB-driver and framework instrumentations. Add a manual span only around a business operation (`documents.get`), put identifiers in attributes (never PII), and record an error once at the boundary (`span.recordException` / `RecordError` / `set_status`).

**Anti-example:** a span around `pool.query` by hand (the driver already does it), or `user.email` as a span attribute.

**When to deviate:** Hot loops: do not span them, use a metric. Python DB instrumentation: `@opentelemetry/instrumentation-sqlalchemy` declares support for `sqlalchemy <2.1.0`; the scaffold pins `2.1.4`, so it reports "nothing can be instrumented". Use `opentelemetry-instrumentation-asyncpg` (driver level) instead — verified DB spans (2026-10-09).

## Rule: Route templates, not raw paths, in span names and metrics

**Why:** Raw paths have unbounded cardinality (`/users/1`, `/users/2`, …); route templates keep span names and metric labels bounded. This is the [observability.md](../../core/_shared/observability.md) RED rule on cardinality.

**How to apply:** TS: Node's http instrumentation cannot see Hono's router, so the `routeTemplate` middleware reads `getRPCMetadata` and sets its `route` to `c.req.routePath`. Go: `otelhttp` wraps the whole mux and never sees the pattern, so `routeTag` asks `mux.Handler(r)` first and sets the span name, the `http.route` attribute and the `otelhttp` labeler (for metrics). Python: the FastAPI instrumentation sets it itself.

**Anti-example:** using `r.URL.Path` or `c.req.path` as the span name or a metric attribute.

**When to deviate:** A route with genuinely fixed cardinality and no parameters can use the literal path.

## Rule: Measure with RED for services, USE for resources

**Why:** Two small sets cover most incidents; RED answers "are users hurting", USE answers "why". See [observability.md](../../core/_shared/observability.md).

**How to apply:** The HTTP instrumentation emits `http.server.request.duration` — a histogram that yields rate, errors and duration together. Python emits the older name `http.server.duration` by default (verified 2026-10-09); do not claim the stable name works without checking. Custom counters (`documents.read`) keep attributes to a small fixed set. Measure the pool with USE (wait time = saturation, not a RED dimension).

**Anti-example:** a counter labeled with `tenant.id` or a raw path.

**When to deviate:** Batch and stream jobs use throughput, lag and oldest-message age instead of request RED.

## Rule: JSON stdout stays the source of truth for logs

**Why:** OTel Logs is Development in the JS SDK as of 2026-10-09 ([logging-contract.md](../../core/_shared/logging-contract.md)). Building trace correlation on stdout JSON works in every backend today; OTLP log export is an addition, not a dependency.

**How to apply:** The logger seam adds `trace_id`/`span_id` itself from the active span: TS pino `mixin`, Go slog wrapper handler using the `*Context` methods, Python structlog `add_trace_context` processor. Verified 2026-10-09: `@opentelemetry/instrumentation-pino` does not patch an ESM `import pino` (log lines had no `trace_id`), so it is disabled and the mixin does the work. OTLP log export stays optional.

**Anti-example:** passing `trace_id` by hand into each log call, or relying on `instrumentation-pino` alone.

**When to deviate:** A backend that forces its own schema; map at the exporter, never in application code.

## Rule: Flush in order on shutdown

**Why:** Batching means the last spans of in-flight requests live in memory. Shut the SDK down too early and they are lost; too late and the process is killed mid-export.

**How to apply:** Drain the server → close the pool → shutdown telemetry, with a hard timeout around the whole thing so a rollout never hangs. Python: uvicorn re-raises `SIGTERM` after shutdown, so `atexit` never runs — verified that spans are lost without an explicit shutdown in the lifespan teardown (0 spans) and exported with it (3 spans). Call `shutdown_telemetry()` in the lifespan `finally`.

**Anti-example:** `process.exit()` in a signal handler, or `shutdownTelemetry()` before `server.close()` finishes.

**When to deviate:** None. Every signal path ends in the same ordered teardown.

## Rule: Head-sample in the SDK, tail-sample in the collector

**Why:** Keeping every trace is costly; dropping at random loses the failures you need. See [observability.md](../../core/_shared/observability.md).

**How to apply:** `OTEL_TRACES_SAMPLER=parentbased_traceidratio` and `OTEL_TRACES_SAMPLER_ARG=1.0` in dev/staging, lower in production; the collector's `tail_sampling` processor keeps errors and slow traces. Metrics are never sampled.

**Anti-example:** sampling at 100% in production "for now".

**When to deviate:** Very low traffic (under ~1 rps): sample 100%.

## Rule: Tests never export telemetry

**Why:** Tests run without a collector; an SDK pointing at `localhost:4318` retries and logs exporter errors into a green test run. The no-op tracer is what tests want.

**How to apply:** `OTEL_SDK_DISABLED=true` — vitest `test.env`, pytest conftest `os.environ.setdefault("OTEL_SDK_DISABLED", "true")` before any `svc` import, Go `Setup` is only called from `main` (never from package constructors).

**Anti-example:** calling `telemetry.Setup` in `httpapi.New` "so every entry point is covered".

**When to deviate:** An integration test that specifically asserts a span is exported, against a real collector.

## Rule: Node ESM needs one CJS require of `node:http` after `start()`

**Why:** Verified 2026-10-09: `import http from 'node:http'` is not patched by the loader hook, even with `module.register`; requiring `node:http` and `node:https` once through `createRequire` after `sdk.start()` patches the shared module objects that ESM `import` reads, so spans and routes appear. `pg` (CJS) is patched either way.

**How to apply:** after `sdk.start()`, `const cjs = createRequire(import.meta.url); cjs('node:http'); cjs('node:https');`.

**Anti-example:** assuming the loader hook covers the stdlib, then seeing no HTTP spans.

**When to deviate:** None for Node ≥ 24 with ESM.

## Rule: `OTEL_TRACES_EXPORTER=none` means no active span

**Why:** Verified 2026-10-09: with the trace exporter disabled, `NodeSDK` installs no tracer provider, so there is no active span — log correlation and child spans silently do nothing.

**How to apply:** when testing trace output, use `console` (which keeps a real tracer provider), not `none`.

**Anti-example:** setting `OTEL_TRACES_EXPORTER=none` to "reduce noise" and then wondering why `trace_id` is empty.

**When to deviate:** Metrics-only services can use `none` for traces and accept that logs carry no `trace_id`.

## Rule: Keep dependencies external when bundling

**Why:** Verified 2026-10-09: a bundler that inlines `@opentelemetry/*` gives instrumentation its own module copies, so it cannot patch the ones the app imports.

**How to apply:** `tsdown` keeps dependencies external by default — leave it. Make `src/platform/telemetry.ts` a second tsdown entry (`entry: ['src/main.ts', 'src/platform/telemetry.ts']`, output `dist/platform/telemetry.mjs`) so `node --import ./dist/platform/telemetry.mjs dist/main.mjs` and `dist/main.mjs` share one module instance (verified running the built bundle).

**Anti-example:** bundling `@opentelemetry/api` in and importing a second copy in the app.

**When to deviate:** A deployment that cannot ship `node_modules`; verify spans still appear against a real collector before trusting it.

## When to deviate

- `observability.otel: false` (a static site, a one-off script): skip the SDK; keep `request_id` logging per the logging contract.
- Edge runtimes (Workers, Vercel Edge) where the Node SDK does not run: use the platform's OTel integration and verify what it supports.
- `uv run` after a `pyproject.toml` change can take longer to start than a short test sleep waits (verified 2026-10-09): re-sync the environment, or lengthen the sleep, before blaming a missing span.
