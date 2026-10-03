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
const CENTRE_M := Vector3.ONE * CUBE_M / 2.0
## Arena boundary: pilots whose hull reaches further than this from the centre are out of
## bounds (dead).
const BOUNDARY_RADIUS_M := 125000.0
## Pilots starting this close to the centre can't be attributed to a corner line.
const CENTRE_RADIUS_M := 10000.0
## Max distance of a pilot's first position from a corner->centre line to count as on it.
const LINE_TOLERANCE_M := 10000.0

## pilot name -> Array of { t: float, pos: Vector3 (metres), ship_type: String }, sorted by t.
var tracks: Dictionary = {}
## pilot name -> Team, from each pilot's first position.
var teams: Dictionary = {}
## pilot name -> { t: float (match time, s since start), pos: Vector3 (metres) } where the
## pilot first crossed the arena boundary. Pilots who never left are absent.
var deaths: Dictionary = {}
## Lowercase ship type -> published hull radius in metres (from `ShipSizes`); unknown types
## count as points.
var radii: Dictionary = {}
var start_time := 0.0
var duration := 0.0
## Follow a Catmull-Rom spline through the samples instead of straight lines between them.
var smooth := false


static func load_csv(path: String, ship_radii := {}) -> MatchData:
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
	data.radii = ship_radii
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
	data._find_deaths()
	return data


## Puts each pilot on the corner->centre line nearest its first position; the two most
## populated corners become BLUE (lower corner index) and RED, everyone else is UNKNOWN.
func _assign_teams() -> void:
	var centre := CENTRE_M
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


## Hull radius of `ship_type` in metres, or 0.0 if unknown.
func radius_m(ship_type: String) -> float:
	return radii.get(ship_type.to_lower(), 0.0)


## Records where each pilot's hull first touched the boundary sphere; later re-entry is ignored.
func _find_deaths() -> void:
	for pilot in tracks:
		var track: Array = tracks[pilot]
		for i in track.size():
			var b: Dictionary = track[i]
			# The ship centre may get this close before the hull reaches the boundary.
			var limit := maxf(BOUNDARY_RADIUS_M - radius_m(b.ship_type), 0.0)
			if b.pos.distance_to(CENTRE_M) <= limit:
				continue
			if i == 0:
				deaths[pilot] = {"t": b.t - start_time, "pos": b.pos}
			else:
				var a: Dictionary = track[i - 1]
				var w := _boundary_crossing(a.pos, b.pos, limit)
				deaths[pilot] = {"t": lerpf(a.t, b.t, w) - start_time, "pos": a.pos.lerp(b.pos, w)}
			break


## Fraction w in [0, 1] along a->b (a inside, b outside) where the segment hits the sphere of
## radius `r` around the centre.
static func _boundary_crossing(a: Vector3, b: Vector3, r: float) -> float:
	# Solve |a - c + w (b - a)|^2 = R^2 for w.
	var d := b - a
	var f := a - CENTRE_M
	var qa := d.dot(d)
	var qb := 2.0 * f.dot(d)
	var qc := f.dot(f) - r * r
	if qa == 0.0:
		return 1.0
	return clampf((-qb + sqrt(maxf(qb * qb - 4.0 * qa * qc, 0.0))) / (2.0 * qa), 0.0, 1.0)


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
	if not smooth:
		return {"t": t, "pos": a.pos.lerp(b.pos, w), "ship_type": a.ship_type}
	var pre := _neighbour(track, i - 2, a, b)
	var post := _neighbour(track, i + 1, b, a)
	var pos: Vector3 = a.pos.cubic_interpolate_in_time(
			b.pos, pre.pos, post.pos, w, b.t - a.t, pre.t - a.t, post.t - a.t)
	return {"t": t, "pos": pos, "ship_type": a.ship_type}


## Spline control point beyond `end` (away from `other`): `track[j]` if it exists and isn't
## across a gap, else `other` mirrored through `end`.
static func _neighbour(track: Array, j: int, end: Dictionary, other: Dictionary) -> Dictionary:
	if j >= 0 and j < track.size() and absf(track[j].t - end.t) <= MAX_GAP_S:
		return track[j]
	return {"t": end.t * 2.0 - other.t, "pos": end.pos * 2.0 - other.pos}
