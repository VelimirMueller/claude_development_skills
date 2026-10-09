# Testing Patterns

Reference for [test-bevy-systems](SKILL.md). Snippets compiled and passed under `cargo nextest` on Bevy 0.20.0.

## Rule: test headless — `MinimalPlugins`, never `DefaultPlugins`
**Why:** `DefaultPlugins` opens a window and creates a GPU device. CI has neither, and a test that needs them is slow and flaky. `MinimalPlugins` gives schedules, time, and the task pools. Game logic that follows [structure-bevy-app](../structure-bevy-app/SKILL.md) (logic separate from rendering) needs nothing else.
**How to apply:** `App::new().add_plugins((MinimalPlugins, StatesPlugin, ..your plugins))`. `StatesPlugin` (`bevy::state::app::StatesPlugin`) is required for `init_state`; `DefaultPlugins` adds it for you, `MinimalPlugins` does not. Drive with `app.update()`. Never call `app.run()` — `MinimalPlugins` includes a runner that loops forever.
**Anti-example:** `App::new().add_plugins(DefaultPlugins)` in a test.

## Rule: the smallest app that can run the feature
**Why:** Every extra plugin is a way for an unrelated change to break the test. A player-damage test needs `CorePlugin` (state, sets) and `PlayerPlugin`, not the whole game.
**How to apply:** one `test_app()` per test file. Add plugins for what the feature reads (`AssetPlugin`, `Time` is already there). Insert missing resources by hand.

## Rule: bare `World` for pure logic
**Why:** No schedule, no states, no ordering: the test states input and output.
**How to apply:** `world.run_system_once(system)` runs the system once and applies its commands; it returns a `Result`, so `.unwrap()` in tests. Initialize the resources and messages the system uses (`world.init_resource::<Messages<Damage>>()`). Systems with `Local`s or `Query` state work; run conditions are ignored.
**Anti-example:** an `App` with five plugins to test a damage formula.

## Rule: know what one `update()` covers, and say it in a comment
**Why:** One `app.update()` runs the whole main schedule: state transitions run before `Update`, so a `NextState::set` followed by one `update()` runs `OnExit`/`OnEnter` and then the `Update` systems gated by the new state. Commands queued by systems and observers are applied at sync points inside that frame. A test with a blind loop of `update()` calls hides which of these it depends on.
**How to apply:** use the fewest `update()` calls that pass, and comment each:
```rust
app.world_mut().resource_mut::<NextState<Screen>>().set(Screen::Playing);
app.update(); // transition + OnEnter + Update in Playing (apply_damage runs, observer despawns)
```
Outside `update()`, `world.trigger(..)` runs observers but the commands they queue are applied only on the next flush: call `app.world_mut().flush()` before asserting their effects.
**Anti-example:** `for _ in 0..10 { app.update(); }` to "make it settle".

## Rule: assert messages by draining, observers by recording
**Why:** Messages are buffered data: read them from `Messages<M>`. Observers are side effects: record what they saw in a resource.
**How to apply:**
```rust
let written: Vec<f32> = app
    .world_mut()
    .resource_mut::<Messages<Damage>>()
    .drain()
    .map(|d| d.amount)
    .collect();

#[derive(Resource, Default)]
struct DiedLog(Vec<Entity>);

app.init_resource::<DiedLog>();
app.add_observer(|died: On<Died>, mut log: ResMut<DiedLog>| log.0.push(died.entity));
```
Write input with `app.world_mut().write_message(Damage { .. })`; trigger with `app.world_mut().trigger(Died { entity })` then `flush()`. Drain before the next `update()`: messages live two frames.
**Anti-example:** asserting on world state alone when the contract is "a message is sent".

## Rule: time is a test input
**Why:** Real time makes movement and timers vary per run. `TimeUpdateStrategy::ManualDuration` makes each `update()` advance exactly one chosen step.
**How to apply:**
```rust
app.insert_resource(TimeUpdateStrategy::ManualDuration(Duration::from_millis(500)));
app.update(); // the first update only initialises the clock (delta 0)
app.update(); // delta = 500 ms
```
For `FixedUpdate`: `app.insert_resource(Time::<Fixed>::from_duration(Duration::from_millis(100)))` and a manual step of the same size gives one tick per `update()`. Virtual time clamps each frame to `max_delta` (250 ms by default), so a 10 s step runs 2 ticks of 100 ms, not 100: set the step at most that size, or change `Time::<Virtual>::set_max_delta`.
**Anti-example:** `thread::sleep(Duration::from_millis(100))` before an assertion.

## Rule: assets in tests — bounded polling, real fixture, no gate surprises
**Why:** Loading runs on a task pool. A fixed `sleep` is a flaky guess; an unbounded loop hangs CI. A loading gate that panics on a failed load ([manage-bevy-assets](../manage-bevy-assets/SKILL.md)) can panic on a background task after your assertions passed, which fails the test run at a random time (seen with a missing loader for `png`).
**How to apply:** For a loader test: `MinimalPlugins + AssetPlugin::default() + the plugin`, `load` a fixture from `assets/`, loop `app.update()` up to a bound until `is_loaded_with_dependencies(&handle)`, then assert on `Assets<T>`. Do not add the gameplay `AssetsPlugin` to unrelated tests; give gameplay tests a `GameAssets` stub or no asset plugin at all.
**Anti-example:** adding `AssetsPlugin` to a combat test that never loads a sprite.

## Rule: detect ordering bugs with ambiguity checks and schedule shuffling
**Why:** Two systems that write the same data without an order produce results that depend on thread timing. Bevy can report them, and (with the `debug` feature) shuffle the order within allowed constraints so hidden dependencies show up.
**How to apply:**
```rust
use bevy::ecs::schedule::{LogLevel, ScheduleBuildSettings};

app.edit_schedule(Update, |schedule| {
    schedule.set_build_settings(ScheduleBuildSettings {
        ambiguity_detection: LogLevel::Error,   // panics on first update if two systems conflict unordered
        ..default()
    });
});
app.update();

```
Shuffling needs `bevy/debug` as a dev-dependency feature. Run the same scenario under several seeds and assert one result:
```rust
#[test]
fn result_does_not_depend_on_system_order() {
    for seed in 0..8 {
        let mut app = App::new();
        app.add_plugins((MinimalPlugins, StatesPlugin, CorePlugin, PlayerPlugin));
        app.edit_schedule(Update, |schedule| {
            schedule.set_build_settings(ScheduleBuildSettings {
                shuffle_seed: Some(seed),
                ..default()
            });
        });
        app.world_mut().resource_mut::<NextState<Screen>>().set(Screen::Playing);
        app.update();
        let target = app.world_mut().spawn(Health(10.0)).id();
        app.world_mut().write_message(Damage { target, amount: 4.0 });
        app.update();
        assert_eq!(app.world().get::<Health>(target), Some(&Health(6.0)), "seed {seed}");
    }
}
```
Run the ambiguity test on `Update` and `FixedUpdate` of the composed app, not only one plugin. Fix by adding the system to the right `GameSystems` set, not by silencing the log.
**Anti-example:** `.after()` sprinkled until the test goes green, with no set to explain why.

## Rule: property tests for the math, not for the engine
**Why:** Damage, scoring, spawn rates and clamps have input spaces too large to enumerate. `proptest` finds the 0.0 and the overflow you did not think of. Engine behavior (`App` wiring) does not need random input.
**How to apply:**
```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn health_never_increases(start in 1.0f32..1000.0, hits in proptest::collection::vec(0.0f32..50.0, 0..20)) {
        let mut world = World::new();
        world.init_resource::<Messages<Damage>>();
        let target = world.spawn(Health(start)).id();
        for amount in &hits {
            world.write_message(Damage { target, amount: *amount });
        }
        world.run_system_once(apply_damage).unwrap();
        world.flush();
        if let Some(h) = world.get::<Health>(target) {
            prop_assert!(h.0 <= start);
        }
    }
}
```
Extract the formula into a pure function when you can and test that directly; the world test above is the fallback.
**Anti-example:** proptest over a full `App` with 1000 cases per test — slow, and the shrunk case is unreadable.

## Rule: nextest for tests, `cargo test --doc` for doctests
**Why:** nextest runs each test in its own process: a panic in one cannot poison another, test output is isolated, and the CI profile can set timeouts and JUnit output. It does not run doctests.
**How to apply:** `cargo nextest run` locally; `cargo nextest run --profile ci` in CI plus `cargo test --doc`. Tests start from the package root, so `assets/` resolves for fixture loads.
**Anti-example:** only `cargo test` in CI and a shared global resource that leaks between tests.

## When to deviate
- **Rendering bugs:** shaders, sprite order, and UI layout need a window or a screenshot test; keep those few tests out of the default `nextest` run (a separate profile or `#[ignore]`) and run them on a machine with a GPU.
- **Whole-game smoke test:** one test may add `GamePlugin` with `MinimalPlugins` and run 100 updates to prove it starts; keep it to one.
- **Exact timing:** if the test is about frame pacing, use real time and a generous bound, and mark it as a benchmark, not a unit test.
- **Colocated tests:** fine for private helpers; the headless `App` tests still go in `tests/`.
