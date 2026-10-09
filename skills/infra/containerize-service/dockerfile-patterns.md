# Dockerfile Patterns

Three templates, each built and run during authoring (2026-10-09): non-root, healthy, digests current on that date. Replace the digests from [stack-versions.md](../_shared/stack-versions.md) when you copy. The sample services are minimal; the Dockerfiles are the point.

All three share the shape: `build` stage → final stage; digests in `ARG`; cache mounts; exec-form `CMD`; own-binary `HEALTHCHECK`.

## Node (pnpm)

Assumes `package.json` has a `build` script writing `dist/` and a `packageManager` field (`"pnpm@12.10.1"`), so Corepack uses the pinned pnpm. Measured: image 225 MB, healthy, runs as uid 65532.

```dockerfile
# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66
ARG RUNTIME_IMAGE=gcr.io/distroless/nodejs24-debian13:nonroot@sha256:9eeb7f5887d0e239e78264b06f7f11d2e14be534050481803a9e4728fcdd278e

FROM ${NODE_IMAGE} AS build
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile
COPY . .
RUN pnpm build \
 && pnpm prune --prod

FROM ${RUNTIME_IMAGE}
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
CMD ["dist/server.js"]
```

Service side of the health seam (Hono):

```ts
app.get('/healthz', (c) => c.text('ok'));
```

**Why `pnpm prune --prod` and not `pnpm deploy`:** a single-package repository needs no workspace logic. For a monorepo, use `pnpm --filter <name> --prod deploy /out` and copy `/out`; pnpm 12 builds a dedicated lockfile for it (no `--legacy` or `injectWorkspacePackages` needed since 12.2.0). Not built during authoring.

**Why Corepack:** Node 24 still ships it. Node 25 and later do not, so install pnpm with `npm i -g pnpm@<version>` there.

## Go

Static binary, `CGO_ENABLED=0`, `-trimpath`, distroless static. Measured: 15.7 MB, healthy, runs with `read_only: true` in compose.

```dockerfile
# syntax=docker/dockerfile:1
ARG GO_IMAGE=golang:1.27.2-trixie@sha256:e58d6f83b3416618d8bcac2b3dde1b7f7e3c4a77d25e88637f8bbae81536c48d
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3

FROM ${GO_IMAGE} AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/app ./cmd/app

FROM ${RUNTIME_IMAGE}
COPY --from=build /out/app /app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/app", "healthcheck"]
ENTRYPOINT ["/app"]
```

Service side: a `healthcheck` subcommand in `main`, because the image has no shell or `curl`.

```go
if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
	c := http.Client{Timeout: 2 * time.Second}
	r, err := c.Get("http://127.0.0.1:8080/healthz")
	if err != nil || r.StatusCode != 200 {
		os.Exit(1)
	}
	return
}
```

If the binary needs CGO (sqlite, some drivers): switch the final stage to `gcr.io/distroless/base-debian13:nonroot` and set `CGO_ENABLED=1` in a `golang:*-trixie` build stage.

## Python (uv)

Follows the uv Docker guide: pinned `uv` binary, bytecode compile, locked sync in two layers, `.venv` copied alone. Measured: 202 MB, healthy, runs as uid 10001. `requires-python` and `.python-version` must match the image tag.

```dockerfile
# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.24@sha256:3af4716e991d6956a41e573eab705d0ee08500cd829ed30293eb8472f372c65a

FROM ${UV_IMAGE} AS uv

FROM ${PYTHON_IMAGE} AS build
COPY --from=uv /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0 UV_NO_DEV=1
WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable

FROM ${PYTHON_IMAGE}
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build --chown=app:app /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["svc", "healthcheck"]
CMD ["svc"]
```

Service side: a console script with a `healthcheck` argument (`[project.scripts] svc = "svc:main"`):

```python
def main():
    if len(sys.argv) > 1 and sys.argv[1] == "healthcheck":
        urllib.request.urlopen("http://127.0.0.1:8000/healthz", timeout=2)
        return
    ...  # serve
```

`urlopen` raises on a non-2xx status and on connection failure, so the process exits non-zero. For FastAPI replace `main` with `uvicorn svc.app:app --host 0.0.0.0` and keep the same probe.

## Compose service block for any track

```yaml
app:
  image: ${APP_IMAGE:?APP_IMAGE must be image@sha256:digest}
  restart: unless-stopped
  read_only: true
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]
  init: true
```

The full stack is in [compose-patterns.md](../deploy-to-hetzner/compose-patterns.md).

## When to deviate
- Python with heavy native wheels or a build toolchain at runtime: keep `slim`, add only the runtime libraries.
- Node with a custom runtime (`bun`): swap the base image and install line; keep stages, digest pin, non-root.
- A repository with several services: one Dockerfile per service under `services/<name>/`, one `.dockerignore` at the context root.
