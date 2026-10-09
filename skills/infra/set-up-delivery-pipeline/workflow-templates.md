# Workflow Templates

Reference for [set-up-delivery-pipeline](./SKILL.md). Copy-ready files. SHAs were resolved from the tags in the
comments on 2026-10-09. Dependabot keeps them current; re-resolve before you copy
(`gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha`; dereference annotated tags).

| Action | Tag | SHA |
|---|---|---|
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/setup-node` | v7.1.0 | `949feb2413d6458794dcd2491c4babbbce0c15c1` |
| `pnpm/action-setup` | v6.1.0 | `ea17c68df8912ef543352723c149a84f56e3d413` |
| `jdx/mise-action` | v5.1.1 | `2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca` |
| `docker/setup-buildx-action` | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| `docker/login-action` | v4.6.0 | `dbcb813823bdd20940b903addbd779551569679f` |
| `docker/metadata-action` | v6.2.0 | `dc802804100637a589fabce1cb79ff13a1411302` |
| `docker/build-push-action` | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
| `actions/attest` | v4.2.2 | `1e69f48acb82d1966a394da916b4c1698aa569d6` |
| `zizmorcore/zizmor-action` | v0.6.4 | `cc914d7f3750a2d13d75c7f184a1060aa0e9d482` |

## `.github/workflows/delivery.yml`

```yaml
name: delivery

on:
  pull_request:
  push:
    branches: [main]
    tags: ['v*']

permissions: {}

concurrency:
  group: delivery-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  checks:
    if: ${{ !startsWith(github.ref, 'refs/tags/') }}
    permissions:
      contents: read
    uses: ./.github/workflows/_checks.yml

  build:
    if: ${{ github.ref == 'refs/heads/main' }}
    needs: checks
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
    uses: ./.github/workflows/_build.yml

  dev:
    needs: build
    permissions:
      contents: read
      packages: read
      attestations: read
    uses: ./.github/workflows/_deploy.yml
    with:
      environment: dev
      image: ${{ needs.build.outputs.image }}

  # Tag push: no rebuild. Find the digest that main already built for this commit.
  resolve:
    if: ${{ startsWith(github.ref, 'refs/tags/v') }}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      packages: read
    outputs:
      image: ${{ steps.digest.outputs.image }}
    steps:
      - name: Tag must point at a commit on main
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          SHA: ${{ github.sha }}
        run: |
          status=$(gh api "repos/$REPO/compare/main...$SHA" --jq .status)
          case "$status" in
            identical|behind) ;;
            *) echo "::error::$SHA is not an ancestor of main (compare status: $status)"; exit 1 ;;
          esac
      - name: Look up the digest built for this commit
        id: digest
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          SHA: ${{ github.sha }}
        run: |
          echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
          name="ghcr.io/${REPO,,}"
          digest=$(docker buildx imagetools inspect "$name:sha-$SHA" --format '{{.Manifest.Digest}}')
          [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::no image for $SHA; did the main build finish?"; exit 1; }
          echo "image=$name@$digest" >> "$GITHUB_OUTPUT"

  stg:
    needs: resolve
    permissions:
      contents: read
      packages: read
      attestations: read
    uses: ./.github/workflows/_deploy.yml
    with:
      environment: stg
      image: ${{ needs.resolve.outputs.image }}

  prd:
    needs: [resolve, stg]
    permissions:
      contents: read
      packages: read
      attestations: read
    uses: ./.github/workflows/_deploy.yml   # pauses here: the prd environment has required reviewers
    with:
      environment: prd
      image: ${{ needs.resolve.outputs.image }}
```

## `.github/workflows/_checks.yml`

The repo's task runner owns what "checks" means. The workflow only calls one task named `ci`
(lint + typecheck + test), so local and CI runs are the same command.

```yaml
name: checks

on: workflow_call

permissions: {}

jobs:
  checks:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      # Track A: runtime_manager = mise. Installs every tool in mise.toml, caches them.
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5.1.1
      - run: mise run ci

      # Track B: package_manager = pnpm without mise. Delete track A, use these.
      # - uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413 # v6.1.0
      # - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
      #   with:
      #     node-version-file: .nvmrc
      #     cache: pnpm
      # - run: pnpm install --frozen-lockfile
      # - run: pnpm run ci

  workflow-lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: zizmorcore/zizmor-action@cc914d7f3750a2d13d75c7f184a1060aa0e9d482 # v0.6.4
        with:
          advanced-security: false
```

## `.github/workflows/_build.yml`

```yaml
name: build

on:
  workflow_call:
    outputs:
      image:
        description: Immutable image reference, name@sha256:digest
        value: ${{ jobs.build.outputs.image }}

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      artifact-metadata: write
    outputs:
      image: ${{ steps.ref.outputs.image }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}

      - id: meta
        uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302 # v6.2.0
        with:
          images: ghcr.io/${{ github.repository }}
          tags: type=sha,format=long          # sha-<40 hex>; the only tag. Deploys use the digest.

      - id: push
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: false                    # the signed attestation below replaces buildx's unsigned one
          sbom: false

      - id: ref
        env:
          REPO: ${{ github.repository }}
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          name="ghcr.io/${REPO,,}"             # GHCR rejects upper-case names
          echo "name=$name" >> "$GITHUB_OUTPUT"
          echo "image=$name@$DIGEST" >> "$GITHUB_OUTPUT"

      - uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
        with:
          subject-name: ${{ steps.ref.outputs.name }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
```

## `.github/workflows/_deploy.yml`

```yaml
name: deploy

on:
  workflow_call:
    inputs:
      environment:
        type: string
        required: true
      image:
        type: string
        required: true

permissions: {}

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    environment:
      name: ${{ inputs.environment }}
      url: ${{ vars.APP_URL }}
    concurrency:
      group: deploy-${{ inputs.environment }}
      cancel-in-progress: false               # never kill a deploy half way
    permissions:
      contents: read
      packages: read
      attestations: read
      # id-token: write                       # add only when the host trusts GitHub OIDC (AWS, Azure, GCP)
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Verify provenance
        env:
          GH_TOKEN: ${{ github.token }}
          IMAGE: ${{ inputs.image }}
        run: |
          echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
          gh attestation verify "oci://$IMAGE" \
            --owner "$GITHUB_REPOSITORY_OWNER" \
            --signer-workflow "$GITHUB_REPOSITORY/.github/workflows/_build.yml"

      - name: Deploy
        env:
          ENVIRONMENT: ${{ inputs.environment }}
          IMAGE: ${{ inputs.image }}
          REGISTRY_TOKEN: ${{ github.token }}              # short-lived; the host logs in with it, then discards it
          DEPLOY_HOST: ${{ vars.DEPLOY_HOST }}
          DEPLOY_HOST_KEY: ${{ vars.DEPLOY_HOST_KEY }}   # pinned host key; deploy.sh refuses without it
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}    # environment secret; remove for hosts that use OIDC
        run: ./deploy/deploy.sh "$ENVIRONMENT" "$IMAGE"

      - name: Smoke test
        env:
          HEALTH_URL: ${{ vars.HEALTH_URL }}
        run: curl --fail --silent --show-error --retry 10 --retry-delay 6 --retry-all-errors "$HEALTH_URL"
```

`deploy/deploy.sh` contract (the host skill writes the body): take `<environment> <image@sha256:…>`; log in to GHCR
with `REGISTRY_TOKEN` into a temporary Docker config directory; set the image reference by digest; start the new version;
wait until it is healthy; remove the temporary credentials; exit non-zero on any failure. Running it twice with the same
arguments changes nothing.

## `.github/workflows/rollback.yml`

Run it from the tag of the version you want back ("Use workflow from: Tag"). That checks out the deploy files of that
release, and satisfies the tag rule on `stg` and `prd`.

```yaml
name: rollback

on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, stg, prd]
        required: true
      image:
        description: ghcr.io/<org>/<repo>@sha256:<digest> from an earlier run
        type: string
        required: true

permissions: {}

jobs:
  deploy:
    permissions:
      contents: read
      packages: read
      attestations: read
    uses: ./.github/workflows/_deploy.yml
    with:
      environment: ${{ inputs.environment }}
      image: ${{ inputs.image }}
```

## `.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7           # a new release has to survive a week before it is proposed
    groups:
      actions:
        patterns: ['*']
  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
```

Dependabot rewrites the SHA and the `# vX.Y.Z` comment together. Renovate does the same with
`helpers:pinGitHubActionDigests`; use it if the repo already runs Renovate.

## Vercel track

Vercel's Git integration builds every push. To get an approval gate, turn off automatic domain assignment so a build
of `main` is a **staged** production deployment, then promote it from Actions after approval.

One time, per project: Vercel dashboard → Project → Settings → Environments → Production → Branch Tracking →
turn **Auto-assign Custom Production Domains** off. Add `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` as
secrets on the GitHub `prd` environment only.

Mapping: PR preview deployment = `dev`; staged production deployment of `main` = `stg`; promote = `prd`.
`delivery.yml` keeps only the `checks` job. Make `checks` a required status check on `main`.

```yaml
# .github/workflows/promote-vercel.yml
name: promote-vercel

on:
  workflow_dispatch:
    inputs:
      deployment:
        description: URL or id of the staged production deployment (Vercel commit status on main)
        type: string
        required: true

permissions: {}

jobs:
  promote:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    environment: prd                  # required reviewers pause the job here
    concurrency:
      group: deploy-prd
      cancel-in-progress: false
    permissions:
      contents: read
    steps:
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
        with:
          node-version: 24
      - name: Promote
        env:
          DEPLOYMENT: ${{ inputs.deployment }}
          VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
          VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
          VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}
        run: npx --yes vercel@63.1.0 promote "$DEPLOYMENT" --yes --token "$VERCEL_TOKEN"
```

Promotion of a staged production build does not rebuild, so what was tested in `stg` is what goes live. Promoting a
**preview** build to production does rebuild with production env vars; do not use that path for releases.

Fallback when the repo must build in Actions (GitHub Enterprise Server, or source must not leave GitHub):
`vercel pull --yes --environment=production`, `vercel build --prod`, `vercel deploy --prebuilt --prod`, each with
`--token "$VERCEL_TOKEN"`. Build once per environment: Vercel embeds environment variables at build time.
