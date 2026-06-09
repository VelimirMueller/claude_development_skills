# Contributing to frontendskills

`frontendskills` encodes senior frontend judgment as *situation-triggered procedures* —
audit-first, idempotent, dual-framework. A good contribution is a new skill that captures one
such piece of judgment, a fix that sharpens an existing one, or an improvement to the shared
conventions. This guide explains the house style so your work fits the set rather than sitting
beside it.

## What you need

There's no build step — skills are Markdown. You need `git`, `bash` (for the validator), and
ideally Claude Code itself to trigger a skill and watch it run. The only gate is:

```bash
bash scripts/validate.sh
```

It checks that the manifest parses, every `SKILL.md` has a `name` and a `Use when…`
description, and every reference link resolves. Keep it green; CI treats it as the bar.

## Anatomy of a skill

Each skill is a folder under `skills/<domain>/<skill-name>/`:

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

1. **Audit current state** — grep/ls for what already exists; change nothing yet.
2. **Decide what to do** — full setup, add only the missing piece, or exit "already in place."
3. **Detect framework** — branch React 19 / Vue 3.
4. **Install only what's missing.**
5. **Generate the seams / examples.**
6. **Wire it up.**
7. **Verify** — the command that proves it (usually `pnpm tsc --noEmit`) and the expected output.

## The house style — what makes a skill *ours*

- **Audit-first & idempotent.** Inspect before acting; apply only the delta; a second run is a
  no-op. A skill must be safe to point at a messy, real, half-finished repo.
- **Dual-framework parity.** Branch React 19 *and* Vue 3 in every step. The judgment is
  framework-independent; show both tracks.
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

Cross-cutting rules live in `skills/frontend/_shared/` — link there instead of restating:

- `conventions.md` — the `@/` alias, the `src/` root, tests in `tests/` by type, naming, the
  `stores/` rule.
- `stack-versions.md` — track the active Node LTS; **caret (`^`) for runtime deps, tilde (`~`)
  for build/test tooling**; pnpm by default, but honour the user's choice.
- `glossary.md` — atomic-design terms; server-state vs UI-state.

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
  **patch**. Bump `.claude-plugin/plugin.json` and add a `CHANGELOG.md` entry in the same PR.

## License

By contributing, you agree your work is released under the project's [MIT license](LICENSE).
