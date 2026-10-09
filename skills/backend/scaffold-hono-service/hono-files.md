# Hono Service: File Contents

Canonical contents for [SKILL.md](SKILL.md). Every file here ran clean on 2026-10-09 (`tsc --noEmit`, `biome check`, `vitest run`, `tsdown`, a live `curl` and SIGTERM check) against the lines in [stack-versions.md](../_shared/stack-versions.md). Adapt names (`notes`, `svc`); keep the structure. The `notes` module is a worked example of the layering: delete it once a real module exists.

## `tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2023"],
    "types": ["node"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,
    "verbatimModuleSyntax": true,
    "erasableSyntaxOnly": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "allowImportingTsExtensions": true,
    "noEmit": true,
    "rootDir": "."
  },
  "include": ["src", "tests", "scripts", "*.config.ts"]
}
```

## `biome.json`

```json
{
  "$schema": "./node_modules/@biomejs/biome/configuration_schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "formatter": { "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
  "javascript": { "formatter": { "quoteStyle": "single" } },
  "linter": { "enabled": true, "rules": { "preset": "recommended" } }
}
```

## `tsdown.config.ts`

```ts
import { defineConfig } from 'tsdown';

export default defineConfig({
  entry: ['src/main.ts'],
  platform: 'node',
  target: 'node24',
  clean: true,
  sourcemap: true,
});
```

## `vitest.config.ts`

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { include: ['tests/**/*.test.ts'], environment: 'node' },
});
```

## `.env.example`

```bash
# Copy to .env for local dev. Never commit .env.
DEPLOYMENT_ENVIRONMENT=development
OTEL_SERVICE_NAME=svc
PORT=3000
LOG_LEVEL=info
SHUTDOWN_TIMEOUT_MS=10000
# DATABASE_URL=postgres://user:password@localhost:5432/app
```

## `.gitignore`

```gitignore
node_modules
dist
.env
```

## `src/config.ts`

```ts
import { z } from 'zod';

const schema = z.object({
  DEPLOYMENT_ENVIRONMENT: z.enum(['development', 'staging', 'production']).default('development'),
  OTEL_SERVICE_NAME: z.string().min(1).default('svc'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
  SHUTDOWN_TIMEOUT_MS: z.coerce.number().int().positive().default(10_000),
  // Add required secrets here without a default, e.g. DATABASE_URL: z.url()
});

export type Config = z.infer<typeof schema>;

/** Parse once at startup. Throws with every invalid key; never prints values. */
export function loadConfig(source: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(source);
  if (!parsed.success) {
    const keys = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('\n  ');
    throw new Error(`Invalid configuration:\n  ${keys}`);
  }
  return parsed.data;
}
```

## `src/platform/logger.ts`

```ts
import { type Logger, pino } from 'pino';
import type { Config } from '../config.ts';

export type { Logger };

export type LoggerConfig = Pick<
  Config,
  'LOG_LEVEL' | 'OTEL_SERVICE_NAME' | 'DEPLOYMENT_ENVIRONMENT'
>;

/** Log shape follows core/_shared/logging-contract.md: JSON lines to stdout, fixed field names. */
export function createLogger(config: LoggerConfig): Logger {
  return pino({
    level: config.LOG_LEVEL,
    base: {
      'service.name': config.OTEL_SERVICE_NAME,
      'deployment.environment.name': config.DEPLOYMENT_ENVIRONMENT,
    },
    timestamp: () => `,"timestamp":"${new Date().toISOString()}"`,
    messageKey: 'message',
    formatters: { level: (label) => ({ level: label }) },
    redact: {
      paths: [
        'req.headers.authorization',
        'req.headers.cookie',
        '*.password',
        '*.token',
        '*.api_key',
      ],
      censor: '[redacted]',
    },
  });
}
```

## `src/platform/clock.ts`

```ts
export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };
```

## `src/platform/problem.ts`

```ts
import { z } from '@hono/zod-openapi';

/** RFC 9457 problem details. */
export const problemSchema = z
  .object({
    type: z.string().default('about:blank'),
    title: z.string(),
    status: z.number().int(),
    detail: z.string().optional(),
    instance: z.string().optional(),
  })
  .loose()
  .openapi('Problem');

export type Problem = z.infer<typeof problemSchema>;

export const PROBLEM_CONTENT_TYPE = 'application/problem+json';

/** Domain error the service layer throws. No HTTP types: `status` is a plain number. */
export class AppError extends Error {
  readonly status: number;
  readonly title: string;
  readonly type: string;
  constructor(status: number, title: string, options: { type?: string; detail?: string } = {}) {
    super(options.detail ?? title);
    this.name = 'AppError';
    this.status = status;
    this.title = title;
    this.type = options.type ?? 'about:blank';
  }
}

export const notFound = (detail: string) => new AppError(404, 'Not Found', { detail });
```

## `src/repository/notes.repository.ts`

```ts
export interface Note {
  id: string;
  body: string;
}

/** The only layer that talks to storage. Swap the in-memory map for SQL here. */
export interface NotesRepository {
  findById(id: string): Promise<Note | undefined>;
}

export function createInMemoryNotesRepository(seed: Note[] = []): NotesRepository {
  const rows = new Map(seed.map((n) => [n.id, n]));
  return { findById: async (id) => rows.get(id) };
}
```

## `src/service/notes.service.ts`

```ts
import { notFound } from '../platform/problem.ts';
import type { Note, NotesRepository } from '../repository/notes.repository.ts';

export interface NotesService {
  get(id: string): Promise<Note>;
}

/** Use cases. No Hono, no Request/Response: callable from a job or a test as-is. */
export function createNotesService(deps: { notes: NotesRepository }): NotesService {
  return {
    async get(id) {
      const note = await deps.notes.findById(id);
      if (!note) throw notFound(`Note ${id} does not exist`);
      return note;
    },
  };
}
```

## `src/transport/health.routes.ts`

```ts
import { createRoute, OpenAPIHono, z } from '@hono/zod-openapi';

export type ReadinessCheck = { name: string; check: () => Promise<void> };

const statusSchema = z.object({ status: z.enum(['ok', 'unavailable']) });
const body = { 'application/json': { schema: statusSchema } };

const live = createRoute({
  method: 'get',
  path: '/healthz',
  tags: ['ops'],
  responses: { 200: { description: 'Process is up', content: body } },
});

const ready = createRoute({
  method: 'get',
  path: '/readyz',
  tags: ['ops'],
  responses: {
    200: { description: 'Dependencies reachable', content: body },
    503: { description: 'A dependency is down or the process is draining', content: body },
  },
});

/** `/healthz` never touches dependencies (liveness). `/readyz` checks them (readiness). */
export function healthRoutes(checks: ReadinessCheck[], isShuttingDown: () => boolean) {
  return new OpenAPIHono()
    .openapi(live, (c) => c.json({ status: 'ok' as const }, 200))
    .openapi(ready, async (c) => {
      if (isShuttingDown()) return c.json({ status: 'unavailable' as const }, 503);
      const results = await Promise.allSettled(checks.map((x) => x.check()));
      const ok = results.every((r) => r.status === 'fulfilled');
      return ok
        ? c.json({ status: 'ok' as const }, 200)
        : c.json({ status: 'unavailable' as const }, 503);
    });
}
```

## `src/transport/notes.routes.ts`

```ts
import { createRoute, OpenAPIHono, z } from '@hono/zod-openapi';
import { PROBLEM_CONTENT_TYPE, problemSchema } from '../platform/problem.ts';
import type { NotesService } from '../service/notes.service.ts';

const noteSchema = z.object({ id: z.string(), body: z.string() }).openapi('Note');

const getNote = createRoute({
  method: 'get',
  path: '/notes/{id}',
  tags: ['notes'],
  request: { params: z.object({ id: z.string().min(1) }) },
  responses: {
    200: { description: 'The note', content: { 'application/json': { schema: noteSchema } } },
    404: {
      description: 'No such note',
      content: { [PROBLEM_CONTENT_TYPE]: { schema: problemSchema } },
    },
  },
});

/** Transport: validate input, call one service method, shape the response. */
export function notesRoutes(service: NotesService) {
  return new OpenAPIHono().openapi(getNote, async (c) => {
    const { id } = c.req.valid('param');
    return c.json(await service.get(id), 200);
  });
}
```

## `src/app.ts`

```ts
import { OpenAPIHono } from '@hono/zod-openapi';
import type { Context } from 'hono';
import type { Logger } from './platform/logger.ts';
import { AppError, PROBLEM_CONTENT_TYPE, type Problem } from './platform/problem.ts';
import type { NotesService } from './service/notes.service.ts';
import { healthRoutes, type ReadinessCheck } from './transport/health.routes.ts';
import { notesRoutes } from './transport/notes.routes.ts';

export interface AppDeps {
  logger: Logger;
  notes: NotesService;
  readinessChecks: ReadinessCheck[];
  isShuttingDown: () => boolean;
}

function problem(c: Context, p: Problem) {
  return c.newResponse(JSON.stringify(p), p.status as 400, {
    'Content-Type': PROBLEM_CONTENT_TYPE,
  });
}

export function createApp(deps: AppDeps) {
  const app = new OpenAPIHono({
    // Validation failures become 400 problem+json instead of Zod's default shape.
    defaultHook: (result, c) => {
      if (!result.success) {
        return problem(c, {
          type: 'about:blank',
          title: 'Bad Request',
          status: 400,
          detail: 'Request validation failed',
          instance: c.req.path,
          errors: result.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
        });
      }
    },
  });

  app.route('/', healthRoutes(deps.readinessChecks, deps.isShuttingDown));
  app.route('/', notesRoutes(deps.notes));

  app.doc31('/openapi.json', { openapi: '3.1.0', info: { title: 'svc', version: '0.1.0' } });

  app.notFound((c) =>
    problem(c, { type: 'about:blank', title: 'Not Found', status: 404, instance: c.req.path }),
  );

  app.onError((err, c) => {
    if (err instanceof AppError) {
      return problem(c, {
        type: err.type,
        title: err.title,
        status: err.status,
        detail: err.message,
        instance: c.req.path,
      });
    }
    // Unknown error: log it once with its cause, tell the client nothing internal.
    deps.logger.error({ err, 'url.path': c.req.path }, 'unhandled error');
    return problem(c, {
      type: 'about:blank',
      title: 'Internal Server Error',
      status: 500,
      instance: c.req.path,
    });
  });

  return app;
}
```

## `src/main.ts`

```ts
import { serve } from '@hono/node-server';
import { createApp } from './app.ts';
import { loadConfig } from './config.ts';
import { createLogger } from './platform/logger.ts';
import { createInMemoryNotesRepository } from './repository/notes.repository.ts';
import { createNotesService } from './service/notes.service.ts';

const config = loadConfig();
const logger = createLogger(config);

let shuttingDown = false;
const app = createApp({
  logger,
  notes: createNotesService({
    notes: createInMemoryNotesRepository([{ id: '1', body: 'hello' }]),
  }),
  readinessChecks: [], // push { name: 'db', check: () => db.ping() } here
  isShuttingDown: () => shuttingDown,
});

const server = serve({ fetch: app.fetch, port: config.PORT }, (info) => {
  logger.info({ port: info.port }, 'listening');
});

function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true; // /readyz now answers 503
  logger.info({ signal }, 'shutting down');
  const force = setTimeout(() => {
    logger.error('shutdown timed out, forcing exit');
    process.exit(1);
  }, config.SHUTDOWN_TIMEOUT_MS);
  force.unref();
  // Stops accepting, closes idle keep-alive sockets, waits for in-flight requests.
  server.close((err) => {
    // Close pools and flush telemetry here, after the server has drained.
    process.exit(err ? 1 : 0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
```

## `scripts/print-openapi.ts`

```ts
// Committed as the API contract; CI fails if it is stale (regenerate + `git diff --exit-code openapi.json`).
import { createApp } from '../src/app.ts';
import { createLogger } from '../src/platform/logger.ts';
import { createInMemoryNotesRepository } from '../src/repository/notes.repository.ts';
import { createNotesService } from '../src/service/notes.service.ts';

const app = createApp({
  logger: createLogger({
    LOG_LEVEL: 'silent',
    OTEL_SERVICE_NAME: 'svc',
    DEPLOYMENT_ENVIRONMENT: 'development',
  }),
  notes: createNotesService({ notes: createInMemoryNotesRepository() }),
  readinessChecks: [],
  isShuttingDown: () => false,
});
const res = await app.request('/openapi.json');
process.stdout.write(`${JSON.stringify(await res.json(), null, 2)}\n`);
```

## `tests/app.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app.ts';
import { createLogger } from '../src/platform/logger.ts';
import { createInMemoryNotesRepository } from '../src/repository/notes.repository.ts';
import { createNotesService } from '../src/service/notes.service.ts';

function build({ down = false } = {}) {
  return createApp({
    logger: createLogger({
      LOG_LEVEL: 'silent',
      OTEL_SERVICE_NAME: 'test',
      DEPLOYMENT_ENVIRONMENT: 'development',
    }),
    notes: createNotesService({ notes: createInMemoryNotesRepository([{ id: '1', body: 'hi' }]) }),
    readinessChecks: down ? [{ name: 'db', check: () => Promise.reject(new Error('down')) }] : [],
    isShuttingDown: () => false,
  });
}

describe('http', () => {
  it('reports liveness', async () => {
    expect((await build().request('/healthz')).status).toBe(200);
  });

  it('reports 503 when a dependency is down', async () => {
    expect((await build({ down: true }).request('/readyz')).status).toBe(503);
  });

  it('returns problem+json for a missing note', async () => {
    const res = await build().request('/notes/nope');
    expect(res.status).toBe(404);
    expect(res.headers.get('content-type')).toContain('application/problem+json');
    expect(await res.json()).toMatchObject({ title: 'Not Found', status: 404 });
  });

  it('returns the note', async () => {
    const res = await build().request('/notes/1');
    expect(await res.json()).toEqual({ id: '1', body: 'hi' });
  });

  it('serves OpenAPI 3.1 generated from the route schemas', async () => {
    const doc = (await (await build().request('/openapi.json')).json()) as {
      openapi: string;
      paths: Record<string, unknown>;
    };
    expect(doc.openapi).toBe('3.1.0');
    expect(doc.paths['/notes/{id}']).toBeDefined();
  });
});
```
