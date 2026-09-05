# scrim-recorder

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
