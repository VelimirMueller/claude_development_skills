# Set Up State Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author one audit-first frontend skill, `set-up-state-management`, that wires TanStack Query (server state) and Zustand/Pinia (UI state) with a hard boundary between them.

**Architecture:** Create a skill folder (`SKILL.md` + three reference docs) and make three `_shared/` updates. The `SKILL.md` follows the `set-up-error-boundaries` shape: audit → decide → detect framework → install → seams → examples → wire providers → verify. The three references hold the deep-dive rules. Reference files are created before `SKILL.md` so its relative links resolve.

**Tech Stack:** TanStack Query v5 (`@tanstack/react-query` + `@tanstack/vue-query`), Zustand v5, Pinia (setup-stores), TypeScript, markdown skill authoring.

**Verification model:** This is a skills repo, not an app. The standing test is `bash scripts/validate.sh` (manifest, SKILL.md frontmatter, relative-link resolution). Each task verifies with `validate.sh` plus `grep` checks that required sections exist. Code snippets are verified by review against the spec (`docs/superpowers/specs/2026-06-05-state-management-skill-design.md`), which was checked against authoritative docs; `pnpm tsc --noEmit` inside snippets runs only in consuming projects.

**Spec:** `docs/superpowers/specs/2026-06-05-state-management-skill-design.md`

---

## File Structure

**Modify (existing `_shared/` files):**
- `skills/frontend/_shared/stack-versions.md` — add `zustand`, `pinia`, `@tanstack/vue-query` to the runtime-dep rule.
- `skills/frontend/_shared/folder-conventions.md` — add the `stores/` folder rule.
- `skills/frontend/_shared/glossary.md` — add "Server state" and "Client / UI state" entries.

**Create (new skill folder `skills/frontend/set-up-state-management/`):**
- `state-boundaries.md` — the boundary rules (most important reference).
- `server-state.md` — TanStack Query patterns, React + Vue.
- `ui-state.md` — Zustand + Pinia patterns.
- `SKILL.md` — trigger + numbered body (created last so links resolve).

**Ordering rationale:** `_shared` edits first (independent, low-risk). Then the three references. Then `SKILL.md` last — `validate.sh` fails if `SKILL.md` links to a reference file that does not yet exist.

---

## Task 1: Add state libraries to the version policy

**Files:**
- Modify: `skills/frontend/_shared/stack-versions.md:16`

- [ ] **Step 1: Make the edit**

Replace the runtime-dep bullet (currently line 16):

```
- `react`, `vue`, `tanstack/query`, etc. → `^X.Y.Z`
```

with:

```
- `react`, `vue`, `@tanstack/react-query`, `@tanstack/vue-query`, `zustand`, `pinia`, etc. → `^X.Y.Z`
```

- [ ] **Step 2: Verify content and validator**

Run: `grep -n "zustand" skills/frontend/_shared/stack-versions.md && bash scripts/validate.sh`
Expected: the grep prints the updated line; validator ends with `OK: validator passed`.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/_shared/stack-versions.md
git commit -m "docs(shared): add zustand, pinia, vue-query to version policy"
```

---

## Task 2: Add the `stores/` folder convention

**Files:**
- Modify: `skills/frontend/_shared/folder-conventions.md` (insert after the `libs/` vs `utils/` rule, before the barrel rule at line 46)

- [ ] **Step 1: Insert the new rule**

After the `utils/clsx.ts` bullet (line 44) and its blank line, immediately before the barrel rule (the `## Rule: barrel ...` heading, line 46), insert:

```markdown
## Rule: `stores/` holds UI-state stores; one small store per domain
**Why:** UI state (toggles, selections, filters, theme) is separate from server state, which lives in the TanStack Query cache, not a store. A dedicated folder keeps that boundary visible. One store per domain limits re-render scope and keeps each store readable.
**How to apply:**
- React → `src/stores/use<Domain>Store.ts` (Zustand). Example: `useTodoFiltersStore.ts`.
- Vue → `src/stores/use<Domain>Store.ts` (Pinia, setup-store style).
- Server data never goes in a store. See the `set-up-state-management` skill, ref `state-boundaries.md`.

```

- [ ] **Step 2: Verify content and validator**

Run: `grep -n "stores/ holds UI-state" skills/frontend/_shared/folder-conventions.md && bash scripts/validate.sh`
Expected: grep prints the new heading line; validator passes.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/_shared/folder-conventions.md
git commit -m "docs(shared): add stores/ folder convention for UI state"
```

---

## Task 3: Add glossary entries for server vs UI state

**Files:**
- Modify: `skills/frontend/_shared/glossary.md` (insert after the "Component-level vs page-level boundary" section, before `## Audit-first`)

- [ ] **Step 1: Insert the two entries**

Before `## Audit-first`, insert:

```markdown
## Server state
State owned by a server and fetched over the network — lists, entities, anything with a canonical copy elsewhere. Managed by TanStack Query, which caches, deduplicates, refetches, and invalidates it.

**Test:** could a server change this value without the user touching the UI? If yes, it's server state.

## Client / UI state
Ephemeral, client-only state with no server copy — toggles, selections, active filters, theme, wizard step. Managed by Zustand (React) or Pinia (Vue).

**Test:** does it exist only because of what the user is doing in the browser right now? If yes, it's UI state.

```

- [ ] **Step 2: Verify content and validator**

Run: `grep -nE "^## (Server state|Client / UI state)" skills/frontend/_shared/glossary.md && bash scripts/validate.sh`
Expected: grep prints both headings; validator passes.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/_shared/glossary.md
git commit -m "docs(shared): add server/UI state glossary entries"
```

---

## Task 4: Create the `state-boundaries.md` reference

**Files:**
- Create: `skills/frontend/set-up-state-management/state-boundaries.md`

- [ ] **Step 1: Write the file**

````markdown
# State Boundaries

Reference for `set-up-state-management`. The rules that keep server state and UI state from bleeding into each other. This is the most important file in the skill — the libraries are easy; the boundary is what teams get wrong.

## The decision

| Question | Goes to |
|---|---|
| Fetched over the network / owned by a server? | TanStack Query |
| Derived from server data? | Derive in render or via `select` — store nothing |
| Pure client UI (toggles, selections, filters, theme, wizard step)? | Zustand / Pinia |

## Rule: server data never lives in a store
**Why:** TanStack Query already caches, deduplicates, refetches, and invalidates server data. Copy that data into Zustand/Pinia and you re-own all of it by hand — the exact problem the query cache exists to remove. The two systems then fight over which copy is current.
**How to apply:** Components read server data only through a query hook (`useTodos()`), never from a store. Stores hold UI state only.

**Anti-example:**
```ts
// bad: mirroring a query result into a store
const { data } = useTodos(filters);
useEffect(() => {
  useTodoStore.getState().setTodos(data ?? []); // now two sources of truth
}, [data]);
```

## Rule: derive from server data, never duplicate it
**Why:** Derived values (counts, filtered subsets, sums) recompute for free from the cached source. Storing them creates a second value that drifts.
**How to apply:** Compute in render, or with TanStack Query's `select` option to keep the derivation memoized inside the cache.

```ts
// good: derive with select; the cache stays the single source
const doneCount = useTodos(filters, {
  select: (todos) => todos.filter((t) => t.done).length,
});
```

**Anti-example:**
```ts
// bad: a stored count that must be kept in sync forever
useUiStore.setState({ doneCount: todos.filter((t) => t.done).length });
```

## Rule: UI state may feed a query key; the result stays in the cache
**Why:** This is how the two layers cooperate without crossing. The active filter is UI state (a store); the data for that filter is server state (the cache). The filter flows *into* the key; the data never flows *back* into the store.
**How to apply:**
```ts
const status = useTodoFiltersStore((s) => s.status); // UI state
const todos = useTodos({ status });                  // keyed by it; result cached
```

## When to deviate

- **Form state:** in-progress form fields are UI state, but a form library (React Hook Form, VeeValidate) usually serves better than a store. Use a store only for cross-component form state, such as a multi-step wizard.
- **Static server data** fetched once at boot (feature flags, config) can stay in the query cache with `staleTime: Infinity` rather than a store — still no copying.
````

- [ ] **Step 2: Verify content and validator**

Run: `grep -cE "^## Rule:" skills/frontend/set-up-state-management/state-boundaries.md && bash scripts/validate.sh`
Expected: grep prints `3` (three rules); validator passes.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/set-up-state-management/state-boundaries.md
git commit -m "feat(skill): add state-boundaries reference"
```

---

## Task 5: Create the `server-state.md` reference

**Files:**
- Create: `skills/frontend/set-up-state-management/server-state.md`

- [ ] **Step 1: Write the file**

````markdown
# Server State — TanStack Query

Reference for `set-up-state-management`. Patterns for the server-state half, React and Vue. The React adapter is `@tanstack/react-query`; the Vue adapter is `@tanstack/vue-query`. The query cache is the single source of truth for anything owned by a server.

## Rule: every TanStack call lives inside a hook (React) or composable (Vue)
**Why:** Keeps `useQuery`/`useMutation` out of components, templates, and pages, so call sites read as plain data access and each query's config has one home. Extends the atomic-design rule "templates should not fetch".
**How to apply:** `useTodos()` wraps `useQuery`; components call `useTodos()`.

**Anti-example:**
```tsx
// bad: useQuery inline in a component
function TodoList() {
  const { data } = useQuery({ queryKey: ['todos'], queryFn: fetchTodos }); // move to a hook
}
```

## Rule: query keys come from the factory, never inline arrays
**Why:** A typed factory makes every key consistent and every invalidation precise. Inline arrays drift (`['todos']` here, `['todo']` there) and silently miss cache entries on invalidation.
**How to apply:** Import `queryKeys` from `@/libs/queryKeys`. Build hierarchical keys: `queryKeys.todos.all` → `queryKeys.todos.list(filters)`.

**Anti-example:**
```ts
// bad: inline key that won't match the factory's invalidations
useQuery({ queryKey: ['todos', status], queryFn });
```

## Rule: mutations invalidate via the broadest matching factory key
**Why:** `invalidateQueries({ queryKey: queryKeys.todos.all })` refetches every todo query — all filters and details — in one call, because TanStack matches keys by prefix. A narrow key leaves stale sibling caches.
**How to apply:**
```ts
onSettled: () => queryClient.invalidateQueries({ queryKey: queryKeys.todos.all }),
```

## Rule: set sensible client defaults; tune the freshness-vs-requests dial
**Why:** `staleTime` controls how long data stays fresh (no refetch); `gcTime` controls how long unused cache is retained. Higher `staleTime` means fewer requests and staler data. The library default `staleTime: 0` refetches aggressively.
**How to apply:** Start at `staleTime: 60_000`, `gcTime: 5 * 60_000`, `retry: 2`. Raise `staleTime` for rarely-changing data. Set `refetchOnWindowFocus: false` to favour fewer requests over focus-freshness.

## The Suspense upgrade (documented; not the scaffolded default)

The example hooks use classic `useQuery` with `isPending`/`isError`, which works everywhere. To integrate with `set-up-error-boundaries`, swap to `useSuspenseQuery`: the component suspends while loading and throws errors to the nearest `ErrorBoundary`.

```tsx
// upgrade: no isPending/isError branches; needs <Suspense> + <ErrorBoundary> above
const { data } = useSuspenseQuery({
  queryKey: queryKeys.todos.list(filters),
  queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.status}`),
});
```

**Caveat — pagination/filter flash:** changing the key while a Suspense query is mounted re-triggers the fallback. Wrap the update in `startTransition` to keep the old data visible during the fetch.

React 19's `use()` hook covers conditional/loop/RSC-promise cases only; for standard client fetching, `useSuspenseQuery` is idiomatic.

## Vue specifics: reactive query keys
**Why:** Vue queries re-run when reactive inputs change. A plain key won't track a `ref`; wrap it in `computed`.
**How to apply:**
```ts
useQuery({
  queryKey: computed(() => queryKeys.todos.list(filters.value)),
  queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.value.status}`),
});
```

## When to deviate

- **Persisted cache** (offline, instant reloads): add `persistQueryClient` and set `gcTime` ≥ the persister's `maxAge`.
- **Pinia Colada** is a Vue-native alternative to the Query Vue adapter. Valid, but this plugin standardises on TanStack Query both sides for one mental model.
````

- [ ] **Step 2: Verify content and validator**

Run: `grep -cE "^## Rule:" skills/frontend/set-up-state-management/server-state.md && bash scripts/validate.sh`
Expected: grep prints `4`; validator passes.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/set-up-state-management/server-state.md
git commit -m "feat(skill): add server-state (TanStack Query) reference"
```

---

## Task 6: Create the `ui-state.md` reference

**Files:**
- Create: `skills/frontend/set-up-state-management/ui-state.md`

- [ ] **Step 1: Write the file**

````markdown
# UI State — Zustand (React) / Pinia (Vue)

Reference for `set-up-state-management`. Patterns for the UI-state half. UI state is client-only: toggles, selections, filters, theme, wizard steps. It never holds server data (see `state-boundaries.md`).

## Rule: one small store per domain; no mega-store
**Why:** Small stores are easier to read, test, and tree-shake, and they limit the blast radius of a change. A single global store becomes a dumping ground and a re-render hotspot.
**How to apply:** `useTodoFiltersStore`, `useThemeStore`, `useSidebarStore` — each owns one concern, each in its own file under `src/stores/`, named `use<Domain>Store`.

## Rule (React): select with inline functions; never codegen selectors
**Why:** Inline selectors (`useStore((s) => s.x)`) subscribe the component to just that slice, so it re-renders only when `x` changes. The auto-generated `useStore.use.x()` helper **breaks under React Compiler** and is not recommended.
**How to apply:**
```ts
const status = useTodoFiltersStore((s) => s.status);          // one value
const { status, setStatus } = useTodoFiltersStore(            // many values
  useShallow((s) => ({ status: s.status, setStatus: s.setStatus })),
);
```

**Anti-example:**
```ts
// bad: subscribes to the whole store; re-renders on every change
const store = useTodoFiltersStore();
// bad: codegen selector — breaks with React Compiler
const status = useTodoFiltersStore.use.status();
```

> **React Compiler note:** the compiler auto-memoizes rendering, so drop manual `useMemo`/`useCallback`. It does *not* replace selectors — those control store *subscription*, a different axis — so inline selectors stay required.

## Rule (Vue): setup-store style + storeToRefs
**Why:** Setup stores (`defineStore('x', () => { ... })`) read like the Composition API and map 1:1 onto Zustand's functional store. `storeToRefs` keeps destructured state reactive; actions can be destructured directly.
**How to apply:**
```ts
const store = useTodoFiltersStore();
const { status } = storeToRefs(store); // reactive state
const { setStatus, reset } = store;    // actions: plain destructure
```

## Growing a store: the slices pattern (React)
When one store legitimately needs several cohesive parts, compose typed slices rather than splitting into coupled stores.
```ts
import { create, type StateCreator } from 'zustand';
import type { TodoStatus } from '@/libs/queryKeys';

type FiltersSlice = { status: TodoStatus; setStatus: (s: TodoStatus) => void };
type SortSlice = { sort: 'newest' | 'oldest'; setSort: (s: SortSlice['sort']) => void };

const createFiltersSlice: StateCreator<FiltersSlice & SortSlice, [], [], FiltersSlice> = (set) => ({
  status: 'all',
  setStatus: (status) => set({ status }),
});
const createSortSlice: StateCreator<FiltersSlice & SortSlice, [], [], SortSlice> = (set) => ({
  sort: 'newest',
  setSort: (sort) => set({ sort }),
});

export const useTodoViewStore = create<FiltersSlice & SortSlice>()((...a) => ({
  ...createFiltersSlice(...a),
  ...createSortSlice(...a),
}));
```

## Durability: persist (documented; not the default)
- **React:** wrap with `persist`, keeping `devtools` outermost — `devtools(persist(fn, { name }))`. Use `partialize` to persist only chosen keys.
- **Vue:** add `pinia-plugin-persistedstate`.

Persist UI preferences (theme, collapsed panels), never server data.

## When to deviate

- **A single boolean** shared by a parent and one child rarely needs a store — lift state or use context. Reach for a store when the value is read across unrelated parts of the tree.
- **Server-derived UI state** (for example "is this row selected", keyed by server id): the selection set is UI state (store); the rows are server state (cache). Keep them separate per `state-boundaries.md`.
````

- [ ] **Step 2: Verify content and validator**

Run: `grep -cE "^## Rule" skills/frontend/set-up-state-management/ui-state.md && bash scripts/validate.sh`
Expected: grep prints `3`; validator passes.

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/set-up-state-management/ui-state.md
git commit -m "feat(skill): add ui-state (Zustand/Pinia) reference"
```

---

## Task 7: Create `SKILL.md` (the skill body)

**Files:**
- Create: `skills/frontend/set-up-state-management/SKILL.md`

**Note:** Created last so the `## References` links to `./state-boundaries.md`, `./server-state.md`, and `./ui-state.md` resolve under `validate.sh`. The `description` must be a single line starting with `Use when`, and `name` must equal the folder name `set-up-state-management`.

- [ ] **Step 1: Write the file**

````markdown
---
name: set-up-state-management
description: Use when adding state management to a frontend project — wires server-state (TanStack Query) and UI-state (Zustand for React / Pinia for Vue) with a hard boundary between them, a typed query-key factory, a fetch seam, and example query/mutation hooks plus a small UI store.
---

# Set Up State Management

## 1. Audit current state

Detect what already exists before changing anything.

Dependencies (read `package.json`):
```bash
grep -E '"@tanstack/(react|vue)-query"|"zustand"|"pinia"' package.json 2>/dev/null
```

Provider wiring:
```bash
grep -rE "QueryClientProvider|VueQueryPlugin|createPinia" src/ 2>/dev/null
```

Existing seams and stores:
```bash
ls src/libs/queryClient.ts src/libs/fetcher.ts src/libs/queryKeys.ts 2>/dev/null
ls src/stores/ 2>/dev/null
```

**Check prerequisites.** This skill writes into `src/libs/`, `src/hooks/` (React) or `src/composables/` (Vue), and `src/stores/`, and imports through the `@/` alias.

- `@/*` path alias configured? Check: `grep '"@/\*"' tsconfig.json tsconfig.app.json 2>/dev/null`. If absent, run `configure-typescript` first.
- `src/libs/` and `src/hooks/` (or `src/composables/`) exist? If not, run `set-up-frontend-structure` first, or create them flat and note the deviation in the project README.

## 2. Decide what to do

- No deps, no wiring → full setup (steps 3–8).
- Library installed but seams/examples missing → add only the missing pieces.
- Everything present → confirm `staleTime`/devtools defaults and that `state-boundaries.md` is followed; exit "State management already in place."

## 3. Detect framework

Read `package.json`. React or Vue? Branch every step below. React uses TanStack Query's React adapter + Zustand; Vue uses the Vue adapter + Pinia.

## 4. Install dependencies (only what is missing)

Versioning per `../_shared/stack-versions.md` (caret for runtime deps).

### React
```bash
pnpm add @tanstack/react-query zustand
pnpm add -D @tanstack/react-query-devtools
```

### Vue
```bash
pnpm add @tanstack/vue-query pinia
```

## 5. Generate the seams

### `src/libs/fetcher.ts` (both frameworks)

A typed `fetch` wrapper that throws on non-2xx so TanStack Query treats failures as errors. Single seam for base URL and auth headers later.

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

### `src/libs/queryKeys.ts` (both frameworks)

The hand-rolled, typed query-key factory. Also the home of the example domain types, so the store, the hooks, and the cache key all import from one place.

```ts
// src/libs/queryKeys.ts
export type TodoStatus = 'all' | 'active' | 'done';
export type TodoFilters = { status: TodoStatus };
export type Todo = { id: string; text: string; done: boolean };

export const queryKeys = {
  todos: {
    all: ['todos'] as const,
    list: (filters: TodoFilters) => [...queryKeys.todos.all, 'list', filters] as const,
    detail: (id: string) => [...queryKeys.todos.all, 'detail', id] as const,
  },
} as const;
```

### `src/libs/queryClient.ts` (React only)

```ts
// src/libs/queryClient.ts
import { QueryClient } from '@tanstack/react-query';

// Freshness-vs-requests dial — tune per project.
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 60_000, // fresh for 1 min; no refetch within window
      gcTime: 5 * 60_000, // unused cache retained 5 min
      retry: 2,
    },
  },
});
```

Vue configures the client through `VueQueryPlugin` options in step 7 — no separate file.

## 6. Generate the example hooks and store

The example is a pair that cooperates across the boundary without crossing it: the filter is UI state (the store); the filtered list is server state (the cache).

### React

```ts
// src/hooks/useTodos.ts
import { useQuery } from '@tanstack/react-query';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type Todo, type TodoFilters } from '@/libs/queryKeys';

export function useTodos(filters: TodoFilters) {
  return useQuery({
    queryKey: queryKeys.todos.list(filters),
    queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.status}`),
  });
}
```

```ts
// src/hooks/useCreateTodo.ts
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type Todo } from '@/libs/queryKeys';

export function useCreateTodo() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { text: string }) =>
      fetcher<Todo>('/todos', { method: 'POST', body: JSON.stringify(input) }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: queryKeys.todos.all }),
  });
}
```

```ts
// src/stores/useTodoFiltersStore.ts — UI state only (which filter is active)
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

Consume with inline selectors: `const status = useTodoFiltersStore((s) => s.status);`. See `./ui-state.md` for `useShallow` and the React Compiler note.

### Vue

```ts
// src/composables/useTodos.ts — Vue keys must be reactive (computed)
import { useQuery } from '@tanstack/vue-query';
import { computed, type Ref } from 'vue';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type Todo, type TodoFilters } from '@/libs/queryKeys';

export function useTodos(filters: Ref<TodoFilters>) {
  return useQuery({
    queryKey: computed(() => queryKeys.todos.list(filters.value)),
    queryFn: () => fetcher<Todo[]>(`/todos?status=${filters.value.status}`),
  });
}
```

```ts
// src/composables/useCreateTodo.ts
import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { fetcher } from '@/libs/fetcher';
import { queryKeys, type Todo } from '@/libs/queryKeys';

export function useCreateTodo() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: { text: string }) =>
      fetcher<Todo>('/todos', { method: 'POST', body: JSON.stringify(input) }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: queryKeys.todos.all }),
  });
}
```

```ts
// src/stores/useTodoFiltersStore.ts — Pinia setup-store
import { defineStore } from 'pinia';
import { ref } from 'vue';
import type { TodoStatus } from '@/libs/queryKeys';

export const useTodoFiltersStore = defineStore('todoFilters', () => {
  const status = ref<TodoStatus>('all');
  function setStatus(next: TodoStatus) {
    status.value = next;
  }
  function reset() {
    status.value = 'all';
  }
  return { status, setStatus, reset };
});
```

Consume with `storeToRefs` — see `./ui-state.md`.

## 7. Wire providers

### React (`src/main.tsx`)

```tsx
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClientProvider } from '@tanstack/react-query';
import { ReactQueryDevtools } from '@tanstack/react-query-devtools';
import App from './App';
import { queryClient } from '@/libs/queryClient';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
      {import.meta.env.DEV && <ReactQueryDevtools />}
    </QueryClientProvider>
  </StrictMode>,
);
```

If `set-up-error-boundaries` is in place, keep the `ErrorBoundary` outermost (above `QueryClientProvider`) so provider-setup errors are still caught.

### Vue (`src/main.ts`)

```ts
import { createApp } from 'vue';
import { VueQueryPlugin, type VueQueryPluginOptions } from '@tanstack/vue-query';
import { createPinia } from 'pinia';
import App from './App.vue';
import './style.css';

const vueQueryOptions: VueQueryPluginOptions = {
  queryClientConfig: {
    defaultOptions: { queries: { staleTime: 60_000, gcTime: 5 * 60_000, retry: 2 } },
  },
};

createApp(App).use(createPinia()).use(VueQueryPlugin, vueQueryOptions).mount('#app');
```

## 8. Verify

```bash
pnpm tsc --noEmit
```

Expected: 0 errors (seams, hooks, and store compile).

Run `pnpm dev` and confirm the TanStack Query devtools panel renders (React) or the Vue Query devtools are available.

Playwright e2e is deferred to skill `configure-test-stack`, matching the `set-up-error-boundaries` precedent. Until then, the type-check is the gate.

## References
- ./state-boundaries.md — which state goes where; the decision table; anti-patterns. The most important file.
- ./server-state.md — TanStack Query patterns (React + Vue): hooks-only rule, query-key factory, invalidation, client defaults, the Suspense upgrade.
- ./ui-state.md — Zustand + Pinia patterns: small stores, inline selectors (React Compiler note), slices, persistence.
- ../_shared/folder-conventions.md — `stores/` rule; `libs/` vs `utils/`.
- ../_shared/stack-versions.md — runtime-dep versioning.
- ../_shared/glossary.md — "Server state" vs "Client / UI state".
````

- [ ] **Step 2: Verify frontmatter, links, and structure**

Run: `bash scripts/validate.sh`
Expected: `OK: validator passed (5 skills checked)` — the new skill's `name` matches its folder, the `description` starts with "Use when", and all six relative links resolve.

Run: `grep -nE "^## [0-9]\." skills/frontend/set-up-state-management/SKILL.md | wc -l`
Expected: `8` (eight numbered sections).

- [ ] **Step 3: Commit**

```bash
git add skills/frontend/set-up-state-management/SKILL.md
git commit -m "feat(skill): set-up-state-management"
```

---

## Task 8: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full validator run**

Run: `bash scripts/validate.sh`
Expected: `OK: validator passed (5 skills checked)`.

- [ ] **Step 2: Confirm the skill folder is complete**

Run: `ls skills/frontend/set-up-state-management/`
Expected: `SKILL.md  server-state.md  state-boundaries.md  ui-state.md`.

- [ ] **Step 3: Confirm no unbalanced code fences in the new files**

Run:
```bash
for f in skills/frontend/set-up-state-management/*.md; do
  n=$(grep -c '```' "$f"); echo "$f: $n fences"; [ $((n % 2)) -eq 0 ] || echo "  WARNING: odd fence count in $f";
done
```
Expected: every file reports an even fence count; no WARNING lines.

- [ ] **Step 4: Confirm the cross-references between skills are intact**

Run: `grep -rn "set-up-state-management" skills/frontend/_shared/folder-conventions.md`
Expected: the `stores/` rule references the new skill — confirms the shared docs and the skill agree.

No commit (verification only). If `finishing-a-development-branch` is used next, this branch (`feat/state-management-skill`) is ready for a PR.

---

## Self-Review

**1. Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|---|---|
| §5 skill structure (4 files) | Tasks 4–7 |
| §6 audit-first behavior | Task 7, SKILL.md §1–2 |
| §7 file layout / §8 worked example | Task 7, SKILL.md §5–6 |
| §9 server state (React + Vue) | Task 5 + Task 7 §5–7 |
| §10 UI state (Zustand + Pinia) | Task 6 + Task 7 §6 |
| §11 reference-doc outlines | Tasks 4–6 |
| §12 shared-file updates | Tasks 1–3 |
| §13 verification | Task 7 §8, Task 8 |
| §16 2026 notes (Compiler, Suspense, factory, Pinia) | Tasks 5–6 (baked into rules) |

No spec requirement is left without a task. §14 (out of scope) and §15 (open values: `staleTime`, `refetchOnWindowFocus`, example domain) are intentionally deferred and surfaced in `server-state.md` + SKILL.md comments.

**2. Placeholder scan** — no "TBD/TODO/implement later". Code steps show complete content; verification steps give exact commands and expected output.

**3. Type consistency** — `TodoStatus`, `TodoFilters`, and `Todo` are defined once in `queryKeys.ts` (Task 7 §5) and imported everywhere else (`useTodos`, `useCreateTodo`, `useTodoFiltersStore`, slices example). `queryKeys.todos.all` is the invalidation key used by both mutations. `useTodoFiltersStore` exposes `status` / `setStatus` / `reset` consistently across React and Vue.
