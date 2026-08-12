extends "res://tests/pt_validation.gd"

## Variance-reduction and cost measurement for ANALYTIC-LIGHT SELECTION
## (roadmap C2: power-weighted CDF vs the pre-C2 uniform k=16 mini-batch
## reservoir).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_light_rmse_scene.tscn
##
## WHY THIS SCENE
##
## The roadmap's accept criterion for C2 (PATH_TRACER_QUALITY_ROADMAP.md:523) is
## "one bright key among 40 dim fills converges at several x the current rate".
## This scene is that sentence made concrete, and it is built so that neither
## estimator can look good for the wrong reason:
##
##   * ONE bright key among 40 dim fills. The key carries ~97% of the scene's
##     total power, so a uniform selector spends 40/41 = 97.6% of its draws on
##     lights that carry ~3% of the light -- and at k = 16 it fails to even
##     CONSIDER the key at (1 - 1/41)^16 = 67% of shading points.
##   * NO sky (BG_COLOR black). render_raytracing.cpp binds
##     DEFAULT_RD_TEXTURE_BLACK, every environment CDF cell has luminance 0 and
##     env_sample() returns false immediately, so environment NEE cannot
##     contribute and cannot dilute the measurement. Every photon in this image
##     came through the analytic-light selector.
##   * REAL OCCLUDERS. A uniform selector and a weighted one converge to the same
##     image at the same rate on an unoccluded plane lit from directly above,
##     because there the only variance is in which light was picked, not in
##     whether the shadow ray survived. Boxes, a slatted canopy and spheres give
##     the shadow rays traversal work and give the fills genuinely different
##     visibility from the key.
##   * Lights are UNEQUAL in energy AND in distance, so both factors of the
##     weight (magnitude and distance attenuation) vary across the array.
##
## MEASUREMENTS
##
##   [1] convergence sweep: RMSE against a high-sample reference at matched
##       sample counts, plus converged mean RGB.
##   [2] wall-clock ms/frame -- the cost of walking a 41-entry CDF twice per
##       shading point instead of a 16-iteration reservoir. This is what turns
##       a per-sample win into an equal-time win or not.
##
## Run this binary twice -- once at RT_LIGHT_SELECT_UNIFORM 1 (control) and once
## at 0 (treatment), each after a FULL `scons platform=windows target=editor` so
## the raygen .glsl.gen.h regenerates -- and pass the FIRST run's raw reference
## dump to the second through ZR_LIGHT_XREF. The cross-scored column is the
## comparison that matters: both builds scored against ONE image, so the
## reference is not itself a variable.
##
## Env vars:
##   ZR_LIGHT_TAG          label for the reference dump      (default "run")
##   ZR_LIGHT_REF          frames for the reference render   (default 4096)
##   ZR_LIGHT_COUNTS       comma-separated sweep             (default "16,32,64,128,256")
##   ZR_LIGHT_RES          square render resolution          (default 256)
##   ZR_LIGHT_XREF         path to another build's raw reference (default none)
##   ZR_LIGHT_TIME_FRAMES  frames for the timing pass        (default 512)
##   ZR_LIGHT_SKIP_SWEEP   "1" to run the timing pass only
##   ZR_LIGHT_SKIP_REF     "1" to skip rendering a self reference (score against
##                         ZR_LIGHT_XREF alone -- the equal-time sweep does not
##                         need a second reference)

var _res := 256
var _tag := "run"


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution.
	var r_env := OS.get_environment("ZR_LIGHT_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	# Otherwise the timing pass measures the display refresh, not the renderer.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var t_env := OS.get_environment("ZR_LIGHT_TAG")
	if t_env != "":
		_tag = t_env

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(2.0).timeout

	print("\n=== ANALYTIC LIGHT SELECTION measurement (tag '%s') ===" % _tag)
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))
	# Derived from the mode, never hardcoded: a fixed string here cannot tell you
	# whether ZR_LIGHT_SHADOW_MODE actually engaged, and a timing number recorded
	# against a scene you did not confirm you built is worthless.
	if OS.get_environment("ZR_LIGHT_SHADOW_MODE") == "mixed":
		print("light sources: MIXED -- 1 directional sun + 2 spots (shadow_enabled=true)")
		print("               + 38 omni fills (shadow_enabled=FALSE), 41 total, no sky")
	else:
		print("light sources: ALL-SHADOW -- 1 key (energy 200) + 40 fills (energy 0.15),")
		print("               41 total, every light shadow_enabled=true (default), no sky")

	if OS.get_environment("ZR_LIGHT_SKIP_SWEEP") != "1":
		await _sweep(env)
	await _timing(env)

	print("\n=== DONE ===")
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# [1] convergence sweep and converged mean
# ---------------------------------------------------------------------------
func _sweep(p_env: Environment) -> void:
	var ref_frames := 4096
	var f_env := OS.get_environment("ZR_LIGHT_REF")
	if f_env.is_valid_int():
		ref_frames = maxi(256, f_env.to_int())

	var counts: Array = [16, 32, 64, 128, 256]
	var c_env := OS.get_environment("ZR_LIGHT_COUNTS")
	if c_env != "":
		counts = []
		for part in c_env.split(",", false):
			if part.strip_edges().is_valid_int():
				counts.append(part.strip_edges().to_int())

	var vp := get_viewport().get_viewport_rid()

	var reference: Image = null
	if OS.get_environment("ZR_LIGHT_SKIP_REF") != "1":
		print("\n[1] reference render: %d frames" % ref_frames)
		var t0 := Time.get_ticks_msec()
		reference = await _render_accum(p_env, vp, ref_frames)
		var ref_ms := Time.get_ticks_msec() - t0
		if reference == null:
			print("  FAIL - reference readback returned null")
			return
		print("  reference mean_luma  : %.6f" % mean_luma(reference))
		print("  reference mean RGB   : %.6f  (ENERGY REGRESSION GUARD)" % _mean_rgb(reference))
		print("  reference wall clock : %d ms" % ref_ms)

		var ref_path := "user://pt_light_ref_%s.raw" % _tag
		if _save_raw(reference, ref_path):
			print("  reference written to : %s" % ProjectSettings.globalize_path(ref_path))
	else:
		print("\n[1] self reference SKIPPED (ZR_LIGHT_SKIP_REF=1)")

	# The other build's reference, so both builds can be scored against ONE image.
	var xref: Image = null
	var x_path := OS.get_environment("ZR_LIGHT_XREF")
	if x_path != "":
		# The window manager can refuse the requested window size (a 128-wide
		# request comes back as 148 here), so the reference must be matched
		# against the size the viewport ACTUALLY has, not against ZR_LIGHT_RES.
		var vsize := get_viewport().get_visible_rect().size
		xref = _load_raw(x_path, int(vsize.x), int(vsize.y))
		if xref == null:
			print("  WARNING: could not load cross reference '%s'" % x_path)
		else:
			print("  cross reference      : %s" % x_path)
			print("  cross ref mean RGB   : %.6f" % _mean_rgb(xref))
			if reference != null:
				print("  RMSE(self ref, cross ref) : %.6f" % rmse(reference, xref))

	if reference == null and xref == null:
		print("  FAIL - no reference of any kind; nothing to score against")
		return

	print("\n  frames |   rmse(self)  |  rmse(cross)  | mean_luma  | mean RGB")
	print("  -------+---------------+---------------+------------+----------")
	for frames in counts:
		var img: Image = await _render_accum(p_env, vp, int(frames))
		if img == null:
			print("  %6d | READBACK NULL" % int(frames))
			continue
		var e_self := -1.0
		if reference != null:
			e_self = rmse(img, reference)
		var e_cross := -1.0
		if xref != null:
			e_cross = rmse(img, xref)
		print("  %6d | %13.6f | %13.6f | %10.6f | %.6f"
				% [int(frames), e_self, e_cross, mean_luma(img), _mean_rgb(img)])


# ---------------------------------------------------------------------------
# [2] frame time -- the cost of the CDF walk
# ---------------------------------------------------------------------------
func _timing(p_env: Environment) -> void:
	var frames := 512
	var t_env := OS.get_environment("ZR_LIGHT_TIME_FRAMES")
	if t_env.is_valid_int():
		frames = maxi(64, t_env.to_int())

	var vp := get_viewport().get_viewport_rid()
	print("\n[2] frame time at %dx%d, %d accumulated frames, vsync off" % [_res, _res, frames])

	# Warm the pipeline first; the first accumulation after a reset pays for
	# pipeline creation and TLAS work that is not per-frame cost.
	var warm: Image = await _render_accum(p_env, vp, 64)
	if warm == null:
		print("  FAIL - warmup readback returned null")
		return

	var best := INF
	for pass_i in range(3):
		p_env.pathtracing_accumulate = false
		for _i in range(RESET_SETTLE_FRAMES):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		p_env.pathtracing_accumulate = true
		p_env.pathtracing_accumulation_target = frames
		for _i in range(RESET_SETTLE_FRAMES):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw

		var t0 := Time.get_ticks_usec()
		for _i in range(frames):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var dt := Time.get_ticks_usec() - t0
		var ms := float(dt) / 1000.0 / float(frames)
		print("  pass %d: %.4f ms/frame  (%d frames in %.1f ms)" % [pass_i + 1, ms, frames, float(dt) / 1000.0])
		best = minf(best, ms)
	print("  BEST: %.4f ms/frame" % best)


# ---------------------------------------------------------------------------
# Reference I/O -- raw float32 RGB, no codec in the loop
# ---------------------------------------------------------------------------
func _save_raw(p_img: Image, p_path: String) -> bool:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_32(p_img.get_width())
	f.store_32(p_img.get_height())
	for y in range(p_img.get_height()):
		for x in range(p_img.get_width()):
			var c := p_img.get_pixel(x, y)
			f.store_float(c.r)
			f.store_float(c.g)
			f.store_float(c.b)
	f.close()
	return true


func _load_raw(p_path: String, p_w: int, p_h: int) -> Image:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return null
	var w := int(f.get_32())
	var h := int(f.get_32())
	if w != p_w or h != p_h:
		push_warning("cross reference is %dx%d but this run is %dx%d" % [w, h, p_w, p_h])
		f.close()
		return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBF)
	for y in range(h):
		for x in range(w):
			var r := f.get_float()
			var g := f.get_float()
			var b := f.get_float()
			img.set_pixel(x, y, Color(r, g, b))
	f.close()
	return img


## Plain mean of R, G and B over every pixel. `mean_luma` in the base class
## stride-samples and is only a diagnostic; the energy guard wants all of it.
func _mean_rgb(p_img: Image) -> float:
	var acc := 0.0
	var n := 0
	for y in range(p_img.get_height()):
		for x in range(p_img.get_width()):
			var c := p_img.get_pixel(x, y)
			acc += c.r + c.g + c.b
			n += 3
	return acc / float(maxi(n, 1))


# ---------------------------------------------------------------------------
# Scene
# ---------------------------------------------------------------------------
func _build_scene() -> Environment:
	var env := Environment.new()
	# No sky: environment NEE is inert (see the header), so this measures the
	# analytic-light selector alone.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias and it truncates exactly the heavy tail a
	# poorly-importance-sampled selector produces -- leaving it on would flatter
	# the control and understate the difference.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	# Adaptive sampling freezes converged pixels and flattens the tail of the
	# convergence curve; this harness measures the un-accelerated estimator.
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 3.2, 9.0)
	cam.rotation_degrees = Vector3(-14.0, 0.0, 0.0)
	cam.fov = 55.0
	add_child(cam)
	cam.make_current()

	# --- Geometry: real occluder depth ------------------------------------
	_add_box(Vector3(0, -0.1, 0), Vector3(40, 0.2, 40), Color(0.72, 0.70, 0.66))
	_add_box(Vector3(0, 2.6, -7.0), Vector3(18, 5.2, 0.3), Color(0.66, 0.30, 0.26))
	_add_box(Vector3(-7.0, 2.6, 0.0), Vector3(0.3, 5.2, 18), Color(0.28, 0.54, 0.30))
	_add_box(Vector3(7.0, 2.6, 0.0), Vector3(0.3, 5.2, 18), Color(0.30, 0.36, 0.62))

	# Slatted canopy between the key light and the floor: high-frequency partial
	# occlusion, so the key's visibility varies sharply across the image and the
	# shadow rays have something to traverse.
	for i in range(12):
		var z := -4.4 + float(i) * 0.8
		_add_box(Vector3(0.0, 4.0, z), Vector3(12.0, 0.16, 0.28), Color(0.58, 0.52, 0.44))

	# Blockers at fill height, so the fills are occluded differently from the key
	# and the two selectors cannot agree by symmetry.
	_add_box(Vector3(-3.4, 1.2, -1.0), Vector3(0.3, 2.4, 5.0), Color(0.70, 0.68, 0.62))
	_add_box(Vector3(3.4, 1.2, 1.0), Vector3(0.3, 2.4, 5.0), Color(0.70, 0.68, 0.62))

	_add_sphere(Vector3(-2.0, 1.0, 0.6), 1.0, Color(0.80, 0.78, 0.74), 1.0, 0.0)
	_add_sphere(Vector3(1.6, 0.8, 1.8), 0.8, Color(0.85, 0.80, 0.70), 0.35, 0.0)
	_add_sphere(Vector3(3.0, 0.6, -1.4), 0.6, Color(0.90, 0.88, 0.86), 0.25, 1.0)
	_add_sphere(Vector3(-0.6, 0.5, 3.4), 0.5, Color(0.70, 0.72, 0.80), 0.60, 0.0)

	_build_lights(self)

	return env


## One bright key among 40 dim fills. The key carries ~97% of the scene's total
## power, so uniform selection spends ~97.6% of its draws (40/41) on lights that
## contribute ~3% of the light -- and with k = 16 it fails to CONSIDER the key at
## all at roughly (1 - 1/41)^16 = 67% of shading points.
func _build_lights(root: Node) -> void:
	if OS.get_environment("ZR_LIGHT_SHADOW_MODE") == "mixed":
		_build_lights_mixed(root)
		return

	var key := OmniLight3D.new()
	key.position = Vector3(0.0, 5.0, 0.0)
	key.light_energy = 200.0
	key.omni_range = 100.0
	key.light_color = Color(1, 1, 1)
	root.add_child(key)

	for i in range(40):
		var f := OmniLight3D.new()
		var a := TAU * float(i) / 40.0
		f.position = Vector3(cos(a) * 6.0, 2.0 + float(i % 4), sin(a) * 6.0)
		f.light_energy = 0.15
		f.omni_range = 100.0
		f.light_color = Color(1, 1, 1)
		root.add_child(f)


## ZR_LIGHT_SHADOW_MODE=mixed -- the configuration the default scene above is
## STRUCTURALLY BLIND TO, and the one a real interior actually has.
##
## Every light in the default scene leaves shadow_enabled at its default of true,
## so the control and the treatment trace the SAME number of shadow rays and the
## only thing that build differs in is the weight arithmetic. That is why the
## default scene measured C2 at +50.8% frame time while the production pipeline
## measured +128% on the same change: the pipeline's lights are not shaped like
## this one's.
##
## In the production scene (image_glb_creation.gd) roughly 35 of ~40 lights are
## shadowless fills -- fill/fill_front/fill_back per room, ceiling and decor
## spots -- and only the sun and the two window portal spots set
## shadow_enabled = true. In the shader, shadow_enabled == 0.0 skips the shadow
## ray ENTIRELY. So:
##
##   * uniform selection picks a shadow-casting light ~3/41 = 7% of the time and
##     almost never pays for a traversal;
##   * power-weighted selection concentrates on the brightest emitters, which are
##     exactly the three that DO trace -- and a directional light takes no
##     distance attenuation at all, so the sun dominates the CDF outright.
##
## The shadow-ray rate therefore jumps by roughly an order of magnitude, and in a
## scene with real occluders that traversal, not the CDF scan, is the dominant
## cost. This mode reproduces that shape at the same total light count (41) so the
## scan cost is held constant and the ray-count change is what is being measured.
##
## It is also the only rendered measurement in this project that exercises the
## SPOT and DIRECTIONAL branches of lights_select_weight -- the default scene is
## omni-only, which the C2 final review recorded as an open coverage gap.
func _build_lights_mixed(root: Node) -> void:
	# The sun. Dominates the CDF: directional lights return `mag * indirect_factor`
	# with attenuation pinned at 1.0, so no distance falloff discounts it.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-62.0, 34.0, 0.0)
	sun.light_energy = 1.6
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	root.add_child(sun)

	# Two window portal spots, shadow-casting, matching the pipeline's pattern.
	for i in range(2):
		var s := SpotLight3D.new()
		var sx := -7.0 if i == 0 else 7.0
		s.position = Vector3(sx, 4.5, 0.0)
		s.look_at_from_position(s.position, Vector3(0.0, 0.5, 0.0), Vector3.UP)
		s.light_energy = 22.0
		s.spot_range = 20.0
		s.spot_angle = 60.0
		s.spot_angle_attenuation = 0.4
		s.spot_attenuation = 1.0
		s.light_color = Color(1.0, 0.97, 0.92)
		s.shadow_enabled = true
		root.add_child(s)

	# 38 shadowless fills, as the pipeline builds per room.
	for i in range(38):
		var f := OmniLight3D.new()
		var a := TAU * float(i) / 38.0
		f.position = Vector3(cos(a) * 6.0, 2.0 + float(i % 4), sin(a) * 6.0)
		f.light_energy = 0.15
		f.omni_range = 100.0
		f.light_color = Color(1, 1, 1)
		f.shadow_enabled = false
		root.add_child(f)


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


func _add_sphere(p_pos: Vector3, p_radius: float, p_col: Color, p_rough: float, p_metal: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = p_radius
	sm.height = p_radius * 2.0
	sm.radial_segments = 64
	sm.rings = 32
	mi.mesh = sm
	mi.position = p_pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_col
	mat.roughness = p_rough
	mat.metallic = p_metal
	mi.material_override = mat
	add_child(mi)
