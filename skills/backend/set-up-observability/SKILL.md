---
name: set-up-observability
description: Use when a backend service should emit traces, metrics and trace-correlated logs. Wires app-side OpenTelemetry - SDK started before app code, HTTP and DB auto-instrumentation, use-case spans, RED metrics, OTEL_* env only, flush on shutdown (Hono, Go, FastAPI).
---

# Set Up Observability

Rules and rationale: [otel-patterns.md](otel-patterns.md). Code per track: [otel-tracks.md](otel-tracks.md). One seam, one exporter: [observability.md](../../core/_shared/observability.md). Trace-correlated logs: [logging-contract.md](../../core/_shared/logging-contract.md). Seam paths: [service-layout.md](../_shared/service-layout.md). Env keys: [config.md](../_shared/config.md).

Bootstrap path: [observability.md](../../core/_shared/observability.md) shows `src/instrumentation.ts` as an example; the backend layout below wins — `src/platform/telemetry.ts` (TS), `internal/platform/telemetry/telemetry.go` (Go), `src/svc/platform/telemetry.py` (Python).

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null    # observability.otel, observability.backend, backend.track
grep -rnE "opentelemetry" package.json go.mod pyproject.toml 2>/dev/null
grep -rnE "console\.(log|error|warn)|print\(" --include=*.ts --include=*.go --include=*.py src internal cmd 2>/dev/null | head
grep -n "OTEL_" .env.example 2>/dev/null
ls src/platform/telemetry.ts internal/platform/telemetry src/svc/platform/telemetry.py 2>/dev/null
```

Read the profile first; detect only what it leaves open ([stack-profile.md](../../core/_shared/stack-profile.md)).

## 2. Decide

- `observability.otel: false`: stop. Keep `request_id` logging per the logging contract's "When to deviate" (generate a request id and log it as `request_id`). No OTel SDK.
- No telemetry module and no OTel dependencies: full setup, steps 3 to 7.
- A telemetry module exists but misses auto-instrumentation, route templates, trace fields or shutdown flush: apply the deltas from [otel-tracks.md](otel-tracks.md) in place. Do not rewrite what works.
- Everything present and step 7 passes: report "already in place" and stop.

## 3. Detect track

| `backend.track` | Do |
|---|---|
| `hono`, `go`, `fastapi` | Continue. |
| `nextjs` | Stop. Use [build-nextjs-backend](../build-nextjs-backend/SKILL.md). |
| `supabase` | Stop. Use [set-up-supabase](../set-up-supabase/SKILL.md) for the edge-function telemetry notes. |
| `none` or unset | Run `set-up-stack-profile`, then a `scaffold-*-service` skill. |

Also read `observability.backend` (`signoz` \| `grafana-lgtm` \| `sentry` \| `none`) only to write the exporter env example in step 6. The `OTEL_*` variables are the same for all backends ([observability.md](../../core/_shared/observability.md)).

## 4. Install only what is missing

```bash
pnpm add @opentelemetry/api @opentelemetry/core @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node @opentelemetry/exporter-metrics-otlp-http @opentelemetry/sdk-metrics   # hono
go get go.opentelemetry.io/otel go.opentelemetry.io/otel/sdk go.opentelemetry.io/otel/sdk/metric go.opentelemetry.io/contrib/exporters/autoexport go.opentelemetry.io/contrib/propagators/autoprop go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp github.com/exaring/otelpgx   # go
uv add opentelemetry-distro opentelemetry-exporter-otlp opentelemetry-instrumentation-fastapi opentelemetry-instrumentation-asyncpg   # fastapi (NOT instrumentation-sqlalchemy, see tracks)
```

Use the profile's package manager. Verify each line in [stack-versions.md](../_shared/stack-versions.md) before you write it.

## 5. Generate the seams

Create from [otel-tracks.md](otel-tracks.md), skipping files that exist:

```
TS      src/platform/telemetry.ts, src/platform/tracer.ts + deltas to logger.ts, main.ts, app.ts, tsdown.config.ts, package.json, vitest.config.ts
Go      internal/platform/telemetry/telemetry.go, internal/transport/httpapi/route.go + deltas to logging.go, main.go, server.go
Python  src/svc/platform/telemetry.py + deltas to main.py, logging.py, app.py, pyproject.toml, tests/conftest.py
```

Paths follow [service-layout.md](../_shared/service-layout.md). `tracer` is the platform seam that owns the OTel SDK.

## 6. Wire

1. **Order.** Telemetry first, then config, logger, DB, app. The SDK patches modules at load; anything imported before it keeps the unpatched original ([otel-patterns.md](otel-patterns.md) rule 1).
2. **Route templates.** TS: `app.use(routeTemplate)` as the first middleware. Go: `routeTag(mux)` first in the chain. Python: the FastAPI instrumentation does it itself.
3. **Logger trace fields.** The logger seam adds `trace_id`/`span_id` from the active span (pino `mixin`, slog `traceHandler`, structlog `add_trace_context`), per [logging-contract.md](../../core/_shared/logging-contract.md).
4. **Shutdown order.** Drain server → close pool → flush telemetry, with a hard timeout so a rollout never hangs.
5. **Tests disable the SDK.** `OTEL_SDK_DISABLED=true` (vitest `test.env`, pytest conftest before any `svc` import; Go: `Setup` is only called from `main`).
6. **`.env.example`** (plus `DEPLOYMENT_ENVIRONMENT` and `OTEL_SERVICE_NAME`, already read by [config.md](../_shared/config.md)):

```bash
OTEL_SERVICE_NAME=svc
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0
OTEL_RESOURCE_ATTRIBUTES=service.version=dev
```

`deployment.environment.name` comes from `DEPLOYMENT_ENVIRONMENT` ([config.md](../_shared/config.md)): in the deploy config, append `deployment.environment.name=$DEPLOYMENT_ENVIRONMENT` to `OTEL_RESOURCE_ATTRIBUTES` — not in `.env.example`.

## 7. Verify

```bash
OTEL_TRACES_EXPORTER=console pnpm dev                            # hono
OTEL_TRACES_EXPORTER=console go run ./cmd/svc                    # go
OTEL_TRACES_EXPORTER=console uv run fastapi run                  # fastapi
```

Curl one route and expect:

- span name TS `GET /notes/:id` with attribute `http.route`; Go `GET /notes/{id}` with `http.route`; Python `GET /notes/{note_id}`;
- DB spans appear when the DB is used — Go: `otelpgx` spans; TS: `pg.query:SELECT postgres` with attribute `db.system.name=postgresql`; Python: asyncpg spans with `db.system=postgresql`;
- the structured log line of the same request carries the same `trace_id`;
- send `SIGTERM` right after a request: the spans still appear (flush on shutdown).

Then finish with the four-step Verify in [observability.md](../../core/_shared/observability.md).

## References

- [otel-patterns.md](otel-patterns.md): the rules and the verified pitfalls behind each decision.
- [otel-tracks.md](otel-tracks.md): files for Hono, Go and FastAPI, with wiring deltas and span examples.
