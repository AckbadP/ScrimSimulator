## Capture setup (OBS / EVE clients)
- fix eve client window setup
- fix obs scene

## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- output exact eve time of each tick so it can be more easilly synced with other data
- bug where some ships seem to be moved out of bounds errouniously

## Test data (resouces)


## GUI
- pause, play, and navigation of video along with timeline
- stop updating position of ships once it becomes a capsule
- backtrack in time of 100km jump to calculate mjd activaton
- incoming and outgoing ewar tracking based on combat log
- togglable vectors for ship movement
- show mjd activation range
- instead of one unit 1km, should be 1 unit 1m
- tooltips
- basic menu for simulator 
- web interface for simulator
- add popup for 10s countdown
- selectable resolution
- Measure tool to check distance between any two points
- ability to asign shapes to ships or points (ie 30km shpear around ashimu) that can be color coded
- right side menu should display speed and distance from center
- ability to center on beacons
- button to re-center on center
- speed should auto-truncate to km with 1 decimal at or above 1 km/s, and it should not be interpolated instead showing the actual speed value for each step
- when a ship dies it should sno just a bar for the speed and distance rather then the true distance
- Ability to sync with audio from scrim
