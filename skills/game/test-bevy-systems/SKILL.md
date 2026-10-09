---
name: test-bevy-systems
description: Use when writing or fixing tests for a Bevy game — headless App/World tests with MinimalPlugins, running one system, asserting messages, observers and state transitions, deterministic time, ordering checks, property tests, and cargo-nextest in CI.
---

# Test Bevy Systems

Bevy 0.20, `cargo-nextest`. Rationale and pitfalls: [testing-patterns.md](testing-patterns.md). Versions: [stack-versions](../_shared/stack-versions.md).

## 1. Audit current state (change nothing)

```bash
cat .claude/stack-profile.md 2>/dev/null                   # tests.layout, task_runner, ci
ls tests/ .config/nextest.toml 2>/dev/null; ls src/lib.rs
grep -rln "#\[test\]" src/ tests/ | head
grep -rnE "DefaultPlugins|WinitPlugin|RenderPlugin" tests/ src/**/tests* 2>/dev/null   # windowed tests: replace
grep -n "nextest\|cargo test" justfile Makefile mise.toml .github/workflows/*.yml 2>/dev/null
cargo nextest --version; grep -n "proptest" Cargo.toml
```

`tests.layout: tests-dir` (default): integration tests in `tests/`, one file per feature. `colocated`: unit tests in `#[cfg(test)] mod tests` next to the plugin; keep integration tests in `tests/` anyway.
No `src/lib.rs` → the game cannot be tested; run [scaffold-bevy-game](../scaffold-bevy-game/SKILL.md) step 5 first.

## 2. Decide what to do
- No tests → add the harness (step 5) and one test per plugin: its main state change.
- Tests exist but use `DefaultPlugins` → switch to `MinimalPlugins` (windowed tests need a GPU and break CI).
- Harness, per-feature tests, nextest in CI present → "already in place", stop.

## 3. Detect track
- **Pure logic (damage, scoring, movement math):** `run_system_once` on a bare `World`; no `App`.
- **Cross-system behavior (messages, observers, states):** `App` with `MinimalPlugins + StatesPlugin + the plugin under test`.
- **Time-dependent:** add `TimeUpdateStrategy::ManualDuration`.
- **Assets:** add `AssetPlugin::default()` and only the loaders you test.
- **Input-space tests (any number, any order):** `proptest`.

## 4. Install only what's missing

```bash
cargo install cargo-nextest --locked          # local; CI uses taiki-e/install-action
```
```toml
# Cargo.toml — only if used
[dev-dependencies]
proptest = "1.11"
bevy = { version = "0.20", default-features = false, features = ["debug"] }   # enables schedule shuffling in tests only
```

## 5. Generate the seams

One helper per test file builds the smallest app that can run the feature:

```rust
fn test_app() -> App {
    let mut app = App::new();
    app.add_plugins((MinimalPlugins, StatesPlugin, CorePlugin, PlayerPlugin));
    app
}
```

Run one system on a bare world:

```rust
let mut world = World::new();
let target = world.spawn(Health(30.0)).id();
world.init_resource::<Messages<Damage>>();
world.write_message(Damage { target, amount: 10.0 });
world.run_system_once(apply_damage).unwrap();          // use bevy::ecs::system::RunSystemOnce
assert_eq!(world.get::<Health>(target), Some(&Health(20.0)));
```

Drive a state transition, then assert (state transitions run before `Update` inside the same `update()`):

```rust
app.world_mut().resource_mut::<NextState<Screen>>().set(Screen::Playing);
app.update();                                           // transition + OnEnter + Update in the new state
assert_eq!(app.world_mut().query::<&Player>().iter(app.world()).count(), 1);
```

Deterministic time:

```rust
app.insert_resource(TimeUpdateStrategy::ManualDuration(Duration::from_millis(500)));
app.update(); // first update only initialises the clock: delta is 0
app.update(); // now delta == 500 ms
```

Observers, messages and ordering checks: copy from [testing-patterns.md](testing-patterns.md).

`.config/nextest.toml`:

```toml
[profile.ci]
fail-fast = false
retries = 0
slow-timeout = { period = "30s", terminate-after = 4 }
```

## 6. Wire it
- Task runner (from the profile; `just` shown): `test: cargo nextest run` and `cargo test --doc` (nextest does not run doctests).
- CI: `taiki-e/install-action@v2` with `tool: cargo-nextest`, then `cargo nextest run --profile ci` and `cargo test --doc` (full workflow: [scaffold-patterns.md](../scaffold-bevy-game/scaffold-patterns.md#rule-ci-mirrors-just-check)).
- Each new plugin lands with a test file `tests/<feature>.rs` in the same change.
- No `thread::sleep`. Advance with `app.update()` and manual time. Asset waits are bounded loops.

## 7. Verify

```bash
cargo nextest run --profile ci
cargo test --doc
```

Expected: every test passes in well under a second per test and no window opens. Break a system on purpose (flip a sign): its test must fail. Run with `--no-fail-fast` in a pipeline that has retries off to confirm no flakiness.

Contracts: [engineering principles](../../core/_shared/engineering-principles.md) (tests at the boundary that pays).
