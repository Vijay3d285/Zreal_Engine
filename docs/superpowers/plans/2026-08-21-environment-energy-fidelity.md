# Environment Energy Fidelity (E2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an absolute sky-energy gate that determines, unambiguously, whether the ~23% environment dimming versus Cycles comes from a scalar (`IBL_exposure_normalization`) or from resolution loss in the borrowed raster IBL radiance map.

**Architecture:** Four probes added as one new GPU gate. Probe A checks sky radiance against its authored value with zero resolution sensitivity, isolating the scalar. Probe B checks a Lambertian plane's response against an irradiance integral computed in GDScript directly from the source panorama, giving absolute ground truth. Probe C re-runs Probe B at two `Sky.radiance_size` values, which proves or disproves resolution loss outright. Probe D reads `IBL_exposure_normalization` off the GPU through a new debug vis mode so its value is observed rather than inferred.

**Tech Stack:** Godot 4.7-beta fork, SCons/MSVC, GLSL (Vulkan RD raytracing pipeline), GDScript gates run headless against the editor binary.

## Scope of this plan

**This plan covers Task 1 of the spec's three tasks — the diagnostic gate — and nothing else.**

The spec's Task 2 (the fix) is deliberately mechanism-dependent, and the spec says so in §5.2: *"Determined by Task 1, and deliberately not pre-committed here. E1 shipped three defects that originated in a spec asserting an implementation before the evidence justified it."* Writing plan steps for a fix whose shape is unknown would mean inventing them, which is the failure this project has already paid for three times. Task 3 (re-baseline) cannot be written either, because the numbers it re-baselines do not exist yet.

**A second planning pass follows once this gate reports.** The decision rule that pass will use is in Task 5 below, stated in advance so the verdict is read off a rule rather than argued after the fact.

This plan still produces working, testable software on its own: a permanent, headless-runnable regression gate that closes a documented blind spot in the existing suite, valuable regardless of which way the verdict lands.

## Global Constraints

- **Never stage, commit, revert, check out over, or stash these six files.** They are the user's own uncommitted work: `pipeline_references/compositor_effect.gd`, `pipeline_references/image_glb_creation.gd`, `pipeline_references/render.gd`, `pipeline_references/structure.gd`, `pipeline_references/video_glb_creation.gd`, `pipeline_references/custom_shape.gd`. Use explicit paths with `git add`; never `git add -A` or `git add .`.
- **New files under `pipeline_references/tests/` ARE in scope** and should be committed. Only the six files above are protected.
- Build with `scons` on PATH at `C:\Users\aiadmin\AppData\Roaming\Python\Python310\Scripts`. Always pass `platform=windows`.
- **After touching any `.glsl`, run a full scons build** so `.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- Verify every claim about Cycles or about this codebase by **reading the file at implementation time**. Do not transcribe from this plan or from the spec into shipped code comments without re-reading the source. This is the practice E1's §3.2 erratum exists to enforce.
- Debug vis modes 0-33 are allocated. **34 is the next free.**
- `Environment.BG_COLOR` renders pure black to the path tracer (roadmap F3). Every scene here must use `BG_SKY` with a real `Sky` resource.
- Gate tolerance for absolute energy assertions: **2%**, per spec §8.2.

---

## File Structure

**Create:**
- `pipeline_references/tests/pt_sky_energy_gate.gd` — the gate. Owns all four probes, the analytic irradiance integrator, and the verdict printer. One file because the probes share the scene builder and panorama generators, and splitting them would duplicate that setup three ways.
- `pipeline_references/tests/pt_sky_energy_gate_scene.tscn` — three-line scene stub that hosts the script, matching `pt_energy_gate_scene.tscn` exactly in shape.

**Modify:**
- `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` — add vis mode 34 inside `debug_visualize()`.

**Not modified by this plan:** any C++, any other shader, any existing gate. If the gate finds a defect, fixing it belongs to the follow-up plan.

---

## Task 1: Vis mode 34 exposes `IBL_exposure_normalization`

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (inside `debug_visualize()`, after the `vis_mode == 33` branch)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: debug vis mode `34`. A gate selects it with `env.set_pathtracing_debug_mode(34)` and reads the value back in the **red channel** of the accumulated image at any pixel covering geometry. Green and blue are 0.

**Why a vis mode rather than reading it in GDScript:** `IBL_exposure_normalization` is computed C++-side into the scene-data UBO (`render_scene_data_rd.cpp:246-252`) and is not exposed to script at all. The only way to observe the value the shader actually multiplies by is to have the shader report it. Inferring it from a brightness ratio would assume the very thing the gate is testing.

- [ ] **Step 1: Read the existing vis-mode block to match its exact style**

Run: `sed -n '488,530p' servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`

You are looking for the `} else if (vis_mode == NN) {` chain and confirming that `ps.radiance` is assigned raw, unscaled values. The existing comment at mode 23 states why: *"Raw, unscaled values: the accumulation target is float, so nothing needs remapping and values above 1.0 survive readback intact."* Your new branch must follow that convention.

- [ ] **Step 2: Find the end of the `vis_mode == 33` branch**

Run: `grep -n "vis_mode == 33" servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`

Read from that line to the end of the `if/else if` chain so you insert the new branch at the correct closing point, not in the middle of mode 33's body.

- [ ] **Step 3: Add the mode 34 branch**

Insert immediately after the `vis_mode == 33` branch closes, keeping the `} else if (...) {` chain style and tab indentation used by the surrounding code:

```glsl
	} else if (vis_mode == 34) {
		// E2a probe D: the scalar this shader multiplies sky radiance by.
		//
		// env_sky_radiance() does `sky_color *= IBL_exposure_normalization`.
		// Cycles has no equivalent scalar, so if this is not 1.0 it is a direct
		// candidate for the ~23% environment dimming (roadmap 7.4).
		//
		// It is reported rather than inferred on purpose. Deriving it from a
		// brightness ratio would assume the rest of the sky path is correct,
		// which is exactly what the gate is testing -- the same circularity
		// the E1 closeout had to retract from roadmap 7.1's calibration
		// argument. Raw and unscaled, matching mode 23's convention.
		ps.radiance = vec3(scene_data_block.data.IBL_exposure_normalization, 0.0, 0.0);
```

- [ ] **Step 4: Full build so the `.glsl.gen.h` regenerates**

```bash
scons platform=windows target=editor tests=yes -j8
```

Expected: exit code 0. A GLSL syntax error surfaces here as a shader-compile failure during the build's header generation step. If `scons` is not found, prepend `C:\Users\aiadmin\AppData\Roaming\Python\Python310\Scripts` to PATH.

- [ ] **Step 5: Confirm the generated header picked up the change**

```bash
grep -c "vis_mode == 34" servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl.gen.h
```

Expected: a count of **1**. (Corrected 2026-08-21 during execution: this step originally predicted "2 or more", reasoning that `debug_visualize()` has both an HG0 and an `RT_CUSTOM_HIT_GROUP` call site. That is wrong — the two call sites *call* the function, they do not duplicate its body, so every vis mode including long-established ones such as 23 and 33 also greps to exactly 1. Verified against the built header.) A count of **0** means the build did not regenerate the header; re-run Step 4 without `-j8` and read the output.

- [ ] **Step 6: Confirm no existing test regressed**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
```

Expected: `1513 passed | 0 failed | 3 skipped`. This shader change cannot affect doctest (which never executes the shader), so any deviation means something else broke in the build.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): vis mode 34 reports IBL_exposure_normalization"
```

---

## Task 2: Probe A — constant sky, absolute

**Files:**
- Create: `pipeline_references/tests/pt_sky_energy_gate.gd`
- Create: `pipeline_references/tests/pt_sky_energy_gate_scene.tscn`

**Interfaces:**
- Consumes: vis mode `34` from Task 1. `PTValidation._render_accum(p_env: Environment, p_vp_rid: RID, p_frames: int) -> Image` from `pipeline_references/tests/pt_validation.gd:88`.
- Produces: `_measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary` returning keys `"r"`, `"g"`, `"b"`, `"mean"`, `"n"`. `_build_scene(p_panorama: ImageTexture, p_radiance_size: int) -> Environment`. `_failures: Array[String]`. `SKY_RADIANCE: float`. Tasks 3, 4 and 5 all use these.

**What this probe proves.** With a constant panorama, every camera ray misses geometry and lands in the miss shader, where `mis_ray_pdf` is the `RT_MIS_PDF_NONE` sentinel so the MIS weight is exactly 1. The rendered pixel is therefore `authored_radiance * IBL_exposure_normalization`, with no BSDF, no NEE and no integrator involved. **A constant sky is invariant to resolution**, so this probe cannot see Mechanism B and is a clean read on Mechanism A alone.

- [ ] **Step 1: Write the scene stub**

Create `pipeline_references/tests/pt_sky_energy_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_sky_energy_gate.gd" id="1_skygate"]

[node name="PTSkyEnergyGate" type="Node"]
script = ExtResource("1_skygate")
```

- [ ] **Step 2: Write the gate's header, constants and scene builder**

Create `pipeline_references/tests/pt_sky_energy_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## E2a GPU gate: ABSOLUTE sky energy, against the authored panorama.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_sky_energy_gate_scene.tscn
##
## WHY THIS EXISTS WHEN pt_energy_gate.gd ALREADY TESTS ENERGY.
##
## pt_energy_gate.gd Gate 1 is already an analytic furnace test -- constant sky,
## Lambertian plane, asserting L_o = rho * L to 1% -- and it passes. It proves
## the integrator is correct GIVEN whatever radiance the renderer sees.
##
## It cannot prove the renderer sees the right radiance. Its expected value is
## `ALBEDO * l_sky` where l_sky is measured FROM THE RENDER (pt_energy_gate.gd
## :206, :222), so any loss upstream of both the sky pass and the surface pass
## cancels exactly. Its own header says so: "The gate is a RATIO against this,
## so no global sky scale can fake a pass or a failure."
##
## A ~23% uniform environment dimming versus Cycles (roadmap 7.4) IS a global
## sky scale. That gate is blind to it by construction -- the same shape as all
## four defects E1 shipped through a green suite: an assertion that is correct
## but cannot fail in the direction that matters.
##
## Every assertion in THIS file compares against a value computed from the
## SOURCE PANORAMA, never from a render.
##
## Four probes:
##   A. Constant sky, sky-only. Invariant to resolution, so it reads the
##      scalar path alone (Mechanism A).
##   B. Peaked sky, Lambertian plane, against an irradiance integral computed
##      in GDScript from the panorama image (Mechanism B).
##   C. Probe B repeated at two Sky.radiance_size values. If the response moves
##      with resolution, energy is being lost in the radiance map -- proof, not
##      inference.
##   D. IBL_exposure_normalization read directly off the GPU via vis mode 34.

const SKY_RADIANCE := 0.5 # Authored constant radiance for probe A.
const ALBEDO := 0.5 # LINEAR reflectance of the probe plane.
const TOLERANCE := 0.02 # 2 percent, per spec section 8.
const FRAMES := 128

var _plane: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []
var _verdict: Dictionary = {}


func _build_scene(p_panorama: ImageTexture, p_radiance_size: int) -> Environment:
	for c in get_children():
		c.queue_free()

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = p_panorama
	sky_mat.energy_multiplier = 1.0

	var sky := Sky.new()
	sky.sky_material = sky_mat
	# QUALITY, not REALTIME: sky.cpp:593-595 force-clamps a REALTIME sky's
	# radiance map to REAL_TIME_SIZE (256, sky.h:248) and warns. Probe C needs
	# the size to actually take effect, so this must not be REALTIME.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = p_radiance_size

	var env := Environment.new()
	# BG_SKY with a real Sky resource is MANDATORY. BG_COLOR renders pure black
	# to the path tracer -- env_sky_radiance() reads radiance_octmap, which the
	# sky pass only populates for BG_SKY (roadmap F3).
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

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(200.0, 200.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO)
	mat.metallic = 0.0
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_plane = MeshInstance3D.new()
	_plane.mesh = plane_mesh
	_plane.material_override = mat
	add_child(_plane)

	get_viewport().world_3d.environment = env
	return env


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


func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


func _look_up() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(90.0, 0.0, 0.0)


func _look_down() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
```

- [ ] **Step 3: Add probe A and a minimal `_ready` that runs only probe A**

Append to `pt_sky_energy_gate.gd`:

```gdscript
func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated sweep would take
	# hours. Disable content scaling so the viewport follows the window.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	await _probe_a()

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - sky energy gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


## PROBE A -- constant sky, sky-only, absolute.
##
## The plane is hidden, so every camera ray misses and reaches the miss shader
## with mis_ray_pdf == RT_MIS_PDF_NONE, giving MIS weight exactly 1. The pixel
## is therefore authored_radiance * IBL_exposure_normalization, with no BSDF,
## no NEE and no integrator involved.
##
## A constant sky is invariant to RESOLUTION, so this probe is blind to
## Mechanism B by construction and reads Mechanism A alone. That is the point:
## it is the only probe here whose result has a single possible cause.
func _probe_a() -> void:
	var env := _build_scene(_constant_panorama(), Sky.RADIANCE_SIZE_256)
	_plane.visible = false
	_look_up()
	# The sky pass renders the radiance octmap and the env CDF is built from it;
	# both need a moment before the first measurement.
	await get_tree().create_timer(2.0).timeout

	print("\n=== PROBE A: constant sky, authored L = %.5f ===" % SKY_RADIANCE)
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 16)
	if img == null:
		_failures.append("probe A: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.25, 0.75)
	var ratio := s["mean"] / SKY_RADIANCE
	print("  authored  : %.5f" % SKY_RADIANCE)
	print("  measured  : %.5f  (R %.5f  G %.5f  B %.5f)" % [s["mean"], s["r"], s["g"], s["b"]])
	print("  ratio     : %.5f" % ratio)
	_verdict["a_ratio"] = ratio

	if absf(ratio - 1.0) > TOLERANCE:
		_failures.append("probe A: sky reads %.5f vs %.5f authored, ratio %.5f (limit %.0f%%)"
				% [s["mean"], SKY_RADIANCE, ratio, TOLERANCE * 100.0])
```

- [ ] **Step 4: Run probe A**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Expected: it runs to completion and prints a `ratio`. **Either outcome is a valid result — do not "fix" a failure here.** A ratio near 1.0 means the scalar path is clean and Mechanism A is out. A ratio near 0.772 means Mechanism A is very likely the whole defect. Record the number; it is the deliverable.

If instead the render is pure black, the sky is not reaching the path tracer at all — check that `background_mode` is `BG_SKY` and that `sky_material.panorama` was assigned before the `Sky` was attached.

- [ ] **Step 5: Commit**

```bash
git add pipeline_references/tests/pt_sky_energy_gate.gd pipeline_references/tests/pt_sky_energy_gate_scene.tscn
git commit -m "test(pt): E2a probe A - constant sky against authored radiance"
```

---

## Task 3: Probe B — analytic irradiance ground truth

**Files:**
- Modify: `pipeline_references/tests/pt_sky_energy_gate.gd`

**Interfaces:**
- Consumes: `_build_scene`, `_measure_crop`, `_look_down`, `_failures`, `ALBEDO`, `TOLERANCE`, `FRAMES` from Task 2.
- Produces: `_banded_panorama(p_bright_rows: int) -> ImageTexture`, `_analytic_outgoing_radiance(p_img: Image) -> float`, `_probe_b_at(p_radiance_size: int, p_label: String) -> float` returning the measured/analytic ratio. Task 4 calls `_probe_b_at` twice.

**The panorama is deliberately symmetric about the equator.** The engine's lat-long polar convention (whether `v = 0` is +Y or -Y) is not something this gate should have to assume — assuming it would be exactly the kind of unverified transcription that produced E1's F1. A panorama mirrored top-to-bottom makes the upward hemisphere's content identical either way, so the analytic integral is correct under **both** conventions and the gate tests energy rather than orientation.

**The bright band is one texel row of a 1024-tall panorama** — an angular width of `pi/1024`, far thinner than a 256-wide octmap texel. That is what makes Probe C's resolution comparison decisive.

- [ ] **Step 1: Write the panorama generator**

Append to `pt_sky_energy_gate.gd`:

```gdscript
const PANO_W := 2048
const PANO_H := 1024
const BAND_BASE := 0.02
const BAND_BRIGHT := 200.0


## A dim base with two narrow bright bands, mirrored about the equator.
##
## MIRRORED ON PURPOSE. This gate must not assume whether the engine's lat-long
## v = 0 is +Y or -Y. A top-bottom symmetric panorama presents identical content
## to the upward hemisphere under either convention, so _analytic_outgoing_radiance()
## is correct without the gate ever having to know -- and the probe measures
## ENERGY rather than accidentally testing orientation.
##
## Each band is p_bright_rows texel rows out of PANO_H, an angular width of
## p_bright_rows * PI / PANO_H. At the default of 1 row that is PI/1024, far
## thinner than a 256px octmap texel (PI/256 at best). A point sampler either
## hits it or misses it; an area average preserves it. That gap is what probe C
## measures.
func _banded_panorama(p_bright_rows: int) -> ImageTexture:
	var pano := Image.create(PANO_W, PANO_H, false, Image.FORMAT_RGBF)
	pano.fill(Color(BAND_BASE, BAND_BASE, BAND_BASE))
	var y_top := int(PANO_H * 0.25)
	var y_bot := PANO_H - 1 - y_top
	for i in range(p_bright_rows):
		for x in range(PANO_W):
			pano.set_pixel(x, y_top + i, Color(BAND_BRIGHT, BAND_BRIGHT, BAND_BRIGHT))
			pano.set_pixel(x, y_bot - i, Color(BAND_BRIGHT, BAND_BRIGHT, BAND_BRIGHT))
	return ImageTexture.create_from_image(pano)
```

- [ ] **Step 2: Write the analytic integrator**

Append to `pt_sky_energy_gate.gd`:

```gdscript
## Outgoing radiance of an upward-facing Lambertian patch of reflectance ALBEDO
## under the panorama, computed from the IMAGE -- never from a render.
##
##   E   = integral over upper hemisphere of L(w) cos(theta) dw
##   L_o = ALBEDO * E / PI
##
## The panorama is azimuthally uniform by construction, so the phi integral is
## just a factor of 2*PI and the sum runs over rows only:
##
##   E = sum over rows with theta < PI/2 of  L(row) * 2*PI * cos(theta) * sin(theta) * dtheta
##
## with dtheta = PI / PANO_H and theta measured from the pole at v = 0. Because
## the panorama is mirrored, whichever pole that is, the upper hemisphere sees
## the same values -- so summing the v < 0.5 half is correct either way.
func _analytic_outgoing_radiance(p_img: Image) -> float:
	var h := p_img.get_height()
	var d_theta := PI / float(h)
	var e := 0.0
	for y in range(h):
		var theta := (float(y) + 0.5) * d_theta
		if theta >= PI * 0.5:
			continue
		# Azimuthally uniform: one sample per row is exact.
		var c := p_img.get_pixel(0, y)
		var l := (c.r + c.g + c.b) / 3.0
		e += l * TAU * cos(theta) * sin(theta) * d_theta
	return ALBEDO * e / PI
```

- [ ] **Step 3: Write the probe body**

Append to `pt_sky_energy_gate.gd`:

```gdscript
## PROBE B -- peaked sky, Lambertian plane, against the analytic integral.
##
## Returns the measured/analytic ratio so probe C can compare two resolutions.
## A Lambertian plane integrates the whole upper hemisphere, so its response is
## proportional to the sky's INTEGRAL -- which is the energy quantity that a
## point-subsampled radiance map fails to preserve.
func _probe_b_at(p_radiance_size: int, p_label: String) -> float:
	var pano_tex := _banded_panorama(1)
	var env := _build_scene(pano_tex, p_radiance_size)
	_plane.visible = true
	_look_down()
	await get_tree().create_timer(2.0).timeout

	var analytic := _analytic_outgoing_radiance(pano_tex.get_image())

	print("\n=== PROBE B [%s]: banded sky, Lambertian albedo %.3f ===" % [p_label, ALBEDO])
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	if img == null:
		_failures.append("probe B [%s]: accumulator readback returned null" % p_label)
		return -1.0
	var s := _measure_crop(img, 0.25, 0.75)
	var ratio: float = s["mean"] / maxf(analytic, 1e-9)
	print("  analytic L_o : %.5f  (from the panorama image)" % analytic)
	print("  measured     : %.5f  (R %.5f  G %.5f  B %.5f)" % [s["mean"], s["r"], s["g"], s["b"]])
	print("  ratio        : %.5f" % ratio)
	return ratio
```

- [ ] **Step 4: Call probe B from `_ready`**

In `_ready`, replace the single `await _probe_a()` line with:

```gdscript
	await _probe_a()

	var b256: float = await _probe_b_at(Sky.RADIANCE_SIZE_256, "radiance 256")
	_verdict["b256"] = b256
	if b256 > 0.0 and absf(b256 - 1.0) > TOLERANCE:
		_failures.append("probe B (radiance 256): ratio %.5f vs 1.0 (limit %.0f%%)"
				% [b256, TOLERANCE * 100.0])
```

- [ ] **Step 5: Run and record**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Expected: probe A's number from Task 2 unchanged, plus a probe B ratio. **Again, a failure here is a result, not a bug to fix.** Record the ratio.

Sanity check before trusting it: `analytic L_o` should be a positive number of order `0.01`-`0.1`. If it prints `0.00000`, the row sampling picked the wrong half — confirm `_banded_panorama` actually wrote bright rows by checking `pano_tex.get_image().get_pixel(0, int(PANO_H * 0.25))`.

- [ ] **Step 6: Commit**

```bash
git add pipeline_references/tests/pt_sky_energy_gate.gd
git commit -m "test(pt): E2a probe B - Lambertian response vs analytic irradiance"
```

---

## Task 4: Probe C — the resolution sweep

**Files:**
- Modify: `pipeline_references/tests/pt_sky_energy_gate.gd`

**Interfaces:**
- Consumes: `_probe_b_at(p_radiance_size: int, p_label: String) -> float` from Task 3, `_verdict`, `_failures`.
- Produces: `_verdict["b2048"]`. Task 5 reads `_verdict["a_ratio"]`, `_verdict["b256"]`, `_verdict["b2048"]`, `_verdict["d_ibl"]`.

**This is the decisive probe.** Everything else is corroboration. The same panorama, the same geometry, the same integrator — only `Sky.radiance_size` differs. Physics does not depend on a texture size, so **any difference in the measured response is energy the radiance map lost.** No cross-renderer comparison and no analytic model is needed for this one; it is self-contained.

- [ ] **Step 1: Add the second resolution to `_ready`**

In `_ready`, immediately after the probe B block added in Task 3, insert:

```gdscript
	var b2048: float = await _probe_b_at(Sky.RADIANCE_SIZE_2048, "radiance 2048")
	_verdict["b2048"] = b2048
	if b2048 > 0.0 and absf(b2048 - 1.0) > TOLERANCE:
		_failures.append("probe B (radiance 2048): ratio %.5f vs 1.0 (limit %.0f%%)"
				% [b2048, TOLERANCE * 100.0])

	# PROBE C -- the resolution comparison itself.
	#
	# Same panorama, same geometry, same integrator; only Sky.radiance_size
	# differs. Physics does not depend on a texture size, so ANY difference here
	# is energy the radiance map lost. This is the one probe in the file that
	# needs neither an analytic model nor another renderer to be conclusive.
	if b256 > 0.0 and b2048 > 0.0:
		var res_delta: float = absf(b2048 - b256) / maxf(b256, 1e-9)
		print("\n=== PROBE C: resolution sensitivity ===")
		print("  ratio at 256  : %.5f" % b256)
		print("  ratio at 2048 : %.5f" % b2048)
		print("  relative shift: %.3f%%" % (res_delta * 100.0))
		_verdict["c_shift"] = res_delta
		if res_delta > TOLERANCE:
			_failures.append("probe C: response moved %.3f%% between radiance 256 and 2048 -- the radiance map is losing energy (Mechanism B)"
					% (res_delta * 100.0))
```

- [ ] **Step 2: Verify the radiance size actually took effect**

Run the gate and read stderr for the warning text from `sky.cpp:594`: `"Realtime Skies can only use a radiance size of"`. It must **not** appear. If it does, `sky.process_mode` is not `PROCESS_MODE_QUALITY` and probe C is comparing 256 against 256, which would silently produce a shift of 0% and a false "Mechanism B is out" verdict.

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn 2>&1 | grep -i "radiance size" || echo "OK: no clamp warning"
```

Expected: `OK: no clamp warning`.

- [ ] **Step 3: Run the full sweep and record all three numbers**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Record `a_ratio`, `b256`, `b2048` and the relative shift. These four numbers are this plan's actual deliverable.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/tests/pt_sky_energy_gate.gd
git commit -m "test(pt): E2a probe C - radiance-map resolution sensitivity"
```

---

## Task 5: Probe D, the verdict, and the roadmap entry

**Files:**
- Modify: `pipeline_references/tests/pt_sky_energy_gate.gd`
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: vis mode `34` from Task 1; `_verdict` keys `a_ratio`, `b256`, `b2048`, `c_shift` from Tasks 2-4.
- Produces: nothing downstream in this plan. The follow-up plan consumes the printed verdict.

- [ ] **Step 1: Add probe D**

Append to `pt_sky_energy_gate.gd`:

```gdscript
## PROBE D -- read IBL_exposure_normalization straight off the GPU.
##
## env_sky_radiance() multiplies sky radiance by this scalar
## (raytracing_closest_hit_common_inc.glsl:306). Cycles has no equivalent. Vis
## mode 34 reports it in the red channel at any pixel covering geometry, so the
## value is OBSERVED rather than inferred from a brightness ratio -- inferring
## it would assume the rest of the sky path is correct, which is what the gate
## is testing.
func _probe_d() -> void:
	var env := _build_scene(_constant_panorama(), Sky.RADIANCE_SIZE_256)
	_plane.visible = true
	_look_down()
	await get_tree().create_timer(2.0).timeout

	env.set_pathtracing_debug_mode(34)
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 4)
	env.set_pathtracing_debug_mode(0)
	if img == null:
		_failures.append("probe D: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.4, 0.6)
	print("\n=== PROBE D: IBL_exposure_normalization ===")
	print("  value : %.6f" % s["r"])
	_verdict["d_ibl"] = s["r"]
	if absf(s["r"] - 1.0) > TOLERANCE:
		_failures.append("probe D: IBL_exposure_normalization is %.6f, not 1.0 -- it scales sky radiance and Cycles has no counterpart (Mechanism A)"
				% s["r"])
```

- [ ] **Step 2: Add the verdict printer**

Append to `pt_sky_energy_gate.gd`:

```gdscript
## Reads the four numbers against a rule fixed BEFORE the measurement, so the
## conclusion is read off rather than argued for afterwards.
func _print_verdict() -> void:
	var a: float = _verdict.get("a_ratio", -1.0)
	var b256: float = _verdict.get("b256", -1.0)
	var b2048: float = _verdict.get("b2048", -1.0)
	var shift: float = _verdict.get("c_shift", -1.0)
	var ibl: float = _verdict.get("d_ibl", -1.0)

	print("\n=== VERDICT ===")
	print("  A constant-sky ratio        : %.5f" % a)
	print("  B ratio @ radiance 256      : %.5f" % b256)
	print("  B ratio @ radiance 2048     : %.5f" % b2048)
	print("  C resolution shift          : %.3f%%" % (shift * 100.0))
	print("  D IBL_exposure_normalization: %.6f" % ibl)

	var a_off := absf(a - 1.0) > TOLERANCE
	var res_sensitive := shift > TOLERANCE

	if a_off and not res_sensitive:
		print("  -> MECHANISM A. A scalar dims the sky at every peakedness and the")
		print("     response does not move with resolution. Probe D names the value.")
	elif res_sensitive:
		print("  -> MECHANISM B. The response moves with radiance-map resolution, so")
		print("     energy is lost in the map. The fix is to stop borrowing the raster")
		print("     IBL map and sample the panorama directly (spec 5.2).")
	elif not a_off and not res_sensitive and absf(b256 - 1.0) <= TOLERANCE:
		print("  -> NEITHER. Both engine-side mechanisms are clean, so the 23%% is a")
		print("     measurement artefact in the Cycles-side setup (colour management,")
		print("     or gen_panorama.py's own scaling). Spec 8.7: correct roadmap 7.4")
		print("     and make NO engine change.")
	else:
		print("  -> INCONCLUSIVE. Probe B is off while A is clean and resolution does")
		print("     not matter, which fits no modelled mechanism. Do not guess a fix;")
		print("     widen the sweep before changing any engine code.")
```

- [ ] **Step 3: Wire probe D and the verdict into `_ready`**

In `_ready`, immediately before the `print("\n=== RESULT ===")` line, insert:

```gdscript
	await _probe_d()
	_print_verdict()
```

- [ ] **Step 4: Run the complete gate**

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_sky_energy_gate_scene.tscn
```

Expected: all four probes report, and exactly one verdict line prints. If the verdict is `INCONCLUSIVE`, **stop and report** — do not proceed to a fix.

- [ ] **Step 5: Confirm the existing suite is untouched**

```bash
bin/godot.windows.editor.x86_64.console.exe --headless --test
```

Expected: `1513 passed | 0 failed | 3 skipped`.

```bash
bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_energy_gate_scene.tscn
```

Expected: `PASS - all energy gates green.` This plan adds a gate and one vis mode; nothing it does should move an existing gate. If `pt_energy_gate` fails here, something in Task 1's shader edit was wrong.

- [ ] **Step 6: Record the finding in the roadmap**

Add a subsection `### 7.6 E2a - environment energy: measured verdict` to `PATH_TRACER_QUALITY_ROADMAP.md`, immediately after §7.5. Write the four measured numbers into a table, state which mechanism the verdict rule selected, and add one sentence recording that `pt_energy_gate` Gate 1 is a ratio and was structurally blind to this defect — so the next person does not read its green status as covering sky energy.

Amend §7.4's "Root cause not chased" paragraph to point at §7.6 rather than leaving the two candidate causes open.

- [ ] **Step 7: Commit**

```bash
git add pipeline_references/tests/pt_sky_energy_gate.gd PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "test(pt): E2a probe D and verdict; record measured finding"
```

---

## After this plan

Report the four numbers and the verdict. **Do not begin a fix.** The follow-up plan for the spec's Tasks 2 and 3 is written against the verdict, per spec §5.2.

The decision rule is the one encoded in `_print_verdict()` above, and it was fixed before any measurement was taken. That ordering is deliberate: roadmap §7.1 had to retract a circular calibration argument in the E1 fix wave, and a rule written after seeing the numbers is how that happens.
