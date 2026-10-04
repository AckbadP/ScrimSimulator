# Scrim Simulator

**[Download the latest release](https://github.com/AckbadP/ScrimSimulator/releases/latest)**
(Linux and Windows).

Scrim Simulator turns a recording of an EVE Online scrim into a 3D replay you can scrub through,
pause, and inspect from any angle.

1. **Record.** Three stationary observer clients sit on grid while OBS records their overviews
   into one video.
2. **Process.** `scrim-positions` reads (OCRs) each observer's overview in every frame and works
   out every ship's position from the three distances it sees, writing a `*.positions.csv`.
3. **Watch.** The simulator replays that CSV in 3D: hull models, team colours, kills, micro jumps,
   range spheres, a measuring tool, and optional match audio.

Nothing reads EVE client memory and nothing automates or injects input. The pipeline only uses
what the client draws on screen for the player. See [`docs/DESIGN.md`](docs/DESIGN.md) for the
full design and the maths.

## What's in the download

Each release zip contains:

| File | What it is |
|---|---|
| `scrim-simulator` (`.x86_64` / `.exe`) | The replay viewer. |
| `glb-undraco` | Helper the simulator runs to unpack downloaded ship models. Keep it next to the simulator. |
| `scrim-positions` | Turns a recorded match video into a `*.positions.csv`. Needs `ffmpeg` and `ffprobe` on your `PATH`. |

## Quick start: watch the demo match

1. Unzip the release and run `scrim-simulator`.
2. On first run it asks to download ship data: sizes from CCP's Static Data Export, bracket icons
   from CCP's Image Export Collection, and hull models from
   [EVE_Model_Gallery](https://github.com/EstamelGG/EVE_Model_Gallery). These go into `sde/` next
   to the executable. Models are fetched one hull at a time, the first time a match needs one.
3. Click **Add match…** and pick
   [`resouces/demo/match_03.positions.csv`](resouces/demo/match_03.positions.csv) from this
   repository (or just drop the file onto the window).
4. Press **Start** (or Space).

## Recording your own match

[`docs/obs/`](docs/obs/README.md) has an OBS scene collection for recording three observer
clients side by side, and explains how to set it up: which windows to capture, how to crop to the
overview, and which video settings to use. Record near-lossless. The OCR needs crisp text.

## Processing a recording

```sh
scrim-positions --scene docs/obs/scene.json --out out/ match.mkv
```

This writes `out/match.positions.csv`. `scene.json` tells it where each observer's overview is in
the video frame. The one in `docs/obs/` matches the OBS template; adjust its panel rectangles if
your layout differs.

The CSV has one row per pilot per second:
`t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m`.

## Using the simulator

### Match list

The main menu lists the matches you have added. **Add match…** adds a `*.positions.csv`, and
dropping a CSV onto the window adds it and opens it straight away. Select a match and use
**Rename…**, **Remove** or **Add audio…** (also on its right-click menu). Audio (ogg, mp3 or wav) should start at the same moment
as the match data. It then plays in sync with the replay, at any playback speed. **Menu** returns
to the list.

Added matches are copied into the simulator's own library
(`~/.local/share/godot/app_userdata/simulator/matches` on Linux), so they stay available if you
move or delete the original file. Team swaps (⇄ in the roster) and team names (double-click a
team's heading) are saved per match. Pilot renames (right-click a pilot → **Rename pilot…**) apply
in every match, and an empty name restores the original.

### Controls

| Input | Action |
|---|---|
| Space / **Play** | Play or pause (matches open paused) |
| ← / → | Pause and step one tick (1 s) |
| `[` / `]` | Jump to the previous / next event on the timeline (kills, boundary deaths, micro jumps) |
| Timeline slider | Scrub |
| Left drag (empty space) | Orbit the camera |
| Mouse wheel | Zoom |
| Right drag | Pan |
| Click a ship | Select it and show its details top left |
| Double-click a ship | Follow it with the camera |
| Esc / click empty space | Clear the selection |
| Left drag from a ship | Measure: a sphere grows from the ship and brackets every ship it reaches. Drag onto another ship for the hull-to-hull distance. |
| Right-click a ship (in space or roster) | Its debug menu: movement vector and any number of coloured range spheres |
| D / **Debug…** | Debug menu for every ship at once, vector length, and the beacons' 5 km jump range |
| M | Toggle hull models and icons vs. plain spheres |
| B | Toggle the 125 km arena boundary |

**Settings…** has the remaining options: interface scale, **Ship overlay…** (which of name, type,
distance and speed are shown above each ship), smooth vs. straight-line movement, and the
SDE/model download controls. Resize the window to see more of the arena.

## Building from source

### Prerequisites

- [Rust](https://rustup.rs/) (stable)
- [Godot 4.6](https://godotengine.org/download) on your `PATH` as `godot`, or set `$GODOT` to its
  binary. `scripts/build.sh` downloads Godot and its export templates itself if they're missing.
- `ffmpeg` and `ffprobe` to run `scrim-positions` and the Rust tests
- For Windows release builds (cross-compiled from Ubuntu): `sudo apt install mingw-w64`

### Repository layout

| Path | Contents |
|---|---|
| `crates/glyph` | Glyph-template OCR for EVE's UI font |
| `crates/videoin` | Frame decoding via `ffmpeg` |
| `crates/overview` | Overview parsing, tracking and trilateration; the `scrim-positions` and `overview-track` binaries |
| `crates/glb-undraco` | Converts the model gallery's Draco-compressed GLBs into ones Godot can load |
| `simulator/` | The Godot replay viewer (`scripts/`, headless tests in `tests/`) |
| `docs/` | Design document and the OBS template |
| `resouces/` | Demo match and OCR sample images |
| `scripts/` | Build and test scripts |

### Run from source

```sh
# Position extraction
cargo run --release -p overview --bin scrim-positions -- --scene docs/obs/scene.json --out out/ match.mkv

# Simulator (it finds glb-undraco in target/release/)
cargo build --release -p glb-undraco
godot --path simulator                                      # main menu
godot --path simulator -- --csv /abs/path/to/match.positions.csv  # open one file directly
```

`--csv` opens a file without adding it to the library, so team swaps and names last only until you
quit. When running from source, downloaded ship data goes into `simulator/sde/`.

### Tests

```sh
cargo test --workspace --release   # Rust crates (release: the video OCR test is slow unoptimised)
scripts/test.sh                    # simulator tests, headless (uses $GODOT or `godot`)
scripts/test.sh match_data         # only simulator test files whose name contains "match_data"
```

Simulator tests live in `simulator/tests/`. Each `test_*.gd` extends `tests/test_case.gd`, and
every `test_*` method is a test.

### Release builds

```sh
scripts/build.sh [linux|windows|all]   # default: all
```

This builds the simulator (Godot export), `glb-undraco` and `scrim-positions` and zips each
platform into `dist/`.

To publish a release, push a `v*` tag on a commit that's on `master`:

```sh
git tag -a v0.2.0 -m v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` builds both platforms and attaches the zips to a GitHub Release.
`.github/workflows/test.yml` runs both test suites for the tag and fails if the commit isn't on
`master`.

## Credits

- Ship sizes: CCP's Static Data Export. Bracket icons: CCP's Image Export Collection.
- Hull models: [EstamelGG/EVE_Model_Gallery](https://github.com/EstamelGG/EVE_Model_Gallery).
- OCR approach inspired by
  [darkmatter2222/EVE-Online-Bot](https://github.com/darkmatter2222/EVE-Online-Bot).
