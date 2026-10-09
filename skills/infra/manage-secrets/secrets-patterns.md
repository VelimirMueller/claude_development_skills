# Secrets Patterns

Reference for [manage-secrets](./SKILL.md). Cross-cutting policy is in
[security-baseline](../../core/_shared/security-baseline.md); this file is the infra mechanics.

## Rule: a secret has one home per environment

**Why:** Copies drift. A secret in the repo, the CI store, and a laptop `.env` cannot be rotated by changing one place, so
it is never fully rotated. One home means rotation is one edit and revocation is one deletion.
**How to apply:** Pick the home from the table in the skill, by where the secret is *used*: the runtime holds runtime
secrets; CI holds only what CI needs to deploy. CI does not hold runtime secrets for self-hosted Compose, because the
host decrypts its own file; CI does not hold them for Vercel or Supabase, because those platforms hold their own.
**Anti-example:** `DATABASE_URL` for prd in a GitHub repository secret, a `.env` on the server and a sops file.

## Rule: sops + age for self-hosted Compose, decrypted on the host

**Why:** A Compose host has no secret manager. A sops file in the repo gives versioned, reviewable, access-controlled
secrets (the diff shows which key changed, not its value) with no extra service to run. age over PGP: one small key
format, no keyring, no expiry dance. Decrypting on the host, not in CI, keeps the private key and the plaintext out of
GitHub: a compromised workflow can ship ciphertext but cannot read it.
**How to apply:** One age key per host and one per human who edits that environment (`.sops.yaml`, `creation_rules` with
`path_regex` per environment; first matching rule wins). The file is `deploy/envs/<env>/secrets.sops.env` (dotenv, keys in
clear, values encrypted, so diffs name the changed key). Host private key at `/etc/sops/age/keys.txt`, mode 0400, root.
Decrypt into `/run/app/` (tmpfs) at deploy and pass with `--env-file`. Back up the host key separately (a password
manager vault); losing it loses the file.
**Anti-example:** One shared age key for all environments, pasted into a GitHub secret so CI can decrypt.

**Alternative considered:** SOPS with a cloud KMS, Vault, or Infisical. Each adds a service or a cloud dependency. Choose
them when more than a handful of hosts or people need audited, time-limited access; the sops file format moves over
unchanged (add the KMS key to `.sops.yaml`, run `sops updatekeys`).

## Rule: rotate at the source, then the store, then the consumers

**Why:** Updating the store first means consumers hold a value the source no longer accepts, or the source still accepts
the old one. Rotating only the store never invalidates the leaked value.
**How to apply:**
1. Create the new credential at the source (database role password, API console, Supabase **secret key**: create new, swap, delete old).
2. Write it to the home: `sops edit`, `vercel env update NAME production`, `supabase secrets set`, `gh secret set --env`.
3. Redeploy the consumers (Supabase Edge Functions read new secrets immediately; Vercel needs a new deployment; Compose needs `up -d`).
4. Revoke the old credential at the source, and confirm nothing broke before you close the task.
5. Removing a person or host from `.sops.yaml`: `sops updatekeys <file>`, then `sops rotate -i <file>` to change the data key.
   **They already saw the values**, so also rotate every secret in that file at its source (steps 1 to 4).
Rotate on a schedule (record an interval per secret), on offboarding, and on suspicion.
**Anti-example:** Deleting a leaked key from the repo and calling it fixed. History, forks and caches keep it.

## Rule: the client bundle is public; names say so

**Why:** Anything in a browser bundle is readable by every visitor. Frameworks expose variables with a public prefix
(`VITE_`, `NEXT_PUBLIC_`, `NUXT_PUBLIC_`) to the bundle, so a secret with that prefix ships to everyone.
**How to apply:** Public prefix only on values that are safe to publish. Supabase: the publishable key (`sb_publishable_…`;
legacy `anon`) is safe in clients, because Row Level Security protects data; the secret key (`sb_secret_…`; legacy
`service_role`) bypasses RLS and lives only on the server. Legacy keys are deprecated by the end of 2026; new work uses
the new keys. Grep the build output in CI (step 7 of the skill). Server-only values are read in server code through the
env schema module, never imported from shared client code.
**Anti-example:** `VITE_SUPABASE_SERVICE_ROLE_KEY` "just for the admin page".

## Rule: build secrets are mounted, runtime secrets are not build inputs

**Why:** `ARG` and `ENV` values persist in image layers and `docker history`; anyone who can pull the image reads them.
A BuildKit secret mount exists only during one `RUN` and is not stored in any layer.
**How to apply:** `RUN --mount=type=secret,id=…` and `secret-envs`/`secret-files` on the build action. If an app needs a
value to *start*, it reads it at runtime from the environment or a file; the image is identical across environments.
**Anti-example:** `ARG DATABASE_URL` so the build can run migrations.

## Rule: secrets never reach logs, traces or state

**Why:** Telemetry is copied to a backend with broader access and longer retention than the secret store. Terraform/OpenTofu
state stores every attribute of every resource, including generated passwords, in plain text.
**How to apply:** Log redaction at the logger ([logging-contract](../../core/_shared/logging-contract.md)); attribute
redaction in the collector ([otel-collector-patterns](../deploy-otel-collector/otel-collector-patterns.md)); GitHub masks
registered secrets in logs but not derived values (base64, JSON-wrapped), so never echo them. State goes in an encrypted
remote backend with restricted access; prefer passing secrets to resources by reference (generated at the source, read
by the app) over tofu-managed values. See [set-up-opentofu](../set-up-opentofu/SKILL.md).
**Anti-example:** `set -x` in a deploy script, or `echo "$TOKEN" | base64` "to check it".

## Rule: scan in three places, because each fails differently

**Why:** Push protection blocks known token formats at the push (not generic passwords, and it can be bypassed with a
reason); the pre-commit hook stops it before it leaves the laptop but only if installed; the CI scan covers people who
skipped both and finds history hits. Together they leave a gap only for secrets with no recognisable shape.
**How to apply:** GitHub push protection where the plan has it (free on public repos; GitHub Secret Protection, paid per
active committer, on private repos). `gitleaks git --pre-commit --staged` as the hook. `gitleaks git` in the `ci` task
(checkout with `fetch-depth: 0` for a full-history scan; the default shallow checkout scans only the tip). Use the
`gitleaks` binary, not `gitleaks-action`: the action needs a license key for organization accounts. Fix a hit by rotating first.
**Anti-example:** Enabling only the CI scan: the secret is already public by the time it runs.

## When to deviate

- **A managed secret store is already mandated** (company Vault, cloud KMS): use it as the home and keep every other rule
  (one home, rotate at source, no bundles, scanning).
- **High-value secrets** (payment keys, signing keys): mount as files (`secrets:` in Compose, `*_FILE` env convention)
  instead of environment variables. Environment variables show up in `docker inspect`, crash dumps and child processes.
- **Solo hobby project on one box:** a sops file and one age key is enough; skip per-environment recipients, keep
  scanning and `.env.example`.
- **Pull-based or Kubernetes hosts:** the in-cluster operator for sops (or External Secrets) replaces the host decrypt
  step; rules above still apply.
