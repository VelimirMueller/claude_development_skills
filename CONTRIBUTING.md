# Contributing to frontendskills

This repo is one marketplace, `frontendskills`, with seven plugins: **devcore**
(`skills/core`), **frontendskills** (`skills/frontend` + `skills/landing`), **backendskills**
(`skills/backend`), **infraskills** (`skills/infra`), **cliskills** (`skills/cli`),
**aiskills** (`skills/ai`), and **gameskills** (`skills/game`). Each plugin is an entry in
`.claude-plugin/marketplace.json` with `source: "./"` and its own `skills` list; every plugin
depends on devcore. There is no root `plugin.json` — it would leak every catalogue into every
plugin. The skills encode senior judgment as *situation-triggered procedures* — audit-first,
idempotent, track-aware. A good contribution is a new skill that captures one such piece of
judgment, a fix that sharpens an existing one, or an improvement to the shared conventions.
This guide explains the house style so your work fits the set rather than sitting beside it.

## What you need

There's no build step — skills are Markdown. You need `git`, `bash` >= 4 and `jq` (for the
validator), and ideally Claude Code itself to trigger a skill and watch it run. The only gate
is:

```bash
bash scripts/validate.sh
```

It checks that every marketplace entry has a name, version, description, and `skills` list;
that one version is shared by all entries, `metadata.version`, the README Status line, and
the top `CHANGELOG.md` entry; that each catalogue is owned by exactly one plugin and all
dependencies resolve; that every `SKILL.md` has a `name` and a description starting with
"Use when", at most 300 characters, and no unquoted `": "`; that skill names are unique
across catalogues; and that every relative `.md` link under `skills/` resolves. Keep it
green: the `validate` workflow in `.github/workflows/validate.yml` runs it on every pull
request and blocks on failure.

## Anatomy of a skill

Each skill is a folder under `skills/<catalogue>/<skill-name>/`:

```
skills/frontend/set-up-something/
  SKILL.md               # the trigger + procedure Claude sees first
  something-patterns.md  # reference: the rules, with rationale
```

**`SKILL.md`** opens with YAML frontmatter:

```yaml
---
name: set-up-something                 # matches the folder name
description: Use when … — <what it wires, in one breath>.
---
```

The `description` **must start with "Use when"** — it's enforced by the validator and it's the
sentence Claude matches on to decide the skill is relevant. Make it situation-specific, not a
topic label: *"Use when adding authentication to a frontend SPA — …"*, never *"Auth skill."*

The body is a short, numbered, **audit-first** procedure. The canonical shape:

1. **Audit current state** — read `.claude/stack-profile.md` (schema:
   `skills/core/_shared/stack-profile.md`) before detecting, then grep/ls for what already
   exists; change nothing yet.
2. **Decide what to do** — full setup, add only the missing piece, or exit "already in place."
3. **Detect track** — React 19 / Vue 3 in frontend; Hono / Go / FastAPI / Supabase / Next.js
   in backend; etc.
4. **Install only what's missing.**
5. **Generate the seams / examples.**
6. **Wire it up.**
7. **Verify** — the command that proves it and the expected output. In frontend that's
   `pnpm typecheck` (`tsc -b`) — never `tsc --noEmit`, which checks zero files in Vite
   templates.

## The house style — what makes a skill *ours*

- **Audit-first & idempotent.** Inspect before acting; apply only the delta; a second run is a
  no-op. A skill must be safe to point at a messy, real, half-finished repo.
- **Profile first.** Honour `.claude/stack-profile.md`; ask only what the repo and profile
  don't answer.
- **Track parity.** Branch every track the catalogue supports — React + Vue in frontend,
  Hono / Go / FastAPI in backend; the profile picks one.
- **Seams over scattered vendor calls.** Route integration through one point of indirection
  (`fetcher`, `captureError`, `env`, `queryKeys`, the analytics/flag clients) so a vendor swap
  or a test mock is a one-file change.
- **Boundaries that make bugs unrepresentable.** Prefer a rule that *can't* be violated to a
  convention that asks nicely — server data in the Query cache (never a store); tokens never in
  `localStorage`.
- **Verify against live docs.** Don't trust training memory for versions and APIs. Check the
  tool's current docs before writing config — the ecosystem moves faster than any model's
  cutoff (it's `motion`, not `framer-motion`; Tailwind v4 wants one `@import`, not three
  `@tailwind` directives).
- **Run the snippets.** Every code block is built and run in a scratch project before it
  ships; anything not run is labelled *unverified* in the text.
- **Ship every rule with its "when to deviate."** A rule without its conditions is dogma.

## Reference files

Keep `SKILL.md` lean (the *what to do*) and push the *why* into companion `*-patterns.md` files
that load only when the question demands them. Each rule follows one shape:

```markdown
## Rule: <the rule, stated plainly>
**Why:** <the reason — the cost of getting it wrong>
**How to apply:** <the concrete move, with code>
**Anti-example:** <the tempting wrong version>   (where it clarifies)
```

…and the file closes with a `## When to deviate` section.

## Shared conventions

Cross-cutting contracts live in `skills/core/_shared/` — `engineering-principles`,
`stack-profile`, `version-protocol`, `security-baseline`, `logging-contract`,
`observability`, `tech-radar`, `audience` — and every catalogue has its own
`_shared/stack-versions.md`. Link there instead of restating.

Frontend-only shared rules live in `skills/frontend/_shared/`:

- `conventions.md` — the `@/` alias, the `src/` root, tests in `tests/` by type, naming, the
  `stores/` rule.
- `stack-versions.md` — track the active Node LTS; **caret (`^`) for runtime deps, tilde (`~`)
  for build/test tooling**; pnpm by default, but honour the user's choice.
- `glossary.md` — atomic-design terms; server-state vs UI-state.
- `fetcher.md` — the one canonical `fetcher` (base and auth versions).

**A snippet used by more than one skill lives in `_shared/` once, and skills link to it.** Code
copied into several skills drifts, and a bug in it is taught several times over.

## Adding a skill for a stack we don't cover

Run the `extend-skillset` skill (devcore) — it writes a skill in this house style into a
project's `.claude/skills/` or into this repo.

## Reviewing your own work

There's no unit-test harness for Markdown skills, so the embedded code *is* the thing to get
right — treat it as code under test. Read every snippet against the current library API; a
skill that ships a year-stale config is worse than none, because it looks authoritative while
being wrong. The project leans on **adversarial review**: a fresh pair of eyes whose only job
is to find what's broken. Invite one before opening a PR.

## Planning documents

Design specs and implementation plans belong under `docs/`, which is **gitignored**. Only the
deliverables — `skills/`, `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `RATIONALE.md` — get
committed. Keep work-in-progress planning out of the published tree.

## Commits, versioning, and PRs

- **Commits:** conventional style — `feat(skill): …`, `fix(skills): …`, `docs(skills): …`.
- **Scope:** one concern per PR; keep `validate.sh` green.
- **Versioning (SemVer):** a new skill is a **minor** bump, a fix to an existing one is a
  **patch**. Bump `metadata.version` and every plugin entry's version in
  `.claude-plugin/marketplace.json` — one version for the whole marketplace — the README
  Status line, and add a `CHANGELOG.md` entry in the same PR; the validator fails if they
  disagree. A new catalogue = a new plugin entry + its `skills/` dir, depending on devcore.

## License

By contributing, you agree your work is released under the project's [MIT license](LICENSE).
