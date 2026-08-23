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
## PROBE 1b -- white furnace, NEE-dominant configuration (fix round 1, I6).
##
## Probe 1's roughness=0.4 configuration under a uniform sky gives env-NEE
## (which is what exercises evalMicrofacet's anisotropic branch -- the C1 fix
## lives there) a MIS weight of roughly 0.4% of the pixel mean: env_pdf for a
## uniform sky is ~1/(4*PI) ~ 0.08 while bsdf_pdf for this lobe is ~1.2 (see
## probe 2's own G readouts), so the power heuristic gives env-NEE a weight of
## ~0.0044. A 4x error confined to evalMicrofacet's anisotropic branch would
## move probe 1's mean by roughly 1.3% -- INSIDE its own 2% tolerance. Probe 1
## alone would pass with the C1 fix reverted; it is not, on its own, a working
## guard on that fix (see task-4-report.md fix round 1, I6). This probe uses
## a higher roughness and the SAME anisotropy the feature under test cares
## about specifically so the specular lobe is broad enough that env-NEE
## carries real weight, while still keeping the sky perfectly UNIFORM so the
## "output == sky radiance" closed form still holds exactly -- unlike a
## point/spot light, which would break that identity.
##
## PROBE 2 -- pdf/sampler self-normalization (vis mode 35).
##
## Fix round 1 (C2, CRITICAL): the original construction compared the density
## sampleSpecularMicrofacet actually realises (R) against what combinedPdf --
## the SAME function shade_and_bounce calls for mis_ray_pdf -- reports for
## that exact direction (G). Traced symbolically, R and G resolve to the
## IDENTICAL expression with the identical inputs (combinedPdf's own
## prepareBRDFData call uses the local placeholder normal (0,0,1), making
## getRotationToZAxis the identity there, so it recomputes the same phi/ax/ay
## and calls the same sampleGGXVNDFReflectionPdfAniso R already called) --  a
## genuinely wrong pdf formula would still read R == G and PASS. It cannot
## detect the B2 defect class (two MIS strategies estimating different
## integrands, mean-preserving, invisible to any rendered image) it exists to
## catch. Kept below ONLY as a hemisphere-guard confirmation diagnostic
## (expected to collapse to ~1e-6 once both sides share production's own
## `dot(N,L) <= 0` early-out) -- it does not gate pass/fail.
##
## The REAL instrument is self-normalized importance sampling: draw L with
## the REAL sampler (sampleSpecularMicrofacet) and accumulate 1/combinedPdf(L)
## over many real samples. If combinedPdf's reported density equals the
## density the sampler actually realises everywhere on its support, that
## expectation equals the support's solid-angle measure -- 2*PI for the upper
## hemisphere -- independent of the LOBE SHAPE of either side, so it cannot be
## gamed by evaluating the same formula twice the way R/G above could. Task 3
## needed two frame fixes here (a world-to-local transform in evalMicrofacet,
## and pre-rotating the tangent before prepareBRDFData) that are load-bearing
## ONLY when the shading normal is not already world Z -- run across a
## sphere, which presents a whole cone of normals away from Z at once, and at
## non-zero anisotropy (anisotropy 0 leaves anisoPhi == 0 and
## anisoActive == false, so the frame-rotation code this probe exists to
## guard never executes; kept as a control the same way probe 1 keeps one).
## See raytracing_closest_hit_common_inc.glsl's vis_mode == 35 block for the
## full construction.

const SKY_RADIANCE := 1.0
const TOLERANCE := 0.02 # furnace, 2% per the brief.
# Fix round 1: the old exact per-pixel |R - G| check is kept only as an
# UNASSERTED confirmation diagnostic (see the header comment) -- it no longer
# gates pass/fail, so this constant is documentation, not a live bound.
const PDF_TOLERANCE_DIAGNOSTIC_ONLY := 1e-4
# Fix round 1 (C2 item 3): tolerance for the REAL instrument,
# E[1/combinedPdf(L)] vs 2*PI. Chosen a priori from the expected Monte Carlo
# noise floor, BEFORE looking at whether any anisotropic case passes or
# fails: combinedPdf's reported values in this scene run ~0.9-1.5 (see fix
# round 0's R/G printouts), so 1/combinedPdf is a modest, low-variance
# quantity, and PDF_FRAMES samples across every pixel of a fully-sphere-
# filled 256x256 crop give an effective sample count in the millions --
# standard-error-of-the-mean at that count is orders of magnitude below 1%
# for a quantity in this range. 3% leaves comfortable margin for unexpected
# tail behaviour near the crop's more grazing edges while staying far below
# the >=10-30% shift a genuine missing-factor or swapped-axis pdf bug would
# produce.
const TOL_SELFNORM := 0.03
const FURNACE_FRAMES := 32
# Fix round 1: bumped from 4. The old value was sized for an EXACT per-sample
# comparison (any single valid sample either matched or it didn't); the new
# self-normalizing check is a Monte Carlo mean and needs real sample count to
# converge, even though spatial averaging over the whole sphere crop already
# supplies most of that.
const PDF_FRAMES := 64
const MODE_ANISO_PDF_PARITY := 35

const ANISOTROPY_VALUES := [-0.9, -0.5, 0.0, 0.5, 0.9]
const ROTATION_VALUES := [0.0, PI / 4.0, PI / 2.0]

# Fix round 2 (Important #1): probe 1's PASS/FAIL logic used to compare the
# absolute ratio against 1.0 (TOLERANCE below) and NOTHING ELSE, but every
# combination in this sweep fails that comparison for a real, PRE-EXISTING,
# anisotropy-orthogonal reason -- evalMultiScatterApproximation/evalEmsApprox
# over-compensates the true single-scatter energy loss at this roughness by
# several percentage points (confirmed and deliberately left unfixed; see
# task-4-report.md fix round 1, C5, and PATH_TRACER_QUALITY_ROADMAP.md). That
# made `_failures` structurally non-empty: the gate printed FAIL both when
# the feature under test was correct AND when it was broken, so it guarded
# nothing (see this file's fix-round-2 header note).
#
# These five values are the ratios MEASURED on the intact tree (HEAD
# ff5a3a88d4 / 27c2c0f10b -- see task-4-report.md section 4's full stdout),
# one per ANISOTROPY_VALUES entry, averaged across the three ROTATION_VALUES
# at that anisotropy (the round-0 report's per-rotation spread is ~0.0002,
# two orders of magnitude below BASELINE_BAND below -- a pure rotation of the
# tangent frame cannot change how much energy a furnace returns, so
# collapsing rotation out of the baseline is not throwing away signal). They
# sit ABOVE 1.0 because of the `ms` over-compensation above, NOT because
# anything here is broken -- do not "fix" this array to read 1.0.
#
# The point of asserting a TIGHT band around a number that is itself known to
# be over 1.0 is regression detection, not correctness measurement: reverting
# the C1 fix (evalMicrofacet's `G2 /= 4.0f * NdotL * NdotV`,
# servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl) moves these
# same five configurations by +10.2 to +15.8 percentage points (measured,
# task-4-report.md fix round 1, I6's C1-revert experiment table) -- vastly
# outside BASELINE_BAND, while ordinary run-to-run Monte Carlo noise (~0.02pp
# per the per-rotation spread above) stays vastly inside it.
const BASELINE_INTACT_RATIO := [1.0777727, 1.0809253, 1.059535, 1.0776337, 1.034110] # parallel to ANISOTROPY_VALUES
const BASELINE_BAND := 0.005 # +/- 0.5 percentage points; see BASELINE_INTACT_RATIO's doc comment.

# Fix round 1: 0.0 added per the coordinator's C2 fix instruction -- the
# self-normalizing check being a genuinely independent instrument (unlike the
# old R-vs-G tautology) means an isotropic control is now meaningful evidence
# again: correct pre-E2b code must ALSO read 2*PI here.
const PDF_PARITY_ANISOTROPY_VALUES := [-0.9, -0.5, 0.0, 0.5, 0.9]
const PDF_PARITY_ROTATION_VALUES := [0.0, PI / 4.0]

# Probe 1b (I6): a configuration where env-NEE -- and therefore
# evalMicrofacet's anisotropic branch -- carries real MIS weight. See the
# header comment.
const NEE_DOM_ROUGHNESS := 0.9
const NEE_DOM_ANISOTROPY := 0.9
const NEE_DOM_ROTATION := 0.0
const NEE_DOM_FRAMES := 64

# Fix round 2 (Important #1): same regression-band treatment as probe 1's
# BASELINE_INTACT_RATIO -- measured on the intact tree (task-4-report.md fix
# round 1, I6), sits well above 1.0 for the same pre-existing `ms`
# over-compensation reason (much larger here since it scales with roughness,
# and NEE_DOM_ROUGHNESS is 0.9 vs probe 1's 0.4), and reverting the C1 fix
# moves it by +42.6 percentage points (measured, the I6 C1-revert experiment)
# -- far outside BASELINE_BAND.
const BASELINE_INTACT_RATIO_NEE_DOM := 1.345900

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
	print("  sky radiance %.5f" % SKY_RADIANCE)
	print("  [diagnostic-only] absolute vs 1.0, tolerance %.1f%% -- NOT asserted, see BASELINE_INTACT_RATIO doc"
			% (TOLERANCE * 100.0))
	print("  [REAL gate] vs measured-intact baseline, band +/-%.1fpp" % (BASELINE_BAND * 100.0))
	var vp_rid := get_viewport().get_viewport_rid()
	var worst_ratio := 1.0
	var worst_label := ""
	for ai in range(ANISOTROPY_VALUES.size()):
		var aniso: float = ANISOTROPY_VALUES[ai]
		var baseline: float = BASELINE_INTACT_RATIO[ai]
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
			# Diagnostic only -- NOT asserted (fix round 2, Important #1). The
			# absolute deviation from 1.0 is dominated by the pre-existing,
			# anisotropy-orthogonal `ms` over-compensation (see
			# BASELINE_INTACT_RATIO's doc comment and task-4-report.md fix
			# round 1, C5) -- printed as a pointer to that open item, same
			# demotion pattern probe 2's old R-vs-G check already received.
			if absf(ratio - 1.0) > TOLERANCE:
				print(("  [diagnostic] %-34s ratio %.6f vs 1.0 exceeds %.1f%% -- known pre-existing " +
						"multi-scatter over-compensation (see BASELINE_INTACT_RATIO doc), not asserted")
						% [tag, ratio, TOLERANCE * 100.0])
			# The REAL gate: a tight regression band around the ratio MEASURED
			# on the intact tree. A C1-class reversion moves this same
			# quantity by +10 to +16 percentage points (measured); ordinary
			# run-to-run noise stays within ~0.02pp (measured) -- see
			# BASELINE_INTACT_RATIO's doc comment for both numbers.
			if absf(ratio - baseline) > BASELINE_BAND:
				_failures.append(("probe1 furnace [%s]: ratio %.6f vs intact baseline %.6f " +
						"(band +/-%.1fpp) -- moved outside the measured-good range, consistent with " +
						"a reverted C1 fix (evalMicrofacet's G2/4*NdotL*NdotV, brdf_inc.glsl) or " +
						"another regression in the anisotropic branch")
						% [tag, ratio, baseline, BASELINE_BAND * 100.0])
	print("  worst deviation: %s  ratio=%.6f" % [worst_label, worst_ratio])


func _probe_furnace_nee_dominant(p_env: Environment) -> void:
	print("\n=== PROBE 1b: white furnace, NEE-dominant configuration (fix round 1, I6) ===")
	print("  roughness=%.2f anisotropy=%.2f rotation=%.4f"
			% [NEE_DOM_ROUGHNESS, NEE_DOM_ANISOTROPY, NEE_DOM_ROTATION])
	print("  [diagnostic-only] absolute vs 1.0, tolerance %.1f%% -- NOT asserted, see BASELINE_INTACT_RATIO_NEE_DOM doc"
			% (TOLERANCE * 100.0))
	print("  [REAL gate] vs measured-intact baseline %.6f, band +/-%.1fpp"
			% [BASELINE_INTACT_RATIO_NEE_DOM, BASELINE_BAND * 100.0])
	var mat := _sphere_material(NEE_DOM_ANISOTROPY, NEE_DOM_ROTATION)
	mat.roughness = NEE_DOM_ROUGHNESS
	_sphere.material_override = mat
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), NEE_DOM_FRAMES)
	if img == null:
		_failures.append("probe1b NEE-dominant furnace: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.05, 0.95)
	var ratio: float = s["mean"] / SKY_RADIANCE
	print("  mean=%.6f  ratio=%.6f  (n=%d)" % [s["mean"], ratio, s["n"]])
	# Diagnostic only -- NOT asserted (fix round 2, Important #1). See probe
	# 1's identical treatment above.
	if absf(ratio - 1.0) > TOLERANCE:
		print(("  [diagnostic] ratio %.6f vs 1.0 exceeds %.1f%% -- known pre-existing multi-scatter " +
				"over-compensation (see BASELINE_INTACT_RATIO_NEE_DOM doc), not asserted")
				% [ratio, TOLERANCE * 100.0])
	# The REAL gate: regression band around the measured-intact baseline. A
	# C1-class reversion moves this same quantity by +42.6 percentage points
	# (measured, task-4-report.md fix round 1 I6) -- far outside BASELINE_BAND.
	if absf(ratio - BASELINE_INTACT_RATIO_NEE_DOM) > BASELINE_BAND:
		_failures.append(("probe1b NEE-dominant furnace: ratio %.6f vs intact baseline %.6f " +
				"(band +/-%.1fpp) -- moved outside the measured-good range, consistent with a " +
				"reverted C1 fix or another regression in the anisotropic branch")
				% [ratio, BASELINE_INTACT_RATIO_NEE_DOM, BASELINE_BAND * 100.0])


func _probe_pdf_parity(p_env: Environment) -> void:
	print("\n=== PROBE 2: anisotropic pdf/sampler self-normalization (vis mode %d) ===" % MODE_ANISO_PDF_PARITY)
	print("  diagnostic-only: old per-pixel |R - G| tautology check, NOT asserted (fix round 1, C2)")
	print("  REAL instrument: E[1/combinedPdf(L)] over real sampler draws vs 2*PI=%.6f, tolerance %.1f%%"
			% [TAU, TOL_SELFNORM * 100.0])
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

			# Diagnostic only -- NOT asserted. Confirms the hemisphere guard
			# collapsed the old tautological R-vs-G comparison (fix round 1,
			# C2 items 1-2), it does not test the pdf formula.
			var diag := _max_abs_rg_diff(img, 0.05, 0.95)
			print("  %-34s [diagnostic] max|R-G|=%.8f  at (%d,%d)  R=%.6f G=%.6f"
					% [tag, diag["max_diff"], diag["x"], diag["y"], diag["r"], diag["g"]])

			# The real instrument: mean of the B channel (1/combinedPdf(L) per
			# valid sample, 0 otherwise) over the crop, via the SAME
			# _measure_crop helper probe 1 uses.
			var s := _measure_crop(img, 0.05, 0.95)
			var self_norm: float = s["b"]
			var ratio: float = self_norm / TAU
			print("  %-34s [self-norm] E[1/G]=%.6f  ratio vs 2*PI=%.6f  (n=%d)"
					% [tag, self_norm, ratio, s["n"]])
			if absf(ratio - 1.0) > TOL_SELFNORM:
				_failures.append(("probe2 self-norm pdf parity [%s]: E[1/combinedPdf(L)] %.6f vs " +
						"2*PI=%.6f, ratio %.6f exceeds %.1f%% tolerance -- the reported pdf does not " +
						"describe the density the sampler actually realises")
						% [tag, self_norm, TAU, ratio, TOL_SELFNORM * 100.0])
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
	await _probe_furnace_nee_dominant(env)
	await _probe_pdf_parity(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - anisotropic GGX gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)
