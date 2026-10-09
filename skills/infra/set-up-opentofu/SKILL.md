---
name: set-up-opentofu
description: Use when infrastructure should be code — OpenTofu repo layout (modules, one root per environment), encrypted remote state with locking, pinned providers, fmt/validate/plan in CI, plan-as-artifact applied after approval, drift detection.
---

# Set Up OpenTofu

Infrastructure as reviewed code: one module set, one root per environment, state that is encrypted and locked, and an `apply` that only runs a plan a human approved. Contract: [environments.md](../_shared/environments.md).

## 1. Audit current state (change nothing)

```bash
cat .claude/stack-profile.md 2>/dev/null          # iac, hosting, ci, runtime_manager, task_runner
ls infra/ infra/envs infra/modules 2>/dev/null; ls *.tf 2>/dev/null
git ls-files | grep -E '\.tfstate|\.tfplan|tfvars' # committed state or plans: stop and fix first
grep -rn --include=*.tf -E '^(terraform|provider) ' . | head -20
ls .terraform.lock.hcl infra/envs/*/.terraform.lock.hcl 2>/dev/null
tofu version 2>&1 | head -1
```

From the profile: `iac` (`opentofu` or `none`), `hosting` (picks the provider), `ci` (github-actions), `runtime_manager` (mise, asdf, none). If `iac: none` and the user did not ask for IaC, stop. If the repo already has Terraform (`required_providers` with `hashicorp` source, `.terraform.lock.hcl` from Terraform), keep its layout and migrate in place (step 2).

## 2. Decide
- No tofu files → full setup (steps 3 to 7).
- Existing tofu, partial → add only the missing pieces: lock file, encryption, CI, drift, tests.
- Terraform repo → `tofu init` reads it as is; add `.terraform.lock.hcl` for the registry.opentofu.org addresses with `tofu providers lock`, then add encryption. Do not rename resources.
- Layout, backend, encryption, CI and drift all present → "already in place", run step 7, stop.
- Committed `*.tfstate`: remove from history first and rotate every secret it held.

## 3. Detect the provider
| `hosting` | Provider | Skill that uses this |
|---|---|---|
| `hetzner` | `hetznercloud/hcloud` ~> 1.70 | [deploy-to-hetzner](../deploy-to-hetzner/SKILL.md) |
| `ionos` | `ionos-cloud/ionoscloud` ~> 6.7 | [deploy-to-ionos](../deploy-to-ionos/SKILL.md) |
| `vercel`, `supabase` only | none required | Skip; configure through [deploy-to-vercel](../deploy-to-vercel/SKILL.md). A provider exists for both; add it only when the team wants projects and env vars as code |

## 4. Install only what is missing
Pin the tool with the profile's runtime manager (`mise use opentofu@1.13.1`) or the package manager of the machine (`brew install opentofu`). CI uses `opentofu/setup-opentofu`. Line and support window: [stack-versions.md](../_shared/stack-versions.md). Use a supported line (1.12 or 1.13); 1.11 and 1.10 are end of life.

## 5. Generate

Layout (root `infra/`):
```
infra/
  modules/<name>/{main,variables,outputs,versions}.tf  + tests/*.tftest.hcl
  envs/{dev,stg,prd}/{main,versions,backend}.tf  terraform.tfvars  .terraform.lock.hcl
```
Details and every file in [opentofu-patterns.md](./opentofu-patterns.md). In short:

1. **`versions.tf` in every environment root**: `required_version = ">= 1.11"` and a `required_providers` block with the full `source`. Without it OpenTofu looks for `hashicorp/<name>` and fails or, worse, picks a different provider with the same name.
2. **`backend.tf`**: S3-compatible bucket, one state key per environment, `use_lockfile = true`, versioning on the bucket. Create the bucket once by hand (console or CLI); it is the one resource that cannot manage itself.
3. **Encryption**: `TF_ENCRYPTION` environment variable with `pbkdf2` key provider and `aes_gcm`, `enforced = true` for state **and** plan. Passphrase from the secret store ([manage-secrets](../manage-secrets/SKILL.md)).
4. **Lock file**: `tofu providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64`, committed. CI runs `init -lockfile=readonly`.
5. **`.gitignore`**: `.terraform/`, `*.tfstate*`, `*.tfplan`, `tfplan`, `crash.log`, `*.auto.tfvars`.
6. **Module tests** with `mock_provider` (`tofu test`).

## 6. Wire
- Workflows from [opentofu-ci-patterns.md](./opentofu-ci-patterns.md): `infra.yml` (check on PR, plan and apply on `main` with the approval gate) and `infra-drift.yml` (weekly).
- GitHub environments: `dev`, `stg`, `prd` hold the secrets for apply; `prd` has required reviewers. `dev-plan`, `stg-plan`, `prd-plan` hold the same secrets without reviewers, so a plan does not wait for a person.
- Environment secrets: `TF_ENCRYPTION`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (state bucket credentials, not AWS), and `HCLOUD_TOKEN` or `IONOS_TOKEN`. **No OIDC exists for Hetzner or IONOS** (none found 2026-10-09), so these are long-lived tokens: scope them per environment, rotate on a schedule, and say so in the README.
- Delivery of the application itself stays in [set-up-delivery-pipeline](../set-up-delivery-pipeline/SKILL.md).

## 7. Verify
```bash
cd infra/envs/dev
tofu fmt -check -recursive ../..                           # no output
tofu init -input=false -lockfile=readonly                  # "successfully initialized"
tofu validate                                              # "The configuration is valid."
tofu -chdir=../../modules/<name> test                      # "Success! N passed, 0 failed."
tofu plan -input=false -detailed-exitcode; echo $?         # 0 = no changes, 2 = changes, 1 = error
```
Encryption check: with `TF_ENCRYPTION` unset, `tofu plan` must fail to read the state. A plan file must start with `{"meta":{"key_provider.pbkdf2…`, not with the plan JSON.
Locking check: run two applies at once; the second must print `Error acquiring the state lock`. If the bucket cannot lock, `use_lockfile` is not safe there; see the S3 rule in the patterns file.

## References
- [opentofu-patterns.md](./opentofu-patterns.md): layout, backend, encryption, providers, secrets, tests.
- [opentofu-ci-patterns.md](./opentofu-ci-patterns.md): workflows, plan artifact, drift.
- [../_shared/environments.md](../_shared/environments.md), [../_shared/hosting-decision.md](../_shared/hosting-decision.md).
- [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md), [../../core/_shared/engineering-principles.md](../../core/_shared/engineering-principles.md).
