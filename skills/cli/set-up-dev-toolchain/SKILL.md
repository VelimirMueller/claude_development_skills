---
name: set-up-dev-toolchain
description: Use when setting up or auditing a repo's developer toolchain — mise pins and tasks or just, shared task verbs, lefthook git hooks, editorconfig, GitHub CLI conventions, and a doctor task that verifies everything.
---

# Set up dev toolchain

One runner, one lockfile, one set of verbs (`setup dev test lint fmt check build` plus `typecheck` and `doctor`), the same on every repo. Hooks call tools through the runner, never a bare binary. CI runs the same `check` a developer runs.

Rules with reasons and tested config: [toolchain-patterns.md](toolchain-patterns.md). Versions: [stack-versions.md](../_shared/stack-versions.md) (verify live first, per [version-protocol](../../core/_shared/version-protocol.md)). Stack profile: [stack-profile.md](../../core/_shared/stack-profile.md).

## 1. Audit current state

Change nothing yet. Read the stack profile, then list what exists.

```bash
cat .claude/stack-profile.md 2>/dev/null | sed -n '1,40p'
ls mise.toml .mise.toml .tool-versions .nvmrc justfile Makefile lefthook.yml .husky .pre-commit-config.yaml .editorconfig 2>/dev/null
grep -nE '"(scripts|prepare)"' package.json 2>/dev/null
```

Record: language(s), current task runner, git hooks, editorconfig, CI. Note what is missing and what already exists.

## 2. Decide what to do

- Nothing present → full scaffold (steps 3-7).
- Some pieces present, gaps remain → delta. Name each gap you will close.
- Runner, hooks, editorconfig and doctor already match this file → say "already in place" and stop.

Respect existing tools. Never replace husky, make or just with something else unasked; only fill gaps. An existing runner wins over the default.

## 3. Detect the track

Pick from `languages` in the profile or from the files on disk:

| Track | Evidence | Package manager |
|---|---|---|
| TypeScript / Node | `package.json` + `pnpm-lock.yaml` | pnpm |
| Go | `go.mod` | go |
| Python | `pyproject.toml` + `uv.lock` | uv |
| Rust | `Cargo.toml` | cargo |

A polyglot repo pins all of its tracks in one `mise.toml`.

## 4. Install only what is missing

Run the live check first (`mise --version`, `npm view pnpm version`, `gh api repos/golangci/golangci-lint/releases/latest`), then install the vendor installer or brew, then pin in the project:

```bash
curl https://mise.run | sh          # or: brew install mise
mise use node@24 pnpm@12 lefthook@2 actionlint@1   # TypeScript
mise use go golangci-lint lefthook@2 actionlint@1   # Go
mise use uv ruff lefthook@2 actionlint@1            # Python
mise use rust lefthook@2 actionlint@1               # Rust
```

Install only what step 1 found missing. `mise use` writes `[tools]` into `mise.toml`.

## 5. Generate

**`mise.toml`** — `[tools]` (step 4), `[settings] lockfile = true`, `min_version`, and the tasks. The same verbs in every repo: `setup dev test lint fmt check build typecheck doctor`. The canonical file is in [toolchain-patterns.md](toolchain-patterns.md). Per-language bodies:

| Verb | TypeScript | Go | Python | Rust |
|---|---|---|---|---|
| lint | `biome check .` | `golangci-lint run ./...` | `ruff check` | `cargo clippy --all-targets -- -D warnings` |
| fmt | `biome format --write .` | `golangci-lint fmt` | `ruff format` | `cargo fmt` |
| typecheck | `tsc --noEmit` | `go build ./...` | — | `cargo check` |
| test | `vitest run` | `go test ./...` | `uv run pytest` | `cargo test` |
| build | `tsdown` | `go build ./...` | `uv build` | `cargo build --release` |

`setup` installs tools, deps and hooks (idempotent). `dev` runs the entry (`node src/cli.ts`, `go run ./cmd/<name>`, `uv run <pkg>`, `cargo run`). `check` runs `lint` + `typecheck` + `test`. `doctor` is one shared script, `mise-tasks/doctor`. `build` declares `sources`/`outputs` so mise can skip it.

**Task runner** — honour `task_runner` from the profile. Unset → package scripts for a pure JS/TS repo, mise tasks for a polyglot one (default per [stack-profile.md](../../core/_shared/stack-profile.md)): mise is already required to pin runtimes, so one tool and one file; tasks pin their own tools and skip work by `sources`/`outputs`. `just` when the profile says so (better for argument-heavy recipes and plain shell, but a separate install; the tested justfile is in [toolchain-patterns.md](toolchain-patterns.md)). `package-scripts`: keep the scripts, mise only pins runtimes. `make`: keep it. See the table in [toolchain-patterns.md](toolchain-patterns.md).

**`lefthook.yml`** — `pre-commit` parallel with `glob` + `{staged_files}`, `stage_fixed: true` for formatters, `pre-push` runs `mise run check`. Every hook command calls tools through `mise x --` (git hooks do not run in an activated shell; a bare `biome` fails with "command not found"). Canonical file in [toolchain-patterns.md](toolchain-patterns.md).

**`.editorconfig`**:

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.go]
indent_style = tab

[Makefile]
indent_style = tab

[*.py]
indent_size = 4

[*.rs]
indent_size = 4
```

**GitHub CLI conventions** — keep to these, do not invent flags: `gh auth status`, `gh pr create --fill`, `gh pr checks --watch`, `gh run watch`. Branch names: `type/short-slug` (e.g. `feat/add-doctor`).

**CI** — `.github/workflows/ci.yml` using `jdx/mise-action`, checkout with `persist-credentials: false`, `permissions: contents: read`, running `mise run check`. The tested file is in [toolchain-patterns.md](toolchain-patterns.md).

## 6. Wire it

```bash
mise trust
mise install
mise lock --platform linux-x64,macos-arm64
```

Commit `mise.toml` and `mise.lock`. Put `lefthook install` inside the `setup` task, not a manual step. README "Getting started" is one line: `mise run setup`.

## 7. Verify

```bash
mise run doctor                     # every line starts "ok" (gh may warn)
mise run check                      # green
```

Then prove the guards work: stage a deliberately bad file (a lint error) and confirm the commit is blocked; run `mise run setup` a second time and confirm it changes nothing.

## References

- [toolchain-patterns.md](toolchain-patterns.md): canonical `mise.toml`, `lefthook.yml`, `mise-tasks/doctor`, justfile, `ci.yml`; pitfalls and their reasons.
- [../_shared/stack-versions.md](../_shared/stack-versions.md): verified versions.
- [../../core/_shared/stack-profile.md](../../core/_shared/stack-profile.md): the profile keys this skill reads.
- [../build-cli/SKILL.md](../build-cli/SKILL.md), [../release-cli/SKILL.md](../release-cli/SKILL.md): the skills that consume these verbs.
- [../../core/_shared/engineering-principles.md](../../core/_shared/engineering-principles.md), [../../core/_shared/security-baseline.md](../../core/_shared/security-baseline.md): seams and secrets.
