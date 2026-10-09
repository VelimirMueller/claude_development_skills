# Stack Versions (game)

Version policy for Bevy games scaffolded by these skills. Dated 2026-10-09.
Re-verify before scaffolding; this is a floor, not a pin. Method: [version-protocol.md](../../core/_shared/version-protocol.md).

## Current lines

| Tool | Line | Verified from | Note |
|---|---|---|---|
| `bevy` | 0.20 (0.20.0, released 2026-10-08) | crates.io API `max_stable_version`; bevy.org 0.19→0.20 migration guide | One day old on the verify date. Every snippet in these skills compiled against 0.20.0 |
| Rust toolchain | stable 1.99.0 | static.rust-lang.org `channel-rust-stable.toml` (2026-09-28 build) | Bevy 0.20 sets `rust-version = 1.97.1`; Bevy's own policy is "latest stable" |
| Rust edition | 2024 | `cargo` 1.99 default for `cargo new` | Set `edition = "2024"` and `rust-version = "1.97.1"` |
| `cargo-nextest` | 0.9.148 | crates.io | `cargo install cargo-nextest --locked` or `taiki-e/install-action` in CI |
| `proptest` | 1.11 | crates.io | Dev-dependency only |
| `wasm-bindgen-cli` | 0.2.129 | crates.io | Must match the `wasm-bindgen` crate version in `Cargo.lock` exactly |
| `bevy_asset_loader` | 0.28.0-rc.1 targets Bevy 0.20 rc; 0.27.0 stable targets Bevy 0.19 | crates.io dependency lists | No stable release for Bevy 0.20 on the verify date. Native loading is the default in `manage-bevy-assets` |
| `bevy_common_assets` | 0.18.0-rc.1 targets Bevy 0.20 rc; 0.17.0 stable targets Bevy 0.19 | crates.io dependency lists | Same situation |
| `avian2d` | 0.7.0 requires `bevy ^0.19` | crates.io dependency list | No 0.20 release yet. Physics decision: see below |
| `leafwing-input-manager` | 0.21.0 requires `bevy ^0.19` | crates.io dependency list | No 0.20 release yet |
| `bevy_rapier2d`, `bevy_egui`, `bevy_tweening` | unverified for Bevy 0.20 | crates.io `max_stable_version` only | Check each crate's `bevy` requirement before adding |
| Bevy CLI (`bevy_cli`) | 0.1.0-alpha.2, installed from git (`cli-v0.1.0-alpha.2`) | `TheBevyFlock/bevy_cli` README | Not on crates.io, alpha. Optional, never required by a skill |
| `bevy_lint` | v0.6 (Bevy 0.18), 0.7.0-dev (Bevy 0.18); needs a pinned nightly | bevy_cli linter compatibility table | No Bevy 0.20 support. Skipped |
| Tracy | version tied to `tracing-tracy`/`tracy-client` in `Cargo.lock` | Bevy `docs/profiling.md` (v0.20.0) | Find it with `cargo tree --features bevy/trace_tracy \| grep tracy`, then match the table in `rust_tracy_client` |

## Rule: Bevy line — the newest stable, unless a needed crate is behind
**Why:** Bevy changes APIs every release (0.20 alone changed observer generics, `NextState` method names, feature sets, and the scene→world renames). Mixing a plugin built for 0.19 with Bevy 0.20 does not compile. Starting on the newest line avoids a migration in month one, but a crate you cannot do without sets the ceiling.
**How to apply:** Before scaffolding, run `curl -s -A skills https://crates.io/api/v1/crates/<crate>/<version>/dependencies` for each third-party Bevy crate and read the `bevy` requirement. If every crate supports the newest Bevy, use it. If a core crate (physics, input) is one line behind, stay on that line for the whole project and say so in the profile notes. Never `[patch]` a plugin to a Bevy it does not declare.
**Anti-example:** `bevy = "0.20"` next to `avian2d = "0.7"` — Cargo resolves two Bevy versions and the types never match.

## Rule: Bevy caret as a minor pin
**Why:** For `0.x` crates a caret (`"0.20"`) means `>=0.20.0, <0.21.0`. Patch releases fix bugs; the next minor breaks the API. That is the exact range we want.
**How to apply:** `bevy = "0.20"`. Commit `Cargo.lock` (a game is an application). Upgrade one minor at a time, reading the migration guide at `bevy.org/learn/migration-guides/`.

## Rust toolchain pin
**How to apply:** Pin with `rust-toolchain.toml` (`channel = "stable"` plus `components = ["clippy", "rustfmt"]`) so CI and local agree on the components. Do not pin a numbered channel: Bevy's MSRV policy follows latest stable, and a stale pin blocks the next Bevy patch. Set `rust-version` in `Cargo.toml` to Bevy's current MSRV so `cargo` reports a clear error on an old compiler.

## When to deviate
- A needed crate is behind (see the Bevy line rule): stay on its Bevy line and state the ceiling.
- A numbered Rust channel is worth it only in a studio with a locked CI image; bump it with every Bevy patch.
