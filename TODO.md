## Capture setup (OBS / EVE clients)
- fix eve client window setup
- fix obs scene

## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- output exact eve time of each tick so it can be more easily synced with other data
- bug where some ships seem to be moved out of bounds erroneously
- I should be able to give this a video file and log file get the data I need. It can use the scrimTrimmer do the truncation, but this proccess should preserve the eve timestamps of every tic so it can be synced with other log files later

## Test data (resouces)


## GUI
- pause, play, and navigation of video along with timeline
- stop updating position of ships once it becomes a capsule
- backtrack in time of 100km jump to calculate mjd activation
- incoming and outgoing ewar tracking based on combat log
- instead of one unit 1km, should be 1 unit 1m
- web interface for simulator
- add popup for 10s countdown
- selectable resolution
- ability to center on beacons
- button to re-center on center
- when a ship dies it should show just a bar for the speed and distance rather than the true distance
- add some basic .gifs for the README
- shift + arrow keys to seek forward or back 10s
