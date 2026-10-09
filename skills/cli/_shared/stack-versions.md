# Stack Versions — CLI catalogue

Verified on 2026-10-09. Re-verify before scaffolding; this is a floor, not a pin. Protocol: [version-protocol](../../core/_shared/version-protocol.md). Ring labels: [tech-radar](../../core/_shared/tech-radar.md).

Status words: **stable**, **rc/beta**, **announced**, **unverified**.

## CLI libraries (the default is the first row of each language)

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `commander` (TS default) | 15.0.0, stable | `npm view commander version`; CHANGELOG | ESM only, Node >= 22.12, zero dependencies. 14.x gets security fixes to May 2027 |
| `@clack/prompts` | 1.8.1, stable | `npm view` | Interactive prompts only; Node >= 20.12 |
| `citty` (alternative) | 0.2.2, stable (0.x) | `npm view`; GitHub releases | UnJS; lazy subcommands, plugins; pre-1.0 |
| `clipanion` | 4.0.0-rc.4 on `latest`, last publish 2024-09-06 | `npm view clipanion` | rc/beta and idle: not recommended |
| `cac` | 7.0.1, stable | `npm view` | Tiny; no first-class typed args. Not recommended as a default |
| `smol-toml` | 1.9.0, stable | `npm view` | TOML parse for config files |
| `env-paths` | 4.0.0, stable | `npm view` | XDG-correct config/cache dirs on every OS |
| `cobra` (Go default) | v1.10.2 (2025-12-03), stable | `proxy.golang.org` | Repo still active (pushed 2026-07) |
| `urfave/cli/v3` (alternative) | v3.14.0 (2026-10-02), stable | `proxy.golang.org` | Active; single-package API |
| `kong` (alternative) | v1.16.1 (2026-08-09), stable | `proxy.golang.org` | Struct-tag CLIs; no GitHub release objects, tags only |
| `charmbracelet/fang` | v1.0.0 (2025-12-20) | `proxy.golang.org` | Optional styled cobra wrapper; not used by default |
| `charmbracelet/huh/v2` | v2.0.3 | `proxy.golang.org` | Interactive forms (Go) |
| `pelletier/go-toml/v2` | v2.4.3 | `proxy.golang.org` | TOML config |
| `golang.org/x/term` | v0.46.0 | `proxy.golang.org` | TTY detection |
| `typer` (Python default) | 0.27.3, stable | PyPI JSON; release notes | Vendors Click since 0.27: no separate `click` dependency. Python >= 3.10 |
| `click` (alternative) | 8.5.0, stable | PyPI JSON | Standalone use when you do not want type-hint parsing |
| `cyclopts` (alternative) | 5.2.0, stable | PyPI JSON | Python >= 3.11; best typing story; smaller ecosystem |
| `platformdirs` | 4.12.4 | PyPI JSON | XDG config dirs |
| `uv_build` | 0.12.24 | PyPI JSON | Default build backend for pure-Python CLIs |
| `clap` (Rust default) | 4.6.7, stable | crates.io `max_stable_version` | `derive` feature; `try_parse` + `err.exit()` gives exit 2 |
| `clap_complete` / `clap_mangen` | 4.6.11 / 0.3.3 | crates.io | Completions and man pages |
| `toml` / `serde` / `serde_json` / `thiserror` / `dirs` | 1.1.8 / 1.0.229 / 1.0.151 / 2.0.21 / 7.0.0 | crates.io | Config, errors, config dir |
| `assert_cmd` / `insta` | 2.2.2 / 1.49.0 | crates.io | Spawn-the-binary tests and help snapshots |

## Distribution tooling

| Tool | Line | Verified from | Note |
|---|---|---|---|
| npm CLI | 11.16.0 ships with Node 24.18; trusted publishing needs >= 11.5.1 and Node >= 22.14 | `npm -v`; docs.npmjs.com/trusted-publishers | OIDC, no stored token. Provenance is automatic from a public repo on a cloud runner. Up to 10 trusted publishers per package |
| pnpm | 12.10.1, stable | `npm view pnpm` | `pnpm publish` is native since v11; docs name `pnpm pack && npm publish *.tgz` as the workaround. OIDC exchange by pnpm itself: **unverified** |
| `tsdown` | 0.23.0 (0.x), stable | `npm view`; tsup README | Rolldown-based; `tsup` (8.5.1, last publish 2025-11) says it is unmaintained and points here |
| GoReleaser | v2.18.3, stable | `gh api`; goreleaser.com; `goreleaser check` run on 2026-10-09 | Config `version: 2`. `archives.formats` (plural) since v2.6; `brews` deprecated v2.10, replaced by `homebrew_casks` |
| `goreleaser/goreleaser-action` | v7.2.3 | `gh api` | `version: "~> v2"` |
| cosign | v3.1.3 | `gh api` | `sign-blob --bundle=<file>.sigstore.json --yes`; installer action v4.1.2 |
| syft | v1.54.1 | `gh api` | GoReleaser `sboms:` default is syft, SPDX JSON |
| cargo-dist (binary: `dist`) | 0.33.0 on GitHub (crates.io `cargo-dist` shows 0.32.0) | `gh api`; `dist init` run on 2026-10-09 | Config in `dist-workspace.toml`; generates `.github/workflows/release.yml`; `github-attestations = true` opt-in |
| uv | 0.12.24 | PyPI JSON | `uv build --no-sources`, `uv publish` (trusted publishing automatic on GitHub Actions) |
| PyPI trusted publishing | docs.pypi.org | WebFetch | Pending publisher allows the first release without a token; it does not reserve the name |
| `pypa/gh-action-pypi-publish` | v1.14.2 | `gh api` | Alternative to `uv publish`; attestations on by default |
| Homebrew tap | repo named `homebrew-<name>` | docs.brew.sh/Taps; GoReleaser docs | Core tap rejects third-party prebuilt binaries |
| `softprops/action-gh-release` | v3.0.3 | `gh api` | Not used: `gh release create` needs no third-party action |
| `orhun/git-cliff` / `release-please` / `changesets` | v2.14.2 / v5.0.0 / `@changesets/cli` 3.0.3 | `gh api`; `npm view` | Changelog generators; see `release-patterns.md` |

## Developer toolchain

| Tool | Line | Verified from | Note |
|---|---|---|---|
| mise | 2026.10.5 (2026-10-08) | `gh api`; `mise --version` run locally | `mise.lock` via `[settings] lockfile = true`; `minimum_release_age` hides brand-new releases; set `GITHUB_TOKEN` or installs hit the 60/hour API limit |
| `jdx/mise-action` | v5.1.1 | `gh api` | Set `cache: false` in release workflows (zizmor `cache-poisoning`) |
| just | 1.58.0 | `gh api`; run locally | Only when profile says `task_runner: just` |
| lefthook | 2.2.1 on GitHub and npm; mise registry served 2.2.0 | `gh api`; `npm view` | `jobs:` syntax (since 1.10.0), `glob` list since 1.10.10 |
| Biome | 2.5.15 | `npm view` | `biome init` writes `"preset": "recommended"` |
| TypeScript | 7.0.2 | `npm view` | `erasableSyntaxOnly` for Node type stripping |
| Vitest | 5.0.3 | `npm view` | Node `^22.12 \|\| ^24 \|\| >=26` |
| ruff | 0.16.10 | PyPI JSON | |
| golangci-lint | v2.14.0 | `gh api`; run locally | Config `version: "2"`, `formatters:` section |
| actionlint / zizmor | v1.7.12 / v1.30.1 | `gh api` | Both run clean on the workflows in `release-patterns.md` |
| GitHub CLI | v2.102.0 | `gh api` | |
| Node.js | 24 active LTS (24.21.0); 26 is Current and becomes LTS on 2026-10-28 | endoflife.date | Re-check after 2026-10-28 |
| Go / Rust / Python | go1.27.2 / 1.99.0 / 3.14.8 (3.15 not out) | endoflife.date; `static.rust-lang.org` | |
| GitHub Actions used | checkout v7.0.1, setup-go v7.0.0, upload-artifact v7.0.2, download-artifact v8.0.2, setup-uv v10.2.0 | `gh api` | SHAs in `release-patterns.md`; re-resolve before copying |

Unverified: `pnpm publish` OIDC behaviour on its own; Homebrew casks on Linux (GoReleaser's docs do not say); `ty` and other Astral type checkers are out of scope here.

## Rule: Node CLIs target the oldest supported LTS, not the newest
**Why:** A CLI runs on machines you do not control. Commander 15 needs Node >= 22.12 and `import.meta.main` needs >= 22.18 (it shipped in 24.2 and 22.18), so 22.18 is the honest floor.
**How to apply:** `engines.node: ">=22.18"`; build target `node22`; CI runs the oldest and newest LTS. Develop on the version in `mise.toml`.

## Rule: Pin the build backend with a compatible range
**Why:** `uv init` writes `uv_build>=0.11.30,<0.12.0` for the uv that made it. A newer uv would fail to build against that range after the next uv minor.
**How to apply:** `requires = ["uv_build>=0.12.24,<0.13"]`; raise both numbers together with a deliberate bump.

## When to deviate
- A repo already on Click, yargs, urfave v2 or clap 3: keep it. Migration is a task of its own.
- A shop that bans 0.x dependencies: use `commander` (stable 15) and avoid `citty`, `tsdown` (use `tsc` or `esbuild` directly).
