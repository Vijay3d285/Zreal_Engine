# Sky Miss Clamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clamp the sky a bounce ray reaches in the miss stage with Cycles' `bounce - 1` rule (`total_bounces <= 1u` direct, else indirect). Prove it with a GPU gate that fails on the old binary and on the rejected rule, then measure job 209 before and after so the owner can decide whether to ship.

**Architecture:** One expression in the miss stage of `scene_raytracing_raygen.glsl` routes the existing `sky_contribution` through `clamp_contribution`, with the limit chosen by `total_bounces`. A new ratio gate (`pt_sky_clamp_gate.gd`) renders four scenes at clamps 0/0 and 0/10 under a uniform sky of radiance 1000. Job 209 is rendered five times with the production scripts (copied, never edited), and the raw OIDN input of each run is compared.

**Tech Stack:** Godot 4.7 fork (Vulkan RT, GLSL 460), GDScript gates, Git Bash runner, Python 3 (numpy 2.2.6, Pillow 12.1.1) for the measurement.

**Spec:** `docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md`

## Global Constraints

- Rule: `total_bounces <= 1u ? RT_PARAM_CLAMP_DIRECT : RT_PARAM_CLAMP_INDIRECT`, through `clamp_contribution` (spec 1). Rejected: `total_bounces == 0u`.
- The emissive-hit clamp (`raytracing_closest_hit_common_inc.glsl:1632`) is NOT touched (spec, Out of scope).
- `clamp_contribution` stays max-channel. There is no payload, C++ or script change apart from the one comment (spec 1, 2).
- With clamps 0/0 the output is byte-identical to the pre-change binary (spec 1, Invariants). DLSS-RR video and every gate default to 0/0.
- Gate: `SKY := 1000.0`; S1 `1.0 +- 0.001`, S3 `1.0 +- 0.001`, F1 `1.0 +- 0.01`, S2 `<= 0.5` (spec 3 table).
- Verdicts V1-V4 are exactly as spec section 4 fixes them. Bias is judged on the raw `oidn_color.pfm`, never the PNG.
- Nothing under `C:\Zlendo2026` changes. Never stage `pipeline_references/video_glb_creation.gd`, which is modified but not part of this work. Commit by path. Do not push.
- Build with `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes` through PowerShell. The current binary has `TESTS_ENABLED`: it lacks the "compiled without support for unit tests" string and contains 3832 "doctest" strings.
- Before every GPU run, `tasklist | grep -i godot` must be empty and `query session` is recorded. Run in the background with the harness's `run_in_background`, never a shell `&`. Grep every Godot log for `Error compiling`, because a clean build does not validate GLSL.
- Files in the main checkout are written by copying from the session scratchpad with Bash. This session is anchored in an app worktree, and a hook blocks the Write/Edit tools on the main checkout. The owner asked for this work in the main checkout.

### Rulings recorded here (from reading the code)

- **Backup names.** The spec says "back up as `*.pre_skyclamp.exe`". The console wrapper
  (`platform/windows/console_wrapper_windows.cpp:75-93`) finds its target by replacing the
  literal `.console.exe` in its own name with `.exe`. A backup named `...console.pre_skyclamp.exe`
  would print "Invalid wrapper executable name" and never run. So the backups are
  `bin/godot.windows.editor.x86_64.pre_skyclamp.exe` and
  `bin/godot.windows.editor.x86_64.pre_skyclamp.console.exe`, and the wrapper launches the first.
- **The pre-change binary is the current one.** `bin/` was built on 2026-10-14 at 21:00. The only
  later source change (b5637d0c94, 21:22) is a comment in `scene_shader_raytracing.cpp`, plus scripts.
- **Fault build first, then the rule.** The spec's F1 proof is: "build with `== 0u` and run the gate,
  F1 must FAIL; restore the rule, rebuild, confirm GREEN". Building the fault first and the rule
  second gives the same two readings with two builds instead of three. The final binary is still
  built from the committed rule, and the fault is never committed.
- **S1 carries a scale guard.** S1, S3 and F1 assert 1.0, which a sky too dim to be clamped would also
  give. So S1 also asserts that the 0/0 crop mean is at least 10x the indirect limit, which means the
  clamp is able to bite. This is a second check under S1, not a new scene.
- **S1 keeps one box out of view** (behind the camera), so the TLAS is not empty.
- **The `image_glb_creation.gd` default line.** The tuning list says `ZR_PT_CLAMP_INDIRECT ... (default 0;
  Blender's is 10)`, and the old block says "inert at the default (clamp is 0 = off)". But
  `PHASE_A_CLAMP_INDIRECT := 10.0` (`:1283`). The rewrite corrects both lines, since the old block's
  claim rested on that stale default.
- **Run order.** R1, R2 and R4 (pre-change) run before any build; R3 and R5 run after the final build.
  No render overlaps a build, so render times are comparable.

## Review Focus

1. **The DLSS-RR one-shot variant at clamps 0/0** should stay byte-identical. The change is in the miss stage, which both variants share, and `clamp_contribution` returns its argument unchanged when the limit is `<= 0.0` (`raytracing_inc.glsl:719-725`). V1 pins the accumulate variant on job 209 (Task 5); the one-shot variant is covered by construction only. The report says so.
2. **OIDN video jobs change too.** Production video windows use an alpha closure. Sky reached by a bounce ray through one (total >= 2) is now clamped at `clamp_indirect` 10. No task measures a video job, and the report says so for the ship decision.
3. **The alpha pass-through deviation.** A first-bounce ray that passes an alpha pane before reaching the sky arrives at the miss with total 2, so it takes the indirect limit where Cycles keeps it direct. This is documented at the site (Task 2) and in `image_glb_creation.gd` (Task 4). S3 pins the camera case (total 1, direct).
4. **Debug vis modes.** `VIS_MODE == 0` uses the clamped value. The other modes overwrite `ps.radiance` and are unaffected. Checked by reading Task 2's diff.
5. **The sun disc in a window.** A clamp at 10 cuts any sky sample above 10 reached at total >= 2, including the sun seen through glass. V4 makes an exception when the sun disc itself is in view, and Task 5 Step 8 checks the crops for it.

---

### Task 1: Backups and the gate, RED on the pre-change binary

**Files:**
- Create: `pipeline_references/tests/pt_sky_clamp_gate.gd`
- Create: `pipeline_references/tests/pt_sky_clamp_gate_scene.tscn`
- Backup: `bin/godot.windows.editor.x86_64.pre_skyclamp.exe`, `bin/godot.windows.editor.x86_64.pre_skyclamp.console.exe`

**Interfaces:**
- Consumes: `res://tests/pt_validation.gd` (`_render_accum(env, vp_rid, frames) -> Image`; also pins `filter_glossy` to 0); `Environment.set_pathtracing_clamp_direct/indirect` and `set_pathtracing_max_bounces`.
- Produces: the gate scene, run as `<console exe> --rendering-driver vulkan --path pipeline_references res://tests/pt_sky_clamp_gate_scene.tscn`. Exit 0 means PASS. It prints `PASS: all N sky-clamp checks passed.` or `FAIL - ...` lines.

- [ ] **Step 1: Back up the pre-change binaries**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/bin
cp -p godot.windows.editor.x86_64.exe godot.windows.editor.x86_64.pre_skyclamp.exe
cp -p godot.windows.editor.x86_64.console.exe godot.windows.editor.x86_64.pre_skyclamp.console.exe
md5sum godot.windows.editor.x86_64.exe godot.windows.editor.x86_64.pre_skyclamp.exe
```
Expected: identical md5s.

- [ ] **Step 2: Write the scene file**

`pipeline_references/tests/pt_sky_clamp_gate_scene.tscn`:
```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_sky_clamp_gate.gd" id="1_gate"]

[node name="PTSkyClampGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 3: Write the gate**

`pipeline_references/tests/pt_sky_clamp_gate.gd`. The scaffolding comes from `pt_shadow_visibility_gate.gd`, the pane geometry and BLEND material from `pt_transparent_alpha_gate.gd`, and the glass from `image_glb_creation.gd` `_apply_glb_transmissive_glass`:

```gdscript
extends "res://tests/pt_validation.gd"

## Sky miss clamp gate (spec docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_sky_clamp_gate_scene.tscn
##
## The miss stage clamps the sky a ray reaches with Cycles' rule: film_write_background clamps
## with film_clamp_light(bounce - 1) (kernel/film/light_passes.h:638), i.e. by the vertex that
## cast the ray. Our total_bounces already counts the bounce that produced the ray, so total <= 1
## at the miss takes clamp_direct and anything later takes clamp_indirect.
##
## Each check renders one scene twice, with clamps (direct/indirect) 0/0 and 0/10, and asserts
## mean(0/10) / mean(0/0) over the centre crop. The sky is a uniform RGBF panorama of radiance
## SKY, so a sky sample is ~100x the indirect limit: a clamp that applies cuts it to ~1%, one
## that does not leaves the ratio at 1.0, and noise cannot sit in between.
##
##   S1 camera sees the sky                  total 0 at the miss   1.0 +- 0.001
##      guard: the 0/0 crop mean is >= 10x the limit, so the clamp can bite at all
##   S3 sky through one alpha-0 BLEND pane   total 1               1.0 +- 0.001
##   F1 grey floor, first surface's bounce   total 1               1.0 +- 0.01
##   S2 sky through a solid glass slab       total 2               <= 0.5
##
## S2's expected value: the front-face reflection (F ~0.04, total 1) stays unclamped, about 40;
## the twice-refracted share (~0.92) is cut to 10 per sample, about 9; so ~0.05.
## F1's counterfactual (the rejected total_bounces == 0 rule): the bounce ray's sky is cut to ~10
## against ~214 x w per sample (linear albedo 0.214 of sRGB 0.5), which leaves the env-NEE share
## of the floor (1 - ln(17)/16 = 0.18 of it under a uniform sky) plus ~10/214: about 0.2.
##
## READINGS: filled in by Task 3 of docs/superpowers/plans/2026-10-14-pt-sky-miss-clamp.md.

const SKY := 1000.0
const FRAMES := 128
const CLAMP_INDIRECT := 10.0
const EXACT_TOL := 0.001
const F1_TOL := 0.01
const S2_MAX := 0.5

# Camera on the -Z axis and a 6x6 pane at z = -2: pt_transparent_alpha_gate.gd's geometry, which
# keeps the pane over the whole 0.35-0.65 crop.
const CAM_POS := Vector3(0, 0, 5)
const CAM_TARGET := Vector3(0, 0, -5)
const CAM_FOV := 25.0
const PANE_SIZE := Vector3(6, 6, 0.05)
const PANE_Z := -2.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== S1: camera sees the sky (total 0 at the miss) ===")
	var s1: Dictionary = await _clamp_ratio("s1", 2)
	_check("S1 camera sky", s1["ratio"], 1.0 - EXACT_TOL, 1.0 + EXACT_TOL)
	_check("S1 guard: sky / limit", float(s1["off"]) / CLAMP_INDIRECT, 10.0, INF)

	print("\n=== S3: sky through one alpha-0 BLEND pane (total 1) ===")
	var s3: Dictionary = await _clamp_ratio("s3", 2)
	_check("S3 alpha pane", s3["ratio"], 1.0 - EXACT_TOL, 1.0 + EXACT_TOL)

	print("\n=== F1: grey floor, the first surface's bounce ray (total 1) ===")
	var f1: Dictionary = await _clamp_ratio("f1", 1)
	_check("F1 first bounce", f1["ratio"], 1.0 - F1_TOL, 1.0 + F1_TOL)

	print("\n=== S2: sky through a solid glass slab (total 2) ===")
	var s2: Dictionary = await _clamp_ratio("s2", 4)
	_check("S2 solid glass", s2["ratio"], 0.0, S2_MAX)

	print("")
	if _failures.is_empty():
		print("PASS: all %d sky-clamp checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	print("  %s: %.6f (band [%.3f, %.3f])" % [p_name, p_value, p_lo, p_hi])
	if p_value < p_lo or p_value > p_hi:
		_failures.append("%s: %.6f outside [%.3f, %.3f]" % [p_name, p_value, p_lo, p_hi])


## Builds scene p_scene, renders it with clamps 0/0 and then 0/CLAMP_INDIRECT, and returns
## {off, on, ratio} for the centre crop. Only clamp_indirect changes between the two renders;
## clamp_direct stays 0, as in production.
func _clamp_ratio(p_scene: String, p_bounces: int) -> Dictionary:
	for c in get_children():
		c.queue_free()
	await get_tree().process_frame

	var cam_pos := CAM_POS
	var cam_target := CAM_TARGET
	var cam_fov := CAM_FOV
	match p_scene:
		"s1":
			_add_offscreen_box()
		"s3":
			_add_pane(_alpha_pane_material())
		"s2":
			_add_pane(_glass_material())
		"f1":
			_add_floor()
			# pt_shadow_visibility_gate.gd's floor view.
			cam_pos = Vector3(0, 0.5, 4)
			cam_target = Vector3(0, -1, 0)
			cam_fov = 30.0
	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child(): see pt_transparent_alpha_gate.gd.
	cam.look_at_from_position(cam_pos, cam_target, Vector3.UP)
	cam.fov = cam_fov
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(SKY, SKY, SKY))
	env.set_pathtracing_max_bounces(p_bounces)
	await get_tree().create_timer(1.0).timeout

	var vp_rid := get_viewport().get_viewport_rid()
	env.set_pathtracing_clamp_indirect(0.0)
	var off_img: Image = await _render_accum(env, vp_rid, FRAMES)
	var off: float = _measure_crop(off_img, 0.35, 0.65)["mean"]
	env.set_pathtracing_clamp_indirect(CLAMP_INDIRECT)
	var on_img: Image = await _render_accum(env, vp_rid, FRAMES)
	var on: float = _measure_crop(on_img, 0.35, 0.65)["mean"]
	print("  crop mean: clamps 0/0 %.6f, 0/%.0f %.6f" % [off, CLAMP_INDIRECT, on])
	if off < 1e-6:
		_checks += 1
		_failures.append("%s: control render is black (%.8f)" % [p_scene, off])
		return {"off": off, "on": on, "ratio": 0.0}
	return {"off": off, "on": on, "ratio": on / off}


## S1 has nothing in view; this box behind the camera only keeps the TLAS non-empty.
func _add_offscreen_box() -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	mi.mesh = mesh
	mi.position = Vector3(0, 0, 20)
	add_child(mi)


func _add_pane(p_mat: StandardMaterial3D) -> void:
	var pane := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = PANE_SIZE
	pane.mesh = mesh
	pane.position = Vector3(0, 0, PANE_Z)
	pane.material_override = p_mat
	add_child(pane)


## What the glTF importer produces for alphaMode BLEND (pt_transparent_alpha_gate.gd). Alpha 0:
## every camera ray passes through (one inc_transmission_bounce), so it meets the sky at total 1.
func _alpha_pane_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	m.albedo_color = Color(1, 1, 1, 0.0)
	return m


## Production window glass, as image_glb_creation.gd _apply_glb_transmissive_glass sets it:
## solid (thickness > 0 is the flag), clear, IOR 1.5, metallic_specular 0.5 (the no-op that keeps
## eta == ior). A camera ray refracts in at the front face and out at the back face: total 2.
func _glass_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	m.no_depth_test = false
	m.metallic = 0.0
	m.transmission = 1.0
	m.ior = 1.5
	m.metallic_specular = 0.5
	m.thickness = 0.05
	m.albedo_color = Color(1, 1, 1, 1)
	m.roughness = 0.0
	m.emission_enabled = false
	return m


## An open grey floor: nothing above it, so every bounce ray from it meets the sky at total 1.
## albedo_color is sRGB: 0.5 shades as linear 0.214 (pt_energy_gate.gd's note).
func _add_floor() -> void:
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(200, 0.1, 200)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, -1, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.5, 0.5, 0.5)
	floor_mat.roughness = 1.0
	floor_mat.metallic = 0.0
	floor_mi.material_override = floor_mat
	add_child(floor_mi)


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
	return {"mean": (r + g + b) * inv / 3.0, "n": n}
```

- [ ] **Step 4: Run it on the pre-change binary (expect RED on S2 only)**

```bash
tasklist | grep -i godot; query session
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
bin/godot.windows.editor.x86_64.pre_skyclamp.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_sky_clamp_gate_scene.tscn > <scratch>/gate_pre.log 2>&1; echo exit=$?
grep -E "crop mean|band|PASS|FAIL|Error compiling|SCRIPT ERROR" <scratch>/gate_pre.log
```
Expected:
- S1 ~1.000000, and the S1 guard >= 10 (a sky of ~1000 over a limit of 10 gives ~100).
- S3 ~1.000000 and F1 ~1.0.
- **S2 ~1.0, so it FAILs** ("S2 solid glass: ... outside [0.000, 0.500]"), and the exit code is 1.

If any other check fails, or a control render is black, stop: the gate is wrong, not the engine. Fix the measurement, never the expectation.

No commit yet. The gate is committed in Task 3 with its readings.

### Task 2: The miss-stage clamp: fault build, then the rule

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:752`

**Interfaces:**
- Consumes: `get_total_bounces(uint)`, `get_rt_param(int)`, `RT_PARAM_CLAMP_DIRECT` (9), `RT_PARAM_CLAMP_INDIRECT` (10), `clamp_contribution(vec3, float)` (`raytracing_inc.glsl`).
- Produces: a clamped `sky_contribution`. The `VIS_MODE == 0` debug path (`:760`) and the release path (`:766`) consume it unchanged.

Run order: Task 5 Steps 1-4 (R1, R2 and R4 on the backup) run before this task's builds, so no render overlaps a build.

- [ ] **Step 1: Write the change with the FAULT expression (`== 0u`)**

Replace `:752` `	vec3 sky_contribution = ps.throughput * sky_color * mis_w;` with:

```glsl
	// Firefly clamp on the sky, with Cycles' rule: film_write_background clamps the
	// background with film_clamp_light(bounce - 1) (kernel/film/light_passes.h:638), i.e.
	// by the vertex that CAST this ray -- the same class as that vertex's own NEE clamp
	// (shade_and_bounce's clamp_limit), so both MIS halves of a sky hit share one limit.
	// total_bounces already counts the bounce that produced this ray, so the camera ray (0)
	// and the first surface's bounce ray (1) are direct; later bounces are indirect.
	// Deviation: our total_bounces also counts transparent (alpha) pass-throughs, which
	// Cycles keeps in transparent_bounce, so a pass-through between the casting vertex and
	// the sky moves the hit to the indirect limit where Cycles keeps it direct. Exact parity
	// needs a payload bit we do not have (PathPayload's sss_restart note in raytracing_inc.glsl).
	// The emissive-hit clamp (raytracing_closest_hit_common_inc.glsl, clamp_limit) still
	// uses total_bounces == 0 -- the same off-by-one, a filed follow-up.
	// Spec: docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md.
	const float sky_clamp = (get_total_bounces(ps.packed_bounces_flags) == 0u)
			? get_rt_param(RT_PARAM_CLAMP_DIRECT)
			: get_rt_param(RT_PARAM_CLAMP_INDIRECT);
	vec3 sky_contribution = clamp_contribution(ps.throughput * sky_color * mis_w, sky_clamp);
```

This file already uses `const float x = <runtime expr>` (`:101`, `:363`), and `sky_clamp` is not a GLSL reserved word.

- [ ] **Step 2: Build the fault binary (PowerShell, background)**

```powershell
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Tee-Object <scratch>\build_fault.log | Select-Object -Last 30
```
Expected: `scons: done building targets.`, no `command not found`, and an updated timestamp on the bin exe.

- [ ] **Step 3: Run the gate on the fault build (expect F1 RED)**

Use the same command as Task 1 Step 4 with `bin/godot.windows.editor.x86_64.console.exe`, logging to `gate_fault.log`.
Expected:
- F1 well below 0.99 (~0.2).
- S3 ~0.01, because its miss is also at total 1.
- S2 ~0.05 and S1 1.0.
- Exit code 1, and no `Error compiling RayGen`.

If F1 passes, stop: the gate cannot see the rule.

- [ ] **Step 4: Write the rule (`<= 1u`)**

In the block from Step 1, change only `== 0u` to `<= 1u`:
```glsl
	const float sky_clamp = (get_total_bounces(ps.packed_bounces_flags) <= 1u)
```

- [ ] **Step 5: Build the final binary** (as in Step 2, logging to `build_rule.log`).

- [ ] **Step 6: Run the gate (expect GREEN)**

Same command, logging to `gate_new.log`. Expected: `PASS: all 5 sky-clamp checks passed.`, exit code 0, S2 ~0.05, and no `Error compiling`.

- [ ] **Step 7: Commit the shader**

```bash
git add -- servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
git commit -m "fix(pt): clamp the sky a bounce ray reaches, with Cycles' bounce - 1 rule" -- servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
```
The body gives the rule, the gate readings and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

### Task 3: Record the gate's readings and commit it

**Files:**
- Modify: `pipeline_references/tests/pt_sky_clamp_gate.gd` (the `READINGS` line in the header)

- [ ] **Step 1: Replace the READINGS line** with the three measured rows, in this form:

```gdscript
## READINGS (2026-10-14, session 2 Active, 128 frames, 256x256), ratio 0/10 over 0/0:
##   pre-change binary   S1 <v>  S3 <v>  F1 <v>  S2 <v>  -> FAIL (S2)
##   fault, == 0u        S1 <v>  S3 <v>  F1 <v>  S2 <v>  -> FAIL (F1, S3)
##   this rule, <= 1u    S1 <v>  S3 <v>  F1 <v>  S2 <v>  -> PASS
```
Copy the values from `gate_pre.log`, `gate_fault.log` and `gate_new.log`.

- [ ] **Step 2: Commit the gate and its scene**

```bash
git add -- pipeline_references/tests/pt_sky_clamp_gate.gd pipeline_references/tests/pt_sky_clamp_gate_scene.tscn
git commit -m "test(pt): sky clamp gate -- S2 RED before, F1 RED on the == 0 rule, GREEN now" -- pipeline_references/tests/pt_sky_clamp_gate.gd pipeline_references/tests/pt_sky_clamp_gate_scene.tscn
```

### Task 4: The KNOWN OPEN ITEM comment

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd:1310` and `:1314-1320`

- [ ] **Step 1: Correct the default in the tuning list**

Line `:1310`, `	#   ZR_PT_CLAMP_INDIRECT firefly clamp, 0 = off     (default 0; Blender's is 10)`, becomes
`	#   ZR_PT_CLAMP_INDIRECT firefly clamp, 0 = off     (default 10; Blender's is 10)`.

- [ ] **Step 2: Rewrite the block**

Replace `:1314-1320`, from `# KNOWN OPEN ITEM if CLAMP_INDIRECT is enabled:` to `...just not yet fixed.`, with:

```gdscript
	# CLAMP_INDIRECT AND THE SKY (spec 2026-10-14-pt-sky-miss-clamp-design.md). Both MIS halves
	# of a sky hit are clamped. The environment-NEE half takes its vertex's limit
	# (raytracing_closest_hit_common_inc.glsl clamp_limit); the BSDF half, added in the miss
	# stage (scene_raytracing_raygen.glsl sky_clamp), takes Cycles' film_write_background rule,
	# bounce - 1: the camera ray and the first surface's bounce ray are direct (clamp_direct,
	# 0 here, so unclamped), later bounces indirect. Before this the miss half was added raw,
	# and single-pixel sky spikes through glass passed clamp_indirect untouched.
	# One asymmetry remains: an alpha pass-through counts as a bounce in our counter, so sky
	# reached through an alpha pane from a first-bounce vertex takes the indirect limit where
	# Cycles keeps it direct. Fixing that needs a payload bit; not planned.
```

- [ ] **Step 3: Check that the diff touches only those comment lines, then commit**

```bash
git diff -- pipeline_references/image_glb_creation.gd
git add -- pipeline_references/image_glb_creation.gd
git commit -m "docs(pipeline): the sky miss half is clamped now -- rewrite the KNOWN OPEN ITEM note" -- pipeline_references/image_glb_creation.gd
```
`git status` must still show `video_glb_creation.gd` as modified and unstaged.

### Task 5: Job 209, R1-R5, verdict V1-V4

**Files.** All are under `.superpowers/sdd/2026-10-14-sky-miss-clamp/`, which `.superpowers/sdd/.gitignore` ignores.
- Create: `run_still.sh` (a copy of `../2026-10-08-video-parity/prodab/run_still.sh`), `j209_input.json` (a copy), `measure_209.py` and `windows.json`.
- Output: `R1/` .. `R5/`, each holding `render.png`, `run.log`, `done`, `session.txt`, `binary.txt` and `dump/oidn_*.pfm`; plus `crops/`.

- [ ] **Step 1: Copy the runner and fix it**

Copy both files. Then change `run_still.sh` so that:
- `W` points at the new folder;
- the binary is an optional 4th argument;
- it always dumps to `<tag>/dump`, using a `cygpath -m` path, because `_oidn_write_pfm` fails silently when the folder does not exist;
- it records `query session` and the binary used.

```bash
#!/bin/bash
# Render a STILL with PRODUCTION's current godot_project scripts (copied; production untouched).
# usage: run_still.sh <tag> <godot_input.json> [extra env] [binary]
# Always dumps the raw OIDN input to <tag>/dump (ZR_OIDN_DUMP) -- spec 2026-10-14-pt-sky-miss-clamp.
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-sky-miss-clamp
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=${4:-/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/bin/godot.windows.editor.x86_64.console.exe}
TAG=$1; JOB=$2; EXTRA=$3
D=$W/$TAG; rm -rf "$D"; mkdir -p "$D/proj" "$D/dump"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
query session > "$D/session.txt" 2>&1
echo "$BIN $EXTRA" > "$D/binary.txt"
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
DUMP=$(cygpath -m "$D/dump")
start=$(date +%s)
( cd "$D" && env ZR_OIDN_DUMP="$DUMP" $EXTRA $BIN --path "$D/proj" res://main.tscn -- "$JOB" "$D/render.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

`j209_input.json` is used as is. The production settings (4K, 256 spp, `clamp_indirect` 10, `clamp_direct` 0) come from the scripts' Phase A defaults.

- [ ] **Step 2: R1, pre-change** (background; ~9 min)

```bash
S=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-sky-miss-clamp
OLD=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/bin/godot.windows.editor.x86_64.pre_skyclamp.console.exe
bash $S/run_still.sh R1 $S/j209_input.json "" $OLD
```
Then check:
- `cat $S/R1/done` shows `exit=0`;
- `grep -c "Godot Engine v4.7" $S/R1/run.log` gives 1;
- there is no `Error compiling`;
- `$S/R1/dump/oidn_color.pfm` exists;
- `grep "PhaseA" $S/R1/run.log` shows the offline route.

- [ ] **Step 3: R2, pre-change repeat** (same command, tag R2).

- [ ] **Step 4: R4, pre-change, clamp off** (tag R4, EXTRA `"ZR_PT_CLAMP_INDIRECT=0 ZR_PT_ACCUM_TARGET=64"`, binary `$OLD`).

Task 2 (the fault build and the rule build) runs next. Once Task 2 Step 6 is GREEN:

- [ ] **Step 5: R3, new** (tag R3, EXTRA `""`, default binary).

- [ ] **Step 6: R5, new, clamp off** (tag R5, EXTRA `"ZR_PT_CLAMP_INDIRECT=0 ZR_PT_ACCUM_TARGET=64"`, default binary).

- [ ] **Step 7: Locate the three windows on R1's PNG**

View `R1/render.png` (a downscaled copy for reading) and find the three windows. Write `windows.json` with one box per window, inside the glazing rather than the frame, in 4K pixel coordinates with a top-left origin:
```json
{"window_1": [x0, y0, x1, y1], "window_2": [x0, y0, x1, y1], "window_3": [x0, y0, x1, y1]}
```
Confirm each box on the raw dump: its mean must be several times the frame's box-4 median, which shows it is a window and not a wall.

- [ ] **Step 8: Measure**

`measure_209.py`:

```python
"""Job 209 sky miss clamp measurement (spec docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md,
section 4). Luminance of the raw OIDN input (pre-exposure; the daylight probe re-meters the PNG).

usage: python -I measure_209.py <work_dir>
Reads <work_dir>/R1..R5/{dump/oidn_color.pfm, render.png, run.log, done} and <work_dir>/windows.json
({"name": [x0, y0, x1, y1]}, pixels on R1's PNG, top-left origin). Writes <work_dir>/crops/<name>.png
(R1 | R3 PNG crops side by side) and prints every number plus the V1-V4 verdict.
"""
import hashlib
import json
import os
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)
RUNS = ["R1", "R2", "R3", "R4", "R5"]


def read_pfm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() in (b"PF", b"Pf")
        w, h = map(int, f.readline().split())
        scale = float(f.readline())
        a = np.fromfile(f, dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return np.flipud(a)


def box4(l):
    # Medians of single noisy pixels are biased low; take them on 4x4 box averages.
    h, w = l.shape[0] // 4 * 4, l.shape[1] // 4 * 4
    return l[:h, :w].reshape(h // 4, 4, w // 4, 4).mean(axis=(1, 3))


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def stats(d, windows):
    pfm = os.path.join(d, "dump", "oidn_color.pfm")
    png_path = os.path.join(d, "render.png")
    lum = read_pfm(pfm) @ LUMA
    png = np.asarray(Image.open(png_path).convert("RGB"), np.float32)
    flat = lum.ravel()
    w = lum.shape[1]
    top = np.argsort(flat)[::-1][:10]
    lines = open(os.path.join(d, "run.log"), encoding="utf-8", errors="replace").read().splitlines()
    return {
        "lum": lum,
        "png": png,
        "gt50": int((lum > 50.0).sum()),
        "gt200": int((lum > 200.0).sum()),
        "top": [(int(i % w), int(i // w), float(flat[i])) for i in top],
        "mean": float(lum.mean()),
        "median4": float(np.median(box4(lum))),
        "png_luma": float((png @ LUMA).mean()),
        "probe": [l for l in lines if l.startswith("[Daylight]") and "exposure" in l],
        "errors": [l for l in lines if "Error compiling" in l or "SCRIPT ERROR" in l],
        "engines": sum("Godot Engine v4.7" in l for l in lines),
        "done": open(os.path.join(d, "done")).read().strip(),
        "md5_pfm": md5(pfm),
        "md5_png": md5(png_path),
        "win": {k: float(lum[y0:y1, x0:x1].mean()) for k, (x0, y0, x1, y1) in windows.items()},
    }


def pct(a, b):
    return 100.0 * (a / b - 1.0)


def main():
    work = sys.argv[1]
    windows = json.load(open(os.path.join(work, "windows.json")))
    s = {r: stats(os.path.join(work, r), windows) for r in RUNS}

    for r in RUNS:
        x = s[r]
        print(f"== {r}: {x['done']}  engines {x['engines']}  errors {len(x['errors'])}")
        print(f"   >50 {x['gt50']}  >200 {x['gt200']}  mean {x['mean']:.5f}  box4 median {x['median4']:.5f}"
              f"  PNG luma {x['png_luma']:.2f}")
        print(f"   md5 pfm {x['md5_pfm']}  png {x['md5_png']}")
        for l in x["probe"]:
            print(f"   {l}")
        print("   windows: " + "  ".join(f"{k} {v:.4f}" for k, v in x["win"].items()))
        print("   top10: " + "  ".join(f"({px},{py}) {v:.1f}" for px, py, v in x["top"]))

    for ref in ("R1", "R3"):
        print(f"\n== {ref}'s top 10, value in each run")
        for px, py, _ in s[ref]["top"]:
            print(f"   ({px:4d},{py:4d}) " + "  ".join(f"{r} {s[r]['lum'][py, px]:9.2f}" for r in RUNS))

    r1, r2, r3, r4, r5 = (s[r] for r in RUNS)
    v1 = r4["md5_pfm"] == r5["md5_pfm"] and r4["md5_png"] == r5["md5_png"]
    print(f"\nV1 off is exact: R4 vs R5 pfm {'==' if r4['md5_pfm'] == r5['md5_pfm'] else '!='}, "
          f"png {'==' if r4['md5_png'] == r5['md5_png'] else '!='} -> {'PASS' if v1 else 'FAIL (stop)'}"
          f"   [determinism control R1 vs R2: pfm {'==' if r1['md5_pfm'] == r2['md5_pfm'] else '!='}, "
          f"png {'==' if r1['md5_png'] == r2['md5_png'] else '!='}]")
    v2 = True
    for t in ("gt50", "gt200"):
        drop, spread = r1[t] - r3[t], abs(r1[t] - r2[t])
        ok = drop > spread
        v2 = v2 and ok
        print(f"V2 {t}: R1 {r1[t]} R2 {r2[t]} R3 {r3[t]}; drop {drop} vs R1-R2 spread {spread} -> "
              f"{'PASS' if ok else 'FAIL'}")
    dm, dmed = pct(r3["mean"], r1["mean"]), pct(r3["median4"], r1["median4"])
    v3 = abs(dm) <= 2.0 and abs(dmed) <= 2.0
    print(f"V3 no bias: R3 vs R1 mean {dm:+.2f}% box4 median {dmed:+.2f}% (control R2: "
          f"{pct(r2['mean'], r1['mean']):+.2f}% / {pct(r2['median4'], r1['median4']):+.2f}%) -> "
          f"{'PASS' if v3 else 'FAIL'}")
    v4 = True
    for k in windows:
        d = pct(r3["win"][k], r1["win"][k])
        ok = abs(d) <= 2.0
        v4 = v4 and ok
        print(f"V4 {k}: R1 {r1['win'][k]:.4f} R2 {r2['win'][k]:.4f} R3 {r3['win'][k]:.4f} -> {d:+.2f}% "
              f"{'PASS' if ok else 'FAIL'} (raw; PNG crops to be looked at)")

    os.makedirs(os.path.join(work, "crops"), exist_ok=True)
    for k, (x0, y0, x1, y1) in windows.items():
        a = r1["png"][y0:y1, x0:x1]
        b = r3["png"][y0:y1, x0:x1]
        gap = np.full((a.shape[0], 8, 3), 255.0, np.float32)
        Image.fromarray(np.concatenate([a, gap, b], axis=1).astype(np.uint8)).save(
            os.path.join(work, "crops", f"{k}_R1_vs_R3.png"))
    print(f"\nverdict: V1 {'PASS' if v1 else 'FAIL'}  V2 {'PASS' if v2 else 'FAIL'}  "
          f"V3 {'PASS' if v3 else 'FAIL'}  V4(raw) {'PASS' if v4 else 'FAIL'}")


if __name__ == "__main__":
    main()
```

Run `python -I measure_209.py <work_dir> | tee <work_dir>/measure.txt`. Then look at each `crops/*_R1_vs_R3.png` and judge whether the two look the same, and whether the sun disc is in any window.

If V1 fails, stop and report. Check R1 against R2 first: if R1 and R2 also differ, the machine is nondeterministic and V1 is inconclusive, and the report says so.

### Task 6: Results, and the owner's decision

**Files:**
- Modify: `docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md` (append `## Results 2026-10-14`)

- [ ] **Step 1: Append a short results section** containing:
  - the gate readings (pre-change, fault, new);
  - the R1-R5 table (>50, >200, mean, box4 median, exposure, PNG luma, time);
  - V1-V4, each with its numbers and PASS/FAIL against the fixed rule;
  - which top-10 spikes disappeared;
  - the window crop paths;
  - Review Focus items 1-2, as open facts for the ship decision.

- [ ] **Step 2: Commit the spec by path**

```bash
git add -- docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md
git commit -m "docs(spec): sky miss clamp -- gate readings and job 209 results" -- docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md
```

- [ ] **Step 3: Report to the owner and ask for the ship decision.** Nothing under `C:\Zlendo2026` changes.
