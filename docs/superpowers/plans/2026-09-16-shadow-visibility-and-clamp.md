# Gap #30 Shadow Visibility + Indirect Clamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shadow rays ignore any instance whose `cast_shadow` is OFF (Cycles' per-object shadow visibility), so daylight enters through window glass; the still route runs Cycles' indirect clamp of 10; the user gets three lighting-rig renders to decide the rig's future.

**Architecture:** A third TLAS instance-mask value `RT_INSTANCE_MASK_NO_SHADOW = 0x04` that camera/bounce rays (0xFF) see and neither shadow pass (0x01 / 0x02) does. The cast-shadows setting travels from `RendererSceneCull` to `RenderGeometryInstanceBase::Data` through a new virtual, and the four mask sites in `build_tlas` read it. A gate with an opaque card over a lit floor is red today. A documented debug env var `ZR_LIGHTS_SKIP` replaces this session's temporary knob for the rig renders.

**Tech Stack:** C++ (rendering server abstraction, RD renderer, TLAS build), GLSL define, GDScript gate.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-16-shadow-visibility-and-clamp-design.md`.
- `pipeline_references/*.gd` directly under that directory are the user's files: the clamp edit is a reference copy, never staged. `pipeline_references/tests/` may be committed.
- `git add` with explicit paths only. Commits end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Build: `python -m SCons platform=windows target=editor tests=yes -j8`; a clean build proves nothing about GLSL — run the gate.
- Gate paths carry `.tscn`. Renders go to the scratchpad (`<scratchpad>` = this session's, `.../012f0870-.../scratchpad`, which already holds `proj_225` and the six decomposition EXRs/PNGs).
- Mask constants, both sides: `RT_INSTANCE_MASK_OPAQUE 0x01`, `RT_INSTANCE_MASK_TRANSMISSIVE 0x02`, **`RT_INSTANCE_MASK_NO_SHADOW 0x04`**, `RT_INSTANCE_MASK_ALL 0xFF`.
- Storage abstraction: any new `RenderGeometryInstance` virtual needs the base implementation *and* the dummy stub (`servers/rendering/dummy/rasterizer_scene_dummy.h`).
- `SHADOW_CASTING_SETTING_SHADOWS_ONLY` and `DOUBLE_SIDED` behave as ON in the tracer (out of scope).

---

### Task 1: The shadow-visibility gate (red on today's build)

**Files:**
- Create: `pipeline_references/tests/pt_shadow_visibility_gate.gd`
- Create: `pipeline_references/tests/pt_shadow_visibility_gate_scene.tscn`

**Interfaces:**
- Consumes: `pt_validation.gd::_render_accum`; the geometry of `pt_transparent_shadow_gate.gd::_measure_ratio` (floor at y = −1, 30×0.05×30 pane at y = 1 above the camera at y = 0.5, directional light, crop 0.35–0.65).
- Produces: printed `V1..V4` ratios; constants `BLOCK_MAX := 0.005`, `PASS_TOL := 0.02`.

Four probes, each a ratio "floor crop with the card ÷ floor crop without it", black sky, one bounce, directional light at normal incidence:

- **V1 control** — opaque black card, `cast_shadow = ON`: ratio ≤ `BLOCK_MAX` (the card shadows the whole crop).
- **V2 fix** — same card, `cast_shadow = OFF`: ratio within `PASS_TOL` of 1.0 (shadow rays ignore it). **Red today** (reads ≈ 0).
- **V3 Gap #22 guard** — thin glass pane (transmission 1, thickness 0), `cast_shadow = ON`: ratio ≤ `BLOCK_MAX`.
- **V4 camera guard** — opaque card with `cast_shadow = OFF` placed at y = 0, **between** camera and floor, covering the crop: ratio ≤ `BLOCK_MAX` because camera rays still hit the black card (proves the mask only hides it from shadow rays).

- [ ] **Step 1: Write the gate**

`pipeline_references/tests/pt_shadow_visibility_gate.gd`:

```gdscript
extends "res://tests/pt_validation.gd"

## Shadow-visibility gate (spec 2026-09-16-shadow-visibility-and-clamp-design.md,
## roadmap Gap #30).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_shadow_visibility_gate_scene.tscn
##
## Cycles' per-object "Ray Visibility: Shadow" -- an object without the bit is
## never hit by a shadow ray but is still seen by camera and bounce rays. Godot's
## switch for it is GeometryInstance3D.cast_shadow = OFF; the pipeline already
## sets it on window-asset glass, and until Gap #30 the tracer ignored it, so
## no daylight entered a glazed room (job 225: sun + sky alone rendered black).
##
## Same fixture as pt_transparent_shadow_gate: a grey floor at y = -1, a
## 30x30 card at y = 1 (above the camera at y = 0.5, so no camera ray can hit
## it), a directional light straight down, black sky, one bounce. Each probe
## is the crop's mean with the card / without it.
##
##   V1 opaque card, cast_shadow ON  : <= BLOCK_MAX   (control -- it shadows)
##   V2 opaque card, cast_shadow OFF : 1.0 +- PASS_TOL (shadow rays ignore it)
##   V3 glass pane,  cast_shadow ON  : <= BLOCK_MAX   (Gap #22 still blocks)
##   V4 opaque card, cast_shadow OFF, placed at y = 0 IN the camera's view:
##      <= BLOCK_MAX -- camera rays still see it; only shadow rays do not.

const FRAMES := 128
const BLOCK_MAX := 0.005
const PASS_TOL := 0.02

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== V1: opaque card, cast_shadow ON (control) ===")
	var v1 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, 1.0)
	_check("V1 control", v1, 0.0, BLOCK_MAX)

	print("\n=== V2: opaque card, cast_shadow OFF ===")
	var v2 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, 1.0)
	_check("V2 shadow-off", v2, 1.0 - PASS_TOL, 1.0 + PASS_TOL)

	print("\n=== V3: glass pane, cast_shadow ON (Gap #22 guard) ===")
	var v3 := await _ratio(true, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, 1.0)
	_check("V3 glass blocks", v3, 0.0, BLOCK_MAX)

	print("\n=== V4: opaque card, cast_shadow OFF, in view (camera guard) ===")
	var v4 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, 0.0)
	_check("V4 camera sees it", v4, 0.0, BLOCK_MAX)

	print("")
	if _failures.is_empty():
		print("PASS: all %d shadow-visibility checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	print("  %s: ratio %.6f (band [%.3f, %.3f])" % [p_name, p_value, p_lo, p_hi])
	if p_value < p_lo or p_value > p_hi:
		_failures.append("%s: ratio %.6f outside [%.3f, %.3f]" % [p_name, p_value, p_lo, p_hi])


## Floor crop with the card divided by the crop without it. p_card_y = 1.0
## puts the card above the camera (only shadow rays can meet it); 0.0 puts it
## between camera and floor (camera rays meet it first).
func _ratio(p_glass: bool, p_cast: int, p_card_y: float) -> float:
	for c in get_children():
		c.queue_free()

	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(6, 0.1, 6)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, -1, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.5, 0.5, 0.5)
	floor_mat.roughness = 1.0
	floor_mat.metallic = 0.0
	floor_mi.material_override = floor_mat
	add_child(floor_mi)

	var card_mat := StandardMaterial3D.new()
	if p_glass:
		card_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		card_mat.transmission = 1.0
		card_mat.thickness = 0.0
		card_mat.roughness = 0.0
		card_mat.metallic = 0.0
		card_mat.metallic_specular = 0.5
		card_mat.ior = 1.5
	else:
		card_mat.albedo_color = Color(0, 0, 0)
		card_mat.roughness = 1.0
		card_mat.metallic = 0.0
		card_mat.metallic_specular = 0.0
	var card := MeshInstance3D.new()
	var card_mesh := BoxMesh.new()
	card_mesh.size = Vector3(30, 0.05, 30)
	card.mesh = card_mesh
	card.position = Vector3(0, p_card_y, 0)
	card.material_override = card_mat
	card.cast_shadow = p_cast
	add_child(card)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-90, 0, 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0, 0.5, 4), Vector3(0, -1, 0), Vector3.UP)
	cam.fov = 30.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(1)
	await get_tree().create_timer(1.0).timeout

	card.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)
	card.visible = true
	for _i in range(3):
		await get_tree().process_frame
	var with_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var with_card := _measure_crop(with_img, 0.35, 0.65)
	print("  control mean %.6f, with-card mean %.6f" % [control["mean"], with_card["mean"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f)" % control["mean"])
		return 0.0
	return float(with_card["mean"]) / float(control["mean"])


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

`pipeline_references/tests/pt_shadow_visibility_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_shadow_visibility_gate.gd" id="1_gate"]

[node name="PTShadowVisibilityGate" type="Node"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: Run on the current build — V2 red, V1/V3/V4 green**

```bash
bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_shadow_visibility_gate_scene.tscn
```

Expected: V1 ≈ 0, **V2 ≈ 0 → FAIL**, V3 ≈ 0, V4 ≈ 0, `FAIL: 1 of 4`. If V1 is not ≈ 0, the card is not covering the crop's light path — the light is straight down, so check the card is at y = 1 and 30 units wide. If the control reads black, the floor is unlit: the light's `rotation_degrees = (-90, 0, 0)` points −Z down… Godot's DirectionalLight3D shines along its local −Z, and `(-90,0,0)` turns −Z to −Y (down); verify with `light.rotation_degrees` printed.

- [ ] **Step 3: Commit**

```bash
git add pipeline_references/tests/pt_shadow_visibility_gate.gd pipeline_references/tests/pt_shadow_visibility_gate_scene.tscn
git commit -m "test(pt): shadow-visibility gate -- cast_shadow OFF must hide an instance from shadow rays only (red)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `cast_shadows` reaches the geometry instance (engine, abstraction)

**Files:**
- Modify: `servers/rendering/renderer_geometry_instance.h:63` (virtual), `:130` (Data field), `:153` (base override)
- Modify: `servers/rendering/renderer_geometry_instance.cpp:131` (base implementation, beside `set_cast_double_sided_shadows`)
- Modify: `servers/rendering/dummy/rasterizer_scene_dummy.h:68` (stub)
- Modify: `servers/rendering/renderer_scene_cull.cpp:1367` (call site)

**Interfaces:**
- Produces: `RenderGeometryInstanceBase::Data::cast_shadows_setting` (`RSE::ShadowCastingSetting`, default `SHADOW_CASTING_SETTING_ON`), set by `set_cast_shadows_setting()`.

- [ ] **Step 1: Virtual, field, base override, stub**

`renderer_geometry_instance.h` — after `virtual void set_cast_double_sided_shadows(bool p_enable) = 0;`:

```cpp
	// Full cast-shadows setting, not just the double-sided bit: the path tracer
	// reads it to hide SHADOW_CASTING_SETTING_OFF instances from shadow rays
	// (Cycles' per-object shadow visibility). Gap #30.
	virtual void set_cast_shadows_setting(RSE::ShadowCastingSetting p_setting) = 0;
```

after `bool cast_double_sided_shadows = false;` in `Data`:

```cpp
		RSE::ShadowCastingSetting cast_shadows_setting = RSE::SHADOW_CASTING_SETTING_ON;
```

after `virtual void set_cast_double_sided_shadows(bool p_enable) override;` in the base class:

```cpp
	virtual void set_cast_shadows_setting(RSE::ShadowCastingSetting p_setting) override;
```

`renderer_geometry_instance.cpp`, after the `set_cast_double_sided_shadows` body:

```cpp
void RenderGeometryInstanceBase::set_cast_shadows_setting(RSE::ShadowCastingSetting p_setting) {
	data->cast_shadows_setting = p_setting;

	_mark_dirty();
}
```

`rasterizer_scene_dummy.h`, after the `set_cast_double_sided_shadows` stub:

```cpp
		virtual void set_cast_shadows_setting(RSE::ShadowCastingSetting p_setting) override {}
```

- [ ] **Step 2: Call it from the cull layer**

`renderer_scene_cull.cpp`, in `instance_geometry_set_cast_shadows_setting`, directly after `geom->geometry_instance->set_cast_double_sided_shadows(...)`:

```cpp
		geom->geometry_instance->set_cast_shadows_setting(instance->cast_shadows);
```

- [ ] **Step 3: Build**

Expected: exit 0. A "cannot instantiate abstract class" error names a `RenderGeometryInstance` subclass missing the override — add the stub there (grep `set_cast_double_sided_shadows` for every implementer).

- [ ] **Step 4: Commit**

```bash
git add servers/rendering/renderer_geometry_instance.h servers/rendering/renderer_geometry_instance.cpp servers/rendering/dummy/rasterizer_scene_dummy.h servers/rendering/renderer_scene_cull.cpp
git commit -m "feat(rs): geometry instances carry their full cast-shadows setting

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The NO_SHADOW mask (engine, tracer)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:142-146`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:91-95`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:2533-2537` (helper) and the four `instance_masks.push_back(...)` sites (~2875, ~3164, ~3222, ~3310)

**Interfaces:**
- Consumes: `inst->data->cast_shadows_setting` (Task 2); `inst` is the loop variable at all four sites (`render_raytracing.cpp:2784`).
- Produces: `RT_INSTANCE_MASK_NO_SHADOW = 0x04`; `rt_instance_mask(inst, feature_bits, uses_blend)`.

- [ ] **Step 1: Constants**

`scene_shader_raytracing.h`, after `RT_INSTANCE_MASK_TRANSMISSIVE`:

```cpp
	// Cycles' per-object shadow visibility (Gap #30): an instance whose
	// cast_shadows is SHADOW_CASTING_SETTING_OFF gets ONLY this bit. Camera and
	// bounce rays trace with RT_INSTANCE_MASK_ALL and still hit it; shadow pass A
	// (OPAQUE) and pass B (TRANSMISSIVE) never do. Window glass with cast_shadow
	// off lets the sky and the sun in, as it does in Blender archviz.
	constexpr static uint32_t RT_INSTANCE_MASK_NO_SHADOW = 0x04;
```

and extend the static_assert block:

```cpp
	static_assert((RT_INSTANCE_MASK_NO_SHADOW & (RT_INSTANCE_MASK_OPAQUE | RT_INSTANCE_MASK_TRANSMISSIVE)) == 0,
			"NO_SHADOW must be invisible to both shadow passes");
```

`raytracing_common_inc.glsl`, after `#define RT_INSTANCE_MASK_TRANSMISSIVE 0x02u`:

```glsl
#define RT_INSTANCE_MASK_NO_SHADOW 0x04u // cast_shadow OFF: camera/bounce rays only (Gap #30)
```

- [ ] **Step 2: The helper and the four sites**

Replace `rt_instance_mask_from_features` with:

```cpp
// Which shadow pass may see an instance (Gap #22 split), and whether any may
// (Gap #30). An instance with cast_shadows OFF is Cycles' "shadow visibility
// off": camera and bounce rays (RT_INSTANCE_MASK_ALL) hit it, no shadow ray
// does, whatever its material. SHADOWS_ONLY and DOUBLE_SIDED behave as ON here.
static _FORCE_INLINE_ uint32_t rt_instance_mask(const RenderForwardClustered::GeometryInstanceForwardClustered *p_inst, uint32_t p_feature_bits, bool p_uses_blend) {
	if (p_inst && p_inst->data && p_inst->data->cast_shadows_setting == RSE::SHADOW_CASTING_SETTING_OFF) {
		return SceneShaderRaytracing::RT_INSTANCE_MASK_NO_SHADOW;
	}
	return ((p_feature_bits & SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY) || p_uses_blend)
			? SceneShaderRaytracing::RT_INSTANCE_MASK_TRANSMISSIVE
			: SceneShaderRaytracing::RT_INSTANCE_MASK_OPAQUE;
}
```

At each of the four sites change `rt_instance_mask_from_features(` to `rt_instance_mask(inst, ` (the procedural site: `rt_instance_mask(inst, proc_mat_data->feature_bits, false)`). `grep -n rt_instance_mask_from_features` must then return only comments; update the comment at ~1959-1967 that names the old function.

- [ ] **Step 3: Build, gate green**

Build; run the Task 1 gate. Expected: V1 ≈ 0, **V2 within 0.02 of 1.0**, V3 ≈ 0, V4 ≈ 0, `PASS: all 4`. If V2 is still ≈ 0: the mask never reached the TLAS — check `instance_masks` is consumed at `render_raytracing.cpp:2065` (`inst.mask = ...`) for the mesh path, and that the setting arrived (print `inst->data->cast_shadows_setting` for one frame). If V4 lights up: camera rays are also tracing with a mask that excludes 0x04 somewhere — grep `traceRayEXT(` / `hitObjectTraceRayEXT(` for a mask other than `0xFF`.

- [ ] **Step 4: Suite and doctest**

All 18 gates green (17 + this one), doctest 1558/1558. `pt_transparent_shadow_gate` is the one that could move — its panes have `cast_shadow` at the default ON, so it must not.

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): cast_shadow OFF hides an instance from shadow rays -- Cycles' shadow visibility (Gap #30)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `ZR_LIGHTS_SKIP` debug env var (engine), clamp 10 (pipeline reference copy)

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (directional site ~3494, positional loop ~3552, `emissive_active` read ~2547)
- Modify: `pipeline_references/image_glb_creation.gd` (`PHASE_A_CLAMP_INDIRECT`; NOT staged)

- [ ] **Step 1: The env var, read once**

Add near the top of `render_raytracing.cpp` (after the includes; `core/os/os.h` is already included):

```cpp
// Debug: ZR_LIGHTS_SKIP=dir,pos,emissive drops whole light classes from the
// tracer for lighting decomposition renders (roadmap Gap #30 used it to show
// a "day" interior was lit almost entirely by the pipeline's artificial
// lights). Read once per process; production never sets it.
static uint32_t zr_lights_skip_flags() {
	static uint32_t flags = 0xFFFFFFFFu;
	if (flags == 0xFFFFFFFFu) {
		const String v = OS::get_singleton()->get_environment("ZR_LIGHTS_SKIP");
		flags = (v.contains("dir") ? 1u : 0u) | (v.contains("pos") ? 2u : 0u) | (v.contains("emissive") ? 4u : 0u);
		if (flags != 0u) {
			print_line(vformat("[ZR_LIGHTS_SKIP] '%s' -> directional %d, positional %d, emissive %d", v, (flags & 1u) != 0u, (flags & 2u) != 0u, (flags & 4u) != 0u));
		}
	}
	return flags;
}
```

Directional site, after `if (type != RSE::LIGHT_DIRECTIONAL) { continue; }`:

```cpp
		if (zr_lights_skip_flags() & 1u) {
			continue;
		}
```

Positional loop condition: `for (uint32_t i = 0; i < positional_lights.size() && rt_light_count < p_max_lights && !(zr_lights_skip_flags() & 2u); i++) {`

After `emissive_active = GLOBAL_GET("rendering/pathtracer/emissive_mesh_lights");`:

```cpp
	if (zr_lights_skip_flags() & 4u) {
		emissive_active = false;
	}
```

- [ ] **Step 2: Clamp 10 in the reference copy**

`image_glb_creation.gd`: `const PHASE_A_CLAMP_INDIRECT := 0.0` → `10.0`, and replace the tuning comment line `#   CLAMP_INDIRECT   firefly suppression, 0 = off. Blender's default is 10.0.` with:

```
	#   CLAMP_INDIRECT   firefly suppression, 0 = off. 10.0 is Cycles'
	#                    sample_clamp_indirect default. Measured on job 225 at FHD
	#                    (2026-09-16): pixels above 4x the local median 0.12% -> 0.00%,
	#                    brightest/median 36x -> 2x, medians unchanged to 4 digits.
	#                    Those fireflies are what OIDN smeared into blotches.
```

Parse check: `bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references --check-only -s image_glb_creation.gd`.

- [ ] **Step 3: Build, run the decomposition again**

Copy the reference `image_glb_creation.gd` over `<scratchpad>/proj_225/image_glb_creation.gd`. Re-run the six-render script (`<scratchpad>/run_g30.sh`, outputs now to `g30b_*`) with the new binary, then `python <scratchpad>/g30_stats.py <scratchpad-windows-path> base nosun sunonly clamp10` (add `g30b_` to the script's file pattern or pass names accordingly). Expected: **sun-and-sky-only is no longer black** (frame mean well above 0.013 — the exact value is the finding), the full rig's fireflies are 0.00% at 2×, and the sun's contribution to the ceiling median is now visible. If sun-only is still black: the window asset's glass is not the mesh carrying `cast_shadow = OFF` — read the `[GlassFix]` line for `d0533267_SoftMinimal_Window` and `_disable_shadow_casting_recursive`'s `_is_glass_mesh` predicate; the pane may be classified by name, not material.

- [ ] **Step 4: Commit the engine part**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): ZR_LIGHTS_SKIP debug env var for lighting decomposition renders

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

`image_glb_creation.gd` stays unstaged.

---

### Task 5: Three lighting-rig renders for the user, roadmap

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md` (row 30, §11.26)
- Modify: this plan (ticks, notes)

- [ ] **Step 1: The three renders (FHD, Phase A + OIDN, the deliverable route)**

In `<scratchpad>/proj_225` (reference pipeline, clamp 10):

1. `rig_full.png` — as production now is (no env vars).
2. `daylight_only.png` — `ZR_LIGHTS_SKIP=pos,emissive`.
3. `rig_no_portals.png` — a scratch-copy-only edit: comment out the `_create_window_portal_lights()` call (`image_glb_creation.gd:503` in the copy), no env vars.

Each with `ZR_PT_EXR=1`; run `g30_stats.py` on the three EXRs. Deliver the three PNGs (half-size previews) and the noise table to the user with `SendUserFile`. No pipeline change beyond the clamp is made; the rig decision is the user's.

- [ ] **Step 2: Roadmap**

Row 30 after row 29:

```
| 30 | **Daylight could not enter: the tracer ignored `cast_shadow = OFF`; indirect clamp off** — a "day" interior was lit by 17 artificial lights, sun + sky alone rendered black, fireflies at 36× fed OIDN's blotches. **Closed 2026-09-16 (§11.26)**: `RT_INSTANCE_MASK_NO_SHADOW` (Cycles' shadow visibility) honours `cast_shadow = OFF`; `PHASE_A_CLAMP_INDIRECT` 10 (Cycles' default). `pt_shadow_visibility_gate` V2 0 → 1.0. Lighting rig: user's decision, three renders delivered. | `render_raytracing.cpp rt_instance_mask`, `renderer_geometry_instance.h`, `image_glb_creation.gd` | `kernel/light/light.h` visibility, `scene.cycles.sample_clamp_indirect` | High |
```

§11.26 "Gap #30 — the daylight was outside the window": the two noise tables (before/after), the decomposition, the mechanism, the gate's V1–V4 before/after, the three rig renders' numbers, and "open": the rig decision; `SHADOWS_ONLY` camera invisibility; a light tree if the rig stays.

- [ ] **Step 3: Tick and commit**

```bash
sed -i 's/^- \[ \] /- [x] /' docs/superpowers/plans/2026-09-16-shadow-visibility-and-clamp.md
git add PATH_TRACER_QUALITY_ROADMAP.md docs/superpowers/plans/2026-09-16-shadow-visibility-and-clamp.md
git commit -m "docs(pt): Gap #30 -- shadow visibility honoured, indirect clamp 10 (roadmap 11.26)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** NO_SHADOW mask + abstraction plumbing + four sites (T2, T3); SHADOWS_ONLY out of scope (T3 helper comment); clamp 10 with the measured comment (T4); `ZR_LIGHTS_SKIP` as a kept debug var (T4); gate V1–V4 with V2 red today (T1); asset decomposition re-run and the three rig renders delivered (T4 S3, T5 S1); roadmap (T5).
- **Placeholders:** none; the "exact value is the finding" in T4 S3 is a measurement to record, not a blank to fill before running.
- **Type consistency:** `set_cast_shadows_setting(RSE::ShadowCastingSetting)` (T2) read as `data->cast_shadows_setting` (T3); `rt_instance_mask(inst, ...)` signature matches the four call sites; `zr_lights_skip_flags()` bits 1/2/4 used consistently in T4.
