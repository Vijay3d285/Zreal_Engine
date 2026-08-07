extends PTValidation

## Standalone Phase A verification runner.
##
## Builds a small path-traced scene, then runs the two checks that cannot be
## proven from code alone:
##   check 2 — convergence: RMSE must fall ~1/sqrt(N) with no flat tail
##             (this is what proves the fp32 accumulator fix)
##   check 3 — anti-aliasing: a high-contrast diagonal edge must resolve
##             intermediate tones (this is what proves camera jitter works)
##
## Run it (from the repo root, with a GPU — this cannot run headless because it
## needs the Vulkan RT pipeline):
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
##
## Optional env vars:
##   ZR_VAL_REFERENCE   frames for the reference render   (default 1024)
##   ZR_VAL_COUNTS      comma-separated sweep             (default "16,64,256,512")
##   ZR_VAL_NOISE       adaptive threshold during the run (default 0 = off)
##
## Exit code is 0 when both checks pass, 1 otherwise, so it can gate CI later.

var _failures: Array[String] = []

func _ready() -> void:
	# Give the RT pipeline a moment to build TLAS/BLAS and compile shaders.
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()

	await get_tree().create_timer(1.0).timeout

	print("\n=== Phase A verification ===")
	print("Renderer: %s" % ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))

	await _check_convergence(env)
	await _check_anti_aliasing(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS — both checks green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL — %s" % f)
		get_tree().quit(1)


## check 2 — the accumulator must keep converging at high sample counts.
func _check_convergence(p_env: Environment) -> void:
	var reference := 1024
	var r_env := OS.get_environment("ZR_VAL_REFERENCE")
	if r_env.is_valid_int():
		reference = maxi(64, r_env.to_int())

	var counts: Array = [16, 64, 256, 512]
	var c_env := OS.get_environment("ZR_VAL_COUNTS")
	if c_env != "":
		counts = []
		for part in c_env.split(",", false):
			if part.strip_edges().is_valid_int():
				counts.append(part.strip_edges().to_int())

	print("\n[check 2] convergence — sweep %s against a %d-frame reference" % [str(counts), reference])
	print("          (this renders %d frames total; be patient)" % [reference + _sum(counts)])

	var results := await convergence_curve(p_env, counts, reference)
	if results.is_empty():
		_failures.append("convergence: no results returned (readback failed?)")
		return

	# report_convergence asserts; in a release build asserts are stripped, so we
	# also evaluate the same two conditions explicitly and record them.
	report_convergence(results)

	var first: float = results[0]["rmse"]
	var last: float = results[results.size() - 1]["rmse"]
	if last >= first * 0.5:
		_failures.append("convergence: RMSE only fell %.2fx across the sweep (need >2x)" % [first / maxf(last, 1e-9)])
	if results.size() >= 2:
		var prev: float = results[results.size() - 2]["rmse"]
		if last >= prev * 0.98:
			_failures.append("convergence: FLAT TAIL — RMSE stopped falling at high sample counts (%.6f -> %.6f). This is the fp16-style stall." % [prev, last])


## check 3 — jitter must produce real anti-aliasing on a hard silhouette.
func _check_anti_aliasing(p_env: Environment) -> void:
	print("\n[check 3] anti-aliasing — 256-frame accumulation, diagonal edge")
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 256)
	if img == null:
		_failures.append("anti-aliasing: accumulator readback returned null")
		return

	# Sample several scanlines; the diagonal edge crosses all of them.
	var best := 0
	for frac in [0.35, 0.5, 0.65]:
		var y := int(img.get_height() * frac)
		best = maxi(best, PTValidation.edge_gradient_steps(img, y))
	print("          max intermediate-tone pixels across scanlines: %d" % best)
	if best < 3:
		_failures.append("anti-aliasing: only %d intermediate tones on the edge (need >=3). Camera jitter is not taking effect." % best)


func _sum(p_arr: Array) -> int:
	var t := 0
	for v in p_arr:
		t += int(v)
	return t


## Builds a deliberately simple, noisy-but-convergent path-traced scene:
## a diffuse room lit by one small bright light (produces indirect noise), with
## a bright emissive slab rotated 45 degrees to give a hard diagonal silhouette.
func _build_scene() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)          # raw radiance: we are measuring the estimator
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)

	var noise := 0.0
	var n_env := OS.get_environment("ZR_VAL_NOISE")
	if n_env.is_valid_float():
		noise = maxf(0.0, n_env.to_float())
	env.set_pathtracing_noise_threshold(noise)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 4.2)
	cam.fov = 55.0
	add_child(cam)
	cam.make_current()

	# Room: floor + back wall + one side wall, plain diffuse (colour bleeding = indirect noise).
	_add_box(Vector3(0, -0.05, 0), Vector3(8, 0.1, 8), Color(0.72, 0.70, 0.68))
	_add_box(Vector3(0, 2.0, -3.0), Vector3(8, 4.2, 0.1), Color(0.70, 0.32, 0.28))
	_add_box(Vector3(-3.0, 2.0, 0), Vector3(0.1, 4.2, 8), Color(0.30, 0.55, 0.32))

	# Small bright light: high contrast, real indirect bounce, plenty of variance.
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(1.4, 3.0, 1.0)
	lamp.light_energy = 12.0
	lamp.omni_range = 14.0
	add_child(lamp)

	# The AA target: a bright emissive slab rolled 45 degrees so its silhouette is
	# diagonal in screen space. Without jitter this edge stays hard-aliased forever.
	var slab := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.6, 1.6, 0.08)
	slab.mesh = bm
	slab.position = Vector3(0.0, 1.6, 0.0)
	slab.rotation_degrees = Vector3(0, 0, 45)
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(1, 1, 1)
	em.emission_enabled = true
	em.emission = Color(1, 1, 1)
	em.emission_energy_multiplier = 6.0
	slab.material_override = em
	add_child(slab)

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
	mi.material_override = mat
	add_child(mi)
