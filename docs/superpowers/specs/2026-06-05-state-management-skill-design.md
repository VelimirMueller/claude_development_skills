# Spec: `set-up-state-management` skill

- **Date:** 2026-06-05
- **Status:** Approved — ready for planning
- **Author:** Velimir Mueller
- **Plugin:** frontendskills (`skills/frontend/`)

## 1. Goal

Add one frontend skill that wires state management into a project with a hard
boundary between **server state** (TanStack Query) and **UI state** (Zustand for
React, Pinia for Vue). The skill installs missing dependencies, wires providers,
creates canonical seams (query client, fetch wrapper, query-key factory), and
generates one worked example per layer. It teaches the boundary by showing both
layers cooperating without crossing.

The skill is audit-first and idempotent, matching every other skill in the
plugin: it inspects the project, applies only what is missing, and exits cleanly
when the project already conforms.

## 2. Context

The plugin already prepares the ground for this skill:

- `_shared/stack-versions.md` lists `tanstack/query` as a caret-versioned runtime
  dependency.
- `_shared/folder-conventions.md` names `libs/queryClient.ts` (TanStack wrapper)
  and `libs/fetcher.ts` (fetch wrapper) as canonical file locations.
- `set-up-frontend-structure/atomic-design.md` carries the rule "templates should
  not fetch (`useQuery`)".

Two gaps remain: no `stores/` convention exists (the UI-state hole), and no skill
wires TanStack Query, Zustand, or Pinia. This skill closes both.

It sits after `set-up-frontend-structure` and `configure-typescript`, and pairs
with `set-up-error-boundaries`: the documented Suspense path throws to the error
boundaries that skill installs.

## 3. Decisions

All forks below are resolved; rationale recorded for the planner.

| Decision | Choice | Rationale |
|---|---|---|
| Framework scope | Dual React + Vue | Matches the plugin's other four skills, which all branch React/Vue. |
| Skill shape | One skill | Teaches the server/UI boundary by showing both layers side by side; matches the plugin's one-concern-per-skill scale. |
| Code layout | Layer-based | Extends today's structure (`hooks/`, `libs/`, new `stores/`); low friction, internally consistent. |
| Query keys | Hand-rolled typed factory | Zero dependencies; matches the plugin's seam philosophy (cf. `error-reporter`). |
| Fetch pattern | Classic `useQuery` default | Explicit `isPending`/`isError` reads everywhere; `useSuspenseQuery` documented as the error-boundary-integrated upgrade. |
| Server state, Vue | TanStack Query Vue adapter | Keeps server state on the same library both sides; Pinia Colada noted as an alternative only. |

## 4. The architecture — the boundary

Two state systems, one rule.

| Question | Goes to |
|---|---|
| Fetched over the network / owned by a server? | **TanStack Query** |
| Derived from server data? | Derive in render or via `select` — store nothing |
| Pure client UI (toggles, selections, filters, theme, wizard step)? | **Zustand / Pinia** |

**The rule that prevents the classic bug: server data never gets copied into a
store.** Stores hold UI state only. To read server data, call the hook.

**Collaboration pattern:** UI state may *feed* a query key — an active filter
becomes part of the key — but the fetched result stays in the Query cache, never
the store. The worked example (section 8) demonstrates exactly this.

## 5. Skill structure

```
skills/frontend/set-up-state-management/
├── SKILL.md            # trigger + numbered audit→wire→verify body
├── state-boundaries.md # the rules: which state goes where, decision table, anti-patterns
├── server-state.md     # TanStack Query deep dive, React + Vue
└── ui-state.md         # Zustand + Pinia deep dive
```

**Trigger (`description` frontmatter):**

> Use when adding state management to a frontend project — wires server-state
> (TanStack Query) and UI-state (Zustand for React / Pinia for Vue) with a hard
> boundary between them, a typed query-key factory, a fetch seam, and example
> query/mutation hooks plus a small UI store.

`SKILL.md` body follows the `set-up-error-boundaries` shape: audit → decide →
detect framework → generate seams → generate examples → wire providers → verify.

## 6. Audit-first behavior

The skill detects, in order:

1. **Dependencies** — `@tanstack/react-query` or `@tanstack/vue-query`; `zustand`
   (React) or `pinia` (Vue). Install only what is missing, per
   `stack-versions.md` versioning.
2. **Prerequisites** — `@/` alias (`grep '"@/\*"' tsconfig*.json`), `src/libs/`,
   `src/hooks/` (React) or `src/composables/` (Vue). If missing, defer to
   `configure-typescript` / `set-up-frontend-structure`, or fall back and note
   the deviation.
3. **Provider wiring** — `QueryClientProvider` in `main.tsx`, or `VueQueryPlugin`
   + `createPinia()` in `main.ts`.
4. **Existing seams** — `libs/queryClient.ts`, `libs/fetcher.ts`,
   `libs/queryKeys.ts`, `src/stores/`.

Decision:

- Nothing present → full setup.
- Providers present, seams or examples missing → add only those.
- Everything present → confirm defaults (`staleTime`, devtools) and the boundary
  doc, then exit "State management already in place."

## 7. File layout (layer-based; created only if missing)

```
src/
├── libs/
│   ├── queryClient.ts   # QueryClient defaults (staleTime/gcTime/retry) [React]
│   ├── fetcher.ts       # typed fetch wrapper; throws on !ok
│   └── queryKeys.ts     # hand-rolled typed query-key factory
├── hooks/  (React) | composables/ (Vue)
│   ├── useTodos.ts      # useQuery example, keyed by filters
│   └── useCreateTodo.ts # useMutation example, invalidates via queryKeys
├── stores/              # NEW folder convention
│   └── useTodoFiltersStore.ts  # Zustand (React) / Pinia (Vue) — UI state only
└── main.tsx | main.ts   # provider wiring + devtools
```

## 8. The worked example — why these two pieces

The example is a pair that cooperates across the boundary without crossing it:
filter selection is UI state (the store); the filtered list is server state (the
Query cache). One example teaches "clear boundaries, logical abstractions" better
than two unrelated toys. Theme and sidebar are noted as other typical UI state.

The example domain is a minimal `Todo` — `{ id: string; text: string; done: boolean }` —
defined once (e.g. in `libs/queryKeys.ts` beside the filter types) and imported where
needed. Swap it for a clearer domain at implementation time.

### Query-key factory — keys live in one typed place, never inline

```ts
// src/libs/queryKeys.ts
export type TodoStatus = 'all' | 'active' | 'done';
export type TodoFilters = { status: TodoStatus };

export const queryKeys = {
  todos: {
    all: ['todos'] as const,
    list: (filters: TodoFilters) => [...queryKeys.todos.all, 'list', filters] as const,
    detail: (id: string) => [...queryKeys.todos.all, 'detail', id] as const,
  },
} as const;
```

### Fetch seam — failures become errors Query can catch

```ts
// src/libs/fetcher.ts
const BASE_URL = import.meta.env.VITE_API_URL ?? '';

export async function fetcher<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: { 'Content-Type': 'application/json', ...init?.headers },
    ...init,
  });
  if (!res.ok) throw new Error(`Request failed: ${res.status} ${res.statusText}`);
  return res.json() as Promise<T>;
}
```

## 9. Server state — TanStack Query

### React

```ts
// src/libs/queryClient.ts
import { QueryClient } from '@tanstack/react-query';

// Freshness-vs-requests dial — confirm these defaults at implementation time.
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 60_000,      // fresh for 1 min; no refetch within window
      gcTime: 5 * 60_000,     // unused cache retained 5 min
      retry: 2,
    },
  },
});
```

```tsx
// src/main.tsx — provider + dev-only devtools
import { QueryClientProvider } from '@tanstack/react-query';
import { ReactQueryDevtools } from '@tanstack/react-query-devtools';
import { queryClient } from '@/libs/queryClient';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
      {import.meta.env.DEV && <ReactQueryDevtools />}
    </QueryClientProvider>
  </StrictMode>,
);
```

```ts
// src/hooks/useTodos.ts — TanStack logic stays inside hooks
import { useQuery } from '@tanstack/react-query';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type TodoFilters } from '@/libs/queryKeys';

export function useTodos(filters: TodoFilters) {
  return useQuery({
    queryKey: queryKeys.todos.list(filters),
    queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.status}`),
  });
}
```

```ts
// src/hooks/useCreateTodo.ts — mutation invalidates via the factory
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { fetcher } from '@/libs/fetcher';
import { queryKeys } from '@/libs/queryKeys';

export function useCreateTodo() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { text: string }) =>
      fetcher<Todo>('/todos', { method: 'POST', body: JSON.stringify(input) }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: queryKeys.todos.all }),
  });
}
```

**Documented upgrade (not the default):** swap `useQuery` for `useSuspenseQuery`,
drop the `isPending`/`isError` branches, and let the component suspend and throw
to the nearest `ErrorBoundary` from `set-up-error-boundaries`. Note the
pagination caveat: wrap key changes in `startTransition` to avoid fallback
flashes.

### Vue

```ts
// src/main.ts
import { VueQueryPlugin, type VueQueryPluginOptions } from '@tanstack/vue-query';
import { createPinia } from 'pinia';

const vueQueryOptions: VueQueryPluginOptions = {
  queryClientConfig: { defaultOptions: { queries: { staleTime: 60_000, gcTime: 5 * 60_000 } } },
};
app.use(createPinia());
app.use(VueQueryPlugin, vueQueryOptions);
```

```ts
// src/composables/useTodos.ts — Vue keys must be reactive (computed)
import { useQuery } from '@tanstack/vue-query';
import { computed, type Ref } from 'vue';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type TodoFilters } from '@/libs/queryKeys';

export function useTodos(filters: Ref<TodoFilters>) {
  return useQuery({
    queryKey: computed(() => queryKeys.todos.list(filters.value)),
    queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.value.status}`),
  });
}
```

## 10. UI state — Zustand (React) / Pinia (Vue)

### React (Zustand v5)

One small store per domain. Consume with **inline selectors** — never the
auto-generated `useStore.use.x()` helper, which breaks under React Compiler.

```ts
// src/stores/useTodoFiltersStore.ts
import { create } from 'zustand';
import { devtools } from 'zustand/middleware';
import type { TodoStatus } from '@/libs/queryKeys';

type TodoFiltersState = {
  status: TodoStatus;
  setStatus: (status: TodoStatus) => void;
  reset: () => void;
};

export const useTodoFiltersStore = create<TodoFiltersState>()(
  devtools(
    (set) => ({
      status: 'all',
      setStatus: (status) => set({ status }, false, 'setStatus'),
      reset: () => set({ status: 'all' }, false, 'reset'),
    }),
    { name: 'todo-filters' },
  ),
);
```

```ts
// Consuming: one value via inline selector; many via useShallow.
const status = useTodoFiltersStore((s) => s.status);
const { status, setStatus } = useTodoFiltersStore(
  useShallow((s) => ({ status: s.status, setStatus: s.setStatus })),
);
```

`ui-state.md` documents the slices pattern (`StateCreator`) for when a single
store grows, and `persist` for stores that must survive reload — neither is the
default.

### Vue (Pinia setup-store)

Setup-store style maps 1:1 onto Zustand's functional shape. One store per file.

```ts
// src/stores/useTodoFiltersStore.ts
import { defineStore } from 'pinia';
import { ref } from 'vue';
import type { TodoStatus } from '@/libs/queryKeys';

export const useTodoFiltersStore = defineStore('todoFilters', () => {
  const status = ref<TodoStatus>('all');
  function setStatus(next: TodoStatus) { status.value = next; }
  function reset() { status.value = 'all'; }
  return { status, setStatus, reset };
});
```

```ts
// Consuming: storeToRefs keeps state reactive; actions destructure directly.
const store = useTodoFiltersStore();
const { status } = storeToRefs(store);
const { setStatus, reset } = store;
```

`pinia-plugin-persistedstate` is documented as the persistence option, not the
default.

## 11. Reference docs — content outline

Each reference uses the plugin's `## Rule: … / **Why:** / **How to apply:** /
**Anti-example:**` format with a closing **When to deviate** section.

**`state-boundaries.md`**
- Rule: server data never lives in a store.
- Rule: derive from server data in render or via `select`; never duplicate.
- Rule: UI state may feed a query key; the result stays in the cache.
- The decision table from section 4.
- Anti-examples: copying `data` into a store; a `useEffect` that mirrors a query
  into Zustand; storing a derived count.

**`server-state.md`**
- Rule: all TanStack calls live inside hooks/composables (no `useQuery` in
  components, templates, or pages — extends the existing atomic-design rule).
- Rule: query keys come from the factory, never inline arrays.
- Rule: mutations invalidate via the factory's broadest matching key.
- `staleTime`/`gcTime` rationale; the freshness-vs-requests trade-off.
- Suspense variant and the `set-up-error-boundaries` integration; pagination
  `startTransition` caveat.
- Vue specifics: reactive (`computed`) query keys.

**`ui-state.md`**
- Rule: one small store per domain; no mega-store.
- Rule: inline selectors only; `useShallow` for multiple values; no codegen
  selectors (React Compiler compatibility).
- Slices pattern for growth; `persist`/persistedstate for durability; `devtools`
  naming.
- Pinia setup-store style and `storeToRefs`.

## 12. Shared-file updates

These touch existing `_shared/` files and are approved as part of this skill.

- **`stack-versions.md`** — add `zustand`, `pinia`, and `@tanstack/vue-query` to
  the caret-versioned runtime-dependency rule (TanStack Query React is already
  listed).
- **`folder-conventions.md`** — add **Rule: `stores/` holds UI-state stores
  (Zustand/Pinia); one small store per domain, named `use<Domain>Store`.**
- **`glossary.md`** — add **Server state** and **Client / UI state** definitions,
  each with the "test" question the other entries use.

**Companion change, flagged not bundled:** `set-up-frontend-structure` should
later scaffold an empty `src/stores/` with a `.gitkeep` and barrel, so fresh
projects include it. Tracked as a follow-up, outside this skill's scope.

## 13. Verification

- `pnpm tsc --noEmit` → 0 errors (examples and seams compile).
- TanStack and store devtools render in dev.
- Playwright e2e deferred to `configure-test-stack`, matching the
  `set-up-error-boundaries` precedent. Until then, type-check is the gate.

## 14. Out of scope

- Server-side rendering / Next.js per-request query clients (this plugin targets
  Vite SPAs; document the SSR client pattern only if an SSR skill lands).
- Optimistic updates beyond a documented note.
- An ESLint rule enforcing the boundary (possible future `configure-lint` skill).
- Pinia Colada and other non-TanStack server-state libraries (noted, not used).

## 15. Open values to confirm at implementation

- `staleTime` / `gcTime` / `retry` defaults, and whether to set
  `refetchOnWindowFocus: false` to favour fewer requests.
- Example domain: `todos` assumed; swap if a different domain reads more clearly.

## 16. 2026 best-practice notes

- React Compiler is GA and the de-facto default; it auto-memoizes rendering, so
  the skill teaches no `useMemo`/`useCallback` ceremony. It does **not** replace
  Zustand selectors, which control store *subscription*, a separate axis. Inline
  selectors are correct with or without the compiler, so the skill need not
  detect it.
- `useSuspenseQuery` is the idiomatic Suspense default; React 19's `use()` is for
  conditional/loop/RSC-promise cases only — out of scope here.
- The query-key factory is a named TanStack best practice; the hand-rolled
  version captures it without a dependency.
- Pinia setup-stores are the current recommended style and map cleanly onto
  Zustand.

**Sources:** [zustand#2562 — compiler + selectors](https://github.com/pmndrs/zustand/discussions/2562) ·
[TanStack Suspense docs](https://tanstack.com/query/latest/docs/framework/react/guides/suspense) ·
[query-key-factory](https://github.com/lukemorales/query-key-factory) ·
[Pinia core concepts](https://pinia.vuejs.org/core-concepts/)
