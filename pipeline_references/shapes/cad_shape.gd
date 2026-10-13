extends RefCounted

# ==============================================================================
# CAD SHAPES (port of the editor's CAD solid pipeline)
# ==============================================================================
# WHY IT EXISTS: The editor's CAD tools (push/pull, revolve, follow-me, blend,
# swept blend, voids) store a shape as PROFILES plus an ordered list of
# OPERATIONS under layer["cadShapes"]. There is no baked mesh in the JSON: the
# editor rebuilds every solid on load (src/cad/model/ShapeSolids.ts ->
# buildShapeSolids / resolveVoids, drawn by CADShapeManager.ts). Without this
# file those solids simply did not exist in the render.
#
# Source files ported, one section each below:
#   model/profileGeometry.ts   isProfileClosed, normalizeProfilePoints
#   topology/Extrude.ts        buildExtrudedGeometry          (push/pull)
#   topology/SolidFaces.ts     signedLoopArea, side-wall outward normals
#   topology/SolidFaceGroups.ts paintable faces of a prism
#   topology/Loft.ts           loftRings + loft faces          (shared core)
#   topology/Revolve.ts        buildRevolveGeometry
#   topology/FollowMe.ts       mitered / rotation-minimising sweep
#   topology/ProfileResample.ts correspondSections
#   topology/Blend.ts          blend and swept blend
#   topology/BoxUV.ts          world-space box UVs, 1 UV = 1 metre
#   model/ProfileCutters.ts    flat outlines cutting straight through
#   model/ShapeSolids.ts       which solids a shape is made of
#   CADShapeManager.ts         voids, materials, what is (not) drawn
#
# Coordinates: profile points are METRES in the editor's three.js world
# (x = plan x, y = up, z = plan y), stored layer-local. They are lifted by the
# layer altitude and passed through the scene's plan rotation, so they land
# exactly where walls and items built from the same plan land.
#
# Triangles are produced in three.js order (counter-clockwise seen from
# outside) exactly as the editor builds them, and only flipped to Godot's
# clockwise front-face convention when the mesh is written.
# ==============================================================================

var main_script: Object
var _layer_altitude: float = 0.0
var _material_cache: Dictionary = {}

# Distance under which two profile points are the same point (CADTolerance).
const CAD_TOLERANCE = 0.000001
# Neighbouring faces meeting at less than this are one paintable surface.
const SMOOTH_ANGLE_DEG = 25.0
# Cut void forms (and boolean 'subtract' tools) out of the solids they pass
# through, as the editor does. Uses Godot CSG on closed solids only.
const CAD_APPLY_VOIDS = true
# The editor shows a closed outline that was never pulled into a solid as a
# 30%-opaque draft face. A finished render normally should not; set true to
# draw them as thin translucent faces anyway.
const CAD_RENDER_FLAT_FACES = false
# Editor default surface for any face nobody painted (defaultSolidMaterial).
const CAD_DEFAULT_COLOR = "#d0d0d0"
const CAD_DEFAULT_ROUGHNESS = 0.4
const CAD_DEFAULT_METALNESS = 0.1

const EPS = 0.000000001

func _init(p_main_script: Object):
	main_script = p_main_script

# ==============================================================================
# ENTRY POINT
# ==============================================================================
# Builds every CAD shape of one layer under `parent`. Returns the number of
# solids added. Never raises: a shape that cannot be built is skipped and
# logged, the rest of the layer still renders.
func build_layer_cad_shapes(parent: Node3D, cad_shapes, layer_altitude: float, layer_id: String = "") -> int:
	_layer_altitude = layer_altitude
	_material_cache = {}
	var shapes = {}
	if typeof(cad_shapes) == TYPE_DICTIONARY:
		for sid in cad_shapes:
			var s = cad_shapes[sid]
			if typeof(s) == TYPE_DICTIONARY:
				shapes[str(s.get("id", sid))] = s
	elif typeof(cad_shapes) == TYPE_ARRAY:
		for s in cad_shapes:
			if typeof(s) == TYPE_DICTIONARY and s.has("id"):
				shapes[str(s["id"])] = s
	if shapes.is_empty():
		return 0

	var container = Node3D.new()
	container.name = "CADShapes_%s" % layer_id
	parent.add_child(container)

	# Every shape's solids, built once. Voids of one shape cut the others, so
	# all of them have to exist before any mesh is written.
	var built = {}
	for sid in shapes:
		built[sid] = build_shape_solids(shapes[sid])

	var solid_count = 0
	var skipped_flat = 0
	for sid in shapes:
		var shape = shapes[sid]
		if shape.get("visible", true) == false:
			continue
		var result = built[sid]
		var solids = result["solids"]
		var own_bounds = AABB()
		var has_bounds = false
		for solid in solids:
			if solid["subtract"]:
				continue
			var b = _tris_aabb(solid["tris"])
			own_bounds = b if not has_bounds else own_bounds.merge(b)
			has_bounds = true

		var tools = []
		if CAD_APPLY_VOIDS and has_bounds:
			for solid in solids:
				if solid["subtract"]:
					tools.append(solid["tris"])
			tools.append_array(_external_cutters(sid, shape, shapes, built, own_bounds))
			tools.append_array(_passing_voids(sid, shapes, built, own_bounds))

		var shape_node = Node3D.new()
		shape_node.name = "CADShape_%s" % sid
		container.add_child(shape_node)
		for solid in solids:
			if solid["subtract"]:
				# A void is a red ghost in the editor, never a surface.
				continue
			if _add_solid(shape_node, shape, solid, tools):
				solid_count += 1

		var flat = _flat_profiles(shape, result["hidden"])
		if CAD_RENDER_FLAT_FACES:
			for loop in flat:
				_add_flat_face(shape_node, loop)
		else:
			skipped_flat += flat.size()

	print("[CAD] layer %s: %d shape(s), %d solid(s) built, %d draft outline(s) left undrawn" % [
		layer_id, shapes.size(), solid_count, skipped_flat])
	return solid_count

# ==============================================================================
# SMALL VECTOR HELPERS
# ==============================================================================
func _num(v) -> float:
	if v == null:
		return 0.0
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return float(v)
	if typeof(v) == TYPE_STRING and str(v).is_valid_float():
		return float(v)
	return 0.0

# Editor world (metres, layer-local) -> Godot world.
func _xf_point(x: float, y: float, z: float) -> Vector3:
	var p = Vector3(x, y + _layer_altitude, z)
	if main_script != null and main_script.has_method("_transform_plan_point_meters"):
		var q = main_script._transform_plan_point_meters(p)
		return q
	return p

# A direction only turns with the plan; it never moves.
func _xf_dir(d: Vector3) -> Vector3:
	return _xf_point(d.x, d.y, d.z) - _xf_point(0.0, 0.0, 0.0)

func _vec_dict(d) -> Vector3:
	if typeof(d) != TYPE_DICTIONARY:
		return Vector3.ZERO
	return Vector3(_num(d.get("x", 0.0)), _num(d.get("y", 0.0)), _num(d.get("z", 0.0)))

func _point_of(d) -> Vector3:
	var v = _vec_dict(d)
	return _xf_point(v.x, v.y, v.z)

func _same_point(a: Vector3, b: Vector3) -> bool:
	return abs(a.x - b.x) <= CAD_TOLERANCE and abs(a.y - b.y) <= CAD_TOLERANCE and abs(a.z - b.z) <= CAD_TOLERANCE

func _centroid(points: Array) -> Vector3:
	var c = Vector3.ZERO
	for p in points:
		c += p
	if points.size() > 0:
		c /= float(points.size())
	return c

# Newell's method: the direction a ring is wound about (Loft.ringNormal).
func _ring_normal(ring: Array) -> Vector3:
	var n = Vector3.ZERO
	for i in range(ring.size()):
		var a = ring[i]
		var b = ring[(i + 1) % ring.size()]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	return n * 0.5

# The 2D basis every CAD builder flattens a plane with.
func _plane_u(n: Vector3) -> Vector3:
	var helper = Vector3(1, 0, 0) if abs(n.y) > 0.999 else Vector3(0, 1, 0)
	return helper.cross(n).normalized()

func _plane_v(n: Vector3, u: Vector3) -> Vector3:
	return n.cross(u).normalized()

# Plane through a loop: Newell normal through the centroid. Null when the
# points do not span a plane.
func _fit_plane(points: Array):
	if points.size() < 3:
		return null
	var n = _ring_normal(points)
	if n.length_squared() < 1e-18:
		return null
	n = n.normalized()
	var c = _centroid(points)
	return Plane(n, n.dot(c))

func _triangulate(pts2d: PackedVector2Array) -> PackedInt32Array:
	var tris = Geometry2D.triangulate_polygon(pts2d)
	if tris.size() == 0 and pts2d.size() >= 3:
		# Geometry2D refuses some nearly-degenerate outlines that earcut would
		# still fan; a convex fan is a fair stand-in for those.
		var reversed = PackedVector2Array(pts2d)
		reversed.reverse()
		var rt = Geometry2D.triangulate_polygon(reversed)
		if rt.size() > 0:
			var n = pts2d.size()
			var fixed = PackedInt32Array()
			for i in rt:
				fixed.append(n - 1 - i)
			return fixed
	return tris

func _tris_aabb(tris: PackedVector3Array) -> AABB:
	if tris.size() == 0:
		return AABB()
	var b = AABB(tris[0], Vector3.ZERO)
	for p in tris:
		b = b.expand(p)
	return b

# ==============================================================================
# PROFILES (model/profileGeometry.ts)
# ==============================================================================
func _is_profile_closed(profile: Dictionary) -> bool:
	if profile.has("closed") and typeof(profile["closed"]) == TYPE_BOOL:
		return bool(profile["closed"])
	var t = str(profile.get("type", ""))
	return not (t in ["line", "spline", "bezier", "arc"])

func _raw_points(profile) -> Array:
	var out = []
	if typeof(profile) != TYPE_DICTIONARY:
		return out
	var pts = profile.get("points", [])
	if typeof(pts) != TYPE_ARRAY:
		return out
	for p in pts:
		if typeof(p) == TYPE_DICTIONARY:
			out.append(_point_of(p))
	return out

func _normalize_points(raw: Array, closed: bool) -> Array:
	var out = []
	for p in raw:
		if out.size() > 0 and _same_point(p, out[out.size() - 1]):
			continue
		out.append(p)
	if closed and out.size() > 2 and _same_point(out[0], out[out.size() - 1]):
		out.pop_back()
	return out

# loopOf(): a profile's points in the form every operation expects, or null.
func _loop_of(profile):
	if typeof(profile) != TYPE_DICTIONARY:
		return null
	var raw = _raw_points(profile)
	if raw.size() == 0:
		return null
	var closed = _is_profile_closed(profile)
	var pts = _normalize_points(raw, closed)
	if pts.size() == 0:
		return null
	return {"points": pts, "closed": closed}

# ==============================================================================
# EXTRUSION (topology/Extrude.ts, SolidFaces.ts, SolidFaceGroups.ts)
# ==============================================================================
func _signed_loop_area(points: Array, normal: Vector3) -> float:
	if points.size() < 3:
		return 0.0
	var n = normal.normalized()
	var u = _plane_u(n)
	var v = _plane_v(n, u)
	var origin = points[0]
	var s = 0.0
	for i in range(points.size()):
		var a = points[i] - origin
		var b = points[(i + 1) % points.size()] - origin
		s += a.dot(u) * b.dot(v) - b.dot(u) * a.dot(v)
	return s / 2.0

func _side_outward(points: Array, edge_index: int, extrusion_normal: Vector3):
	if points.size() < 3 or edge_index < 0 or edge_index >= points.size():
		return null
	var a = points[edge_index]
	var b = points[(edge_index + 1) % points.size()]
	var edge = b - a
	if edge.length_squared() < 1e-12:
		return null
	var n = extrusion_normal.normalized()
	var perp = edge.cross(n)
	if perp.length_squared() < 1e-24:
		return null
	perp = perp.normalized()
	return perp if _signed_loop_area(points, n) > 0.0 else -perp

# Side walls that meet smoothly are ONE paintable face (union-find, wraps).
func _side_face_runs(points: Array, extrusion_normal: Vector3) -> Array:
	var n = points.size()
	if n < 3:
		return []
	var normals = []
	for i in range(n):
		normals.append(_side_outward(points, i, extrusion_normal))
	var cos_limit = cos(deg_to_rad(SMOOTH_ANGLE_DEG))
	var run_of = []
	for i in range(n):
		run_of.append(i)
	var find = func(i: int) -> int:
		var k = i
		while run_of[k] != k:
			run_of[k] = run_of[run_of[k]]
			k = run_of[k]
		return k
	for i in range(n):
		var nx = (i + 1) % n
		var na = normals[i]
		var nb = normals[nx]
		if na == null or nb == null:
			continue
		if na.dot(nb) >= cos_limit:
			var ra = find.call(i)
			var rb = find.call(nx)
			if ra != rb:
				run_of[max(ra, rb)] = min(ra, rb)
	var grouped = {}
	var roots = []
	for i in range(n):
		var r = find.call(i)
		if not grouped.has(r):
			grouped[r] = []
			roots.append(r)
		grouped[r].append(i)
	var runs = []
	for r in roots:
		var run = grouped[r]
		run.sort()
		runs.append(run)
	runs.sort_custom(func(a, b): return a[0] < b[0])
	return runs

func _merge_spans(ranges: Array) -> Array:
	ranges.sort_custom(func(a, b): return a[0] < b[0])
	var merged = []
	for r in ranges:
		if merged.size() > 0 and merged[merged.size() - 1][0] + merged[merged.size() - 1][1] == r[0]:
			merged[merged.size() - 1][1] += r[1]
		else:
			merged.append([r[0], r[1]])
	return merged

func _build_extruded(points: Array, normal: Vector3, depth: float):
	if points.size() < 3:
		return null
	var loop = points.duplicate()
	if loop.size() > 1 and loop[0].is_equal_approx(loop[loop.size() - 1]):
		loop.pop_back()
	if loop.size() < 3:
		return null
	var n = normal.normalized() if normal.length_squared() > 0.0 else Vector3(0, 1, 0)
	if n.length_squared() < 0.001:
		n = Vector3(0, 1, 0)
	var u = _plane_u(n)
	var v = _plane_v(n, u)
	var p0 = loop[0]
	var pts2d = PackedVector2Array()
	for p in loop:
		pts2d.append(Vector2((p - p0).dot(u), (p - p0).dot(v)))
	var tri_idx = _triangulate(pts2d)
	if tri_idx.size() == 0:
		return null
	var offset = n * depth
	var top = []
	for p in loop:
		top.append(p + offset)
	var tris = PackedVector3Array()
	# Bottom cap faces back along the extrusion, top cap forward.
	for t in range(0, tri_idx.size(), 3):
		var a = loop[tri_idx[t]]
		var b = loop[tri_idx[t + 1]]
		var c = loop[tri_idx[t + 2]]
		if (b - a).cross(c - a).dot(n) > 0.0:
			tris.append_array([a, c, b])
		else:
			tris.append_array([a, b, c])
	for t in range(0, tri_idx.size(), 3):
		var a2 = top[tri_idx[t]]
		var b2 = top[tri_idx[t + 1]]
		var c2 = top[tri_idx[t + 2]]
		if (b2 - a2).cross(c2 - a2).dot(n) < 0.0:
			tris.append_array([a2, c2, b2])
		else:
			tris.append_array([a2, b2, c2])
	var ccw = _signed_loop_area(loop, n) > 0.0
	var count = loop.size()
	for i in range(count):
		var nx = (i + 1) % count
		var b1 = loop[i]
		var b2 = loop[nx]
		var t1 = top[i]
		var t2 = top[nx]
		if ccw:
			tris.append_array([b1, b2, t2, b1, t2, t1])
		else:
			tris.append_array([b2, b1, t1, b2, t1, t2])
	var cap_count = tri_idx.size() / 3
	return {"tris": tris, "closed": true, "layout": {"kind": "prism", "caps": cap_count, "loop": count}}

# Paintable faces of a prism: both caps and each run of side walls.
func _extrusion_faces(layout: Dictionary, base_points: Array, direction: Vector3) -> Array:
	var caps = int(layout["caps"])
	var n = int(layout["loop"])
	var faces = [
		{"id": "cap:bottom", "spans": [[0, caps]]},
		{"id": "cap:top", "spans": [[caps, caps]]}
	]
	for run in _side_face_runs(base_points, direction):
		var ranges = []
		for edge in run:
			if edge >= 0 and edge < n:
				ranges.append([2 * caps + 2 * edge, 2])
		faces.append({"id": "side:%d" % run[0], "spans": _merge_spans(ranges)})
	return faces

# ==============================================================================
# LOFT CORE (topology/Loft.ts)
# ==============================================================================
# rings: Array of Array[Vector3]; section / end_section: Array of Vector2.
func _loft_rings(rings: Array, section_in: Array, end_section_in, profile_closed: bool, rings_closed: bool):
	if rings.size() < 2:
		return null
	var section = section_in
	var end_section = end_section_in
	var m = section.size()
	if m < (3 if profile_closed else 2):
		return null
	for ring in rings:
		if ring.size() != m:
			return null
	if end_section != null and end_section.size() != m:
		return null

	var ordered = rings
	if profile_closed:
		var run = _centroid(rings[1]) - _centroid(rings[0])
		var facing = _ring_normal(rings[0]).dot(run)
		if run.length_squared() > 1e-18 and facing < 0.0:
			section = section.duplicate()
			section.reverse()
			if end_section != null:
				end_section = end_section.duplicate()
				end_section.reverse()
			ordered = []
			for ring in rings:
				var r = ring.duplicate()
				r.reverse()
				ordered.append(r)

	var segment_count = ordered.size() if rings_closed else ordered.size() - 1
	var edge_count = m if profile_closed else m - 1
	if segment_count < 1 or edge_count < 1:
		return null

	var tris = PackedVector3Array()
	for e in range(edge_count):
		var e2 = (e + 1) % m
		for s in range(segment_count):
			var ring_a = ordered[s]
			var ring_b = ordered[(s + 1) % ordered.size()]
			var a1 = ring_a[e]
			var a2 = ring_a[e2]
			var b1 = ring_b[e]
			var b2 = ring_b[e2]
			tris.append_array([a1, a2, b2, a1, b2, b1])

	var cap_count = 0
	var end_cap_count = 0
	var closed_solid = rings_closed and profile_closed
	if profile_closed and not rings_closed:
		var start_tris = _triangulate(_to_packed2(section))
		var end_tris = _triangulate(_to_packed2(end_section)) if end_section != null else start_tris
		if start_tris.size() > 0 and end_tris.size() > 0:
			var start = ordered[0]
			var last = ordered[ordered.size() - 1]
			var run_start = _centroid(ordered[1]) - _centroid(start)
			var run_end = _centroid(last) - _centroid(ordered[ordered.size() - 2])
			for t in range(0, start_tris.size(), 3):
				var p0 = start[start_tris[t]]
				var p1 = start[start_tris[t + 1]]
				var p2 = start[start_tris[t + 2]]
				# Start cap faces back along the run.
				if (p1 - p0).cross(p2 - p0).dot(run_start) > 0.0:
					tris.append_array([p0, p2, p1])
				else:
					tris.append_array([p0, p1, p2])
			for t in range(0, end_tris.size(), 3):
				var q0 = last[end_tris[t]]
				var q1 = last[end_tris[t + 1]]
				var q2 = last[end_tris[t + 2]]
				if (q1 - q0).cross(q2 - q0).dot(run_end) < 0.0:
					tris.append_array([q0, q2, q1])
				else:
					tris.append_array([q0, q1, q2])
			cap_count = start_tris.size() / 3
			end_cap_count = end_tris.size() / 3
			closed_solid = true

	if tris.size() == 0:
		return null
	var layout = {
		"kind": "loft",
		"edges": edge_count,
		"segments": segment_count,
		"caps": cap_count,
		"end_caps": end_cap_count,
		"section": section,
		"closed": profile_closed
	}
	return {"tris": tris, "closed": closed_solid, "layout": layout}

func _to_packed2(arr) -> PackedVector2Array:
	var out = PackedVector2Array()
	if arr == null:
		return out
	for p in arr:
		out.append(p)
	return out

# Runs of cross-section edges that read as one surface (loftProfileRuns).
func _loft_profile_runs(layout: Dictionary) -> Array:
	var section = layout["section"]
	var n = section.size()
	var edge_count = int(layout["edges"])
	if edge_count < 1:
		return []
	var normal_of = func(i: int):
		var a = section[i]
		var b = section[(i + 1) % n]
		var edge = b - a
		if edge.length_squared() < 1e-12:
			return null
		return Vector2(edge.y, -edge.x).normalized()
	var cos_limit = cos(deg_to_rad(SMOOTH_ANGLE_DEG))
	var runs = []
	var current = []
	for i in range(edge_count):
		if current.size() == 0:
			current.append(i)
			continue
		var prev = normal_of.call(current[current.size() - 1])
		var here = normal_of.call(i)
		if prev != null and here != null and prev.dot(here) >= cos_limit:
			current.append(i)
		else:
			runs.append(current)
			current = [i]
	if current.size() > 0:
		runs.append(current)
	if bool(layout["closed"]) and runs.size() > 1:
		var first = normal_of.call(runs[0][0])
		var last_run = runs[runs.size() - 1]
		var last = normal_of.call(last_run[last_run.size() - 1])
		if first != null and last != null and first.dot(last) >= cos_limit:
			var tail = runs.pop_back()
			tail.append_array(runs[0])
			runs[0] = tail
	return runs

func _loft_faces(layout: Dictionary) -> Array:
	var per_edge = int(layout["segments"]) * 2
	var faces = []
	for run in _loft_profile_runs(layout):
		var spans = []
		for edge in run:
			var start = edge * per_edge
			if spans.size() > 0 and spans[spans.size() - 1][0] + spans[spans.size() - 1][1] == start:
				spans[spans.size() - 1][1] += per_edge
			else:
				spans.append([start, per_edge])
		faces.append({"id": "sweep:%d" % run[0], "spans": spans})
	var caps = int(layout["caps"])
	if caps > 0:
		var caps_begin = int(layout["edges"]) * per_edge
		faces.append({"id": "cap:start", "spans": [[caps_begin, caps]]})
		faces.append({"id": "cap:end", "spans": [[caps_begin + caps, int(layout["end_caps"])]]})
	return faces

# ==============================================================================
# REVOLVE (topology/Revolve.ts)
# ==============================================================================
func _build_revolve(profile: Array, profile_closed: bool, axis_origin: Vector3, axis_direction: Vector3, angle_rad: float, segments: int):
	if profile.size() < (3 if profile_closed else 2):
		return null
	if is_nan(angle_rad) or is_inf(angle_rad) or abs(angle_rad) < 1e-6:
		return null
	if axis_direction.length_squared() < 1e-12:
		return null
	var dir = axis_direction.normalized()
	# Radial direction from the point furthest off the axis.
	var u = null
	var best = 0.0
	for p in profile:
		var off = p - axis_origin
		var radial = off - dir * off.dot(dir)
		var d = radial.length_squared()
		if d > best:
			best = d
			u = radial
	if u == null or best < 1e-12:
		return null
	u = u.normalized()
	var facets = clampi(int(round(segments)), 3, 256)
	var full = abs(angle_rad) >= PI * 2.0 - 1e-6
	var ring_count = facets if full else facets + 1
	var step = ((sign(angle_rad) * PI * 2.0) if full else angle_rad) / float(facets)
	var rings = []
	for k in range(ring_count):
		var q = Quaternion(dir, step * k)
		var ring = []
		for p in profile:
			ring.append(q * (p - axis_origin) + axis_origin)
		rings.append(ring)
	var section = []
	for p in profile:
		var off2 = p - axis_origin
		section.append(Vector2(off2.dot(u), off2.dot(dir)))
	return _loft_rings(rings, section, null, profile_closed, full)

# ==============================================================================
# FOLLOW ME / SWEEP (topology/FollowMe.ts)
# ==============================================================================
func _path_tangents(path: Array, closed: bool) -> Array:
	var n = path.size()
	var out = []
	for i in range(n):
		var prev_i = (i - 1 + n) % n if closed else max(0, i - 1)
		var next_i = (i + 1) % n if closed else min(n - 1, i + 1)
		var t = path[next_i] - path[prev_i]
		if t.length_squared() < EPS:
			var fwd = path[next_i] - path[i]
			var back = path[i] - path[prev_i]
			var fb = fwd if fwd.length_squared() > back.length_squared() else back
			out.append(fb.normalized() if fb.length_squared() > EPS else Vector3(0, 0, 1))
		else:
			out.append(t.normalized())
	return out

func _seed_perpendicular(tangent: Vector3) -> Vector3:
	var helper = Vector3(1, 0, 0) if abs(tangent.y) > 0.9 else Vector3(0, 1, 0)
	var x = helper - tangent * helper.dot(tangent)
	if x.length_squared() > EPS:
		return x.normalized()
	return (Vector3(1, 0, 0) - tangent * tangent.x).normalized()

func _transport_frame(prev_origin: Vector3, prev_tangent: Vector3, prev_x: Vector3, next_origin: Vector3, next_tangent: Vector3) -> Vector3:
	var r = next_origin - prev_origin
	var c1 = r.dot(r)
	if c1 < EPS:
		return prev_x
	var reflected_x = prev_x + r * ((-2.0 / c1) * r.dot(prev_x))
	var reflected_t = prev_tangent + r * ((-2.0 / c1) * r.dot(prev_tangent))
	var v2 = next_tangent - reflected_t
	var c2 = v2.dot(v2)
	var x = reflected_x if c2 < EPS else reflected_x + v2 * ((-2.0 / c2) * v2.dot(reflected_x))
	var projected = x - next_tangent * x.dot(next_tangent)
	return projected.normalized() if projected.length_squared() > EPS else _seed_perpendicular(next_tangent)

func _rmf_frames(path: Array, closed: bool) -> Array:
	var n = path.size()
	if n < 2:
		return []
	var tangents = _path_tangents(path, closed)
	var x0 = _seed_perpendicular(tangents[0])
	var frames = [{"origin": path[0], "tangent": tangents[0], "x": x0, "y": tangents[0].cross(x0).normalized()}]
	for i in range(1, n):
		var prev = frames[i - 1]
		var x_axis = _transport_frame(prev["origin"], prev["tangent"], prev["x"], path[i], tangents[i])
		frames.append({"origin": path[i], "tangent": tangents[i], "x": x_axis, "y": tangents[i].cross(x_axis).normalized()})
	if closed and n >= 3:
		var last = frames[n - 1]
		var closing_x = _transport_frame(last["origin"], last["tangent"], last["x"], frames[0]["origin"], frames[0]["tangent"])
		var cr = frames[0]["x"].cross(closing_x)
		var twist = atan2(cr.dot(frames[0]["tangent"]), frames[0]["x"].dot(closing_x))
		for i in range(1, n):
			var q = Quaternion(frames[i]["tangent"].normalized(), -twist * (float(i) / float(n)))
			frames[i]["x"] = q * frames[i]["x"]
			frames[i]["y"] = q * frames[i]["y"]
	return frames

func _orient_path(path: Array, path_closed: bool, profile: Array) -> Array:
	if path.size() < 2 or profile.size() == 0:
		return path
	var anchor = _centroid(profile)
	if not path_closed:
		if anchor.distance_squared_to(path[path.size() - 1]) < anchor.distance_squared_to(path[0]):
			var r = path.duplicate()
			r.reverse()
			return r
		return path
	var nearest = 0
	var best = INF
	for i in range(path.size()):
		var d = anchor.distance_squared_to(path[i])
		if d < best:
			best = d
			nearest = i
	if nearest == 0:
		return path
	return path.slice(nearest) + path.slice(0, nearest)

func _project_to_frame(profile: Array, frame: Dictionary) -> Array:
	var out = []
	for p in profile:
		var rel = p - frame["origin"]
		out.append(Vector2(rel.dot(frame["x"]), rel.dot(frame["y"])))
	return out

func _ring_at(local: Array, frame: Dictionary) -> Array:
	var out = []
	for uv in local:
		out.append(frame["origin"] + frame["x"] * uv.x + frame["y"] * uv.y)
	return out

func _mitered_rings(profile: Array, path: Array, path_closed: bool):
	var n = path.size()
	var edge_count = n if path_closed else n - 1
	var dirs = []
	for k in range(edge_count):
		var d = path[(k + 1) % n] - path[k]
		if d.length_squared() < EPS:
			return null
		dirs.append(d.normalized())
	if path_closed:
		var path_normal = _ring_normal(path)
		if path_normal.length_squared() < EPS:
			return null
		path_normal = path_normal.normalized()
		for p in path:
			if abs((p - path[0]).dot(path_normal)) > 0.0001:
				return null
	var direction = dirs[0]
	var profile_normal = _ring_normal(profile)
	if path_closed and profile_normal.length_squared() > EPS:
		profile_normal = profile_normal.normalized()
		var incoming0 = dirs[edge_count - 1]
		if abs(profile_normal.dot(incoming0)) > abs(profile_normal.dot(direction)):
			direction = incoming0
	var x_axis = _seed_perpendicular(direction)
	var y_axis = direction.cross(x_axis).normalized()
	var section = []
	for p in profile:
		var rel = p - path[0]
		section.append(Vector2(rel.dot(x_axis), rel.dot(y_axis)))
	var points = profile.duplicate()
	var rings = []
	for i in range(n):
		var incoming = dirs[(i - 1 + edge_count) % edge_count] if (path_closed or i > 0) else null
		var outgoing = dirs[i] if (path_closed or i < n - 1) else null
		var cut = Vector3.ZERO
		if incoming != null and outgoing != null:
			cut = incoming + outgoing
		elif incoming != null:
			cut = incoming
		else:
			cut = outgoing
		if cut.length_squared() < EPS:
			cut = incoming
		cut = cut.normalized()
		var along = cut.dot(direction)
		if abs(along) < 1e-6:
			cut = direction
			along = 1.0
		var origin = path[i]
		var moved = []
		for p in points:
			moved.append(p + direction * (cut.dot(origin - p) / along))
		points = moved
		rings.append(points)
		if outgoing != null:
			direction = outgoing
	return {"rings": rings, "section": section}

func _build_follow_me(profile: Array, profile_closed: bool, path: Array, path_closed: bool):
	if profile.size() < (3 if profile_closed else 2):
		return null
	if path.size() < (3 if path_closed else 2):
		return null
	var oriented = _orient_path(path, path_closed, profile)
	var mitered = _mitered_rings(profile, oriented, path_closed)
	if mitered != null:
		return _loft_rings(mitered["rings"], mitered["section"], null, profile_closed, path_closed)
	var frames = _rmf_frames(oriented, path_closed)
	if frames.size() < 2:
		return null
	var section = _project_to_frame(profile, frames[0])
	var rings = []
	for f in frames:
		rings.append(_ring_at(section, f))
	return _loft_rings(rings, section, null, profile_closed, path_closed)

# ==============================================================================
# SECTION CORRESPONDENCE (topology/ProfileResample.ts)
# ==============================================================================
func _resample_loop(points: Array, closed: bool, target: int):
	var n = points.size()
	if n < 2:
		return null
	var seg_count = n if closed else n - 1
	if seg_count < 1:
		return null
	var extra = target - n
	if extra <= 0:
		return points.duplicate()
	var lengths = []
	var total = 0.0
	for i in range(seg_count):
		var d = points[i].distance_to(points[(i + 1) % n])
		lengths.append(d)
		total += d
	if total <= 0.0:
		return points.duplicate()
	var exact = []
	var counts = []
	var assigned = 0
	for l in lengths:
		var e = (l / total) * extra
		exact.append(e)
		counts.append(int(floor(e)))
		assigned += int(floor(e))
	# Largest remainder; ties keep edge order (JS sort is stable).
	var order = []
	for i in range(exact.size()):
		order.append([exact[i] - floor(exact[i]), i])
	order.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var k = 0
	while assigned < extra:
		counts[order[k % order.size()][1]] += 1
		assigned += 1
		k += 1
	var out = []
	for i in range(seg_count):
		var a = points[i]
		var b = points[(i + 1) % n]
		out.append(a)
		for j in range(1, counts[i] + 1):
			out.append(a.lerp(b, float(j) / float(counts[i] + 1)))
	if not closed:
		out.append(points[n - 1])
	return out

func _best_start_shift(reference: Array, loop: Array) -> int:
	var n = loop.size()
	if n == 0 or reference.size() != n:
		return 0
	var best_shift = 0
	var best_cost = INF
	for shift in range(n):
		var cost = 0.0
		for i in range(n):
			cost += reference[i].distance_squared_to(loop[(i + shift) % n])
			if cost >= best_cost:
				break
		if cost < best_cost:
			best_cost = cost
			best_shift = shift
	return best_shift

func _rotate_array(arr: Array, shift: int) -> Array:
	if shift == 0:
		return arr
	return arr.slice(shift) + arr.slice(0, shift)

func _correspond_sections(sections: Array, closed: bool):
	if sections.size() < 2:
		return null
	var target = 0
	for s in sections:
		if s.size() < (3 if closed else 2):
			return null
		target = max(target, s.size())
	var resampled = []
	for s in sections:
		var loop = _resample_loop(s, closed, target)
		if loop == null or loop.size() != target:
			return null
		resampled.append(loop)
	if not closed:
		return resampled
	var run = _centroid(resampled[resampled.size() - 1]) - _centroid(resampled[0])
	var reference = sign(_ring_normal(resampled[0]).dot(run))
	var out = [resampled[0]]
	for i in range(1, resampled.size()):
		var loop2 = resampled[i]
		if reference != 0 and sign(_ring_normal(loop2).dot(run)) == -reference:
			loop2 = loop2.duplicate()
			loop2.reverse()
		if loop2.size() >= 3 and out[i - 1].size() == loop2.size():
			loop2 = _rotate_array(loop2, _best_start_shift(out[i - 1], loop2))
		out.append(loop2)
	return out

# ==============================================================================
# BLEND / SWEPT BLEND (topology/Blend.ts)
# ==============================================================================
func _section_outline(loop: Array, fallback_normal: Vector3) -> Array:
	var plane = _fit_plane(loop)
	var normal = fallback_normal
	if plane != null:
		normal = plane.normal
		if normal.dot(fallback_normal) < 0.0:
			normal = -normal
	var n = normal.normalized()
	var u = _plane_u(n)
	var v = _plane_v(n, u)
	var origin = _centroid(loop)
	var out = []
	for p in loop:
		var off = p - origin
		out.append(Vector2(off.dot(u), off.dot(v)))
	return out

func _signed_area_uv(outline: Array) -> float:
	var s = 0.0
	for i in range(outline.size()):
		var a = outline[i]
		var b = outline[(i + 1) % outline.size()]
		s += a.x * b.y - b.x * a.y
	return s / 2.0

func _catmull(x0: float, x1: float, x2: float, x3: float, t: float) -> float:
	var t0 = 0.5 * (x2 - x0)
	var t1 = 0.5 * (x3 - x1)
	var c2 = -3.0 * x1 + 3.0 * x2 - 2.0 * t0 - t1
	var c3 = 2.0 * x1 - 2.0 * x2 + t0 + t1
	return x1 + t0 * t + c2 * t * t + c3 * t * t * t

# three.js CatmullRomCurve3(points, false, 'catmullrom', 0.5).getPoint(t)
func _catmull_point(points: Array, t: float) -> Vector3:
	var l = points.size()
	var p = (l - 1) * t
	var int_point = int(floor(p))
	var weight = p - int_point
	if weight == 0.0 and int_point == l - 1:
		int_point = l - 2
		weight = 1.0
	var p0 = points[int_point - 1] if int_point > 0 else (points[0] - points[1]) + points[0]
	var p1 = points[int_point % l]
	var p2 = points[(int_point + 1) % l]
	var p3 = points[int_point + 2] if int_point + 2 < l else (points[l - 1] - points[l - 2]) + points[l - 1]
	return Vector3(
		_catmull(p0.x, p1.x, p2.x, p3.x, weight),
		_catmull(p0.y, p1.y, p2.y, p3.y, weight),
		_catmull(p0.z, p1.z, p2.z, p3.z, weight))

func _smooth_rings(rings: Array, steps: int) -> Array:
	var vertex_count = rings[0].size()
	var stations = (rings.size() - 1) * steps
	var curves = []
	for i in range(vertex_count):
		var pts = []
		for ring in rings:
			pts.append(ring[i])
		curves.append(pts)
	var out = []
	for s in range(stations + 1):
		var t = float(s) / float(stations)
		var ring2 = []
		for c in curves:
			ring2.append(_catmull_point(c, t))
		out.append(ring2)
	return out

func _sections_stacked(sections: Array) -> bool:
	for i in range(sections.size() - 1):
		var normal = _ring_normal(sections[i])
		if normal.length_squared() < 1e-18:
			return false
		var step = _centroid(sections[i + 1]) - _centroid(sections[i])
		if abs(step.dot(normal.normalized())) < 0.0001:
			return false
	return true

func _build_blend(sections: Array, profile_closed: bool, smooth_steps: int):
	if sections.size() < 2:
		return null
	if profile_closed and not _sections_stacked(sections):
		return null
	var corresponded = _correspond_sections(sections, profile_closed)
	if corresponded == null:
		return null
	var run = _centroid(corresponded[corresponded.size() - 1]) - _centroid(corresponded[0])
	var fallback = run.normalized() if run.length_squared() > 1e-12 else Vector3(0, 1, 0)
	var rings = corresponded
	if smooth_steps > 1 and corresponded.size() >= 3:
		rings = _smooth_rings(corresponded, min(32, int(round(smooth_steps))))
	return _loft_rings(rings,
		_section_outline(corresponded[0], fallback),
		_section_outline(corresponded[corresponded.size() - 1], fallback),
		profile_closed, false)

func _build_swept_blend(start_profile: Array, end_profile: Array, profile_closed: bool, path: Array):
	if path.size() < 2:
		return null
	var corresponded = _correspond_sections([start_profile, end_profile], profile_closed)
	if corresponded == null:
		return null
	var start_section = corresponded[0]
	var end_section = corresponded[1]
	var oriented = _orient_path(path, false, start_section)
	var frames = _rmf_frames(oriented, false)
	if frames.size() < 2:
		return null
	var start_local = _project_to_frame(start_section, frames[0])
	var end_local = _project_to_frame(end_section, frames[frames.size() - 1])
	if profile_closed and start_local.size() > 2:
		if _signed_area_uv(start_local) * _signed_area_uv(end_local) < 0.0:
			end_local = end_local.duplicate()
			end_local.reverse()
		var flat_a = []
		var flat_b = []
		for p in start_local:
			flat_a.append(Vector3(p.x, p.y, 0))
		for p in end_local:
			flat_b.append(Vector3(p.x, p.y, 0))
		end_local = _rotate_array(end_local, _best_start_shift(flat_a, flat_b))
	var last = frames.size() - 1
	var rings = []
	for k in range(frames.size()):
		var t = 0.0 if last == 0 else float(k) / float(last)
		var morphed = []
		for i in range(start_local.size()):
			morphed.append(start_local[i].lerp(end_local[i], t))
		rings.append(_ring_at(morphed, frames[k]))
	return _loft_rings(rings, start_local, end_local, profile_closed, false)

# ==============================================================================
# WHAT A SHAPE IS MADE OF (model/ShapeSolids.ts)
# ==============================================================================
func _enabled_operations(shape: Dictionary) -> Array:
	var out = []
	var ops = shape.get("operations", [])
	if typeof(ops) != TYPE_ARRAY:
		return out
	for op in ops:
		if typeof(op) == TYPE_DICTIONARY and op.get("enabled", true) != false:
			out.append(op)
	return out

func _op_params(op: Dictionary) -> Dictionary:
	var p = op.get("parameters", {})
	return p if typeof(p) == TYPE_DICTIONARY else {}

func _referenced_profile(profiles: Dictionary, reference):
	if typeof(reference) != TYPE_DICTIONARY or str(reference.get("type", "")) != "profile":
		return null
	return profiles.get(str(reference.get("id", "")), null)

func _profile_ids(op: Dictionary) -> Array:
	var ids = op.get("profileIds", [])
	var out = []
	if typeof(ids) == TYPE_ARRAY:
		for i in ids:
			out.append(str(i))
	return out

func _add_built(solids: Array, profile_id: String, geo, faces: Array, subtract: bool) -> void:
	solids.append({
		"profile_id": profile_id,
		"tris": geo["tris"],
		"closed": bool(geo["closed"]),
		"faces": faces,
		"subtract": subtract
	})

# Returns {"solids": [...], "hidden": {profile_id: true}}.
func build_shape_solids(shape: Dictionary) -> Dictionary:
	var solids = []
	var hidden = {}
	var profiles = shape.get("profiles", {})
	if typeof(profiles) != TYPE_DICTIONARY:
		profiles = {}
	var operations = _enabled_operations(shape)

	# Forms built from several profiles go first, so their sections are taken
	# before the per-profile pass could build them again on their own.
	for op in operations:
		var op_type = str(op.get("type", ""))
		if op_type == "blend":
			var ids = _profile_ids(op)
			var sections = []
			var ok = ids.size() >= 2
			for blend_pid in ids:
				var lp = _loop_of(profiles.get(blend_pid, null))
				if lp == null:
					ok = false
					break
				sections.append(lp)
			if not ok:
				continue
			var closed = bool(sections[0]["closed"])
			var mixed = false
			for s in sections:
				if bool(s["closed"]) != closed:
					mixed = true
			if mixed:
				continue
			var pts_list = []
			for s in sections:
				pts_list.append(s["points"])
			var params = _op_params(op)
			var steps = 1
			if bool(params.get("smooth", false)):
				steps = int(_num(params.get("steps", 8))) if params.get("steps", null) != null else 8
			var geo = _build_blend(pts_list, closed, steps)
			if geo == null:
				continue
			for blend_pid2 in ids:
				hidden[blend_pid2] = true
			_add_built(solids, ids[0], geo, _loft_faces(geo["layout"]), str(op.get("mode", "add")) == "subtract")
		elif op_type == "sweepBlend":
			var params_sb = _op_params(op)
			var start_id = str(params_sb.get("startProfileId", ""))
			var end_id = str(params_sb.get("endProfileId", ""))
			var start = _loop_of(profiles.get(start_id, null))
			var end = _loop_of(profiles.get(end_id, null))
			var path = _loop_of(_referenced_profile(profiles, params_sb.get("path", null)))
			if start == null or end == null or path == null or bool(start["closed"]) != bool(end["closed"]):
				continue
			var path_ref = params_sb.get("path", {})
			if typeof(path_ref) == TYPE_DICTIONARY and str(path_ref.get("type", "")) == "profile":
				hidden[str(path_ref.get("id", ""))] = true
			var geo_sb = _build_swept_blend(start["points"], end["points"], bool(start["closed"]), path["points"])
			if geo_sb == null:
				continue
			hidden[start_id] = true
			hidden[end_id] = true
			_add_built(solids, start_id, geo_sb, _loft_faces(geo_sb["layout"]), str(op.get("mode", "add")) == "subtract")

	# A sweep's path is data, hidden whether or not the sweep builds.
	for op in operations:
		if str(op.get("type", "")) != "sweep":
			continue
		var pr = _op_params(op).get("path", null)
		if typeof(pr) == TYPE_DICTIONARY and str(pr.get("type", "")) == "profile":
			hidden[str(pr.get("id", ""))] = true

	for profile_id in profiles:
		var pid = str(profile_id)
		if hidden.has(pid):
			continue
		var source = _loop_of(profiles[profile_id])
		if source == null:
			continue
		var sweep = _first_op(operations, "sweep", pid)
		if sweep != null:
			var sweep_path = _loop_of(_referenced_profile(profiles, _op_params(sweep).get("path", null)))
			if sweep_path != null:
				var geo_s = _build_follow_me(source["points"], bool(source["closed"]), sweep_path["points"], bool(sweep_path["closed"]))
				if geo_s != null:
					hidden[pid] = true
					_add_built(solids, pid, geo_s, _loft_faces(geo_s["layout"]), str(sweep.get("mode", "add")) == "subtract")
					continue

		var revolve = _first_op(operations, "revolve", pid)
		if revolve != null:
			var rp = _op_params(revolve)
			if rp.has("axisOrigin") and rp.has("axisDirection") and rp["axisOrigin"] != null and rp["axisDirection"] != null:
				var origin = _point_of(rp["axisOrigin"])
				var direction = _xf_dir(_vec_dict(rp["axisDirection"]))
				var segs = int(_num(rp.get("segments", 32))) if rp.get("segments", null) != null else 32
				var geo_r = _build_revolve(source["points"], bool(source["closed"]), origin, direction, deg_to_rad(_num(rp.get("angle", 0.0))), segs)
				if geo_r != null:
					hidden[pid] = true
					_add_built(solids, pid, geo_r, _loft_faces(geo_r["layout"]), str(revolve.get("mode", "add")) == "subtract")
					continue

		var extrusion = _first_op(operations, "extrusion", pid)
		if extrusion != null and bool(source["closed"]):
			var ep = _op_params(extrusion)
			var depth = _num(ep.get("depth", 0.0)) / 1000.0
			var dir_param = ep.get("direction", null)
			var dir_e = Vector3(0, 1, 0)
			if typeof(dir_param) == TYPE_DICTIONARY:
				dir_e = _xf_dir(_vec_dict(dir_param))
			var offset = _num(ep.get("offset", 0.0)) / 1000.0
			var points = _raw_points(profiles[profile_id])
			var base_points = points
			if offset != 0.0 and dir_e.length_squared() >= 0.001:
				base_points = []
				var nd = dir_e.normalized()
				for p in points:
					base_points.append(p + nd * offset)
			if depth > 0.00001 and not is_inf(depth):
				var geo_e = _build_extruded(base_points, dir_e, depth)
				if geo_e != null:
					hidden[pid] = true
					_add_built(solids, pid, geo_e, _extrusion_faces(geo_e["layout"], base_points, dir_e), str(extrusion.get("mode", "add")) == "subtract")
	return {"solids": solids, "hidden": hidden}

func _first_op(operations: Array, op_type: String, profile_id: String):
	for op in operations:
		if str(op.get("type", "")) == op_type and profile_id in _profile_ids(op):
			return op
	return null

# ==============================================================================
# VOIDS AND CUTTERS (CADShapeManager.externalCutters / overlappingVoids,
# model/ProfileCutters.ts)
# ==============================================================================
func _has_void(shape: Dictionary) -> bool:
	for op in _enabled_operations(shape):
		if str(op.get("mode", "")) == "subtract":
			return true
	return false

# Closed outlines no solid absorbed - the ones a flat cut can use.
func _flat_profiles(shape: Dictionary, hidden: Dictionary) -> Array:
	var loops = []
	var profiles = shape.get("profiles", {})
	if typeof(profiles) != TYPE_DICTIONARY:
		return loops
	for profile_id in profiles:
		var profile = profiles[profile_id]
		if hidden.has(str(profile_id)) or typeof(profile) != TYPE_DICTIONARY or not _is_profile_closed(profile):
			continue
		var pts = _normalize_points(_raw_points(profile), true)
		if pts.size() >= 3:
			loops.append(pts)
	return loops

# A flat outline swept straight through everything `reach` covers.
func _through_cut(loop: Array, reach: AABB):
	if loop.size() < 3:
		return null
	var plane = _fit_plane(loop)
	if plane == null:
		return null
	var normal = plane.normal.normalized()
	var centre = reach.get_center()
	var off_plane = abs(plane.distance_to(centre))
	var length = off_plane + reach.size.length() + 0.5
	var base = []
	for p in loop:
		base.append(p - normal * length)
	var geo = _build_extruded(base, normal, length * 2.0)
	return geo["tris"] if geo != null else null

func _external_cutters(shape_id: String, shape: Dictionary, shapes: Dictionary, built: Dictionary, reach: AABB) -> Array:
	var cutters = []
	for op in _enabled_operations(shape):
		if str(op.get("type", "")) != "boolean":
			continue
		var params = _op_params(op)
		if str(params.get("operation", "")) != "subtract" or str(params.get("targetId", "")) != shape_id:
			continue
		var tool_id = str(params.get("toolId", ""))
		if not shapes.has(tool_id):
			continue
		var tool = shapes[tool_id]
		var tool_built = built[tool_id]
		if bool(params.get("outlineOnly", false)):
			for loop in _flat_profiles(tool, {}):
				var cut = _through_cut(loop, reach)
				if cut != null:
					cutters.append(cut)
			continue
		# The tool's own solids. (The editor first cuts the tool's own voids
		# out of it; a tool with voids of its own cuts here with its full shape.)
		for solid in tool_built["solids"]:
			if not solid["subtract"]:
				cutters.append(solid["tris"])
		for loop in _flat_profiles(tool, tool_built["hidden"]):
			var cut2 = _through_cut(loop, reach)
			if cut2 != null:
				cutters.append(cut2)
	return cutters

func _passing_voids(shape_id: String, shapes: Dictionary, built: Dictionary, bounds: AABB) -> Array:
	var out = []
	for other_id in shapes:
		if other_id == shape_id or not _has_void(shapes[other_id]):
			continue
		for solid in built[other_id]["solids"]:
			if solid["subtract"] and _tris_aabb(solid["tris"]).intersects(bounds):
				out.append(solid["tris"])
	return out

# Every edge used exactly twice: the condition Godot's CSG needs to tell the
# inside of a solid from the outside.
func _is_watertight(tris: PackedVector3Array) -> bool:
	if tris.size() < 12:
		return false
	var key_of = func(p: Vector3) -> String:
		return "%d,%d,%d" % [int(round(p.x * 100000.0)), int(round(p.y * 100000.0)), int(round(p.z * 100000.0))]
	var edges = {}
	for t in range(0, tris.size(), 3):
		for e in range(3):
			var ka = key_of.call(tris[t + e])
			var kb = key_of.call(tris[t + (e + 1) % 3])
			if ka == kb:
				continue
			var k = ka + "|" + kb if ka < kb else kb + "|" + ka
			edges[k] = int(edges.get(k, 0)) + 1
	for k in edges:
		if edges[k] != 2:
			return false
	return true

# ==============================================================================
# MATERIALS (CADShapeManager.defaultSolidMaterial / buildFaceMaterial)
# ==============================================================================
func _repeats_per_metre(tile_mm) -> float:
	var v = _num(tile_mm)
	if v <= 1.0:
		return 1.0
	return 1000.0 / v

func _default_material() -> Material:
	if not _material_cache.has("__default__"):
		var mat_data = {"color": CAD_DEFAULT_COLOR, "roughness": CAD_DEFAULT_ROUGHNESS, "metallic": CAD_DEFAULT_METALNESS}
		var mat = main_script.create_material(mat_data)
		_finish_material(mat, 1.0)
		_material_cache["__default__"] = mat
	return _material_cache["__default__"]

func _finish_material(mat, opacity: float) -> void:
	if mat is BaseMaterial3D:
		var bm: BaseMaterial3D = mat
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		bm.uv1_triplanar = false
		if opacity < 0.999:
			bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var c = bm.albedo_color
			bm.albedo_color = Color(c.r, c.g, c.b, clamp(opacity, 0.0, 1.0))

# A painted face's material. A texture and a colour are alternatives in the
# editor: an image shows exactly as it is, a colour alone paints the face.
func _face_material(entry) -> Material:
	if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("material", null)) != TYPE_DICTIONARY:
		return null
	var key = JSON.stringify(entry)
	if _material_cache.has(key):
		return _material_cache[key]
	var spec = entry["material"]
	var uv = entry.get("uv", {})
	if typeof(uv) != TYPE_DICTIONARY:
		uv = {}
	var mat_data = {
		"roughness": _num(spec["roughness"]) if spec.get("roughness", null) != null else 0.6,
		"metallic": _num(spec["metalness"]) if spec.get("metalness", null) != null else 0.0,
		"repeat": [_repeats_per_metre(uv.get("repeatX", null)), _repeats_per_metre(uv.get("repeatY", null))]
	}
	var map_url = str(spec.get("mapUrl", "")) if spec.get("mapUrl", null) != null else ""
	if map_url != "":
		mat_data["mapUrl"] = map_url
	else:
		mat_data["color"] = str(spec.get("color", "#ffffff")) if spec.get("color", null) != null and str(spec.get("color", "")) != "" else "#ffffff"
	for k in ["normalUrl", "roughnessUrl"]:
		if spec.get(k, null) != null and str(spec[k]) != "":
			mat_data[k] = str(spec[k])
	var mat = main_script.create_material(mat_data)
	var opacity = _num(spec["opacity"]) if spec.get("opacity", null) != null else 1.0
	if bool(spec.get("transparent", false)) and opacity >= 0.999:
		opacity = 0.999
	_finish_material(mat, opacity)
	_material_cache[key] = mat
	return mat

func _uv_rotation(entry) -> float:
	if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("uv", null)) != TYPE_DICTIONARY:
		return 0.0
	return _num(entry["uv"].get("rotation", 0.0))

# ==============================================================================
# MESH OUTPUT
# ==============================================================================
# Box-projected UV in metres (topology/BoxUV.ts), per triangle.
func _box_uv(p: Vector3, n: Vector3) -> Vector2:
	var ax = abs(n.x)
	var ay = abs(n.y)
	var az = abs(n.z)
	if ax >= ay and ax >= az:
		return Vector2(p.z, p.y)
	if ay >= ax and ay >= az:
		return Vector2(p.x, p.z)
	return Vector2(p.x, p.y)

func _build_array_mesh(solid: Dictionary, shape: Dictionary) -> ArrayMesh:
	var tris: PackedVector3Array = solid["tris"]
	var tri_count = tris.size() / 3
	var painted = shape.get("faceMaterials", {})
	if typeof(painted) != TYPE_DICTIONARY:
		painted = {}
	# Which material each triangle takes: default unless its face was painted.
	var tri_mat = []
	tri_mat.resize(tri_count)
	tri_mat.fill(-1)
	var mats = [_default_material()]
	var rotations = [0.0]
	if painted.size() > 0:
		for face in solid["faces"]:
			var entry = painted.get(face["id"], null)
			var m = _face_material(entry)
			if m == null:
				continue
			mats.append(m)
			rotations.append(_uv_rotation(entry))
			var mi = mats.size() - 1
			for span in face["spans"]:
				for t in range(int(span[0]), min(int(span[0]) + int(span[1]), tri_count)):
					tri_mat[t] = mi
	var tools = []
	for i in range(mats.size()):
		var st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools.append(st)
	var used = []
	used.resize(mats.size())
	used.fill(false)
	for t in range(tri_count):
		var a = tris[t * 3]
		var b = tris[t * 3 + 1]
		var c = tris[t * 3 + 2]
		var n = (b - a).cross(c - a)
		if n.length_squared() < 1e-24:
			continue
		n = n.normalized()
		var mi2 = tri_mat[t] if tri_mat[t] >= 0 else 0
		var st2: SurfaceTool = tools[mi2]
		var rot = rotations[mi2]
		var cr = cos(rot)
		var sr = sin(rot)
		# three.js order is counter-clockwise from outside; Godot wants clockwise.
		for p in [a, c, b]:
			var uv = _box_uv(p, n)
			if rot != 0.0:
				uv = Vector2(cr * uv.x + sr * uv.y, -sr * uv.x + cr * uv.y)
			st2.set_normal(n)
			st2.set_uv(uv)
			st2.add_vertex(p)
		used[mi2] = true
	var mesh = ArrayMesh.new()
	for i in range(mats.size()):
		if not used[i]:
			continue
		var stc: SurfaceTool = tools[i]
		stc.generate_tangents()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, stc.commit_to_arrays())
		mesh.surface_set_material(mesh.get_surface_count() - 1, mats[i])
	return mesh

func _tool_mesh(tris: PackedVector3Array) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, tris.size(), 3):
		var a = tris[t]
		var b = tris[t + 1]
		var c = tris[t + 2]
		var n = (b - a).cross(c - a)
		if n.length_squared() < 1e-24:
			continue
		n = n.normalized()
		for p in [a, c, b]:
			st.set_normal(n)
			st.set_uv(_box_uv(p, n))
			st.add_vertex(p)
	var mesh = ArrayMesh.new()
	st.commit(mesh)
	if mesh.get_surface_count() > 0:
		# Walls a cut exposes take the unpainted surface, as in the editor.
		mesh.surface_set_material(0, _default_material())
	return mesh

func _add_solid(parent: Node3D, shape: Dictionary, solid: Dictionary, tools: Array) -> bool:
	var tris: PackedVector3Array = solid["tris"]
	if tris.size() < 3:
		return false
	var mesh = _build_array_mesh(solid, shape)
	if mesh.get_surface_count() == 0:
		return false
	var cutting = []
	if tools.size() > 0 and bool(solid["closed"]) and _is_watertight(tris):
		var bounds = _tris_aabb(tris)
		for tool_tris in tools:
			if tool_tris == null or tool_tris.size() < 12:
				continue
			if not _tris_aabb(tool_tris).intersects(bounds):
				continue
			if not _is_watertight(tool_tris):
				continue
			cutting.append(tool_tris)
	var node_name = "CADSolid_%s" % str(solid["profile_id"])
	if cutting.size() == 0:
		var mi = MeshInstance3D.new()
		mi.name = node_name
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(mi)
		return true
	var comb = CSGCombiner3D.new()
	comb.name = node_name
	var body = CSGMesh3D.new()
	body.mesh = mesh
	comb.add_child(body)
	for tool_tris in cutting:
		var cutter = CSGMesh3D.new()
		cutter.operation = CSGShape3D.OPERATION_SUBTRACTION
		cutter.mesh = _tool_mesh(tool_tris)
		comb.add_child(cutter)
	parent.add_child(comb)
	return true

# A closed outline nobody pulled into a solid (only with CAD_RENDER_FLAT_FACES).
func _add_flat_face(parent: Node3D, loop: Array) -> void:
	var n = _ring_normal(loop)
	if n.length_squared() < 1e-18:
		return
	n = n.normalized()
	var u = _plane_u(n)
	var v = _plane_v(n, u)
	var p0 = loop[0]
	var pts2d = PackedVector2Array()
	for p in loop:
		pts2d.append(Vector2((p - p0).dot(u), (p - p0).dot(v)))
	var idx = _triangulate(pts2d)
	if idx.size() == 0:
		return
	var tris = PackedVector3Array()
	for t in range(0, idx.size(), 3):
		tris.append_array([loop[idx[t]], loop[idx[t + 1]], loop[idx[t + 2]]])
	var mat_data = {"color": CAD_DEFAULT_COLOR, "roughness": 0.5}
	var mat = main_script.create_material(mat_data)
	_finish_material(mat, 0.3)
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in range(0, tris.size(), 3):
		for p in [tris[t], tris[t + 2], tris[t + 1]]:
			st.set_normal(n)
			st.set_uv(_box_uv(p, n))
			st.add_vertex(p)
	var mesh = ArrayMesh.new()
	st.commit(mesh)
	mesh.surface_set_material(0, mat)
	var mi = MeshInstance3D.new()
	mi.name = "CADDraftFace"
	mi.mesh = mesh
	parent.add_child(mi)
