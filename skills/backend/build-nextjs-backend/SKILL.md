---
name: build-nextjs-backend
description: Use when building or reviewing the server side of a Next.js 16 App Router app — a server-only data access layer that authorizes every call, Server Actions as public endpoints, route handlers, caching with Cache Components, proxy.ts, env validation and error boundaries.
---

# Build a Next.js Backend

Next.js is the backend here: Server Components read, Server Actions write, route handlers serve webhooks and external clients. The rule that organizes everything: **authorization lives next to the data, in a `server-only` layer, and runs on every call.** Pages, actions and `proxy.ts` do not carry it.

## 1. Audit current state

Read `.claude/stack-profile.md` (`frontend.meta: next`, `backend.track`, `database`, `hosting`). Then:

```bash
grep -n '"next"\|"react"\|"typescript"' package.json; ls middleware.ts src/middleware.ts proxy.ts src/proxy.ts 2>/dev/null
grep -n "cacheComponents\|partialPrefetching\|allowedOrigins" next.config.*
grep -rln "'use server'\|\"use server\"" src | xargs -I{} sh -c 'echo "== {}"; grep -c "getViewer\|requireViewer\|auth()" {}'   # actions with 0 = no auth check
grep -rn "process.env" src --include=*.ts --include=*.tsx | grep -v "src/libs/env\|src/server/env"                  # raw env reads
grep -rn "from '@supabase/supabase-js'\|createClient(" src | grep -v "src/libs/supabase"                           # clients outside the seam
grep -rLn "server-only" src/server 2>/dev/null; ls src/server src/features/*/actions.ts 2>/dev/null
grep -rn "export const \(dynamic\|revalidate\|fetchCache\|runtime\)" src/app                                      # segment configs
```

Findings to report: `middleware.ts` (renamed `proxy.ts` in 16), actions without an auth check, DB or SDK access inside components, whole DB rows passed to client components, raw `process.env`, `revalidateTag(tag)` with one argument.

## 2. Decide what to do

- No DAL (data calls in pages or components) → create `src/server/` (steps 5–6) and move calls one route at a time.
- Actions exist without validation or an auth check → step 5 "actions" first; it is the exposed surface.
- Next ≤ 15 → upgrade first (`proxy.ts` is never called on 15; Node 20.9+, TypeScript 5.1+).
- Everything present, `pnpm build` passes → "already in place".

## 3. Detect the data source and caching model

| Signal | Branch |
|---|---|
| `backend.track: supabase` / `@supabase/ssr` | Request-scoped Supabase client in the DAL; RLS is the real check ([secure-supabase-rls](../secure-supabase-rls/SKILL.md)) |
| Drizzle / SQL client | The DAL takes the viewer and filters every query by it; there is no RLS to catch a mistake |
| `cacheComponents: true` | `'use cache'`, `cacheLife`, `cacheTag`, Suspense for request data ([nextjs-caching-patterns.md](./nextjs-caching-patterns.md)) |
| flag absent | Previous model (`fetch` cache options, segment configs). New apps from `create-next-app` have Cache Components on; enable it deliberately in an existing app |

Versions: [stack-versions.md](../_shared/stack-versions.md).

## 4. Install only what's missing

```bash
pnpm add server-only zod        # server-only: Next resolves it itself; install it so lint and tools see it
```

For Supabase: [set-up-supabase](../set-up-supabase/SKILL.md) and [set-up-nextjs-supabase-auth](../set-up-nextjs-supabase-auth/SKILL.md) provide `src/libs/supabase/*` and `src/server/auth.ts` (`getViewer`, `requireViewer`).

## 5. Generate the seams

Layout (matches the folder standard): `src/server/` server-only code, `src/features/<domain>/actions.ts` thin `'use server'` files, `src/app/` routing files only.

```
src/server/env.ts            # secrets, server-only
src/libs/env.client.ts       # NEXT_PUBLIC_* only
src/server/auth.ts           # getViewer / requireViewer
src/server/data/<domain>.ts  # DAL: authorize, query, return DTOs
src/features/<domain>/actions.ts
src/app/api/webhooks/<provider>/route.ts
```

**Env** — parse once, fail at boot. Client values are read as literal `process.env.NEXT_PUBLIC_X` (Next inlines only literal reads); server secrets live in a `server-only` module. Code: [nextjs-backend-patterns.md](./nextjs-backend-patterns.md), "Env".

**DAL** — every exported function authorizes first and returns a DTO, never a raw row:

```ts
// src/server/data/notes.ts
import 'server-only';
import { notFound } from 'next/navigation';
import { createClient } from '@/libs/supabase/server';
import type { Tables } from '@/libs/supabase/database.types';
import { requireViewer } from '@/server/auth';

export type NoteDTO = { id: string; body: string; createdAt: string };

const toDTO = (row: Pick<Tables<'notes'>, 'id' | 'body' | 'created_at'>): NoteDTO => ({
  id: row.id, body: row.body, createdAt: row.created_at,
});

export async function getNote(id: string): Promise<NoteDTO> {
  await requireViewer();
  const supabase = await createClient();
  const { data, error } = await supabase.from('notes').select('id, body, created_at').eq('id', id).maybeSingle();
  if (error) throw new Error(`getNote failed: ${error.code}`);
  if (!data) notFound(); // RLS hides other users' rows: "not yours" and "not there" look the same
  return toDTO(data);
}
```

**Server Action** — a public POST endpoint. Authenticate, validate, authorize (the DAL does), act, return a typed result:

```ts
// src/features/notes/actions.ts
'use server';
import { refresh } from 'next/cache';
import { unstable_rethrow } from 'next/navigation';
import { z } from 'zod';
import type { ActionResult } from '@/libs/action-result';
import { getViewer } from '@/server/auth';
import { createNote, type NoteDTO } from '@/server/data/notes';

const CreateNote = z.object({ body: z.string().trim().min(1).max(2000) });

export async function createNoteAction(_previous: ActionResult<NoteDTO> | null, formData: FormData): Promise<ActionResult<NoteDTO>> {
  if (!(await getViewer())) return { ok: false, code: 'unauthenticated' };
  const parsed = CreateNote.safeParse({ body: formData.get('body') });
  if (!parsed.success) return { ok: false, code: 'invalid', fieldErrors: z.flattenError(parsed.error).fieldErrors };
  try {
    const note = await createNote(parsed.data);
    refresh(); // per-user data is not cached on the server; re-render the current route
    return { ok: true, data: note };
  } catch (error) {
    unstable_rethrow(error); // let redirect() and notFound() through
    return { ok: false, code: 'failed' };
  }
}
```

`ActionResult` (`src/libs/action-result.ts`), the form component with `useActionState`, the webhook route handler, and the error boundaries: [nextjs-backend-patterns.md](./nextjs-backend-patterns.md).

## 6. Wire

- `next.config.ts`: `cacheComponents: true, partialPrefetching: true` for new code; add `experimental.serverActions.allowedOrigins` only when a reverse proxy forwards a different host; raise `bodySizeLimit` (default 1 MB) only for upload actions.
- `src/proxy.ts` (same level as `app/`): session refresh and coarse redirects only; Node runtime; no data fetching ([set-up-nextjs-supabase-auth](../set-up-nextjs-supabase-auth/SKILL.md)). Rename `middleware.ts` to `proxy.ts` and the export to `proxy`.
- Pages that read request data (`cookies()`, `headers()`, `searchParams`, `params`) wrap that component in `<Suspense>`; the DAL's `getViewer()` reads cookies, so the same applies.
- Self-hosting several instances: set `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (`openssl rand -base64 32`) so every instance shares one key.
- CI: `next build` prerenders cached pages, so a page reading Supabase through `'use cache'` needs the API reachable at build (the local stack in CI, or the staging project).

## 7. Verify

`typecheck` is `tsc --noEmit` in a Next.js app (one tsconfig); add `"typecheck": "tsc --noEmit"` to package.json if it is missing.

```bash
pnpm typecheck
pnpm build                       # Cache Components errors name the exact uncached read or missing <Suspense>
pnpm build && grep -rEl "sb_secret_|SUPABASE_SECRET_KEY" .next/static   # prints nothing
```

Then four checks by hand or test: an anonymous request to a protected route redirects; calling a DAL function with no session redirects or throws; a webhook with a bad signature returns 400 and with a good one 200; importing `@/libs/supabase/admin` from a `'use client'` file fails the build.

## References
- [nextjs-backend-patterns.md](./nextjs-backend-patterns.md) — DAL, actions, route handlers, env, errors, proxy rules with code.
- [nextjs-caching-patterns.md](./nextjs-caching-patterns.md) — Cache Components: `use cache`, `cacheLife`, `cacheTag`, `updateTag`, `revalidateTag`.
- [../../frontend/_shared/framework-idioms.md](../../frontend/_shared/framework-idioms.md) — React 19 idioms the client side follows.
- [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md) — rules 3 and 4.
