# Hetzner Patterns

Reference for `deploy-to-hetzner`. Every rule is a choice with a reason. The module files below were written and validated during research (`tofu fmt`, `tofu validate`, `tofu test` with `mock_provider`); they are embedded verbatim.

## Rule: one VM per environment, no sharing

**Why:** A flat monthly cost per VM and a separate failure domain beat density for a service of a few containers. One Hetzner project and token for all three environments means a leaked `dev` token deletes `prd` ([environments.md](../_shared/environments.md)).
**How to apply:** The module's `environment` variable is validated to `dev|stg|prd`, so a typo fails at plan time, not in DNS. One project per environment where the team size allows; otherwise one token per environment with `protect` on `prd`.

## Rule: Hetzner Cloud Firewall at the edge, not ufw on the host

**Why:** Docker publishes ports with its own iptables rules that bypass ufw. ufw on a Docker host gives a false sense of a firewall. Hetzner's Cloud Firewall sits outside the server, in front of Docker, so published ports cannot bypass it.
**How to apply:** The module defines one `hcloud_firewall` opening only 22, 80, 443 and icmp; everything else is dropped at the edge. Do not also install and trust ufw for the Docker ports.

## Rule: SSH is open to the world, but the key cannot open a shell

**Why:** GitHub-hosted runners have no stable egress range, so port 22 cannot be safely restricted to a CIDR without breaking CI. The mitigation is not the network; it is key-only auth plus a forced command.
**How to apply:** `sshd` drop-in sets `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers admin deploy`, `MaxAuthTries 3`. The `deploy` user's key is prefixed `restrict,command="/opt/deploy/run.sh"`, so a leaked key runs one script and nothing else. fail2ban (jail `backend = systemd`, needs `python3-systemd`) slows brute force. `ssh_allowed_cidrs` defaults to `0.0.0.0/0, ::/0` for this reason.
**How to tighten:** a self-hosted runner inside a fixed range or a VPN lets you set `ssh_allowed_cidrs` to that range and close 22 to the world. The forced command stays either way.

## Rule: a private network exists even with one VM

**Why:** A database or a second node must be able to join later without renumbering public IPs. A private network is cheap and forward-looking.
**How to apply:** The module creates a `hcloud_network` (`10.10.0.0/16`), a subnet in `network_zone = "eu-central"`, and attaches the server at `10.10.1.10`. Nothing else uses it yet; the point is that it is there.

## Rule: the primary IP outlives the server

**Why:** If DNS points at a server-assigned IP, a rebuild renumbers the public address and DNS breaks. A `hcloud_primary_ip` is a separate resource that survives the server, so the A/AAAA records stay valid across rebuilds.
**How to apply:** `auto_delete = false` and `delete_protection` on the primary IP; the server's `public_net.ipv4` references it by id.

## Rule: `/srv/data` on its own volume, not the root disk

**Why:** The root disk is where the OS and Docker live. Rebuilding the server with the same volume keeps the database; a volume also has its own backup and resize path.
**How to apply:** `hcloud_volume` (`format = "ext4"`) attached with `automount = false`; cloud-init writes an fstab line with `nofail` and runs a wait loop for the device to appear before mounting. The volume-mount timing and the device path are **unverified on a live host** — see the list below.

## Rule: delete and rebuild protection on `prd`

**Why:** `tofu destroy` or a rebuild that deletes the data volume is unrecoverable.
**How to apply:** `protect = true` sets `delete_protection`/`rebuild_protection` on the server, the primary IP and the volume for `prd`. Leave it `false` on `dev`/`stg` so they stay disposable.

## Rule: cloud-init is first-boot only; config ships through the deploy bundle

**Why:** cloud-init runs once. Editing `user_data` later would force a destroy/rebuild if tofu saw a change, which is exactly what you do not want on a live host.
**How to apply:** `lifecycle { ignore_changes = [ssh_keys, user_data] }` on the server. Ongoing config (compose files, `config.env`, the run script) ships through the deploy bundle in `deploy/`, never through cloud-init. Hardening that cloud-init does perform on first boot: `unattended-upgrades` with a reboot window at 04:30, an sshd drop-in, no password auth, `AllowUsers`, Docker from its own apt repo pinned by GPG fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, `daemon.json` with the `local` log driver and rotation, and the `deploy` user with the forced command.

## Rule: Docker packages come from Docker's apt repo, not the distro

**Why:** The Debian `docker.io` package lags and splits the engine. The Docker apt repo carries the current engine and compose plugin.
**How to apply:** cloud-init adds the `download.docker.com` apt source with the pinned key fingerprint, then installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`. Docker packages are not in `unattended-upgrades` origins by default, so schedule a manual `apt upgrade` window for the host.

## Rule: never hard-code a server type or a price

**Why:** Hetzner changed server types and prices twice in 2026 (April and June), and some shared types were listed unavailable for weeks. A hard-coded type or a quoted price is a silent defect.
**How to apply:** `server_type` is a required variable with no default; look it up with `hcloud server-type list` at scaffold time and record it. `location` is `fsn1`, `nbg1` or `hel1` for EU residency; `datacenter` is removed from the API (use `location`).

## Rule: `arch` is a variable because arm64 servers exist

**Why:** Hetzner `cax` servers are arm64; `cx`/`cpx`/`ccx` are amd64. Picking the wrong one fails at boot or runs emulated.
**How to apply:** `arch` defaults to `amd64`; set `arm64` for `cax`. Build multi-arch images (`--platform linux/amd64,linux/arm64`) so the same digest works on both ([containerize-service](../containerize-service/container-patterns.md)).

## Rule: Postgres in Compose on the volume is the default

**Why:** Hetzner has no first-party managed Postgres (none found 2026-10-09). The cheapest correct option is Postgres as a Compose service on the `/srv/data` volume.
**How to apply:** Run Postgres in the `backend` network and back it up (below). If you want a managed database, buy it from a third party or move to IONOS DBaaS ([hosting-decision.md](../_shared/hosting-decision.md)); do not pretend Hetzner sells one.

## Rule: backups go to Hetzner Object Storage over S3

**Why:** Off-host, cheap, EU-resident. Buckets and credentials are created in the Hetzner Console or via the S3 API only — there is no provider resource, so tofu cannot manage them.
**How to apply:** Create the bucket and S3 credentials once by hand, put them in `/etc/deploy/backup.env` (see [compose-patterns.md](./compose-patterns.md)). Endpoint is `<location>.your-objectstorage.com`. Conditional-write (`If-None-Match`) support for the state bucket's `use_lockfile` is **unverified** — test it before relying on it ([set-up-opentofu](../set-up-opentofu/SKILL.md)).

## Rule: graduate to k3s only on these triggers

**Why:** Kubernetes buys scheduling and resilience but adds a control plane, upgrades and on-call burden. One VM with Compose is the cheaper default for a single service.
**How to apply:** Move when one of these is true: more than one VM per environment behind a load balancer, rolling zero-downtime needs, several teams shipping independently, or node-level failure tolerance. The target is k3s `v1.37.1+k3s1`. **This skill does not build k3s**; it stops at the Compose host and points you at the decision, not the implementation.

## The modules, verbatim

`infra/modules/hetzner-host/versions.tf`:

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

`infra/modules/hetzner-host/variables.tf`:

```hcl
variable "name" {
  description = "Prefix for every resource, e.g. shop-prd."
  type        = string
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd."
  }
}

variable "location" {
  description = "Hetzner location: fsn1, nbg1 or hel1 for EU residency."
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  description = "Look up current names with `hcloud server-type list`; availability differs per location."
  type        = string
}

variable "image" {
  type    = string
  default = "debian-13"
}

variable "arch" {
  description = "amd64 for cx/cpx/ccx server types, arm64 for cax."
  type        = string
  default     = "amd64"
}

variable "volume_size_gb" {
  type    = number
  default = 20
}

variable "admin_ssh_public_key" {
  type = string
}

variable "deploy_ssh_public_key" {
  description = "Public half of the environment-scoped deploy key. The private half is a GitHub environment secret."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Who may reach port 22. GitHub-hosted runners have no stable range, so the default is open; key-only auth and a forced command carry the risk."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "image_repo" {
  description = "The only image repository the host will deploy, e.g. ghcr.io/acme/shop."
  type        = string
}

variable "protect" {
  description = "Block deletion and rebuild of the server and volume. Set true for prd."
  type        = bool
  default     = false
}

variable "run_script" {
  description = "Contents of deploy/host/run.sh (see _shared/deploy-script.md)."
  type        = string
}
```

`infra/modules/hetzner-host/main.tf`:

```hcl
locals {
  labels = {
    project     = var.name
    environment = var.environment
    managed_by  = "opentofu"
  }
}

module "bootstrap" {
  source                = "../host-bootstrap"
  distro                = "debian"
  arch                  = var.arch
  environment           = var.environment
  image_repo            = var.image_repo
  admin_ssh_public_key  = var.admin_ssh_public_key
  deploy_ssh_public_key = var.deploy_ssh_public_key
  run_script            = var.run_script
  data_device           = "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.data.id}"
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.name}-admin"
  public_key = var.admin_ssh_public_key
  labels     = local.labels
}

resource "hcloud_network" "this" {
  name     = var.name
  ip_range = "10.10.0.0/16"
  labels   = local.labels
}

resource "hcloud_network_subnet" "this" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.10.1.0/24"
}

resource "hcloud_firewall" "this" {
  name   = var.name
  labels = local.labels

  rule {
    description = "ssh"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_allowed_cidrs
  }
  rule {
    description = "http (ACME challenge and redirect)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "https"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "ping"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# A primary IP outlives the server, so DNS survives a rebuild.
resource "hcloud_primary_ip" "v4" {
  name              = "${var.name}-v4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = var.protect
  labels            = local.labels
}

resource "hcloud_volume" "data" {
  name              = "${var.name}-data"
  size              = var.volume_size_gb
  location          = var.location
  format            = "ext4"
  delete_protection = var.protect
  labels            = local.labels
}

resource "hcloud_server" "this" {
  name         = var.name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.this.id]
  labels       = local.labels

  delete_protection  = var.protect
  rebuild_protection = var.protect

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.v4.id
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.this.id
    ip         = "10.10.1.10"
  }

  user_data = module.bootstrap.user_data

  depends_on = [hcloud_network_subnet.this]

  # cloud-init runs once. A change to it must not destroy a running host.
  lifecycle {
    ignore_changes = [ssh_keys, user_data]
  }
}

resource "hcloud_volume_attachment" "data" {
  volume_id = hcloud_volume.data.id
  server_id = hcloud_server.this.id
  automount = false
}
```

`infra/modules/hetzner-host/outputs.tf`:

```hcl
output "ipv4" {
  value = hcloud_primary_ip.v4.ip_address
}

output "ipv6" {
  value = hcloud_server.this.ipv6_address
}
```

`infra/modules/host-bootstrap/variables.tf`:

```hcl
variable "distro" {
  description = "Which Docker apt repository to use."
  type        = string
  validation {
    condition     = contains(["debian", "ubuntu"], var.distro)
    error_message = "distro must be debian or ubuntu."
  }
}

variable "arch" {
  type    = string
  default = "amd64"
}

variable "environment" {
  type = string
}

variable "image_repo" {
  description = "The only image repository the host will deploy, e.g. ghcr.io/acme/shop."
  type        = string
}

variable "registry" {
  type    = string
  default = "ghcr.io"
}

variable "admin_ssh_public_key" {
  type = string
}

variable "deploy_ssh_public_key" {
  type = string
}

variable "run_script" {
  description = "Contents of deploy/host/run.sh."
  type        = string
}

variable "data_device" {
  description = "Block device for /srv/data. Empty keeps data on the root disk."
  type        = string
  default     = ""
}
```

`infra/modules/host-bootstrap/main.tf`:

```hcl
locals {
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    distro         = var.distro
    arch           = var.arch
    environment    = var.environment
    image_repo     = var.image_repo
    registry       = var.registry
    admin_key      = var.admin_ssh_public_key
    deploy_key     = var.deploy_ssh_public_key
    data_device    = var.data_device
    run_script_b64 = base64encode(var.run_script)
  })
}

output "user_data" {
  description = "cloud-config text."
  value       = local.user_data
}

output "user_data_b64" {
  description = "Same, base64 encoded, for APIs that want it (IONOS)."
  value       = base64encode(local.user_data)
}
```

`infra/modules/host-bootstrap/cloud-init.yaml.tftpl`:

```yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - fail2ban
  - python3-systemd
  - unattended-upgrades
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-compose-plugin

apt:
  sources:
    docker:
      source: "deb [arch=${arch}] https://download.docker.com/linux/${distro} $RELEASE stable"
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

users:
  - name: admin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${admin_key}
  - name: deploy
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - 'restrict,command="/opt/deploy/run.sh" ${deploy_key}'

write_files:
  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AllowUsers admin deploy
      MaxAuthTries 3
      LoginGraceTime 20
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
  - path: /etc/apt/apt.conf.d/52unattended-upgrades-local
    permissions: "0644"
    content: |
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-Time "04:30";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
  - path: /etc/fail2ban/jail.d/sshd.local
    permissions: "0644"
    content: |
      [sshd]
      enabled = true
      backend = systemd
      maxretry = 4
      findtime = 10m
      bantime = 1h
  - path: /etc/docker/daemon.json
    permissions: "0644"
    content: |
      {
        "log-driver": "local",
        "log-opts": { "max-size": "20m", "max-file": "5" },
        "live-restore": true
      }
  - path: /etc/deploy/deploy.conf
    permissions: "0644"
    content: |
      ENVIRONMENT=${environment}
      IMAGE_REPO=${image_repo}
      COMPOSE_DIR=/opt/app
      REGISTRY=${registry}
      HEALTH_TIMEOUT=120
  - path: /etc/systemd/system/app-backup.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Nightly Postgres backup to restic
      After=docker.service
      Requires=docker.service

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/bash /opt/app/bin/backup.sh
  - path: /etc/systemd/system/app-backup.timer
    permissions: "0644"
    content: |
      [Unit]
      Description=Run the nightly Postgres backup

      [Timer]
      OnCalendar=daily
      RandomizedDelaySec=15m
      Persistent=true

      [Install]
      WantedBy=timers.target
  - path: /opt/deploy/run.sh
    permissions: "0755"
    encoding: b64
    content: ${run_script_b64}

bootcmd:
  - mkdir -p /srv/data

runcmd:
%{ if data_device != "" ~}
  - [sh, -c, "echo '${data_device} /srv/data ext4 defaults,nofail 0 2' >> /etc/fstab"]
  - [sh, -c, "for i in $(seq 1 60); do [ -e ${data_device} ] && break; sleep 2; done; systemctl daemon-reload; mount /srv/data; findmnt -M /srv/data >/dev/null || { echo 'data volume failed to mount; refusing to put Postgres on the root disk' >&2; exit 1; }"]
%{ endif ~}
  - [usermod, -aG, docker, deploy]
  - [systemctl, daemon-reload]
  - [systemctl, enable, app-backup.timer]
  - [install, -d, -o, deploy, -g, deploy, -m, "0750", /opt/app]
  - [install, -d, -o, root, -g, root, -m, "0755", /opt/deploy]
  - [install, -d, -m, "0700", /srv/data/postgres]
  - [systemctl, restart, ssh]
  - [systemctl, enable, --now, fail2ban]

power_state:
  mode: reboot
  condition: true
```

## Unverified on a live host

Exercised during research (locally, not against Hetzner): the Compose stack, the deploy script, the backup and the restore drill, `tofu fmt`/`validate`/`test` of both modules, and the cloud-init YAML parse.

Not exercised, because there was no real Hetzner project:

- Server creation and the `debian-13` image name (seen in provider fixtures, not the live API).
- The Cloud Firewall's effect on Docker-published ports (the ufw-bypass rule is from Docker/Hetzner behaviour, not a live test).
- Volume-mount timing: the wait loop and the `scsi-0HC_Volume_<id>` device path.
- cloud-init running end to end on a live host (first-boot hardening, forced command, `power_state` reboot).
- ACME issuance against Let's Encrypt (only the staging CA URL is known; not run).

## When to deviate

- **One VM for all three environments** (a solo side project): keep the module contract but run a single host; the `environment` validation then names one `prd` host and you drop `dev`/`stg` deploy keys. Say in the README that isolation is by Compose project, not by account.
- **No volume** (stateless app, DB elsewhere): set `data_device` empty and skip `hcloud_volume`; keep the fstab block conditional as written.
- **A self-hosted runner or VPN** (see the SSH rule): tighten `ssh_allowed_cidrs` to that range.
- **Already on k3s or moving to it**: stop using this module's server/firewall/volume for the workload; k3s is out of scope here.
