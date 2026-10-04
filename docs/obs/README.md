# OBS scene template

`scrim-recording.json` is an OBS scene collection for recording a match from three observer
clients on Linux. Its one scene, `Scrim`, on a 2560×1600 canvas, holds three Window Capture
(Xcomposite) sources:

```
+----------------+----------------+
|                |   Observer B   |
|                |  (1280×800)    |
|   Observer A   +----------------+
|  (1280×1600)   |   Observer C   |
|                |  (1280×800)    |
+----------------+----------------+
```

Each source is fitted into its slot with "scale to inner bounds", so whatever you capture keeps its
aspect ratio and is anchored to the slot's top-left corner. The items are locked so they can't be
dragged out of place by accident.

## Setup

1. **Scene Collection → Import**, choose `scrim-recording.json`, then select "Scrim Recording" from
   the Scene Collection menu.
2. For each Observer source, open **Properties** and pick that observer's `EVE - <name>` window.
   Window IDs change every session, so the template leaves them blank.
3. Still in Properties, crop the capture (Crop Top/Left/Right/Bottom) down to the overview so its
   text is drawn as large as possible in the slot. Crop off the title bar too.
4. **Settings → Video**: base (canvas) and output resolution both **2560×1600**, so the output is
   never rescaled. **Settings → Output → Recording**: near-lossless encode (x264 CQP ≈ 12, or
   lossless), 30 or 60 fps. See [DESIGN.md §3.3](../DESIGN.md#33-obs) for why.

## Processing

`scene.json` describes the same three slots as panels A, B and C for `scrim-positions`:

```sh
scrim-positions --scene docs/obs/scene.json match.mkv
```

The slots are a starting point. A panel must contain the overview's header row and its rows, and
nothing below them that could be read as extra rows (a tab strip, another window). If your cropped
capture doesn't fill its slot, shrink that panel's `rect` to fit.
