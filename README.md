# frontendskills

Opinionated, audit-aware Claude Code skills for building scalable, maintainable frontend projects.

This plugin captures development knowledge — process and technical, blended — as situation-based skills that Claude loads on demand. Each skill is **idempotent**: it inspects the current project state first and applies only what is missing. The same skill works on a brand-new project and on an existing one being brought up to standard.

## Status

**0.1.0 — under construction.** Frontend skills first; infrastructure and backend domains will follow under the same plugin.

## What's inside

Skills live under `skills/frontend/`. Each skill is a folder containing a `SKILL.md` (the trigger + body Claude sees first) and one or more reference `.md` files for deep-dive rules with rationale.

Shared knowledge across multiple frontend skills lives in `skills/frontend/_shared/`:
- `conventions.md` — canonical project conventions (paths, naming, prefixes).
- `stack-versions.md` — version policy (Node, package manager, dep version pinning).
- `glossary.md` — atomic-design term definitions.

## Install (local)

This plugin is intended for local Claude Code use. Add the plugin's directory as a marketplace path in your Claude Code settings; Claude Code auto-discovers `skills/**/SKILL.md`.

## Validate

Run `bash scripts/validate.sh` to check that:
- `.claude-plugin/plugin.json` parses and has the required fields.
- Every `SKILL.md` has YAML frontmatter with `name` and `description` (the latter starting with `Use when`).
- Every relative reference link in a `SKILL.md` resolves to an existing file.
