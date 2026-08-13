extends "res://tests/pt_validation.gd"

## C1 Task 4 SHADER-COMPILE PROBE, and the brightness reading that goes with it.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_emissive_compile_scene.tscn
##
## This is NOT the C1 energy gate -- Task 6 owns that. It exists for one narrow
## reason: RD shaders are compiled at RUNTIME by ShaderRD, and
## EmissiveLights::_ensure_shader() is LAZY, so until something actually enables
## `rendering/pathtracer/emissive_mesh_lights` on a scene that has emissive
## geometry in it, emissive_area_build.glsl has never been handed to glslang at
## all. A syntax error in it would sit undetected and the failure mode is silent:
## zero-filled buffers, an empty distribution, a feature that is quietly inert.
## The same is true of the raytracing NEE code, which only reaches glslang when a
## raygen variant carrying RT_FLAG_EMISSIVE_LIGHTS_ENABLED is compiled.
##
## So: render a few real path-traced frames with the setting OFF, then with it
## ON, and print both means. Any compile failure surfaces as an ERROR line on
## stderr from ShaderRD / RenderingDevice.
##
## THE BRIGHTNESS DELTA IS NOW EXPECTED TO BE ~ZERO, and that is the point.
## Emissive NEE finds the emitter far more reliably than a BSDF ray stumbling
## onto it, but MIS (Task 5) splits the two strategies with weights that sum to
## one, so turning the feature on must change the VARIANCE of this image and not
## its MEAN. It is a redistribution, not extra light.
##
## Before Task 5 this read +99.7% -- NEE's contribution added on top of an
## unweighted emissive hit. That number is what the MIS partition removed, and
## the tolerance below is what stops it coming back.
##
## Env vars:
##   ZR_EMI_FRAMES  accumulated frames per pass  (default 64)
##   ZR_EMI_RES     square render resolution     (default 192)

const SETTING := "rendering/pathtracer/emissive_mesh_lights"
const ALBEDO := 0.5

var _res := 192
var _frames := 64
var _failures: Array[String] = []


func _ready() -> void:
	var r_env := OS.get_environment("ZR_EMI_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	var f_env := OS.get_environment("ZR_EMI_FRAMES")
	if f_env.is_valid_int():
		_frames = maxi(8, f_env.to_int())

	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))

	var env := _build_scene()
	await get_tree().create_timer(2.0).timeout

	# Empty is the readback-failed sentinel.
	var off: Dictionary = await _pass(env, false)
	var on: Dictionary = await _pass(env, true)

	print("\n=== RESULT ===")
	if off.is_empty() or on.is_empty():
		_failures.append("accumulator readback returned null")
	else:
		var d: float = on["mean"] - off["mean"]
		var rel: float = d / maxf(off["mean"], 1e-9)
		print("  emissive NEE OFF : %.6f   (std-dev %.6f, noise sigma %.6f)"
				% [off["mean"], off["sd"], off["noise"]])
		print("  emissive NEE ON  : %.6f   (std-dev %.6f, noise sigma %.6f)"
				% [on["mean"], on["sd"], on["noise"]])
		print("  delta            : %+.6f  (%+.3f%%)" % [d, rel * 100.0])
		print("  A near-ZERO delta is correct: MIS redistributes the emitter, it does not add light.")

		# THE BAND IS DERIVED FROM THIS RUN'S OWN NOISE, not hardcoded. The
		# previous 3% was calibrated by hand against one scene at one frame count
		# and said nothing about any other; at ZR_EMI_FRAMES=2048 it is ~24 sigma
		# and effectively vacuous, while on a dimmer emitter it could be tighter
		# than the measurement can resolve. The standard error comes from the
		# HIGH-PASS noise sigma (adjacent-pixel first differences), which cancels
		# the smooth spatial signal and leaves the pixel-independent Monte Carlo
		# noise; the plain std-dev would set the band by how contrasty the scene
		# is instead.
		#
		# Two-sided, because the two failures are different bugs and both are
		# silent. Above the band: the MIS weight is not reaching the emissive hit
		# and the surface is counted twice again (the +99.7% Task 5 removed).
		# Below it: energy is being deleted rather than redistributed -- e.g. the
		# reverse pdf disagreeing with the forward one, which drives the BSDF half
		# to ~0 without NEE picking the difference up.
		var se_rel: float = sqrt(off["se"] * off["se"] + on["se"] * on["se"]) / maxf(off["mean"], 1e-9)
		var tol: float = clampf(6.0 * se_rel, 0.002, 0.03)
		print("  combined standard error : %.4f%% relative" % (se_rel * 100.0))
		print("  derived band (6 se, clamped to [0.2%%, 3%%]) : %.3f%%" % (tol * 100.0))
		# A NaN satisfies `> tol` AND `< tol`, so it passes every bound silently.
		# It has to be rejected before either comparison, not after.
		if is_nan(rel) or is_inf(rel):
			_failures.append("relative delta is not a finite number (%f) -- one of the two means is NaN, or the OFF mean is zero" % rel)
		elif absf(rel) > tol:
			_failures.append("MIS does not conserve energy: ON is %+.3f%% off OFF (derived band %.3f%%). %s"
					% [rel * 100.0, tol * 100.0,
					"Above the band means the emissive hit is unweighted (double count)."
							if rel > 0.0 else "Below it means the weight is deleting energy."])

		# LIVENESS. The mean cannot carry this -- the assertion above is that the
		# means AGREE, and they agree just as well when the NEE block never fires.
		# The per-pixel spread is what differs between a working build and an inert
		# one. The old `absf(rel) < 1e-9` check was four orders of magnitude below
		# the live delta (0.26%) and would have passed an entirely dead feature
		# whose two passes happened to differ by any noise at all.
		if not (on["sd"] < off["sd"]):
			_failures.append("liveness: per-pixel spread did not fall (OFF %.6f, ON %.6f). The NEE block is probably not running at all (stale .glsl.gen.h, or the spec-constant flag never reached the shader)"
					% [off["sd"], on["sd"]])

	if _failures.is_empty():
		print("PASS - shaders compiled and the emissive NEE path is live.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


func _pass(p_env: Environment, p_enabled: bool) -> Dictionary:
	ProjectSettings.set_setting(SETTING, p_enabled)
	print("\n=== %s emissive_mesh_lights ===" % ("ENABLE" if p_enabled else "DISABLE"))
	# The setting drives a specialization constant, so flipping it forces a fresh
	# raygen pipeline compile. Give that (and the first EmissiveLights build) room
	# to land before the measured frames start.
	for _i in range(30):
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout

	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), _frames)
	if img == null:
		return {}
	var stats := _measure_crop(img, 0.2, 0.8)
	stats["sd"] = _stddev_crop(img, stats["mean"], 0.2, 0.8)
	stats["noise"] = _noise_sigma_crop(img, 0.2, 0.8)
	stats["se"] = stats["noise"] / sqrt(float(maxi(stats["n"], 1)))
	print("  MEAN      : %.6f   (R %.6f  G %.6f  B %.6f over %d px)"
			% [stats["mean"], stats["r"], stats["g"], stats["b"], stats["n"]])
	print("  std-dev   : %.6f" % stats["sd"])
	print("  noise sig : %.6f   (adjacent-pixel high pass; std-dev with the" % stats["noise"])
	print("              scene's own spatial variation removed)")
	if stats["sd"] <= 1e-7:
		_failures.append("zero per-pixel spread with the setting %s - nothing stochastic is running"
				% ("ON" if p_enabled else "OFF"))
	return stats


func _measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	var inv := 1.0 / float(maxi(n, 1))
	r *= inv
	g *= inv
	b *= inv
	return { "r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n }


## Per-pixel MONTE CARLO noise, isolated from the image's real spatial variation.
## Adjacent pixels share the signal but carry independent noise, so the standard
## deviation of first differences is sqrt(2) times the noise alone. This is what
## the derived energy band above is computed from; `_stddev_crop` mixes signal
## into the estimate and would set the band by how contrasty the scene is.
func _noise_sigma_crop(p_img: Image, p_lo: float, p_hi: float) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	var x_end := int(w * p_hi) - 1
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), x_end):
			var a := p_img.get_pixel(x, y)
			var b := p_img.get_pixel(x + 1, y)
			var d := ((a.r + a.g + a.b) - (b.r + b.g + b.b)) / 3.0
			acc += d * d
			n += 1
	return sqrt(acc / float(maxi(n, 1)) * 0.5)


func _stddev_crop(p_img: Image, p_mean: float, p_lo: float, p_hi: float) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0 - p_mean
			acc += v * v
			n += 1
	return sqrt(acc / float(maxi(n, 1)))


# ---------------------------------------------------------------------------
# Scene: one Lambertian floor lit ONLY by an emissive quad above it.
#
# No sky (BG_COLOR black, so environment NEE is inert) and no analytic lights, so
# every photon in the image came through the path under test -- either found by
# emissive NEE or stumbled onto by a BSDF ray.
# ---------------------------------------------------------------------------
func _build_scene() -> Environment:
	for c in get_children():
		c.queue_free()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(3)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias and would eat exactly the energy this measures.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.position = Vector3(0.0, 2.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(cam)
	cam.make_current()

	var floor_node := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(200.0, 0.2, 200.0)
	floor_node.mesh = bm
	floor_node.position = Vector3(0.0, -0.1, 0.0)
	var mat := StandardMaterial3D.new()
	# render_raytracing.cpp runs albedo_color through srgb_to_linear() before it
	# reaches the BRDF; pre-encode so the shader ends up with exactly ALBEDO.
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb()
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	floor_node.material_override = mat
	add_child(floor_node)

	# The emitter: a small box well above the floor and clear of the camera's
	# 2.0-unit height, so it lights the measured crop without occluding it. SMALL
	# on purpose -- a large emitter is easy for BSDF rays to find and the NEE path
	# would barely register.
	var emitter := MeshInstance3D.new()
	var em := BoxMesh.new()
	em.size = Vector3(0.6, 0.05, 0.6)
	emitter.mesh = em
	emitter.position = Vector3(0.0, 5.0, 0.0)
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(0, 0, 0)
	emat.roughness = 1.0
	emat.metallic = 0.0
	emat.metallic_specular = 0.0
	emat.emission_enabled = true
	emat.emission = Color(1.0, 0.85, 0.6)
	emat.emission_energy_multiplier = 40.0
	emitter.material_override = emat
	add_child(emitter)

	return env
