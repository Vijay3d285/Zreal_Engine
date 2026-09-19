# Light Portals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `AreaLight3D` marked `area_portal` makes the path tracer aim half of its sky samples through that rectangle from every point that faces it — Cycles' light portal — so daylight interiors get the sky through the windows with a fraction of the noise.

**Architecture:** Portals are not lights. They live in their own 16-entry SSBO (binding 41) uploaded next to the light buffer; a new GLSL include transcribes Cycles' portal facing test, Ureña spherical-rectangle sampling and the portal pdf; the sky sampler's two entry points `env_sample` / `env_pdf` gain the shading position and become Cycles' 1:1 portal/map mixture with the mixture pdf, and the miss stage passes the ray origin for MIS. `AreaLight3D` gets the `area_portal` bool through Godot's four storage layers; the Forward+ raster skips portals; the tracer also starts treating a non-portal `AreaLight3D` as a real rect light (it was falling through as an omni).

**Tech Stack:** GLSL (Vulkan RT), C++ (Godot RD + scene), GDScript gate, Blender 5.2.1 Python.

**Spec:** `docs/superpowers/specs/2026-09-18-light-portals-design.md`

## Global Constraints

- Build: `python -m SCons platform=windows target=editor tests=yes -j8`. Every `.glsl` edit needs a full build; a clean build proves nothing about GLSL — only a render does.
- Gates run only in a **connected desktop session** (`query session` shows the user's RDP session `Active`).
- Gate command: `bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/<name>_scene.tscn` — the `.tscn` suffix is mandatory.
- `pipeline_references/*.gd` at the top level are the user's files: never stage, commit, revert or checkout over them; edits there stay uncommitted for the user to copy. `pipeline_references/tests/` is this workstream's.
- `git add` with explicit paths only. Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Scratch files and render outputs go to the scratchpad directory (`$S` below), never into the repo or the live project. `C:\Zlendo2026\ZlenderRender_stage_copy` is read-only.
- Patch scripts are written with the Write tool, never through a bash heredoc (heredocs eat backslashes); chain with `&&` so a failed patch never lets a build or gate run.
- Colour properties on `StandardMaterial3D` / `Environment` are sRGB-encoded: a linear albedo `a` is authored as `Color(a,a,a).linear_to_srgb()`. `PanoramaSkyMaterial` fed an RGBF image is linear.
- Gates set msaa/FXAA/TAA/debanding off themselves (they inherit the project's AA otherwise).
- Before bisecting any gate regression, run the same gate on `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\godot.windows.editor.x86_64.console.exe` (the previous hand-over binary, `$OLD`).
- Blender: `"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P <script> -- <out_dir>`.
- Coordinates: Godot `(x, y, z)` → Blender `(x, -z, y)`. Godot lights and `AreaLight3D` face their local `−Z`; so does a Blender area light.
- Names fixed by the spec: property `area_portal` (`set_area_portal` / `is_area_portal`), RS `light_set_portal`, RD `light_is_portal`, `RT_PortalData` / `RTPortalData` 64 bytes, binding 41, `RT_PORTALS_MAX = 16`, `RT_PARAM_PORTAL_COUNT = 18`, include `raytracing_portal_inc.glsl`, gate `pt_portal_gate`, Cycles script `cycles_portal_room.py`.

---

## File map

| File | Responsibility |
|---|---|
| `tools/cycles_comparison/cycles_portal_room.py` | **Create.** Cycles half: the closed white room with one opening and one portal area light; prints `@@@` crop means for P3. |
| `pipeline_references/tests/pt_portal_gate.gd` + `_scene.tscn` | **Create.** Probes P1–P5. |
| `scene/3d/light_3d.h/.cpp`, `doc/classes/AreaLight3D.xml` | **Modify.** `AreaLight3D::area_portal`. |
| `servers/rendering/rendering_server.h/.cpp`, `rendering_server_default.h`, `servers/rendering/storage/light_storage.h`, `servers/rendering/dummy/storage/light_storage.h`, `drivers/gles3/storage/light_storage.h/.cpp`, `doc/classes/RenderingServer.xml` | **Modify.** `light_set_portal` plumbing. |
| `servers/rendering/renderer_rd/storage_rd/light_storage.h/.cpp` | **Modify.** `Light::portal`, setter, `light_is_portal()`, raster skip in `update_light_buffers`. |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h/.cpp` | **Modify.** `RT_PortalData`, `RT_PORTALS_MAX`, `RTViewportState::portal_buffer`, `gather_lights` (portal pass, portal skip in the scorer, `LIGHT_AREA` → rect), upload, binding 41. |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` | **Modify.** `RT_PARAM_PORTAL_COUNT = 18`. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | **Modify.** `RT_PARAM_PORTAL_COUNT` define. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_portal_inc.glsl` | **Create.** `RTPortalData` SSBO (binding 41), `portal_count`, `portal_fetch_and_check_side`, `portal_rect_sample` (Ureña), `portal_ray_quad_intersect`, `portal_num_possible`, `portal_pdf`, `portal_sample`. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl` | **Modify.** Include the portal file before the env sampler. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl` | **Modify.** `env_map_sample` / `env_map_pdf` (today's bodies), new `env_sample(P, …)` / `env_pdf(P, dir)` mixture. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`, `scene_raytracing_raygen.glsl` | **Modify.** The three call sites pass a position. |
| `pipeline_references/image_glb_creation.gd` (user's file, uncommitted) | **Modify.** `_create_window_portals()`. |
| `PATH_TRACER_QUALITY_ROADMAP.md`, `Full_Architectural_Gap_Roadmap.md` | **Modify.** Closeout §11.31; the portal row. |

Shell variables used throughout:

```bash
S="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/b37a70cf-2a76-48f2-b7de-63b1ab2399c1/scratchpad"
OLD="/c/Zlendo2026/ZlenderRender_stage_copy/godot/bin/godot.windows.editor.x86_64.console.exe"
NEW="bin/godot.windows.editor.x86_64.console.exe"
BLENDER="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"
```

---

### Task 1: The gate and its Cycles half (red on the current binary)

**Files:**
- Create: `tools/cycles_comparison/cycles_portal_room.py`
- Create: `pipeline_references/tests/pt_portal_gate.gd`, `pipeline_references/tests/pt_portal_gate_scene.tscn`

**Interfaces:**
- Consumes: `res://tests/pt_validation.gd` (`_render_accum(env, vp_rid, frames) -> Image`), `Environment.set_pathtracing_*`.
- Produces: the gate the later tasks turn green; constants `CYCLES_P3_WALL`, `CYCLES_P3_FLOOR` captured here; `P2_BAR` left at `0.0` (Task 4 captures it).

The room, in Godot coordinates: x ∈ [−2, 2], y ∈ [0, 3], z ∈ [−1.5, 1.5]; six inward-facing quads; the left wall (x = −2) is four quads around a 1.2 (z) × 1.0 (y) opening centred at z = 0, y ∈ [0.9, 1.9]. Camera (0, 1.5, 1.2) looking at (0, 1.2, −1.5), 60° vertical FOV, 256 × 256: only the back wall, the floor and a strip of ceiling are in frame (the side walls need a depth > 3.46 m to enter a 60° frame; the back wall is 2.7 m away). Crops: back wall rows 0.30–0.60 × cols 0.30–0.70; floor rows 0.90–0.98 × cols 0.30–0.70.

- [ ] **Step 1: Cycles script**

`tools/cycles_comparison/cycles_portal_room.py`:

```python
# Closed white room with one window opening, lit by a uniform world through a
# light portal -- the pt_portal_gate P3 stimulus
# (spec 2026-09-18-light-portals-design.md).
#
# Godot (x, y, z) -> Blender (x, -z, y). The room is Godot [-2,2] x [0,3] x
# [-1.5,1.5]; the opening is in the x = -2 wall, 1.2 wide (Godot z) x 1.0
# tall, sill at y = 0.9. Every quad is given by its four Godot corners and
# converted, so the two fixtures are the same numbers. One area light,
# is_portal, sits in the opening facing +X (into the room). World strength 1,
# albedo 0.8 everywhere, 8 bounces, 1024 spp, no denoise.
# Camera Godot (0, 1.5, 1.2) looking at (0, 1.2, -1.5), 60 deg vertical FOV.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_portal_room.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "1024"))
ALBEDO = 0.8


def g2b(p):
    return (p[0], -p[2], p[1])


def mat_surface(name, albedo):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Specular IOR Level"].default_value = 0.0
    return m


def quad(name, corners_godot, mat):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([g2b(c) for c in corners_godot], [], [(0, 1, 2, 3)])
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)
    return obj


# The same quad list the gate builds (pt_portal_gate.gd, _room_quads()).
def room_quads():
    X0, X1, Y0, Y1, Z0, Z1 = -2.0, 2.0, 0.0, 3.0, -1.5, 1.5
    WZ0, WZ1, WY0, WY1 = -0.6, 0.6, 0.9, 1.9  # the opening
    return [
        ("floor", [(X0, Y0, Z0), (X1, Y0, Z0), (X1, Y0, Z1), (X0, Y0, Z1)]),
        ("ceiling", [(X0, Y1, Z0), (X0, Y1, Z1), (X1, Y1, Z1), (X1, Y1, Z0)]),
        ("back", [(X0, Y0, Z0), (X0, Y1, Z0), (X1, Y1, Z0), (X1, Y0, Z0)]),
        ("front", [(X0, Y0, Z1), (X1, Y0, Z1), (X1, Y1, Z1), (X0, Y1, Z1)]),
        ("right", [(X1, Y0, Z0), (X1, Y1, Z0), (X1, Y1, Z1), (X1, Y0, Z1)]),
        ("left_below", [(X0, Y0, Z0), (X0, Y0, Z1), (X0, WY0, Z1), (X0, WY0, Z0)]),
        ("left_above", [(X0, WY1, Z0), (X0, WY1, Z1), (X0, Y1, Z1), (X0, Y1, Z0)]),
        ("left_neg", [(X0, WY0, Z0), (X0, WY0, WZ0), (X0, WY1, WZ0), (X0, WY1, Z0)]),
        ("left_pos", [(X0, WY0, WZ1), (X0, WY0, Z1), (X0, WY1, Z1), (X0, WY1, WZ1)]),
    ]


def build(portal):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 8
    scene.cycles.diffuse_bounces = 8
    scene.cycles.glossy_bounces = 8
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
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    world.cycles.sampling_method = "AUTOMATIC"  # map MIS on: Cycles' map_weight 1

    white = mat_surface("white", ALBEDO)
    for name, corners in room_quads():
        quad(name, corners, white)

    if portal:
        ld = bpy.data.lights.new("Portal", "AREA")
        ld.shape = "RECTANGLE"
        ld.size = 1.0    # local X -> Blender +Z (Godot +Y): the opening's height
        ld.size_y = 1.2  # local Y -> Blender -Y (Godot z): the opening's width
        ld.cycles.is_portal = True
        lo = bpy.data.objects.new("Portal", ld)
        scene.collection.objects.link(lo)
        lo.location = g2b((-2.0, 1.4, 0.0))
        lo.rotation_euler = (0.0, -math.pi / 2.0, 0.0)  # local -Z -> +X, into the room

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(60.0)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = g2b((0.0, 1.5, 1.2))
    cam.rotation_euler = (math.radians(90.0) - math.atan2(0.3, 2.7), 0.0, 0.0)  # looks +Y, 6.34 deg down


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
print("@@@ PORTAL ROOM vs Cycles @@@")
print("@@@ blender: %s  samples %d  bounces 8" % (bpy.app.version_string, SAMPLES))

build(True)
p = os.path.join(OUT, "portal_on.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
wall = crop_mean(p, 0.30, 0.60, 0.30, 0.70)
floor = crop_mean(p, 0.90, 0.98, 0.30, 0.70)
print("@@@ P3 portal wall %.6f floor %.6f" % (wall, floor))

build(False)
p = os.path.join(OUT, "portal_off.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
wall_off = crop_mean(p, 0.30, 0.60, 0.30, 0.70)
floor_off = crop_mean(p, 0.90, 0.98, 0.30, 0.70)
print("@@@ CONTROL no portal wall %.6f floor %.6f (must equal P3 within noise: a portal changes variance, not the mean)" % (wall_off, floor_off))
print("@@@ DONE")
```

- [ ] **Step 2: Run it, capture the numbers**

```bash
mkdir -p "$S/portal" && "$BLENDER" -b -P tools/cycles_comparison/cycles_portal_room.py -- "$S/portal" 2>&1 | grep "@@@"
```

Expected: two `@@@` lines with wall and floor means; the control line's numbers within ~1% of the portal line (Cycles' portal is unbiased — if they differ by more, the fixture is wrong: check that the portal faces +X and that every quad is where the comment says). Write the portal-on values into the gate's `CYCLES_P3_WALL` / `CYCLES_P3_FLOOR` in Step 3 with the capture date.

- [ ] **Step 3: The gate**

`pipeline_references/tests/pt_portal_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Light portals gate (spec 2026-09-18-light-portals-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_portal_gate_scene.tscn
##
## An AreaLight3D with area_portal is a sampling hint for the sky, not a
## light: from every shading point that faces it, half of the sky samples
## are aimed through its rectangle (Cycles' portal, background.h:333). It
## emits nothing. Fixture: a closed 4 x 3 x 3 m white room (albedo linear
## 0.8), one 1.2 x 1.0 m opening in the x = -2 wall (sill y = 0.9), uniform
## world 1.0, no lamps, 8 bounces. Camera (0, 1.5, 1.2) looking at
## (0, 1.2, -1.5), 60 deg vertical FOV: only the back wall, the floor and a
## strip of ceiling are in frame. Cycles half:
## tools/cycles_comparison/cycles_portal_room.py.
##
##   P1 unbiased  : portal on / off at FRAMES_HI, back-wall and floor crops
##                  -> 1 +- 1 %
##   P2 variance  : per-pixel RMS of the back-wall crop at FRAMES_LO against
##                  the FRAMES_HI render, on / off -> must be < P2_BAR (< 1)
##   P3 Cycles    : portal on at FRAMES_HI, crop means vs Cycles +- 3 %
##   P4 side test : the portal flipped (facing outdoors: nothing in the room
##                  faces it) vs off at FRAMES_LO -> max abs diff <= the
##                  build's own repeat floor (off rendered twice)
##   P5 area light: a 1 x 1 m AreaLight3D (normalize off) over a floor vs the
##                  179.9 deg spot-rect of the same size and energy -> 1 +- 1 %
##
## albedo_color is sRGB-encoded: linear values are authored through
## linear_to_srgb(). The portal flag is set with set("area_portal", true) so a
## binary without the property runs the gate (and fails P2/P5) instead of
## failing to parse.

var FRAMES_HI: int = 1024 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const FRAMES_LO := 16
const TOL := 0.01
const BAR_CYCLES := 0.03
# Task 4 captures the on/off RMS ratio on the first green build and writes
# it here with margin; 0.0 makes P2 fail loudly until then.
const P2_BAR := 0.0
# Cycles 5.2.1, cycles_portal_room.py, 1024 spp, captured <date> (Task 1 Step 2):
const CYCLES_P3_WALL := 0.0
const CYCLES_P3_FLOOR := 0.0

const ALBEDO := 0.8
const WALL_ROWS := [0.30, 0.60, 0.30, 0.70]
const FLOOR_ROWS := [0.90, 0.98, 0.30, 0.70]

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

	print("AreaLight3D.area_portal present: ", ClassDB.class_has_property("AreaLight3D", "area_portal"))

	print("\n=== P1: unbiased, portal on / off at %d frames ===" % FRAMES_HI)
	var on_hi := await _render_room("on", FRAMES_HI)
	var off_hi := await _render_room("off", FRAMES_HI)
	var wall_on := _crop(on_hi, WALL_ROWS)
	var wall_off := _crop(off_hi, WALL_ROWS)
	var floor_on := _crop(on_hi, FLOOR_ROWS)
	var floor_off := _crop(off_hi, FLOOR_ROWS)
	print("  wall on %.6f off %.6f | floor on %.6f off %.6f" % [wall_on, wall_off, floor_on, floor_off])
	_check("P1 wall on/off", wall_on / maxf(wall_off, 1e-9), 1.0, TOL)
	_check("P1 floor on/off", floor_on / maxf(floor_off, 1e-9), 1.0, TOL)

	print("\n=== P2: variance at %d frames ===" % FRAMES_LO)
	var on_lo := await _render_room("on", FRAMES_LO)
	var off_lo := await _render_room("off", FRAMES_LO)
	var rms_on := _rms(on_lo, on_hi, WALL_ROWS)
	var rms_off := _rms(off_lo, off_hi, WALL_ROWS)
	var p2 := rms_on / maxf(rms_off, 1e-9)
	print("  RMS on %.6f off %.6f ratio %.4f (bar %.4f)" % [rms_on, rms_off, p2, P2_BAR])
	_checks += 1
	if P2_BAR <= 0.0 or P2_BAR >= 1.0:
		_failures.append("P2 variance: bar not captured (P2_BAR = %.4f)" % P2_BAR)
	elif p2 > P2_BAR:
		_failures.append("P2 variance: on/off RMS ratio %.4f above bar %.4f" % [p2, P2_BAR])

	print("\n=== P3: portal on vs Cycles ===")
	_check_vs("P3 wall vs Cycles", wall_on, CYCLES_P3_WALL, BAR_CYCLES)
	_check_vs("P3 floor vs Cycles", floor_on, CYCLES_P3_FLOOR, BAR_CYCLES)

	print("\n=== P4: flipped portal (nothing faces it) vs off ===")
	var off_lo_b := await _render_room("off", FRAMES_LO)
	var flipped_lo := await _render_room("flipped", FRAMES_LO)
	var floor_diff := _max_abs_diff(off_lo, off_lo_b)
	var flip_diff := _max_abs_diff(flipped_lo, off_lo)
	print("  repeat floor %.6g | flipped vs off %.6g" % [floor_diff, flip_diff])
	_checks += 1
	if flip_diff > floor_diff:
		_failures.append("P4 side test: flipped vs off max abs diff %.6g above the repeat floor %.6g" % [flip_diff, floor_diff])

	print("\n=== P5: AreaLight3D as a rect light vs the spot-rect convention ===")
	var area_img := await _render_rect_light("area", 256)
	var spot_img := await _render_rect_light("spot", 256)
	var p5 := _crop(area_img, [0.40, 0.60, 0.40, 0.60]) / maxf(_crop(spot_img, [0.40, 0.60, 0.40, 0.60]), 1e-9)
	print("  area %.6f spot-rect %.6f" % [_crop(area_img, [0.40, 0.60, 0.40, 0.60]), _crop(spot_img, [0.40, 0.60, 0.40, 0.60])])
	_check("P5 area / spot-rect", p5, 1.0, TOL)

	print("")
	if _failures.is_empty():
		print("PASS: all %d portal checks passed." % _checks)
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


## One inward-facing quad: centre, size (width, height), and the rotation
## that turns a +Z-facing QuadMesh toward the room.
func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## The room. Same numbers as cycles_portal_room.py room_quads(): x [-2,2],
## y [0,3], z [-1.5,1.5]; opening in the x = -2 wall, z [-0.6,0.6],
## y [0.9,1.9].
func _build_room(p_mat: Material) -> void:
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 3.0), Vector3(-90.0, 0.0, 0.0), p_mat) # floor, faces +Y
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 3.0), Vector3(90.0, 0.0, 0.0), p_mat) # ceiling, faces -Y
	_quad(Vector3(0.0, 1.5, -1.5), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), p_mat) # back, faces +Z
	_quad(Vector3(0.0, 1.5, 1.5), Vector2(4.0, 3.0), Vector3(0.0, 180.0, 0.0), p_mat) # front, faces -Z
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(3.0, 3.0), Vector3(0.0, -90.0, 0.0), p_mat) # right, faces -X
	# Left wall (faces +X), four quads around the opening.
	_quad(Vector3(-2.0, 0.45, 0.0), Vector2(3.0, 0.9), Vector3(0.0, 90.0, 0.0), p_mat) # below
	_quad(Vector3(-2.0, 2.45, 0.0), Vector2(3.0, 1.1), Vector3(0.0, 90.0, 0.0), p_mat) # above
	_quad(Vector3(-2.0, 1.4, -1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z < -0.6
	_quad(Vector3(-2.0, 1.4, 1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z > 0.6


## Builds the room with the portal "on", "off" or "flipped" and returns the
## accumulated frame.
func _render_room(p_portal: String, p_frames: int) -> Image:
	await _clear()
	_build_room(_lambert(ALBEDO))

	if p_portal != "off":
		var portal := AreaLight3D.new()
		portal.name = "Portal"
		portal.area_size = Vector2(1.2, 1.0)
		portal.area_normalize_energy = false
		portal.light_energy = 0.0
		portal.shadow_enabled = false
		portal.set("area_portal", true)
		add_child(portal)
		portal.position = Vector3(-2.0, 1.4, 0.0)
		var facing := Vector3(1.0, 0.0, 0.0) if p_portal == "on" else Vector3(-1.0, 0.0, 0.0)
		portal.look_at(portal.position + facing, Vector3.UP) # -Z toward `facing`

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.5, 1.2)
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.2, -1.5), Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(1.0)
	env.set_pathtracing_max_bounces(8)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)


## P5 fixture: a 4 x 4 floor (albedo 0.8) lit from 1 m above by a 1 x 1 m
## rectangle facing down, either an AreaLight3D or the 179.9 deg spot-rect
## (size = half-width, spot_angle_attenuation = half-height). Black world.
func _render_rect_light(p_kind: String, p_frames: int) -> Image:
	await _clear()
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 4.0), Vector3(-90.0, 0.0, 0.0), _lambert(ALBEDO))

	var light: Light3D
	if p_kind == "area":
		var a := AreaLight3D.new()
		a.area_size = Vector2(1.0, 1.0)
		a.area_normalize_energy = false
		a.set_param(Light3D.PARAM_RANGE, 10.0)
		a.set_param(Light3D.PARAM_ATTENUATION, 1.0)
		light = a
	else:
		var s := SpotLight3D.new()
		s.spot_angle = 180.0
		s.light_size = 0.5
		s.spot_angle_attenuation = 0.5
		s.spot_range = 10.0
		s.spot_attenuation = 1.0
		light = s
	light.light_energy = 1.0
	light.light_specular = 0.0
	light.shadow_enabled = false
	add_child(light)
	light.position = Vector3(0.0, 1.0, 0.0)
	light.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # -Z points down

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 2.5, 3.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(0.0)
	env.set_pathtracing_max_bounces(2)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)


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


## Per-pixel RMS of p_img against p_ref over a crop (luminance mean of RGB).
func _rms(p_img: Image, p_ref: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var a := p_img.get_pixel(x, y)
			var b := p_ref.get_pixel(x, y)
			var d := (a.r + a.g + a.b) / 3.0 - (b.r + b.g + b.b) / 3.0
			acc += d * d
			n += 1
	return sqrt(acc / float(maxi(n, 1)))


func _max_abs_diff(p_a: Image, p_b: Image) -> float:
	var m := 0.0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			m = maxf(m, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return m


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

Fill `CYCLES_P3_WALL` / `CYCLES_P3_FLOOR` and the `captured <date>` comment from Step 2.

`pipeline_references/tests/pt_portal_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_portal_gate.gd" id="1_gate"]

[node name="PTPortalGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 4: Run on the current binary — red by design**

```bash
$NEW --rendering-driver vulkan --path pipeline_references res://tests/pt_portal_gate_scene.tscn 2>&1 | grep -E "present|^  |^PASS|^FAIL" | tail -30
```

Expected: `area_portal present: false`; P1 green (both renders are the same scene: the energy-0 light contributes nothing); P2 ratio ≈ 1.0 → red (bar uncaptured); P3 — either colour (the map strategy is unbiased too; the number is what it is); P4 green; P5 red (the `AreaLight3D` renders as an omni today: expect a ratio far from 1). Record the P2 "ratio ≈ 1.0" and P5 numbers — they are the "before".

- [ ] **Step 5: Commit**

```bash
git add tools/cycles_comparison/cycles_portal_room.py pipeline_references/tests/pt_portal_gate.gd pipeline_references/tests/pt_portal_gate_scene.tscn
git commit -m "test(pt): light-portal gate (P1-P5) and its Cycles half; P2/P5 red by design

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `AreaLight3D.area_portal` through the storage layers

**Files:**
- Modify: `scene/3d/light_3d.h:275-300`, `scene/3d/light_3d.cpp:859-892`, `doc/classes/AreaLight3D.xml:21`
- Modify: `servers/rendering/rendering_server.h:313`, `servers/rendering/rendering_server.cpp:2526`, `servers/rendering/rendering_server_default.h:491`, `servers/rendering/storage/light_storage.h:60`, `servers/rendering/dummy/storage/light_storage.h:79`, `drivers/gles3/storage/light_storage.h:55,330`, `drivers/gles3/storage/light_storage.cpp:215`, `doc/classes/RenderingServer.xml:2235`
- Modify: `servers/rendering/renderer_rd/storage_rd/light_storage.h:68,520,635`, `servers/rendering/renderer_rd/storage_rd/light_storage.cpp:329,958`

**Interfaces:**
- Produces: `RenderingServer::light_set_portal(RID, bool)`; `RendererRD::LightStorage::light_is_portal(RID) const -> bool`; `AreaLight3D::set_area_portal(bool)` / `is_area_portal()`; property `area_portal`.

- [ ] **Step 1: Scene node**

`scene/3d/light_3d.h`, inside `class AreaLight3D` after `bool area_normalize_energy = true;`:

```cpp
	// Light portal (spec 2026-09-18-light-portals-design.md): a sampling hint
	// for the path tracer's sky, not a light. Blender's "Is Portal".
	bool area_portal = false;
```

and after `bool is_area_normalizing_energy() const;`:

```cpp
	void set_area_portal(bool p_enable);
	bool is_area_portal() const;
```

`scene/3d/light_3d.cpp`, after `is_area_normalizing_energy()`:

```cpp
void AreaLight3D::set_area_portal(bool p_enable) {
	area_portal = p_enable;
	RS::get_singleton()->light_set_portal(light, p_enable);
}

bool AreaLight3D::is_area_portal() const {
	return area_portal;
}
```

In `AreaLight3D::_bind_methods()`, after the `is_area_normalizing_energy` bind:

```cpp
	ClassDB::bind_method(D_METHOD("set_area_portal", "enable"), &AreaLight3D::set_area_portal);
	ClassDB::bind_method(D_METHOD("is_area_portal"), &AreaLight3D::is_area_portal);
```

and after the `area_normalize_energy` `ADD_PROPERTY`:

```cpp
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "area_portal"), "set_area_portal", "is_area_portal");
```

`doc/classes/AreaLight3D.xml`, after the `area_normalize_energy` member:

```xml
		<member name="area_portal" type="bool" setter="set_area_portal" getter="is_area_portal" default="false">
			If [code]true[/code], this area light is a [b]light portal[/b]: it emits nothing, but the path tracer aims part of its sky (environment) sampling through the rectangle from every point in front of it, which removes most of the noise of daylight entering a room through a window. Place one in each window opening, in the wall plane, facing into the room. Ignored by the rasterizer.
		</member>
```

- [ ] **Step 2: RenderingServer and the storage interfaces**

`servers/rendering/rendering_server.h`, after `virtual void light_set_negative(RID p_light, bool p_enable) = 0;`:

```cpp
	virtual void light_set_portal(RID p_light, bool p_enable) = 0;
```

`servers/rendering/rendering_server.cpp`, after the `light_set_negative` bind:

```cpp
	ClassDB::bind_method(D_METHOD("light_set_portal", "light", "enable"), &RenderingServer::light_set_portal);
```

`servers/rendering/rendering_server_default.h`, after `FUNC2(light_set_negative, RID, bool)`:

```cpp
	FUNC2(light_set_portal, RID, bool)
```

`servers/rendering/storage/light_storage.h`, after `virtual void light_set_negative(...) = 0;`:

```cpp
	virtual void light_set_portal(RID p_light, bool p_enable) = 0;
```

`servers/rendering/dummy/storage/light_storage.h`, after the `light_set_negative` stub:

```cpp
	virtual void light_set_portal(RID p_light, bool p_enable) override {}
```

`drivers/gles3/storage/light_storage.h`: after `bool negative = false;` add `bool portal = false;`; after the `light_set_negative` declaration add `virtual void light_set_portal(RID p_light, bool p_enable) override;`. `drivers/gles3/storage/light_storage.cpp`, after `light_set_negative`:

```cpp
void LightStorage::light_set_portal(RID p_light, bool p_enable) {
	Light *light = light_owner.get_or_null(p_light);
	ERR_FAIL_NULL(light);

	light->portal = p_enable;
}
```

(The Compatibility renderer stores the flag and keeps drawing the light; with the pipeline's `light_energy = 0` that is nothing. Recorded as out of scope.)

`doc/classes/RenderingServer.xml`, after the `light_set_negative` method:

```xml
		<method name="light_set_portal">
			<return type="void" />
			<param index="0" name="light" type="RID" />
			<param index="1" name="enable" type="bool" />
			<description>
				If [code]true[/code], the area light is a light portal for the path tracer: it emits nothing and guides sky sampling through its rectangle. Equivalent to [member AreaLight3D.area_portal].
			</description>
		</method>
```

- [ ] **Step 3: RD storage — the flag, the getter, the raster skip**

`servers/rendering/renderer_rd/storage_rd/light_storage.h`: in `struct Light` after `bool negative = false;`:

```cpp
		bool portal = false; // Light portal: skipped by the raster, a sky-sampling hint in the tracer.
```

after `virtual void light_set_negative(...) override;`:

```cpp
	virtual void light_set_portal(RID p_light, bool p_enable) override;
```

after `light_is_negative()`:

```cpp
	_FORCE_INLINE_ bool light_is_portal(RID p_light) const {
		const Light *light = light_owner.get_or_null(p_light);
		ERR_FAIL_NULL_V(light, false);

		return light->portal;
	}
```

`servers/rendering/renderer_rd/storage_rd/light_storage.cpp`, after `light_set_negative`:

```cpp
void LightStorage::light_set_portal(RID p_light, bool p_enable) {
	Light *light = light_owner.get_or_null(p_light);
	ERR_FAIL_NULL(light);

	light->portal = p_enable;
	light->dependency.changed_notify(Dependency::DEPENDENCY_CHANGED_LIGHT);
}
```

In `update_light_buffers()`, `case RSE::LIGHT_AREA: {` (line ~958), as the first statement of the case:

```cpp
				if (light->portal) {
					// A portal emits nothing (Cycles' Light::has_contribution
					// is false for it); the path tracer reads it separately.
					continue;
				}
```

- [ ] **Step 4: Build, doctest, property check**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 > "$S/build_t2.log" 2>&1; tail -3 "$S/build_t2.log"
$NEW --test 2>&1 | tail -3
ZR_GATE_FRAMES=16 $NEW --rendering-driver vulkan --path pipeline_references res://tests/pt_portal_gate_scene.tscn 2>&1 | grep -E "present" 
```

Expected: build clean; doctest count unchanged (1558/1558); `area_portal present: true`. (The gate itself is still red — P5 needs Task 3, P2 needs Task 4.)

- [ ] **Step 5: Commit**

```bash
git add scene/3d/light_3d.h scene/3d/light_3d.cpp doc/classes/AreaLight3D.xml doc/classes/RenderingServer.xml servers/rendering/rendering_server.h servers/rendering/rendering_server.cpp servers/rendering/rendering_server_default.h servers/rendering/storage/light_storage.h servers/rendering/dummy/storage/light_storage.h drivers/gles3/storage/light_storage.h drivers/gles3/storage/light_storage.cpp servers/rendering/renderer_rd/storage_rd/light_storage.h servers/rendering/renderer_rd/storage_rd/light_storage.cpp
git commit -m "feat(pt): AreaLight3D.area_portal through the storage layers; the Forward+ raster skips portals

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The portal buffer, the gather, and `AreaLight3D` as a rect light (P5 green)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:207-219,416,714`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:262,3501-3738,4306-4321,4605-4612`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:211`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:37`

**Interfaces:**
- Consumes: `RendererRD::LightStorage::light_is_portal(RID)`, `light_area_get_size(RID)`, `light_area_get_normalize_energy(RID)` (Task 2 / stock).
- Produces: `struct RT_PortalData` (64 B), `RT_PORTALS_MAX = 16`, `RTViewportState::portal_buffer`, binding 41 in the scene raytracing uniform set, `rt_params[18]` = live portal count, `gather_lights(const RenderDataRD *, RT_LightData *, uint32_t, RT_PortalData *, uint32_t &)`.

- [ ] **Step 1: Struct, capacity, state**

`render_raytracing.h`, after the `RT_LightData` static_asserts (line ~212):

```cpp
// Light portals (spec 2026-09-18-light-portals-design.md). A portal is a
// sampling hint for the sky, not a light: Cycles keeps them after the real
// lights in one array (scene/light.cpp:1416); ours get a buffer of their own
// because the miss stage -- which evaluates the portal pdf for MIS -- does not
// include the light buffer. Centre, unit axes, full side lengths and the
// facing direction (the light's -Z), i.e. Cycles' klight->area fields.
// MIRRORED IN raytracing_portal_inc.glsl (RTPortalData).
struct alignas(16) RT_PortalData {
	float position[3];
	float _pad0;
	float axis_u[3];
	float len_u;
	float axis_v[3];
	float len_v;
	float dir[3];
	float _pad1;
};
static_assert(sizeof(RT_PortalData) == 64, "RT_PortalData must be 64 bytes for std430");
static_assert(offsetof(RT_PortalData, axis_u) == 16, "RT_PortalData::axis_u must sit at offset 16");
static_assert(offsetof(RT_PortalData, dir) == 48, "RT_PortalData::dir must sit at offset 48");
```

In the `enum { RT_LIGHTS_MAX = 64, ... };` block add `RT_PORTALS_MAX = 16,`.

In `RTViewportState`, after `RID light_buffer;`:

```cpp
	RID portal_buffer; // RT_PORTALS_MAX x RT_PortalData, binding 41.
```

Change the declaration at line ~714 to:

```cpp
	uint32_t gather_lights(const RenderDataRD *p_render_data, RT_LightData *r_light_data, uint32_t p_max_lights, RT_PortalData *r_portal_data, uint32_t &r_portal_count);
```

`scene_shader_raytracing.h`, after `static constexpr int RT_PARAM_VOLUME_G = 17;`:

```cpp
	static constexpr int RT_PARAM_PORTAL_COUNT = 18; // live light portals (raytracing_portal_inc.glsl)
```

`raytracing_inc.glsl`, after the `RT_PARAM_VOLUME_G` define:

```glsl
#define RT_PARAM_PORTAL_COUNT 18 // rt_params[4].z - live light portals (raytracing_portal_inc.glsl)
```

- [ ] **Step 2: Free the buffer with the others**

`render_raytracing.cpp` ~line 262, after the `light_buffer` free:

```cpp
	if (p_state->portal_buffer.is_valid()) {
		RD::get_singleton()->free_rid(p_state->portal_buffer);
	}
```

- [ ] **Step 3: `gather_lights`**

Signature (line 3501):

```cpp
uint32_t RenderRaytracing::gather_lights(const RenderDataRD *p_render_data, RT_LightData *r_light_data, uint32_t p_max_lights, RT_PortalData *r_portal_data, uint32_t &r_portal_count) {
	uint32_t rt_light_count = 0;
	r_portal_count = 0;
```

In the `score_positional_light` lambda, right after `RID base = ls->light_instance_get_base_light(light_instance);`:

```cpp
		if (ls->light_get_type(base) == RSE::LIGHT_AREA && ls->light_is_portal(base)) {
			return; // A portal is not a light: never a candidate for NEE.
		}
```

In the fill loop, replace the type mapping

```cpp
		if (type == RSE::LIGHT_SPOT && spot_angle_deg >= 179.9f) {
			ld.type = RT_LIGHT_TYPE_RECT;
		} else {
			ld.type = (type == RSE::LIGHT_SPOT) ? RT_LIGHT_TYPE_SPOT : RT_LIGHT_TYPE_OMNI;
		}
```

with

```cpp
		if (type == RSE::LIGHT_AREA || (type == RSE::LIGHT_SPOT && spot_angle_deg >= 179.9f)) {
			// AreaLight3D is a rectangle; so is the 179.9 deg SpotLight3D
			// convention (size = half-width, spot_angle_attenuation = half-height).
			ld.type = RT_LIGHT_TYPE_RECT;
		} else {
			ld.type = (type == RSE::LIGHT_SPOT) ? RT_LIGHT_TYPE_SPOT : RT_LIGHT_TYPE_OMNI;
		}
```

Replace `float energy = compute_light_energy(base, type);` with

```cpp
		// An AreaLight3D takes the spot conversion so the two rect paths agree;
		// with area_normalize_energy the raster divides by the surface area
		// (light_storage.cpp update_light_buffers), and so do we.
		float energy = compute_light_energy(base, type == RSE::LIGHT_AREA ? RSE::LIGHT_SPOT : type);
		if (type == RSE::LIGHT_AREA && ls->light_area_get_normalize_energy(base)) {
			Vector2 area_size = ls->light_area_get_size(base);
			energy /= MAX(area_size.x * area_size.y, 1e-6f);
		}
```

In the `if (ld.type == RT_LIGHT_TYPE_RECT) {` block replace the two `hw` / `hh` reads with

```cpp
			float hw;
			float hh;
			if (type == RSE::LIGHT_AREA) {
				Vector2 area_size = ls->light_area_get_size(base);
				hw = area_size.x * 0.5f;
				hh = area_size.y * 0.5f;
			} else {
				hw = ls->light_get_param(base, RSE::LIGHT_PARAM_SIZE); // half-width
				hh = ls->light_get_param(base, RSE::LIGHT_PARAM_SPOT_ATTENUATION); // half-height
			}
```

Change the IES basis correction condition `if (type != RSE::LIGHT_SPOT) {` to `if (type != RSE::LIGHT_SPOT && type != RSE::LIGHT_AREA) {` (an area light is aimed like a spot; its IES slot is −1 anyway).

Before the final `return rt_light_count;` add the portal pass:

```cpp
	// Light portals: AreaLight3D with area_portal, from the AABB-culled RT
	// list. Not lights -- the sky sampler reads them (raytracing_portal_inc.glsl).
	if (p_render_data->rt_lights && r_portal_data) {
		const PagedArray<RID> &rt_lights = *p_render_data->rt_lights;
		for (uint32_t li = 0; li < (uint32_t)rt_lights.size(); li++) {
			RID light_instance = rt_lights[li];
			RID base = ls->light_instance_get_base_light(light_instance);
			if (ls->light_get_type(base) != RSE::LIGHT_AREA || !ls->light_is_portal(base)) {
				continue;
			}
			if (r_portal_count >= RT_PORTALS_MAX) {
				static bool warned = false;
				if (!warned) {
					WARN_PRINT(vformat("Path tracer: more than %d light portals in view; the rest are ignored.", (int)RT_PORTALS_MAX));
					warned = true;
				}
				break;
			}
			Transform3D xform = ls->light_instance_get_base_transform(light_instance);
			Basis b = xform.basis.orthonormalized();
			Vector3 axis_u = b.get_column(0);
			Vector3 axis_v = b.get_column(1);
			Vector3 dir = -b.get_column(2); // Godot lights face their local -Z.
			Vector2 area_size = ls->light_area_get_size(base);
			RT_PortalData &pd = r_portal_data[r_portal_count];
			pd.position[0] = xform.origin.x;
			pd.position[1] = xform.origin.y;
			pd.position[2] = xform.origin.z;
			pd._pad0 = 0.0f;
			pd.axis_u[0] = axis_u.x;
			pd.axis_u[1] = axis_u.y;
			pd.axis_u[2] = axis_u.z;
			pd.len_u = MAX(area_size.x, 1e-4f);
			pd.axis_v[0] = axis_v.x;
			pd.axis_v[1] = axis_v.y;
			pd.axis_v[2] = axis_v.z;
			pd.len_v = MAX(area_size.y, 1e-4f);
			pd.dir[0] = dir.x;
			pd.dir[1] = dir.y;
			pd.dir[2] = dir.z;
			pd._pad1 = 0.0f;
			r_portal_count++;
		}
	}

	return rt_light_count;
```

- [ ] **Step 4: Upload and bind**

At the caller (line ~4306) replace the gather block with:

```cpp
		// --- Light gathering ---
		uint32_t rt_light_count = 0;
		RT_LightData rt_light_data[RT_LIGHTS_MAX] = {};
		RT_PortalData rt_portal_data[RT_PORTALS_MAX] = {};
		uint32_t rt_portal_count = 0;

		rt_light_count = gather_lights(p_render_data, rt_light_data, RT_LIGHTS_MAX, rt_portal_data, rt_portal_count);

		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_LIGHT_COUNT] = float(rt_light_count);
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_PORTAL_COUNT] = float(rt_portal_count);

		// Upload light buffer.
		{
			uint32_t buf_size = RT_LIGHTS_MAX * sizeof(RT_LightData);
			if (!p_state->light_buffer.is_valid()) {
				p_state->light_buffer = RD::get_singleton()->storage_buffer_create(buf_size);
				RD::get_singleton()->set_resource_name(p_state->light_buffer, "RT Light Buffer");
			}
			RD::get_singleton()->buffer_update(p_state->light_buffer, 0, buf_size, rt_light_data);
		}

		// Upload the portal buffer (binding 41). Always uploaded: the shader
		// reads RT_PARAM_PORTAL_COUNT entries and a stale buffer would be read
		// the frame after the last portal leaves.
		{
			uint32_t buf_size = RT_PORTALS_MAX * sizeof(RT_PortalData);
			if (!p_state->portal_buffer.is_valid()) {
				p_state->portal_buffer = RD::get_singleton()->storage_buffer_create(buf_size);
				RD::get_singleton()->set_resource_name(p_state->portal_buffer, "RT Portal Buffer");
			}
			RD::get_singleton()->buffer_update(p_state->portal_buffer, 0, buf_size, rt_portal_data);
		}
```

In `update_uniform_set`, after the binding-40 block (line ~4611):

```cpp
	// Binding 41: light portals (SSBO, raytracing_portal_inc.glsl).
	{
		RD::Uniform u;
		u.binding = 41;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		if (p_state->portal_buffer.is_valid()) {
			u.append_id(p_state->portal_buffer);
		} else {
			u.append_id(RendererRD::MeshStorage::get_singleton()->get_default_rd_storage_buffer());
		}
		uniforms.push_back(u);
	}
```

Check the uniform set is created after the upload block in the same frame path (the light buffer at 13 already relies on this; the portal buffer follows the same order). If `update_uniform_set` is reached with `portal_buffer` invalid on the very first frame, the default buffer is bound and the shader reads `portal_count == 0` — safe.

Binding 41 is not yet declared in any shader; Godot's reflection ignores a uniform the pipeline does not declare? **No** — RD rejects a uniform set with a binding the shader lacks. So this task's build is verified with the GLSL declaration from Task 4 Step 1 (the SSBO block only) added now: put the `RTPortalData` struct + `layout(set = 0, binding = 41, std430) readonly buffer PortalBuffer { RTPortalData rt_portals[]; };` into the new `raytracing_portal_inc.glsl` and the `#include "raytracing_portal_inc.glsl"` line into `raytracing_common_inc.glsl` in this task (Task 4 fills in the functions). Exact text in Task 4 Step 1, first block.

- [ ] **Step 5: Build, run the gate — P5 green**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 > "$S/build_t3.log" 2>&1; tail -3 "$S/build_t3.log"
ZR_GATE_FRAMES=64 $NEW --rendering-driver vulkan --path pipeline_references res://tests/pt_portal_gate_scene.tscn 2>&1 | grep -E "^  |^PASS|^FAIL" | tail -20
```

Expected: P5 `area / spot-rect` 1 ± 1% (green). P2 still red (bar uncaptured), P1/P4 green, P3 as measured. No Vulkan validation error about binding 41 in the log (`grep -i "binding 41\|VUID" ` on the full output must be empty).

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_portal_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl
git commit -m "feat(pt): portal buffer (binding 41) and gather; AreaLight3D is a rect light in the tracer (P5 green)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Portal sampling and the sky mixture (P1–P4 green)

**Files:**
- Create/complete: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_portal_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:205`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl:129-215`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1868`, `scene_raytracing_raygen.glsl:130,557`
- Modify: `pipeline_references/tests/pt_portal_gate.gd` (`P2_BAR`)

**Interfaces:**
- Consumes: `rt_portals[]` at binding 41, `RT_PARAM_PORTAL_COUNT` (Task 3); `get_rt_param`, `env_dist`, `env_direction_from_uv`, `env_uv_from_direction`, `env_pdf_from_uv`, `env_world_to_sky` (existing).
- Produces: `bool env_sample(vec3 P, vec2 rand, out vec3 dir, out float pdf)`, `float env_pdf(vec3 P, vec3 dir)`; internal `env_map_sample`, `env_map_pdf`, `portal_*`.

- [ ] **Step 1: The portal include**

`servers/rendering/renderer_rd/shaders/raytracing/raytracing_portal_inc.glsl` (the first block — struct, SSBO, `portal_count` — is what Task 3 needs to build; the rest is this task):

```glsl
// Light portals (spec 2026-09-18-light-portals-design.md): a sampling hint for
// the sky, not a light. Transcribed from Cycles 5.3.0-alpha
// kernel/light/background.h (portal facing test, portal pdf, portal sample) and
// kernel/light/area.h (Urena spherical-rectangle sampling); the line cited
// above each function is the original.
//
// Included from raytracing_common_inc.glsl immediately before
// raytracing_env_sampling_inc.glsl, so every stage that has the sky sampler
// has the portals (the miss stage evaluates the portal pdf for MIS and does
// NOT include the light buffer -- hence a buffer of their own).
//
// Requires: get_rt_param (raytracing_common_inc.glsl), RT_PARAM_PORTAL_COUNT
// (raytracing_inc.glsl).

// MIRRORS C++ RT_PortalData (render_raytracing.h), 64 bytes, std430.
struct RTPortalData {
	vec3 position; // Rectangle centre, world space.
	float _pad0;
	vec3 axis_u; // Unit axis along the width (the light's local +X).
	float len_u; // Full width.
	vec3 axis_v; // Unit axis along the height (local +Y).
	float len_v; // Full height.
	vec3 dir; // Facing direction (local -Z); a point P is "in front" when dot(dir, P - position) > 0.
	float _pad1;
};

layout(set = 0, binding = 41, std430) readonly buffer PortalBuffer {
	RTPortalData rt_portals[];
};

int portal_count() {
	return int(get_rt_param(RT_PARAM_PORTAL_COUNT));
}

// util/math_base.h:571 safe_asinf.
float portal_safe_asin(float a) {
	return asin(clamp(a, -1.0, 1.0));
}

// util/math_base.h safe_divide: a / b, or 0 when b == 0.
float portal_safe_divide(float a, float b) {
	return (b != 0.0) ? a / b : 0.0;
}

// background.h:153 background_portal_data_fetch_and_check_side.
bool portal_fetch_and_check_side(int p_index, vec3 P, out vec3 r_pos, out vec3 r_dir) {
	r_pos = rt_portals[p_index].position;
	r_dir = rt_portals[p_index].dir;
	// Check whether portal is on the right side.
	return dot(r_dir, P - r_pos) > 1e-4;
}

// area.h:19 area_light_rect_sample -- Urena et al., "An Area-Preserving
// Parametrization for Spherical Rectangles", with Cycles' asin reformulation
// for small rectangles and its planar-pdf fallback. p_light_p is the centre on
// entry and, when p_sample_coord, the sampled point on exit. Returns the
// solid-angle pdf.
float portal_rect_sample(vec3 P, inout vec3 p_light_p, vec3 p_axis_u, float p_len_u, vec3 p_axis_v, float p_len_v, vec2 p_rand, bool p_sample_coord) {
	// Compute local reference system R.
	vec3 x = p_axis_u;
	vec3 y = p_axis_v;
	vec3 z = cross(x, y);
	// Compute rectangle coords in local reference system.
	vec3 dir = p_light_p - P;
	float z0 = dot(dir, z);
	// Flip 'z' to make it point against Q.
	if (z0 > 0.0) {
		z = -z;
		z0 = -z0;
	}
	float xc = dot(dir, x);
	float yc = dot(dir, y);
	float x0 = xc - 0.5 * p_len_u;
	float x1 = xc + 0.5 * p_len_u;
	float y0 = yc - 0.5 * p_len_v;
	float y1 = yc + 0.5 * p_len_v;
	// Compute predefined constants.
	vec4 nz = vec4(-y0, x1, y1, -x0);
	nz /= sqrt(nz * nz + vec4(z0 * z0));
	// asin(x) = pi/2 - acos(x): avoids the cancellation of the acos form for
	// very small rectangles (Cycles' comment at area.h:49).
	float g0 = portal_safe_asin(-nz.x * nz.y);
	float g1 = portal_safe_asin(-nz.y * nz.z);
	float g2 = portal_safe_asin(-nz.z * nz.w);
	float g3 = portal_safe_asin(-nz.w * nz.x);
	float S = -(g0 + g1 + g2 + g3);

	if (p_sample_coord) {
		// Compute predefined constants.
		float b0 = nz.x;
		float b1 = nz.z;
		float b0sq = b0 * b0;
		// Compute cu (area.h:64-72).
		float au = p_rand.x * S + g2 + g3;
		float fu = portal_safe_divide(cos(au) * b0 + b1, sin(au));
		float cu = ((fu >= 0.0) ? 1.0 : -1.0) / sqrt(fu * fu + b0sq); // copysignf(1/sqrt(...), fu)
		cu = clamp(cu, -1.0, 1.0);
		// Compute xu.
		float xu = -(cu * z0) / max(sqrt(1.0 - cu * cu), 1e-7);
		xu = clamp(xu, x0, x1);
		// Compute yv.
		float d2 = xu * xu + z0 * z0;
		float h0 = y0 / sqrt(d2 + y0 * y0);
		float h1 = y1 / sqrt(d2 + y1 * y1);
		float hv = h0 + p_rand.y * (h1 - h0);
		float hv2 = hv * hv;
		float yv = (hv2 < 1.0 - 1e-6) ? hv * sqrt(d2 / (1.0 - hv2)) : y1;

		// Transform (xu, yv, z0) to world coords.
		p_light_p = P + xu * x + yv * y + z0 * z;
	}

	// Return pdf (area.h:89-101): the solid angle is too small to be computed
	// accurately in single precision, or the rectangle is seen edge-on --
	// fall back to the planar pdf.
	vec4 nz2 = nz * nz;
	if (S < 1e-5 || min(min(nz2.x, nz2.y), min(nz2.z, nz2.w)) > 0.99999) {
		float t = length(dir);
		return portal_safe_divide(-t * t * t, z0 * p_len_u * p_len_v);
	}
	return 1.0 / S;
}

// util/math_intersect.h:288 ray_quad_intersect, rectangle only, tmin 1e-4,
// no tmax. p_inv_u / p_inv_v are axis / length, so |u|, |v| <= 0.5 is inside.
bool portal_ray_quad_intersect(vec3 P, vec3 D, vec3 p_quad_p, vec3 p_inv_u, vec3 p_inv_v, vec3 p_quad_n) {
	float denom = dot(D, p_quad_n);
	if (denom == 0.0) {
		return false;
	}
	float t = -(dot(P, p_quad_n) - dot(p_quad_p, p_quad_n)) / denom;
	if (!(t > 1e-4)) {
		return false;
	}
	vec3 hit = P + t * D;
	vec3 inplane = hit - p_quad_p;
	float u = dot(inplane, p_inv_u);
	if (u < -0.5 || u > 0.5) {
		return false;
	}
	float v = dot(inplane, p_inv_v);
	if (v < -0.5 || v > 0.5) {
		return false;
	}
	return true;
}

// background.h:247 background_num_possible_portals.
int portal_num_possible(vec3 P) {
	int n = 0;
	int count = portal_count();
	for (int p = 0; p < count; p++) {
		vec3 pos;
		vec3 dir;
		if (portal_fetch_and_check_side(p, P, pos, dir)) {
			n++;
		}
	}
	return n;
}

// background.h:173 background_portal_pdf. The pdf of direction D under the
// portal strategy at P: the mean over every portal facing P of that portal's
// solid-angle pdf (zero when D misses its quad). p_ignore_portal skips one
// portal's pdf but still counts it (the caller already holds it).
float portal_pdf(vec3 P, vec3 D, int p_ignore_portal, out bool r_is_possible) {
	r_is_possible = false;
	float pdf = 0.0;
	int num_possible = 0;
	int count = portal_count();
	for (int p = 0; p < count; p++) {
		if (p == p_ignore_portal) {
			continue;
		}
		vec3 pos;
		vec3 dir;
		if (!portal_fetch_and_check_side(p, P, pos, dir)) {
			continue;
		}
		// There's a portal that could be sampled from this position.
		r_is_possible = true;
		num_possible++;

		vec3 axis_u = rt_portals[p].axis_u;
		float len_u = rt_portals[p].len_u;
		vec3 axis_v = rt_portals[p].axis_v;
		float len_v = rt_portals[p].len_v;
		if (!portal_ray_quad_intersect(P, D, pos, axis_u / len_u, axis_v / len_v, dir)) {
			continue;
		}
		vec3 light_p = pos;
		pdf += portal_rect_sample(P, light_p, axis_u, len_u, axis_v, len_v, vec2(0.0), false);
	}
	if (p_ignore_portal >= 0) {
		// We have skipped a portal that could be sampled as well.
		num_possible++;
	}
	return (num_possible > 0) ? pdf / float(num_possible) : 0.0;
}

// background.h:260 background_portal_sample. Picks one of the p_num_possible
// facing portals uniformly on rand.y (renormalised), samples a point on it,
// returns the world direction; r_pdf is that portal's pdf / p_num_possible.
vec3 portal_sample(vec3 P, vec2 p_rand, int p_num_possible, out int r_sampled_portal, out float r_pdf) {
	r_sampled_portal = -1;
	r_pdf = 0.0;
	// Pick a portal, then re-normalize rand.y.
	p_rand.y *= float(p_num_possible);
	int portal = min(int(p_rand.y), p_num_possible - 1); // clamp: rand.y == 1.0 exactly would overrun
	p_rand.y -= float(portal);

	int count = portal_count();
	for (int p = 0; p < count; p++) {
		// Search for the sampled portal.
		vec3 pos;
		vec3 dir;
		if (!portal_fetch_and_check_side(p, P, pos, dir)) {
			continue;
		}
		if (portal == 0) {
			// p is the portal to be sampled.
			vec3 light_p = pos;
			r_pdf = portal_rect_sample(P, light_p, rt_portals[p].axis_u, rt_portals[p].len_u, rt_portals[p].axis_v, rt_portals[p].len_v, p_rand, true);
			r_pdf /= float(p_num_possible);
			r_sampled_portal = p;
			return normalize(light_p - P);
		}
		portal--;
	}
	return vec3(0.0);
}
```

`raytracing_common_inc.glsl`, immediately before `#include "raytracing_env_sampling_inc.glsl"`:

```glsl
// Light portals: declared before the sky sampler, which mixes them in.
#include "raytracing_portal_inc.glsl"
```

- [ ] **Step 2: The mixture in the sky sampler**

In `raytracing_env_sampling_inc.glsl`:

1. Rename today's `float env_pdf(vec3 p_dir)` to `float env_map_pdf(vec3 p_dir)` (body unchanged) and today's `bool env_sample(vec2 p_rand, out vec3 r_dir, out float r_pdf)` to `bool env_map_sample(vec2 p_rand, out vec3 r_dir, out float r_pdf)` (body unchanged). Update the doc comments' first lines to say "the MAP strategy".
2. Append, after `env_map_sample`:

```glsl
// ---------------------------------------------------------------------------
// Light portals (spec 2026-09-18-light-portals-design.md). Cycles'
// background_light_sample / background_light_pdf (kernel/light/background.h:
// 333-470) minus the Nishita sun strategy: the map strategy above and the
// portal strategy (raytracing_portal_inc.glsl) mixed 1:1 whenever at least one
// portal faces P (background_num_possible_portals > 0), map only otherwise.
// Both entry points take the shading position because the mixture depends on
// which portals face it; the miss stage passes the ray origin, as Cycles'
// light/sample.h:591 passes ray_P. With no portal in the buffer both collapse
// to the map strategy exactly as before -- bit-identical renders.
//
// The "no sky" contract is kept from the map sampler: marginal_total <= 0
// means no usable sky, env_sample() returns false and env_pdf() 0, so NEE
// and MIS agree that the sky strategy does not exist (Cycles falls back to
// uniform sphere sampling there; a black sky makes that moot).
// ---------------------------------------------------------------------------

/// Sample a sky direction from P. r_dir is WORLD-space; r_pdf is the mixture's
/// pdf for it (background.h:333-433).
bool env_sample(vec3 P, vec2 p_rand, out vec3 r_dir, out float r_pdf) {
	r_dir = vec3(0.0, 1.0, 0.0);
	r_pdf = 0.0;
	if (env_dist.marginal_total <= 0.0) {
		return false;
	}

	float portal_method_pdf = 0.0;
	int num_portals = 0;
	if (portal_count() > 0) {
		// Check if there are portals in the scene which we can sample.
		num_portals = portal_num_possible(P);
		portal_method_pdf = (num_portals > 0) ? 1.0 : 0.0;
	}
	float map_method_pdf = 1.0;

	// We have 100% in total and split it between the two categories (Cycles
	// splits three, background.h:351-367): portals if rand.x is below
	// portal_method_pdf, map otherwise.
	float pdf_fac = 1.0 / (portal_method_pdf + map_method_pdf);
	portal_method_pdf *= pdf_fac;
	map_method_pdf *= pdf_fac;

	if (p_rand.x < portal_method_pdf) {
		// Rescale rand.x.
		p_rand.x /= portal_method_pdf;
		// Sample a portal.
		int portal;
		float pdf;
		r_dir = portal_sample(P, p_rand, num_portals, portal, pdf);
		if (portal < 0) {
			return false;
		}
		if (num_portals > 1) {
			// Ignore the chosen portal, its pdf is already included.
			bool unused;
			pdf += portal_pdf(P, r_dir, portal, unused);
		}
		// MIS weighting against the map strategy.
		r_pdf = pdf * portal_method_pdf + env_map_pdf(r_dir) * map_method_pdf;
	} else {
		// Rescale rand.x.
		if (map_method_pdf != 1.0) {
			p_rand.x = (p_rand.x - portal_method_pdf) / map_method_pdf;
		}
		float pdf;
		if (!env_map_sample(p_rand, r_dir, pdf)) {
			return false;
		}
		// Skip MIS if this is the only method.
		if (map_method_pdf == 1.0) {
			r_pdf = pdf;
			return r_pdf > 0.0;
		}
		bool unused;
		r_pdf = pdf * map_method_pdf + portal_pdf(P, r_dir, -1, unused) * portal_method_pdf;
	}
	r_pdf = isnan(r_pdf) ? 0.0 : r_pdf;
	return r_pdf > 0.0;
}

/// pdf of the mixture for an arbitrary WORLD-space direction from P
/// (background.h:436-470). Same NaN firewall as env_map_pdf.
float env_pdf(vec3 P, vec3 p_dir) {
	if (env_dist.marginal_total <= 0.0) {
		return 0.0;
	}
	float pdf = env_map_pdf(p_dir);
	if (portal_count() > 0) {
		// Portals are a special case here since we need to compute their pdf in
		// order to find out if we can sample them.
		bool is_possible = false;
		float portal_pdf_val = portal_pdf(P, p_dir, -1, is_possible);
		if (is_possible) {
			pdf = 0.5 * pdf + 0.5 * portal_pdf_val;
		}
	}
	pdf = isnan(pdf) ? 0.0 : pdf;
	return max(pdf, 0.0);
}
```

Also update the file header's "CRITICAL INVARIANT" paragraph: `env_sample()` and `env_pdf()` must agree — now including the portal mixture, and both must be given the **same position** the ray starts from.

- [ ] **Step 3: The three call sites**

`raytracing_closest_hit_common_inc.glsl:1868`: `env_sample(rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val)` → `env_sample(h.hit_pos, rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val)`.

`scene_raytracing_raygen.glsl:130` (the F2 scatter site in `volume_scatter_shade`): `env_sample(rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val)` → `env_sample(p_pos, rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val)`.

`scene_raytracing_raygen.glsl:557` (miss stage): `float e_pdf = env_pdf(gl_WorldRayDirectionEXT);` → `float e_pdf = env_pdf(gl_WorldRayOriginEXT, gl_WorldRayDirectionEXT);` with, above it, the comment line: `// Light portals: the mixture depends on which portals face the ray's origin (Cycles passes ray_P, light/sample.h:591).`

Verify no other caller: `grep -rn "env_sample(\|env_pdf(" servers/rendering/renderer_rd/shaders/` shows exactly the definitions, the two internal `env_map_*` uses, and the three sites.

- [ ] **Step 4: Build, run the gate, capture P2**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 > "$S/build_t4.log" 2>&1; tail -3 "$S/build_t4.log"
$NEW --rendering-driver vulkan --path pipeline_references res://tests/pt_portal_gate_scene.tscn 2>&1 | grep -E "^  |^PASS|^FAIL" | tail -24
```

Expected: P1 wall and floor 1 ± 1% (the mixture is unbiased — if either is off by more than 1%, the pdf and the sampler disagree: first suspect is the portal's own pdf not being added for the *other* facing portals — n/a here with one portal — then `env_map_pdf` vs `env_map_sample` for a direction that came from the portal, then the miss-stage position); P3 within 3% of Cycles; P4 flipped vs off ≤ floor; **P2 ratio printed** — expected around 0.3–0.6. If the ratio is not below 0.67, stop: the portal is not doing its job (check that `portal_num_possible` returns 1 for a back-wall point: temporarily `ps.radiance = vec3(float(portal_num_possible(h.hit_pos)))` under a debug vis mode is the fastest instrument).

Write the bar: `P2_BAR := <measured ratio × 1.5, rounded up to 2 decimals, and < 1.0>` with the measured value and date in the comment. Re-run: **5/5 green**.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_portal_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_env_sampling_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl pipeline_references/tests/pt_portal_gate.gd
git commit -m "feat(pt): light portals -- Cycles' portal/map sky mixture with Urena rect sampling (P2 <ratio>, P3 <wall>%/<floor>% vs Cycles)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Pipeline hookup and the asset check

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd:503` (call site), new function after `_create_window_portal_lights()` — **user's file: edit, never stage or commit**.

**Interfaces:**
- Consumes: `_window_sunlight_data` records (`center`, `width`, `height`, `inner_dir`), `day_render`; `AreaLight3D.area_portal` (Task 2).

- [ ] **Step 1: The function and its call**

Insert after `_create_window_portal_lights()` (before the `# -- Subtle SpotLights for non-window holes` tail ends, i.e. after that function's last line):

```gdscript
# ---------------------------------------------------------------------------
# _create_window_portals
# ---------------------------------------------------------------------------
# Light portals (engine spec 2026-09-18-light-portals-design.md). An AreaLight3D
# with area_portal is NOT a light: it emits nothing and casts nothing, the
# raster ignores it, and the path tracer aims half of its sky samples through
# the rectangle from every point that faces it -- Cycles' portal. One per
# window opening, in the wall plane, facing into the room. The window glass
# itself keeps cast_shadow OFF (Gap #30) so the sky gets through.
# The portal spots (_create_window_portal_lights) stay for now; the daylight
# design (Gap #31) is what replaces them.
func _create_window_portals() -> void:
	if not day_render or _window_sunlight_data.is_empty():
		return
	for i in range(_window_sunlight_data.size()):
		var win = _window_sunlight_data[i]
		var center = win["center"] as Vector3
		var inner_dir = (win["inner_dir"] as Vector3).normalized()
		var portal := AreaLight3D.new()
		portal.name = "WindowPortal_" + str(i)
		portal.area_size = Vector2(float(win["width"]), float(win["height"]))
		portal.area_normalize_energy = false
		portal.light_energy = 0.0
		portal.shadow_enabled = false
		# set(): a binary without the property ignores it instead of failing to parse.
		portal.set("area_portal", true)
		add_child(portal)
		portal.position = center
		portal.look_at(center + inner_dir, Vector3.UP) # -Z points into the room
		print("  [Portal] window ", i, " at ", center, " size=", portal.area_size, " facing ", inner_dir)
```

At the call site (`if day_render:` block, line ~503) add, right after `_create_window_portal_lights()`:

```gdscript
		_create_window_portals()
```

- [ ] **Step 2: Job 226 through the still route, portals on**

Copy the previous session's scratch project (it already holds the 226 input and `day.exr`) into this session's scratchpad and overlay the edited script:

```bash
PREV="/c/Users/aiadmin/AppData/Local/Temp/claude/C--Users-aiadmin-Desktop-Engine-Build-test-Zreal-Engine/012f0870-88b3-476f-a0b6-d65dd20daf7c/scratchpad"
mkdir -p "$S/proj_225" && cp -r "$PREV/proj_225/." "$S/proj_225/" && cp pipeline_references/image_glb_creation.gd "$S/proj_225/image_glb_creation.gd" && cp pipeline_references/render.gd "$S/proj_225/render.gd"
export ZR_PT_EXR=1; unset ZR_PHASE_A ZR_PT_FINAL ZR_LIGHTS_SKIP
T0=$(date +%s); ./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" res://main.tscn -- "$S/proj_225/input_json/f2_226_input.json" "$S/portal_226.png" > "$S/portal_226_godot.log" 2>&1; echo "exit=$? secs=$(( $(date +%s) - T0 ))"
grep -c "\[Portal\] window" "$S/portal_226_godot.log"
```

Expected: exit 0; N `[Portal]` lines (one per window the plan collected); wall-clock within a few % of the F2 run (207 s at FHD in §11.30). "Before" is `$PREV/f2_226.png` (same scene, same rig, F2 binary). Diff map + crops with `$PREV/bump/compare_226.py` pointed at the two files; `SendUserFile` both crops. Because the portal spots and fills are still on, the *mean* should not move (the portal changes variance, not the answer) — report the noise change on a wall crop (per-pixel std of the difference) and any mean shift > 1% as a finding.

- [ ] **Step 3: Sun + sky + portals only**

```bash
export ZR_LIGHTS_SKIP=pos
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" res://main.tscn -- "$S/proj_225/input_json/f2_226_input.json" "$S/portal_226_sky.png" > "$S/portal_226_sky_godot.log" 2>&1; echo "exit=$?"; unset ZR_LIGHTS_SKIP
```

This is the picture sub-project B starts from: the room lit by the sun and the sky through the windows alone, with the portal sampling. `SendUserFile` it with the exposure it comes out at; note the frame mean (it will be dark — §11.27's "0.0175" was this frame without portals).

- [ ] **Step 4: No commit** (user's file). Note in the closeout that `image_glb_creation.gd` carries `_create_window_portals()` uncommitted.

---

### Task 6: Regression suite, cost, roadmap, finishing

- [ ] **Step 1: Whole suite, old binary first, then new**

```bash
for s in pipeline_references/tests/pt_*_gate_scene.tscn pipeline_references/tests/png16_encoding_gate_scene.tscn; do n=$(basename $s .tscn); echo "== $n"; "$OLD" --rendering-driver vulkan --path pipeline_references res://tests/$n.tscn 2>&1 | grep -E "^PASS|^FAIL" | tail -1; done
```

then the same with `$NEW`. Expected: old binary — green except `pt_portal_gate` (P2/P5 red; P3 either), plus the F1/F2-designed reds if `$OLD` still predates them (`pt_bump_correction_gate`, `pt_volume_gate`, energy `bumpy`, transmission probe 10 — check which hand-over binary is at `$OLD` today with `ls -l`); new binary — **22/22**. Any other red on the new binary: bisect Tasks 3–4 on the engine paths only (`git checkout <sha> -- servers/`, rebuild, `git checkout HEAD -- servers/`).

- [ ] **Step 2: Cost with no portal**

Three timing passes on `pt_light_rmse_scene.tscn` per binary (old vs new): expected identical within noise — the only new work per sky sample is one uniform read and a branch. With portals: the 226 wall-clock from Task 5 Step 2.

- [ ] **Step 3: Doctest**

```bash
$NEW --test 2>&1 | tail -3
```

Expected: count unchanged.

- [ ] **Step 4: Roadmap and the gap file**

`PATH_TRACER_QUALITY_ROADMAP.md`: new **§11.31 Light portals** in the house style — what the source says (portal = sampling hint, 1:1 with the map, facing test, Ureña), why a separate buffer (the miss stage), the gate table with readings (P1–P5, P2's ratio is the headline), the 226 findings, cost, and recorded follow-ups (ellipse portals, Ureña for ordinary rect lights, `sun_weight` for a Nishita sun, the daylight design B). Gap-table: add a row `| 33 | **No light portals — CLOSED 2026-09-18 (§11.31).** … | `raytracing_portal_inc.glsl`, `env_sample(P, …)` | `background.h:333`, `area.h:19` | **Closed** |` and mention in row 31 that the portal spots now have a physical replacement waiting for B.

`Full_Architectural_Gap_Roadmap.md` (user's file — **ask before editing**; if yes): §1 Lights row "no portals" → "portals via `AreaLight3D.area_portal`"; §3 Lights table: strike the "Light portals" row with the date; §4 item 1 becomes "the daylight design (portals done 2026-09-18)".

- [ ] **Step 5: Commit; finishing menu**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): light portals closeout (11.31)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Then present keep / push / merge, as every phase, and remind the user that `bin/` and the uncommitted `image_glb_creation.gd` (`_create_window_portals`) are what to carry to the live project.
