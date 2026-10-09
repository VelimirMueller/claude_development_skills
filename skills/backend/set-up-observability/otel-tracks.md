# Set Up Observability: Code per Track

Companion to [set-up-observability](SKILL.md). Every file ran on 2026-10-09 inside the scaffolds of [scaffold-hono-service](../scaffold-hono-service/SKILL.md), [scaffold-go-service](../scaffold-go-service/SKILL.md) and [scaffold-fastapi-service](../scaffold-fastapi-service/SKILL.md): `tsc --noEmit`, `biome check`, `vitest run`; `go vet`, `golangci-lint`, `go test` against Postgres 18; `ruff`, `mypy --strict`, `pytest` against Postgres 18. Versions: [stack-versions.md](../_shared/stack-versions.md). Package paths follow [service-layout.md](../_shared/service-layout.md); `svc` is the placeholder package name.

## TypeScript (Hono)

### `src/platform/telemetry.ts`

```ts
// Preloaded with `node --import`, so it runs before any app module is imported.
// Endpoint, protocol, headers, service name and sampler come from the standard OTEL_* variables.
import { createRequire, register } from 'node:module';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-http';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { NodeSDK } from '@opentelemetry/sdk-node';

// Loader hook for ESM-only libraries (OpenTelemetry's ESM guide).
register('@opentelemetry/instrumentation/hook.mjs', import.meta.url);

const sdk = new NodeSDK({
  // No traceExporter: NodeSDK builds an OTLP exporter from OTEL_EXPORTER_OTLP_* itself.
  metricReaders: [new PeriodicExportingMetricReader({ exporter: new OTLPMetricExporter() })],
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false }, // one span per file operation: noise
      '@opentelemetry/instrumentation-pino': { enabled: false }, // the logger seam adds trace_id itself
    }),
  ],
});

sdk.start();

// Node built-ins are out of reach of the ESM hook. Requiring them once through CJS, after start(),
// lets the instrumentation patch the module objects that ESM `import` shares.
const cjs = createRequire(import.meta.url);
cjs('node:http');
cjs('node:https');

/** Call once, after the HTTP server has drained. Flushes batched spans and metrics. */
export async function shutdownTelemetry(): Promise<void> {
  await sdk.shutdown();
}
```

### `src/platform/tracer.ts`

```ts
import { type Attributes, context, metrics, SpanStatusCode, trace } from '@opentelemetry/api';
import { getRPCMetadata, RPCType } from '@opentelemetry/core';
import { createMiddleware } from 'hono/factory';

const tracer = trace.getTracer('svc');
const meter = metrics.getMeter('svc');

/** One span per use case. Attributes are ids and enums, never personal data or free text. */
export function withSpan<T>(
  name: string,
  attributes: Attributes,
  fn: () => Promise<T>,
): Promise<T> {
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      return await fn();
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR });
      throw err;
    } finally {
      span.end();
    }
  });
}

/** Business counter. Keep attribute values to a small fixed set. */
export const documentsRead = meter.createCounter('documents.read', {
  description: 'Documents served',
});

/** Node's http instrumentation cannot see Hono's router. This hands it the route template, so
 *  span names and http.server.request.duration use `/documents/{id}`, not raw paths. */
export const routeTemplate = createMiddleware(async (c, next) => {
  await next();
  const meta = getRPCMetadata(context.active());
  if (meta?.type === RPCType.HTTP) meta.route = c.req.routePath;
});
```

### Wiring deltas

`src/platform/logger.ts` — add the import and the `mixin()` (the rest of the file is unchanged):

```ts
import { trace } from '@opentelemetry/api';
// ...
return pino({
  // ... level, base, timestamp, messageKey, formatters, redact ...
  // trace_id and span_id per the logging contract. Added here, not by instrumentation-pino,
  // which does not patch ESM imports of pino.
  mixin() {
    const ctx = trace.getActiveSpan()?.spanContext();
    return ctx ? { trace_id: ctx.traceId, span_id: ctx.spanId } : {};
  },
});
```

`src/main.ts` — flush after the pool closes, inside the `server.close` callback:

```ts
import { shutdownTelemetry } from './platform/telemetry.ts';
// ...
server.close(async (err) => {
  await pool.end();
  await shutdownTelemetry(); // after the drain, so the last spans of in-flight requests are exported
  process.exit(err ? 1 : 0);
});
```

`src/app.ts` — route template first, before auth and edge:

```ts
import { routeTemplate } from './platform/tracer.ts';
// ...
app.use(routeTemplate);
```

`tsdown.config.ts` — two entries so the preload and the app share one module instance:

```ts
import { defineConfig } from 'tsdown';

export default defineConfig({
  entry: ['src/main.ts', 'src/platform/telemetry.ts'],
  platform: 'node',
  target: 'node24',
  clean: true,
  sourcemap: true,
});
```

`package.json` scripts:

```json
"scripts": {
  "dev": "tsx watch --env-file-if-exists=.env --import ./src/platform/telemetry.ts src/main.ts",
  "start": "node --import ./dist/platform/telemetry.mjs dist/main.mjs"
}
```

`vitest.config.ts`:

```ts
test: {
  environment: 'node',
  env: { OTEL_SDK_DISABLED: 'true' },
  // ...
}
```

A use-case span and counter, in `documents.service.ts` style:

```ts
import { documentsRead, withSpan } from '../platform/tracer.ts';
// ...
async get(principal, id) {
  return withSpan('documents.get', { 'tenant.id': principal.tenantId }, async () => {
    const doc = await deps.documentsFor(principal).findById(id);
    if (!doc) throw new AppError(404, 'Not Found', { detail: 'Document does not exist' });
    assertAllowed(documentPolicy.read(principal, doc));
    documentsRead.add(1);
    return doc;
  });
}
```

## Go

### `internal/platform/telemetry/telemetry.go`

```go
// Package telemetry owns OpenTelemetry setup. Endpoint, protocol, headers, service name,
// sampler and propagators all come from standard OTEL_* environment variables.
package telemetry

import (
	"context"
	"errors"

	"go.opentelemetry.io/contrib/exporters/autoexport"
	"go.opentelemetry.io/contrib/propagators/autoprop"
	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// Setup installs the global tracer and meter providers and returns one Shutdown that flushes both.
// Logs stay JSON on stdout (see logging); the platform ships them.
// Call it first in main, and call the returned function after the HTTP server has drained.
func Setup(ctx context.Context) (shutdown func(context.Context) error, err error) {
	res, err := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK(), resource.WithProcess())
	if err != nil {
		return nil, err
	}

	spanExp, err := autoexport.NewSpanExporter(ctx)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(spanExp), sdktrace.WithResource(res))

	reader, err := autoexport.NewMetricReader(ctx)
	if err != nil {
		return nil, err
	}
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader), sdkmetric.WithResource(res))

	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(autoprop.NewTextMapPropagator()) // OTEL_PROPAGATORS, default tracecontext+baggage

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx))
	}, nil
}
```

### `internal/transport/httpapi/route.go`

```go
package httpapi

import (
	"net/http"
	"strings"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// routeTag gives otelhttp the route template ("/documents/{id}") for span names and metrics.
// otelhttp wraps the whole handler, so it never sees the pattern the mux matched: ask the mux first.
func routeTag(mux *http.ServeMux) middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, pattern := mux.Handler(r); pattern != "" {
				route := pattern
				if _, path, ok := strings.Cut(pattern, " "); ok { // "GET /documents/{id}" -> "/documents/{id}"
					route = path
				}
				attr := attribute.String("http.route", route)
				span := trace.SpanFromContext(r.Context())
				span.SetName(r.Method + " " + route)
				span.SetAttributes(attr)
				if l, ok := otelhttp.LabelerFromContext(r.Context()); ok {
					l.Add(attr)
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
```

### Wiring deltas

`internal/platform/logging/logging.go` — the added import, the `traceHandler` type with its three methods, and the changed return line:

```go
import (
	// ...
	"go.opentelemetry.io/otel/trace"
)

// return slog.New(traceHandler{h}).With(...) — wrap the handler so it can add the span context:
return slog.New(traceHandler{h}).With("service.name", service, "deployment.environment.name", environment)

// traceHandler adds trace_id and span_id from the active span. Log with the *Context methods
// (InfoContext, ErrorContext) so the span is in ctx.
type traceHandler struct{ slog.Handler }

func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(a []slog.Attr) slog.Handler {
	return traceHandler{h.Handler.WithAttrs(a)}
}
func (h traceHandler) WithGroup(n string) slog.Handler { return traceHandler{h.Handler.WithGroup(n)} }
```

`cmd/svc/main.go` — order: `Setup` before logger/pool, the `otelpgx` tracer line, `otelhttp.NewHandler`, and the shutdown order:

```go
// Telemetry first: the pool, the HTTP handler and the logger below are all instrumented.
shutdownTelemetry, err := telemetry.Setup(ctx)
if err != nil {
	return fmt.Errorf("telemetry: %w", err)
}
log := logging.New(os.Stdout, cfg.LogLevel, cfg.ServiceName, cfg.Environment)

poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
if err != nil {
	return errors.New("DATABASE_URL: not a valid connection string")
}
poolCfg.ConnConfig.Tracer = otelpgx.NewTracer() // one span per query
pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
// ...

srv := &http.Server{
	Addr:    net.JoinHostPort("", strconv.Itoa(cfg.Port)),
	Handler: otelhttp.NewHandler(api.Handler(), "http.server"), // outermost: spans cover every middleware
	// ...
}

// ... on ctx.Done():
log.Info("shutting down")
api.Drain()
shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cfg.ShutdownTimeout)
defer cancel()
if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
	return fmt.Errorf("shutdown: %w", err)
}
// The server has drained: flush the last spans, metrics and logs before the pool closes.
if err := shutdownTelemetry(shutdownCtx); err != nil {
	return fmt.Errorf("telemetry shutdown: %w", err)
}
```

`internal/transport/httpapi/server.go` — `routeTag(mux)` first in the middleware chain:

```go
return chain(mux,
	routeTag(mux), a.recoverer, a.accessLog,
	secureHeaders, corsAllowList(a.deps.AllowedOrigins), maxBody(1<<20), deadline(10*time.Second),
)
```

A manual use-case span (API per the otel-go docs; not part of the verified scaffold run):

```go
import (
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

ctx, span := otel.Tracer("svc").Start(ctx, "documents.get",
	trace.WithAttributes(attribute.String("tenant.id", p.TenantID)))
defer span.End()

doc, err := store.FindByID(ctx, id)
if err != nil {
	span.RecordError(err)
	span.SetStatus(codes.Error, "get document failed")
	return repository.Document{}, err
}
```

Optional OTLP log bridge: `go.opentelemetry.io/contrib/bridges/otelslog` (v0.21.0 exists) with `slog.NewMultiHandler` (Go 1.26+) forwards slog records to OTLP logs. Not run in the scaffold.

## Python (FastAPI)

### `src/svc/platform/telemetry.py`

```python
"""OpenTelemetry bootstrap and the app's tracing and metrics seam.

Endpoint, protocol, headers, service name and sampler come from the standard OTEL_* variables.
"""

from opentelemetry import metrics, trace
from opentelemetry.instrumentation.auto_instrumentation import initialize
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.trace import TracerProvider

tracer = trace.get_tracer("svc")
meter = metrics.get_meter("svc")

documents_read = meter.create_counter("documents.read", description="Documents served")


def init_telemetry() -> None:
    """Start the SDK and patch FastAPI, SQLAlchemy and the HTTP client libraries.

    Call it first in `main.py`, before anything imports `fastapi`: the instrumentation replaces
    classes, and a module that already did `from fastapi import FastAPI` keeps the original.
    """
    initialize()


def shutdown_telemetry() -> None:
    """Flush batched spans and metrics. Call it from the lifespan teardown, not from atexit:
    uvicorn re-raises SIGTERM after shutdown, so the process dies before atexit hooks run
    and the last spans are lost."""
    tracer_provider = trace.get_tracer_provider()
    if isinstance(tracer_provider, TracerProvider):
        tracer_provider.shutdown()
    meter_provider = metrics.get_meter_provider()
    if isinstance(meter_provider, MeterProvider):
        meter_provider.shutdown()
```

### `src/svc/main.py`

```python
"""ASGI entrypoint: `fastapi run` and `uvicorn svc.main:app` import `app` from here."""

from svc.platform.telemetry import init_telemetry

init_telemetry()  # must run before the imports below create FastAPI or SQLAlchemy objects

from svc.app import create_app  # noqa: E402
from svc.config import get_settings  # noqa: E402

app = create_app(get_settings())
```

### Wiring deltas

`src/svc/platform/logging.py` — the `add_trace_context` processor and its place in the processors list:

```python
from opentelemetry import trace


def add_trace_context(
    _logger: object, _method: str, event_dict: structlog.typing.EventDict
) -> structlog.typing.EventDict:
    """trace_id and span_id from the active span, per the logging contract."""
    ctx = trace.get_current_span().get_span_context()
    if ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict

# in configure_logging():
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        add_trace_context,   # after merge_contextvars, before add_log_level
        structlog.processors.add_log_level,
        # ...
    ],
)
```

`src/svc/app.py` — `shutdown_telemetry()` in the lifespan `finally`:

```python
from svc.platform.telemetry import shutdown_telemetry
# ...
try:
    yield
finally:
    # Uvicorn has stopped accepting connections and drained in-flight requests by now.
    log.info("stopping")
    if engine is not None:
        await engine.dispose()
    shutdown_telemetry()  # after the drain; atexit is too late under uvicorn
```

`pyproject.toml` — the OpenTelemetry dependency lines:

```toml
"opentelemetry-distro>=0.66b1",
"opentelemetry-exporter-otlp>=1.45.1",
"opentelemetry-instrumentation-fastapi>=0.66b1",
"opentelemetry-instrumentation-asyncpg>=0.66b1",
```

`tests/conftest.py`:

```python
import os

# Before any svc import: tests never export telemetry.
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
```

A manual use-case span (not run in the scaffold):

```python
from svc.platform.telemetry import documents_read, tracer


async def get(self, principal: Principal, doc_id: str) -> Document:
    with tracer.start_as_current_span(
        "documents.get", attributes={"tenant.id": principal.tenant_id}
    ):
        doc = await self._store.find_by_id(doc_id)
        if doc is None:
            raise AppError(404, "Not Found", "Document does not exist")
        documents_read.add(1)
        return doc
```

`record_exception` and the ERROR status are set automatically when an exception leaves the block.
