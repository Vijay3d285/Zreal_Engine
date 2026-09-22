extends SceneTree

# Preloaded, not a global class name: the live pipeline has no class cache.
const GlbCreation = preload("res://image_glb_creation.gd")

## Headless unit checks for the GlassFix auto-smooth step
## (image_glb_creation.gd :: _autosmooth_surface_arrays).
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/glb_autosmooth_unit.gd
##
## A1-A3: a smooth-shaded cube comes out with six axis-aligned normals and 24
##        vertices, every attribute following the split.
## B1-B2: a 64-segment cylinder wall (5.6 deg dihedral) is left smooth: the
##        normals move by under 0.5 deg, the vertex count does not grow.
## C1-C3: the real aquarium's Glass surface: normals corrected by >= 20 deg,
##        every big pane ends up with the geometric normal, Water untouched.

const AQUARIUM := "C:/Zlendo2026/ZlenderRender_stage_copy/asset_downloads/2b030deb_MarineDecorativeGlassAquarium_HP_high.glb"

var _failures: Array[String] = []
var _checks := 0


func _check_true(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	_checks += 1
	if p_ok:
		print("  PASS %s %s" % [p_name, p_detail])
	else:
		_failures.append(p_name)
		print("  FAIL %s %s" % [p_name, p_detail])


func _smooth_cube_arrays() -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(0)
	var box := BoxMesh.new()
	box.size = Vector3(2, 1, 0.5)
	var src: Array = box.get_mesh_arrays()
	# Re-index by welded position so every corner is shared and the normals
	# come out corner-averaged, the way the libraries export their tanks.
	var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = src[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX]
	var ids := {}
	var welded := PackedInt32Array()
	welded.resize(verts.size())
	for v in range(verts.size()):
		var k := Vector3i(verts[v] * 1000.0)
		if not ids.has(k):
			ids[k] = ids.size()
			st.set_uv(uvs[v])
			st.add_vertex(verts[v])
		welded[v] = ids[k]
	for i in idx:
		st.add_index(welded[i])
	st.generate_normals()
	return st.commit_to_arrays()


func _cylinder_wall_arrays(p_segments: int) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in range(p_segments):
		var a := TAU * float(s) / float(p_segments)
		var n := Vector3(cos(a), 0.0, sin(a))
		st.set_normal(n)
		st.set_uv(Vector2(float(s) / p_segments, 0.0))
		st.add_vertex(n)
		st.set_normal(n)
		st.set_uv(Vector2(float(s) / p_segments, 1.0))
		st.add_vertex(n + Vector3.UP)
	for s in range(p_segments):
		var a := s * 2
		var b := ((s + 1) % p_segments) * 2
		st.add_index(a)
		st.add_index(b)
		st.add_index(a + 1)
		st.add_index(b)
		st.add_index(b + 1)
		st.add_index(a + 1)
	return st.commit_to_arrays()


func _geometric_deviation_deg(p_arrays: Array) -> Dictionary:
	# Area-weighted mean and max angle between each corner's vertex normal and
	# its face's geometric normal.
	var verts: PackedVector3Array = p_arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = p_arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = p_arrays[Mesh.ARRAY_INDEX]
	var acc := 0.0
	var wsum := 0.0
	var worst := 0.0
	var worst_face := {}
	var per_face := [] # [area, max corner deviation]
	for f in range(idx.size() / 3):
		var a := verts[idx[f * 3]]
		var b := verts[idx[f * 3 + 1]]
		var c := verts[idx[f * 3 + 2]]
		var fn := (c - a).cross(b - a) # Godot front faces wind clockwise
		var w := fn.length()
		if w <= 0.0:
			continue
		fn /= w
		var face_worst := 0.0
		for k in range(3):
			var d := rad_to_deg(acos(clampf(normals[idx[f * 3 + k]].normalized().dot(fn), -1.0, 1.0)))
			acc += d * w
			wsum += w
			face_worst = maxf(face_worst, d)
			if d > worst:
				worst = d
				worst_face = {"area": w / 2.0, "normal": fn, "centroid": (a + b + c) / 3.0, "vertex_normal": normals[idx[f * 3 + k]]}
		per_face.append([w / 2.0, face_worst])
	# Max over faces carrying at least 1% of the surface's area: a bevel sliver
	# under the auto-smooth angle legitimately keeps a blended normal.
	var total := wsum / 2.0 / 3.0
	var worst_big := 0.0
	for pf in per_face:
		if pf[0] >= 0.01 * total:
			worst_big = maxf(worst_big, pf[1])
	return {"mean": acc / maxf(wsum, 1e-12), "max": worst, "max_big": worst_big, "worst_face": worst_face}


func _init() -> void:
	print("\n=== glb_autosmooth_unit: smooth-shaded cube ===")
	var cube := _smooth_cube_arrays()
	var before := _geometric_deviation_deg(cube)
	print("  cube before: mean %.1f deg, max %.1f deg, %d verts" % [before["mean"], before["max"], cube[Mesh.ARRAY_VERTEX].size()])
	_check_true("A0 fixture is smooth-shaded", before["max"] > 30.0, "(max %.1f)" % before["max"])
	var res: Dictionary = GlbCreation._autosmooth_surface_arrays(cube, 30.0)
	var out: Array = res["arrays"]
	var after := _geometric_deviation_deg(out)
	_check_true("A1 every normal is the face normal", after["max"] < 0.01, "(max %.4f deg)" % after["max"])
	_check_true("A2 24 vertices (6 faces x 4)", out[Mesh.ARRAY_VERTEX].size() == 24, "(%d)" % out[Mesh.ARRAY_VERTEX].size())
	_check_true("A3 uv array follows the split", out[Mesh.ARRAY_TEX_UV].size() == 24, "(%d)" % out[Mesh.ARRAY_TEX_UV].size())
	_check_true("A4 index count unchanged", out[Mesh.ARRAY_INDEX].size() == cube[Mesh.ARRAY_INDEX].size())
	_check_true("A5 reported correction matches the fixture's max deviation", absf(res["max_correction_deg"] - before["max"]) < 0.01, "(%.2f vs %.2f)" % [res["max_correction_deg"], before["max"]])

	print("\n=== glb_autosmooth_unit: 64-segment cylinder wall ===")
	var cyl := _cylinder_wall_arrays(64)
	var cres: Dictionary = GlbCreation._autosmooth_surface_arrays(cyl, 30.0)
	var cout: Array = cres["arrays"]
	_check_true("B1 normals left smooth (< 0.5 deg)", cres["max_correction_deg"] < 0.5, "(%.3f deg)" % cres["max_correction_deg"])
	_check_true("B2 vertex count unchanged", cout[Mesh.ARRAY_VERTEX].size() == cyl[Mesh.ARRAY_VERTEX].size(), "(%d -> %d)" % [cyl[Mesh.ARRAY_VERTEX].size(), cout[Mesh.ARRAY_VERTEX].size()])

	print("\n=== glb_autosmooth_unit: aquarium Glass surface ===")
	if FileAccess.file_exists(AQUARIUM):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(AQUARIUM, state) == OK:
			var root := doc.generate_scene(state)
			var found := false
			for m in _all_meshes(root):
				if m.mesh == null:
					continue
				for i in range(m.mesh.get_surface_count()):
					var mat = m.mesh.surface_get_material(i)
					var mname := str(mat.resource_name) if mat else ""
					if mname != "Glass":
						continue
					found = true
					var arr: Array = m.mesh.surface_get_arrays(i)
					var b := _geometric_deviation_deg(arr)
					var r: Dictionary = GlbCreation._autosmooth_surface_arrays(arr, 30.0)
					var a := _geometric_deviation_deg(r["arrays"])
					print("  Glass: %d tris, deviation mean %.1f max %.1f deg -> mean %.2f max %.2f deg; corrected up to %.1f deg" % [arr[Mesh.ARRAY_INDEX].size() / 3, b["mean"], b["max"], a["mean"], a["max"], r["max_correction_deg"]])
					print("  worst remaining face: ", a["worst_face"])
					_check_true("C1 authored normals off by >= 20 deg somewhere", b["max"] >= 20.0)
					_check_true("C2 every pane >= 1%% of the area is flat (< 0.5 deg)", a["max_big"] < 0.5, "(%.3f)" % a["max_big"])
					_check_true("C2b area-weighted mean deviation < 0.5 deg", a["mean"] < 0.5, "(%.3f)" % a["mean"])
					_check_true("C3 correction reported >= 20 deg", r["max_correction_deg"] >= 20.0)
			_check_true("C0 Glass surface found", found)

			print("\n=== glb_autosmooth_unit: _convert_glb_alpha_glass end to end ===")
			var twin := root.duplicate() # shares the Mesh resources, as _glb_cache duplicates do
			var glb = GlbCreation.new()
			glb._convert_glb_alpha_glass(root, "aquarium")
			var meshes_a := _all_meshes(root)
			var meshes_b := _all_meshes(twin)
			for i in range(meshes_a.size()):
				var m: MeshInstance3D = meshes_a[i]
				var t: MeshInstance3D = meshes_b[i]
				if m.mesh == null:
					continue
				var glass_i := -1
				for s in range(m.mesh.get_surface_count()):
					if m.mesh.surface_get_name(s) == "Glass":
						glass_i = s
				if glass_i < 0:
					continue
				_check_true("D1 mesh was replaced on the converted instance", m.mesh != t.mesh)
				_check_true("D2 surface count preserved", m.mesh.get_surface_count() == t.mesh.get_surface_count())
				var names_ok := true
				var mats_ok := true
				for s in range(m.mesh.get_surface_count()):
					names_ok = names_ok and m.mesh.surface_get_name(s) == t.mesh.surface_get_name(s)
					mats_ok = mats_ok and m.mesh.surface_get_material(s) == t.mesh.surface_get_material(s)
				_check_true("D3 surface names preserved in order", names_ok)
				_check_true("D4 surface materials preserved in order", mats_ok)
				var ov = m.get_surface_override_material(glass_i)
				_check_true("D5 Glass override is the converted dielectric", ov != null and ov.transmission == 1.0 and ov.ior == 1.5)
				var dev := _geometric_deviation_deg(m.mesh.surface_get_arrays(glass_i))
				_check_true("D6 rebuilt Glass panes are flat", dev["max_big"] < 0.5, "(%.3f)" % dev["max_big"])
				var water_i := -1
				for s in range(m.mesh.get_surface_count()):
					if m.mesh.surface_get_name(s) == "Water":
						water_i = s
				if water_i >= 0:
					var wa: Array = m.mesh.surface_get_arrays(water_i)
					var wb: Array = t.mesh.surface_get_arrays(water_i)
					# Normals are re-encoded octahedral 16-bit on every surface add,
					# so compare within that quantisation, not bit-exactly.
					var same: bool = wa[Mesh.ARRAY_VERTEX] == wb[Mesh.ARRAY_VERTEX] and wa[Mesh.ARRAY_NORMAL].size() == wb[Mesh.ARRAY_NORMAL].size()
					var worst_n := 0.0
					if same:
						for v in range(wa[Mesh.ARRAY_NORMAL].size()):
							worst_n = maxf(worst_n, rad_to_deg(wa[Mesh.ARRAY_NORMAL][v].angle_to(wb[Mesh.ARRAY_NORMAL][v])))
					_check_true("D7 Water surface untouched (vertices exact, normals < 0.1 deg)", same and worst_n < 0.1, "(%.4f deg)" % worst_n)
				var rebuilt = m.mesh
				glb._convert_glb_alpha_glass(twin, "aquarium (duplicate)")
				_check_true("D8 duplicate instance receives the cached rebuild", t.mesh == rebuilt)
			# Flush the dirty instances while their override materials are still
			# alive; freeing a dirty MeshInstance3D re-binds materials the node
			# has already released (a harmless "Parameter material is null").
			RenderingServer.force_draw(false)
			glb.free()
			twin.free()
			root.free()
		else:
			_check_true("C0 aquarium GLB loads", false)
	else:
		print("  SKIP: %s not present" % AQUARIUM)

	print("\n%d checks, %d failed%s" % [_checks, _failures.size(), "" if _failures.is_empty() else ": " + ", ".join(_failures)])
	quit(0 if _failures.is_empty() else 1)


func _all_meshes(p_node: Node) -> Array:
	var out := []
	if p_node is MeshInstance3D:
		out.append(p_node)
	for c in p_node.get_children():
		out.append_array(_all_meshes(c))
	return out
