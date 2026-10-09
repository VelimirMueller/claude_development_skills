# Scaffold Patterns

Reference for [scaffold-bevy-game](SKILL.md). Versions: [stack-versions](../_shared/stack-versions.md). Bevy 0.20, edition 2024.

## Rule: one package, `lib.rs` + `main.rs`
**Why:** Integration tests in `tests/` link against the library target only. A game that lives in `main.rs` cannot be tested without a window. A single package keeps one `Cargo.toml` and one compile unit until a second consumer exists.
**How to apply:** All plugins live in the library. `main.rs` builds `App`, adds `DefaultPlugins` and `GamePlugin`, and runs. Move to a workspace when a second crate has a real reason (dedicated server, asset-pipeline tool, shared network protocol), not for tidiness.
**Anti-example:** `main.rs` with 400 lines of `add_systems` and `spawn` calls.

## Rule: pick Bevy features, do not take `default`
**Why:** `default` pulls in 3D, PBR, glTF, and every audio codec. A 2D game compiles and ships roughly what it needs with `["2d", "ui", "audio"]`. Since 0.19, `audio` is no longer implied by `2d`, `3d` or `ui`, and `ui` is no longer implied by `2d` or `3d`, so list them.
**How to apply:**
```toml
[dependencies]
bevy = { version = "0.20", default-features = false, features = ["2d", "ui", "audio"] }
```
3D: `["3d", "ui", "audio"]`. Headless server or test tool: `default-features = false, features = ["default_app"]` (adds assets, log, state; no window or renderer).
**Anti-example:** `bevy = "0.20"` for a pixel-art platformer.

## Rule: `dev` feature for dev-only speed, never in release
**Why:** `bevy/dynamic_linking` links Bevy as a shared library and cuts incremental link time. It cannot ship: the binary then needs the dylib next to it. `bevy/dev` bundles `debug`, `bevy_dev_tools`, `render_dev_tools` and `file_watcher` (asset hot reload). One feature named `dev` makes the rule "release builds never use it" a single check.
**How to apply:**
```toml
[features]
default = []
dev = ["bevy/dev", "bevy/dynamic_linking"]
```
Run `cargo run --features dev`. Add `bevy/embedded_watcher` to `dev` if you hot reload embedded assets. `default = []` keeps `cargo build --release` and CI correct without flags. On Windows, dynamic linking also needs the dependency opt-level rule below.
**Anti-example:** `default = ["bevy/dynamic_linking"]` — a release build ships a binary that fails to start on a clean machine.

## Rule: optimize dependencies in dev, lightly optimize your own crate
**Why:** At opt-level 0 Bevy runs at a few frames per second; physics and rendering are unplayable. Dependencies rarely change, so compile them once at opt-level 3. Your own crate at opt-level 1 keeps rebuilds fast and still runs playable.
**How to apply:**
```toml
[profile.dev]
opt-level = 1

[profile.dev.package."*"]
opt-level = 3
```
**Anti-example:** `opt-level = 3` on the whole dev profile — every edit rebuilds your crate at full optimization.

## Rule: linker — keep the platform default, fix only where it is slow
**Why:** macOS ships the fast `ld-prime`. Rust uses `rust-lld` by default for `x86_64-unknown-linux-gnu` since 1.90. Extra config there only adds failure modes. Linux aarch64 and Windows still benefit.
**How to apply:**
- macOS: nothing.
- Linux x86_64: nothing. `mold` is an opt-in extra (`-C link-arg=-fuse-ld=mold` with `clang`); Bevy's guide says up to 5x faster than lld with stability caveats.
- Linux aarch64: install `clang` and `lld`, then in `.cargo/config.toml`:
```toml
[target.aarch64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=lld"]
```
- Windows (MSVC): `[target.x86_64-pc-windows-msvc]` with `linker = "rust-lld.exe"`; needs `cargo-binutils` and the `llvm-tools-preview` component per Bevy's setup guide. Re-read that guide at scaffold time.
**Anti-example:** a committed `.cargo/config.toml` with `-fuse-ld=mold` that breaks every machine without mold.

## Rule: every feature is a plugin; `GamePlugin` composes them
**Why:** A plugin is the unit of removal, test, and ownership. `GamePlugin` is the one place the whole game is listed, so "what runs?" has one answer. Tests add only the plugin under test.
**How to apply:** `app.add_plugins((core::CorePlugin, player::PlayerPlugin, enemy::EnemyPlugin))` in `lib.rs`. A plugin owns its components, messages, systems and the `OnEnter`/`OnExit` wiring for its feature. See [structure-bevy-app](../structure-bevy-app/SKILL.md).

## Rule: pin the toolchain by components, not by number
**Why:** Bevy's MSRV follows latest stable; a numbered pin blocks patches. CI and local must agree on clippy and rustfmt being installed.
**How to apply:**
```toml
# rust-toolchain.toml
[toolchain]
channel = "stable"
components = ["clippy", "rustfmt"]
targets = ["wasm32-unknown-unknown"]   # web track only
```
`Cargo.toml`: `edition = "2024"`, `rust-version = "1.97.1"`.

## Rule: lints in `Cargo.toml`, `-D warnings` only in CI
**Why:** Bevy injects system parameters, so clippy's `too_many_arguments` and `type_complexity` fire on correct code. Declaring lint levels in the manifest applies them to every contributor; `-D warnings` on the command line in CI keeps new warnings from landing without blocking local experiments.
**How to apply:**
```toml
[lints.clippy]
too_many_arguments = "allow"
type_complexity = "allow"
```
Run `cargo clippy --all-targets -- -D warnings` in CI. Do not allow more lints than these two without a recorded reason.

## Rule: tasks in the profile's runner
**Why:** One command per intent keeps the README short and CI identical to local. `tests.layout` and `task_runner` come from the stack profile; `just` is the default for polyglot repos.
**How to apply:**
```just
default: check

run:
    cargo run --features dev

check:
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
    cargo nextest run
    cargo test --doc

web:
    cargo build --profile wasm-release --target wasm32-unknown-unknown
```
With `mise` or `make`, write the same four targets.

## Rule: CI mirrors `just check`
**Why:** A CI that differs from the local check finds problems only after the push. Bevy needs system libraries on Linux even for `clippy`, because the audio and input crates link them.
**How to apply:**
```yaml
# .github/workflows/ci.yml
name: ci
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: sudo apt-get update && sudo apt-get install -y g++ pkg-config libx11-dev libasound2-dev libudev-dev libxkbcommon-x11-0
      - uses: dtolnay/rust-toolchain@686976e191b89faba57d3206551f0f330d8cb249 # stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2
      - uses: taiki-e/install-action@f7e5d7c961414b23f5b25b2da9294395d08513ad # v2
        with:
          tool: cargo-nextest
      - run: cargo fmt --check
      - run: cargo clippy --all-targets -- -D warnings
      - run: cargo nextest run
      - run: cargo test --doc
  web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: dtolnay/rust-toolchain@686976e191b89faba57d3206551f0f330d8cb249 # stable
        with:
          targets: wasm32-unknown-unknown
      - uses: Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6 # v2
      - run: cargo check --target wasm32-unknown-unknown --lib
```
Drop the `web` job on the desktop track. Re-verify action SHAs when scaffolding (`gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha`; a branch pin like `dtolnay/rust-toolchain` resolves to its current commit). Pin actions to a commit SHA — the [security baseline](../../core/_shared/security-baseline.md) requires it.

## Rule: web builds use a size profile and need no `getrandom` config unless you use `rand`
**Why:** Release builds optimize for speed; a browser download wants size. On the verify date Bevy 0.20 itself pulled no `getrandom` on `wasm32-unknown-unknown`; a game that adds `rand` does, and then needs the `wasm_js` backend.
**How to apply:**
```toml
[profile.wasm-release]
inherits = "release"
opt-level = "s"
strip = "symbols"
```
`strip = "symbols"` instead of Bevy's guide value `"debuginfo"`: measured 36 MB vs 66 MB raw output on a reference game (2026-10-09). Build: `cargo build --profile wasm-release --target wasm32-unknown-unknown`, then `wasm-bindgen --out-dir dist --target web target/wasm32-unknown-unknown/wasm-release/<name>.wasm`. Optional `wasm-opt -Oz` (slow, measure the gain). If the game uses `rand`/`getrandom`, follow the `getrandom` crate's current wasm instructions and verify them; do not copy a flag from memory.
Audio does not start in browsers before a user gesture; show a "click to start" state.
**Anti-example:** shipping `target/release` wasm (tens of MB) to the web.

## Rule: `Cargo.lock` is committed
**Why:** A game is an application. Bevy minors break the API; an unpinned transitive update breaks CI on a day nobody touched the code.
**How to apply:** Commit the lockfile. Update with `cargo update -p bevy` on purpose, in its own PR.

## When to deviate
- **Template instead of hand-rolling:** the community `bevy_new_2d` template and the Bevy CLI cover similar ground, but at the verify date the template still targeted Bevy 0.19 and the CLI was alpha. Use them if the version matches; do not adopt them as a dependency of these skills.
- **Workspace from day one:** when the game ships a dedicated server or an editor binary sharing types.
- **Single crate with `main.rs` only:** a throwaway jam prototype that will never get a test.
- **Faster linker config on Linux x86_64:** when link time is the measured bottleneck, try `mold`; keep it out of the committed config unless the whole team has it.
