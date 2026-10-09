# Vercel Patterns

Reference for `deploy-to-vercel`. Every rule is a choice with a reason. Verified against the Vercel docs read 2026-10-09 and a typechecked `vercel.ts` (`@vercel/config` 0.12.0, TypeScript 6.0.3); nothing here was run against a Vercel account.

## Rule: one config file, and choose the format by what it must do

**Why:** Vercel supports `vercel.json`, `vercel.toml` and `vercel.ts` (also `.js`/`.mjs`/`.cjs`/`.mts`), and only one may exist per project. Two files produce ambiguity about which one wins.

**How to apply:** `vercel.json` (with `$schema`) for static config — it is static, schema-validated and needs no dependency or build step. `vercel.ts` only when the config needs build-time logic (imports, computed values), using `@vercel/config` (0.12.0, pre-1.0) with `import { routes, type VercelConfig } from '@vercel/config/v1'` and `export const config: VercelConfig`. `vercel.toml` exists but offers no reason to prefer it.

**Anti-example:** A `vercel.json` and a `vercel.ts` both checked in, or a `vercel.ts` that only restates static fields.

## Rule: Fluid compute is the default; set `maxDuration` per function, not globally

**Why:** Fluid compute has been the default for new projects since 2025-04-23, across Node, Python, Edge, Bun and Rust. The default duration is 300 s; Pro and Enterprise cap at 800 s (Hobby stays 300), and 1800 s is in beta. A single long default for the whole project burns budget on functions that finish in milliseconds.

**How to apply:** Set `maxDuration` per function glob in `functions`, e.g. `'app/api/**/*': { maxDuration: 30 }`. Use `waitUntil` for background work after the response is sent (the docs name it; no code shown here because the exact signature was not verified).

**Anti-example:** A catch-all `maxDuration: 300` under `functions` that lets an accidentally-hanging route bill for five minutes.

## Rule: put the function region next to the database

**Why:** A function in one region calling a database in another adds latency to every query. The default for new projects is `iad1`, a US region, which is wrong for an EU database.

**How to apply:** Set `regions: ['fra1']` for EU data. Hobby allows one region; Pro allows several (the docs disagree between 3 and 5 — check the plan); failover regions are Enterprise-only. Per-function `regions` is available for a specific hot path. A Supabase database region must match: pick the same EU region for both at creation, since a Supabase region cannot be moved later.

**Anti-example:** Leaving the default `iad1` for a project whose Supabase Postgres is in `eu-central-1`, adding a transatlantic round trip to every query.

## Rule: env vars are per environment and either Config or Secret

**Why:** The same variable differs across Production, Preview, Development and custom environments, and a secret in the wrong type leaks into the dashboard or the bundle.

**How to apply:** The CLI distinguishes Config (visible, not encrypted) from Secret (`--type config|secret`, or `--sensitive`/`--no-sensitive`). Defaults: Production, Preview and custom environments default to Secret; Development defaults to Config. Secrets are allowed in Development now. Changes apply to NEW deployments only; a change is not picked up by an old deployment. Each environment's total env is capped at 64 KB. `vercel env pull [file]` (default `.env`) merges remote env into the local file, keeps local-only keys, and includes the `VERCEL_OIDC_TOKEN` variable; pass `--environment=preview --git-branch=x` for a per-branch override. `vercel env run -- <cmd>` runs a command with the env without writing a file. Prefer leaving `--value` off so the CLI prompts: a secret passed with `--value` lands in shell history. Enable the team policy "Separate Production Secret Values". Never commit `.env*`.

**Anti-example:** `vercel env add DATABASE_URL production --value "postgres://…"` then finding the connection string in `~/.zsh_history`.

## Rule: OIDC federation is for Vercel calling the cloud, not for CLI auth

**Why:** The two are often confused, but they solve different problems. OIDC lets a build or function prove it is your Vercel project to AWS, GCP, Azure or your own API, with no long-lived cloud key. CI auth to Vercel itself stays a token.

**How to apply:** Use the team issuer `https://oidc.vercel.com/<team>` (recommended), read `VERCEL_OIDC_TOKEN` in builds, the `x-vercel-oidc-token` header in functions, or the `@vercel/oidc` helper. It covers Vercel → cloud only. For CI, keep `VERCEL_TOKEN` as a `prd`-environment secret; OIDC does not replace it.

**Anti-example:** Putting a Vercel OIDC token in the GitHub workflow and expecting `vercel deploy` to authenticate with it.

## Rule: crons are best-effort; protect them and make them idempotent

**Why:** Vercel GETs the production deployment on the schedule, in UTC, with no retries, and may fire more than once ("best-effort, possible duplicates"). Unauthenticated, the route is an open endpoint that runs your job.

**How to apply:** Declare `crons: [{ path, schedule }]`. Require the `CRON_SECRET`, which Vercel sends as `Authorization: Bearer`, and return 401 when it is missing or mismatched (see the SKILL step 5). Make the handler idempotent. Remember: Hobby runs crons once per day at hour-level precision; 100 crons per project; production deployment only; cron config reverts on Instant Rollback; `vercel dev` does not support them.

**Anti-example:** A cron route with no auth check: a public GET is enough to trigger the job.

## Rule: protect previews with Standard Protection, keep production public

**Why:** Every pull request gets a public preview URL from the Git integration. Leaked, that URL exposes half-built features and the API.

**How to apply:** Set Deployment Protection to Standard Protection (the recommended default) on all but production domains, which stays public. Add Vercel Authentication when only team members should see a preview. Use the Protection Bypass for Automation (`VERCEL_AUTOMATION_BYPASS_SECRET`) for health checks and e2e against protected previews. Password protection costs extra on Pro. When you need a stable URL for self-calls, migrate off `VERCEL_URL` (unverified that it is deprecated; the docs pushed off it).

**Anti-example:** An e2e suite that curls the preview URL and 401s, then gets "fixed" by turning protection off for the whole project.

## Rule: rolling releases move traffic in stages; promote is not the tool

**Why:** A rolling release sends a percentage of traffic to the new deployment before it is fully live, with Skew Protection keeping one user on one version. `vercel promote` makes the deployment live instantly, which defeats the point.

**How to apply:** Rolling Releases are on Pro (one project) and Enterprise. Configure the stages in project settings (last stage 100%) and enable Skew Protection with it. From CI, call the idempotent REST start endpoint via `vercel rolling-release start` and finish with `vercel rolling-release complete`. Abort by Instant Rollback. The force cookies `vcrrForceCanary` and `vcrrForceStable` pin a visitor to a stage, and anyone can set them, so they are a debug tool, not a gate.

**Anti-example:** Calling `vercel promote` to "start" a rolling release, so 100% of traffic jumps to the new build at once.

## Rule: Instant Rollback reverts code and config, not env vars

**Why:** Knowing what a rollback does and does not touch is what makes it safe to press during an incident.

**How to apply:** Instant Rollback redeploys the previous production deployment. It reverts code and cron config, but environment variables do NOT revert. Auto-assign of production domains stays off until you run `vercel promote <url>`, which is also how you undo a mistaken promotion.

**Anti-example:** Assuming a rollback also restores the old `DATABASE_URL`, then finding the service pointing at the new one.

## Rule: firewall blocks traffic; BotID blocks bots on specific routes

**Why:** DDoS mitigation and WAF are on all plans, and a bot that bypasses the UI still hits your API. BotID is an invisible CAPTCHA that tells you whether a request came from a bot.

**How to apply:** Add custom firewall rules for IP blocking and rate limiting (rate-limit plan details unverified). For BotID, protect specific routes, not the whole site: initialize the client with the exact routes, check on the server, and wrap with the framework helper.

```ts
// client
import { initBotId } from 'botid';
initBotId({ protect: [{ path: '/checkout', method: 'POST' }] });
```

```ts
// server
import { checkBotId } from 'botid/server';
const { isBot } = await checkBotId(request);   // true when the visitor is a bot
```

```ts
// Next.js — wrap the config (exact import specifier unverified)
import { withBotId } from 'botid';
export default withBotId(nextConfig);
```

Basic BotID is free on all plans; Deep Analysis is paid on Pro. In local development BotID always returns `isBot` false, so a local run cannot be mistaken for a bot.

**Anti-example:** `initBotId({ protect: [{ path: '/', method: 'GET' }] })` — CAPTCHA-ing the whole site, or trusting local dev to return a real verdict.

## Rule: prebuilt deploys lose system env vars; use `--archive=tgz`

**Why:** With `vercel deploy --prebuilt`, the build already happened, so Vercel system environment variables are missing at build time. An unverified archive format is the other common failure.

**How to apply:** In the full-CI mode (`git.deploymentEnabled: false`), run `vercel pull --yes --environment=production`, `vercel build --prod`, then `vercel deploy --prebuilt --prod --archive=tgz` with `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`. For custom environments, use `vercel pull --environment=<name>`, `vercel build --target=<name>`, and `vercel deploy --prebuilt --target=<name>`.

**Anti-example:** `vercel deploy --prebuilt` with the archive passed as a directory or an unverified format, or forgetting that production env vars were not inlined at build.

## Rule: Vercel has no digest to promote

**Why:** The container track promotes one immutable `image@sha256:…` across environments. Vercel builds in its own pipeline, so there is no digest to compare; "promote" moves a specific deployment between slots without rebuilding.

**How to apply:** Treat the pipeline's build-once rule as "build once per environment, promote the deployment", not "one digest everywhere". The exception is documented in [environments.md](../_shared/environments.md): promoting a staged production build does not rebuild, but there is no digest to verify. Build once per environment, because Vercel embeds environment variables at build time.

**Anti-example:** Building once for `stg` and "promoting the same artifact" to `prd`, which rebuilds with production env anyway, so the tested binary is not what ships.

## Rule: `fra1` puts compute in the EU; data residency is per product

**Why:** The default `iad1` is US compute. Vercel is a US company under the EU-US Data Privacy Framework and relies on Standard Contractual Clauses; the pages read did not state that every product stores data only in the EU.

**How to apply:** Set `regions: ['fra1']` for EU compute. Persistent data location varies per product — confirm in writing with Vercel before relying on EU storage. Whether a US parent company is acceptable is a legal decision for your data, recorded in the README, not in this skill ([hosting-decision.md](../_shared/hosting-decision.md)).

**Anti-example:** Assuming all Vercel products (KV, Postgres, Blob) store data in `fra1` because the functions run there.

## Rule: Hobby is non-commercial; a product needs Pro

**Why:** Hobby is restricted to non-commercial use by Vercel's fair-use guidelines. Cost is near zero at low traffic and rises with it (per seat plus usage: function time, bandwidth), unlike a flat VM.

**How to apply:** A company product goes on Pro before traffic. The full cost-shape comparison is in [hosting-decision.md](../_shared/hosting-decision.md).

**Anti-example:** Launching a customer product on Hobby and getting rate-limited or suspended at the first real traffic spike.

## When to deviate

- **Netlify or another host is the standard:** use [hosting-decision.md](../_shared/hosting-decision.md) and the host's own skill; the `configure-ci` preview step covers Netlify.
- **A monorepo with several projects:** one `vercel.json` (or `vercel.ts`) per project, each linked separately; a single config file per project still holds.
- **Long-running jobs or a worker** that outlive the 300 s default (or 800 s on Pro, 1800 s beta): move them to Vercel Workflows or a container host, not a function with a huge `maxDuration`.
