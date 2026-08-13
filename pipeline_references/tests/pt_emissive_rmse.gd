extends "res://tests/pt_validation.gd"

## Variance-reduction and cost measurement for EMISSIVE-MESH LIGHT SAMPLING
## (roadmap C1: emissive NEE, MIS-combined against the BSDF hit).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_emissive_rmse_scene.tscn
##
## WHY THIS SCENE
##
## The roadmap's accept criterion for C1 is "a room lit only by a glowing panel
## converges clean; no hotspot speckle". This scene is that sentence made
## concrete:
##
##   * ONE emissive quad and NOTHING else emitting. No analytic lights. No sky
##     (BG_COLOR black -- render_raytracing.cpp binds DEFAULT_RD_TEXTURE_BLACK,
##     every environment CDF cell has luminance 0, env_sample() returns false
##     immediately), so environment NEE cannot contribute and cannot dilute the
##     measurement. Every photon came through emissive sampling or through a BSDF
##     ray that found the panel.
##   * REAL OCCLUDERS -- walls, a ceiling, boxes, a slatted baffle, spheres. On a
##     bare unoccluded plane the shadow ray survives everywhere and the two
##     strategies differ only in which point of the panel they picked; the
##     occluders are what give the shadow rays traversal work and give different
##     parts of the image genuinely different visibility of the panel.
##   * TWO EMITTER SIZES, because the BSDF-only control degrades fastest as the
##     emitter shrinks and a large-panel-only measurement would understate the
##     win. `ZR_EMIS_SIZE=large` is a 2.0 m quad; `small` is a 0.25 m quad with
##     its emission scaled by the area ratio (64x) so the two scenes carry the
##     SAME total emitted power and their RMSE numbers are on the same scale.
##
## BOTH SIDES RUN IN ONE PROCESS. The setting is read per frame
## (render_raytracing.cpp:2780) and drives a raygen specialization constant, so
## OFF and ON are two configurations of one binary. The C2 measurement had to
## compare two BUILDS, which put a rebuild and an unknown amount of thermal drift
## between the two timing numbers; here the timing pass INTERLEAVES OFF and ON
## within one thermal state.
##
## MEASUREMENTS
##
##   [1] frame time, OFF vs ON, interleaved. Run first, because the equal-time
##       sweep needs the ratio before it can choose frame counts.
##   [2] two references at ZR_EMIS_REF frames, one per setting. Everything is
##       scored against BOTH. The ON reference is the more converged of the two
##       and is the headline; the OFF column exists so nobody has to take on
##       trust that scoring ON against an ON-rendered reference did not flatter
##       it. RMSE(ref_off, ref_on) is printed as the references' own disagreement.
##   [3] per-sample RMSE at matched frame counts, and EQUAL-TIME RMSE measured
##       DIRECTLY -- for each OFF count N the ON side is re-rendered at
##       round(N * ms_off / ms_on) frames, i.e. the same wall clock. No
##       1/sqrt(N) extrapolation is used for the equal-time headline; the
##       exponents are printed separately as a sanity check, not as an input.
##
## Env vars:
##   ZR_EMIS_SIZE    "large" | "small"                 (default "large")
##   ZR_EMIS_REF     frames for each reference render  (default 2048)
##   ZR_EMIS_COUNTS  comma-separated sweep             (default "16,32,64,128,256")
##   ZR_EMIS_RES     square render resolution          (default 192)
##   ZR_EMIS_TIME_FRAMES  frames per timing pass       (default 256)
##   ZR_EMIS_TIME_PASSES  interleaved OFF/ON pairs     (default 3)

const SETTING := "rendering/pathtracer/emissive_mesh_lights"
const ALBEDO := 0.5

## Held constant across the two sizes: emission_energy_multiplier is scaled by the
## area ratio so both scenes emit the same total power and their RMSE numbers can
## be read side by side.
const LARGE_SIZE := 2.0
const LARGE_ENERGY := 40.0
const SMALL_SIZE := 0.25

var _res := 192
var _size_tag := "large"
var _emitter_size := LARGE_SIZE
var _emitter_energy := LARGE_ENERGY


func _ready() -> void:
	var r_env := OS.get_environment("ZR_EMIS_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	if OS.get_environment("ZR_EMIS_SIZE") == "small":
		_size_tag = "small"
		_emitter_size = SMALL_SIZE
		# Same total power: L * A is held fixed, so the radiance goes up by the
		# inverse area ratio.
		_emitter_energy = LARGE_ENERGY * (LARGE_SIZE * LARGE_SIZE) / (SMALL_SIZE * SMALL_SIZE)

	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	# Otherwise the timing pass measures the display refresh, not the renderer.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(2.0).timeout

	print("\n=== EMISSIVE-MESH LIGHT measurement (size '%s') ===" % _size_tag)
	print("viewport render size : %s" % str(get_viewport().get_visible_rect().size))
	# Derived from the actual scene state, never a hardcoded string: a fixed line
	# here cannot tell you whether ZR_EMIS_SIZE engaged, and a number recorded
	# against a scene you did not confirm you built is worthless.
	print("emitter              : %.3f x %.3f m quad (A = %.5f m^2), emission energy %.1f"
			% [_emitter_size, _emitter_size, _emitter_size * _emitter_size, _emitter_energy])
	print("                       total emitted power L*A is held constant across sizes")
	print("light sources        : this one quad, nothing else. No analytic lights, no sky.")

	var timing := await _timing(env)
	var refs := await _references(env)
	if refs.is_empty():
		print("\n=== DONE (no reference; nothing scored) ===")
		get_tree().quit(1)
		return
	await _sweep(env, refs, timing)

	print("\n=== DONE ===")
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# [1] frame time -- interleaved, because thermal drift is the dominant artefact
# ---------------------------------------------------------------------------
## The same binary on this machine has read 2.2238 ms cold and 2.6094 ms hot -- a
## 16% spread, wider than most of the effects being measured, and it has already
## produced two false conclusions in this project. So OFF and ON alternate inside
## one loop rather than being measured in two blocks, and the MINIMUM of each
## side's passes is taken: the minimum is the least thermally contaminated sample
## available, and alternating means neither side systematically occupies the cold
## end of the run.
func _timing(p_env: Environment) -> Dictionary:
	var frames := 256
	var t_env := OS.get_environment("ZR_EMIS_TIME_FRAMES")
	if t_env.is_valid_int():
		frames = maxi(64, t_env.to_int())
	var passes := 3
	var p_env_s := OS.get_environment("ZR_EMIS_TIME_PASSES")
	if p_env_s.is_valid_int():
		passes = maxi(2, p_env_s.to_int())

	var vp := get_viewport().get_viewport_rid()
	print("\n[1] frame time at %dx%d, %d accumulated frames per pass, vsync off" % [_res, _res, frames])
	print("    OFF and ON ALTERNATE within one loop (thermal drift on this machine")
	print("    is larger than the effect); the minimum of each side is reported.")

	# Warm the pipeline: the first accumulation after a reset pays for pipeline
	# creation and TLAS work that is not per-frame cost.
	await _set_feature(false)
	var warm: Image = await _render_accum(p_env, vp, 64)
	if warm == null:
		print("    FAIL - warmup readback returned null")
	await _set_feature(true)
	warm = await _render_accum(p_env, vp, 64)
	if warm == null:
		print("    FAIL - warmup readback returned null")

	var best := { "off": INF, "on": INF }
	for pass_i in range(passes):
		for side in ["off", "on"]:
			await _set_feature(side == "on")
			var ms := await _time_one(p_env, vp, frames)
			print("    pass %d %-3s : %.4f ms/frame" % [pass_i + 1, side.to_upper(), ms])
			best[side] = minf(best[side], ms)
	print("    BEST OFF : %.4f ms/frame" % best["off"])
	print("    BEST ON  : %.4f ms/frame" % best["on"])
	print("    frame-time delta : %+.2f%%" % ((best["on"] / maxf(best["off"], 1e-9) - 1.0) * 100.0))
	return best


func _time_one(p_env: Environment, p_vp: RID, p_frames: int) -> float:
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var t0 := Time.get_ticks_usec()
	for _i in range(p_frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var dt := Time.get_ticks_usec() - t0
	return float(dt) / 1000.0 / float(p_frames)


# ---------------------------------------------------------------------------
# [2] references
# ---------------------------------------------------------------------------
func _references(p_env: Environment) -> Dictionary:
	var ref_frames := 2048
	var f_env := OS.get_environment("ZR_EMIS_REF")
	if f_env.is_valid_int():
		ref_frames = maxi(256, f_env.to_int())

	var vp := get_viewport().get_viewport_rid()
	print("\n[2] references: %d frames each, one per setting" % ref_frames)

	await _set_feature(false)
	var ref_off: Image = await _render_accum(p_env, vp, ref_frames)
	await _set_feature(true)
	var ref_on: Image = await _render_accum(p_env, vp, ref_frames)
	if ref_off == null or ref_on == null:
		print("    FAIL - reference readback returned null")
		return {}

	var m_off := _mean_rgb(ref_off)
	var m_on := _mean_rgb(ref_on)
	print("    reference OFF mean RGB : %.6f" % m_off)
	print("    reference ON  mean RGB : %.6f" % m_on)
	print("    mean delta             : %+.3f%%   <- ENERGY CROSS-CHECK, REPORTED AND"
			% ((m_on / maxf(m_off, 1e-12) - 1.0) * 100.0))
	print("                                        NOT ASSERTED. These are two unbiased")
	print("                                        estimators of ONE integral, so this must")
	print("                                        be near zero -- but this script is a")
	print("                                        MEASUREMENT harness and exits 0 whatever")
	print("                                        it prints. The assertion on this quantity")
	print("                                        lives in pt_emissive_gate_scene.tscn's")
	print("                                        gate 1, against a band derived from that")
	print("                                        run's own standard error. Do not read a")
	print("                                        green exit code here as an energy check.")
	print("    RMSE(ref_off, ref_on)  : %.6f   <- the references' own disagreement;" % rmse(ref_off, ref_on))
	print("                                     every sweep RMSE below must be well")
	print("                                     above this to mean anything.")
	return { "off": ref_off, "on": ref_on }


# ---------------------------------------------------------------------------
# [3] convergence sweep, per-sample and equal-time
# ---------------------------------------------------------------------------
func _sweep(p_env: Environment, p_refs: Dictionary, p_timing: Dictionary) -> void:
	var counts: Array = [16, 32, 64, 128, 256]
	var c_env := OS.get_environment("ZR_EMIS_COUNTS")
	if c_env != "":
		counts = []
		for part in c_env.split(",", false):
			if part.strip_edges().is_valid_int():
				counts.append(part.strip_edges().to_int())

	var vp := get_viewport().get_viewport_rid()
	var ms_off: float = p_timing["off"]
	var ms_on: float = p_timing["on"]
	# The ON side gets FEWER frames for the same wall clock whenever ON is slower.
	var eq_scale: float = ms_off / maxf(ms_on, 1e-9)

	print("\n[3] convergence. 'eq' rows re-render the ON side at round(N * %.4f)" % eq_scale)
	print("    frames, i.e. the SAME WALL CLOCK as the OFF row above it. The")
	print("    equal-time ratio is therefore MEASURED, not extrapolated from a")
	print("    1/sqrt(N) law.")
	print("\n    scored against ref_ON            | scored against ref_OFF")
	print("       N |  frames | side |      rmse  |       rmse")
	print("    -----+---------+------+------------+-----------")

	var rows: Array = []
	for n in counts:
		var frames := int(n)
		var n_eq: int = maxi(1, int(round(float(frames) * eq_scale)))

		await _set_feature(false)
		var img_off: Image = await _render_accum(p_env, vp, frames)
		await _set_feature(true)
		var img_on: Image = await _render_accum(p_env, vp, frames)
		var img_eq: Image = img_on
		if n_eq != frames:
			img_eq = await _render_accum(p_env, vp, n_eq)

		if img_off == null or img_on == null or img_eq == null:
			print("    %4d | READBACK NULL" % frames)
			continue

		var e_off_on := rmse(img_off, p_refs["on"])
		var e_on_on := rmse(img_on, p_refs["on"])
		var e_eq_on := rmse(img_eq, p_refs["on"])
		var e_off_off := rmse(img_off, p_refs["off"])
		var e_on_off := rmse(img_on, p_refs["off"])
		var e_eq_off := rmse(img_eq, p_refs["off"])

		print("    %4d | %7d | OFF  | %10.6f | %10.6f" % [frames, frames, e_off_on, e_off_off])
		print("    %4d | %7d | ON   | %10.6f | %10.6f" % [frames, frames, e_on_on, e_on_off])
		print("    %4d | %7d | ONeq | %10.6f | %10.6f" % [frames, n_eq, e_eq_on, e_eq_off])
		rows.append({
			"n": frames, "n_eq": n_eq,
			"off": e_off_on, "on": e_on_on, "eq": e_eq_on,
			"off_x": e_off_off, "on_x": e_on_off, "eq_x": e_eq_off,
		})

	if rows.is_empty():
		return

	print("\n    per-sample and equal-time ratios (OFF / ON), scored against ref_ON")
	print("       N | per-sample | equal-time | ON frames at equal time")
	print("    -----+------------+------------+------------------------")
	var ps_lo := INF
	var ps_hi := -INF
	var et_lo := INF
	var et_hi := -INF
	for r in rows:
		var ps: float = r["off"] / maxf(r["on"], 1e-12)
		var et: float = r["off"] / maxf(r["eq"], 1e-12)
		ps_lo = minf(ps_lo, ps)
		ps_hi = maxf(ps_hi, ps)
		et_lo = minf(et_lo, et)
		et_hi = maxf(et_hi, et)
		print("    %4d | %9.2fx | %9.2fx | %d" % [r["n"], ps, et, r["n_eq"]])
	print("    RANGE ACROSS THE WHOLE SWEEP -- per-sample %.2f-%.2fx, equal-time %.2f-%.2fx."
			% [ps_lo, ps_hi, et_lo, et_hi])
	print("    The floor is the sweep's own minimum, not the best row.")

	print("\n    same ratios scored against ref_OFF (the control's own reference,")
	print("    so no possibility of a shared-noise advantage for ON):")
	var etx_lo := INF
	var etx_hi := -INF
	for r in rows:
		var etx: float = r["off_x"] / maxf(r["eq_x"], 1e-12)
		etx_lo = minf(etx_lo, etx)
		etx_hi = maxf(etx_hi, etx)
	print("    equal-time %.2f-%.2fx" % [etx_lo, etx_hi])

	# Printed as a sanity check on the sweep, NOT used as an input to anything
	# above. A healthy Monte Carlo estimator falls as N^-0.5.
	print("\n    convergence exponents (log-log slope between adjacent counts;")
	print("    -0.5 is the ideal 1/sqrt(N)):")
	for i in range(1, rows.size()):
		var a: Dictionary = rows[i - 1]
		var b: Dictionary = rows[i]
		var ln := log(float(b["n"]) / float(a["n"]))
		print("      %4d -> %4d : OFF %+.3f   ON %+.3f"
				% [a["n"], b["n"],
				log(maxf(b["off"], 1e-12) / maxf(a["off"], 1e-12)) / ln,
				log(maxf(b["on"], 1e-12) / maxf(a["on"], 1e-12)) / ln])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
## Flip the project setting and give the raygen pipeline time to recompile. The
## setting is a specialization constant, so this is a fresh pipeline build, not a
## uniform write.
func _set_feature(p_on: bool) -> void:
	if bool(ProjectSettings.get_setting(SETTING, false)) == p_on:
		return
	ProjectSettings.set_setting(SETTING, p_on)
	for _i in range(30):
		await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout


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
# Scene -- the same room gate 1 uses, so a reader comparing the two is comparing
# like with like.
# ---------------------------------------------------------------------------
func _build_scene() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(4)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias and it truncates exactly the heavy tail a
	# BSDF-only estimator produces on a small emitter -- leaving it on would
	# flatter the control and understate the difference this measures.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	# Adaptive sampling freezes converged pixels and flattens the tail of the
	# convergence curve; this harness measures the un-accelerated estimator.
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Above the camera and outside its downward cone, so the panel is never a
	# directly-visible (and therefore noiseless) part of the image -- a big
	# zero-variance patch would dilute every RMSE below.
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(0.0, 3.0, 2.8)
	cam.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	add_child(cam)
	cam.make_current()

	_add_box(Vector3(0.0, -0.1, 0.0), Vector3(200.0, 0.2, 200.0), Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb())
	_add_box(Vector3(0.0, 2.0, -3.2), Vector3(6.4, 4.0, 0.3), Color(0.66, 0.30, 0.26))
	_add_box(Vector3(-3.2, 2.0, 0.0), Vector3(0.3, 4.0, 6.4), Color(0.28, 0.54, 0.30))
	_add_box(Vector3(3.2, 2.0, 0.0), Vector3(0.3, 4.0, 6.4), Color(0.30, 0.36, 0.62))
	_add_box(Vector3(0.0, 4.1, 0.0), Vector3(6.4, 0.3, 6.4), Color(0.72, 0.70, 0.66))

	_add_box(Vector3(-1.2, 0.6, -0.6), Vector3(0.9, 1.2, 0.9), Color(0.74, 0.72, 0.68))
	_add_box(Vector3(1.4, 0.4, 0.4), Vector3(1.1, 0.8, 0.7), Color(0.70, 0.68, 0.62))
	for i in range(6):
		_add_box(Vector3(0.0, 2.6, -1.6 + float(i) * 0.7), Vector3(4.4, 0.12, 0.22),
				Color(0.58, 0.52, 0.44))
	_add_sphere(Vector3(-0.4, 0.55, 1.1), 0.55, Color(0.80, 0.78, 0.74))
	_add_sphere(Vector3(1.9, 0.45, -1.5), 0.45, Color(0.85, 0.80, 0.70))

	_add_emitter()
	return env


## Front-face-only emission, matching lights_eval_rect_light: a QuadMesh faces +Z
## and rotating +90 degrees about X takes +Z to -Y, so the panel emits DOWN into
## the room. Flipped, the room goes black. The only emissive instance in the scene.
func _add_emitter() -> void:
	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(_emitter_size, _emitter_size)
	panel.mesh = quad
	panel.position = Vector3(0.0, 3.5, 0.0)
	panel.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0, 0, 0)
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.emission_enabled = true
	m.emission = Color(1.0, 1.0, 1.0)
	m.emission_energy_multiplier = _emitter_energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = m
	add_child(panel)


func _add_box(p_pos: Vector3, p_size: Vector3, p_col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = p_size
	mi.mesh = bm
	mi.position = p_pos
	mi.material_override = _diffuse_material(p_col)
	add_child(mi)


func _add_sphere(p_pos: Vector3, p_radius: float, p_col: Color) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = p_radius
	sm.height = p_radius * 2.0
	sm.radial_segments = 48
	sm.rings = 24
	mi.mesh = sm
	mi.position = p_pos
	mi.material_override = _diffuse_material(p_col)
	add_child(mi)


func _diffuse_material(p_col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_col
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	return mat
