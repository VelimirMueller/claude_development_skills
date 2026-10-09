# Hosting Decision

Which host, and why. Read the stack profile first: `hosting:` and `database.host:` in `.claude/stack-profile.md` already answer this for most repositories. Use this file when the profile is empty or the question is "should we move".

## Decision table

| Situation | Host | Why |
|---|---|---|
| Frontend or full-stack Next.js/Nuxt, short functions, small team, nobody on call for servers | **Vercel** (+ Supabase or another managed Postgres) | No servers to patch. Preview per pull request, instant rollback, firewall in front. You pay per usage and per seat |
| Containers, steady traffic, one or few services, cost matters, EU residency matters | **Hetzner** (VM + Compose + Traefik) | Flat monthly cost per VM. German company, EU locations. You own patching, backups and restores |
| German or EU contract, support SLA, BSI or customer demands a German provider, you need managed Postgres or managed Kubernetes | **IONOS** (VM or Cube + DBaaS Postgres, or Managed Kubernetes) | Managed database with backups, point-in-time restore and failover. Contract and invoicing in Germany. Smaller ecosystem and fewer tutorials than Hetzner |
| App is mostly auth, Postgres, storage and realtime; little custom server code | **Supabase** (managed) | Auth, database, storage and realtime in one product. Pair it with Vercel or a container host for custom code |
| Static site, no server code | **Vercel**, Netlify, or **IONOS Deploy Now** | Cheapest and lowest effort. See `deploy-to-ionos` for when Deploy Now fits |
| Many services, autoscaling, several teams | Managed Kubernetes (IONOS) or k3s on Hetzner | Only after one VM stops being enough. See "graduate" in [deploy-to-hetzner](../deploy-to-hetzner/SKILL.md) |

If the profile says `hosting: [vercel]` and `database.host: supabase`, stop here: use [deploy-to-vercel](../deploy-to-vercel/SKILL.md). Do not re-open the question inside a task.

## The three axes

### Cost shape
- **Vercel and Supabase** charge per seat plus usage (function time, bandwidth, database compute). Cost is near zero at low traffic and rises with it. Hobby is restricted to non-commercial use (Vercel fair-use guidelines): a company product needs Pro.
- **Hetzner and IONOS VMs** charge a flat rate per server. Cost is flat until the VM is full, then steps up.
- **Prices moved in 2026.** Hetzner raised cloud prices in April and again in June, and some shared types were listed as unavailable for weeks. Read the live price page and `hcloud server-type list` before quoting a number. Do not copy a number from this file.
- Count your hours too. A VM saves money only while nobody spends a day a month on patching, backups and restore drills. Managed services buy those hours back.

### GDPR and EU residency
- **Hetzner and IONOS** are German companies. Hetzner locations `fsn1`, `nbg1`, `hel1` are in Germany and Finland; IONOS has Frankfurt, Berlin, Logroño, Paris and others. Data stays in the EU when you choose an EU location, and no US parent company is involved.
- **Vercel** is a US company, certified under the EU-US Data Privacy Framework, and relies on Standard Contractual Clauses. Functions run where you set `regions` (use `fra1`; the default for new projects is `iad1` in the US). Vercel did not state in the pages read that every product stores data only in the EU. Ask in writing before you rely on it.
- **Supabase** is a US company with selectable regions. Choose an EU region when you create the project; it cannot be moved without a migration.
- Whether a US parent company is acceptable is a legal question about your data and your customers. Record the answer in the project README. Do not decide it in a skill.

### Ops burden
| Host | You run |
|---|---|
| Vercel | Config, env vars, domains. No servers |
| Supabase | Schema, RLS policies, backups you test. No servers |
| IONOS DBaaS | The app VM or cluster. Not the database server, patches or replication |
| IONOS Managed K8s | Workloads. Not the control plane |
| Hetzner VM | OS patching, Docker, Postgres, backups, restore drills, disk space, certificates |

Hetzner has no managed Postgres in the sources read (2026-10-09). If you want one there, you buy it from a third party or run it yourself.

## Rule: pick the least ops that meets the residency and cost constraints
**Why:** Operations work does not ship features. Each step down the table (Vercel, Supabase or IONOS DBaaS, a VM with your own database) adds toil. Take the step only for a reason you can write down: cost, residency, a contract.
**How to apply:** Start at the top row that satisfies the hard constraints (EU-only provider, price ceiling). Write the reason into the stack profile notes. Revisit on a trigger, not on a feeling.
**Anti-example:** Running Kubernetes for one service because "we might scale".

## Rule: keep the database near the code, and the code behind a seam
**Why:** A function in Frankfurt calling a database in Virginia adds a transatlantic round trip to every query. A move between hosts is cheap only when the host-specific code sits in one place.
**How to apply:** Put the function region, the database region and the user base in the same geography. Keep host-specific files (`vercel.json`, `compose.yaml`, tofu modules) out of application code. The app reads `DATABASE_URL` and nothing else about its host.

## Rule: pairs that work, and one that needs care
| Pair | Notes |
|---|---|
| Vercel + Supabase (EU region) | Default pairing. Use the pooled connection string from serverless functions. Functions in `fra1` |
| Hetzner VM + Postgres in Compose | Cheapest. Backups to object storage and a restore drill are mandatory (see `deploy-to-hetzner`) |
| IONOS VM + DBaaS Postgres | The database is reachable on a private LAN only, so the app must run in the same IONOS datacenter |
| Vercel + Hetzner or IONOS database | Works over the public internet with TLS. Latency and egress cost apply. Restrict by credentials; Vercel has no stable egress IP without a paid add-on (unverified) |

**Why:** The pair decides latency, egress and who can reach the database.
**How to apply:** Pick the pair first, then the region for both.

## Triggers to move
- A VM runs above 70% CPU or memory for a week and the next size costs more than the managed alternative: move up or move to managed.
- A second engineer is on call for the host more than one day per month: take a managed database or move the app to Vercel.
- A customer contract requires a German provider or a certificate: move to IONOS or Hetzner.
- Function bills exceed the price of a VM for the same load for three months: move the container track to Hetzner or IONOS.
- You need more than one VM per environment behind a load balancer: graduate to k3s or Managed Kubernetes.

## When to deviate
- A company standard names the host. Follow it and record the reason in the stack notes.
- A prototype: use the host that needs no setup (Vercel or Supabase) and move later. The seam rule keeps the move cheap.
- A team with a platform group: use their cluster and skip this table.
