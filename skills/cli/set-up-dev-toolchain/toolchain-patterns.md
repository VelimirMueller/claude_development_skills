# Toolchain patterns

Reference for `set-up-dev-toolchain`. Everything below ran green on 2026-10-09. The `mise.toml`, `lefthook.yml` and `mise-tasks/doctor` below are the canonical examples; the justfile is the tested `just` variant for `task_runner: just`.

## Canonical setup (tested 2026-10-09)

### `mise.toml`

```toml
min_version = "2026.10.0"

[settings]
lockfile = true

[tools]
node = "24"
pnpm = "12"
lefthook = "2"
actionlint = "1"

[env]
_.path = ["{{config_root}}/node_modules/.bin"]

[tasks.setup]
description = "Install tools, dependencies and git hooks (idempotent)"
run = ["mise install", "pnpm install --frozen-lockfile", "lefthook install"]

[tasks.dev]
description = "Run the CLI from source"
run = "node src/cli.ts"

[tasks.fmt]
description = "Format everything"
run = "biome format --write ."

[tasks.lint]
description = "Lint without changing files"
run = "biome check ."

[tasks.typecheck]
description = "Type-check"
run = "tsc --noEmit"

[tasks.test]
description = "Run tests"
depends = ["build"]
run = "vitest run"

[tasks.build]
description = "Build dist/"
sources = ["src/**/*.ts", "tsdown.config.ts", "package.json"]
outputs = ["dist/**"]
run = "tsdown"

[tasks.check]
description = "Everything CI runs: lint, typecheck, test"
depends = ["lint", "typecheck", "test"]
```

`doctor` is not in `[tasks]`: mise discovers it from `mise-tasks/doctor` (below). `test` depends on `build`; `check` depends on `lint typecheck test`.

### `lefthook.yml`

```yaml
# yaml-language-server: $schema=https://lefthook.dev/schema.json
min_version: 2.2.0
output: [failure, summary]

pre-commit:
  parallel: true
  jobs:
    - name: biome
      glob: "*.{ts,tsx,js,jsx,json,jsonc,css}"
      run: mise x -- biome check --write --no-errors-on-unmatched {staged_files}
      stage_fixed: true
    - name: actionlint
      glob: ".github/workflows/*.{yml,yaml}"
      run: mise x -- actionlint {staged_files}

pre-push:
  jobs:
    - name: check
      run: mise run check
```

### `mise-tasks/doctor`

```bash
#!/usr/bin/env bash
#MISE description="Verify the toolchain matches the pins"
set -euo pipefail
fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; fail=1; }

command -v mise >/dev/null && ok "mise $(mise --version | cut -d' ' -f1)" || bad "mise missing"

# every pinned tool is installed at a version that satisfies mise.toml
if mise ls --current --missing --quiet 2>/dev/null | grep -q .; then
  bad "tools pinned in mise.toml but not installed: run 'mise run setup'"
else
  ok "pinned tools installed"
fi

[ -f mise.lock ] && ok "mise.lock present" || bad "mise.lock missing: run 'mise lock' and commit it"

if [ -x "$(git rev-parse --git-path hooks)/pre-commit" ] && grep -q lefthook "$(git rev-parse --git-path hooks)/pre-commit"; then
  ok "git hooks installed"
else
  bad "git hooks not installed: run 'lefthook install'"
fi

if gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else printf '  warn  gh not authenticated (needed for PRs)\n'; fi

exit "$fail"
```

### `justfile` (when `task_runner: just`)

```just
set shell := ["bash", "-euo", "pipefail", "-c"]
default:
    @just --list
setup:
    mise install
    pnpm install --frozen-lockfile
    lefthook install
dev *args:
    node src/cli.ts {{ args }}
fmt:
    biome format --write .
lint:
    biome check .
typecheck:
    tsc --noEmit
build:
    tsdown
test: build
    vitest run
check: lint typecheck test
doctor:
    mise-tasks/doctor
```

### `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5.1.1
        with:
          cache: true
      - run: mise install --locked
      - run: mise run check
```

Release workflows set `cache: false` (zizmor flags `cache-poisoning` there); check workflows keep `cache: true`.

## Why mise tasks, just, package scripts, make

| Runner | One-line reason |
|---|---|
| mise tasks | mise is already required to pin runtimes, so one tool and one file; tasks pin their own tools and skip work by `sources`/`outputs` |
| just | plain shell with argument-heavy recipes and `{{ args }}`; a separate install |
| package scripts | already in `package.json`, no new file; scripts cannot pin their own tools or skip work |
| make | ubiquitous and understood; weak for named flags and argument passing |

## Verified versions (2026-10-09)

mise 2026.10.5 · just 1.58.0 · lefthook 2.2.1 (config `min_version: 2.2.0`) · biome 2.5.15 · pnpm 12.10.1 · node 24 LTS · golangci-lint v2.14.0 (config `version: "2"`, `linters.default: standard`, `formatters.enable: [gofumpt, goimports]`) · ruff 0.16.10 · uv 0.12.24. Re-verify live before scaffolding: [stack-versions.md](../_shared/stack-versions.md).

## Rule: hooks call tools through `mise x --`

**Why:** git hooks run in a bare environment, not your activated shell. The mise shims are not on the hook's `PATH`, so a bare `biome` fails with `biome: command not found`. Verified failure.

**How to apply:** every hook command prefixes the tool with `mise x --` (`mise x -- biome check --write …`). The `mise run check` in `pre-push` already goes through mise, so it needs no prefix.

**Anti-example:** `run: biome check {staged_files}` in `lefthook.yml` — the commit fails with "command not found" and the developer cannot tell why.

## Rule: give mise a `GITHUB_TOKEN` or installs hit the API limit

**Why:** mise installs tools from GitHub releases. Anonymous requests cap at 60/hour; a cold repo with node, pnpm and a few tools can cross it mid-install. Locally and in CI the symptom is the same.

**How to apply:** set `GITHUB_TOKEN` in the shell (and in CI). `jdx/mise-action` passes the workflow token automatically, so the CI file above needs no extra step; local installs need `GITHUB_TOKEN` exported.

**Anti-example:** running `mise install` on a fresh clone with no token, then filing a bug for "rate limit" when the second tool fails to download.

## Rule: a task name lives in one format only

**Why:** mise resolves tasks from `[tasks.<name>]` in `mise.toml` and from `mise-tasks/<name>` files. Defining the same name in both is ambiguous and fails.

**How to apply:** define each task in exactly one place. Short `run` tasks stay in `mise.toml`; the doctor script is long shell, so it lives in `mise-tasks/doctor` with a `#MISE description=…` header and is not repeated in `[tasks]`.

**Anti-example:** `[tasks.doctor]` in `mise.toml` plus a `mise-tasks/doctor` file — mise errors on the duplicate name.

## Rule: `depends` run in parallel, ordered steps use a `run` array

**Why:** mise runs the tasks in `depends = [...]` concurrently, not in order. Anyone reading `depends = ["lint", "typecheck", "test"]` as "lint then typecheck then test" gets surprised by interleaved output. A `run = ["a", "b", "c"]` array runs in order.

**How to apply:** use `depends` when order does not matter (the check tasks above). Use a `run` array when one step must finish before the next (setup: `mise install`, then `pnpm install --frozen-lockfile`, then `lefthook install`).

**Anti-example:** `depends = ["setup-tools", "install-deps", "install-hooks"]` where the hooks install must come after deps — they race.

## Rule: commit `mise.lock` and install `--locked`

**Why:** without `mise.lock`, every machine and CI resolve tool versions independently, so a new patch release changes what "installed" means. `minimum_release_age` in `[settings]` hides brand-new releases so a same-day patch does not break a build.

**How to apply:** commit `mise.lock`. CI runs `mise install --locked` so it uses exactly the locked versions. Generate or refresh the lock with `mise lock --platform linux-x64,macos-arm64` (both platforms, or CI on Linux locks only Linux and local macOS drift).

**Anti-example:** `.gitignore`-ing `mise.lock` and running a bare `mise install` everywhere — CI and each developer drift to different tool versions.

## Rule: lefthook `glob` `**` needs `doublestar` to cross directories

**Why:** a lefthook `glob` pattern `**` matches one or more directories only when `glob_matcher: doublestar` is set; the default matcher treats `**` like `*`. Nested files then slip past the hook silently.

**How to apply:** the canonical hooks above match files at the repo root (`*.{ts,…}`, `.github/workflows/*.{yml,yaml}`), which needs no flag. If a job must match nested paths, set `glob_matcher: doublestar` on that job.

**Anti-example:** `glob: "**/*.go"` with no matcher set, expecting every Go file under `internal/` to be linted — only top-level files match.

## Rule: biome must honour `.gitignore`

**Why:** without `vcs.useIgnoreFile`, biome lints and formats `dist/` and `node_modules/`, wastes time and can rewrite generated files.

**How to apply:** set `vcs: { enabled: true, clientKind: "git", useIgnoreFile: true }` in `biome.json`. Then `biome check .` skips ignored paths.

**Anti-example:** `biome format --write .` reformatting committed build output because `vcs.useIgnoreFile` was left unset.

## Rule: the doctor task checks the whole chain

**Why:** a broken toolchain should fail loudly in one command, not as a surprise at commit or CI time.

**How to apply:** the doctor script checks, in order: mise is present; every pinned tool is installed (`mise ls --current --missing`); `mise.lock` is present; git hooks are installed (a `pre-commit` that mentions lefthook); `gh` is authenticated — warn only, never fail, because PRs are optional to develop.

**Anti-example:** a doctor that only prints `mise --version` and exits 0 while hooks are missing and the lockfile is gone.

## Rule: actionlint and zizmor check the workflow files

**Why:** workflow YAML breaks in ways GitHub's runner accepts until the first push; a wrong `on:` trigger or an insecure action version is a silent regression.

**How to apply:** run actionlint on `.github/workflows/*.{yml,yaml}` from a lefthook job (the canonical `pre-commit` above), and run zizmor over the same files as a second job. Both are pinned in `mise.toml`.

**Anti-example:** relying on `github.actions` to catch a bad `permissions` block — it only fails when the workflow runs.

## When to deviate

- A repo already on husky, make or just: keep it and only fill gaps. Migration is a separate task, not this one.
- `task_runner: package-scripts`: leave `package.json` scripts alone; mise only pins runtimes, and the hooks still call tools through `mise x --`.
- A repo that already publishes to a strict internal registry: keep its install path; the lockfile rule still applies.
- Monorepo with per-package `stack-profile.md`: one `mise.toml` at the root, one `doctor` per package that checks its own track.
