class_name MatchData
extends RefCounted
## Per-pilot position tracks loaded from a `scrim-positions` CSV:
## `t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m`.
## Positions are metres in the observers' cube frame (0..100 km per axis).

## Samples further apart than this are treated as a gap: the ship is hidden in between.
const MAX_GAP_S := 5.0

## Teams start strung along lines from two cube corners to the centre.
enum Team { UNKNOWN = -1, BLUE = 0, RED = 1 }
const CUBE_M := 100000.0
## Pilots starting this close to the centre can't be attributed to a corner line.
const CENTRE_RADIUS_M := 10000.0
## Max distance of a pilot's first position from a corner->centre line to count as on it.
const LINE_TOLERANCE_M := 10000.0

## pilot name -> Array of { t: float, pos: Vector3 (metres), ship_type: String }, sorted by t.
var tracks: Dictionary = {}
## pilot name -> Team, from each pilot's first position.
var teams: Dictionary = {}
var start_time := 0.0
var duration := 0.0


static func load_csv(path: String) -> MatchData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return null
	var header := f.get_csv_line()
	var col := {}
	for i in header.size():
		col[header[i].strip_edges()] = i
	for name in ["t", "pilot", "ship_type", "x_m", "y_m", "z_m"]:
		if not col.has(name):
			push_error("%s: missing column '%s' (expected a scrim-positions CSV)" % [path, name])
			return null

	var data := MatchData.new()
	var t_min := INF
	var t_max := -INF
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < header.size():
			continue
		var x: String = row[col["x_m"]]
		if x.is_empty():
			continue
		var t := float(row[col["t"]])
		var pilot: String = row[col["pilot"]]
		var s := {
			"t": t,
			"pos": Vector3(float(x), float(row[col["y_m"]]), float(row[col["z_m"]])),
			"ship_type": row[col["ship_type"]],
		}
		if not data.tracks.has(pilot):
			data.tracks[pilot] = []
		data.tracks[pilot].append(s)
		t_min = minf(t_min, t)
		t_max = maxf(t_max, t)

	if data.tracks.is_empty():
		push_error("%s: no position rows" % path)
		return null
	for pilot in data.tracks:
		data.tracks[pilot].sort_custom(func(a, b): return a.t < b.t)
	data.start_time = t_min
	data.duration = t_max - t_min
	data._assign_teams()
	return data


## Puts each pilot on the corner->centre line nearest its first position; the two most
## populated corners become BLUE (lower corner index) and RED, everyone else is UNKNOWN.
func _assign_teams() -> void:
	var centre := Vector3.ONE * CUBE_M / 2.0
	var corner_of := {}  # pilot -> corner index, or -1
	var counts := {}  # corner index -> pilot count
	for pilot in tracks:
		var p: Vector3 = tracks[pilot][0].pos
		var best := -1
		if p.distance_to(centre) >= CENTRE_RADIUS_M:
			var best_d := LINE_TOLERANCE_M
			for i in 8:
				var corner := Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * CUBE_M
				var d := p.distance_to(Geometry3D.get_closest_point_to_segment(p, centre, corner))
				if d < best_d:
					best_d = d
					best = i
		corner_of[pilot] = best
		if best >= 0:
			counts[best] = counts.get(best, 0) + 1

	var corners := counts.keys()
	corners.sort_custom(func(a, b): return counts[a] > counts[b])
	var team_corners := corners.slice(0, 2)
	team_corners.sort()
	for pilot in tracks:
		var idx := team_corners.find(corner_of[pilot])
		teams[pilot] = Team.UNKNOWN if idx < 0 else idx  # 0 = BLUE, 1 = RED


## Interpolated state of `pilot` at match time `t` (seconds since start), or an empty
## Dictionary when the pilot has no data then (before first / after last sample, or in a gap).
func sample(pilot: String, t: float) -> Dictionary:
	var track: Array = tracks[pilot]
	t += start_time
	if track.is_empty() or t < track[0].t or t > track[-1].t:
		return {}
	var i := track.bsearch_custom(t, func(s, v): return s.t < v)
	# i = first sample with s.t >= t.
	if i < track.size() and is_equal_approx(track[i].t, t):
		return track[i]
	var a: Dictionary = track[i - 1]
	var b: Dictionary = track[i]
	if b.t - a.t > MAX_GAP_S:
		return {}
	var w: float = (t - a.t) / (b.t - a.t)
	return {"t": t, "pos": a.pos.lerp(b.pos, w), "ship_type": a.ship_type}
