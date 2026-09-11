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
# RE-CAPTURED 2026-09-10, after roadmap Gap #17 replaced
# evalMultiScatterApproximation's fitted `1 + F0*Ems` with Cycles'
# table-driven `1 + Fms*(1-E)/E` (evalMultiScatterEnergy, brdf_inc.glsl). The
# previous values were
#   [1.0777727, 1.0809253, 1.059535, 1.0776337, 1.034110]
# and carried that over-compensation.
#
# THEY STILL DO NOT ALL READ 1.0, AND THAT IS A SEPARATE, PRE-EXISTING DEFECT
# -- do not "fix" this array to read 1.0. The isotropic entry now reads
# 1.000549, which is the whole of what Gap #17 was; the anisotropic entries
# sit +1.7pp (anisotropy -0.9) and -2.4pp (anisotropy +0.9) away from it. That
# offset is NOT caused by the compensation, and the proof is the
# RT_MS_COMPENSATION three-state sweep measured the same day:
#
#   state                 a=-0.9      a=0.0     a=+0.9   offset vs isotropic
#   2 (legacy 1+F0*Ems)  1.077787   1.059535   1.034011   +1.83pp / -2.55pp
#   0 (no compensation)  0.982335   0.965699   0.942440   +1.66pp / -2.33pp
#   1 (Cycles table)     1.017784   1.000549   0.976442   +1.72pp / -2.41pp
#
# The offset is essentially identical in all three states INCLUDING state 0,
# where no compensation is applied at all. GGX_E_TABLE has no anisotropy axis
# (it is (rough, mu) only, and Cycles feeds it the same geometric-mean
# roughness we do), so the isotropic table cannot describe an eccentric lobe.
#
# RE-CAPTURED AGAIN 2026-09-11, after Gap #19 divergence A was fixed (roadmap
# §11.8): below-hemisphere VNDF samples were being CLAMPED into the shading
# hemisphere rather than rejected, handing a finite G2/G1 weight to directions
# where the BRDF is identically zero. The previous values were
#   [1.0177450, 1.0207473, 1.0005490, 1.0176387, 0.9765347]
# and carried that spurious energy. They were also NON-MONOTONIC in
# eccentricity, which probe 1d now asserts against.
#
# Against Cycles 5.2.1 on the identical furnace, roughness 0.4, the anisotropy
# sweep now agrees essentially exactly:
#   anisotropy 0.0   ours 1.000547   Cycles 1.000504   +0.00%
#   anisotropy 0.5   ours 0.992494   Cycles 0.992470   +0.00%
#   anisotropy 0.9   ours 0.928423   Cycles 0.928014   +0.04%
#
# Divergence B landed 2026-09-11 as well: ax/ay are now clamped to [0,1] as
# Cycles does, and `rough` for the GGX_E lookup comes from the clamped product
# rather than from sqrt(alpha). That only moves configurations where ax > 1, so
# the roughness-0.4 sweep above is unchanged by it; probe 1b is the cell it
# fixes. See roadmap §11.9.
#
# The point of asserting a TIGHT band around a number that is itself known to
# be over 1.0 is regression detection, not correctness measurement: reverting
# the C1 fix (evalMicrofacet's `G2 /= 4.0f * NdotL * NdotV`,
# servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl) moves these
# same five configurations by +10.2 to +15.8 percentage points (measured,
# task-4-report.md fix round 1, I6's C1-revert experiment table) -- vastly
# outside BASELINE_BAND, while ordinary run-to-run Monte Carlo noise (~0.02pp
# per the per-rotation spread above) stays vastly inside it.
const BASELINE_INTACT_RATIO := [0.9926490, 0.9974993, 1.0005453, 0.9924913, 0.9284207] # parallel to ANISOTROPY_VALUES
const BASELINE_BAND := 0.005 # +/- 0.5 percentage points; see BASELINE_INTACT_RATIO's doc comment.

# Probe 1d (Gap #19 divergence A, 2026-09-11). Monotonicity band.
#
# A more ECCENTRIC lobe has more masking-shadowing, so a white furnace must
# return LESS energy as ax:ay departs from 1 -- never more. This is a physical
# law, not a reference number, so unlike BASELINE_INTACT_RATIO it needs no
# re-capture when the integrator legitimately changes.
#
# It is the check that would have caught divergence A years earlier. Before the
# fix the sweep read 0.965696 at anisotropy 0.0 and 0.985205 at -0.5 -- a 1.95pp
# INCREASE with eccentricity, physically impossible, and sitting in committed
# measurements the whole time because nothing asserted on it.
#
# 0.2pp is ~10x the measured run-to-run spread (~0.02pp) and ~10x smaller than
# the violation it exists to catch.
const MONOTONIC_BAND := 0.002

# Probe 1e -- the BRUSHED METAL comparison against Cycles, re-taken 2026-09-11.
#
# This reproduces §7.8's Task-5 configuration: a metallic sphere at roughness
# 0.4, anisotropy 0.6 (>0, the range where the two engines' conventions agree
# exactly), at anisotropy_rotation 0 and PI/2, under a spatially uniform world.
#
# WHY IT IS RE-TAKEN RATHER THAN RE-RUN: the original .blend and harness were
# never checked into this repo, and the Blender it used (4.5.3) is no longer
# installed. This is a NEW measurement built from §7.8's written parameters, on
# Blender 5.2.1, with the framing matched to this gate on both sides. It is not
# a reproduction of the old numbers and must not be read as one.
#
# THE COLOUR-SPACE TRAP, which §7.8 called out and which cost E2a a phantom 53%
# energy error: albedo_color is sRGB as an artist types it, and
# render_raytracing.cpp runs it through srgb_to_linear() on upload. Blender's
# Base Color must be set to the DECODED number, not to 0.8. The decode is
# printed live below rather than assumed, exactly as the original harness did.
const BRUSHED_ALBEDO_SRGB := 0.8
const BRUSHED_ROUGHNESS := 0.4
const BRUSHED_ANISOTROPY := 0.6
const BRUSHED_FRAMES := 64
# Measured in Blender 5.2.1 Cycles by tools/cycles_comparison/cycles_brushed_metal.py,
# framing matched to this gate, 2048 samples, mean of both rotations
# (0.587468 at 0 turns, 0.587623 at 0.25 turns). See roadmap §7.8.
#
# THE RECONSTRUCTION VALIDATES ITSELF TWICE, which matters because the original
# .blend was never checked in and 4.5.3 is gone:
#   - the rotation-0 render reads 0.587468 against §7.8's recorded 0.587438,
#     0.005% apart, on a different Blender version;
#   - the colour-space positive control (rendering the RAW 0.8 instead of the
#     decoded 0.60382730) gives ratio 1.333905 against §7.8's recorded 1.333904,
#     versus a naive v/srgb_to_linear(v) prediction of 1.324882. Six decimals.
const CYCLES_BRUSHED_REF := 0.587546
# §8.6's acceptance bar for a Cycles material comparison.
const BRUSHED_BAR := 0.05

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

# Probe 1c (Gap #19, 2026-09-11). The missing cell in the Cycles comparison:
# probe 1 sweeps anisotropy at roughness 0.4 and probe 1b is roughness 0.9 AT
# anisotropy 0.9, so nothing measured roughness 0.9 ISOTROPIC -- which is exactly
# what separates "the divergence from Blender is anisotropy" from "part of it is
# roughness". Cycles 5.2.1 reads 0.999645 in this configuration (§11).
#
# Same sphere, same uniform sky, same crop as probes 1 and 1b; only roughness and
# anisotropy differ, so the three are directly comparable to each other and to
# the Cycles table in §11.2.
const ISO_HIROUGH_ROUGHNESS := 0.9
const ISO_HIROUGH_ANISOTROPY := 0.0
const ISO_HIROUGH_FRAMES := 64

# Fix round 2 (Important #1): same regression-band treatment as probe 1's
# BASELINE_INTACT_RATIO -- measured on the intact tree (task-4-report.md fix
# round 1, I6), sits well above 1.0 for the same pre-existing `ms`
# over-compensation reason (much larger here since it scales with roughness,
# and NEE_DOM_ROUGHNESS is 0.9 vs probe 1's 0.4), and reverting the C1 fix
# moves it by +42.6 percentage points (measured, the I6 C1-revert experiment)
# -- far outside BASELINE_BAND.
# RE-CAPTURED 2026-09-11 (Gap #19 divergence A, roadmap §11.8); was 1.278307,
# and 1.345900 before Gap #17. This probe is roughness 0.9 AND anisotropy 0.9 --
# an ax:ay of about 5.26:1, and the ONE configuration in this gate where
# ax = 0.81 / 0.4359 = 1.858 exceeds 1.
#
# RE-CAPTURED AGAIN 2026-09-11 after divergence B landed (roadmap §11.9); was
# 0.596594 with only A fixed, and 1.278307 before either. This is the ONE
# configuration in this gate where ax = 0.81 / 0.4359 = 1.858 exceeds 1, so it is
# the only cell B moves at all -- and it now agrees with Cycles 5.2.1 to 0.21%
# (0.829155 against 0.830896), from +53.85% before A and -28.2% after A alone.
#
# Deliberately still NOT asserted against 1.0: this configuration is
# anisotropic, so the isotropic 1/E derivation that makes probe 1's
# anisotropy-0 check and probe 1c assertable does not apply here.
const BASELINE_INTACT_RATIO_NEE_DOM := 0.829155

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
	print("  [gate] absolute vs 1.0, tolerance %.1f%% -- ASSERTED at anisotropy 0 (Gap #17, 2026-09-10);"
			% (TOLERANCE * 100.0))
	print("         diagnostic-only at other anisotropies, see BASELINE_INTACT_RATIO doc")
	print("  [gate] vs measured-intact baseline, band +/-%.1fpp" % (BASELINE_BAND * 100.0))
	var vp_rid := get_viewport().get_viewport_rid()
	var worst_ratio := 1.0
	var worst_label := ""
	# Probe 1d: mean ratio per anisotropy, for the monotonicity check below.
	var by_aniso: Array[float] = []
	for ai in range(ANISOTROPY_VALUES.size()):
		var aniso: float = ANISOTROPY_VALUES[ai]
		var baseline: float = BASELINE_INTACT_RATIO[ai]
		var aniso_sum := 0.0
		var aniso_n := 0
		for rot in ROTATION_VALUES:
			_sphere.material_override = _sphere_material(aniso, rot)
			var img: Image = await _render_accum(p_env, vp_rid, FURNACE_FRAMES)
			var tag := "anisotropy=%.2f rotation=%.4f" % [aniso, rot]
			if img == null:
				_failures.append("probe1 furnace [%s]: accumulator readback returned null" % tag)
				continue
			var s := _measure_crop(img, 0.05, 0.95)
			var ratio: float = s["mean"] / SKY_RADIANCE
			aniso_sum += ratio
			aniso_n += 1
			print("  %-34s mean=%.6f  ratio=%.6f  (n=%d)" % [tag, s["mean"], ratio, s["n"]])
			if absf(ratio - 1.0) > absf(worst_ratio - 1.0):
				worst_ratio = ratio
				worst_label = tag
			# ASSERTED AT ANISOTROPY 0 ONLY, as of 2026-09-10 (Gap #17).
			#
			# This check existed and was correct all along, but fix round 2
			# demoted it to diagnostic-only because evalMultiScatterApproximation's
			# over-compensation made EVERY entry fail it on a correct build --
			# which left the gate structurally unable to fail on an absolute
			# energy error, the condition that let Gap #17 hide for two phases.
			#
			# It is live again for the isotropic case, where a white furnace must
			# return the sky radiance by DERIVATION: for this material
			# (albedo 1, metallic 1) Fss = 1, so Fms = 1 and the compensation is
			# exactly 1/E, which cancels the lobe's directional albedo E. It
			# reads 1.000549 against a 2% bar.
			#
			# It stays diagnostic for the ANISOTROPIC entries because that
			# derivation does not cover them -- GGX_E_TABLE has no anisotropy
			# axis, so 1/E does not cancel an eccentric lobe's albedo. Their
			# residual is a separate pre-existing defect (see
			# BASELINE_INTACT_RATIO's doc comment for the three-state proof) and
			# the regression band below is what guards them.
			#
			# DO NOT widen TOLERANCE to promote the anisotropic entries. The
			# residual is a defect to fix, not a tolerance to absorb.
			if absf(ratio - 1.0) > TOLERANCE:
				if is_zero_approx(aniso):
					_failures.append(("probe1 furnace [%s]: ratio %.6f vs 1.0 exceeds %.1f%% -- a white " +
							"furnace must return the sky radiance exactly, and for the ISOTROPIC case " +
							"the Cycles compensation is exactly 1/E by derivation. See " +
							"evalMultiScatterEnergy in brdf_inc.glsl and RT_MS_COMPENSATION's " +
							"three-state falsification.")
							% [tag, ratio, TOLERANCE * 100.0])
				else:
					print(("  [diagnostic] %-34s ratio %.6f vs 1.0 exceeds %.1f%% -- the separate, " +
							"pre-existing ANISOTROPIC energy residual (present with compensation " +
							"disabled entirely; see BASELINE_INTACT_RATIO doc), not asserted")
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
		by_aniso.append(aniso_sum / maxf(float(aniso_n), 1.0))
	print("  worst deviation: %s  ratio=%.6f" % [worst_label, worst_ratio])
	_check_eccentricity_monotonic(by_aniso)


## PROBE 1d -- eccentricity monotonicity (Gap #19 divergence A).
##
## A white furnace must return LESS energy as the lobe gets more eccentric,
## because masking-shadowing grows with eccentricity. Never more.
##
## Eccentricity is ax:ay. With ax = alpha/aspect, ay = alpha*aspect and
## aspect = sqrt(1 - 0.9*anisotropy), that ratio is 1/(1 - 0.9*a) for a > 0 and
## (1 - 0.9*a) for a < 0 -- so the SIGNED sweep is not monotonic in `a` itself,
## and the entries have to be sorted by eccentricity before comparing. At the
## gate's five values that order is 0.0 (1.00), -0.5 (1.45), -0.9 (1.81),
## +0.5 (1.82), +0.9 (5.26): note -0.9 and +0.5 are nearly tied, which is why
## the band has to exceed their genuine 0.03pp separation.
##
## This assertion is independent of Cycles and of any stored reference. It is
## what divergence A violated, in committed measurements, unnoticed.
func _check_eccentricity_monotonic(p_by_aniso: Array[float]) -> void:
	if p_by_aniso.size() != ANISOTROPY_VALUES.size():
		_failures.append("probe1d: got %d ratios for %d anisotropies -- the sweep did not run as expected"
				% [p_by_aniso.size(), ANISOTROPY_VALUES.size()])
		return
	var rows: Array = []
	for i in range(ANISOTROPY_VALUES.size()):
		var a: float = ANISOTROPY_VALUES[i]
		var aspect_sq: float = 1.0 - 0.9 * a
		var ecc: float = maxf(1.0 / aspect_sq, aspect_sq)
		rows.append({ "a": a, "ecc": ecc, "ratio": p_by_aniso[i] })
	rows.sort_custom(func(x, y): return x["ecc"] < y["ecc"])

	print("\n=== PROBE 1d: eccentricity monotonicity ===")
	print("  a white furnace must not RETURN MORE energy as the lobe gets more eccentric")
	print("  %10s %12s %12s" % ["anisotropy", "ax:ay", "ratio"])
	for r in rows:
		print("  %10.2f %12.4f %12.6f" % [r["a"], r["ecc"], r["ratio"]])

	for i in range(1, rows.size()):
		var prev: Dictionary = rows[i - 1]
		var cur: Dictionary = rows[i]
		if cur["ratio"] > prev["ratio"] + MONOTONIC_BAND:
			_failures.append(("probe1d monotonicity: anisotropy %.2f (ax:ay %.4f) returns %.6f, MORE than " +
					"anisotropy %.2f (ax:ay %.4f) at %.6f, by %.2fpp. A more eccentric lobe has more " +
					"masking-shadowing and must return LESS. Energy gain with eccentricity is " +
					"physically impossible -- see PATH_TRACER_QUALITY_ROADMAP.md section 11.8.")
					% [cur["a"], cur["ecc"], cur["ratio"], prev["a"], prev["ecc"], prev["ratio"],
					(cur["ratio"] - prev["ratio"]) * 100.0])


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
	# Diagnostic only -- NOT asserted, and unlike probe 1 it stays that way even
	# after Gap #17. This configuration is anisotropy 0.9, so the isotropic
	# 1/E derivation that made probe 1's absolute check assertable does not
	# apply here; this is the extreme corner of the separate anisotropic
	# residual (see BASELINE_INTACT_RATIO_NEE_DOM's doc comment).
	if absf(ratio - 1.0) > TOLERANCE:
		print(("  [diagnostic] ratio %.6f vs 1.0 exceeds %.1f%% -- the separate, pre-existing " +
				"ANISOTROPIC energy residual at its worst corner (see " +
				"BASELINE_INTACT_RATIO_NEE_DOM doc), not asserted")
				% [ratio, TOLERANCE * 100.0])
	# The REAL gate: regression band around the measured-intact baseline. A
	# C1-class reversion moves this same quantity by +42.6 percentage points
	# (measured, task-4-report.md fix round 1 I6) -- far outside BASELINE_BAND.
	if absf(ratio - BASELINE_INTACT_RATIO_NEE_DOM) > BASELINE_BAND:
		_failures.append(("probe1b NEE-dominant furnace: ratio %.6f vs intact baseline %.6f " +
				"(band +/-%.1fpp) -- moved outside the measured-good range, consistent with a " +
				"reverted C1 fix or another regression in the anisotropic branch")
				% [ratio, BASELINE_INTACT_RATIO_NEE_DOM, BASELINE_BAND * 100.0])


func _probe_furnace_isotropic_hirough(p_env: Environment) -> void:
	print("\n=== PROBE 1c: white furnace, roughness %.2f ISOTROPIC ===" % ISO_HIROUGH_ROUGHNESS)
	print("  roughness=%.2f anisotropy=%.2f" % [ISO_HIROUGH_ROUGHNESS, ISO_HIROUGH_ANISOTROPY])
	print("  [gate] absolute vs 1.0, tolerance %.1f%% -- ASSERTED. This configuration is"
			% (TOLERANCE * 100.0))
	print("         ISOTROPIC, so the 1/E derivation applies exactly (see probe 1).")
	print("  Cycles 5.2.1 reads 0.999645 here; see PATH_TRACER_QUALITY_ROADMAP.md section 11.2.")
	var mat := _sphere_material(ISO_HIROUGH_ANISOTROPY, 0.0)
	mat.roughness = ISO_HIROUGH_ROUGHNESS
	_sphere.material_override = mat
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), ISO_HIROUGH_FRAMES)
	if img == null:
		_failures.append("probe1c isotropic high-roughness furnace: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.05, 0.95)
	var ratio: float = s["mean"] / SKY_RADIANCE
	print("  mean=%.6f  ratio=%.6f  (n=%d)" % [s["mean"], ratio, s["n"]])
	# ASSERTED, on the same derivation that made probe 1's anisotropy-0 case
	# assertable: for this material (albedo 1, metallic 1) Fss = 1, so Fms = 1
	# and the compensation is exactly 1/E, which cancels the lobe's directional
	# albedo E. A white furnace must return the sky radiance. Anisotropy is 0
	# here, so Gap #19's residual -- whatever its cause -- cannot reach this probe.
	#
	# DO NOT widen TOLERANCE. If this fails, the multi-scatter compensation is
	# incomplete at high roughness and that is a finding, not a threshold.
	if absf(ratio - 1.0) > TOLERANCE:
		_failures.append(("probe1c isotropic high-roughness furnace: ratio %.6f vs 1.0 exceeds %.1f%% " +
				"-- an ISOTROPIC white furnace must return the sky radiance exactly, and the Cycles " +
				"compensation is exactly 1/E by derivation for this material. Gap #17 (section 10) is " +
				"incomplete at roughness %.2f if this fires.")
				% [ratio, TOLERANCE * 100.0, ISO_HIROUGH_ROUGHNESS])


## PROBE 1e -- brushed metal against Cycles (§7.8, re-taken).
func _probe_brushed_metal(p_env: Environment) -> void:
	var linear: Color = Color(BRUSHED_ALBEDO_SRGB, BRUSHED_ALBEDO_SRGB, BRUSHED_ALBEDO_SRGB).srgb_to_linear()
	print("\n=== PROBE 1e: brushed metal vs Cycles (roughness %.2f, anisotropy %.2f) ==="
			% [BRUSHED_ROUGHNESS, BRUSHED_ANISOTROPY])
	print("  albedo_color %.4f sRGB decodes to LINEAR %.8f -- Blender Base Color must be THIS,"
			% [BRUSHED_ALBEDO_SRGB, linear.r])
	print("  not %.4f. Printed live, not assumed (the E2a colour-space trap)." % BRUSHED_ALBEDO_SRGB)
	var vp_rid := get_viewport().get_viewport_rid()
	var means: Array[float] = []
	for rot in [0.0, PI / 2.0]:
		var m := StandardMaterial3D.new()
		# NOT pre-encoded: we want the engine's own srgb_to_linear to run, so the
		# linear albedo is the number printed above and handed to Blender.
		m.albedo_color = Color(BRUSHED_ALBEDO_SRGB, BRUSHED_ALBEDO_SRGB, BRUSHED_ALBEDO_SRGB)
		m.metallic = 1.0
		m.roughness = BRUSHED_ROUGHNESS
		m.anisotropy_enabled = true
		m.anisotropy = BRUSHED_ANISOTROPY
		m.anisotropy_rotation = rot
		_sphere.material_override = m
		var img: Image = await _render_accum(p_env, vp_rid, BRUSHED_FRAMES)
		if img == null:
			_failures.append("probe1e brushed metal: accumulator readback returned null")
			return
		var st := _measure_crop(img, 0.05, 0.95)
		means.append(st["mean"])
		print("  rotation=%.4f  mean=%.6f  (n=%d)" % [rot, st["mean"], st["n"]])

	var ours: float = (means[0] + means[1]) * 0.5
	print("  ours (mean of both rotations): %.6f" % ours)
	if CYCLES_BRUSHED_REF <= 0.0:
		print("  CYCLES_BRUSHED_REF not captured yet -- run")
		print("    tools/cycles_comparison/cycles_brushed_metal.py")
		print("  with Base Color %.8f and record the result." % linear.r)
		return
	var err: float = ours / CYCLES_BRUSHED_REF - 1.0
	print("  Cycles 5.2.1 reference: %.6f" % CYCLES_BRUSHED_REF)
	print("  ratio %.6f  (%+.2f%%)  bar +/-%.1f%%" % [ours / CYCLES_BRUSHED_REF, err * 100.0, BRUSHED_BAR * 100.0])
	if absf(err) > BRUSHED_BAR:
		_failures.append(("probe1e brushed metal: %.6f vs Cycles %.6f, %+.2f%% -- outside the %.1f%% " +
				"bar (§8.6). This is a MATERIAL parity comparison, not an energy law; see §7.8.")
				% [ours, CYCLES_BRUSHED_REF, err * 100.0, BRUSHED_BAR * 100.0])


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
	await _probe_furnace_isotropic_hirough(env)
	await _probe_brushed_metal(env)
	await _probe_pdf_parity(env)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - anisotropic GGX gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)
