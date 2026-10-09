# Asset Patterns

Reference for [manage-bevy-assets](SKILL.md). Snippets compiled against Bevy 0.20.0. Versions: [stack-versions](../_shared/stack-versions.md).

## Rule: load through one seam and hold strong handles
**Why:** A `Handle` is a reference count. If the last strong handle drops, Bevy unloads the asset. Calling `asset_server.load("a.png")` in ten systems scatters path strings and lifetime decisions. One `GameAssets` resource makes paths greppable, keeps assets alive, and gives the loading gate one list to wait on.
**How to apply:** `src/assets.rs` owns `GameAssets`. Other plugins read `Res<GameAssets>`. Add a field per asset the game needs before the first frame; load rare or large assets (levels, music) through the same module on demand.
**Anti-example:** `commands.spawn(Sprite::from_image(asset_server.load("player.png")))` inside gameplay code.

## Rule: gate on load state and fail loudly
**Why:** Loading is asynchronous. Spawning against a not-yet-loaded handle shows nothing; a missing file shows nothing forever. Both are bugs a player reports as "black screen".
**How to apply:** `Screen::Loading` runs until `asset_server.recursive_dependency_load_state(id)` is `Loaded` for every id; `Failed(error)` panics with the path in the message. `is_loaded_with_dependencies(&handle)` is the one-call check when you hold typed handles and do not need the failure branch. Loading a folder: `asset_server.load_folder("levels")` returns `Handle<LoadedFolder>`; wait for it the same way.
**Anti-example:** `if let Some(img) = images.get(&handle)` in `Update` and silently doing nothing otherwise.

## Rule: native loading by default; third-party collections only on a matching line
**Why:** `bevy_asset_loader` (declarative `AssetCollection` structs) saves boilerplate, but it is a third-party crate tied to one Bevy minor. On 2026-10-09 its stable 0.27 targeted Bevy 0.19 and only `0.28.0-rc.1` targeted 0.20. A project must not hold a plugin on a different Bevy line than the engine. The native pattern above is about 30 lines.
**How to apply:** Native until crates.io shows a stable `bevy_asset_loader` whose `bevy_asset` requirement matches your Bevy minor (`curl -s -A skills https://crates.io/api/v1/crates/bevy_asset_loader/<ver>/dependencies`). Then switching is a one-file change because only `src/assets.rs` knows about loading. Same check for `bevy_common_assets` (RON/JSON/TOML asset plugins).
**Anti-example:** `bevy_asset_loader = "0.27"` next to `bevy = "0.20"`.

## Rule: custom data is an asset with a loader
**Why:** Levels, enemy tables and dialogue are data. As assets they hot reload, load asynchronously, and parse errors name the file. `include_str!` bakes them in and loses all three.
**How to apply:**
```rust
use bevy::asset::{AssetLoader, LoadContext, io::Reader};
use bevy::prelude::*;

/// One `x, y` spawn point per line.
#[derive(Asset, TypePath, Debug)]
pub struct Level {
    pub spawns: Vec<Vec2>,
}

#[derive(Debug)]
pub enum LoadLevelError {
    Io(std::io::Error),
    Parse(String),
}

impl std::fmt::Display for LoadLevelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "io: {e}"),
            Self::Parse(e) => write!(f, "parse: {e}"),
        }
    }
}

impl std::error::Error for LoadLevelError {}

#[derive(Default, TypePath)]
pub struct LevelLoader;

impl AssetLoader for LevelLoader {
    type Asset = Level;
    type Settings = ();
    type Error = LoadLevelError;

    async fn load(
        &self,
        reader: &mut dyn Reader,
        _settings: &(),
        _load_context: &mut LoadContext<'_>,
    ) -> Result<Level, LoadLevelError> {
        let mut bytes = Vec::new();
        reader.read_to_end(&mut bytes).await.map_err(LoadLevelError::Io)?;
        let text = String::from_utf8(bytes).map_err(|e| LoadLevelError::Parse(e.to_string()))?;
        let spawns = text
            .lines()
            .map(|line| {
                let (x, y) = line.split_once(',').ok_or_else(|| LoadLevelError::Parse(line.into()))?;
                let parse = |s: &str| s.trim().parse::<f32>().map_err(|e| LoadLevelError::Parse(e.to_string()));
                Ok(Vec2::new(parse(x)?, parse(y)?))
            })
            .collect::<Result<_, LoadLevelError>>()?;
        Ok(Level { spawns })
    }

    fn extensions(&self) -> &[&str] {
        &["level"]
    }
}

app.init_asset::<Level>().init_asset_loader::<LevelLoader>();
```
The loader error type implements `std::error::Error + Send + Sync + 'static` (a small enum as above, or `thiserror`). Loaders, savers and processors need `TypePath` since 0.18. For RON/JSON with serde, `bevy_common_assets` is this loader pre-written, subject to the version rule above. Parse at load time; systems receive validated data ([engineering principles](../../core/_shared/engineering-principles.md): validate at the edge).
**Anti-example:** `ron::from_str(include_str!("level1.ron")).unwrap()` in a startup system.

## Rule: hot reload in dev only
**Why:** Seeing an asset change without restarting cuts the edit loop to seconds. The watcher costs file handles and does not exist on web, so it must not ship.
**How to apply:** `dev` feature includes `bevy/dev`, which enables `file_watcher`. Embedded assets need `bevy/embedded_watcher` added to `dev`. Toggle at runtime with `AssetPlugin { watch_for_changes_override: Some(false), .. }`. React to reloads with `MessageReader<AssetEvent<T>>` (`Modified`, `LoadedWithDependencies`). Since 0.19, `Assets::get_mut` returns `AssetMut`, and `Modified` fires only after a real mutation: compare before assigning.
**Anti-example:** `default = ["bevy/file_watcher"]` — release builds watch the player's disk.

## Rule: processing is opt-in and desktop-only
**Why:** `AssetMode::Processed` runs importers over `assets/` (for example texture compression) and writes `imported_assets/`. It saves load time and size, but it needs a filesystem at build time and has known problems on web.
**How to apply:** Stay on `AssetMode::Unprocessed` (the default) until a measurement shows load time or asset size is a problem ([optimize-bevy-game](../optimize-bevy-game/SKILL.md)). Then: `AssetPlugin { mode: AssetMode::Processed, ..default() }`, enable `bevy/asset_processor` in `dev`, run the game once to fill `imported_assets/`, ship that folder. In 0.20 the default compressed-image processor also handles JPEG; to keep PNG only set `ImagePlugin { default_compressed_image_processor_extensions: ["png".into()].into(), ..default() }`. Texture compression is behind the `compressed_image_saver` feature (BCn/ASTC; `compressed_image_saver_universal` for Basis Universal).
**Anti-example:** processed mode on a web build.

## Rule: web needs `AssetMetaCheck::Never`
**Why:** By default Bevy requests a `.meta` file next to every asset. On web every `.meta` request is a network round trip, and hosts that rewrite unknown paths to an HTML page return content that is not a meta file. `Never` skips the request and uses the default settings.
**How to apply:**
```rust
use bevy::asset::AssetMetaCheck;

DefaultPlugins.set(AssetPlugin { meta_check: AssetMetaCheck::Never, ..default() })
```
Only on the web target (`#[cfg(target_arch = "wasm32")]`) if you use `.meta` files on desktop.
**Anti-example:** shipping the desktop plugin config to itch.io and debugging "asset meta parse error".

## Rule: embed what the first frame needs
**Why:** On web every asset is an HTTP request; a splash or loading font that arrives late shows an empty screen. In a single-file desktop build, a few embedded assets avoid a missing-folder crash on start.
**How to apply:**
```rust
use bevy::asset::embedded_asset;

embedded_asset!(app, "src/", "splash.png");          // file: src/splash.png
let splash: Handle<Image> = asset_server.load("embedded://my_game/splash.png");
```
The path is `embedded://<crate_name>/<path relative to the "src/" root argument>`. Embed only the first-frame assets; load the rest from `assets/`. Hot reload for them needs `bevy/embedded_watcher`.
**Anti-example:** `include_bytes!` for all textures — the binary grows and nothing reloads.

## Rule: test loaders headless, with a fixture
**Why:** A loader is parsing code at an I/O edge: the best place for a test. It needs no window.
**How to apply:** `MinimalPlugins + AssetPlugin::default() + YourPlugin`, `load`, then loop `app.update()` (bounded) until `is_loaded_with_dependencies`. Details in [test-bevy-systems](../test-bevy-systems/SKILL.md).

## When to deviate
- **Declarative collections:** on a matching `bevy_asset_loader` stable release, a team that loads dozens of assets may prefer it; keep it inside `src/assets.rs`.
- **Streaming open worlds:** per-region loading replaces the one `Loading` gate; keep the failure-is-loud rule.
- **Processing on desktop:** worth it earlier for texture-heavy 3D games, where compressed textures cut VRAM and load time.
- **Dev without a watcher:** CI machines and containers with file-watch limits: leave `dev` off there.
