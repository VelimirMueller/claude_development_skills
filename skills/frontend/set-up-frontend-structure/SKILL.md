---
name: set-up-frontend-structure
description: Use when laying down folder structure for a frontend project — creates atomic-design component layout (atoms / molecules / organisms / templates / pages) plus hooks-or-composables, libs, utils, and tests folders, with index.ts barrels and one example component per atomic layer to document the pattern.
---

# Set Up Frontend Structure

## 1. Audit current state

For each folder below, check if it already exists and is non-empty:
- `src/components/atoms`
- `src/components/molecules`
- `src/components/organisms`
- `src/components/templates`
- `src/components/pages`
- `src/hooks` (React) **or** `src/composables` (Vue)
- `src/libs`
- `src/utils`
- `src/tests`

Detect framework from `package.json` (`react` vs `vue`). The hook-vs-composable folder is framework-specific — see `../_shared/conventions.md`.

If every folder exists and is non-empty, exit: "Structure already in place."

## 2. Decide what to do

- Nothing in place → full setup (steps 3–5).
- Partial → create only missing folders; do not overwrite existing files.
- Already structured → exit.

## 3. Create folder tree

Create:

```
src/
├── components/
│   ├── atoms/
│   ├── molecules/
│   ├── organisms/
│   ├── templates/
│   └── pages/
├── hooks/        (React) OR composables/ (Vue)
├── libs/
├── utils/
└── tests/
```

Drop a `.gitkeep` in each empty folder so git tracks them.

## 4. Add barrel files

Create one `index.ts` per atomic layer (5 files) and one for hooks/composables, libs, utils. Each starts empty (just a header comment) and gets re-exports added as components/utilities are introduced.

```ts
// src/components/atoms/index.ts
// Barrel: re-exports every atom in this folder.
```

Repeat for molecules, organisms, templates, pages, hooks (or composables), libs, utils.

## 5. Generate one example per atomic layer

To document the convention, generate a single example component at each layer with matching `*.stories.ts` and `*.test.ts` siblings. The Storybook test runner and Vitest are configured later; the test/story files should compile but won't run yet.

### React example tree

```
src/components/atoms/Button/
├── Button.tsx
├── Button.stories.ts
├── Button.test.tsx
└── index.ts

src/components/molecules/SearchInput/
├── SearchInput.tsx
├── SearchInput.stories.ts
├── SearchInput.test.tsx
└── index.ts

src/components/organisms/Header/
├── Header.tsx
├── Header.stories.ts
├── Header.test.tsx
└── index.ts

src/components/templates/AuthLayout/
├── AuthLayout.tsx
├── AuthLayout.stories.ts
└── index.ts

src/components/pages/HomePage/
├── HomePage.tsx
├── HomePage.stories.ts
└── index.ts
```

### Example file content (React `Button` atom)

```tsx
// src/components/atoms/Button/Button.tsx
import type { ButtonHTMLAttributes, ReactNode } from 'react';

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  children: ReactNode;
};

export function Button({ children, ...rest }: ButtonProps) {
  return (
    <button
      type="button"
      className="px-3 py-1.5 rounded-md bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50"
      {...rest}
    >
      {children}
    </button>
  );
}
```

```ts
// src/components/atoms/Button/index.ts
export * from './Button';
```

```tsx
// src/components/atoms/Button/Button.test.tsx
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Button } from './Button';

describe('Button', () => {
  it('renders its children', () => {
    render(<Button>Click me</Button>);
    expect(screen.getByRole('button', { name: 'Click me' })).toBeInTheDocument();
  });
});
```

```ts
// src/components/atoms/Button/Button.stories.ts
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta: Meta<typeof Button> = {
  title: 'Atoms/Button',
  component: Button,
};
export default meta;

export const Default: StoryObj<typeof Button> = {
  args: { children: 'Click me' },
};
```

For Vue projects, mirror this structure with `.vue` SFCs and Vue testing-library.

After generating one example per layer, also update each barrel:

```ts
// src/components/atoms/index.ts
export * from './Button';
```

## 6. Verify

```bash
pnpm tsc --noEmit
```

Expected: 0 errors. The example components compile (test/story imports may resolve but not run yet — that's fine).

If tests / stories fail to resolve `@testing-library/*` or `@storybook/react`, the deps were not installed in skill `scaffold-frontend-project`. Re-run that skill first.

The spec also calls for verifying that Storybook lists the example components; the Storybook test runner is wired in skill `configure-test-stack` (Plan 3). Until that lands, the type-check above is the available verification.

## References
- ./atomic-design.md — methodology, criteria for each layer, anti-patterns.
- ./folder-conventions.md — naming, barrel pattern, hooks vs composables decision.
- ../_shared/glossary.md — atomic terms (atom / molecule / organism / template / page) with the "test" question for each.
