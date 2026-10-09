# Environments Contract

The contract every infra skill follows. Three environments: `dev`, `stg`, `prd`. One artifact, built once, promoted by digest.

## Rule: build once, promote the digest
**Why:** A rebuild per environment ships a different binary to `prd` than the one tested in `stg`. Base-image drift, a moved tag or a changed dependency makes "it worked in stg" false. A digest names the exact bytes.
**How to apply:** CI builds `ghcr.io/<org>/<app>` once, records `image@sha256:…`, and every environment deploys that reference. Never deploy a tag. The host rejects any reference that is not `<repo>@sha256:<64 hex>` (see [deploy-script.md](./deploy-script.md)). Promotion moves the same digest from `dev` to `stg` to `prd`. Pipeline mechanics: [set-up-delivery-pipeline](../set-up-delivery-pipeline/SKILL.md).
**Anti-example:** `docker build` on the `prd` host, or `image: app:latest` in compose.
**Exception:** Vercel builds in its own pipeline. Promoting a staged production build does not rebuild, but there is no digest to compare. See [deploy-to-vercel](../deploy-to-vercel/SKILL.md).

## Rule: config differs by environment variables only
**Why:** If code branches on `if (env === 'prd')`, the `prd` path is untested everywhere else. Configuration is data; code is the same.
**How to apply:** The app reads every setting from environment variables, validated once at startup (fail fast; see [validate-env](../../frontend/validate-env/SKILL.md) for the TypeScript seam). Per-environment files hold only non-secret values: `deploy/envs/<env>/config.env`. Secrets come from the secret store: [manage-secrets](../manage-secrets/SKILL.md). The same compose file, the same image, different `config.env`.
**Anti-example:** A `compose.prd.yaml` that adds services `dev` does not have.

## Rule: prd changes need approval
**Why:** `prd` is where users and data are. A person who did not write the change must see it first, and the record must say who approved.
**How to apply:**
- Infrastructure: `tofu plan` runs on the pull request; `tofu apply` runs from the saved plan file after approval of the GitHub environment `prd` (required reviewers). See [set-up-opentofu](../set-up-opentofu/SKILL.md).
- Application: the `prd` deploy job uses the same environment gate.
- `dev` deploys on merge to `main`. `stg` and `prd` deploy from a version tag.
- Private repositories on a plan without environment reviewers have a weaker gate. Say so in the README; do not pretend.
**Anti-example:** `tofu apply -auto-approve` from a laptop against `prd`.

## Rule: names are derived, never typed twice
**Why:** A name spelled differently in DNS, tofu and compose is the usual cause of "it deployed to the wrong place".
**How to apply:**

| Thing | Pattern | Example |
|---|---|---|
| Environment | `dev`, `stg`, `prd` | `prd` |
| Resource prefix | `<app>-<env>` | `shop-prd` |
| GitHub environment | the environment name | `prd` |
| Hostname | `<env>.<app>.<domain>`; `prd` uses `<app>.<domain>` | `stg.shop.example.com` |
| Tofu state key | `<env>/terraform.tfstate` in a bucket per app | `prd/terraform.tfstate` |
| Compose project | `<app>-<env>` | `shop-prd` |
| Labels on every cloud resource | `project`, `environment`, `managed_by=opentofu` | |
| Image | one repository per app, never per environment | `ghcr.io/acme/shop` |

Set `name = "${var.app}-${var.environment}"` once in the environment root and pass it down.

## Rule: environments are isolated by account, not by trust
**Why:** A shared database or shared credentials makes `dev` a path into `prd`.
**How to apply:** Separate servers, volumes, networks and databases per environment. Separate deploy keys and tokens, stored as secrets of that GitHub environment only. Separate Postgres credentials. `dev` and `stg` never hold `prd` data; copy to `stg` only after masking.
**Anti-example:** One Hetzner project and one API token for all three environments (a leaked `dev` token deletes `prd`). Use one Hetzner project per environment where the team size allows it; otherwise one token per environment with delete protection on `prd` resources.

## Rule: a rollback is a deploy of an older digest
**Why:** A rollback that uses a different code path is untested when it is needed.
**How to apply:** Re-run the deploy job with the previous digest. The host script keeps the previous release file and restores it when the new version does not become healthy. Database migrations must be backward compatible for one release (expand, then contract), or the rollback breaks.

## When to deviate
- A static site with no server state: `dev` can be the pull-request preview; `stg` can be skipped when the preview is the staging step. Keep `prd` behind an approval.
- A solo project: one reviewer is the author. Keep the gate as a pause for the plan output, and say that it is not a second pair of eyes.
- Two environments only (`stg` and `prd`): keep the contract; do not rename them.
