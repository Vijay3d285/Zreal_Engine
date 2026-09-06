# Transparent Shadows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let shadow rays pass through transmissive surfaces attenuated by Fresnel, so geometry enclosed in glass receives direct light.

**Architecture:** Split the shadow query across two disjoint TLAS instance cull masks. Pass A keeps today's `TerminateOnFirstHit` query against opaque geometry only — byte-for-byte the current hot path. Pass B runs only if A clears, iterating an inline `rayQuery` over transmissive geometry and accumulating `transmission * (1 - F)` per crossing. A scene-content flag bit compiles pass B away entirely when no glass exists.

**Tech Stack:** C++ (Godot RD renderer), GLSL (Vulkan ray tracing + `GL_EXT_ray_query`), SCons, GDScript gate scenes.

**Spec:** `docs/superpowers/specs/2026-09-05-transparent-shadows-design.md`

## Global Constraints

- **`git add` uses explicit paths only.** Never `-A`, never `.`.
- **Every `.gd` file directly under `pipeline_references/` is the user's own work.** Never stage, commit, revert, checkout over, or stash any of them — no exceptions, and do not enumerate a subset and assume the rest are fair game. Three of them (`image_glb_creation.gd`, `render.gd`, `video_glb_creation.gd`) currently carry uncommitted user changes that must survive this work untouched; `git status` must still show them modified-but-unstaged when each task ends. **NEW** files under `pipeline_references/tests/` may be created and staged — that subdirectory is the only writable area, and it is how `pt_coat_gate.gd` and `pt_sheen_gate.gd` were added in earlier phases.
- **Build:** `python -m SCons platform=windows target=editor tests=yes -j8`. Bare `scons` is not on PATH and its failure exits 0 under Bash.
- **Any `.glsl` edit requires a build** so `*.glsl.gen.h` regenerates. A `.glsl`-only incremental build is ~1 minute; a full rebuild ~20 minutes.
- **`glsl_builders.py` performs no GLSL validation.** It only embeds text. A clean `scons` exit is near-zero evidence about shader correctness — only a render proves a shader compiles and runs.
- **Renders on this build ARE bit-reproducible — measured 2026-09-05, correcting an earlier claim in this document.** Two runs of `urbantestdark180_fishtank` through the live project on this binary came back byte-identical: rmse `0.000000`, `0.00%` of pixels differing, max channel delta `0`. An earlier revision of this line asserted a noise floor of rmse ~0.1406 across ~5.58% of pixels and forbade equality-based acceptance criteria on that basis; that figure is stale (it predates this branch and the E3-era nondeterminism investigation left DLSS-RR and an async pipeline race as unresolved suspects). Exact comparison IS therefore a valid acceptance criterion here. Two cautions before relying on it: compare renders from the SAME project directory — a cross-project comparison in this very plan produced a 20.39% pixel delta that was entirely the project difference, not the engine — and re-establish the floor with a two-run control if the configuration changes.
- **C++/GLSL struct and constant parity is enforced by hand.** Any constant mirrored between `scene_shader_raytracing.h` and `raytracing_common_inc.glsl` must be changed in both, in the same commit.
- **`gl_ObjectToWorldEXT` does not exist inside a ray query.** Use `rayQueryGetIntersectionObjectToWorldEXT(rq, true)`.
- **Non-goal: caustics.** Light crosses panes without bending. Do not add refraction to the shadow path.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` | Flag bit `RT_FLAG_TRANSMISSIVE_GEOMETRY`, instance mask constants, `static_assert` guards | 1 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` | Feature-bit detection in `process_material`; per-instance cull mask at four TLAS push sites | 2 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl` | GLSL mirrors of the mask constants and the `RT_GET_TRANSMISSIVE_GEOMETRY()` accessor | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` | `lights_trace_shadow_ray` signature, pass A mask, pass B loop, `rt_max_component` | 3, 5 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl` | Emissive-light call site | 3 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Environment-NEE call site | 3 |
| `pipeline_references/tests/pt_transparent_shadow_gate.gd` (new) | GPU gate: interior illuminance ratio through glass | 4 |
| `pipeline_references/tests/pt_transparent_shadow_gate_scene.tscn` (new) | Gate scene entry point | 4 |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Correct the mis-scoped `:1412` note; add closeout | 6 |

---

### Task 1: Flag bit and instance mask constants

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:98` (after `RT_FLAG_SHEEN_ENABLED`), `:130` and `:142` (the two `static_assert`s)

**Interfaces:**
- Consumes: nothing.
- Produces: `SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY` (`uint32_t`, value `1 << 18`), `SceneShaderRaytracing::RT_INSTANCE_MASK_OPAQUE` (`0x01`), `SceneShaderRaytracing::RT_INSTANCE_MASK_TRANSMISSIVE` (`0x02`), `SceneShaderRaytracing::RT_INSTANCE_MASK_ALL` (`0xFF`).

- [ ] **Step 1: Add the flag bit**

In the `RT_FLAG_*` enum, immediately after `RT_FLAG_SHEEN_ENABLED = (1 << 17),`:

```cpp
		// Transparent shadows. Bit 18, next free after E3 took 15-17. NOT 11-14 --
		// those are RT_MAX_TRANSMISSION_BOUNCE and a collision would corrupt that
		// field's readback while leaving the render merely plausible.
		//
		// Unlike RT_FLAG_TRANSMISSION_ENABLED (an Environment toggle), this bit is
		// set from SCENE CONTENT: any material with transmission > 0. It exists so
		// a scene with no glass folds the pass-B loop away at specialization.
		RT_FLAG_TRANSMISSIVE_GEOMETRY = (1 << 18),
```

- [ ] **Step 2: Add the instance mask constants**

Immediately after the `RT_MAX_TRANSMISSION_BOUNCE_MASK` definition:

```cpp
	// TLAS instance cull masks. Every instance was pushed as 0xFF before
	// transparent shadows, so all eight bits were free; two are claimed here so the
	// shadow query can address opaque and transmissive geometry separately.
	// MIRRORED IN raytracing_common_inc.glsl -- change both together.
	constexpr static uint32_t RT_INSTANCE_MASK_OPAQUE = 0x01;
	constexpr static uint32_t RT_INSTANCE_MASK_TRANSMISSIVE = 0x02;
	// Primary, indirect and DLSS-RR probe rays keep seeing everything.
	constexpr static uint32_t RT_INSTANCE_MASK_ALL = 0xFF;
	static_assert((RT_INSTANCE_MASK_OPAQUE & RT_INSTANCE_MASK_TRANSMISSIVE) == 0,
			"Opaque and transmissive instance masks must be disjoint, or pass A would "
			"see glass and occlude behind it while pass B attenuates it a second time");
```

- [ ] **Step 3: Extend both `static_assert`s**

At `:130`, add `| RT_FLAG_TRANSMISSIVE_GEOMETRY` to the OR-chain inside the first operand. At `:142`, add `RT_FLAG_TRANSMISSIVE_GEOMETRY |` to the OR-chain of neighbouring fields.

- [ ] **Step 4: Prove the guards actually fire**

Temporarily change the new bit to `(1 << 5)` — inside the Russian Roulette `min_bounce` field — and build.

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: **compile error**, "RT_FLAG_* bit overlaps the Russian Roulette min_bounce field (bits 4-8)".

A guard that cannot newly fail is not a guard. Restore `(1 << 18)` afterwards.

- [ ] **Step 5: Build clean**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: exit 0, no errors.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h
git commit -m "feat(pt): transparent shadows - flag bit 18 and TLAS instance masks"
```

---

### Task 2: Detect transmissive materials and mask their instances

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` — `process_material` (after the E3 sheen check at `:1898`); the four `instance_masks.push_back(0xFF)` sites at `:2739`, `:2996`, `:3040`, `:3112`; the comment at `:2604`

**Interfaces:**
- Consumes: `SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY`, `RT_INSTANCE_MASK_OPAQUE`, `RT_INSTANCE_MASK_TRANSMISSIVE` from Task 1.
- Produces: `static uint32_t rt_instance_mask_from_features(uint32_t p_feature_bits)` (file-scope in `render_raytracing.cpp`); `mat_data->feature_bits` now carries bit 18; TLAS instances carry a real cull mask.

- [ ] **Step 1: Set the feature bit in `process_material`**

`mat.transmission` is assigned at `:1766`, before the E3 detection block, so it is valid here. Immediately after the sheen check:

```cpp
	if (mat.transmission > 0.0f) {
		// The SAME predicate the shadow loop's per-hit attenuation uses
		// (raytracing_lights_inc.glsl pass B, `atten *= mat.transmission * (1 - F)`).
		// Deriving the instance mask and the scene-level skip from this one bit is
		// what stops them desyncing: a scene can never enable pass B while its glass
		// sits outside the transmissive mask, or vice versa.
		mat_data->feature_bits |= SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY;
	}
```

- [ ] **Step 2: Add the mask helper**

At file scope in `render_raytracing.cpp`, above `build_tlas`:

```cpp
// Chooses a TLAS instance cull mask from a material's detected feature bits.
// Takes the bits rather than the RTMaterialData so all four TLAS push sites --
// which hold `mat_data`, `proc_mat_data` and `pending.mat_data` respectively --
// can share one function.
static _FORCE_INLINE_ uint32_t rt_instance_mask_from_features(uint32_t p_feature_bits) {
	return (p_feature_bits & SceneShaderRaytracing::RT_FLAG_TRANSMISSIVE_GEOMETRY)
			? SceneShaderRaytracing::RT_INSTANCE_MASK_TRANSMISSIVE
			: SceneShaderRaytracing::RT_INSTANCE_MASK_OPAQUE;
}
```

- [ ] **Step 3: Replace all four push sites**

Each is currently `instance_masks.push_back(0xFF);`. Replace with, respectively:

- `:2739` (procedural): `instance_masks.push_back(rt_instance_mask_from_features(proc_mat_data->feature_bits));`
- `:2996` (triangle surfaces): `instance_masks.push_back(rt_instance_mask_from_features(mat_data->feature_bits));`
- `:3040` (deferred multimesh surface): `instance_masks.push_back(rt_instance_mask_from_features(pending.mat_data->feature_bits));`
- `:3112` (multimesh instances): `instance_masks.push_back(rt_instance_mask_from_features(pending.mat_data->feature_bits));`

- [ ] **Step 4: Correct the stale range comment**

At `:2604`, the comment reads that `feature_bits` "only ever carries bits 15-17". Change to 15-18.

- [ ] **Step 5: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: exit 0.

- [ ] **Step 6: Verify detection fires, and can report absence**

Run a render of a scene containing glass and read the per-frame `scene_mask` log line that `build_tlas` already prints (the E3 detection log).

Run:
```bash
./bin/godot.windows.editor.x86_64.console.exe --path "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project" res://main.tscn -- "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/urbantestdark180_fishtank_render_input.json" /tmp/t2.png 2>&1 | grep -i "scene_mask\|aniso="
```
Expected: the log line reports the transmissive bit SET for this scene (it contains converted aquarium glass). Then run the same command against a scene with no glass and confirm the bit is CLEAR. Both directions are required — a detector that cannot report absence is not a detector.

At this point nothing has changed visually: the shadow ray still traces with `0xFF`, which matches both masks.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp
git commit -m "feat(pt): detect transmissive materials and mask their TLAS instances"
```

---

### Task 3: Widen the shadow query to vec3 (behaviour-preserving)

This task changes no rendering behaviour. It converts the boolean shadow result into a `vec3` attenuation that is still only ever `vec3(0.0)` or `vec3(1.0)`, and narrows pass A's cull mask. Splitting it from Task 5 means a reviewer can confirm the refactor is inert before any physics changes.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl` (mask mirrors + accessor)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:266` (signature), `:357`, `:566`, `:618` (call sites)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl:460`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:1643`

**Interfaces:**
- Consumes: `RT_INSTANCE_MASK_OPAQUE` from Task 1 (via the GLSL mirror added here).
- Produces: `vec3 lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist)` — `vec3(0.0)` occluded, `vec3(1.0)` clear; `float rt_max_component(vec3 v)`; `RT_GET_TRANSMISSIVE_GEOMETRY()`.

- [ ] **Step 1: Mirror the constants and add the accessor**

In `raytracing_common_inc.glsl`, beside the existing `RT_GET_*` macros:

```glsl
// MIRRORS scene_shader_raytracing.h RT_INSTANCE_MASK_* -- change both together.
#define RT_INSTANCE_MASK_OPAQUE 0x01u
#define RT_INSTANCE_MASK_TRANSMISSIVE 0x02u

// Scene CONTENT, not an Environment toggle: true when any material in the scene
// has transmission > 0. Folds the pass-B loop away entirely when false.
#define RT_GET_TRANSMISSIVE_GEOMETRY() ((RT_FLAGS & RT_FLAG_TRANSMISSIVE_GEOMETRY) != 0u)
```

Also add `RT_FLAG_TRANSMISSIVE_GEOMETRY` to this file's mirror of the flag values, matching how `RT_FLAG_SHEEN_ENABLED` is mirrored there.

- [ ] **Step 2: Add the max-component helper**

No such helper exists in the raytracing shaders. In `raytracing_lights_inc.glsl`, above `lights_trace_shadow_ray`:

```glsl
float rt_max_component(vec3 v) {
	return max(v.x, max(v.y, v.z));
}
```

- [ ] **Step 3: Change the signature only — do NOT narrow the mask yet**

**AMENDED 2026-09-05 after measurement.** An earlier revision of this step also
narrowed both cull masks to `RT_INSTANCE_MASK_OPAQUE` here. That is wrong, and it
was measured wrong rather than reasoned wrong: Task 2 tags transmissive instances
`0x02`, so narrowing the shadow query to `0x01` culls glass out of the shadow test
entirely (`0x02 & 0x01 == 0`). Between this task and Task 5, glass would then cast
no shadow at all — passing light with NO attenuation instead of the intended
Fresnel-weighted ~0.92 — and Task 4's gate could not fail at `0.0000` as designed,
because its precondition (glass blocks shadow rays) would no longer hold. Three
per-task reviews passed this; the defect lives in the seam between tasks, which
per-task review cannot see. **The narrowing now belongs to Task 5, landing in the
same commit as the pass B that compensates for it.**

Replace only the signature and the two return statements. Both `0xFF` literals
become the named constant `RT_INSTANCE_MASK_ALL` (same value, `0xFF`) so the
intent is explicit and Task 5's change is a one-token edit:

```glsl
/// Returns per-channel light transmittance along the shadow ray.
///   vec3(0.0) = fully occluded, vec3(1.0) = clear.
/// PASS A only for now -- opaque occlusion, unchanged logic, and STILL TRACED
/// AGAINST EVERY INSTANCE. The narrowing to RT_INSTANCE_MASK_OPAQUE lands in
/// Task 5 together with pass B: narrowing it here would cull glass out of the
/// shadow test with nothing yet in place to attenuate it, so glass would cast
/// no shadow at all in the interval.
vec3 lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist) {
```

`USE_SER` branch: `return hitObjectIsHitEXT(hitObject) ? vec3(0.0) : vec3(1.0);`
Non-SER branch: `return visible ? vec3(1.0) : vec3(0.0);`

- [ ] **Step 4: Update the three analytic-light call sites**

All three share the shape `if (light.shadow_enabled > 0.5 && !lights_trace_shadow_ray(...)) { return vec3(0.0); }`. Replace each with a captured attenuation, and multiply it into that function's final return.

`raytracing_lights_inc.glsl:357` (rect light), and its return at the end of `lights_eval_rect_light`:

```glsl
	vec3 shadow_atten = vec3(1.0);
	if (light.shadow_enabled > 0.5) {
		shadow_atten = lights_trace_shadow_ray(hit_pos, L, dist);
		if (rt_max_component(shadow_atten) <= 0.0) {
			return vec3(0.0);
		}
	}
```
```glsl
	return contribution * shadow_atten / max(light_select_pdf * solid_ang_pdf, 1e-10);
```

`:566` (omni/spot), and its return:

```glsl
		vec3 shadow_atten = vec3(1.0);
		if (light.shadow_enabled > 0.5) {
			shadow_atten = lights_trace_shadow_ray(hit_pos, L, shadow_dist);
			if (rt_max_component(shadow_atten) <= 0.0) {
				return vec3(0.0);
			}
		}
```
```glsl
		return contribution * shadow_atten / max(light_select_pdf, 1e-10);
```

`:618` (directional), and its return:

```glsl
		vec3 shadow_atten = vec3(1.0);
		if (light.shadow_enabled > 0.5) {
			shadow_atten = lights_trace_shadow_ray(hit_pos, L, ls.max_distance);
			if (rt_max_component(shadow_atten) <= 0.0) {
				return vec3(0.0);
			}
		}
```
```glsl
		return brdf_value * light.emission * indirect_mul * shadow_atten / max(light_select_pdf, 1e-10);
```

- [ ] **Step 5: Update the emissive call site**

`raytracing_emissive_inc.glsl:460`:

```glsl
	vec3 shadow_atten = lights_trace_shadow_ray(p_hit_pos, L, dist);
	if (rt_max_component(shadow_atten) <= 0.0) {
		return false;
	}
```

and its output write at the end of the function:

```glsl
	r_contribution = bsdf_val * radiance * shadow_atten * (w / pdf_omega);
```

- [ ] **Step 6: Update the environment-NEE call site**

`raytracing_closest_hit_common_inc.glsl:1643`:

```glsl
			vec3 env_shadow_atten = lights_trace_shadow_ray(env_origin, env_dir, 10000.0);
			if (rt_max_component(env_shadow_atten) > 0.0) {
```

and multiply the sky radiance where it is fetched, so every downstream use of it carries the attenuation:

```glsl
				vec3 sky_rad = env_sky_radiance(env_dir) * env_shadow_atten;
```

- [ ] **Step 7: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: exit 0. **This proves nothing about the shader** — `glsl_builders.py` runs no validation. Step 8 is the real check.

- [ ] **Step 8: Render and confirm the refactor is inert**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project" res://main.tscn -- "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/urbantestdark180_fishtank_render_input.json" /tmp/task3.png
```

Expected: the render completes, no shader compile errors in stdout, and the image is visually indistinguishable from the pre-task baseline. Compare region means against `urbantestdark180_fishtank_render.png`. Renders are not bit-reproducible, so compare against the established noise floor (rmse ~0.1406, ~5.58% of pixels) — a change materially larger than that means the refactor was not inert.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_emissive_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl
git commit -m "refactor(pt): shadow ray returns vec3 transmittance, pass A masked to opaque"
```

---

### Task 4: The failing gate

Written before pass B exists, so it demonstrably fails first.

**Files:**
- Create: `pipeline_references/tests/pt_transparent_shadow_gate.gd`
- Create: `pipeline_references/tests/pt_transparent_shadow_gate_scene.tscn`

**Interfaces:**
- Consumes: the engine as built after Task 3.
- Produces: a gate reporting `PASS`/`FAIL` and printing the measured interior/control illuminance ratio.

- [ ] **Step 1: Create the scene file**

`pipeline_references/tests/pt_transparent_shadow_gate_scene.tscn`, matching the shape of the existing `pt_transmission_gate_scene.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/pt_transparent_shadow_gate.gd" id="1_gate"]

[node name="PTTransparentShadowGate" type="Node3D"]
script = ExtResource("1_gate")
```

- [ ] **Step 2: Write the gate**

`pipeline_references/tests/pt_transparent_shadow_gate.gd` extends the shared harness, exactly as `pt_transmission_gate.gd:1` does:

```gdscript
extends "res://tests/pt_validation.gd"

## Transparent shadows GPU gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transparent_shadow_gate_scene.tscn
##
## WHAT THIS PROVES. Before transparent shadows, lights_trace_shadow_ray used
## gl_RayFlagsTerminateOnFirstHitEXT and returned a boolean, and the any-hit stage
## consulted only alpha cutout -- so a transmissive surface was a full occluder and
## anything enclosed in glass received ZERO direct light from every source
## (analytic, emissive-mesh, and environment NEE all route through that one
## function). This gate measures that directly as a ratio.
##
## The doctest suite cannot catch this: it mirrors GLSL formulas in C++ and never
## executes a shader, and the headless renderer discards material parameters
## entirely. Only a real GPU render through the real shadow path measures it.

const FRAMES := 128

# One pane crossed twice (front and back face) at near-normal incidence, ior 1.5:
# F0 = ((1.5-1)/(1.5+1))^2 = 0.04, so each crossing passes ~0.96 and the pair
# ~0.92. The floor is what carries the gate -- the pre-fix value is 0.0 and
# cannot satisfy it under any tolerance.
const P1_RATIO_MIN := 0.85
const P1_RATIO_MAX := 1.00

# The pane tilted so the shadow ray crosses it at ~80 degrees from its normal.
# Dielectric Fresnel at ior 1.5 reflects ~0.40 there, so the ratio must fall well
# below the near-normal case. A flat (non-Fresnel) attenuation leaves it unchanged
# at ~0.92, so this bound is what distinguishes the two.
const P2_GRAZING_MAX := 0.80

var _failures: Array[String] = []
var _checks: int = 0

func _ready() -> void:
	print("\n=== PROBE 1: interior lit through a pane ===")
	await _probe1_interior_lit()

	print("\n=== PROBE 2: grazing crossing darkens ===")
	await _probe2_grazing_darkens()

	print("")
	if _failures.is_empty():
		print("PASS: all %d transparent-shadow checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Renders a lit grey floor twice -- once with a glass pane interposed between it
## and the light, once with that pane hidden -- and returns the ratio.
##
## Toggling `visible` rather than building two scenes is deliberate, and is the
## same technique probe 3 of pt_transmission_gate.gd uses: every other term (light
## intensity, BRDF, exposure, tonemap, camera) is bit-identical between the two
## arms, so it cancels in the ratio and what remains is the shadow transmittance
## alone.
func _probe1_interior_lit() -> void:
	var ratio := await _measure_ratio(0.0)
	print("  ratio through pane = %.6f (band %.2f - %.2f)"
			% [ratio, P1_RATIO_MIN, P1_RATIO_MAX])
	_checks += 1
	if ratio < P1_RATIO_MIN or ratio > P1_RATIO_MAX:
		_failures.append("probe1 interior lit: ratio %.6f outside [%.2f, %.2f]"
				% [ratio, P1_RATIO_MIN, P1_RATIO_MAX])


func _probe2_grazing_darkens() -> void:
	var ratio := await _measure_ratio(80.0)
	print("  ratio at 80deg incidence = %.6f (must be < %.2f)"
			% [ratio, P2_GRAZING_MAX])
	_checks += 1
	if ratio >= P2_GRAZING_MAX:
		_failures.append(("probe2 grazing: ratio %.6f is not below %.2f -- Fresnel is "
				+ "not reaching the accumulation, or a flat factor is being applied")
				% [ratio, P2_GRAZING_MAX])


## p_tilt_deg rotates the pane about X so the shadow ray crosses it off-normal.
func _measure_ratio(p_tilt_deg: float) -> float:
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

	# Matches _apply_glb_transmissive_glass in image_glb_creation.gd.
	var pane := MeshInstance3D.new()
	var pane_mesh := BoxMesh.new()
	pane_mesh.size = Vector3(8, 0.05, 8)
	pane.mesh = pane_mesh
	pane.position = Vector3(0, 1, 0)
	pane.rotation_degrees = Vector3(p_tilt_deg, 0, 0)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	glass_mat.transmission = 1.0
	glass_mat.thickness = 0.0
	glass_mat.roughness = 0.0
	glass_mat.metallic = 0.0
	glass_mat.metallic_specular = 0.5
	glass_mat.ior = 1.5
	pane.material_override = glass_mat
	add_child(pane)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-90, 0, 0) # straight down
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.5, 4)
	cam.look_at(Vector3(0, -1, 0))
	cam.fov = 30.0
	add_child(cam)
	cam.make_current()

	# Black background and one bounce: the floor must be lit by the directional
	# light through the pane and by nothing else, or the ratio measures ambient
	# rather than shadow transmittance.
	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(1)
	await _settle_sky()

	pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	pane.visible = true
	await _settle()
	var glass_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(glass_img, 0.35, 0.65)

	print("  control mean %.6f, through-glass mean %.6f"
			% [control["mean"], through["mean"]])
	# A black control would make any ratio meaningless and a 0/0 read as a pass.
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- the floor is not lit at "
				% control["mean"] + "all, so the ratio proves nothing")
		return 0.0
	return float(through["mean"]) / float(control["mean"])
```

Every helper used above exists: `_new_env`, `_settle`, `_settle_sky`, `_measure_crop` in `pt_transmission_gate.gd` (`:570`, `:624`, `:633`, `:603`), and `_render_accum` in `pt_validation.gd:88`. Copy `_new_env`, `_settle`, `_settle_sky` and `_measure_crop` into the new gate from `pt_transmission_gate.gd` verbatim — they are not on the shared base class.

- [ ] **Step 3: Run the gate and confirm it FAILS**

Run:
```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transparent_shadow_gate_scene.tscn
```
Expected: **FAIL** on probe 1, with its printed ratio at or extremely near `0.0000` — the pane blocks every shadow ray, so the floor receives no direct light. Probe 2 will trivially "pass" at this stage (0.0 is below its ceiling); that is expected and is why probe 1 is the one that carries the gate before the fix.

Also confirm the printed `control mean` is comfortably above zero. If the control is black the ratio is 0/0 and the gate proves nothing; if the through-glass mean is NOT near zero, either the floor is being lit by something other than the directional light (check for residual ambient or sky) or the pane is not transmissive, and in both cases the gate is not measuring what it claims.

- [ ] **Step 4: Commit the failing gate**

```bash
git add pipeline_references/tests/pt_transparent_shadow_gate.gd pipeline_references/tests/pt_transparent_shadow_gate_scene.tscn
git commit -m "test(pt): transparent shadow gate - fails at ratio 0.00 before pass B"
```

---

### Task 5: Pass B — Fresnel-weighted accumulation

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` — `lights_trace_shadow_ray`

**Interfaces:**
- Consumes: `RT_INSTANCE_MASK_TRANSMISSIVE`, `RT_GET_TRANSMISSIVE_GEOMETRY()`, `rt_max_component` (Task 3); `fresnel_dielectric` (`brdf_inc.glsl:482`); `fetch_tbn` (`raytracing_hit_inc.glsl:172`); `get_triangle_indices_ex`; `geometries[]`, `materials[]`.
- Produces: `lights_trace_shadow_ray` returning fractional transmittance. No signature change.

- [ ] **Step 1: Add the constant**

Above `lights_trace_shadow_ray`:

```glsl
// Below this the ray is treated as blocked. Deliberately small: the returned
// value multiplies a light contribution that may be thousands of nits for a sun,
// so an aggressive epsilon clips real light rather than pruning a dead ray.
#define RT_SHADOW_ATTEN_EPSILON 1e-4
```

- [ ] **Step 2: Narrow pass A's cull mask (moved here from Task 3)**

In BOTH branches of `lights_trace_shadow_ray` — the `USE_SER` `hitObjectTraceRayEXT`
and the `#else` `traceRayEXT` — change the cull mask argument from
`RT_INSTANCE_MASK_ALL` to `RT_INSTANCE_MASK_OPAQUE`, and update the docstring to
drop the "STILL TRACED AGAINST EVERY INSTANCE" note.

This step and Step 3 must land in the SAME commit. Narrowing without pass B makes
glass cast no shadow at all; pass B without narrowing double-counts every pane —
pass A occludes on it, and pass B attenuates through it. Neither half is correct
alone, which is why Task 3 no longer owns this edit.

- [ ] **Step 3: Append pass B**

After pass A's `return visible ? vec3(1.0) : vec3(0.0);` becomes a fallthrough, add:

```glsl
	// PASS B -- transmissive accumulation. Runs only when pass A found no opaque
	// occluder AND the scene actually contains transmissive geometry (a
	// specialization constant, so this whole block folds away otherwise).
	//
	// This is an inline ray query rather than any-hit accumulation on purpose.
	// Any-hit would require clearing FORCE_OPAQUE on transmissive instances
	// (render_raytracing.cpp:2991), and that bit is shared with the primary and
	// indirect rays -- every ray in the scene would start invoking any-hit on all
	// glass to pay for a shadow-path fix.
	if (!RT_GET_TRANSMISSIVE_GEOMETRY()) {
		return vec3(1.0);
	}

	vec3 atten = vec3(1.0);
	float t_min = 0.001;
	uint max_crossings = max(1u, RT_GET_MAX_TRANSMISSION_BOUNCE());

	for (uint i = 0u; i < max_crossings; i++) {
		rayQueryEXT rq;
		rayQueryInitializeEXT(rq, tlas,
				gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsOpaqueEXT,
				RT_INSTANCE_MASK_TRANSMISSIVE,
				origin, t_min, direction, max_dist - 0.001);
		while (rayQueryProceedEXT(rq)) {
		}
		if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
			break;
		}

		uint geometry_idx = rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true);
		uint prim_id = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
		vec2 cb = rayQueryGetIntersectionBarycentricsEXT(rq, true);
		float hit_t = rayQueryGetIntersectionTEXT(rq, true);
		bool front = rayQueryGetIntersectionFrontFaceEXT(rq, true);

		GeometryData geom = geometries[geometry_idx];
		MaterialData mat = materials[geometry_idx];
		uint i0, i1, i2;
		get_triangle_indices_ex(geom, prim_id, i0, i1, i2);
		vec3 bary = vec3(1.0 - cb.x - cb.y, cb.x, cb.y);

		// gl_ObjectToWorldEXT does NOT exist inside a ray query -- every use of it
		// in this codebase is in a hit shader. This is the ray-query form.
		mat3 m3 = mat3(rayQueryGetIntersectionObjectToWorldEXT(rq, true));
		mat3 nrm_mat = mat3(normalize(m3[0]), normalize(m3[1]), normalize(m3[2]));
		vec3 N = normalize(nrm_mat * fetch_tbn(geom, i0, i1, i2, bary).normal);

		// CORRECTED 2026-09-06 BY MEASUREMENT. Do NOT flip eta on the back face.
		// An earlier revision of this plan mandated mirroring the BSDF's flip at
		// raytracing_closest_hit_common_inc.glsl:1504. That is wrong here: the BSDF
		// flips because it REFRACTS the ray and evaluates the exit interface at the
		// INTERNAL angle. Pass B deliberately does not bend the ray (the no-caustics
		// decision), so at the back face it still holds the EXTERNAL angle.
		// eta = 1/ior against an external 80 deg gives eta^2 - sin^2(theta) = -0.525,
		// which fresnel_dielectric reports as total internal reflection: F = 1.0,
		// attenuation zero, glass black at grazing angles. Measured: probe 2 read
		// 0.000000 where theory says 0.3749.
		//
		// Using ior at BOTH crossings is exact, not an approximation: by Fresnel
		// reciprocity R(theta_internal, 1/n) == R(theta_external, n), so the unbent
		// two-crossing product (1-F)^2 IS the thin-slab transmittance -- 0.9216 at
		// normal incidence, 0.3749 at 80 deg for ior 1.5.
		//
		// The flip is harmless at normal incidence (both forms give F = 0.04), which
		// is why probe 1 read a perfect 0.9216 while probe 2 read zero. A
		// normal-incidence probe alone cannot catch this.
		float eta = mat.ior;
		float cos_t;
		float F = fresnel_dielectric(dot(direction, N), eta, cos_t);

		atten *= mat.transmission * (1.0 - F);
		if (rt_max_component(atten) < RT_SHADOW_ATTEN_EPSILON) {
			return vec3(0.0);
		}

		// Scale-relative advance. A fixed epsilon is swallowed by float precision
		// at large t and the loop would re-hit the same pane until the cap.
		t_min = hit_t * (1.0 + 1e-4) + 1e-4;
	}

	// Cap reached with attenuation left: return what accumulated, so deep glass
	// dims rather than going black.
	return atten;
```

Note `gl_RayFlagsOpaqueEXT` is passed so the query commits transmissive hits directly without an any-hit candidate step — these instances carry `FORCE_OPAQUE` and we want each crossing reported, not alpha-tested.

- [ ] **Step 4: Build**

Run: `python -m SCons platform=windows target=editor tests=yes -j8`
Expected: exit 0. Again, this says nothing about shader correctness.

- [ ] **Step 5: Run the gate and confirm it now PASSES**

Run:
```bash
./bin/godot.windows.editor.x86_64.console.exe --path pipeline_references res://tests/pt_transparent_shadow_gate_scene.tscn
```
Expected: **PASS**, both probes. Probe 1's ratio lands in `[0.85, 1.00]` — the same probe that printed `0.0000` in Task 4, so it failed before and passes after. Probe 2's grazing ratio lands below `0.80`.

- [ ] **Step 6: Prove probe 2 can actually fail**

Probe 2 is the only check distinguishing Fresnel weighting from a flat factor, so it needs to be shown capable of failing. Temporarily change `atten *= mat.transmission * (1.0 - F);` to `atten *= mat.transmission;`, rebuild, and re-run.

Expected: probe 1 still passes (its ratio rises toward ~1.00) but **probe 2 FAILS**, because with no angular term the grazing ratio stays near the near-normal value instead of dropping below 0.80. If probe 2 still passes here, it is not testing Fresnel and its threshold needs tightening before proceeding. Restore the line afterwards and re-run to confirm both probes pass again.

- [ ] **Step 7: Run the full test suite**

Run: `./bin/godot.windows.editor.x86_64.console.exe --test`
Expected: no new failures against the pre-task baseline.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl
git commit -m "feat(pt): transparent shadows - Fresnel-weighted pass B accumulation"
```

---

### Task 6: Measure and document

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md:1412` and a new closeout section

**Interfaces:**
- Consumes: everything above.
- Produces: measured before/after numbers and a corrected roadmap note.

- [ ] **Step 1: Re-render the reported scenes**

```bash
./bin/godot.windows.editor.x86_64.console.exe --path "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project" res://main.tscn -- "C:/Zlendo2026/ZlenderRender_stage_copy/godot_project/input_json/urbantestdark191_glass_render_input.json" /tmp/191_after.png
```

Measure the tank interior region mean and compare against the reported baseline of `40, 47, 11` (room wall reference `147, 127, 115`). Repeat for the `190` side-angle scene, baseline `84, 79, 75`.

- [ ] **Step 2: Measure render time**

Time the same render before and after by timestamping the `Driving 128 frames` log line to split startup from loop. E3's 273s regression was caught exactly this way and nothing cheaper would have caught it. Record the loop-time delta.

- [ ] **Step 3: Confirm the glassless case is free**

Render a scene with no transmissive geometry and confirm the loop time is unchanged within the noise floor, proving the scene-level skip works.

- [ ] **Step 4: Rewrite the mis-scoped roadmap note**

Replace `PATH_TRACER_QUALITY_ROADMAP.md:1412`:

```markdown
- Shadow rays passed through glass as of the transparent-shadows work (section 8):
  a transmissive surface now attenuates a shadow ray by `transmission * (1 - F)`
  per crossing instead of blocking it. Caustics remain absent and unscheduled --
  light crosses the pane without bending. The previous revision of this line
  claimed being blocked "matches Cycles"; that is true only of Cycles' Glass BSDF.
  Cycles' transparent-shadow path (`shade_shadow.h:183`) fires for Transparent BSDF
  closures, which is what alpha-authored glass assets actually produce, so the
  reference renders were never taking the path this line described.
```

- [ ] **Step 5: Add the closeout section**

Follow the E1/E3 closeout pattern with: the gate ratio before (0.00) and after, the tank interior means before and after, the loop-time delta, and the glassless no-regression result. Record anything measured that contradicted an expectation.

- [ ] **Step 6: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): transparent shadows closeout and corrected :1412 scoping"
```
