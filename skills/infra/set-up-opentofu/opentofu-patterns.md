# OpenTofu Patterns

Reference for `set-up-opentofu`. Layout, provider sources, remote state, encryption, secrets, module rules, tests. Verified against OpenTofu 1.13.1 on 2026-10-09; the CI side is [opentofu-ci-patterns.md](./opentofu-ci-patterns.md).

## Rule: one root module per environment, modules shared
**Why:** Each root has its own state file, its own tfvars and its own credentials, so a dev plan cannot reach prd resources at all. Workspaces share one state and one variable set; selecting the wrong workspace applies dev values to prd. Blast radius is the argument, not convenience.
**How to apply:**
```
infra/
  modules/<name>/{main,variables,outputs,versions}.tf  + tests/*.tftest.hcl
  envs/{dev,stg,prd}/{main,variables,versions,backend}.tf  terraform.tfvars  .terraform.lock.hcl
```
The root is thin: locals for names, the provider block, one module call, outputs. `envs/dev/main.tf`:

```hcl
locals {
  app         = "shop"
  environment = "dev"
  name        = "${local.app}-${local.environment}"
}

provider "hcloud" {} # token from HCLOUD_TOKEN

module "host" {
  source = "../../modules/hetzner-host"

  name                  = local.name
  environment           = local.environment
  server_type           = var.server_type
  volume_size_gb        = 20
  protect               = false
  admin_ssh_public_key  = var.admin_ssh_public_key
  deploy_ssh_public_key = var.deploy_ssh_public_key
  image_repo            = "ghcr.io/acme/shop"
  run_script            = file("${path.module}/../../../deploy/host/run.sh")
}

output "ipv4" {
  value = module.host.ipv4
}
```

`envs/dev/variables.tf` (what differs per environment):

```hcl
variable "server_type" {
  type = string
}

variable "admin_ssh_public_key" {
  type = string
}

variable "deploy_ssh_public_key" {
  type = string
}
```

`envs/dev/terraform.tfvars` — sizing and public keys, no secrets:

```hcl
server_type           = "cx23"
admin_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdmin admin@example.com"
deploy_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDeploy deploy-dev"
```

Sizing lives in the root, not the module: dev takes `volume_size_gb = 20` and `server_type = "cx23"`; the prd root passes a larger volume, a bigger `server_type` (look it up with `hcloud server-type list`; prices moved twice in 2026) and `protect = true`. The IONOS module sizes its database by environment (`count = var.environment == "prd" ? 2 : 1`). Names are derived once ([environments.md](../_shared/environments.md)); `run_script` pulls the host-side deploy script from the same tree ([deploy-script.md](../_shared/deploy-script.md)). `versions.tf` and `backend.tf` complete the root — below.

**Anti-example:** one root with `terraform.workspace == "prd" ? … : …` and a shared tfvars file.

## Rule: every root declares `required_providers` with the full source
**Why:** Verified pitfall: a root with `provider "hcloud" {}` but no root `required_providers` makes OpenTofu resolve the bare name to `hashicorp/hcloud`. Init fails — or resolves a different provider with the same name. The OpenTofu registry does not share Terraform's default namespace.
**How to apply:** `envs/dev/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
```

The IONOS root declares its provider the same way (`envs/dev-ionos/versions.tf`):

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    ionoscloud = {
      source  = "ionos-cloud/ionoscloud"
      version = "~> 6.7"
    }
  }
}
```

Modules repeat the block (`modules/hetzner-host/versions.tf` holds the same hcloud stanza), so a module pulled into a new root cannot fail on a missing source.
**Anti-example:** `provider "ionoscloud" {}` in a root whose only `required_providers` lives in a module.

## Rule: remote state in object storage, with a lock the store actually supports
**Why:** State in the repo leaks resource values and merges badly; state on a laptop blocks CI. The lock keeps two applies from interleaving. On S3-compatible stores the lock is a conditional write (`If-None-Match`) to `<key>.tflock`, so it works only where the store supports conditional writes.
**How to apply:** `envs/dev/backend.tf` (Hetzner Object Storage, nbg1):

```hcl
terraform {
  backend "s3" {
    bucket = "shop-tfstate"
    key    = "dev/terraform.tfstate"
    region = "nbg1"

    endpoints      = { s3 = "https://nbg1.your-objectstorage.com" }
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
```

The skip flags exist because the store is not AWS: `skip_credentials_validation` (no STS to validate against), `skip_requesting_account_id` (no account API), `skip_metadata_api_check` (no EC2 metadata on a runner; the probe hangs), `skip_region_validation` (`nbg1` is not an AWS region), `skip_s3_checksum` (do not send the SDK's new checksum headers). `use_path_style = true` puts the bucket in the path — S3-compatible stores do not route virtual-hosted buckets. All flags verified against a local S3 clone, including a real lock conflict (`Error acquiring the state lock`).

Create the bucket once by hand — Console or S3 API; Hetzner has no provider resource for buckets — with versioning on. It is the one resource that cannot manage itself. One state key per environment (`dev/terraform.tfstate`).

Before trusting the lock on a real store, test conditional writes:

```bash
aws s3api put-object --bucket shop-tfstate --key locktest --if-none-match '*'   # succeeds
aws s3api put-object --bucket shop-tfstate --key locktest --if-none-match '*'   # must fail with 412 PreconditionFailed
```

Support on Hetzner and IONOS Object Storage is unverified (2026-10-09); run this test first. If the second put succeeds, `use_lockfile` is not safe there: fall back to the `pg` backend (unverified here) or a store that can lock. IONOS values: endpoint `https://s3.eu-central-3.ionoscloud.com`, region `eu-central-3` (unverified combination).

**Anti-example:** `backend "local"` in a repo with two engineers, or an S3 backend without the skip flags against a non-AWS store.

## Rule: encrypt state and plans before they touch the store
**Why:** Bucket credentials are one leak away from full infrastructure state — addresses, ids, everything the resources hold. `TF_ENCRYPTION` encrypts the state file and saved plans with `aes_gcm` before the backend sees them; `enforced = true` refuses to write plaintext.
**How to apply:** `TF_ENCRYPTION` holds HCL; the whole value is one secret:

```hcl
key_provider "pbkdf2" "state_key" {
  passphrase = "<openssl rand -base64 32; from the secret store>"
}

method "aes_gcm" "state_method" {
  keys = key_provider.pbkdf2.state_key
}

state {
  method   = method.aes_gcm.state_method
  enforced = true
}

plan {
  method   = method.aes_gcm.state_method
  enforced = true
}
```

An env var, not a file, because the passphrase must never sit in the repo, and the encryption HCL is not module config: it cannot reference `var.*` (unverified whether any interpolation form is supported there). Generate the passphrase with `openssl rand -base64 32`, keep it in the secret store ([manage-secrets](../manage-secrets/SKILL.md)); CI injects it as a GitHub environment secret. Verified results: an encrypted plan file starts with `{"meta":{"key_provider.pbkdf2` (not the plan JSON), and without the key the state cannot be read.

pbkdf2 is acceptable because the passphrase is 32+ random characters and Hetzner and IONOS have no KMS to hand keys to. Where a KMS exists, prefer a KMS key provider — `aws_kms`, `gcp_kms`, `openbao`, `external` (OpenTofu docs).

Key rotation and the initial migration both use `fallback` (reads old, writes new). To encrypt an existing plaintext state, put the `unencrypted` method as `fallback`, apply once, remove it:

```hcl
method "unencrypted" "migration" {}

state {
  method    = method.aes_gcm.state_method
  fallback  = method.unencrypted.migration
  enforced  = true
}
```

Rotating a passphrase has the same shape: new key provider as `method`, old as `fallback`, one apply, remove the fallback. Recipe from the OpenTofu encryption docs; not run during authoring.

## Rule: pin providers with `~>` and a committed lock file
**Why:** `~> 1.70` takes 1.70.x patches and refuses 1.71 until someone reads the changelog. The lock file records checksums, so CI installs the same provider bytes the plan was made with.
**How to apply:** after adding or bumping a provider:

```bash
tofu providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
```

Three platforms: the CI runner (linux_amd64), arm64 hosts (Hetzner `cax`), developer Macs. Commit `.terraform.lock.hcl` per root; CI runs `tofu init -lockfile=readonly` and fails when the lock does not cover the config. Upgrades go through reviewed pull requests; whether Renovate or Dependabot (`terraform` ecosystem) resolves registry.opentofu.org addresses is unverified — check before relying on either.
**Anti-example:** `version = ">= 1.0"` and no lock file.

## Rule: passwords are ephemeral and write-only
**Why:** A `sensitive` variable still lands in state in plaintext. An `ephemeral = true` variable never persists; a write-only attribute (OpenTofu >= 1.11, which `required_version = ">= 1.11"` already demands) reaches the API without being stored.
**How to apply:** `modules/ionos-host/variables.tf`:

```hcl
variable "db_password" {
  description = "Write-only: never stored in state. Supply it ephemerally (TF_VAR_db_password from the secret store)."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}
```

and the DBaaS block that consumes it (`modules/ionos-host/main.tf`):

```hcl
  credentials = {
    username         = "app"
    password         = var.db_password
    password_version = var.db_password_version
    database         = "app"
  }
```

Supply the value as `TF_VAR_db_password` from the secret store; `db_password_version` is bumped to rotate. State still holds other values — addresses, ids — so it stays encrypted and the bucket stays private. tfvars hold no secrets (see the dev file above: a server type and two public keys). Provider tokens (`HCLOUD_TOKEN`, `IONOS_TOKEN`) arrive as env vars only; the provider blocks in the roots are empty.
**Anti-example:** a `db_password` value in `prd/terraform.tfvars`.

## Rule: modules validate inputs, label everything, and do not churn hosts
**Why:** A module is a contract; validation turns a typo (`"qa"`) into a plan-time error instead of a wrongly-named stack of resources. Labels make every console listing answer "which environment owns this". cloud-init runs once per host: treating it as config that must converge forces a server replacement on every template edit.
**How to apply:** typed variables with validation (`modules/hetzner-host/variables.tf`):

```hcl
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd."
  }
}
```

Labels on every resource (`modules/hetzner-host/main.tf`):

```hcl
locals {
  labels = {
    project     = var.name
    environment = var.environment
    managed_by  = "opentofu"
  }
}
```

And the cloud-init ignore (`modules/hetzner-host/main.tf`; the IONOS module ignores `ssh_keys, volume[0].user_data` for the same reason):

```hcl
  # cloud-init runs once. A change to it must not destroy a running host.
  lifecycle {
    ignore_changes = [ssh_keys, user_data]
  }
```

A deliberate cloud-init change is then an explicit replace decision, not a side effect. Delete protection uses provider flags driven by a variable (`delete_protection = var.protect`, `rebuild_protection = var.protect`) over `prevent_destroy`, because `prevent_destroy` accepts a literal only and cannot take a variable: dev could never rebuild, or prd would need a per-env code fork.
**Anti-example:** `prevent_destroy = var.protect` — not valid; lifecycle guards take literals.

## Rule: module tests with `mock_provider`, run in CI
**Why:** The module encodes rules that matter — firewall shape, prd protection, input validation. `tofu test` checks them at plan time without cloud credentials, so they run on every pull request, forks included.
**How to apply:** `modules/hetzner-host/tests/host.tftest.hcl`:

```hcl
# Hetzner ids are numeric; the default mock id is a random string.
mock_provider "hcloud" {
  mock_resource "hcloud_ssh_key" {
    defaults = { id = "1001" }
  }
  mock_resource "hcloud_network" {
    defaults = { id = "1002" }
  }
  mock_resource "hcloud_firewall" {
    defaults = { id = "1003" }
  }
  mock_resource "hcloud_primary_ip" {
    defaults = { id = "1004" }
  }
  mock_resource "hcloud_volume" {
    defaults = { id = "1005" }
  }
  mock_resource "hcloud_server" {
    defaults = { id = "1006" }
  }
}

variables {
  name                  = "shop-dev"
  environment           = "dev"
  server_type           = "cx23"
  admin_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdmin admin"
  deploy_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDeploy deploy"
  image_repo            = "ghcr.io/acme/shop"
  run_script            = "#!/usr/bin/env bash\necho hi\n"
}

run "firewall_opens_only_ssh_http_https_icmp" {
  command = plan

  assert {
    condition     = length(hcloud_firewall.this.rule) == 4
    error_message = "Firewall must hold exactly ssh, http, https and icmp rules."
  }
}

run "prd_is_protected" {
  command = plan

  variables {
    environment = "prd"
    protect     = true
  }

  assert {
    condition     = hcloud_server.this.delete_protection && hcloud_volume.data.delete_protection
    error_message = "prd server and volume need delete protection."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}
```

Hetzner ids are numeric and the default mock id is a random string, so every mock resource pins a numeric `id` default. `expect_failures` asserts the validation rule fires. The CI check job runs `tofu test` for every module with a `tests/` directory ([opentofu-ci-patterns.md](./opentofu-ci-patterns.md)).

## Rule: adopt existing resources with `import`, move them with `moved`
**Why:** Hand-made resources can join state without recreation, and renames do not destroy-and-recreate when the mapping is declared. Both are plain blocks, reviewed like any change.
**How to apply:**

```hcl
import {
  to = hcloud_server.this
  id = "12345678" # the cloud-side id, from the console
}

moved {
  from = hcloud_server.this
  to   = hcloud_server.renamed
}
```

`tofu plan` shows an import or move as an in-place change; apply records it. Verified against the OpenTofu docs only — not exercised on a live stack during authoring.

## Rule: scan the tofu code for misconfigurations
**Why:** Provider defaults drift; a scanner catches open ingress and unencrypted stores before review does.
**How to apply:** the CI check job runs, from the pinned image (never the compromised action tag — see [containerize-service](../containerize-service/SKILL.md)):

```bash
docker run --rm -v "$PWD/infra:/work:ro" \
  ghcr.io/aquasecurity/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa \
  config --exit-code 1 --severity HIGH,CRITICAL --no-progress /work
```

It reported 0 misconfigurations on these modules.

## Pitfalls (already paid for)
- **Missing root `required_providers`** resolves to `hashicorp/<name>` and init fails — the rule above exists because this happened.
- **Sticky `ssh_keys` / `user_data` on Hetzner**: both force server replacement, so the module ignores them after creation; a new admin key or cloud-init only lands through a deliberate replace. On IONOS, volume `user_data` is base64 and immutable outright.
- **hcloud `datacenter` is gone**: the attribute was removed from the API (datacenter endpoints return 410 since 2026-10-01); use `location` — `fsn1`, `nbg1`, `hel1` are EU.

## When to deviate
- **Existing Terraform repo**: `tofu init` reads it as is; add the OpenTofu lock file and encryption in place instead of restructuring (SKILL.md step 2).
- **One environment**: a single `envs/dev` root is fine; add roots when stg and prd exist.
- **Store that cannot lock**: the `pg` backend or a different store beats `use_lockfile = false` on a shared state.
- **A platform group owns the state**: their backend and CI win; keep the module, secret and test rules.
