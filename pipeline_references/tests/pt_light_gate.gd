extends "res://tests/pt_validation.gd"

## Path-tracer ENERGY gates for ANALYTIC-LIGHT SELECTION (roadmap C2).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_light_gate_scene.tscn
##
## Both gates render the same trivially-analysable scene -- one unoccluded
## Lambertian plane of albedo 0.5, camera looking straight down, NO sky
## (BG_COLOR black, so environment NEE is inert by construction and every photon
## in the image came through the analytic-light path under test) -- and differ
## only in whether the lights are all in range.
##
## Run each gate TWICE: once with RT_LIGHT_SELECT_UNIFORM 1 (the pre-C2 uniform
## k=16 mini-batch reservoir) and once with 0 (the power-weighted CDF), each
## after a FULL `scons platform=windows target=editor` so the raygen
## .glsl.gen.h actually regenerates. Feed the first run's mean back in through
## ZR_GATE_REF so the second run does the comparison itself.
##
## Env vars:
##   ZR_GATE_MODE    "in_range" | "culled" | "both"   (default "both")
##   ZR_GATE_FRAMES  accumulated frames per gate      (default 256)
##   ZR_GATE_RES     square render resolution         (default 256)
##   ZR_GATE_REF     reference mean for THIS mode; "in_range,culled" when both
##
## ---------------------------------------------------------------------------
## GATE 1 - "in_range". NEUTRALITY IS THE CORRECT ASSERTION HERE.
##
## Every light is within range at every shaded point, so the pre-C2 estimator was
## EXACT: no light fails the range test, valid_found == k deterministically, so
## valid_count_estimate == light_count with zero variance and 1/estimate is the
## true density. Both estimators are therefore unbiased for the same integral and
## the converged mean MUST NOT MOVE. A shift here is a BUG in the C2 selector,
## not a finding, and this gate FAILS on it.
##
## The light energies are deliberately UNEQUAL (1.0 .. 8.5). Equal energies make
## the power weight a constant, the CDF degenerate to uniform, and the gate blind
## to the thing it is gating.
##
## ---------------------------------------------------------------------------
## GATE 2 - "culled". NEUTRALITY IS *NOT* ASSERTED, ON PURPOSE.
##
## Half the lights are out of range at the floor. The pre-C2 pdf was genuinely
## BIASED in that configuration -- valid_found is a random variable and
## E[1/X] != 1/E[X] -- so the converged mean SHOULD move, and asserting
## neutrality here would be asserting the bug. This gate REPORTS the signed shift
## and never fails on it. The direction was predicted before it was measured:
## see .superpowers/sdd/2026-08-11-power-weighted-light-selection/gate2-prediction.md
##
## Gate 2 doubles as the LIVENESS PROBE for the A/B: it is a configuration where
## the two builds must read DIFFERENTLY. Two identical readings mean the macro
## edit never reached the shader (stale .glsl.gen.h from an incremental build),
## not that the change is neutral.

const ALBEDO := 0.5 # LINEAR reflectance.
const TOLERANCE := 0.01 # 1 percent, matching pt_energy_gate.gd's gate 1.
const LIGHT_COUNT := 16

## Captured at 256 frames / 256x256 from the RT_LIGHT_SELECT_UNIFORM 1 build
## (the pre-C2 uniform reservoir), commit bfaa512a93 with only that macro
## flipped. Gate 1 asserts against it; gate 2 only reports against it.
## ZR_GATE_REF overrides both.
const REF_IN_RANGE := 0.0 # filled in after the control run
const REF_CULLED := 0.0 # filled in after the control run

var _res := 256
var _plane: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated path-traced run would
	# take hours. Disable content scaling so the viewport follows the window.
	var r_env := OS.get_environment("ZR_GATE_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))

	var frames := 256
	var f_env := OS.get_environment("ZR_GATE_FRAMES")
	if f_env.is_valid_int():
		frames = maxi(32, f_env.to_int())

	var mode := OS.get_environment("ZR_GATE_MODE")
	if mode == "":
		mode = "both"

	var refs := _parse_refs(mode)

	if mode == "in_range" or mode == "both":
		await _gate("in_range", frames, refs[0])
	if mode == "culled" or mode == "both":
		await _gate("culled", frames, refs[1])

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - light-selection energy gates green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


## ZR_GATE_REF is "in_range,culled" in "both" mode and a single number otherwise.
func _parse_refs(p_mode: String) -> Array:
	var out := [REF_IN_RANGE, REF_CULLED]
	var s := OS.get_environment("ZR_GATE_REF")
	if s == "":
		return out
	var parts := s.split(",", false)
	if p_mode == "both":
		if parts.size() >= 2:
			out[0] = parts[0].strip_edges().to_float()
			out[1] = parts[1].strip_edges().to_float()
	elif parts.size() >= 1:
		var v := parts[0].strip_edges().to_float()
		if p_mode == "in_range":
			out[0] = v
		else:
			out[1] = v
	return out


func _gate(p_mode: String, p_frames: int, p_ref: float) -> void:
	var env := _build_scene(p_mode)
	# Give the TLAS build and the light buffer upload a moment to land.
	await get_tree().create_timer(2.0).timeout

	var in_range := p_mode == "in_range"
	print("\n=== GATE %d: %s (%d omni lights, energies 1.0 .. %.1f) ==="
			% [1 if in_range else 2, p_mode, LIGHT_COUNT,
			1.0 + float(LIGHT_COUNT - 1) * 0.5])
	if in_range:
		print("  every light in range -- the pre-C2 estimator was EXACT here, so the")
		print("  converged mean MUST NOT move. A shift is a bug, not a finding.")
	else:
		print("  %d of %d lights out of range at the floor -- the pre-C2 pdf was BIASED"
				% [LIGHT_COUNT / 2, LIGHT_COUNT])
		print("  here, so the mean SHOULD move. Neutrality is NOT asserted.")

	var t0 := Time.get_ticks_msec()
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	var dt := Time.get_ticks_msec() - t0
	if img == null:
		_failures.append("gate %s: accumulator readback returned null" % p_mode)
		return

	var stats := _measure_crop(img, 0.25, 0.75)
	var sd := _stddev_crop(img, stats["mean"], 0.25, 0.75)
	print("  %d frames in %d ms (%.3f ms/frame at %dx%d)"
			% [p_frames, dt, float(dt) / float(p_frames), _res, _res])
	print("  MEAN      : %.6f   (R %.6f  G %.6f  B %.6f over %d px)"
			% [stats["mean"], stats["r"], stats["g"], stats["b"], stats["n"]])
	print("  std-dev   : %.6f" % sd)

	if sd <= 1e-7:
		_failures.append("gate %s liveness: zero per-pixel spread - nothing stochastic is running" % p_mode)

	if p_ref <= 0.0:
		print("  (no reference supplied - record this as the %s baseline)" % p_mode)
		return

	var d: float = stats["mean"] - p_ref
	var rel: float = d / maxf(p_ref, 1e-9)
	print("  reference : %.6f" % p_ref)
	print("  delta     : %+.6f  (%+.3f%%)" % [d, rel * 100.0])

	if in_range:
		if absf(rel) > TOLERANCE:
			_failures.append("gate 1 neutrality: %.6f vs reference %.6f, %+.3f%% (limit %.1f%%). Every light is in range, so both estimators are unbiased for the same integral; a shift here is a defect in the C2 selector."
					% [stats["mean"], p_ref, rel * 100.0, TOLERANCE * 100.0])
	else:
		print("  gate 2 does not assert. Direction only:")
		if absf(rel) < 1e-4:
			print("    NO MEASURABLE SHIFT - if these are two different builds, suspect a")
			print("    stale .glsl.gen.h: the A/B macro may not have reached the shader.")
		elif d < 0.0:
			print("    this build reads LOWER than the reference.")
		else:
			print("    this build reads HIGHER than the reference.")


# ---------------------------------------------------------------------------
# Measurement (same shapes as pt_energy_gate.gd)
# ---------------------------------------------------------------------------
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
# Scene
# ---------------------------------------------------------------------------
func _build_scene(p_mode: String) -> Environment:
	for c in get_children():
		c.queue_free()

	var env := Environment.new()
	# No sky at all: render_raytracing.cpp binds DEFAULT_RD_TEXTURE_BLACK, every
	# environment CDF cell has luminance 0 and env_sample() returns false on its
	# first branch. Environment NEE is inert, so the analytic-light path is the
	# only source of light in the image.
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
	# Clamping is a deliberate bias and would eat exactly the energy these gates
	# measure -- a heavy-tailed selection estimator is precisely what it clips.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	# Adaptive sampling freezes converged pixels; these gates want the
	# un-accelerated estimator.
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(_cam)
	_cam.make_current()

	# The floor: a thin box so the top face is a genuine single-sided surface
	# under back-face culling, and wide enough that its edges are far outside the
	# view.
	_plane = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(200.0, 0.2, 200.0)
	_plane.mesh = bm
	_plane.position = Vector3(0.0, -0.1, 0.0)
	var mat := StandardMaterial3D.new()
	# render_raytracing.cpp runs albedo_color through srgb_to_linear() before it
	# reaches the BRDF; pre-encode so the shader ends up with exactly ALBEDO.
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb()
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Kills the dielectric specular lobe (F0 = 0.16 * specular^2), leaving a pure
	# Lambertian BRDF. At the default specular = 0.5 the surface still carries an
	# F0 = 0.04 lobe and the gate stops being a clean diffuse measurement.
	mat.metallic_specular = 0.0
	_plane.material_override = mat
	add_child(_plane)

	if p_mode == "in_range":
		_build_in_range(self)
	else:
		_build_culled(self)

	return env


## GATE 1 - every light within range.
func _build_in_range(root: Node) -> void:
	for i in range(LIGHT_COUNT):
		var l := OmniLight3D.new()
		var a := TAU * float(i) / float(LIGHT_COUNT)
		l.position = Vector3(cos(a) * 3.0, 4.0, sin(a) * 3.0)
		l.omni_range = 100.0 # far beyond any surface distance
		l.light_energy = 1.0 + float(i) * 0.5 # deliberately unequal: equal
		                                      # energies make power weighting a
		                                      # no-op and the gate blind
		l.light_color = Color(1, 1, 1)
		root.add_child(l)


## GATE 2 - half the lights out of range at the sampled surface. The odd-indexed
## lights sit sqrt(3^2 + 4^2) = 5.0 from the floor origin with a range of 2.0, so
## they are culled everywhere in the measured crop -- not marginally, decisively.
func _build_culled(root: Node) -> void:
	for i in range(LIGHT_COUNT):
		var l := OmniLight3D.new()
		var a := TAU * float(i) / float(LIGHT_COUNT)
		l.position = Vector3(cos(a) * 3.0, 4.0, sin(a) * 3.0)
		l.omni_range = 100.0 if (i % 2 == 0) else 2.0
		l.light_energy = 1.0 + float(i) * 0.5
		l.light_color = Color(1, 1, 1)
		root.add_child(l)
