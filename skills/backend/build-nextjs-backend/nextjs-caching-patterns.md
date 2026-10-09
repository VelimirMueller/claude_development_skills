# Next.js Caching Patterns

Reference for `build-nextjs-backend`. Cache Components model, Next.js 16.4 docs (Caching, `use cache`, `cacheLife`, `cacheTag`, `updateTag`, `revalidateTag`, Migrating to Cache Components) checked 2026-10-09. The build output quoted here comes from a real `next build` on 16.4.0.

## Rule: everything is dynamic until you cache it on purpose
**Why:** Cache Components inverts the old model: data fetching runs at request time unless a `'use cache'` scope gives the result a lifetime. Next prerenders a static shell from static and cached parts and streams the rest behind `<Suspense>`. Nothing is cached by accident, and nothing stale ships by default.
**How to apply:** `next.config.ts` gets `cacheComponents: true` and `partialPrefetching: true`. Set `partialPrefetching` explicitly: leaving it unset logs a warning, and Next says both features become the default in the next major and the options go away. `create-next-app` already writes both. Route segment configs (`dynamic`, `revalidate`, `fetchCache`) error once the flag is on: delete them and use `use cache` plus Suspense. Cache Components needs the Node.js runtime.
**When it fails:** the dev overlay and `next build` report a "blocking route" for an uncached read or runtime API with no `<Suspense>` above it, and name the fix.

## Rule: cache what everyone sees; never cache per-user data under a shared key
**Why:** A `use cache` scope cannot read `cookies()` or `headers()`, anywhere in its call stack (error `next-request-in-use-cache`). That is the design: a cached result may be served to any request with the same key, and the key is made of arguments and captured variables. User-specific data belongs to the request, not to a shared cache. Supabase's session client reads cookies, so it cannot run inside one; the admin client could, and would then serve one user's rows to the next caller if a key were wrong.
**How to apply:** Public, shared data → `'use cache'` with the cookie-less client (`createStaticClient`, anon role, RLS decides what is public). Per-user data → no `use cache`; render it behind `<Suspense>` through the DAL.

```ts
// src/server/data/posts.ts
import 'server-only';
import { cacheLife, cacheTag } from 'next/cache';
import { createStaticClient } from '@/libs/supabase/static';

export type PostDTO = { id: string; title: string; slug: string };

/** Public data, the same for everyone: cached for an hour, invalidated by the 'posts' tag. */
export async function listPublishedPosts(): Promise<PostDTO[]> {
  'use cache';
  cacheLife('hours');
  cacheTag('posts');

  const { data, error } = await createStaticClient()
    .from('posts')
    .select('id, title, slug')
    .eq('published', true)
    .order('title');
  if (error) throw new Error(`listPublishedPosts failed: ${error.code}`);
  return data;
}
```

Build output with this page and a per-user `/notes` page: `/` is static with `Revalidate 1h, Expire 1d`; `/notes` is `Partial Prerender` (static shell, user content streamed). Return values must be serializable: plain objects and arrays, dates, maps and sets; no class instances, no functions.
**Anti-example:** `'use cache'` on `getCurrentUser()` or on a function that takes the viewer's access token as an argument: the token becomes part of a shared cache key and the data outlives the session.

## Rule: give every `use cache` an explicit `cacheLife` and a `cacheTag`
**Why:** Without `cacheLife` the `default` profile applies silently (5-minute client stale time, 15-minute revalidate, never expires), which hides the choice at the call site. A tag is the handle for on-demand invalidation; without one, only a deploy or the lifetime refreshes the entry.
**How to apply:** Pick the profile by how often the content changes:

| Profile | Stale (client) | Revalidate | Expire |
|---|---|---|---|
| `seconds` | 30 s | 1 s | 1 min |
| `minutes` | 5 min | 1 min | 1 hour |
| `hours` | 5 min | 1 hour | 1 day |
| `days` | 5 min | 1 day | 1 week |
| `weeks` | 5 min | 1 week | 30 days |
| `max` | 5 min | 30 days | 1 year |

Tag names are case-sensitive, at most 256 characters; a longer tag is never assigned and revalidating it does nothing. Name tags by entity (`posts`, `post-<id>`).

## Rule: pick the invalidation by who needs to see the change
**Why:** Three calls look alike and behave differently. `updateTag` expires the entry so the next request waits for fresh data: right when the user just made the change and must see it. `revalidateTag(tag, 'max')` marks it stale and serves the old value while a refresh runs in the background: right for changes from elsewhere (a webhook, another user). `refresh()` re-renders the current route for data that is not in the cache.
**How to apply:**

| Situation | Call | Where |
|---|---|---|
| The user edits public content and returns to a page showing it | `updateTag('posts')` | Server Action only |
| A webhook or admin job changed shared content | `revalidateTag('posts', 'max')` | Server Action or route handler |
| The user changed their own uncached data | `refresh()` | Server Action only |
| A whole path changed | `revalidatePath('/posts')` | Server Action or route handler |

`revalidateTag(tag)` with one argument is deprecated (it behaves like `{ expire: 0 }`); `revalidateTag` cannot run in Client Components or `proxy.ts`. A revalidation is triggered by the next request, not by the call. Call these as the last step of the success path, after the write succeeded.
**Anti-example:** `revalidateTag('posts')` in a webhook: deprecated signature, and the next visitor waits for a blocking refetch.

## Rule: read request data behind Suspense, as low in the tree as possible
**Why:** `cookies()`, `headers()`, `params` and `searchParams` exist only at request time, so a component that reads them cannot be part of the static shell. Without a boundary the whole route waits for the request; reading the session at the top of a layout holds every child behind it.
**How to apply:** Wrap the component that calls `getViewer()` (or reads params) in `<Suspense fallback={…}>`; keep headers, nav and cached lists outside it. Share the viewer by calling `getViewer()` again (`React.cache` dedupes it per request) rather than passing it down. Migrating a route you cannot fix yet: `export const instant = false` lets it keep blocking while the rest moves.

## Rule: a cached scope may receive values you read outside it — not secrets you then cache
**Why:** Next's supported pattern for runtime data is to read it outside and pass it in as an argument, which makes it part of the key. For a Supabase app that fits ids and filters (`categoryId`), not tokens or whole viewers. `'use cache: private'` exists for session-derived values that must be read inside the scope; it keeps the result in the browser only, never on the server, and is a rare, deliberate choice.
**How to apply:** Default to no server caching for per-user reads. If a per-user query is slow, index it (see [rls-patterns.md](../secure-supabase-rls/rls-patterns.md)) before caching it.

## Rule: build-time caching needs the data source at build time
**Why:** Prerendering executes cached functions during `next build` to fill the static shell. A page whose cached function calls Supabase fails the build when the API is unreachable (run: `listPublishedPosts failed` aborted the build until a stub answered). Cache entries also do not carry over to a new deploy, because the key includes the build or deployment ID; with the default in-memory handler on serverless hosting, runtime entries often do not persist between requests.
**How to apply:** CI builds against the local stack (`supabase start`) or the staging project. Public data that must exist at build time must also be seeded there. For persistence between requests or deploys use `'use cache: remote'` with a platform cache handler (it costs a network round trip and usually platform fees), or the `fetch` cache.

## Rule: route handlers follow the same model for `GET`
**Why:** With the flag on, a `GET` handler that touches no request data or non-deterministic call is prerendered at build time. A handler you expect to run per request must read request data or use `POST`.
**How to apply:** Webhooks and mutations are `POST`; read-only public JSON can be `GET` with `use cache` inside it. Do not read cookies in a `GET` handler and expect it to be cached.

## When to deviate
- **No Cache Components (flag off, older app):** the previous model applies (`fetch` cache options, `unstable_cache`, segment configs). `unstable_cache` keeps working with the flag on; migrate it later, not in the same change.
- **Mostly-static marketing site on Next:** cache more aggressively (`days`/`max` with tags from the CMS webhook) and keep the Supabase session out of those routes.
- **Multi-instance self-hosting:** configure a shared cache handler, or entries differ per instance.
- **A per-user hot read:** `'use cache: private'` or a materialised table, chosen by measurement, never by guess.
