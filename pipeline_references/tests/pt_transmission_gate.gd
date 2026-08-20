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
## Eight probes:
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
##      degenerate corners -- structurally the only real render in this gate
##      that exercises combinedPdf's non-degenerate specular-density branch
##      (Task 5/6 defect a's mechanism) and sampleDielectricMicrofacet's
##      non-delta VNDF path (defect c's mechanism) at all. Reintroducing EITHER
##      historical defect was tried, across three scene configurations each,
##      and none moved this probe's reading outside its band -- see
##      _probe8_rough_partial_transmission's "HONEST LIMITATION" comment and
##      task-7-report.md's fix-round-1 addendum for the full investigation and
##      a working theory of why (real render, captured-reference two-sided
##      band).
##
## SCOPE: probes 1-2 exercise resolveDielectricF0 directly through vis modes,
## which is the SAME function shade_and_bounce calls -- not a re-inlined copy.
## Probes 3-8 render real StandardMaterial3D geometry through the production
## shade_and_bounce path. Every probe in this file therefore proves the
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
const P3_TOLERANCE := 0.02 # 2%, per the brief.

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
const P5_REF_CORRECT := 0.998713
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
const P8_REF_CORRECT := 0.994691
const P8_TOLERANCE := 0.02 # 2%; see task-7-report.md fix-round-1 addendum for the capture run.
const P8_FLOOR := 1e-6 # I2.

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

	# eta must stay at the untouched ior (1.5): the re-derivation in
	# resolveDielectricF0 only fires when specular != 0.5, and specular was
	# not touched by this fixture.
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe2 eta unchanged",
			Vector3(1.5, 1.5, 1.5))


## All seven call sites here have three legitimately distinct (or at least
## legitimately non-zero-suppressible) channels, unlike Phase D's material-data
## gate this pattern was borrowed from -- so this always checks all three
## channels. Fix round 1: dropped the p_check_all parameter and its dead
## "skip zero-expected channels 1/2" branch, which every call site passed
## `true` past.
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
	env.set_pathtracing_max_bounces(4)
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
## HONEST LIMITATION (fix round 1 verification -- read this before trusting
## this probe as a regression detector for defects a or c specifically).
## Three deliberate-break attempts, across three different scene
## configurations, ALL failed to move this probe's reading outside its band:
##
##   1. Hemisphere guard (defect c): reintroduced the pre-fix-round-1 ordering
##      (thin-walled -V override applied BEFORE wrongNg/wrongN, so both
##      comparisons become vacuously `isTransmit == true`). Normal-incidence
##      camera (the one shipped below): 0.994690 under the break vs a
##      0.994691 correct-code reference. A grazing-incidence variant tried
##      during investigation: 0.970174 under the break vs 0.969589-0.970442
##      across three correct-code runs at the same geometry -- statistically
##      indistinguishable, inside that configuration's own ~0.09% run-to-run
##      noise.
##   2. combinedPdf desync (defect a): reintroduced the pre-fix-round-1 form
##      by passing 0.0 instead of material.transmissivness into
##      baseColorToDiffuseReflectance inside combinedPdf specifically (the
##      exact historical bug -- see brdf_inc.glsl:1345-1356's own comment,
##      which documents the original 0.0909-vs-0.0476 pSpec split this
##      reproduces). Same uniform-sky quad shipped below: 0.994685 under the
##      break vs 0.994691 correct -- a 0.000006 delta, four orders of
##      magnitude under the 2% tolerance.
##   3. Same combinedPdf break, tried again against pt_energy_gate.gd's own
##      directional-sky methodology (a bright 20.0-vs-0.02 patch, chosen
##      specifically because that gate's header comment explains a uniform
##      sky is "blind to every direction-dependent defect"), first on a flat
##      quad (1.309403 under the break vs 1.309548-1.309570 correct -- still
##      indistinguishable) and then on a sphere, matching that same gate's
##      own reasoning for why a sphere and not a flat mirror ("a flat
##      mirror's single reflected direction could land on dim sky... a sphere
##      reflects essentially every direction at once") (0.813891 under the
##      break vs a 0.813740 correct-code reading -- a 0.00015 delta, again
##      far under any plausible detection threshold).
##
## Working theory for why defect a stayed invisible across all three
## variants: the MIS weights on both sides of every comparison this scene
## exercises (the BSDF ray's mis_ray_pdf, and env-NEE's bsdf_pdf_for_dir) are
## computed by the SAME (broken) combinedPdf call, just at different
## directions. Power-heuristic weights are ratios, so a SYSTEMATIC bias that
## shifts combinedPdf's output the same way regardless of which direction it
## is evaluated at can cancel in the weighted sum even though the underlying
## density is wrong in an absolute sense -- unlike the ORIGINAL discovery
## context for this defect (Task 6 review), which compared combinedPdf's
## output directly against the SAMPLER's own realised brdfProbability as two
## numbers side by side, not through a rendered image. Reproducing that
## detection would need a comparison against a BSDF-only reference build
## (pt_energy_gate.gd's Gate 2 methodology, which explicitly captures its
## REF_* constants from a build with environment NEE/MIS not yet added) rather
## than a live single-build rendered mean -- out of scope for this fix round.
##
## What this probe's shipped form DOES demonstrably provide, independent of
## whether defects a/c specifically regress: it is the only real render in
## this gate exercising combinedPdf's non-degenerate specular-density branch
## and sampleDielectricMicrofacet's non-delta VNDF path at all, closing the
## STRUCTURAL coverage gap fix round 1's C1 identified (every other probe sat
## at roughness 0 or transmission 0/1). Whether it can also catch a live
## regression in either mechanism remains open; see task-7-report.md's
## fix-round-1 addendum for the full investigation.
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
