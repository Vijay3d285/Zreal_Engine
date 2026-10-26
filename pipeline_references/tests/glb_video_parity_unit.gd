extends SceneTree

# Preloaded, not global class names: the live pipeline has no class cache.
const ImageGlb = preload("res://image_glb_creation.gd")
const VideoGlb = preload("res://video_glb_creation.gd")

## Headless checks that video_glb_creation.gd treats converted GLB glass as the still route does
## (2026-10-26): solid, index 1.5 (water 1.33), optically clear, and an auto-smooth that never
## swaps in a mesh which lost its geometry. Every check runs against BOTH scripts.
##
## Run it from a copy of pipeline_references WITHOUT .godot/:
##   bin\godot.windows.editor.x86_64.console.exe --headless --path <copy> -s res://tests/glb_video_parity_unit.gd

var _failures: Array[String] = []
var _checks := 0
var _label := ""


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	var name := "[%s] %s" % [_label, p_name]
	print("  %s: %s %s" % [name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
		_failures.append("%s %s" % [name, p_detail])


## A smooth-shaded unit cube (8 shared corners, diagonal normals) carrying a CUSTOM0 channel,
## like a GLB's TEXCOORD_2: auto-smooth must split its corners, and the rebuild must keep the
## custom channel's format or Godot rejects the surface.
func _custom_channel_cube() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# RG_FLOAT, as a GLB TEXCOORD_2 imports: a float custom array whose component count only the
	# format flags carry (an RGBA8 channel would be inferred and pass either way).
	st.set_custom_format(0, SurfaceTool.CUSTOM_RG_FLOAT)
	for i in 8:
		var p := Vector3(float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1))
		st.set_normal((p - Vector3(0.5, 0.5, 0.5)).normalized())
		st.set_custom(0, Color(p.x, p.y, 0.0, 0.0))
		st.add_vertex(p)
	for f in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
		st.add_index(f[0])
		st.add_index(f[1])
		st.add_index(f[2])
		st.add_index(f[0])
		st.add_index(f[2])
		st.add_index(f[3])
	var mesh := st.commit()
	mesh.resource_name = "custom_channel_cube"
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _suite(glb, p_label: String) -> void:
	_label = p_label
	print("\n=== glb_video_parity [%s]: converted glass ===" % p_label)
	var glass := StandardMaterial3D.new()
	glass.roughness = 0.08
	glass.roughness_texture = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	glb._apply_glb_transmissive_glass(glass, "glass")
	_check_true("G1 glass index 1.5", is_equal_approx(glass.ior, 1.5), "(%.2f)" % glass.ior)
	_check_true("G2 glass is solid (thickness > 0)", glass.thickness > 0.0, "(%.3f)" % glass.thickness)
	_check_true("G3 glass is optically clear", glass.roughness == 0.0 and glass.roughness_texture == null,
			"(roughness %.2f, texture %s)" % [glass.roughness, "kept" if glass.roughness_texture != null else "dropped"])
	_check_true("G4 glass transmits", glass.transmission == 1.0)
	var water := StandardMaterial3D.new()
	glb._apply_glb_transmissive_glass(water, "water")
	_check_true("G5 water index 1.33", is_equal_approx(water.ior, 1.33), "(%.2f)" % water.ior)
	# Tinted, alpha-blended white-metal "glass", the way these libraries author panes and vases
	# (alpha ~0.1, metallic 1, a colour tint): stills convert glass ALWAYS (2026-09-15).
	var tinted := StandardMaterial3D.new()
	tinted.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tinted.albedo_color = Color(0.55, 0.75, 0.70, 0.1)
	tinted.metallic = 1.0
	tinted.roughness = 0.08
	_check_true("G6 tinted glass is converted, not kept as alpha", not glb._glb_alpha_kind_keeps_alpha(tinted, "glass"))
	_check_true("G7 water keeps its alpha (GLB_WATER_KEEPS_ALPHA)", glb._glb_alpha_kind_keeps_alpha(tinted, "water") == glb.GLB_WATER_KEEPS_ALPHA)

	print("\n=== glb_video_parity [%s]: auto-smooth keeps geometry ===" % p_label)
	var cube := _custom_channel_cube()
	glb._autosmooth_converted_surfaces(cube, [0])
	var n_surf: int = cube.mesh.get_surface_count() if cube.mesh != null else 0
	_check_true("A1 a mesh with a custom channel keeps its surface", n_surf == 1, "(%d surfaces)" % n_surf)
	_check_true("A2 and its vertices", n_surf == 1 and cube.mesh.surface_get_array_len(0) > 0)
	cube.free()
	glb.free()


func _init() -> void:
	_suite(ImageGlb.new(), "stills")
	_suite(VideoGlb.new(), "video")
	print("")
	if _failures.is_empty():
		print("PASS: all %d parity checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		quit(1)
