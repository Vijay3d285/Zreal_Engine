# Phase F2 — Volumetrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Environment's volumetric fog becomes a bounded homogeneous medium in the path tracer — Cycles' single-scatter default on the scene's own bounding box — so the pipeline's day haze reaches the traced frame.

**Architecture:** Raygen draws the free-flight distance before each trace and bounds the trace by it (analog tracking on a grey-extinction medium); a miss inside that bound is a scatter event, shaded in raygen by the existing analytic-light NEE (phase function in place of the BRDF) plus sky NEE, then terminated (volume bounces 0). Every shadow ray pays `exp(-σt · length inside the box)`. The box is the union of the TLAS instances' AABBs; the medium's parameters ride in the params UBO, which grows from 4 to 10 `vec4`s; the whole path is compiled out under a new specialisation-constant flag so every existing render is bit-identical.

**Tech Stack:** GLSL (Vulkan RT, ray queries), C++ (Godot RD), GDScript gate, Blender 5.2.1 Python.

**Spec:** `docs/superpowers/specs/2026-09-17-volumetrics-design.md`

## Global Constraints

- Build: `python -m SCons platform=windows target=editor tests=yes -j8`. Every `.glsl` edit needs a full build; a clean build proves nothing about GLSL — only a render does.
- Gates run only in a **connected desktop session** (`query session` shows the user's RDP session `Active`).
- Gate command: `bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/<name>_scene.tscn` — the `.tscn` suffix is mandatory.
- `pipeline_references/*.gd` at the top level are the user's files: never stage, commit, revert or checkout over them. `pipeline_references/tests/` is this workstream's.
- `git add` with explicit paths only. Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Scratch files and render outputs go to the scratchpad directory (`$S` below), never into the repo or the live project.
- Patch scripts are written with the Write tool, never through a bash heredoc (heredocs eat backslashes); chain with `&&` so a failed patch never lets a build or gate run.
- Colour properties on `StandardMaterial3D` / `Environment` are sRGB-encoded: a linear albedo `a` is authored as `Color(a,a,a).linear_to_srgb()`. `PanoramaSkyMaterial` fed an RGBF image is linear.
- The fog box is the union of ALL geometry: every gate fixture pins it with eight 1 cm black corner posts and places every surface on a face of that box.
- Before bisecting any gate regression, run the same gate on `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\godot.windows.editor.x86_64.console.exe` (the previous hand-over binary).
- Blender: `"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P <script> -- <out_dir>`.
- Coordinates: Godot `(x, y, z)` → Blender `(x, -z, y)`; a Godot `DirectionalLight3D` with `rotation_degrees = (-90, 0, 0)` points straight down, as does a Blender Sun with `rotation_euler = (0, 0, 0)`.

---

## File map

| File | Responsibility |
|---|---|
| `tools/cycles_comparison/cycles_volume_box.py` | **Create.** Cycles half: the 2 m box fixture with a Volume Scatter cube, arms V3 (sun) and V4 (sky); prints `@@@` lines. |
| `pipeline_references/tests/pt_volume_gate.gd` + `_scene.tscn` | **Create.** Probes V1–V6. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_volume_inc.glsl` | **Create.** `volume_box_clip`, `volume_transmittance_along`, `phaseHenyeyGreenstein`, `volume_sigma_t/albedo/emission/g` accessors. Included after `raytracing_common_inc.glsl` in every stage that needs it. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | **Modify.** `RT_PARAM_VOLUME_*` indices, `RT_FLAG_VOLUME_ENABLED`, `RT_PRNG_VOLUME`, `RT_RAY_TMAX`, `RT_MIS_PDF_VOLUME_SCATTER`, `RT_PHASE_SURFACE`. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl` | **Modify.** `rt_params[4]` → `rt_params[10]`. |
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | **Modify.** `MaterialProperties.phaseG`. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` | **Modify.** Shadow-ray volume transmittance; volume mode at the three NEE evaluation sites. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | **Modify.** `phaseG = RT_PHASE_SURFACE` at the six `MaterialProperties` construction sites; env-NEE shadow ray already goes through the helper. |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | **Modify.** Free flight + emission in `trace_one_sample`; scatter sentinel + guides in the miss stage; `volume_scatter_shade` in raygen with the light/geometry/material declarations. |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h/.cpp` | **Modify.** `RT_FLAG_VOLUME_ENABLED = (1 << 20)`, `RT_PARAM_VOLUME_*` constants, `compute_rt_flags(..., bool p_volume_enabled)`. |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h/.cpp` | **Modify.** `RTViewportState::volume_box`; box union in `build_tlas`; UBO `params[40]` + volume fields. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` | **Modify.** Pass the volume-enabled bool to `compute_rt_flags`. |
| `servers/rendering/rendering_server_enums.h` | **Modify** only if `PT_PARAM_*` indices 16+ must be visible there (they are shader-side only; see Task 2). |
| `PATH_TRACER_QUALITY_ROADMAP.md` | **Modify.** Row 16 closed, F2 done, §11.30 closeout. |

---

### Task 1: The gate and its Cycles half (red on the current binary)

**Files:**
- Create: `tools/cycles_comparison/cycles_volume_box.py`
- Create: `pipeline_references/tests/pt_volume_gate.gd`, `pipeline_references/tests/pt_volume_gate_scene.tscn`

**Interfaces:**
- Produces: constants `CYCLES_V3_RATIO`, `CYCLES_V4` (from the script), bars `TOL_ANALYTIC = 0.01`, `BAR_CYCLES = 0.03`; probe names `V1 absorption`, `V2 emission`, `V3 sun beam vs Cycles`, `V4 sky haze vs Cycles`, `V5 surface shadowing`.
- Consumes: `pt_validation.gd` `_render_accum(env, vp_rid, frames) -> Image`.

The fixture (both engines): box `[-1,1] × [0,2] × [-1,1]` (Godot) pinned by eight 1 cm black cubes at its corners; a 2 × 2 floor quad at `y = 0` facing up; for V1 a 2 × 2 emissive quad at `z = -1` facing `+z`; camera at `(0, 1, 4)` looking at `(0, 1, 0)`, vertical FOV 30° (frame height at the box's front face, 3 m away: 1.6 m — the box's 2 m height overfills; at the back face, 5 m: 2.68 m — the emissive quad at the back fills the centre). Crops: **fog** = rows 10–40 %, cols 30–70 % (haze against black, above the floor's horizon); **floor** = rows 65–90 %, cols 30–70 %; **back** (V1) = rows 40–60 %, cols 40–60 %.

- [ ] **Step 1: Cycles script**

```python
# Homogeneous fog box against Cycles -- the pt_volume_gate stimulus
# (spec 2026-09-17-volumetrics-design.md, roadmap F2 / Gap #16).
#
# Godot (x, y, z) -> Blender (x, -z, y). The box [-1,1] x [0,2] x [-1,1]
# (Godot) is Blender [-1,1] x [-1,1] x [0,2]. Eight 1 cm black cubes pin the
# corners (they exist so the Godot side's automatic box is this box), a 2 m
# cube object carries the Volume Scatter shader, a 2 x 2 floor at z = 0.
# Camera at Blender (0, -4, 1) looking +Y, 30 deg vertical FOV, 256 x 256.
#
#   V3: albedo 1, sigma_t 0.3, g 0.8, Sun straight down (strength 3), black
#       world; prints fog crop mean, floor crop mean, and their ratio.
#   V4: albedo 1, sigma_t 0.3, g 0.0, uniform world 1.0, black floor; prints
#       the fog crop mean.
#   volume_bounces = 0 (Cycles' default: single scattering), volume sampling
#   Distance, 1024 spp.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_volume_box.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "1024"))
SUN_STRENGTH = 3.0


def mat_surface(name, albedo):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Specular IOR Level"].default_value = 0.0
    return m


def mat_volume(sigma_t, albedo, g):
    m = bpy.data.materials.new("fog")
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    vs = nt.nodes.new("ShaderNodeVolumeScatter")
    vs.inputs["Color"].default_value = (albedo, albedo, albedo, 1.0)
    vs.inputs["Density"].default_value = sigma_t
    vs.inputs["Anisotropy"].default_value = g
    nt.links.new(vs.outputs["Volume"], out.inputs["Volume"])
    m.cycles.volume_sampling = "DISTANCE"
    m.cycles.homogeneous_volume = True
    return m


def build(sigma_t, albedo, g, sun, world_strength, floor_albedo):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 4
    scene.cycles.glossy_bounces = 4
    scene.cycles.volume_bounces = 0
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = world_strength

    black = mat_surface("black", 0.0)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            for sz in (0.0, 2.0):
                bpy.ops.mesh.primitive_cube_add(size=0.01, location=(sx, sy, sz))
                bpy.context.object.data.materials.append(black)

    bpy.ops.mesh.primitive_plane_add(size=2.0, location=(0.0, 0.0, 0.0))
    floor = bpy.context.object
    floor.data.materials.append(mat_surface("floor", floor_albedo))

    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(0.0, 0.0, 1.0))
    fog = bpy.context.object
    fog.name = "fog"
    fog.data.materials.append(mat_volume(sigma_t, albedo, g))

    if sun:
        sd = bpy.data.lights.new("Sun", "SUN")
        sd.energy = SUN_STRENGTH
        sd.angle = 0.0
        so = bpy.data.objects.new("Sun", sd)
        scene.collection.objects.link(so)
        so.rotation_euler = (0.0, 0.0, 0.0)  # points down -Z

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(30.0)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, -4.0, 1.0)
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)  # looks +Y


def crop_mean(path, fy0, fy1, fx0, fx1):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    acc, n = 0.0, 0
    # Blender rows are bottom-up; the gate's fractions are from the top.
    for y in range(int((1.0 - fy1) * h), int((1.0 - fy0) * h)):
        for x in range(int(fx0 * w), int(fx1 * w)):
            i = (y * w + x) * 4
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return acc / n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ VOLUME BOX vs Cycles @@@")
print("@@@ blender: %s  samples %d  volume_bounces 0" % (bpy.app.version_string, SAMPLES))

build(0.3, 1.0, 0.8, True, 0.0, 1.0)
p = os.path.join(OUT, "volume_v3.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
fog3 = crop_mean(p, 0.10, 0.40, 0.30, 0.70)
floor3 = crop_mean(p, 0.65, 0.90, 0.30, 0.70)
print("@@@ V3 fog %.6f floor %.6f ratio %.6f" % (fog3, floor3, fog3 / max(floor3, 1e-9)))

build(0.3, 1.0, 0.0, False, 1.0, 0.0)
p = os.path.join(OUT, "volume_v4.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
fog4 = crop_mean(p, 0.10, 0.40, 0.30, 0.70)
print("@@@ V4 fog %.6f" % fog4)
print("@@@ DONE")
```

- [ ] **Step 2: Run it, record the two numbers**

```bash
mkdir -p "$S/vol" && "/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b -P tools/cycles_comparison/cycles_volume_box.py -- "$S/vol" 2>&1 | grep "@@@"
```

Sanity: V4 must be below 1.0 (single scattering under a unit sky through 2 m of σt 0.3 loses energy) and above 0.2; V3's ratio is positive. If Blender complains that `homogeneous_volume` does not exist on `m.cycles`, delete that line (it is an optimisation hint only) and re-run.

- [ ] **Step 3: The gate**

`pipeline_references/tests/pt_volume_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_volume_gate.gd" id="1_gate"]

[node name="PTVolumeGate" type="Node"]
script = ExtResource("1_gate")
```

`pipeline_references/tests/pt_volume_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Volumetrics gate (spec 2026-09-17-volumetrics-design.md, roadmap F2 / Gap #16).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_volume_gate_scene.tscn
##
## The Environment's volumetric fog is a bounded homogeneous medium in the
## tracer: sigma_t = density per metre, sigma_s = density * albedo, g =
## anisotropy, on the scene's own bounding box, Cycles' single-scatter default.
## The box is the union of ALL geometry, so every fixture pins it to
## [-1,1] x [0,2] x [-1,1] with eight 1 cm black corner posts and keeps every
## surface on a face of that box. Camera at (0, 1, 4) looking at (0, 1, 0).
## Cycles half: tools/cycles_comparison/cycles_volume_box.py.
##
##   V1 absorption : albedo 0, sigma_t 0.5, white emissive back wall, black
##                   world -> back crop with fog / without = exp(-1) (2 m of box)
##   V2 emission   : albedo 0, sigma_t 0.5, emission 1 energy 1, black world,
##                   black floor -> fog crop = E (1 - e^-1) / sigma_t = 1.2642
##   V3 sun beam   : albedo 1, sigma_t 0.3, g 0.8, sun straight down, black
##                   world, white floor -> fog crop / floor crop vs Cycles
##   V4 sky haze   : albedo 1, sigma_t 0.3, g 0, uniform world 1, black floor
##                   -> fog crop vs Cycles
##   V5 shadowing  : albedo 0, sigma_t 0.5, sun straight down, white floor ->
##                   floor with fog / without = exp(-1) (every shadow ray climbs 2 m)
##   V6 (implicit) : fog off is compiled out -- pt_energy_gate and
##                   pt_light_energy_gate are unchanged to the digit.

var FRAMES: int = 256 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const TOL_ANALYTIC := 0.01
const BAR_CYCLES := 0.03
# Cycles 5.2.1, cycles_volume_box.py, 1024 spp, captured 2026-09-17 (Task 1 Step 2).
const CYCLES_V3_RATIO := 0.0 # <- fill from the @@@ V3 line
const CYCLES_V4 := 0.0 # <- fill from the @@@ V4 line

var _failures: Array[String] = []
var _checks: int = 0


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

	print("\n=== V1: absorption, emissive back wall ===")
	var v1_off := await _render({"fog": false, "back_wall": true, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v1_on := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "back_wall": true, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v1 := _crop(v1_on, 0.40, 0.60, 0.40, 0.60) / maxf(_crop(v1_off, 0.40, 0.60, 0.40, 0.60), 1e-9)
	_check("V1 absorption", v1, exp(-1.0), TOL_ANALYTIC)

	print("\n=== V2: emission ===")
	var v2_img := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "emission": 1.0, "floor_albedo": 0.0, "world": 0.0, "sun": false})
	var v2 := _crop(v2_img, 0.10, 0.40, 0.30, 0.70)
	_check("V2 emission", v2, (1.0 - exp(-1.0)) / 0.5, TOL_ANALYTIC)

	print("\n=== V3: sun beam vs Cycles ===")
	var v3_img := await _render({"fog": true, "density": 0.3, "albedo": 1.0, "g": 0.8, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v3 := _crop(v3_img, 0.10, 0.40, 0.30, 0.70) / maxf(_crop(v3_img, 0.65, 0.90, 0.30, 0.70), 1e-9)
	_check_vs("V3 sun beam vs Cycles", v3, CYCLES_V3_RATIO, BAR_CYCLES)

	print("\n=== V4: sky haze vs Cycles ===")
	var v4_img := await _render({"fog": true, "density": 0.3, "albedo": 1.0, "g": 0.0, "floor_albedo": 0.0, "world": 1.0, "sun": false})
	var v4 := _crop(v4_img, 0.10, 0.40, 0.30, 0.70)
	_check_vs("V4 sky haze vs Cycles", v4, CYCLES_V4, BAR_CYCLES)

	print("\n=== V5: surface shadowing through the box ===")
	var v5_off := await _render({"fog": false, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v5_on := await _render({"fog": true, "density": 0.5, "albedo": 0.0, "g": 0.0, "floor_albedo": 1.0, "world": 0.0, "sun": true})
	var v5 := _crop(v5_on, 0.65, 0.90, 0.30, 0.70) / maxf(_crop(v5_off, 0.65, 0.90, 0.30, 0.70), 1e-9)
	_check("V5 surface shadowing", v5, exp(-1.0), TOL_ANALYTIC)

	print("")
	if _failures.is_empty():
		print("PASS: all %d volume checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs analytic %.6f (%+.2f%%, tol %.0f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs analytic %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_vs(p_name: String, p_value: float, p_ref: float, p_bar: float) -> void:
	_checks += 1
	if p_ref <= 0.0:
		_failures.append("%s: Cycles reference not captured (constant is %.6f)" % [p_name, p_ref])
		return
	var err := absf(p_value - p_ref) / p_ref
	print("  %s: %.6f vs Cycles %.6f  (%+.2f%%, bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * (p_value / p_ref - 1.0), 100.0 * p_bar])
	if err > p_bar:
		_failures.append("%s: %.6f vs Cycles %.6f, %.2f%% off (bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * err, 100.0 * p_bar])


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


## Builds the box fixture from a dictionary of options and returns the
## accumulated frame. Keys: fog (bool), density, albedo, g, emission,
## back_wall (bool), floor_albedo, world (uniform sky radiance), sun (bool).
func _render(p: Dictionary) -> Image:
	await _clear()
	var black := _lambert(0.0)
	for sx in [-1.0, 1.0]:
		for sy in [0.0, 2.0]:
			for sz in [-1.0, 1.0]:
				var post := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.01, 0.01, 0.01)
				post.mesh = bm
				post.position = Vector3(sx, sy, sz)
				post.material_override = black
				add_child(post)

	var floor_mi := MeshInstance3D.new()
	var fq := QuadMesh.new()
	fq.size = Vector2(2.0, 2.0)
	floor_mi.mesh = fq
	floor_mi.material_override = _lambert(float(p.get("floor_albedo", 0.0)))
	floor_mi.position = Vector3(0.0, 0.0, 0.0)
	floor_mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # QuadMesh faces +Z; turn it to face +Y
	add_child(floor_mi)

	if p.get("back_wall", false):
		var wall := MeshInstance3D.new()
		var wq := QuadMesh.new()
		wq.size = Vector2(2.0, 2.0)
		wall.mesh = wq
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0, 0, 0)
		wm.emission_enabled = true
		wm.emission = Color(1, 1, 1)
		wm.emission_energy_multiplier = 1.0
		wm.roughness = 1.0
		wm.metallic_specular = 0.0
		wall.material_override = wm
		wall.position = Vector3(0.0, 1.0, -1.0) # faces +Z, toward the camera
		add_child(wall)

	if p.get("sun", false):
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		sun.light_energy = 1.0
		sun.light_angular_distance = 0.0
		sun.shadow_enabled = true
		add_child(sun)

	var cam := Camera3D.new()
	cam.fov = 30.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.0, 4.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(float(p.get("world", 0.0)))
	env.set_pathtracing_max_bounces(4)
	env.volumetric_fog_enabled = bool(p.get("fog", false))
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = float(p.get("density", 0.0))
		var a := float(p.get("albedo", 0.0))
		env.volumetric_fog_albedo = Color(a, a, a).linear_to_srgb()
		env.volumetric_fog_anisotropy = float(p.get("g", 0.0))
		var e := float(p.get("emission", 0.0))
		env.volumetric_fog_emission = Color(e, e, e).linear_to_srgb()
		env.volumetric_fog_emission_energy = 1.0
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)


func _crop(p_img: Image, fy0: float, fy1: float, fx0: float, fx1: float) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * fy0), int(h * fy1)):
		for x in range(int(w * fx0), int(w * fx1)):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))


func _new_env_sky(p_radiance: float) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(Color(p_radiance, p_radiance, p_radiance))
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
```

Fill `CYCLES_V3_RATIO` / `CYCLES_V4` from Step 2. Note: `volumetric_fog_albedo` and `volumetric_fog_emission` are `Color` properties and therefore sRGB-encoded like every other; the engine reads them through `environment_get_volumetric_fog_scattering/emission` as stored, so Task 2 converts with `srgb_to_linear()` exactly as the raster path does — check `RendererRD::Fog` (`fog.cpp`, search `volumetric_fog_scattering`) for the raster's conversion and mirror it; if the raster does NOT convert, the gate must author the colours raw. Settle this in Task 2 Step 1 and adjust the gate's two `linear_to_srgb()` calls accordingly, recording the finding in the gate header.

- [ ] **Step 4: Run on the current binary — everything red for the right reason**

```bash
query session && bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_volume_gate_scene.tscn 2>&1 | grep -E "^  V|^PASS|^FAIL"
```

Expected: V1 ≈ 1.0 (no absorption), V2 0.0, V3 0.0 (no in-scatter), V4 0.0, V5 ≈ 1.0. All five red.

- [ ] **Step 5: Commit**

```bash
git add tools/cycles_comparison/cycles_volume_box.py pipeline_references/tests/pt_volume_gate.gd pipeline_references/tests/pt_volume_gate_scene.tscn
git commit -m "test(pt): pt_volume_gate + Cycles half -- all five red on the current binary (V1 <r>, V2 0, V3 0, V4 0, V5 <r>; Cycles V3 ratio <n>, V4 <n>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Parameters, flag, box, shadow-ray transmittance (V5 green)

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (defines), `raytracing_common_inc.glsl:114` (UBO), `raytracing_lights_inc.glsl:291` (shadow helper)
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_volume_inc.glsl`
- Modify: `scene_shader_raytracing.h` (flag, param constants, `compute_rt_flags` signature), `scene_shader_raytracing.cpp:649`, `render_forward_clustered.cpp:2505`, `render_raytracing.h:400` (`RTViewportState`), `render_raytracing.cpp` (`build_tlas` union at `:2858`; UBO at `:4155-4180`)
- Modify: `scene_raytracing_raygen.glsl` — include the new file in every stage after `raytracing_common_inc.glsl`

**Interfaces:**
- Produces (GLSL): `RT_FLAG_VOLUME_ENABLED (1u << 20)`; `RT_RAY_TMAX 10000.0`; `RT_PARAM_VOLUME_SIGMA_T 16`, `RT_PARAM_VOLUME_G 17`, `RT_PARAM_VOLUME_ALBEDO_R 20` (G 21, B 22), `RT_PARAM_VOLUME_EMISSION_R 24` (25, 26), `RT_PARAM_VOLUME_BOX_MIN_X 28` (29, 30), `RT_PARAM_VOLUME_BOX_MAX_X 32` (33, 34); `RT_PRNG_VOLUME 12u`; `RT_MIS_PDF_VOLUME_SCATTER -3.0`; `RT_PHASE_SURFACE -2.0`. Functions: `bool volume_active()`, `float volume_sigma_t()`, `vec3 volume_albedo()`, `vec3 volume_emission()`, `float volume_g()`, `bool volume_box_clip(vec3 o, vec3 d, float t0, float t1, out float t_in, out float t_out)`, `float volume_segment_length(vec3 o, vec3 d, float t0, float t1)`, `vec3 volume_transmittance_along(vec3 o, vec3 d, float t0, float t1)`, `float phaseHenyeyGreenstein(float cos_theta, float g)`.
- Produces (C++): `SceneShaderRaytracing::RT_FLAG_VOLUME_ENABLED = (1 << 20)`, `RT_PARAM_VOLUME_*` matching the GLSL indices, `compute_rt_flags(const float *p_env_params, bool p_fog_enabled, bool p_volume_enabled)`, `RTViewportState::volume_box` (`AABB`) and `volume_box_valid` (`bool`).

- [ ] **Step 1: Settle the colour-space question**

```bash
grep -n "volumetric_fog_scattering\|volumetric_fog_emission\|srgb_to_linear\|base_scattering\|base_emission" servers/rendering/renderer_rd/environment/fog.cpp | head
```

If the raster multiplies `environment_get_volumetric_fog_scattering()` through `srgb_to_linear()` (or via `Color::to_linear`), the tracer does the same and the gate keeps `linear_to_srgb()`; if it uses the Color raw, remove the two `linear_to_srgb()` calls in the gate's `_render` and note "raw" in the gate header. Record the answer in the commit message.

- [ ] **Step 2: GLSL defines**

In `raytracing_inc.glsl`, after `#define RT_PARAM_FRAME_INDEX 15 ...`:

```glsl
// F2 volumetrics (roadmap Gap #16). rt_params grew from 4 to 10 vec4s; these
// live in the second block. All linear, energy applied on the CPU.
#define RT_PARAM_VOLUME_SIGMA_T 16 // rt_params[4].x - extinction per metre (Environment.volumetric_fog_density)
#define RT_PARAM_VOLUME_G 17 // rt_params[4].y - Henyey-Greenstein anisotropy
#define RT_PARAM_VOLUME_ALBEDO_R 20 // rt_params[5].xyz - single-scattering albedo
#define RT_PARAM_VOLUME_EMISSION_R 24 // rt_params[6].xyz - emission per metre, already x energy x density
#define RT_PARAM_VOLUME_BOX_MIN_X 28 // rt_params[7].xyz - world-space box (the scene's AABB, padded 1 cm)
#define RT_PARAM_VOLUME_BOX_MAX_X 32 // rt_params[8].xyz
```

Next to the `RT_FLAG_*` shader defines (find `#define RT_FLAG_SSS_ENABLED`):

```glsl
#define RT_FLAG_VOLUME_ENABLED (1u << 20) // F2: Environment volumetric fog on, density > 0
```

Next to `RT_PRNG_TRANSMIT 11u`:

```glsl
#define RT_PRNG_VOLUME 12u // 1D: free-flight distance through the fog box (F2).
```

Next to `const float RT_MIS_PDF_NONE = -1.0;`:

```glsl
// F2: the miss stage marks a bounded trace that ended inside the fog box (a
// scatter event) with this sentinel in mis_ray_pdf; raygen shades it.
const float RT_MIS_PDF_VOLUME_SCATTER = -3.0;
// F2: MaterialProperties.phaseG below this means "a surface" -- the NEE sites
// evaluate the BRDF. Above it, the value IS the Henyey-Greenstein g and the
// sites evaluate the phase function instead.
const float RT_PHASE_SURFACE = -2.0;
// The unbounded ray length. Was a bare 10000.0 at every trace and in the miss
// stage's far-point; F2 needs to compare a ray's tmax against it.
const float RT_RAY_TMAX = 10000.0;
```

Replace every `10000.0` in `scene_raytracing_raygen.glsl` (the two `traceRayEXT` / `hitObjectTraceRayEXT` calls and `far_world`) and the env shadow ray in `raytracing_closest_hit_common_inc.glsl` (`lights_trace_shadow_ray(env_origin, env_dir, 10000.0)`) with `RT_RAY_TMAX`.

In `raytracing_common_inc.glsl` change `vec4 rt_params[4];` to `vec4 rt_params[10];`.

- [ ] **Step 3: The volume include**

Create `raytracing_volume_inc.glsl`:

```glsl
// F2 volumetrics (roadmap Gap #16): one bounded homogeneous medium -- the
// Environment's volumetric fog on the scene's bounding box -- shaded the way
// Cycles shades a cube with a Volume Scatter shader at its default
// volume_bounces = 0 (single scattering). See
// docs/superpowers/specs/2026-09-17-volumetrics-design.md.
//
// Requires raytracing_inc.glsl and raytracing_common_inc.glsl (rt_params).
// Everything here is gated on RT_FLAG_VOLUME_ENABLED, a specialisation
// constant: with the fog off every call folds to its no-op branch and the
// render is bit-identical to a build without this file.

bool volume_active() {
	return (RT_FLAGS & RT_FLAG_VOLUME_ENABLED) != 0u;
}

float volume_sigma_t() {
	return get_rt_param(RT_PARAM_VOLUME_SIGMA_T);
}

float volume_g() {
	return get_rt_param(RT_PARAM_VOLUME_G);
}

vec3 volume_albedo() {
	return vec3(get_rt_param(RT_PARAM_VOLUME_ALBEDO_R), get_rt_param(RT_PARAM_VOLUME_ALBEDO_R + 1u), get_rt_param(RT_PARAM_VOLUME_ALBEDO_R + 2u));
}

vec3 volume_emission() {
	return vec3(get_rt_param(RT_PARAM_VOLUME_EMISSION_R), get_rt_param(RT_PARAM_VOLUME_EMISSION_R + 1u), get_rt_param(RT_PARAM_VOLUME_EMISSION_R + 2u));
}

/// Slab test of the ray o + t d against the fog box, clipped to [t0, t1].
/// Returns false when the clipped interval is empty.
bool volume_box_clip(vec3 o, vec3 d, float t0, float t1, out float t_in, out float t_out) {
	vec3 bmin = vec3(get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X), get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X + 1u), get_rt_param(RT_PARAM_VOLUME_BOX_MIN_X + 2u));
	vec3 bmax = vec3(get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X), get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X + 1u), get_rt_param(RT_PARAM_VOLUME_BOX_MAX_X + 2u));
	// 1/d with the sign kept on zero components: a ray parallel to a slab is
	// inside it iff the origin is, which the +-inf arithmetic below yields.
	vec3 inv_d = 1.0 / d;
	vec3 ta = (bmin - o) * inv_d;
	vec3 tb = (bmax - o) * inv_d;
	vec3 tn = min(ta, tb);
	vec3 tf = max(ta, tb);
	t_in = max(max(max(tn.x, tn.y), tn.z), t0);
	t_out = min(min(min(tf.x, tf.y), tf.z), t1);
	return t_out > t_in;
}

/// Length of [t0, t1] that lies inside the box.
float volume_segment_length(vec3 o, vec3 d, float t0, float t1) {
	float t_in, t_out;
	return volume_box_clip(o, d, t0, t1, t_in, t_out) ? (t_out - t_in) : 0.0;
}

/// exp(-sigma_t * L) over the in-box part of [t0, t1]: Cycles'
/// volume_color_transmittance on a bounded homogeneous medium
/// (shade_volume.h:680), grey because Godot's density is a scalar.
vec3 volume_transmittance_along(vec3 o, vec3 d, float t0, float t1) {
	if (!volume_active()) {
		return vec3(1.0);
	}
	return vec3(exp(-volume_sigma_t() * volume_segment_length(o, d, t0, t1)));
}

/// Cycles' phase_henyey_greenstein (closure/volume_util.h:27-34): cos_theta is
/// dot(ray_dir, L) -- the angle between the direction the light travels on
/// toward the camera and the direction to the light -- so g > 0 peaks when
/// the light is ahead of the ray (forward scattering). g is clamped as
/// volume_henyey_greenstein_setup does.
float phaseHenyeyGreenstein(float cos_theta, float g) {
	g = sign(g) * min(abs(g), 1.0 - 1e-3);
	if (abs(g) < 1e-3) {
		return 1.0 / (4.0 * PI);
	}
	float fac = 1.0 + g * (g - 2.0 * cos_theta);
	return (1.0 - g * g) / (4.0 * PI * fac * sqrt(max(fac, 1e-12)));
}
```

`PI` — confirm the name used elsewhere in these shaders (`grep -n "define PI\|const float PI" servers/rendering/renderer_rd/shaders/raytracing/*.glsl`) and use that.

Include it in `scene_raytracing_raygen.glsl` in the raygen, miss and closest-hit stages immediately after `#include "raytracing_common_inc.glsl"`.

- [ ] **Step 4: Shadow rays pay the transmittance**

In `raytracing_lights_inc.glsl` rename the existing `vec3 lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist) {` to `vec3 lights_trace_shadow_ray_geometry(vec3 origin, vec3 direction, float max_dist) {` and add, directly after that function's closing brace (line ~481):

```glsl
// F2: every shadow ray -- surface NEE, scatter-point NEE, the env shadow ray
// -- pays the medium's transmittance over its in-box length, as Cycles'
// volume_shadow_* does for a shadow ray crossing a volume object. Folded to
// the geometry query alone when the volume is compiled out.
vec3 lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist) {
	vec3 atten = lights_trace_shadow_ray_geometry(origin, direction, max_dist);
	if (volume_active() && rt_max_component(atten) > 0.0) {
		atten *= volume_transmittance_along(origin, direction, 0.0, max_dist);
	}
	return atten;
}
```

(`rt_max_component` is defined at `:263`, above.) Any internal recursive call inside the geometry function (pass B re-trace loop) stays on the geometry function.

- [ ] **Step 5: C++ — flag, params, box**

`scene_shader_raytracing.h`: add `RT_FLAG_VOLUME_ENABLED = (1 << 20),` after `RT_FLAG_SSS_ENABLED`, include it in the `static_assert` mask list at `:162`; add

```cpp
	// F2 volumetrics: shader-side rt_params indices 16-34 (raytracing_inc.glsl).
	static constexpr int RT_PARAM_VOLUME_SIGMA_T = 16;
	static constexpr int RT_PARAM_VOLUME_G = 17;
	static constexpr int RT_PARAM_VOLUME_ALBEDO_R = 20;
	static constexpr int RT_PARAM_VOLUME_EMISSION_R = 24;
	static constexpr int RT_PARAM_VOLUME_BOX_MIN_X = 28;
	static constexpr int RT_PARAM_VOLUME_BOX_MAX_X = 32;
```

and change `compute_rt_flags(const float *p_env_params, bool p_fog_enabled)` to `compute_rt_flags(const float *p_env_params, bool p_fog_enabled, bool p_volume_enabled)`; in the `.cpp` add after the fog block:

```cpp
	if (p_volume_enabled) {
		flags |= RT_FLAG_VOLUME_ENABLED;
	}
```

`render_forward_clustered.cpp:2505`:

```cpp
		const bool fog_enabled = p_render_data && p_render_data->environment.is_valid() && environment_get_fog_enabled(p_render_data->environment);
		// F2: the Environment's volumetric fog becomes the tracer's bounded medium.
		const bool volume_enabled = p_render_data && p_render_data->environment.is_valid() &&
				environment_get_volumetric_fog_enabled(p_render_data->environment) &&
				environment_get_volumetric_fog_density(p_render_data->environment) > 0.0f;
		rt_flags = SceneShaderRaytracing::compute_rt_flags(env_params, fog_enabled, volume_enabled);
```

`render_raytracing.h` `RTViewportState`: add

```cpp
	// F2: union of every TLAS instance's world AABB this frame -- the fog box.
	AABB volume_box;
	bool volume_box_valid = false;
```

`render_raytracing.cpp` `build_tlas`, at the head of the main loop (`:2858`, after `if (!inst || !inst->data) { continue; }`):

```cpp
		if (!p_state->volume_box_valid) {
			p_state->volume_box = inst->transformed_aabb;
			p_state->volume_box_valid = true;
		} else {
			p_state->volume_box = p_state->volume_box.merge(inst->transformed_aabb);
		}
```

with `p_state->volume_box_valid = false;` reset before the loop (the state object is reused across frames). If `p_state` is not yet in scope at that point of `build_tlas`, union into a local `AABB scene_box; bool scene_box_valid = false;` and copy both into the state where the function fills the rest of it.

UBO (`:4155`): `float params[16]` → `float params[40]`; `static_assert(sizeof(rt_ubo) == 48 * sizeof(float))` → `72 * sizeof(float)`; the `memcpy(rt_ubo.params, env_params, sizeof(float) * 16)` stays (the Environment owns 0-15). After the `FRAME_INDEX` line:

```cpp
		// F2 volumetrics: the Environment's fog as a bounded homogeneous medium.
		// sigma_t = density per metre (the raster's exp(-density * depth)),
		// sigma_s = density * albedo, emission = colour * energy * density
		// (volumetric_fog_process.glsl:385,393); the box is this frame's TLAS AABB.
		if (p_render_data && p_render_data->environment.is_valid() && owner->environment_get_volumetric_fog_enabled(p_render_data->environment) && p_state->volume_box_valid) {
			const RID env = p_render_data->environment;
			const float density = owner->environment_get_volumetric_fog_density(env);
			const Color albedo = owner->environment_get_volumetric_fog_scattering(env); // colour space per Task 2 Step 1
			const Color emission = owner->environment_get_volumetric_fog_emission(env);
			const float e_energy = owner->environment_get_volumetric_fog_emission_energy(env) * density;
			const AABB box = p_state->volume_box.grow(0.01f);
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_SIGMA_T] = density;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_G] = owner->environment_get_volumetric_fog_anisotropy(env);
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_ALBEDO_R + 0] = albedo.r;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_ALBEDO_R + 1] = albedo.g;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_ALBEDO_R + 2] = albedo.b;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_EMISSION_R + 0] = emission.r * e_energy;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_EMISSION_R + 1] = emission.g * e_energy;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_EMISSION_R + 2] = emission.b * e_energy;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MIN_X + 0] = box.position.x;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MIN_X + 1] = box.position.y;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MIN_X + 2] = box.position.z;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MAX_X + 0] = box.position.x + box.size.x;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MAX_X + 1] = box.position.y + box.size.y;
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_VOLUME_BOX_MAX_X + 2] = box.position.z + box.size.z;
		}
```

Apply `.srgb_to_linear()` to `albedo` and `emission` if Step 1 found the raster converting.

- [ ] **Step 6: Build; run the volume gate, the energy gate and the light-energy gate**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -2
for g in pt_volume_gate pt_energy_gate pt_light_energy_gate; do echo "== $g"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/${g}_scene.tscn 2>&1 | grep -E "^  V|^PASS|^FAIL|vs reference"; done
```

Expected: **V5 green** (the sun's shadow rays now pay `exp(-1)`); V1–V4 still red; energy and light-energy gates unchanged to the digit (flag off → compiled out; the UBO growth changes no value at indices 0–15).

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_volume_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): F2 volume parameters, scene-AABB fog box, shadow-ray transmittance (V5 <reading>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Free flight, the scatter event, emission (V1, V2 green)

**Files:**
- Modify: `scene_raytracing_raygen.glsl` — `trace_one_sample` (`:70-125`) and the miss stage (`:266-400`)

**Interfaces:**
- Produces: in the miss stage, a scatter event sets `ps.mis_ray_pdf = RT_MIS_PDF_VOLUME_SCATTER`, `ps.hit_t = gl_RayTmaxEXT`, and does NOT terminate the path; raygen detects it and (in this task) multiplies throughput by the albedo and terminates — Task 4 adds the lighting. Emission is added in raygen per segment.

- [ ] **Step 1: Free flight and emission in raygen**

In `trace_one_sample`, replace the loop body's trace with (both SER and non-SER arms use `t_max_this`):

```glsl
	[[dont_unroll]] for (uint bounce = 0u; bounce <= iteration_limit; bounce++) {
		path_pack(payload, ps);
		uint ray_flags = is_inside_medium(ps.packed_bounces_flags)
				? (RT_RAY_FLAGS & ~gl_RayFlagsCullBackFacingTrianglesEXT)
				: RT_RAY_FLAGS;

		// F2: draw the free-flight distance through the fog box BEFORE the trace
		// and bound the trace by it. A hit closer than that is a transmit event
		// (P(t_free > t) = exp(-sigma_t t), so throughput is unchanged -- analog
		// tracking on a grey extinction); a miss inside it is a scatter event the
		// miss stage marks and raygen shades below. Cycles makes the same
		// scatter-or-transmit decision after the intersection
		// (volume_integrate_homogeneous); the estimator is the same.
		float t_max_this = RT_RAY_TMAX;
		float vol_t_in = 0.0;
		float vol_t_out = 0.0;
		bool vol_in_box = false;
		if (volume_active()) {
			vol_in_box = volume_box_clip(ray_origin, ray_dir, t_min, RT_RAY_TMAX, vol_t_in, vol_t_out);
			if (vol_in_box) {
				RNGState vrng = rng_unpack(ps.rng_packed, p_pixel);
				float u = rng_1d(vrng, RT_PRNG_VOLUME);
				float t_free = vol_t_in - log(max(1.0 - u, 1e-7)) / volume_sigma_t();
				if (t_free < vol_t_out) {
					t_max_this = t_free;
				}
			}
		}
		const vec3 throughput_before = ps.throughput;
#ifdef USE_SER
		hitObjectEXT hitObject;
		hitObjectTraceRayEXT(hitObject, tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, t_min, ray_dir, t_max_this, 0);
		...unchanged...
#else
		traceRayEXT(tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, t_min, ray_dir, t_max_this, 0);
#endif
		ps = path_unpack(payload);

		if (volume_active() && vol_in_box) {
			// Where this segment ended inside the box: the surface, the scatter
			// point, or the far wall of the box.
			// (The miss stage writes ps.hit_t = RT_RAY_TMAX on a sky miss and
			// t_max_this on a scatter, so min() below is right in every case.)
			const bool scattered = (ps.mis_ray_pdf == RT_MIS_PDF_VOLUME_SCATTER);
			const float t_end = min(ps.hit_t, vol_t_out);
			// Emission integrated over the in-box length: Cycles'
			// volume_emission_integrate, E (1 - exp(-sigma_t L)) / sigma_t.
			const vec3 E = volume_emission();
			if (any(greaterThan(E, vec3(0.0)))) {
				const float L = max(min(t_end, vol_t_out) - vol_t_in, 0.0);
				const float st = volume_sigma_t();
				const float od = st * L;
				const float k = (od > 1e-5) ? (1.0 - exp(-od)) / st : L * (1.0 - 0.5 * od);
				ps.radiance += throughput_before * E * k;
			}
			if (scattered) {
				const vec3 scatter_pos = ray_origin + ray_dir * t_max_this;
				volume_scatter_shade(p_pixel, scatter_pos, ray_dir, throughput_before, ps);
				break;
			}
		}
		if (is_path_terminated(ps.packed_bounces_flags)) {
			break;
		}
		...unchanged (hit_pos, restart)...
```

`p_pixel` is `trace_one_sample`'s pixel parameter — check its actual name at the function signature (`:50`) and use that. The miss stage (Step 2) writes `ps.hit_t = gl_RayTmaxEXT` on every miss, scatter or sky, which is what makes `min(ps.hit_t, vol_t_out)` the segment's end in every case.

Add, before `trace_one_sample`, the Task-3 version of the scatter shader (Task 4 replaces its body):

```glsl
// F2: a scatter event. Task 3: weight by the single-scattering albedo and end
// the path (Cycles' volume_bounces = 0 terminates after the first scatter);
// Task 4 adds the direct light at the scatter point.
void volume_scatter_shade(uvec2 p_pixel, vec3 p_pos, vec3 p_ray_dir, vec3 p_throughput, inout PathState ps) {
	ps.throughput = p_throughput * volume_albedo();
	ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
}
```

- [ ] **Step 2: The miss stage marks a scatter**

In the miss stage, right after the shadow-ray early-out and before `ps.packed_bounces_flags = set_path_terminated(...)`:

```glsl
	// F2: a trace bounded below RT_RAY_TMAX by raygen's free-flight draw that
	// reached its bound is a SCATTER event inside the fog box, not the sky. Mark
	// it and hand it back; raygen shades it. Primary sample-zero rays still feed
	// the denoiser guides, as a miss does, with the fog's albedo and the ray
	// direction (depth stays 0 -- haze reads as "far").
	if (volume_active() && gl_RayTmaxEXT < RT_RAY_TMAX) {
		ps.mis_ray_pdf = RT_MIS_PDF_VOLUME_SCATTER;
		ps.hit_t = gl_RayTmaxEXT;
#ifdef DLSS_RR_ENABLED
		if (get_total_bounces(ps.packed_bounces_flags) == 0u && is_sample_zero(ps.packed_bounces_flags)) {
			ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);
			imageStore(rt_depth_image, pixel, vec4(0.0));
			imageStore(dlss_rr_diffuse_albedo, pixel, vec4(volume_albedo(), 1.0));
			imageStore(dlss_rr_specular_albedo, pixel, vec4(0.0));
			imageStore(dlss_rr_normal_roughness, pixel, vec4(-gl_WorldRayDirectionEXT, 1.0));
			imageStore(dlss_rr_specular_hit_dist, pixel, vec4(-1.0));
			rt_accum_guide_sample(pixel, volume_albedo(), -gl_WorldRayDirectionEXT);
		}
#endif
		path_pack(payload, ps);
		return;
	}
	ps.hit_t = RT_RAY_TMAX; // F2: raygen reads the segment end from here on a sky miss.
```

(Check whether the miss stage's `RT_DEBUG_ENABLED` early-return for vis mode 13 should come before or after — keep the scatter test *before* it; vis mode 13 is a bounce-count debug.)

- [ ] **Step 3: Build; run the volume gate**

Expected: **V1** = 0.368 ± 1% (green), **V2** = 1.264 ± 1% (green), V5 green; V3/V4 read a small positive (albedo-weighted throughput with no light: exactly 0 — Task 4). If V1 reads ~0.37 but noisy beyond 1%: raise `FRAMES` for that probe to 512 via `ZR_GATE_FRAMES` and note the floor; if it reads 1.0 still, the miss stage's `gl_RayTmaxEXT` test is not firing — print `gl_RayTmaxEXT` through vis mode 20 (`ps.radiance = vec3(gl_RayTmaxEXT / RT_RAY_TMAX)`) to see whether raygen's bound arrives.

- [ ] **Step 4: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
git commit -m "feat(pt): F2 free-flight sampling, scatter events, medium emission (V1 <r>, V2 <r>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Direct light at the scatter point (V3, V4 green)

**Files:**
- Modify: `brdf_inc.glsl` (`MaterialProperties.phaseG`), `raytracing_closest_hit_common_inc.glsl` (six construction sites), `raytracing_lights_inc.glsl` (three eval sites), `scene_raytracing_raygen.glsl` (raygen declarations + `volume_scatter_shade` body)

**Interfaces:**
- Produces: `MaterialProperties.phaseG` (`float`, `RT_PHASE_SURFACE` on every surface). In volume mode `lights_evaluate_direct_lighting(pos, N, V, material, rng, is_indirect, count)` is called with `N = -ray_dir`, `V = -ray_dir`, `material.phaseG = g`; the three sites evaluate `phaseHenyeyGreenstein(dot(-V, L), g)`.

- [ ] **Step 1: `phaseG`**

In `MaterialProperties` after `float3 bumpNormal;`:

```glsl
	// F2: RT_PHASE_SURFACE for a surface. A scatter point sets it to the
	// medium's Henyey-Greenstein g, and the analytic-light NEE sites evaluate
	// the phase function instead of the BRDF (raytracing_lights_inc.glsl).
	float phaseG;
```

At each of the six construction sites in `raytracing_closest_hit_common_inc.glsl` (after every `dbg_mat.bumpNormal = final_normal;`, `dbg_mat40.bumpNormal = final_normal;` and `brdf_mat.bumpNormal = m.normal;`): add `<name>.phaseG = RT_PHASE_SURFACE;`.

- [ ] **Step 2: Volume mode at the three NEE sites**

`raytracing_lights_inc.glsl`, rect light (`:517-590`):

```glsl
	const bool in_volume = material.phaseG > RT_PHASE_SURFACE + 0.5;
	// 4. Check shading normal -- F1 approach C: either lobe normal's hemisphere.
	float NdotL = max(dot(N, L), dot(diffuseLobeNormal(N, material), L));
	if (!in_volume && NdotL <= 0.0) {
		return vec3(0.0);
	}
	...
	vec3 brdf_value;
	if (in_volume) {
		// F2: -V is the ray direction; Cycles' cos_theta = dot(-sd->wi, wo).
		brdf_value = vec3(phaseHenyeyGreenstein(dot(-V, L), material.phaseG));
	} else {
		vec3 brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen;
		evalCombinedBRDFSeparate(N, L, V, material, brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen);
#if MICROFACET_DISTRIBUTION == GGX
		brdf_specular *= evalMultiScatterFactorForMaterial(N, V, material); // Gap #23
#endif
		float spec_mul = lights_get_specular_multiplier(light.specular_amount, material.roughness);
		brdf_value = brdf_diffuse + brdf_specular * spec_mul + brdf_coat * spec_mul + brdf_sheen;
	}
```

The same shape at the omni/spot site (`:745`, the pre-sample `dot(N, L)` test and `:765-778`) and the directional site (`:805-830`). Three sites, three explicit edits — do not factor them into a helper (the file's own rule: "five call sites, five explicit decisions").

- [ ] **Step 3: Raygen gets the NEE machinery and the scatter shader**

In the raygen stage of `scene_raytracing_raygen.glsl`, after its existing `layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;` and `rayPayloadEXT` lines, add the declarations the closest-hit stage has (copy them verbatim from that stage: `#extension GL_EXT_ray_query : enable` at the top with the other extensions, `bindless_textures` set 1, `#include "raytracing_samplers_inc.glsl"`, the `MaterialBuffer` binding 5 block, `#include "raytracing_lights_inc.glsl"`, `radiance_octmap`/`radiance_sampler` bindings 7/8). `GeometryBuffer` (3) and `MotionIndexBuffer` (4) are already declared in raygen — do not duplicate. `raytracing_lights_inc.glsl` includes `raytracing_hit_inc.glsl`? Check; if the lights include needs `get_triangle_indices`/`fetch_uv` for the alpha test, include `raytracing_hit_inc.glsl` before it with `#define RT_HIT_ATTRIBS_DECLARED` NOT set (the raygen has no hit attribs; the alpha-test helpers it uses must not depend on them — verify by building; if they do, guard the alpha test in `ray_query_alpha_test` with `#ifdef RT_STAGE_CLOSEST_HIT` and return `true` in raygen, noting the limit: scatter-point shadow rays treat alpha-tested geometry as opaque).

Replace Task 3's `volume_scatter_shade` with:

```glsl
// F2: direct light at a scatter point -- Cycles' volume_integrate direct
// scatter at its default volume_bounces = 0: NEE through the phase function,
// then the path ends. Analytic lights go through the same reservoir /
// shadow-ray / IES / clamp code a surface uses, with the phase function in
// place of the BRDF (MaterialProperties.phaseG); the sky is one env_sample
// with MIS weight 1 (no second strategy exists at a scatter point);
// emissive-mesh NEE is deferred (spec, out of scope).
void volume_scatter_shade(uvec2 p_pixel, vec3 p_pos, vec3 p_ray_dir, vec3 p_throughput, inout PathState ps) {
	RNGState rng = rng_unpack(ps.rng_packed, p_pixel);
	const vec3 V = -p_ray_dir;
	const vec3 throughput = p_throughput * volume_albedo();
	const float g = volume_g();
	const bool is_indirect = get_diffuse_bounces(ps.packed_bounces_flags) > 0u || get_glossy_bounces(ps.packed_bounces_flags) > 0u;
	const float clamp_limit = is_indirect ? get_rt_param(RT_PARAM_CLAMP_INDIRECT) : get_rt_param(RT_PARAM_CLAMP_DIRECT);

	MaterialProperties vm;
	vm.baseColor = vec3(1.0);
	vm.metalness = 0.0;
	vm.emissive = vec3(0.0);
	vm.roughness = 1.0;
	vm.dielectricF0 = vec3(0.0);
	vm.transmissivness = 0.0;
	vm.eta = 1.0;
	vm.opacity = 1.0;
	vm.anisotropy = 0.0;
	vm.anisotropyRotation = 0.0;
	vm.tangent = vec3(0.0);
	vm.smoothNormal = vec3(0.0);
	vm.bumpNormal = vec3(0.0);
	vm.phaseG = g;
	// Every other MaterialProperties field is read only by surface code paths
	// the volume mode skips; set the ones with a "0 disables" convention.
	vm.coatWeight = 0.0;
	vm.sheenColor = vec3(0.0);
	vm.sssWeight = 0.0;

	// Analytic lights.
	uint rt_light_count = uint(get_rt_param(RT_PARAM_LIGHT_COUNT));
	if (rt_light_count > 0u) {
		vec3 direct = lights_evaluate_direct_lighting(p_pos, V, V, vm, rng, is_indirect, rt_light_count);
		ps.radiance += clamp_contribution(throughput * direct, clamp_limit);
	}

	// Sky.
	{
		vec3 env_dir;
		float env_pdf_val;
		if (env_sample(rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val) && env_pdf_val > 0.0) {
			vec3 atten = lights_trace_shadow_ray(p_pos, env_dir, RT_RAY_TMAX);
			if (rt_max_component(atten) > 0.0) {
				vec2 border = vec2(scene_data_block.data.radiance_border_size, 1.0 - scene_data_block.data.radiance_border_size * 2.0);
				vec2 sky_uv = vec3_to_oct_with_border(env_world_to_sky() * env_dir, border);
				vec3 sky_rad = textureLod(sampler2D(radiance_octmap, radiance_sampler), sky_uv, 0.0).rgb * scene_data_block.data.IBL_exposure_normalization;
				vec3 contrib = throughput * sky_rad * atten * phaseHenyeyGreenstein(dot(p_ray_dir, env_dir), g) / env_pdf_val;
				ps.radiance += clamp_contribution(contrib, clamp_limit);
			}
		}
	}

	ps.throughput = throughput;
	ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
}
```

`clamp_contribution` and `env_world_to_sky` — confirm both are visible in raygen (`clamp_contribution` lives where? `grep -n "vec3 clamp_contribution" servers/rendering/renderer_rd/shaders/raytracing/*.glsl`; if it is in `raytracing_closest_hit_common_inc.glsl`, move it to `raytracing_common_inc.glsl` — it has no closest-hit dependencies). List every `MaterialProperties` field (`grep -n "^\t[a-z0-9]* [a-zA-Z0-9]*;" brdf_inc.glsl` within the struct) and initialise each one in `vm`; GLSL leaves unset fields undefined and the three sites read `material.roughness` for the specular multiplier even in volume mode.

- [ ] **Step 4: Build; run the volume gate, then the three NEE-sensitive gates**

```bash
for g in pt_volume_gate pt_light_energy_gate pt_light_gate pt_energy_gate; do echo "== $g"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/${g}_scene.tscn 2>&1 | grep -E "^  V|^PASS|^FAIL|vs reference"; done
```

Expected: **V3 and V4 within 3% of Cycles**; V1/V2/V5 still green; the three surface gates unchanged to the digit (`in_volume` is false on every surface; the flag is off in those scenes). If V3 is off by a constant factor with V4 green: the sun's `indirect_energy` / `specular_amount` path or `light_angular_distance` — compare the floor crop's absolute against the pre-F2 binary first (it must be `exp(-0.6)` = 0.549 of it). If V4 is off with V3 green: `IBL_exposure_normalization` or the sky lookup's border — compare against `env_sky_radiance` in the closest-hit stage line by line.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl
git commit -m "feat(pt): F2 direct light at scatter points -- analytic lights through the phase function, sky NEE (V3 <r> vs Cycles, V4 <r>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Regression suite and cost

- [ ] **Step 1: Whole suite, old binary first, then new**

```bash
OLD="/c/Zlendo2026/ZlenderRender_stage_copy/godot/bin/godot.windows.editor.x86_64.console.exe"
for s in pipeline_references/tests/pt_*_gate_scene.tscn pipeline_references/tests/png16_encoding_gate_scene.tscn; do n=$(basename $s .tscn); echo "== $n"; "$OLD" --rendering-driver vulkan --path pipeline_references res://tests/$n.tscn 2>&1 | grep -E "^PASS|^FAIL" | tail -1; done
```

then the same with `bin/godot.windows.editor.x86_64.console.exe`. Expected: old binary — every gate green except `pt_volume_gate` (five red) and `pt_bump_correction_gate` (the previous hand-over predates F1); new binary — **21/21**. Any other red on the new binary: bisect Tasks 2–4 on the engine paths only (`git checkout <sha> -- servers/`, rebuild, `git checkout HEAD -- servers/`).

- [ ] **Step 2: Cost**

Fog off (the flag compiled out): three timing passes on `pt_light_rmse_scene.tscn` with `ZR_LIGHT_SKIP_SWEEP=1` per binary — expected identical within noise. Fog on: not measurable on that scene (no Environment fog there); instead time the 226 render in Task 6 (old vs new binary, same scene, the pipeline's density 0.001) and report the wall-clock delta.

- [ ] **Step 3: Doctest**

```bash
bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | tail -3
```

Expected: 1558/1558.

- [ ] **Step 4: Commit** (only if a gate reference needed re-capture; otherwise nothing to commit — record the readings in Task 6's closeout).

---

### Task 6: Asset check and roadmap

- [ ] **Step 1: Job 225/226's scene, old vs new binary**

```bash
export ZR_PT_EXR=1; unset ZR_PHASE_A ZR_PT_FINAL ZR_LIGHTS_SKIP
T0=$(date +%s); ./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" res://main.tscn -- "$S/proj_225/input_json/d225_fhd.json" "$S/f2_226.png" > "$S/f2_226_godot.log" 2>&1; echo "new exit=$? secs=$(( $(date +%s) - T0 ))"
```

and the F1 binary's render is already at `$S/f1_226.png` (same scene, same settings, made in the F1 closeout) — reuse it as the "before". Diff map + crops (the `$S/bump/compare_226.py` script from F1, pointed at the two files), `SendUserFile`. What to report: beams where the sun enters (the windows are behind the camera in this scene — expect a faint gradient rather than visible shafts), the haze on the far wall (density 0.001 over the room's depth), the sky through the windows, the wall-clock delta.

- [ ] **Step 2: Roadmap**

Row 16: `| 16 | **No volumetrics — CLOSED 2026-09-17 (§11.30).** The Environment's volumetric fog is a bounded homogeneous medium on the scene's AABB, Cycles' single-scatter default (volume_bounces 0): free-flight sampling bounds every trace, a scatter point gets analytic-light and sky NEE through Henyey-Greenstein, every shadow ray pays exp(-σt·L). A World volume was deliberately NOT copied (it extinguishes the sun and sky: FLT_MAX shadow rays). pt_volume_gate: V1/V2/V5 analytic ± 1%, V3/V4 vs Cycles <n>%. | `raytracing_volume_inc.glsl`, raygen free flight, `lights_trace_shadow_ray` | `shade_volume.h:1716`, `volume_util.h:27`, `sun.h:44` | **Closed** |`. Phase F: **F2** `— ✅ DONE 2026-09-17 (§11.30)`. New §11.30 in the house style: the three source findings, the estimator equivalence (free flight before the trace vs Cycles' decision after), the gate table with readings, what the asset shows, cost, and the recorded follow-ups (equiangular + MIS for lamps, multiple scattering, emissive NEE at scatter points, FogVolume objects).

- [ ] **Step 3: Commit; finishing menu**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): Phase F2 closeout (11.30); Gap #16 closed

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Then present keep / push / merge, as every phase.
