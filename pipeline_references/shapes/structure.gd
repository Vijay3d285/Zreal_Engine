extends RefCounted

# Structures for BOTH the image (image_glb_creation.gd) and video
# (video_glb_creation.gd) renders, built the way the editor draws them
# (StructureManager.ts). Verified against the editor's own code run in node:
# every structure type and staircase variant matches its bounding box and its
# area per material part.

var main_script: Object
var custom_shape_gen: Object

func _init(p_main_script: Object):
	main_script = p_main_script
	custom_shape_gen = preload("res://shapes/custom_shape.gd").new(main_script)

# ==============================================================================
# STRUCTURE MATERIALS (frontend parity)
# ==============================================================================
# The editor (StructureManager.ts -> structMat/getMat) looks a structure's
# material up by ONE part name per mesh - 'Column', 'Beam', 'Sun Shade',
# 'StaircaseTop' ... - and when that key is missing it falls back to a fixed
# grey (#808080, roughness 0.85), never to "whichever material happens to be
# first". A few parts use their own default colour, and flue / bay-window sill
# ignore the materials dictionary altogether.
#
# The render has to make the same choice or a structure comes out in a colour
# nobody picked in the editor.
const STRUCT_DEFAULT_COLOR = "#808080"
const STRUCT_DEFAULT_ROUGHNESS = 0.85

func _structure_materials_dict(structure: Dictionary) -> Dictionary:
	if structure.has("materials") and typeof(structure["materials"]) == TYPE_DICTIONARY:
		return structure["materials"]
	return {}

# Material data for one named part, resolved exactly the way the editor does.
func _struct_mat_data(structure: Dictionary, key: String, default_color: String = STRUCT_DEFAULT_COLOR) -> Dictionary:
	var mats = _structure_materials_dict(structure)
	var out = {}
	if mats.has(key) and typeof(mats[key]) == TYPE_DICTIONARY:
		out = mats[key].duplicate()
	var has_map = out.has("mapUrl") and out["mapUrl"] != null and str(out["mapUrl"]) != ""
	var has_color = out.has("color") and out["color"] != null and str(out["color"]).strip_edges() != ""
	if not has_color:
		if has_map:
			# Editor: a texture with no colour shows untinted (colour set to white).
			out.erase("color")
		else:
			out["color"] = default_color
	if not out.has("roughness") or out["roughness"] == null:
		out["roughness"] = STRUCT_DEFAULT_ROUGHNESS
	if out.has("metalness") and out["metalness"] != null and not out.has("metallic"):
		out["metallic"] = float(out["metalness"])
	out["is_structure"] = true
	return out

# A fixed material the editor uses regardless of what is stored on the structure.
func _fixed_struct_mat_data(color: String, roughness: float = 1.0) -> Dictionary:
	return {"color": color, "roughness": roughness, "metallic": 0.0, "is_structure": true}

func _struct_mat(structure: Dictionary, key: String, default_color: String = STRUCT_DEFAULT_COLOR) -> Material:
	return _struct_material(_struct_mat_data(structure, key, default_color), UV_UNIT)

# ── Texture scale (editor parity) ────────────────────────────────────────────
# Editor (StructureManager.applyStructTexture): texture.repeat is the
# material's `repeat` array taken as-is, or 1000 / repeatX when the material
# stores a tile size in mm instead. That repeat multiplies the GEOMETRY's own
# UVs, which in three.js are:
#   - BoxGeometry / PlaneGeometry / CylinderGeometry: 0..1 across each face,
#     so `repeat` is the number of images per face whatever its size;
#   - ExtrudeGeometry (steps, ramps, sunshades, flat flights, winders):
#     the shape's own coordinates, i.e. metres.
# The render used triplanar mapping instead (repeat per metre on every part),
# which made a 3 m column show 3 images where the editor shows 1.
# Every builder below therefore emits the editor's UV layout and turns
# triplanar off; uv_factor compensates Godot primitives whose UV layout is
# packed differently (BoxMesh puts each face in a 1/3 x 1/2 cell).
const UV_UNIT = Vector2(1.0, 1.0)
const UV_BOXMESH = Vector2(3.0, 2.0)

func _editor_struct_repeat(mat_data) -> Vector2:
	if typeof(mat_data) != TYPE_DICTIONARY:
		return Vector2.ONE
	var r = mat_data.get("repeat", null)
	if typeof(r) == TYPE_ARRAY:
		var rx = float(r[0]) if r.size() > 0 and r[0] != null else 1.0
		var ry = float(r[1]) if r.size() > 1 and r[1] != null else 1.0
		return Vector2(rx, ry)
	var tx = float(mat_data.get("repeatX", 0.0)) if mat_data.get("repeatX", null) != null else 0.0
	var ty = float(mat_data.get("repeatY", 0.0)) if mat_data.get("repeatY", null) != null else 0.0
	return Vector2(1000.0 / (tx if tx > 0.0 else 1000.0), 1000.0 / (ty if ty > 0.0 else 1000.0))

func _struct_material(mat_data, uv_factor: Vector2) -> Material:
	var mat = main_script.create_material(mat_data)
	if mat is BaseMaterial3D:
		var bm: BaseMaterial3D = mat
		var rep = _editor_struct_repeat(mat_data)
		bm.uv1_triplanar = false
		bm.uv1_scale = Vector3(rep.x * uv_factor.x, rep.y * uv_factor.y, 1.0)
	return mat

# Kept for callers outside this file: the main material of a structure type.
func _resolve_structure_material(structure: Dictionary, structure_type: String) -> Dictionary:
	match structure_type:
		"squarecolumn", "column", "circlecolumn":
			return _struct_mat_data(structure, "Column")
		"beam":
			return _struct_mat_data(structure, "Beam")
		"sunshade":
			return _struct_mat_data(structure, "Sun Shade")
		"ramp":
			return _struct_mat_data(structure, "Ramp", "#999999")
		"step":
			return _struct_mat_data(structure, "Step")
		"niche":
			return _struct_mat_data(structure, "Niche", "#dddddd")
		"falseceiling":
			return _struct_mat_data(structure, "False Ceiling", "#f0f0f0")
		"staircase":
			return _struct_mat_data(structure, "StaircaseTop")
		"flue":
			return _fixed_struct_mat_data("#bbbbbb")
		"baywindowsill":
			return _fixed_struct_mat_data("#ffffff")
		"flooropening":
			return _struct_mat_data(structure, "FloorOpening")
		_:
			pass
	var mats = _structure_materials_dict(structure)
	if mats.size() > 0:
		var first_key = mats.keys()[0]
		if typeof(mats[first_key]) == TYPE_DICTIONARY:
			return _struct_mat_data(structure, str(first_key))
	return _fixed_struct_mat_data(STRUCT_DEFAULT_COLOR, STRUCT_DEFAULT_ROUGHNESS)

# ==============================================================================
# MESH HELPERS
# ==============================================================================
# Geometry is emitted into one SurfaceTool per material and committed as a
# single ArrayMesh, so a 20-step staircase is one mesh with three surfaces
# instead of sixty MeshInstance3D nodes.
#
# Winding: Godot treats a triangle as front-facing when its vertices run
# CLOCKWISE seen from the front, i.e. (b - a).cross(c - a) points AWAY from the
# viewer. Every triangle here is given its intended outward normal and the
# winding is chosen from it, so nothing depends on the order a caller happened
# to list the corners in.

func _mesh_acc() -> Dictionary:
	return {"tools": {}, "mats": {}, "order": []}

func _mesh_tool(acc: Dictionary, mat: Material) -> SurfaceTool:
	var key = mat.get_instance_id()
	if not acc["tools"].has(key):
		var st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		acc["tools"][key] = st
		acc["mats"][key] = mat
		acc["order"].append(key)
	return acc["tools"][key]

func _box_uv(p: Vector3, n: Vector3) -> Vector2:
	var ax = abs(n.x)
	var ay = abs(n.y)
	var az = abs(n.z)
	if ax >= ay and ax >= az:
		return Vector2(p.z, p.y)
	if ay >= ax and ay >= az:
		return Vector2(p.x, p.z)
	return Vector2(p.x, p.y)

func _emit_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3, tri_uv: Array = []) -> void:
	var n = outward
	if n.length_squared() < 1e-12:
		n = -(b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	n = n.normalized()
	var pts = [a, b, c]
	var uvs = tri_uv if tri_uv.size() == 3 else [_box_uv(a, n), _box_uv(b, n), _box_uv(c, n)]
	var order = [0, 1, 2]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [0, 2, 1]
	for k in order:
		st.set_normal(n)
		st.set_uv(uvs[k])
		st.add_vertex(pts[k])

func _emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, quad_uv: Array = []) -> void:
	if quad_uv.size() == 4:
		_emit_tri(st, a, b, c, outward, [quad_uv[0], quad_uv[1], quad_uv[2]])
		_emit_tri(st, a, c, d, outward, [quad_uv[0], quad_uv[2], quad_uv[3]])
		return
	_emit_tri(st, a, b, c, outward)
	_emit_tri(st, a, c, d, outward)

func _mesh_commit(acc: Dictionary, parent: Node3D, node_name: String) -> MeshInstance3D:
	var mesh = ArrayMesh.new()
	for key in acc["order"]:
		var st: SurfaceTool = acc["tools"][key]
		var arrays = st.commit_to_arrays()
		var verts = arrays[Mesh.ARRAY_VERTEX]
		if verts == null or verts.size() == 0:
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, acc["mats"][key])
	if mesh.get_surface_count() == 0:
		return null
	var mi = MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi

# An axis-aligned box with one material per face, in three.js BoxGeometry face
# order: [+X, -X, +Y, -Y, +Z, -Z].
func _emit_box(acc: Dictionary, size: Vector3, center: Vector3, mats6: Array) -> void:
	var hx = max(size.x, 0.0005) * 0.5
	var hy = max(size.y, 0.0005) * 0.5
	var hz = max(size.z, 0.0005) * 0.5
	var c = center
	var p = [
		c + Vector3(-hx, -hy, -hz), c + Vector3(hx, -hy, -hz),
		c + Vector3(hx, hy, -hz), c + Vector3(-hx, hy, -hz),
		c + Vector3(-hx, -hy, hz), c + Vector3(hx, -hy, hz),
		c + Vector3(hx, hy, hz), c + Vector3(-hx, hy, hz)
	]
	# Each face is UV-mapped 0..1 across itself, as three.js BoxGeometry is.
	var fuv = func(q: Vector3, axis: int) -> Vector2:
		var r = q - c
		if axis == 0:
			return Vector2((r.z + hz) / (2.0 * hz), (r.y + hy) / (2.0 * hy))
		if axis == 1:
			return Vector2((r.x + hx) / (2.0 * hx), (r.z + hz) / (2.0 * hz))
		return Vector2((r.x + hx) / (2.0 * hx), (r.y + hy) / (2.0 * hy))
	var faces = [
		[0, [1, 2, 6, 5], Vector3(1, 0, 0), 0], [1, [0, 4, 7, 3], Vector3(-1, 0, 0), 0],
		[2, [3, 7, 6, 2], Vector3(0, 1, 0), 1], [3, [0, 1, 5, 4], Vector3(0, -1, 0), 1],
		[4, [4, 5, 6, 7], Vector3(0, 0, 1), 2], [5, [0, 3, 2, 1], Vector3(0, 0, -1), 2]
	]
	for f in faces:
		var ids = f[1]
		var quv = []
		for id in ids:
			quv.append(fuv.call(p[id], f[3]))
		_emit_quad(_mesh_tool(acc, mats6[f[0]]), p[ids[0]], p[ids[1]], p[ids[2]], p[ids[3]], f[2], quv)

func _clean_loop_2d(pts: PackedVector2Array) -> PackedVector2Array:
	var out = PackedVector2Array()
	for p in pts:
		if out.size() > 0 and out[out.size() - 1].distance_to(p) < 1e-7:
			continue
		out.append(p)
	while out.size() > 2 and out[0].distance_to(out[out.size() - 1]) < 1e-7:
		out.remove_at(out.size() - 1)
	return out

func _signed_area_2d(pts: PackedVector2Array) -> float:
	var s = 0.0
	for i in range(pts.size()):
		var a = pts[i]
		var b = pts[(i + 1) % pts.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5

# A side profile drawn in the editor's XY plane and extruded across the width:
# the pattern StructureManager uses for steps, ramps and flat-bottom flights
# (Shape -> ExtrudeGeometry(depth = width) -> translate(-width/2) -> rotateY).
# The profile's X becomes z_sign * x + z_offset, its Y stays up, and the
# extrusion spans X from -width/2 to +width/2.
#
# mats3 = [sides, top, bottom], picked per face the way the editor's flat
# staircase does it: a face whose normal runs along X is a side, a face with an
# upward or +Z component is a top, everything else a bottom. Pass the same
# material three times for a single-material part.
func _emit_side_profile_prism(acc: Dictionary, raw_pts: PackedVector2Array, width: float, z_sign: float, z_offset: float, mats3: Array) -> void:
	var pts = _clean_loop_2d(raw_pts)
	if pts.size() < 3:
		return
	var area = _signed_area_2d(pts)
	if abs(area) < 1e-12:
		return
	var orient = 1.0 if area > 0.0 else -1.0
	var hw = max(width, 0.0005) * 0.5
	var tris = Geometry2D.triangulate_polygon(pts)
	var side_st = _mesh_tool(acc, mats3[0])
	for i in range(0, tris.size(), 3):
		var a = pts[tris[i]]
		var b = pts[tris[i + 1]]
		var c = pts[tris[i + 2]]
		for sx in [-1.0, 1.0]:
			_emit_tri(side_st,
				Vector3(sx * hw, a.y, z_sign * a.x + z_offset),
				Vector3(sx * hw, b.y, z_sign * b.x + z_offset),
				Vector3(sx * hw, c.y, z_sign * c.x + z_offset),
				Vector3(sx, 0, 0))
	for i in range(pts.size()):
		var p0 = pts[i]
		var p1 = pts[(i + 1) % pts.size()]
		var d = p1 - p0
		if d.length_squared() < 1e-14:
			continue
		var n2 = Vector2(d.y, -d.x).normalized() * orient
		var n3 = Vector3(0, n2.y, z_sign * n2.x)
		var mat_idx = 2
		if abs(n3.x) > 0.5:
			mat_idx = 0
		elif n3.y > 0.01 or n3.z > 0.01:
			mat_idx = 1
		_emit_quad(_mesh_tool(acc, mats3[mat_idx]),
			Vector3(-hw, p0.y, z_sign * p0.x + z_offset),
			Vector3(hw, p0.y, z_sign * p0.x + z_offset),
			Vector3(hw, p1.y, z_sign * p1.x + z_offset),
			Vector3(-hw, p1.y, z_sign * p1.x + z_offset),
			n3)

# A flat outline (x, z) extruded straight up from y0 to y1. Used for winder
# treads. mats3 = [sides, top, bottom].
func _emit_vertical_prism(acc: Dictionary, raw_pts: PackedVector2Array, y0: float, y1: float, mats3: Array) -> void:
	var pts = _clean_loop_2d(raw_pts)
	if pts.size() < 3:
		return
	var area = _signed_area_2d(pts)
	if abs(area) < 1e-12:
		return
	var orient = 1.0 if area > 0.0 else -1.0
	var tris = Geometry2D.triangulate_polygon(pts)
	var top_st = _mesh_tool(acc, mats3[1])
	var bot_st = _mesh_tool(acc, mats3[2])
	for i in range(0, tris.size(), 3):
		var a = pts[tris[i]]
		var b = pts[tris[i + 1]]
		var c = pts[tris[i + 2]]
		_emit_tri(top_st, Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(c.x, y1, c.y), Vector3(0, 1, 0))
		_emit_tri(bot_st, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(c.x, y0, c.y), Vector3(0, -1, 0))
	var side_st = _mesh_tool(acc, mats3[0])
	for i in range(pts.size()):
		var p0 = pts[i]
		var p1 = pts[(i + 1) % pts.size()]
		var d = p1 - p0
		if d.length_squared() < 1e-14:
			continue
		var n2 = Vector2(d.y, -d.x).normalized() * orient
		_emit_quad(side_st,
			Vector3(p0.x, y0, p0.y), Vector3(p1.x, y0, p1.y),
			Vector3(p1.x, y1, p1.y), Vector3(p0.x, y1, p0.y),
			Vector3(n2.x, 0, n2.y))

func _dim_m(props: Dictionary, key: String, default_m: float) -> float:
	# A {length: mm} (or bare number) property in metres; default when absent or not positive.
	if not props.has(key) or props[key] == null:
		return default_m
	var raw = main_script.get_dimension_value(props[key])
	if raw <= 0.0:
		return default_m
	return raw * main_script._scene_unit_scale

func _add_custom_shape_structure(parent: Node3D, structure: Dictionary, scale_factor: float) -> void:
	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var shapes_json_str = ""
	if structure.has("customShapeData") and str(structure["customShapeData"]) != "":
		shapes_json_str = str(structure["customShapeData"])
	elif structure.has("shapesJson"):
		shapes_json_str = str(structure["shapesJson"])
	elif props.has("shapesJson"):
		shapes_json_str = str(props["shapesJson"])
	elif props.has("customShapeData"):
		shapes_json_str = str(props["customShapeData"])
	elif props.has("custom_shape_data"):
		shapes_json_str = str(props["custom_shape_data"])

	if shapes_json_str != "" and shapes_json_str != "null":
		# Editor parity first: natural canvas size (mm), no stretching to
		# width / height / depth. Old builder only if nothing could be built.
		if custom_shape_gen.build_editor_custom_shape(parent, shapes_json_str, "structure " + str(structure.get("id", ""))):
			_rescale_custom_shape_uvs(parent)
			return
		var tw = float(props.get("width", {}).get("length", -1.0)) * scale_factor if props.has("width") else -1.0
		var th = float(props.get("height", {}).get("length", -1.0)) * scale_factor if props.has("height") else -1.0
		var td = float(props.get("depth", {}).get("length", -1.0)) * scale_factor if props.has("depth") else -1.0
		custom_shape_gen.generate_shapes(parent, shapes_json_str, scale_factor, Vector3(tw, th, td))
		_rescale_custom_shape_uvs(parent)

# Editor (CustomShapeManager): shape geometry is in metres and the texture
# repeats 1000 / repeatX per metre (default 1000 mm). The CSG polygons here
# normalise cap UVs to the polygon's bounding box (0..0.5 per axis), and are
# then resized to the structure's width / height / depth, so the scale is set
# afterwards from each polygon's FINAL size: uv1 = 2 * span_m / tile_m.
#
# Shapes with identical material settings (and, when textured, the same texture
# scale) also SHARE one material here. Godot merges a CSG group into one mesh
# with one surface per distinct material and a mesh holds at most 256 surfaces,
# so a group of more than 256 separately-materialled shapes lost everything
# past the 256th (job a3ca857c: a 1440-piece jaali wall rendered ~18 % of it).
const CUSTOM_SHAPE_MAX_SURFACES := 256

func _rescale_custom_shape_uvs(root: Node3D) -> void:
	var shared := {}
	var shape_count := 0
	var stack = [root]
	while stack.size() > 0:
		var n = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if not (n is CSGPolygon3D):
			continue
		var mat = n.material
		if not (mat is BaseMaterial3D) or not mat.has_meta("editor_mat"):
			continue
		var md = mat.get_meta("editor_mat")
		if typeof(md) != TYPE_DICTIONARY:
			continue
		var poly: PackedVector2Array = n.polygon
		if poly.size() < 3:
			continue
		var pmin = poly[0]
		var pmax = poly[0]
		for q in poly:
			pmin = pmin.min(q)
			pmax = pmax.max(q)
		var xf = Transform3D.IDENTITY
		var walk = n
		while walk != null and walk != root and walk is Node3D:
			xf = walk.transform * xf
			walk = walk.get_parent()
		var span_u = (xf.basis * Vector3(pmax.x - pmin.x, 0, 0)).length()
		var span_v = (xf.basis * Vector3(0, pmax.y - pmin.y, 0)).length()
		var tx = float(md.get("repeatX", 0.0)) if md.get("repeatX", null) != null else 0.0
		var ty = float(md.get("repeatY", 0.0)) if md.get("repeatY", null) != null else 0.0
		var tile_u = (tx if tx > 0.0 else 1000.0) * main_script._scene_unit_scale
		var tile_v = (ty if ty > 0.0 else 1000.0) * main_script._scene_unit_scale
		var bm: BaseMaterial3D = mat
		var uv_scale := Vector3(2.0 * span_u / max(tile_u, 0.000001), 2.0 * span_v / max(tile_v, 0.000001), 1.0)
		var textured: bool = bm.albedo_texture != null or bm.normal_texture != null or bm.roughness_texture != null
		var key := JSON.stringify(md)
		if textured:
			key += "|%.3f,%.3f" % [uv_scale.x, uv_scale.y]
		shape_count += 1
		if shared.has(key):
			n.material = shared[key]
			continue
		bm.uv1_triplanar = false
		bm.uv1_scale = uv_scale
		shared[key] = bm
	if shape_count > 0:
		print("[CustomShape] %d shape(s) share %d material(s)" % [shape_count, shared.size()])
		if shared.size() > CUSTOM_SHAPE_MAX_SURFACES:
			push_warning("[CustomShape] %d distinct materials in one custom shape: Godot keeps only %d mesh surfaces, the rest will be missing" % [shared.size(), CUSTOM_SHAPE_MAX_SURFACES])

func _add_sunshade_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary, render_mode: String = "INTERIOR") -> void:
	var w = max(width, 0.05)
	var d = max(depth, 0.05)
	var h = max(height, 0.05)
	var props = structure.get("properties", {})
	var slope_deg = float(props.get("slope", 5.0))
	var slope_rad = deg_to_rad(slope_deg)
	var dh = d * tan(slope_rad)
	var front_thickness = max(h * 0.5, 0.04)
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var wall_top = h
	var wall_bot = 0.0
	var front_top = h - dh
	var front_bot = front_top - front_thickness
	
	var min_x = -w * 0.5
	var max_x = w * 0.5
	var min_z = -d * 0.5
	var max_z = d * 0.5
	
	var v0 = Vector3(min_x, wall_bot, min_z)
	var v1 = Vector3(max_x, wall_bot, min_z)
	var v2 = Vector3(max_x, wall_top, min_z)
	var v3 = Vector3(min_x, wall_top, min_z)
	var v4 = Vector3(min_x, front_bot, max_z)
	var v5 = Vector3(max_x, front_bot, max_z)
	var v6 = Vector3(max_x, front_top, max_z)
	var v7 = Vector3(min_x, front_top, max_z)
	
	st.add_vertex(v0); st.add_vertex(v3); st.add_vertex(v2);
	st.add_vertex(v0); st.add_vertex(v2); st.add_vertex(v1);
	st.add_vertex(v5); st.add_vertex(v6); st.add_vertex(v7);
	st.add_vertex(v5); st.add_vertex(v7); st.add_vertex(v4);
	st.add_vertex(v3); st.add_vertex(v7); st.add_vertex(v6);
	st.add_vertex(v3); st.add_vertex(v6); st.add_vertex(v2);
	st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(v5);
	st.add_vertex(v0); st.add_vertex(v5); st.add_vertex(v4);
	st.add_vertex(v4); st.add_vertex(v7); st.add_vertex(v3);
	st.add_vertex(v4); st.add_vertex(v3); st.add_vertex(v0);
	st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v6);
	st.add_vertex(v1); st.add_vertex(v6); st.add_vertex(v5);
	
	st.generate_normals()
	# The editor's sunshade is an ExtrudeGeometry, whose UVs are the profile's
	# own coordinates in metres; this mesh had no UVs at all.
	var ss_arrays = st.commit_to_arrays()
	var ss_verts = ss_arrays[Mesh.ARRAY_VERTEX]
	var ss_uvs = PackedVector2Array()
	ss_uvs.resize(ss_verts.size())
	for vi in range(0, ss_verts.size() - 2, 3):
		# Project each triangle along its OWN face normal (generate_normals
		# smooths across shared corners, which would mix projections).
		var fn = (ss_verts[vi + 1] - ss_verts[vi]).cross(ss_verts[vi + 2] - ss_verts[vi])
		for k in range(3):
			ss_uvs[vi + k] = _box_uv(ss_verts[vi + k], fn)
	ss_arrays[Mesh.ARRAY_TEX_UV] = ss_uvs
	var ss_mesh = ArrayMesh.new()
	ss_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ss_arrays)
	var mesh = MeshInstance3D.new()
	mesh.mesh = ss_mesh
	mesh.material_override = _struct_material(mat_data, UV_UNIT)
	if mesh.material_override is BaseMaterial3D:
		# Sunshades are often thin and viewed from grazing angles, so keep both
		# sides visible instead of relying on face winding.
		(mesh.material_override as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Interior sunshades are often thin and close to the camera; a generous
	# bounding box prevents them from being frustum-culled before they reach
	# the image plane.
	if render_mode.to_upper() == "INTERIOR":
		mesh.extra_cull_margin = 2.0
		mesh.custom_aabb = AABB(Vector3(-w, -h, -d), Vector3(w * 2.0, h * 3.0, d * 2.0))
	else:
		mesh.extra_cull_margin = max(w, d, h) * 0.5 + 0.25
		mesh.custom_aabb = AABB(
			Vector3(-w * 0.5 - 0.25, min(0.0, front_bot) - 0.25, -d * 0.5 - 0.25),
			Vector3(w + 0.5, max(wall_top, front_top) - min(0.0, front_bot) + 0.5, d + 0.5)
		)
	parent.add_child(mesh)

func _add_niche_structure(parent: Node3D, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var w = max(width, 0.05)
	var d = max(depth, 0.05)
	var h = max(height, 0.05)
	var niche_group = Node3D.new()
	var mat = _struct_material(mat_data, UV_UNIT)
	
	var back = MeshInstance3D.new()
	back.mesh = PlaneMesh.new()
	back.mesh.size = Vector2(w, h)
	back.mesh.orientation = PlaneMesh.FACE_Z
	back.position = Vector3(0, 0, -d / 2.0)
	back.material_override = mat
	niche_group.add_child(back)
	
	var left = MeshInstance3D.new()
	left.mesh = PlaneMesh.new()
	left.mesh.size = Vector2(d, h)
	left.mesh.orientation = PlaneMesh.FACE_Z
	left.position = Vector3(-w / 2.0, 0, 0)
	left.rotation.y = PI / 2.0
	left.material_override = mat
	niche_group.add_child(left)
	
	var right = MeshInstance3D.new()
	right.mesh = PlaneMesh.new()
	right.mesh.size = Vector2(d, h)
	right.mesh.orientation = PlaneMesh.FACE_Z
	right.position = Vector3(w / 2.0, 0, 0)
	right.rotation.y = - PI / 2.0
	right.material_override = mat
	niche_group.add_child(right)
	
	var top = MeshInstance3D.new()
	top.mesh = PlaneMesh.new()
	top.mesh.size = Vector2(w, d)
	top.mesh.orientation = PlaneMesh.FACE_Y
	top.position = Vector3(0, h / 2.0, 0)
	top.rotation.x = PI
	top.material_override = mat
	niche_group.add_child(top)
	
	var bot = MeshInstance3D.new()
	bot.mesh = PlaneMesh.new()
	bot.mesh.size = Vector2(w, d)
	bot.mesh.orientation = PlaneMesh.FACE_Y
	bot.position = Vector3(0, -h / 2.0, 0)
	bot.material_override = mat
	niche_group.add_child(bot)
	
	niche_group.position.y = h / 2.0
	parent.add_child(niche_group)

func _add_baywindowsill_structure(parent: Node3D, width: float, depth: float, mat_data: Dictionary) -> void:
	# Editor: a 5 mm white slab centred on the structure origin; the stored
	# materials are not used.
	var h = 0.005
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(width, 0.001), h, max(depth, 0.001))
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _struct_material(mat_data, UV_BOXMESH)
	parent.add_child(mi)

func _add_box_structure(parent: Node3D, structure_type: String, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(width, 0.001), max(height, 0.001), max(depth, 0.001))
	var mi = MeshInstance3D.new()
	mi.name = structure_type.capitalize()
	mi.mesh = mesh
	mi.material_override = _struct_material(mat_data, UV_BOXMESH)
	mi.position = Vector3(0, max(height, 0.001) * 0.5, 0)
	parent.add_child(mi)

# Editor 'partitionwall': up to four walls, each with its own thickness
# (wall_thickness_1..4, falling back to wall_thickness, default 100 mm) and an
# _Outer / _Inner material per wall (default #cccccc).
func _add_partitionwall_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, _mat_data: Dictionary) -> void:
	var props = structure.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		props = {}
	var shape = str(props.get("partition_shape", "rect")).to_lower().strip_edges()
	if shape == "" or shape == "null":
		shape = "rect"
	var w = width
	var d = depth
	var h = height
	var t_all = _dim_m(props, "wall_thickness", 0.1)
	var t1 = _dim_m(props, "wall_thickness_1", t_all)
	var t2 = _dim_m(props, "wall_thickness_2", t_all)
	var t3 = _dim_m(props, "wall_thickness_3", t_all)
	var t4 = _dim_m(props, "wall_thickness_4", t_all)

	var cache = {}
	var mat_for = func(part_name: String) -> Material:
		if not cache.has(part_name):
			cache[part_name] = _struct_mat(structure, part_name, "#cccccc")
		return cache[part_name]
	var std_faces = func(seg: String, inner_idx: int) -> Array:
		var arr = []
		for i in range(6):
			arr.append(mat_for.call(seg + ("_Inner" if i == inner_idx else "_Outer")))
		return arr

	var acc = _mesh_acc()
	if shape == "rect":
		var it1 = min(t1, d * 0.45)
		var it2 = min(t2, w * 0.45)
		var it3 = min(t3, d * 0.45)
		var it4 = min(t4, w * 0.45)
		var mid_d = max(0.0, d - it1 - it3)
		var mid_z = -d / 2.0 + it1 + mid_d / 2.0
		var bottom_faces = [mat_for.call("PartitionWallRight_Outer"), mat_for.call("PartitionWallLeft_Outer"),
			mat_for.call("PartitionWallBottom_Outer"), mat_for.call("PartitionWallBottom_Outer"),
			mat_for.call("PartitionWallBottom_Inner"), mat_for.call("PartitionWallBottom_Outer")]
		_emit_box(acc, Vector3(w, h, it1), Vector3(0, h / 2.0, -d / 2.0 + it1 / 2.0), bottom_faces)
		var top_faces = [mat_for.call("PartitionWallRight_Outer"), mat_for.call("PartitionWallLeft_Outer"),
			mat_for.call("PartitionWallTop_Outer"), mat_for.call("PartitionWallTop_Outer"),
			mat_for.call("PartitionWallTop_Outer"), mat_for.call("PartitionWallTop_Inner")]
		_emit_box(acc, Vector3(w, h, it3), Vector3(0, h / 2.0, d / 2.0 - it3 / 2.0), top_faces)
		_emit_box(acc, Vector3(it4, h, mid_d), Vector3(-w / 2.0 + it4 / 2.0, h / 2.0, mid_z), std_faces.call("PartitionWallLeft", 0))
		_emit_box(acc, Vector3(it2, h, mid_d), Vector3(w / 2.0 - it2 / 2.0, h / 2.0, mid_z), std_faces.call("PartitionWallRight", 1))
	elif shape == "l_shaped":
		var lt1 = min(t1, d * 0.9)
		var lt2 = min(t2, w * 0.9)
		var rem_d = max(0.0, d - lt1)
		var leg1_faces = [mat_for.call("PartitionWallLeg1_Outer"), mat_for.call("PartitionWallLeg2_Outer"),
			mat_for.call("PartitionWallLeg1_Outer"), mat_for.call("PartitionWallLeg1_Outer"),
			mat_for.call("PartitionWallLeg1_Inner"), mat_for.call("PartitionWallLeg1_Outer")]
		_emit_box(acc, Vector3(w, h, lt1), Vector3(0, h / 2.0, -d / 2.0 + lt1 / 2.0), leg1_faces)
		_emit_box(acc, Vector3(lt2, h, rem_d), Vector3(-w / 2.0 + lt2 / 2.0, h / 2.0, -d / 2.0 + lt1 + rem_d / 2.0), std_faces.call("PartitionWallLeg2", 0))
	elif shape == "u_shaped":
		var ut1 = min(t1, d * 0.9)
		var ut2 = min(t2, w * 0.45)
		var ut3 = min(t3, w * 0.45)
		var rem_d_u = max(0.0, d - ut1)
		var leg_z = -d / 2.0 + ut1 + rem_d_u / 2.0
		var base_faces = [mat_for.call("PartitionWallRightLeg_Outer"), mat_for.call("PartitionWallLeftLeg_Outer"),
			mat_for.call("PartitionWallBase_Outer"), mat_for.call("PartitionWallBase_Outer"),
			mat_for.call("PartitionWallBase_Inner"), mat_for.call("PartitionWallBase_Outer")]
		_emit_box(acc, Vector3(w, h, ut1), Vector3(0, h / 2.0, -d / 2.0 + ut1 / 2.0), base_faces)
		_emit_box(acc, Vector3(ut2, h, rem_d_u), Vector3(-w / 2.0 + ut2 / 2.0, h / 2.0, leg_z), std_faces.call("PartitionWallLeftLeg", 0))
		_emit_box(acc, Vector3(ut3, h, rem_d_u), Vector3(w / 2.0 - ut3 / 2.0, h / 2.0, leg_z), std_faces.call("PartitionWallRightLeg", 1))
	else:
		# The editor draws nothing for an unknown partition shape.
		return
	_mesh_commit(acc, parent, "PartitionWall")

func _add_cylinder_structure(parent: Node3D, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	# Editor: CylinderGeometry(w/2, w/2, h, 32) - the radius follows WIDTH only.
	# Built here rather than with CylinderMesh so the UVs are three.js's: the
	# side wraps 0..1 once around and 0..1 up, each cap is a 0..1 disc.
	var radius = max(width, 0.001) * 0.5
	var h = max(height, 0.001)
	var segs = 32
	var mat = _struct_material(mat_data, UV_UNIT)
	var acc = _mesh_acc()
	var st = _mesh_tool(acc, mat)
	for i in range(segs):
		var a0 = TAU * float(i) / segs
		var a1 = TAU * float(i + 1) / segs
		var p0 = Vector3(sin(a0) * radius, 0.0, cos(a0) * radius)
		var p1 = Vector3(sin(a1) * radius, 0.0, cos(a1) * radius)
		var u0 = float(i) / segs
		var u1 = float(i + 1) / segs
		var mid = (a0 + a1) * 0.5
		_emit_quad(st, p0, p1, p1 + Vector3(0, h, 0), p0 + Vector3(0, h, 0), Vector3(sin(mid), 0, cos(mid)),
			[Vector2(u0, 1), Vector2(u1, 1), Vector2(u1, 0), Vector2(u0, 0)])
		var c0 = Vector2(cos(a0) * 0.5 + 0.5, sin(a0) * 0.5 + 0.5)
		var c1 = Vector2(cos(a1) * 0.5 + 0.5, sin(a1) * 0.5 + 0.5)
		_emit_tri(st, Vector3(0, h, 0), p0 + Vector3(0, h, 0), p1 + Vector3(0, h, 0), Vector3(0, 1, 0), [Vector2(0.5, 0.5), c0, c1])
		_emit_tri(st, Vector3.ZERO, p0, p1, Vector3(0, -1, 0), [Vector2(0.5, 0.5), c0, c1])
	_mesh_commit(acc, parent, "Column")

# Editor 'ramp': a right-triangle side profile of length run_length (default:
# depth). A positive slope (degrees) sets the rise; otherwise the height does.
# The high end sits at -Z (Shape -> rotateY(+PI/2)).
func _add_ramp_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var props = structure.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		props = {}
	var run_len = depth
	if props.has("run_length") and props["run_length"] != null:
		var rl = main_script.get_dimension_value(props["run_length"]) * main_script._scene_unit_scale
		if rl > 0.0:
			run_len = rl
	var eff_h = height
	var slope = float(props.get("slope", 0.0)) if props.get("slope", null) != null else 0.0
	if slope > 0.0:
		eff_h = run_len * tan(deg_to_rad(slope))
	var pts = PackedVector2Array([
		Vector2(-run_len / 2.0, 0.0),
		Vector2(run_len / 2.0, eff_h),
		Vector2(run_len / 2.0, 0.0)
	])
	var mat = _struct_material(mat_data, UV_UNIT)
	var acc = _mesh_acc()
	_emit_side_profile_prism(acc, pts, width, -1.0, 0.0, [mat, mat, mat])
	_mesh_commit(acc, parent, "Ramp")

# Editor 'step': one solid block of steps (no separate support) built from the
# structure's width / depth / height. step_count comes from the first flight
# (default 5). The tallest step is at -Z, descending towards +Z.
func _add_step_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var props = structure.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		props = {}
	var stair = props.get("stair", {})
	if typeof(stair) != TYPE_DICTIONARY:
		stair = {}
	var flights = stair.get("flights", [])
	var step_count = 5
	if typeof(flights) == TYPE_ARRAY and flights.size() > 0 and typeof(flights[0]) == TYPE_DICTIONARY:
		var sc_raw = flights[0].get("step_count", 10)
		step_count = int(sc_raw) if sc_raw != null else 10
	step_count = max(step_count, 1)
	var h = max(height, 0.001)
	var d = max(depth, 0.001)
	var sh = h / float(step_count)
	var sd = d / float(step_count)
	var pts = PackedVector2Array()
	pts.append(Vector2(0, 0))
	pts.append(Vector2(0, h))
	for i in range(step_count):
		var cur_y = h - i * sh
		var nxt_y = h - (i + 1) * sh
		var nxt_x = (i + 1) * sd
		pts.append(Vector2(i * sd, cur_y))
		pts.append(Vector2(nxt_x, cur_y))
		pts.append(Vector2(nxt_x, nxt_y))
	var mat = _struct_material(mat_data, UV_UNIT)
	var acc = _mesh_acc()
	_emit_side_profile_prism(acc, pts, width, 1.0, -d / 2.0, [mat, mat, mat])
	_mesh_commit(acc, parent, "Step")

# Editor 'falseceiling': a 2 mm board centred on the structure's altitude, and
# for the 'coffered' pattern a raised box half the width and depth sitting on
# top of it, drop_height tall (default 200 mm).
func _add_false_ceiling_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, _height: float, _mat_data: Dictionary) -> void:
	var props = structure.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		props = {}
	var drop_h = _dim_m(props, "drop_height", 0.2)
	var pattern = str(props.get("pattern_type", "plain")).to_lower()
	var thick = 0.002
	_add_box_part(parent, Vector3(width, thick, depth), _struct_mat_data(structure, "False Ceiling", "#f0f0f0"), Vector3.ZERO)
	if pattern == "coffered":
		_add_box_part(parent, Vector3(width * 0.5, drop_h, depth * 0.5), _struct_mat_data(structure, "Drop Section", "#f0f0f0"), Vector3(0, thick / 2.0 + drop_h / 2.0, 0))

func _add_box_part(parent: Node3D, size: Vector3, mat_data: Dictionary, local_position: Vector3) -> void:
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(size.x, 0.001), max(size.y, 0.001), max(size.z, 0.001))
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _struct_material(mat_data, UV_BOXMESH)
	mi.position = local_position
	parent.add_child(mi)

# ==============================================================================
# STAIRCASE (port of StructureManager.ts 'staircase')
# ==============================================================================
# Riser and tread come from the FIRST flight and apply to every flight; when
# either is missing the structure's height / depth is shared out over the
# total step count. Multi-flight stairs (l_shaped, u_shaped, winder) count both
# flights' steps. Every flight runs along +Z from its own origin and is then
# placed and turned exactly as the editor places it.

func _flight_dict(flights, index: int) -> Dictionary:
	if typeof(flights) == TYPE_ARRAY and flights.size() > index and typeof(flights[index]) == TYPE_DICTIONARY:
		return flights[index]
	return {}

func _flight_count(flight: Dictionary) -> int:
	if flight.is_empty():
		return 10
	var v = flight.get("step_count", 10)
	if v == null:
		return 10
	return max(int(v), 1)

func _flight_positive(flight: Dictionary, key: String) -> float:
	if flight.is_empty() or not flight.has(key) or flight[key] == null:
		return 0.0
	return max(float(flight[key]), 0.0)

# One straight flight, z = 0 .. fD, y = 0 .. fH, centred on X.
# mats3 = [sides, top, bottom]; box faces use [+X,-X,+Y,-Y,+Z,-Z] =
# [sides, sides, top, bottom, top, bottom], as the editor's matArrBox.
func _build_stair_flight(step_count: int, step_h: float, step_d: float, fw: float, fh: float, fd: float, bottom_type: String, mats3: Array) -> Node3D:
	var fg = Node3D.new()
	fg.name = "Flight"
	var acc = _mesh_acc()
	if bottom_type == "flat":
		var L = sqrt(fd * fd + fh * fh)
		var soffit_t = max(step_h * 0.6, 0.002)
		var back_clip_x = min(fd, soffit_t * L / max(fh, 1e-6))
		var front_clip_y = max(0.0, fh - soffit_t * L / max(fd, 1e-6))
		var pts = PackedVector2Array()
		pts.append(Vector2(0, 0))
		for i in range(step_count):
			var rise_y = (i + 1) * step_h
			var tread_x = (i + 1) * step_d
			pts.append(Vector2(i * step_d, rise_y))
			pts.append(Vector2(tread_x, rise_y))
		pts.append(Vector2(fd, front_clip_y))
		pts.append(Vector2(back_clip_x, 0))
		_emit_side_profile_prism(acc, pts, fw, 1.0, 0.0, mats3)
	else:
		var nosing = step_d * 0.1
		var box_mats = [mats3[0], mats3[0], mats3[1], mats3[2], mats3[1], mats3[2]]
		for i in range(step_count):
			var is_last = i == step_count - 1
			var actual_d = step_d if is_last else step_d + nosing
			_emit_box(acc, Vector3(fw, step_h, actual_d), Vector3(0, i * step_h + step_h / 2.0, i * step_d + actual_d / 2.0), box_mats)
	_mesh_commit(acc, fg, "Staircase")
	return fg

func _build_stair_landing(lw: float, ld: float, lh: float, lmats6: Array) -> Node3D:
	var holder = Node3D.new()
	holder.name = "Landing"
	var acc = _mesh_acc()
	_emit_box(acc, Vector3(lw, lh, ld), Vector3.ZERO, lmats6)
	_mesh_commit(acc, holder, "Staircase")
	return holder

func _add_staircase_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, _mat_data: Dictionary) -> void:
	var props = structure.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		props = {}
	var stair = props.get("stair", {})
	if typeof(stair) != TYPE_DICTIONARY:
		stair = {}
	var stair_type = str(stair.get("stair_type", "straight")).to_lower()
	if stair_type == "" or stair_type == "null":
		stair_type = "straight"
	var is_multi = stair_type in ["l_shaped", "u_shaped", "winder"]
	var flights = stair.get("flights", [])
	var f1 = _flight_dict(flights, 0)
	var f2 = _flight_dict(flights, 1)
	var f1_count = _flight_count(f1)
	var f2_count = _flight_count(f2)
	var step_count = f1_count + f2_count if is_multi else f1_count
	var bottom_type = str(stair.get("bottom_type", "stepped")).to_lower()
	var turn_sign = -1.0 if str(stair.get("turn_direction", "")).to_lower() == "right" else 1.0

	var unit = main_script._scene_unit_scale
	var riser = _flight_positive(f1, "riser_height") * unit
	var tread = _flight_positive(f1, "tread_depth") * unit
	var eff_h = step_count * riser if riser > 0.0 else height
	var eff_d = step_count * tread if tread > 0.0 else depth
	var step_h = eff_h / float(step_count)
	var step_d = eff_d / float(step_count)
	var w = width

	var sides = _struct_mat(structure, "StaircaseSides")
	var top = _struct_mat(structure, "StaircaseTop")
	var bottom = _struct_mat(structure, "StaircaseBottom")
	var mats3 = [sides, top, bottom]
	var l_sides = _struct_mat(structure, "LandingSides")
	var lmats6 = [l_sides, l_sides, _struct_mat(structure, "LandingTop"), _struct_mat(structure, "LandingBottom"), l_sides, l_sides]

	var gap = _flight_positive(f1, "landing_length") * unit
	var landing_depth_set = _flight_positive(f1, "landing_depth") * unit

	if stair_type == "straight":
		var fg = _build_stair_flight(f1_count, step_h, step_d, w, eff_h, eff_d, bottom_type, mats3)
		fg.position.z = -eff_d / 2.0
		parent.add_child(fg)
	elif stair_type == "l_shaped":
		var f1h = f1_count * step_h
		var f1d = f1_count * step_d
		var land_len = landing_depth_set if landing_depth_set > 0.0 else (w + gap)
		var center_z = eff_d / 2.0
		var fg1 = _build_stair_flight(f1_count, step_h, step_d, w, f1h, f1d, bottom_type, mats3)
		fg1.position = Vector3(0, 0, -center_z)
		parent.add_child(fg1)
		var landing = _build_stair_landing(w, land_len, step_h, lmats6)
		landing.position = Vector3(0, f1h - step_h / 2.0, f1d + land_len / 2.0 - center_z)
		parent.add_child(landing)
		var fg2 = _build_stair_flight(f2_count, step_h, step_d, w, f2_count * step_h, f2_count * step_d, bottom_type, mats3)
		fg2.rotation.y = turn_sign * (PI / 2.0)
		fg2.position = Vector3(turn_sign * w / 2.0, f1h, f1d + land_len - w / 2.0 - center_z)
		parent.add_child(fg2)
	elif stair_type == "u_shaped":
		var f1h_u = f1_count * step_h
		var f1d_u = f1_count * step_d
		var f2d_u = f2_count * step_d
		var land_width = w * 2.0 + gap
		var land_len_u = landing_depth_set if landing_depth_set > 0.0 else w
		var z_offset = max(0.0, f2d_u - f1d_u)
		var center_z_u = eff_d / 2.0 + z_offset
		var fg1_u = _build_stair_flight(f1_count, step_h, step_d, w, f1h_u, f1d_u, bottom_type, mats3)
		fg1_u.position = Vector3(0, 0, z_offset - center_z_u)
		parent.add_child(fg1_u)
		var landing_u = _build_stair_landing(land_width, land_len_u, step_h, lmats6)
		landing_u.position = Vector3(turn_sign * (w + gap) / 2.0, f1h_u - step_h / 2.0, z_offset + f1d_u + land_len_u / 2.0 - center_z_u)
		parent.add_child(landing_u)
		var fg2_u = _build_stair_flight(f2_count, step_h, step_d, w, f2_count * step_h, f2d_u, bottom_type, mats3)
		fg2_u.rotation.y = PI
		fg2_u.position = Vector3(turn_sign * (w + gap), f1h_u, z_offset + f1d_u - center_z_u)
		parent.add_child(fg2_u)
	elif stair_type == "winder":
		# Both flights are counted in step_count, so the editor's winder count
		# max(1, step_count - f1 - f2) is always one quarter-turn tread.
		var winder_count = max(1, step_count - f1_count - f2_count)
		var f1h_w = f1_count * step_h
		var f1d_w = f1_count * step_d
		var center_z_w = eff_d / 2.0
		var f2x = turn_sign * w / 2.0
		var fg1_w = _build_stair_flight(f1_count, step_h, step_d, w, f1h_w, f1d_w, bottom_type, mats3)
		fg1_w.position = Vector3(0, 0, -center_z_w)
		parent.add_child(fg1_w)
		var winder_r = w
		var winder_angle = (PI / 2.0) / float(winder_count)
		for i in range(winder_count):
			var a0 = i * winder_angle
			var a1 = (i + 1) * winder_angle
			# Editor pie in its shape plane is (-ts*R*cos a, -R*sin a); after
			# rotateX(-PI/2) that lands on plan (x, z) = (-ts*R*cos a, R*sin a).
			var pie = PackedVector2Array()
			pie.append(Vector2(0, 0))
			for s in range(5):
				var a = a0 + (a1 - a0) * (float(s) / 4.0)
				pie.append(Vector2(-turn_sign * winder_r * cos(a), winder_r * sin(a)))
			var holder = Node3D.new()
			holder.name = "Winder"
			holder.position = Vector3(f2x, f1h_w + i * step_h, f1d_w - center_z_w)
			var acc_w = _mesh_acc()
			_emit_vertical_prism(acc_w, pie, 0.0, step_h, mats3)
			_mesh_commit(acc_w, holder, "Staircase")
			parent.add_child(holder)
		var winder_top_y = f1h_w + winder_count * step_h
		var fg2_w = _build_stair_flight(f2_count, step_h, step_d, w, f2_count * step_h, f2_count * step_d, bottom_type, mats3)
		fg2_w.rotation.y = turn_sign * (PI / 2.0)
		fg2_w.position = Vector3(f2x, winder_top_y, f1d_w + w / 2.0 - center_z_w)
		parent.add_child(fg2_w)
	else:
		# 'custom' stairs are solved by the editor's customStairEngine, which
		# has no port here yet. Nothing is drawn rather than a wrong stair.
		print("[Structure] staircase type '%s' is not supported by the renderer; skipped (%s)" % [stair_type, str(structure.get("id", ""))])

func _add_floor_opening_frame(parent: Node3D, structure: Dictionary, width: float, depth: float, mat_data: Dictionary) -> void:
	var frame = max(min(width, depth) * 0.08, 0.04)
	var frame_h = 0.04
	var slab_y = frame_h * 0.5
	_add_box_part(parent, Vector3(width + frame * 2.0, frame_h, frame), mat_data, Vector3(0, slab_y, depth * 0.5 + frame * 0.5))
	_add_box_part(parent, Vector3(width + frame * 2.0, frame_h, frame), mat_data, Vector3(0, slab_y, -depth * 0.5 - frame * 0.5))
	_add_box_part(parent, Vector3(frame, frame_h, depth), mat_data, Vector3(width * 0.5 + frame * 0.5, slab_y, 0))
	_add_box_part(parent, Vector3(frame, frame_h, depth), mat_data, Vector3(-width * 0.5 - frame * 0.5, slab_y, 0))

func _add_floor_opening_cutters(csg: CSGCombiner3D, structures, area_id: String, layer_altitude: float, cut_height: float, scale_factor: float) -> void:
	if typeof(structures) != TYPE_DICTIONARY:
		return

	for structure_id in structures:
		var structure = structures[structure_id]
		if typeof(structure) != TYPE_DICTIONARY:
			continue
		if str(structure.get("structure_type", "")).to_lower() != "flooropening":
			continue
		if structure.has("parentId") and str(structure["parentId"]) != area_id:
			continue

		var props = {}
		if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
			props = structure["properties"]

		var width = main_script.get_dimension_value(props.get("width", structure.get("width", 100))) * scale_factor
		var depth = main_script.get_dimension_value(props.get("depth", structure.get("depth", 100))) * scale_factor
		var altitude = main_script.get_dimension_value(props.get("altitude", structure.get("altitude", 0))) * scale_factor
		var opening_xy = main_script._plan_point_2d(float(structure.get("x", 0)), float(structure.get("y", 0)))
		var opening = CSGBox3D.new()
		opening.operation = CSGBox3D.OPERATION_SUBTRACTION
		opening.size = Vector3(max(width, 0.05), max(cut_height, 0.2), max(depth, 0.05))
		opening.position = Vector3(
			opening_xy.x * scale_factor,
			layer_altitude + altitude - max(cut_height, 0.2) * 0.5,
			opening_xy.y * scale_factor
		)
		csg.add_child(opening)

# ==============================================================================
# ASSET LOADING AND PLACEMENT
# ==============================================================================
# WHY IT EXISTS: To read the items array from the JSON layout, dynamically 
# download the 3D GLB models for furniture, appliances, and decorations, and 
# place them at exact coordinates inside the 3D rooms.
# ==============================================================================