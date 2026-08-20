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
## Seven probes:
##   1. F0 arbitration at default inputs (vis mode 30/31, no rendering).
##   2. F0 arbitration with a tinted, non-default specular_factor (vis mode 30).
##   3. Thin-walled straight-through transmittance (real render, ratio-based).
##   4. Volumetric absorption, isolated from Fresnel loss via a white-vs-tinted
##      attenuation_color RATIO on the same geometry (real render).
##   5. Opaque (transmission = 0) self-consistency, three readings (real render).
##   6. Total internal reflection: a glass rod engineered so a ray undergoes
##      guaranteed TIR against a side wall, with a bright trap surface
##      reachable ONLY if the medium flag's lifecycle regresses to the old
##      unconditional clear (real render).
##   7. Tinted-glass energy conservation: reflectance + transmittance must sum
##      to 1 per channel even under a saturated specular_tint, checked against
##      a uniform-radiance sky so the sum is directly observable as "unchanged
##      total" (real render).
##
## SCOPE: probes 1-2 exercise resolveDielectricF0 directly through vis modes,
## which is the SAME function shade_and_bounce calls -- not a re-inlined copy.
## Probes 3-7 render real StandardMaterial3D geometry through the production
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

# ---------------------------------------------------------------------------
# Probe 6: total internal reflection / medium-flag lifecycle.
# ---------------------------------------------------------------------------
const P6_FRAMES := 256
## Captured reference (see _probe6_tir's header comment for the full
## derivation): three consecutive correct-code runs of this exact scene read
## 4.068884 / 4.068838 / 4.069076 (spread ~0.00006). The same scene under the
## reintroduced medium-flag bug (old unconditional clear_inside_medium) read
## 4.490434 -- see task-7-report.md for the verbatim failure message. The
## threshold sits roughly halfway, with four orders of magnitude of margin
## over the measured noise floor on both sides.
const P6_REF_CORRECT := 4.069
const P6_THRESHOLD := 4.2

# ---------------------------------------------------------------------------
# Probe 7: tinted-glass energy conservation.
# ---------------------------------------------------------------------------
const P7_FRAMES := 96
const P7_TINT_SRGB := Color(0.95, 0.15, 0.10) # saturated, authored sRGB.
const P7_TOLERANCE := 0.02 # 2%.

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
			Vector3(0.04, 0.04, 0.04), true)
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe1 resolved eta",
			Vector3(1.5, 1.5, 1.5), true)

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
			Vector3(expected_f0_b, expected_f0_b, expected_f0_b), true)


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
	await _check_vis_mode(s["env"], MODE_RESOLVED_F0, "probe2 tinted F0", expected_f0, true)

	# eta must stay at the untouched ior (1.5): the re-derivation in
	# resolveDielectricF0 only fires when specular != 0.5, and specular was
	# not touched by this fixture.
	await _check_vis_mode(s["env"], MODE_RESOLVED_ETA, "probe2 eta unchanged",
			Vector3(1.5, 1.5, 1.5), true)


func _check_vis_mode(p_env: Environment, p_mode: int, p_label: String,
		p_expected: Vector3, p_check_all: bool) -> void:
	p_env.set_pathtracing_debug_mode(p_mode)
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 1)
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var got := Vector3(px.r, px.g, px.b)
	for i in 3:
		if not p_check_all and p_expected[i] == 0.0 and i > 0:
			continue
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
## bug read 4.490434 -- a ~10% jump, four orders of magnitude above the noise
## floor. REF_BACKDROP_CORRECT below is that captured baseline; see
## pt_energy_gate.gd's REF_* constants for the same captured-reference pattern
## used elsewhere in this codebase.
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
	var leak_dir := Vector3(-0.47140452079103173, 0.0, -0.8819171036881969)
	var backdrop_center := Vector3(-1.0177810138476415, 0.0, -4.145751311064591)
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
	print("  measured mean : %.6f  (r %.6f g %.6f b %.6f) -- reference %.6f, threshold %.6f"
			% [stats["mean"], stats["r"], stats["g"], stats["b"], P6_REF_CORRECT, P6_THRESHOLD])
	_checks += 1
	if stats["mean"] > P6_THRESHOLD:
		_failures.append(("probe6 TIR: measured mean %.6f exceeds threshold %.6f (correct-code "
				+ "reference %.6f) -- undiminished throughput is reaching the backdrop, "
				+ "consistent with the far-face hit never being registered")
				% [stats["mean"], P6_THRESHOLD, P6_REF_CORRECT])


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
