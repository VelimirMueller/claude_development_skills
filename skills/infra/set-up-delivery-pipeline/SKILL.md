---
name: set-up-delivery-pipeline
description: Use when a repo needs trunk-based CI/CD on GitHub Actions — PR checks, one image build per commit pushed by digest, auto-deploy to dev, tag to stg, manual approval to prd — with least-privilege permissions, SHA-pinned actions, OIDC and provenance.
---

# Set Up Delivery Pipeline

One commit is built once. The artifact that passes `dev` is the artifact that reaches `prd`.
Promotion moves a digest between environments; it never rebuilds.

## 1. Audit current state

```bash
cat .claude/stack-profile.md 2>/dev/null || cat ~/.claude/stack-profile.md 2>/dev/null
ls .github/workflows .github/dependabot.yml 2>/dev/null
grep -rn "uses:" .github/workflows 2>/dev/null | grep -vE "@[0-9a-f]{40}" | grep -v "uses: \./"   # unpinned actions
grep -rLn "^permissions:" .github/workflows 2>/dev/null                                           # no top-level permissions
ls Dockerfile compose*.yaml docker-compose*.yml vercel.json justfile mise.toml 2>/dev/null
gh api repos/{owner}/{repo}/environments --jq '.environments[].name' 2>/dev/null                  # dev/stg/prd exist?
gh api repos/{owner}/{repo}/actions/permissions --jq .sha_pinning_required 2>/dev/null
```

Read from the profile: `hosting`, `ci` (must be `github-actions`; any other value: stop and say so), `task_runner`,
`package_manager`, `runtime_manager`, `iac`. If there is no profile, detect from the files above. Ask one question only
when the answer changes the output and the repo does not answer it (for example, `hosting` is unknowable and there is
no `Dockerfile` and no `vercel.json`); then suggest `set-up-stack-profile`.

## 2. Decide what to do

- Workflows already follow all rules in [pipeline-patterns.md](./pipeline-patterns.md) → exit "already in place".
- Workflows exist but break rules (floating tags, no `permissions:`, rebuild per environment, long-lived cloud keys)
  → apply only the delta; list each fix before editing.
- Nothing exists → full setup (steps 3 to 7).
- Tell the user in one line which of the three applies.

## 3. Detect the track

| `hosting` | Track | What deploys |
|---|---|---|
| `hetzner`, `ionos` (container) | **container** | Image digest, through the host skill's deploy step |
| `vercel` only | **vercel** | Vercel Git integration builds; Actions gates promotion |
| `supabase` | **supabase** | Same graph; `deploy/deploy.sh` runs `supabase db push` and `supabase functions deploy` per environment. No image, so `_build.yml` is skipped. |
| mixed | One track per service; the container build workflow is reused for every container service |

Host mechanics are not in this skill: see [containerize-service](../containerize-service/SKILL.md),
[deploy-to-hetzner](../deploy-to-hetzner/SKILL.md), [deploy-to-ionos](../deploy-to-ionos/SKILL.md),
[deploy-to-vercel](../deploy-to-vercel/SKILL.md), and [hosting-decision](../_shared/hosting-decision.md).
Environment names and their meaning are in [environments](../_shared/environments.md).

## 4. Prepare the repo (one time, needs admin)

```bash
# Environments: dev, stg, prd. prd gets reviewers who are not the author.
gh api -X PUT repos/{owner}/{repo}/environments/dev
gh api -X PUT repos/{owner}/{repo}/environments/stg --input - <<'JSON'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
gh api -X PUT repos/{owner}/{repo}/environments/prd --input - <<'JSON'
{ "prevent_self_review": true,
  "reviewers": [{ "type": "Team", "id": 0 }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
# Replace "id": 0 with the team id (gh api orgs/<org>/teams/<slug> --jq .id). Then allow only tags v* on prd and stg:
gh api -X POST repos/{owner}/{repo}/environments/prd/deployment-branch-policies -f name='v*' -f type=tag
gh api -X POST repos/{owner}/{repo}/environments/stg/deployment-branch-policies -f name='v*' -f type=tag
# Reject any action that is not pinned to a full commit SHA (reusable workflows in the same repo are fine).
gh api -X PUT repos/{owner}/{repo}/actions/permissions -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
```

Plan limit: required reviewers and wait timers on **private** repos need GitHub Enterprise. On Free/Pro/Team private
repos, use the fallback in [pipeline-patterns.md](./pipeline-patterns.md#rule-the-prd-gate-must-exist-on-every-plan).
Default workflow token to read-only: Settings → Actions → General → "Read repository contents and packages permissions".

## 5. Generate the workflows

Copy from [workflow-templates.md](./workflow-templates.md), then fill in the commands the profile names:

| File | Role |
|---|---|
| `.github/workflows/delivery.yml` | The only entry point. Triggers, concurrency, job graph. No logic. |
| `.github/workflows/_checks.yml` | Reusable. Lint, typecheck, test, workflow lint (zizmor). Runs the repo's own task runner. |
| `.github/workflows/_build.yml` | Reusable. Build once, push to GHCR, output the digest, attest provenance. |
| `.github/workflows/_deploy.yml` | Reusable. Verify attestation, run `deploy/deploy.sh <env> <image>`, smoke test. |
| `.github/workflows/rollback.yml` | Manual. Redeploys an earlier digest to one environment. |
| `.github/dependabot.yml` | Weekly grouped action bumps with a cooldown. |

Rules to keep while filling in:

1. Pin every third-party `uses:` to a full SHA with the version in a trailing comment. Resolve the SHA from the tag, never copy one from a blog.
2. `permissions: {}` at workflow level; each job declares exactly what it needs.
3. `actions/checkout` always with `persist-credentials: false`.
4. Never interpolate `${{ ... }}` of user-controlled values (branch names, PR titles) into `run:`; pass through `env:`.
5. Task runner branch: `just`, `mise run`, `pnpm run` or `make` is the one command per check; the workflow does not restate lint flags.
6. Runtime setup branch: `runtime_manager: mise` → `jdx/mise-action` (it installs every tool in `mise.toml`); otherwise `pnpm/action-setup` + `actions/setup-node` with `cache: pnpm` and `node-version-file`.
7. Vercel track: replace `_build.yml`/`_deploy.yml` with the Vercel jobs in the templates file.

## 6. Wire

- `deploy/deploy.sh` is the seam to the host. Contract: args `<environment> <image@sha256:digest>`, idempotent, exits non-zero if the new version is not healthy. The host skill writes it.
- Per-environment config lives in GitHub **environment** variables and secrets (`HEALTH_URL`, `DEPLOY_HOST`, …), never in the workflow files. See [manage-secrets](../manage-secrets/SKILL.md).
- Cloud access uses OIDC: `id-token: write` on the deploy job, a trust policy on `sub = repo:<org>/<repo>:environment:<env>`. Targets without OIDC (Hetzner, IONOS, Vercel token) use environment-scoped secrets and rotation; see the patterns file.
- Services emit traces through the collector: [deploy-otel-collector](../deploy-otel-collector/SKILL.md). Mark each deploy in telemetry by setting `deployment.environment.name` and `service.version=<sha>` as resource attributes ([observability](../../core/_shared/observability.md)).
- Security rules this pipeline enforces are defined in [security-baseline](../../core/_shared/security-baseline.md).

## 7. Verify

```bash
actionlint                                                    # syntax and expression errors
pipx run zizmor==1.30.1 .github/workflows                     # injection, excessive permissions, unpinned refs; expect no findings above "low"
grep -rn "uses:" .github/workflows | grep -vE "@[0-9a-f]{40}|uses: \./"   # expect: no output
```

End to end, in this order:

1. Open a PR → only `checks` runs; no build, no deploy, no secrets exposed.
2. Merge → `checks`, `build`, `dev` run; the run summary lists an attestation; `dev` deploys `image@sha256:…`.
3. `gh attestation verify oci://ghcr.io/<org>/<repo>@sha256:… --owner <org>` exits 0.
4. Tag `v0.0.1` on that commit → `resolve` finds the same digest, `stg` deploys it, `prd` waits for approval.
5. Approve → `prd` deploys the **same** digest. The `image` line in the `dev`, `stg`, `prd` logs is identical.

## References
- [pipeline-patterns.md](./pipeline-patterns.md): why each rule exists, the no-OIDC targets, the prd gate on every plan, when to deviate.
- [workflow-templates.md](./workflow-templates.md): the six files, copy-ready.
- [../_shared/stack-versions.md](../_shared/stack-versions.md): action and tool lines; re-verify before pinning.
