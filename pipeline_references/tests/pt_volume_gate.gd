extends "res://tests/pt_validation.gd"

## Volumetrics gate (spec 2026-09-17-volumetrics-design.md, roadmap F2 / Gap #16).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_volume_gate_scene.tscn
##
## The Environment's volumetric fog is a bounded homogeneous medium in the
## tracer: sigma_t = density per metre, sigma_s = density * albedo, g =
## anisotropy, on the scene's own bounding box, Cycles' single-scatter default.
## The box is the union of ALL geometry, so every fixture pins it to
## [-1,1] x [0,2] x [-1,1] with eight 1 cm black corner posts and keeps every
## surface 1 mm inside a face of that box (coplanar with the face, Cycles'
## surface-less volume cube wins the intersection and the surface is never
## hit). Camera at (0, 1, 4) looking at (0, 0.4, 0), 30 deg vertical FOV: the
## floor spans rows ~45-80 %, the fog above it reads against the sky.
## Cycles half: tools/cycles_comparison/cycles_volume_box.py.
##
## volumetric_fog_albedo / _emission are Color properties and sRGB-encoded;
## the raster converts with srgb_to_linear() (fog.cpp:1107,1113) and so does
## the tracer, so linear values are authored through linear_to_srgb() here.
##
## The analytic probes (V1, V2, V5) are evaluated PER PIXEL on the CPU from
## the camera's own rays and the same box (padded 1 cm as the engine pads it):
## the camera's path through the fog is part of every reading, and it differs
## across a crop (the floor rows sit ~0.9 m into the box, the back wall ~2 m).
##
##   V1 absorption : albedo 0, sigma_t 0.5, white emissive back wall, black
##                   world -> back crop with fog / without = mean exp(-sigma_t L_view)
##   V2 emission   : albedo 0, sigma_t 0.5, emission 1 energy 1, black world,
##                   black floor -> fog crop = mean E_eff (1 - e^(-sigma_t L)) / sigma_t,
##                   E_eff = colour x energy x density -- Godot's raster
##                   convention (volumetric_fog_process.glsl:393), which the
##                   tracer follows
##   V3 sun beam   : albedo 1, sigma_t 0.3, g 0.8, sun straight down, black
##                   world, white floor -> fog crop / floor crop vs Cycles
##   V4 sky haze   : albedo 1, sigma_t 0.3, g 0, uniform world 1, black floor
##                   -> fog crop vs Cycles
##   V5 shadowing  : albedo 0, sigma_t 0.5, sun straight down, white floor ->
##                   floor with fog / without = mean exp(-sigma_t L_view) x
##                   exp(-sigma_t L_sun), L_sun the climb from the floor to the
##                   box top
##   V6 (implicit) : fog off is compiled out -- pt_energy_gate and
##                   pt_light_energy_gate are unchanged to the digit.

var FRAMES: int = 256 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const TOL_ANALYTIC := 0.01
const BOX_PAD := 0.01 # the engine pads the scene AABB by 1 cm
const FLOOR_Y := 0.001
const WALL_Z := -0.999
var _cam: Camera3D
const BAR_CYCLES := 0.03
# Cycles 5.2.1, cycles_volume_box.py, 1024 spp, captured 2026-09-18 (Task 1 Step 2):
#   V3 fog 0.013223 floor 0.607924 ratio 0.021751; V4 fog 0.828252.
const CYCLES_V3_RATIO := 0.021751
const CYCLES_V4 := 0.828252

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== V1: absorption, emissive back wall ===")
	var v1_off := await _render({"fog": false, "back_wall": true, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v1_on := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "back_wall": true, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v1 := _crop(v1_on, 0.15, 0.45, 0.40, 0.60) / maxf(_crop(v1_off, 0.15, 0.45, 0.40, 0.60), 1e-9)
	_check("V1 absorption", v1, _expected(0.15, 0.45, 0.40, 0.60, 0.5, "wall_transmittance"), TOL_ANALYTIC)

	print("\n=== V2: emission ===")
	var v2_img := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "emission": 1.0, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v2 := _crop(v2_img, 0.10, 0.40, 0.30, 0.70)
	_check("V2 emission", v2, _expected(0.10, 0.40, 0.30, 0.70, 0.5, "emission"), TOL_ANALYTIC)

	print("\n=== V3: sun beam vs Cycles ===")
	var v3_img := await _render({"fog": true, "density": 0.3, "albedo": 1.0, "g": 0.8, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v3_fog := _crop(v3_img, 0.10, 0.40, 0.30, 0.70)
	var v3_floor := _crop(v3_img, 0.62, 0.80, 0.30, 0.70)
	print("  fog %.6f floor %.6f" % [v3_fog, v3_floor])
	_check_vs("V3 sun beam vs Cycles", v3_fog / maxf(v3_floor, 1e-9), CYCLES_V3_RATIO, BAR_CYCLES)

	print("\n=== V4: sky haze vs Cycles ===")
	var v4_img := await _render({"fog": true, "density": 0.3, "albedo": 1.0, "g": 0.0, "floor_albedo": 0.0, "world": 1.0, "sun": false})
	var v4 := _crop(v4_img, 0.10, 0.40, 0.30, 0.70)
	_check_vs("V4 sky haze vs Cycles", v4, CYCLES_V4, BAR_CYCLES)

	print("\n=== V5: surface shadowing through the box ===")
	var v5_off := await _render({"fog": false, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v5_on := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v5 := _crop(v5_on, 0.62, 0.80, 0.30, 0.70) / maxf(_crop(v5_off, 0.62, 0.80, 0.30, 0.70), 1e-9)
	_check("V5 surface shadowing", v5, _expected(0.62, 0.80, 0.30, 0.70, 0.5, "floor_shadowed"), TOL_ANALYTIC)

	print("")
	if _failures.is_empty():
		print("PASS: all %d volume checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs analytic %.6f (%+.2f%%, tol %.0f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs analytic %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_vs(p_name: String, p_value: float, p_ref: float, p_bar: float) -> void:
	_checks += 1
	if p_ref <= 0.0:
		_failures.append("%s: Cycles reference not captured (constant is %.6f)" % [p_name, p_ref])
		return
	var err := absf(p_value - p_ref) / p_ref
	print("  %s: %.6f vs Cycles %.6f  (%+.2f%%, bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * (p_value / p_ref - 1.0), 100.0 * p_bar])
	if err > p_bar:
		_failures.append("%s: %.6f vs Cycles %.6f, %.2f%% off (bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * err, 100.0 * p_bar])


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await get_tree().process_frame


func _lambert(p_albedo_linear: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo_linear, p_albedo_linear, p_albedo_linear).linear_to_srgb()
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	return m


## Builds the box fixture from a dictionary of options and returns the
## accumulated frame. Keys: fog (bool), density, albedo, g, emission,
## back_wall (bool), floor_albedo, world (uniform sky radiance), sun (bool).
func _render(p: Dictionary) -> Image:
	await _clear()
	var black := _lambert(0.0)
	for sx in [-1.0, 1.0]:
		for sy in [0.0, 2.0]:
			for sz in [-1.0, 1.0]:
				var post := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.01, 0.01, 0.01)
				post.mesh = bm
				post.position = Vector3(sx, sy, sz)
				post.material_override = black
				add_child(post)

	var floor_mi := MeshInstance3D.new()
	var fq := QuadMesh.new()
	fq.size = Vector2(2.0, 2.0)
	floor_mi.mesh = fq
	floor_mi.material_override = _lambert(float(p.get("floor_albedo", 0.0)))
	floor_mi.position = Vector3(0.0, 0.001, 0.0) # 1 mm inside the box, as in the Cycles fixture
	floor_mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # QuadMesh faces +Z; turn it to face +Y
	add_child(floor_mi)

	if p.get("back_wall", false):
		var wall := MeshInstance3D.new()
		var wq := QuadMesh.new()
		wq.size = Vector2(2.0, 2.0)
		wall.mesh = wq
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0, 0, 0)
		wm.emission_enabled = true
		wm.emission = Color(1, 1, 1)
		wm.emission_energy_multiplier = 1.0
		wm.roughness = 1.0
		wm.metallic_specular = 0.0
		wall.material_override = wm
		wall.position = Vector3(0.0, 1.0, -0.999) # faces +Z, toward the camera; 1 mm inside the box
		add_child(wall)

	if p.get("sun", false):
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		sun.light_energy = 1.0
		sun.light_angular_distance = 0.0
		sun.shadow_enabled = true
		add_child(sun)

	var cam := Camera3D.new()
	cam.fov = 30.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.0, 4.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.4, 0.0), Vector3.UP)
	cam.make_current()
	_cam = cam

	var env := _new_env_sky(float(p.get("world", 0.0)))
	env.set_pathtracing_max_bounces(4)
	env.volumetric_fog_enabled = bool(p.get("fog", false))
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = float(p.get("density", 0.0))
		var a := float(p.get("albedo", 0.0))
		env.volumetric_fog_albedo = Color(a, a, a).linear_to_srgb()
		env.volumetric_fog_anisotropy = float(p.get("g", 0.0))
		var e := float(p.get("emission", 0.0))
		env.volumetric_fog_emission = Color(e, e, e).linear_to_srgb()
		env.volumetric_fog_emission_energy = 1.0
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)


## Ray / box slab test on the padded fixture box; returns [t_in, t_out] or
## an empty array.
func _box_clip(o: Vector3, d: Vector3) -> Array:
	var bmin := Vector3(-1.0 - BOX_PAD, 0.0 - BOX_PAD, -1.0 - BOX_PAD)
	var bmax := Vector3(1.0 + BOX_PAD, 2.0 + BOX_PAD, 1.0 + BOX_PAD)
	var t_in := 0.0
	var t_out := 1e9
	for i in range(3):
		var di: float = d[i]
		if absf(di) < 1e-9:
			if o[i] < bmin[i] or o[i] > bmax[i]:
				return []
			continue
		var ta: float = (bmin[i] - o[i]) / di
		var tb: float = (bmax[i] - o[i]) / di
		t_in = maxf(t_in, minf(ta, tb))
		t_out = minf(t_out, maxf(ta, tb))
	if t_out <= t_in:
		return []
	return [t_in, t_out]


## Per-pixel analytic expectation over a crop, from the camera's own rays.
##   wall_transmittance : exp(-sigma_t L) to the back wall
##   emission           : E_eff (1 - exp(-sigma_t L_box)) / sigma_t, E_eff = 1 * 1 * sigma_t
##   floor_shadowed     : exp(-sigma_t L_view to the floor) * exp(-sigma_t (box top - floor))
func _expected(fy0: float, fy1: float, fx0: float, fx1: float, sigma_t: float, mode: String) -> float:
	var w := get_window().size.x
	var h := get_window().size.y
	var acc := 0.0
	var n := 0
	for y in range(int(h * fy0), int(h * fy1)):
		for x in range(int(w * fx0), int(w * fx1)):
			var sp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var o := _cam.project_ray_origin(sp)
			var d := _cam.project_ray_normal(sp)
			var clip := _box_clip(o, d)
			var v := 0.0
			if clip.is_empty():
				v = 1.0 if mode != "emission" else 0.0
			elif mode == "wall_transmittance":
				var t_wall: float = (WALL_Z - o.z) / d.z
				v = exp(-sigma_t * maxf(minf(t_wall, clip[1]) - clip[0], 0.0))
			elif mode == "emission":
				var e_eff := 1.0 * 1.0 * sigma_t
				v = e_eff * (1.0 - exp(-sigma_t * (clip[1] - clip[0]))) / sigma_t
			else:
				var t_floor: float = (FLOOR_Y - o.y) / d.y
				var l_view: float = maxf(minf(t_floor, clip[1]) - clip[0], 0.0)
				var l_sun: float = (2.0 + BOX_PAD) - FLOOR_Y
				v = exp(-sigma_t * l_view) * exp(-sigma_t * l_sun)
			acc += v
			n += 1
	return acc / float(maxi(n, 1))


func _crop(p_img: Image, fy0: float, fy1: float, fx0: float, fx1: float) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * fy0), int(h * fy1)):
		for x in range(int(w * fx0), int(w * fx1)):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))


func _new_env_sky(p_radiance: float) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(Color(p_radiance, p_radiance, p_radiance))
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)
	return env
