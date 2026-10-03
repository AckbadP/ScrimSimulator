# scrim-recorder

**[Download the latest release](https://github.com/AckbadP/ScrimSimulator/releases/latest)**
(Linux and Windows builds of the simulator and `scrim-positions`).

A tool that records everything that happened on an EVE Online grid — ship positions, velocities,
pilots, ship types, and damage/effect events — as a compressed recording for later replay and
simulation. Three or four stationary observer clients are recorded on video; every ship's position
and velocity is recovered by multilaterating the distance and radial-velocity readings each
observer's overview already displays, with the clients' own combat logs fused in for damage and
effect events.

No EVE client process memory is read, and nothing automates or injects input — everything the
pipeline consumes is either rendered on screen for the player to look at, or written to disk by
the client itself.

**Status: design phase.** No implementation yet. See [`docs/DESIGN.md`](docs/DESIGN.md) for the
full design: the multilateration math, OBS/capture requirements, the glyph-matching OCR approach
(inspired by [darkmatter2222/EVE-Online-Bot](https://github.com/darkmatter2222/EVE-Online-Bot)),
the on-disk recording format, and the validation plan.

## Simulator (`simulator/`)

A standalone Godot 4.6 replay viewer for the `*.positions.csv` files written by `scrim-positions`.
Each pilot is a placeholder sphere. Boxes mark the 100 km cube's corners and its centre.

```sh
godot --path simulator -- --csv /abs/path/to/match_03.positions.csv
```

You can also load a CSV with the **Open CSV…** button, or by dropping the file onto the window.
Controls: Space plays/pauses, ←/→ seek 10 s, the slider scrubs. Left/right drag orbits the camera,
the wheel zooms, and middle drag pans.

### Tests

`simulator/tests/` holds a headless, dependency-free test suite (CSV loading, team assignment,
boundary deaths, interpolation, SDE cache/zip parsing, settings, camera, and playback in
`main.gd`). Each `test_*.gd` extends `tests/test_case.gd`; every `test_*` method is a test.

```sh
scripts/test.sh               # all tests (uses $GODOT or `godot` on PATH)
scripts/test.sh match_data    # only test files whose name contains "match_data"
```

`.github/workflows/test.yml` runs these and `cargo test` on every push and pull request.

## Building releases

`scripts/build.sh [linux|windows|all]` builds the simulator (Godot export) and `scrim-positions`
and zips each platform into `dist/`. It runs on Ubuntu; the Windows build is cross-compiled and
needs `sudo apt install mingw-w64`. Godot 4.6 and its export templates are downloaded on first
run if missing (set `$GODOT` to use a specific binary).

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds both platforms and attaches
the zips to a GitHub Release:

```sh
git tag -a v0.2.0 -m v0.2.0 && git push origin v0.2.0
```
