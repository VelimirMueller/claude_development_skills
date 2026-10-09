# OTel Collector Patterns

Reference for [deploy-otel-collector](./SKILL.md). Signal naming and what to emit is in
[observability](../../core/_shared/observability.md); this file is how the collector carries it.

## Rule: one gateway per environment; agents only for host data

**Why:** A gateway is one process that every service exports to. The backend credential, the redaction rules and the
sampling policy then exist once per environment, and a rotated key is a one-file change. Tail sampling decides per trace,
so it needs all spans of a trace in one process; a gateway provides that, per-service sidecars do not. An agent on
every host multiplies the config you must keep identical and adds a hop for no gain on a Compose box.
**How to apply:** One `otel-collector` service per environment, same Compose project as the apps, reached by service
name. Add an agent (a second collector with `hostmetrics` / `filelog` receivers, exporting to the gateway) only when you
need node metrics or log files from machines where the apps cannot push themselves.
**Anti-example:** A collector sidecar per service with a copy of the backend API key in each.

## Rule: `memory_limiter` first, `batch` last, in that order

**Why:** The limiter refuses data when memory is near the limit, so it must see data before anything allocates;
otherwise a traffic spike kills the collector and loses everything in flight. Batching must come after any step that
drops data (redaction, sampling), so batches are not built from data that is then thrown away.
**How to apply:** `[memory_limiter, resource, attributes/redact, redaction, (tail_sampling), batch]`. Set `limit_mib` to
about 80% of the container memory limit and `spike_limit_mib` to about 20% of `limit_mib` (the upstream starting point).
The batch processor is beta but is the standard choice; exporter-level batching (`sending_queue.batch`) is the
alternative once it matters.
**Anti-example:** `batch` before `memory_limiter`, or no limiter and no container memory limit.

## Rule: redact in the collector even though apps already do

**Why:** The logging contract tells services not to emit secrets. Instrumentation libraries still capture headers, URLs
and statements nobody wrote by hand. The collector is the last point before data leaves your network, and it is the only
point that covers every language with one rule set. Two layers: a mistake in one is caught by the other.
**How to apply:** `attributes` deletes known-bad keys exactly (cheap, no false positives). `redaction` in deny-list mode
(`allow_all_keys: true`) masks keys matching `password|token|secret|…` and values matching bearer tokens, JWTs and
provider key shapes. `summary: info` records how many keys were masked, not which. The processor is beta for traces and
alpha for logs and metrics; test new patterns against real telemetry in `dev` first. Do not switch to allow-list mode
(`allowed_keys`) unless you can enumerate every attribute: an empty list removes all attributes.
**Anti-example:** Relying on the backend to hide fields at query time. The data is already stored.

## Rule: services know one endpoint; the collector knows the backend

**Why:** If services carry backend URLs and keys, a backend change is a redeploy of everything, and every service holds a credential. With `OTEL_EXPORTER_OTLP_ENDPOINT` pointing at the gateway, application code and its env never mention the backend.
**How to apply:** The four variables in step 6 of the skill; HTTP/protobuf on 4318 as the default (works through proxies and from serverless runtimes), gRPC on 4317 for in-cluster high volume.
The endpoint is a base URL (no `/v1/traces`). Instrumentation must treat the collector as optional: exporters drop data when it is unreachable, and the app still starts.
**Anti-example:** Each service with its own `SIGNOZ_INGESTION_KEY`.

## Rule: probe the collector from outside, because the image has no shell

**Why:** `otelcol-contrib` is built `FROM scratch`. `docker exec` has nothing to run, so a Compose `healthcheck:` using
`curl` or `wget` always fails and marks a healthy container unhealthy.
**How to apply:** Enable the `health_check` extension on `0.0.0.0:13133` and publish it on loopback; probe it from the host
(`curl -fsS http://127.0.0.1:13133/`), from the uptime monitor, or from the deploy script's smoke test. Do not use
`depends_on: condition: service_healthy` on the collector; apps must not wait for it.
**Anti-example:** Copying a `curl` binary into a custom image just to satisfy `healthcheck:`.

## Rule: tail sampling only when volume or cost demands it, and only on one instance

**Why:** Head sampling in the SDK is free but cannot know whether a trace will fail. Tail sampling keeps all errors and
slow traces and a fraction of the rest, but it buffers every span until the decision, so it costs memory and delays export
by `decision_wait`. It is correct only if one collector instance sees the whole trace.
**How to apply:** Skip it at low volume (keep 100%). When needed, add before `batch`:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 50000
    policies:
      - { name: errors, type: status_code, status_code: { status_codes: [ERROR] } }
      - { name: slow, type: latency, latency: { threshold_ms: 1000 } }
      - { name: baseline, type: probabilistic, probabilistic: { sampling_percentage: 10 } }
```

Raise the container memory limit and `limit_mib` with `num_traces`. Scaling to several gateway replicas requires
trace-ID-aware load balancing in front; at that point read the upstream docs, do not guess.
**Anti-example:** Two gateway replicas behind round-robin DNS with tail sampling on: every trace is cut in half.

## Rule: a public ingest endpoint needs TLS and a token

**Why:** Vercel and Supabase Edge Functions cannot reach a private network. An open OTLP port on the internet lets anyone
write junk into your backend and fill its disk and bill.
**How to apply:** Terminate TLS at the host's reverse proxy (`https://otel.<domain>` to `127.0.0.1:4318`), and require a bearer
token in the collector:

```yaml
extensions:
  bearertokenauth:
    token: ${env:OTEL_INGEST_TOKEN}
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
        auth:
          authenticator: bearertokenauth
service:
  extensions: [health_check, bearertokenauth]
```

Clients set `OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20<token>` (percent-encode the space). One token per client
group, rotated like any secret ([manage-secrets](../manage-secrets/SKILL.md)). Keep gRPC and the health port off the public
interface. The extension is beta.
**Anti-example:** Publishing `0.0.0.0:4318` on the firewall "temporarily".

## Backend overlays

Each overlay defines only `exporters: otlp/backend`; the base `config.yaml` stays identical in every environment. Mount
one as `/etc/otelcol/backend.yaml`. Facts as verified 2026-10-09:

```yaml
# otel/backend-signoz.yaml  (self-hosted SigNoz: its ingester listens on 4317 / 4318)
exporters:
  otlp/backend:
    endpoint: ${env:BACKEND_ENDPOINT}      # e.g. signoz-ingester:4317 on a shared Docker network, or host:4317
    tls:
      insecure: true                       # private network only
```
```yaml
# otel/backend-signoz-cloud.yaml
exporters:
  otlp/backend:
    endpoint: ingest.${env:SIGNOZ_REGION}.signoz.cloud:443
    headers:
      signoz-ingestion-key: ${env:SIGNOZ_INGESTION_KEY}
```
```yaml
# otel/backend-lgtm.yaml  (grafana/otel-lgtm: OTLP on 4317 / 4318, Grafana on 3000)
exporters:
  otlp/backend:
    endpoint: lgtm:4317
    tls:
      insecure: true
```
```yaml
# otel/backend-generic.yaml
exporters:
  otlp/backend:
    endpoint: ${env:BACKEND_ENDPOINT}
    headers:
      authorization: ${env:BACKEND_AUTH}   # e.g. "Bearer …"; remove the block if the backend needs none
```

Notes per backend:

- **SigNoz self-hosted:** its ingester accepts OTLP on 4317 (gRPC) and 4318 (HTTP). Our collector in front of it is worth
  having when you need redaction, one stable endpoint, or a retry queue between your apps and SigNoz. If SigNoz is the only
  backend and nothing needs redaction, apps may export to its ingester directly; do not run two layers for nothing.
- **SigNoz Cloud:** endpoint `ingest.<region>.signoz.cloud:443`, header `signoz-ingestion-key`. TLS is on by default; do not set `insecure`.
- **grafana/otel-lgtm:** bundles an OTel Collector, Prometheus, Tempo, Loki, Pyroscope and Grafana in one image. Upstream
  states it is for development, demo and testing; for prd, choose SigNoz or Grafana Cloud. Its Grafana UI is on port 3000.
- **Generic OTLP:** gRPC is the default of the `otlp` exporter. For an HTTP-only backend, use the `otlphttp` exporter under
  the name `otlphttp/backend` and change the three `exporters:` lines in `config.yaml` to match.
- **Sentry:** errors go through the Sentry SDK ([configure-error-tracking](../../frontend/configure-error-tracking/SKILL.md) for
  the frontend). Whether to route OTLP to Sentry as well is unverified here; check Sentry's OTLP docs before adding it.

## When to deviate

- **Single small service, SigNoz Cloud, no sensitive data:** export straight from the SDK to the backend and skip the
  collector. Add it the day you need redaction, a second backend, or sampling.
- **Kubernetes:** run the collector as a Deployment (gateway) plus a DaemonSet (agent) from the upstream Helm chart; the
  processor order and redaction rules above carry over.
- **Very high volume:** switch SDK export to gRPC, add exporter batching and a persistent queue (`file_storage`
  extension) so a backend outage does not drop data; size memory from measurements.
