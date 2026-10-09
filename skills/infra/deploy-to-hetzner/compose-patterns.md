# Compose Patterns

Reference for `deploy-to-hetzner`. The stack, Traefik and backup files below were built and run during research (first deploy, same-digest re-run, a bad release, a backup and a restore drill); they are embedded verbatim.

## Rule: one compose file for every environment

**Why:** A `compose.prd.yaml` that adds a service `dev` does not have means `prd` is untested ([environments.md](../_shared/environments.md)). Configuration is data, not a second file.
**How to apply:** `deploy/stack/compose.yaml` is the only compose file. Per-environment, non-secret values live in `deploy/envs/<env>/config.env`. Secrets arrive separately (below). The deploy script writes a `release.env` holding exactly one line, `APP_IMAGE=<repo>@sha256:<digest>`; the image is never a tag.

## Rule: Traefik uses the file provider, not the docker provider

**Why:** The docker provider needs the Docker socket mounted into the edge container, which makes Traefik a root-equivalent process that can start any container on the host. A file provider removes the socket entirely.
**How to apply:** `providers.file` with `watch: true`; the router/service/middleware are declared in `dynamic.yaml`. Compose mounts only the two config files and the `letsencrypt` volume.

## Rule: TLS terminates at the edge, with ACME HTTP-01

**Why:** HTTP-01 needs only port 80, which the firewall already opens for the redirect; no DNS-provider credentials are required.
**How to apply:** `certificatesResolvers.le.acme.httpChallenge` with storage on the `letsencrypt` volume (`/letsencrypt/acme.json`). Use the staging CA `https://acme-staging-v02.api.letsencrypt.org/directory` for `dev` only — mark it untested here (never run against a live domain). On public entrypoints: `aliasHeadersStrategy: delete`, every `allowEncoded*` set to `false` (verified: a `%2F` path returned 400), TLS 1.2 minimum (`VersionTLS12`), HSTS with subdomains, `frameDeny`, `contentTypeNosniff`, `referrerPolicy`. The `ping` entrypoint (healthcheck) listens on `:8082` and is **not** published to the host.

## Rule: two networks; Postgres stays internal

**Why:** A published port or an attached edge network would make the database reachable from the public internet.
**How to apply:** `networks.edge` and `networks.backend` with `backend.internal: true`. `app` is on both; `postgres` is on `backend` only, so Traefik (edge) cannot route to it and it has no host mapping.

## Rule: every service is hardened

**Why:** A read-only root filesystem, dropped capabilities and no new privileges shrink what a compromised container can do ([security-baseline.md](../../core/_shared/security-baseline.md)).
**How to apply:** `read_only: true`, `cap_drop: [ALL]` (Traefik adds only `NET_BIND_SERVICE`), `security_opt: ["no-new-privileges:true"]` on every service. The image runs as a non-root user ([containerize-service](../containerize-service/SKILL.md)).

## Rule: Postgres 18 mounts at `/var/lib/postgresql`

**Why:** The PG 18 image changed its data directory; mounting at the old `/var/lib/postgresql/data` loses your data to a fresh initdb.
**How to apply:** `- ${DATA_DIR:-./data}/postgres:/var/lib/postgresql` — the whole directory, not a `data` subdirectory. `POSTGRES_PASSWORD_FILE` points at the mounted secret; `shm_size: 256mb` for parallel queries.

## Rule: secrets are mounted files, never in the repo or the bundle

**Why:** A `secrets:` entry backed by a committed file would put the password in git; an `environment:` value lands in `docker inspect`.
**How to apply:** Compose declares `secrets: [postgres_password]` with `file: ./secrets/postgres_password`, and Postgres reads `POSTGRES_PASSWORD_FILE`. The pre-up hook (`HOOK_PRE_UP` in `deploy.conf`, optional, called by `run.sh` before `compose up`) creates that file from the sops-encrypted store ([manage-secrets](../manage-secrets/SKILL.md)). The file stays on disk, not on tmpfs, because Compose bind-mounts it and the container must restart after a reboot. It is on the host only, mode 0400, and never packed by `deploy.sh`. The hook is in [manage-secrets](../manage-secrets/SKILL.md); it writes this file from the `POSTGRES_PASSWORD` key and fails the deploy when the key is missing.

## Rule: backups are restic over `pg_dump`, streamed, with a retention policy

**Why:** A logical dump is portable across Postgres majors; streaming it into restic means no plaintext dump file ever sits on disk.
**How to apply:** `backup.sh` runs nightly: `pg_dump --format custom` piped into `restic backup --stdin`, `forget --keep-daily 7 --keep-weekly 5 --keep-monthly 6 --prune`, then `restic check --read-data-subset=5%`. The restic repository is S3-compatible object storage ([hetzner-patterns.md](./hetzner-patterns.md)). Credentials live in `/etc/deploy/backup.env`, root-only `0600`, holding `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (names only here, never values).

The scripts live in `deploy/stack/bin/`, so the deploy bundle ships them to `/opt/app/bin/` with the compose files. The bundle is unpacked with `--no-same-permissions`, so run them with `bash`, not as executables. Cloud-init installs the two systemd units (`app-backup.service`, `app-backup.timer`: `OnCalendar=daily`, `Persistent=true`, 15 minutes of random delay) and enables the timer; they are in the cloud-init file in [hetzner-patterns.md](./hetzner-patterns.md). The units and the timer were parsed as YAML but never ran on a live host. `/etc/deploy/backup.env` is not created by cloud-init: place it through [manage-secrets](../manage-secrets/SKILL.md) before the first night.

## Rule: an untested backup is not a backup

**Why:** A backup that cannot be restored is a story, not a restore path. The only proof is a restore into a fresh database.
**How to apply:** `restore-drill.sh` restores the latest snapshot into a throw-away Postgres and runs a sanity query, never touching the live database. Run it monthly (calendar reminder or your own timer): `PG_IMAGE=$(grep -o 'postgres:[^ ]*' /opt/app/compose.yaml | head -1) CHECK_SQL="select count(*) from information_schema.tables where table_schema = 'public'" bash /opt/app/bin/restore-drill.sh`. Verified result during research: 1000 rows restored and `restore drill ok`. RPO is 24 h with nightly dumps. If that is not enough, step up to pgBackRest 2.59.3 with WAL archiving for point-in-time recovery — **unverified here**; treat it as a separate piece of work, not a config tweak.

## Rule: the hostname comes from the environment, through Traefik's file templating

**Why:** The stack is one set of files for every environment, and the hostname differs per environment. Hard-coding it forces a second copy of the Traefik file.
**How to apply:** `deploy/envs/<env>/config.env` sets `APP_HOST=stg.shop.example.com` (plus `COMPOSE_PROJECT_NAME` and `DATA_DIR=/srv/data`). The Traefik service passes `APP_HOST` into its environment and `dynamic.yaml` reads it with ``Host(`{{ env "APP_HOST" }}`)``. Verified: with `APP_HOST=stg.shop.test` a request for that host returned 200 and a request for another host returned 404. The ACME email sits in the static `traefik.yaml` (one ops address for all environments), because Traefik reads static configuration from one source only, file or environment, never both.
**Anti-example:** `compose.prd.yaml` and `dynamic.prd.yaml` copies that drift from the dev ones.

## The files, verbatim

`deploy/stack/compose.yaml`:

```yaml
name: ${COMPOSE_PROJECT_NAME:-app}

services:
  traefik:
    image: traefik:v3.7.14@sha256:575fa15b135078fe5e50aa847987d96dbddd7b093c172429618404df73f3fa7c
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik/traefik.yaml:/etc/traefik/traefik.yaml:ro
      - ./traefik/dynamic.yaml:/etc/traefik/dynamic.yaml:ro
      - letsencrypt:/letsencrypt
    environment:
      APP_HOST: ${APP_HOST:?APP_HOST must be set in config.env}
    networks: [edge]
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping", "--ping.entrypoint=ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  app:
    image: ${APP_IMAGE:?APP_IMAGE must be image@sha256:digest}
    restart: unless-stopped
    env_file:
      - path: ./config.env
      - path: /run/app/secrets.env
        required: false   # environments without secrets
    networks: [edge, backend]
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:18.6-trixie@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336
    restart: unless-stopped
    environment:
      POSTGRES_USER: app
      POSTGRES_DB: app
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets: [postgres_password]
    volumes:
      - ${DATA_DIR:-./data}/postgres:/var/lib/postgresql
    networks: [backend]
    shm_size: 256mb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 10s
      timeout: 3s
      retries: 6

networks:
  edge:
  backend:
    internal: true

volumes:
  letsencrypt:

secrets:
  postgres_password:
    file: ./secrets/postgres_password
```

`deploy/stack/traefik/traefik.yaml`:

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false
log:
  format: json
  level: INFO
accessLog:
  format: json
ping:
  entryPoint: ping
entryPoints:
  ping:
    address: ":8082"
    http:
      aliasHeadersStrategy: delete
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
  web:
    address: ":80"
    http:
      aliasHeadersStrategy: delete
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      aliasHeadersStrategy: delete
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
      tls:
        certResolver: le
certificatesResolvers:
  le:
    acme:
      email: ops@example.com
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
providers:
  file:
    filename: /etc/traefik/dynamic.yaml
    watch: true
```

`deploy/stack/traefik/dynamic.yaml`:

```yaml
http:
  routers:
    app:
      rule: Host(`{{ env "APP_HOST" }}`)
      entryPoints: [websecure]
      service: app
      middlewares: [secure-headers]
  middlewares:
    secure-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        contentTypeNosniff: true
        frameDeny: true
        referrerPolicy: strict-origin-when-cross-origin
  services:
    app:
      loadBalancer:
        servers:
          - url: http://app:8080
        healthCheck:
          path: /healthz
          interval: 10s
tls:
  options:
    default:
      minVersion: VersionTLS12
```

`deploy/stack/bin/backup.sh`:

```bash
#!/usr/bin/env bash
# /opt/app/bin/backup.sh — nightly logical backup of the app database into the restic repository on object storage.
# Env file /etc/deploy/backup.env (root:root 0600): RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
set -Eeuo pipefail
COMPOSE_DIR="${COMPOSE_DIR:-/opt/app}"
ENV_FILE="${BACKUP_ENV:-/etc/deploy/backup.env}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.19.1}"
restic() { docker run --rm -i --env-file "$ENV_FILE" "$RESTIC_IMAGE" "$@"; }
pg() { docker compose --project-directory "$COMPOSE_DIR" --env-file "$COMPOSE_DIR/config.env" --env-file "$COMPOSE_DIR/release.env" exec -T postgres "$@"; }

restic snapshots >/dev/null 2>&1 || restic init
pg pg_dump --username app --dbname app --format custom --no-owner | restic backup --stdin --stdin-filename app.dump --tag nightly
restic forget --tag nightly --keep-daily 7 --keep-weekly 5 --keep-monthly 6 --prune
restic check --read-data-subset=5%
```

`deploy/stack/bin/restore-drill.sh`:

```bash
#!/usr/bin/env bash
# /opt/app/bin/restore-drill.sh — restore the latest snapshot into a throw-away Postgres and run a sanity query.
# Exit non-zero if the restore or the check fails. Never touches the live database.
set -Eeuo pipefail
ENV_FILE="${BACKUP_ENV:-/etc/deploy/backup.env}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.19.1}"
PG_IMAGE="${PG_IMAGE:?set to the same postgres@sha256 reference as compose.yaml}"
CHECK_SQL="${CHECK_SQL:-select count(*) from information_schema.tables where table_schema = 'public'}"
name="drill-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$name" -e POSTGRES_PASSWORD=drill "$PG_IMAGE" >/dev/null
for i in $(seq 1 60); do
  docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "restore drill: Postgres did not become ready in 60s" >&2; exit 1; }
  sleep 1
done
docker run --rm -i --env-file "$ENV_FILE" "$RESTIC_IMAGE" dump latest app.dump \
  | docker exec -i "$name" pg_restore --username postgres --dbname postgres --no-owner --exit-on-error
docker exec "$name" psql -U postgres -tA -c "$CHECK_SQL"
echo "restore drill ok"
```

## When to deviate

- **No database in Compose** (managed Postgres elsewhere): drop the `postgres` service, the `backend` network can go, and the backup scripts apply to nothing — replace them with the managed provider's backups.
- **A second app container:** extend `compose.yaml`; keep `app` as the service whose health gates the release, or generalise the health check ([deploy-script.md](../_shared/deploy-script.md)).
- **Point-in-time recovery needed:** adopt pgBackRest 2.59.3 with WAL archiving; the nightly `pg_dump` remains as a secondary, portable copy.
- **TLS from a load balancer instead of Traefik:** remove the ACME resolver and `web`/`websecure` entrypoints; keep the security headers and the internal network rule.
