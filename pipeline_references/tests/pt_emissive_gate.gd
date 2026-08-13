extends "res://tests/pt_validation.gd"

## Path-tracer ENERGY gates for EMISSIVE-MESH LIGHT SAMPLING (roadmap C1).
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_emissive_gate_scene.tscn
##
## Every gate here renders the SAME scene twice -- `rendering/pathtracer/
## emissive_mesh_lights` off, then on -- inside ONE process. The setting is read
## per frame (`GLOBAL_GET` in render_raytracing.cpp:2780) and drives a raygen
## specialization constant, so a single binary can run both sides. That matters
## for more than convenience: the C2 gates had to compare two BUILDS, which put a
## rebuild and an unknown amount of thermal drift between the two numbers. Here
## the only thing that differs between the two renders is the setting.
##
## Every scene is lit ONLY by emissive geometry: no analytic lights and no sky
## (BG_COLOR black, so render_raytracing.cpp binds DEFAULT_RD_TEXTURE_BLACK, every
## environment CDF cell has luminance 0, and env_sample() returns false on its
## first branch). So every photon in every image below arrived either through
## emissive NEE or through a BSDF ray that stumbled onto the panel.
##
## Env vars:
##   ZR_EMIS_GATE_MODE  "invariance" | "analytic" | "nearfield" | "all"  (default "all")
##   ZR_EMIS_FRAMES     accumulated frames per render   (default 2048)
##   ZR_EMIS_RES        square render resolution        (default 192)
##
## ---------------------------------------------------------------------------
## GATE 3 IS NOT IN THIS FILE, DELIBERATELY.
##
## Gate 3 is sampler-widening neutrality: C1 Task 1 widened RT_PRNG_BOUNCE_NUM
## from 8 to 16, which re-stratifies EVERY bounce in every scene, emissive or not.
## The right way to measure that is against an existing scene's already-recorded
## reference, with this feature OFF, and that scene and those references already
## exist:
##
##   ZR_GATE_MODE=in_range ZR_GATE_FRAMES=2048 ZR_GATE_RES=256 \
##       bin/godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_light_gate_scene.tscn
##
## A shift there is Task 1's problem and NOT a C1 defect; duplicating the scene
## here would invite someone to read it as one.
##
## ---------------------------------------------------------------------------
## WHAT `w_bsdf` MEANS BELOW, AND WHY EVERY GATE REPORTS IT
##
## MIS splits each emissive surface between two strategies. The BSDF half's share
## of the energy is
##
##     w_bsdf = pdf_bsdf^2 / (pdf_bsdf^2 + pdf_light^2)     (power heuristic, beta=2)
##
## and the number printed per gate is that weight INTEGRATED over the emitter and
## weighted by each direction's contribution -- i.e. literally the fraction of the
## measured brightness that flows through the BSDF half rather than through NEE.
##
## This is load-bearing for what the gates can prove. On a small, distant emitter
## w_bsdf is ~1e-5: the image is NEE-only, and a build whose BSDF half was
## silently zeroed would produce the SAME mean and the SAME spread as a correct
## one. Such a configuration rules out double-counting and gross energy loss and
## rules out nothing else. That is why the `nearfield` gate exists: there
## w_bsdf ~ 0.56, so more than half the light in the image is carried by the BSDF
## half, and its absolute-energy assertion fails outright if that half is dead.
##
## The formulas are the shader's own. For a floor of metallic_specular = 0 the
## specular lobe's F0 is zero, so combinedPdf()'s pSpec is 0 and the BSDF density
## is exactly the Lambertian cosine density NdotL/PI (brdf_inc.glsl:433). For a
## single emitter instance P(inst) = 1, and uniform-over-triangles times
## uniform-in-area gives pdf_A = 1/instance_area independently of the tessellation:
## a QuadMesh's two triangles each have half the area and are picked half the time.
## pdf_light in solid angle is then pdf_A * dist^2 / cos_light
## (emissive_pdf_solid_angle, raytracing_emissive_inc.glsl:296).

const SETTING := "rendering/pathtracer/emissive_mesh_lights"

## LINEAR reflectance of every measured floor. Fed to the material through
## linear_to_srgb() because render_raytracing.cpp runs albedo_color back through
## srgb_to_linear() before the BRDF sees it.
const ALBEDO := 0.5

## Quadrature resolution for the closed-form predictions: QUAD_N^2 samples over
## the emitter for each of RECV_N^2 points across the measured crop. Converged to
## well under 0.01% against 4x these counts for every geometry here.
const QUAD_N := 64
const RECV_N := 7

## MINIMUM EFFECT SIZE FOR THE LIVENESS PROBE. `on < off` alone is a COIN FLIP on
## an inert build, and that is the exact failure this gate exists to catch.
##
## Two renders of the same configuration are not bit-identical here (the OFF side
## moves in the 5th decimal place run to run), so on a build where the setting
## never reaches the shader the two spreads differ by a small random amount and
## the sign of that difference is a fair coin. Both spread probes are computed
## from the SAME image pair, so they are correlated and the joint pass probability
## is near 50%, not 25%. Nothing else in the suite covers it: with the feature
## wholly inert, gate 4's ON equals its OFF equals the prediction and gate 4
## passes, gate 2 passes, and the RMSE sweep -- which would show it enormously --
## asserts nothing and exits 0.
##
## So the probe demands a MINIMUM RATIO, not merely a sign. The sampling error of
## a ratio of two standard deviations estimated from n pixels is about 1/sqrt(n)
## = 0.87% at n = 13225, so 1.05 sits ~5.7 sigma above 1.0 (an inert build fails
## it deterministically) while the measured ratios of 1.236 and 1.249 clear it by
## ~20 sigma. Raise this only with a measurement in hand.
const LIVENESS_MIN_RATIO := 1.05

## Multiplier on the derived standard error for the energy band, and therefore
## THE DETECTION FLOOR: this gate cannot see an energy regression smaller than
## SIGMA_MULTIPLIER x the run's own standard error. On gate 1 at 2048 frames that
## floor is ~0.43%. It is printed at run time so nobody has to work it out.
##
## 6 rather than 3, deliberately. The OFF estimator in every scene here is
## HEAVY-TAILED -- a small emitter found by a BSDF ray once in thousands -- so its
## Gaussian standard error is a LOWER BOUND on its true uncertainty, and a nominal
## 3 sigma band computed from an understated sigma is not really 3 sigma. Halving
## this to 3.0 would halve the detection floor to ~0.22% at the cost of a gate
## that fails a correct build often enough to be ignored. The consequence is
## recorded rather than hidden: the -0.284% residual on
## pt_emissive_compile_scene.tscn (task-6-report.md section 6) is BELOW what this
## band can resolve, which is why it is carried as an unexplained observation and
## not as a finding.
const SIGMA_MULTIPLIER := 6.0

var _res := 192
var _frames := 2048
var _failures: Array[String] = []
var _cam_main: Camera3D
var _cam_emitter: Camera3D


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated run would take hours.
	var r_env := OS.get_environment("ZR_EMIS_RES")
	if r_env.is_valid_int():
		_res = maxi(64, r_env.to_int())
	var f_env := OS.get_environment("ZR_EMIS_FRAMES")
	if f_env.is_valid_int():
		_frames = maxi(32, f_env.to_int())

	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(_res, _res)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))
	print("frames per render   : %d" % _frames)

	var mode := OS.get_environment("ZR_EMIS_GATE_MODE")
	if mode == "":
		mode = "all"

	if mode == "invariance" or mode == "all":
		await _gate_invariance()
	if mode == "analytic" or mode == "all":
		await _gate_analytic()
	if mode == "nearfield" or mode == "all":
		await _gate_nearfield()

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - emissive-mesh light gates green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


# ---------------------------------------------------------------------------
# GATE 1 - MIS invariance and the variance win
# ---------------------------------------------------------------------------
## A Lambertian room with real occluders lit only by one emissive quad.
##
## THE MEAN CANNOT BE THE LIVENESS PROBE HERE. Both estimators are unbiased for
## the same integral, so equal converged means is the CORRECTNESS assertion --
## and it is equally satisfied by an NEE block that never fires. C3 shipped a gate
## with exactly that hole and only a variance probe caught it. So the per-pixel
## spread is asserted too, and it is the half of this gate that proves the two
## renders were not the same render twice.
func _gate_invariance() -> void:
	var half := 1.0 # 2.0 m quad
	var height := 3.5
	var env := _build_room_scene(half * 2.0, height, 40.0)
	await _settle()

	# A 0.2 m x 0.2 m patch of floor directly under the panel, as a representative
	# point: this scene is a room, so there is no single crop footprint the closed
	# form applies to, and this number is reported rather than asserted.
	var w_bsdf: float = _predict(half, height, 0.1, 0.1)["w_bsdf"]
	print("\n=== GATE 1: MIS invariance (room, 2.0 m panel at y=%.2f) ===" % height)
	print("  lit only by one emissive quad; walls, boxes and spheres as occluders")
	print("  w_bsdf (BSDF half's share of the direct energy at the room-centre")
	print("          floor point, unoccluded geometry only) : %.5f" % w_bsdf)
	print("  -> this configuration is NEE-dominated. It rules out double counting")
	print("     and gross energy deletion; it does NOT probe the BSDF half. That")
	print("     is gate 4's job.")

	var off := await _pass(env, false, 0.2, 0.8)
	var on := await _pass(env, true, 0.2, 0.8)
	if off.is_empty() or on.is_empty():
		_failures.append("gate 1: accumulator readback returned null")
		return

	_report_pair("gate 1", off, on)

	# --- assertion A: the converged means agree -----------------------------
	# The tolerance is DERIVED from this run's own noise, not hardcoded. The
	# per-pixel spread mixes real spatial variation into the estimate, so the
	# standard error is taken from the HIGH-PASS noise sigma (adjacent-pixel
	# first differences), which cancels the smooth signal and leaves the
	# pixel-independent Monte Carlo noise. 6 sigma, floored at 0.2% so a
	# spectacularly converged pair cannot produce an unmeetable gate, and capped
	# at 3% so a spectacularly noisy one cannot produce a vacuous one.
	var se_rel: float = sqrt(off["se"] * off["se"] + on["se"] * on["se"]) / maxf(off["mean"], 1e-9)
	var tol: float = clampf(SIGMA_MULTIPLIER * se_rel, 0.002, 0.03)
	var rel: float = (on["mean"] - off["mean"]) / maxf(off["mean"], 1e-9)
	print("  combined standard error : %.4f%% relative" % (se_rel * 100.0))
	print("  derived tolerance (%.0f se, clamped to [0.2%%, 3%%]) : %.3f%%"
			% [SIGMA_MULTIPLIER, tol * 100.0])
	print("  DETECTION FLOOR: this gate cannot see an energy regression below")
	print("                   %.3f%%. See SIGMA_MULTIPLIER for why it is 6 and not 3." % (tol * 100.0))
	if is_nan(rel) or is_inf(rel):
		# A NaN passes `> tol` AND `< tol` silently. It has to be caught first.
		_failures.append("gate 1: relative shift is not a finite number (%f). One of the two means is NaN or the OFF mean is zero." % rel)
	elif absf(rel) > tol:
		_failures.append("gate 1 invariance: ON is %+.3f%% off OFF (derived limit %.3f%%). %s"
				% [rel * 100.0, tol * 100.0,
				"Above the band: the emissive hit is not MIS-weighted and the panel is counted twice."
						if rel > 0.0 else "Below the band: the weight is deleting energy rather than redistributing it."])

	# --- assertion B: the spread falls, BY A MINIMUM AMOUNT -------------------
	# This is the half that distinguishes a working build from an inert one.
	#
	# THE HIGH-PASS NOISE SIGMA IS THE LOAD-BEARING PROBE, and it is the one that
	# carries the LIVENESS_MIN_RATIO minimum effect size (see that constant for why
	# a bare `on < off` is a coin flip on an inert build).
	#
	# THE RAW STD-DEV CHECK BELOW IT IS WEAK AND IS KNOWN TO BE WEAK, and it is
	# deliberately NOT given a minimum ratio, because it could not meet one. At
	# 2048 frames the raw std-dev of this scene is dominated by the room's real
	# spatial structure rather than by noise, so almost all of it cancels between
	# the two renders. Three measured margins, in order:
	#
	#     0.562422 vs 0.561645  ->  +0.138%
	#     0.562255 vs 0.561645  ->  +0.109%
	#     0.561870 vs 0.561642  ->  +0.041%
	#
	# All the right sign, none of them large, and the third is inside the
	# run-to-run wobble of the OFF side. THIS ASSERTION CAN FAIL A CORRECT BUILD.
	# It is kept because the acceptance criterion names it and because the sign has
	# been reproducible, NOT because it discriminates -- a build where the setting
	# never reached the shader would pass it about half the time. The noise sigma
	# above is what makes such a build fail deterministically. If this one ever
	# fails while the noise sigma still clears LIVENESS_MIN_RATIO, that is this
	# statistic being weak and not the feature being broken: read the sigma, and do
	# not loosen either threshold to make it green.
	var noise_ratio: float = off["noise"] / maxf(on["noise"], 1e-12)
	print("  liveness: noise sigma ratio %.3fx, minimum required %.2fx"
			% [noise_ratio, LIVENESS_MIN_RATIO])
	if not (noise_ratio > LIVENESS_MIN_RATIO):
		_failures.append("gate 1 liveness: high-pass noise sigma fell by only %.3fx (OFF %.6f, ON %.6f); %.2fx is required. Equal means alone are also produced by an NEE block that never fires, and a spread that barely moves says the setting never reached the shader (stale .glsl.gen.h) or the NEE block is inert. A bare sign test would have passed this on a coin flip."
				% [noise_ratio, off["noise"], on["noise"], LIVENESS_MIN_RATIO])
	if not (on["sd"] < off["sd"]):
		_failures.append("gate 1 liveness (WEAK PROBE, see the comment above): raw per-pixel std-dev did not fall (OFF %.6f, ON %.6f). Check the noise sigma before treating this as a defect -- at 2048 frames the raw std-dev of this scene is signal-dominated and its margin is ~0.1%%."
				% [off["sd"], on["sd"]])


# ---------------------------------------------------------------------------
# GATE 2 - absolute energy against a closed form
# ---------------------------------------------------------------------------
## An emissive quad of area A and radiance L directly above an unoccluded
## Lambertian patch of albedo rho, both facing each other, camera looking straight
## down. For a patch small relative to the distance d,
##
##     E   ~= L * A * cos(t1) * cos(t2) / d^2
##     L_o  = rho * E / PI
##
## L IS MEASURED, NOT ASSUMED. A second camera looks straight up into the panel
## and reads its radiance out of the same accumulator: a camera ray carries
## RT_MIS_PDF_NONE (scene_raytracing_raygen.glsl:60), so the primary hit on an
## emitter takes MIS weight 1 and the pixel value IS L in whatever units
## emissive_exposure_normalization has put it. That removes every constant this
## gate would otherwise have to guess -- emission_energy_multiplier's scaling, the
## exposure normalization, the sRGB round trip -- and leaves a pure geometry test.
func _gate_analytic() -> void:
	var half := 0.25 # 0.5 m quad
	var height := 4.0
	var area := 4.0 * half * half
	var env := _build_analytic_scene(half * 2.0, height, 40.0, 2.0, 3.0)
	await _settle()

	var crop := _crop_extent(2.0, 55.0, 0.40, 0.60)
	print("\n=== GATE 2: analytic (0.5 m panel at y=%.2f over a bare rho=%.2f floor) ===" % [height, ALBEDO])
	print("  geometry: quad %.3f x %.3f m (A = %.6f m^2) centred on the origin at" % [half * 2.0, half * 2.0, area])
	print("            y = %.3f facing down; floor top face at y = 0.000, albedo" % height)
	print("            %.3f LINEAR; camera at (0, 2.0, 0) fov 55 (vertical) looking" % ALBEDO)
	print("            straight down; crop 0.40..0.60 of the frame = %.4f x %.4f m"
			% [crop.x * 2.0, crop.y * 2.0])
	print("            about the axis. Radiance camera at (0, 3.0, 0) looking up.")

	var pred := _predict(half, height, crop.x, crop.y)
	print("  w_bsdf : %.6f  -- NEE carries essentially all of it" % pred["w_bsdf"])

	var radiance := await _measure_emitter_radiance(env)
	if radiance < 0.0:
		_failures.append("gate 2: emitter-radiance readback returned null")
		return
	print("  measured emitter radiance L : %.6f" % radiance)

	# Closed form (the brief's small-patch approximation) at the axis point.
	var predicted: float = ALBEDO * radiance * area / (PI * height * height)
	# And the same integral without the approximation, over the crop the render
	# actually measures, so the reader can see how much of any residual is the
	# approximation itself rather than the renderer.
	var predicted_exact: float = ALBEDO * radiance * pred["E"] / PI
	print("  closed form  L_o = rho*L*A/(pi*d^2)   : %.6f" % predicted)
	print("  exact quadrature over emitter + crop  : %.6f  (%+.3f%% vs the closed form)"
			% [predicted_exact, (predicted_exact / maxf(predicted, 1e-12) - 1.0) * 100.0])

	var off := await _pass(env, false, 0.40, 0.60)
	var on := await _pass(env, true, 0.40, 0.60)
	if off.is_empty() or on.is_empty():
		_failures.append("gate 2: accumulator readback returned null")
		return
	_report_pair("gate 2", off, on)

	# Only ON is asserted. OFF is reported because it is the same integral by a
	# different strategy and should agree -- but a 0.5 m panel at 4 m is found by
	# roughly one BSDF ray in a thousand, so its own standard error is far wider
	# than the 2% band and asserting it would produce a flaky gate, not a stricter
	# one. The printed OFF standard error is there so that comparison can be made
	# honestly rather than by eye.
	const TOL := 0.02
	var rel: float = (on["mean"] - predicted) / maxf(predicted, 1e-12)
	var rel_exact: float = (on["mean"] - predicted_exact) / maxf(predicted_exact, 1e-12)
	var rel_off: float = (off["mean"] - predicted) / maxf(predicted, 1e-12)
	print("  measured ON  : %.6f   (%+.3f%% vs closed form, %+.3f%% vs exact)"
			% [on["mean"], rel * 100.0, rel_exact * 100.0])
	print("  measured OFF : %.6f   (%+.3f%% vs closed form, +/- %.3f%% standard error)"
			% [off["mean"], rel_off * 100.0, off["se"] / maxf(predicted, 1e-12) * 100.0])
	if is_nan(rel) or is_inf(rel):
		_failures.append("gate 2: relative error is not a finite number (%f)" % rel)
	elif absf(rel) > TOL:
		_failures.append("gate 2 analytic: measured %.6f vs closed form %.6f, %+.3f%% (limit %.1f%%)"
				% [on["mean"], predicted, rel * 100.0, TOL * 100.0])
	if absf(rel_exact) > TOL:
		_failures.append("gate 2 analytic (exact form): measured %.6f vs exact quadrature %.6f, %+.3f%% (limit %.1f%%). The small-patch approximation is not the explanation here."
				% [on["mean"], predicted_exact, rel_exact * 100.0, TOL * 100.0])


# ---------------------------------------------------------------------------
# GATE 4 - the BSDF half, made load-bearing
# ---------------------------------------------------------------------------
## THE GATE THE TASK 5 REVIEW ASKED FOR, and the reason it exists:
##
## On the scene C1 has been measured on so far, pdf_light / pdf_bsdf is about 34,
## so w_bsdf is about 0.00085. A correct MIS partition and one whose BSDF half is
## silently zeroed produce the same mean AND the same spread there -- the image is
## NEE-only either way. Gates 1 and 2 therefore cannot see a dead BSDF half.
##
## Here the panel is 2.0 m across at 0.6 m -- large and near instead of small and
## far -- which puts pdf_light BELOW pdf_bsdf over most of the emitter and pushes
## the BSDF half's share of the energy to ~0.56. The assertion is absolute energy
## against an exact quadrature of the same integral, so a build that dropped the
## BSDF half would read ~44% of the prediction and fail by 25 sigma, not by a
## judgement call.
##
## The prediction is exact rather than approximate here because the small-patch
## form is meaningless at these proportions: the panel subtends most of the
## hemisphere. Both the emitter and the measured crop are integrated numerically.
## Nothing else in the scene reflects (the panel's albedo is black and the floor is
## planar, so there is no interreflection to model), so direct lighting is the
## whole image.
func _gate_nearfield() -> void:
	var half := 1.0 # 2.0 m quad
	var height := 0.6
	var area := 4.0 * half * half
	var cam_h := 0.4
	var env := _build_analytic_scene(half * 2.0, height, 3.0, cam_h, 0.3)
	await _settle()

	var crop := _crop_extent(cam_h, 55.0, 0.25, 0.75)

	print("\n=== GATE 4: near-field, BSDF half LOAD-BEARING (2.0 m panel at y=%.2f) ===" % height)
	print("  geometry: quad %.3f x %.3f m (A = %.6f m^2) centred on the origin at" % [half * 2.0, half * 2.0, area])
	print("            y = %.3f facing down; floor top face at y = 0.000, albedo" % height)
	print("            %.3f LINEAR; camera at (0, %.2f, 0) fov 55 (vertical) looking" % [ALBEDO, cam_h])
	print("            straight down; crop 0.25..0.75 = %.4f x %.4f m about the axis."
			% [crop.x * 2.0, crop.y * 2.0])
	print("            Radiance camera at (0, 0.30, 0) looking straight up.")

	var pred := _predict(half, height, crop.x, crop.y)
	var w_bsdf: float = pred["w_bsdf"]
	print("  w_bsdf : %.4f  <-- MORE THAN HALF the energy in this image is carried" % w_bsdf)
	print("           by the BSDF half. Zero it and the measurement below reads")
	print("           %.1f%% of the prediction." % ((1.0 - w_bsdf) * 100.0))

	var radiance := await _measure_emitter_radiance(env)
	if radiance < 0.0:
		_failures.append("gate 4: emitter-radiance readback returned null")
		return
	print("  measured emitter radiance L : %.6f" % radiance)

	# Exact prediction, integrated over the emitter AND over the crop footprint.
	var predicted: float = ALBEDO * radiance * pred["E"] / PI
	print("  exact prediction L_o = rho*L*E/pi, E over emitter + crop : %.6f" % predicted)
	print("  (the small-patch closed form is NOT usable at these proportions:")
	print("   it would give %.6f, %+.1f%% off.)"
			% [ALBEDO * radiance * area / (PI * height * height),
			(area / (height * height) / maxf(pred["E"], 1e-12) - 1.0) * 100.0])

	var off := await _pass(env, false, 0.25, 0.75)
	var on := await _pass(env, true, 0.25, 0.75)
	if off.is_empty() or on.is_empty():
		_failures.append("gate 4: accumulator readback returned null")
		return
	_report_pair("gate 4", off, on)

	const TOL := 0.02
	var rel_on: float = (on["mean"] - predicted) / maxf(predicted, 1e-12)
	var rel_off: float = (off["mean"] - predicted) / maxf(predicted, 1e-12)
	print("  measured ON  : %.6f   (%+.3f%% vs prediction)" % [on["mean"], rel_on * 100.0])
	print("  measured OFF : %.6f   (%+.3f%% vs prediction)" % [off["mean"], rel_off * 100.0])

	# BOTH sides are asserted here, unlike gate 2. OFF is BSDF-only against a large
	# near emitter, which converges perfectly well, so it carries a real standard
	# error and is worth pinning: it establishes that the prediction is right
	# independently of any NEE code, which is what makes the ON assertion a test of
	# the partition rather than of the arithmetic.
	for row in [["ON", on["mean"], rel_on], ["OFF", off["mean"], rel_off]]:
		var r: float = row[2]
		if is_nan(r) or is_inf(r):
			_failures.append("gate 4 (%s): relative error is not a finite number (%f)" % [row[0], r])
		elif absf(r) > TOL:
			_failures.append("gate 4 near-field (%s): measured %.6f vs exact prediction %.6f, %+.3f%% (limit %.1f%%). With w_bsdf = %.3f, a dead BSDF half reads %+.1f%%."
					% [row[0], row[1], predicted, r * 100.0, TOL * 100.0, w_bsdf, -w_bsdf * 100.0])


# ---------------------------------------------------------------------------
# Passes and reporting
# ---------------------------------------------------------------------------
func _pass(p_env: Environment, p_on: bool, p_lo: float, p_hi: float) -> Dictionary:
	ProjectSettings.set_setting(SETTING, p_on)
	print("\n  --- %s emissive_mesh_lights ---" % ("ENABLE" if p_on else "DISABLE"))
	# The setting drives a specialization constant, so flipping it forces a fresh
	# raygen pipeline compile; the first EmissiveLights build also has to land.
	# Give both room before any measured frame is accumulated.
	for _i in range(30):
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout

	var t0 := Time.get_ticks_msec()
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), _frames)
	var dt := Time.get_ticks_msec() - t0
	if img == null:
		return {}
	var s := _measure_crop(img, p_lo, p_hi)
	s["sd"] = _stddev_crop(img, s["mean"], p_lo, p_hi)
	s["noise"] = _noise_sigma_crop(img, p_lo, p_hi)
	s["se"] = s["noise"] / sqrt(float(maxi(s["n"], 1)))
	s["ms"] = float(dt) / float(_frames)
	if s["sd"] <= 1e-9:
		_failures.append("zero per-pixel spread with the setting %s - nothing stochastic is running"
				% ("ON" if p_on else "OFF"))
	return s


func _report_pair(p_tag: String, p_off: Dictionary, p_on: Dictionary) -> void:
	print("\n  %s summary (%d frames, %dx%d, crop %d px)"
			% [p_tag, _frames, _res, _res, int(p_off["n"])])
	print("            |        mean |     std-dev |  noise sigma |   ms/frame")
	print("    --------+-------------+-------------+--------------+-----------")
	print("    OFF     | %11.6f | %11.6f | %12.6f | %9.4f"
			% [p_off["mean"], p_off["sd"], p_off["noise"], p_off["ms"]])
	print("    ON      | %11.6f | %11.6f | %12.6f | %9.4f"
			% [p_on["mean"], p_on["sd"], p_on["noise"], p_on["ms"]])
	var d: float = p_on["mean"] - p_off["mean"]
	print("    mean delta        : %+.6f  (%+.3f%%)" % [d, d / maxf(p_off["mean"], 1e-9) * 100.0])
	print("    std-dev ratio     : %.3fx   (OFF / ON)" % (p_off["sd"] / maxf(p_on["sd"], 1e-12)))
	print("    noise sigma ratio : %.3fx   (OFF / ON)" % (p_off["noise"] / maxf(p_on["noise"], 1e-12)))
	print("    frame-time delta  : %+.2f%%" % ((p_on["ms"] / maxf(p_off["ms"], 1e-9) - 1.0) * 100.0))


## Radiance of the emitter itself, read off a camera pointed straight into it.
## A camera ray carries RT_MIS_PDF_NONE so the primary emissive hit takes weight 1
## and the pixel is exactly the emitted radiance -- deterministic, hence the small
## frame count.
func _measure_emitter_radiance(p_env: Environment, p_frames: int = 32) -> float:
	_cam_emitter.make_current()
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), p_frames)
	_cam_main.make_current()
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	if img == null:
		return -1.0
	return _measure_crop(img, 0.45, 0.55)["mean"]


func _settle() -> void:
	# The TLAS build, the emissive area pass and the light buffer upload all need
	# to land before anything is measured.
	await get_tree().create_timer(2.0).timeout


# ---------------------------------------------------------------------------
# Measurement (same shapes as pt_light_gate.gd, plus the high-pass noise probe)
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


## Per-pixel MONTE CARLO noise, isolated from the image's real spatial variation.
##
## `_stddev_crop` mixes the two: on a scene with shading gradients most of it is
## signal, and using it for a standard error would produce a tolerance set by how
## contrasty the scene is rather than by how noisy the render is. Adjacent pixels
## share the signal but carry independent noise, so the standard deviation of
## first differences is sqrt(2) times the noise alone. That is what the tolerance
## in gate 1 is derived from.
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


# ---------------------------------------------------------------------------
# Closed forms
# ---------------------------------------------------------------------------
## Half-extents, in METRES on the floor plane, of the crop `p_lo`..`p_hi` of the
## frame, for a camera at height `p_cam_y` looking straight down.
##
## READ OFF THE ACTUAL VIEWPORT, never assumed square. The window manager on this
## machine refuses widths below ~148 px, so `ZR_EMIS_RES=96` renders 148x96 and
## the crop is 1.54x wider in world space than it is tall. Assuming a square frame
## there mis-states the prediction by ~0.6% -- comparable to the whole residual
## these gates are trying to resolve. Godot's Camera3D defaults to
## `KEEP_ASPECT_HEIGHT`, so `fov` is the VERTICAL field of view and the horizontal
## extent is the vertical one times the viewport aspect.
func _crop_extent(p_cam_y: float, p_fov_deg: float, p_lo: float, p_hi: float) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var aspect: float = float(vp.x) / maxf(float(vp.y), 1.0)
	var half_v: float = p_cam_y * tan(deg_to_rad(p_fov_deg * 0.5))
	var crop_v: float = (p_hi - p_lo) * half_v
	return Vector2(crop_v * aspect, crop_v)


## Everything the closed forms need, in ONE quadrature: the irradiance per unit
## emitted radiance, and the BSDF strategy's share of it.
##
## The emitter is a horizontal, downward-facing, uniformly emitting square of
## half-extent `p_half` at height `p_h`. The receiver is the horizontal
## rectangle -p_cx..p_cx by -p_cz..p_cz on the floor plane -- the actual measured
## crop, not a point, because at gate 4's proportions the irradiance varies
## materially across it.
##
##   E        = INT cos_s * cos_l / dist^2 dA           (per unit radiance)
##   pdf_bsdf = cos_s / PI                              (Lambertian, pSpec == 0)
##   pdf_light= (1 / area) * dist^2 / cos_l             (emissive_pdf_solid_angle)
##   w_bsdf   = pdf_bsdf^2 / (pdf_bsdf^2 + pdf_light^2) (power heuristic, beta=2)
##
## `w_bsdf` is returned WEIGHTED by each direction's contribution to E, which is
## what "the BSDF half's share of the energy" means: zero that half and the
## measured brightness falls by this fraction.
##
## `pdf_light` uses 1/area independently of the tessellation because
## P(inst) * (1/prim_count) * (1/area_tri) collapses to 1/area for a single
## emitter whose triangles are equal -- which a QuadMesh's two are.
func _predict(p_half: float, p_h: float, p_cx: float, p_cz: float) -> Dictionary:
	var area: float = 4.0 * p_half * p_half
	var e_step := 2.0 * p_half / float(QUAD_N)
	var rx_step := 2.0 * p_cx / float(RECV_N)
	var rz_step := 2.0 * p_cz / float(RECV_N)
	var e_acc := 0.0
	var w_num := 0.0
	var w_den := 0.0
	for ri in range(RECV_N):
		var px := -p_cx + (float(ri) + 0.5) * rx_step
		for rj in range(RECV_N):
			var pz := -p_cz + (float(rj) + 0.5) * rz_step
			for i in range(QUAD_N):
				var x := -p_half + (float(i) + 0.5) * e_step
				for j in range(QUAD_N):
					var z := -p_half + (float(j) + 0.5) * e_step
					var dx := x - px
					var dz := z - pz
					var d2 := dx * dx + p_h * p_h + dz * dz
					var dist := sqrt(d2)
					var cos_s := p_h / dist # cos at the receiver, N = +Y
					var cos_l := p_h / dist # cos at the emitter, Ne = -Y
					var f := cos_s * cos_l / d2
					var pdf_b := cos_s / PI
					var pdf_l := (1.0 / area) * d2 / cos_l
					e_acc += f
					w_num += f * (pdf_b * pdf_b / (pdf_b * pdf_b + pdf_l * pdf_l))
					w_den += f
	var n_recv := float(RECV_N * RECV_N)
	return {
		"E": e_acc * e_step * e_step / n_recv,
		"w_bsdf": w_num / maxf(w_den, 1e-30),
	}


# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------
func _new_env() -> Environment:
	var env := Environment.new()
	# No sky at all: render_raytracing.cpp binds DEFAULT_RD_TEXTURE_BLACK, every
	# environment CDF cell has luminance 0 and env_sample() returns false on its
	# first branch. Environment NEE is inert by construction.
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
	# Clamping is a deliberate bias and it truncates exactly the heavy tail a
	# BSDF-only estimator produces on a small emitter -- leaving it on would
	# flatter the control and understate the difference.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	# Adaptive sampling freezes converged pixels; these gates measure the
	# un-accelerated estimator.
	env.set_pathtracing_noise_threshold(0.0)
	return env


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()


## Front-face-only emission is deliberate and matches lights_eval_rect_light, so
## the quad's orientation is load-bearing: flipped, the room goes black. A
## QuadMesh faces +Z; rotating +90 degrees about X takes +Z to -Y.
##
## THE ONLY EMISSIVE INSTANCE IN EVERY SCENE HERE. That is what makes P(inst) = 1
## in the printed w_bsdf; add a second emitter and those numbers stop being right.
func _add_emitter(p_size: float, p_y: float, p_energy: float) -> void:
	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(p_size, p_size)
	panel.mesh = quad
	panel.position = Vector3(0.0, p_y, 0.0)
	panel.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0, 0, 0)
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.emission_enabled = true
	m.emission = Color(1.0, 1.0, 1.0)
	m.emission_energy_multiplier = p_energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = m
	add_child(panel)


## A flat Lambertian floor whose top face sits at y = 0, wide enough that its
## edges are far outside every view here.
func _add_floor() -> void:
	var floor_node := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(200.0, 0.2, 200.0)
	floor_node.mesh = bm
	floor_node.position = Vector3(0.0, -0.1, 0.0)
	floor_node.material_override = _diffuse_material(Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb())
	add_child(floor_node)


## Pure Lambertian. metallic_specular = 0 kills the dielectric lobe (F0 =
## 0.16 * specular^2); at the default 0.5 the surface still carries an F0 = 0.04
## lobe, combinedPdf()'s pSpec stops being zero, and the analytic gates below stop
## being closed-form.
func _diffuse_material(p_col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_col
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	return mat


## Gates 2 and 4: bare floor, one panel, two cameras.
func _build_analytic_scene(p_size: float, p_height: float, p_energy: float,
		p_cam_y: float, p_rad_cam_y: float) -> Environment:
	_clear()
	var env := _new_env()
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_cam_main = Camera3D.new()
	_cam_main.fov = 55.0
	_cam_main.position = Vector3(0.0, p_cam_y, 0.0)
	_cam_main.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(_cam_main)
	_cam_main.make_current()

	# Straight up into the panel, close enough that the 0.45..0.55 crop lands well
	# inside it.
	_cam_emitter = Camera3D.new()
	_cam_emitter.fov = 55.0
	_cam_emitter.position = Vector3(0.0, p_rad_cam_y, 0.0)
	_cam_emitter.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(_cam_emitter)

	_add_floor()
	_add_emitter(p_size, p_height, p_energy)
	return env


## Gate 1: a closed Lambertian room with real occluders. The occluders matter --
## on a bare unoccluded plane the shadow ray survives everywhere and the two
## strategies differ only in which point on the panel they picked.
func _build_room_scene(p_size: float, p_height: float, p_energy: float) -> Environment:
	_clear()
	var env := _new_env()
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Above the camera and outside its downward cone, so the panel is never a
	# directly-visible (and therefore noiseless) part of the measured crop.
	_cam_main = Camera3D.new()
	_cam_main.fov = 55.0
	_cam_main.position = Vector3(0.0, 3.0, 2.8)
	_cam_main.rotation_degrees = Vector3(-35.0, 0.0, 0.0)
	add_child(_cam_main)
	_cam_main.make_current()
	_cam_emitter = _cam_main

	_add_floor()
	# Walls and ceiling: real interreflection, and they keep the light in the room.
	_add_box(Vector3(0.0, 2.0, -3.2), Vector3(6.4, 4.0, 0.3), Color(0.66, 0.30, 0.26))
	_add_box(Vector3(-3.2, 2.0, 0.0), Vector3(0.3, 4.0, 6.4), Color(0.28, 0.54, 0.30))
	_add_box(Vector3(3.2, 2.0, 0.0), Vector3(0.3, 4.0, 6.4), Color(0.30, 0.36, 0.62))
	_add_box(Vector3(0.0, 4.1, 0.0), Vector3(6.4, 0.3, 6.4), Color(0.72, 0.70, 0.66))

	# Occluders between the panel and the floor, so the panel's visibility varies
	# sharply and the shadow rays have traversal work to do.
	_add_box(Vector3(-1.2, 0.6, -0.6), Vector3(0.9, 1.2, 0.9), Color(0.74, 0.72, 0.68))
	_add_box(Vector3(1.4, 0.4, 0.4), Vector3(1.1, 0.8, 0.7), Color(0.70, 0.68, 0.62))
	for i in range(6):
		_add_box(Vector3(0.0, 2.6, -1.6 + float(i) * 0.7), Vector3(4.4, 0.12, 0.22),
				Color(0.58, 0.52, 0.44))
	_add_sphere(Vector3(-0.4, 0.55, 1.1), 0.55, Color(0.80, 0.78, 0.74), 1.0, 0.0)
	_add_sphere(Vector3(1.9, 0.45, -1.5), 0.45, Color(0.85, 0.80, 0.70), 1.0, 0.0)

	_add_emitter(p_size, p_height, p_energy)
	return env


func _add_box(p_pos: Vector3, p_size: Vector3, p_col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = p_size
	mi.mesh = bm
	mi.position = p_pos
	mi.material_override = _diffuse_material(p_col)
	add_child(mi)


func _add_sphere(p_pos: Vector3, p_radius: float, p_col: Color, p_rough: float, p_metal: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = p_radius
	sm.height = p_radius * 2.0
	sm.radial_segments = 48
	sm.rings = 24
	mi.mesh = sm
	mi.position = p_pos
	var mat := _diffuse_material(p_col)
	mat.roughness = p_rough
	mat.metallic = p_metal
	mi.material_override = mat
	add_child(mi)
