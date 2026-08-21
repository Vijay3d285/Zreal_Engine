extends "res://tests/pt_validation.gd"

## E1 Task 8, spec §7.3 / §8.1: the Cycles reference comparison harness.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transmission_reference_scene.tscn
##
## Renders a glass slab (WHITE, undyed) and a glass vase (deliberately TINTED
## -- non-white specular_tint AND non-white attenuation_color, per spec §7.3)
## on a grey ground plane, under one shared equirect HDRI, to a linear EXR via
## the Phase A2 path (Image.save_exr()). A companion Blender/Cycles script
## renders the SAME geometry (matched by explicit numeric transform, see the
## coordinate-mapping note below) under the SAME HDRI file to a second EXR.
## Comparison (per-channel MSE + a box-filter SSIM) is done by a third,
## Blender-headless numpy script, because neither this engine's Python nor
## its GDScript has an EXR reader outside this engine itself -- see
## task-8-report.md for why the comparison could not be done in-engine.
##
## COORDINATE MAPPING (Godot Y-up -> Blender Z-up, the same convention
## Blender's own glTF importer applies): blender(x, y, z) = godot(x, -z, y).
## Every position/size below is quoted in BOTH systems in this file's
## comments so the companion Blender script (kept outside the repo per the
## brief -- see task-8-report.md) can be verified against it by inspection.
##
## Env vars:
##   ZR_TRANSREF_RES        square render resolution        (default 320)
##   ZR_TRANSREF_FRAMES     accumulated frames               (default 1024)
##   ZR_TRANSREF_OUT        output EXR path                  (default user://pt_transmission_reference.exr)
##   ZR_TRANSREF_PANORAMA   ABSOLUTE path to the shared HDRI EXR (required for
##                          a meaningful comparison -- see _load_shared_sky).

var _res := 320
var _frames := 1024


func _ready() -> void:
	var r_env := OS.get_environment("ZR_TRANSREF_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var f_env := OS.get_environment("ZR_TRANSREF_FRAMES")
	if f_env.is_valid_int():
		_frames = maxi(16, f_env.to_int())

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(1.0).timeout

	print("\n=== E1 Cycles reference render (tag 'ours') ===")
	print("resolution: %dx%d, accumulated frames: %d" % [_res, _res, _frames])

	var t0 := Time.get_ticks_msec()
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), _frames)
	var ms := Time.get_ticks_msec() - t0
	if img == null:
		print("FAIL - accumulator readback returned null")
		get_tree().quit(1)
		return

	print("render wall clock : %d ms" % ms)
	print("mean_luma          : %.6f" % mean_luma(img))

	var out_path := "user://pt_transmission_reference.exr"
	var o_env := OS.get_environment("ZR_TRANSREF_OUT")
	if o_env != "":
		out_path = o_env
	var err: int = img.save_exr(out_path, false)
	if err == OK:
		print("EXR written to      : %s" % ProjectSettings.globalize_path(out_path))
	else:
		print("FAIL - save_exr returned error %d for %s" % [err, out_path])
		get_tree().quit(1)
		return

	print("\n=== DONE ===")
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# Scene. Every transform is quoted in Godot units in the comment beside it;
# the Blender-side mirror applies blender(x,y,z) = godot(x,-z,y) verbatim.
# ---------------------------------------------------------------------------
func _build_scene() -> Environment:
	var env := _load_shared_sky()

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(8)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Camera: godot pos (0, 1.7, 5.4) looking at (0, 0.65, 0), fov 40 (vertical,
	# Camera3D's default keep_aspect = KEEP_HEIGHT). Blender mirror: pos
	# (0, -5.4, 1.7) looking at (0, 0, 0.65), sensor_fit VERTICAL, angle=radians(40).
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.7, 5.4)
	cam.fov = 40.0
	add_child(cam)
	cam.make_current()
	cam.look_at(Vector3(0.0, 0.65, 0.0), Vector3.UP)

	# Ground: godot BoxMesh size (10, 0.2, 10) at (0, -0.1, 0).
	# Blender mirror: cube dims (10, 10, 0.2) at (0, 0, -0.1).
	_add_box(Vector3(0, -0.1, 0), Vector3(10, 0.2, 10), Color(0.55, 0.55, 0.55))

	# Glass slab (WHITE, undyed): godot BoxMesh size (1.6, 1.2, 0.25) at
	# (-1.4, 0.65, 0). Blender mirror: cube dims (1.6, 0.25, 1.2) at (-1.4, 0, 0.65).
	var slab := MeshInstance3D.new()
	var slab_mesh := BoxMesh.new()
	slab_mesh.size = Vector3(1.6, 1.2, 0.25)
	slab.mesh = slab_mesh
	slab.position = Vector3(-1.4, 0.65, 0.0)
	slab.material_override = _white_glass()
	add_child(slab)

	# Glass vase (TINTED -- non-white specular_tint AND non-white
	# attenuation_color, spec §7.3): godot CylinderMesh top_radius 0.22,
	# bottom_radius 0.55, height 1.3, at (1.5, 0.65, 0). Blender mirror: a cone
	# (bmesh.ops.create_cone, radius1=0.55, radius2=0.22, depth=1.3) at
	# (1.5, 0, 0.65).
	var vase := MeshInstance3D.new()
	var vase_mesh := CylinderMesh.new()
	vase_mesh.top_radius = 0.22
	vase_mesh.bottom_radius = 0.55
	vase_mesh.height = 1.3
	vase_mesh.radial_segments = 48
	vase.mesh = vase_mesh
	vase.position = Vector3(1.5, 0.65, 0.0)
	vase.material_override = _tinted_glass()
	add_child(vase)

	return env


## specular_tint white, attenuation_color white -- an undyed control sample.
func _white_glass() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.metallic = 0.0
	mat.roughness = 0.0
	mat.transmission = 1.0
	mat.ior = 1.5
	mat.thickness = 0.25
	mat.attenuation_color = Color(1, 1, 1)
	mat.attenuation_distance = 5.0 # irrelevant at white -- sigma = (1-1)*density = 0.
	mat.specular_tint = Color(1, 1, 1)
	mat.specular_factor = 1.0
	return mat


## Deliberately tinted per spec §7.3: specular_tint (0.75, 0.55, 1.0) -- a
## saturated purple -- AND attenuation_color (0.15, 0.85, 0.35) -- a saturated
## green -- both non-white, both live at once. This is the ONLY fixture in
## this comparison able to reveal §4.2's tinted-transmittance behaviour and
## §6.4's NEE/BSDF Fresnel mismatch; a white-glass-only comparison would pass
## while both are wrong (spec §7.3, verbatim).
func _tinted_glass() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.metallic = 0.0
	mat.roughness = 0.06 # slightly rough -- exercises §6.3's single-scatter dimming.
	mat.transmission = 1.0
	mat.ior = 1.45
	mat.thickness = 0.35
	mat.attenuation_color = Color(0.15, 0.85, 0.35)
	mat.attenuation_distance = 0.8 # density = 1/0.8 = 1.25.
	mat.specular_tint = Color(0.75, 0.55, 1.0)
	mat.specular_factor = 0.75
	return mat


func _add_box(p_pos: Vector3, p_size: Vector3, p_col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = p_size
	mi.mesh = bm
	mi.position = p_pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_col
	mat.roughness = 1.0
	mat.metallic = 0.0
	mi.material_override = mat
	add_child(mi)


## Loads the shared HDRI baked by the companion generator script
## (gen_panorama.py, kept outside the repo -- see task-8-report.md) so this
## engine and the Cycles reference consume literally the same environment
## texture rather than two independently-authored approximations of it.
## Falls back to a flat grey sky (documented, NOT matched to Cycles) if the
## env var is unset or the file cannot be read, so this scene still runs
## standalone for smoke-testing -- but a fallback run is NOT a valid Cycles
## comparison and must not be reported as one.
func _load_shared_sky() -> Environment:
	var pano_tex: ImageTexture = null
	var p_env := OS.get_environment("ZR_TRANSREF_PANORAMA")
	if p_env != "":
		var img := Image.new()
		var err := img.load(p_env)
		if err == OK:
			pano_tex = ImageTexture.create_from_image(img)
			print("shared HDRI loaded  : %s (%dx%d)" % [p_env, img.get_width(), img.get_height()])
		else:
			push_warning("ZR_TRANSREF_PANORAMA set but failed to load (err %d): %s" % [err, p_env])

	var sky_mat := PanoramaSkyMaterial.new()
	if pano_tex != null:
		sky_mat.panorama = pano_tex
	else:
		print("WARNING: no shared HDRI -- using an UNMATCHED flat grey fallback. This run is NOT a valid Cycles comparison.")
		var fallback := Image.create(8, 4, false, Image.FORMAT_RGBF)
		fallback.fill(Color(0.06, 0.06, 0.07))
		sky_mat.panorama = ImageTexture.create_from_image(fallback)
	sky_mat.energy_multiplier = 1.0

	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY # BG_COLOR does not reach the tracer -- roadmap F3.
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env
