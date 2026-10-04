extends "res://tests/test_case.gd"
## End-to-end checks against the anonymized demo match checked in at
## `resouces/demo/match_03.positions.csv` (regenerate with `scripts/anonymize.py`). It lives
## outside the Godot project so it isn't imported as a translation table.

const Main := preload("res://scripts/main.gd")

const PILOTS := 20
## Every hull in the demo, with its SDE radius in metres (build 3569502). Pinned here so the
## tests run offline; `sde/` is git-ignored and absent in CI.
const HULL_RADII := {
	"Capsule": 2.0, "Venture": 41.0, "Prospect": 41.0, "Endurance": 41.0,
	"Procurer": 137.0, "Retriever": 202.0, "Covetor": 254.0, "Skiff": 137.0, "Mackinaw": 202.0,
	"Porpoise": 450.0, "Orca": 550.0,
}
const PILOT_PATTERN := "^(Amarr|Caldari|Gallente|Minmatar) Citizen \\d{7}$"

var _saved_path: String


static func demo_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join(
		"../resouces/demo/match_03.positions.csv").simplify_path()


## `MatchData` radii: lowercase ship type -> metres.
static func radii() -> Dictionary:
	var out := {}
	for hull in HULL_RADII:
		out[hull.to_lower()] = HULL_RADII[hull]
	return out


func _load() -> MatchData:
	return MatchData.load_csv(demo_path(), radii())


## Ship type `pilot` was flying at match time `t`.
static func _ship_at(d: MatchData, pilot: String, t: float) -> String:
	var ship := ""
	for s in d.tracks[pilot]:
		if s.t - d.start_time > t:
			break
		ship = s.ship_type
	return ship


func before_each() -> void:
	# main.gd reads settings on _ready; keep the real ones untouched and stay offline.
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null
	Settings.set_value("sde/auto_update", false)
	Settings.set_value("display/ship_models", false)


func after_each() -> void:
	Settings.path = _saved_path
	Settings._cfg = null


# --- the file itself ---------------------------------------------------------

func test_file_exists() -> void:
	assert_true(FileAccess.file_exists(demo_path()), demo_path())


func test_pilots_are_anonymized() -> void:
	var d := _load()
	var re := RegEx.create_from_string(PILOT_PATTERN)
	for pilot in d.tracks:
		assert_not_null(re.search(pilot), "pilot name %s" % pilot)


func test_ships_are_mining_hulls() -> void:
	var d := _load()
	for pilot in d.tracks:
		for s in d.tracks[pilot]:
			if not HULL_RADII.has(s.ship_type):
				fail("%s flies %s at t=%s" % [pilot, s.ship_type, s.t])
				return


# --- MatchData ---------------------------------------------------------------

func test_load() -> void:
	var d := _load()
	assert_not_null(d)
	assert_eq(d.tracks.size(), PILOTS)
	assert_eq(d.start_time, 11.0, "countdown skipped: first ship moves at t=12")
	assert_eq(d.duration, 574.0)
	var samples := 0
	for pilot in d.tracks:
		samples += d.tracks[pilot].size()
	assert_eq(samples, 11102)


func test_tracks_sorted() -> void:
	var d := _load()
	for pilot in d.tracks:
		var track: Array = d.tracks[pilot]
		for i in range(1, track.size()):
			if track[i].t < track[i - 1].t:
				fail("%s unsorted at sample %d" % [pilot, i])
				break


func test_teams() -> void:
	var d := _load()
	var counts := {MatchData.Team.BLUE: 0, MatchData.Team.RED: 0, MatchData.Team.UNKNOWN: 0}
	for pilot in d.teams:
		counts[d.teams[pilot]] += 1
	assert_eq(counts[MatchData.Team.BLUE], 10, "blue")
	assert_eq(counts[MatchData.Team.RED], 9, "red")
	assert_eq(counts[MatchData.Team.UNKNOWN], 1, "unknown")
	assert_eq(d.teams["Amarr Citizen 2674287"], MatchData.Team.BLUE)
	assert_eq(d.teams["Caldari Citizen 6206817"], MatchData.Team.RED)
	assert_eq(d.teams["Amarr Citizen 2281178"], MatchData.Team.UNKNOWN, "starts off both lines")


func test_deaths() -> void:
	var d := _load()
	var dead := d.deaths.keys()
	dead.sort()
	assert_eq(dead, ["Amarr Citizen 5054432", "Caldari Citizen 8777524", "Caldari Citizen 9942864"])
	assert_almost(d.deaths["Amarr Citizen 5054432"].t, 221.571, 1e-2)
	assert_almost(d.deaths["Caldari Citizen 9942864"].t, 329.827, 1e-2)
	assert_almost(d.deaths["Caldari Citizen 8777524"].t, 418.890, 1e-2)
	assert_eq(_ship_at(d, "Amarr Citizen 5054432", d.deaths["Amarr Citizen 5054432"].t), "Prospect")
	assert_eq(_ship_at(d, "Caldari Citizen 9942864", d.deaths["Caldari Citizen 9942864"].t), "Capsule")


## A death is where the hull sphere touches the boundary, so the ship's centre is one hull
## radius inside it.
func test_deaths_touch_boundary_with_hull() -> void:
	var d := _load()
	for pilot in d.deaths:
		var death: Dictionary = d.deaths[pilot]
		var r: float = HULL_RADII[_ship_at(d, pilot, death.t)]
		assert_almost(death.pos.distance_to(MatchData.CENTRE_M),
			MatchData.BOUNDARY_RADIUS_M - r, 1.0, "%s centre at boundary - %s m" % [pilot, r])


## No surviving pilot's hull ever crosses the boundary.
func test_survivors_stay_inside_with_hull() -> void:
	var d := _load()
	for pilot in d.tracks:
		if d.deaths.has(pilot):
			continue
		for s in d.tracks[pilot]:
			var reach: float = s.pos.distance_to(MatchData.CENTRE_M) + HULL_RADII[s.ship_type]
			if reach > MatchData.BOUNDARY_RADIUS_M:
				fail("%s's %s reaches %.0f m at t=%s" % [pilot, s.ship_type, reach, s.t])
				break


func test_ship_change_to_capsule() -> void:
	var d := _load()
	var track: Array = d.tracks["Amarr Citizen 0220922"]
	assert_eq(track[0].ship_type, "Porpoise")
	assert_eq(track[-1].ship_type, "Capsule")


func test_events() -> void:
	var d := _load()
	var count := {}
	for e in d.events:
		count[e.kind] = count.get(e.kind, 0) + 1
	assert_eq(count.get(MatchData.Event.DEATH, 0), 11, "pilots podded")
	assert_eq(count.get(MatchData.Event.BOUNDARY, 0), d.deaths.size())
	assert_eq(count.get(MatchData.Event.MJD, 0), 0, "pod warps aren't MJDs")


func test_sample() -> void:
	var d := _load()
	var pilot := "Amarr Citizen 0220922"
	var s := d.sample(pilot, 89.0)
	assert_eq(s.ship_type, "Porpoise")
	assert_almost(s.pos, Vector3(40775, 57520, 68065))

	var a := d.sample(pilot, 89.0)
	var b := d.sample(pilot, 90.0)
	var mid := d.sample(pilot, 89.5)
	assert_almost(mid.pos, a.pos.lerp(b.pos, 0.5))

	assert_eq(d.sample(pilot, -d.start_time - 1.0), {}, "before the recording")
	assert_eq(d.sample(pilot, 575.0), {}, "after the match")


# --- main.gd -----------------------------------------------------------------

## The viewer, with SDE sizes for the demo hulls standing in for the (offline) cache.
func _viewer() -> Main:
	var m: Main = Main.new()
	add_node(m)
	m.sizes.ships.clear()
	for hull in HULL_RADII:
		m.sizes.ships[hull.to_lower()] = {
			"name": hull, "type_id": 0, "group_id": 0, "radius_m": HULL_RADII[hull],
		}
	m.load_match(demo_path())
	m.start_button.pressed.emit()
	return m


func test_viewer_loads_demo() -> void:
	var m := _viewer()
	assert_not_null(m.data)
	assert_eq(m.ships.size(), PILOTS)
	assert_eq(m.timeline.max_value, 574.0)
	assert_eq(m.file_label.text,
		"match_03.positions.csv — 20 pilots (blue 10 / red 9 / unknown 1), 3 out of bounds")


func test_viewer_plays_through() -> void:
	var m := _viewer()
	m.speed = 10.0
	for i in 60:
		m._process(1.0)
	assert_eq(m.time, 574.0)
	assert_false(m.playing)
