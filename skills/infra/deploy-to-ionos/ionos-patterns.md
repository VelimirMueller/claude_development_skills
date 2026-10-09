# IONOS Patterns

Reference for `deploy-to-ionos`. Provider `ionos-cloud/ionoscloud` ~> 6.7 (6.7.38); lines in [stack-versions.md](../_shared/stack-versions.md). OpenTofu >= 1.11 is required for the DBaaS write-only password. The module below passed `tofu validate` with provider 6.7.x and its cloud-init template parses; nothing that needs an IONOS contract was run (list at the end).

## Rule: one datacenter per environment; EU location; backups in the same country

**Why:** The datacenter fixes the geography a residency contract names, and datacenter, LANs, server and DBaaS cluster must all sit in the same one. `backup.location` ships WAL and backups to Object Storage — a different region there quietly moves the data abroad.

**How to apply:** One `ionoscloud_datacenter` per environment. `location` values look like `de/fra` (Frankfurt), `de/txl` (Berlin), `es/vit`, `fr/par`, `gb/lhr`; pick an EU one for residency. DBaaS is offered in all locations. Set `backup.location` to an Object Storage region in the same country as the datacenter (`eu-central-3` is Berlin; list valid values with the `ionoscloud_pg_backup_location_v2` data source).

**Anti-example:** Server and cluster in `de/fra`, `backup.location = "us-central-1"`.

## Rule: public LAN + private LAN; the database is reachable only on the private one

**Why:** DBaaS Postgres has no public endpoint: it listens on a private LAN in the same datacenter. That LAN is the database's firewall, and the app must run in the same datacenter.

**How to apply:** Two `ionoscloud_lan` resources, `public = true` and `public = false`. The server's inline NIC sits on the public LAN with an IP from `ionoscloud_ipblock`; a second NIC (`ionoscloud_nic`) sits on the private LAN. The cluster's `connections.primary_instance_address` (`192.168.1.100/24` in the module) must sit inside the subnet of the LAN that second NIC uses. How that NIC gets its address is unverified — after apply, check `ip -4 addr` on the host and configure the address statically if DHCP did not hand one out.

Forbidden ranges (IONOS docs; do not build LANs in them): `10.208.0.0/12`, `10.233.0.0/18`, `10.233.64.0/18`, `192.168.230.0/24`.

**Anti-example:** An app on another provider reaching the database "over the internet" — there is no such route.

## Rule: one inline `nic` per server; extra NICs are resources; firewall on the NIC, ingress only

**Why:** `ionoscloud_server` accepts exactly one inline `nic` block — a second inline block fails `tofu validate` (verified during research). Extra NICs are `ionoscloud_nic` resources attached by `server_id`. Firewall rules live inline in the NIC and `firewall_type` is `INGRESS`: egress stays open, which keeps Traefik's outbound ACME calls working without a rule list nobody reviews.

**How to apply:** Inline NIC on the public LAN, reserved IP, `firewall_active = true`, rules for TCP 22, 80 and 443. One honest limit: a firewall rule takes a single `source_ip`, so the module's SSH rule uses `var.ssh_allowed_cidrs[0]` only. To allow several ranges, add one rule per range — not tested here. Hosted CI runners have no stable range, hence the open default in `variables.tf`.

**Anti-example:** Two inline `nic` blocks (validate error); an `EGRESS` rule set copied from another environment without a review.

## Rule: DBaaS Postgres v2 — each knob has a failure mode

**Why:** Managed Postgres buys back patching, replication and PITR hours ([hosting-decision.md](../_shared/hosting-decision.md)). The knobs decide what is lost and when writes stop.

**How to apply:**
- **Password:** write-only. Declare the variable `ephemeral = true` (needs OpenTofu >= 1.11) and supply `TF_VAR_db_password` from the secret store ([manage-secrets](../manage-secrets/SKILL.md)); the value never lands in state. Rotate by bumping `db_password_version`, then updating the secret.
- **Version:** `18` (14 to 18 available).
- **`replication_mode`:** `ASYNCHRONOUS` can lose the most recent commits on failover; `STRICTLY_SYNCHRONOUS` refuses writes when no standby acknowledges. The module ships ASYNCHRONOUS.
- **Instances:** `count = 2` in prd (a standby for failover), `1` elsewhere.
- **`connection_pooler = "TRANSACTION"`**; `max_connections` follows the instance RAM (4 GB = 384 … > 8 GB = 1000; 11 connections are reserved).
- **TLS** is always on, SCRAM-SHA-256 is required, there is no superuser.
- **Backups:** default 7-day window, `retention_days` 1 to 365; WAL ships to Object Storage every 5 minutes. PITR always creates a **new** cluster: restore from a backup via console or API, or with a `restore_from_backup` block and `recovery_target_datetime`, then repoint the app at the new `dns_name`.
- **Restore drill, quarterly:** recover one backup into a scratch cluster and read from it. A backup never restored is a hope, not a backup.

**Anti-example:** `STRICTLY_SYNCHRONOUS` with `instances.count = 1` — no standby acknowledges, so every write stops.

## Rule: Object Storage — global names, five keys, conditional writes unverified

**Why:** Backups land there, and the tofu state may land there — but only if the store supports conditional writes.

**How to apply:** Bucket via `ionoscloud_s3_bucket`. The bucket name is unique across **all** IONOS accounts, not per account. Region `eu-central-3` (Berlin; `eu-central-4` Frankfurt and `us-central-1` exist too); endpoints look like `s3.eu-central-3.ionoscloud.com`. Versioning, lifecycle rules and object lock are supported. Credentials via `ionoscloud_object_storage_accesskey` or the console — at most five access keys per user; the provider reads `IONOS_S3_ACCESS_KEY` / `IONOS_S3_SECRET_KEY` from the environment. Before using a bucket as the tofu state backend, prove conditional writes: two `aws s3api put-object --if-none-match '*'` to the same key, the second must fail with 412 PreconditionFailed (`use_lockfile` needs this; see [opentofu-patterns.md](../set-up-opentofu/opentofu-patterns.md)). Support on IONOS is unverified.

## Rule: server sizing — ENTERPRISE, vCPU or Cube; a Cube template is a life sentence

**Why:** The three families trade price against noisy-neighbour risk, and a Cube cannot be resized.

**How to apply:** `type = "ENTERPRISE"` (the module's choice) buys dedicated cores — predictable latency next to a database. `ionoscloud_vcpu_server` is the shared vCPU family. A Cube (`ionoscloud_cube_server`) is a fixed bundle: `template_uuid` from `data "ionoscloud_template"` (for example name `"Basic Cube XS"`: 1 vCPU, 2 GB RAM, 60 GB NVMe; nine Basic and Memory templates up to Basic XL 16 vCPU / 32 GB / 960 GB). Cores, RAM and volume size cannot be set on a Cube, and the template is fixed at creation: to grow, replace the server. `cpu_family` availability varies by location — check the location's catalog before pinning one.

## Rule: cloud-init runs once — keep `user_data` out of the diff

**Why:** The volume's `user_data` (base64) is immutable; a detected change replaces a running host.

**How to apply:** Boot a cloud-init-capable image (`image_name = "ubuntu:latest"`), pass `module.bootstrap.user_data_b64`, and ignore later drift: `lifecycle { ignore_changes = [ssh_keys, volume[0].user_data] }` (accepted by `tofu validate`). Bootstrap changes reach new hosts through the module; apply them to a running host over SSH, or accept a deliberate replacement by removing the ignore for that one change.

## The module (`tofu validate` passed, provider 6.7.x)

It reuses `modules/host-bootstrap` for cloud-init with `distro = "ubuntu"` — the same bootstrap module as the Hetzner skill ([hetzner-patterns.md](../deploy-to-hetzner/hetzner-patterns.md)); only the infrastructure around it differs.

`infra/modules/ionos-host/versions.tf`:

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

`infra/modules/ionos-host/variables.tf`:

```hcl
variable "name" {
  type = string
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd."
  }
}

variable "location" {
  description = "IONOS location: de/fra, de/txl, es/vit, fr/par, gb/lhr ... Pick an EU one for residency."
  type        = string
  default     = "de/fra"
}

variable "cores" {
  type    = number
  default = 2
}

variable "ram_mb" {
  type    = number
  default = 4096
}

variable "disk_gb" {
  type    = number
  default = 60
}

variable "admin_ssh_public_key" {
  type = string
}

variable "deploy_ssh_public_key" {
  type = string
}

variable "image_repo" {
  type = string
}

variable "run_script" {
  type = string
}

variable "ssh_allowed_cidrs" {
  description = "Hosted CI runners have no stable range, so the default is open."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_enabled" {
  type    = bool
  default = true
}

variable "pg_version" {
  type    = string
  default = "18"
}

variable "db_password" {
  description = "Write-only: never stored in state. Supply it ephemerally (TF_VAR_db_password from the secret store)."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}

variable "db_password_version" {
  description = "Bump to rotate the password."
  type        = string
  default     = "1"
}

variable "backup_location" {
  description = "Object Storage location for DBaaS backups; list valid values with the ionoscloud_pg_backup_location_v2 data source."
  type        = string
  default     = "eu-central-3"
}
```

`infra/modules/ionos-host/main.tf`:

```hcl
module "bootstrap" {
  source                = "../host-bootstrap"
  distro                = "ubuntu"
  environment           = var.environment
  image_repo            = var.image_repo
  admin_ssh_public_key  = var.admin_ssh_public_key
  deploy_ssh_public_key = var.deploy_ssh_public_key
  run_script            = var.run_script
}

resource "ionoscloud_datacenter" "this" {
  name     = var.name
  location = var.location
}

resource "ionoscloud_ipblock" "this" {
  name     = var.name
  location = var.location
  size     = 1
}

resource "ionoscloud_lan" "public" {
  datacenter_id = ionoscloud_datacenter.this.id
  name          = "${var.name}-public"
  public        = true
}

resource "ionoscloud_lan" "private" {
  datacenter_id = ionoscloud_datacenter.this.id
  name          = "${var.name}-private"
  public        = false
}

resource "ionoscloud_server" "this" {
  name              = var.name
  datacenter_id     = ionoscloud_datacenter.this.id
  type              = "ENTERPRISE"
  cores             = var.cores
  ram               = var.ram_mb
  availability_zone = "ZONE_1"
  image_name        = "ubuntu:latest"
  ssh_keys          = [var.admin_ssh_public_key]

  volume {
    name      = "${var.name}-system"
    size      = var.disk_gb
    disk_type = "SSD Standard"
    user_data = module.bootstrap.user_data_b64
  }

  nic {
    lan             = ionoscloud_lan.public.id
    name            = "public"
    dhcp            = true
    ips             = [ionoscloud_ipblock.this.ips[0]]
    firewall_active = true
    firewall_type   = "INGRESS"

    firewall {
      name             = "ssh"
      protocol         = "TCP"
      port_range_start = 22
      port_range_end   = 22
      source_ip        = var.ssh_allowed_cidrs[0]
    }
    firewall {
      name             = "http"
      protocol         = "TCP"
      port_range_start = 80
      port_range_end   = 80
    }
    firewall {
      name             = "https"
      protocol         = "TCP"
      port_range_start = 443
      port_range_end   = 443
    }
  }

  # cloud-init runs once. A change to it must not destroy a running host.
  lifecycle {
    ignore_changes = [ssh_keys, volume[0].user_data]
  }
}

resource "ionoscloud_nic" "private" {
  datacenter_id = ionoscloud_datacenter.this.id
  server_id     = ionoscloud_server.this.id
  lan           = ionoscloud_lan.private.id
  name          = "private"
  dhcp          = true
}

resource "ionoscloud_pg_cluster_v2" "this" {
  count = var.db_enabled ? 1 : 0

  name              = var.name
  version           = var.pg_version
  location          = var.location
  replication_mode  = "ASYNCHRONOUS"
  connection_pooler = "TRANSACTION"
  logs_enabled      = true
  metrics_enabled   = true

  backup = {
    location       = var.backup_location
    retention_days = 7
  }

  instances = {
    count        = var.environment == "prd" ? 2 : 1
    cores        = 2
    ram          = 4
    storage_size = 20
  }

  connections = {
    datacenter_id            = ionoscloud_datacenter.this.id
    lan_id                   = ionoscloud_lan.private.id
    primary_instance_address = "192.168.1.100/24"
  }

  maintenance_window = {
    time            = "03:00:00"
    day_of_the_week = "Sunday"
  }

  credentials = {
    username         = "app"
    password         = var.db_password
    password_version = var.db_password_version
    database         = "app"
  }
}
```

`infra/modules/ionos-host/outputs.tf`:

```hcl
output "ipv4" {
  value = ionoscloud_ipblock.this.ips[0]
}

output "db_dns_name" {
  value = one(ionoscloud_pg_cluster_v2.this[*].dns_name)
}
```

## The environment root

`infra/envs/dev-ionos/main.tf` — the provider block and the module call (research path; in a repository point `run_script` at `deploy/host/run.sh`):

```hcl
module "host" {
  source                = "../../modules/ionos-host"
  name                  = "shop-dev"
  environment           = "dev"
  admin_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample admin"
  deploy_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample deploy"
  image_repo            = "ghcr.io/acme/shop"
  run_script            = file("${path.module}/../../../deploy/host/run.sh")
  ssh_allowed_cidrs     = ["0.0.0.0/0"] # open default (hosted CI has no stable range); tighten to a VPN/runner range where possible
}

provider "ionoscloud" {}
```

`infra/envs/dev-ionos/versions.tf` — every root declares the full provider source itself (a root `provider "x" {}` without root `required_providers` makes OpenTofu look for `hashicorp/x`):

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

## Managed Kubernetes (not built here)

When one VM stops being enough: `ionoscloud_k8s_cluster` plus `ionoscloud_k8s_node_pool`. Verified: the resource names exist in provider 6.7. Nothing else: no example was built, so treat every attribute set as unverified until your own `tofu validate` passes against the provider docs. `k8s_version` accepts specific values from the API — list them with the API or `ionosctl`; do not guess. The Compose stack does not carry over: workloads become Deployments, Traefik becomes an ingress path, and the deploy scripts are replaced per the Kubernetes deviation in [deploy-script.md](../_shared/deploy-script.md). Graduation triggers: [hosting-decision.md](../_shared/hosting-decision.md).

## Deploy Now (static sites; no tofu)

IONOS Deploy Now hosts static sites, SPAs and PHP on IONOS shared (Apache) webspace, driven from GitHub: connect the repository, Deploy Now generates a GitHub Actions workflow that builds and uploads the site, and branches deploy to staging. No containers and no Docker; no digest promotion — the build is Deploy Now's own workflow, not the pipeline's. Prices and quotas differ across IONOS pages; read the live page before quoting either. Right for a marketing site, docs, or a SPA that talks to an API hosted elsewhere. Wrong for SSR, background jobs, anything needing the environment contract (config.env, host secrets, health-gated deploys; [environments.md](../_shared/environments.md)). Minimal steps: connect the repo in the Deploy Now dashboard, review the generated workflow, set the domain, confirm the quotas — then stop; no tofu, no deploy scripts.

## Unverified on a live contract

- No `apply` was ever run: creation order, timings and the plan output beyond `validate` are untested.
- Private-LAN DHCP: whether the second NIC gets its address without static configuration is unknown.
- DBaaS connect: `sslmode=verify-full` against `db_dns_name` with the ISRG Root X1 CA (per IONOS docs) was never executed.
- Firewall with several `source_ip` ranges (one rule per range): not tested.
- Object Storage: no bucket or access key created; conditional writes untested.
- Managed Kubernetes: resource names only.
- Deploy Now: no project built; quota and price pages disagree with each other.

## When to deviate

- **Static site:** Deploy Now (above); skip the module entirely.
- **Database elsewhere** (`database.host` is not IONOS): `db_enabled = false`; keep the private LAN only if something else needs it.
- **A customer demands synchronous replication:** `STRICTLY_SYNCHRONOUS` with `instances.count = 2`; accept that a standby outage stops writes.
- **A legacy `ionoscloud_pg_cluster` (v1) already exists:** the v1-to-v2 migration was not researched here; do not manage both in one datacenter without a written plan.
- **A `cpu_family` is unavailable in the chosen location:** change the family or the location per the live catalog, not this file.
