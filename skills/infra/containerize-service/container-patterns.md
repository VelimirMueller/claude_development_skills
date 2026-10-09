# Container Patterns

Reference for `containerize-service`. Every rule is a choice with a reason.

## Rule: multi-stage, with the toolchain only in the build stage
**Why:** The compiler, package manager and dev dependencies are attack surface and weight in production. A static Go service ships as a 15.7 MB image.
**How to apply:** Stage `build` installs and compiles. The final stage copies only the artifact. Measured while writing these templates: Go static 15.7 MB, Node (Hono) 225 MB, Python 202 MB.
**Anti-example:** A single `FROM node:24` stage that runs `pnpm install` and `node server.js`.

## Rule: distroless for Node and Go, slim for Python
**Why:** Distroless has no shell, no package manager and no `curl`, so an attacker who gets code execution has fewer tools. `static-debian13` exists for static Go binaries; `nodejs24-debian13` carries only Node. Python on distroless needs a matching interpreter copied between stages, which breaks silently when minor versions differ. `python:*-slim` with a non-root user is the pragmatic floor.
**How to apply:** Go → `gcr.io/distroless/static-debian13:nonroot`. Node → `gcr.io/distroless/nodejs24-debian13:nonroot`. Python → `python:3.14.8-slim-trixie`. Use the `-debug` distroless variant only to debug, never in a deployed environment.
**Anti-example:** `alpine` for glibc-linked Python wheels (musl differences break wheels and add debugging cost for a few megabytes).

## Rule: pin every base image by digest
**Why:** A tag moves. `node:24-slim` today is a different image next week, so "the same Dockerfile" builds different software. A digest names the bytes. The pin is also what makes the build reproducible.
**How to apply:** `FROM image:tag@sha256:…` — keep the tag for humans, the digest for the build. Put the references in `ARG NODE_IMAGE=…` at the top so Renovate or Dependabot (`docker` ecosystem) can bump them with a reviewed pull request. Digests are in [stack-versions.md](../_shared/stack-versions.md).
**Anti-example:** `FROM node:latest`.

## Rule: run as a non-root user with a fixed numeric id
**Why:** A container escape or a writable-mount bug is far worse as root. A numeric id works in Kubernetes `runAsNonRoot` checks; a name does not.
**How to apply:** Distroless `:nonroot` tags run as uid 65532. For `slim`, `useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app` and `USER 10001:10001`. Add `read_only: true`, `cap_drop: [ALL]` and `no-new-privileges` in compose ([compose-patterns.md](../deploy-to-hetzner/compose-patterns.md)). The Go template ran with a read-only root filesystem and stayed healthy.
**Anti-example:** No `USER` line (runs as root).

## Rule: `.dockerignore` is a security file
**Why:** `COPY . .` sends everything in the build context. `.env`, `.git` history and local `node_modules` end up in a layer that anyone with the image can read.
**How to apply:** Exclude `.git`, `.env*` (keep `.env.example`), `node_modules`, `.venv`, build output. A `.venv` copied from the host breaks the image (uv docs call this out).
**Anti-example:** No `.dockerignore`; a developer's `.env` is in layer 4.

## Rule: the image defines its own health check, using its own binary
**Why:** Orchestrators decide "ready" from it, and `docker compose up --wait` and the deploy script depend on it. In a test, a container with no healthcheck that exited and restarted in a loop still passed `up --wait`.
**How to apply:** Go: the binary has a `healthcheck` subcommand that GETs `/healthz` and exits 0 or 1; `HEALTHCHECK CMD ["/app","healthcheck"]`. Node: `/nodejs/bin/node -e "fetch(...)"`. Python: the console script has a `healthcheck` argument. `--start-period` covers boot. Probe `127.0.0.1`, not `localhost` (IPv6 resolution surprises).
**Anti-example:** `HEALTHCHECK CMD curl -f http://localhost/` on an image with no `curl`; it reports unhealthy forever.

## Rule: deterministic builds — lockfile, frozen install, one clock
**Why:** A build that resolves dependencies at build time ships what the registry says today, not what you reviewed.
**How to apply:** `pnpm install --frozen-lockfile`, `uv sync --locked`, `go mod download` with `go.sum`, `GOTOOLCHAIN=local` so Go never downloads a toolchain, `-trimpath -buildvcs=false`. Cache mounts (`--mount=type=cache`) speed builds without changing output. For byte-identical images set `SOURCE_DATE_EPOCH` and `rewrite-timestamp=true`; two `--no-cache` builds of the Go template produced the same digest.
**Anti-example:** `pnpm install` without `--frozen-lockfile` in CI.

## Rule: attach an SBOM and provenance, and verify them
**Why:** When a CVE lands you need to know which images contain the package. Provenance says which commit and workflow built the image.
**How to apply:** `--sbom=true --provenance=mode=max` writes both as attestation manifests next to the image (verified: they appear as `attestation-manifest` entries in the image index, and `docker buildx imagetools inspect <ref> --format '{{json .SBOM}}'` prints the SPDX document). They need `--push` or the containerd image store. The digest you promote is then the index digest. In CI use the pipeline's single signed attestation instead (see [set-up-delivery-pipeline](../set-up-delivery-pipeline/SKILL.md)); do not mix the two.
**Anti-example:** An SBOM in a build log nobody archives.

## Rule: scan the built image, fail on fixable HIGH and CRITICAL
**Why:** An unscanned image is an unknown. Failing on every unfixed CVE blocks every build on a base-image bug nobody can fix.
**How to apply:** Trivy with `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`, run from a digest-pinned `ghcr.io/aquasecurity/trivy` image. Not the `trivy-action`: in March 2026 attackers rewrote 76 of its 77 version tags to carry a credential stealer. Pin every third-party action by commit SHA (the pipeline skill does) and prefer a pinned container for tools. `trivy config` also scans the tofu and Dockerfile code; it reported 0 findings on the modules in [hetzner-patterns.md](../deploy-to-hetzner/hetzner-patterns.md). Grype is the alternative.
**Anti-example:** `uses: aquasecurity/trivy-action@master`.

## Rule: no secret in an image, in a build arg, or in a layer
**Why:** Layers are readable by anyone who can pull. `ARG` and `ENV` values appear in `docker history`.
**How to apply:** Runtime secrets arrive as environment or files at run time ([manage-secrets](../manage-secrets/SKILL.md)). Build-time secrets (a private registry token) use `RUN --mount=type=secret,id=npmrc`. Never `COPY .env`.
**Anti-example:** `ARG NPM_TOKEN` then `RUN npm config set //registry…:_authToken=$NPM_TOKEN`.

## Rule: one process, handle signals, log to stdout
**Why:** The orchestrator restarts a container, not a process inside it. Logs on stdout feed the collector with no file handling ([logging-contract.md](../../core/_shared/logging-contract.md)).
**How to apply:** `CMD`/`ENTRYPOINT` in exec form (JSON array) so the process is PID 1 and receives `SIGTERM`. Compose `init: true` when the app spawns children. Structured JSON logs to stdout. Rotate with Docker's `local` log driver, set in `daemon.json`.
**Anti-example:** `CMD node server.js` (shell form; the shell swallows the signal).

## Rule: OCI labels name the source
**Why:** From a running container you must find the commit and repository with one command.
**How to apply:** Set `org.opencontainers.image.source`, `.revision` and `.version` through `docker/metadata-action` in CI. They also link a GHCR package to its repository.

## Next.js note (not built during authoring)
Set `output: 'standalone'` in `next.config`, copy `.next/standalone`, `.next/static` and `public` into the final stage, and run `server.js`. Mark this unverified until built in your repository.

## When to deviate
- **Native dependencies** (sharp, bcrypt, Python wheels without musl): use `slim` instead of distroless; keep the other rules.
- **Need a shell for operations:** keep distroless in `prd`; use the `-debug` tag in a throw-away `dev` container.
- **Multi-arch** (arm64 hosts such as Hetzner `cax`): build with `--platform linux/amd64,linux/arm64`; the digest then names the index. Test on both.
- **Tiny internal tool:** a single-stage `python:slim` image is fine if it still runs non-root and is pinned.
