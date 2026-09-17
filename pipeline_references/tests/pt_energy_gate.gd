extends "res://tests/pt_validation.gd"

## Path-tracer ENERGY gates for environment NEE + MIS.
##
## MIS's failure mode is losing or double-counting energy while still producing a
## plausible image. Neither gate below is a quality metric; both are conservation
## checks, and both are meant to be re-runnable whenever the integrator changes.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_energy_gate_scene.tscn
##
## Env vars:
##   ZR_GATE_MODE    "constant" | "directional" | "both"  (default "both")
##   ZR_GATE_FRAMES  accumulated frames per measurement   (default 256)
##
## ---------------------------------------------------------------------------
## GATE 1 - constant sky. Absolute, analytic.
##
## Constant-radiance environment L = 1.0, one unoccluded Lambertian plane of
## albedo rho = 0.5, no analytic lights, camera looking straight down:
##
##     L_o = integral_hemisphere (rho / PI) * L * cos(theta) dw  =  rho * L
##
##     ~0.50 -> correct;  ~1.00 -> the two strategies double-count (a weight is
##     missing);  ~0.25 -> one side is weighted twice.
##
## The mean alone is NOT sufficient: an environment-NEE block that never fires,
## combined with a miss shader taking weight 1, also lands on exactly rho*L. So
## the gate also reports per-pixel std-dev. Under a CONSTANT sky plain BSDF
## sampling is a zero-variance estimator -- every cosine-sampled path carries
## throughput exactly rho onto radiance exactly L -- so spread > 0 at an
## unchanged mean proves the BSDF half is being weighted down AND that
## environment NEE is putting back exactly the energy the weight removed.
##
## ---------------------------------------------------------------------------
## GATE 2 - directional sky. Relative, against a stored reference.
##
## A constant sky is invariant to rotation, to the octmap border, and to the cell
## lookup, so it is blind to every direction-dependent defect -- including the
## whole class of bugs fixed earlier in this phase. Gate 2 uses a high-contrast
## sky (a bright patch of ~4.6% solid angle at radiance 20 against a 0.02 base,
## 1000:1) and measures four surfaces:
##
##   smooth  - a roughness-0.02 metallic sphere. Near-delta specular lobes are
##             unreachable by environment sampling, so the sky reflection must
##             come from the BSDF strategy ALONE. If environment NEE also
##             contributes there, the highlight is counted twice and the sphere
##             renders up to 2x too bright.
##   rough   - a roughness-0.6 METALLIC sphere, which probes the opposite failure:
##             energy DELETED rather than doubled. Every direction for which
##             combinedPdf() returns 0 must be handed the full BSDF weight, because
##             environment NEE's own value is zero there too and cannot collect it.
##             Metal makes pSpec = 1, so every sample is specular and maximally
##             exposed to the dot(N,L) <= 0 band that sampleSpecularMicrofacet
##             CLAMPS into rather than rejecting (evalIndirectCombinedBRDF only
##             tests the GEOMETRY plane, and a smooth-shaded sphere has
##             N != geometry_normal). Roughness 0.6 keeps it out of the delta
##             branch, which is what makes this case distinct from `smooth`.
##             Reported over the full disc AND over a silhouette annulus, where
##             grazing angles concentrate the effect.
##   bumpy   - the same rough metal plus a steep normal map. Drives the shading
##             normal far off the geometry normal, so the true-face rejection
##             (F1) and Cycles' ensure_valid_specular_reflection fire constantly,
##             and dot(N,V) <= 0 becomes common. This is the ONLY surface here
##             that reacts to the bump-correction / backfacing-V policies: it
##             moved 1.415 -> 0.836 (-41%) when they were mishandled, and
##             1.411 -> 1.079 when F1 replaced the mirror recovery with
##             Cycles' rules (roadmap 11.29).
##   plastic - a rough DIELECTRIC sphere (roughness 0.4, metallic 0). Every other
##             surface here is either metallic = 1, which makes pSpec = 1 and kills
##             the diffuse lobe outright, or near-Lambertian, which leaves the
##             specular lobe carrying almost nothing. Neither exercises the regime
##             where pSpec is strictly between 0 and 1 and BOTH lobes carry real
##             energy -- which is where the lobe-selection split in combinedPdf()
##             has to agree with the one in shade_and_bounce(), and where the
##             COMBINE_BRDFS_WITH_FRESNEL integrand mismatch became visible. That
##             mismatch is now FIXED (see the REF_PLASTIC block); this surface is
##             the only one in the gate that can detect its return, so it is the
##             one to watch after any change to the diffuse lobe or to MIS.
##   diffuse - the Lambertian plane again, as a control: it must NOT move.
##
## A SPHERE rather than a flat smooth plane is deliberate. `env_world_to_sky()`
## folds in the camera basis, so which world direction a given panorama texel
## ends up in is not predictable from the scene description; a flat mirror's
## single reflected direction could land on dim sky and the test would quietly
## measure nothing. A sphere reflects essentially every direction at once, so the
## bright patch is guaranteed to appear on it whatever the rotation works out to.
##
## Gate 2 has no closed form -- it is a comparison against numbers captured from
## a BSDF-only build. Update REF_* only alongside a deliberate integrator change,
## and say so in the commit.

const ALBEDO := 0.5 # LINEAR reflectance.
const SKY_RADIANCE := 1.0
const TOLERANCE := 0.01 # 1 percent, per the brief.

# Gate 2 reference, captured at 256 frames / 256x256 from a BSDF-only build --
# the raytracing shaders checked out at de2ce2c248, i.e. before environment NEE
# and the MIS weights existed. Both figures were stable across repeat runs
# (smooth 1.48916 / 1.48892, diffuse 0.37311 / 0.37311), and the reference's
# max pixel was exactly 20.0026: a mirror reflecting a radiance-20 sky patch
# should peak at the patch's own radiance and nothing higher, which is a useful
# independent sanity check on any future re-capture.
# RE-CAPTURED 2026-09-10 for roadmap Gap #17. The previous values were
#   REF_SMOOTH 1.48904, REF_DIFFUSE 0.37311, REF_ROUGH 1.70870,
#   REF_ROUGH_RIM 1.22400, REF_BUMPY 1.41451
# taken at de2ce2c248, which predates environment NEE AND carries the old
# evalMultiScatterApproximation. Gap #17 replaced that factor with Cycles'
# table-driven evalMultiScatterEnergy, so those numbers no longer describe a
# BSDF-only build of THIS tree, and comparing against them would have conflated
# a deliberate BRDF change with the MIS neutrality this gate exists to assert.
#
# THE RE-CAPTURE PRESERVES THE GATE'S MEANING RATHER THAN ERASING IT. These are
# NOT the current MIS-on renders. They were taken from a BSDF-only build --
# RT_ENV_NEE_ENABLED 0 in raytracing_inc.glsl, with RT_MS_COMPENSATION at its
# production value of 1 -- so the gate still asserts that turning MIS on moves
# no energy. Gate 1's pass-C std-dev read exactly 0.000000 in that build, which
# is what proves it really was BSDF-only and not merely dimmer.
#
# Measured neutrality on the current MIS-on build against these five:
#   smooth  1.48879 vs 1.48883  (-0.003%)
#   rough   1.63069 vs 1.63024  (+0.03%)
#   rim     1.24986 vs 1.25141  (-0.12%)
#   bumpy   1.41110 vs 1.41124  (-0.01%)
#   diffuse 0.37290 vs 0.37281  (+0.02%)
#
# Only `rough` moved materially from the old reference (1.70870 -> 1.63024,
# -4.6%): it is metallic 1 at roughness 0.6, where F0 = 1 made the legacy
# `1 + F0*Ems` over-shoot hardest. `smooth` barely moved (roughness 0.02, so
# E ~ 1 and the factor is ~1) and `diffuse` has no specular lobe at all.
const REF_SMOOTH := 1.48883
const REF_DIFFUSE := 0.37281
const REF_ROUGH := 1.63024 # full disc
const REF_ROUGH_RIM := 1.25141 # silhouette annulus
# RE-CAPTURED 2026-09-17 for Phase F1 (roadmap 11.29): the mirror recovery
# this surface was named for is gone -- a below-face sample now ends the path
# (Cycles' LABEL_NONE) -- and the shading normal is corrected by Cycles'
# ensure_valid_specular_reflection instead of the 0.4 clamp, on the TRUE face
# normal rather than the smooth one. Three readings on the final F1 binary:
# 1.07918 / 1.07863 / 1.07905, median taken. `rough` did not move (ratio 1.0001
# over the whole F1 sequence, so the true-face rejection band on a smooth-shaded
# sphere is below this gate's noise); `smooth`, `diffuse` and `plastic` are
# unchanged (< 0.05%). Previous value: 1.41124.
const REF_BUMPY := 1.07905 # normal-mapped rough metal
# Rough DIELECTRIC (roughness 0.4, metallic 0), added in Task 5.
#
# THIS SURFACE CARRIES THE MEASUREMENT THAT CLOSED THE COMBINE_BRDFS_WITH_FRESNEL
# INTEGRAND MISMATCH -- the open "+2.4% converged-mean shift on dielectric
# specular surfaces" that stood through Phases B and C. All four numbers below
# are re-derivable on any tree with RT_ENV_NEE_ENABLED (raytracing_inc.glsl),
# which is why they are worth keeping rather than trimming to the two the gate
# asserts on.
#
#                                    disc      silhouette rim    MIS - BSDF-only
#   BEFORE (stochastic 1 - F(V.H_random), H_random from VNDF independent of L)
#     BSDF-only   0.46667 / 0.41831
#     with MIS    0.47089 / 0.42792                              +0.91%  +2.30%
#   AFTER (deterministic 1 - data.F, the same term the evaluators apply)
#     BSDF-only   0.47112 / 0.42776
#     with MIS    0.47107 / 0.42821                              -0.01%  +0.11%
#
# The BSDF-only path is what moved: it rose ~0.95% to meet where MIS-on already
# was, which is the signature of the SAMPLER having carried the wrong integrand
# while the evaluator carried the right one. MIS-on barely moved at all
# (0.47089 -> 0.47107, +0.04%), so no rendered image gets materially brighter or
# darker from this fix -- what changed is that the two strategies now estimate
# the same function.
#
# HOW TO RE-DERIVE THE "BSDF-only" ROW, because a single build cannot produce it
# and a stale pair of constants asserting against each other would be a check
# that can never fail: set RT_ENV_NEE_ENABLED to 0 in
# servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl, rebuild,
# and run this scene again. Gate 1's pass-C std-dev must read exactly 0.000000 in
# that build -- under a constant sky BSDF sampling is a zero-variance estimator --
# which is the instrument proving it really is BSDF-only before you trust its
# gate 2 numbers. That control was itself validated against the pre-MIS build
# swap it replaces: old sampler with NEE off measured 0.46636 / 0.41767 against
# the 0.46667 / 0.41831 captured at commit de2ce2c248, i.e. 0.07% / 0.15%.
#
# REF_PLASTIC / REF_PLASTIC_RIM are what this gate asserts on, captured from the
# current (fixed, MIS-on) build. REF_PLASTIC_BSDF_ONLY / _RIM_BSDF_ONLY are the
# fixed build's control and are PRINTED, not asserted -- they are the residual
# non-neutrality, and printing them keeps its size visible instead of letting a
# 2% tolerance absorb a regression back to +2.30%.
# Run-to-run spread on this surface is ~0.03%.
# Re-taken 2026-09-10 alongside the five above, so the whole reference set comes
# from one measurement session. This surface barely moved under Gap #17
# (0.47107 -> 0.47109 MIS-on, 0.00%): it is a dielectric, F0 = 0.04, where the
# compensation is ~1.004 either way. The B2 neutrality figure it reports is
# unchanged in character: -0.01% (disc) / +0.13% (rim).
# RE-CAPTURED 2026-09-11 for Gap #21 cause (a): the base specular Fresnel is now
# Cycles' exact-dielectric remap rather than Schlick (roadmap §11.11). This is
# the ONLY surface in this gate that moves -- `smooth`, `rough` and `bumpy` are
# metallic 1, where Cycles uses F82 and our Schlick already matched, and the
# Lambertian plane has metallic_specular 0 so it carries no specular lobe at all.
# Previous values: 0.47109 / 0.42832 / 0.47105 / 0.42776.
# RE-CAPTURED AGAIN 2026-09-11 for Gap #21 cause (b): the diffuse lobe is now
# attenuated by 1 - darkening*albedo(specular, N.V), Cycles' closure_layering_weight,
# instead of 1 - F(L.H) (roadmap §11.12). Again the only surface that moves. It
# moves DOWN -- -0.91% on the disc, -2.2% on the rim -- although the furnace
# withdrawal shrank, because Cycles' withdrawal keys on the VIEW angle
# (bsdf_microfacet_estimate_albedo's cos_NI = dot(wi, N)) and is ~8.7% at the
# grazing rim where F(L.H) for a light off to the side was ~4-5%. That is the
# faithful behaviour; the rim was too bright before. Gate 1's pass-C std-dev read
# exactly 0.000000 in the control build. Previous values: 0.47660 / 0.43739 /
# 0.47657 / 0.43686.
const REF_PLASTIC := 0.47225
const REF_PLASTIC_RIM := 0.42770
const REF_PLASTIC_BSDF_ONLY := 0.47228
const REF_PLASTIC_RIM_BSDF_ONLY := 0.42711
const REF_TOLERANCE := 0.02 # 2 percent; gate 2 is a stochastic comparison.

var _plane: MeshInstance3D
var _sphere: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated path-traced sweep would
	# take hours. Disable content scaling so the viewport follows the window.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	# Otherwise the per-frame timings below just measure the display refresh.
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

	if mode == "constant" or mode == "both":
		await _gate_constant(frames)
	if mode == "directional" or mode == "both":
		await _gate_directional(frames)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - all energy gates green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


# ---------------------------------------------------------------------------
# GATE 1 - constant sky
# ---------------------------------------------------------------------------
func _gate_constant(p_frames: int) -> void:
	var env := _build_scene(_constant_panorama())
	_sphere.visible = false
	_look_down()
	# The sky's radiance octmap is rendered by the sky pass and the env CDF is
	# built from it; both need a moment before the first measurement.
	await get_tree().create_timer(2.0).timeout

	print("\n=== GATE 1: constant sky L=%.3f, Lambertian albedo %.3f ===" % [SKY_RADIANCE, ALBEDO])

	# Pass A: plane hidden, so every camera ray misses and lands on the sky with
	# mis_ray_pdf == RT_MIS_PDF_NONE (weight 1). Measures L_env as the renderer
	# actually sees it, absorbing IBL_exposure_normalization, the sky shader's own
	# scaling and the octmap round trip. The gate is a RATIO against this, so no
	# global sky scale can fake a pass or a failure.
	_plane.visible = false
	var sky_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 16)
	if sky_img == null:
		_failures.append("gate 1: accumulator readback returned null (sky pass)")
		return
	var l_sky: float = _measure_crop(sky_img, 0.25, 0.75)["mean"]
	print("  [A] sky-only mean radiance : %.5f" % l_sky)

	# Pass B: the plane.
	_plane.visible = true
	for _i in range(4):
		await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	var dt := Time.get_ticks_msec() - t0
	if img == null:
		_failures.append("gate 1: accumulator readback returned null")
		return
	var stats := _measure_crop(img, 0.25, 0.75)
	print("  [B] %d frames in %d ms (%.3f ms/frame at 256x256)" % [p_frames, dt, float(dt) / float(p_frames)])

	var expected: float = ALBEDO * l_sky
	var err: float = absf(stats["mean"] - expected) / maxf(expected, 1e-9)
	print("      measured  : %.5f  (R %.5f  G %.5f  B %.5f)" % [stats["mean"], stats["r"], stats["g"], stats["b"]])
	print("      expected  : %.5f  (rho * L_env)" % expected)
	print("      rel error : %.3f%%" % (err * 100.0))
	if err > TOLERANCE:
		_failures.append("gate 1 energy: %.5f vs %.5f expected, %.3f%% off (limit %.1f%%)"
				% [stats["mean"], expected, err * 100.0, TOLERANCE * 100.0])

	# Pass C: the variance proof described in the header.
	var few := 4
	var noisy: Image = await _render_accum(env, get_viewport().get_viewport_rid(), few)
	if noisy != null:
		var ns := _measure_crop(noisy, 0.25, 0.75)
		var sd := _stddev_crop(noisy, ns["mean"], 0.25, 0.75)
		print("  [C] %d-frame per-pixel std-dev : %.6f (mean %.5f)" % [few, sd, ns["mean"]])
		print("      %s" % ("both MIS strategies live (BSDF-only would be exactly 0)" if sd > 1e-5
				else "ZERO SPREAD - the MIS split is NOT running"))
		if sd <= 1e-5:
			_failures.append("gate 1 liveness: zero per-pixel spread under a constant sky - the MIS split is not running")


# ---------------------------------------------------------------------------
# GATE 2 - directional sky
# ---------------------------------------------------------------------------
func _gate_directional(p_frames: int) -> void:
	var env := _build_scene(_sun_panorama())
	await get_tree().create_timer(2.0).timeout

	print("\n=== GATE 2: directional sky (bright patch 20.0 vs base 0.02) ===")

	# Smooth pass: roughness-0.02 metallic sphere, nothing else.
	_plane.visible = false
	_sphere.visible = true
	_look_at_sphere()
	for _i in range(4):
		await get_tree().process_frame
	var s_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	if s_img == null:
		_failures.append("gate 2: accumulator readback returned null (smooth pass)")
		return
	var smooth := _measure_disc(s_img, 0.45)
	print("  [smooth ] mirror sphere mean : %.5f   (max pixel %.4f over %d px)"
			% [smooth["mean"], smooth["max"], smooth["n"]])

	# Rough-metal pass: the zero-pdf probe. Same sphere, roughness 0.6.
	_sphere.material_override = _rough_material()
	for _i in range(4):
		await get_tree().process_frame
	var r_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	_sphere.material_override = _smooth_material()
	if r_img == null:
		_failures.append("gate 2: accumulator readback returned null (rough pass)")
		return
	var rough := _measure_disc(r_img, 0.45)
	var rough_rim := _measure_annulus(r_img, 0.34, 0.45)
	print("  [rough  ] metal sphere mean  : %.5f   (silhouette annulus %.5f over %d px)"
			% [rough["mean"], rough_rim["mean"], rough_rim["n"]])

	# Bumpy pass: the bump-correction probe. Same rough metal plus a steep
	# tangent-space normal map, so the shading normal tilts far off the geometry
	# normal and evalIndirectCombinedBRDF's below-face rejection (F1: the path
	# ends, as in Cycles) fires constantly. That is the case that
	# actually carries throughput into the combinedPdf() == 0 path -- the plain
	# rough sphere does not, because there the specular sample weight vanishes on
	# the same NdotL -> 0 limit that drives the pdf to zero.
	_sphere.material_override = _bumpy_material()
	for _i in range(4):
		await get_tree().process_frame
	var b_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	_sphere.material_override = _smooth_material()
	if b_img == null:
		_failures.append("gate 2: accumulator readback returned null (bumpy pass)")
		return
	var bumpy := _measure_disc(b_img, 0.45)
	print("  [bumpy  ] normal-mapped mean : %.5f" % bumpy["mean"])

	# Plastic pass: rough DIELECTRIC. The only surface here with pSpec strictly
	# between 0 and 1, i.e. where the stochastic lobe choice in shade_and_bounce
	# and the mixture density in combinedPdf must agree term for term, and where
	# both lobes carry energy that MIS has to split correctly.
	_sphere.material_override = _plastic_material()
	for _i in range(4):
		await get_tree().process_frame
	var p_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	_sphere.material_override = _smooth_material()
	if p_img == null:
		_failures.append("gate 2: accumulator readback returned null (plastic pass)")
		return
	var plastic := _measure_disc(p_img, 0.45)
	var plastic_rim := _measure_annulus(p_img, 0.34, 0.45)
	print("  [plastic] rough dielectric   : %.5f   (silhouette annulus %.5f)"
			% [plastic["mean"], plastic_rim["mean"]])

	# Diffuse pass: the Lambertian plane, as a control.
	_sphere.visible = false
	_plane.visible = true
	_look_down()
	for _i in range(4):
		await get_tree().process_frame
	var d_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	if d_img == null:
		_failures.append("gate 2: accumulator readback returned null (diffuse pass)")
		return
	var diffuse := _measure_crop(d_img, 0.25, 0.75)
	print("  [diffuse] plane mean         : %.5f" % diffuse["mean"])

	if REF_SMOOTH <= 0.0 or REF_DIFFUSE <= 0.0:
		print("  (no reference captured yet - record these as REF_SMOOTH / REF_DIFFUSE)")
		return

	var s_err: float = absf(smooth["mean"] - REF_SMOOTH) / REF_SMOOTH
	var d_err: float = absf(diffuse["mean"] - REF_DIFFUSE) / REF_DIFFUSE
	print("  smooth  vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_SMOOTH, smooth["mean"] / REF_SMOOTH, s_err * 100.0])
	print("  diffuse vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_DIFFUSE, diffuse["mean"] / REF_DIFFUSE, d_err * 100.0])
	if REF_BUMPY > 0.0:
		var b_err: float = absf(bumpy["mean"] - REF_BUMPY) / REF_BUMPY
		print("  bumpy   vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_BUMPY, bumpy["mean"] / REF_BUMPY, b_err * 100.0])
		if b_err > REF_TOLERANCE:
			_failures.append("gate 2 bumpy: %.5f vs reference %.5f, ratio %.4f. This surface is the recovery / backfacing-V probe."
					% [bumpy["mean"], REF_BUMPY, bumpy["mean"] / REF_BUMPY])

	if REF_PLASTIC > 0.0:
		var p_err: float = absf(plastic["mean"] - REF_PLASTIC) / REF_PLASTIC
		var pr_err: float = absf(plastic_rim["mean"] - REF_PLASTIC_RIM) / REF_PLASTIC_RIM
		print("  plastic vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_PLASTIC, plastic["mean"] / REF_PLASTIC, p_err * 100.0])
		print("  plas.rim vs reference %.5f: ratio %.4f  (%.2f%% off)" % [REF_PLASTIC_RIM, plastic_rim["mean"] / REF_PLASTIC_RIM, pr_err * 100.0])
		print("  MIS energy neutrality on this surface: %+.2f%% (disc) / %+.2f%% (rim) vs the"
				% [(REF_PLASTIC / REF_PLASTIC_BSDF_ONLY - 1.0) * 100.0,
				(REF_PLASTIC_RIM / REF_PLASTIC_RIM_BSDF_ONLY - 1.0) * 100.0])
		print("    BSDF-only control (%.5f / %.5f). Was +0.91%% / +2.30%% before the"
				% [REF_PLASTIC_BSDF_ONLY, REF_PLASTIC_RIM_BSDF_ONLY])
		print("    COMBINE_BRDFS_WITH_FRESNEL integrand mismatch was fixed.")
		print("    These two are STORED, not measured by this run -- re-derive the control")
		print("    with RT_ENV_NEE_ENABLED 0. See the REF_PLASTIC comment block.")
		if p_err > REF_TOLERANCE:
			_failures.append("gate 2 plastic: %.5f vs reference %.5f, ratio %.4f. This is the only surface with pSpec strictly between 0 and 1 (both BRDF lobes live)."
					% [plastic["mean"], REF_PLASTIC, plastic["mean"] / REF_PLASTIC])
		if pr_err > REF_TOLERANCE:
			_failures.append("gate 2 plastic rim: %.5f vs reference %.5f, ratio %.4f (grazing band, where the diffuse-Fresnel attenuation bites hardest)."
					% [plastic_rim["mean"], REF_PLASTIC_RIM, plastic_rim["mean"] / REF_PLASTIC_RIM])
	else:
		print("  (no plastic reference captured yet - record REF_PLASTIC)")

	if REF_ROUGH > 0.0:
		var r_err: float = absf(rough["mean"] - REF_ROUGH) / REF_ROUGH
		var rr_err: float = absf(rough_rim["mean"] - REF_ROUGH_RIM) / REF_ROUGH_RIM
		print("  rough   vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_ROUGH, rough["mean"] / REF_ROUGH, r_err * 100.0])
		print("  rim     vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_ROUGH_RIM, rough_rim["mean"] / REF_ROUGH_RIM, rr_err * 100.0])
		if r_err > REF_TOLERANCE:
			_failures.append("gate 2 rough: %.5f vs reference %.5f, ratio %.4f. Below 1.0 means sky contribution is being DELETED where combinedPdf() returns 0 (no strategy collects it); above means it is double counted."
					% [rough["mean"], REF_ROUGH, rough["mean"] / REF_ROUGH])
		if rr_err > REF_TOLERANCE:
			_failures.append("gate 2 rough rim: %.5f vs reference %.5f, ratio %.4f (grazing/silhouette band)."
					% [rough_rim["mean"], REF_ROUGH_RIM, rough_rim["mean"] / REF_ROUGH_RIM])
	else:
		print("  (no rough reference captured yet - record REF_ROUGH / REF_ROUGH_RIM)")

	if s_err > REF_TOLERANCE:
		_failures.append("gate 2 smooth: %.5f vs reference %.5f, ratio %.4f. A ratio near 2 means the near-delta specular sky highlight is being counted by BOTH strategies."
				% [smooth["mean"], REF_SMOOTH, smooth["mean"] / REF_SMOOTH])
	if d_err > REF_TOLERANCE:
		_failures.append("gate 2 diffuse: %.5f vs reference %.5f, ratio %.4f (the diffuse control must not move)."
				% [diffuse["mean"], REF_DIFFUSE, diffuse["mean"] / REF_DIFFUSE])


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------
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
	r *= inv
	g *= inv
	b *= inv
	return { "r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n }


## Mean over a centred disc of radius `p_radius` in units of half the smaller
## image dimension. Used for the sphere so the measurement never picks up sky
## pixels outside the silhouette.
func _measure_disc(p_img: Image, p_radius: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	var rad := p_radius * float(mini(w, h)) * 0.5
	var rad2 := rad * rad
	var acc := 0.0
	var peak := 0.0
	var n := 0
	for y in range(h):
		for x in range(w):
			var dx := float(x) + 0.5 - cx
			var dy := float(y) + 0.5 - cy
			if dx * dx + dy * dy > rad2:
				continue
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			acc += v
			peak = maxf(peak, v)
			n += 1
	return { "mean": acc / float(maxi(n, 1)), "max": peak, "n": n }


## Mean over a centred annulus, radii in units of half the smaller image
## dimension. On the sphere this is the grazing/silhouette band, where a
## shading-normal-vs-geometry-normal disagreement is largest.
func _measure_annulus(p_img: Image, p_r_lo: float, p_r_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	var half := float(mini(w, h)) * 0.5
	var lo2 := (p_r_lo * half) * (p_r_lo * half)
	var hi2 := (p_r_hi * half) * (p_r_hi * half)
	var acc := 0.0
	var n := 0
	for y in range(h):
		for x in range(w):
			var dx := float(x) + 0.5 - cx
			var dy := float(y) + 0.5 - cy
			var d2 := dx * dx + dy * dy
			if d2 < lo2 or d2 > hi2:
				continue
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return { "mean": acc / float(maxi(n, 1)), "n": n }


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
func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


## Dim base with one bright lat-lon patch. u in [0.2,0.5], v in [0.4,0.5] is
## theta in [72deg, 90deg], so the patch covers 0.3 * (cos72 - cos90) / 2 = 4.6%
## of the sphere -- small enough to be strongly directional, large enough that it
## lands on many pixels of the mirror sphere whatever the sky rotation is.
func _sun_panorama() -> ImageTexture:
	var w := 128
	var h := 64
	var pano := Image.create(w, h, false, Image.FORMAT_RGBF)
	pano.fill(Color(0.02, 0.02, 0.02))
	for y in range(int(h * 0.40), int(h * 0.50)):
		for x in range(int(w * 0.20), int(w * 0.50)):
			pano.set_pixel(x, y, Color(20.0, 20.0, 20.0))
	return ImageTexture.create_from_image(pano)


func _look_down() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)


func _look_at_sphere() -> void:
	_cam.position = Vector3(0.0, 0.0, 4.0)
	_cam.rotation_degrees = Vector3.ZERO


func _build_scene(p_panorama: ImageTexture) -> Environment:
	for c in get_children():
		c.queue_free()

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = p_panorama
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

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(4)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias; it must be off or it eats the very energy
	# these gates are measuring.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_cam = Camera3D.new()
	_cam.fov = 55.0
	add_child(_cam)
	_cam.make_current()
	_look_down()

	# The diffuse plane: large enough that its edges are far outside the view,
	# thin box so the top face is a genuine single-sided surface under back-face
	# culling.
	_plane = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(200.0, 0.2, 200.0)
	_plane.mesh = bm
	_plane.position = Vector3(0.0, -0.1, 0.0)
	var mat := StandardMaterial3D.new()
	# ALBEDO is the LINEAR reflectance the analytic answer is written in, but
	# render_raytracing.cpp:1492 runs albedo_color through srgb_to_linear() before
	# it reaches the BRDF. Pre-encode so the shader ends up with exactly ALBEDO.
	# Without this the plane reads 0.21404 = srgb_to_linear(0.5), which looks
	# exactly like a 57% MIS energy loss and is really just a colour-space round
	# trip. This trap cost real debugging time once; do not "simplify" it away.
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb()
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Kills the dielectric specular lobe (F0 = 0.16 * specular^2), leaving a pure
	# Lambertian BRDF whose directional-hemispherical reflectance is exactly rho.
	# At the default specular = 0.5 the surface also carries an F0 = 0.04 lobe and
	# the analytic answer above no longer holds.
	mat.metallic_specular = 0.0
	_plane.material_override = mat
	add_child(_plane)

	# The near-delta mirror. metallic = 1 makes specularF0 = albedo and
	# diffuseReflectance = 0, so this surface is reached ONLY through the specular
	# lobe; roughness 0.02 is below RT_MIS_DELTA_ROUGHNESS (0.03), which is the
	# regime environment sampling must not contribute to.
	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 96
	sm.rings = 48
	_sphere.mesh = sm
	_sphere.position = Vector3.ZERO
	_sphere.material_override = _smooth_material()
	add_child(_sphere)
	_sphere.visible = false

	return env


## metallic = 1 makes specularF0 = albedo and diffuseReflectance = 0, so the
## surface is reached ONLY through the specular lobe. roughness 0.02 is below
## RT_MIS_DELTA_ROUGHNESS (0.03): the regime environment sampling must not
## contribute to at all.
func _smooth_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.metallic = 1.0
	m.roughness = 0.02
	return m


## Same metal, but roughness 0.6 -- ABOVE RT_MIS_DELTA_ROUGHNESS, so it takes the
## ordinary MIS branch rather than the delta branch. This is the configuration
## that exercises directions where combinedPdf() returns 0 while the sample was
## still generated and is still carrying throughput.
func _rough_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.metallic = 1.0
	m.roughness = 0.6
	return m


## The rough metal plus a steep tangent-space normal map. Drives the shading
## normal far off the geometry normal so below-geometry rejection and the
## mirrored-sample recovery path fire heavily.
func _bumpy_material() -> StandardMaterial3D:
	var m := _rough_material()
	m.normal_enabled = true
	m.normal_scale = 1.0
	m.normal_texture = _bump_normal_map()
	return m


## A rough DIELECTRIC: metallic 0 with the engine default specular 0.5, so
## F0 = 0.16 * 0.5^2 = 0.04 and diffuseReflectance = albedo. Roughness 0.4 keeps
## the specular lobe broad enough to be reachable by environment sampling while
## the diffuse lobe still carries most of the energy, which is what puts pSpec
## strictly between 0 and 1 -- unlike every other surface in this gate.
func _plastic_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.5, 0.5, 0.5)
	m.metallic = 0.0
	m.roughness = 0.4
	return m


func _bump_normal_map() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in range(n):
		for x in range(n):
			# Steep slopes: z = 0.45 keeps the tilt near 65 degrees at the extremes.
			var u := float(x) / float(n) * TAU * 8.0
			var v := float(y) / float(n) * TAU * 8.0
			var nv := Vector3(0.85 * sin(u), 0.85 * sin(v), 0.45).normalized()
			img.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	return ImageTexture.create_from_image(img)
