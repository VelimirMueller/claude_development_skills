# Release Patterns

Reference for `release-cli`. Each rule has its reason. The pipelines below were linted with `actionlint` 1.7.12 and `zizmor` 1.30.1 (no findings), and the GoReleaser, cargo-dist and uv/npm dry runs were executed on 2026-10-09. No real release was published, so the registry-side steps (trusted publisher setup, tap push, signing in CI) are documented from the official docs and are the part to watch on the first tag. Versions: [stack-versions.md](../_shared/stack-versions.md).

## Rule: SemVer, with the CLI surface as the public API

**Why:** Users script against your flags, exit codes and `--json` output. A version number is the promise about those, so it must be counted over them and not only over the code.
**How to apply:**
- Major: a removed or renamed command or flag, a changed exit code, a renamed or retyped JSON field, a changed config key or precedence.
- Minor: a new command, flag, JSON field, config key or exit code.
- Patch: a fix that keeps all of the above.
- Pre-releases are `1.2.0-rc.1`. They publish under a non-default channel (`next` on npm, a pre-release on GitHub, no Homebrew bump), so `latest` never moves.
- `0.x` is allowed while the contract is moving; say so in the README and keep the same discipline.
**Anti-example:** changing an exit code in a patch because "it was a bug". Scripts that branch on it break.

## Rule: one human-written changelog, the release notes come from it

**Why:** Generated notes list commits; users need to know what changed for them. Reusing the changelog section as the release body keeps one source and makes a missing entry fail the release.
**How to apply:** [Keep a Changelog](https://keepachangelog.com) format in `CHANGELOG.md`: `## [Unreleased]` on top, then `## [1.2.0] - 2026-10-09` with `Added / Changed / Deprecated / Removed / Fixed / Security`. Each PR adds a line under Unreleased. The release commit renames Unreleased to the version and date. `scripts/release-notes.sh` (below) prints that section and exits 1 when it is empty; every release workflow calls it before publishing.
**Alternatives:** `changesets` when a monorepo publishes several npm packages (each PR carries a change file); `release-please` or `git-cliff` when the team already writes Conventional Commits strictly. Both generate the changelog from commit or change files; choose them for the whole repo, not per release.

## Rule: the tag is the release, and the tag must equal the version file

**Why:** Publishing from a branch push or a manual command makes the artifact depend on who ran it. A pushed `vX.Y.Z` tag is an immutable, reviewable trigger, and a check that it equals the manifest version stops the classic "tagged 1.2.0, published 1.1.9".
**How to apply:**
1. Bump the version: `npm version <bump> --no-git-tag-version` (or edit `package.json`), `uv version --bump <part>`, edit `Cargo.toml` `version` (and run `cargo update -w`), Go has no version file (the tag is the version).
2. Move Unreleased to the new version in `CHANGELOG.md`.
3. Commit `release: vX.Y.Z`, open a PR, merge.
4. Tag the merge commit: `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`. Protect tags `v*` in repository rules so only maintainers can create them.
5. The workflow checks tag == version, runs `check`, builds, publishes, creates the GitHub Release.

## Rule: CI releases from a clean runner with the least permissions

**Why:** The release job holds the power to publish under your name. Everything that is not needed is a way in.
**How to apply:**
- `permissions: {}` at workflow level; each job lists only what it needs (`contents: write` for the Release, `id-token: write` for OIDC and signing).
- OIDC trusted publishing instead of stored tokens wherever the registry supports it (npm and PyPI do). A token that does not exist cannot leak.
- A GitHub `environment:` (`npm`, `pypi`) on the publish job; set required reviewers on it if more than one person can push tags. The environment name goes into the registry's trusted-publisher form.
- Third-party actions pinned to full commit SHAs with a version comment ([version-protocol](../../core/_shared/version-protocol.md), [security-baseline](../../core/_shared/security-baseline.md)). `actions/*` too: `zizmor` flags tags under a blanket policy.
- `persist-credentials: false` on checkout; `cache: false` / `enable-cache: false` on setup actions in release jobs (`zizmor` `cache-poisoning`).
- Run `actionlint` and `zizmor` on the workflow files in CI (the toolchain skill adds the hooks).

## Rule: sign what users download, and publish how to verify it

**Why:** A checksum next to the file proves nothing if the same account can swap both. A signature or attestation tied to the workflow identity lets users check that this repository's pipeline produced the file.
**How to apply:** npm: provenance (automatic with trusted publishing from a public repo). PyPI: attestations (automatic with `uv publish` or the PyPA action under trusted publishing). Go: cosign keyless signature of `checksums.txt` plus an SBOM (GoReleaser). Rust: GitHub artifact attestations (`github-attestations = true` in cargo-dist). Put the verification command in the README (section "Verify a download", below).

## Rule: one distribution path per language, plus the package manager people already use

| Language | Primary | Also | Why |
|---|---|---|---|
| TypeScript | npm package with `bin`, built by `tsdown` | `npx`, `pnpm dlx` run it with no install | The audience already has Node; npm gives provenance and no binary to sign |
| Go | GoReleaser archives for linux/darwin/windows x amd64/arm64 | Homebrew cask in your tap; `go install` | Static binaries need no runtime; the cask covers macOS and Linuxbrew |
| Python | wheel + sdist on PyPI (`uv_build`) | `uv tool install`, `pipx install` | Isolated tool environments, no `pip install` into system Python |
| Rust | cargo-dist: tarballs, shell and PowerShell installers | Homebrew formula in your tap; `cargo install --locked` | One tool plans targets, generates the workflow, installers and attestations |

**Why not Docker for CLIs:** a CLI that users run on their files and shells does not fit a container's isolation; ship an image only when CI needs one.

## Rule: a CLI reports its own version two ways, neither of them a network call

**Why:** Bug reports start with "which version". A version command that needs the network fails exactly when you need it.
**How to apply:** `--version` prints `name X.Y.Z`; the value comes from the build (ldflags `-X`, `package.json`, `importlib.metadata`, `env!("CARGO_PKG_VERSION")` which clap's `version` attribute uses). For Go also fall back to the module version, so `go install ...@v1.2.3` is not `dev`:

```go
package main

import (
	"fmt"
	"runtime/debug"
)

// Set by GoReleaser via -ldflags -X. Empty for `go install` and `go build`.
var version = ""

func resolvedVersion() string {
	if version != "" {
		return version
	}
	if bi, ok := debug.ReadBuildInfo(); ok && bi.Main.Version != "" && bi.Main.Version != "(devel)" {
		return bi.Main.Version // `go install module@v1.2.3` records the module version
	}
	return "dev"
}

func main() { fmt.Println(resolvedVersion()) }
```

**Optional update check:** off by default. If you add one: only on a TTY, never in CI, at most once a day with a cached timestamp, a 2 second timeout, output on stderr, disabled by `MYCLI_NO_UPDATE_CHECK=1`, and it never delays the command. Skip it for tools installed by a package manager that already reports updates.

## Shared script: `scripts/release-notes.sh`

```bash
#!/usr/bin/env bash
# Print the CHANGELOG.md section for a tag (v1.2.0 -> "## [1.2.0]"). Fails when the section is missing or empty,
# which doubles as the "changelog was written" gate.
set -euo pipefail

version="${1:?usage: release-notes.sh <tag>}"
version="${version#v}"

notes="$(awk -v v="$version" 'index($0, "## [" v "]") == 1 { f = 1; next } /^## \[/ { f = 0 } f' CHANGELOG.md)"

if [ -z "${notes//[[:space:]]/}" ]; then
  echo "error: CHANGELOG.md has no entry for $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
```

## TypeScript: `.github/workflows/release.yml`

Prerequisites in `package.json`: `repository` with the exact GitHub URL (provenance checks it), `files: ["dist"]`, `engines`, `bin`. Runtime libraries in `dependencies`. Registry side: on npmjs.com open the package, Settings, Trusted Publisher, GitHub Actions: owner, repository, workflow file `release.yml`, environment `npm`. Needs npm CLI >= 11.5.1 (Node 24 ships 11.16) and Node >= 22.14. Each package can hold up to 10 trusted publishers; a saved one cannot be edited, only deleted and re-created; npm does not validate it on save, so a typo shows up on the first publish.

First publish: the npm docs do not say whether a package must exist before a trusted publisher can be attached (unverified). Plan one manual `npm publish` of `0.0.1` by a maintainer, attach the trusted publisher, then publish through the workflow. Do not leave a token behind.

`pnpm pack` then `npm publish <tgz>` is deliberate: pnpm resolves `workspace:` and `catalog:` protocols while packing, and `npm publish` is the client the OIDC docs describe. `pnpm publish` is native since v11 and attaches provenance itself; whether its OIDC exchange works was not verified.

```yaml
name: release

on:
  push:
    tags: ["v*.*.*"]

permissions: {}

jobs:
  publish:
    runs-on: ubuntu-latest
    environment: npm # restrict who can publish; use this exact name in the npm trusted-publisher config
    permissions:
      contents: write # create the GitHub Release
      id-token: write # OIDC: npm trusted publishing + provenance
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5.1.1
        with:
          cache: false # a release must not restore a cache an earlier job could have poisoned
      - run: pnpm install --frozen-lockfile
      - run: mise run check
      - name: Tag must equal package.json version
        run: test "v$(node -p "require('./package.json').version")" = "$GITHUB_REF_NAME"
      - name: Release notes from CHANGELOG.md (fails when missing)
        run: scripts/release-notes.sh "$GITHUB_REF_NAME" > "$RUNNER_TEMP/notes.md"
      - name: Pack with pnpm, publish with npm
        run: |
          dist_tag=latest
          case "$GITHUB_REF_NAME" in *-*) dist_tag=next ;; esac # v1.2.0-rc.1 must not become latest
          pnpm pack --pack-destination "$RUNNER_TEMP/pack"
          npm publish "$RUNNER_TEMP"/pack/*.tgz --access public --tag "$dist_tag"
      - name: GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          flags=()
          case "$GITHUB_REF_NAME" in *-*) flags+=(--prerelease) ;; esac
          gh release create "$GITHUB_REF_NAME" --verify-tag --notes-file "$RUNNER_TEMP/notes.md" "${flags[@]}"
```

Consumer check: `npm audit signatures` verifies registry signatures and provenance of installed packages.

## Go: `.goreleaser.yaml` and workflow

Validated with `goreleaser check` and a full `goreleaser release --snapshot --clean --skip=sign,sbom,publish` on 2026-10-09 (GoReleaser v2.18.3). Notes on the config:

- `version: 2` first; `archives.formats` (plural) and `format_overrides.formats`, since v2.6. The singular `format` is deprecated.
- `brews` is deprecated since v2.10 (marked deprecated in v2.16): use `homebrew_casks`. A cask for a CLI binary is generated with `on_macos` and `on_linux` blocks and a `binary` stanza; users run `brew install --cask acme/tap/mycli`. Completions come from `generate_completions_from_executable` (since v2.15), which needs the CLI to have a `completion` command (cobra has one).
- macOS Gatekeeper quarantines unsigned binaries from a cask. The proper fix is signing and notarizing (Apple Developer account). The `hooks.post.install` below clears the quarantine flag instead; it bypasses a security check, GoReleaser says Apple may disable it, so keep it off when you can sign.
- `signs` with `artifacts: checksum` signs only `checksums.txt` (one signature covers every archive listed in it). Cosign v3 writes a single `.sigstore.json` bundle.
- `-trimpath`, `CGO_ENABLED=0` and `mod_timestamp` make the build reproducible and static.
- The Homebrew tap token is a fine-grained PAT with `contents: write` on the tap repository only. The default `GITHUB_TOKEN` cannot push to another repository.

```yaml
# yaml-language-server: $schema=https://goreleaser.com/static/schema.json
version: 2

project_name: mycli

before:
  hooks:
    - go mod tidy
    - go test ./...

builds:
  - id: mycli
    main: ./cmd/mycli
    binary: mycli
    env: [CGO_ENABLED=0]
    goos: [linux, darwin, windows]
    goarch: [amd64, arm64]
    flags: [-trimpath]
    ldflags:
      - -s -w
      - -X example.com/mycli/internal/cli.version={{ .Version }}
      - -X example.com/mycli/internal/cli.commit={{ .ShortCommit }}
    mod_timestamp: "{{ .CommitTimestamp }}"

archives:
  - id: default
    formats: [tar.gz]
    format_overrides:
      - goos: windows
        formats: [zip]
    name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"

checksum:
  name_template: checksums.txt

# Keyless signing of the checksum file. One signature covers every archive listed in it.
signs:
  - id: cosign-checksums
    cmd: cosign
    signature: "${artifact}.sigstore.json"
    args: [sign-blob, "--bundle=${signature}", "${artifact}", --yes]
    artifacts: checksum
    output: true

sboms:
  - artifacts: archive

changelog:
  use: github
  sort: asc
  filters:
    exclude: ["^docs:", "^test:", "^chore:"]

homebrew_casks:
  - name: mycli
    repository:
      owner: acme
      name: homebrew-tap
      token: "{{ .Env.TAP_GITHUB_TOKEN }}"
    homepage: https://github.com/acme/mycli
    description: Manage widgets.
    generate_completions_from_executable:
      executable: mycli
      args: [completion]
      shell_parameter_format: cobra
    # Unsigned binaries are quarantined by macOS Gatekeeper. This hook clears the flag.
    # It bypasses a security check: prefer signing and notarizing, and keep this off if you can.
    hooks:
      post:
        install: |
          if OS.mac?
            system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{staged_path}/mycli"]
          end
```

```yaml
name: release

on:
  push:
    tags: ["v*.*.*"]

permissions: {}

jobs:
  goreleaser:
    runs-on: ubuntu-latest
    permissions:
      contents: write # GitHub Release
      id-token: write # cosign keyless signing
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0 # GoReleaser reads the full history
          persist-credentials: false
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5.1.1
        with:
          cache: false
      - name: Release notes from CHANGELOG.md (fails when missing)
        run: scripts/release-notes.sh "$GITHUB_REF_NAME" > "$RUNNER_TEMP/notes.md"
      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
      - uses: anchore/sbom-action/download-syft@66cbf4bc1f1c0d2edc94016e65bc221b6bb0ad6c # v0.24.3
      - uses: goreleaser/goreleaser-action@f06c13b6b1a9625abc9e6e439d9c05a8f2190e94 # v7.2.3
        with:
          version: "~> v2"
          args: release --clean --release-notes ${{ runner.temp }}/notes.md
        env:
          GITHUB_TOKEN: ${{ github.token }}
          TAP_GITHUB_TOKEN: ${{ secrets.TAP_GITHUB_TOKEN }} # fine-grained PAT: contents:write on the tap repo only
```

Release notes come from the changelog via `--release-notes`; GoReleaser's own `changelog:` block then only matters for snapshot runs.

Consumer verification (identity and issuer from GoReleaser's docs; replace owner, repository and tag):

```bash
cosign verify-blob \
  --certificate-identity 'https://github.com/acme/mycli/.github/workflows/release.yml@refs/tags/v1.2.0' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --bundle checksums.txt.sigstore.json checksums.txt
sha256sum --check --ignore-missing checksums.txt
```

## Python: `pyproject.toml` and workflow

`uv build --no-sources` ignores `[tool.uv.sources]` so the wheel is built as PyPI users would build it. `uv publish --trusted-publishing always` fails instead of falling back to a missing token. `uv publish` uploads attestations unless `--no-attestations` is set. Registry side: on pypi.org, Account, Publishing, add a *pending* publisher before the first release (project name, owner, repository, workflow `release.yml`, environment `pypi`); the first successful publish creates the project and converts it. A pending publisher does not reserve the name: register and publish promptly. The build backend and version pin are in [build-cli's examples](../build-cli/cli-examples.md).

Check before tagging: `uv build --no-sources && uvx twine check dist/*` (both files `PASSED` on 2026-10-09).

```yaml
name: release

on:
  push:
    tags: ["v*.*.*"]

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5.1.1
        with:
          cache: false
      - run: uv sync --locked
      - run: mise run check
      - name: Tag must equal project version
        run: test "v$(uv version --short)" = "$GITHUB_REF_NAME"
      - name: Release notes from CHANGELOG.md (fails when missing)
        run: |
          mkdir -p release
          scripts/release-notes.sh "$GITHUB_REF_NAME" > release/notes.md
      - run: uv build --no-sources
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: dist
          path: |
            dist/
            release/

  publish:
    needs: build
    runs-on: ubuntu-latest
    environment: pypi # use this exact name in the PyPI trusted-publisher config
    permissions:
      id-token: write # OIDC: PyPI trusted publishing + attestations
      contents: read
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: dist
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
        with:
          enable-cache: false
      - run: uv publish --trusted-publishing always dist/*

  github-release:
    needs: publish
    runs-on: ubuntu-latest
    permissions:
      contents: write # create the GitHub Release
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: dist
      - name: GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
        run: |
          flags=()
          case "$GITHUB_REF_NAME" in *-*) flags+=(--prerelease) ;; esac
          gh release create "$GITHUB_REF_NAME" --verify-tag --notes-file release/notes.md "${flags[@]}" dist/*
```

Alternative: `pypa/gh-action-pypi-publish` (v1.14.2, attestations by default) in the `publish` job instead of `uv publish`; choose it if you do not want `uv` in the publish job.

## Rust: cargo-dist (`dist`)

`dist init` writes `dist-workspace.toml`, a `[profile.dist]` in `Cargo.toml` and `.github/workflows/release.yml`; `dist generate` rewrites the workflow after config changes; `dist plan` lists what a tag would build without building. The binary is `dist` (package `cargo-dist`, 0.33.0 on GitHub; crates.io showed 0.32.0 on 2026-10-09). The workflow is **generated**: change `dist-workspace.toml` and re-run `dist generate`, never hand-edit it (or add `allow-dirty = ["ci"]` and own it).

Verified: with the config below `dist plan` reported tarballs for five targets, a shell installer, a PowerShell installer, a Homebrew formula (`mycli.rb`) and checksums. Registry side: create the repository `acme/homebrew-tap` and a fine-grained PAT stored as the secret `HOMEBREW_TAP_TOKEN` (what cargo-dist's homebrew publisher reads). Cargo.toml needs `repository`, `description`, `license` and, for Homebrew, `homepage`.

```toml
[workspace]
members = ["cargo:."]

[dist]
cargo-dist-version = "0.33.0"
ci = "github"
installers = ["shell", "powershell", "homebrew"]
tap = "acme/homebrew-tap"
publish-jobs = ["homebrew"]
targets = ["aarch64-apple-darwin", "x86_64-apple-darwin", "aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu", "x86_64-pc-windows-msvc"]
github-attestations = true
pr-run-mode = "plan"

[dist.github-action-commits]
"actions/checkout" = "3d3c42e5aac5ba805825da76410c181273ba90b1"
"actions/upload-artifact" = "cf430e030ddbb5b0abf93d22962f4752f3646cd9"
"actions/download-artifact" = "9000827ccba6bdab643e8b6fd33ac0654aef8333"
"actions/attest" = "1e69f48acb82d1966a394da916b4c1698aa569d6"
```

`github-action-commits` pins the actions in the generated workflow to SHAs (dist's default is tags such as `actions/checkout@v6`). With it, `zizmor` still reported findings in the generated file on 2026-10-09: `template-injection` (one error, three warnings), `excessive-permissions` and `unpinned-images` (the `container` matrix entry). They come from dist's template. Run `zizmor` on it, read each finding, and either accept it in a `zizmor.yml` ignore with a reason or wait for the template to change. Do not hide them.

Consumer verification: `gh attestation verify <file> --repo acme/mycli`.

## Rule: tell users how to install and how to verify, in the README

**Why:** The install line is the product's front door; a verify line is what security reviewers ask for.
**How to apply:** a table of install commands, then "Verify a download":

| Language | Install | Verify |
|---|---|---|
| TypeScript | `npm i -g mycli`, `npx mycli` | `npm audit signatures` |
| Go | `brew install --cask acme/tap/mycli`, `go install example.com/mycli/cmd/mycli@latest`, or an archive from Releases | `cosign verify-blob` as above, then `sha256sum --check` |
| Python | `uv tool install mycli`, `pipx install mycli` | provenance shown on the PyPI file page |
| Rust | `curl --proto '=https' --tlsv1.2 -LsSf https://github.com/acme/mycli/releases/latest/download/mycli-installer.sh \| sh`, `brew install acme/tap/mycli`, `cargo install mycli --locked` | `gh attestation verify` |

The shell-installer URL follows cargo-dist's `<package>-installer.sh` naming from the `dist plan` output above.

## Rule: first release is a release candidate

**Why:** The first tag exercises every credential, permission and registry setting at once. A mistake on `v1.0.0` is a public version number you cannot reuse (npm and PyPI never allow re-upload).
**How to apply:** tag `v0.1.0-rc.1` first. It publishes to `next` or as a pre-release, proves the OIDC setup, and costs nothing if wrong. Delete the pre-release and the tag; the next attempt is `-rc.2`.

## When to deviate

- **Internal tools:** skip registry publication; build with the same GoReleaser/dist/uv config and attach artifacts to the GitHub Release, or publish to the private registry with its own auth.
- **Monorepo, several packages:** `changesets` (npm) or per-package tags (`pkg-v1.2.0`) with a path filter; cargo-dist supports `PACKAGE/VERSION` tags.
- **Private repositories:** npm provenance and GitHub artifact attestations are not generated for private repositories on every plan; check the plan before promising them in the README.
- **No Apple Developer account:** keep the quarantine hook, say so in the README, and expect to revisit it.
- **Self-hosted runners:** npm trusted publishing supports only cloud-hosted runners; use a scoped, expiring token there.
