# Folder Conventions

Reference for `set-up-frontend-structure`. Naming, barrel patterns, and the React-vs-Vue split for hooks/composables.

## Rule: hooks (React) vs composables (Vue)
**Why:** Each framework's idiom. Mixing terms creates cognitive overhead.
**How to apply:**
- React → `src/hooks/`
- Vue → `src/composables/`

The skill `set-up-frontend-structure` detects framework and picks the right folder.

## Rule: each component lives in its own folder
**Why:** A component, its tests, its stories, and its barrel together — co-located, navigable.
**How to apply:**
```
src/components/atoms/Button/
├── Button.tsx           # component
├── Button.test.tsx      # unit/component test
├── Button.stories.ts    # Storybook
└── index.ts             # barrel: export * from './Button'
```

**Anti-example:**
```
src/components/atoms/
├── Button.tsx           # everything flat
├── Button.test.tsx
├── Card.tsx             # quickly becomes 50 files in one folder
```

## Rule: tests are co-located by default; e2e in `src/tests/`
**Why:** Co-located unit tests stay in sync with the subject. End-to-end tests don't have a single subject — they live separately.
**How to apply:**
- `Button.test.tsx` lives next to `Button.tsx`.
- `src/tests/` holds Playwright e2e specs and the Vitest setup file (`setup.ts`).

## Rule: `libs/` is for "third-party adapter or wrapper"; `utils/` is for "pure helpers"
**Why:** Different lifetimes and dependencies. A wrapper around `tanstack/query` belongs to libs because it depends on a third-party. A `formatDate` belongs to utils because it has no external deps.
**How to apply:**
- `libs/queryClient.ts` (wraps TanStack Query) → `libs/`
- `libs/fetcher.ts` (wraps `fetch`) → `libs/`
- `utils/formatDate.ts` (pure date formatter) → `utils/`
- `utils/clsx.ts` (pure class-string utility) → `utils/`

## Rule: barrel `index.ts` re-exports only; never defines inline
**Why:** A file that defines AND re-exports does two jobs. Splits concerns.
**How to apply:**
```ts
// src/components/atoms/index.ts
export * from './Button';
export * from './Input';
export * from './ErrorFallback';
```

## Rule: file names match the primary export's PascalCase identifier
**Why:** Predictable imports.
**How to apply:** `Button.tsx` exports `Button`. `useToggle.ts` exports `useToggle`. `formatDate.ts` exports `formatDate`.

## When to deviate

- **`pages/` for route components:** if using a file-based router (Next.js, Nuxt, TanStack Router), the routing layer dictates a `pages/` or `routes/` folder. In that case, the atomic-design `pages/` layer redundantly mirrors that — pick one. The skill audits and asks.
- **Co-located vs separate test folders:** team preference. Default is co-located. If a project has chosen otherwise, follow what's there.

## Empty-folder placeholders

Each empty folder gets a `.gitkeep` file (zero bytes). Once real content arrives, the `.gitkeep` should be deleted in the same commit that adds the first real file.
