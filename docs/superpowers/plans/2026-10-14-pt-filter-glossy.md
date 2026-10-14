# Filter Glossy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a blurry bounce, floor the glossy lobes' roughness exactly as Cycles' Filter Glossy does (default 1.0), so sharp reflections reached through bounce light stop producing speckles, at no render-time cost.

**Architecture:** Three small GLSL helpers (encode / decode / alpha floor of a 5-bit log-scale running minimum pdf) mirrored in a doctest; the minimum rides in bits 3-7 of `PathPayload.sss_bits` on the accumulate route; `shade_and_bounce()` floors `brdf_mat` roughness (and `ggxAnisoAlphas` floors both alphas via a global) before NEE, and updates the minimum where it records the bounce pdf; one project setting in rt_params slot 42.

**Tech Stack:** Godot 4.7 fork (C++17, Vulkan RT, GLSL 460), doctest, Python 3 + numpy + Pillow for render checks.

**Spec:** `docs/superpowers/specs/2026-10-14-pt-filter-glossy-design.md`

## Global Constraints

- Cycles' rule: `blur_pdf = fg * min_pdf`; if `blur_pdf < 1`, `alpha_floor = sqrt(1 - blur_pdf) * 0.5`; `alpha_x/y = max(alpha_floor, alpha_x/y)`; diffuse and sheen untouched (spec, "Cycles' rule").
- `fg = setting > 0 ? 1 / setting : 0`; setting `rendering/pathtracer/filter_glossy`, float, **default 1.0**, range 0-10, 0 = off; rt_params **slot 42** (`RT_PARAM_FILTER_GLOSSY`) (spec 4).
- Code 0 = none; `encode(p) = (p >= 16) ? 0 : min(31, floor(3 * (4 - log2(p))) + 1)`; `decode(c) = 2^(4 - (c - 1) / 3)`; update `code = max(code, encode(p))` (spec 1).
- Stored in **bits 3-7 of `sss_bits`**, accumulate route (`RT_OIDN_FEATURES`) only; one-shot route unchanged (spec 1, 4).
- Updated only in the `combinedPdf` branch, with the UNGUIDED pdf; not by the `RT_MIS_PDF_NONE` branches, alpha pass-through or the SSS exit (spec 2).
- Floor applied after `brdf_mat` is fully populated and before the first NEE call; our `alpha = roughness^2`, so `roughness >= sqrt(alpha_floor)` for `roughness` and `coatRoughness`; `ggxAnisoAlphas` clamps both alphas to `g_glossy_alpha_floor` (spec 3).
- Off (`filter_glossy = 0`) is byte-identical to the pre-change binary (spec, Verification 2).
- Build with `python -m SCons ...`; grep every render log for `Error compiling` (a clean build does not validate GLSL). Check `tasklist | grep -i godot` before every render; never touch Godot processes running from `C:\Zlendo2026\`; stop a batch with a `STOP` file.

### Ruling recorded here (from the spec's own measurement)

- **Video speckles are measured on the LAST frame only.** `ZR_OIDN_DUMP` writes fixed file names
  (`oidn_color.pfm` etc., `render_forward_clustered.cpp` `_oidn_write_pfm`), so every OIDN fire
  overwrites the previous one. The spec asks for "raw speckle count per frame"; the plan measures
  the last frame's raw input plus the delivered PNGs' frame-to-frame change. Cost if wrong: a
  per-frame speckle trend is not reported.

## Review Focus

1. **Off drifting by compiler rounding** (the DoF branch's lesson: a dataflow-only change moved 20.8% of pixels). Expected: `filter_glossy = 0` byte-identical. Pinned in Task 2 Step 9.
2. **A mirror or window seen directly getting blurred** (the camera hit must have code 0). Expected: unchanged. Pinned in Task 3 Step 4 (crop check) and by the code-0 unit test.
3. **Guided paths lowering the minimum with the guided pdf.** Expected: the unguided pdf. Guiding is off by default (`guiding_probability` 0.0), so no render exercises it; pinned by code inspection in the final review and the explicit save/restore in Task 2 Step 6.
4. **The one-shot / DLSS-RR variant** (compiled without `RT_OIDN_FEATURES`): must still compile. Its only new code is the `g_glossy_alpha_floor` read in `ggxAnisoAlphas` (declared unconditionally). The still route's daylight probe renders frames with accumulation off (`Daylight.probe` sets `pathtracing_accumulate = false`), which compiles that variant, so the `Error compiling` check on every still render covers it. Pinned in Task 2 Step 10.
5. **Brightness bias larger than Cycles accepts.** Expected: mean PNG luma within +/-1%. Pinned in Task 3 Step 3 (stop and show the owner if outside).

---

## Workspace and harness (before Task 1)

Workspace (git-ignored): `.superpowers/sdd/2026-10-14-pt-filter-glossy/`. Copy the inputs:

```bash
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-pt-filter-glossy
mkdir -p $W
cp /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-08-video-parity/prodab/j209_input.json $W/j209_input.json
cp /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-video-fill-grid/seg204.json $W/seg204.json
```

`$W/run_still.sh` -- job 209 still with PRODUCTION's current scripts (copied; production untouched), optional `override.cfg` lines and extra env:

```bash
#!/bin/bash
# usage: run_still.sh <tag> [override.cfg lines ';'-separated] [extra env, e.g. ZR_OIDN_DUMP=<dir>]
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-pt-filter-glossy
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
TAG=$1; OVR=$2; EXTRA=$3; D=$W/$TAG
if [ -f "$W/STOP" ]; then echo "ABORT: $W/STOP exists" >&2; exit 1; fi
rm -rf "$D"; mkdir -p "$D/proj"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
if [ -n "$OVR" ]; then echo "$OVR" | tr ';' '\n' > "$D/proj/override.cfg"; fi
start=$(date +%s)
( cd "$D" && env $EXTRA $BIN --path "$D/proj" res://main.tscn -- "$W/j209_input.json" "$D/render.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

`$W/run_video.sh` -- the same for the 12-keyframe segment (`video_main.tscn`, writes `frame*.png`):

```bash
#!/bin/bash
# usage: run_video.sh <tag> [override.cfg lines ';'-separated] [extra env]
W=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-14-pt-filter-glossy
R=/c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
BIN=$R/bin/godot.windows.editor.x86_64.console.exe
TAG=$1; OVR=$2; EXTRA=$3; D=$W/$TAG
if [ -f "$W/STOP" ]; then echo "ABORT: $W/STOP exists" >&2; exit 1; fi
rm -rf "$D"; mkdir -p "$D/proj"
if tasklist | grep -qi godot; then echo "ABORT: a Godot process is running" > "$D/done"; exit 1; fi
cp $P/*.gd $P/*.tscn $P/project.godot "$D/proj/"; cp -r $P/shapes "$D/proj/"
ln $P/day.exr "$D/proj/day.exr" 2>/dev/null || cp $P/day.exr "$D/proj/"
ln $P/night.exr "$D/proj/night.exr" 2>/dev/null || cp $P/night.exr "$D/proj/"
if [ -n "$OVR" ]; then echo "$OVR" | tr ';' '\n' > "$D/proj/override.cfg"; fi
start=$(date +%s)
( cd "$D" && env $EXTRA $BIN --path "$D/proj" --write-movie "$D/frame.png" --fixed-fps 60 res://video_main.tscn -- "$W/seg204.json" "$D/out.mp4" "$D/thumb.png" > "$D/run.log" 2>&1 )
echo "exit=$? secs=$(( $(date +%s) - start ))" > "$D/done"
rm -rf "$D/proj"
```

`OFF="[rendering];pathtracer/filter_glossy=0.0"` is the override string that turns the feature off.

---

### Task 1: The encoding and floor helpers, mirrored and tested

**Files:**
- Create: `tests/servers/rendering/test_pt_filter_glossy.cpp`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (after `camera_lens_u()`, which follows `camera_filter_jitter()`)

**Interfaces:**
- Consumes: nothing.
- Produces (GLSL, `raytracing_inc.glsl`): `float g_glossy_alpha_floor = 0.0;` (module-level), `uint rt_glossy_min_encode(float p_pdf)`, `float rt_glossy_min_decode(uint p_code)`, `uint rt_glossy_min_update(uint p_code, float p_pdf)`, `float rt_glossy_alpha_floor(uint p_code, float p_fg)`.

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_filter_glossy.cpp` (licence header copied from `test_pt_dof.cpp` lines 1-29 with the file name changed), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_filter_glossy)

#include "core/math/math_funcs.h"

namespace TestPTFilterGlossy {

// Mirrors of the GLSL in raytracing_inc.glsl (Filter Glossy). Keep in lockstep.
static uint32_t encode(float p_pdf) {
	return 0u; // replaced in Step 3
}
static float decode(uint32_t p_code) {
	return 0.0f; // replaced in Step 3
}
static uint32_t update(uint32_t p_code, float p_pdf) {
	return p_code; // replaced in Step 3
}
static float alpha_floor(uint32_t p_code, float p_fg) {
	return 0.0f; // replaced in Step 3
}

static float exact_floor(float p_blur_pdf) {
	return p_blur_pdf < 1.0f ? Math::sqrt(1.0f - p_blur_pdf) * 0.5f : 0.0f;
}

TEST_CASE("[PathTracer][FilterGlossy] code 0 means no bounce yet and never blurs") {
	CHECK(alpha_floor(0u, 1.0f) == 0.0f);
	CHECK(alpha_floor(0u, 100.0f) == 0.0f);
}

TEST_CASE("[PathTracer][FilterGlossy] a stored minimum is never smaller than the true one, and within one step") {
	const float step = Math::pow(2.0f, 1.0f / 3.0f);
	for (float p = 1.0f / 64.0f; p < 16.0f; p *= 1.0137f) {
		const uint32_t c = encode(p);
		CHECK(c >= 1u);
		CHECK(c <= 31u);
		const float d = decode(c);
		CHECK(d >= p * (1.0f - 1e-5f));
		CHECK(d < p * step * (1.0f + 1e-5f));
	}
}

TEST_CASE("[PathTracer][FilterGlossy] pdfs of 16 or more, and non-positive pdfs, do not lower the minimum") {
	CHECK(encode(16.0f) == 0u);
	CHECK(encode(1000.0f) == 0u);
	CHECK(encode(0.0f) == 0u);
	CHECK(encode(-1.0f) == 0u);
	CHECK(encode(0.001f) == 31u); // below 2^-6 clamps to the last code
	CHECK(decode(31u) == doctest::Approx(1.0f / 64.0f));
	CHECK(decode(1u) == doctest::Approx(16.0f));
}

TEST_CASE("[PathTracer][FilterGlossy] the running update keeps the smaller pdf") {
	const uint32_t a = update(0u, 0.3f);
	CHECK(a == encode(0.3f));
	CHECK(update(a, 2.0f) == a); // a later, larger pdf does not raise the minimum
	CHECK(update(a, 0.05f) == encode(0.05f)); // a later, smaller pdf lowers it
	CHECK(update(a, 50.0f) == a); // a near-delta pdf never matters
}

TEST_CASE("[PathTracer][FilterGlossy] the floor follows Cycles and is never stronger") {
	CHECK(exact_floor(0.318f) == doctest::Approx(0.4129f).epsilon(1e-3));
	CHECK(exact_floor(1.0f) == 0.0f);
	const uint32_t c = encode(0.318f); // a diffuse bounce, cos/pi at normal incidence
	const float q = alpha_floor(c, 1.0f);
	CHECK(q > 0.0f);
	CHECK(q <= exact_floor(0.318f) + 1e-6f);
	CHECK(q >= exact_floor(0.318f) - 0.03f);
	CHECK(alpha_floor(encode(2.0f), 1.0f) == 0.0f); // blur_pdf >= 1: no blur
	CHECK(alpha_floor(c, 0.0f) == 0.0f); // setting 0: off
	CHECK(alpha_floor(encode(0.001f), 1.0f) <= 0.5f); // never above Cycles' 0.5 cap
}

} // namespace TestPTFilterGlossy
```

- [ ] **Step 2: Build and run it -- it must fail**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_t1_red.log 2>&1; tail -1 $W/build_t1_red.log
bin/godot.windows.editor.x86_64.console.exe --test --test-case="*FilterGlossy*" 2>&1 | grep -E 'test cases'
```
Expected: build done; `5 | 2 passed | 3 failed`. "code 0 never blurs" and "the running update keeps the smaller pdf" pass against the all-zero stubs (every code is 0, so equalities hold trivially); the update test's real RED is mutation (c) in Step 5.

- [ ] **Step 3: Implement the mirrors and the GLSL helpers**

Replace the four stubs in the test with:
```cpp
static uint32_t encode(float p_pdf) {
	if (!(p_pdf > 0.0f) || p_pdf >= 16.0f) {
		return 0u;
	}
	return (uint32_t)MIN(31.0f, Math::floor(3.0f * (4.0f - Math::log(p_pdf) / Math::log(2.0f))) + 1.0f);
}
static float decode(uint32_t p_code) {
	return Math::pow(2.0f, 4.0f - float(p_code - 1u) / 3.0f);
}
static uint32_t update(uint32_t p_code, float p_pdf) {
	return MAX(p_code, encode(p_pdf));
}
static float alpha_floor(uint32_t p_code, float p_fg) {
	if (p_code == 0u || !(p_fg > 0.0f)) {
		return 0.0f;
	}
	const float blur_pdf = p_fg * decode(p_code);
	return blur_pdf < 1.0f ? Math::sqrt(1.0f - blur_pdf) * 0.5f : 0.0f;
}
```
In `raytracing_inc.glsl`, after the closing brace of `camera_lens_u()`:
```glsl
// Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md; Cycles surface_shader.h:195,
// shade_surface.h:612). Each path keeps the smallest BSDF pdf it has sampled; once
// fg * min_pdf < 1 its glossy lobes get an alpha floor of sqrt(1 - fg * min_pdf) * 0.5. The
// minimum rides in 5 bits as a log-scale code: 0 = none yet; c in 1..31 decodes to
// 2^(4 - (c-1)/3), 16 down to 2^-6, rounded so the stored pdf is never smaller than the true
// one (the blur never stronger than Cycles'). Mirrored in test_pt_filter_glossy.cpp.
float g_glossy_alpha_floor = 0.0; // set by shade_and_bounce at a blurred hit; read by ggxAnisoAlphas

uint rt_glossy_min_encode(float p_pdf) {
	if (!(p_pdf > 0.0) || p_pdf >= 16.0) {
		return 0u;
	}
	return uint(min(31.0, floor(3.0 * (4.0 - log2(p_pdf))) + 1.0));
}

float rt_glossy_min_decode(uint p_code) {
	return exp2(4.0 - float(p_code - 1u) / 3.0);
}

uint rt_glossy_min_update(uint p_code, float p_pdf) {
	return max(p_code, rt_glossy_min_encode(p_pdf));
}

// p_fg = 1 / the filter_glossy setting, 0 = off. Returns 0.0 for no blur.
float rt_glossy_alpha_floor(uint p_code, float p_fg) {
	if (p_code == 0u || !(p_fg > 0.0)) {
		return 0.0;
	}
	float blur_pdf = p_fg * rt_glossy_min_decode(p_code);
	return blur_pdf < 1.0 ? sqrt(1.0 - blur_pdf) * 0.5 : 0.0;
}
```

- [ ] **Step 4: Build and run -- it must pass**

Same commands as Step 2. Expected: `5 | 5 passed | 0 failed`.

- [ ] **Step 5: Mutation check (apply one at a time to the test's mirror, rebuild, run, revert)**

(a) `Math::floor(...)` in `encode` -> `Math::ceil(...)`: expected "never smaller than the true one" FAILS. (b) `* 0.5f` in `alpha_floor` -> `* 0.6f`: expected "the floor follows Cycles" FAILS. (c) `MAX(p_code, ...)` in `update` -> `MIN(p_code, ...)`: expected "the running update" FAILS. Record each FAIL line; after reverting, 5/5.

- [ ] **Step 6: Commit**

```bash
git add tests/servers/rendering/test_pt_filter_glossy.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl
git commit -m "feat(pt): Filter Glossy helpers -- 5-bit running minimum pdf and Cycles' alpha floor

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Wire it into the integrator, the payload and the setting

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (RT_PARAM define after `RT_PARAM_DOF_FOCUS 41`; `PathState`; `path_unpack`; `path_pack`)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` (`trace_one_sample` init, `#ifdef RT_OIDN_FEATURES` block ~line 175)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` (`shade_and_bounce`: before `vec3 specularF0 = baseColorToSpecularF0(` ~line 1869; the `combinedPdf` branch ~line 2756)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl` (`ggxAnisoAlphas` ~line 1983)
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` (after `RT_PARAM_DOF_FOCUS = 41`)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (after the DoF params fill)
- Modify: `servers/rendering/rendering_server.cpp` (after the `dof_focus_distance` GLOBAL_DEF)

**Interfaces:**
- Consumes: Task 1's helpers and `g_glossy_alpha_floor`.
- Produces: setting `rendering/pathtracer/filter_glossy` (default 1.0); `PathState.glossy_min_code` (accumulate route).

- [ ] **Step 1: Baseline -- build the current HEAD and render job 209 twice**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_base.log 2>&1; tail -1 $W/build_base.log
bash $W/run_still.sh base_a; cat $W/base_a/done
bash $W/run_still.sh base_b; cat $W/base_b/done
cmp $W/base_a/render.png $W/base_b/render.png && echo REPEATABLE
grep -c 'Error compiling' $W/base_a/run.log
```
Expected: `REPEATABLE`, `0`. (Task 1's helpers are unused, so this build renders as before them.)

- [ ] **Step 2: Parameter slot and setting**

`raytracing_inc.glsl`, after `#define RT_PARAM_DOF_FOCUS 41 ...`:
```glsl
#define RT_PARAM_FILTER_GLOSSY 42 // rt_params[10].z - 1 / the Filter Glossy setting (0 = off)
```
`scene_shader_raytracing.h`, after `RT_PARAM_DOF_FOCUS = 41`:
```cpp
	static constexpr int RT_PARAM_FILTER_GLOSSY = 42; // 1 / rendering/pathtracer/filter_glossy; 0 = off
```
`render_raytracing.cpp`, directly after the two DoF `rt_ubo.params[...]` lines:
```cpp
		// Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md): Cycles stores 1 / the UI value
		// (scene/integrator.cpp:269); 0 = off.
		{
			const float filter_glossy = (float)GLOBAL_GET("rendering/pathtracer/filter_glossy");
			rt_ubo.params[SceneShaderRaytracing::RT_PARAM_FILTER_GLOSSY] = filter_glossy > 0.0f ? 1.0f / filter_glossy : 0.0f;
		}
```
`rendering_server.cpp`, after the `dof_focus_distance` GLOBAL_DEF:
```cpp
	// Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md): Blender's setting and default
	// (1.0): after a blurry bounce, glossy lobes get an alpha floor, so sharp reflections seen
	// through bounce light stop producing speckles. 0 = off. Accumulate (still / video) route.
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/filter_glossy", PROPERTY_HINT_RANGE, "0,10,0.01"), 1.0);
```

- [ ] **Step 3: PathState field and payload bits**

`raytracing_inc.glsl`, in `struct PathState` inside the existing `#ifdef RT_OIDN_FEATURES` block (after `bool feat_pending;`):
```glsl
	uint glossy_min_code; // Filter Glossy: running minimum pdf code, 0..31 (bits 3-7 of sss_bits)
```
In `path_unpack`, inside `#ifdef RT_OIDN_FEATURES` after `s.feat_pending = ...`:
```glsl
	s.glossy_min_code = (p.sss_bits >> 3u) & 31u;
```
In `path_pack`, replace the `#ifdef RT_OIDN_FEATURES` `p.sss_bits = ...` statement with:
```glsl
	p.sss_bits = (s.sss_exit ? 1u : 0u) | (s.guide_record ? 2u : 0u) | (s.feat_pending ? 4u : 0u) |
			((s.glossy_min_code & 31u) << 3u) | (packUnorm4x8(vec4(s.feat_throughput, 0.0)) << 8u);
```
Also update the `sss_bits` layout comments in `PathPayload` and `path_unpack` to name bits 3-7.

- [ ] **Step 4: Initialise at the camera ray**

`scene_raytracing_raygen.glsl`, `trace_one_sample()`, inside the `#ifdef RT_OIDN_FEATURES` block after `ps.feat_pending = ...`:
```glsl
	ps.glossy_min_code = 0u; // Filter Glossy: no blurry bounce yet (Cycles' min_ray_pdf = FLT_MAX)
```

- [ ] **Step 5: The floor in shade_and_bounce**

`raytracing_closest_hit_common_inc.glsl`, immediately before `vec3 specularF0 = baseColorToSpecularF0(brdf_mat.baseColor, ...` (after the SSS `#endif`):
```glsl
#ifdef RT_OIDN_FEATURES
	// Filter Glossy (spec 2026-10-14-pt-filter-glossy-design.md; Cycles surface_shader.h:195):
	// after a blurry bounce, every glossy lobe gets Cycles' alpha floor before NEE and the next
	// bounce, so a sharp reflection reached through bounce light cannot be a speckle. The
	// camera's own hit has code 0 and never blurs. Our alpha is roughness^2.
	{
		const float glossy_floor = rt_glossy_alpha_floor(ps.glossy_min_code, get_rt_param(RT_PARAM_FILTER_GLOSSY));
		if (glossy_floor > 0.0) {
			const float r_floor = sqrt(glossy_floor);
			brdf_mat.roughness = max(brdf_mat.roughness, r_floor);
			brdf_mat.coatRoughness = max(brdf_mat.coatRoughness, r_floor);
			g_glossy_alpha_floor = glossy_floor;
		}
	}
#endif
```
Then confirm nothing after this point reads the unfloored roughness for BSDF evaluation:
`awk 'NR>1869 && /m\.roughness|raw_mat\.clearcoat_roughness/' servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl`
Expected: only the DLSS-RR G-buffer / denoiser-threshold uses (~lines 1906-1916), which describe the primary hit (code 0, never blurred).

- [ ] **Step 6: The update where the bounce pdf is recorded**

In the same function, replace
```glsl
	} else {
		float bsdf_pdf = combinedPdf(N, next_dir, V, brdf_mat);
		ps.mis_ray_pdf = (bsdf_pdf > 0.0) ? bsdf_pdf : RT_MIS_PDF_NONE;
	}
```
with
```glsl
	} else {
		float bsdf_pdf = combinedPdf(N, next_dir, V, brdf_mat);
		ps.mis_ray_pdf = (bsdf_pdf > 0.0) ? bsdf_pdf : RT_MIS_PDF_NONE;
#ifdef RT_OIDN_FEATURES
		if (get_rt_param(RT_PARAM_FILTER_GLOSSY) > 0.0) {
			// Cycles: min_ray_pdf = fminf(unguided_bsdf_pdf, min_ray_pdf) (shade_surface.h:612).
			// combinedPdf's diffuse term reads g_guide, so take the material's own pdf without it.
			float unguided_pdf = bsdf_pdf;
			if (g_guide.is_active) {
				const GuideState guide_saved = g_guide;
				g_guide.is_active = false;
				unguided_pdf = combinedPdf(N, next_dir, V, brdf_mat);
				g_guide = guide_saved;
			}
			ps.glossy_min_code = rt_glossy_min_update(ps.glossy_min_code, unguided_pdf);
		}
#endif
	}
```

- [ ] **Step 7: Both anisotropic alphas**

`brdf_inc.glsl`, in `ggxAnisoAlphas`: replace `outAx = clamp(alpha, 0.0f, 1.0f);` with `outAx = max(clamp(alpha, 0.0f, 1.0f), g_glossy_alpha_floor);`, and in the anisotropic branch replace the two assignments with
```glsl
			outAx = max(clamp(alpha / aspect, 0.0f, 1.0f), g_glossy_alpha_floor);
			outAy = max(clamp(alpha * aspect, 0.0f, 1.0f), g_glossy_alpha_floor);
```
(`g_glossy_alpha_floor` is 0.0 except at a blurred hit, where it equals Cycles' `bsdf_blur` floor on both axes.)

- [ ] **Step 8: Build, tests, full suite**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes > $W/build_t2.log 2>&1; tail -1 $W/build_t2.log; grep -i ' error' $W/build_t2.log | head -3
bin/godot.windows.editor.x86_64.console.exe --test --test-case="*FilterGlossy*" 2>&1 | grep 'test cases'
bin/godot.windows.editor.x86_64.console.exe --test > $W/suite_t2.log 2>&1; tail -3 $W/suite_t2.log
```
Expected: build done; 5/5; full suite `0 failed`.

- [ ] **Step 9: Off is byte-identical; on compiles (Review Focus 1)**

```bash
bash $W/run_still.sh t2_off "[rendering];pathtracer/filter_glossy=0.0"; cat $W/t2_off/done
grep -c 'Error compiling' $W/t2_off/run.log
cmp $W/base_a/render.png $W/t2_off/render.png && echo IDENTICAL
bash $W/run_still.sh t2_on; cat $W/t2_on/done; grep -c 'Error compiling' $W/t2_on/run.log
cmp -s $W/base_a/render.png $W/t2_on/render.png && echo "SAME (feature inert?)" || echo "on differs from base (expected)"
```
Expected: `IDENTICAL`; `0` errors in both; "on differs from base (expected)". If off is NOT identical: systematic-debugging -- first suspect codegen (as on the DoF branch: keep the unchanged code paths textually unchanged, gate the new code in its own branch), never accept a drift.

- [ ] **Step 10: The one-shot variant still compiles (Review Focus 4)**

The one-shot pipeline compiles without `RT_OIDN_FEATURES`; the still route compiles it while the daylight probe renders with accumulation off. Confirm the probe did that on this run and that no variant failed:
```bash
grep -c 'Error compiling' $W/t2_off/run.log $W/t2_on/run.log
grep -c '\[Daylight\] probe:' $W/t2_on/run.log
```
Expected: `0` errors in both logs; `1` probe line (the probe ran, so both variants were compiled). Also run the relief gate as a regression check on the accumulate route:
```bash
timeout 900 bin/godot.windows.editor.x86_64.console.exe --rendering-driver vulkan --path pipeline_references res://tests/pt_highlight_relief_gate_scene.tscn > $W/gate_t2.log 2>&1; echo "exit=$?"; grep -c 'Error compiling' $W/gate_t2.log; grep -E '^PASS|^FAIL' $W/gate_t2.log
```
Expected: `exit=0`, `0`, `PASS: all 8 highlight-relief checks passed.`

- [ ] **Step 11: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/rendering_server.cpp
git commit -m "feat(pt): Filter Glossy on the accumulate route -- Cycles' blur after blurry bounces, on by default

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Measure, show the owner, close

**Files:**
- Modify: `docs/superpowers/specs/2026-10-14-pt-filter-glossy-design.md` (results amendment)

**Interfaces:**
- Consumes: Task 2's binary and setting.
- Produces: the measured results; the owner's ship decision.

- [ ] **Step 1: Still renders with the raw OIDN input dumped**

```bash
mkdir -p $W/dump_off $W/dump_on
bash $W/run_still.sh m_off "[rendering];pathtracer/filter_glossy=0.0" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_off)"; cat $W/m_off/done
bash $W/run_still.sh m_on "" "ZR_OIDN_DUMP=$(cygpath -w $W/dump_on)"; cat $W/m_on/done
ls -la $W/dump_off/oidn_color.pfm $W/dump_on/oidn_color.pfm
```
Expected: both `exit=0`, both PFMs present.

- [ ] **Step 2: Speckles, bias, time**

```bash
python - <<'EOF'
import numpy as np
from PIL import Image
W = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine\.superpowers\sdd\2026-10-14-pt-filter-glossy"
def pfm(p):
    with open(p, "rb") as f:
        assert f.readline().strip() in (b"PF", b"Pf")
        w, h = map(int, f.readline().split()); scale = float(f.readline())
        a = np.fromfile(f, dtype="<f4" if scale < 0 else ">f4").reshape(h, w, 3)
    return np.flipud(a)
K = np.array([0.2126, 0.7152, 0.0722], np.float32)
def speckles(l):
    pad = np.pad(l, 2, mode="edge")
    stack = np.stack([pad[dy:dy + l.shape[0], dx:dx + l.shape[1]] for dy in range(5) for dx in range(5)])
    med = np.median(stack, axis=0)
    return int(((l > 8.0 * med) & (l > 1e-3)).sum())
for t in ("off", "on"):
    l = pfm(fr"{W}\dump_{t}\oidn_color.pfm") @ K
    png = np.asarray(Image.open(fr"{W}\m_{t}\render.png").convert("RGB")).astype(np.float32) @ K
    secs = open(fr"{W}\m_{t}\done").read().split("secs=")[1].strip()
    print(f"{t}: raw speckles {speckles(l)}  raw mean {l.mean():.5f}  PNG mean luma {png.mean():.2f}  {secs} s")
EOF
```
Expected: off speckles > 0 (else the metric sees nothing -- stop and choose another measure); on speckles < off; PNG mean luma within +/-1% of off; on time within +2% of off. Outside +/-1%: stop and show the owner before continuing (Review Focus 5).

- [ ] **Step 3: Crops (Review Focus 2)**

```bash
python - <<'EOF'
from PIL import Image, ImageDraw
W = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine\.superpowers\sdd\2026-10-14-pt-filter-glossy"
A, B = (Image.open(fr"{W}\m_{t}\render.png").convert("RGB") for t in ("off", "on"))
boxes = {"table_vase": (1500, 1150, 2700, 1650), "floor_rug": (700, 1600, 1900, 2160), "window_glass": (1550, 600, 2550, 1250), "tv_glossy": (350, 550, 1150, 1200)}
for n, bx in boxes.items():
    w, h = bx[2] - bx[0], bx[3] - bx[1]
    o = Image.new("RGB", (2 * w, h + 40), (20, 20, 20)); d = ImageDraw.Draw(o)
    o.paste(A.crop(bx), (0, 40)); o.paste(B.crop(bx), (w, 40))
    d.text((10, 12), "Filter Glossy off", fill=(255, 255, 255)); d.text((w + 10, 12), "Filter Glossy on (1.0)", fill=(255, 255, 255))
    o.save(fr"{W}\fg_crop_{n}.png")
print("saved")
EOF
```
Look at each crop: glossy surfaces seen in bounce light may soften slightly; the window glass and the TV screen (seen directly) must be unchanged.

- [ ] **Step 4: Video segment on vs off**

```bash
mkdir -p $W/vdump_off $W/vdump_on
bash $W/run_video.sh v_off "[rendering];pathtracer/filter_glossy=0.0" "ZR_OIDN_DUMP=$(cygpath -w $W/vdump_off)"; cat $W/v_off/done
bash $W/run_video.sh v_on "" "ZR_OIDN_DUMP=$(cygpath -w $W/vdump_on)"; cat $W/v_on/done
grep -c 'Error compiling' $W/v_off/run.log $W/v_on/run.log
```
Then the last frame's raw speckles (the Step 2 `speckles()` on `vdump_*/oidn_color.pfm`) and the delivered frames' mean frame-to-frame change (last 12 `frame*.png`, mean |L(t+1) - L(t)| in 8-bit luma), on vs off; and a side-by-side clip:
```bash
python - <<'EOF'
import glob, subprocess
from PIL import Image
W = r"C:\Users\aiadmin\Desktop\Engine_Build_test\Zreal_Engine\.superpowers\sdd\2026-10-14-pt-filter-glossy"
FF = "C:/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/ffmpeg.exe"
fa, fb = sorted(glob.glob(W + r"\v_off\frame*.png"))[-12:], sorted(glob.glob(W + r"\v_on\frame*.png"))[-12:]
for i, (x, y) in enumerate(zip(fa, fb)):
    A, B = Image.open(x).convert("RGB"), Image.open(y).convert("RGB")
    o = Image.new("RGB", (A.width, A.height // 2)); o.paste(A.resize((A.width // 2, A.height // 2)), (0, 0)); o.paste(B.resize((A.width // 2, A.height // 2)), (A.width // 2, 0))
    o.save(fr"{W}\cmp_{i:03d}.png")
subprocess.run([FF, "-y", "-loglevel", "error", "-stream_loop", "4", "-framerate", "12", "-i", W + r"\cmp_%03d.png", "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", W + r"\fg_video_compare.mp4"], check=True)
print("wrote fg_video_compare.mp4 (left off, right on)")
EOF
```
Expected: 0 errors; on's raw speckles <= off's; frame-to-frame change on <= off.

- [ ] **Step 5: Show the owner**

Send the four crops and the clip (SendUserFile) with the Step 2/4 numbers, and ask (AskUserQuestion) whether to ship as is (on by default), ship off, or adjust. Do not decide for the owner.

- [ ] **Step 6: Record and commit**

Append "Results 2026-10-14" to the spec (the Step 2/4 numbers, the off byte-identity, the owner's decision, the last-frame-only video ruling). If the owner chose "ship off", change the GLOBAL_DEF default to 0.0 (rebuild, re-run Step 9's off check, which is then the default). Commit:
```bash
git add docs/superpowers/specs/2026-10-14-pt-filter-glossy-design.md
git commit -m "docs(spec): Filter Glossy -- measured results and the owner's ship decision

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
The owner copies the binary to production (`godot/bin/`) themselves.
