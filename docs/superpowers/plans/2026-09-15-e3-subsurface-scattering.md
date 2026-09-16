# E3 Subsurface Scattering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Materials with `subsurface_scattering_strength > 0` render with Cycles' subsurface model — the random walk for solids, the OpenPBR thin-wall split for sheets — gated against Cycles, and a material-name rule in the pipeline turns it on for marble, wax, shades, paper and leaves.

**Architecture:** Three new material fields (radius ×3, weight; scale in the old pad) flow importer-free from `BaseMaterial3D`'s existing subsurface uniforms through `process_material` into `RT_MaterialData` / GLSL `MaterialData`. A per-scene feature bit compiles the code in only for scenes that have an SSS material. In the hit shader a fifth registry lobe, `LOBE_SUBSURFACE`, takes the `weight` share of the diffuse lobe; thin-wall materials split it into a cosine bounce about `+N` or `−N`; solid materials sample a refracted entry direction, walk inside their own instance with ray queries using Cycles' coefficients and Dwivedi guiding, and on exit re-aim the next ray at the exit point from outside with a payload flag that makes the next hit shade as a white Lambertian (Cycles' `subsurface_shader_data_setup`).

**Tech Stack:** GLSL (Vulkan RT + `GL_EXT_ray_query`), C++ (`render_raytracing.cpp/.h`, `scene_shader_raytracing.h/.cpp`, `environment.cpp`), GDScript gates on `pt_validation.gd`, Blender 5.2.1 Python for the Cycles reference, SCons.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-15-e3-subsurface-scattering-design.md`. Deviation recorded in Task 1: **skin mode deferred** (Godot's `sss_mode_skin` is a shader render_mode invisible to the RT upload; no library material needs it; S5 removed).
- Build: `python -m SCons platform=windows target=editor tests=yes -j8`. A clean build proves nothing about GLSL — read Godot stderr on the first render of every task.
- Scenes with no SSS material must stay **byte-identical**: everything new is under `#ifdef RT_SSS_ENABLED`, and `RT_SSS_ENABLED` is only injected when a material in the scene has `sss_weight > 1e-5`.
- Anisotropy `g = 0` throughout (spec). Constants transcribed from Cycles: `BSSRDF_MAX_BOUNCES 256`, `BSSRDF_MIN_RADIUS 1e-8`, `VOLUME_THROUGHPUT_EPSILON 1e-6`, alpha floor `0.2`, ior clamp `[1.01, 3.8]`, exit restart `δ = 0.002` (2 mm, above the raygen's 1 mm `t_min`).
- `git add` with explicit paths only. `pipeline_references/*.gd` (top level) are the user's: edited in the reference copy, **never staged**. `pipeline_references/tests/` and `tools/cycles_comparison/` are ours.
- Render outputs to the scratchpad; the live project `C:\Zlendo2026\ZlenderRender_stage_copy\` is read-only.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Paths relative to `C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine`; `GODOT` = `bin/godot.windows.editor.x86_64.console.exe`; gates run with `--rendering-driver vulkan --path pipeline_references res://tests/<gate>_scene.tscn`.
- Blender: `"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P <script> -- <outdir>`.

---

### Task 1: Material data — struct, upload, feature bit, and the field-arrival probe

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:105-150` (struct + flags)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl:118-170` (mirror + flag defines)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:~1812` (upload, after `attenuation_color`), `:~1908` (feature bit), `:~2688` (verbose print)
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:98-108,150-166` (bit, asserts), `scene_shader_raytracing.cpp:70-72` (define injection)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:~531` (vis modes 41/42), `scene/resources/environment.cpp:1616` (enum names)
- Modify: `pipeline_references/tests/pt_material_data_gate.gd` (two new checks)
- Modify: spec (skin-mode deferral note)

**Interfaces:**
- Produces (C++): `RT_MaterialData::sss_scale` (offset 188), `sss_radius[3]` (192), `sss_weight` (204); `RT_MAT_FLAG_SSS_THIN = 32u`; `SceneShaderRaytracing::RT_FLAG_SSS_ENABLED = (1 << 19)`.
- Produces (GLSL): `MaterialData.sss_scale`, `.sss_radius` (vec3), `.sss_weight`; `#define RT_MAT_FLAG_SSS_THIN 32u`; `#define RT_SSS_ENABLED` when the scene has SSS; vis modes 41 (`sss_radius`) and 42 (`(sss_weight, sss_scale, thin ? 1 : 0)`).

- [ ] **Step 1: Extend the material-data gate (red first)**

In `pipeline_references/tests/pt_material_data_gate.gd`, after `const MODE_SHEEN_COLOR := 29`:

```gdscript
const MODE_SSS_RADIUS := 41
const MODE_SSS_WEIGHT_SCALE_THIN := 42
```

after `const V_SHEEN_COLOR := ...`:

```gdscript
const V_SSS_STRENGTH := 0.65
const V_SSS_RADIUS := Color(0.9, 0.3, 0.12)   # linear; transmittance_color
const V_SSS_DEPTH := 0.037                     # transmittance_depth, metres
```

in `_ready()` after `mat.anisotropy = V_ANISOTROPY`:

```gdscript
	mat.subsurf_scatter_enabled = true
	mat.subsurf_scatter_strength = V_SSS_STRENGTH
	mat.subsurf_scatter_transmittance_enabled = true
	mat.transmittance_color = V_SSS_RADIUS.linear_to_srgb()
	mat.transmittance_depth = V_SSS_DEPTH
```

and after the last existing `await _check_mode(...)`:

```gdscript
	await _check_mode(env, MODE_SSS_RADIUS,
			"sss_radius (transmittance_color)",
			Vector3(V_SSS_RADIUS.r, V_SSS_RADIUS.g, V_SSS_RADIUS.b))
	await _check_mode(env, MODE_SSS_WEIGHT_SCALE_THIN,
			"sss_weight/sss_scale/thin",
			Vector3(V_SSS_STRENGTH, V_SSS_DEPTH, 0.0))
```

Update the PASS line's count from 25 to 31 fields wherever the file states it (grep `25`).

- [ ] **Step 2: Run the gate, expect the two new checks red**

```bash
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_material_data_gate_scene.tscn 2>&1 | grep -E "sss|PASS|FAIL"
```

Expected: the two `sss` checks FAIL (mode 41/42 do not exist; the read is 0), everything else passes.

- [ ] **Step 3: C++ struct and flags**

`render_raytracing.h`: replace `float _pad0;` at the struct tail with

```cpp
	// E3 subsurface. sss_scale takes the old _pad0 slot (offset 188, no growth);
	// radius+weight are one 16-byte row at 192 (vec3 aligns to 16 in std430),
	// so the struct grows 192 -> 208. Cycles: bssrdf->radius = radius * scale.
	// sss_scale <= 0 means THIN-WALL (OpenPBR sheet), decided at upload into
	// RT_MAT_FLAG_SSS_THIN so the shader tests one bit.
	float sss_scale;
	float sss_radius[3];
	float sss_weight;
```

change the size assert to 208 and add:

```cpp
static_assert(offsetof(RT_MaterialData, sss_scale) == 188, "sss_scale must occupy the old _pad0 slot");
static_assert(offsetof(RT_MaterialData, sss_radius) == 192, "sss_radius must be 16-byte aligned for std430 vec3");
static_assert(offsetof(RT_MaterialData, sss_weight) == 204, "sss_weight must follow sss_radius");
```

In the material flag enum after `RT_MAT_FLAG_ANYHIT_SKIP_ONLY = 16u,`:

```cpp
	// Bit 5 (E3): thin-wall subsurface (transmittance_depth <= 0). MIRRORED IN
	// raytracing_data_inc.glsl.
	RT_MAT_FLAG_SSS_THIN = 32u,
```

Update the comment `// Must match GLSL MaterialData (std430, 192 bytes).` to 208.

- [ ] **Step 4: GLSL mirror**

`raytracing_data_inc.glsl`: replace `float _pad0;` at the end of `MaterialData` with

```glsl
	float sss_scale; // E3. Was _pad0. Cycles subsurface_scale; <= 0 = thin-wall.
	vec3 sss_radius; // E3. std430 aligns this to offset 192; struct is 208 bytes.
	float sss_weight; // E3. Cycles subsurface_weight.
```

update the `(matches C++ layout, 192 bytes)` comment to 208, and after the `RT_MAT_FLAG_ANYHIT_SKIP_ONLY` define add:

```glsl
#define RT_MAT_FLAG_SSS_THIN 32u // Bit 5. MIRRORS render_raytracing.h (E3).
```

- [ ] **Step 5: Upload**

`render_raytracing.cpp`, directly after the `attenuation_color` block (before the `// E3 detection` comment), add:

```cpp
	// E3 subsurface. Read from BaseMaterial3D's existing subsurface uniforms:
	// the raster path's screen-space SSS and the tracer's random walk now share
	// one authoring surface. A material without the feature has no such
	// uniforms and material_get_param returns NIL -> weight 0, nothing else read.
	mat.sss_weight = 0.0f;
	mat.sss_scale = 0.05f; // Cycles' default Subsurface Scale.
	mat.sss_radius[0] = 1.0f; // Cycles' default Subsurface Radius (1, 0.2, 0.1).
	mat.sss_radius[1] = 0.2f;
	mat.sss_radius[2] = 0.1f;
	Variant sss_strength_var = material_storage->material_get_param(p_material_rid, "subsurface_scattering_strength");
	if (sss_strength_var.get_type() == Variant::FLOAT) {
		mat.sss_weight = CLAMP((float)sss_strength_var, 0.0f, 1.0f);
	}
	Variant sss_radius_var = material_storage->material_get_param(p_material_rid, "transmittance_color");
	if (sss_radius_var.get_type() == Variant::COLOR) {
		Color c = ((Color)sss_radius_var).srgb_to_linear();
		mat.sss_radius[0] = MAX(0.0f, c.r);
		mat.sss_radius[1] = MAX(0.0f, c.g);
		mat.sss_radius[2] = MAX(0.0f, c.b);
	}
	Variant sss_depth_var = material_storage->material_get_param(p_material_rid, "transmittance_depth");
	if (sss_depth_var.get_type() == Variant::FLOAT) {
		mat.sss_scale = (float)sss_depth_var; // <= 0 selects thin-wall below.
	}
	if (mat.sss_weight > 0.0f && mat.sss_scale <= 0.0f) {
		mat.flags |= RT_MAT_FLAG_SSS_THIN;
	}
```

Check first (grep) that `mat.flags` is the field the other flag writes use at this point of `process_material`; if the flags are assembled under a different local name, use that one.

In the `// E3 detection` block, after the sheen predicate:

```cpp
	if (mat.sss_weight > 0.00001f) {
		// Cycles CLOSURE_WEIGHT_CUTOFF on subsurface_weight (svm/closure.h:477).
		mat_data->feature_bits |= SceneShaderRaytracing::RT_FLAG_SSS_ENABLED;
	}
```

In the verbose print add `sss=%d` with `(int)((scene_mask & SceneShaderRaytracing::RT_FLAG_SSS_ENABLED) != 0)`.

- [ ] **Step 6: Feature bit and define**

`scene_shader_raytracing.h`, after `RT_FLAG_TRANSMISSIVE_GEOMETRY = (1 << 18),`:

```cpp
		// E3 subsurface. Bit 19. Scene content: any material with
		// sss_weight > 1e-5 (process_material). Folds the random walk, the
		// fifth registry lobe and the exit shading away for every other scene.
		RT_FLAG_SSS_ENABLED = (1 << 19),
```

Add `RT_FLAG_SSS_ENABLED` to both static_assert lists (the min-bounce one at `:150` and the max-transmission-bounce one at `:157-166`). Confirm bit 19 is below `RT_SAMPLE_COUNT_SHIFT = 20` — it is; the asserts prove it.

`scene_shader_raytracing.cpp:72`, after the sheen entry:

```cpp
	{ SceneShaderRaytracing::RT_FLAG_SSS_ENABLED, "#define RT_SSS_ENABLED\n" },
```

Find where `scene_mask` is folded into the pipeline flags for coat/sheen (grep `RT_FLAG_SHEEN_ENABLED` in `render_raytracing.cpp` around `:2660-2700` and in `scene_shader_raytracing.cpp`) and add `RT_FLAG_SSS_ENABLED` at every site the sheen bit appears, so the bit reaches the define table the same way.

- [ ] **Step 7: Vis modes 41 and 42**

`raytracing_closest_hit_common_inc.glsl`, after the `vis_mode == 29` arm:

```glsl
	} else if (vis_mode == 41) {
		ps.radiance = dbg_material.sss_radius;
	} else if (vis_mode == 42) {
		ps.radiance = vec3(dbg_material.sss_weight, dbg_material.sss_scale,
				((dbg_material.flags & RT_MAT_FLAG_SSS_THIN) != 0u) ? 1.0 : 0.0);
```

`environment.cpp:1616`: append `,Mat: SSS Radius,Mat: SSS Weight/Scale/Thin` to the enum hint string (positions 41 and 42 — count the existing entries: "Aniso PDF Parity" is 35; add five spacer names first? **No**: check how modes 36–40 are named in that string; if the string ends at 35 while the shader has modes up to 40, append entries for 36–40 with the names used in the shader comments so 41/42 land at the right index. The gate sets the mode by integer, so only the integer matters for correctness; the names are for the Inspector.)

- [ ] **Step 8: Build, run the gate, expect green**

```bash
python -m SCons platform=windows target=editor tests=yes -j8 2>&1 | tail -2
./bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_material_data_gate_scene.tscn 2>&1 | grep -E "sss|PASS|FAIL|error"
```

Expected: `PASS: all 31 material fields arrived in the shader intact.` Then the doctest suite (`--test`): 1558/1558 (no C++ mirror test reads the struct size).

- [ ] **Step 9: Spec amendment and commit**

Append to the spec under `## Not in scope`: `- Skin mode (Cycles RANDOM_WALK_SKIN): Godot's sss_mode_skin is a shader render_mode, not a uniform, so process_material cannot read it; deferred with probe S5. No library material needs it.` Remove `RT_MAT_FLAG_SSS_SKIN` and S5 from the spec's tables.

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_data_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl scene/resources/environment.cpp pipeline_references/tests/pt_material_data_gate.gd docs/superpowers/specs/2026-09-15-e3-subsurface-scattering-design.md
git commit -m "feat(pt): E3 -- subsurface material fields reach the tracer (radius, weight, scale, thin flag)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Thin-wall subsurface — the fifth lobe, NEE, and gate probe S3

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl:310-372` (MaterialProperties), `:2126-2160` (registry), `:3342-3356` (layer walk), `:3736-3760` (separate eval), `:3850-3900` (indirect sample)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:~1640` (brdf_mat fields), `:~2005-2062` (weights + selection), `:~2214` (bounce accounting)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:575,756,812` (NEE consumers)
- Create: `pipeline_references/tests/pt_subsurface_gate.gd`, `pipeline_references/tests/pt_subsurface_gate_scene.tscn`

**Interfaces:**
- Consumes: Task 1's `MaterialData.sss_*` and `RT_MAT_FLAG_SSS_THIN`, `RT_SSS_ENABLED`.
- Produces: `MaterialProperties.sssWeight` (float), `.sssThin` (bool), `.sssRadius` (float3), `.sssScale` (float); `LOBE_SUBSURFACE`, `SUBSURFACE_TYPE` brdf type; `evalCombinedBRDFSeparate` gains a fifth out `outTranslucent` (float3) — every existing caller passes a dummy. Task 4 relies on `LOBE_SUBSURFACE` selection and `brdfType == SUBSURFACE_TYPE`.

- [ ] **Step 1: The gate, probe S3 only (red)**

`pipeline_references/tests/pt_subsurface_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Subsurface gate (E3, roadmap Gap #13 remainder).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_subsurface_gate_scene.tscn
##
## Probes (spec 2026-09-15-e3-subsurface-scattering-design.md):
##   S3 thin-wall: a thin-wall SSS sheet (weight 1, albedo A) between the camera
##      and an emissive backdrop, camera side black. The translucent half of
##      the OpenPBR split lets 0.5 * A * L_backdrop through; the diffuse half
##      sees only black. Ratio sheet/backdrop = 0.5 * A within 2%.
##   S1 energy (Task 4): white solid SSS sphere in a uniform furnace <= 1.0 and
##      within 2% of a white diffuse sphere.
##   S2 Cycles (Task 4): albedo 0.8 sphere, radius (1,0.2,0.1)*0.05, ior 1.4,
##      within 5% of CYCLES_REF per channel.
##   S4 fallback (Task 4): S2's material with radius 0 equals plain diffuse
##      to 0.5%.

const FRAMES := 128
const SHEET_ALBEDO := 0.8
const S3_TOL := 0.02

const CAM_POS := Vector3(0, 0, 5)
const CAM_TARGET := Vector3(0, 0, -5)
const CAM_FOV := 25.0
const SHEET_Z := -2.0
const BACKDROP_Z := -5.0
const BACKDROP_EMISSION := Color(0.6, 0.5, 0.4)
const EMISSION_ENERGY := 3.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== S3: thin-wall sheet, translucent share ===")
	var s3 := await _probe_s3()
	var s3_theory := 0.5 * SHEET_ALBEDO
	print("  S3 ratio = %.6f (theory %.4f)" % [s3, s3_theory])
	_checks += 1
	if absf(s3 - s3_theory) > S3_TOL * s3_theory:
		_failures.append("S3 thin-wall: %.6f vs %.4f (%.1f%% off, max %.0f%%)"
				% [s3, s3_theory, (s3 / s3_theory - 1.0) * 100.0, S3_TOL * 100.0])

	_finish()


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d subsurface checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Backdrop + single-sided thin-wall sheet, black sky. Ratio of the centre crop
## with the sheet visible to the crop with it hidden.
func _probe_s3() -> float:
	for c in get_children():
		c.queue_free()

	var backdrop := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(20, 20, 0.1)
	backdrop.mesh = bm
	backdrop.position = Vector3(0, 0, BACKDROP_Z)
	var bmat := StandardMaterial3D.new()
	bmat.emission_enabled = true
	bmat.emission = BACKDROP_EMISSION
	bmat.emission_energy_multiplier = EMISSION_ENERGY
	backdrop.material_override = bmat
	add_child(backdrop)

	var sheet := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(6, 6)
	sheet.mesh = qm
	sheet.position = Vector3(0, 0, SHEET_Z)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(SHEET_ALBEDO, SHEET_ALBEDO, SHEET_ALBEDO).linear_to_srgb()
	smat.metallic = 0.0
	smat.metallic_specular = 0.0
	smat.roughness = 1.0
	smat.subsurf_scatter_enabled = true
	smat.subsurf_scatter_strength = 1.0
	smat.subsurf_scatter_transmittance_enabled = true
	smat.transmittance_color = Color(1, 1, 1)
	smat.transmittance_depth = 0.0 # thin-wall
	sheet.material_override = smat
	add_child(sheet)

	var cam := Camera3D.new()
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(4)
	await get_tree().create_timer(1.0).timeout

	sheet.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)
	sheet.visible = true
	for _i in range(3):
		await get_tree().process_frame
	var through_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(through_img, 0.35, 0.65)
	print("  control mean %.6f, through mean %.6f" % [control["mean"], through["mean"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("S3 control is black")
		return 0.0
	return float(through["mean"]) / float(control["mean"])


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
	return {"r": r * inv, "g": g * inv, "b": b * inv, "mean": (r + g + b) * inv / 3.0}
```

Scene file `pt_subsurface_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_subsurface_gate.gd" id="1_gate"]

[node name="PTSubsurfaceGate" type="Node"]
script = ExtResource("1_gate")
```

Run it. Expected on the Task 1 build: S3 reads **0.0** (a plain diffuse sheet in front of a black sky passes nothing) → FAIL. Note: the backdrop is *behind* the sheet, so the diffuse share contributes nothing and the translucent share alone is measured.

- [ ] **Step 2: MaterialProperties fields**

`brdf_inc.glsl` `struct MaterialProperties`, after `float sheenRoughness;`:

```glsl
	// E3 subsurface (Cycles Principled: subsurface_weight, radius * scale).
	// sssThin selects the OpenPBR thin-wall split; otherwise the random walk.
	float sssWeight;
	bool sssThin;
	float3 sssRadius;
	float sssScale;
```

`raytracing_closest_hit_common_inc.glsl`, after `brdf_mat.sheenRoughness = ...`:

```glsl
#ifdef RT_SSS_ENABLED
	// E3. Cycles bssrdf_setup: a channel whose radius (after scale) is below
	// BSSRDF_MIN_RADIUS is diffuse for that channel; if all three are, the
	// material has no subsurface closure at all. Anisotropy is fixed at 0.
	brdf_mat.sssWeight = clamp(raw_mat.sss_weight, 0.0, 1.0);
	brdf_mat.sssThin = (raw_mat.flags & RT_MAT_FLAG_SSS_THIN) != 0u;
	brdf_mat.sssScale = max(raw_mat.sss_scale, 0.0);
	brdf_mat.sssRadius = max(raw_mat.sss_radius * brdf_mat.sssScale, vec3(0.0));
	if (!brdf_mat.sssThin && max(max(brdf_mat.sssRadius.r, brdf_mat.sssRadius.g), brdf_mat.sssRadius.b) < 1e-8) {
		brdf_mat.sssWeight = 0.0;
	}
#else
	brdf_mat.sssWeight = 0.0;
	brdf_mat.sssThin = false;
	brdf_mat.sssRadius = vec3(0.0);
	brdf_mat.sssScale = 0.0;
#endif
```

Every other site that builds a `MaterialProperties` by hand (grep `MaterialProperties dbg_mat` and `dbg_mat40`) sets `sssWeight = 0.0; sssThin = false; sssRadius = float3(0); sssScale = 0.0;` so those instruments are unchanged.

- [ ] **Step 3: Registry**

`brdf_inc.glsl` after the sheen block, before `LOBE_COUNT`:

```glsl
// E3. APPENDS after sheen; slides like the coat and sheen do. Registry
// position is not layer depth: layerTransmittanceAbove maps LOBE_SUBSURFACE
// to LOBE_DIFFUSE's depth (it IS the diffuse share, Cycles svm/closure.h:479).
#ifdef RT_SSS_ENABLED
#if defined(RT_COAT_ENABLED) && defined(RT_SHEEN_ENABLED)
#define LOBE_SUBSURFACE 4
#elif defined(RT_COAT_ENABLED) || defined(RT_SHEEN_ENABLED)
#define LOBE_SUBSURFACE 3
#else
#define LOBE_SUBSURFACE 2
#endif
#endif
```

and replace the `LOBE_COUNT` block with:

```glsl
#ifdef RT_SSS_ENABLED
#define LOBE_SSS_EXTRA 1
#else
#define LOBE_SSS_EXTRA 0
#endif
#if defined(RT_COAT_ENABLED) && defined(RT_SHEEN_ENABLED)
#define LOBE_COUNT (4 + LOBE_SSS_EXTRA)
#elif defined(RT_COAT_ENABLED) || defined(RT_SHEEN_ENABLED)
#define LOBE_COUNT (3 + LOBE_SSS_EXTRA)
#else
#define LOBE_COUNT (2 + LOBE_SSS_EXTRA)
#endif
```

Add a brdf type constant next to `SHEEN_TYPE` (grep `#define SHEEN_TYPE`): `#define SUBSURFACE_TYPE 5` (or the next free integer — read the neighbours).

`layerTransmittanceAbove`: first line of the body:

```glsl
#ifdef RT_SSS_ENABLED
	if (lobeIndex == LOBE_SUBSURFACE) {
		lobeIndex = LOBE_DIFFUSE; // the diffuse share: same layer depth.
	}
#endif
```

- [ ] **Step 4: Selection weights**

`raytracing_closest_hit_common_inc.glsl` selection block: replace

```glsl
		weights[LOBE_DIFFUSE] = baseShare * (1.0 - pSpec);
```

with

```glsl
		float diffuseShare = baseShare * (1.0 - pSpec);
#ifdef RT_SSS_ENABLED
		// E3: Cycles splits the diffuse closure by subsurface_weight
		// (svm/closure.h:479 bssrdf weight, :515 diffuse weight).
		weights[LOBE_DIFFUSE] = diffuseShare * (1.0 - brdf_mat.sssWeight);
		weights[LOBE_SUBSURFACE] = diffuseShare * brdf_mat.sssWeight;
#else
		weights[LOBE_DIFFUSE] = diffuseShare;
#endif
```

and in the selection chain, before the trailing `} else {` (diffuse):

```glsl
#ifdef RT_SSS_ENABLED
		} else if (lobe == LOBE_SUBSURFACE) {
			brdfType = SUBSURFACE_TYPE;
			ps.throughput /= weights[LOBE_SUBSURFACE];
#endif
```

- [ ] **Step 5: Thin-wall sampling**

In `evalIndirectCombinedBRDF` (`brdf_inc.glsl:~3850`), add an arm:

```glsl
#ifdef RT_SSS_ENABLED
	if (brdfType == SUBSURFACE_TYPE && material.sssThin) {
		// OpenPBR thin-wall (Cycles bsdf_thin_subsurface_setup): with g = 0 the
		// weight splits 0.5 diffuse (about +N) / 0.5 translucent (about -N).
		// One draw decides the side; the cosine sample reuses u.y and a
		// re-scaled u.x, and the closure weight is the base colour either way.
		const bool translucent = (u.x >= 0.5f);
		float2 u2 = float2(translucent ? (u.x - 0.5f) * 2.0f : u.x * 2.0f, u.y);
		float3 side = translucent ? -shadingNormal : shadingNormal;
		float4 qRotationToZ = getRotationToZAxis(side);
		float3 localDir = sampleHemisphere(u2);
		rayDirection = normalize(rotatePoint(invertRotation(qRotationToZ), localDir));
		// Selection probability 0.5 and the Lambertian's cos/pdf = 1 cancel to:
		sampleWeight = material.baseColor;
		return dot(rayDirection, translucent ? -geometryNormal : geometryNormal) > 0.0f;
	}
#endif
```

Read the existing diffuse arm first and use exactly its rotation helpers (`getRotationToZAxis` / `rotatePoint` / `invertRotation` or whatever names it uses); the arm above must be a copy of the diffuse arm with `side` in place of `shadingNormal`.

In `shade_and_bounce`'s post-sample bookkeeping (`:~2214`, `brdfType == DIFFUSE_TYPE || brdfType == SHEEN_TYPE`), extend the condition with `|| brdfType == SUBSURFACE_TYPE` so it counts as a diffuse bounce, and where `ps.offset_normal` is set (`:~2274`) make the translucent case restart on the far side:

```glsl
#ifdef RT_SSS_ENABLED
	const bool sss_thin_through = (brdfType == SUBSURFACE_TYPE) && brdf_mat.sssThin && (dot(next_dir, h.geometry_normal) < 0.0);
#else
	const bool sss_thin_through = false;
#endif
	ps.offset_normal = (took_transmissive_lobe || sss_thin_through) ? -h.geometry_normal : h.geometry_normal;
```

(`INSIDE_MEDIUM` untouched: a sheet has no interior; the transmission counter is incremented in the same branch that increments it for `took_transmissive_lobe` — extend that `if` with `|| sss_thin_through`.)

- [ ] **Step 6: NEE — the translucent share lit from behind**

`evalCombinedBRDFSeparate` gains `OUT_PARAMETER(float3) outTranslucent`; every existing caller (three in `raytracing_lights_inc.glsl`, any in `raytracing_closest_hit_common_inc.glsl`) passes a new local `brdf_translucent`. Inside:

```glsl
	outTranslucent = float3(0.0f, 0.0f, 0.0f);
#ifdef RT_SSS_ENABLED
	if (material.sssWeight > 0.0f) {
		// The diffuse term is the (1 - w) share (Cycles diffuse weight); the
		// thin-wall translucent lobe is 0.5 * w of the base colour about -N and
		// only sees lights BEHIND the sheet. The solid random walk has no eval:
		// its share is lit at the exit point, so here it contributes nothing.
		outDiffuse *= (1.0f - material.sssWeight);
		if (material.sssThin) {
			float NdotL_back = dot(-N, L);
			if (NdotL_back > 0.0f) {
				outTranslucent = material.baseColor * 0.5f * material.sssWeight * NdotL_back * ONE_OVER_PI;
			}
			outDiffuse += material.baseColor * 0.5f * material.sssWeight * max(dot(N, L), 0.0f) * ONE_OVER_PI;
		}
	}
#endif
```

placed AFTER the existing diffuse evaluation. Use the file's own name for `1/π` (grep `ONE_OVER_PI`).

At each NEE consumer, `brdf_translucent` is added to the contribution exactly where `brdf_sheen` is, **but its shadow ray must start on the far side of the sheet**: the three sites compute `hit_pos` offset along the front normal; for the translucent term evaluate a second shadow ray from `offset_ray_origin(hit_pos, -h.geometry_normal)` only when `brdf_translucent` is non-zero. Read `lights_trace_shadow_ray`'s call at each site and duplicate it for the back side under `#ifdef RT_SSS_ENABLED`, guarded by `rt_max_component(brdf_translucent) > 0.0`.

- [ ] **Step 7: Build, run S3**

Expected: S3 ratio ≈ `0.5 × 0.8 = 0.40` within 2%. If it reads ≈ 0.80, the translucent lobe is being counted by both the sample and the NEE without MIS — check the MIS pdf for the translucent direction at the emissive-hit site (the emissive backdrop is hit by the BSDF ray *and* sampled by emissive NEE; the cosine pdf about `−N` must be what `mis_ray_pdf` carries for the translucent sample — set it exactly as the diffuse arm sets it, with `side` as the normal).

- [ ] **Step 8: Isolation check and commit**

Run `pt_energy_gate`, `pt_sheen_gate`, `pt_coat_gate`, `pt_glass_energy_gate`: all green, no numbers moved (none has an SSS material, so `RT_SSS_ENABLED` is not defined and the shader is byte-identical).

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl pipeline_references/tests/pt_subsurface_gate.gd pipeline_references/tests/pt_subsurface_gate_scene.tscn
git commit -m "feat(pt): E3 -- thin-wall subsurface (OpenPBR diffuse/translucent split) as the fifth registry lobe

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Cycles reference for the solid sphere

**Files:**
- Create: `tools/cycles_comparison/cycles_sss_sphere.py`

**Interfaces:**
- Produces: printed `@@@` lines with per-channel means for `sss_a0.8` (S2) and `diffuse_a0.8` (the fallback/diffuse control) — pasted into the gate in Task 4 as `CYCLES_REF_S2` and `CYCLES_REF_DIFFUSE`.

- [ ] **Step 1: Write the script**

```python
# Subsurface sphere against Cycles -- E3 (spec 2026-09-15-e3-subsurface-scattering).
#
# Solid sphere, Principled BSDF, Subsurface Weight 1.0, Random Walk, radius
# (1, 0.2, 0.1) * scale 0.05, IOR 1.4, albedo 0.8, under a uniform world of
# radiance 1.0. Framing matched to cycles_glass_furnace.py / the gate. Also
# renders the same sphere with Subsurface Weight 0 (plain diffuse) as the
# control the gate's fallback probe compares against.

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 2048
CAM_DIST = 2.5
CAM_FOV_DEG = 20.0
BOUNCES = 12
ALBEDO = 0.8
RADIUS = (1.0, 0.2, 0.1)
SCALE = 0.05
IOR = 1.4


def build(sss_weight, albedo, radius, scale):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = False
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.max_bounces = BOUNCES
    scene.cycles.diffuse_bounces = BOUNCES
    scene.cycles.glossy_bounces = BOUNCES
    scene.cycles.transmission_bounces = BOUNCES
    scene.cycles.transparent_max_bounces = BOUNCES
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0

    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1.0)
    sphere = bpy.context.object
    bpy.ops.object.shade_smooth()

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["IOR"].default_value = IOR
    bsdf.inputs["Specular IOR Level"].default_value = 0.0
    bsdf.subsurface_method = "RANDOM_WALK"
    bsdf.inputs["Subsurface Weight"].default_value = sss_weight
    bsdf.inputs["Subsurface Radius"].default_value = radius
    bsdf.inputs["Subsurface Scale"].default_value = scale
    bsdf.inputs["Subsurface Anisotropy"].default_value = 0.0
    sphere.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    k = CAM_DIST / math.sqrt(3.0)
    cam.location = (k, -k, k)
    con = cam.constraints.new("TRACK_TO")
    con.target = sphere
    con.track_axis = "TRACK_NEGATIVE_Z"
    con.up_axis = "UP_Y"
    return bsdf


def stats(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    n = 0
    acc = [0.0, 0.0, 0.0]
    for i in range(0, len(px), 4):
        if px[i + 3] > 0.99:
            acc[0] += px[i]
            acc[1] += px[i + 1]
            acc[2] += px[i + 2]
            n += 1
    bpy.data.images.remove(img)
    ch = [a / n for a in acc]
    return sum(ch) / 3.0, ch, n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ SUBSURFACE SPHERE vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
for label, w, a, r, s in (
        ("diffuse_a0.8", 0.0, ALBEDO, RADIUS, SCALE),
        ("sss_a0.8", 1.0, ALBEDO, RADIUS, SCALE),
        ("sss_white", 1.0, 1.0, (1.0, 1.0, 1.0), SCALE)):
    bsdf = build(w, a, r, s)
    p = os.path.join(OUT, "%s.exr" % label)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    m, ch, n = stats(p)
    print("@@@ %-14s mean=%.8f RGB=(%.8f,%.8f,%.8f) n=%d" % (label, m, ch[0], ch[1], ch[2], n))
print("@@@ DONE")
```

Note `Specular IOR Level = 0` removes the dielectric specular lobe so the sphere is diffuse + subsurface only, matching the gate's `metallic_specular = 0.0`.

- [ ] **Step 2: Run it**

```bash
"/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b -P tools/cycles_comparison/cycles_sss_sphere.py -- "<scratchpad>/e3/cycles" 2>&1 | grep "@@@"
```

Expected: three `@@@` lines. `sss_white` should read ≤ 1.0 and close to `diffuse` at albedo 1 would (a white furnace reads 1.0 for a lossless sphere; Cycles at 12 bounces reads a little under). Record all three.

- [ ] **Step 3: Commit**

```bash
git add tools/cycles_comparison/cycles_sss_sphere.py
git commit -m "tools(pt): Cycles reference render for the E3 subsurface sphere

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The random walk — entry, walk, exit, and probes S1/S2/S4

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_sss_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl:~251` (flag bit 27 + helpers)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (include, exit-shading override at the top of `shade_and_bounce`, walk at the SUBSURFACE_TYPE sample site)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` closest-hit stage includes (if the new include must be listed there)
- Modify: `pipeline_references/tests/pt_subsurface_gate.gd` (S1, S2, S4)

**Interfaces:**
- Consumes: Task 2's `SUBSURFACE_TYPE`, `MaterialProperties.sss*`; Task 3's reference numbers.
- Produces: `SSS_EXIT_FLAG = (1u << 27)` with `set_sss_exit / clear_sss_exit / is_sss_exit`; `bool sss_random_walk(vec3 P, vec3 D, vec3 N, MaterialProperties material, inout vec3 throughput, uint seed, out vec3 exit_pos, out vec3 exit_dir)`.

- [ ] **Step 1: Gate probes S1, S2, S4 (red)**

Add to `pt_subsurface_gate.gd` (constants after `S3_TOL`):

```gdscript
const S_FRAMES := 256
const S_BOUNCES := 12
const S1_TOL := 0.02
const S2_TOL := 0.05
const S4_TOL := 0.005
# From tools/cycles_comparison/cycles_sss_sphere.py (Blender 5.2.1, 2048 spp,
# 12 bounces). Filled in from Task 3's run.
const CYCLES_REF_S2 := Vector3(0.0, 0.0, 0.0)      # sss_a0.8 RGB
const CYCLES_REF_DIFFUSE := Vector3(0.0, 0.0, 0.0) # diffuse_a0.8 RGB
```

Replace the zero vectors with Task 3's `sss_a0.8` and `diffuse_a0.8` RGB triples.

Sphere fixture (mirrors `pt_glass_energy_gate.gd` `_build_scene`: sphere radius 1, 64×32, camera at `normalize(1,1,1)*2.5`, FOV 20, constant panorama radiance 1.0, `_measure` over the whole 256×256 image):

```gdscript
func _sphere_mean(p_mat: StandardMaterial3D) -> Vector3:
	for c in get_children():
		c.queue_free()
	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(S_BOUNCES)
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	sphere.mesh = sm
	sphere.material_override = p_mat
	add_child(sphere)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.fov = 20.0
	cam.position = Vector3(1.4433757, 1.4433757, 1.4433757)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	await get_tree().create_timer(2.0).timeout
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), S_FRAMES)
	var acc := Vector3.ZERO
	var n := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	return acc / float(maxi(n, 1))


func _sss_material(p_albedo: float, p_weight: float, p_radius: Color, p_scale: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo).linear_to_srgb()
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.roughness = 1.0
	m.ior = 1.4
	if p_weight > 0.0:
		m.subsurf_scatter_enabled = true
		m.subsurf_scatter_strength = p_weight
		m.subsurf_scatter_transmittance_enabled = true
		m.transmittance_color = p_radius.linear_to_srgb()
		m.transmittance_depth = p_scale
	return m
```

Probes, inserted in `_ready()` before `_finish()`:

```gdscript
	print("\n=== S1: white solid SSS sphere, furnace ===")
	var s1_sss := await _sphere_mean(_sss_material(1.0, 1.0, Color(1, 1, 1), 0.05))
	var s1_dif := await _sphere_mean(_sss_material(1.0, 0.0, Color(1, 1, 1), 0.05))
	var m1s := (s1_sss.x + s1_sss.y + s1_sss.z) / 3.0
	var m1d := (s1_dif.x + s1_dif.y + s1_dif.z) / 3.0
	print("  sss %.6f  diffuse %.6f  ratio %.5f" % [m1s, m1d, m1s / maxf(m1d, 1e-9)])
	_checks += 1
	if m1s > 1.0 + 1e-3 or absf(m1s / maxf(m1d, 1e-9) - 1.0) > S1_TOL:
		_failures.append("S1 energy: sss %.6f vs diffuse %.6f" % [m1s, m1d])

	print("\n=== S2: albedo 0.8, radius (1,0.2,0.1)*0.05 vs Cycles ===")
	var s2 := await _sphere_mean(_sss_material(0.8, 1.0, Color(1.0, 0.2, 0.1), 0.05))
	print("  ours RGB %s  Cycles %s" % [s2, CYCLES_REF_S2])
	for i in range(3):
		_checks += 1
		var off := absf(s2[i] / maxf(CYCLES_REF_S2[i], 1e-9) - 1.0)
		if off > S2_TOL:
			_failures.append("S2 channel %d: %.6f vs Cycles %.6f (%.2f%%)" % [i, s2[i], CYCLES_REF_S2[i], off * 100.0])

	print("\n=== S4: radius 0 falls back to diffuse ===")
	var s4 := await _sphere_mean(_sss_material(0.8, 1.0, Color(0, 0, 0), 0.05))
	var s4_dif := await _sphere_mean(_sss_material(0.8, 0.0, Color(1, 1, 1), 0.05))
	print("  radius-0 %s  diffuse %s  (Cycles diffuse %s)" % [s4, s4_dif, CYCLES_REF_DIFFUSE])
	_checks += 1
	var m4 := (s4.x + s4.y + s4.z) / 3.0
	var m4d := (s4_dif.x + s4_dif.y + s4_dif.z) / 3.0
	if absf(m4 / maxf(m4d, 1e-9) - 1.0) > S4_TOL:
		_failures.append("S4 fallback: %.6f vs diffuse %.6f" % [m4, m4d])
```

Run on the Task 2 build. Expected: S1 passes vacuously (the solid SSS lobe is unimplemented → selected lobe falls through to a diffuse bounce ONLY if the `SUBSURFACE_TYPE` arm returns something — it returns `false` today, so the path terminates and S1 reads *low* → FAIL), S2 FAIL, S4 PASS (radius 0 → weight forced to 0 by Task 2 → diffuse). Record the readings.

- [ ] **Step 2: Payload flag**

`raytracing_inc.glsl`, after `PATH_TERMINATED_FLAG`:

```glsl
// E3 subsurface exit (bit 27). Set by the hit shader after a random walk
// found its exit point; the next ray is aimed back AT that point from
// outside, and the hit that results is shaded as a white Lambertian --
// Cycles' subsurface_shader_data_setup -- then the flag is cleared.
const uint SSS_EXIT_FLAG = (1u << 27);
uint set_sss_exit(uint packed) { return packed | SSS_EXIT_FLAG; }
uint clear_sss_exit(uint packed) { return packed & ~SSS_EXIT_FLAG; }
bool is_sss_exit(uint packed) { return (packed & SSS_EXIT_FLAG) != 0u; }
```

- [ ] **Step 3: The walk include**

`servers/rendering/renderer_rd/shaders/raytracing/raytracing_sss_inc.glsl` (new; included from the closest-hit stage after `brdf_inc.glsl`; `raytracing_common_inc.glsl`'s `tlas` and `GL_EXT_ray_query` are already available there — pass B uses them):

```glsl
// E3 subsurface: Cycles' random-walk BSSRDF, transcribed from
// intern/cycles/kernel/integrator/subsurface_random_walk.h (5.3.0-alpha) with
// anisotropy fixed at 0. Every constant and formula is Cycles'; only the
// intersection call (a same-instance ray query) and the RNG are ours.
#ifdef RT_SSS_ENABLED

#define SSS_MAX_BOUNCES 256u // BSSRDF_MAX_BOUNCES
#define SSS_THROUGHPUT_EPSILON 1e-6 // VOLUME_THROUGHPUT_EPSILON
#define SSS_MIN_ALPHA 0.2 // subsurface_random_walk_coefficients min_alpha

// Walk-local PCG. Cycles scrambles its path RNG with 0xdeadbeef for the walk;
// ours must not consume the path's Sobol dimensions (up to 256 steps x 4 draws),
// so the walk owns an independent 32-bit stream seeded from the path state.
uint sss_pcg(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}
float sss_rand(inout uint state) {
	return float(sss_pcg(state) >> 8u) * (1.0 / 16777216.0);
}

// subsurface_random_walk_remap (van de Hulst, d'Eon 53.7), g = 0.
void sss_remap(vec3 color, vec3 radius, out vec3 sigma_t, out vec3 alpha) {
	vec3 s_sq = 4.20863 * color - sqrt(9.59217 + 41.6808 * color + 17.7126 * color * color) + 4.09712;
	s_sq *= s_sq;
	alpha = clamp(1.0 - s_sq, vec3(0.0), vec3(0.999999)); // (1 - s²)/(1 - g s²) at g = 0
	sigma_t = 1.0 / max(radius, vec3(1e-16));
}

// diffusion_length_dwivedi, Eq. 67 of d'Eon & Krivanek 2020.
float sss_diffusion_length(float alpha) {
	return 1.0 / sqrt(1.0 - pow(alpha, 2.44294 - 0.0215813 * alpha + 0.578637 / alpha));
}
float sss_eval_phase_dwivedi(float v, float phase_log, float cos_theta) {
	return 1.0 / ((v - cos_theta) * phase_log);
}
float sss_sample_phase_dwivedi(float v, float phase_log, float r) {
	return v - (v + 1.0) * exp(-r * phase_log);
}
vec3 sss_direction_from_cosine(vec3 D, float cos_theta, float randv) {
	float phi = 2.0 * PI * randv;
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	vec3 T, B;
	// make_orthonormals
	if (abs(D.x) > abs(D.y)) {
		T = normalize(vec3(-D.z, 0.0, D.x));
	} else {
		T = normalize(vec3(0.0, D.z, -D.y));
	}
	B = cross(D, T);
	return T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + D * cos_theta;
}
// volume_sample_channel: MIS over channels by |throughput * albedo|.
int sss_sample_channel(vec3 alpha, vec3 throughput, inout float r, out vec3 pdf) {
	vec3 w = abs(throughput * alpha);
	float sum_w = w.x + w.y + w.z;
	pdf = (sum_w > 0.0) ? (w / sum_w) : vec3(1.0 / 3.0);
	if (r < pdf.x) {
		r /= pdf.x;
		return 0;
	}
	if (r < pdf.x + pdf.y) {
		r = (r - pdf.x) / pdf.y;
		return 1;
	}
	r = (r - pdf.x - pdf.y) / max(pdf.z, 1e-8);
	return 2;
}
float sss_channel(vec3 v, int c) { return (c == 0) ? v.x : ((c == 1) ? v.y : v.z); }
// subsurface_random_walk_pdf: T = exp(-sigma_t t); hit ? T : sigma_t T.
vec3 sss_walk_pdf(vec3 sigma_t, float t, bool hit, out vec3 transmittance) {
	transmittance = exp(-sigma_t * t);
	return hit ? transmittance : sigma_t * transmittance;
}

// Nearest intersection with THIS instance only, in [0, t_max]. step_zero skips
// the entry triangle (Cycles ray.self.prim on the first step).
bool sss_intersect_self(vec3 origin, vec3 dir, float t_max, uint self_instance, uint self_prim, bool step_zero,
		out float hit_t, out vec3 hit_normal_geo) {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, tlas, gl_RayFlagsNoOpaqueEXT, 0xFF, origin, 0.0, dir, t_max);
	bool any = false;
	while (rayQueryProceedEXT(rq)) {
		if (rayQueryGetIntersectionInstanceIdEXT(rq, false) != self_instance) {
			continue;
		}
		if (step_zero && rayQueryGetIntersectionPrimitiveIndexEXT(rq, false) == self_prim) {
			continue;
		}
		rayQueryConfirmIntersectionEXT(rq);
		any = true;
	}
	if (!any || rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
		return false;
	}
	hit_t = rayQueryGetIntersectionTEXT(rq, true);
	// Geometric normal of the exit triangle, world space, from the committed hit.
	uint gidx = rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true);
	uint pidx = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
	GeometryData geom = geometries[gidx];
	uint i0, i1, i2;
	get_triangle_indices_ex(geom, pidx, i0, i1, i2);
	vec3 p0 = fetch_position(geom, i0);
	vec3 p1 = fetch_position(geom, i1);
	vec3 p2 = fetch_position(geom, i2);
	mat4x3 o2w = rayQueryGetIntersectionObjectToWorldEXT(rq, true);
	vec3 w0 = o2w * vec4(p0, 1.0);
	vec3 w1 = o2w * vec4(p1, 1.0);
	vec3 w2 = o2w * vec4(p2, 1.0);
	hit_normal_geo = normalize(cross(w1 - w0, w2 - w0));
	return true;
}

// The walk. P: entry point (on the surface). D: entry direction (into the
// surface). N: shading normal at entry. Returns true with exit_pos/exit_dir on
// success; throughput is updated in place. False = path ends (Cycles).
bool sss_random_walk(vec3 P, vec3 D, vec3 N, MaterialProperties material, inout vec3 throughput,
		uint seed, uint self_instance, uint self_prim, out vec3 exit_pos, out vec3 exit_dir) {
	vec3 albedo = max(material.baseColor, vec3(0.0));
	vec3 radius = material.sssRadius;
	vec3 sigma_t, alpha;
	sss_remap(albedo, radius, sigma_t, alpha);
	// Throughput already carries the closure weight including albedo; divide it
	// out, the scattering re-adds it (subsurface_random_walk_coefficients).
	throughput = (albedo.r > 0.0 && albedo.g > 0.0 && albedo.b > 0.0) ? throughput / albedo : vec3(0.0);
	for (int i = 0; i < 3; i++) {
		if (alpha[i] < SSS_MIN_ALPHA) {
			throughput[i] *= alpha[i] / SSS_MIN_ALPHA;
			alpha[i] = SSS_MIN_ALPHA;
		}
	}
	vec3 sigma_s = sigma_t * alpha;
	float diffusion_length = sss_diffusion_length(max(max(alpha.r, alpha.g), alpha.b));
	if (diffusion_length == 1.0) {
		return false;
	}
	float phase_log = log((diffusion_length + 1.0) / (diffusion_length - 1.0));
	uint rng = seed ^ 0xdeadbeefu;
	// g = 0: guided_fraction = 1 - max(0.5, 0) = 0.5 (Cycles' heuristic).
	const float guided_fraction = 0.5;

	vec3 ray_p = P;
	vec3 ray_d = D;
	bool hit = false;
	bool have_opposite = false;
	float opposite_distance = 0.0;
	float hit_t = 0.0;
	vec3 hit_n = vec3(0.0);

	for (uint bounce = 0u; bounce < SSS_MAX_BOUNCES; bounce++) {
		float rchannel = sss_rand(rng);
		vec3 channel_pdf;
		int channel = sss_sample_channel(alpha, throughput, rchannel, channel_pdf);
		float sample_sigma_t = sss_channel(sigma_t, channel);
		float randt = sss_rand(rng);

		float backward_fraction = 0.0;
		float forward_pdf_factor = 0.0;
		float forward_stretching = 1.0;
		float backward_pdf_factor = 0.0;
		float backward_stretching = 1.0;

		if (bounce > 0u) {
			bool guided = sss_rand(rng) < guided_fraction;
			bool guide_backward = false;
			if (have_opposite) {
				float x = clamp(dot(ray_p - P, -N), 0.0, opposite_distance);
				backward_fraction = 1.0 / (1.0 + exp((opposite_distance - 2.0 * x) / diffusion_length));
				guide_backward = sss_rand(rng) < backward_fraction;
			}
			float rs_x = sss_rand(rng);
			float rs_y = sss_rand(rng);
			float cos_theta;
			float hg_pdf = 1.0 / (4.0 * PI); // isotropic phase at g = 0
			if (guided) {
				cos_theta = sss_sample_phase_dwivedi(diffusion_length, phase_log, rs_x);
				if (guide_backward) {
					cos_theta = -cos_theta;
				}
				ray_d = sss_direction_from_cosine(N, cos_theta, rs_y);
			} else {
				// phase_henyey_greenstein_sample at g = 0: uniform sphere.
				float ct = 1.0 - 2.0 * rs_x;
				ray_d = sss_direction_from_cosine(ray_d, ct, rs_y);
				cos_theta = dot(ray_d, N);
			}
			forward_pdf_factor = (1.0 / (2.0 * PI)) * sss_eval_phase_dwivedi(diffusion_length, phase_log, cos_theta) / hg_pdf;
			backward_pdf_factor = (1.0 / (2.0 * PI)) * sss_eval_phase_dwivedi(diffusion_length, phase_log, -cos_theta) / hg_pdf;
			forward_stretching = 1.0 - cos_theta / diffusion_length;
			backward_stretching = 1.0 + cos_theta / diffusion_length;
			if (guided) {
				sample_sigma_t *= guide_backward ? backward_stretching : forward_stretching;
			}
		}

		float t = -log(1.0 - randt) / sample_sigma_t;
		float t_max = (bounce == 0u) ? max(t, 10.0 / min(min(sigma_t.r, sigma_t.g), sigma_t.b)) : t;
		float ht;
		vec3 hn;
		bool h = sss_intersect_self(ray_p, ray_d, t_max, self_instance, self_prim, bounce == 0u, ht, hn);
		if (h) {
			t_max = ht;
		}
		if (bounce == 0u) {
			if (h) {
				have_opposite = true;
				opposite_distance = dot(ray_p + t_max * ray_d - P, -N);
			}
			h = t_max < t; // only a hit inside the sampled distance counts
		}
		if (h) {
			t = t_max;
			hit_t = ht;
			hit_n = hn;
		}
		ray_p += t * ray_d;

		vec3 transmittance;
		vec3 pdf = sss_walk_pdf(sigma_t, t, h, transmittance);
		if (bounce > 0u) {
			vec3 dummy;
			vec3 guided_pdf = sss_walk_pdf(forward_stretching * sigma_t, t, h, dummy);
			if (have_opposite) {
				vec3 back_pdf = sss_walk_pdf(backward_stretching * sigma_t, t, h, dummy);
				guided_pdf = mix(guided_pdf * forward_pdf_factor, back_pdf * backward_pdf_factor, backward_fraction);
			} else {
				guided_pdf *= forward_pdf_factor;
			}
			pdf = mix(pdf, guided_pdf, guided_fraction);
		}
		throughput *= (h ? transmittance : sigma_s * transmittance) / max(dot(channel_pdf, pdf), 1e-20);

		if (h) {
			hit = true;
			break;
		}
		if (max(max(throughput.r, throughput.g), throughput.b) < SSS_THROUGHPUT_EPSILON) {
			break;
		}
	}
	if (!hit) {
		return false;
	}
	exit_pos = ray_p;
	exit_dir = ray_d;
	return true;
}
#endif // RT_SSS_ENABLED
```

`fetch_position(geom, index)` — use the name the hit include actually exposes for a vertex position fetch (grep `fetch_` in `raytracing_hit_inc.glsl`); if only a combined fetch exists, use it. Confirm `PI` is defined in the closest-hit stage (grep); otherwise use the constant the BRDF file defines.

- [ ] **Step 4: Restart at an arbitrary point (payload)**

The raygen rebuilds the next origin as `ray_origin + ray_dir * hit_t`, which cannot express the SSS restart point. Add to `PathPayload` / `PathState` a `vec3 sss_restart` (12 bytes; payload 56 → 68, padded to 80 by vec3 alignment — acceptable; note it in the size comment) copied by `path_pack`/`path_unpack`, initialised to `vec3(0)`, and in the raygen restart block:

```glsl
#ifdef RT_SSS_ENABLED
		if (is_sss_exit(ps.packed_bounces_flags)) {
			// E3: the walk's exit is not on this ray; restart from the point the
			// hit shader computed, 2 mm outside the exit face, aimed back at it.
			ray_origin = ps.sss_restart;
			t_min = 0.001;
			ray_dir = ps.next_ray_dir;
			continue_to_trace = true;
		} else
#endif
		{ ...existing restart... }
```

Read the loop's structure first: the restart block assigns `ray_origin`, `t_min` and `ray_dir` then loops; write the SSS branch as an `if/else` around exactly those three assignments (no `continue_to_trace` variable exists — that line is illustrative; the branch just must skip the offset/skip-id logic).

- [ ] **Step 5: Entry and exit in `shade_and_bounce`**

Exit shading first — at the top of `shade_and_bounce`, right after the Gap #26 skip clear:

```glsl
#ifdef RT_SSS_ENABLED
	// E3: this hit is the EXIT of a random walk (SSS_EXIT_FLAG). Cycles'
	// subsurface_shader_data_setup replaces the whole shader with a diffuse
	// closure of weight 1 on the bump-mapped normal: no emission, no specular,
	// no coat/sheen/transmission, no second subsurface here.
	const bool sss_exit_hit = is_sss_exit(ps.packed_bounces_flags);
	if (sss_exit_hit) {
		ps.packed_bounces_flags = clear_sss_exit(ps.packed_bounces_flags);
		m.albedo = vec3(1.0);
		m.alpha = 1.0;
		m.blends = false;
		m.metalness = 0.0;
		m.specular = 0.0;
		m.emissive = vec3(0.0);
		m.transmission = 0.0;
		m.roughness = 1.0;
	}
#endif
```

and after `brdf_mat` is fully built (after the Task 2 block), force the exit material's other lobes off:

```glsl
#ifdef RT_SSS_ENABLED
	if (sss_exit_hit) {
		brdf_mat.coatWeight = 0.0;
		brdf_mat.sheenColor = vec3(0.0);
		brdf_mat.sssWeight = 0.0;
		brdf_mat.transmissivness = 0.0;
		brdf_mat.dielectricF0 = vec3(0.0);
	}
#endif
```

(Confirm the field names against `MaterialResult` in the raygen file and `MaterialProperties`; `m.specular = 0.0` + `dielectricF0 = 0` is what makes `lobeWeight` pick diffuse with probability 1 — check `lobeWeight`'s inputs and, if it reads `specular` differently, set whichever field zeroes the specular share.)

Entry — in the SUBSURFACE_TYPE branch of the sampling code (where `evalIndirectCombinedBRDF` is called for the selected lobe), for the **solid** case:

```glsl
#ifdef RT_SSS_ENABLED
	if (brdfType == SUBSURFACE_TYPE && !brdf_mat.sssThin) {
		// Cycles subsurface_entry_bounce: GGX VNDF microfacet at alpha = r², refract
		// wi at 1/ior, direction only (no BSDF/pdf factor -- Cycles' note).
		float sss_ior = clamp(brdf_mat.eta > 0.0 ? brdf_mat.eta : 1.4, 1.01, 3.8);
		float ent_alpha = brdf_mat.roughness * brdf_mat.roughness;
		float2 u_ent = rng_2d(rng, RT_PRNG_SURFACE_BSDF);
		float4 qRot = getRotationToZAxis(N);
		float3 V_local = rotatePoint(qRot, V);
		float3 H_local = sampleGGXVNDF(V_local, float2(ent_alpha, ent_alpha), u_ent);
		float3 H = normalize(rotatePoint(invertRotation(qRot), H_local));
		float neta = 1.0 / sss_ior;
		float cos_HI = dot(H, V);
		float arg = 1.0 - neta * neta * (1.0 - cos_HI * cos_HI);
		if (cos_HI <= 0.0 || arg < 0.0) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		float dnp = max(sqrt(arg), 1e-7);
		float nK = neta * cos_HI - dnp;
		vec3 wo = -(neta * V) + nK * H;
		if (dot(h.geometry_normal, wo) >= 0.0) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// Closure weight over selection probability: the base colour (Cycles
		// closure_weight = base_color * w * layering; w / weights[] cancelled at
		// selection), then the walk divides the albedo back out.
		ps.throughput *= brdf_mat.baseColor * layerTransmittanceAbove(brdf_mat, N, V, LOBE_DIFFUSE);
		vec3 exit_pos, exit_dir;
		uint seed = ps.rng_packed ^ (gl_PrimitiveID * 0x9E3779B9u) ^ floatBitsToUint(hit_pos.x + hit_pos.z);
		if (!sss_random_walk(hit_pos, wo, N, brdf_mat, ps.throughput, seed, gl_InstanceID, gl_PrimitiveID, exit_pos, exit_dir)) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// Re-aim: next ray starts 2 mm past the exit point along the walk
		// direction and points back at it (Cycles: P += D*tmax*2; D = -D).
		const float SSS_EXIT_DELTA = 0.002;
		vec3 restart = exit_pos + exit_dir * SSS_EXIT_DELTA;
		// The raygen rebuilds the next origin as origin + dir * hit_t, which cannot
		// express a point off the current ray; Step 4 added ps.sss_restart and the
		// raygen branch that starts from it when SSS_EXIT_FLAG is set.
		ps.hit_t = gl_HitTEXT;
		ps.next_ray_dir = -exit_dir;
		ps.offset_normal = exit_dir;
		ps.sss_restart = restart;
		ps.packed_bounces_flags = set_sss_exit(inc_diffuse_bounce(ps.packed_bounces_flags));
		ps.mis_ray_pdf = RT_MIS_PDF_NONE;
		ps.rng_packed = rng_pack(rng_next_bounce(rng));
		path_pack(payload, ps);
		return;
	}
#endif
```

- [ ] **Step 6: Build and run the gate**

Expected: S3 unchanged (≈ 0.40), S1 `sss` within 2% of `diffuse` and ≤ 1.0, S2 within 5% of Cycles per channel, S4 unchanged. If S1 reads high: the throughput at entry is being multiplied by the base colour twice (selection division already includes `w`; check `ps.throughput /= weights[LOBE_SUBSURFACE]` in Task 2 and the `* baseColor` here — Cycles' closure weight is `base_color * w * layering` and its `sample_weight` normalisation divides by `w`, so the net factor is `base_color * layering`, which is what the line applies). If S1 reads low by a constant factor: the walk is dividing by `albedo` before the throughput had it — verify the multiply-then-divide order. If S1 is ~0: `sss_intersect_self` never confirms — print `gl_InstanceID` vs `rayQueryGetIntersectionInstanceIdEXT` once via a vis mode if needed.

- [ ] **Step 7: Doctest, isolation, commit**

`--test`: 1558/1558. `pt_glass_energy_gate`, `pt_transmission_gate`, `pt_thin_layer_gate`: unchanged (no SSS material → identical shader).

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_sss_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl pipeline_references/tests/pt_subsurface_gate.gd
git commit -m "feat(pt): E3 -- Cycles random-walk subsurface: refracted entry, Dwivedi-guided walk, exit shaded as a white Lambertian

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Pipeline rule, asset renders, suite, roadmap

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd` (user's file — NOT staged)
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (row 13, §11.23)

- [ ] **Step 1: The keyword table**

In `image_glb_creation.gd`, next to `GLB_GLASS_MATERIAL_KEYWORDS`:

```gdscript
# E3 subsurface presets, keyed on the MATERIAL name (never the asset). Applied
# after GLB_KEEP_ALPHA_KEYWORDS, water and glass have had their turn; first
# matching row wins. transmittance_depth 0.0 means THIN-WALL (a sheet: diffuse
# + translucent split), > 0 means a solid random walk with that scale in
# metres. Starting points -- tune by eye. See
# docs/superpowers/specs/2026-09-15-e3-subsurface-scattering-design.md.
const GLB_SUBSURFACE_PRESETS = [
	{"keywords": ["marble"], "strength": 1.0, "radius": Color(1.0, 0.95, 0.9), "depth": 0.03},
	{"keywords": ["candle", "wax"], "strength": 1.0, "radius": Color(1.0, 0.8, 0.6), "depth": 0.05},
	{"keywords": ["lampshade", "shade", "paper"], "strength": 0.7, "radius": Color(1, 1, 1), "depth": 0.0},
	{"keywords": ["leaf"], "strength": 0.3, "radius": Color(1, 1, 1), "depth": 0.0},
]
```

A function beside `_apply_glb_transmissive_glass`:

```gdscript
# Returns true when a preset applied. `context_text` is the same lower-cased
# material/surface name the glass classifier reads.
func _apply_glb_subsurface_preset(mat: BaseMaterial3D, context_text: String) -> bool:
	var t := context_text.to_lower()
	if t.strip_edges() == "":
		return false
	for kw in GLB_KEEP_ALPHA_KEYWORDS:
		if kw in t:
			return false
	if _classify_glb_alpha_material(context_text) != "":
		return false # glass and water are handled by their own rules
	for preset in GLB_SUBSURFACE_PRESETS:
		for kw in preset["keywords"]:
			if kw in t:
				mat.subsurf_scatter_enabled = true
				mat.subsurf_scatter_strength = float(preset["strength"])
				mat.subsurf_scatter_transmittance_enabled = true
				mat.transmittance_color = (preset["radius"] as Color).linear_to_srgb()
				mat.transmittance_depth = float(preset["depth"])
				return true
	return false
```

Call it from the same per-surface loop that runs the glass classification (`_convert_glb_alpha_glass`'s surface loop, or the asset material pass that runs for every surface — read which loop visits every surface material of every asset, and call it there on a `duplicate()` of the surface material set as the override, exactly as the kept-alpha branch does). Print one summary line per asset: `  [SSS] <asset> -> <material> (<preset first keyword>)`.

Parse check: `--headless --path pipeline_references --check-only -s image_glb_creation.gd`.

- [ ] **Step 2: Isolation render — rule off**

Scratch copy of the live project with the reference `image_glb_creation.gd` but `GLB_SUBSURFACE_PRESETS = []`, render `d217_fhd.json` on the Task 4 build to `<scratchpad>/e3/d217_off.png`; compare to `<scratchpad>/g26/d217_g22.png` (last pre-E3 render on the same route): whole-frame change must be **0.00%** (no SSS material → the feature is compiled out).

- [ ] **Step 3: Rule on**

Same copy with the presets in; render to `<scratchpad>/e3/d217_on.png`. Expected: the log shows `[SSS]` lines for the marble table and the candles; the marble table's mean moves (record by how much) and the rest of the frame is within 1%. Crop the table and the candle for the roadmap and for the user.

- [ ] **Step 4: Suite and doctest**

Every `pt_*_gate_scene.tscn` (with `.tscn` in the path!) green; `pt_subsurface_gate` included. Doctest 1558/1558.

- [ ] **Step 5: Roadmap**

Row 13: replace `**SSS is what remains**` with `**SSS shipped 2026-09-xx (E3, §11.23)**: Cycles random walk (van de Hulst remap, Dwivedi guiding, channel MIS, 256 steps) for solids and the OpenPBR thin-wall split for sheets; gate S1 energy / S2 vs Cycles / S3 thin-wall / S4 fallback; pipeline keyword rule (marble, wax, shade/paper, leaf). Skin mode deferred (render_mode invisible to the upload).` Add §11.23 with the Cycles numbers, the gate table before/after, the 217 off/on measurements, and the deviation list (skin, anisotropy 0, payload +12 bytes).

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md docs/superpowers/plans/2026-09-15-e3-subsurface-scattering.md
git commit -m "docs(pt): E3 subsurface shipped -- roadmap 11.23, Gap #13 complete

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

`pipeline_references/image_glb_creation.gd` stays uncommitted for the user.

---

## Self-review

- **Spec coverage:** material mapping + struct + feature gate (T1); registry lobe, weights, layer depth, thin-wall sampling and NEE (T2); Cycles script (T3); entry/coefficients/walk/self-intersection/exit/termination + payload flag (T4); pipeline table + isolation + asset check + roadmap (T5); gates S1–S4 (T2, T4). Skin mode / S5: deferred with the reason in T1 Step 9. Spec's "DLSS-RR guides unchanged": nothing touches them.
- **Placeholders:** `CYCLES_REF_*` zero vectors are filled from Task 3's measured run (T4 Step 1 says so); no other TODO/TBD.
- **Type consistency:** `sssWeight/sssThin/sssRadius/sssScale` (T2) read by T4; `SUBSURFACE_TYPE`, `LOBE_SUBSURFACE` (T2) used by T4; `SSS_EXIT_FLAG` helpers (T4 Step 2) used in T4 Steps 4–5; `sss_random_walk` signature (T4 Step 3) matches its call (Step 4); `outTranslucent`/`brdf_translucent` (T2 Step 6) consistent across the three NEE sites.
