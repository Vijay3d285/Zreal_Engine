# Daylight Design (Gap #31) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Day renders are lit by a physically proportioned sun and sky, exposed by a measurement of the job's own frame, with at most one measured fallback fill — replacing the fill grid, the portal spots and the guessed exposure. Spec: `docs/superpowers/specs/2026-09-19-daylight-design.md`.

**Architecture:** A new pure-function script `pipeline_references/daylight.gd` (sky irradiance integral, probe statistics, fill solver, the probe coroutine) that both the pipeline and a new gate call. `image_glb_creation.gd` normalises the panorama and sets the sun; `render.gd` skips the rig on day renders and runs the probe before the still. No engine change.

**Tech Stack:** GDScript (Godot 4.7 fork), the fork's path tracer via `Environment.pathtracing_*`, Python 3 + numpy for the EXR validation script, Blender 5.2 (`"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"`) as the EXR→PFM converter.

## Global Constraints

- Build: `python -m SCons platform=windows target=editor tests=yes -j8` (bare `scons` is not on PATH). No engine files change in this plan, so **no rebuild is needed**; the current `bin/godot.windows.editor.x86_64.console.exe` is the binary.
- Gates run headless-in-a-window: `bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/<gate>_scene.tscn`. `ZR_GATE_FRAMES=64` shortens a gate for iteration; the recorded numbers come from the default.
- `albedo_color` on a `StandardMaterial3D` is sRGB-encoded by the RT upload (`srgb_to_linear()`): every linear albedo in a gate is authored as `Color(a, a, a).linear_to_srgb()`. `metallic_specular = 0.0` on Lambertian probes.
- Gate viewports: msaa/FXAA/TAA/debanding off, `SCALING_3D_MODE_BILINEAR @ 1.0`, `TONE_MAPPER_LINEAR`, `AMBIENT_SOURCE_DISABLED` (memory: gates reading the viewport inherit project AA).
- The accumulator resets only on the accumulate toggle off→on (three settle frames each side — `PTValidation._render_accum`), a camera move, a resize or a shader-flag change. Exposure changes and added lights do **not** reset it.
- Constants, verbatim from the spec: `DAYLIGHT_SUN_TO_SKY = 5.0` (the sun's `light_energy` is `SUN_TO_SKY / π`: energy E is irradiance πE in the tracer), probe statistics on 4 × 4 BOX AVERAGES (`shrink_x2()` twice), not point samples, `DAYLIGHT_TARGET_MEDIAN = 0.18`, `DAYLIGHT_FLOOR = 0.02`, `DAYLIGHT_MASK_RATIO = 8.0`, `DAYLIGHT_PROBE_FRAMES = 16`, `DAYLIGHT_PROBE_STEP = 4`, exposure clamp `[0.05, 50.0]`, fill share cap `0.5`, fill scan `f = 0.01 × 1.1ⁿ`.
- `day_render` is `lighting_profile != "night"` (`image_glb_creation.gd:455`), so **sunset is a day render** and gets the same treatment.
- Night renders must be byte-identical before/after (Task 7 measures the repeat floor first — memory: renders may or may not be reproducible).
- The live project (`C:\Zlendo2026\ZlenderRender_stage_copy\godot_project`) is **not** edited by this plan; `pipeline_references/` is the reference copy the user mirrors across. `day.exr` (200 MB) lives only in the live project.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Brief history for implementers: my task briefs in earlier phases contained an error on every task, each caught by an implementer reading the surrounding code rather than transcribing. If a code block or value here does not fit the code around it, follow the code and report the lines that justified it. If unsure which is right, stop and ask.

---

## File map

| file | responsibility |
|---|---|
| `pipeline_references/daylight.gd` (create) | `class_name Daylight`, `extends RefCounted`. Pure functions: `sky_irradiance`, `subsample`, `stats`, `solve_fill`; the coroutine `probe`; the constants. No scene tree access except through the node passed to `probe`. |
| `pipeline_references/tests/daylight_unit.gd` (create) | Headless unit checks of the pure functions (`extends SceneTree`, run with `-s`). |
| `pipeline_references/tests/pt_daylight_gate.gd` + `pt_daylight_gate_scene.tscn` (create) | The rendered gate D1–D6. |
| `pipeline_references/image_glb_creation.gd` (modify) | Sky normalisation at load; sun 5.0; rig removals; the JSON-fields log line. |
| `pipeline_references/render.gd` (modify) | Skip `setup_fixed_fill_lights()` on day renders; probe → exposure → fill → still. |
| `tools/daylight_validation.py` (create) | Measures a job's linear EXR against the spec's numbers. |
| `docs/superpowers/specs/2026-09-19-daylight-design.md` (modify) | "Measured" section. |
| `PATH_TRACER_QUALITY_ROADMAP.md` (modify) | §11.27 closeout. |

---

### Task 1: `daylight.gd` pure functions + headless unit test

**Files:**
- Create: `pipeline_references/daylight.gd`
- Create: `pipeline_references/tests/daylight_unit.gd`

**Interfaces (produces):**
```gdscript
class_name Daylight extends RefCounted
const SUN_TO_SKY := 5.0
const SUN_ENERGY := SUN_TO_SKY / PI  # DirectionalLight3D.light_energy: energy E is irradiance pi*E in the tracer
const TARGET_MEDIAN := 0.18
const FLOOR := 0.02
const MASK_RATIO := 8.0
const PROBE_FRAMES := 16
const PROBE_STEP := 4
const EXPOSURE_MIN := 0.05
const EXPOSURE_MAX := 50.0
const FILL_SHARE_CAP := 0.5
static func sky_irradiance(p_img: Image) -> float                      # upward-facing irradiance of an equirect panorama
static func subsample(p_img: Image, p_step: int) -> PackedFloat32Array # mean-RGB luminance of p_step x p_step BOX AVERAGES (p_step a power of two), row-major
static func stats(p_samples: PackedFloat32Array) -> Dictionary         # {raw_median, median, p25, occupied_fraction, exposure, clamped}
static func solve_fill(p_s0: PackedFloat32Array, p_s1: PackedFloat32Array) -> Dictionary
                                                                       # {needed: bool, energy, exposure, median, p25, capped}
```

- [ ] **Step 1: Write the failing unit test**

`pipeline_references/tests/daylight_unit.gd`:

```gdscript
extends SceneTree

## Headless unit checks for daylight.gd (spec 2026-09-19-daylight-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/daylight_unit.gd
##
## Pure functions only: no viewport, no path tracer. The rendered checks are
## pt_daylight_gate.gd.

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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/daylight_unit.gd 2>&1 | grep -v "icon.svg" | tail -5
```

Expected: a parse error naming `Daylight` as an unknown identifier (the class does not exist yet), non-zero exit. If `--headless` refuses to start on this build, drop `--headless` and add `--rendering-driver vulkan`; note which form worked in the file's header comment.

- [ ] **Step 3: Write `daylight.gd`**

`pipeline_references/daylight.gd`:

```gdscript
class_name Daylight
extends RefCounted

## Daylight design for day renders (docs/superpowers/specs/2026-09-19-daylight-design.md).
##
## Pure functions plus one coroutine, shared by the pipeline (render.gd /
## image_glb_creation.gd) and pt_daylight_gate.gd so the gate proves the code
## the pipeline runs. Nothing here touches the scene tree except through the
## node handed to probe().
##
## Units: the tracer reads a white Lambertian surface under a uniform sky of
## radiance L as L (irradiance pi*L), and under a DirectionalLight3D of
## energy E at incidence theta as E*cos(theta)/pi. The panorama is normalised
## so a horizontal surface receives irradiance exactly 1 from the sky; the sun
## is then SUN_TO_SKY in the same units.

## Direct-normal over diffuse-horizontal irradiance for a 10 AM clear sky:
## ~90 klux direct vs ~18 klux diffuse. The one look-defining constant.
const SUN_TO_SKY := 5.0
## Photographic mid-grey: the occupied frame's median after exposure.
const TARGET_MEDIAN := 0.18
## Darkest occupied quarter must reach this after exposure, or a fill is added.
const FLOOR := 0.02
## Pixels above MASK_RATIO x the raw median are sky seen through windows
## (a physical sky is 50-100x the wall) and are excluded from the statistics.
const MASK_RATIO := 8.0
const PROBE_FRAMES := 16
## Statistics are taken at every PROBE_STEP-th pixel in x and y.
const PROBE_STEP := 4
const EXPOSURE_MIN := 0.05
const EXPOSURE_MAX := 50.0
## The fill may supply at most this share of the occupied median.
const FILL_SHARE_CAP := 0.5
const FILL_SCAN_START := 0.01
const FILL_SCAN_STEP := 1.1
const FILL_SCAN_MAX_ITER := 400
## Downsample the panorama to this before integrating (256 x 128 of an
## 8192 x 4096 EXR estimates its full-resolution irradiance within 1%).
const IRRADIANCE_W := 256
const IRRADIANCE_H := 128
## Frames to hold each side of the accumulate off/on edge so the rendering
## server observes the transition (pt_validation.gd RESET_SETTLE_FRAMES).
const RESET_SETTLE_FRAMES := 3


## Upward-facing irradiance of an equirect panorama (v = 0 is the zenith, as
## Godot's PanoramaSkyMaterial maps it: v = acos(dir.y) / PI):
##   E = sum over rows with theta < pi/2, all columns, of
##       L * cos(theta) * sin(theta) * (2 pi / W) * (pi / H)
## A uniform sky of radiance 1 gives pi. Same integral as
## pt_sky_energy_gate.gd _analytic_outgoing_radiance() without the azimuthal
## shortcut.
static func sky_irradiance(p_img: Image) -> float:
	var img := p_img
	if p_img.get_width() > IRRADIANCE_W or p_img.get_height() > IRRADIANCE_H:
		img = p_img.duplicate()
		img.resize(IRRADIANCE_W, IRRADIANCE_H, Image.INTERPOLATE_CUBIC)
	var w := img.get_width()
	var h := img.get_height()
	var d_theta := PI / float(h)
	var d_phi := TAU / float(w)
	var e := 0.0
	for y in range(h):
		var theta := (float(y) + 0.5) * d_theta
		if theta >= PI * 0.5:
			break
		var weight := cos(theta) * sin(theta) * d_theta * d_phi
		var row := 0.0
		for x in range(w):
			var c := img.get_pixel(x, y)
			row += (c.r + c.g + c.b) / 3.0
		e += row * weight
	return e


## Mean-RGB luminance of p_step x p_step BOX AVERAGES, row-major. p_step
## must be a power of two (1, 2, 4, 8): each shrink_x2() halves the image
## with an exact 2x2 mean in C++. Box averages rather than point samples:
## the sample median of noisy pixels is biased low (path-tracing noise is
## right-skewed) -- a point-sampled 16-frame probe read 7.5% under the
## 256-frame still on the gate's windowed room; averaging 16 pixels first
## cuts the per-sample variance 16x and the skew with it (spec section 2).
static func subsample(p_img: Image, p_step: int) -> PackedFloat32Array:
	var img := p_img.duplicate()
	var step := maxi(1, p_step)
	assert((step & (step - 1)) == 0, "subsample: p_step must be a power of two") # == binds tighter than & in GDScript
	while step > 1 and img.get_width() >= 2 and img.get_height() >= 2:
		img.shrink_x2()
		step /= 2
	var out := PackedFloat32Array()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			out.append((c.r + c.g + c.b) / 3.0)
	return out


static func _percentile(p_sorted: PackedFloat32Array, p_q: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	var idx := int(floor(p_q * float(p_sorted.size() - 1)))
	return p_sorted[clampi(idx, 0, p_sorted.size() - 1)]


## Occupancy mask + exposure from a probe's luminance samples.
## Returns {raw_median, median, p25, occupied_fraction, exposure, clamped}.
## `median` and `p25` are over the OCCUPIED samples (<= MASK_RATIO x raw median).
static func stats(p_samples: PackedFloat32Array) -> Dictionary:
	var sorted := p_samples.duplicate()
	sorted.sort()
	var raw_median := _percentile(sorted, 0.5)
	var occupied := PackedFloat32Array()
	var cut := raw_median * MASK_RATIO
	for v in sorted:
		if v <= cut:
			occupied.append(v)
		else:
			break # sorted ascending: everything after is excluded too
	var median := _percentile(occupied, 0.5)
	var p25 := _percentile(occupied, 0.25)
	var clamped := false
	var exposure := EXPOSURE_MAX
	if median > 0.0:
		exposure = TARGET_MEDIAN / median
	else:
		clamped = true # a black frame: nothing to expose for
	if exposure < EXPOSURE_MIN or exposure > EXPOSURE_MAX:
		clamped = true
		exposure = clampf(exposure, EXPOSURE_MIN, EXPOSURE_MAX)
	return {
		"raw_median": raw_median,
		"median": median,
		"p25": p25,
		"occupied_fraction": float(occupied.size()) / float(maxi(p_samples.size(), 1)),
		"exposure": exposure,
		"clamped": clamped,
	}


## Fill energy from two probes: p_s0 without the fill, p_s1 with it at energy
## 1.0 (same pixels, same order). Per pixel L(f) = L0 + f (L1 - L0). Scans f
## geometrically from FILL_SCAN_START and returns the first f whose
## p25(f) * e(f) reaches FLOOR, with e(f) = TARGET_MEDIAN / median(f)
## recomputed at every step (the fill lifts the median too). Capped where
## the fill's share of the occupied median, (median(f) - median(0)) /
## median(f), reaches FILL_SHARE_CAP.
## Returns {needed, energy, exposure, median, p25, capped}.
static func solve_fill(p_s0: PackedFloat32Array, p_s1: PackedFloat32Array) -> Dictionary:
	var base := stats(p_s0)
	if base["p25"] * base["exposure"] >= FLOOR:
		return {"needed": false, "energy": 0.0, "exposure": base["exposure"],
				"median": base["median"], "p25": base["p25"], "capped": false}
	var n := mini(p_s0.size(), p_s1.size())
	var f := FILL_SCAN_START
	var mixed := PackedFloat32Array()
	mixed.resize(n)
	var last := base
	for _i in range(FILL_SCAN_MAX_ITER):
		for k in range(n):
			mixed[k] = p_s0[k] + f * (p_s1[k] - p_s0[k])
		var st := stats(mixed)
		last = st
		var share := 0.0
		if st["median"] > 0.0:
			share = (st["median"] - base["median"]) / st["median"]
		if st["p25"] * st["exposure"] >= FLOOR:
			return {"needed": true, "energy": f, "exposure": st["exposure"],
					"median": st["median"], "p25": st["p25"], "capped": false}
		if share >= FILL_SHARE_CAP:
			return {"needed": true, "energy": f, "exposure": st["exposure"],
					"median": st["median"], "p25": st["p25"], "capped": true}
		f *= FILL_SCAN_STEP
	return {"needed": true, "energy": f, "exposure": last["exposure"],
			"median": last["median"], "p25": last["p25"], "capped": true}


## Drives a fresh accumulation of p_frames frames and reads the linear
## accumulator back, subsampled. p_node is any node in the tree (for
## process_frame); p_env the Environment; p_vp the viewport RID.
## Transcribed from pt_validation.gd _render_accum(): the accumulate flag
## must be seen off for several server frames before it is set on again, or
## the driver keeps the old average.
static func probe(p_node: Node, p_env: Environment, p_vp: RID, p_frames: int = PROBE_FRAMES, p_step: int = PROBE_STEP) -> Dictionary:
	var prev_target := p_env.pathtracing_accumulation_target
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	for _i in range(p_frames):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = RenderingServer.viewport_get_pathtracing_accum_image(p_vp)
	p_env.pathtracing_accumulation_target = prev_target
	if img == null or img.is_empty():
		return {"samples": PackedFloat32Array(), "width": 0, "height": 0}
	return {"samples": subsample(img, p_step), "width": img.get_width(), "height": img.get_height()}


## Resets the accumulator the same way probe() does, without rendering
## anything: call before the final still so it starts from a cleared buffer.
static func reset_accumulator(p_node: Node, p_env: Environment) -> void:
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	p_env.pathtracing_accumulate = true
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
```

- [ ] **Step 4: Run the unit test to verify it passes**

Same command as Step 2. Expected: `PASS: all N daylight unit checks passed.` (U5 prints SKIP on a machine without the live `day.exr`; on this machine it must run and pass). If U3 is outside 1%, the row/column weighting is wrong — compare against `pt_sky_energy_gate.gd:304` before touching tolerances. If F2's energy lands outside `[0.2388, 0.2627]`, print `r1` and check the scan start/step against the constants; do not widen the band.

- [ ] **Step 5: Commit**

```bash
git add pipeline_references/daylight.gd pipeline_references/tests/daylight_unit.gd
git commit -m "feat(pipeline): daylight.gd -- panorama irradiance, probe statistics, fill solver, accumulator probe; headless unit checks

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `pt_daylight_gate` D1/D2 — sky normalisation and sun ratio

**Files:**
- Create: `pipeline_references/tests/pt_daylight_gate.gd`
- Create: `pipeline_references/tests/pt_daylight_gate_scene.tscn`

**Interfaces:**
- Consumes: `Daylight.sky_irradiance`, `Daylight.SUN_TO_SKY`, `Daylight.SUN_ENERGY` (Task 1); `PTValidation._render_accum` (`tests/pt_validation.gd`).
- Produces: the gate file that Tasks 3 and 4 extend with D3–D6; helpers `_gradient_panorama()`, `_new_env(pano, multiplier)`, `_card_scene()`, `_crop()`, `_check()`.

- [ ] **Step 1: Write the scene file**

`pipeline_references/tests/pt_daylight_gate_scene.tscn` (copy of the portal gate's scene with the script path changed — open `pt_portal_gate_scene.tscn`, keep everything, replace the script resource):

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_daylight_gate.gd" id="1"]

[node name="DaylightGate" type="Node3D"]
script = ExtResource("1")
```

Check `pt_portal_gate_scene.tscn` first; if it carries more than this (a node type other than `Node3D`, extra nodes), mirror it exactly and change only the name and script.

- [ ] **Step 2: Write the gate with D1/D2 and the control**

`pipeline_references/tests/pt_daylight_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Daylight design gate (spec 2026-09-19-daylight-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_daylight_gate_scene.tscn
##
## Every number here is computed from the source panorama or from the sun's
## energy, never from a render (pt_sky_energy_gate.gd's rule). Sky: a
## synthetic 512 x 256 equirect, zenith 1.2 -> horizon 0.6 (linear in
## theta), ground 0.3, whose irradiance Daylight.sky_irradiance() puts near
## 2.4 -- so a forgotten multiplier reads 2.4x, not 1x.
##
##   D0 control : card under the UNnormalised sky reads E_sky / pi (proves the
##                multiplier is what moves D1, not the integral)
##   D1 sky     : card, sky normalised (energy_multiplier = 1 / E_sky) -> 1/pi
##   D2 sun     : D1 + sun at 45 deg elevation, light_energy SUN_ENERGY
##                (= SUN_TO_SKY / pi: a DirectionalLight3D of energy E is
##                irradiance pi*E in the tracer, as in Godot's raster --
##                measured here 2026-09-19) -> (1 + 5 cos 45) / pi
##   D3 exposure: windowed room probe, then a FRAMES_HI still: occupied
##                median x e -> 0.18
##   D4 no fill : windowed room -> p25 x e >= 0.02, solver says no fill
##   D5 fill    : dark room (opening bricked, albedo 0.3, one corner omni):
##                solver places DaylightFill; rendered with it, p25 x e = 0.02
##                and median x e = 0.18
##   D6 mask    : camera facing the window: excluded fraction vs the window's
##                projected area
##
## albedo_color is sRGB-encoded: linear values are authored through
## linear_to_srgb(). Tolerances: 3% on D0-D2 (pt_sky_energy_gate probe B
## found a 1.5-2.2% peaked-sky shortfall, Gap #27; this sky is smooth but
## the same estimator is under test).

var FRAMES_HI: int = 256 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const TOL_ENERGY := 0.03
const TOL_EXPOSURE := 0.05
const TOL_FLOOR := 0.10
const TOL_MASK := 0.20
const ALBEDO := 0.8
const ALBEDO_DARK := 0.3
const PANO_W := 512
const PANO_H := 256
const SKY_ZENITH := 1.2
const SKY_HORIZON := 0.6
const SKY_GROUND := 0.3
const SUN_ELEVATION_DEG := 45.0
# Card crop: the down-looking camera sees only the card (2 x 2 m from 1 m,
# 90 deg FOV would just fit; 60 deg sees the middle 1.15 m). Centre 40%.
const CARD_ROWS := [0.30, 0.70, 0.30, 0.70]

var _failures: Array[String] = []
var _checks: int = 0
var _pano: Image


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await get_tree().process_frame
	await get_tree().process_frame

	_pano = _gradient_panorama()
	var e_sky := Daylight.sky_irradiance(_pano)
	print("gate sky E_sky = %.5f (uniform 1 would be %.5f)" % [e_sky, PI])
	_checks += 1
	if absf(e_sky - 1.0) < 0.2:
		_failures.append("gate sky irradiance %.4f is too close to 1: the normalisation could not be told from no-op" % e_sky)

	print("\n=== D0: control, card under the unnormalised sky ===")
	var ctrl := await _card_scene(1.0, false)
	_check("D0 card x pi vs E_sky", _crop(ctrl, CARD_ROWS) * PI, e_sky, TOL_ENERGY)

	print("\n=== D1: sky normalised to unit irradiance ===")
	var d1 := await _card_scene(1.0 / e_sky, false)
	_check("D1 card x pi", _crop(d1, CARD_ROWS) * PI, 1.0, TOL_ENERGY)

	print("\n=== D2: + sun at %.0f deg, light_energy %.4f (sun:sky %.1f) ===" % [SUN_ELEVATION_DEG, Daylight.SUN_ENERGY, Daylight.SUN_TO_SKY])
	var d2 := await _card_scene(1.0 / e_sky, true)
	var expected_d2 := 1.0 + Daylight.SUN_TO_SKY * cos(deg_to_rad(90.0 - SUN_ELEVATION_DEG))
	_check("D2 card x pi", _crop(d2, CARD_ROWS) * PI, expected_d2, TOL_ENERGY)

	print("")
	if _failures.is_empty():
		print("PASS: all %d daylight checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (%+.2f%%, tol %.0f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s: %s %s" % [p_name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
		_failures.append("%s %s" % [p_name, p_detail])


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await get_tree().process_frame


func _lambert(p_albedo_linear: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo_linear, p_albedo_linear, p_albedo_linear).linear_to_srgb()
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	return m


## One quad: centre, size (width, height), and the rotation that turns a
## +Z-facing QuadMesh the way it should face.
func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## Radiance depends on elevation only: SKY_ZENITH at v = 0 falling linearly
## in theta to SKY_HORIZON at the equator, SKY_GROUND below. Mipmapped as the
## pipeline's EXR is.
func _gradient_panorama() -> Image:
	var img := Image.create(PANO_W, PANO_H, false, Image.FORMAT_RGBF)
	for y in range(PANO_H):
		var theta := (float(y) + 0.5) / float(PANO_H) * PI
		var l := SKY_GROUND
		if theta < PI * 0.5:
			l = lerpf(SKY_ZENITH, SKY_HORIZON, theta / (PI * 0.5))
		for x in range(PANO_W):
			img.set_pixel(x, y, Color(l, l, l))
	img.generate_mipmaps()
	return img


func _new_env(p_pano: Image, p_multiplier: float) -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(p_pano)
	sky_mat.filter = true
	sky_mat.energy_multiplier = p_multiplier
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_1024
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
	env.set_pathtracing_max_bounces(16)
	env.set_pathtracing_max_diffuse_bounce(16)
	env.set_pathtracing_max_glossy_bounce(16)
	return env


## A 2 x 2 m white horizontal card, alone under the sky, seen from 1 m above
## straight down. The sun, when on, is a DirectionalLight3D shining along
## its -Z; it is rotated so the light comes from SUN_ELEVATION_DEG above the
## horizon (incidence 90 - elevation on the horizontal card).
func _card_scene(p_multiplier: float, p_sun: bool) -> Image:
	await _clear()
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(2.0, 2.0), Vector3(-90.0, 0.0, 0.0), _lambert(1.0)) # faces +Y
	if p_sun:
		var sun := DirectionalLight3D.new()
		sun.light_energy = Daylight.SUN_ENERGY
		sun.light_color = Color(1.0, 1.0, 1.0)
		sun.light_angular_distance = 0.0
		sun.shadow_enabled = true
		add_child(sun)
		# -Z must point DOWN toward the card at the given elevation: rotate
		# about X by -(elevation) so a light at elevation 90 points straight down.
		sun.rotation_degrees = Vector3(-SUN_ELEVATION_DEG, 0.0, 0.0)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.0, 0.0)
	add_child(cam)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # look straight down
	cam.make_current()
	var env := _new_env(_pano, p_multiplier)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES_HI)


func _crop(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))
```

- [ ] **Step 3: Run the gate at 64 frames**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && ZR_GATE_FRAMES=64 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_daylight_gate_scene.tscn 2>&1 | grep -E "^  |^PASS|^FAIL|^gate sky|^===" | grep -v "^   at"
```

Expected: D0, D1, D2 within 3%. Interpretation if not:
- D0 off but D1 = D0 × E_sky → the multiplier is not reaching the tracer's radiance map (spec §5: engine fix in its own commit; stop and report).
- D0 and D1 fine, D2 reads `(1 + 5 cos45 · π)/π` or `(1 + 5 cos45 / π)/π` → the sun convention is not the one `SUN_ENERGY` assumes; report the measured ratio, do not adjust `SUN_TO_SKY`, stop and ask. (2026-09-19: the first run with `light_energy = 5.0` read exactly `1 + 5·cos45·π` — energy E is irradiance πE — which is why `SUN_ENERGY = SUN_TO_SKY / π` exists.)
- D2 reads `1/π` → the sun's -Z is not pointing at the card (or the card shadows itself): print `sun.global_basis.z` and fix the rotation sign.
- The card being lit from below by the ground half of the panorama is excluded by construction: the quad is single-sided and faces +Y.

- [ ] **Step 4: Run at the default frames and commit**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_daylight_gate_scene.tscn 2>&1 | grep -E "^  |^PASS|^FAIL" | grep -v "^   at"
```

Expected `PASS: all 4 daylight checks passed.` (the E_sky sanity check counts as one). Put the three measured values in the commit message.

```bash
git add pipeline_references/tests/pt_daylight_gate.gd pipeline_references/tests/pt_daylight_gate_scene.tscn
git commit -m "test(pt): daylight gate D0-D2 -- panorama normalised to unit irradiance, sun 5:1 (card x pi: D0 <v>, D1 <v>, D2 <v>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Gate D3/D6 — the probe's exposure and mask on the windowed room

**Files:**
- Modify: `pipeline_references/tests/pt_daylight_gate.gd`

**Interfaces:**
- Consumes: `Daylight.probe`, `Daylight.stats`, `Daylight.subsample`, `Daylight.MASK_RATIO`, `Daylight.TARGET_MEDIAN` (Task 1); the helpers from Task 2.
- Produces: `_room_scene(p_albedo, p_opening: String, p_camera: String, p_omni: bool) -> Environment` (builds and returns the env without rendering), used by Task 4.

- [ ] **Step 1: Add the room builder and D3/D6 to `_ready()`**

Add after the `_card_scene` function:

```gdscript
## The portal gate's room: x [-2,2], y [0,3], z [-1.5,1.5], six inward
## quads, opening in the x = -2 wall z [-0.6,0.6], y [0.9,1.9] (1.2 x 1.0 m).
## p_opening: "open" (the 1.2 x 1.0 window), "bricked" (no window).
## p_camera: "back" = (0,1.5,1.2) looking at (0,1.2,-1.5) as the portal gate;
##           "window" = (1.5,1.4,0) looking at (-2,1.4,0), the window centred.
## p_omni adds D5's corner lamp. Returns the Environment; render with
## _render_accum or Daylight.probe.
func _room_scene(p_albedo: float, p_opening: String, p_camera: String, p_omni: bool) -> Environment:
	await _clear()
	var mat := _lambert(p_albedo)
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 3.0), Vector3(-90.0, 0.0, 0.0), mat) # floor, faces +Y
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 3.0), Vector3(90.0, 0.0, 0.0), mat) # ceiling, faces -Y
	_quad(Vector3(0.0, 1.5, -1.5), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), mat) # back, faces +Z
	_quad(Vector3(0.0, 1.5, 1.5), Vector2(4.0, 3.0), Vector3(0.0, 180.0, 0.0), mat) # front, faces -Z
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(3.0, 3.0), Vector3(0.0, -90.0, 0.0), mat) # right, faces -X
	if p_opening == "bricked":
		_quad(Vector3(-2.0, 1.5, 0.0), Vector2(3.0, 3.0), Vector3(0.0, 90.0, 0.0), mat) # left, whole
	else:
		_quad(Vector3(-2.0, 0.45, 0.0), Vector2(3.0, 0.9), Vector3(0.0, 90.0, 0.0), mat) # below
		_quad(Vector3(-2.0, 2.45, 0.0), Vector2(3.0, 1.1), Vector3(0.0, 90.0, 0.0), mat) # above
		_quad(Vector3(-2.0, 1.4, -1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), mat) # z < -0.6
		_quad(Vector3(-2.0, 1.4, 1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), mat) # z > 0.6
	if p_omni:
		# D5's "fixture": one shadowed omni in the camera's corner so the far
		# corners are dark relative to the median by construction.
		var lamp := OmniLight3D.new()
		lamp.light_energy = 2.0
		lamp.omni_range = 6.0
		lamp.omni_attenuation = 1.0
		lamp.light_specular = 0.0
		lamp.shadow_enabled = true
		add_child(lamp)
		lamp.position = Vector3(1.6, 2.5, 1.2)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	add_child(cam)
	if p_camera == "window":
		cam.position = Vector3(1.5, 1.4, 0.0)
		cam.look_at(Vector3(-2.0, 1.4, 0.0), Vector3.UP)
	else:
		cam.position = Vector3(0.0, 1.5, 1.2)
		cam.look_at(Vector3(0.0, 1.2, -1.5), Vector3.UP)
	cam.make_current()
	var env := _new_env(_pano, 1.0 / Daylight.sky_irradiance(_pano))
	await get_tree().create_timer(1.0).timeout
	return env


## Mean-RGB luminance samples of a full image at PROBE_STEP, for the same
## statistics the probe takes.
func _samples(p_img: Image) -> PackedFloat32Array:
	return Daylight.subsample(p_img, Daylight.PROBE_STEP)
```

In `_ready()`, before the final `print("")`, add:

```gdscript
	print("\n=== D3: probe exposure on the windowed room, checked on a %d-frame still ===" % FRAMES_HI)
	var env3 := await _room_scene(ALBEDO, "open", "back", false)
	var pr := await Daylight.probe(self, env3, get_viewport().get_viewport_rid())
	var st := Daylight.stats(pr["samples"])
	print("  probe: raw median %.5f occupied %.1f%% median %.5f p25 %.5f exposure %.3f%s" % [
			st["raw_median"], 100.0 * st["occupied_fraction"], st["median"], st["p25"], st["exposure"],
			" (CLAMPED)" if st["clamped"] else ""])
	_check_true("D3 probe not clamped", not st["clamped"])
	var still3 := await _render_accum(env3, get_viewport().get_viewport_rid(), FRAMES_HI)
	var st_hi := Daylight.stats(_samples(still3))
	_check("D3 still occupied median x e", st_hi["median"] * st["exposure"], Daylight.TARGET_MEDIAN, TOL_EXPOSURE)

	print("\n=== D6: mask, camera facing the window ===")
	var env6 := await _room_scene(ALBEDO, "open", "window", false)
	var still6 := await _render_accum(env6, get_viewport().get_viewport_rid(), FRAMES_HI)
	var st6 := Daylight.stats(_samples(still6))
	# The window is a 1.2 x 1.0 m rectangle 3.5 m from the camera, on axis,
	# facing it: projected height 1.0 / (2 * 3.5 * tan 30) of the frame, width
	# 1.2 / (2 * 3.5 * tan 30) of a square frame.
	var half_extent := 3.5 * tan(deg_to_rad(30.0))
	var window_fraction := (1.0 / (2.0 * half_extent)) * (1.2 / (2.0 * half_extent))
	_check("D6 excluded fraction vs window area", 1.0 - st6["occupied_fraction"], window_fraction, TOL_MASK)
```

- [ ] **Step 2: Run at 64 frames**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && ZR_GATE_FRAMES=64 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_daylight_gate_scene.tscn 2>&1 | grep -E "^  |^PASS|^FAIL|^===" | grep -v "^   at"
```

Expected: D3 within 5% (a 16-frame median against a 64-frame one on a smooth wall), D6 within 20% of ≈ 0.0734. If D6's excluded fraction is ~0, the sky through the window is not 8× the wall — print `st6["raw_median"]` and the crop mean at the frame centre; the sky here is normalised to E = 1 (radiance ≈ 0.3) against a wall ≈ 0.08·0.8, so the ratio is only ≈ 4.5 and the mask threshold must be tested at a physical level instead: multiply the panorama for D6 by 20 (`_new_env(_pano, 20.0 / E_sky)`), which is what a real sky through a real window looks like (spec: 50–100 ×). Record which was needed in the gate's header.

- [ ] **Step 3: Run at the default frames, commit**

```bash
git add pipeline_references/tests/pt_daylight_gate.gd
git commit -m "test(pt): daylight gate D3/D6 -- probe exposure lands the still's occupied median on 0.18; window mask matches the projected area

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Gate D4/D5 — the fill decision, measured

**Files:**
- Modify: `pipeline_references/tests/pt_daylight_gate.gd`

**Interfaces:**
- Consumes: `Daylight.solve_fill`, `Daylight.FLOOR`, `Daylight.stats` (Task 1); `_room_scene` (Task 3).
- Adds the constant `const D5_FILL_ENERGY := 0.5` next to the other tolerances. `ALBEDO_DARK` is no longer used by any probe: delete it, and do not add `p_omni`/`p_partition` fixtures (measured 2026-09-19: a single lamp in the closed box gives p25/median ≈ 0.73–0.80, with or without a partition — the trigger cannot be staged in this room; the decision is unit-tested F1–F3).
- Produces: `_add_fill(p_energy: float) -> AreaLight3D` — the same placement rule `render.gd` will use in Task 6 (centroid, ceiling − 0.3, 0.6 × extent, down, shadows off, normalised).

- [ ] **Step 1: Add the fill builder and D4/D5**

After `_samples()`:

```gdscript
## The DaylightFill as the pipeline places it: room centroid, 0.3 m below the
## ceiling, 0.6 x the room's extent, facing down, no shadows, normalised.
## Room here is the gate's 4 x 3 x 3 m box.
func _add_fill(p_energy: float) -> AreaLight3D:
	var fill := AreaLight3D.new()
	fill.name = "DaylightFill"
	fill.area_size = Vector2(4.0 * 0.6, 3.0 * 0.6)
	fill.area_normalize_energy = true
	fill.light_energy = p_energy
	fill.light_color = Color(1.0, 1.0, 1.0)
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.set_param(Light3D.PARAM_RANGE, 2.0 * sqrt(4.0 * 4.0 + 3.0 * 3.0) + 4.0)
	fill.set_param(Light3D.PARAM_ATTENUATION, 1.0)
	add_child(fill)
	fill.position = Vector3(0.0, 3.0 - 0.3, 0.0)
	fill.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # -Z points down
	return fill
```

In `_ready()`, after D6:

```gdscript
	print("\n=== D4: no fill when the daylight reaches ===")
	var env4 := await _room_scene(ALBEDO, "open", "back", false)
	var pr4 := await Daylight.probe(self, env4, get_viewport().get_viewport_rid())
	var fill4 := _add_fill(1.0)
	var pr4b := await Daylight.probe(self, env4, get_viewport().get_viewport_rid())
	fill4.queue_free()
	var sol4 := Daylight.solve_fill(pr4["samples"], pr4b["samples"])
	print("  p25 x e = %.4f (floor %.3f); solver needed=%s" % [sol4["p25"] * sol4["exposure"], Daylight.FLOOR, str(sol4["needed"])])
	_check_true("D4 windowed room needs no fill", not sol4["needed"], "(p25 x e = %.4f)" % (sol4["p25"] * sol4["exposure"]))

	print("\n=== D5: fill model -- rendered fill at energy %.2f vs the per-pixel linear model ===" % D5_FILL_ENERGY)
	# Same room and probes as D4 (pr4 = no fill, pr4b = fill at 1.0). The solver's
	# decision is unit-tested on synthetic samples (daylight_unit.gd F1-F3); what
	# only a render can test is the physics it relies on: per-pixel linearity in
	# the fill's energy, the placement rule, area_normalize_energy. (A closed
	# diffuse box lit by one lamp never reaches the trigger's p25/median < 0.11 --
	# bounces homogenise it to ~0.7-0.8, partition or not -- so the trigger is not
	# staged here.)
	var model := PackedFloat32Array()
	var s0: PackedFloat32Array = pr4["samples"]
	var s1: PackedFloat32Array = pr4b["samples"]
	model.resize(mini(s0.size(), s1.size()))
	for k in range(model.size()):
		model[k] = s0[k] + D5_FILL_ENERGY * (s1[k] - s0[k])
	var st_model := Daylight.stats(model)
	var st_none := Daylight.stats(s0)
	print("  model at %.2f: median %.5f p25 %.5f (no fill: median %.5f)" % [D5_FILL_ENERGY, st_model["median"], st_model["p25"], st_none["median"]])
	_check_true("D5 premise: the fill contributes >= 20%% of the median", st_model["median"] >= 1.2 * st_none["median"],
			"(%.3fx)" % (st_model["median"] / maxf(st_none["median"], 1e-9)))
	var fill5 := _add_fill(D5_FILL_ENERGY)
	var still5 := await _render_accum(env4, get_viewport().get_viewport_rid(), FRAMES_HI)
	var st5r := Daylight.stats(_samples(still5))
	print("  rendered: median %.5f p25 %.5f" % [st5r["median"], st5r["p25"]])
	_check("D5 rendered median vs model", st5r["median"], st_model["median"], TOL_EXPOSURE)
	_check("D5 rendered p25 vs model", st5r["p25"], st_model["p25"], TOL_FLOOR)
	fill5.queue_free()
```

- [ ] **Step 2: Run at 64 frames**

Same command as Task 3 Step 2. Expected: D4 no fill; D5 premise holds (a 0.5-energy fill in the windowed room adds well over 20% to the median — if not, raise `D5_FILL_ENERGY`, it is a fixture constant, and say so), rendered median within 5% and p25 within 10% of the model. If the rendered values miss, the per-pixel linearity assumption broke: a rect light with `area_normalize_energy` is linear in energy, so look for the probe reading a stale buffer (the settle frames) first, then for `_add_fill` placing the light somewhere the 16-frame probe undersamples.

- [ ] **Step 3: Default frames, commit**

```bash
git add pipeline_references/tests/pt_daylight_gate.gd
git commit -m "test(pt): daylight gate D4/D5 -- no fill on the lit room; a rendered fill matches the per-pixel linear model the solver relies on

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `image_glb_creation.gd` — sky normalisation, sun 5.0, rig removal, JSON log line

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd` — the sky block (~line 782–795), the sun block (~718–722 and ~749–752), the day exposure/ambient block (~855–915), the AgX multipliers (~922–928), the exposure trim (~946–950), the `_create_window_portal_lights()` call (~503) and function (~2823), the "Scene Fill Lights" block (~1382–1430), the JSON reads (~611–628).

**Interfaces:**
- Consumes: `Daylight.sky_irradiance`, `Daylight.SUN_ENERGY`, `Daylight.SUN_TO_SKY`.
- Produces: on day renders the Environment has `tonemap_exposure = 1.0` (the probe sets it), the sky's `energy_multiplier = 1 / E_sky`, the sun at `SUN_ENERGY` (5/π); no `FillLight`/`FrontFillLight`/`BackFillLight`, no `[PortalSpot]`.

Line numbers are from the 2026-09-19 file; find each block by its comment text, not the number.

- [ ] **Step 1: Sky normalisation**

In the sky block, after `exr_image.generate_mipmaps()` and before `var sky_tex := ...`, the panorama material gets the multiplier. Replace:

```gdscript
			var panorama_mat = PanoramaSkyMaterial.new()
			panorama_mat.panorama = sky_tex
			panorama_mat.filter = true
```

with:

```gdscript
			var panorama_mat = PanoramaSkyMaterial.new()
			panorama_mat.panorama = sky_tex
			panorama_mat.filter = true
			if day_render:
				# Daylight design (spec 2026-09-19): the panorama is normalised so a
				# horizontal surface receives irradiance exactly 1 from the sky,
				# whatever file was loaded (day.exr is an LDR panorama clipped at
				# 1.0 with E_sky = 1.62). The sun is then Daylight.SUN_TO_SKY in
				# the same units. Night keeps the panorama as authored.
				var e_sky = Daylight.sky_irradiance(exr_image)
				if e_sky > 1e-6:
					panorama_mat.energy_multiplier = 1.0 / e_sky
				print("[Daylight] sky irradiance %.4f -> energy_multiplier %.4f" % [e_sky, panorama_mat.energy_multiplier])
```

`exr_image` must still hold the full image at this point (it does: `generate_mipmaps()` is in place; `sky_irradiance` duplicates before resizing).

- [ ] **Step 2: The sun**

Replace the day branch of the energy block:

```gdscript
	if day_render:
		# 6.0 gives physically realistic PT sunlight — the path tracer needs high
		# directional energy to bounce enough photons off walls/floor and fill the interior.
		# Without portal lights, this is the sole light source driving GI bounces.
		dir_energy = 1.0
		dir_color = Color(1.0, 1.0, 1.0) # Color(1.0, 0.835, 0.50) 10AM sunlight — warm golden white
		print("[Sun] Day render: 10AM sunlight energy=6.0, blur=1.2, angular=0.8 (soft shadows).")
```

with:

```gdscript
	if day_render:
		# Daylight design (spec 2026-09-19): the sky is normalised to unit
		# horizontal irradiance above; the sun is SUN_TO_SKY (5, a 10 AM clear
		# sky: ~90 klux direct-normal vs ~18 klux diffuse) times that, and a
		# DirectionalLight3D of energy E is irradiance pi*E in the tracer, so
		# light_energy = 5 / pi. The exposure is measured per job by the probe
		# in render.gd, so the absolute level here is not a brightness knob;
		# the ratio is the look.
		dir_energy = Daylight.SUN_ENERGY # = SUN_TO_SKY / pi: energy E is irradiance pi*E in the tracer
		dir_color = Color(1.0, 1.0, 1.0) # Color(1.0, 0.835, 0.50) 10AM sunlight — warm golden white
		print("[Sun] Day render: light_energy=%.4f (sun : sky irradiance %.1f), blur=1.2, angular=0.8 (soft shadows)." % [dir_energy, Daylight.SUN_TO_SKY])
```

And in the application block replace `dir_light.light_energy = dir_energy * _auto_sun_multiplier # automation scales for dark/light surfaces` with `dir_light.light_energy = dir_energy`. Check the `blur=1.2, angular=0.8` claims against the lines that set `shadow_blur` / `light_angular_distance` on `dir_light` (grep `dir_light.shadow_blur`); print the live values instead of literals if they differ.

- [ ] **Step 3: The day exposure / ambient block**

Replace, in the `if day_render:` exposure block, everything from `env.tonemap_exposure = 1.3` through the `print("[Lighting] Day PT: exposure=", ...)` line (the 1.3 base, the `_auto_ambient_boost > 1.0` compensation, the long ambient comment, `_illum_ambient_factor`, `env.ambient_light_energy = 10.0 * ...`, its print, `env.ambient_light_color`, the "Printed from the live values" print) with:

```gdscript
		# Daylight design (spec 2026-09-19): exposure is MEASURED per job by
		# Daylight.probe() in render.gd (occupied median -> 0.18) and set there;
		# 1.0 here is a placeholder the probe overwrites. ambient_light_energy is
		# not read by the path tracer (nothing in render_raytracing.cpp reads
		# it) -- the "sky ambient energy" this block used to print was a no-op.
		env.tonemap_exposure = 1.0
		env.ambient_light_color = Color(1.0, 1.0, 1.0)
		print("[Daylight] JSON lighting fields ambientBoost/illuminationLevel/exposureScale/sunEnergyMultiplier are not used on day renders (probe-exposed daylight); fixture adjustments are.")
```

Keep the `if not day_render:` branch that follows untouched.

- [ ] **Step 4: AgX multipliers and the exposure trim, day only**

Change:

```gdscript
	if env.tonemap_mode == Environment.TONE_MAPPER_AGX:
		env.tonemap_white = lighting.get("tonemap_agx_white", lighting["tonemap_white"])
		# AGX contrast is applied via exposure adjustment (baked into exposure).
		env.tonemap_exposure *= lighting.get("tonemap_agx_contrast", 1.0)
		# Warm mood: slightly boost AGX exposure for richer shadows
		if mood_key == "warm":
			env.tonemap_exposure *= 1.08
```

to:

```gdscript
	if env.tonemap_mode == Environment.TONE_MAPPER_AGX:
		env.tonemap_white = lighting.get("tonemap_agx_white", lighting["tonemap_white"])
		# Day: the probe owns the exposure (spec 2026-09-19); a multiplier after
		# it would move the median off 0.18. Night keeps the profile's contrast
		# and warm-mood terms.
		if not day_render:
			# AGX contrast is applied via exposure adjustment (baked into exposure).
			env.tonemap_exposure *= lighting.get("tonemap_agx_contrast", 1.0)
			# Warm mood: slightly boost AGX exposure for richer shadows
			if mood_key == "warm":
				env.tonemap_exposure *= 1.08
```

and guard the trim: `if not day_render and (_auto_exposure_scale < 0.999 or _auto_exposure_scale > 1.001):`.

- [ ] **Step 5: Portal spots, scene fill lights, JSON reads**

- Delete the line `_create_window_portal_lights()` in `build_scene`'s `if day_render:` block (leave `_create_window_portals()`), and delete `func _create_window_portal_lights()` whole (it has no other caller in this file — `grep -n _create_window_portal_lights pipeline_references/image_glb_creation.gd` must return only comment lines afterwards; update the comment at "WHY IT EXISTS: _create_window_portal_lights() is disabled" to say the spots were removed by the daylight design, and the one in `_create_window_portals`'s header).
- The "Scene Fill Lights" block (`if lighting_profile == "day" or lighting_profile == "sunset":` — `FillLight`, `FrontFillLight`, `BackFillLight`) only ever runs on day renders, so **delete the block** (from `# ── Scene Fill Lights` through `add_child(fill_back)`) and leave a two-line comment in its place: `# Daylight design (spec 2026-09-19): no omni fills on day renders; render.gd adds one measured DaylightFill when the probe finds the darkest quarter under the floor.`
- JSON reads: keep `_auto_ambient_boost` and `_auto_exposure_scale` (night uses them); delete `_auto_sun_multiplier` and its read (`_automationSunMultiplier`) and its print; the `[AUTO-LIGHTING] ambientBoost=` print stays for night only: wrap it in `if not day_render:`.

- [ ] **Step 6: Render job 226 once and read the log**

The scratch copy of the live project used for job 226 is `C:\Users\aiadmin\AppData\Local\Temp\claude\C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine\b37a70cf-2a76-48f2-b7de-63b1ab2399c1\scratchpad\proj_225` (`day.exr`, `input_json/f2_226_input.json`). Copy the edited `image_glb_creation.gd`, `daylight.gd` and `render.gd` (unchanged yet) into it, then:

```bash
S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; cp pipeline_references/image_glb_creation.gd pipeline_references/daylight.gd pipeline_references/render.gd "$S/proj_225/" && ZR_PT_ACCUM_TARGET=16 ZR_PT_FINAL=none bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" main.tscn "$S/proj_225/input_json/f2_226_input.json" "$S/t5_226.png" > "$S/t5_226_godot.log" 2>&1; echo exit=$?; grep -n "\[Daylight\]\|\[Sun\]\|PortalSpot\|FillLight\|Fill grid\|AUTO-LIGHTING\|sky ambient\|Placed .* light" "$S/t5_226_godot.log" | cut -c1-160
```

Expected: `[Daylight] sky irradiance 1.62xx -> energy_multiplier 0.61xx`, `[Sun] Day render: light_energy=1.5915 (sun : sky irradiance 5.0) ...`, the JSON-fields line, `Placed 23 room light(s)`; **no** `[PortalSpot]`, no `AUTO-LIGHTING`, no `sky ambient`. `Fill grid at 1.25x` still prints (render.gd is Task 6). exit 0.

- [ ] **Step 7: Commit**

```bash
git add pipeline_references/image_glb_creation.gd
git commit -m "feat(pipeline): daylight layer 1 -- panorama normalised to unit irradiance, sun 5:1, portal spots and scene fills removed, LLM lighting fields ignored on day renders

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `render.gd` — no fill grid on day renders; probe → exposure → fill → still

**Files:**
- Modify: `pipeline_references/render.gd` — `render_image()` around `setup_fixed_fill_lights()` (~line 463) and the day `accumulate_enabled` branch (~469–484).

**Interfaces:**
- Consumes: `Daylight.probe`, `Daylight.stats`, `Daylight.solve_fill`, `Daylight.reset_accumulator`, `Daylight.FLOOR`, `Daylight.TARGET_MEDIAN`; `_resolve_active_area_polygon()`, `_extract_room_lighting_bounds()`, `_get_world_environment()`, `_wait_frames()` (existing, `image_glb_creation.gd` / `render.gd`).
- Produces: `_daylight_probe_and_expose(env: Environment) -> void` (coroutine) and `_place_daylight_fill(p_energy: float) -> AreaLight3D`.

- [ ] **Step 1: Skip the fill grid on day renders**

Replace:

```gdscript
	if cam:
		setup_fixed_fill_lights()
		_apply_no_authored_light_boost()
```

with:

```gdscript
	if cam:
		if day_render:
			# Daylight design (spec 2026-09-19): no omni fill grid on day renders.
			# The room is sun + normalised sky + fixtures + portals; if the probe
			# below finds the darkest occupied quarter under the floor, ONE
			# measured DaylightFill is added. Night keeps its grid.
			print("[Daylight] fill grid skipped on day render (probe-exposed daylight).")
		else:
			setup_fixed_fill_lights()
		_apply_no_authored_light_boost()
```

- [ ] **Step 2: The probe before the day accumulation**

In the `if day_render:` branch, replace:

```gdscript
			if _dir_light:
				# Sun energy is calibrated at 2.8 — no boost needed.
				# Previous 1.30x and 1.10x boosts were causing floor blowout.
				print("[Render] Day render: sun energy is calibrated (no boost applied).")
			if accumulate_enabled:
```

with:

```gdscript
			if accumulate_enabled:
				await _daylight_probe_and_expose(env.environment)
```

(The three-line sun print goes: the sun is set in `setup_lighting` and printed there.)

- [ ] **Step 3: Add the two functions**

After `_get_world_environment()`:

```gdscript
## Daylight design (spec 2026-09-19, sections 2-3). Measures the job's own
## frame and sets the exposure; adds one DaylightFill if the darkest occupied
## quarter is still under the floor. Leaves the accumulator reset so the
## still that follows starts from a cleared buffer.
func _daylight_probe_and_expose(p_env: Environment) -> void:
	var vp := get_viewport().get_viewport_rid()
	p_env.tonemap_exposure = 1.0
	var t0 := Time.get_ticks_msec()
	var pr := await Daylight.probe(self, p_env, vp)
	if pr["samples"].is_empty():
		printerr("[Daylight] probe: accumulator readback returned nothing; exposure left at 1.0")
		await Daylight.reset_accumulator(self, p_env)
		return
	var st := Daylight.stats(pr["samples"])
	print("[Daylight] probe: median %.5f (occupied %.1f%%), exposure %.3f%s, p25 %.5f -> %.4f after exposure  [%d ms, %dx%d]" % [
			st["median"], 100.0 * st["occupied_fraction"], st["exposure"],
			" CLAMPED -- scene is not a lit interior" if st["clamped"] else "",
			st["p25"], st["p25"] * st["exposure"], Time.get_ticks_msec() - t0, pr["width"], pr["height"]])
	var exposure: float = st["exposure"]
	if st["p25"] * exposure < Daylight.FLOOR and not st["clamped"]:
		var fill := _place_daylight_fill(1.0)
		var pr1 := await Daylight.probe(self, p_env, vp)
		var sol := Daylight.solve_fill(pr["samples"], pr1["samples"])
		if sol["needed"]:
			fill.light_energy = sol["energy"]
			exposure = sol["exposure"]
			print("[Daylight] fill: p25 %.4f < %.3f after exposure -> DaylightFill at %s size %s energy %.4f%s; exposure %.3f -> %.3f" % [
					st["p25"] * st["exposure"], Daylight.FLOOR, str(fill.global_position), str(fill.area_size),
					sol["energy"], " (CAPPED at share %.2f)" % Daylight.FILL_SHARE_CAP if sol["capped"] else "",
					st["exposure"], exposure])
		else:
			fill.queue_free()
	p_env.tonemap_exposure = exposure
	await Daylight.reset_accumulator(self, p_env)


## The fallback fill: centroid of the camera's room (or the lighting bounds'
## centre), 0.3 m below its ceiling, 0.6 x the room's extent, facing down,
## no shadows, normalised energy. Same rule as pt_daylight_gate.gd _add_fill().
func _place_daylight_fill(p_energy: float) -> AreaLight3D:
	var bounds := _extract_room_lighting_bounds(_render_data.get("floor_plan_data", {}))
	var center: Vector3 = bounds["center"]
	var extent: Vector2 = bounds["extent"]
	var ceiling_y: float = bounds["ceiling_y"]
	var poly := _resolve_active_area_polygon()
	if poly.size() >= 3:
		var sum := Vector2.ZERO
		var mn := Vector2(1e9, 1e9)
		var mx := Vector2(-1e9, -1e9)
		for p in poly:
			sum += p
			mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
			mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
		var c := sum / float(poly.size())
		center = Vector3(c.x, center.y, c.y)
		extent = mx - mn
	var fill := AreaLight3D.new()
	fill.name = "DaylightFill"
	fill.area_size = extent * 0.6
	fill.area_normalize_energy = true
	fill.light_energy = p_energy
	fill.light_color = Color(1.0, 1.0, 1.0)
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.set_param(Light3D.PARAM_RANGE, 2.0 * extent.length() + 4.0)
	fill.set_param(Light3D.PARAM_ATTENUATION, 1.0)
	add_child(fill)
	fill.position = Vector3(center.x, ceiling_y - 0.3, center.z)
	fill.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # -Z points down
	return fill
```

Check `_extract_room_lighting_bounds`'s parameter: it takes `geom_data` (the floor plan dictionary `build_scene` passes to `setup_lighting`). Find what `setup_lighting(data, geom_data)` receives in `build_scene` and pass the same thing; if it is not reachable from `render.gd`, store it in a member in `setup_lighting` (`_daylight_geom_data = geom_data`) and use that. `_resolve_active_area_polygon()` returns metres (its comment says so) — check it against `_extract_room_lighting_bounds`'s `center` units before combining them.

- [ ] **Step 4: Render job 226 through the still route**

```bash
S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; cp pipeline_references/image_glb_creation.gd pipeline_references/daylight.gd pipeline_references/render.gd "$S/proj_225/" && ZR_PT_ACCUM_TARGET=64 ZR_PT_FINAL=none bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" main.tscn "$S/proj_225/input_json/f2_226_input.json" "$S/t6_226.png" > "$S/t6_226_godot.log" 2>&1; echo exit=$?; grep -n "\[Daylight\]\|Fill grid\|Accumulating\|Image saved" "$S/t6_226_godot.log" | cut -c1-200
```

Expected: `[Daylight] fill grid skipped`, a `[Daylight] probe:` line with a non-clamped exposure, either no fill line (windows in view — expected) or one fill line, then `Accumulating 64 frames`. Open `t6_226.png`: a room, not black, not white. If the probe's `occupied` is < 50%, the mask is swallowing the room — print `raw_median` and check that the 8× cut is against the raw median, not the occupied one.

- [ ] **Step 5: Commit**

```bash
git add pipeline_references/render.gd
git commit -m "feat(pipeline): daylight probe on the still route -- occupied median to 0.18, one measured DaylightFill when the darkest quarter is under 0.02; no fill grid on day renders

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Night byte-identity and the gate suite

**Files:** none modified; evidence only.

- [ ] **Step 1: Measure the night repeat floor on this build, then before/after**

Pick a night job from the live folder: `python -c "import json,glob,os; L=r'C:\Zlendo2026\ZlenderRender_stage_copy\godot_project\input_json'; print([os.path.basename(p) for p in sorted(glob.glob(L+r'\*.json'), key=os.path.getmtime) if 'night' in open(p,encoding='utf-8-sig').read()[:400000] and not json.load(open(p,encoding='utf-8-sig')).get('day_render', True)][-3:])"`. Copy its JSON into `proj_225/input_json/night_ref_input.json`. Render it **twice** with the pre-plan pipeline files (`git stash` is not needed: `git show a9de51bc3d:pipeline_references/render.gd > "$S/proj_225/render.gd"` and the same for `image_glb_creation.gd`; `daylight.gd` may stay), 16 frames, `ZR_PT_EXR=1`, and `cmp` the two EXRs → the repeat floor (memory: it was md5-identical on the 2026-09-11 build). Then render once with the plan's files and `cmp` against the first. Expected: identical if the floor is identical; otherwise the same max-abs-diff as the floor (use `portal/compare_pfm.py` after `exr2pfm.py`). Record the three results.

- [ ] **Step 2: The suite**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; mkdir -p "$S/suite7"; for t in pipeline_references/tests/*_gate_scene.tscn; do n=$(basename "$t" _scene.tscn); bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references "res://tests/${n}_scene.tscn" > "$S/suite7/$n.log" 2>&1; echo "$n exit=$? :: $(grep -E '^PASS|^FAIL:|gate PASSED|gate FAILED' "$S/suite7/$n.log" | tail -1)"; done
```

Run it detached if the tool's timeout is a concern (this session used a `Start-Process bash.exe run_suite.sh` runner writing `summary.txt`). Expected: 23 lines, every one PASS (`png16_encoding_gate` prints `=== png16 encoding gate PASSED (13 checks) ===`). Also the unit script from Task 1.

No commit; the numbers go into Task 9's spec section.

---

### Task 8: `tools/daylight_validation.py` and the four jobs

**Files:**
- Create: `tools/daylight_validation.py`
- Scratch: `proj_225/input_json/<job>_input.json` for the four jobs; renders in the scratchpad.

**Interfaces:**
- Consumes: the linear EXR the still route writes with `ZR_PT_EXR=1`, converted to PFM by `scratchpad/portal/exr2pfm.py` (Blender); the job's Godot log for the exposure.
- Produces: one report block per job.

- [ ] **Step 1: Write the script**

`tools/daylight_validation.py`:

```python
"""Daylight design validation (spec 2026-09-19-daylight-design.md, "The four jobs").

    python tools/daylight_validation.py <job>.pfm <job>_godot.log [--wall y0 y1 x0 x1]

The PFM is the LINEAR accumulation buffer (before exposure and tone curve),
converted from the still route's EXR. The exposure is read from the log's
"[Daylight] probe:" / "[Daylight] fill:" lines, so the numbers below are
what the tone curve received:

  occupied median x e            must be in [0.15, 0.35]
  min over 4x4 tiles of the occupied tile-mean x e   must be >= 0.02
  window pixels with L x e > 1.0                     <= 2% of the window
  wall grain (5x5 residual RMS / mean on the wall crop, fractions of the
  frame, default the central 20% x 20%)               <= 10%

"Occupied" and "window" use the probe's own rule: window = pixels above 8x
the raw median.
"""
import re
import sys

import numpy as np

MASK_RATIO = 8.0


def read_pfm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() == b"PF"
        w, h = map(int, f.readline().split())
        scale = float(f.readline())
        data = np.frombuffer(f.read(), dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return data[::-1].astype(np.float64)


def exposure_from_log(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    fill = re.findall(r"\[Daylight\] fill:.*exposure ([0-9.]+) -> ([0-9.]+)", text)
    if fill:
        return float(fill[-1][1]), True
    probe = re.findall(r"\[Daylight\] probe: .*exposure ([0-9.]+)", text)
    if not probe:
        raise SystemExit("no [Daylight] probe line in %s" % path)
    return float(probe[-1]), False


def box(x, k):
    p = np.pad(x, k // 2, mode="edge")
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    H, W = x.shape
    return (c[k:k + H, k:k + W] - c[0:H, k:k + W] - c[k:k + H, 0:W] + c[0:H, 0:W]) / (k * k)


def main():
    args = sys.argv[1:]
    wall = [0.40, 0.60, 0.40, 0.60]
    if "--wall" in args:
        i = args.index("--wall")
        wall = [float(v) for v in args[i + 1:i + 5]]
        del args[i:i + 5]
    pfm, log = args[:2]
    img = read_pfm(pfm)
    lum = img.mean(axis=2)
    e, had_fill = exposure_from_log(log)
    raw_median = np.median(lum)
    window = lum > MASK_RATIO * raw_median
    occupied = ~window
    med = np.median(lum[occupied]) * e
    h, w = lum.shape
    tile_min = 1e9
    for j in range(4):
        for i in range(4):
            sl = (slice(j * h // 4, (j + 1) * h // 4), slice(i * w // 4, (i + 1) * w // 4))
            occ = occupied[sl]
            if occ.mean() < 0.5:
                continue  # a tile that is mostly window is not "occupied"
            tile_min = min(tile_min, lum[sl][occ].mean() * e)
    clipped = (lum[window] * e > 1.0).mean() if window.any() else 0.0
    ys, ye, xs, xe = int(h * wall[0]), int(h * wall[1]), int(w * wall[2]), int(w * wall[3])
    crop = lum[ys:ye, xs:xe]
    grain = np.sqrt(((crop - box(crop, 5)) ** 2).mean()) / max(crop.mean(), 1e-9)
    ok = lambda c: "ok " if c else "RED"
    print("%s  exposure %.3f%s  window %.1f%% of frame" % (pfm, e, " (with DaylightFill)" if had_fill else "", 100 * window.mean()))
    print("  %s occupied median x e   %.4f   [0.15, 0.35]" % (ok(0.15 <= med <= 0.35), med))
    print("  %s darkest occupied tile %.4f   >= 0.02" % (ok(tile_min >= 0.02), tile_min))
    print("  %s window clipped        %.2f%%  <= 2%%" % (ok(clipped <= 0.02), 100 * clipped))
    print("  %s wall grain            %.2f%%  <= 10%%  (crop rows %.2f-%.2f cols %.2f-%.2f)" % (ok(grain <= 0.10), 100 * grain, *wall))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Stage the four jobs**

Copy the live JSONs into the scratch project (`urbantestdark226_fish` is already `f2_226_input.json`):

```bash
S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; L="/c/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json"; for j in urbantestdark225_fish urbantestdark176_llm urbantestdark157_fillLight1.3; do cp "$L/${j}_render_input.json" "$S/proj_225/input_json/dl_${j}_input.json"; done; ls "$S/proj_225/input_json" | grep dl_
```

- [ ] **Step 3: Render the four at FHD, 256 frames, OIDN, EXR on; convert; measure**

```bash
cd "C:/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine" && S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"; B="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"; for pair in "dl_226:f2_226_input.json" "dl_225:dl_urbantestdark225_fish_input.json" "dl_176:dl_urbantestdark176_llm_input.json" "dl_157:dl_urbantestdark157_fillLight1.3_input.json"; do n=${pair%%:*}; j=${pair##*:}; ZR_PT_EXR=1 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" main.tscn "$S/proj_225/input_json/$j" "$S/$n.png" > "$S/${n}_godot.log" 2>&1; echo "$n exit=$?"; grep -n "\[Daylight\]" "$S/${n}_godot.log" | cut -c1-200; "$B" -b --python "$S/portal/exr2pfm.py" -- "$S/$n.exr" "$S/$n.pfm" 2>&1 | grep -i "wrote\|error"; python tools/daylight_validation.py "$S/$n.pfm" "$S/${n}_godot.log"; done
```

Run detached (≈ 4 × 3 min at FHD plus loads). `render_quality` in the JSON drives the resolution; if a job is 4K, set it to FHD in the scratch copy (spec: FHD). If a job's assets fail to load (`Loaded hole asset` errors, `Failed to load GLB`), take the next most recent job in its class from the scan (`scratchpad/daylight/scan_jobs.py`) and note the substitution.

- [ ] **Step 4: Look at the four PNGs and the wall crop**

Read each PNG. The wall crop default (central 20%) must land on a flat wall; if it lands on furniture or a window, pass `--wall` with a crop that is wall and record the crop in the report. Compare `dl_226.png` side by side with the Blender reference dining still — **ask the user for its path** (it is not in the repo or the live folder's `output_renders`); if they cannot supply it, record "reference not available" rather than substituting another image.

- [ ] **Step 5: Commit the script**

```bash
git add tools/daylight_validation.py
git commit -m "tools(pt): daylight_validation.py -- occupied median, darkest tile, window clipping and wall grain from a job's linear EXR

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Record the results; close §11.27

**Files:**
- Modify: `docs/superpowers/specs/2026-09-19-daylight-design.md` — add `## Measured (2026-09-xx)` before "Out of scope".
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` — the Gap #31 row in the table (line ~127: `**OPEN — spec in §11.27, parked 2026-09-16.**` → `**DONE 2026-09-xx — spec 2026-09-19-daylight-design.md.**`) and a closeout paragraph at the end of §11.27.

- [ ] **Step 1: Write the Measured section**

Template — every value from Tasks 2–4 (gate), 7 (night, suite) and 8 (four jobs), red or green as measured:

```markdown
## Measured (2026-09-xx)

Gate `pt_daylight_gate` (256 frames): D0 <v> vs E_sky <v>; D1 <v>; D2 <v> vs <expected>;
D3 <v>; D4 p25·e <v>; D5 energy <v> exposure <v> → median·e <v>, p25·e <v>; D6 <v> vs <v>.
Unit checks: <n>/<n>. Suite 23/23. Night job <id>: repeat floor <identical | max diff>, before/after <identical | max diff>.

| job | class | exposure | fill | occupied median·e | darkest tile | window clipped | wall grain |
|---|---|---|---|---|---|---|---|
| 226 | in view | | | | | | |
| 225 | behind | | | | | | |
| 176 | deep | | | | | | |
| 157 | windowless | | | | | | |

Blender reference (job 226): <side-by-side note, or "reference not available">.
Probe cost: <ms> at FHD (one probe), <ms> with the fill probe.
```

- [ ] **Step 2: Roadmap closeout**

At the end of §11.27, after "Engine dependencies", add:

```markdown
### Closed 2026-09-xx

Spec `docs/superpowers/specs/2026-09-19-daylight-design.md`, plan
`docs/superpowers/plans/2026-09-19-daylight-design.md`. `day.exr` turned out
to be an LDR panorama (max 1.0, E_sky 1.62); it is normalised to unit
horizontal irradiance at load and the sun is 5× that. Exposure is a
16-frame probe of the job's own frame (occupied median → 0.18); one measured
`DaylightFill` when the darkest occupied quarter is under 0.02. Fill grid,
portal spots, scene fills and the LLM lighting multipliers are gone from day
renders. Numbers: spec "Measured". Video route unchanged (follow-up).
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-19-daylight-design.md PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): daylight design measured -- gate D0-D6, suite 23/23, four jobs; Gap #31 closed

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review (done while writing)

- **Spec coverage.** §1 → Task 5 Steps 1–2 (+ gate D0–D2, Task 2). §2 → Task 1 (`stats`, `probe`), Task 6 Step 2–3, gate D3/D6 (Task 3). §3 → Task 1 (`solve_fill`), Task 6 Step 3 (`_place_daylight_fill`), gate D4/D5 (Task 4). §4 → Task 5 Steps 3–5, Task 6 Step 1. §5 → nothing to do. Gate table → Tasks 2–4. Four jobs → Task 8. Night identity + suite → Task 7. Measured section + roadmap → Task 9.
- **Deviations from the spec, on record.** (1) D5 is the fill *model* test (rendered fill at 0.5 vs the per-pixel linear prediction), not a staged dark room: the spec's first fixture was degenerate and no single-lamp box reaches the trigger (spec, gate table note); the decision logic is unit-tested F1–F3. (2) D6 may need the panorama at 20× to put the window above 8× the wall (the gate's normalised sky is only ≈ 4.5× a 0.8 wall); Task 3 says when and records it. (3) The `[Sun] blur=1.2, angular=0.8` literals are printed from the live values if they differ.
- **Placeholders.** `2026-09-xx` in Task 9 is the date of the run, filled in at execution; `<v>` in the Measured template are the measured values — both are execution-time inputs, not design gaps. No "TBD"/"handle edge cases".
- **Type consistency.** `Daylight.probe` returns `{samples: PackedFloat32Array, width, height}`; `stats` and `solve_fill` take `PackedFloat32Array`; `solve_fill` returns `{needed, energy, exposure, median, p25, capped}` — used with those keys in Tasks 4, 6. `_room_scene` returns `Environment`; `_add_fill`/`_place_daylight_fill` return `AreaLight3D`. `reset_accumulator(p_node, p_env)` used in Task 6 as defined in Task 1.
