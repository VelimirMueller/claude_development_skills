# Deploy Script Contract (container hosts)

The seam between the pipeline and a VM host (Hetzner, IONOS). The pipeline's `_deploy.yml` calls one command in the repository:

```bash
deploy/deploy.sh <environment> <image@sha256:digest>
```

Contract (from [set-up-delivery-pipeline](../set-up-delivery-pipeline/workflow-templates.md)): idempotent, pulls by digest, `compose up -d`, waits for health, exits non-zero on failure, prints the deployed digest. The two scripts below honour it. Both were run against a local registry with the real Compose file: first deploy, same-digest re-run (no change), a bad release (non-zero exit, automatic restoration of the previous release), and wrong environment or wrong repository (refused).

**No OIDC federation exists for Hetzner or IONOS** (none found 2026-10-09). The credential is therefore a **scoped deploy SSH key** stored as a secret of the GitHub *environment* (one key per environment, never a repository secret). The key cannot open a shell: on the host it is bound to a forced command, `restrict,command="/opt/deploy/run.sh"`. Infrastructure API tokens (`HCLOUD_TOKEN`, `IONOS_TOKEN`) are also environment secrets; see [set-up-opentofu](../set-up-opentofu/SKILL.md).

## Inputs the workflow must provide

| Name | Kind | Source |
|---|---|---|
| `DEPLOY_HOST` | variable | tofu output `ipv4` |
| `DEPLOY_SSH_KEY` | secret (environment) | private half of the deploy key |
| `DEPLOY_HOST_KEY` | variable | public host key line, e.g. `ssh-ed25519 AAAA…`. Read it once from the console or the first admin login and store it. The script refuses to run without it: no trust on first use |
| `REGISTRY_TOKEN` | short-lived | `github.token` of the job |
| `DEPLOY_USER`, `DEPLOY_PORT`, `REGISTRY_USER` | optional | defaults `deploy`, `22`, `$GITHUB_ACTOR` |

The pipeline template passes all four.

## Repository layout the scripts expect

```
deploy/
  deploy.sh                 # runner side (below)
  host/run.sh               # host side (below); tofu passes it into cloud-init
  stack/compose.yaml        # one file for every environment
  stack/traefik/traefik.yaml
  stack/traefik/dynamic.yaml
  stack/bin/backup.sh       # shipped to /opt/app/bin by the bundle; run with bash (see compose-patterns.md)
  stack/bin/restore-drill.sh
  envs/dev/config.env       # non-secret values per environment
  envs/stg/config.env
  envs/prd/config.env
  envs/<env>/secrets.sops.env  # sops-encrypted; decrypted on the host by the pre-up hook
```

`deploy.sh` packs `stack/` and `envs/<env>/` of the **checked-out release** and sends them with the image reference. Compose changes therefore ship through the same reviewed pipeline as the image, and nobody edits files on the host.

## `deploy/deploy.sh` (runs on the CI runner)

```bash
#!/usr/bin/env bash
# deploy/deploy.sh <environment> <image@sha256:digest>
# Called by the pipeline's _deploy.yml. Opens one SSH session to the host and runs the host's forced command.
# Env (all from the GitHub environment): DEPLOY_HOST, DEPLOY_SSH_KEY (secret), DEPLOY_HOST_KEY (public host key line),
#   REGISTRY_TOKEN (short-lived). Optional: DEPLOY_USER=deploy, DEPLOY_PORT=22, REGISTRY_USER=$GITHUB_ACTOR.
set -Eeuo pipefail
umask 077

[[ $# -eq 2 ]] || { echo "usage: deploy.sh <environment> <image@sha256:digest>" >&2; exit 2; }
environment="$1" image="$2"
[[ "$environment" =~ ^(dev|stg|prd)$ ]] || { echo "deploy: bad environment: $environment" >&2; exit 2; }
[[ "$image" =~ ^[a-z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]] || { echo "deploy: image must be name@sha256:<64 hex>" >&2; exit 2; }
: "${DEPLOY_HOST:?}" "${DEPLOY_SSH_KEY:?}" "${DEPLOY_HOST_KEY:?pin the host key; no trust on first use}" "${REGISTRY_TOKEN:?}"
user="${DEPLOY_USER:-deploy}" port="${DEPLOY_PORT:-22}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$DEPLOY_SSH_KEY" >"$work/key"
if [[ "$port" == 22 ]]; then known="$DEPLOY_HOST"; else known="[$DEPLOY_HOST]:$port"; fi
printf '%s %s\n' "$known" "$DEPLOY_HOST_KEY" >"$work/known_hosts"

# The release's own stack files travel with the image, so compose changes ship through the same reviewed pipeline.
[[ -f deploy/stack/compose.yaml && -f "deploy/envs/$environment/config.env" ]] || { echo "deploy: missing deploy/stack/compose.yaml or deploy/envs/$environment/config.env" >&2; exit 2; }
bundle="$(tar -C deploy -czf - stack "envs/$environment" | base64 | tr -d '\n')"

{ printf '%s\n%s\n' "${REGISTRY_USER:-${GITHUB_ACTOR:-deploy}}" "$REGISTRY_TOKEN"; printf '%s\n' "$bundle"; } |
  ssh -i "$work/key" -p "$port" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$work/known_hosts" -o ConnectTimeout=15 -o ServerAliveInterval=15 \
    "$user@$DEPLOY_HOST" "$environment $image"
```

## `deploy/host/run.sh` (runs on the host as the forced command)

```bash
#!/usr/bin/env bash
# /opt/deploy/run.sh — host side of deploy/deploy.sh. Runs as user "deploy" through the
# forced command in authorized_keys:  restrict,command="/opt/deploy/run.sh" ssh-ed25519 AAAA...
# Input: SSH_ORIGINAL_COMMAND = "<environment> <image@sha256:digest>"; stdin = three lines:
#   registry user, registry token, base64 of a tar.gz holding stack/ (compose files) and envs/<environment>/config.env.
set -Eeuo pipefail
umask 077

CONF="${DEPLOY_CONF:-/etc/deploy/deploy.conf}"
# shellcheck source=/dev/null
source "$CONF"   # sets: ENVIRONMENT IMAGE_REPO COMPOSE_DIR REGISTRY HEALTH_TIMEOUT [HOOK_PRE_UP]

die() { echo "deploy: $*" >&2; exit 1; }

read -r want_env image extra <<<"${SSH_ORIGINAL_COMMAND:-}"
[[ -z "${extra:-}" && -n "${image:-}" ]] || die "usage: <environment> <image@sha256:digest>"
[[ "$want_env" == "$ENVIRONMENT" ]] || die "this host serves $ENVIRONMENT, not $want_env"
[[ "$image" =~ ^${IMAGE_REPO//./\\.}@sha256:[a-f0-9]{64}$ ]] || die "image must be ${IMAGE_REPO}@sha256:<64 hex>"

read -r reg_user
read -r reg_token
read -r bundle
[[ -n "$reg_user" && -n "$reg_token" && -n "$bundle" ]] || die "stdin must carry registry user, token and bundle"

exec 9>"$COMPOSE_DIR/.deploy.lock"
flock -n 9 || die "another deploy is running"

export DOCKER_CONFIG; DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

compose() {
  docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/compose.yaml" \
    --env-file "$COMPOSE_DIR/config.env" --env-file "$COMPOSE_DIR/release.env" "$@"
}
write_release() { printf 'APP_IMAGE=%s\n' "$1" >"$COMPOSE_DIR/release.env.tmp" && mv "$COMPOSE_DIR/release.env.tmp" "$COMPOSE_DIR/release.env"; }

# Unpack the stack from the release into a staging dir. Only plain files and directories are accepted.
stage="$(mktemp -d)"
trap 'rm -rf "$DOCKER_CONFIG" "$stage"' EXIT
printf '%s' "$bundle" | base64 -d >"$stage/bundle.tgz"
if tar -tvzf "$stage/bundle.tgz" | grep -qv '^[-d]'; then die "bundle holds links or special files"; fi
mkdir "$stage/x" && tar -xzf "$stage/bundle.tgz" -C "$stage/x" --no-same-owner --no-same-permissions
[[ -f "$stage/x/stack/compose.yaml" && -f "$stage/x/envs/$ENVIRONMENT/config.env" ]] || die "bundle lacks stack/compose.yaml or envs/$ENVIRONMENT/config.env"
cp -R "$stage/x/stack/." "$COMPOSE_DIR/"
cp "$stage/x/envs/$ENVIRONMENT/config.env" "$COMPOSE_DIR/config.env"
[[ -f "$stage/x/envs/$ENVIRONMENT/secrets.sops.env" ]] && cp "$stage/x/envs/$ENVIRONMENT/secrets.sops.env" "$COMPOSE_DIR/secrets.sops.env"
[[ -x "${HOOK_PRE_UP:-/nonexistent}" ]] && "$HOOK_PRE_UP" "$COMPOSE_DIR"   # optional: decrypt sops secrets to tmpfs (manage-secrets)

touch "$COMPOSE_DIR/release.env"
previous="$(sed -n 's/^APP_IMAGE=//p' "$COMPOSE_DIR/release.env")"

printf '%s' "$reg_token" | docker login "$REGISTRY" -u "$reg_user" --password-stdin >/dev/null
APP_IMAGE="$image" compose pull --quiet   # the only step that needs the registry token
rm -rf "$DOCKER_CONFIG"; DOCKER_CONFIG="$(mktemp -d)"   # token is gone before anything starts
write_release "$image"

cid_health() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(compose ps -q app)" 2>/dev/null || echo none; }
start() {   # --wait only means something when the service defines a healthcheck, so require "healthy" explicitly
  compose up -d --no-build --pull never --remove-orphans --wait --wait-timeout "${HEALTH_TIMEOUT:-120}" && [[ "$(cid_health)" == healthy ]]
}

if ! start; then
  echo "deploy: new version is not healthy (status: $(cid_health))" >&2
  compose logs --no-color --tail 40 app >&2 || true
  if [[ -n "$previous" && "$previous" != "$image" ]]; then
    echo "deploy: rolling back to $previous" >&2
    write_release "$previous"
    start >&2 || true
  fi
  exit 1
fi

running="$(docker inspect --format '{{.Config.Image}}' "$(compose ps -q app)")"
[[ "$running" == "$image" ]] || die "running image $running does not match $image"
docker image prune -f >/dev/null
echo "deployed $ENVIRONMENT $running"
```

Host config `/etc/deploy/deploy.conf` (written by cloud-init; the host decides what it accepts, not the caller):

```bash
ENVIRONMENT=prd
IMAGE_REPO=ghcr.io/acme/shop
COMPOSE_DIR=/opt/app
REGISTRY=ghcr.io
HEALTH_TIMEOUT=120
HOOK_PRE_UP=/opt/deploy/hooks/pre-up.sh   # optional; see manage-secrets
```

## Rule: the host decides what it will run
**Why:** An SSH key in CI is a root-equivalent credential on a host whose user is in the `docker` group. If the script trusts its caller, a leaked key runs any image.
**How to apply:** The forced command takes no shell. `run.sh` accepts only `<its own environment> <its own image repository>@sha256:<64 hex>`, a bundle of plain files, and a token it uses once. Nothing the caller sends reaches a shell unquoted.
**Anti-example:** `ssh deploy@host "cd /opt/app && docker compose pull && docker compose up -d"` with a login shell.

## Rule: "healthy" means the image says so
**Why:** `compose up --wait` succeeds for a container that is merely running, even one that exits and restarts in a loop. A test with an image that had no healthcheck returned success.
**How to apply:** Every image defines a `HEALTHCHECK` (see [containerize-service](../containerize-service/SKILL.md)). `run.sh` additionally requires the `healthy` status and fails otherwise, then restores the previous release file and starts it.

## Rule: the registry token lives for one `pull`
**Why:** A PAT left on a host is a standing credential for the whole registry.
**How to apply:** The token arrives on stdin, logs in to a temporary Docker config directory, is used by `compose pull`, and the directory is deleted before `compose up`. `up` runs with `--pull never`.

## Verify
```bash
shellcheck deploy/deploy.sh deploy/host/run.sh      # no output
DIGEST=$(docker buildx imagetools inspect ghcr.io/acme/shop:sha-abc123 --format '{{.Manifest.Digest}}')
DEPLOY_HOST=… DEPLOY_SSH_KEY="$(cat key)" DEPLOY_HOST_KEY="ssh-ed25519 AAAA…" REGISTRY_TOKEN="$(gh auth token)" \
  deploy/deploy.sh dev ghcr.io/acme/shop@$DIGEST       # prints: deployed dev ghcr.io/acme/shop@sha256:…
# run it again: same output, no container restarts (docker ps shows the same "Up" ages)
deploy/deploy.sh prd ghcr.io/acme/shop@$DIGEST          # against the dev host: "this host serves dev, not prd", exit 1
```

## When to deviate
- **Pull-based hosts** (an agent on the host pulls new digests): drop SSH from CI; the contract stays the same for the pipeline, which then only publishes the digest.
- **A self-hosted runner inside the network or a VPN**: restrict port 22 to that range; the forced command stays.
- **Kubernetes**: replace both scripts with `kubectl set image` or a GitOps commit of the digest.
- **Several app containers per host**: extend `compose.yaml`; keep `app` as the service whose health gates the release, or generalise the `cid_health` check to every service with a healthcheck.

## Unverified
- Not run against a real Hetzner or IONOS host: the SSH hop (replaced by a shim that runs `run.sh` with the same stdin and `SSH_ORIGINAL_COMMAND`), and `flock` (the macOS test host has none; Linux hosts do).
- The host-side `restrict` option disables TTY and forwarding; stdin piping through `ssh` is standard and assumed.
