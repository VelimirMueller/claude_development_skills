---
name: manage-secrets
description: Use when a repo handles credentials — decide where each secret lives per host (Vercel, GitHub environments, sops+age for Compose, Supabase), keep them out of images, logs, bundles and state, set up .env.example, rotation and secret scanning.
---

# Manage Secrets

One rule: a secret has exactly one home per environment, and that home is not the repo, the image, or a log.
Everything else in this skill follows from it.

## 1. Audit current state

```bash
cat .claude/stack-profile.md 2>/dev/null || cat ~/.claude/stack-profile.md 2>/dev/null   # hosting, database.host, iac, ci
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -v '\.example$'                          # tracked env files: must be empty or *.sops.*
grep -nE '^\.env|\.tfstate|\.tfvars' .gitignore                                          # ignored?
ls .env.example .sops.yaml deploy/envs/*/secrets.sops.env 2>/dev/null
grep -rnE '^\s*(ARG|ENV)\s+\w*(KEY|TOKEN|SECRET|PASSWORD|PASS)\w*' Dockerfile* 2>/dev/null   # secrets baked into layers
grep -rnE '(VITE|NEXT_PUBLIC|NUXT_PUBLIC|PUBLIC)_\w*(SECRET|TOKEN|PASSWORD|SERVICE_ROLE|PRIVATE)' --include='*.ts' --include='*.vue' --include='*.tsx' --include='.env*' . 2>/dev/null | head
git ls-files | grep -E '\.(tfstate|pem|key|p12)$'                                         # state and key material in git
gh secret list 2>/dev/null; gh secret list --env prd 2>/dev/null
gh api repos/{owner}/{repo} --jq '.security_and_analysis | {secret_scanning, secret_scanning_push_protection}' 2>/dev/null
command -v sops age gitleaks
```

Also scan history once: `gitleaks git --redact --no-banner` (reports file, rule and line, never the value). A hit means
the secret is burned: rotate it first, then remove it from the repo.

## 2. Decide what to do

- No finding in step 1 and the home table (step 3) is satisfied → "already in place", report the one-line status.
- Findings → fix in this order: **rotate** leaked secrets, **move** secrets to their home, **block** recurrence (scanning).
- Never print or paste secret values into the chat, logs, or the report. Use names and the first 4 characters at most.

## 3. Detect the track: where each secret lives

| Where it runs | Runtime secrets live in | Deploy credentials live in | Never |
|---|---|---|---|
| Vercel (`hosting: vercel`) | Vercel env vars, type **Secret**, per environment | GitHub `prd` environment secrets (`VERCEL_TOKEN`, …) only if Actions promotes | `NEXT_PUBLIC_*` / `VITE_*` for anything private |
| Hetzner / IONOS with Compose | **sops+age** file in the repo, decrypted on the host into tmpfs | GitHub environment secret (SSH key) | `.env` committed; secrets as image `ENV` |
| Supabase | Edge Function secrets (`supabase secrets set`), DB creds in Supabase | GitHub environment secrets (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`) | `sb_secret_*` / `service_role` in a client |
| GitHub Actions | GitHub **environment** secrets, one set per env | OIDC where the target supports it ([pipeline-patterns](../set-up-delivery-pipeline/pipeline-patterns.md#rule-oidc-where-the-target-supports-it-a-scoped-short-lived-secret-where-it-does-not)) | Repository-level secrets for prd credentials |
| Local dev | `.env` (gitignored), copied from `.env.example` | n/a | Production values on a laptop |
| IaC ([set-up-opentofu](../set-up-opentofu/SKILL.md)) | Provider tokens in the CI environment; state in an encrypted remote backend | Environment secrets | Secrets in `*.tfvars` or in committed state |

Why each home is chosen: [secrets-patterns.md](./secrets-patterns.md). Host mechanics:
[deploy-to-hetzner](../deploy-to-hetzner/SKILL.md), [deploy-to-ionos](../deploy-to-ionos/SKILL.md),
[deploy-to-vercel](../deploy-to-vercel/SKILL.md).

## 4. Install only what is missing

```bash
mise use sops@3.13.3 age@1.3.2 gitleaks@8.30.1     # versions verified 2026-10-09; see ../_shared/stack-versions.md
```

Without mise: `brew install sops age gitleaks`. On a host that only decrypts: `sops` and `age` from the release page,
checksum verified.

## 5. Generate the seams

**`.env.example`** (committed, every variable the app reads, no real values, one comment per non-obvious var):

```dotenv
# Public: shipped to the browser. Never put a secret here.
VITE_API_URL=http://localhost:8787
# Private: server only.
DATABASE_URL=postgres://app:app@localhost:5432/app
SESSION_SECRET=            # openssl rand -base64 32
```

**`.gitignore`** gets `.env`, `.env.*`, `!.env.example`, `!*.sops.env`, `*.tfstate*`, `*.tfvars`, `*.pem`, `*.key`.

**The env schema module** (one file validates all env at startup and exports a typed object; nothing else reads the
environment): see [validate-env](../../frontend/validate-env/SKILL.md) for the pattern. Same rule on the server: parse once, fail fast.

**sops + age for self-hosted Compose.** One age key per host, plus one per human who must edit that environment:

```bash
age-keygen -o host-prd.key        # writes the private key file
age-keygen -y host-prd.key        # prints the public key for .sops.yaml; move host-prd.key to the host, mode 0400
```

```yaml
# .sops.yaml  (public keys only; this file is committed)
creation_rules:
  - path_regex: ^deploy/envs/dev/secrets\.sops\.env$
    age: >-
      age1<dev-host-public-key>,
      age1<alice-public-key>
  - path_regex: ^deploy/envs/stg/secrets\.sops\.env$
    age: >-
      age1<stg-host-public-key>,
      age1<alice-public-key>
  - path_regex: ^deploy/envs/prd/secrets\.sops\.env$
    age: >-
      age1<prd-host-public-key>,
      age1<lead-public-key>
```

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt         # explicit; the default differs on macOS
sops edit deploy/envs/prd/secrets.sops.env                        # creates or edits; plaintext only in the editor buffer
sops decrypt deploy/envs/prd/secrets.sops.env >/dev/null          # proves you hold a recipient key
```

Decrypt on the host, at deploy. The host's pre-up hook does this, not `deploy/deploy.sh`: CI never holds the private key or the plaintext. `run.sh` copies the release's `secrets.sops.env` into `$COMPOSE_DIR` and calls the hook before `compose up`. Install the hook at `/opt/deploy/hooks/pre-up.sh` (root-owned, 0755) and enable it with one line in `/etc/deploy/deploy.conf`, which `run.sh` sources, so the host (not the caller) decides that it runs:

```bash
HOOK_PRE_UP=/opt/deploy/hooks/pre-up.sh
```

```bash
#!/usr/bin/env bash
# /opt/deploy/hooks/pre-up.sh <compose_dir> — turn this release's sops file into what Compose reads
set -Eeuo pipefail
umask 077
dir="$1"
[[ -f "$dir/secrets.sops.env" ]] || exit 0          # environment without secrets
install -d -m 0700 /run/app "$dir/secrets"
SOPS_AGE_KEY_FILE=/etc/sops/age/keys.txt sops decrypt --input-type dotenv --output-type dotenv \
  "$dir/secrets.sops.env" > /run/app/secrets.env.tmp
mv /run/app/secrets.env.tmp /run/app/secrets.env    # app env_file; /run is tmpfs
# Self-hosted Postgres (Hetzner track) reads POSTGRES_PASSWORD_FILE from a Compose file secret,
# which must survive a reboot. Managed Postgres (IONOS DBaaS, Supabase) declares no such secret: skip.
if grep -q 'postgres_password' "$dir/compose.yaml"; then
  sed -n 's/^POSTGRES_PASSWORD=//p' /run/app/secrets.env > "$dir/secrets/postgres_password"
  [[ -s "$dir/secrets/postgres_password" ]] || { echo "pre-up: POSTGRES_PASSWORD missing in secrets.sops.env" >&2; exit 1; }
  chmod 0400 "$dir/secrets/postgres_password"
fi
```

A decrypt failure or a missing key exits non-zero and aborts `run.sh` before `compose up` (`set -e`; the hook is the last command of its `&&` list, so its status counts). Two honest limits: values passed through `env_file` are stored in the container config, so root on the host can read them with `docker inspect` — acceptable on a single-tenant VM where root already holds the age key; and the hook ran locally with sops 3.13.3 + age 1.3.2 on 2026-10-09 (decrypt, managed-database skip, missing `POSTGRES_PASSWORD` → exit 1, tampered file → exit 1), not yet on a live host.

**Docker builds.** A build secret is mounted, never `ARG`/`ENV`:

```dockerfile
RUN --mount=type=secret,id=npm_token NPM_TOKEN="$(cat /run/secrets/npm_token)" pnpm install --frozen-lockfile
```

with `secret-envs: npm_token=NPM_TOKEN` on `docker/build-push-action`. Runtime secrets are not build inputs at all.

## 6. Wire

1. **Scanning, three layers.** Push protection (GitHub; free on public repos, GitHub Secret Protection on private ones, paid): enable in Settings → Code security. Pre-commit: `gitleaks git --pre-commit --staged --redact --no-banner` in the repo's hook runner. CI: add `gitleaks git --redact --no-banner` to the `ci` task so `_checks.yml` runs it. If push protection is unavailable, pre-commit and CI become the only gates: say so.
2. **GitHub environments:** `printf %s "$VALUE" | gh secret set NAME --env prd` (or run it bare and paste at the prompt); never `--body` with a literal (shell history). Set repository secrets only for things every environment shares and that are harmless alone.
3. **Vercel:** `vercel env add NAME production --sensitive` (prompts for the value). Local: `vercel env run -e development -- pnpm dev` runs with remote values and writes no file.
4. **Supabase:** `supabase secrets set --env-file supabase/functions/.env.prd` from a decrypted temp file, then delete it; `supabase secrets list` shows names only. Names must not start with `SUPABASE_`.
5. **Logs:** redact at the logger, not at the call site ([logging-contract](../../core/_shared/logging-contract.md)); redact again in the collector ([deploy-otel-collector](../deploy-otel-collector/SKILL.md)).
6. **Rotation:** record owner, source of truth and interval for each secret in `deploy/envs/README.md` (names only). Rotate on schedule, on offboarding, and on any suspicion. Procedure per type in [secrets-patterns.md](./secrets-patterns.md#rule-rotate-at-the-source-then-the-store-then-the-consumers).
7. Cross-cutting rules: [security-baseline](../../core/_shared/security-baseline.md).

## 7. Verify

```bash
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '\.example$|\.sops\.env$'   # expect: no output
gitleaks git --redact --no-banner                                                 # expect: "no leaks found"
sops decrypt deploy/envs/dev/secrets.sops.env | head -c0 && echo decrypt-ok           # expect: decrypt-ok
docker history --no-trunc <image> | grep -iE 'secret|token|password|key=' ; echo $?   # expect: 1 (no match)
grep -rE 'sb_secret_|service_role|BEGIN [A-Z ]*PRIVATE KEY' dist .next .output build 2>/dev/null   # expect: no output (client bundle)
```

Then prove the pipeline end to end: a deliberately fake token (`ghp_` + 36 `x`) in a scratch commit must be rejected by the
pre-commit hook. Remove the commit afterwards.

## References
- [secrets-patterns.md](./secrets-patterns.md): why each home, rotation order, the client-bundle boundary, when to deviate.
- [../set-up-delivery-pipeline/SKILL.md](../set-up-delivery-pipeline/SKILL.md): environments and OIDC.
- [../_shared/environments.md](../_shared/environments.md): what dev, stg and prd mean.
- [../_shared/stack-versions.md](../_shared/stack-versions.md): sops, age, gitleaks lines.
