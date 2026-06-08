# Why `frontendskills` Exists — The Ideas Behind the Plugin

*A design narrative: the decisions, the trade-offs, and the case for codifying senior
frontend judgment as a Claude Code plugin.*

---

## The one idea

Every senior engineer carries a body of judgment that almost never gets written down.
It is the set of small, load-bearing decisions you make without thinking — where server
state ends and UI state begins, why the auth token must never touch `localStorage`, which
of two formatters owns the bytes, what a "molecule" is and is not. That judgment is the
difference between a frontend that scales and one that calcifies. It usually lives in one
person's head and dies when they change jobs.

`frontendskills` is an attempt to take that judgment out of the head and put it somewhere a
machine can apply it — **on demand, on any codebase, the same way every time.** Not a
template that scaffolds a frozen snapshot of "best practice 2024," but a set of
*situation-triggered procedures* that inspect what is actually in front of them and apply
only the senior move that is missing. The plugin is, in one phrase, **externalized judgment
that executes.**

Everything else in this document is the story of the choices that shape that idea — told as
a yarn you can follow, each beat in the form *I chose **X** over **Y** to get **Z**.*

---

## The yarn: the decisions that shaped it

### 1. Skills that fire on a situation — over a rulebook that is always on

I chose **on-demand, trigger-based skills** over **a single always-loaded `CLAUDE.md` of
frontend rules**, to get **relevance without dilution**.

A model's attention is a finite budget. Pour five thousand lines of "here is everything I
believe about frontend" into the context of every conversation and two things happen: the
rules that matter to *this* task drown in the rules that do not, and you pay the token cost
on every turn whether you are setting up error boundaries or asking what time it is. A skill
inverts that. It announces *when* it is relevant ("Use when adding state management to a
frontend project…"), stays out of the way otherwise, and when it does fire it brings exactly
the knowledge for that moment. The outcome is surgical: the boundary rules arrive precisely
when the boundary question is being asked, and never a turn sooner.

### 2. Audit-first and idempotent — over generative scaffolding

I chose **inspect-then-apply-only-what-is-missing** over **"generate a fresh project from a
template,"** to get **a tool you can point at any repository, safely, twice.**

Templates have two failure modes a senior knows intimately. They rot — the day after you
publish one, a dependency ships a major version and your snapshot is wrong. And they cannot
touch a project that already exists; they only birth new ones. An audit-first skill has
neither flaw. It reads `package.json`, greps for what is already wired, and does only the
delta. Run it on an empty directory and it scaffolds; run it on a three-year-old codebase and
it brings just the missing concern up to standard; run it twice and the second run is a
no-op. That is the difference between a *generator* and a *tool* — and tools are what
seniors reach for.

### 3. Progressive disclosure — over one fat file

I chose **a lean `SKILL.md` (trigger + procedure) backed by reference `.md` files** over
**one document that says everything at once**, to get **cheap-by-default depth-on-demand.**

The model should be able to read the *what to do* without paying for the *why behind every
rule*. So each skill leads with a short, scannable procedure and pushes the rationale — the
decision tables, the anti-patterns, the "when to deviate" — into companion files like
`state-boundaries.md` or `auth-patterns.md` that load only when the question actually
demands them. You get the summary for free and the dissertation when you ask. It is the same
instinct as a well-factored codebase: a clear interface up front, the heavy reasoning behind
it.

### 4. Seams — over calling vendors directly

I chose **single points of indirection** — `fetcher`, `captureError`, `queryKeys`, `env`,
the analytics and feature-flag clients — over **scattering vendor SDK calls and raw
`import.meta.env` reads through the app**, to get **one-file swaps, one-file validation, and
trivially mockable tests.**

This is the move that most separates senior code from tutorial code. When `captureError`
lives in one module, switching Sentry for GlitchTip is a body-of-one-function change, not a
codebase-wide find-and-replace. When every server request flows through `fetcher`, adding a
401-refresh or an auth cookie happens in one place and every call site inherits it. When
`import.meta.env` is validated once in `env.ts`, a missing variable fails loudly at boot
instead of silently as an empty string in production. A seam costs almost nothing to build
and pays out every time the world changes — and in frontend, the world changes constantly.

### 5. A hard server/UI state boundary — over one global store

I chose **TanStack Query owns server state, Zustand/Pinia owns UI state, and server data is
never copied into a store** over **a single global store that holds everything**, to get
**the elimination of the most expensive bug in frontend.**

The classic catastrophe is two sources of truth for the same data — a query cache and a store
that each think they are current, drifting apart until someone debugs a stale screen for an
afternoon. The boundary makes that bug *unrepresentable*: the store physically cannot hold
server data, so the two systems can never fight. The UI layer may *feed* a query key (the
active filter becomes part of the cache address), but the result flows back into the cache,
never the store. This one rule is the architectural spine the whole state story hangs from,
and it is why `state-boundaries.md` is the most important file in the plugin.

### 6. A composable front-to-back chain — over a bag of unrelated starters

I chose **skills that share seams and hand off to each other** over **a pile of independent
boilerplate generators**, to get **a system rather than a grab-bag.**

The pieces interlock on purpose. `scaffold-frontend-project` lays the Vite + Tailwind v4
base; `clean-frontend-scaffolding` strips its demo; `configure-typescript` and
`validate-env` harden the language and the config; the router carries the `queryClient` in
its context so a route *loader* can prefetch into the exact cache a component's hook reads;
the auth guard reads that same context; the form's submit calls the mutation that invalidates
that same query key; `configure-error-tracking` wires the seam `set-up-error-boundaries`
planted. Pull any thread and you find it tied to the others. That coherence is what an
independent reviewer confirmed was *real code, not README claims* — and it is what makes the
set feel designed instead of assembled.

### 7. Dual-framework — over picking one

I chose **branching React 19 and Vue 3 in every skill** over **committing to a single
framework**, to get **reach without diluting the ideas.**

The judgment being encoded — the state boundary, the seams, schema-first forms, accessibility
as a requirement, reduced-motion gating — is framework-*independent*. Zustand maps cleanly to
Pinia; TanStack Query has adapters for both; the View Transitions API is native to neither and
available to both. Encoding both frameworks roughly doubles who the plugin serves while the
underlying ideas stay identical. The cost is real (every example written twice) and worth it,
because the ideas were never about React or Vue in the first place.

### 8. "When to deviate" — over commandments

I chose **shipping every rule with its escape hatch and its rationale** over **handing down
rules as commandments**, to get **judgment instead of cargo cult.**

A rule without a reason is dogma, and dogma is how juniors ship the wrong thing confidently.
So every reference file ends with *When to deviate*: co-located tests are fine if your team
prefers them; Biome can own formatting too if you do not need Prettier's Tailwind sort; jsdom
beats real-browser tests when you need raw speed over fidelity. The skill teaches the default
*and the conditions under which the default is wrong.* That is what a senior actually
transmits to a junior — not "do this," but "do this, because, except when."

### 9. Verified against current docs — over trusting memory

I chose **pulling the live 2026 API from the docs before writing a line of config** over
**trusting the model's training snapshot**, to get **code that is actually correct today.**

Frontend tooling moves faster than any training cutoff. Memory said `framer-motion`; the docs
said the package is now `motion` with a `motion/react` import. Memory might say `@tailwind`
directives; Tailwind v4 wants a single `@import "tailwindcss"`. Memory might reach for
`provider: 'playwright'`; Vitest 4 wants `provider: playwright()` from a dedicated package.
Each of these was checked against the source before it was written, and each check changed the
answer. A skill that ships a year-stale config is worse than no skill, because it looks
authoritative while being wrong.

### 10. Adversarial review — over self-trust

I chose **dispatching fresh-context reviewers told to be brutal** over **trusting my own
first draft**, to get **quality that is enforced rather than asserted.**

Authors are blind to their own bugs. So the substantial batches went to independent review
agents whose only job was to find what was wrong — and they earned their keep: a TypeScript
error where an example called a hook with an argument it did not accept, a guard referencing a
`context.auth` that did not exist, a missing query-key definition, a dark-mode flash-of-light,
a consent stub that would have shipped a GDPR violation. Just as important, when a reviewer
flagged the `tanstackRouter` import as "wrong," it could be rejected *with evidence* — the
current docs proved the reviewer's memory was the stale one. Review is the step where senior
quality is verified; skipping it is how plausible-but-wrong code ships.

### 11. Your corrections — over my defaults

I chose **bending the plugin to how you actually work** over **my own defaults**, to get
**a skillset that reflects a specific senior, not a generic one.**

Tests belong in `tests/` by type, not co-located — so the structure skill stopped emitting
co-located specs and the de-location rippled coherently through every reference. The toolchain
is pnpm, Biome, Prettier, Node LTS — so the version policy and the linting skill were written
to that, not to ESLint. Planning docs do not belong in the published repo — so they stayed
local and only the deliverables were committed. A *personal* skill plugin that imposed my
defaults over yours would defeat its own purpose; the whole point is that it encodes **your**
judgment, so that Claude works the way you would.

---

## What it buys you — and your Claude

Installed, this plugin changes what Claude *is* on a frontend task. Without it, you get the
model's average of the public internet: a generic, slightly-dated, framework-flavored default
that you then spend your review budget correcting. With it, you get **your** frontend, every
time:

- **Consistency without re-explaining.** You stop re-typing "put server state in Query, UI
  state in Zustand, validate env at boot, gate routes in the guard, respect reduced motion."
  It is encoded once and applied forever, identically, on project one and project fifty.
- **Senior defaults, current.** The model reaches for Tailwind v4, Vitest browser mode, the
  React Compiler, typed routes, schema-first forms — not because it guessed, but because the
  knowledge was checked and written down.
- **Whole classes of bugs designed out.** The state boundary kills dual-source-of-truth
  drift. The seams kill vendor lock-in and untestable code. `validate-env` kills silent
  misconfiguration. Fail-closed flags kill "an outage shipped the half-built feature."
- **Safety on existing code.** Because every skill is audit-first, you can point Claude at a
  real, messy, half-finished repo and it will bring exactly one concern up to standard without
  trampling the rest.
- **Cost only when relevant.** None of this sits in your context until a task triggers it. The
  knowledge is free until the moment it is needed, then precise.

In short: it turns Claude from a capable generalist into *your* senior frontend pair — one who
already knows your boundaries, your seams, your toolchain, and your taste, and who never
forgets them.

## Why a plugin, specifically

The content is *procedural knowledge for a model to act on.* Of the available vessels, a
Claude Code plugin is the only one shaped like the content:

- **Over loose skill files:** a plugin is a *versioned, distributable, namespaced unit.* All
  twenty-two skills plus the shared `_shared/` conventions install together, evolve together,
  and carry a version (`0.2.0`) you can reason about. You share it across every project and
  with a team through a marketplace; you update it centrally and everyone gets the fix. Loose
  files are a folder you copy and forget to keep in sync.
- **Over `CLAUDE.md` rules:** `CLAUDE.md` is always-on, project-local, unstructured prose. It
  bloats every conversation, does not travel between repos, and cannot express "load this only
  when the situation arises." Skills are on-demand, portable, and structured — a trigger, a
  procedure, and progressive-disclosure references — which is exactly the structure this
  knowledge has.
- **Over an MCP server:** MCP exists to give a model new *tools and data* — to reach an API, a
  database, a live system. This plugin grants no new capability; it grants *judgment about how
  to use the capabilities the model already has.* That is a skill, not a server, and it needs
  no process running to deliver it.
- **Over a docs site or blog:** documentation is written for a human to read and then *go
  apply themselves.* A skill is written for the model to apply *directly*, at the moment of
  relevance, with the audit-first procedure and the verification step baked in. A doc tells; a
  skill does.

The plugin format also brings the machinery that keeps the set honest: auto-discovery of every
`skills/**/SKILL.md`, a `_shared/` home for the conventions that cross-cut the skills, and a
`validate.sh` gate that refuses malformed frontmatter or broken reference links. The vessel
matches the cargo.

## Coda

This started as four skills and a question — *"what's missing is state management."* It became
a complete, twenty-two-skill account of how to build a 2026 frontend the way one senior
engineer actually builds them: audit-first, seam-based, boundary-respecting, accessibility-
and-performance-aware, verified against the real world, and honest about when its own rules
do not apply. The deepest value is not any single skill. It is that the judgment is now
*written down, executable, and yours* — so the next project, and the one after that, start
from the standard instead of climbing back to it.
