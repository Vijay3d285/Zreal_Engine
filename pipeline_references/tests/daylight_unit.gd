extends SceneTree

## Headless unit checks for daylight.gd (spec 2026-09-19-daylight-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/daylight_unit.gd
##
## Pure functions only: no viewport, no path tracer. The rendered checks are
## pt_daylight_gate.gd.
##
## A failed `assert()` anywhere under daylight.gd stalls this run silently in
## this editor build (this -s invocation pauses waiting for a debugger: no
## output, no exit, no error) rather than raising a catchable error -- if the
## script prints nothing for about a minute, it is stalled, not slow; kill
## the process and check daylight.gd's asserts (2026-09-19: `step & (step -
## 1) == 0` parsed as `step & ((step - 1) == 0)` -- `==` binds tighter than
## `&` in GDScript -- and failed on every step > 1).

const LIVE_DAY_EXR := "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/day.exr"
# Full-resolution (8192 x 4096) upward-facing irradiance of day.exr, measured
# 2026-09-19 in Blender/numpy (cosine- and equirect-weighted, mean of RGB).
const DAY_EXR_E_SKY := 1.62

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (%+.2f%%, tol %.1f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_true(p_name: String, p_cond: bool) -> void:
	_checks += 1
	print("  %s: %s" % [p_name, "ok" if p_cond else "FAILED"])
	if not p_cond:
		_failures.append(p_name)


## Equirect panorama whose radiance depends on elevation only:
## L = p_zenith at the top row falling linearly (in theta) to p_horizon at
## the equator, p_ground below. Analytic irradiance is integrated in the
## test with 100x finer theta steps than the image has, so the two
## estimates disagree only by the image's own discretisation.
func _gradient_panorama(p_w: int, p_h: int, p_zenith: float, p_horizon: float, p_ground: float) -> Image:
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGBF)
	for y in range(p_h):
		var theta := (float(y) + 0.5) / float(p_h) * PI
		var l := p_ground
		if theta < PI * 0.5:
			l = lerpf(p_zenith, p_horizon, theta / (PI * 0.5))
		for x in range(p_w):
			img.set_pixel(x, y, Color(l, l, l))
	return img


func _analytic_gradient_irradiance(p_zenith: float, p_horizon: float) -> float:
	var n := 20000
	var d_theta := (PI * 0.5) / float(n)
	var e := 0.0
	for i in range(n):
		var theta := (float(i) + 0.5) * d_theta
		var l := lerpf(p_zenith, p_horizon, theta / (PI * 0.5))
		e += l * TAU * cos(theta) * sin(theta) * d_theta
	return e


func _init() -> void:
	print("\n=== daylight_unit: sky_irradiance ===")
	var uniform := Image.create(64, 32, false, Image.FORMAT_RGBF)
	uniform.fill(Color(1.0, 1.0, 1.0))
	_check("U1 uniform sky of 1 -> pi", Daylight.sky_irradiance(uniform), PI, 0.005)
	var half := Image.create(64, 32, false, Image.FORMAT_RGBF)
	half.fill(Color(0.5, 0.5, 0.5))
	_check("U2 uniform sky of 0.5 -> pi/2", Daylight.sky_irradiance(half), PI * 0.5, 0.005)
	var grad := _gradient_panorama(512, 256, 1.2, 0.6, 0.3)
	_check("U3 gradient sky vs analytic", Daylight.sky_irradiance(grad), _analytic_gradient_irradiance(1.2, 0.6), 0.01)
	# The ground half must not contribute: a panorama that is 0 above and 5 below reads 0.
	var below := _gradient_panorama(64, 32, 0.0, 0.0, 5.0)
	_check_true("U4 ground rows excluded", Daylight.sky_irradiance(below) < 1e-6)
	if FileAccess.file_exists(LIVE_DAY_EXR):
		var exr := Image.new()
		if exr.load(LIVE_DAY_EXR) == OK:
			_check("U5 day.exr E_sky (256x128 estimate vs full-res 1.62)", Daylight.sky_irradiance(exr), DAY_EXR_E_SKY, 0.01)
		else:
			_failures.append("U5 day.exr failed to load")
	else:
		print("  U5 SKIP: %s not present on this machine" % LIVE_DAY_EXR)

	print("\n=== daylight_unit: subsample / stats ===")
	# 40 x 20 image: left 32 columns at 0.1, right 8 columns at 20.0 (a "window"),
	# the edge on a 4-pixel boundary so 4x4 box averages are pure.
	var frame := Image.create(40, 20, false, Image.FORMAT_RGBF)
	for y in range(20):
		for x in range(40):
			var l := 0.1 if x < 32 else 20.0
			frame.set_pixel(x, y, Color(l, l, l))
	var s := Daylight.subsample(frame, 4)
	_check_true("S1 subsample count 10x5", s.size() == 50)
	# Box average, not point sample: a 4x4 block that is half 0.1 / half 0.3
	# must read 0.2 (a point sample at its corner would read 0.1).
	var checker := Image.create(4, 4, false, Image.FORMAT_RGBF)
	for y in range(4):
		for x in range(4):
			var v := 0.1 if x < 2 else 0.3
			checker.set_pixel(x, y, Color(v, v, v))
	var sc := Daylight.subsample(checker, 4)
	_check_true("S1b one block", sc.size() == 1)
	_check("S1c block is the 4x4 mean", sc[0], 0.2, 1e-5)
	var st := Daylight.stats(s)
	_check("S2 raw median (window in the top quintile only)", st["raw_median"], 0.1, 1e-6)
	_check("S3 occupied fraction 0.8", st["occupied_fraction"], 0.8, 1e-6)
	_check("S4 occupied median 0.1", st["median"], 0.1, 1e-6)
	_check("S5 exposure 0.18 / 0.1", st["exposure"], 1.8, 1e-6)
	_check_true("S6 not clamped", not st["clamped"])
	var black := PackedFloat32Array()
	black.resize(100)
	black.fill(0.0)
	var stb := Daylight.stats(black)
	_check("S7 black frame clamps to EXPOSURE_MAX", stb["exposure"], Daylight.EXPOSURE_MAX, 1e-6)
	_check_true("S8 black frame reports clamped", stb["clamped"])

	print("\n=== daylight_unit: solve_fill ===")
	# Room lit: 100 samples, p25 already above the floor after exposure -> no fill.
	var lit := PackedFloat32Array()
	for i in range(100):
		lit.append(0.05 + 0.001 * i) # median 0.0995 -> e 1.81; p25 0.0745 * e = 0.135
	var lit1 := PackedFloat32Array()
	for i in range(100):
		lit1.append(lit[i] + 0.5)
	var r0 := Daylight.solve_fill(lit, lit1)
	_check_true("F1 lit room needs no fill", not r0["needed"])
	_check("F1 lit room exposure", r0["exposure"], 0.18 / 0.0995, 0.02)
	# Dark corners: 75 samples at 0.2, 25 at 0.001. e = 0.9 -> p25 0.0009 < 0.02.
	# A unit fill adds 0.1 everywhere. Solve: p25(f) * 0.18 / median(f) >= 0.02
	#   (0.001 + 0.1 f) * 0.18 / (0.2 + 0.1 f) >= 0.02
	#   0.00018 + 0.018 f >= 0.004 + 0.002 f  ->  f >= 0.2388;
	#   the 1.1-step scan from 0.01 lands on 0.01 * 1.1^34 = 0.2555 (<= 10% above).
	var dark := PackedFloat32Array()
	var dark1 := PackedFloat32Array()
	for i in range(100):
		var v := 0.2 if i < 75 else 0.001
		dark.append(v)
		dark1.append(v + 0.1)
	var r1 := Daylight.solve_fill(dark, dark1)
	_check_true("F2 dark corners need a fill", r1["needed"])
	_check_true("F2 energy in [0.2388, 0.2627]", r1["energy"] >= 0.2388 and r1["energy"] <= 0.2627)
	_check("F2 p25 * e lands on the floor", r1["p25"] * r1["exposure"], Daylight.FLOOR, 0.10)
	_check_true("F2 not capped", not r1["capped"])
	# Cap: 75 at 0.02, 25 at 0.0; unit fill adds 1.0. The floor needs f such that
	#   (1.0 f) * 0.18 / (0.02 + f) >= 0.02  ->  f >= 0.0025, but the share cap
	#   (median(f) - median(0)) / median(f) >= 0.5 is hit at f = 0.02 -- the floor
	#   is met first, so this is NOT capped. Then a case that IS: 75 at 0.02,
	#   25 at 0.0, unit fill adds 0.01 to the dark quarter only and 1.0 elsewhere:
	#   p25(f) * e(f) = 0.01 f * 0.18 / (0.02 + f) reaches 0.02 only past f = 0.2 ...
	#   share at f = 0.02 is already 0.5 -> capped.
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	for i in range(100):
		var v := 0.02 if i < 75 else 0.0
		c0.append(v)
		c1.append(v + (1.0 if i < 75 else 0.01))
	var r2 := Daylight.solve_fill(c0, c1)
	_check_true("F3 fill that cannot reach the corners is capped", r2["capped"])
	_check("F3 capped at share 0.5 (f = 0.02)", r2["energy"], 0.02, 0.10)

	print("")
	if _failures.is_empty():
		print("PASS: all %d daylight unit checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		quit(1)
