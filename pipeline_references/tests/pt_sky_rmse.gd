extends "res://tests/pt_validation.gd"

## Variance-reduction and cost measurement for environment (sky) NEE + MIS.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_sky_rmse_scene.tscn
##
## WHY THIS EXISTS RATHER THAN run_pt_validation.gd
##
## `run_pt_validation.gd` builds its environment with `BG_COLOR` and assigns no
## `Sky`, so `render_raytracing.cpp` binds DEFAULT_RD_TEXTURE_BLACK, every cell of
## the environment CDF has luminance 0, `floor = 1e-4 * 0 = 0`, `marginal_total`
## stays 0, and `env_sample()` returns false on its first branch. Environment NEE
## is INERT in that scene by construction: it never fires a shadow ray and the
## miss stage's MIS weight is unconditionally 1. Any before/after figure taken
## there carries no information about this feature in either direction.
##
## This scene is therefore built to the opposite specification:
##   * the sky is the ONLY light source (no analytic lights at all), so every
##     photon in the image travelled through the code path under test;
##   * the sky is high contrast (a small bright sun against a dim dome), which is
##     the regime importance sampling exists for -- a uniform-ish sky would show
##     almost no difference no matter how correct the sampler is;
##   * the geometry has real occluder DEPTH -- walls, a slatted canopy and a
##     cluster of spheres -- so the extra shadow ray each shading point now fires
##     has something to traverse. A two-triangle plane cannot price it.
##
## MEASUREMENTS
##
##   [1] convergence sweep: RMSE against a high-sample reference at matched
##       sample counts. Run this binary twice -- once at HEAD, once with the
##       raytracing shader directory checked out before environment NEE landed --
##       and compare.
##   [2] converged mean luminance, the energy regression guard. MIS redistributes
##       variance, not energy: a shifted converged mean is an energy bug.
##   [3] wall-clock ms/frame, the cost of the extra shadow ray.
##
## The reference is written to disk as a raw float32 RGB dump (NOT an EXR -- no
## codec round trip to argue about) so the SECOND build can be scored against the
## FIRST build's reference as well as its own. Both numbers are reported:
##   * self-reference RMSE measures each estimator's convergence towards its own
##     limit, and is symmetric between the two builds;
##   * cross-reference RMSE scores both builds against ONE image, which is the
##     comparison that would also expose a shift in the converged value.
##
## Env vars:
##   ZR_SKY_TAG          label for the reference dump          (default "run")
##   ZR_SKY_REF          frames for the reference render       (default 4096)
##   ZR_SKY_COUNTS       comma-separated sweep                 (default "16,64,256")
##   ZR_SKY_RES          square render resolution              (default 256)
##   ZR_SKY_XREF         path to another build's raw reference (default none)
##   ZR_SKY_TIME_FRAMES  frames for the timing pass            (default 512)
##   ZR_SKY_SKIP_SWEEP   "1" to run the timing pass only
##   ZR_SKY_LAMBERT      "1" to force every surface PURELY Lambertian
##
## ZR_SKY_LAMBERT is a discriminating control, not a convenience. Godot's default
## `metallic_specular = 0.5` gives F0 = 0.16 * 0.5^2 = 0.04, so EVERY ordinary
## "diffuse" material in this engine still carries a live dielectric specular
## lobe and therefore a pSpec strictly between 0 and 1. Setting
## `metallic_specular = 0` (and metallic 0, roughness 1) kills that lobe outright
## and leaves a pure Lambertian BRDF. Running the same scene both ways isolates
## anything that only happens when both BRDF lobes are live -- which is exactly
## the regime the energy gate never covered.

var _res := 256
var _tag := "run"
var _lambert := false


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution.
	var r_env := OS.get_environment("ZR_SKY_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	# Otherwise the timing pass measures the display refresh, not the renderer.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var t_env := OS.get_environment("ZR_SKY_TAG")
	if t_env != "":
		_tag = t_env
	_lambert = OS.get_environment("ZR_SKY_LAMBERT") == "1"

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	# The sky's radiance octmap is rendered by the sky pass and the environment
	# CDF is built from it; both need a moment before the first measurement.
	await get_tree().create_timer(2.0).timeout

	print("\n=== SKY NEE / MIS measurement (tag '%s') ===" % _tag)
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))
	print("light sources: sky only (no analytic lights)")
	print("materials: %s" % ("PURE LAMBERTIAN (specular lobe killed)" if _lambert
			else "as authored (every surface carries the default F0 = 0.04 specular lobe)"))

	if OS.get_environment("ZR_SKY_SKIP_SWEEP") != "1":
		await _sweep(env)
	await _timing(env)

	print("\n=== DONE ===")
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# [1] + [2] convergence sweep and converged mean luminance
# ---------------------------------------------------------------------------
func _sweep(p_env: Environment) -> void:
	var ref_frames := 4096
	var f_env := OS.get_environment("ZR_SKY_REF")
	if f_env.is_valid_int():
		ref_frames = maxi(256, f_env.to_int())

	var counts: Array = [16, 64, 256]
	var c_env := OS.get_environment("ZR_SKY_COUNTS")
	if c_env != "":
		counts = []
		for part in c_env.split(",", false):
			if part.strip_edges().is_valid_int():
				counts.append(part.strip_edges().to_int())

	var vp := get_viewport().get_viewport_rid()

	print("\n[1] reference render: %d frames" % ref_frames)
	var t0 := Time.get_ticks_msec()
	var reference: Image = await _render_accum(p_env, vp, ref_frames)
	var ref_ms := Time.get_ticks_msec() - t0
	if reference == null:
		print("  FAIL - reference readback returned null")
		return
	var ref_luma := mean_luma(reference)
	var ref_mean := _mean_rgb(reference)
	print("  reference mean_luma  : %.6f" % ref_luma)
	print("  reference mean RGB   : %.6f  (ENERGY REGRESSION GUARD)" % ref_mean)
	print("  reference wall clock : %d ms" % ref_ms)

	var ref_path := "user://pt_sky_ref_%s.raw" % _tag
	if _save_raw(reference, ref_path):
		print("  reference written to : %s" % ProjectSettings.globalize_path(ref_path))

	# Optional second reference from another build, for the cross-scored column.
	var xref: Image = null
	var x_path := OS.get_environment("ZR_SKY_XREF")
	if x_path != "":
		xref = _load_raw(x_path, reference.get_width(), reference.get_height())
		if xref == null:
			print("  WARNING: could not load cross reference '%s'" % x_path)
		else:
			print("  cross reference      : %s" % x_path)
			print("  cross ref mean RGB   : %.6f" % _mean_rgb(xref))
			print("  RMSE(self ref, cross ref) : %.6f" % rmse(reference, xref))

	print("\n  frames |   rmse(self)  |  rmse(cross)  | mean_luma")
	print("  -------+---------------+---------------+-----------")
	for frames in counts:
		var img: Image = await _render_accum(p_env, vp, int(frames))
		if img == null:
			print("  %6d | READBACK NULL" % int(frames))
			continue
		var e_self := rmse(img, reference)
		var e_cross := -1.0
		if xref != null:
			e_cross = rmse(img, xref)
		print("  %6d | %13.6f | %13.6f | %.6f"
				% [int(frames), e_self, e_cross, mean_luma(img)])


# ---------------------------------------------------------------------------
# [3] frame time -- the cost of the extra shadow ray
# ---------------------------------------------------------------------------
func _timing(p_env: Environment) -> void:
	var frames := 512
	var t_env := OS.get_environment("ZR_SKY_TIME_FRAMES")
	if t_env.is_valid_int():
		frames = maxi(64, t_env.to_int())

	var vp := get_viewport().get_viewport_rid()
	print("\n[3] frame time at %dx%d, %d accumulated frames, vsync off" % [_res, _res, frames])

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
## A dim dome with one small bright sun. 1.6% of the pixel area at 400x the base
## radiance: uniform BSDF sampling finds it rarely and pays enormous variance
## when it does, which is exactly the regime environment importance sampling
## exists to fix. A smoothly varying sky would show almost nothing here no matter
## how correct the sampler is.
func _sun_panorama() -> ImageTexture:
	var w := 256
	var h := 128
	var pano := Image.create(w, h, false, Image.FORMAT_RGBF)
	# Dim gradient dome so the image is not lit purely by the sun -- a completely
	# flat base would make the estimator degenerate in a way a real HDRI is not.
	for y in range(h):
		var t := float(y) / float(h - 1)
		var v: float = lerpf(0.10, 0.02, t)
		for x in range(w):
			pano.set_pixel(x, y, Color(v, v * 1.02, v * 1.15))
	# The sun: a small warm patch high in the sky.
	for y in range(int(h * 0.16), int(h * 0.24)):
		for x in range(int(w * 0.30), int(w * 0.38)):
			pano.set_pixel(x, y, Color(40.0, 36.0, 30.0))
	return ImageTexture.create_from_image(pano)


func _build_scene() -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = _sun_panorama()
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

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias and it is applied ASYMMETRICALLY across the
	# MIS partition today (environment NEE goes through clamp_contribution, the
	# miss half does not), so it must be off or this measures the clamp.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	# Adaptive sampling freezes converged pixels and flattens the tail of the
	# convergence curve; this harness measures the un-accelerated estimator.
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 2.4, 8.0)
	cam.rotation_degrees = Vector3(-10.0, 0.0, 0.0)
	cam.fov = 55.0
	add_child(cam)
	cam.make_current()

	# --- Geometry with real occluder depth --------------------------------
	# A three-sided courtyard, open to the sky, with a slatted canopy overhead.
	# The walls block a large fraction of the environment CDF's support, so most
	# environment-NEE shadow rays are occluded (the indoor limitation that portal
	# sampling exists to address); the slats and spheres give those rays real
	# traversal work rather than a single plane test.
	_add_box(Vector3(0, -0.1, 0), Vector3(24, 0.2, 24), Color(0.72, 0.70, 0.66))
	_add_box(Vector3(0, 3.0, -6.0), Vector3(16, 6.0, 0.3), Color(0.66, 0.30, 0.26))
	_add_box(Vector3(-6.0, 3.0, 0.0), Vector3(0.3, 6.0, 16), Color(0.28, 0.54, 0.30))
	_add_box(Vector3(6.0, 3.0, 0.0), Vector3(0.3, 6.0, 16), Color(0.30, 0.36, 0.62))

	# Slatted canopy: 14 thin beams. Partial sky occlusion with high spatial
	# frequency, which is what makes the shadow ray do work and what makes the
	# sun's visibility vary sharply across the floor.
	for i in range(14):
		var z := -5.0 + float(i) * 0.8
		_add_box(Vector3(0.0, 5.4, z), Vector3(11.0, 0.16, 0.28), Color(0.58, 0.52, 0.44))

	# Spheres: curved silhouettes, dense triangles, and self-shadowing.
	_add_sphere(Vector3(-2.2, 1.0, 0.4), 1.0, Color(0.80, 0.78, 0.74), 1.0, 0.0)
	_add_sphere(Vector3(1.6, 0.8, 1.6), 0.8, Color(0.85, 0.80, 0.70), 0.35, 0.0)
	_add_sphere(Vector3(3.0, 0.6, -1.4), 0.6, Color(0.90, 0.88, 0.86), 0.25, 1.0)
	_add_sphere(Vector3(-0.6, 0.5, 3.2), 0.5, Color(0.70, 0.72, 0.80), 0.60, 0.0)

	return env


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
	if _lambert:
		mat.metallic_specular = 0.0
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
	if _lambert:
		mat.roughness = 1.0
		mat.metallic = 0.0
		mat.metallic_specular = 0.0
	mi.material_override = mat
	add_child(mi)
