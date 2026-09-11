extends "res://tests/pt_validation.gd"

## E1 Task 7 GPU gate: transmission physics and F0 arbitration.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transmission_gate_scene.tscn
##
## WHAT THIS PROVES, AND WHY NOTHING ELSE IN THIS PHASE PROVES IT.
##
## Tasks 5 and 6 shipped four Critical/Important defects -- a combinedPdf
## probability desync, a medium flag cleared on internal reflection, a
## hemisphere guard that could never fire, and a transmission weight that
## reached no BSDF value -- and the doctest suite (1511/1511), all three prior
## gates, and the validation mean passed through every one of them. The reason
## is structural: the doctest suite mirrors the GLSL formulas in C++ and never
## executes the shader, and the headless renderer discards material parameters
## entirely (servers/rendering/dummy/storage/material_storage.h:123-124 are
## both no-ops). No test anywhere in this repository, before this file, ever
## rendered a transmissive material through the real GPU pipeline. This gate
## is what closes that gap.
##
## Ten probes:
##   1. F0 arbitration at default inputs, PLUS a non-default-specular fixture
##      (vis mode 30/31, no rendering) -- see P1B_SPECULAR's doc comment for
##      why the default-specular case alone cannot catch a curve regression.
##   2. F0 arbitration with a tinted, non-default specular_factor (vis mode 30).
##   3. Thin-walled straight-through transmittance (real render, ratio-based).
##   4. Volumetric absorption, isolated from Fresnel loss via a white-vs-tinted
##      attenuation_color RATIO on the same geometry (real render).
##   5. Opaque (transmission = 0): three-reading self-consistency PLUS a
##      captured-reference correctness assertion (real render).
##   6. Total internal reflection: a glass box engineered so a ray undergoes
##      guaranteed TIR against a side wall, then reaches a generous backdrop
##      whose brightness sits in a two-sided band around a captured reference
##      -- undiminished if the medium flag's lifecycle regresses to the old
##      unconditional clear, dimmer if the transmit weight is corrupted
##      (real render).
##   7. Tinted-glass energy conservation: reflectance + transmittance must sum
##      to 1 per channel even under a saturated specular_tint, checked against
##      a uniform-radiance sky so the sum is directly observable as "unchanged
##      total" (real render).
##   8. Rough (roughness 0.5), partially transmissive (transmission 0.5)
##      energy, the only probe where BOTH parameters sit strictly inside their
##      degenerate corners, closing the STRUCTURAL coverage gap where every
##      other probe sat at roughness 0 or transmission 0/1. Cannot itself
##      detect the two historical defects that live in this regime -- see
##      probes 9/10, which were built specifically because it can't (real
##      render, captured-reference two-sided band).
##   9. PDF PARITY (vis mode 32, no rendering): reads combinedPdf's own
##      lobe-selection probability and the sampler's own, side by side, the
##      exact comparison that originally exposed Task 5/6 defect a. A pdf-only
##      desync is mean-preserving by construction (MIS is unbiased for any
##      weights summing to 1 pointwise) -- no rendered probe, including probe
##      8, can ever catch it. This is the only way.
##   10. HEMISPHERE-GUARD FIRING RATE (vis mode 33, real render but reading a
##       raw rejection rate, not a shaded value): accumulates whether Task 5/6
##       defect c's guard would fire, across many independent samples. A
##       rendered mean's sensitivity to this defect is bounded to ~1e-5 by an
##       unrelated downstream clamp on NdotL -- this detector sidesteps that
##       by measuring the rejection rate directly, before any weight is ever
##       applied.
##
## SCOPE: probes 1-2 and 9-10 exercise the underlying formulas directly
## through vis modes, calling the SAME functions shade_and_bounce and
## combinedPdf call -- not re-inlined copies. Probes 3-8 render real
## StandardMaterial3D geometry through the production shade_and_bounce path.
## Every probe in this file therefore proves the
## StandardMaterial3D path ONLY. debug_visualize() has two call sites in
## scene_raytracing_raygen.glsl (HG0's materials[]-in-scope form and the
## RT_CUSTOM_HIT_GROUP form fetching materials[h.geometry_idx] directly), and
## the custom-hit-group fetch is exercised by successful shader compilation
## only -- no scene in this repository drives it with real values, matching
## the residual-risk note in pt_material_data_gate.gd. Custom ShaderMaterials
## never carry transmission data at all (scene_raytracing_raygen.glsl:497-502
## hardcodes m.transmission = 0.0 for that path), so this gap is orthogonal to
## everything E1 touches.
##
## Every probe below was deliberately broken and observed to fail before this
## gate was considered complete; see task-7-report.md for the verbatim
## failure messages.

const MODE_RESOLVED_F0 := 30
const MODE_RESOLVED_ETA := 31

# ---------------------------------------------------------------------------
# Probe 1/2 tolerances and fixtures (vis-mode reads: no light transport, so the
# only error source is float storage -- generous relative to that, far tighter
# than any plausible formula-divergence delta).
# ---------------------------------------------------------------------------
const TOL_VIS := 1e-4

const P1_IOR := 1.5
const P1_SPECULAR := 0.5
const P1_SPECULAR_FACTOR := 1.0

## A second F0 arbitration fixture at a NON-DEFAULT specular. Godot's response
## curve (4*specular^2, normalised so it is exactly 1.0 at specular 0.5) and
## Blender's (2*specular) agree ONLY at specular 0.5 -- both give 0.04 there,
## which is precisely why probe 1 alone cannot catch a curve regression: a
## broken 2*specular substitution reads identically to the correct formula at
## the default. At specular 1.0 they diverge (4*1.0*1.0=4.0 vs 2*1.0=2.0,
## i.e. F0 = 0.16 vs 0.08) -- this is the fixture the brief's Step 6 calls for.
const P1B_SPECULAR := 1.0

const P2_SPECULAR_FACTOR := 0.62
const P2_TINT_SRGB := Color(0.8, 0.7, 0.55) # authored sRGB, per the brief.

# ---------------------------------------------------------------------------
# Probe 3: thin-walled straight-through.
# ---------------------------------------------------------------------------
const P3_FRAMES := 96
const P3_EXPECTED_T := 0.96 # Fresnel transmittance at normal incidence, ior 1.5.
## Fix round 2 correction: 2% (per the brief) was sized around a probe that
## rendered at max_bounces = 4, where a real +0.93% second-order GI offset
## (see the I5 investigation in task-7-report.md) ate nearly half the budget.
## Now that the probe renders at max_bounces = 2 -- matching where the
## analytic model actually holds (0.015% measured) -- 0.2% is ~13x that
## measured precision, a comparable margin to every other tightened tolerance
## in this gate.
const P3_TOLERANCE := 0.002 # 0.2%.

# ---------------------------------------------------------------------------
# Probe 4: volumetric absorption, isolated via a white-vs-tinted ratio on
# otherwise-identical geometry (see _probe4_absorption for why this is the
# correct experiment: comparing directly against a raw background would bake
# in TWO uncontrolled Fresnel losses -- entry and exit -- that swamp the 3%
# tolerance and have nothing to do with absorption).
# ---------------------------------------------------------------------------
const P4_FRAMES := 96
const P4_DEPTH := 1.0 # box Z-extent -- the "d" in exp(-(1-color)*density*d).
const P4_ATTENUATION_DISTANCE := 5.0
const P4_DENSITY := 1.0 / P4_ATTENUATION_DISTANCE # 0.2
const P4_ATTENUATION_COLOR := Color(0.9, 0.4, 0.15) # LINEAR, per the brief.
const P4_TOLERANCE := 0.03 # 3%, per the brief.

# ---------------------------------------------------------------------------
# Probe 5: opaque control. See _probe5_opaque_control for why "match a pre-E1
# build reading" is implemented as a three-reading self-consistency check
# rather than a literal old-commit rebuild.
# ---------------------------------------------------------------------------
const P5_FRAMES := 256
const P5_TOLERANCE := 2e-5 # Global Constraints: noise floor ~1e-5.
## Fix round 1, I3: the three-reading self-consistency check can only fail on
## harness non-determinism -- it has no external reference, so it cannot
## detect any actual renderer regression (a bug that shifted the opaque
## reading to, say, 1.5 and did so deterministically would pass all three
## comparisons). P5_REF_CORRECT freezes the reading captured from this build
## (mean_luma 0.998713 across all three original readings) as a forward-looking
## correctness guard, using the same captured-reference pattern as
## P6_REF_CORRECT. The determinism check is kept alongside it, not replaced --
## it is still useful for catching non-determinism specifically.
## RE-CAPTURED 2026-09-11. 0.998713 was captured before Gap #17 (multi-scatter
## energy), #19 (anisotropic sampler) and #21 (base Fresnel + layering) moved
## every dielectric; this gate was not re-run after any of them, and it failed
## IDENTICALLY (0.999925, three readings) on the pre-Gap-#20 binary, so the move
## is theirs, not Gap #20's -- which is arithmetically incapable of touching a
## transmission-0 material (evalMultiScatterFactorDielectric returns the opaque
## factor unchanged there). Previous value: 0.998713.
const P5_REF_CORRECT := 0.999925
const P5_REF_TOLERANCE := 2e-5 # Global Constraints noise floor, same as P5_TOLERANCE.
const P5_FLOOR := 1e-6 # I2.

# ---------------------------------------------------------------------------
# Probe 6: total internal reflection / medium-flag lifecycle.
# ---------------------------------------------------------------------------
const P6_FRAMES := 256
## Captured reference (see _probe6_tir's header comment for the full
## derivation): three consecutive correct-code runs of this exact scene read
## 4.068884 / 4.068838 / 4.069076 (spread ~0.00006). The same scene under the
## reintroduced medium-flag bug (old unconditional clear_inside_medium) read
## 4.490431 -- see task-7-report.md for the verbatim failure message.
##
## Fix round 1, I1: this was previously a ONE-SIDED check (`mean >
## P6_THRESHOLD`), which cannot see a regression that makes the probe DIMMER
## -- and the fix-round-1 review caught exactly that: Break E (probe 3's
## bogus 0.85 transmit-weight scale, unrelated to this probe) made probe 6
## read 2.937198, 28% below reference, and the one-sided check passed it
## silently. P6_LOW is chosen to sit above that measured false-negative and
## comfortably below the noise floor on the correct-code side.
const P6_REF_CORRECT := 4.069
const P6_LOW := 3.9
const P6_HIGH := 4.2
const P6_FLOOR := 1e-6 # I2.

# ---------------------------------------------------------------------------
# Probe 7: tinted-glass energy conservation.
# ---------------------------------------------------------------------------
const P7_FRAMES := 96
const P7_TINT_SRGB := Color(0.95, 0.15, 0.10) # saturated, authored sRGB.
## Fix round 1, I5: 0.02 (2%) was ~300x the observed run-to-run spread
## (~0.006%), and Break D (reverted tinted-transmittance formula) only cleared
## it by 1.96x on 2 of 3 channels (3.923% / 3.961% measured against a 2%
## limit) -- comfortable, but not the margin the rest of this gate holds
## everywhere else. Tightened to 0.5%, still >80x the noise floor.
const P7_TOLERANCE := 0.005 # 0.5%.
const P7_FLOOR := 1e-6 # I2: a black render must not read as "0% error".

# ---------------------------------------------------------------------------
# Probe 8: rough, partial transmission (roughness 0.5, transmission 0.5).
#
# Fix round 1, C1 (Critical): every other real-render probe sits at one of the
# two degenerate corners of the (roughness, transmission) parameter space --
# roughness 0.0 (probes 3, 4, 6, 7) or transmission 0.0 (probe 5). At
# roughness 0, sampleDielectricMicrofacet takes the `alpha == 0.0f` fast path
# with Hlocal exactly (0,0,1), so both hemisphere dot products in the
# wrongNg/wrongN guard are deterministic and correct BY CONSTRUCTION -- the
# guard this probe exists to exercise is structurally unreachable at
# roughness 0. And at transmission 1.0, diffuseLum is exactly 0, so pSpec
# collapses to 1 and combinedPdf's specular density is the ONLY term -- but
# roughness 0 is also below RT_MIS_DELTA_ROUGHNESS (0.03), so combinedPdf
# zeroes that term too and shade_and_bounce bypasses it entirely for the BSDF
# ray. Neither combinedPdf's lobe-probability desync (Task 5/6 defect a) nor
# the hemisphere guard (defect c) can be observed by any probe in this gate
# without a fixture that is BOTH rough AND partially transmissive. This is
# that fixture -- "rough glass" is the phase's own name for exactly this
# regime.
# ---------------------------------------------------------------------------
const P8_FRAMES := 128
const P8_ROUGHNESS := 0.5
const P8_TRANSMISSION := 0.5
## No analytic invariant survives at these settings, so this is a
## captured-reference probe (see P6_REF_CORRECT for the same pattern), tested
## with a symmetric band per fix round 1, I1, rather than an exact prediction:
## diffuseReflectance and the dielectric closure's reflectance+transmittance
## are independent, additively-combined terms here (baseColorToSpecularF0/
## baseColorToDiffuseReflectance, brdf_inc.glsl), not a single energy-
## conserving split, so there is no simple rho*L-style closed form the way
## there is for a pure Lambertian (pt_energy_gate.gd's Gate 1) or a
## transmission=1.0 dielectric alone (probe 7). Captured from a correct build:
## three consecutive runs read 0.994691 / 0.994692 / 0.994690 (spread
## ~0.000001). Note this landed close to the sky radiance L (1.0), not
## "measurably below" it as originally guessed before running it -- the
## transmitted lobe's single-scatter-only weighting (brdf_inc.glsl's
## sampleDielectricMicrofacet transmit branch has no
## evalMultiScatterApproximation call) is a real, documented deficit, but at
## these settings it is evidently a small contributor next to the additive
## diffuse layer.
##
## RE-CAPTURED 2026-09-11 for Gap #20: the transmitted lobe is now compensated
## by Cycles' 1/E_glass (ggxGlassEnergyScale), and the reflected lobe of a
## transmissive closure by lerp(opaque, glass, transmission) -- so the
## "single-scatter-only" deficit the paragraph above describes no longer
## exists. This arm moved +0.569%, from 0.994691 to 1.000353 (pre-Gap-#20
## binary still read 0.994691 on the same day). Under a uniform world a
## lossless rough half-glass landing at ~1.0 is the expected outcome.
const P8_REF_CORRECT := 1.000353
## Fix round 2 correction: 0.02 (2%) was 20,000x the measured 0.000001
## run-to-run spread, and unjustified in its own doc comment -- while THE
## SAME fix-round-1 commit tightened P7_TOLERANCE from 0.02 to 0.005 on the
## explicit reasoning that 300x the noise floor was "not the margin the rest
## of this gate holds everywhere else." 0.005 is still 5000x the noise floor,
## and Break E (fix round 1's bogus 0.85 transmit-weight scale) moved this
## probe 7.2%, comfortably outside it.
const P8_TOLERANCE := 0.005 # 0.5%.
const P8_FLOOR := 1e-6 # I2.

# ---------------------------------------------------------------------------
# Probe 9: pdf value check (fix round 2 detector 1 -- Task 5/6 defect a).
# RETIRED as a two-function agreement check by E2c (Task 3); see below.
#
# Vis mode 32 originally read combinedPdfLobeProbability(dbg_mat) and
# samplerLobeProbability(dbg_mat) (brdf_inc.glsl) DIRECTLY -- the exact
# production functions combinedPdf and shade_and_bounce respectively called
# -- and emitted vec3(pSpec, brdfProbability, ratio). That side-by-side
# comparison is what originally exposed Task 5/6 defect a (a pdf-only desync
# between combinedPdf and the sampler, mean-preserving by construction -- see
# WHY THIS below).
#
# E2c (Task 3) deleted both functions: combinedPdf and shade_and_bounce's
# sampler now both call ONE registry function, lobeWeight. A pdf-only desync
# between "combinedPdf's view" and "the sampler's view" is therefore
# structurally impossible, not merely re-synced by hand -- there is only one
# call site left to be wrong, and if it is wrong, every consumer reads the
# same wrong value, so no side-by-side ratio can ever observe a disagreement
# again. Comparing two evaluations of one formula is a tautology (ratio ==
# 1.0 always, by construction, regardless of correctness) -- vis mode 32 now
# reports lobeWeight's one real value as vec3(pSpec, 0.0, 0.0) rather than
# fabricate a second reading to compare it against. Probe 9 below keeps only
# the analytic assertion on that value (assertion 2 in the old numbering).
# The live detector for "is the pdf VALUE correct" (as opposed to "do two
# call sites of it agree") is vis mode 35's self-normalizing E[1/pdf]
# instrument -- see pt_anisotropy_gate.gd, Probe 2.
#
# WHY THIS, AND NOT A RENDERED MEAN (see also probe 8's header comment and
# the fix-round-1 addendum in task-7-report.md): MIS is unbiased for ANY set
# of weights satisfying sum(w) == 1 pointwise, and combinedPdf appears ONLY
# inside such weights (raytracing_closest_hit_common_inc.glsl's env-NEE and
# mis_ray_pdf sites, raytracing_emissive_inc.glsl's emissive NEE) -- never as
# an estimator divisor. A pdf-only desync between combinedPdf and the sampler
# was therefore MEAN-PRESERVING BY CONSTRUCTION: no rendered probe, at any
# roughness or transmission, could ever have detected it. Reading the value
# directly, as this probe still does, remains the only way to check it.
# ---------------------------------------------------------------------------
const MODE_PDF_PARITY := 32
const TOL_PDF_PARITY_RATIO := 1e-4
const P9_ROUGHNESS := 0.5
const P9_TRANSMISSION := 0.5
## Analytic, not captured: default StandardMaterial3D albedo is white (1,1,1),
## ior 1.5 / specular 0.5 give F0 = 0.04 (probe 1's own invariant), and
## diffuseReflectance = albedo * (1-metalness) * (1-transmissivness) =
## 1 * 1 * 0.5 = 0.5. luminance() of a uniform-channel colour equals that
## channel value (the Rec.709 weights sum to 1), so pSpec = 0.04 / (0.04 +
## 0.5) exactly -- both channels well clear of the 0.0001 degenerate
## thresholds on either side, so this exercises the actual clamp(...) branch,
## not one of its trivial 0.0/1.0 short-circuits.
const P9_EXPECTED_PSPEC := 0.04 / (0.04 + 0.5) # 0.074074...

# ---------------------------------------------------------------------------
# Probe 10: hemisphere-guard firing rate (fix round 2, detector 2 -- Task 5/6
# defect c).
#
# Vis mode 33 accumulates float(wrongNg || wrongN) over many samples by
# calling sampleTransmissiveLobe (brdf_inc.glsl) directly -- the exact
# production function shade_and_bounce calls, not a re-inlined copy -- once
# per accumulated frame. The mean of the accumulator is the empirical
# guard-firing rate.
#
# WHY THIS, AND NOT A RENDERED MEAN: the transmit branch clamps NdotL to
# -1e-5 (brdf_inc.glsl:1136, sampleDielectricMicrofacet), and
# specularSampleWeight -> Smith_G2_Over_G1_Height_Correlated goes to ~0 as
# NdotL -> 0. Every sample the guard would reject already carries weight
# ~1e-5 regardless of whether the guard fires -- a rendered mean's
# sensitivity to this defect is bounded at ~1e-5 by that unrelated
# downstream clamp, not by Monte Carlo noise (an earlier draft of this gate's
# documentation blamed noise; that was wrong -- see the fix-round-2 addendum
# in task-7-report.md). This detector measures the RAW rejection rate,
# before any weight is ever applied.
#
# NEEDS a grazing view angle AND a normal map (diverging the shading normal
# from geometry_normal): getting a non-zero correct-code rate at all took an
# honest, recorded search across four fixture attempts, three of which read
# exactly 0.0. See _probe10_guard_firing_rate's header comment for the full
# search and the measured correct-code rate.
# ---------------------------------------------------------------------------
const MODE_GUARD_FIRING_RATE := 33
const P10_FRAMES := 16384 # High sample count: the transmit-conditional statistic is noisy (see below).
const P10_ROUGHNESS := 1.0
const P10_IOR := 3.0
const P10_TRANSMISSION := 1.0
const P10_CAM_POS := Vector3(3.99, 0.0, 0.05) # "grazing" is a misnomer here -- see the note
# at the camera-setup site in _probe10_guard_firing_rate() for the actual geometry (near-normal
# incidence on the box's thin edge face, not a shallow view angle against a broad surface).
## Captured reference (transmit-conditional rate; see _probe10_guard_firing_rate's
## header comment for the full search that found this fixture): three
## consecutive correct-code runs read 0.001916 / 0.001975 / 0.001933 (spread
## ~0.00003, but the underlying sample count is small -- ~11.2% of P10_FRAMES
## take the transmit lobe at all, so this statistic is noisier than most in
## this gate). P10_RATE_LOW sits well below all three readings while staying
## orders of magnitude above the 0.0 defect c drives this to on a FLAT
## fixture. P10_RATE_HIGH is not just a loose sanity bound here: reintroducing
## defect c against THIS (normal-mapped) fixture measured 0.080879, a ~42x
## INCREASE rather than a collapse to zero, because the override's
## "vacuously consistent" property only holds when N == geometry_normal (see
## the header comment) -- so both bounds are load-bearing.
const P10_RATE_LOW := 0.0005
const P10_RATE_HIGH := 0.02
const P10_FLOOR := 1e-6 # I2 pattern: a zero transmit-sample fraction can't be conditioned on.

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	# project.godot renders at high resolution with stretch mode "viewport";
	# an accumulated sweep at that size would blow the ~2 minute budget.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(96, 96)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	print("=== PROBE 1: F0 arbitration at defaults ===")
	await _probe1_f0_arbitration()

	print("\n=== PROBE 2: tinted F0 ===")
	await _probe2_tinted_f0()

	print("\n=== PROBE 3: thin-walled straight-through ===")
	await _probe3_thin_walled()

	print("\n=== PROBE 4: volumetric absorption ===")
	await _probe4_absorption()

	print("\n=== PROBE 5: opaque control ===")
	await _probe5_opaque_control()

	print("\n=== PROBE 6: total internal reflection ===")
	await _probe6_tir()

	print("\n=== PROBE 7: tinted-glass energy conservation ===")
	await _probe7_tinted_energy()

	print("\n=== PROBE 8: rough, partial transmission ===")
	await _probe8_rough_partial_transmission()

	print("\n=== PROBE 9: pdf parity (combinedPdf vs sampler) ===")
	await _probe9_pdf_parity()

	print("\n=== PROBE 10: hemisphere-guard firing rate ===")
	await _probe10_guard_firing_rate()

	print("")
	if _failures.is_empty():
		print("PASS: all %d transmission-gate checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


# ===========================================================================
# PROBE 1/2: F0 arbitration via vis modes 30/31.
# ===========================================================================

func _build_vis_scene() -> Dictionary:
	for c in get_children():
		c.queue_free()

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4, 4, 0.1)
	mesh_instance.mesh = box
	add_child(mesh_instance)

	var cam := Camera3D.new()
	cam.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 3))
	add_child(cam)
	cam.make_current()

	# BG_COLOR here is fine, unlike _new_env's use for the real-render probes
	# (see that function's header comment): vis modes write ps.radiance
	# directly from the material fields and terminate the path immediately, so
	# nothing ever reads the sky/radiance octmap this scene never populates.
	# Do not copy this construct into a real-render probe.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)

	for _i in range(2):
		await get_tree().process_frame

	return {"mesh": mesh_instance, "env": env}


func _probe1_f0_arbitration() -> void:
	var s := await _build_vis_scene()
	var mat := StandardMaterial3D.new()
	mat.ior = P1_IOR
	mat.metallic_specular = P1_SPECULAR # NOT `.specular` -- BaseMaterial3D's ClassDB
	# property for set_specular()/get_specular() is named "metallic_specular"
	# (scene/resources/material.cpp:3768); `.specular` matches nothing and
	# silently no-ops via the legacy _set() remap (confirmed by the runtime
	# warning "Godot 3.x SpatialMaterial remapped parameter not found: specular").
	mat.specular_factor = P1_SPECULAR_FACTOR
	mat.specular_tint = Color(1, 1, 1)
	(s["mesh"] as MeshInstance3D).material_override = mat

	# At every default (ior 1.5, specular 0.5, specular_factor 1.0, white
	# tint), resolveDielectricF0 must yield exactly F0 = 0.04 on all three
	# channels and eta = 1.5 -- this is arithmetic, not a measurement: it is
	# what makes an untouched material bit-identical to pre-E1.
	await _check_vis_mode(s["env"], MODE_RESOLVED_F0, "probe1 resolved F0",
			Vector3(0.04, 0.04, 0.04))
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe1 resolved eta",
			Vector3(1.5, 1.5, 1.5))

	# Non-default-specular fixture (see P1B_SPECULAR doc comment): the ONLY
	# check in this gate that can distinguish Godot's 4*specular^2 curve from
	# Blender's 2*specular -- both give 0.04 at the default 0.5, but at
	# specular 1.0 they diverge to F0 = 0.16 vs 0.08.
	var mat_b := StandardMaterial3D.new()
	mat_b.ior = P1_IOR
	mat_b.metallic_specular = P1B_SPECULAR
	mat_b.specular_factor = P1_SPECULAR_FACTOR
	mat_b.specular_tint = Color(1, 1, 1)
	(s["mesh"] as MeshInstance3D).material_override = mat_b
	var expected_f0_b: float = 0.04 * (4.0 * P1B_SPECULAR * P1B_SPECULAR)
	await _check_vis_mode(s["env"], MODE_RESOLVED_F0, "probe1b non-default-specular F0",
			Vector3(expected_f0_b, expected_f0_b, expected_f0_b))

	# Fix round 1, I4: mode 31 (resolved eta) was checked ONLY at specular ==
	# 0.5 (probes 1, 2), which is the trivial `eta = ior` pass-through branch
	# in resolveDielectricF0. P1B_SPECULAR = 1.0 is the one fixture in this
	# gate that reaches the OTHER branch -- `eta = ior_from_F0(luminance(F0))`
	# -- and mode 31 was never read there. ior_from_F0(f) = (1+sqrt(f))/(1-sqrt(f));
	# at F0 = 0.16, sqrt(F0) = 0.4, giving (1.4)/(0.6) = 2.333333.
	var expected_eta_b: float = (1.0 + sqrt(expected_f0_b)) / (1.0 - sqrt(expected_f0_b))
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe1b non-default-specular eta",
			Vector3(expected_eta_b, expected_eta_b, expected_eta_b))


func _probe2_tinted_f0() -> void:
	var s := await _build_vis_scene()
	var mat := StandardMaterial3D.new()
	# ior and specular left at their StandardMaterial3D defaults (1.5, 0.5) so
	# this probe isolates specular_factor and specular_tint specifically.
	mat.specular_factor = P2_SPECULAR_FACTOR
	mat.specular_tint = P2_TINT_SRGB # sRGB-authored; the shader receives it linear.
	(s["mesh"] as MeshInstance3D).material_override = mat

	# specular_tint is authored sRGB in the Inspector/GDScript, exactly like
	# albedo_color, and linearised before it reaches the RT parameter map --
	# see pt_material_data_gate.gd's V_SPECULAR_TINT handling for the same
	# pattern. F0 = 0.04 * specular_factor * linear(tint), because specular is
	# left at 0.5 (4*0.5^2 == 1.0, a no-op multiplier).
	var tint_linear := P2_TINT_SRGB.srgb_to_linear()
	var expected_f0 := Vector3(tint_linear.r, tint_linear.g, tint_linear.b) * 0.04 * P2_SPECULAR_FACTOR
	await _check_vis_mode(s["env"], MODE_RESOLVED_F0, "probe2 tinted F0", expected_f0)

	# CHANGED by the E1 final fix wave (F3): resolveDielectricF0's re-derivation
	# gate used to check `specular != 0.5` only, so this probe (specular left at
	# its 0.5 default, only specular_factor touched) previously asserted eta
	# stayed pinned at the untouched ior (1.5). That was wrong against the
	# Cycles source it claims to port (kernel/svm/closure.h:425-435): Blender
	# maps specularFactor -> specular_ior_level = 0.5 * specular_factor (spec
	# section 3.2), so specular_factor != 1.0 already means
	# specular_ior_level != 0.5, and Cycles DOES re-derive eta in that case.
	# The gate now triggers on `specular != 0.5 || specular_factor != 1.0`.
	#
	# Also fixed in the same wave (F2): eta must be re-derived from the
	# UNTINTED scalar F0, never from luminance() of the tinted vector -- so
	# specular_tint (P2_TINT_SRGB, non-white) here must NOT move eta.
	# By hand: f0_untinted = F0_from_ior(1.5) * specular_factor * (4*0.5^2)
	#        = 0.04 * 0.62 * 1.0 = 0.0248
	#          eta = ior_from_F0(0.0248) = (1+sqrt(0.0248))/(1-sqrt(0.0248))
	#              = 1.157480 / 0.842520 = 1.373831
	# (ior 1.5 >= 1, so F1's ior<1 flip does not apply here.)
	const EXPECTED_ETA_P2 := 1.373831
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe2 eta re-derives from specular_factor (F3)",
			Vector3(EXPECTED_ETA_P2, EXPECTED_ETA_P2, EXPECTED_ETA_P2))


## All six call sites here have three legitimately distinct (or at least
## legitimately non-zero-suppressible) channels, unlike Phase D's material-data
## gate this pattern was borrowed from -- so this always checks all three
## channels. Fix round 1: dropped the p_check_all parameter and its dead
## "skip zero-expected channels 1/2" branch, which every call site passed
## `true` past. (Fix round 2 correction: this comment previously miscounted
## the call sites as seven.)
func _check_vis_mode(p_env: Environment, p_mode: int, p_label: String,
		p_expected: Vector3) -> void:
	p_env.set_pathtracing_debug_mode(p_mode)
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 1)
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var got := Vector3(px.r, px.g, px.b)
	for i in 3:
		_checks += 1
		var delta: float = abs(got[i] - p_expected[i])
		if delta > TOL_VIS:
			_failures.append("%s[%d]: expected %.6f, got %.6f (delta %.6f, tolerance %.6f)"
					% [p_label, i, p_expected[i], got[i], delta, TOL_VIS])
			print("  FAIL  %s[%d]: expected %.6f, got %.6f (delta %.6f)"
					% [p_label, i, p_expected[i], got[i], delta])
		else:
			print("  ok    %s[%d]: %.6f" % [p_label, i, got[i]])
	p_env.set_pathtracing_debug_mode(0)


# ===========================================================================
# Shared setup / measurement helpers for the real-render probes (3-7).
# ===========================================================================

## BG_COLOR does NOT populate the path tracer's radiance octmap -- only
## BG_SKY with an actual Sky resource does (env_sky_radiance() /
## env_sample() read radiance_octmap, which the sky pass only fills for a
## real Sky; SkyRD::draw_sky's BG_COLOR/BG_CLEAR_COLOR branch feeds the RASTER
## fog-sky material, a different consumer entirely). A flat single-colour
## panorama is Sky in every direction, matching pt_energy_gate.gd's
## _constant_panorama() pattern -- confirmed empirically: BG_COLOR alone read
## exactly 0.0 on every real-render probe here until switched to this.
func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
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


## Mean (and per-channel means) over an axis-aligned crop given as fractions
## of the image. Mirrors pt_energy_gate.gd's _measure_crop.
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
	return {"r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n}


func _settle() -> void:
	for _i in range(3):
		await get_tree().process_frame


## Longer settle for right after _new_env(): the sky pass renders the
## radiance octmap and the env CDF is built from it, and both need a moment --
## a handful of process_frame ticks is not enough (matches pt_energy_gate.gd's
## 2-second wait after building a fresh sky).
func _settle_sky() -> void:
	await get_tree().create_timer(1.0).timeout


# ===========================================================================
# PROBE 3: thin-walled straight-through.
# ===========================================================================
##
## A single thin quad (transmission 1.0, thickness 0.0, roughness 0.0) sits
## between the camera and a large emissive backdrop. The environment
## background is BLACK, not the backdrop's colour, so the ~4% Fresnel-reflected
## fraction (which bounces back roughly toward the camera, away from the
## backdrop) contributes nothing measurable -- if it also read the backdrop's
## colour, reflected and transmitted paths would be indistinguishable and this
## probe would trivially pass regardless of whether the thin-walled branch
## bends or absorbs. The ratio (glass mean) / (backdrop-only mean) isolates
## exactly the transmittance the thin-walled path is supposed to deliver.
func _probe3_thin_walled() -> void:
	for c in get_children():
		c.queue_free()

	var backdrop := MeshInstance3D.new()
	var backdrop_mesh := BoxMesh.new()
	backdrop_mesh.size = Vector3(6, 6, 0.1)
	backdrop.mesh = backdrop_mesh
	backdrop.position = Vector3(0, 0, -3)
	var backdrop_mat := StandardMaterial3D.new()
	backdrop_mat.emission_enabled = true
	backdrop_mat.emission = Color(0.6, 0.5, 0.4) # deliberately non-grey: a per-channel check.
	backdrop_mat.emission_energy_multiplier = 3.0
	backdrop.material_override = backdrop_mat
	add_child(backdrop)

	var quad := MeshInstance3D.new()
	var quad_mesh := BoxMesh.new()
	quad_mesh.size = Vector3(4, 4, 0.05)
	quad.mesh = quad_mesh
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transmission = 1.0
	glass_mat.thickness = 0.0
	glass_mat.roughness = 0.0
	glass_mat.metallic = 0.0
	glass_mat.ior = 1.5
	quad.material_override = glass_mat
	add_child(quad)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.fov = 25.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	# Fix round 2 correction: was 4. The I5 investigation's own bounce sweep
	# (task-7-report.md) showed this probe matches its analytic model to
	# 0.015% at max_bounces <= 2, and only picks up the +0.93% second-order GI
	# offset (emitter light bouncing off the glass's own back face and
	# returning) once a third bounce is available. 2 is not tuning the offset
	# away -- it is aligning the experiment with the closed form P3_TOLERANCE
	# actually asserts against, which the offset at 4 bounces was never a
	# fair test of. Independently confirmed via a black-albedo control (kills
	# the backdrop's own reflectivity, removing the GI path outright) at
	# max_bounces = 4: measured T = 0.959957, 0.004% off -- collapses the
	# offset from the black-albedo side too, not just the bounce-count side.
	env.set_pathtracing_max_bounces(2)
	await _settle_sky()

	quad.visible = false
	var bg_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P3_FRAMES)
	var bg_stats := _measure_crop(bg_img, 0.3, 0.7)
	print("  backdrop-only mean  : %.6f  (r %.6f g %.6f b %.6f)"
			% [bg_stats["mean"], bg_stats["r"], bg_stats["g"], bg_stats["b"]])

	quad.visible = true
	await _settle()
	var glass_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P3_FRAMES)
	var glass_stats := _measure_crop(glass_img, 0.3, 0.7)
	print("  with-glass mean     : %.6f  (r %.6f g %.6f b %.6f)"
			% [glass_stats["mean"], glass_stats["r"], glass_stats["g"], glass_stats["b"]])

	var measured_t: float = glass_stats["mean"] / maxf(bg_stats["mean"], 1e-9)
	var err: float = absf(measured_t - P3_EXPECTED_T) / P3_EXPECTED_T
	print("  measured T = %.6f, expected T = %.6f, rel err = %.3f%% (limit %.1f%%)"
			% [measured_t, P3_EXPECTED_T, err * 100.0, P3_TOLERANCE * 100.0])
	_checks += 1
	if err > P3_TOLERANCE:
		_failures.append(("probe3 thin-walled transmittance: measured %.6f vs expected %.6f, "
				+ "%.3f%% off (limit %.1f%%)")
				% [measured_t, P3_EXPECTED_T, err * 100.0, P3_TOLERANCE * 100.0])


# ===========================================================================
# PROBE 4: volumetric absorption.
# ===========================================================================
##
## Comparing a "with box" render directly against a "no box" background would
## bake in TWO uncontrolled Fresnel losses (entry and exit, each ~4-10%
## depending on angle) that have nothing to do with absorption and would
## swamp the 3% tolerance on their own. Instead this renders the SAME box
## TWICE, changing only attenuation_color: once white (1,1,1), which makes
## m.attenuation = (1-white)*density = 0 exactly -- i.e. a transmission-only
## reference with the identical Fresnel/TIR physics -- and once with the
## saturated test colour. The Fresnel losses and any internal-reflection
## structure are IDENTICAL between the two renders (attenuation_color affects
## nothing but the exp(-attenuation*t) multiply), so they cancel exactly in
## the ratio, isolating the absorption factor alone. This is also the probe
## that proves the exit-hit detection and back-face visibility: if back faces
## were culled, the ray would never find the exit interface and both renders
## would read black, giving a 0/0 ratio this gate treats as a hard failure.
func _probe4_absorption() -> void:
	for c in get_children():
		c.queue_free()

	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.5, 2.5, P4_DEPTH)
	box.mesh = box_mesh
	add_child(box)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.fov = 20.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(1, 1, 1)) # uniform sky; reflect/transmit see the same radiance.
	env.set_pathtracing_max_bounces(6)
	await _settle_sky()

	var mat := StandardMaterial3D.new()
	mat.transmission = 1.0
	# thickness is the glTF-style boolean-ish gate for "solid volume" (must be
	# > 0 to enable the exit-hit absorption block AND the medium-flag
	# lifecycle); it is NOT the geometric path length -- that comes from
	# gl_HitTEXT via the box's own Z-extent (P4_DEPTH).
	mat.thickness = 1.0
	mat.roughness = 0.0
	mat.metallic = 0.0
	mat.ior = 1.5
	mat.attenuation_distance = P4_ATTENUATION_DISTANCE
	mat.attenuation_color = Color(1, 1, 1) # reference: zero absorption.
	box.material_override = mat

	var ref_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P4_FRAMES)
	var ref_stats := _measure_crop(ref_img, 0.35, 0.65)
	print("  white-attenuation (reference) mean : %.6f  (r %.6f g %.6f b %.6f)"
			% [ref_stats["mean"], ref_stats["r"], ref_stats["g"], ref_stats["b"]])

	mat.attenuation_color = P4_ATTENUATION_COLOR.linear_to_srgb()
	await _settle()
	var test_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P4_FRAMES)
	var test_stats := _measure_crop(test_img, 0.35, 0.65)
	print("  tinted-attenuation (test) mean      : %.6f  (r %.6f g %.6f b %.6f)"
			% [test_stats["mean"], test_stats["r"], test_stats["g"], test_stats["b"]])

	var channels := ["r", "g", "b"]
	var atten_c := [P4_ATTENUATION_COLOR.r, P4_ATTENUATION_COLOR.g, P4_ATTENUATION_COLOR.b]
	for i in 3:
		var ref_v: float = ref_stats[channels[i]]
		var test_v: float = test_stats[channels[i]]
		if ref_v <= 1e-6:
			_checks += 1
			_failures.append(("probe4 absorption[%s]: reference (white-attenuation) reading is "
					+ "%.6f, indistinguishable from zero. If back faces were culled the ray never "
					+ "exits the box and this reads black -- cannot measure absorption against it.")
					% [channels[i], ref_v])
			continue
		var expected: float = exp(-(1.0 - atten_c[i]) * P4_DENSITY * P4_DEPTH)
		var measured: float = test_v / ref_v
		var err: float = absf(measured - expected) / maxf(expected, 1e-9)
		_checks += 1
		print("  channel %s: measured ratio %.6f, analytic exp(-(1-c)*density*d) %.6f, err %.3f%% (limit %.1f%%)"
				% [channels[i], measured, expected, err * 100.0, P4_TOLERANCE * 100.0])
		if err > P4_TOLERANCE:
			_failures.append(("probe4 absorption[%s]: measured ratio %.6f vs analytic %.6f, "
					+ "%.3f%% off (limit %.1f%%)")
					% [channels[i], measured, expected, err * 100.0, P4_TOLERANCE * 100.0])


# ===========================================================================
# PROBE 5: opaque control.
# ===========================================================================
##
## "Match a pre-E1 build reading within 2e-5" cannot be implemented as a
## literal rebuild-and-compare against an old commit within this gate's
## runtime budget, and the geometry this probe uses (the probe 4 box) did not
## exist before this task, so there is no literal pre-E1 reading of it to
## compare against. What IS available, and what this implements instead: with
## transmission = 0.0, brdf_mat.transmissivness is forced to 0.0 regardless of
## RT_GET_TRANSMISSION_ENABLED() (raytracing_closest_hit_common_inc.glsl,
## "brdf_mat.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? m.transmission
## : 0.0"), so this material takes the exact pre-E1 SPECULAR_TYPE/DIFFUSE_TYPE
## dispatch through evalIndirectCombinedBRDF with no dielectric-closure code
## ever reached. Three independent accumulation runs of the identical scene
## should then agree with each other to within the documented ~1e-5 run-to-run
## noise floor (progress.md), exactly as Task 5 and Task 6 verified for
## pt_validation_scene.tscn. A deviation beyond 2e-5 would mean the opaque
## path is not, in fact, bit-stable -- i.e. something IS leaking into it.
func _probe5_opaque_control() -> void:
	for c in get_children():
		c.queue_free()

	var box := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(2.5, 2.5, P4_DEPTH)
	box.mesh = box_mesh
	add_child(box)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.fov = 20.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(6)
	await _settle_sky()

	var mat := StandardMaterial3D.new()
	mat.transmission = 0.0
	mat.roughness = 0.4
	mat.metallic = 0.0
	mat.ior = 1.5 # present but irrelevant: transmissivness is forced 0.
	box.material_override = mat

	var readings: Array[float] = []
	for i in range(3):
		await _settle()
		var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P5_FRAMES)
		var m := mean_luma(img)
		readings.append(m)
		print("  reading %d: mean_luma = %.6f" % [i + 1, m])

	var ref: float = readings[0]
	for i in range(1, readings.size()):
		_checks += 1
		var delta: float = absf(readings[i] - ref)
		print("  reading %d vs reading 1: delta %.6f (limit %.6f)" % [i + 1, delta, P5_TOLERANCE])
		if delta > P5_TOLERANCE:
			_failures.append(("probe5 opaque control: reading %d (%.6f) vs reading 1 (%.6f), "
					+ "delta %.6f exceeds %.6f")
					% [i + 1, readings[i], ref, delta, P5_TOLERANCE])

	# Fix round 1, I3: the three-reading comparison above can only fail on
	# harness non-determinism -- with no external reference it cannot detect a
	# renderer regression that shifts the (still self-consistent) reading to a
	# wrong value. This is the correctness assertion that closes that gap.
	for i in range(readings.size()):
		_checks += 1
		if readings[i] < P5_FLOOR:
			_failures.append(("probe5 opaque control: reading %d (%.6f) is indistinguishable from "
					+ "zero (floor %.6f)") % [i + 1, readings[i], P5_FLOOR])
			continue
		var ref_delta: float = absf(readings[i] - P5_REF_CORRECT)
		print("  reading %d vs captured reference %.6f: delta %.6f (limit %.6f)"
				% [i + 1, P5_REF_CORRECT, ref_delta, P5_REF_TOLERANCE])
		if ref_delta > P5_REF_TOLERANCE:
			_failures.append(("probe5 opaque control: reading %d (%.6f) vs captured reference "
					+ "%.6f, delta %.6f exceeds %.6f")
					% [i + 1, readings[i], P5_REF_CORRECT, ref_delta, P5_REF_TOLERANCE])


# ===========================================================================
# PROBE 6: total internal reflection / medium-flag lifecycle.
# ===========================================================================
##
## Geometry: a glass box hit off-axis (45 degree incidence) so the refracted
## ray travels sideways and hits exactly ONE perpendicular interior wall
## before reaching the far (parallel) face. This is DETERMINISTIC TIR by
## construction, not a tuned near-critical-angle coincidence: refraction
## always keeps the transmitted ray's angle from the ENTRY face's normal at or
## below the critical angle (asin(1/eta) = 41.81 degrees for eta 1.5), so its
## angle from a PERPENDICULAR face's normal is always >= 90 - 41.81 = 48.19
## degrees -- comfortably past critical, regardless of the exact entry angle.
## See task-7-report.md for the full derivation (verified numerically).
##
## Only ONE interior bounce, not several: an earlier version of this probe
## chained three consecutive bounces (narrow rod, same 45-degree entry), which
## is a billiard-in-a-box trajectory -- and those are chaotically sensitive to
## initial conditions. Confirmed empirically: even an orthogonal camera with a
## near-zero aperture gave inconsistent readings run to run once three bounces
## were chained, for reasons having nothing to do with the medium flag. A
## single bounce is not chaotic and reproduces cleanly.
##
## MEASUREMENT: a large bright emissive backdrop sits generously beyond the far
## face, positioned along and covering the UNBENT continuation of the
## TIR-reflected direction. Two designs were tried and rejected before this
## one, and both are worth recording because the reasoning is not obvious:
##
##   1. A geometrically UNREACHABLE trap (thin, precisely positioned so a
##      correctly-refracted exit ray's ~16.9-degree bend misses it), expecting
##      "near zero when correct, bright when buggy". This is wrong on the
##      physics: even under the historical bug, the ray's DIRECTION out of the
##      TIR bounce is unchanged (the bug only affects whether the FAR face's
##      hit is registered, not the direction already computed at the TIR
##      bounce) -- so a bug-reachable trap has to sit ON the unbent line, and a
##      correctly-exiting ray passing NEAR that same line at a wide-enough
##      aperture contaminates the "correct" reading. The measured gap this
##      design produced (a few hundredths, not the "should be exactly zero"
##      the header originally claimed) was aperture-sensitivity noise, not
##      signal -- confirmed by the aperture experiment in point 2 below.
##   2. The same idea with a wide camera aperture (`size` 0.1 out of a 2-unit
##      face) to noise-average: this made the correct-code reading UNSTABLE
##      (0.11 to 0.90 across geometry tweaks) because different entry offsets
##      within that aperture land on different, still-legitimate bounce
##      patterns near the wall's edge -- the same chaos-adjacent sensitivity
##      that ruled out multi-bounce, just milder.
##
## The design actually used sidesteps both problems: instead of trying to
## spatially separate "reached" from "not reached", it puts a backdrop BIG
## enough (3x3, well past both the unbent line for a leaked ray AND the
## ~16.9-degree-off refracted-exit line for a correctly-transmitted one) that
## EITHER outcome lands on it, and measures the SMALL, PREDICTABLE brightness
## difference between them instead: under correct code the ray's throughput at
## the far face gets Fresnel-WEIGHTED (partial transmit, partial reflect-and-
## continue) before reaching the backdrop; under the bug the far-face hit is
## never registered at all, so NO weighting happens and slightly MORE
## throughput reaches the backdrop undiminished. A near-zero-aperture
## orthogonal camera (`size` 0.02) keeps every sampled ray on the same
## geometry, which is what makes this small difference measurable at all:
## three consecutive correct-code runs read 4.068884 / 4.068838 / 4.069076
## (spread ~0.00006, i.e. ~0.001%), and the same scene under the reintroduced
## bug read 4.490431 -- a ~10% jump, four orders of magnitude above the noise
## floor. P6_REF_CORRECT below is that captured baseline, checked as a
## two-sided band (P6_LOW/P6_HIGH) per fix round 1, I1; see pt_energy_gate.gd's
## REF_* constants for the same captured-reference pattern used elsewhere in
## this codebase.
func _probe6_tir() -> void:
	for c in get_children():
		c.queue_free()

	# WIDE cross-section box: entry near the box centre refracts to a shallow
	# lateral angle, hits exactly ONE perpendicular interior wall (guaranteed
	# TIR -- see the header derivation), reflects, and then reaches the FAR
	# PARALLEL face directly -- no second interior wall lookup. Deliberately
	# narrowed down from an earlier three-bounce design: multiple consecutive
	# interior bounces are a billiard-in-a-box trajectory, chaotically
	# sensitive to sub-pixel entry-point variation, which made a multi-bounce
	# trap an unreliable pass/fail signal for reasons having nothing to do
	# with the medium flag.
	var rod := MeshInstance3D.new()
	var rod_mesh := BoxMesh.new()
	rod_mesh.size = Vector3(2.0, 2.0, 3.0)
	rod.mesh = rod_mesh
	var rod_mat := StandardMaterial3D.new()
	rod_mat.transmission = 1.0
	rod_mat.thickness = 0.5
	rod_mat.roughness = 0.0
	rod_mat.metallic = 0.0
	rod_mat.ior = 1.5
	# No attenuation set (attenuation_distance defaults to 0 == no absorption):
	# this probe isolates the medium-flag lifecycle, not absorption.
	rod.material_override = rod_mat
	add_child(rod)

	# Generous backdrop (see the header comment for why "generous" is the
	# point, not a compromise): large enough to catch both a correctly-exited
	# (refracted) ray and a leaked (unbent) one, positioned along the unbent
	# TIR-reflected continuation.
	#
	# Fix round 1 (minor): backdrop_center is now DERIVED from h1 + leak_dir
	# rather than being an independent magic vector -- it used to be a second,
	# separately hand-computed constant with no visible relationship to
	# leak_dir, which was assigned and otherwise unused.
	# h1 is the TIR bounce point on the +X wall (world entry (0,0,1.5), 45deg
	# incidence, ior 1.5 refraction -- see the header derivation).
	var h1 := Vector3(1.0, 0.0, -0.37082869338697044)
	var leak_dir := Vector3(-0.47140452079103173, 0.0, -0.8819171036881969)
	var backdrop_t := 4.280359913523402 # distance along leak_dir from h1.
	var backdrop_center := h1 + leak_dir * backdrop_t
	var backdrop := MeshInstance3D.new()
	var backdrop_mesh := BoxMesh.new()
	backdrop_mesh.size = Vector3(3.0, 3.0, 3.0)
	backdrop.position = backdrop_center
	backdrop.mesh = backdrop_mesh
	var backdrop_mat := StandardMaterial3D.new()
	backdrop_mat.emission_enabled = true
	backdrop_mat.emission = Color(1, 1, 1)
	backdrop_mat.emission_energy_multiplier = 8.0
	backdrop.material_override = backdrop_mat
	add_child(backdrop)

	# ORTHOGONAL projection with a near-zero aperture (`size` 0.02 out of a
	# 2-unit face): every sampled ray shares the SAME entry angle and lands
	# within a tiny patch of the front face, which is what keeps the ~10%
	# correct-vs-buggy gap from being swamped by geometry variation across the
	# sampled rays (see header comment, rejected design 2).
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.02
	cam.near = 0.05
	cam.far = 20.0
	var cam_pos := Vector3(-2.121320343559643, 0.0, 3.621320343559643) # E - d0*3, theta_i = 45deg.
	# look_at_from_position(), not position + look_at(): look_at() requires the
	# node to already be inside the scene tree (it needs a global transform to
	# rebase against), which it is not until add_child() runs.
	cam.look_at_from_position(cam_pos, Vector3(0, 0, 1.5), Vector3.UP)
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0)) # black: only the backdrop can produce signal.
	env.set_pathtracing_max_bounces(8)
	await _settle_sky()

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P6_FRAMES)
	var stats := _measure_crop(img, 0.1, 0.9)
	print("  measured mean : %.6f  (r %.6f g %.6f b %.6f) -- reference %.6f, band [%.6f, %.6f]"
			% [stats["mean"], stats["r"], stats["g"], stats["b"], P6_REF_CORRECT, P6_LOW, P6_HIGH])
	_checks += 1
	if stats["mean"] < P6_FLOOR:
		_failures.append(("probe6 TIR: measured mean %.6f is indistinguishable from zero (floor "
				+ "%.6f) -- the backdrop is not being reached at all")
				% [stats["mean"], P6_FLOOR])
	elif stats["mean"] > P6_HIGH:
		_failures.append(("probe6 TIR: measured mean %.6f exceeds the band's high bound %.6f "
				+ "(correct-code reference %.6f) -- undiminished throughput is reaching the "
				+ "backdrop, consistent with the far-face hit never being registered")
				% [stats["mean"], P6_HIGH, P6_REF_CORRECT])
	elif stats["mean"] < P6_LOW:
		_failures.append(("probe6 TIR: measured mean %.6f falls below the band's low bound %.6f "
				+ "(correct-code reference %.6f) -- less throughput is reaching the backdrop than "
				+ "the reference build produced")
				% [stats["mean"], P6_LOW, P6_REF_CORRECT])


# ===========================================================================
# PROBE 7: tinted-glass energy conservation.
# ===========================================================================
##
## A thin-walled glass quad floats in a spatially UNIFORM sky (the same
## radiance in every direction, unlike probe 3's deliberately asymmetric
## setup). Under a uniform sky, whichever lobe a sample takes -- reflect or
## transmit -- it eventually reads the SAME background radiance L, so the
## expected per-channel mean is exactly (reflectance_c + transmittance_c) * L.
## dielectricFresnelSplit defines transmittance as (1 - reflectance) *
## transmission (brdf_inc.glsl, Task 5 fix round Item 1), so reflectance_c +
## transmittance_c == 1 per channel BY CONSTRUCTION whenever transmission ==
## 1.0 -- meaning the measured mean should equal L for every channel,
## regardless of how saturated specular_tint is. This is the exact invariant
## that broke before Task 5's fix round (transmittance was derived from the
## raw, untinted Fresnel term rather than the remapped/tinted reflectance, so
## a saturated tint made reflectance_c + transmittance_c disagree with 1 on
## every channel where the tint differed from white).
##
## Three measurements: sky-only (quad hidden, establishes L per channel
## directly rather than assuming it), a white-tint control (must reproduce L
## almost exactly, since remapped reflectance reduces to the scalar F0*tint
## with tint=white), and the saturated-tint test (must ALSO reproduce L, and
## must match the white-tint control -- "neither gains nor loses total energy
## against an equivalent white one").
func _probe7_tinted_energy() -> void:
	for c in get_children():
		c.queue_free()

	var quad := MeshInstance3D.new()
	var quad_mesh := BoxMesh.new()
	quad_mesh.size = Vector3(4, 4, 0.05)
	quad.mesh = quad_mesh
	add_child(quad)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.fov = 25.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(1, 1, 1)) # uniform sky in every direction.
	env.set_pathtracing_max_bounces(4)
	await _settle_sky()

	quad.visible = false
	var sky_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P7_FRAMES)
	var sky_stats := _measure_crop(sky_img, 0.3, 0.7)
	print("  sky-only mean (L)        : %.6f  (r %.6f g %.6f b %.6f)"
			% [sky_stats["mean"], sky_stats["r"], sky_stats["g"], sky_stats["b"]])

	quad.visible = true
	var white_mat := _p7_glass_material(Color(1, 1, 1))
	quad.material_override = white_mat
	await _settle()
	var white_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P7_FRAMES)
	var white_stats := _measure_crop(white_img, 0.3, 0.7)
	print("  white-tint mean          : %.6f  (r %.6f g %.6f b %.6f)"
			% [white_stats["mean"], white_stats["r"], white_stats["g"], white_stats["b"]])

	var tint_mat := _p7_glass_material(P7_TINT_SRGB)
	quad.material_override = tint_mat
	await _settle()
	var tint_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P7_FRAMES)
	var tint_stats := _measure_crop(tint_img, 0.3, 0.7)
	print("  saturated-tint mean      : %.6f  (r %.6f g %.6f b %.6f)"
			% [tint_stats["mean"], tint_stats["r"], tint_stats["g"], tint_stats["b"]])

	var channels := ["r", "g", "b"]
	for i in 3:
		var l_c: float = sky_stats[channels[i]]
		var tint_c: float = tint_stats[channels[i]]
		var white_c: float = white_stats[channels[i]]

		# Fix round 1, I2: err = |tint - ref| / max(ref, 1e-9) reads exactly 0
		# (a trivial PASS) if BOTH tint and ref are 0 -- an all-black render,
		# e.g. from a regressed sky pipeline, would pass silently otherwise.
		# This gate hit exactly that failure mode during authoring (the
		# BG_COLOR trap documented in _new_env's header comment): every
		# real-render probe read 0.0 across the board until it was fixed.
		_checks += 1
		if l_c < P7_FLOOR:
			_failures.append(("probe7 tinted energy[%s]: sky-only reading %.6f is "
					+ "indistinguishable from zero (floor %.6f) -- cannot measure energy "
					+ "conservation against it") % [channels[i], l_c, P7_FLOOR])
			continue
		_checks += 1
		if white_c < P7_FLOOR:
			_failures.append(("probe7 tinted energy[%s]: white-tint reading %.6f is "
					+ "indistinguishable from zero (floor %.6f)") % [channels[i], white_c, P7_FLOOR])
			continue

		_checks += 1
		var err_vs_sky: float = absf(tint_c - l_c) / maxf(l_c, 1e-9)
		print("  channel %s vs sky L      : tinted %.6f vs L %.6f, err %.3f%% (limit %.1f%%)"
				% [channels[i], tint_c, l_c, err_vs_sky * 100.0, P7_TOLERANCE * 100.0])
		if err_vs_sky > P7_TOLERANCE:
			_failures.append(("probe7 tinted energy[%s]: tinted mean %.6f vs sky L %.6f, "
					+ "%.3f%% off (limit %.1f%%) -- reflectance + transmittance does not sum to 1")
					% [channels[i], tint_c, l_c, err_vs_sky * 100.0, P7_TOLERANCE * 100.0])

		_checks += 1
		var err_vs_white: float = absf(tint_c - white_c) / maxf(white_c, 1e-9)
		print("  channel %s tint vs white : tinted %.6f vs white %.6f, err %.3f%% (limit %.1f%%)"
				% [channels[i], tint_c, white_c, err_vs_white * 100.0, P7_TOLERANCE * 100.0])
		if err_vs_white > P7_TOLERANCE:
			_failures.append(("probe7 tinted energy[%s]: tinted mean %.6f vs white-tint control "
					+ "%.6f, %.3f%% off (limit %.1f%%) -- tinted glass gained or lost total energy "
					+ "relative to an equivalent white one")
					% [channels[i], tint_c, white_c, err_vs_white * 100.0, P7_TOLERANCE * 100.0])


func _p7_glass_material(p_tint_srgb: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transmission = 1.0
	mat.thickness = 0.0
	mat.roughness = 0.0
	mat.metallic = 0.0
	mat.ior = 1.5
	mat.specular_tint = p_tint_srgb
	return mat


# ===========================================================================
# PROBE 8: rough, partial transmission (fix round 1, C1).
# ===========================================================================
##
## Same uniform-sky rig as probe 7 (a thin-walled quad floating in a
## spatially uniform sky, so any directional dependence in the result comes
## from the material, not the lighting) but at roughness 0.5 / transmission
## 0.5 instead of roughness 0.0 / transmission 1.0. This is deliberately the
## only probe in the gate where BOTH parameters sit strictly inside their
## degenerate corners:
##
##   - roughness > RT_MIS_DELTA_ROUGHNESS (0.03): combinedPdf's specular
##     density term is no longer zeroed, so its lobe-probability arbitration
##     against the diffuse term (the mechanism behind Task 5/6 defect a, the
##     combinedPdf desync) runs for the first time in this gate, instead of
##     being compiled-out-by-value the way it is at roughness 0.
##   - alpha = roughness^2 > 0: sampleDielectricMicrofacet no longer takes the
##     alpha==0 fast path (Hlocal forced to (0,0,1)); VNDF CAN produce a
##     genuinely wrong-side sample, which is what the wrongNg/wrongN
##     hemisphere guard (Task 5/6 defect c) exists to catch.
##   - transmission strictly between 0 and 1: diffuseReflectance is nonzero
##     (baseColorToDiffuseReflectance uses (1-transmissivness)), so pSpec sits
##     strictly between 0 and 1 and BOTH the diffuse and specular/transmissive
##     lobes carry real energy simultaneously -- neither probe 7
##     (transmissivness 1, diffuseReflectance forced to 0) nor probe 5
##     (transmissivness 0, no dielectric closure at all) can exercise that.
##
## No exact analytic invariant survives here (see P8_REF_CORRECT's doc
## comment for why), so this is a captured-reference probe with a two-sided
## band, following the exact pattern fix round 1, I1 established for probe 6.
##
## FIX ROUND 1 FOUND, AND FIX ROUND 2 EXPLAINS AND RESOLVES, A REAL LIMITATION
## OF THIS PROBE AS A REGRESSION DETECTOR FOR DEFECTS A/C -- read this before
## reusing the "clone probe 7 at rough settings" pattern for anything similar.
##
## Fix round 1 tried reintroducing both historical defects against this probe
## (three scene configurations total, including pt_energy_gate.gd's
## directional-sky and sphere patterns) and NONE moved the rendered mean
## outside its band -- deltas of 0.000006 to 0.00015 against a 2% tolerance,
## four to five orders of magnitude too small to detect.
##
## This was NOT a weak-signal problem to fix with a better fixture. The
## fix-round-2 review established why, precisely, for each defect:
##
##   Defect a (combinedPdf desync) is MEAN-PRESERVING BY CONSTRUCTION. MIS is
##   unbiased for ANY set of weights satisfying sum(w) == 1 pointwise, and
##   combinedPdf appears ONLY inside such weights (env-NEE and mis_ray_pdf
##   below, emissive NEE in raytracing_emissive_inc.glsl) -- never as an
##   estimator divisor. The BSDF ray's actual f/p comes from the sampler's own
##   realised weight, not from combinedPdf. No rendered probe, at any
##   roughness or transmission, can ever detect a pdf-only desync between
##   combinedPdf and the sampler. Recommending a BSDF-only reference build
##   (mirroring pt_energy_gate.gd's Gate 2) to chase this down -- which an
##   earlier draft of this comment did -- was a CATEGORY ERROR: that pattern
##   tests MIS *unbiasedness*, which is precisely the property a pdf-only
##   desync preserves. It would have produced a guaranteed null.
##
##   Defect c (hemisphere guard) is bounded, not buried in noise. The transmit
##   branch clamps NdotL to -1e-5 (brdf_inc.glsl, sampleDielectricMicrofacet),
##   and specularSampleWeight -> Smith_G2_Over_G1_Height_Correlated goes to ~0
##   as NdotL -> 0. Every sample the guard would reject already carries weight
##   ~1e-5 regardless of whether the guard fires -- a rendered mean's
##   sensitivity is bounded at ~1e-5 by that unrelated downstream clamp. An
##   earlier draft of this comment blamed "Monte Carlo noise"; that was wrong
##   -- the effect is deterministic and small, not variance.
##
## The ACTUAL fix (fix round 2): two vis modes that read the relevant
## quantities directly instead of through a rendered mean --
## RT_DEBUG_PDF_PARITY (mode 32, probe 9) originally read
## combinedPdfLobeProbability and samplerLobeProbability (brdf_inc.glsl) side
## by side, the same two-numbers comparison that originally exposed defect a;
## RT_DEBUG_GUARD_FIRING_RATE (mode 33, probe 10) accumulates the guard's raw
## rejection rate directly, before any weight is ever applied. See probe 10
## below -- it still catches its defect this way, verified by reintroducing
## it (task-7-report.md's fix-round-2 addendum has the verbatim failure
## message).
##
## E2c (Task 3) retired mode 32's two-function comparison: combinedPdf and
## shade_and_bounce's sampler now both call ONE registry function
## (lobeWeight, brdf_inc.glsl), so the desync this probe watched for is
## structurally impossible, not merely re-synced by hand. Probe 9 below now
## keeps only its analytic check on lobeWeight's actual value; the live
## detector for defect-a-shaped bugs (a pdf VALUE wrong, not two call sites
## disagreeing) is vis mode 35's self-normalizing E[1/pdf] instrument, see
## pt_anisotropy_gate.gd Probe 2.
##
## What THIS probe (8) demonstrably provides, independent of the above: it is
## the only real render in this gate exercising combinedPdf's non-degenerate
## specular-density branch and sampleDielectricMicrofacet's non-delta VNDF
## path at all, closing the STRUCTURAL coverage gap fix round 1's C1
## identified (every other probe sat at roughness 0 or transmission 0/1). That
## coverage is real and worth keeping even though probes 9/10, not this one,
## are what actually catch defects a/c.
func _probe8_rough_partial_transmission() -> void:
	for c in get_children():
		c.queue_free()

	var quad := MeshInstance3D.new()
	var quad_mesh := BoxMesh.new()
	quad_mesh.size = Vector3(4, 4, 0.05)
	quad.mesh = quad_mesh
	var mat := StandardMaterial3D.new()
	mat.transmission = P8_TRANSMISSION
	mat.roughness = P8_ROUGHNESS
	mat.metallic = 0.0
	mat.ior = 1.5
	mat.thickness = 0.0 # thin-walled: isolates the rough dielectric lobe from
	# absorption/medium-flag interactions, which are already covered by
	# probes 4 and 6.
	quad.material_override = mat
	add_child(quad)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.fov = 25.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(1, 1, 1)) # uniform sky in every direction, as probe 7.
	env.set_pathtracing_max_bounces(4)
	await _settle_sky()

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P8_FRAMES)
	var stats := _measure_crop(img, 0.3, 0.7)
	print("  measured mean : %.6f  (r %.6f g %.6f b %.6f) -- reference %.6f, tolerance %.1f%%"
			% [stats["mean"], stats["r"], stats["g"], stats["b"], P8_REF_CORRECT, P8_TOLERANCE * 100.0])

	_checks += 1
	if stats["mean"] < P8_FLOOR:
		_failures.append(("probe8 rough partial transmission: measured mean %.6f is "
				+ "indistinguishable from zero (floor %.6f)") % [stats["mean"], P8_FLOOR])
		return

	_checks += 1
	var err: float = absf(stats["mean"] - P8_REF_CORRECT) / P8_REF_CORRECT
	print("  rel err vs reference: %.3f%% (limit %.1f%%)" % [err * 100.0, P8_TOLERANCE * 100.0])
	if err > P8_TOLERANCE:
		_failures.append(("probe8 rough partial transmission: measured mean %.6f vs captured "
				+ "reference %.6f, %.3f%% off (limit %.1f%%)")
				% [stats["mean"], P8_REF_CORRECT, err * 100.0, P8_TOLERANCE * 100.0])


func _probe9_pdf_parity() -> void:
	var s := await _build_vis_scene()
	var mat := StandardMaterial3D.new()
	mat.transmission = P9_TRANSMISSION
	mat.roughness = P9_ROUGHNESS
	mat.metallic = 0.0
	mat.ior = 1.5
	(s["mesh"] as MeshInstance3D).material_override = mat

	(s["env"] as Environment).set_pathtracing_debug_mode(MODE_PDF_PARITY)
	var img: Image = await _render_accum(s["env"], get_viewport().get_viewport_rid(), 1)
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	# g and b are 0.0 by construction (E2c, Task 3) -- see this file's probe 9
	# header comment and RT_DEBUG_PDF_PARITY's own comment
	# (raytracing_closest_hit_common_inc.glsl) for why the r-only reading
	# replaces the old three-channel vec3(pSpec, brdfProbability, ratio).
	var pSpec: float = px.r
	print("  pSpec=%.6f  (expected %.6f)" % [pSpec, P9_EXPECTED_PSPEC])
	(s["env"] as Environment).set_pathtracing_debug_mode(0)

	# The two-function agreement check this probe used to run (ratio vs 1.0,
	# and a duplicate reading of the same value under a second name) is
	# retired: combinedPdf and the sampler now share one call site
	# (lobeWeight), so that agreement is structurally guaranteed, not merely
	# re-verified here, and a ratio of one formula against itself is a
	# tautology that cannot fail regardless of correctness -- keeping it would
	# have been strictly worse than the vis-mode-35 tautology this project
	# already caught in review, since this one needed zero formula
	# evaluations, not two. The one check that remains is analytic: does
	# lobeWeight itself compute the value the material's inputs predict.
	_checks += 1
	var pspec_delta: float = absf(pSpec - P9_EXPECTED_PSPEC)
	if pspec_delta > TOL_PDF_PARITY_RATIO:
		_failures.append(("probe9 pdf value: lobeWeight %.6f vs analytic %.6f, "
				+ "delta %.6f exceeds %.6f") % [pSpec, P9_EXPECTED_PSPEC, pspec_delta, TOL_PDF_PARITY_RATIO])
	else:
		print("  ok    probe9 lobeWeight: %.6f" % pSpec)


## Finding a NON-ZERO CORRECT-CODE rate for THIS PROBE's specific fixture
## (front-face hits only -- see debug_visualize's own limits, and the vis
## mode 33 comment) took an honest search, and the search itself is worth
## recording (task-7-report.md's fix-round-2 addendum has the full numbers).
## Every attempt below measured the TRANSMIT-CONDITIONAL rate (see the vis
## mode 33 comment for why unconditional is the wrong signal):
##
##   1. Straight-on camera (probe 8/9's normal incidence), roughness 0.9:
##      exactly 0.0 in 1024 correct-code frames.
##   2. Grazing camera (V near the quad's own plane), same roughness: still
##      exactly 0.0, even at 16384 frames.
##   3. Grazing + roughness 1.0 + ior 3.0 (near the most extreme parameters
##      this material model allows): STILL exactly 0.0 at 16384 frames.
##
## Fix round 3 correction: an EARLIER draft of this comment concluded from
## 1-3 that the guard's transmit side "may be structurally unreachable on a
## perfectly flat surface" in general. That overstated what the experiment
## showed, and the narrower, correct explanation matters, because the guard
## is NOT dead code in production. The analytic result (fix round 3 review,
## from sampleGGXVNDF returning H.z = max(0, Nh.z) >= 0 and
## refract_angle's L.z = c*H.z - V.z/eta with
## c = (a - sqrt(a^2 + (eta^2-1))) / eta, a = dot(H, V) > 0):
##
##   - eta > 1 (ENTERING a denser medium -- this is what attempts 1-3 above
##     all rendered, and what every front-face transmit hit in this gate
##     uses): eta^2-1 > 0, so sqrt(.) > a, so c < 0, so L.z < 0 STRICTLY,
##     ALWAYS. wrongN is unreachable BY THEOREM here, for any roughness,
##     ior, or view angle -- attempts 1-3 reading exactly 0.0 were not an
##     empirical curiosity, they were the only possible outcome for that
##     configuration.
##   - eta < 1 (EXITING a denser medium -- production's back-face case, the
##     `!h.is_front_face` branch in raytracing_closest_hit_common_inc.glsl's
##     shade_and_bounce): c > 0, and L.z > 0 (i.e. the guard fires) exactly
##     when (a^2 - k)*H.z^2 < (1 - a^2)*(1 - H.z^2), k = 1 - eta^2. At
##     eta = 1/1.5, a = 0.8, that holds for any H.z < 0.9 -- an ordinary
##     ~32-degree microfacet tilt at roughness >= ~0.5, no normal map
##     required. This is exactly the configuration probes 4 and 6 render: a
##     thick glass object, hit from inside on the way out. The guard is
##     doing real work there.
##
## What attempt 4 below (the normal map, see mat.normal_enabled) actually
## demonstrates is therefore narrower than the earlier draft claimed: it is
## a way to trigger wrongN on a FRONT-FACE (eta > 1) hit specifically, since
## this probe's vis mode 33 only ever visualizes primary (front-face) hits
## -- see the mode-33 comment in raytracing_closest_hit_common_inc.glsl for
## why that is this detector's own, separately-declared coverage limit. It
## is not evidence that the guard is unreachable on flat geometry in
## general; it is unreachable ONLY for eta > 1, which is a theorem, not a
## fixture-dependent measurement.
##
## The pattern across 1-3, restated correctly: with N == geometry_normal
## exactly (a flat quad, no normal map) AND eta > 1 (entering), wrongN is
## mathematically unreachable, regardless of roughness or view angle. What
## triggers a non-zero rate at eta > 1 is a normal map, diverging the
## SHADING normal from geometry_normal (mirrors pt_energy_gate.gd's own
## bumpy-surface probe, built for an unrelated purpose -- forcing
## shading-normal/geometry-normal divergence -- but the same mechanism).
## With one, grazing incidence, roughness 1.0, ior 3.0: three correct-code
## runs read 0.001916 / 0.001933 / 0.001975 (noisy -- only ~11.2% of
## samples take the transmit lobe at all at this geometry, so the effective
## sample count behind this statistic is small).
##
## One more thing worth recording precisely: the coordinator's prediction that
## the pre-fix ordering "drives this to exactly 0.0 by construction" is
## correct FOR A FLAT FIXTURE (dot(-V, N) is unconditionally negative when
## N == geometry_normal, since geometry_normal is flipped toward V by
## construction -- compute_hit_data -- which makes the post-override
## comparison vacuously consistent). It does NOT hold once N diverges from
## geometry_normal: dot(-V, N) is no longer guaranteed negative, so the
## override can just as easily manufacture a NEW inconsistency as suppress an
## existing one. The mechanism: clampShadingNormal (brdf_inc.glsl) returns
## shading_n UNCHANGED whenever dot(geometry_n, V) >= threshold, so with a
## steep enough normal map dot(N, V) can still go negative even after that
## clamp, making dot(-V, N) < 0 FALSE and wrongN fire under the override --
## the "geometry_normal is flipped toward V, so dot(-V, geometry_normal) < 0
## is unconditional" argument is specific to geometry_normal and does not
## transfer to a diverged shading N. Reintroducing the defect against THIS
## fixture moved the rate to 0.080879 -- a ~42x jump, not a collapse to
## zero, which is exactly this mechanism at work -- and the probe below
## still fails decisively on it, just via the high bound rather than the low
## one. Both directions are asserted for exactly this reason.
func _probe10_guard_firing_rate() -> void:
	for c in get_children():
		c.queue_free()

	var quad := MeshInstance3D.new()
	var quad_mesh := BoxMesh.new()
	quad_mesh.size = Vector3(4, 4, 0.05)
	quad.mesh = quad_mesh
	var mat := StandardMaterial3D.new()
	mat.transmission = P10_TRANSMISSION
	mat.roughness = P10_ROUGHNESS
	mat.metallic = 0.0
	mat.ior = P10_IOR
	mat.thickness = 0.0 # thin-walled, matching the brief's "thin-walled transmissive fixture".
	mat.normal_enabled = true # diverges N from geometry_normal -- see the header comment for why this is required.
	mat.normal_scale = 1.0
	mat.normal_texture = _p10_bump_normal_map()
	quad.material_override = mat
	add_child(quad)

	var cam := Camera3D.new()
	var cam_pos := P10_CAM_POS
	# Fix round 3 correction: this fixture has been described as "grazing"
	# elsewhere in this file, but that undersells what it actually is. The
	# box is Vector3(4, 4, 0.05) (x,y half-extent 2, z half-extent 0.025).
	# The camera ray from (3.99, 0, 0.05) to the origin crosses x = 2 (the
	# box's +x face) at t = (3.99-2)/3.99 ~= 0.4987, i.e. at
	# z ~= 0.05*(1-0.4987) ~= 0.025 -- exactly the box's z half-extent. So
	# this ray lands on the SILHOUETTE EDGE where the +x face meets the top
	# face, not at a shallow angle against a broad flat surface. That is
	# near-normal incidence on a knife's-edge, not grazing incidence in the
	# usual sense -- and it explains why this statistic is noisier than most
	# in this gate (small perturbations move the hit between two differently
	# angled faces). The fixture is not being re-cut for this; the existing
	# P10_RATE_LOW/P10_RATE_HIGH band already accounts for the noise.
	cam.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)
	cam.fov = 20.0
	add_child(cam)
	cam.make_current()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_debug_mode(MODE_GUARD_FIRING_RATE)

	for _i in range(3):
		await get_tree().process_frame

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), P10_FRAMES)
	var stats := _measure_crop(img, 0.3, 0.7)
	# r = wrong_hemisphere AND is_transmit; g = is_transmit; b = wrong_hemisphere
	# unconditionally (reference only -- see the vis-mode-33 comment for why
	# the unconditional rate is NOT the detector signal: the thin-walled
	# override this defect reorders around only ever applies to transmit
	# samples, so reflect-lobe hemisphere rejections -- a real but unrelated
	# effect at high roughness -- dilute or even dominate the unconditional
	# rate and mask the defect completely. Confirmed empirically during
	# authoring: the unconditional rate read IDENTICALLY with and without the
	# break reintroduced.
	var transmit_rate: float = stats["g"]
	var conditional_rate: float = stats["r"] / maxf(transmit_rate, 1e-9)
	print("  unconditional rate (reference only): %.6f" % stats["b"])
	print("  transmit sample fraction: %.6f" % transmit_rate)
	print("  transmit-conditional guard firing rate: %.6f  (reference band [%.6f, %.6f])"
			% [conditional_rate, P10_RATE_LOW, P10_RATE_HIGH])

	_checks += 1
	if transmit_rate < P10_FLOOR:
		_failures.append(("probe10 guard firing rate: transmit sample fraction %.6f is "
				+ "indistinguishable from zero (floor %.6f) -- cannot measure a "
				+ "transmit-conditional rate against it") % [transmit_rate, P10_FLOOR])
	elif conditional_rate < P10_RATE_LOW:
		_failures.append(("probe10 guard firing rate: transmit-conditional rate %.6f falls "
				+ "below %.6f -- consistent with the hemisphere guard never firing on transmit "
				+ "samples (defect c: the pre-fix thin-walled-override-before-check ordering "
				+ "drives this to exactly 0.0 by construction)") % [conditional_rate, P10_RATE_LOW])
	elif conditional_rate > P10_RATE_HIGH:
		_failures.append(("probe10 guard firing rate: transmit-conditional rate %.6f exceeds %.6f")
				% [conditional_rate, P10_RATE_HIGH])
	else:
		print("  ok    probe10 transmit-conditional guard firing rate: %.6f" % conditional_rate)


## Steep bump map for probe 10, mirroring pt_energy_gate.gd's own
## _bump_normal_map (built there for an unrelated purpose -- forcing
## shading-normal/geometry-normal divergence on a rough metal sphere -- but
## the same mechanism this probe needs). z = 0.2 keeps the tilt close to 78
## degrees at the extremes, steeper than pt_energy_gate.gd's own 0.45/65
## degrees; probe 10's header comment explains why this fixture needs it.
func _p10_bump_normal_map() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in range(n):
		for x in range(n):
			var u := float(x) / float(n) * TAU * 8.0
			var v := float(y) / float(n) * TAU * 8.0
			var nv := Vector3(0.97 * sin(u), 0.97 * sin(v), 0.2).normalized()
			img.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	return ImageTexture.create_from_image(img)
