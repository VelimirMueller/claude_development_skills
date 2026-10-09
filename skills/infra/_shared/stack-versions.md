# Stack Versions (infra)

Verified lines for the infra skills. **Verified 2026-10-09.** Re-verify before scaffolding; this table is a floor, not a pin.
"verified-from" names the source that was read on that date. "unverified" means it was not checked against a live source.

## Runtime and build

| Tool | Line | Verified from | Note |
|---|---|---|---|
| OpenTofu | 1.13.1 (2026-10-01) | GitHub releases, `CHANGELOG.md`, endoflife.date | Supported: 1.12.x until 2027-02-01, 1.13.x until 2027-08-01. 1.11 and 1.10 are end of life |
| OpenTofu features used | state + plan encryption, `enforced`, `fallback`; S3 backend `use_lockfile`; ephemeral variables and write-only attributes | OpenTofu docs (`state/encryption`, `backends/s3`), changelogs 1.11 to 1.13 | `use_lockfile` needs a store that supports `If-None-Match` conditional writes |
| `opentofu/setup-opentofu` | v2.0.2 (a1320f892987e89d278cc92dc5adc984fb93aca4) | GitHub releases | Org is `opentofu`, not `open-tofu` |
| Docker Engine | 29.9.0 (2026-10-08) | `moby/moby` releases | Install from Docker's apt repo, not the distro `docker.io` |
| Docker Compose | v5.6.0 (2026-10-02) | `docker/compose` releases | No `version:` key in compose files. `up --wait --wait-timeout` verified locally |
| Docker Buildx | v0.38.0 | `docker/buildx` releases | `--sbom=true --provenance=mode=max` per Docker docs |
| BuildKit | v0.34.0 | `moby/buildkit` releases | |
| Traefik | v3.7.14 (2026-10-06) | GitHub releases, endoflife.date | 3.6 is end of life. Image digest in `compose-patterns.md` |
| Trivy | 0.75.0 (2026-10-01) | GitHub releases | `aquasecurity/trivy-action` was compromised in March 2026 (tags rewritten). Run the pinned image instead |
| Grype / Syft | 0.120.1 / 1.54.1 | GitHub releases | Alternative scanner / SBOM tool |
| restic | 0.19.1 | Homebrew + Docker Hub tag `restic/restic:0.19.1` | Backup tool in `compose-patterns.md` |
| pgBackRest | 2.59.3 | Homebrew | Step-up for point-in-time recovery |
| k3s | v1.37.1+k3s1 | `k3s-io/k3s` releases | The graduation target in `deploy-to-hetzner` |
| uv | 0.12.24 | GitHub releases; `ghcr.io/astral-sh/uv:0.12.24` pulled | |
| pnpm | 12.10.1 | npm | `pnpm prune --prod` verified in a built image |
| Node.js | 24.21.0 (Active LTS) | nodejs.org dist index, endoflife.date | Node 26 becomes LTS on 2026-10-28. Stay on 24 until then |
| Go | 1.27.2 (1.26.9 also supported) | go.dev/dl | Set `GOTOOLCHAIN=local` in builds |
| Python | 3.14.8 (3.13.16, 3.12.15 supported) | endoflife.date, Docker Hub | Match `.python-version` |
| PostgreSQL | 18.6 (17.11, 16.15 supported) | endoflife.date, Docker Hub | PG 18 image: mount the volume at `/var/lib/postgresql`, not `/var/lib/postgresql/data` |
| Debian | 13 "trixie" (current stable) | endoflife.date, Docker repo has `trixie` | Debian 12 until 2028-06-30 |
| Ubuntu | 26.04 LTS (24.04 also current) | endoflife.date; Docker repo has `noble` and `resolute` | IONOS image alias `ubuntu:latest` |

## Base images (digests read 2026-10-09; Renovate or Dependabot bumps them)

| Image | Digest |
|---|---|
| `node:24.21.0-trixie-slim` | `sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66` |
| `gcr.io/distroless/nodejs24-debian13:nonroot` | `sha256:9eeb7f5887d0e239e78264b06f7f11d2e14be534050481803a9e4728fcdd278e` |
| `golang:1.27.2-trixie` | `sha256:e58d6f83b3416618d8bcac2b3dde1b7f7e3c4a77d25e88637f8bbae81536c48d` |
| `gcr.io/distroless/static-debian13:nonroot` | `sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3` |
| `python:3.14.8-slim-trixie` | `sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2` |
| `ghcr.io/astral-sh/uv:0.12.24` | `sha256:3af4716e991d6956a41e573eab705d0ee08500cd829ed30293eb8472f372c65a` |
| `traefik:v3.7.14` | `sha256:575fa15b135078fe5e50aa847987d96dbddd7b093c172429618404df73f3fa7c` |
| `postgres:18.6-trixie` | `sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336` |

## Hosts and providers

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `hetznercloud/hcloud` provider | 1.70.0 (2026-10-05) | GitHub releases, provider `CHANGELOG.md`, `docs/` | `datacenter` is removed from the API (2026-07-01). Use `location`. Datacenter endpoints return 410 since 2026-10-01 |
| `hcloud` CLI | 1.70.1 | GitHub releases, Homebrew | |
| Hetzner image names | `debian-13`, `ubuntu-24.04`, `ubuntu-26.04` | provider docs and test fixtures; changelog (ubuntu-26.04 added 2026-05-18) | `debian-13` not checked against the live API. Run `hcloud image list --type system` |
| Hetzner server types | `cx23` appears in provider docs | provider docs | Prices and availability moved twice in 2026 (April, June). Do not hard-code a type. Run `hcloud server-type list` |
| Hetzner Object Storage | endpoints `fsn1`, `nbg1`, `hel1` `.your-objectstorage.com` | docs.hetzner.com | Buckets and credentials: Console or S3 API only. No provider resource. Conditional-write support unverified |
| `ionos-cloud/ionoscloud` provider | 6.7.38 (2026-09-28); 6.7.39 unreleased | GitHub releases, provider `CHANGELOG.md`, `docs/` | `ionoscloud_pg_cluster_v2` password is write-only (needs OpenTofu or Terraform 1.11+) |
| IONOS DBaaS PostgreSQL | v2 API; versions 14 to 18 | docs.ionos.com | Private LAN only. 7-day default backup window, `retention_days` 1 to 365 in v2 |
| IONOS Object Storage | `eu-central-3` (Berlin), `eu-central-4` (Frankfurt), `us-central-1`; contract-owned buckets | docs.ionos.com | Versioning, lifecycle, object lock supported. Conditional writes unverified |
| IONOS Cloud Cubes | nine sizes, Basic XS = 1 vCPU, 2 GB, 60 GB NVMe | docs.ionos.com | Template is fixed at creation |
| Vercel CLI | 63.1.0 | npm | |
| `@vercel/config` | 0.12.0 | npm | `vercel.ts` helper package. Pre-1.0 |
| `botid` | no version read | Vercel docs | Install with the package manager. Unverified version |
| Supabase Pro | from $25 per month; PITR is a paid add-on | supabase.com/pricing | Re-read before quoting. Regions not read |

## CI actions (from the delivery-pipeline skill, verified 2026-10-09)

| Action | Line | Note |
|---|---|---|
| `actions/checkout` | v7.0.1 (3d3c42e5aac5ba805825da76410c181273ba90b1) | |
| `actions/setup-node` | v7.1.0 (949feb2413d6458794dcd2491c4babbbce0c15c1) | |
| `actions/cache` | v6.1.0 (55cc8345863c7cc4c66a329aec7e433d2d1c52a9) | not used directly |
| `actions/upload-artifact` | v7.0.2 (cf430e030ddbb5b0abf93d22962f4752f3646cd9) | SHA from `git ls-remote` |
| `actions/download-artifact` | v8.0.2 (9000827ccba6bdab643e8b6fd33ac0654aef8333) | SHA from `git ls-remote` |
| `actions/attest` | v4.2.2 (1e69f48acb82d1966a394da916b4c1698aa569d6) | needs `id-token`, `attestations`, `artifact-metadata` write |
| `actions/attest-build-provenance` | v4.2.2 (4d101475d8b20a2381f78447822ac1eab6504dd8) | wrapper; new code uses `actions/attest` |
| `docker/setup-buildx-action` | v4.4.1 (f87e5991a6d7451dcb8d9637bfbc97413f497069) | |
| `docker/login-action` | v4.6.0 (dbcb813823bdd20940b903addbd779551569679f) | |
| `docker/metadata-action` | v6.2.0 (dc802804100637a589fabce1cb79ff13a1411302) | |
| `docker/build-push-action` | v7.4.0 (c3c9e263c25d99ce0380d002d59b67737d91b0dc) | `secret-envs`, `provenance`, `sbom` inputs confirmed |
| `pnpm/action-setup` | v6.1.0 (ea17c68df8912ef543352723c149a84f56e3d413) | |
| `jdx/mise-action` | v5.1.1 (2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca) | |
| `zizmorcore/zizmor-action` | v0.6.4 (cc914d7f3750a2d13d75c7f184a1060aa0e9d482); zizmor 1.30.1 | |
| `aws-actions/configure-aws-credentials` | v6.3.0 (e1253824e5c10ff9df46874f81ed3ec929e19cfd) | |
| `azure/login` | v3.1.0 | SHA not resolved |
| `dependabot/fetch-metadata` | v3.1.0 | unused |
| Renovate | 44.148.4 | |
| sops / age | 3.13.3 / 1.3.2 | CLI is `sops encrypt/decrypt/edit/rotate/updatekeys` |
| gitleaks | 8.30.1 | `gitleaks-action` 3.0.0 needs a licence key for org accounts |
| OTel Collector contrib | 0.162.0 | image is `FROM scratch` (no shell) |
| grafana/otel-lgtm | 0.36.0 | upstream: dev, demo and test only |
| SigNoz | v0.145.0 | |
| GitHub plan limits | environment required reviewers and wait timers on private repos: Enterprise only; attestations on private repos: Enterprise Cloud | GitHub docs |

## Rule: re-verify, then record
**Why:** Every number above moved in the last year (Hetzner pricing twice in 2026, the Trivy action tags, Docker Compose to v5, the Hetzner datacenter API removal). A stale pin is a silent defect.
**How to apply:** Follow [version-protocol.md](../../core/_shared/version-protocol.md). Before scaffolding run `tofu version`, `docker --version`, `npm view vercel version`, and the registry lookup for the provider. If a row disagrees, the live value wins; update this file in the same change.

## When to deviate
- An existing repo pins an older supported line: keep it, record why in the stack profile notes, and plan the bump.
- Hosting in a region where a listed server type or location does not exist: use the live listing, not this table.
