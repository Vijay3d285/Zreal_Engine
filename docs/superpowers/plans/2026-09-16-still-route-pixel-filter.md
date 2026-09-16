# Still Route + Pixel Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stills come out of the Cycles-style route (accumulate 256 samples through a 1.5 px Blackman-Harris pixel filter, OIDN final) instead of DLSS-RR + NIS sharpen, so a 4K still zooms like Blender's.

**Architecture:** Three independent changes — a pipeline route flip in the user's `image_glb_creation.gd` (reference copy), one engine constant in `raytracing_inc.glsl` widening the existing filter from ±1.0 to ±1.5 px, and `fsr_sharpness = 0` in `render.gd`. A new gate measures the filter's edge-spread function with a slanted edge and is red on today's build.

**Tech Stack:** GLSL (raygen include), GDScript gates under `pipeline_references/tests/`, SCons build, Python/PIL for image measurement.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-16-still-route-pixel-filter-design.md`.
- `pipeline_references/*.gd` directly under that directory are the user's files: edit as reference copies, **never `git add`, stash, or checkout them**. Files under `pipeline_references/tests/` may be committed.
- `git add` with explicit paths only.
- Build: `python -m SCons platform=windows target=editor tests=yes -j8`. A clean build proves nothing about GLSL; run the gate.
- Gate paths carry `.tscn`: `res://tests/<name>_scene.tscn`.
- Render outputs go to the scratchpad, never into the live project.
- Every commit ends with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Filter constant: `RT_PIXEL_FILTER_WIDTH = 1.5` (Cycles `properties.py` default 1.5, `film.cpp` ×2). Analytic 10–90% edge ramp: **0.721 px at 1.0, 1.081 px at 1.5**.
- Route constants: `PHASE_A_OFFLINE_STILL := true`, `PHASE_A_ACCUM_TARGET := 256`, `PHASE_A_FINAL := "oidn"`, clamp/noise stay 0. Route select becomes `or`.

---

### Task 1: The pixel-filter gate (red on today's build)

**Files:**
- Create: `pipeline_references/tests/pt_pixel_filter_gate.gd`
- Create: `pipeline_references/tests/pt_pixel_filter_gate_scene.tscn`
- Modify: `docs/superpowers/specs/2026-09-16-still-route-pixel-filter-design.md` (gate section)

**Interfaces:**
- Consumes: `pt_validation.gd`'s `_render_accum(env, vp_rid, frames) -> Image` (accumulate route, resets the accumulator, returns the running mean as an Image).
- Produces: constants `F1_EXPECTED := 1.081`, `F1_TOL := 0.08`; Task 2 reads the gate's printed `F1 ramp` value.

Method (slanted edge): a black quad's right edge is tilted by `atan(1/128)` so it drifts exactly one pixel every 128 rows. For every pixel we know the signed distance `d` (in pixels) from its centre to the edge; sorting all pixels by `d` and binning at 0.05 px gives the continuous edge-spread function, which for filter importance sampling is exactly the filter's CDF. The 10–90% width of that curve is 0.721 px for the ±1.0 window and 1.081 px for the ±1.5 window.

- [ ] **Step 1: Write the gate**

`pipeline_references/tests/pt_pixel_filter_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Pixel-filter gate (spec 2026-09-16-still-route-pixel-filter-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_pixel_filter_gate_scene.tscn
##
## Measures the camera reconstruction filter's edge-spread function with a
## SLANTED edge: a black quad against a white sky, its right edge tilted by
## atan(1/128) so it drifts one pixel every 128 rows. Each pixel's signed
## distance to the edge is known from the geometry, so sorting every pixel
## by that distance sweeps out the continuous edge profile -- which, for
## filter importance sampling, IS the filter's CDF. An edge placed on a pixel
## centre cannot do this: both the 1.0 and 1.5 windows then read 0 / 0.5 / 1.
##
##   F1 ramp: 10-90% width of the profile. Blackman-Harris widened x2 to
##      +-1.5 px (Cycles' default filter_width 1.5) gives 1.081 px; the
##      +-1.0 window this gate was first run against gives 0.721.
##   F2 symmetry: |(d75 - d50) - (d50 - d25)| <= 0.05 px.
##   F3 energy: image mean == white area fraction (0.5, the edge passes
##      through the image centre) within 0.2%.

const FRAMES := 256
const BINS_PER_PX := 20
const F1_EXPECTED := 1.081
const F1_TOL := 0.08
const F2_TOL := 0.05
const F3_TOL := 0.002
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const SLANT := 1.0 / 128.0 # tan(theta): one pixel of drift per 128 rows

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(1)

	# Black quad: 40 x 40, centred at x = -20 so its right edge is the line
	# x = 0 before the tilt. Rotating about the camera's forward axis (Z) by
	# theta puts the edge at x = -y * tan(theta).
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(40, 40)
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0, 0, 0)
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.roughness = 1.0
	quad.material_override = mat
	quad.position = Vector3(-20, 0, 0)
	# Rotate about the origin, not the quad's own centre: parent it under a
	# pivot at the origin so the edge line stays through (0, 0).
	var pivot := Node3D.new()
	pivot.rotation = Vector3(0, 0, atan(SLANT))
	add_child(pivot)
	pivot.add_child(quad)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var w := img.get_width()
	var h := img.get_height()
	# Vertical FOV at aspect 1: half-height of the view at the quad plane.
	var half := CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)
	var px := 2.0 * half / float(h) # world units per pixel

	# Bin every pixel by its signed distance (in px) from the edge.
	var nb := 8 * BINS_PER_PX # +-4 px
	var sum := PackedFloat64Array()
	var cnt := PackedInt32Array()
	sum.resize(nb)
	cnt.resize(nb)
	var total := 0.0
	for j in range(h):
		var yc := (1.0 - (float(j) + 0.5) / (float(h) * 0.5)) * half
		var x_edge := -yc * SLANT
		for i in range(w):
			var c := img.get_pixel(i, j)
			var v := (c.r + c.g + c.b) / 3.0
			total += v
			var xc := ((float(i) + 0.5) / (float(w) * 0.5) - 1.0) * half
			var d := (xc - x_edge) / px
			var b := int(floor((d + 4.0) * BINS_PER_PX))
			if b < 0 or b >= nb:
				continue
			sum[b] += v
			cnt[b] += 1
	var esf := PackedFloat64Array()
	var dpos := PackedFloat64Array()
	for b in range(nb):
		if cnt[b] == 0:
			continue
		esf.append(sum[b] / float(cnt[b]))
		dpos.append((float(b) + 0.5) / BINS_PER_PX - 4.0)

	var d10 := _cross(dpos, esf, 0.10)
	var d25 := _cross(dpos, esf, 0.25)
	var d50 := _cross(dpos, esf, 0.50)
	var d75 := _cross(dpos, esf, 0.75)
	var d90 := _cross(dpos, esf, 0.90)
	var ramp := d90 - d10
	var sym := absf((d75 - d50) - (d50 - d25))
	var mean := total / float(w * h)

	print("\n=== F1: edge-spread 10-90%% ramp ===")
	print("  ramp %.4f px  (expected %.3f +- %.3f; +-1.0 window would read 0.721)" % [ramp, F1_EXPECTED, F1_TOL])
	_checks += 1
	if absf(ramp - F1_EXPECTED) > F1_TOL:
		_failures.append("F1 ramp: %.4f px vs expected %.3f +- %.3f" % [ramp, F1_EXPECTED, F1_TOL])

	print("\n=== F2: symmetry ===")
	print("  d25 %.4f d50 %.4f d75 %.4f  asym %.4f px (limit %.3f)" % [d25, d50, d75, sym, F2_TOL])
	_checks += 1
	if sym > F2_TOL:
		_failures.append("F2 symmetry: %.4f px (limit %.3f)" % [sym, F2_TOL])

	print("\n=== F3: energy ===")
	print("  image mean %.5f  (expected 0.5 +- %.3f)" % [mean, F3_TOL])
	_checks += 1
	if absf(mean - 0.5) > F3_TOL:
		_failures.append("F3 energy: mean %.5f vs 0.5" % mean)

	print("")
	if _failures.is_empty():
		print("PASS: all %d pixel-filter checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Position (px) where the monotone profile crosses p_level, by linear
## interpolation between the two bins that straddle it.
func _cross(p_d: PackedFloat64Array, p_v: PackedFloat64Array, p_level: float) -> float:
	for k in range(1, p_v.size()):
		if p_v[k - 1] < p_level and p_v[k] >= p_level:
			var t := (p_level - p_v[k - 1]) / maxf(p_v[k] - p_v[k - 1], 1e-9)
			return p_d[k - 1] + t * (p_d[k] - p_d[k - 1])
	return NAN


func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
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
```

`pipeline_references/tests/pt_pixel_filter_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_pixel_filter_gate.gd" id="1_gate"]

[node name="PTPixelFilterGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: Run it on the current build — F1 must be red, F2/F3 green**

```bash
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_pixel_filter_gate_scene.tscn
```

Expected: `F1 ramp 0.72 ± 0.05` → `FAIL - F1 ramp`, F2 asym < 0.05, F3 mean 0.500 ± 0.002, `FAIL: 1 of 3`.

If F1 reads ~1.6 the profile is being sampled at pixel centres, i.e. the slant is not taking effect — check that `pivot.rotation` is applied (the quad must be a child of the pivot, and the pivot's rotation set before `add_child`). If F3 is off by more than 0.2%, the edge does not pass through the image centre — check `quad.position = (-20, 0, 0)` and that the camera is at `(0, 0, 10)` looking down −Z (Godot's default camera orientation), not rotated. If F1 is NAN, `_cross` found no crossing — print the `esf` array and check the sky reads 1.0 and the quad 0.0.

- [ ] **Step 3: Amend the spec's gate section**

In `docs/superpowers/specs/2026-09-16-still-route-pixel-filter-design.md`, replace the paragraph starting `Scene: an orthographic camera` through `a white sky of radiance 1.` with:

```
Scene: a perspective camera (FOV 10°, 10 units back, 256×256) looking at a
flat black quad (albedo 0, max bounces 1) against a white sky of radiance 1.
The quad's right edge passes through the image centre and is tilted by
atan(1/128), so it drifts one pixel every 128 rows: sorting every pixel by
its known signed distance to the edge sweeps out the CONTINUOUS edge-spread
function (the filter's CDF). An edge on a pixel centre cannot discriminate
the widths — both windows then read 0 / 0.5 / 1, because the Blackman-Harris
tails at ±1 px are 0.6% and 0%.
```

and replace `Expected `1.081 ± 0.08` (the analytic CDF of the 1.5-wide window, sampled at pixel centres, ±0.08 for the pixel-centre quantisation and 256-sample noise)` with `Expected `1.081 ± 0.08` (the analytic CDF of the 1.5-wide window; ±0.08 for 0.05 px binning and 256-sample noise)`.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/tests/pt_pixel_filter_gate.gd pipeline_references/tests/pt_pixel_filter_gate_scene.tscn docs/superpowers/specs/2026-09-16-still-route-pixel-filter-design.md
git commit -m "test(pt): pixel-filter gate -- slanted-edge ESF of the camera filter (red at the 1.0 px window)

F1 reads 0.72 px on the +-1.0 window against Cycles' 1.081 (filter_width
1.5, widened x2). Spec's gate section corrected: an edge on a pixel centre
cannot tell the two widths apart.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Filter width 1.5 (engine)

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (the `CAMERA RECONSTRUCTION FILTER` block: comment, new constant, `bh_filter_1d`)

**Interfaces:**
- Consumes: gate from Task 1.
- Produces: `const float RT_PIXEL_FILTER_WIDTH = 1.5;` — the only knob; `bh_filter_1d(u)` now returns offsets in `[-1.5, 1.5]`.

- [ ] **Step 1: Rewrite the comment block and add the constant**

Replace, in `raytracing_inc.glsl`, the text from `// Blackman-Harris pixel reconstruction filter, matching Blender Cycles.` through `// generated from the same formula Cycles uses.` with:

```glsl
// Blackman-Harris pixel reconstruction filter, matching Blender Cycles.
//
// Cycles evaluates the Blackman-Harris window over its half-profile [0, 1],
// builds an inverted CDF from it, and looks the sub-pixel offset up from that
// table (intern/cycles/scene/film.cpp: filter_func_blackman_harris +
// util_cdf_inverted; applied in kernel/camera/camera.h: raster += lookup_table_read).
// Cycles' DEFAULT filter_width is 1.5 (intern/cycles/blender/addon/properties.py,
// `filter_width ... default=1.5`), and filter_table() widens it x2, so offsets
// span +/-1.5 pixels around the pixel centre. RT_PIXEL_FILTER_WIDTH below is
// that 1.5. (It was 1.0 until 2026-09-16 on the belief that Cycles' default
// was 1.0; the pixel-filter gate's 10-90% edge ramp read 0.72 px against
// Cycles' 1.08.)
//
// The window is strongly centre-weighted: half the samples land within
// +/-0.29 px of the centre (+/-0.19 at width 1.0), the rest fall away
// smoothly to the +/-1.5 px edge. That shape, not the radius alone, is what
// keeps fine detail while still ramping a hard edge over ~1.1 px.
//
// Table below is the inverse CDF of the half-profile sampled at 33 points,
// generated from the same formula Cycles uses, on a NORMALISED radius [0, 1];
// bh_filter_1d scales it by RT_PIXEL_FILTER_WIDTH, so the shape is width-free.
const float RT_PIXEL_FILTER_WIDTH = 1.5;
```

- [ ] **Step 2: Scale the offset**

Replace the body of `bh_filter_1d`:

```glsl
float bh_filter_1d(float u) {
	float s = 2.0 * u - 1.0;
	return sign(s) * bh_inv_cdf_half(abs(s)) * RT_PIXEL_FILTER_WIDTH;
}
```

and its doc comment's `offset in [-1, 1]` → `offset in [-RT_PIXEL_FILTER_WIDTH, RT_PIXEL_FILTER_WIDTH]`.

- [ ] **Step 3: Build**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
```

Expected: exit 0. (No `.gen.h` is hand-edited; the build regenerates it.)

- [ ] **Step 4: Gate green, three times**

Run the Task 1 command three times; record all three F1 values. Expected: each `1.081 ± 0.08`, F2 asym < 0.05, F3 mean 0.500 ± 0.002, `PASS: all 3`. The spread across the three runs is what justifies `F1_TOL`; if it exceeds 0.03, raise `FRAMES` to 512 rather than the tolerance.

If F1 reads ~1.08 but F2 fails: the offset sign differs between axes — `bh_filter_1d` is 1-D and applied to both, so look at `camera_ray`'s `pixel_center = vec2(p_pixel) + p_jitter`. If F1 reads ~1.6: the multiplication landed on `u` instead of on the returned radius.

- [ ] **Step 5: Isolation gates and doctest**

Every gate whose reference was captured on the accumulate route with the 1.0 window could move if it measures an edge; none does by design (furnaces, crops away from edges, ratios). Run the full suite anyway:

```bash
for s in pipeline_references/tests/pt_*_gate_scene.tscn; do n=$(basename "$s" .tscn); timeout 1500 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references "res://tests/$n.tscn" > "$SCRATCH/pf_$n.log" 2>&1; echo "$n exit=$? :: $(grep -E '^(PASS|FAIL)' "$SCRATCH/pf_$n.log" | head -1)"; done
bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | grep "test cases:"
```

Expected: 16/16 green (15 existing + pixel-filter), doctest 1558/1558. A gate that goes red here and measures a crop touching a silhouette (check its `_measure_crop` bounds) has a legitimately moved reference — re-derive it from the new build with the same three-run spread rule, and say so in the commit; anything else red is a bug in this task.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl pipeline_references/tests/pt_pixel_filter_gate.gd
git commit -m "fix(pt): pixel filter width 1.5 -- Cycles' default, not 1.0

camera_filter_jitter's Blackman-Harris window spanned +-1.0 px on the
belief that Cycles' default filter_width was 1.0; it is 1.5
(properties.py), widened x2 in film.cpp. RT_PIXEL_FILTER_WIDTH scales the
normalised inverse-CDF table. Pixel-filter gate F1: 0.72 -> <value> px
(analytic 1.081); suite 16/16, doctest 1558/1558.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

(Include `pt_pixel_filter_gate.gd` only if Step 4 changed `FRAMES`.)

---

### Task 3: Pipeline — Phase A route on, no sharpener (user's files, NOT committed)

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd` (route block, ~line 1252–1296; CRLF)
- Modify: `pipeline_references/render.gd` (viewport setup, the line after `get_viewport().scaling_3d_scale = 1.0` at ~186; LF)

**Interfaces:**
- Consumes: nothing from Tasks 1–2 (independent); the asset check uses the Task 2 binary.
- Produces: the reference copies the user carries to `C:\Zlendo2026\ZlenderRender_stage_copy\godot_project\`.

Patch in bytes with newline detection and exact-count asserts (the memory note on CRLF copies); never launch a render on a `;` after a patch script — chain with `&&`.

- [ ] **Step 1: Route constants and select**

In `image_glb_creation.gd`:

```
const PHASE_A_OFFLINE_STILL := false      →  const PHASE_A_OFFLINE_STILL := true
const PHASE_A_ACCUM_TARGET := 1024        →  const PHASE_A_ACCUM_TARGET := 256
const PHASE_A_FINAL := "none"             →  const PHASE_A_FINAL := "oidn"
```

Replace the comment lines

```
	# ZR_PHASE_A=1 also forces it on, but be aware the variable must be set for the
	# process that SPAWNS Godot — i.e. the uvicorn server — not a separate shell.
	# Setting it in another terminal does nothing, which is why the constant above
	# exists as the reliable switch.
```

with

```
	# PRODUCTION SINCE 2026-09-16 (spec 2026-09-16-still-route-pixel-filter-design.md).
	# The realtime DLSS-RR route below is a game denoiser: its reconstruction never
	# converges to the pixel-filtered image, and on a 4K still it left a one-pixel
	# staircase on every edge and a checkerboard on flat walls, whatever it was fed
	# (sharpener off, jitter sign, 64 jitter phases -- all measured, none fixed it).
	# Phase A is Cycles' own pipeline -- N samples through the Blackman-Harris pixel
	# filter, then OIDN -- and measured clean on the same frame, in half the time.
	# 256 is the sample count of the Blender reference still; OIDN matches Blender's
	# default final denoise. Video keeps DLSS-RR (video_glb_creation.gd).
	#
	# ZR_PHASE_A=1 ALSO turns the route on (either is enough; it used to need
	# both). The variable must be set for the process that SPAWNS Godot -- i.e.
	# the uvicorn server -- not a separate shell.
```

and the select line

```
	var phase_a_offline := PHASE_A_OFFLINE_STILL and OS.get_environment("ZR_PHASE_A") == "1"
```

with

```
	var phase_a_offline := PHASE_A_OFFLINE_STILL or OS.get_environment("ZR_PHASE_A") == "1"
```

Also update the tuning comment's `256 is a preview, 1024 a hero shot.` to `256 matches the Blender reference; 512 halves the grain again at double the time.`

- [ ] **Step 2: No sharpener on stills**

In `render.gd`, after `	get_viewport().scaling_3d_scale = 1.0` (the one in the viewport setup, directly before `print("[Render] DLSS viewport mode enabled`), insert:

```gdscript
	# NO SHARPENER ON A STILL. Godot's Viewport default fsr_sharpness is 0.2, and
	# the DLSS effect runs an NIS sharpen pass at fsr_sharpness / 2 on its output
	# (servers/rendering/renderer_rd/effects/dlss.cpp, "NIS support"). On job 217
	# it doubled the number of hard one-pixel steps along edges (270 vs 124 with
	# it off). Phase A never enters the DLSS branch, but the default would bite
	# the moment the realtime route is switched back on, so it is zeroed here.
	get_viewport().fsr_sharpness = 0.0
```

- [ ] **Step 3: Parse checks**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references --check-only -s image_glb_creation.gd 2>&1 | grep -iE "error|parse" ; echo "exit=${PIPESTATUS[0]}"
bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references --check-only -s render.gd 2>&1 | grep -iE "error|parse" ; echo "exit=${PIPESTATUS[0]}"
```

Expected: no error lines, exit 0 for both.

- [ ] **Step 4: Asset check — job 217 at FHD, Phase A, filter 1.0 vs 1.5**

Scratch project: copy `<scratchpad>/e3/proj_e3` to `<scratchpad>/aa/proj_pa`, then copy the reference `image_glb_creation.gd` and `render.gd` over it. Two renders of `input_json/d217_fhd.json`, same pipeline, engine differing only by Task 2:

- **before**: check out the pre-Task-2 shader (`git stash` is forbidden; use `git show <task-1-commit>:servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl > .../raytracing_inc.glsl`), build, render to `<scratchpad>/aa/d217_pa_w10.png`; then restore with `git checkout -- servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (engine file, clean tree) and rebuild.
- **after**: render to `<scratchpad>/aa/d217_pa_w15.png`.

Both logs must contain `[PhaseA] Offline accumulation ON — target=256 frames, final=oidn` — if absent the route did not run and the render is the realtime one. Record wall time of each.

Measure with the investigation's script (ramp statistic over rows 600–1000, cols 400–1300; hard-step count; chair-leg crop at (1250, 900)):

```python
# <scratchpad>/aa/measure.py  -- python measure.py a.png b.png
import sys, numpy as np
from PIL import Image
def ld(p):
    a=np.asarray(Image.open(p)); a=a.astype(float)/257.0 if a.dtype!=np.uint8 else a.astype(float); return a[:,:,:3]
def lum(a): return a@[0.2126,0.7152,0.0722]
def ramp_stats(a, y0,y1,x0,x1, step=40):
    L=lum(a); ws=[]
    for y in range(y0,y1):
        s=L[y,x0:x1]; d=np.abs(np.diff(s))
        for i in np.argsort(d)[::-1][:3]:
            lo=min(s[max(i-6,0)],s[min(i+7,len(s)-1)]); hi=max(s[max(i-6,0)],s[min(i+7,len(s)-1)])
            if hi-lo<step: continue
            seg=s[max(i-6,0):i+7]; mid=(seg>lo+0.1*(hi-lo))&(seg<hi-0.1*(hi-lo)); ws.append(int(mid.sum()))
    ws=np.array(ws); return ws.mean(), np.bincount(ws, minlength=6)[:6]
for p in sys.argv[1:]:
    m,h=ramp_stats(ld(p),600,1000,400,1300); print("%-24s ramp mean %.2f px  hist(0..5) %s" % (p.split('/')[-1], m, h))
```

Expected: ramp mean rises from ~1.76 (w1.0) toward ~2.1 (w1.5) and the hard-step count (bin 0) falls; the whole-frame mean moves under 0.5% (a wider filter redistributes, it does not add). Cut the chair-leg crop pair for the roadmap.

- [ ] **Step 5: Do not commit; hand over**

`git status` must show `pipeline_references/image_glb_creation.gd` and `pipeline_references/render.gd` modified and unstaged. Tell the user both files are ready to carry over, together with the Task 2 `bin/` build, and that the first 4K run's Godot log line `[Render] Accumulating 256 frames` … `Image saved` gives the wall time to read against `TIMEOUT = 1500` s.

---

### Task 4: Roadmap and plan

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (gap table: new row 28; new §11.24)
- Modify: `docs/superpowers/plans/2026-09-16-still-route-pixel-filter.md` (tick boxes, execution notes)

- [ ] **Step 1: Row 28**

Append to the gap table (after row 27):

```
| 28 | **Still route: DLSS-RR reconstruction, NIS sharpen, 1.0 px filter** — 4K stills had a one-pixel staircase on every edge and a checkerboard on flat walls. **Closed 2026-09-16 (§11.24)**: stills go through Phase A (accumulate 256 × BH filter, OIDN), the filter widened to Cycles' 1.5 px, `fsr_sharpness` 0. `pt_pixel_filter_gate` F1 0.72 → 1.08 px. | `raytracing_inc.glsl camera_filter_jitter`, `render.gd`, `image_glb_creation.gd` | `film.cpp filter_table`, `properties.py filter_width` | High |
```

- [ ] **Step 2: §11.24**

Append a section `## 11.24 Gap #28 — the still route was a game denoiser` with: the Blender-vs-ours edge table (3.6 / 1.0 px), the six-row route experiment table from the spec with the measured numbers, the analytic filter-width table, the three changes, the gate's three F1 readings from Task 2, the Task 3 before/after numbers and wall times, and a "what is still open" line: the checkerboard's mechanism inside DLSS-RR (jitter-zero doubles it, 64 phases reduce it) is recorded, not pursued; the 4K wall time is to be read from the user's first production run.

- [ ] **Step 3: Tick the plan and commit**

```bash
sed -i 's/^- \[ \] /- [x] /' docs/superpowers/plans/2026-09-16-still-route-pixel-filter.md
git add PATH_TRACER_QUALITY_ROADMAP.md docs/superpowers/plans/2026-09-16-still-route-pixel-filter.md
git commit -m "docs(pt): Gap #28 -- still route on Phase A, 1.5 px filter, no sharpen (roadmap 11.24)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** route flip + `or` + comments (T3 S1); filter constant + comment rewrite + tent sentence dropped (T2 S1–2); `fsr_sharpness` (T3 S2); gate F1/F2/F3 with falsifiability run (T1 S2, T2 S4); three-run tolerance justification (T2 S4); asset check before/after + 4K wall time via the user (T3 S4–5); roadmap (T4). Spec's pixel-centre gate design replaced by the slanted edge and the spec amended (T1 S3).
- **Placeholders:** the T2 commit message's `<value>` is filled from Step 4; T4 S2 lists the exact contents the section must carry. No TODO/TBD.
- **Type consistency:** `RT_PIXEL_FILTER_WIDTH` (T2) is the only new identifier; `F1_EXPECTED`/`F1_TOL`/`FRAMES` names match between the gate code and T2 S4's instruction; `_render_accum` signature as in `pt_validation.gd:88`.
