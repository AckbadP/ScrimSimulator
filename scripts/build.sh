#!/usr/bin/env bash
# Build release bundles of the Godot simulator and the scrim-positions OCR tool.
#
#   scripts/build.sh [linux|windows|all]    (default: all)
#
# Output: dist/scrim-simulator-<version>-<platform>-x86_64.zip
# Runs on Ubuntu; Windows is cross-compiled (needs `mingw-w64`). Godot and its export templates
# are downloaded into .cache/ / the user's Godot data dir if not already present. Override the
# Godot binary with $GODOT.
set -euo pipefail

GODOT_VERSION="4.6"
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_RELEASES="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}"
TEMPLATES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_VERSION}.stable"
WIN_TARGET="x86_64-pc-windows-gnu"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-all}"
case "$TARGET" in
    linux|windows|all) ;;
    *) echo "usage: $0 [linux|windows|all]" >&2; exit 2 ;;
esac

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "v0.0.0")"
CACHE="$ROOT/.cache/godot"
DIST="$ROOT/dist"

log() { printf '==> %s\n' "$*"; }

ensure_godot() {
    if [[ -z "${GODOT:-}" ]]; then
        if command -v godot >/dev/null && godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}\.stable"; then
            GODOT="$(command -v godot)"
        else
            GODOT="$CACHE/Godot_v${GODOT_TAG}_linux.x86_64"
            if [[ ! -x "$GODOT" ]]; then
                log "downloading Godot ${GODOT_TAG}"
                mkdir -p "$CACHE"
                curl -fL -o "$CACHE/godot.zip" "$GODOT_RELEASES/Godot_v${GODOT_TAG}_linux.x86_64.zip"
                unzip -o -q "$CACHE/godot.zip" -d "$CACHE"
                rm "$CACHE/godot.zip"
                chmod +x "$GODOT"
            fi
        fi
    fi
    if [[ ! -f "$TEMPLATES_DIR/version.txt" ]]; then
        log "downloading Godot ${GODOT_TAG} export templates"
        mkdir -p "$CACHE" "$TEMPLATES_DIR"
        curl -fL -o "$CACHE/templates.tpz" "$GODOT_RELEASES/Godot_v${GODOT_TAG}_export_templates.tpz"
        # The .tpz is a zip with everything under templates/.
        unzip -o -q "$CACHE/templates.tpz" -d "$CACHE/tpz"
        cp -r "$CACHE/tpz/templates/." "$TEMPLATES_DIR/"
        rm -rf "$CACHE/templates.tpz" "$CACHE/tpz"
    fi
    # A clean checkout has no .godot/ import cache; exports need it.
    if [[ ! -d simulator/.godot ]]; then
        log "importing Godot project"
        "$GODOT" --headless --path simulator --import >/dev/null
    fi
}

export_simulator() { # <preset> <path relative to simulator/>
    mkdir -p "simulator/$(dirname "$2")"
    "$GODOT" --headless --path simulator --export-release "$1" "$2"
}

write_readme() { # <dir> <sim exe> <ocr exe>
    cat > "$1/README.txt" <<EOF
Scrim Simulator ${VERSION}

$2
    Replay viewer for *.positions.csv files. Open a CSV with the "Open CSV..." button, by
    dropping it onto the window, or from the command line:
        $2 -- --csv /path/to/match.positions.csv
    Ship sizes are downloaded from the EVE static data export into sde/ next to the
    executable on first run.

$3
    OCRs a three-observer scrim recording into <video>.positions.csv:
        $3 --scene scene.json --out out/ match.mkv
    Requires ffmpeg and ffprobe on PATH.

Source: https://github.com/AckbadP/ScrimSimulator
EOF
}

package() { # <platform> <sim exe path> <ocr exe path>
    local name="scrim-simulator-${VERSION}-$1-x86_64"
    local stage="$DIST/$name"
    rm -rf "$stage" "$DIST/$name.zip"
    mkdir -p "$stage"
    cp "$2" "$3" "$stage/"
    write_readme "$stage" "$(basename "$2")" "$(basename "$3")"
    (cd "$DIST" && zip -q -r "$name.zip" "$name")
    log "built dist/$name.zip"
}

build_linux() {
    log "building scrim-positions (linux)"
    cargo build --release -p overview --bin scrim-positions
    log "exporting simulator (linux)"
    export_simulator "Linux" "export/linux/scrim-simulator.x86_64"
    package linux simulator/export/linux/scrim-simulator.x86_64 target/release/scrim-positions
}

build_windows() {
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
        echo "error: x86_64-w64-mingw32-gcc not found; install it with: sudo apt install mingw-w64" >&2
        exit 1
    fi
    if ! rustup target list --installed | grep -qx "$WIN_TARGET"; then
        rustup target add "$WIN_TARGET"
    fi
    log "building scrim-positions (windows)"
    cargo build --release -p overview --bin scrim-positions --target "$WIN_TARGET"
    log "exporting simulator (windows)"
    export_simulator "Windows Desktop" "export/windows/scrim-simulator.exe"
    package windows simulator/export/windows/scrim-simulator.exe "target/$WIN_TARGET/release/scrim-positions.exe"
}

ensure_godot
mkdir -p "$DIST"
[[ "$TARGET" == linux || "$TARGET" == all ]] && build_linux
[[ "$TARGET" == windows || "$TARGET" == all ]] && build_windows
log "done ($VERSION)"
