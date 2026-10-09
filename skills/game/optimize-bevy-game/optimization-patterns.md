# Optimization Patterns

Reference for [optimize-bevy-game](SKILL.md). Code compiled against Bevy 0.20.0. Versions: [stack-versions](../_shared/stack-versions.md).

## Rule: measure in release, in the real scene, before changing anything
**Why:** Dev builds run at a different speed profile (your crate at opt-level 1) and mislead. A guess changes the wrong system and adds code. [Engineering principles](../../core/_shared/engineering-principles.md): measure before optimizing.
**How to apply:**
- `cargo run --release --features bevy/trace_chrome` → `trace-*.json` → open in `https://ui.perfetto.dev`. Needs no extra tool.
- `cargo run --release --features bevy/trace_tracy` → live in Tracy (add `bevy/debug` for readable system names; `trace_tracy_memory` adds allocation tracking at higher overhead). Find the matching Tracy UI version with `cargo tree --features bevy/trace_tracy | grep tracy` and the `rust_tracy_client` version table.
- Without a profiler: `FrameTimeDiagnosticsPlugin::default()` + `LogDiagnosticsPlugin::default()`; report frame time in ms.
- Dependency logs cost time even when disabled at runtime. For profiling runs, the `tracing` crate features `max_level_debug` and `release_max_level_warn` compile low-severity logs out for normal release builds; remove them while profiling with Tracy, as Bevy's profiling guide notes.
**Anti-example:** "ECS is slow here" with no trace.

## Rule: do less work — change detection and run conditions
**Why:** The cheapest system is the one that does not run. Bevy tracks changes per component; `Changed<T>` filters skip untouched entities, run conditions skip whole systems.
**How to apply:**
```rust
fn refresh_bars(changed: Query<&Health, Changed<Health>>, mut bars: Query<&mut Text, With<HealthBar>>) { .. }
app.add_systems(Update, refresh_bars.run_if(any_match_filter::<Changed<Health>>));
app.add_systems(Update, log.run_if(resource_changed::<Stats>));
```
Writing marks a component changed whenever the `Mut<T>` is dereferenced mutably, even if you write the same value. Guard writes:
```rust
fn regen(mut query: Query<&mut Health>) {
    for mut health in &mut query {
        let next = (health.0 + 1.0).min(100.0);
        health.set_if_neq(Health(next));      // marks changed only when the value differs; needs PartialEq
    }
}
```
Read changed-ness without writing through `Ref<T>`: `health.is_changed()`. Since 0.20, change ticks are tracked per column, so `Changed` is cheaper than before; the rule stands.
**Anti-example:** `health.0 = next;` every frame for every entity, then `Changed<Health>` UI systems that always fire.

## Rule: let the scheduler parallelize — disjoint access, then `par_iter_mut`
**Why:** Bevy runs systems in parallel when their data access does not conflict. One system holding `ResMut<World-state>` or an overly wide `Query<&mut Transform>` serializes everything behind it. Inside one system, a large loop of independent work can use `par_iter_mut`.
**How to apply:**
- Narrow access: `Query<&mut Transform, With<Enemy>>` instead of `Query<&mut Transform>`; `Res` instead of `ResMut` when you only read; split a system that reads A and writes B into two.
- Heavy per-entity work over thousands of entities:
```rust
fn integrate(mut query: Query<(&mut Transform, &Velocity)>, time: Res<Time>) {
    let dt = time.delta_secs();
    query.par_iter_mut().for_each(|(mut transform, velocity)| {
        transform.translation += velocity.0.extend(0.0) * dt;
    });
}
```
Parallel iteration pays only for large, heavy loops; for a few hundred cheap items it costs more than it saves. Measure.
- Keep `multi_threaded` on (it is in Bevy's default platform features). Do not use `ParamSet` or exclusive `&mut World` systems for convenience; they block parallelism.
**Anti-example:** `par_iter_mut` over 20 entities.

## Rule: no per-frame allocation in hot systems
**Why:** `Vec::new()`, `collect()`, `format!`, `String` and `Box` in `Update` allocate and free every frame. At scale that shows up as frame spikes and allocator time in the trace.
**How to apply:**
```rust
fn collect_hits(query: Query<(Entity, Ref<Health>)>, mut scratch: Local<Vec<Entity>>) {
    scratch.clear();                       // keeps the capacity
    scratch.extend(query.iter().filter(|(_, h)| h.is_changed()).map(|(e, _)| e));
}
```
- Reuse buffers with `Local<Vec<_>>`.
- Spawn groups with `commands.spawn_batch(iter)` instead of a loop of `spawn`.
- Update `Text` only when the value changes (`Changed<..>` or a stored last value), not `format!` every frame.
- Remove many entities of a kind with `commands.despawn_all::<With<Enemy>>()` (new in 0.20, faster than looping).
- Pool entities (hide and reuse) only when the trace shows spawn/despawn cost; do not pool by default.
**Anti-example:** `let v: Vec<_> = query.iter().collect();` at the top of an `Update` system.

## Rule: batch rendering — atlases, shared handles, few unique materials
**Why:** The renderer batches draws that share the same texture and material. 2D sprites that use one atlas image draw in one batch; the same sprites on 100 separate images cannot batch. Frame time that rises with sprite count and not with system work is a draw/batch problem.
**How to apply:**
```rust
let layout = layouts.add(TextureAtlasLayout::from_grid(UVec2::splat(16), 4, 4, None, None));
let image: Handle<Image> = assets.load("sprites/sheet.png");
commands.spawn_batch((0..100).map(move |i| {
    (
        Sprite::from_atlas_image(image.clone(), TextureAtlas { layout: layout.clone(), index: i % 16 }),
        Transform::from_xyz(i as f32 * 4.0, 0.0, 0.0),
    )
}));
```
Reuse one `Handle<Material>`/mesh for identical objects instead of `materials.add(..)` per entity. Check the GPU spans in Tracy (`RenderQueue` row with `trace_tracy`) before assuming CPU. Lower resolution or MSAA first when fill-rate bound.
**Anti-example:** `materials.add(ColorMaterial::from_color(c))` inside a per-enemy spawn for the same color.

## Rule: put heavy deterministic work in `FixedUpdate`, keep `Update` light
**Why:** `FixedUpdate` runs at a fixed rate and can run zero or several times per frame. Physics and simulation at 30–60 Hz do not need to run at 240 FPS. Frame-rate-bound presentation (interpolation, UI) stays in `Update`.
**How to apply:** `app.add_systems(FixedUpdate, simulate)`; set the rate with `Time::<Fixed>::from_hz(30.0)` as a resource. Virtual time clamps each frame to 250 ms by default, so a long hitch does not cause a burst of hundreds of ticks.
**Anti-example:** path-finding for every enemy in `Update` at uncapped frame rate.

## Rule: release profile — thin LTO and one codegen unit, fat only when measured
**Why:** `codegen-units = 1` and `lto` let the compiler inline across crates (Bevy is many crates). Bevy's setup guide describes the gain as marginal at the cost of longer compile times, so it is for shipping builds, not the edit loop.
**How to apply:**
```toml
[profile.release]
codegen-units = 1
lto = "thin"
```
`lto = "fat"` and `panic = "abort"` shrink and speed the binary further (Bevy's own `stress-test` profile uses fat LTO and abort); try them on the release candidate, compare numbers, keep what helps. `panic = "abort"` removes unwinding: a panic ends the process, so confirm that is acceptable (no `catch_unwind`, no test harness reliance). Never optimize dependencies in the *release* profile further than the default; the dev profile already handles dev speed ([scaffold-patterns](../scaffold-bevy-game/scaffold-patterns.md)).
**Anti-example:** `lto = "fat"` in the shared dev loop — every rebuild takes minutes.

## Rule: wasm size — size profile, bindgen, then optionally wasm-opt
**Why:** Download size is load time. Bevy's wasm examples show `opt-level = "z"` plus LTO and `wasm-opt` taking the same demo from 13 MB to about 5 MB (2022 figures: the shape of the result holds, the absolute sizes do not).
**How to apply:**
```toml
[profile.wasm-release]
inherits = "release"
opt-level = "s"
strip = "symbols"
```
```bash
cargo build --profile wasm-release --target wasm32-unknown-unknown
wasm-bindgen --out-dir dist --target web target/wasm32-unknown-unknown/wasm-release/my_game.wasm
wasm-opt -Oz --output dist/opt.wasm dist/my_game_bg.wasm && mv dist/opt.wasm dist/my_game_bg.wasm   # optional, slow
```
Measured on 2026-10-09 with a reference 2D+UI+audio game (Bevy 0.20, `wasm-release`, `opt-level = "s"`, before `wasm-bindgen`/`wasm-opt`): `strip = "debuginfo"` (the value in Bevy's setup guide) gave 66 MB; `strip = "symbols"` gave 36 MB. The symbol names are the difference; the cost is unreadable names in panic backtraces, so keep a non-stripped profile for debugging. Compare `ls -l` before and after each step; keep only steps that pay. Try `opt-level = "z"` against `"s"` for size and `"s"` for speed. Drop unused Bevy features (`default-features = false`) first: they remove code instead of compressing it. Serve with gzip or brotli. Cranelift does not support wasm builds. Texture size usually dominates: see processing in [manage-bevy-assets](../manage-bevy-assets/SKILL.md).
**Anti-example:** shipping `target/release` wasm and blaming the host for slow loads.

## Rule: one change, one measurement
**Why:** Two changes together hide which one helped and which hurt.
**How to apply:** Re-run the step-5 measurement after each fix; record before/after in the PR. Revert changes that did not move the number.

## When to deviate
- **Obvious algorithmic problem:** an `O(n²)` nested query over thousands of entities needs no trace to fix; fix it, then measure.
- **Memory-bound or GPU-bound games:** Tracy with `trace_tracy_memory` and the GPU spans matter more than system times.
- **Editor / dev builds:** do not turn on release-only tuning in the dev loop.
- **Tiny games:** if the frame is already under budget on target hardware, stop.
