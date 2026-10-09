---
name: scaffold-hono-service
description: Use when starting a TypeScript HTTP API or adding a service to a repo with no Hono app yet — scaffolds a strict-TS Hono service with validated config, problem+json errors, OpenAPI from route schemas, health/readiness and graceful shutdown, runnable on Node.
---

# Scaffold Hono Service

Layering, seams and rationale: [hono-patterns.md](hono-patterns.md). Full file contents: [hono-files.md](hono-files.md). Shared standards: [service-layout.md](../_shared/service-layout.md), [config.md](../_shared/config.md), [stack-versions.md](../_shared/stack-versions.md).

## 1. Audit (change nothing)

```bash
cat .claude/stack-profile.md ~/.claude/stack-profile.md 2>/dev/null   # profile: backend.track, package_manager, tests.layout, hosting, database, observability
ls package.json tsconfig.json biome.json pnpm-workspace.yaml src/app.ts src/main.ts src/config.ts 2>/dev/null
ls pnpm-lock.yaml package-lock.json bun.lock yarn.lock 2>/dev/null
grep -E '"(hono|express|fastify|@nestjs/core|next)"' package.json 2>/dev/null
```

Read the profile first; detect only what it leaves open (merge rules: [stack-profile.md](../../core/_shared/stack-profile.md)).
- `backend.track` is set and is not `hono`: stop. Say which track the profile names and suggest the matching scaffold skill, or `set-up-stack-profile` if the profile is wrong.
- `backend.track` is unset, and `express`, `fastify` or `@nestjs/core` is present: ask one question ("add a Hono service next to it, or migrate?"). Otherwise do not ask.

## 2. Decide

- No `hono` dependency and no `src/app.ts`: full scaffold (steps 3 to 7).
- `hono` present: diff against [hono-files.md](hono-files.md) and add only what is missing (config, problem+json handler, readiness, shutdown, OpenAPI, tests). Never overwrite a file you did not create: show the delta and apply it by hand.
- Everything present and step 7 passes: report "already in place" and stop.

## 3. Detect track

| Question | Source | Default |
|---|---|---|
| Package manager | `package_manager` in the profile, else the lockfile | `pnpm` |
| Where does it live | `pnpm-workspace.yaml` or `workspaces` present: `apps/<svc>` or `services/<svc>`; else the repo root | repo root |
| Test layout | `tests.layout` | `tests-dir`: `tests/`. `colocated`: `src/**/*.test.ts` and `include: ['src/**/*.test.ts']` in `vitest.config.ts` |
| Runtime target | `hosting` | Node. `vercel`, Cloudflare, Bun: see step 6 |
| Database | `database.orm` | none yet. `drizzle`: add the DB seam via the Drizzle skill of this catalogue, then a readiness check |
| Observability | `observability.otel` | `true`: start the SDK before the logger is created ([observability.md](../../core/_shared/observability.md)) |
| Runtime pin | `runtime_manager` | `.nvmrc` with `24`, plus `engines.node` |

## 4. Install only what is missing

```bash
pnpm add hono @hono/node-server @hono/zod-openapi zod pino
pnpm add -D -E @biomejs/biome
pnpm add -D typescript@~7.0 tsx tsdown vitest @types/node@^24
```

Replace `pnpm add` with the profile's manager. Check each line against [stack-versions.md](../_shared/stack-versions.md) and `npm view <pkg> version`. `@hono/zod-openapi` requires `zod` 4; do not install Zod 3.

## 5. Generate the seams

Create the files from [hono-files.md](hono-files.md), skipping any that exist:

```
src/config.ts                       validated env, parsed once
src/platform/{logger,clock,problem}.ts
src/repository/*.repository.ts      the only layer that touches storage
src/service/*.service.ts            use cases, no Hono types
src/transport/*.routes.ts           createRoute + handlers
src/app.ts                          createApp(deps): routes, OpenAPI, notFound, onError
src/main.ts                         composition root, serve(), graceful shutdown
tests/app.test.ts                   app.request(), no port
tsconfig.json biome.json tsdown.config.ts vitest.config.ts .env.example .gitignore
```

Rename `notes` to the first real module, or keep it as the worked example until one exists.

## 6. Wire

`package.json`:

```json
{
  "type": "module",
  "engines": { "node": ">=24.0.0" },
  "scripts": {
    "dev": "tsx watch --env-file-if-exists=.env src/main.ts",
    "build": "tsdown",
    "start": "node dist/main.mjs",
    "typecheck": "tsc --noEmit",
    "lint": "biome check .",
    "format": "biome check --write .",
    "test": "vitest run",
    "openapi": "tsx scripts/print-openapi.ts > openapi.json"
  }
}
```

- `task_runner` is `just` or `mise`: expose the same names as recipes or tasks instead of duplicating logic.
- Readiness: push one `{ name, check }` per dependency into `readinessChecks` in `main.ts`. Liveness stays dependency-free.
- Shutdown: add pool close and telemetry flush inside the `server.close` callback, in that order.
- Other runtimes: keep `createApp`; replace `main.ts` with the platform entry. Vercel and Cloudflare: `export default createApp(deps)` in the entry file the platform names (Vercel: `src/index.ts`). Bun: `export default { port, fetch: app.fetch }`. There is no long-lived process on serverless, so drop the shutdown code and build `deps` per isolate. Details: [hono-patterns.md](hono-patterns.md#rule-the-app-is-a-fetch-handler-the-server-is-an-adapter).
- pnpm 12 reports `ERR_PNPM_IGNORED_BUILDS` if a dependency has a build script. The scaffold has none; do not approve builds you did not review.
- CI, Docker and deploy are out of scope here; the `devcore` and `infraskills` plugins own them.

## 7. Verify

```bash
pnpm typecheck && pnpm lint && pnpm test      # expect: no tsc output, "No fixes applied", "5 passed"
pnpm build && PORT=3111 node dist/main.mjs &  # expect a JSON line with "message":"listening"
curl -si localhost:3111/notes/nope            # expect 404 and content-type: application/problem+json
curl -s localhost:3111/readyz                 # expect {"status":"ok"}
curl -s localhost:3111/openapi.json | head -c 80   # expect {"openapi":"3.1.0",...
PORT=abc node dist/main.mjs                   # expect a thrown "Invalid configuration" listing PORT, exit 1
kill -TERM %1                                 # expect "shutting down" in the log, exit code 0
```

A second run of this skill finds everything in place and changes nothing.

## References

- [hono-patterns.md](hono-patterns.md): why each choice, when to deviate.
- [hono-files.md](hono-files.md): the files.
- [service-layout.md](../_shared/service-layout.md), [config.md](../_shared/config.md): the cross-language standards.
- [logging-contract.md](../../core/_shared/logging-contract.md), [security-baseline.md](../../core/_shared/security-baseline.md).
