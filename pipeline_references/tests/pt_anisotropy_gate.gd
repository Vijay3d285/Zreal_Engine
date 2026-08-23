extends "res://tests/pt_validation.gd"

## E2b GPU gate: anisotropic GGX (Task 4).
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_anisotropy_gate_scene.tscn
##
## Two probes, both against a metallic sphere viewed OFF the world-Z axis on
## purpose -- see the camera comment in _build_scene for why that matters.
##
## PROBE 1 -- white furnace sweep.
##
## A perfectly reflective, non-absorbing surface (albedo 1, metallic 1) under
## a uniform sky must return exactly the sky's radiance in every direction,
## for ANY energy-conserving BRDF -- roughness and anisotropy only redistribute
## where the energy goes, never how much of it comes back. This is the only
## gate that exercises the anisotropic branch at NON-ZERO anisotropy: Task 3's
## C1 fix (a missing 1/(4*NdotL*NdotV) factor, a geometry-dependent 0-4x
## brightness error in evalMicrofacet's anisotropic branch) lives entirely
## inside `if (data.anisoActive)`, and the CPU-mirror doctest that also covers
## it computes the division itself rather than executing the shader, so it
## would not fail if the real fix were reverted. anisotropy == 0.0 is kept in
## the sweep as a control (it must ALSO read 1.0, proving the isotropic path
## is undisturbed), but it is not, by itself, evidence about the anisotropic
## branch.
##
## PROBE 2 -- pdf/sampler parity (vis mode 35).
##
## Per-pixel comparison of the density sampleSpecularMicrofacet actually
## realises (R) against what combinedPdf -- the SAME function shade_and_bounce
## calls for mis_ray_pdf -- reports for that exact direction (G). A desync
## here is the B2 defect class: two MIS strategies estimating different
## integrands, which no rendered mean can ever reveal (mean-preserving by
## construction). Task 3 needed two frame fixes for this (a world-to-local
## transform in evalMicrofacet, and pre-rotating the tangent before
## prepareBRDFData) that are load-bearing ONLY when the shading normal is not
## already world Z -- getRotationToZAxis((0,0,1)) is the identity and hides
## both. Run ONLY at non-zero anisotropy (anisotropy 0 leaves anisoPhi == 0
## and anisoActive == false, so the frame-rotation code this probe exists to
## guard never executes) and across a sphere, which presents a whole cone of
## normals away from Z at once. See raytracing_closest_hit_common_inc.glsl's
## vis_mode == 35 block for the full construction.

const SKY_RADIANCE := 1.0
const TOLERANCE := 0.02 # furnace, 2% per the brief.
const PDF_TOLERANCE := 1e-4 # per-pixel |R - G|, per the brief.
const FURNACE_FRAMES := 32
const PDF_FRAMES := 4
const MODE_ANISO_PDF_PARITY := 35

const ANISOTROPY_VALUES := [-0.9, -0.5, 0.0, 0.5, 0.9]
const ROTATION_VALUES := [0.0, PI / 4.0, PI / 2.0]

# Non-zero only, and deliberately NOT the full ANISOTROPY_VALUES sweep --
# every value here must exercise the anisotropic branch (anisotropy 0 would
# prove nothing about it, see the header comment above).
const PDF_PARITY_ANISOTROPY_VALUES := [-0.9, -0.5, 0.5, 0.9]
const PDF_PARITY_ROTATION_VALUES := [0.0, PI / 4.0]

var _sphere: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []


func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


func _build_scene() -> Environment:
	for c in get_children():
		c.queue_free()

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = _constant_panorama()
	sky_mat.energy_multiplier = 1.0

	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	# BG_SKY with a real Sky resource is MANDATORY -- BG_COLOR renders pure
	# black to the path tracer (render_raytracing.cpp; roadmap F3).
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(3)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias; it must be off or it eats the very energy
	# probe 1 is measuring.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	_sphere.mesh = sm
	add_child(_sphere)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 20.0
	# Camera axis (1,1,1) is deliberately NOT aligned with any world axis, and
	# in particular not with +Z. The sphere point directly ahead of the camera
	# has world-space shading normal ~= normalize(1,1,1); getRotationToZAxis on
	# a normal that IS world Z is the identity, which would silently hide both
	# of Task 3's frame fixes (see the header comment and the vis_mode == 35
	# block in raytracing_closest_hit_common_inc.glsl).
	#
	# Distance 2.5 from a radius-1.0 sphere gives an apparent angular radius of
	# asin(1.0 / 2.5) = 23.58 deg. A 20 deg vertical FOV on a square 256x256
	# viewport (KEEP_HEIGHT, aspect 1:1) has a DIAGONAL half-angle of
	# atan(tan(10 deg) * sqrt(2)) = 14.0 deg -- comfortably inside the sphere's
	# cone with ~9.6 deg of margin, so EVERY pixel in the render is a sphere
	# hit and none is background sky. That matters for both probes: a
	# background pixel would trivially read L == SKY_RADIANCE regardless of
	# surface correctness (probe 1) or carry no vis-mode-35 payload at all,
	# since that GLSL block only runs on a closest hit (probe 2) -- either
	# would silently pollute the measurement.
	_cam.position = Vector3(1.4433757, 1.4433757, 1.4433757) # normalize(1,1,1) * 2.5
	_cam.make_current()
	_cam.look_at(Vector3.ZERO, Vector3.UP)

	get_viewport().world_3d.environment = env
	return env


func _sphere_material(p_anisotropy: float, p_rotation: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# LOAD-BEARING: albedo_color must be pre-encoded. render_raytracing.cpp:
	# 1540-1542 runs albedo_color through srgb_to_linear() on upload.
	# Color(1,1,1) round-trips to 1.0 either way, but pre-encoding anyway
	# keeps the pattern correct if this value is ever changed to something
	# that does NOT round-trip -- this exact trap produced a phantom 53%
	# energy loss in E2a. Do not "simplify" it away.
	m.albedo_color = Color(1.0, 1.0, 1.0).linear_to_srgb()
	m.metallic = 1.0
	m.roughness = 0.4
	# BaseMaterial3D forces the anisotropy shader param to 0.0 unless this
	# feature flag is on (scene/resources/material.cpp:2285/2641), regardless
	# of what `anisotropy` is set to.
	m.anisotropy_enabled = true
	m.anisotropy = p_anisotropy
	m.anisotropy_rotation = p_rotation
	return m


## Mean over an axis-aligned crop given as fractions of the image.
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
	return { "r": r * inv, "g": g * inv, "b": b * inv,
			"mean": (r + g + b) * inv / 3.0, "n": n }


## Largest per-pixel |R - G| (vis mode 35's red/green channels) over an
## axis-aligned crop given as fractions of the image. NaN pixels (a
## near-degenerate V ~= -L half-vector, see the vis_mode == 35 comment)
## compare false against `max_diff` in GDScript's IEEE-754 semantics and are
## therefore skipped rather than falsely flagged or falsely hidden behind a
## larger legitimate diff.
func _max_abs_rg_diff(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var max_diff := 0.0
	var max_x := -1
	var max_y := -1
	var max_r := 0.0
	var max_g := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			var d := absf(c.r - c.g)
			n += 1
			if d > max_diff:
				max_diff = d
				max_x = x
				max_y = y
				max_r = c.r
				max_g = c.g
	return { "max_diff": max_diff, "x": max_x, "y": max_y, "r": max_r, "g": max_g, "n": n }


func _probe_furnace(p_env: Environment) -> void:
	print("\n=== PROBE 1: white furnace, anisotropic GGX sweep ===")
	print("  sky radiance %.5f, tolerance %.1f%%" % [SKY_RADIANCE, TOLERANCE * 100.0])
	var vp_rid := get_viewport().get_viewport_rid()
	var worst_ratio := 1.0
	var worst_label := ""
	for aniso in ANISOTROPY_VALUES:
		for rot in ROTATION_VALUES:
			_sphere.material_override = _sphere_material(aniso, rot)
			var img: Image = await _render_accum(p_env, vp_rid, FURNACE_FRAMES)
			var tag := "anisotropy=%.2f rotation=%.4f" % [aniso, rot]
			if img == null:
				_failures.append("probe1 furnace [%s]: accumulator readback returned null" % tag)
				continue
			var s := _measure_crop(img, 0.05, 0.95)
			var ratio: float = s["mean"] / SKY_RADIANCE
			print("  %-34s mean=%.6f  ratio=%.6f  (n=%d)" % [tag, s["mean"], ratio, s["n"]])
			if absf(ratio - 1.0) > absf(worst_ratio - 1.0):
				worst_ratio = ratio
				worst_label = tag
			if absf(ratio - 1.0) > TOLERANCE:
				_failures.append(("probe1 furnace [%s]: ratio %.6f vs 1.0 (limit %.1f%%) -- an " +
						"energy-conserving BRDF must return the sky radiance regardless of ax/ay")
						% [tag, ratio, TOLERANCE * 100.0])
	print("  worst deviation: %s  ratio=%.6f" % [worst_label, worst_ratio])


func _probe_pdf_parity(p_env: Environment) -> void:
	print("\n=== PROBE 2: anisotropic pdf/sampler parity (vis mode %d) ===" % MODE_ANISO_PDF_PARITY)
	print("  per-pixel |R - G| < %.6f across the sphere" % PDF_TOLERANCE)
	var vp_rid := get_viewport().get_viewport_rid()
	p_env.set_pathtracing_debug_mode(MODE_ANISO_PDF_PARITY)
	for aniso in PDF_PARITY_ANISOTROPY_VALUES:
		for rot in PDF_PARITY_ROTATION_VALUES:
			_sphere.material_override = _sphere_material(aniso, rot)
			var img: Image = await _render_accum(p_env, vp_rid, PDF_FRAMES)
			var tag := "anisotropy=%.2f rotation=%.4f" % [aniso, rot]
			if img == null:
				_failures.append("probe2 pdf parity [%s]: accumulator readback returned null" % tag)
				continue
			var stats := _max_abs_rg_diff(img, 0.05, 0.95)
			print("  %-34s n=%d  max|R-G|=%.8f  at (%d,%d)  R=%.6f G=%.6f"
					% [tag, stats["n"], stats["max_diff"], stats["x"], stats["y"], stats["r"], stats["g"]])
			if stats["max_diff"] > PDF_TOLERANCE:
				_failures.append(("probe2 pdf parity [%s]: max|R-G| %.8f at pixel (%d,%d) " +
						"(R=%.6f G=%.6f) exceeds %.6f -- the sampler and the pdf report have desynced")
						% [tag, stats["max_diff"], stats["x"], stats["y"], stats["r"], stats["g"], PDF_TOLERANCE])
	# Clear the debug mode afterwards per the brief -- leaving it set would
	# make every subsequent render in this process emit pdf-parity channels
	# instead of colour.
	p_env.set_pathtracing_debug_mode(0)


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	# The sky pass renders the radiance octmap and the env CDF is built from
	# it; both need a moment before the first measurement (matches
	# pt_sky_energy_gate.gd's pattern).
	await get_tree().create_timer(2.0).timeout

	await _probe_furnace(env)
	await _probe_pdf_parity(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - anisotropic GGX gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)
