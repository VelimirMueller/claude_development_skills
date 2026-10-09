# Architecture Patterns

Reference for [structure-bevy-app](SKILL.md). All snippets compile against Bevy 0.20.0. Versions: [stack-versions](../_shared/stack-versions.md).

## Rule: one plugin per feature, one `GamePlugin` listing them
**Why:** A plugin is the smallest unit you can add, remove, or test alone. One list of plugins answers "what does the game run?" in one file.
**How to apply:** `src/<feature>.rs` holds `pub struct XPlugin` and everything private to it. Export only the types other plugins must name (components, messages). Features do not call each other's systems; they communicate through components, messages, or observer events.
**Anti-example:** `app.add_systems(Update, player::move_player)` in `main.rs` — the plugin boundary is gone and the order lives in two places.

## Rule: states for screens, `DespawnOnExit` for cleanup
**Why:** A hand-written cleanup system per screen is a leak waiting for the next entity type. Scoping at the spawn site makes the lifetime visible where the entity is created.
**How to apply:**
```rust
app.init_state::<Screen>()
    .add_systems(OnEnter(Screen::Playing), spawn_player);

commands.spawn((Player, DespawnOnExit(Screen::Playing)));
```
- `DespawnOnEnter(state)` clears entities when entering a state. In 0.20 both also fire on same-state transitions.
- Sub-screens (pause menu inside gameplay): `#[derive(SubStates)] #[source(Screen = Screen::Playing)] enum PlayPhase { #[default] Running, Paused }` and `app.add_sub_state::<PlayPhase>()`.
- Derived facts ("in any gameplay state"): `impl ComputedStates for InGame { type SourceStates = Screen; fn compute(s: Screen) -> Option<Self> { matches!(s, Screen::Playing).then_some(InGame) } }` and `app.add_computed_state::<InGame>()`.
- Request a change with `next.set(Screen::Menu)`; `set` always runs `OnExit`/`OnEnter`, even for the same value. Use `next.set_if_different(..)` to skip a no-op (`set_if_neq` is a deprecated alias since 0.20).
- Run conditions: `run_if(in_state(Screen::Playing))`, `run_if(state_changed::<Screen>)`.
**Anti-example:** a `despawn_menu` system that queries `With<MenuRoot>` and is called from three places.

## Rule: system sets order the schedule; configure them once
**Why:** Bevy runs systems in parallel unless told otherwise. `.before()/.after()` between feature plugins couples them by system function. A set is a public name for a phase; features join a phase and never know each other.
**How to apply:** Define `GameSystems { Input, Movement, Combat, Cleanup }` in `core.rs`; `configure_sets(Update, (..).chain().run_if(in_state(Screen::Playing)))` once; features use `.in_set(GameSystems::Combat)`. Set enums end in `Systems` (Bevy's own convention since 0.17: `TransformSystems`, `RenderSystems`).
`chain()` gives a strict order including systems with no data conflict. Use `chain_weak()` (new in 0.20) when you only need conflicting systems ordered and want unrelated ones to stay parallel.
**Anti-example:** `.after(player::apply_velocity)` in the enemy plugin.

## Rule: components are small and data-only; required components replace bundles
**Why:** A component with one reason to change is cheap to query and cheap to test. `#[require(..)]` makes "a Player always has Health and Velocity" a compile-time fact, so no spawn site forgets one.
**How to apply:**
```rust
#[derive(Component, Debug, Default)]
#[require(Health, Velocity)]
pub struct Player;

#[derive(Component, Debug, Clone, Copy, PartialEq)]
pub struct Health(pub f32);

#[derive(Component)]
#[require(Health = Health(5.0))]   // override the default for one type
pub struct Boss;
```
Markers (`Player`, `Enemy`) are zero-sized and carry no logic. Behavior lives in systems. Group tuples with `children![..]` for hierarchies.
**Anti-example:** a `Player` struct with 15 fields and `impl Player { fn update(&mut self) }` — it cannot be queried by part and cannot run in parallel.

## Rule: resources only for true singletons — and never both derives
**Why:** Global state in a resource is invisible to the query that needs it. Since 0.19, `#[derive(Resource)]` implies `Component`: deriving both on one type does not compile, and broad queries (`Query<Entity>`, `Query<EntityMut>`) can conflict with `Res<T>` (add `Without<IsResource>` or `Without<MyResource>`).
**How to apply:** Use a resource for settings, score, input maps, asset handle tables. Use a component for anything per-entity. If one concept needs both, define two types.
**Anti-example:** `#[derive(Resource, Component)] struct Score` — split it.

## Rule: messages for streams, observers for reactions
**Why:** Since 0.17 buffered events are `Message`s and `Event` is observer-only. Messages are batched: many writers, readers poll once per frame, good for "N damage events this frame". Observers run immediately on a trigger, target one entity, and need no schedule slot, which fits "when this entity dies, despawn it".
**How to apply:**
```rust
#[derive(Message, Debug, Clone, Copy)]
pub struct Damage { pub target: Entity, pub amount: f32 }

#[derive(EntityEvent, Debug)]
pub struct Died { pub entity: Entity }

app.add_message::<Damage>().add_observer(on_died);

fn apply_damage(mut messages: MessageReader<Damage>, mut healths: Query<&mut Health>, mut commands: Commands) {
    for damage in messages.read() {
        let Ok(mut health) = healths.get_mut(damage.target) else { continue };
        health.0 -= damage.amount;
        if health.0 <= 0.0 {
            commands.trigger(Died { entity: damage.target });
        }
    }
}

fn on_died(died: On<Died>, mut commands: Commands) {
    commands.entity(died.entity).despawn();
}
```
Writing: `MessageWriter<Damage>` and `.write(Damage { .. })`. Lifecycle observers use the component in the type: `On<Add<Player>>` (0.20; it was `On<Add, Player>`), `On<Remove<Health>>`.
**Anti-example:** a `Messages<Died>` reader that polls every frame to despawn one entity.

## Rule: change detection narrows work, `Single` narrows intent
**Why:** `Changed<T>`/`Added<T>` skip untouched entities without a manual dirty flag. `Single` states "exactly one" in the signature; the system skips quietly when that is false instead of panicking.
**How to apply:**
```rust
fn refresh_bars(changed: Query<&Health, Changed<Health>>, mut bars: Query<&mut Text, With<HealthBar>>) { .. }
app.add_systems(Update, refresh_bars.run_if(any_match_filter::<Changed<Health>>));
app.add_systems(Update, log.run_if(resource_changed::<Stats>));

fn camera_follow(player: Single<&Transform, With<Player>>, mut camera: Single<&mut Transform, (With<Camera2d>, Without<Player>)>) { .. }
```
Use `query.single()?` in a system that returns `Result` when you want the failure reported through Bevy's error handler instead of skipped. Do not `.unwrap()` it.
**Anti-example:** a bool field `dirty: bool` that every system must remember to set.

## Rule: avoid query conflicts with `Without`, then `ParamSet`
**Why:** Two queries in one system that could both borrow `&mut Transform` for the same entity panic at startup. Disjoint filters prove disjointness at compile/schedule time and keep the system parallel; `ParamSet` serializes access inside one system.
**How to apply:** First, `(With<Enemy>, Without<Player>)` on one of them. Only if the sets truly overlap, `ParamSet<(Query<&mut Transform, With<Player>>, Query<&Transform, With<Boss>>)>` and access `set.p0()`, `set.p1()` one at a time.
**Anti-example:** `Query<&mut Transform>` plus `Query<&mut Transform, With<Player>>` in one system.

## Rule: logic is headless, rendering is a separate plugin
**Why:** Logic that needs no window is testable without a GPU and can later run on a server. Visuals added by observers keep the logic plugin free of `Sprite`, `Mesh`, and `Text`.
**How to apply:** Logic plugins own components like `Player`, `Health`, `Velocity` and systems that change them. A `ViewPlugin` attaches visuals when the logic entity appears:
```rust
fn attach_visuals(add: On<Add<Player>>, mut commands: Commands) {
    commands.entity(add.entity).insert(Sprite::from_color(Color::WHITE, Vec2::splat(16.0)));
}
```
Simulation that must be deterministic (physics, movement tied to tick count) runs in `FixedUpdate` with `Res<Time<Fixed>>`; input and presentation run in `Update`. Tests then drive `FixedUpdate` without a renderer ([test-bevy-systems](../test-bevy-systems/SKILL.md)).
**Anti-example:** `apply_damage` that also spawns a particle `Sprite` — it needs a renderer to be tested.

## Rule: one place for each seam
**Why:** [Engineering principles](../../core/_shared/engineering-principles.md): one seam per I/O boundary. In a game that means one module for asset handles, one for input mapping, one for save files, one for audio playback.
**How to apply:** Other plugins read `Res<GameAssets>`, send a `PlaySound` message, read an `InputMap`; they never call `asset_server.load("...")` or `ButtonInput<KeyCode>` directly.

## 0.17 → 0.20 rename table (grep targets for old code)

| Old | New | Since |
|---|---|---|
| `EventReader<E>`, `EventWriter<E>`, `Events<E>` (buffered) | `MessageReader<M>`, `MessageWriter<M>`, `Messages<M>` with `#[derive(Message)]` | 0.17 |
| `send_event`, `Events::send` | `write_message`, `Messages::write`, `writer.write(..)` | 0.17 |
| `app.add_event::<E>()` (buffered) | `app.add_message::<M>()` | 0.17 |
| `Trigger<E>` in observers | `On<E>` | 0.17 |
| `StateScoped(state)` | `DespawnOnExit(state)` (+ `DespawnOnEnter`) | 0.17 |
| `RenderSet`, `TransformSystem`, `UiSystem` … | `RenderSystems`, `TransformSystems`, `UiSystems` … | 0.17 |
| `EntityCommands::clear_children` / `remove_child` | `detach_all_children` / `detach_child` | 0.18 |
| `#[derive(Resource, Component)]` on one type | two separate types | 0.19 |
| `init_non_send_resource` etc. | `init_non_send` etc. | 0.19 |
| `DefaultErrorHandler` | `FallbackErrorHandler` | 0.19 |
| `On<Add, A>` | `On<Add<A>>` | 0.20 |
| `NextState::set_if_neq` | `set_if_different` | 0.20 |
| `iter_many` yields `Item` | yields `Result<Item, QueryEntityError>`; `.matched()` for the old behavior | 0.20 |
| `Scene`, `SceneRoot`, `DynamicScene` | `WorldAsset`, `WorldAssetRoot`, `DynamicWorld` | 0.19 |

Full guides: `bevy.org/learn/migration-guides/`. Read the guide for the target version before changing code; this table is a grep aid, not a substitute.

## When to deviate
- **Tiny prototype:** one file, no plugins, until a second feature appears. Do not carry it past a jam.
- **A feature is truly one system:** a plugin with one `add_systems` is fine; do not merge unrelated features to save files.
- **Observers vs messages:** observers have per-trigger overhead; for thousands of events per frame, prefer a message and one batch system.
- **`Update` for simulation:** acceptable for single-player games with no physics when frame-rate-dependent movement is fine; always multiply by `time.delta_secs()`.
- **`ParamSet`/`Without` fight:** if a system needs many overlapping queries, split the system.
