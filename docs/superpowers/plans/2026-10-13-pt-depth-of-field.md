# Depth of Field for Day Stills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Day stills get a subtle thin-lens depth of field, focused automatically on the median depth of the centre of the frame measured during the daylight probe; everything else renders byte-identically.

**Architecture:** The raygen's `camera_ray()` gains a thin lens (round aperture, Cycles' math) driven by two project settings that land in two new `rt_params` slots; radius 0 skips it. A new `RenderingServer.viewport_get_pathtracing_depth_image()` returns the primary-hit depth the probe already rendered; a new preloaded `dof.gd` turns it into a focus distance and an aperture radius; `render.gd` sets the two settings right after the probe, before the accumulator reset.

**Tech Stack:** Godot 4.7 fork (C++17, RenderingDevice/Vulkan RT, GLSL 460 raygen), doctest (`tests/`), GDScript (`pipeline_references`), Python 3 + numpy + Pillow for render checks.

**Spec:** `docs/superpowers/specs/2026-10-13-pt-depth-of-field-design.md`

## Global Constraints

- Day stills only; video, night stills and every other route render byte-identically (spec, Intent 1 and 3).
- Off is exact: `dof_aperture_radius <= 0` -> the lens branch is not taken -> byte-identical frames (spec 1).
- Sample 0 stays a pinhole ray (lens centre), like `camera_filter_jitter()` keeps sample 0 at the pixel centre (spec 1).
- Settings: `rendering/pathtracer/dof_aperture_radius` (float, metres, default `0.0`), `rendering/pathtracer/dof_focus_distance` (float, metres, default `3.0`) (spec 1).
- UBO slots: `RT_PARAM_DOF_APERTURE = 40`, `RT_PARAM_DOF_FOCUS = 41`; `vec4 rt_params[10]` -> `[11]`, C++ `float params[40]` -> `[44]` in lockstep (spec 1).
- Focus rule: central 50% x 50%, grid stride 8 px, misses (`depth <= 0`) dropped, median, clamp **[0.5, 25] m**, off if fewer than **10%** of sampled pixels hit (spec 2).
- Strength: `f = 12 mm / tan(fov / 2)` (24 mm-high full-frame sensor; 45 deg -> 29.0 mm), radius = `f / (2 N)`; `DOF_F_STOP` constant in `dof.gd`, `0.0` = off (spec 2).
- Exposure, daylight fill and highlight relief are decided before depth of field turns on (spec 2).
- `dof.gd` is preloaded, never a `class_name` (production has no `.godot/` class cache; memory `godot-class-name-needs-editor-import`).
- Build with `python -m SCons ...`, never bare `scons` (memory `zreal-build-command`); a clean build proves nothing about GLSL: grep every render log for `Error compiling` (memory `pt-glsl-builders-does-no-validation`).
- Never touch Godot processes running from `C:\Zlendo2026\`; check `tasklist | grep -i godot` before every render; stop a batch with a `STOP` file, never by killing processes.

### Plan amendments to the spec (rulings, recorded here so the executor does not re-derive them)

- **`RT_PRNG_LENS = 1u`, not `2u`.** In this sampler a 2D draw occupies ONE slot (`raytracing_inc.glsl` comment above `RT_PRNG_BOUNCE_NUM`: "A 2D draw occupies exactly ONE slot"), so the next free slot of the init block after `RT_PRNG_FILTER = 0u` is `1u` -- also Cycles' `PRNG_LENS_TIME` position. Cost if wrong: none for correctness (any unused slot is unbiased); `1u` is the better-stratified one.
- **Focus distance is AXIAL** (`-z` of the camera-space point), not the length along the ray. The lens focuses on the plane `z = -focus` (`P = d * (focus / -d.z)`, spec 1), so the measured quantity must be the same plane distance. Off-axis by the central 25% of a 45 deg view the two differ by up to ~5%.
- **The spec is amended in Task 5** with both rulings.

## Review Focus

1. **Wrong depth convention** (reverse-Z, flip, depth correction) in the GDScript unprojection would give a plausible-looking but wrong focus. Expected: the centre pixel of job 209 reads 6.30-6.50 m (the window wall; floor-plan geometry). Pinned in Task 3 Step 8.
2. **Lens direction sign** (`-d.z` vs `d.z`) would put the focal plane behind the camera and blur everything. Expected: with a 1 cm aperture focused at 6.4 m the window stays sharp and the foreground blurs. Pinned in Task 1 Step 11.
3. **The probe early-return path** (`pr["samples"].is_empty()`) or a shot out of a window must leave depth of field off, not at a stale or garbage focus. Pinned in Task 2 (fallback test) and Task 3 Step 4 (autofocus called only after a successful probe; default radius 0 otherwise).
4. **Settings persisting across jobs**: each still is a fresh Godot process and the defaults are radius 0, so a previous job cannot leak; `_dof_autofocus()` always writes both settings (radius 0 when off). Pinned in Task 3 Step 4 code.
5. **Byte-identity drift from unrelated engine changes**: the user's commit `bf2357c28c` (glTF specular tint) is newer than the current binary, so the baseline is rendered with a fresh build of HEAD before any DoF change. Pinned in Task 1 Steps 1-3.

---

## Workspace and harness (set up once, before Task 1)

Workspace (git-ignored): `.superpowers/sdd/2026-10-13-pt-depth-of-field/` (the path `scripts/sdd-workspace PLAN_FILE` prints). Copy job 209's Godot input there:

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-13-pt-depth-of-field
mkdir -p $W
cp /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-08-video-parity/prodab/j209_input.json $W/j209_input.json
```

Create `$W/run_still.sh` -- renders job 209 with PRODUCTION's current scripts (copied; production untouched), optionally overlaying the repo's `render.gd` + `dof.gd`, optionally with an `override.cfg`:

```bash
#!/bin/bash
# usage: run_still.sh <tag> [overlay 0|1] [override.cfg lines, ';'-separated]
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-13-pt-depth-of-field
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
TAG=$1; OVERLAY=${2:-0}; OVR=$3
D=$W/$TAG
if [ -f "$W/STOP" ]; then echo "ABORT: $W/STOP exists" >&2; exit 1; fi
rm -rf "$D"; mkdir -p "$D/proj"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
if [ "$OVERLAY" = 1 ]; then cp $R/pipeline_references/render.gd $R/pipeline_references/dof.gd "$D/proj/"; fi
if [ -n "$OVR" ]; then echo "$OVR" | tr ';' '\n' > "$D/proj/override.cfg"; fi
start=$(date +%s)
( cd "$D" && $BIN --path "$D/proj" res://main.tscn -- "$W/j209_input.json" "$D/render.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

Before Task 3 (overlay renders) confirm the repo `render.gd` still equals production's -- the overlay must add only this plan's change:

```bash
diff <(tr -d '\r' < /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/pipeline_references/render.gd) <(tr -d '\r' < /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/render.gd) && echo SAME
```
Expected (before Task 3 edits it): `SAME`. Production `daylight.gd` (relief knee 2.0, the owner's final value) is used as-is; the repo's `daylight.gd` is synced to it in Task 5.

---

### Task 1: Thin lens in the raygen

**Files:**
- Create: `tests/servers/rendering/test_pt_dof.cpp`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (RT_PARAM defines near line 49; `RT_PRNG_*` block near line 466; after `camera_filter_jitter()` near line 637)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:126`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:385-398, 471, 531`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:230`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:4253-4257` and after the guiding block (~line 4427)
- Modify: `servers/rendering/rendering_server.cpp` (after the `temporal_debug` GLOBAL_DEF, ~line 3896)

**Interfaces:**
- Consumes: nothing.
- Produces: project settings `rendering/pathtracer/dof_aperture_radius` (float m, default 0.0) and `rendering/pathtracer/dof_focus_distance` (float m, default 3.0), read every frame; GLSL `vec2 rt_concentric_disk(vec2 u)`, `vec2 camera_lens_u(uvec2 p_pixel, uint p_sample)`, `camera_ray(uvec2, vec2, uint, out vec3, out vec3)`.

- [ ] **Step 1: Build HEAD before any change (the baseline binary)**

Run:
```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_base.log 2>&1; tail -3 $W/build_base.log
```
Expected: `done building targets.` (or `scons: done building targets.`) and no `error`.

- [ ] **Step 2: Render the baseline twice (repeatability floor)**

Run:
```bash
bash $W/run_still.sh base_a 0; cat $W/base_a/done
bash $W/run_still.sh base_b 0; cat $W/base_b/done
cmp $W/base_a/render.png $W/base_b/render.png && echo REPEATABLE
grep -c 'Error compiling' $W/base_a/run.log
grep -h '\[Relief\]\|\[Daylight\] probe:' $W/base_a/run.log
```
Expected: both `exit=0`, `REPEATABLE`, `0`, a probe line and a `[Relief]` line with knee 2.0. If not `REPEATABLE`: stop and record the per-pixel difference (`np.abs(a-b).max()`, fraction differing); the off-identity check in Step 10 then compares against that floor instead of bytes (memory `pt-render-is-nondeterministic`). Record `secs` from `base_a/done` as the time baseline.

- [ ] **Step 3: Write the failing doctest**

Create `tests/servers/rendering/test_pt_dof.cpp` (licence header copied from `test_pt_temporal.cpp` lines 1-29, then):

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_dof)

#include "core/math/math_funcs.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"

namespace TestPTDof {

// Mirrors of the GLSL in raytracing_inc.glsl (rt_concentric_disk) and
// scene_raytracing_raygen.glsl (camera_ray's thin-lens branch). Keep in lockstep.
static Vector2 concentric_disk(const Vector2 &p_u) {
	const Vector2 o = p_u * 2.0f - Vector2(1.0f, 1.0f);
	if (o.x == 0.0f && o.y == 0.0f) {
		return Vector2();
	}
	float r;
	float theta;
	if (Math::abs(o.x) > Math::abs(o.y)) {
		r = o.x;
		theta = (float)Math::PI * 0.25f * (o.y / o.x);
	} else {
		r = o.y;
		theta = (float)Math::PI * 0.5f - (float)Math::PI * 0.25f * (o.x / o.y);
	}
	return Vector2(r * Math::cos(theta), r * Math::sin(theta));
}

struct LensRay {
	Vector3 origin;
	Vector3 dir;
};

// p_dir_view: normalized pinhole direction in camera space (Godot looks down -Z).
static LensRay thin_lens(const Vector3 &p_dir_view, const Vector2 &p_disk, float p_radius, float p_focus) {
	LensRay ray{ Vector3(), p_dir_view };
	if (p_radius > 0.0f) {
		const Vector3 focal = p_dir_view * (p_focus / -p_dir_view.z);
		ray.origin = Vector3(p_radius * p_disk.x, p_radius * p_disk.y, 0.0f);
		ray.dir = (focal - ray.origin).normalized();
	}
	return ray;
}

TEST_CASE("[PathTracer][DOF] the concentric map stays in the unit disc and preserves area") {
	const int n = 64;
	int inside_half = 0;
	float max_r = 0.0f;
	for (int j = 0; j < n; j++) {
		for (int i = 0; i < n; i++) {
			const Vector2 p = concentric_disk(Vector2((i + 0.5f) / n, (j + 0.5f) / n));
			max_r = MAX(max_r, p.length());
			if (p.length() < 0.5f) {
				inside_half++;
			}
		}
	}
	CHECK(max_r <= 1.0f + 1e-5f);
	// Uniform density: the disc of radius 0.5 holds a quarter of the area.
	CHECK(float(inside_half) / float(n * n) == doctest::Approx(0.25f).epsilon(0.02));
}

TEST_CASE("[PathTracer][DOF] every lens point through one pixel meets at the focal point") {
	const Vector3 d = Vector3(0.2f, -0.1f, -1.0f).normalized();
	const float focus = 4.0f;
	const Vector3 focal = d * (focus / -d.z);
	CHECK(focal.z == doctest::Approx(-focus));
	const Vector2 us[4] = { Vector2(0.1f, 0.9f), Vector2(0.7f, 0.3f), Vector2(0.95f, 0.5f), Vector2(0.5f, 0.02f) };
	for (const Vector2 &u : us) {
		const LensRay ray = thin_lens(d, concentric_disk(u), 0.002f, focus);
		const float t = (focal - ray.origin).length();
		const Vector3 hit = ray.origin + ray.dir * t;
		CHECK(hit.distance_to(focal) < 1e-5f);
		CHECK(ray.origin.z == 0.0f);
	}
}

TEST_CASE("[PathTracer][DOF] radius 0 is exactly the pinhole ray") {
	const Vector3 d = Vector3(-0.3f, 0.05f, -1.0f).normalized();
	const LensRay ray = thin_lens(d, concentric_disk(Vector2(0.8f, 0.2f)), 0.0f, 3.0f);
	CHECK(ray.origin == Vector3());
	CHECK(ray.dir == d);
}

} // namespace TestPTDof
```

- [ ] **Step 4: Build and run the new tests**

Run:
```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_t1a.log 2>&1; tail -2 $W/build_t1a.log
bin/godot.windows.editor.x86_64.console.exe --test --test-case="*DOF*" 2>&1 | tail -3
```
Expected: `[doctest] test cases: 3 | 3 passed`. (These mirrors are the specification of the GLSL; they pass as soon as they compile. The RED that matters is Step 5.)

- [ ] **Step 5: Mutation check -- watch each test fail for the right reason**

Apply each mutation alone, rebuild, run `--test-case="*DOF*"`, revert:
1. In `thin_lens`, `p_focus / -p_dir_view.z` -> `p_focus / p_dir_view.z`. Expected: "meets at the focal point" FAILS.
2. In `concentric_disk`, `theta = ... * (o.y / o.x)` -> `* (o.y / o.x) * 0.5f`. Expected: "preserves area" FAILS (or `max_r` check).
3. In `thin_lens`, `if (p_radius > 0.0f)` -> `if (p_radius >= 0.0f)`. Expected: "radius 0 is exactly the pinhole ray" FAILS.
Record the three FAIL lines in the ledger. After reverting: 3/3 pass.

- [ ] **Step 6: GLSL -- parameter slots, sampler slot, disk and lens sample**

In `raytracing_inc.glsl`, after `#define RT_PARAM_GUIDE_CELL 39 ...`:
```glsl
#define RT_PARAM_DOF_APERTURE 40 // rt_params[10].x - thin-lens aperture radius, metres (0 = pinhole, off)
#define RT_PARAM_DOF_FOCUS 41 // rt_params[10].y - focal plane distance along the view axis, metres
```
After `#define RT_PRNG_FILTER 0u ...`:
```glsl
#define RT_PRNG_LENS 1u // 2D, init block only: point on the thin-lens aperture (Cycles PRNG_LENS_TIME).
```
After the closing brace of `camera_filter_jitter()`:
```glsl
/// Shirley-Chiu concentric map of the unit square onto the unit disc (uniform
/// density, low distortion). Mirrored in tests/servers/rendering/test_pt_dof.cpp.
vec2 rt_concentric_disk(vec2 p_u) {
	vec2 o = 2.0 * p_u - 1.0;
	if (o.x == 0.0 && o.y == 0.0) {
		return vec2(0.0);
	}
	float r;
	float theta;
	if (abs(o.x) > abs(o.y)) {
		r = o.x;
		theta = (PI * 0.25) * (o.y / o.x);
	} else {
		r = o.y;
		theta = (PI * 0.5) - (PI * 0.25) * (o.x / o.y);
	}
	return r * vec2(cos(theta), sin(theta));
}

/// Aperture sample for accumulation/loop sample `p_sample`: init block,
/// dimension RT_PRNG_LENS, the same scheme as camera_filter_jitter().
vec2 camera_lens_u(uvec2 p_pixel, uint p_sample) {
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_sample;
	r.offset = 0u;
	return rng_2d(r, RT_PRNG_LENS);
}
```
In `raytracing_common_inc.glsl:126`: `vec4 rt_params[10]; // F2: ...` -> `vec4 rt_params[11]; // F2: 4 -> 10; DoF: 11 (slots 40-41). indices 16+ are the volume block (raytracing_inc.glsl)`.

- [ ] **Step 7: GLSL -- thin lens in camera_ray, sample index at both call sites**

Replace `camera_ray` in `scene_raytracing_raygen.glsl` (lines 385-398) with:
```glsl
void camera_ray(uvec2 p_pixel, vec2 p_jitter, uint p_sample, out vec3 r_origin, out vec3 r_dir) {
	const vec2 pixel_center = vec2(p_pixel) + p_jitter;
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);
	const vec2 d = in_uv * 2.0 - 1.0;

	mat4 inv_view = transpose(mat4(scene_data_block.data.inv_view_matrix[0],
			scene_data_block.data.inv_view_matrix[1],
			scene_data_block.data.inv_view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	vec3 origin_view = vec3(0.0);
	vec3 dir_view = normalize(target.xyz);
	// Thin lens (Cycles camera_sample_perspective): aim every aperture point at
	// the point where the pinhole ray meets the focal plane z = -focus. Sample 0
	// stays a pinhole ray so the primary-ray depth/G-buffer writes stay aligned.
	// Radius 0 never enters: the ray is the same instructions as before (off is
	// byte-identical). Mirrored in tests/servers/rendering/test_pt_dof.cpp.
	const float aperture = get_rt_param(RT_PARAM_DOF_APERTURE);
	if (aperture > 0.0 && p_sample != 0u) {
		const vec3 focal = dir_view * (get_rt_param(RT_PARAM_DOF_FOCUS) / -dir_view.z);
		origin_view = vec3(aperture * rt_concentric_disk(camera_lens_u(p_pixel, p_sample)), 0.0);
		dir_view = normalize(focal - origin_view);
	}
	r_origin = (inv_view * vec4(origin_view, 1.0)).xyz;
	r_dir = (inv_view * vec4(dir_view, 0.0)).xyz;
}
```
Call site line 471: `camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), origin, direction);` -> `camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), accum_frame, origin, direction);`
Call site line 531: `camera_ray(pixel, camera_filter_jitter(pixel, sample_idx), origin, direction);` -> `camera_ray(pixel, camera_filter_jitter(pixel, sample_idx), sample_idx, origin, direction);`
Confirm no other caller: `grep -n 'camera_ray(' servers/rendering/renderer_rd/shaders/raytracing/*.glsl` -> the definition + these two.

- [ ] **Step 8: C++ -- slots, UBO size, settings, fill**

`scene_shader_raytracing.h`, after `RT_PARAM_GUIDE_CELL = 39`:
```cpp
	static constexpr int RT_PARAM_DOF_APERTURE = 40; // thin-lens aperture radius, metres; 0 = off
	static constexpr int RT_PARAM_DOF_FOCUS = 41; // focal plane distance along the view axis, metres
```
`render_raytracing.cpp:4253-4257`:
```cpp
		struct {
			float params[44]; // F2: 16 -> 40; DoF: 44 (vec4 rt_params[11] in the shader)
			float prev_vp_unjittered[16];
			float curr_vp_unjittered[16];
		} rt_ubo = {};
		static_assert(sizeof(rt_ubo) == 76 * sizeof(float));
```
After the guiding block's closing brace (just before `p_state->accum_enabled = accum_enabled;`):
```cpp
		// Thin-lens depth of field (spec 2026-10-13-pt-depth-of-field-design.md). Set per still by
		// render.gd after the daylight probe; 0 keeps the pinhole camera (byte-identical).
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_DOF_APERTURE] = MAX(0.0f, (float)GLOBAL_GET("rendering/pathtracer/dof_aperture_radius"));
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_DOF_FOCUS] = MAX(0.05f, (float)GLOBAL_GET("rendering/pathtracer/dof_focus_distance"));
```
`rendering_server.cpp`, after the `temporal_debug` GLOBAL_DEF:
```cpp
	// Thin-lens depth of field (spec 2026-10-13-pt-depth-of-field-design.md): aperture radius in
	// metres (0 = pinhole, off) and the focal plane's distance along the view axis. render.gd sets
	// both on day stills from the daylight probe's depth; nothing else does.
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/dof_aperture_radius", PROPERTY_HINT_RANGE, "0,0.05,0.0001,or_greater"), 0.0);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/dof_focus_distance", PROPERTY_HINT_RANGE, "0.05,100,0.01,or_greater"), 3.0);
```

- [ ] **Step 9: Build, tests, full suite**

Run:
```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_t1.log 2>&1; tail -2 $W/build_t1.log
bin/godot.windows.editor.x86_64.console.exe --test --test-case="*DOF*" 2>&1 | tail -2
bin/godot.windows.editor.x86_64.console.exe --test > $W/suite_t1.log 2>&1; tail -3 $W/suite_t1.log
```
Expected: build done; 3/3 DOF; full suite `0 failed`.

- [ ] **Step 10: Off is byte-identical; no GLSL errors**

Run:
```bash
bash $W/run_still.sh t1_off 0; cat $W/t1_off/done
grep -c 'Error compiling' $W/t1_off/run.log
cmp $W/base_a/render.png $W/t1_off/render.png && echo IDENTICAL
```
Expected: `exit=0`, `0`, `IDENTICAL` (or within Step 2's floor if the build is not repeatable).

- [ ] **Step 11: The lens is live and focuses where told (Review Focus 2)**

Run with a deliberately large aperture (1 cm) focused on the window wall (6.4 m):
```bash
bash $W/run_still.sh t1_lens 0 "[rendering];pathtracer/dof_aperture_radius=0.01;pathtracer/dof_focus_distance=6.4"
cat $W/t1_lens/done; grep -c 'Error compiling' $W/t1_lens/run.log
python - <<'EOF'
import numpy as np
from PIL import Image
W = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine\.superpowers\sdd\2026-10-13-pt-depth-of-field"
K = np.array([0.2126, 0.7152, 0.0722], np.float32)
def L(t): return np.asarray(Image.open(fr"{W}\{t}\render.png").convert("RGB")).astype(np.float32) @ K
def hf(l):
    p = np.pad(l, 1, mode="edge")
    b = sum(p[1 + dy:1 + dy + l.shape[0], 1 + dx:1 + dx + l.shape[1]] for dy in (-1, 0, 1) for dx in (-1, 0, 1)) / 9
    return np.abs(l - b)
a, b = hf(L("base_a")), hf(L("t1_lens"))
regions = {"foreground rug/bench (~2 m)": (slice(1700, 2100), slice(1300, 2600)),
           "window wall (~6.4 m, in focus)": (slice(640, 1200), slice(1600, 2480))}
for n, (ys, xs) in regions.items():
    print(f"{n}: detail {a[ys, xs].mean():.3f} -> {b[ys, xs].mean():.3f} ({100 * (b[ys, xs].mean() / a[ys, xs].mean() - 1):+.0f}%)")
EOF
```
Expected: `exit=0`, `0` errors; foreground detail drops by **more than 30%**; window-wall detail within **+/-15%**. If the window blurs as much as the foreground, the focal plane is on the wrong side (`-dir_view.z` sign): stop and debug. Look at the PNG once (`$W/t1_lens/render.png`) and record what is sharp.

- [ ] **Step 12: Commit**

```bash
git add tests/servers/rendering/test_pt_dof.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/rendering_server.cpp
git commit -m "feat(pt): thin-lens depth of field in the raygen (off by default, byte-identical off)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `dof.gd` -- focus rule and aperture, with unit tests

**Files:**
- Create: `pipeline_references/dof.gd`
- Create: `pipeline_references/tests/dof_unit.gd`

**Interfaces:**
- Consumes: nothing (pure functions).
- Produces (all `static func` on the preloaded script `const Dof = preload("res://dof.gd")`):
  - `const DOF_F_STOP := 8.0` (Task 4 sets the owner's value), `const SENSOR_HEIGHT_MM := 24.0`, `const FOCUS_MIN_M := 0.5`, `const FOCUS_MAX_M := 25.0`, `const MIN_HIT_FRACTION := 0.10`, `const CENTRE_FRACTION := 0.5`, `const GRID_STRIDE := 8`
  - `focal_length_mm(p_fov_deg: float) -> float`
  - `aperture_radius_m(p_fov_deg: float, p_f_stop: float) -> float` (0.0 when `p_f_stop <= 0`)
  - `axial_distance(p_inv_proj: Projection, p_ndc: Vector3) -> float` (metres along the view axis)
  - `measure_focus(p_depth: Image, p_inv_proj: Projection, p_stride: int = GRID_STRIDE) -> Dictionary` with keys `ok: bool`, `distance: float` (clamped median, 0.0 when not ok), `hits: int`, `samples: int`, `hit_fraction: float`, `centre_distance: float` (axial distance of the exact centre pixel; 0.0 on a miss)

- [ ] **Step 1: Write the failing unit test**

Create `pipeline_references/tests/dof_unit.gd`:
```gdscript
extends SceneTree

# Preloaded, not a global class name: the live pipeline has no class cache.
const Dof = preload("res://dof.gd")

## Headless unit checks for dof.gd (spec 2026-10-13-pt-depth-of-field-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/dof_unit.gd

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (tol %.2f%%)" % [p_name, p_value, p_expected, 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f" % [p_name, p_value, p_expected])


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s: %s %s" % [p_name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
		_failures.append("%s %s" % [p_name, p_detail])


## The engine's convention: Godot's depth-corrected (flip-y, reverse-Z) projection,
## the same matrix the raygen writes rt_depth with.
func _proj() -> Projection:
	return Projection.create_depth_correction(true) * Projection.create_perspective(45.0, 16.0 / 9.0, 0.05, 500.0)


## NDC depth the engine would store for a point at axial distance p_d straight ahead.
func _ndc_depth(p_proj: Projection, p_d: float) -> float:
	var c := p_proj * Vector4(0.0, 0.0, -p_d, 1.0)
	return c.z / c.w


## p_w x p_h depth image: the central 50% x 50% filled per p_centre(x, y) -> axial metres
## (<= 0 = miss), everything outside the centre at 10 m (must be ignored).
func _depth_image(p_w: int, p_h: int, p_centre: Callable) -> Image:
	var proj := _proj()
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RF)
	for y in range(p_h):
		for x in range(p_w):
			var inside := x >= p_w / 4 and x < p_w * 3 / 4 and y >= p_h / 4 and y < p_h * 3 / 4
			var d: float = p_centre.call(x, y) if inside else 10.0
			img.set_pixel(x, y, Color(_ndc_depth(proj, d) if d > 0.0 else 0.0, 0, 0))
	return img


func _initialize() -> void:
	var inv := _proj().inverse()

	# D1: the depth round-trips to the axial distance.
	for d in [0.5, 3.0, 6.4, 25.0]:
		_check("D1 axial(%.1f m)" % d, Dof.axial_distance(inv, Vector3(0.0, 0.0, _ndc_depth(_proj(), d))), d, 1e-3)

	# D2: uniform 3 m centre -> focus 3 m; the 10 m border is ignored.
	var r2 := Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 3.0), inv, 1)
	_check_true("D2 ok", r2["ok"])
	_check("D2 focus", r2["distance"], 3.0, 0.01)
	_check("D2 centre pixel", r2["centre_distance"], 3.0, 0.01)

	# D3: median, not mean: 70% of the centre at 3 m, 30% at 10 m -> 3 m.
	var r3 := Dof.measure_focus(_depth_image(64, 36, func(x, _y): return 3.0 if (x % 10) < 7 else 10.0), inv, 1)
	_check("D3 median ignores the far 30%", r3["distance"], 3.0, 0.01)

	# D4: misses are dropped, not read as distance 0.
	var r4 := Dof.measure_focus(_depth_image(64, 36, func(x, _y): return 4.0 if x % 2 == 0 else 0.0), inv, 1)
	_check_true("D4 ok with 50% hits", r4["ok"])
	_check("D4 focus from hits only", r4["distance"], 4.0, 0.01)

	# D5: fewer than 10% hits -> off.
	var r5 := Dof.measure_focus(_depth_image(64, 36, func(x, y): return 4.0 if (x + y * 64) % 20 == 0 else 0.0), inv, 1)
	_check_true("D5 off under 10% hits", not r5["ok"], "hit_fraction %.3f" % r5["hit_fraction"])
	_check("D5 distance 0 when off", r5["distance"], 0.0, 1e-9)

	# D6: clamp to [0.5, 25] m.
	_check("D6 clamp near", Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 0.2), inv, 1)["distance"], 0.5, 1e-6)
	_check("D6 clamp far", Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 60.0), inv, 1)["distance"], 25.0, 1e-6)

	# D7: the lens from the field of view (24 mm-high full-frame sensor).
	_check("D7 focal length at 45 deg", Dof.focal_length_mm(45.0), 28.9706, 1e-4)
	_check("D7 radius at f/8", Dof.aperture_radius_m(45.0, 8.0), 0.00181066, 1e-4)
	_check("D7 f-stop 0 is off", Dof.aperture_radius_m(45.0, 0.0), 0.0, 1e-9)

	# D8: an empty image never crashes and is off.
	var r8 := Dof.measure_focus(Image.new(), inv)
	_check_true("D8 empty image -> off", not r8["ok"] and r8["distance"] == 0.0)

	print("")
	if _failures.is_empty():
		print("PASS: all %d dof unit checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		quit(1)
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/dof_unit.gd 2>&1 | tail -5
```
Expected: a parse/load error naming `res://dof.gd` (the file does not exist). If the run prints nothing for a minute it is stalled (see `daylight_unit.gd` header): kill only that test process you started, which runs from the repo, not `C:\Zlendo2026`.

- [ ] **Step 3: Write `pipeline_references/dof.gd`**

```gdscript
extends RefCounted

## Thin-lens depth of field for day stills (spec 2026-10-13-pt-depth-of-field-design.md).
## Pure functions; render.gd calls them right after the daylight probe, which has just
## rendered the exact view with no lens, so the primary-hit depth is already there.
## Preloaded (const Dof = preload("res://dof.gd")), never a class_name: production
## runs with no .godot/ class cache.

## The owner's pick from the f/11 - f/8 - f/5.6 test renders (Task 4). 0.0 = off.
const DOF_F_STOP := 8.0
## Full-frame 36 x 24 mm: Godot's fov is vertical, so the 24 mm height sets the lens.
const SENSOR_HEIGHT_MM := 24.0
const FOCUS_MIN_M := 0.5
const FOCUS_MAX_M := 25.0
## Under this share of central pixels hitting geometry (a shot out of a window), no DoF.
const MIN_HIT_FRACTION := 0.10
## Centre-weighted: the middle 50% x 50% of the frame.
const CENTRE_FRACTION := 0.5
const GRID_STRIDE := 8


static func focal_length_mm(p_fov_deg: float) -> float:
	return 0.5 * SENSOR_HEIGHT_MM / tan(deg_to_rad(p_fov_deg) * 0.5)


## Blender's aperture: radius = focal length / (2 x f-number).
static func aperture_radius_m(p_fov_deg: float, p_f_stop: float) -> float:
	if p_f_stop <= 0.0:
		return 0.0
	return focal_length_mm(p_fov_deg) / (2.0 * p_f_stop) / 1000.0


## Distance along the view axis (-z in camera space) of an NDC point, through the inverse
## of the camera's depth-corrected projection -- the plane the lens focuses on.
static func axial_distance(p_inv_proj: Projection, p_ndc: Vector3) -> float:
	var v := p_inv_proj * Vector4(p_ndc.x, p_ndc.y, p_ndc.z, 1.0)
	return -v.z / v.w


## Median axial distance of the central region's hits, clamped. p_depth: rt_depth
## (FORMAT_RF, reverse-Z NDC depth, 0.0 = miss).
static func measure_focus(p_depth: Image, p_inv_proj: Projection, p_stride: int = GRID_STRIDE) -> Dictionary:
	var off := {"ok": false, "distance": 0.0, "hits": 0, "samples": 0, "hit_fraction": 0.0, "centre_distance": 0.0}
	if p_depth == null or p_depth.is_empty():
		return off
	var w := p_depth.get_width()
	var h := p_depth.get_height()
	var x0 := int(w * (1.0 - CENTRE_FRACTION) * 0.5)
	var y0 := int(h * (1.0 - CENTRE_FRACTION) * 0.5)
	var x1 := int(w * (1.0 + CENTRE_FRACTION) * 0.5)
	var y1 := int(h * (1.0 + CENTRE_FRACTION) * 0.5)
	var dists := PackedFloat32Array()
	var samples := 0
	for y in range(y0, y1, maxi(p_stride, 1)):
		for x in range(x0, x1, maxi(p_stride, 1)):
			samples += 1
			var d := p_depth.get_pixel(x, y).r
			if d > 0.0:
				dists.append(axial_distance(p_inv_proj, _ndc(x, y, w, h, d)))
	var cd := p_depth.get_pixel(w / 2, h / 2).r
	off["centre_distance"] = axial_distance(p_inv_proj, _ndc(w / 2, h / 2, w, h, cd)) if cd > 0.0 else 0.0
	off["samples"] = samples
	off["hits"] = dists.size()
	off["hit_fraction"] = float(dists.size()) / float(maxi(samples, 1))
	if off["hit_fraction"] < MIN_HIT_FRACTION:
		return off
	dists.sort()
	off["ok"] = true
	off["distance"] = clampf(dists[dists.size() / 2], FOCUS_MIN_M, FOCUS_MAX_M)
	return off


## Pixel centre -> NDC, the raygen's convention (camera_ray: d = (pixel + 0.5) / size * 2 - 1).
static func _ndc(p_x: int, p_y: int, p_w: int, p_h: int, p_depth: float) -> Vector3:
	return Vector3((p_x + 0.5) / p_w * 2.0 - 1.0, (p_y + 0.5) / p_h * 2.0 - 1.0, p_depth)
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/dof_unit.gd 2>&1 | tail -3
```
Expected: `PASS: all 18 dof unit checks passed.` (count as printed).

- [ ] **Step 5: Mutation check**

One at a time, rerun, revert: (a) `return -v.z / v.w` -> `return v.z / v.w` -> D1/D2 FAIL; (b) `dists[dists.size() / 2]` -> the mean of `dists` -> D3 FAIL; (c) `if d > 0.0:` -> `if d >= 0.0:` -> D4 FAIL; (d) `MIN_HIT_FRACTION := 0.10` -> `0.0` -> D5 FAIL. Record the FAIL lines.

- [ ] **Step 6: Commit**

```bash
git add pipeline_references/dof.gd pipeline_references/tests/dof_unit.gd
git commit -m "feat(pipeline): dof.gd -- centre-weighted autofocus and aperture from the field of view

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Depth read-back and autofocus wiring

**Files:**
- Modify: `servers/rendering/rendering_server.h:577` (after `viewport_get_pathtracing_accum_image`)
- Modify: `servers/rendering/rendering_server_default.h:767`
- Modify: `servers/rendering/rendering_server.cpp:2884` (bind)
- Modify: `servers/rendering/renderer_viewport.h:253`, `servers/rendering/renderer_viewport.cpp` (after line 1265)
- Modify: `servers/rendering/rendering_method.h:354`, `servers/rendering/renderer_scene_cull.h:1420`, `servers/rendering/renderer_scene_render.h:347`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h:972`, `render_forward_clustered.cpp` (after line 5379)
- Modify: `servers/rendering/dummy/rasterizer_scene_dummy.h:175`
- Modify: `pipeline_references/render.gd` (top: preload; `_daylight_probe_and_expose()` before its final `await Daylight.reset_accumulator(self, p_env)`; new `_dof_autofocus()`)

**Interfaces:**
- Consumes: Task 1's two project settings; Task 2's `Dof.measure_focus`, `Dof.aperture_radius_m`, `Dof.focal_length_mm`, `Dof.DOF_F_STOP`.
- Produces: `RenderingServer.viewport_get_pathtracing_depth_image(viewport: RID) -> Image` (FORMAT_RF, internal size, rt_depth from sample 0; empty Image if no path-tracer depth); log line `[DoF] ...`.

- [ ] **Step 1: Engine chain (one declaration per layer, mirroring the accumulator read)**

`rendering_server.h` after line 577: `virtual Ref<Image> viewport_get_pathtracing_depth_image(RID p_viewport) const = 0;`
`rendering_server_default.h` after line 767: `FUNC1RC(Ref<Image>, viewport_get_pathtracing_depth_image, RID)`
`rendering_server.cpp` after line 2884: `ClassDB::bind_method(D_METHOD("viewport_get_pathtracing_depth_image", "viewport"), &RenderingServer::viewport_get_pathtracing_depth_image);`
`renderer_viewport.h` after line 253: `Ref<Image> viewport_get_pathtracing_depth_image(RID p_viewport) const;`
`renderer_viewport.cpp` after `viewport_get_pathtracing_accum_image`:
```cpp
Ref<Image> RendererViewport::viewport_get_pathtracing_depth_image(RID p_viewport) const {
	const Viewport *viewport = viewport_owner.get_or_null(p_viewport);
	ERR_FAIL_NULL_V(viewport, Ref<Image>());
	ERR_FAIL_COND_V(viewport->render_buffers.is_null(), Ref<Image>());
	return RSG::scene->get_pathtracing_depth_image(viewport->render_buffers);
}
```
`rendering_method.h` after line 354: `virtual Ref<Image> get_pathtracing_depth_image(Ref<RenderSceneBuffers> p_render_buffers) = 0;`
`renderer_scene_cull.h` after line 1420: `PASS1R(Ref<Image>, get_pathtracing_depth_image, Ref<RenderSceneBuffers>)`
`renderer_scene_render.h` after line 347: `virtual Ref<Image> get_pathtracing_depth_image(Ref<RenderSceneBuffers> p_render_buffers) { return Ref<Image>(); }`
`rasterizer_scene_dummy.h` after line 175: `Ref<Image> get_pathtracing_depth_image(Ref<RenderSceneBuffers> p_render_buffers) override { return Ref<Image>(); }`
`render_forward_clustered.h` after line 972: `virtual Ref<Image> get_pathtracing_depth_image(Ref<RenderSceneBuffers> p_render_buffers) override;`
`render_forward_clustered.cpp` after `get_pathtracing_accum_image`:
```cpp
// Primary-hit depth (rt_depth: R32F reverse-Z NDC, written on sample 0; 0 = miss) for the
// still route's autofocus (spec 2026-10-13-pt-depth-of-field-design.md).
Ref<Image> RenderForwardClustered::get_pathtracing_depth_image(Ref<RenderSceneBuffers> p_render_buffers) {
	Ref<RenderSceneBuffersRD> rb = p_render_buffers;
	ERR_FAIL_COND_V(rb.is_null(), Ref<Image>());
	Ref<RenderBufferDataForwardClustered> rb_data = rb->get_custom_data(RB_SCOPE_FORWARD_CLUSTERED);
	ERR_FAIL_COND_V(rb_data.is_null(), Ref<Image>());
	if (!rb_data->rt_has_depth_texture()) {
		return Ref<Image>();
	}
	const RID depth_rid = rb_data->rt_get_depth_texture();
	if (!RD::get_singleton()->texture_is_valid(depth_rid)) {
		return Ref<Image>();
	}
	const Size2i size = rb->get_internal_size();
	ERR_FAIL_COND_V(size.width <= 0 || size.height <= 0, Ref<Image>());
	Vector<uint8_t> bytes = RD::get_singleton()->texture_get_data(depth_rid, 0);
	const int64_t expected = (int64_t)size.width * size.height * 4; // R32F
	ERR_FAIL_COND_V_MSG(bytes.size() != expected, Ref<Image>(),
			vformat("Path-tracer depth readback size mismatch: got %d, expected %d.", (int)bytes.size(), (int)expected));
	return Image::create_from_data(size.width, size.height, false, Image::FORMAT_RF, bytes);
}
```

- [ ] **Step 2: Build; the API is visible to GDScript**

Run:
```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_t3.log 2>&1; tail -2 $W/build_t3.log
cat > $W/api_check.gd <<'EOF'
extends SceneTree
func _initialize() -> void:
	print("has depth api: ", RenderingServer.has_method("viewport_get_pathtracing_depth_image"))
	quit(0)
EOF
cp $W/api_check.gd pipeline_references/tests/_api_check.gd
bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/_api_check.gd 2>&1 | grep 'has depth api'
rm pipeline_references/tests/_api_check.gd
```
Expected: build done; `has depth api: true`.

- [ ] **Step 3: Confirm the repo render.gd still equals production's**

Run the `diff ... && echo SAME` from the Workspace section. Expected: `SAME`. If not, stop: production changed; merge the production file into the repo first (record the ruling).

- [ ] **Step 4: Wire autofocus into render.gd**

Under `extends "res://image_glb_creation.gd"` (line 1) add:
```gdscript
# Thin-lens depth of field (spec 2026-10-13). Preloaded, not a class_name: no class cache in production.
const Dof = preload("res://dof.gd")
```
In `_daylight_probe_and_expose()`, immediately before its final `await Daylight.reset_accumulator(self, p_env)` (after the `[Relief]` print):
```gdscript
	# Depth of field (spec 2026-10-13): focus from the depth this probe just rendered (no
	# lens yet), so exposure, fill and relief above are decided exactly as before.
	_dof_autofocus(vp)
```
New function right after `_daylight_probe_and_expose()`:
```gdscript
## Centre-weighted autofocus from the probe's primary-hit depth (spec 2026-10-13).
## Always writes both settings: a still where it cannot focus keeps the pinhole.
func _dof_autofocus(p_vp: RID) -> void:
	var cam := get_node_or_null("MainCamera") as Camera3D
	var radius := 0.0
	var focus := 3.0
	if cam == null or Dof.DOF_F_STOP <= 0.0:
		print("[DoF] off: %s" % ("no MainCamera" if cam == null else "DOF_F_STOP is 0"))
	else:
		var depth: Image = RenderingServer.viewport_get_pathtracing_depth_image(p_vp)
		var inv := (Projection.create_depth_correction(true) * cam.get_camera_projection()).inverse()
		var m := Dof.measure_focus(depth, inv)
		if m["ok"]:
			radius = Dof.aperture_radius_m(cam.fov, Dof.DOF_F_STOP)
			focus = m["distance"]
			print("[DoF] focus %.2f m (median of %d central pixels, %d%% hit; centre pixel %.2f m), f/%.1f at %.1f mm -> aperture radius %.2f mm" % [
					focus, m["hits"], int(round(100.0 * m["hit_fraction"])), m["centre_distance"],
					Dof.DOF_F_STOP, Dof.focal_length_mm(cam.fov), radius * 1000.0])
		else:
			print("[DoF] off: only %d%% of central pixels hit geometry (need %d%%)" % [
					int(round(100.0 * m["hit_fraction"])), int(round(100.0 * Dof.MIN_HIT_FRACTION))])
	ProjectSettings.set_setting("rendering/pathtracer/dof_aperture_radius", radius)
	ProjectSettings.set_setting("rendering/pathtracer/dof_focus_distance", focus)
```

- [ ] **Step 5: Parse check**

Run:
```bash
mkdir -p $W/parse && cp /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/*.gd /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/project.godot $W/parse/ && cp -r /c/Zlendo2026/ZlenderRender_stage_copy/godot_project/shapes $W/parse/ && cp pipeline_references/render.gd pipeline_references/dof.gd $W/parse/
for f in dof.gd render.gd mo_image.gd; do bin/godot.windows.editor.x86_64.console.exe --headless --path $W/parse --check-only --script res://$f 2>&1 | grep -E 'SCRIPT ERROR|Parse Error' | head -2 || true; done; echo parsed
```
Expected: no `SCRIPT ERROR` / `Parse Error` lines, then `parsed`.

- [ ] **Step 6: Off through the script: DOF_F_STOP 0 is byte-identical**

Temporarily set `const DOF_F_STOP := 0.0` in `pipeline_references/dof.gd`, then:
```bash
bash $W/run_still.sh t3_off 1; cat $W/t3_off/done
grep -h '\[DoF\]' $W/t3_off/run.log; grep -c 'Error compiling\|SCRIPT ERROR' $W/t3_off/run.log
cmp $W/base_a/render.png $W/t3_off/render.png && echo IDENTICAL
```
Expected: `[DoF] off: DOF_F_STOP is 0`, `0`, `IDENTICAL`. Restore `DOF_F_STOP := 8.0`.

- [ ] **Step 7: On at f/8**

```bash
bash $W/run_still.sh t3_f8 1; cat $W/t3_f8/done
grep -h '\[DoF\]\|\[Relief\]\|\[Daylight\] probe:' $W/t3_f8/run.log; grep -c 'Error compiling\|SCRIPT ERROR' $W/t3_f8/run.log
```
Expected: one `[DoF] focus ... m (median of N central pixels, H% hit; centre pixel C m), f/8.0 at 29.0 mm -> aperture radius 1.81 mm`; the `[Daylight] probe:` exposure and `[Relief]` strength **identical** to `base_a`'s lines; `0` errors.

- [ ] **Step 8: The depth convention is right (Review Focus 1)**

From the Step 7 line: the **centre pixel must read 6.30-6.50 m**. Job 209's camera is at x = 3.5317 m looking along -x (target x = -6.459); the window wall's inner face is at x = -2.7889 m and its centre line at x = -2.903 m, so the window glass/frame at the image centre lies 6.33-6.45 m away along the view axis. Outside that range: the unprojection convention is wrong (flip / reverse-Z / remap) -- stop and debug with systematic-debugging; do not tune the range. Also report the median focus distance and whether it is between 2.5 and 6.5 m (inside the room).

- [ ] **Step 9: Time**

Compare `secs` in `t3_f8/done` with `base_a/done`. Expected: within **+2%** (the GDScript scan of ~32k pixels is well under a second). Record both.

- [ ] **Step 10: Full suite and commit**

```bash
bin/godot.windows.editor.x86_64.console.exe --test > $W/suite_t3.log 2>&1; tail -3 $W/suite_t3.log
git add servers/rendering/rendering_server.h servers/rendering/rendering_server_default.h servers/rendering/rendering_server.cpp servers/rendering/renderer_viewport.h servers/rendering/renderer_viewport.cpp servers/rendering/rendering_method.h servers/rendering/renderer_scene_cull.h servers/rendering/renderer_scene_render.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/dummy/rasterizer_scene_dummy.h pipeline_references/render.gd
git commit -m "feat(pt): depth read-back and centre-weighted autofocus for day stills

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Expected suite: `0 failed`. (`pipeline_references/render.gd` also carries the owner's uncommitted thumbnail change, which equals production; committing it with this task is a ruling to record.)

---

### Task 4: The owner picks the strength

**Files:**
- Modify: `pipeline_references/dof.gd` (`DOF_F_STOP`)

**Interfaces:**
- Consumes: Task 3's working pipeline.
- Produces: the final `DOF_F_STOP`.

- [ ] **Step 1: Render f/11 and f/5.6 (f/8 is Task 3's `t3_f8`)**

For each value: set `const DOF_F_STOP := 11.0` (then `5.6`) in `pipeline_references/dof.gd`, run `bash $W/run_still.sh t4_f11 1` (then `t4_f56`), and check the `[DoF]` line and 0 errors.

- [ ] **Step 2: Comparison crops**

```bash
python - <<'EOF'
from PIL import Image, ImageDraw
W = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine\.superpowers\sdd\2026-10-13-pt-depth-of-field"
runs = [("base_a", "today (no DoF)"), ("t4_f11", "f/11"), ("t3_f8", "f/8"), ("t4_f56", "f/5.6")]
ims = [Image.open(fr"{W}\{t}\render.png").convert("RGB") for t, _ in runs]
boxes = {"near_rug_bench": (1100, 1650, 2300, 2160), "focus_sofa_table": (1500, 1150, 2700, 1650), "far_window_wall": (1550, 600, 2550, 1250)}
for name, bx in boxes.items():
    w, h = bx[2] - bx[0], bx[3] - bx[1]
    o = Image.new("RGB", (w * len(ims), h + 40), (20, 20, 20)); d = ImageDraw.Draw(o)
    for i, (im, (_, lab)) in enumerate(zip(ims, runs)):
        o.paste(im.crop(bx), (i * w, 40)); d.text((i * w + 10, 12), lab, fill=(255, 255, 255))
    o.save(fr"{W}\dof_crop_{name}.png")
full = Image.new("RGB", (1280 * 2, 720 * 2))
for i, im in enumerate(ims):
    full.paste(im.resize((1280, 720), Image.LANCZOS), ((i % 2) * 1280, (i // 2) * 720))
full.save(fr"{W}\dof_full_grid.png")
print("saved")
EOF
```
Look at every crop before sending (a crop that misses its subject gets moved by looking at the full frame).

- [ ] **Step 3: Show the owner and ask**

Send the three crops and the grid (SendUserFile), then ask (AskUserQuestion) which strength to ship: f/11, f/8, f/5.6 (or Other). Do not choose for the owner.

- [ ] **Step 4: Set the constant, re-check, commit**

Set `DOF_F_STOP` to the owner's value, then run `bin/godot.windows.editor.x86_64.console.exe --headless --path pipeline_references -s res://tests/dof_unit.gd 2>&1 | tail -1`. Expected: `PASS: all 18 dof unit checks passed.` (D7's f/8 radius check does not read the constant). Commit:
```bash
git add pipeline_references/dof.gd
git commit -m "feat(pipeline): depth of field strength f/<N> (owner's pick from job 209)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Ship and close

**Files:**
- Modify: `docs/superpowers/specs/2026-10-13-pt-depth-of-field-design.md` (amendment: `RT_PRNG_LENS = 1u`, axial focus distance, measured results)
- Modify: `pipeline_references/daylight.gd` (`RELIEF_KNEE := 2.0`, the owner's final production value)
- Production (owner-confirmed): `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\` (binary), `godot_project\render.gd`, `godot_project\dof.gd`

- [ ] **Step 1: Spec amendment and repo sync**

Append to the spec an "Amendment and results 2026-10-13" section: the two rulings (Global Constraints), the measured centre-pixel and focus distances, the time, and the owner's f-number. Set `const RELIEF_KNEE := 2.0` in `pipeline_references/daylight.gd` (production's value, the owner's finalisation); confirm `diff` of `pipeline_references/daylight.gd` against production's is empty.

- [ ] **Step 2: Ask before touching production**

Ask the owner (AskUserQuestion) whether to copy now or hand over the file list. Copying requires `tasklist | grep -i godot` to show no Godot running from `C:\Zlendo2026\`. The copy set: `bin\godot.windows.editor.x86_64.exe` and `bin\godot.windows.editor.x86_64.console.exe` -> `C:\Zlendo2026\ZlenderRender_stage_copy\godot\bin\` (back up the two existing exes there first, as `*.pre_dof.exe`); `pipeline_references\render.gd` and `pipeline_references\dof.gd` -> `C:\Zlendo2026\ZlenderRender_stage_copy\godot_project\` (re-run the Workspace `diff ... SAME` check against the pre-change file first so no production change is overwritten).

- [ ] **Step 3: Commit and record**

```bash
git add docs/superpowers/specs/2026-10-13-pt-depth-of-field-design.md pipeline_references/daylight.gd
git commit -m "docs(spec): depth of field -- amendment and measured results; sync the owner's relief knee 2.0

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Add a memory note (project) on where DoF lives, its off switch (`DOF_F_STOP := 0.0`), and that the probe's depth is the focus source.
