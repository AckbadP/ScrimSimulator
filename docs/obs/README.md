# OBS scene template

`scrim-recording.json` is an OBS scene collection for recording a match from three observer
clients on Linux. Its one scene, `Scrim`, on a 2560×1600 canvas, holds four Window Capture
(Xcomposite) sources: the three observers' overviews and one observer's Local chat.

```
+----------------+----------------+
|                |   Observer B   |
|   Observer A   |  (1280×800)    |
|  (1280×1200)   +----------------+
|                |   Observer C   |
+----------------+  (1280×800)    |
| Chat (1280×400)|                |
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
3. The captures are already cropped for the window layout in [`docs/eve`](../eve/README.md):
   2486×1374 windowed, UI scale 1.75. If your observers use that layout, leave the crops as they
   are. If not, change Crop Top/Left/Right/Bottom in Properties until only the overview is left, so
   its text is drawn as large as possible in the slot. Crop off the title bar too.
4. Point **Chat** at one of the observer windows as well. It's cropped to that client's Local chat
   window (messages only; the input box can go). `scrim-positions --chat-log` reads it to match
   the recording against the chat log and find the EVE time. Keep the chat at the client's
   default font size so Tesseract can read it.
5. **Settings → Video**: base (canvas) and output resolution both **2560×1600**, so the output is
   never rescaled. **Settings → Output → Recording**: near-lossless encode (x264 CQP ≈ 12, or
   lossless), 30 or 60 fps. See [DESIGN.md §3.3](../DESIGN.md#33-obs) for why.

## Processing

`scene.json` describes the same three slots as panels A, B and C for `scrim-positions`, and the
chat slot as `chat`:

```sh
scrim-positions --scene docs/obs/scene.json match.mkv
scrim-positions --scene docs/obs/scene.json --chat-log Local_….txt match.mkv   # one match, EVE timestamps
```

The slots are a starting point. A panel must contain the overview's header row and its rows, and
nothing below them that could be read as extra rows (a tab strip, another window). If your cropped
capture doesn't fill its slot, shrink that panel's `rect` to fit. The same goes for `chat`: the
closer it hugs the chat messages, the less else Tesseract has to read.
