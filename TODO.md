## Capture setup (OBS / EVE clients)
- fix eve client window setup
- fix obs scene

## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- bug where some ships seem to be moved out of bounds erroneously
- gpu acceleration

## Test data (resouces)


## GUI
- pause, play, and navigation of video along with timeline
- stop updating position of ships once it becomes a capsule
- backtrack in time of 100km jump to calculate mjd activation
- instead of one unit 1km, should be 1 unit 1m
- web interface for simulator
- add popup for 10s countdown
- selectable resolution
- ability to center on beacons
- button to re-center on center
- when a ship dies it should show just a bar for the speed and distance rather than the true distance
- add some basic .gifs for the README
- shift + arrow keys to seek forward or back 10s
- option to hide dead ships (or just movement of dead pilots)
- upload folders per scrim with data paired via names for match and audio, folders for library of scrims
- user should be able to upload a combat log and select a match or folder it is associated with. The data gets parsed and saved to the library, discarding any data that dosen't fall within a match
