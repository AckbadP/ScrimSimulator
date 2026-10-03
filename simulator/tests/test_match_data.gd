extends "res://tests/test_case.gd"
## MatchData: CSV loading, team assignment, boundary deaths and track sampling.

const C := MatchData.CENTRE_M
const X := Vector3.RIGHT


func _load(rows: Array, radii := {}) -> MatchData:
	return MatchData.load_csv(write_csv(rows), radii)


# --- load_csv ----------------------------------------------------------------

func test_load_missing_file_returns_null() -> void:
	assert_null(MatchData.load_csv(temp_dir().path_join("nope.csv")))


func test_load_missing_column_returns_null() -> void:
	var path := write_csv([[0, "A", "Rifter", 1, 2]], "t,pilot,ship_type,x_m,y_m")
	assert_null(MatchData.load_csv(path))


func test_load_header_only_returns_null() -> void:
	assert_null(_load([]))


func test_load_skips_blank_position_and_short_rows() -> void:
	var d := _load([
		row(0, "A", "Rifter", C),
		"5,A,Rifter,,,,0,0,0,0,0",
		"6,A,Rifter",
		row(7, "A", "Rifter", C + X),
	])
	assert_not_null(d)
	assert_eq(d.tracks["A"].size(), 2)
	assert_eq(d.tracks["A"][1].pos, C + X)


func test_load_sorts_samples_and_sets_time_range() -> void:
	var d := _load([
		row(13, "A", "Rifter", C),
		row(11, "A", "Rifter", C),
		row(12, "B", "Merlin", C),
		row(12, "A", "Rifter", C),
	])
	assert_eq(d.tracks["A"].map(func(s): return s.t), [11.0, 12.0, 13.0])
	assert_eq(d.tracks.keys().size(), 2)
	assert_eq(d.start_time, 11.0)
	assert_eq(d.duration, 2.0)


func test_load_reads_sample_fields() -> void:
	var d := _load([row(1.5, "A Pilot", "Rifter", Vector3(1, 2, 3))])
	var s: Dictionary = d.tracks["A Pilot"][0]
	assert_eq(s.t, 1.5)
	assert_eq(s.pos, Vector3(1, 2, 3))
	assert_eq(s.ship_type, "Rifter")


func test_load_tolerates_reordered_padded_header() -> void:
	var path := write_csv(["Rifter,0,1,2,3,A"], " ship_type , t , x_m , y_m , z_m , pilot ")
	var d := MatchData.load_csv(path)
	assert_not_null(d)
	assert_eq(d.tracks["A"][0].pos, Vector3(1, 2, 3))
	assert_eq(d.tracks["A"][0].ship_type, "Rifter")


func test_radius_m_is_case_insensitive() -> void:
	var d := _load([row(0, "A", "Rifter", C)], {"rifter": 31.0})
	assert_eq(d.radius_m("RIFTER"), 31.0)
	assert_eq(d.radius_m("Rifter"), 31.0)
	assert_eq(d.radius_m("Unknown Hull"), 0.0)


# --- teams -------------------------------------------------------------------

func test_two_corners_become_blue_and_red_by_corner_index() -> void:
	# Corner 7 has more pilots, but the lower corner index is always BLUE.
	var d := _load([
		row(0, "r1", "x", on_line(7, 0.5)),
		row(0, "r2", "x", on_line(7, 0.8)),
		row(0, "r3", "x", on_line(7, 0.3)),
		row(0, "b1", "x", on_line(2, 0.5)),
		row(0, "b2", "x", on_line(2, 0.9)),
	])
	for p in ["b1", "b2"]:
		assert_eq(d.teams[p], MatchData.Team.BLUE, p)
	for p in ["r1", "r2", "r3"]:
		assert_eq(d.teams[p], MatchData.Team.RED, p)


func test_third_corner_is_unknown() -> void:
	var d := _load([
		row(0, "a1", "x", on_line(0, 0.5)),
		row(0, "a2", "x", on_line(0, 0.6)),
		row(0, "b1", "x", on_line(7, 0.5)),
		row(0, "b2", "x", on_line(7, 0.6)),
		row(0, "c1", "x", on_line(3, 0.5)),
	])
	assert_eq(d.teams["a1"], MatchData.Team.BLUE)
	assert_eq(d.teams["b1"], MatchData.Team.RED)
	assert_eq(d.teams["c1"], MatchData.Team.UNKNOWN)


func test_pilot_near_centre_is_unknown() -> void:
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
		row(0, "mid", "x", C + X * (MatchData.CENTRE_RADIUS_M - 1.0)),
	])
	assert_eq(d.teams["mid"], MatchData.Team.UNKNOWN)


func test_pilot_off_every_line_is_unknown() -> void:
	# ~32.7 km from each corner->centre line, well beyond LINE_TOLERANCE_M.
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
		row(0, "off", "x", C + Vector3(0, 0, 40000)),
	])
	assert_eq(d.teams["off"], MatchData.Team.UNKNOWN)


func test_pilot_within_line_tolerance_is_assigned() -> void:
	var p := on_line(0, 0.5) + Vector3(1, -1, 0).normalized() * (MatchData.LINE_TOLERANCE_M - 100.0)
	var d := _load([
		row(0, "near", "x", p),
		row(0, "b", "x", on_line(7, 0.5)),
	])
	assert_eq(d.teams["near"], MatchData.Team.BLUE)


func test_team_comes_from_first_position() -> void:
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(10, "a", "x", on_line(7, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
	])
	assert_eq(d.teams["a"], MatchData.Team.BLUE)
	assert_eq(d.teams["b"], MatchData.Team.RED)


func test_single_corner_is_blue() -> void:
	var d := _load([row(0, "a", "x", on_line(5, 0.5)), row(0, "b", "x", on_line(5, 0.7))])
	assert_eq(d.teams["a"], MatchData.Team.BLUE)
	assert_eq(d.teams["b"], MatchData.Team.BLUE)


# --- deaths ------------------------------------------------------------------

func test_pilot_inside_boundary_has_no_death() -> void:
	var d := _load([row(0, "a", "x", C), row(10, "a", "x", C + X * 120000.0)])
	assert_false(d.deaths.has("a"))


func test_boundary_crossing_is_interpolated() -> void:
	var d := _load([
		row(10, "early", "x", C),
		row(20, "a", "x", C + X * 100000.0),
		row(30, "a", "x", C + X * 150000.0),
	])
	assert_true(d.deaths.has("a"))
	# Halfway between samples; time is relative to the match start (t=10).
	assert_almost(d.deaths["a"].t, 15.0)
	assert_almost(d.deaths["a"].pos, C + X * MatchData.BOUNDARY_RADIUS_M, 1.0)
	assert_false(d.deaths.has("early"))


func test_first_sample_outside_dies_there() -> void:
	var p := C + Vector3(0, 130000, 0)
	var d := _load([row(4, "start", "x", C), row(6, "a", "x", p), row(8, "a", "x", C)])
	assert_eq(d.deaths["a"].t, 2.0)
	assert_eq(d.deaths["a"].pos, p)


func test_first_crossing_wins_after_reentry() -> void:
	var d := _load([
		row(0, "a", "x", C + X * 100000.0),
		row(10, "a", "x", C + X * 150000.0),
		row(20, "a", "x", C + X * 100000.0),
		row(30, "a", "x", C + X * 200000.0),
	])
	assert_almost(d.deaths["a"].t, 5.0)


func test_hull_radius_brings_boundary_closer() -> void:
	var rows := [row(0, "a", "Big Hull", C), row(10, "a", "Big Hull", C + X * 110000.0)]
	assert_false(_load(rows).deaths.has("a"), "unknown size is a point")
	var d := _load(rows, {"big hull": 20000.0})
	assert_true(d.deaths.has("a"), "20 km hull reaches 125 km at 105 km")
	assert_almost(d.deaths["a"].t, 10.0 * 105.0 / 110.0)
	assert_almost(d.deaths["a"].pos, C + X * 105000.0, 1.0)


func test_boundary_crossing_fraction() -> void:
	assert_almost(MatchData._boundary_crossing(C, C + X * 200.0, 100.0), 0.5)
	assert_almost(MatchData._boundary_crossing(C + X * 50.0, C + X * 150.0, 100.0), 0.5)
	# Degenerate segment.
	assert_eq(MatchData._boundary_crossing(C + X * 200.0, C + X * 200.0, 100.0), 1.0)
	# Both ends inside: the crossing lies beyond b, so it's clamped.
	assert_eq(MatchData._boundary_crossing(C, C + X * 50.0, 100.0), 1.0)


# --- sample ------------------------------------------------------------------

func _sample_data() -> MatchData:
	return _load([
		row(100, "p", "Rifter", Vector3(0, 0, 0)),
		row(102, "p", "Capsule", Vector3(20, 0, 0)),
		row(110, "p", "Capsule", Vector3(20, 80, 0)),  # 8 s gap > MAX_GAP_S
		row(114, "p", "Capsule", Vector3(20, 80, 40)),
	])


func test_sample_outside_track_is_empty() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", -0.5), {})
	assert_eq(d.sample("p", 14.5), {})


func test_sample_on_a_sample_returns_it() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", 0.0).pos, Vector3(0, 0, 0))
	assert_eq(d.sample("p", 2.0).pos, Vector3(20, 0, 0))
	assert_eq(d.sample("p", 14.0).pos, Vector3(20, 80, 40))


func test_sample_interpolates_relative_to_start() -> void:
	var d := _sample_data()
	var s := d.sample("p", 0.5)
	assert_almost(s.pos, Vector3(5, 0, 0))
	assert_almost(s.t, 100.5)
	assert_eq(s.ship_type, "Rifter", "ship type comes from the earlier sample")
	assert_almost(d.sample("p", 12.0).pos, Vector3(20, 80, 20))


func test_sample_in_gap_is_empty() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", 6.0), {})


func test_sample_gap_of_exactly_max_is_interpolated() -> void:
	var g := MatchData.MAX_GAP_S
	var d := _load([row(0, "p", "x", Vector3.ZERO), row(g, "p", "x", X * g)])
	assert_almost(d.sample("p", g / 2.0).pos, X * g / 2.0)
