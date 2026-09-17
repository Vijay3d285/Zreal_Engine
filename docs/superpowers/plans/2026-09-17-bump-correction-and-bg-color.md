# Phase F1 + F3 — Bump-map correction and flat-colour world Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tracer's two home-grown grazing-angle rules (0.4 normal clamp, mirror recovery) with Cycles' three (`ensure_valid_specular_reflection`, below-face rejection, `bump_shadowing_term`) on a true face normal, and make a `BG_COLOR` environment light the tracer instead of rendering black.

**Architecture:** `HitData` gains the triangle's true face normal (`face_normal`, Cycles' `Ng`); `brdf_inc.glsl` gains the two Cycles functions and loses `clampShadingNormal` / `recoverBelowHemisphereSample`; `MaterialProperties` carries the smooth and raw bump normals so the bump-shadowing term lives inside the two BRDF entry points every NEE site already uses. F3 is one C++ block in `update_uniform_set`'s binding-7 code: a 1×1 texture holding the environment's linear background colour × energy.

**Tech Stack:** GLSL (Vulkan ray tracing), C++ (Godot RD renderer), GDScript gate, Blender 5.2.1 Python for the Cycles half.

**Spec:** `docs/superpowers/specs/2026-09-17-bump-correction-and-bg-color-design.md`

## Global Constraints

- Build: `python -m SCons platform=windows target=editor tests=yes -j8` (bare `scons` is not on PATH). Shaders are code-generated: every `.glsl` edit needs a full build, and a clean build proves nothing about GLSL — only a render does.
- Gates run only in a **connected desktop session** (`query session` shows the console session `Active`); a disconnected RDP session moves readings by 24%.
- Gate command form: `bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/<name>_scene.tscn` — the `.tscn` suffix is mandatory (without it Godot opens an alert dialog on the user's screen).
- `pipeline_references/*.gd` at the top level are the user's files: never stage, commit, revert or checkout over them. Files under `pipeline_references/tests/` are this workstream's gates and may be edited and committed.
- `git add` with explicit paths only. Never `-A`, never `.`, never `commit -a`.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Render outputs and scratch scripts go to the scratchpad directory, never into the repo or `C:\Zlendo2026\ZlenderRender_stage_copy` (read-only).
- Do not change system settings (`TdrDelay`).
- Before bisecting any gate regression, run the same gate on the previous binary (`C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\godot.windows.editor.x86_64.console.exe` is the last hand-over build) — memory `pt-gate-regression-run-old-binary-first`.
- Blender: `"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P <script> -- <out_dir>`.
- Existing gate references that this work is *expected* to move: `pt_energy_gate` `REF_BUMPY` (1.41124) and possibly `REF_ROUGH` (1.63024) / `REF_ROUGH_RIM`. Any other gate moving is a defect to investigate, not a reference to re-capture.

---

## File map

| File | Responsibility in this plan |
|---|---|
| `tools/cycles_comparison/cycles_bump_grazing.py` | **Create.** Cycles half of the gate: tilted normal-mapped plane, three materials, two tilts; prints `@@@` lines with patch means. |
| `pipeline_references/tests/pt_bump_correction_gate.gd` + `_scene.tscn` | **Create.** Probes A (furnace ≤ 1), B0/B1/B2 (vs Cycles), C (flat world equivalence). |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | **Modify.** `HitData.face_normal`; `shade_and_bounce` normal setup; delete mirror path; `MaterialProperties` construction sites; `debug_visualize` signature + vis-mode reconstruction sites; SSS entry test. |
| `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` | **Modify.** Add `ensureValidSpecularReflection`, `bumpShadowingTerm`; delete `clampShadingNormal`, `mirrorDirectionAcrossPlane`, `recoverBelowHemisphereSample` and their macros; `MaterialProperties.smoothNormal/bumpNormal`; apply the term in `evalCombinedBRDFSeparate` and `evalIndirectCombinedBRDF`. |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | **Modify.** The two `debug_visualize(...)` calls gain `h.face_normal`. |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h/.cpp` | **Modify.** F3: `flat_world_texture` + `_get_flat_world_texture`, used in the binding-7 block; freed in the destructor. |
| `pipeline_references/tests/pt_energy_gate.gd` | **Modify.** Re-capture `REF_BUMPY` (and `REF_ROUGH*` if moved) with the reason recorded. |
| `PATH_TRACER_QUALITY_ROADMAP.md` | **Modify.** Row 15 closed, F1/F3 marked done in §4, new §11.29 closeout. |

---

### Task 1: The gate and its Cycles half (red on the current binary)

**Files:**
- Create: `tools/cycles_comparison/cycles_bump_grazing.py`
- Create: `pipeline_references/tests/pt_bump_correction_gate.gd`
- Create: `pipeline_references/tests/pt_bump_correction_gate_scene.tscn`

**Interfaces:**
- Produces: gate constants `CYCLES_B0`, `CYCLES_B1`, `CYCLES_B2` (floats, patch means from Blender), `BAR_B0 = 0.01`, `BAR_B = 0.03`, `FURNACE_MAX = 1.005`, `FLAT_TOL = 0.01`. Probe names printed as `A furnace`, `B0 cycles 10deg`, `B1 cycles 80deg dielectric`, `B2 cycles 80deg metal`, `C flat world`.
- Consumes: `pt_validation.gd`'s `_render_accum(env, vp_rid, frames) -> Image` and `RESET_SETTLE_FRAMES`.

Scene, identical in both engines: a 200 × 200 quad, normal +Z (Godot `QuadMesh` faces +Z; Blender `primitive_plane_add` faces +Z), tilted about X by `acos(mu)`; perspective camera at `(0, 0, 150)` looking at the origin with a **4° vertical** field of view (the `pt_sheen_gate` probe-G construction, so every ray meets the plane within ±0.016 rad of the nominal angle); 256 × 256; uniform white world. The normal map is the energy gate's sine pattern (`_bump_normal_map`), 128 × 128, no mipmaps in either engine, tiled 10× across the quad (Godot `uv1_scale = (10, 10, 1)`, Blender a Mapping node scale 10). The pattern is symmetric under x↔y, so the patch mean is invariant to the tangent-frame convention.

- [ ] **Step 1: Write the Cycles script**

```python
# Bump-map correction at grazing angles against Cycles -- the pt_bump_correction_gate
# stimulus (spec 2026-09-17-bump-correction-and-bg-color-design.md, roadmap F1).
#
# A 200 x 200 plane (normal +Z) tilted about X by acos(mu), seen by a 4-degree
# perspective camera at (0, 0, 150), under a uniform world. Tangent-space normal
# map: the pt_energy_gate sine pattern (0.85 sin u, 0.85 sin v, 0.45), 128 px,
# 8 periods per tile, 10 tiles across the plane, no mipmaps, strength 1.
# Cycles' Bump Map Correction is left at its default (on).
#
#   B0  mu = cos 10deg, dielectric albedo 1.0 roughness 0.4, world 0.5
#   B1  mu = cos 80deg, same material
#   B2  mu = cos 80deg, metal (Metallic 1) roughness 0.4, world 0.5
#   A   mu = cos 80deg, dielectric, world 1.0   (furnace; printed for reference)
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_bump_grazing.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "256"))
NMAP = 128
TILES = 10.0
QUAD = 200.0
CAM_DIST = 150.0
CAM_FOV_DEG = 4.0


def make_normal_map():
    img = bpy.data.images.new("bump", NMAP, NMAP, alpha=False, float_buffer=True)
    # Colourspace first: changing it after the pixels are set regenerates the
    # buffer (cycles_oidn_checker.py learned this the hard way).
    img.colorspace_settings.name = "Non-Color"
    px = [0.0] * (NMAP * NMAP * 4)
    for y in range(NMAP):
        for x in range(NMAP):
            u = x / NMAP * 2.0 * math.pi * 8.0
            v = y / NMAP * 2.0 * math.pi * 8.0
            nx, ny, nz = 0.85 * math.sin(u), 0.85 * math.sin(v), 0.45
            ln = math.sqrt(nx * nx + ny * ny + nz * nz)
            nx, ny, nz = nx / ln, ny / ln, nz / ln
            i = (y * NMAP + x) * 4
            px[i:i + 4] = [nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0]
    img.pixels.foreach_set(px)
    img.update()
    img.pack()
    return img


def build(mu, metallic, world_strength):
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

    bpy.ops.mesh.primitive_plane_add(size=QUAD)
    plane = bpy.context.object
    plane.rotation_euler = (math.acos(mu), 0.0, 0.0)

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = 0.4
    bsdf.inputs["IOR"].default_value = 1.5
    bsdf.inputs["Specular IOR Level"].default_value = 0.5  # F0 0.04, Godot's metallic_specular default
    bsdf.inputs["Sheen Weight"].default_value = 0.0
    bsdf.inputs["Coat Weight"].default_value = 0.0
    uv = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (TILES, TILES, 1.0)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = make_normal_map()
    tex.interpolation = "Linear"
    tex.extension = "REPEAT"
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nmap.space = "TANGENT"
    nmap.inputs["Strength"].default_value = 1.0
    nt.links.new(uv.outputs["UV"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
    nt.links.new(tex.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    plane.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam_data.clip_end = 4000.0
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, 0.0, CAM_DIST)
    cam.rotation_euler = (0.0, 0.0, 0.0)  # looks down -Z at the plane


def patch_mean(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    acc, n = 0.0, 0
    for y in range(int(0.3 * h), int(0.7 * h)):
        for x in range(int(0.3 * w), int(0.7 * w)):
            i = (y * w + x) * 4
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return acc / n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ BUMP GRAZING vs Cycles @@@")
print("@@@ blender: %s  samples %d" % (bpy.app.version_string, SAMPLES))
for tag, mu, metallic, strength in (
        ("B0", math.cos(math.radians(10.0)), 0.0, 0.5),
        ("B1", math.cos(math.radians(80.0)), 0.0, 0.5),
        ("B2", math.cos(math.radians(80.0)), 1.0, 0.5),
        ("A", math.cos(math.radians(80.0)), 0.0, 1.0)):
    build(mu, metallic, strength)
    p = os.path.join(OUT, "bump_%s.exr" % tag)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    print("@@@ %-3s mu %.4f metallic %.0f world %.1f  patch mean %.6f" % (tag, mu, metallic, strength, patch_mean(p)))
print("@@@ DONE")
```

- [ ] **Step 2: Run it and record the numbers**

```bash
mkdir -p "$SCRATCH/bump" && "/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b -P tools/cycles_comparison/cycles_bump_grazing.py -- "$SCRATCH/bump" 2>&1 | grep "@@@"
```

Expected: four `@@@` lines. Write the B0/B1/B2 values into the gate constants in Step 3. Sanity: `A` must be ≤ 1.0 (Cycles' furnace does not exceed 1); B0 ≈ 0.5 × (directional albedo near normal incidence ≈ 0.96) ≈ 0.48; B2 < B1 is not required (a rough metal at grazing can exceed a dielectric).

- [ ] **Step 3: Write the gate**

`pipeline_references/tests/pt_bump_correction_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_bump_correction_gate.gd" id="1_gate"]

[node name="PTBumpCorrectionGate" type="Node"]
script = ExtResource("1_gate")
```

`pipeline_references/tests/pt_bump_correction_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Bump-map correction gate (spec 2026-09-17-bump-correction-and-bg-color-design.md,
## roadmap Phase F1 / Gap #15, and F3).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_bump_correction_gate_scene.tscn
##
## Cycles handles a normal-mapped surface at grazing angles with three rules
## (ensure_valid_specular_reflection, below-face rejection, bump_shadowing_term)
## on the true face normal. Until F1 the tracer lerped every lobe's normal
## toward the smooth normal below NdotV 0.4 and MIRRORED rejected samples while
## keeping their weight -- over-bright and detail-flattening at grazing view.
##
## Same construction as pt_sheen_gate probe G: a 200 x 200 quad tilted about X
## by acos(mu), 4-degree camera at (0, 0, 150), so every ray meets the plane
## within +-0.016 rad of the nominal angle. Tangent-space sine normal map
## (pt_energy_gate's _bump_normal_map), tiled 10x, no mipmaps, strength 1.
## Cycles half: tools/cycles_comparison/cycles_bump_grazing.py.
##
##   A  furnace: dielectric, world 1.0, 80 deg  : <= FURNACE_MAX
##   B0 vs Cycles, dielectric, world 0.5, 10 deg : within BAR_B0
##   B1 vs Cycles, dielectric, world 0.5, 80 deg : within BAR_B
##   B2 vs Cycles, metal,      world 0.5, 80 deg : within BAR_B
##   C  flat world (F3): Lambertian sphere under BG_COLOR vs the same colour
##      as a BG_SKY flat panorama                 : ratio 1.0 +- FLAT_TOL

var FRAMES: int = 256 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const FURNACE_MAX := 1.005
const BAR_B0 := 0.01
const BAR_B := 0.03
const FLAT_TOL := 0.01
# Cycles 5.2.1, 256 spp, cycles_bump_grazing.py, captured 2026-09-17 (Task 1 Step 2).
const CYCLES_B0 := 0.0 # <- fill from the @@@ B0 line
const CYCLES_B1 := 0.0 # <- fill from the @@@ B1 line
const CYCLES_B2 := 0.0 # <- fill from the @@@ B2 line

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

	print("\n=== A: furnace, dielectric, 80 deg ===")
	var a := await _plane_mean(cos(deg_to_rad(80.0)), 0.0, 1.0)
	_check("A furnace", a, 0.0, FURNACE_MAX)

	print("\n=== B0: vs Cycles, dielectric, 10 deg ===")
	var b0 := await _plane_mean(cos(deg_to_rad(10.0)), 0.0, 0.5)
	_check_vs("B0 cycles 10deg", b0, CYCLES_B0, BAR_B0)

	print("\n=== B1: vs Cycles, dielectric, 80 deg ===")
	var b1 := await _plane_mean(cos(deg_to_rad(80.0)), 0.0, 0.5)
	_check_vs("B1 cycles 80deg dielectric", b1, CYCLES_B1, BAR_B)

	print("\n=== B2: vs Cycles, metal, 80 deg ===")
	var b2 := await _plane_mean(cos(deg_to_rad(80.0)), 1.0, 0.5)
	_check_vs("B2 cycles 80deg metal", b2, CYCLES_B2, BAR_B)

	print("\n=== C: flat world, BG_COLOR vs BG_SKY panorama ===")
	var c := await _flat_world_ratio()
	_check("C flat world", c, 1.0 - FLAT_TOL, 1.0 + FLAT_TOL)

	print("")
	if _failures.is_empty():
		print("PASS: all %d bump-correction checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	print("  %s: %.6f (band [%.4f, %.4f])" % [p_name, p_value, p_lo, p_hi])
	if p_value < p_lo or p_value > p_hi:
		_failures.append("%s: %.6f outside [%.4f, %.4f]" % [p_name, p_value, p_lo, p_hi])


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


## Mean over the centre 40% crop of a normal-mapped quad tilted to mu under a
## uniform world of the given strength.
func _plane_mean(p_mu: float, p_metallic: float, p_world: float) -> float:
	await _clear()
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(200.0, 200.0)
	quad.mesh = qm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.metallic = p_metallic
	m.metallic_specular = 0.5
	m.roughness = 0.4
	m.normal_enabled = true
	m.normal_scale = 1.0
	m.normal_texture = _bump_normal_map()
	m.uv1_scale = Vector3(10.0, 10.0, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR # no mipmaps: the map is created without them
	quad.material_override = m
	quad.rotation = Vector3(acos(p_mu), 0.0, 0.0)
	add_child(quad)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 4.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 4000.0
	cam.position = Vector3(0.0, 0.0, 150.0)
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(Color(p_world, p_world, p_world), 1.0)
	env.set_pathtracing_max_bounces(4)
	await get_tree().create_timer(1.0).timeout
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var st := _measure_crop(img, 0.3, 0.7)
	print("  crop mean %.6f (%d px)" % [st["mean"], st["n"]])
	return float(st["mean"])


## F3. The same Lambertian sphere under (a) BG_COLOR and (b) BG_SKY with a flat
## panorama of the same linear colour; returns mean(a) / mean(b). The BG_COLOR
## property is sRGB-encoded (the rasteriser clears with srgb_to_linear()), so it
## is set from the linear target's linear_to_srgb().
func _flat_world_ratio() -> float:
	var lin := Color(0.3, 0.5, 0.7)
	var energy := 1.5

	await _clear()
	_flat_world_scene()
	var env_sky := _new_env_sky(lin, energy)
	env_sky.set_pathtracing_max_bounces(2)
	await get_tree().create_timer(1.0).timeout
	var img_sky: Image = await _render_accum(env_sky, get_viewport().get_viewport_rid(), FRAMES)
	var sky_mean := float(_measure_crop(img_sky, 0.4, 0.6)["mean"])

	await _clear()
	_flat_world_scene()
	var env_col := _new_env_color(lin.linear_to_srgb(), energy)
	env_col.set_pathtracing_max_bounces(2)
	await get_tree().create_timer(1.0).timeout
	var img_col: Image = await _render_accum(env_col, get_viewport().get_viewport_rid(), FRAMES)
	var col_mean := float(_measure_crop(img_col, 0.4, 0.6)["mean"])

	print("  BG_SKY panorama mean %.6f, BG_COLOR mean %.6f" % [sky_mean, col_mean])
	if sky_mean < 1e-6:
		_checks += 1
		_failures.append("C: BG_SKY control rendered black (%.8f)" % sky_mean)
		return 0.0
	return col_mean / sky_mean


func _flat_world_scene() -> void:
	var s := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	s.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.5, 0.5, 0.5)
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	s.material_override = m
	add_child(s)
	var cam := Camera3D.new()
	cam.fov = 20.0
	cam.position = Vector3(0.0, 0.0, 3.0)
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.make_current()


func _bump_normal_map() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in range(n):
		for x in range(n):
			var u := float(x) / float(n) * TAU * 8.0
			var v := float(y) / float(n) * TAU * 8.0
			var nv := Vector3(0.85 * sin(u), 0.85 * sin(v), 0.45).normalized()
			img.set_pixel(x, y, Color(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5))
	return ImageTexture.create_from_image(img)


func _env_common(p_env: Environment) -> Environment:
	p_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	p_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = p_env
	add_child(we)
	p_env.set_pathtracing_enabled(true)
	p_env.set_pathtracing_samples_per_pixel(1)
	p_env.set_pathtracing_denoiser(0)
	p_env.set_pathtracing_oidn_denoise(false)
	p_env.set_pathtracing_dlss_rr_final(false)
	p_env.set_pathtracing_clamp_direct(0.0)
	p_env.set_pathtracing_clamp_indirect(0.0)
	p_env.set_pathtracing_noise_threshold(0.0)
	return p_env


func _new_env_sky(p_linear: Color, p_energy: float) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_linear)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = p_energy
	return _env_common(env)


func _new_env_color(p_srgb: Color, p_energy: float) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = p_srgb
	env.background_energy_multiplier = p_energy
	return _env_common(env)


func _measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return {"mean": acc / float(maxi(n, 1)), "n": n}
```

Fill `CYCLES_B0/B1/B2` from Step 2 before running.

- [ ] **Step 4: Run the gate on the current binary (the "before" reading)**

```bash
query session && bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_bump_correction_gate_scene.tscn 2>&1 | grep -E "^  |===|PASS|FAIL"
```

Expected: **A red** (> 1.005 — the mirror keeps rejected samples' weight) and **C red** (ratio 0.0: BG_COLOR renders black). B0/B1/B2 are recorded as the before-readings, whichever way they fall. If A is *not* above 1.005 on the current binary, stop: the probe cannot see the defect it claims to, and must be redesigned (raise the map's slope — `0.85 → 0.95, 0.45 → 0.30` — and re-run both halves) before any engine work starts (memory: gates must be falsifiable).

Record all five readings in the commit message.

- [ ] **Step 5: Commit**

```bash
git add tools/cycles_comparison/cycles_bump_grazing.py pipeline_references/tests/pt_bump_correction_gate.gd pipeline_references/tests/pt_bump_correction_gate_scene.tscn
git commit -m "test(pt): pt_bump_correction_gate + Cycles half -- A/C red on the current binary (A <reading>, C 0.0; B0/B1/B2 <readings> vs Cycles <refs>)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The true face normal in `HitData`

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:16-80` (struct + `compute_hit_data`), `:2252` (`sampleTransmissiveLobe` call), `:2315` (SSS `entry_ok`), `:2355` (`evalIndirectCombinedBRDF` call)

**Interfaces:**
- Produces: `HitData.face_normal` (`vec3`, world space, unit length, oriented toward the incoming ray: `dot(face_normal, -gl_WorldRayDirectionEXT) > 0`). Cycles' `sd->Ng`.
- Consumes: `rt_fetch_vertex_position(GeometryData, uint) -> vec3` (object space; `raytracing_vertex_inc.glsl`, included via `raytracing_hit_inc.glsl`), `get_triangle_indices(geom, i0, i1, i2)` (`raytracing_hit_inc.glsl`).

- [ ] **Step 1: Add the field and compute it**

In the struct (`:16`):

```glsl
struct HitData {
	vec3 hit_pos;
	// The SMOOTH, vertex-interpolated normal -- Cycles' sd->N, NOT its Ng. World
	// space, flipped toward the incoming ray on back-face hits. Ray-origin
	// offsets and the shading frame are built on it. (The name predates F1; it
	// is kept because ~40 sites read it and its meaning has not changed.)
	vec3 geometry_normal;
	// F1: the triangle's TRUE plane normal -- Cycles' sd->Ng. World space, unit
	// length, oriented so dot(face_normal, -ray_dir) > 0. Every "is this
	// direction inside the surface" test in the integrator is against THIS
	// (bsdf_microfacet.h:863, bsdf_diffuse.h:65 test Ng), and
	// ensure_valid_specular_reflection rotates toward it. For procedural
	// (intersection-shader) geometry it equals geometry_normal.
	vec3 face_normal;
	vec3 tangent; // World space.
	vec3 bitangent; // World space.
	vec2 uv; // Raw UV (no material scale/offset applied).
	vec4 color; // Vertex color (white if not present).
	bool is_front_face;
	uint geometry_idx;
};
```

In `compute_hit_data`, the procedural branch gets `h.face_normal = h.geometry_normal;` right after the `if (!h.is_front_face) { h.geometry_normal = -h.geometry_normal; }` block. The triangle branch, after its own flip block:

```glsl
		// F1: true face normal from the three vertex positions. Three extra BDA
		// reads per closest hit; Cycles gets Ng free from its intersector, we do
		// not. Edges are transformed by the full object-to-world rotation/scale
		// (NOT the normalised normal_matrix) so a non-uniformly scaled instance
		// still gets the plane of the world-space triangle.
		{
			uint fi0, fi1, fi2;
			get_triangle_indices(geom, fi0, fi1, fi2);
			vec3 p0 = rt_fetch_vertex_position(geom, fi0);
			vec3 p1 = rt_fetch_vertex_position(geom, fi1);
			vec3 p2 = rt_fetch_vertex_position(geom, fi2);
			vec3 e1 = model_rotation * (p1 - p0);
			vec3 e2 = model_rotation * (p2 - p0);
			vec3 ng = cross(e1, e2);
			float ng_len2 = dot(ng, ng);
			// Degenerate triangle: fall back to the smooth normal rather than NaN.
			h.face_normal = (ng_len2 > 1e-20) ? ng * inversesqrt(ng_len2) : h.geometry_normal;
			// Orient toward the ray, as Cycles flips Ng for back-facing hits
			// (shader_setup_from_ray). Independent of winding convention.
			if (dot(h.face_normal, -gl_WorldRayDirectionEXT) < 0.0) {
				h.face_normal = -h.face_normal;
			}
		}
```

- [ ] **Step 2: Move the three Ng tests onto it**

`:2252` — `sampleTransmissiveLobe(V, N, h.geometry_normal, alpha, ...` → `sampleTransmissiveLobe(V, N, h.face_normal, alpha, ...`, and add above the call:

```glsl
		// F1: the hemisphere guard inside is Cycles' dot(Ng, wo) test
		// (bsdf_microfacet.h:863) -- against the TRUE face, not the smooth normal.
```

`:2315` — `entry_ok = dot(h.geometry_normal, wo) < 0.0;` → `entry_ok = dot(h.face_normal, wo) < 0.0; // F1: Cycles tests Ng here (bsdf_microfacet.h:863).`

`:2355` — `evalIndirectCombinedBRDF(u, N, h.geometry_normal, V, ...` → `evalIndirectCombinedBRDF(u, N, h.face_normal, V, ...`.

Also in `brdf_inc.glsl:4094-4099`, update the comment on the geometry test:

```glsl
	// Prevent tracing direction "under" the surface. F1: `geometryNormal` is the
	// TRUE face normal (HitData.face_normal, Cycles' Ng) -- bsdf_microfacet.h:863
	// and bsdf_diffuse.h:65 make exactly this test and return LABEL_NONE. The
	// caller terminates the path on false.
```

- [ ] **Step 3: Build**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
```

Expected: `scons: done building targets.`

- [ ] **Step 4: Run the three gates whose behaviour the moved tests touch**

```bash
for g in pt_energy_gate pt_transmission_gate pt_subsurface_gate; do echo "== $g"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/${g}_scene.tscn 2>&1 | grep -E "PASS|FAIL|vs reference|ratio"; done
```

Expected: transmission and subsurface green. Energy gate: `smooth`, `diffuse`, `plastic` unchanged (< 0.5%); `rough` and `bumpy` may move (the rejection plane changed from smooth to true face on a smooth-shaded sphere) — record the readings in the commit message, do not re-capture yet (Task 7 does, once). If `smooth` / `diffuse` / `plastic` move by more than their 2% bar, stop: the face normal is wrong (sign or frame) — render vis mode 1 (`ps.radiance = final_normal * 0.5 + 0.5` style) with `face_normal` substituted to look at it.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl
git commit -m "feat(pt): HitData.face_normal (Cycles' Ng) from vertex positions; below-surface tests use it (F1 Task 2)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `ensureValidSpecularReflection` replaces `clampShadingNormal`

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl:209-223` (macros), `:1878-1893` (`clampShadingNormal`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:328-345` (`debug_visualize` params), `:503`, `:672`, `:761`, `:908`, `:1168`, `:1288` (vis-mode reconstructions), `:1393` (production `N`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:575`, `:657` (the two `debug_visualize` calls)

**Interfaces:**
- Produces: `float3 ensureValidSpecularReflection(float3 Ng, float3 I, float3 N)` in `brdf_inc.glsl` — returns `N` unchanged when `dot(Ng, reflect(-I, N)) >= min(0.9·dot(I,Ng), 0.01)`, else the rotated normal. Deletes `clampShadingNormal`, `RT_SHADING_NORMAL_CLAMP_ENABLED`, `RT_SHADING_NORMAL_CLAMP_THRESHOLD`.
- Consumes: `HitData.face_normal` (Task 2).

- [ ] **Step 1: Add the function, delete the clamp**

Replace the macro block at `brdf_inc.glsl:209-223` (from `// Master toggle for the shading-normal clamp` through the `#endif` of `RT_SHADING_NORMAL_CLAMP_THRESHOLD`) with nothing. Replace `clampShadingNormal` (`:1878-1893`, including its comment) with:

```glsl
// F1: Cycles' ensure_valid_specular_reflection, transcribed from
// intern/cycles/kernel/closure/bsdf_util.h:322-395. If the shading normal N
// would put the MIRROR direction of I below the true face Ng, rotate N toward
// Ng -- in the plane spanned by N and Ng -- by exactly the angle that lifts the
// mirror direction to a threshold just above the surface. Everywhere else N is
// returned untouched, so a normal map keeps its full relief at every view angle
// where it can be rendered. Cycles applies this to glossy, coat and SSS
// closures whenever N != Ng (maybe_ensure_valid_specular_reflection,
// bsdf_util.h:399) and the material's Bump Map Correction is on (its default);
// our BRDF library evaluates every lobe from one N, so the rotated normal is
// used for the diffuse lobe as well -- the divergence recorded in the spec's
// approach C.
//
// This REPLACED clampShadingNormal, which lerped every lobe's normal toward the
// SMOOTH normal below geometry NdotV 0.4 whether or not any direction would have
// entered the surface, flattening normal-mapped detail over the outer 66 deg of
// view angle.
float3 ensureValidSpecularReflection(float3 Ng, float3 I, float3 N) {
	const float3 R = 2.0f * dot(N, I) * N - I;
	const float Iz = dot(I, Ng); // > 0: face_normal is oriented toward the ray.

	// Reflection rays may always be at least as shallow as the incoming ray.
	const float threshold = min(0.9f * Iz, 0.01f);
	if (dot(Ng, R) >= threshold) {
		return N;
	}

	// Coordinate system with Ng as Z and N in the X-Z plane. X is the component
	// of N orthogonal to Ng, normalised; safe_normalize_fallback(.., N).
	float3 X = N - dot(N, Ng) * Ng;
	const float Xlen2 = dot(X, X);
	X = (Xlen2 > 1e-12f) ? X * inversesqrt(Xlen2) : N;

	// Solve 4*a*Nz^4 - 2*b*Nz^2 + c = 0 for the N' whose mirror of I sits at
	// exactly the threshold; see the derivation in bsdf_util.h. Of the four roots
	// only one is valid; the sign of Ix picks it.
	const float Ix = dot(I, X);
	const float a = max(Ix * Ix + Iz * Iz, 1e-12f);
	const float b = 2.0f * (a + Iz * threshold);
	const float c = (threshold + Iz) * (threshold + Iz);
	const float disc = sqrt(max(b * b - 4.0f * a * c, 0.0f)); // safe_sqrtf
	const float Nz2 = (Ix < 0.0f) ? 0.25f * (b + disc) / a : 0.25f * (b - disc) / a;

	const float Nx = sqrt(max(1.0f - Nz2, 0.0f));
	const float Nz = sqrt(max(Nz2, 0.0f));
	return Nx * X + Nz * Ng;
}
```

Also fix the two comments that name the old function: `brdf_inc.glsl:1461` (`GEOMETRY-plane test that drives recoverBelowHemisphereSample` — Task 4 rewrites that paragraph; leave until then) and `:3557` (`clampShadingNormal only REDUCES backfacing V` → `ensureValidSpecularReflection does not eliminate backfacing V either`).

- [ ] **Step 2: Production `N` in `shade_and_bounce`**

At `raytracing_closest_hit_common_inc.glsl:1392-1393` replace

```glsl
	// Clamp shading normal toward geometry at grazing view angles to keep BRDF above the geometry hemisphere.
	vec3 N = clampShadingNormal(m.normal, h.geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);
```

with

```glsl
	// F1: Cycles' bump-map correction (bsdf_util.h:322). Returns m.normal
	// untouched unless the mirror direction of V would enter the true face; then
	// rotates it toward h.face_normal by the minimum angle. Everything below --
	// NEE, env NEE, emissive NEE, the sampler, the MIS pdf, the guide normals --
	// shades from THIS N.
	vec3 N = ensureValidSpecularReflection(h.face_normal, V, m.normal);
```

- [ ] **Step 3: `debug_visualize` gets the face normal**

Signature (`:328`): insert `vec3 face_normal,` immediately after `vec3 geometry_normal,`. Both callers in `scene_raytracing_raygen.glsl` (`:575`, `:657`): `debug_visualize(VIS_MODE, h.geometry_normal, h.face_normal, m.normal, ...` / `debug_visualize(VIS_MODE, h.geometry_normal, h.face_normal, final_normal, ...`.

Then each reconstruction site, verbatim replacement of the call:

| line | old | new |
|---|---|---|
| `:503` | `vec3 N_clamped = clampShadingNormal(final_normal, geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);` | `vec3 N_clamped = ensureValidSpecularReflection(face_normal, V, final_normal);` |
| `:672` | `vec3 N_clamped32 = clampShadingNormal(...)` | `vec3 N_clamped32 = ensureValidSpecularReflection(face_normal, V, final_normal);` |
| `:761` | `vec3 dbg_N = clampShadingNormal(...)` | `vec3 dbg_N = ensureValidSpecularReflection(face_normal, V, final_normal);` |
| `:908` | `vec3 dbg_N35 = clampShadingNormal(...)` | `vec3 dbg_N35 = ensureValidSpecularReflection(face_normal, V, final_normal);` |
| `:1168` | `vec3 dbg_N40 = clampShadingNormal(...)` | `vec3 dbg_N40 = ensureValidSpecularReflection(face_normal, V, final_normal);` |
| `:1288` | `vec3 dbg_N41 = clampShadingNormal(...)` | `vec3 dbg_N41 = ensureValidSpecularReflection(face_normal, V, final_normal);` |

Vis mode 22 (`:498-499`, `:504-505`): the four `evalIndirectCombinedBRDF(..., geometry_normal, ...)` calls become `(..., face_normal, ...)` — the same plane the production sampler now tests. Update its comment: `// Uses the same threshold as shade_and_bounce` → `// The same correction shade_and_bounce applies; "clamped" below means "corrected".`

- [ ] **Step 4: Build and grep for leftovers**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3 && grep -rn "clampShadingNormal\|RT_SHADING_NORMAL_CLAMP" servers/rendering/renderer_rd/shaders/raytracing/ ; echo "grep exit $? (1 = clean)"
```

Expected: build done; grep finds nothing.

- [ ] **Step 5: Run the bump gate and the energy gate**

```bash
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_bump_correction_gate_scene.tscn 2>&1 | grep -E "^  |PASS|FAIL"
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_energy_gate_scene.tscn 2>&1 | grep -E "PASS|FAIL|vs reference"
```

Expected: B0 within 1% of Cycles (nothing fires at 10°); B1/B2 move toward Cycles from Task 1's readings — record them; A still red (the mirror is still there, Task 4); C still red (Task 6). Energy gate: only `bumpy`/`rough` move.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
git commit -m "feat(pt): Cycles' ensure_valid_specular_reflection replaces the 0.4 shading-normal clamp (F1 Task 3)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Reject, do not mirror

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl:225-233` (`RT_BELOW_HEMISPHERE_RECOVERY_ENABLED`), `:1895-1937` (recovery section), `:1461-1465` (comment)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:2227` (`recovered_sample`), `:2355-2375` (rejection block), `:2502-2520` and `:2555` (MIS policy)

**Interfaces:**
- Produces: nothing new. Deletes `recoverBelowHemisphereSample`, `mirrorDirectionAcrossPlane`, `RT_BELOW_HEMISPHERE_RECOVERY_ENABLED`, `recovered_sample`.

- [ ] **Step 1: Delete the recovery machinery in `brdf_inc.glsl`**

Remove the macro block (`// Enable below-hemisphere sample recovery.` … `#endif`, `:225-233`) and the whole section from `// -------- Below-hemisphere sample recovery` through the closing brace of `recoverBelowHemisphereSample` (`:1895-1937`). In the Gap #19 comment at `:1461-1465`, replace

```glsl
	// This is the SHADING hemisphere. It is a different plane from the
	// GEOMETRY-plane test that drives recoverBelowHemisphereSample
	// (raytracing_closest_hit_common_inc.glsl) -- that one exists to stop a ray
	// self-intersecting the surface it left, this one states that the BRDF is
	// zero. They are complementary and both are needed.
```

with

```glsl
	// This is the SHADING hemisphere. It is a different plane from the
	// TRUE-FACE test at the end of evalIndirectCombinedBRDF (Cycles' dot(Ng, wo),
	// F1) -- that one exists to stop a ray entering the surface it left, this
	// one states that the BRDF is zero. They are complementary and both are
	// needed.
```

- [ ] **Step 2: Terminate on rejection in `shade_and_bounce`**

Delete `bool recovered_sample = false;` (`:2227`). Replace the block at `:2355-2375`:

```glsl
	if (!transmissive_sample_ok && !evalIndirectCombinedBRDF(u, N, h.face_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
		// Two failure modes:
		//   1) Sample weight is zero (no contribution). Terminate.
		//   2) Sampled direction is below the geometry plane. Recover by
		//      mirroring across the geometry plane (see brdf_inc.glsl). The
		//      mirror is gated by RT_BELOW_HEMISPHERE_RECOVERY_ENABLED; when
		//      disabled, recovery returns false and we terminate the path.
		vec3 recovered_dir;
		if (luminance(brdf_weight) == 0.0 ||
				!recoverBelowHemisphereSample(next_dir, h.geometry_normal, recovered_dir)) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// next_dir is now the MIRRORED direction, carrying the REJECTED sample's
		// brdf_weight. That makes it density-matched to nothing this code can
		// evaluate, which is why it takes MIS weight 1 -- see the mis_ray_pdf
		// assignment below, where both candidate policies are measured.
		next_dir = recovered_dir;
		recovered_sample = true;
	}
```

with

```glsl
	if (!transmissive_sample_ok && !evalIndirectCombinedBRDF(u, N, h.face_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
		// Zero weight, or a direction below the TRUE face. Cycles returns
		// LABEL_NONE for both (bsdf_microfacet.h:863, bsdf_diffuse.h:65) and the
		// path ends. F1 removed the mirror-and-keep-the-weight recovery that stood
		// here: it handed a rejected sample's weight to a direction drawn from no
		// density this code knows, and was over-bright at grazing angles by its
		// own admission (pt_bump_correction_gate probe A read > 1 in a furnace).
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
	}
```

In the MIS policy comment (`:2502-2520`), delete the whole `//   - recovered_sample (a mirrored below-hemisphere sample). ...` bullet (through `... not this one's.`). In the condition at `:2555` remove `recovered_sample ||`. In the `dot(N, V) <= 0` bullet, `clampShadingNormal only REDUCES backfacing V, it does not eliminate it` → `ensureValidSpecularReflection does not eliminate backfacing V either`.

- [ ] **Step 3: Build and grep**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3 && grep -rn "recoverBelowHemisphere\|mirrorDirectionAcrossPlane\|RT_BELOW_HEMISPHERE_RECOVERY\|recovered_sample" servers/rendering/renderer_rd/shaders/raytracing/ ; echo "grep exit $? (1 = clean)"
```

- [ ] **Step 4: Run the bump gate**

```bash
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_bump_correction_gate_scene.tscn 2>&1 | grep -E "^  |PASS|FAIL"
```

Expected: **A green** (≤ 1.005). Record B0/B1/B2. C still red.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "feat(pt): below-face samples terminate the path, as in Cycles; mirror recovery deleted (F1 Task 4)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `bump_shadowing_term`

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl:312-360` (`MaterialProperties`), after `Smith_G1_GGX` (`:1008`) (new function), `:3794-3811` (`evalCombinedBRDFSeparate`), `:3940-3960` and `:4085-4099` (`evalIndirectCombinedBRDF`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:465`, `:619`, `:714`, `:879` (`dbg_mat.tangent` lines), `:1660` (`brdf_mat.tangent`)

**Interfaces:**
- Produces: `MaterialProperties.smoothNormal` (`float3`, Cycles `sd->N`), `MaterialProperties.bumpNormal` (`float3`, raw `m.normal` before correction); `float bumpShadowingTerm(float3 Ns, float3 N, float3 I, bool isDiffuse, bool isEval)`.
- Consumes: `Smith_G1_GGX(float alpha, float NdotS, float alphaSquared, float NdotSSquared)` — `2/(sqrt(1 + a²tan²θ) + 1)`, which is Cycles' `bsdf_G<GGX>(alpha2, cos) = 1/(1+Λ)` exactly.

- [ ] **Step 1: The two fields**

After `float3 tangent;` (`:348`) in `MaterialProperties`:

```glsl
	// F1, Cycles' bump_shadowing_term (bsdf.h:86). smoothNormal is the
	// vertex-interpolated normal (sd->N); bumpNormal is the normal-mapped normal
	// BEFORE ensureValidSpecularReflection (the normal Cycles' diffuse closure
	// carries). The term keys on these two, never on the corrected lobe normal,
	// so a surface without a normal map (bumpNormal == smoothNormal exactly)
	// reads 1.0 even where the correction rotated the lobe normal. Zero-length
	// smoothNormal disables the term (same convention as tangent).
	float3 smoothNormal;
	float3 bumpNormal;
```

Construction sites — after each `dbg_mat.tangent = world_tangent;` (`:465`, `:619`, `:714`, `:879`) add:

```glsl
		dbg_mat.smoothNormal = geometry_normal;
		dbg_mat.bumpNormal = final_normal;
```

After `brdf_mat.tangent = h.tangent;` (`:1660`):

```glsl
	// F1: the two normals bump_shadowing_term keys on; see MaterialProperties.
	brdf_mat.smoothNormal = h.geometry_normal;
	brdf_mat.bumpNormal = m.normal;
```

- [ ] **Step 2: The function**

After the four-argument `Smith_G1_GGX` (`:1008`):

```glsl
// F1: Cycles' bump_shadowing_term, transcribed from
// intern/cycles/kernel/closure/bsdf.h:86-140. Ns = smooth normal (sd->N),
// N = bump-mapped normal (the closure's N), I = the direction being evaluated
// or sampled (wo). Two jobs:
//   1. A direction on the far side of the SMOOTH surface from the bump normal
//      is light leaking through opaque geometry, not around a terminator:
//      rejected (0) for every closure in eval, and for diffuse closures in
//      sampling too.
//   2. Diffuse closures are softened by a GGX G1 whose roughness grows with the
//      bump normal's tilt off the smooth normal (alpha2 = saturate(tan2/8)),
//      so the discontinuity at the perpendicular angle is smoothed.
// Cycles applies it in bsdf_eval (:556, isEval true) and bsdf_sample (:314,
// isEval false); the pdf is never touched. Glossy closures get only job 1.
float bumpShadowingTerm(float3 Ns, float3 N, float3 I, bool isDiffuse, bool isEval) {
	if (dot(Ns, Ns) < 0.5f || all(equal(Ns, N))) {
		return 1.0f;
	}
	const float cosNsI = dot(Ns, I);
	const float cosNsN = dot(Ns, N);
	const float cosNI = dot(N, I);
	if (cosNsI * cosNsN * cosNI < 0.0f && (isEval || isDiffuse)) {
		return 0.0f;
	}
	if (!isDiffuse) {
		return 1.0f;
	}
	const float cos_i = abs(cosNsI);
	const float cos_d = abs(cosNsN);
	if (cos_d >= 1.0f || cos_i >= 1.0f) {
		return 1.0f;
	}
	if (cos_i < 1e-6f) {
		return 0.0f;
	}
	const float tan2_d = 1.0f / (cos_d * cos_d) - 1.0f;
	const float bump_alpha2 = clamp(0.125f * tan2_d, 0.0f, 1.0f);
	// bsdf_G<GGX>(alpha2, cos) == 1 / (1 + 0.5 (sqrt(1 + alpha2 tan2) - 1)) ==
	// 2 / (sqrt(1 + alpha2 tan2) + 1), which is this overload's closed form.
	return Smith_G1_GGX(0.0f, cos_i, bump_alpha2, cos_i * cos_i);
}
```

- [ ] **Step 3: Apply in eval**

In `evalCombinedBRDFSeparate`, immediately after `if (data.Lbackfacing) { return; }` (`:3811`):

```glsl
	// F1, Cycles bsdf_eval:556-559 -- light through the smooth surface is
	// rejected for every lobe; then the diffuse lobe alone is softened (:639).
	const float bumpReject = bumpShadowingTerm(material.smoothNormal, material.bumpNormal, L, false, true);
	if (bumpReject == 0.0f) {
		return;
	}
	const float bumpDiffuse = bumpShadowingTerm(material.smoothNormal, material.bumpNormal, L, true, true);
```

and change `outDiffuse = evalDiffuse(data);` (`:3815`) to `outDiffuse = evalDiffuse(data) * bumpDiffuse;`.

- [ ] **Step 4: Apply in sampling**

In `evalIndirectCombinedBRDF`, after `rayDirection = normalize(rotatePoint(invertRotation(qRotationToZ), rayDirectionLocal));` (`:4087`) and before the zero-weight early-out:

```glsl
	// F1, Cycles bsdf_sample:314 -- only the diffuse draw is shadowed here
	// (bump_shadowing_term with is_eval false returns 1 for non-diffuse
	// closures); eval-side rejection for the other lobes lives in
	// evalCombinedBRDFSeparate. Multiplies the WEIGHT only, never the pdf.
	if (brdfType == DIFFUSE_TYPE) {
		sampleWeight *= bumpShadowingTerm(material.smoothNormal, material.bumpNormal, rayDirection, true, false);
	}
```

- [ ] **Step 5: Build, then the bump gate, energy gate, sheen gate**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
for g in pt_bump_correction_gate pt_energy_gate pt_sheen_gate pt_coat_gate; do echo "== $g"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/${g}_scene.tscn 2>&1 | grep -E "^  |PASS|FAIL|vs reference"; done
```

Expected: bump gate B1/B2 within `BAR_B` of Cycles, B0 within 1%, A ≤ 1.005; sheen and coat gates unchanged (no normal maps: `bumpNormal == smoothNormal` exactly, term = 1); energy gate only `bumpy`/`rough` moved. If B1 is outside 3%: record its value in the gate's comment block as the measured divergence of approach A (the diffuse lobe on the corrected normal), set `BAR_B1_DIELECTRIC` to the measured value rounded up to the next whole percent, use it for B1 only, and write it into the roadmap closeout (Task 8) as approach C's evidence. Do not widen `BAR_B` for B2.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl pipeline_references/tests/pt_bump_correction_gate.gd
git commit -m "feat(pt): Cycles' bump_shadowing_term in eval and diffuse sampling (F1 Task 5) -- B0/B1/B2 <readings> vs Cycles

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: A flat-colour world (F3)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:495-510` (members), `render_raytracing.cpp:70-100` (destructor), `:112-123` (helper pattern; add ours after it), `:4288-4355` (binding-7 block)

**Interfaces:**
- Produces: `RID RenderRaytracing::_get_flat_world_texture(const Color &p_linear)` — 1×1 `R32G32B32A32_SFLOAT`, re-uploaded when the colour changes; `uint64_t flat_world_version` incremented on each upload (feeds `env_cdf`).
- Consumes: `owner->environment_get_background/bg_color/bg_energy_multiplier/bg_intensity(RID)`, `RSG::texture_storage->get_default_clear_color()`, `RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(RID)`.

- [ ] **Step 1: Members**

In `render_raytracing.h` after `RID _get_env_dist_fallback_buffer();`:

```cpp
	// F3: a 1x1 radiance map holding the Environment's flat background colour,
	// bound at binding 7 when the background is BG_COLOR / BG_CLEAR_COLOR and
	// there is no Sky. Before F3 that case bound the default black texture and
	// every ray that missed geometry saw a black world, while the rasteriser
	// cleared to bg_color * energy (render_forward_clustered.cpp, _render_scene).
	// Linear, energy already applied -- the same value the sky pass bakes into a
	// BG_SKY radiance map (brightness_multiplier in sky.glsl).
	RID flat_world_texture;
	Color flat_world_color = Color(-1.0f, -1.0f, -1.0f, -1.0f);
	uint64_t flat_world_version = 0;
	RID _get_flat_world_texture(const Color &p_linear);
```

- [ ] **Step 2: Helper and destructor**

In `render_raytracing.cpp` after `_get_env_dist_fallback_buffer` (`:123`):

```cpp
RID RenderRaytracing::_get_flat_world_texture(const Color &p_linear) {
	if (flat_world_texture.is_null()) {
		RD::TextureFormat tf;
		tf.format = RD::DATA_FORMAT_R32G32B32A32_SFLOAT;
		tf.width = 1;
		tf.height = 1;
		tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_UPDATE_BIT;
		tf.texture_type = RD::TEXTURE_TYPE_2D;
		flat_world_texture = RD::get_singleton()->texture_create(tf, RD::TextureView());
	}
	if (p_linear != flat_world_color) {
		const float px[4] = { p_linear.r, p_linear.g, p_linear.b, 1.0f };
		Vector<uint8_t> data;
		data.resize(sizeof(px));
		memcpy(data.ptrw(), px, sizeof(px));
		RD::get_singleton()->texture_update(flat_world_texture, 0, data);
		flat_world_color = p_linear;
		flat_world_version++;
	}
	return flat_world_texture;
}
```

In the destructor, after the `env_dist_fallback_buffer` block:

```cpp
	if (flat_world_texture.is_valid()) {
		RD::get_singleton()->free_rid(flat_world_texture);
		flat_world_texture = RID();
	}
```

- [ ] **Step 3: Bind it**

In the binding-7 block, replace

```cpp
		// Fall back to default black texture if no sky
		if (!radiance_texture.is_valid()) {
			radiance_texture = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		}
```

with

```cpp
		// F3: no Sky, but a flat background colour -- Cycles' constant world.
		// Mirrors the rasteriser's clear colour chain exactly
		// (render_forward_clustered.cpp _render_scene: srgb_to_linear() of the
		// property, times bg_energy_multiplier, bg_intensity and the camera's
		// exposure normalisation). pt_bump_correction_gate probe C asserts
		// equality with a BG_SKY flat panorama of the same linear colour.
		if (!radiance_texture.is_valid() && p_render_data && p_render_data->environment.is_valid()) {
			const RID env = p_render_data->environment;
			const RSE::EnvironmentBG bg = owner->environment_get_background(env);
			if (bg == RSE::ENV_BG_COLOR || bg == RSE::ENV_BG_CLEAR_COLOR) {
				Color c = (bg == RSE::ENV_BG_COLOR) ? owner->environment_get_bg_color(env) : RSG::texture_storage->get_default_clear_color();
				c = c.srgb_to_linear();
				float energy = owner->environment_get_bg_energy_multiplier(env) * owner->environment_get_bg_intensity(env);
				if (p_render_data->camera_attributes.is_valid()) {
					energy *= RSG::camera_attributes->camera_attributes_get_exposure_normalization_factor(p_render_data->camera_attributes);
				}
				c.r *= energy;
				c.g *= energy;
				c.b *= energy;
				radiance_texture = _get_flat_world_texture(c);
				sky_source_version = flat_world_version;
				sky_uv_border_size = 0.0f;
			}
		}

		// Fall back to default black texture if no sky and no flat colour.
		if (!radiance_texture.is_valid()) {
			radiance_texture = texture_storage->texture_rd_get_default(RendererRD::TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
		}
```

The existing `env_cdf.mark_dirty_if_source_changed(radiance_texture, sky_source_version)` / `env_cdf.update(...)` lines below need no change: a new colour bumps `flat_world_version`, which changes `sky_source_version`, which rebuilds the (uniform) distribution.

- [ ] **Step 4: Build; run the bump gate and the sky-energy gate**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -3
for g in pt_bump_correction_gate pt_sky_energy_gate; do echo "== $g"; bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/${g}_scene.tscn 2>&1 | grep -E "^  |PASS|FAIL"; done
```

Expected: **C green** (ratio 1.00 ± 1%); the whole bump gate PASS; sky-energy gate unchanged (it uses BG_SKY). If C reads a constant factor off (e.g. 0.5 or 2.0): the missing factor is `sky_luminance_multiplier` (1 / `rb->get_luminance_multiplier()`, `render_forward_clustered.cpp:2663`) — read that function, apply the same factor, re-run; record the factor in the code comment. If C reads off by a colour-dependent amount: the sRGB conversion is on the wrong side — compare the raster (`clear_color.srgb_to_linear()` at `:2861`) and fix to match it.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): BG_COLOR / BG_CLEAR_COLOR light the tracer as a flat world (F3) -- probe C 0.0 -> <reading>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Regression suite, reference re-capture, cost

**Files:**
- Modify: `pipeline_references/tests/pt_energy_gate.gd:95-135` (reference block)

- [ ] **Step 1: Old binary first, whole suite**

```bash
OLD="/c/Zlendo2026/ZlenderRender_stage_copy/godot/bin/godot.windows.editor.x86_64.console.exe"
for s in pipeline_references/tests/pt_*_gate_scene.tscn pipeline_references/tests/png16_encoding_gate_scene.tscn; do n=$(basename $s .tscn); echo "== $n"; "$OLD" --rendering-driver vulkan --path pipeline_references res://tests/$n.tscn 2>&1 | grep -E "^PASS|^FAIL"; done 2>&1 | tee "$SCRATCH/suite_old.txt"
```

Expected: every gate PASS except `pt_bump_correction_gate` (A and C red). Any other red on the OLD binary is the session (`query session`) or the machine, not this branch — resolve that before reading the new binary.

- [ ] **Step 2: New binary, whole suite**

Same loop with `bin/godot.windows.editor.x86_64.console.exe`, output to `suite_new.txt`. Expected: everything PASS except `pt_energy_gate` (`bumpy`, possibly `rough`). Any other red: bisect with Tasks 2–6's commits (`git stash` is not allowed on the user's files — use `git checkout <sha> -- servers/` on the engine paths only, rebuild, re-run, then `git checkout HEAD -- servers/`).

- [ ] **Step 3: Re-capture the energy gate's moved references**

Run `pt_energy_gate` three times on the new binary; take the median of `bumpy` (and `rough` / `rough rim` if they moved outside 2%). Replace the constants and add above them:

```gdscript
# RE-CAPTURED 2026-09-17 for Phase F1 (roadmap §11.29): the mirror recovery
# this surface was named for is gone -- a below-face sample now ends the path
# (Cycles' LABEL_NONE) -- and the shading normal is corrected by Cycles'
# ensure_valid_specular_reflection instead of the 0.4 clamp. `rough` moved
# because the sampler's below-surface test is now against the TRUE face, which
# on a smooth-shaded sphere rejects a terminator band the smooth-normal test
# let through (bsdf_diffuse.h:65 tests Ng). `smooth`, `diffuse` and `plastic`
# are unchanged (< 0.5%). Previous values: bumpy 1.41124, rough 1.63024.
```

Update the header comment's `bumpy` description (`:61-66`): it no longer "drives recovery"; it now measures the corrected normal + rejection. Re-run once to confirm green.

- [ ] **Step 4: Frame-time cost**

Three timing passes per binary on the opaque timing scene (E1 §7.2's method):

```bash
for i in 1 2 3; do ZR_LIGHT_SKIP_SWEEP=1 "$OLD" --rendering-driver vulkan --path pipeline_references res://tests/pt_light_rmse_scene.tscn 2>&1 | grep -i "timing\|ms"; done
for i in 1 2 3; do ZR_LIGHT_SKIP_SWEEP=1 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_light_rmse_scene.tscn 2>&1 | grep -i "timing\|ms"; done
```

Record best-of-three for each. Expected: within a few percent (three BDA reads per hit). If the new binary is > 10% slower, note it in the closeout; the fix (fetching Ng only when a lobe needs it) is a follow-up, not this plan.

- [ ] **Step 5: Doctest**

```bash
bin/godot.windows.editor.x86_64.console.exe --test 2>&1 | tail -3
```

Expected: all test cases passed (1558 at last count).

- [ ] **Step 6: Commit**

```bash
git add pipeline_references/tests/pt_energy_gate.gd
git commit -m "test(pt): energy gate bumpy/rough re-captured for F1 (mirror gone, Cycles bump correction); suite 20/20 green

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Asset check and roadmap closeout

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (gap table row 15; §4 Phase F entries F1 and F3; new §11.29)

- [ ] **Step 1: Render job 226's scene through the still route on the new binary**

The Gap #30 rig renders were driven from the scratchpad copy of the reference project (`$SCRATCH/proj_225`, a copy of `pipeline_references/` with the live job's `input_json/d225_fhd.json`; driver `$SCRATCH/run_rig.sh`). Reuse it with the new binary — this is the reference project, so it carries the current `image_glb_creation.gd` / `render.gd` reference edits:

```bash
S="$SCRATCH"; export ZR_PT_EXR=1; unset ZR_PHASE_A ZR_PT_FINAL ZR_LIGHTS_SKIP
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path "$S/proj_225" res://main.tscn -- "$S/proj_225/input_json/d225_fhd.json" "$S/f1_226.png" > "$S/f1_226_godot.log" 2>&1; echo exit=$?
```

and once more with the previous hand-over binary (`$OLD` from Task 7) to `f1_226_old.png`, so the comparison is same-scene, same-settings, binary-only. Crop the same regions as the 226 review (wall and floor normal maps at the frame edges, the pendant, the fish tank) at 200% and put old vs new side by side in one PNG; send it with `SendUserFile`.

What to report, with the crops: (a) relief on the wall/floor normal maps at grazing view — kept, not flattened; (b) silhouettes of bumpy surfaces — no new bright rims; (c) any darkening at smooth-shaded terminators (the true-face rejection) — visible or not.

- [ ] **Step 2: Roadmap**

Row 15 in the gap table: `| 15 | **Biased bump-map mirror recovery — CLOSED 2026-09-17 (§11.29).** Cycles has no "offset normals": it rotates the shading normal only as far as the mirror direction needs (ensure_valid_specular_reflection), rejects below-face samples outright, and shadows diffuse light through bumps (bump_shadowing_term) — all on the true face normal, which the tracer never computed. All three ported; the 0.4 clamp and the mirror deleted. pt_bump_correction_gate A <old> → <new> (furnace ≤ 1), B1/B2 vs Cycles <numbers>. | brdf_inc.glsl ensureValidSpecularReflection, bumpShadowingTerm; HitData.face_normal | bsdf_util.h:322, bsdf.h:86, bsdf_microfacet.h:863 | Closed |`

§4 Phase F: mark **F1** and **F3** `— ✅ DONE 2026-09-17 (§11.29)`, and correct F1's text: strike "Offset normals" and state the three rules.

New §11.29 "Phase F1 + F3 closeout — Cycles' bump-map correction, and a flat-colour world", in the house style of §11.26/§11.28: what the roadmap claimed vs what the source says (the table from the spec), the three rules and where each landed, the single-normal divergence (approach A) and what B1 measured against Cycles, the true-face rejection's effect on smooth-shaded spheres (`rough` before/after), the frame-time delta, the asset check, and the F3 mechanism with probe C's numbers. Close with what is NOT fixed: per-lobe normals (approach C) if B1 needed its own bar; shadow-terminator offset; volumetrics (F2) next.

- [ ] **Step 3: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): Phase F1 + F3 closeout (§11.29); Gap #15 closed

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

Then present the finishing options (keep as-is / push / merge) as in every previous phase.
