# Phase A — Offline Still Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing path-tracer accumulator into a real offline still renderer — one that anti-aliases, stores full precision, exports linear HDR, rejects fireflies, and spends samples where variance actually is.

**Architecture:** The accumulation machinery already exists (`rt_accum` / `rt_accum_n`, driven by `PT_PARAM_ACCUM_FLAG`). This plan fixes four defects in it and adds the measurement harness that every later phase depends on. No new subsystems; every change is to an existing file.

**Tech Stack:** C++ (Godot 4.7 fork), GLSL (Vulkan RT pipeline), GDScript (capture driver), SCons, doctest.

## Global Constraints

- Build with `scons platform=windows target=editor` — always pass `platform=windows` on this machine.
- **After touching any `.glsl`, run a full scons build** so `*.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- Any struct crossing C++↔GLSL must keep byte-identical layout: `std430`, matching member order, `alignas(16)`, and its `static_assert(sizeof(...) == N)`.
- New `RenderingServer` API must be added in all four places or the headless build breaks: `rendering_server.h` virtual → `rendering_server_default.h` `FUNC*` forward → RD impl → `servers/rendering/dummy/` stub.
- Free `PT_PARAM` slots are **9–13 only**. Slots 0–8 are taken (`VIS_MODE, SAMPLE_COUNT, MAX_BOUNCES, DENOISER, ACCUM_FLAG, ACCUM_FRAMES, OIDN_FLAG, ACCUM_TARGET, DLSS_RR_FINAL_FLAG`), 14 = `LIGHT_COUNT`, 15 = `FRAME_INDEX`.
- Tests live in `tests/servers/rendering/*.cpp` and are auto-globbed by `tests/SCsub` — no `test_main.cpp` edit needed. Build with `tests=yes`, run via `bin\godot.windows.editor.x86_64.exe --test`.
- Do not change realtime one-shot behaviour except where a task says so explicitly. The DLSS-RR realtime still path must keep working.

---

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` | Accumulator texture allocation; OIDN readback | 1, 3 |
| `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` | `RB_TEX_*` defines and format comments | 1 |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | Camera ray generation, accumulation blend, convergence early-out | 2, 5, 6 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | Shared helpers: filter jitter, contribution clamp, param indices | 2, 5 |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Per-contribution clamping at the shading site | 5 |
| `servers/rendering/rendering_server_enums.h` | `PT_PARAM_*` slot enum | 5 |
| `scene/resources/environment.cpp` / `.h` | User-facing knobs, packs the params array | 5, 6 |
| `servers/rendering/renderer_scene_render.h` + RD impl + dummy | HDR accumulator readback API | 3 |
| `pipeline_references/render.gd` | Still capture; EXR emission | 3 |
| `pipeline_references/tests/pt_validation.gd` | Convergence + AA measurement harness | 4 |
| `tests/servers/rendering/test_pt_accumulator.cpp` | CPU-side doctest for accumulator precision & clamp math | 1, 5 |

**Task order and dependencies:**

```
Task 1 (fp32 accumulator)  ──┬──> Task 3 (EXR export) ──> Task 4 (harness) ──> Task 5 (clamp) ──> Task 6 (adaptive)
Task 2 (camera jitter)     ──┘
```

Tasks 1 and 2 are independent and may be done in either order. Task 3 requires Task 1 (exporting a stalled fp16 buffer to EXR would bake in the defect). Task 4 requires Task 3 (it measures EXRs). Tasks 5 and 6 require Task 4 to prove they work.

---

## Background: the two defects you are fixing

Read this before starting. Both are non-obvious and both are real.

**Defect 1 — the accumulator is fp16, but the shader declares fp32.**
`render_forward_clustered.cpp:131` allocates `RD::DATA_FORMAT_R16G16B16A16_SFLOAT`, while `scene_raytracing_raygen.glsl:31` declares `layout(set = 0, binding = 29, rgba32f)`. Beyond the format mismatch, fp16 storage breaks the running average. The blend is `prev + (sample - prev)/(n+1)`. fp16 has ~10 mantissa bits, so its relative epsilon near 1.0 is ~9.8e-4. Once `1/(n+1)` drops below that, the increment rounds away entirely and **the image stops converging** — somewhere between n≈200 (noisy pixels) and n≈2000 (quiet ones). Users can set `pathtracing_accumulation_target` up to 8192 and get nothing past the first few hundred frames. fp16 also clamps at 65504, clipping bright pixels.

**Defect 2 — accumulation has no camera jitter.**
`scene_raytracing_raygen.glsl:89` computes `vec2(pixel) + vec2(0.5)` once, outside the sample loop, and every accumulated frame reuses that identical primary ray. Accumulation therefore reduces *shading* noise but delivers **zero anti-aliasing**, no matter how many frames you run. Cycles jitters a dedicated filter dimension per sample and centres only sample 0 (`intern/cycles/kernel/integrator/init_from_camera.h:28-29`).

---

### Task 1: fp32 accumulator

**Files:**
- Create: `tests/servers/rendering/test_pt_accumulator.cpp`
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:131` (format), `:1962` (size check), `:2002-2012` (decode), `:2060-2074` (re-encode)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h:48` (comment)

**Interfaces:**
- Consumes: nothing.
- Produces: `RB_TEX_RAYTRACING_ACCUM` is `RD::DATA_FORMAT_R32G32B32A32_SFLOAT`, 16 bytes/pixel, directly reinterpretable as `float[4]` per pixel. Task 3 relies on this exact layout.

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_accumulator.cpp`:

```cpp
/**************************************************************************/
/*  test_pt_accumulator.cpp                                               */
/**************************************************************************/

#include "tests/test_macros.h"

#include "core/math/math_funcs.h"

namespace TestPTAccumulator {

// Mirrors the raygen accumulator blend: running = prev + (sample - prev) / (n + 1).
// Storage precision is emulated by round-tripping the running value through the
// storage format after every accumulation step, exactly as an imageStore would.
static float accumulate_fp16_storage(const float *p_samples, int p_count) {
	uint16_t prev_h = Math::make_half_float(0.0f);
	for (int n = 0; n < p_count; n++) {
		const float prev = Math::half_to_float(prev_h);
		const float w = 1.0f / float(n + 1);
		prev_h = Math::make_half_float(prev + (p_samples[n] - prev) * w);
	}
	return Math::half_to_float(prev_h);
}

static float accumulate_fp32_storage(const float *p_samples, int p_count) {
	float prev = 0.0f;
	for (int n = 0; n < p_count; n++) {
		const float w = 1.0f / float(n + 1);
		prev = prev + (p_samples[n] - prev) * w;
	}
	return prev;
}

TEST_CASE("[PathTracer][Accumulator] fp16 storage stalls where fp32 converges") {
	// A 1-SPP estimator with true mean 1.0 and heavy per-sample noise.
	const int COUNT = 4096;
	LocalVector<float> samples;
	samples.resize(COUNT);
	for (int i = 0; i < COUNT; i++) {
		samples[i] = (i % 2 == 0) ? 0.25f : 1.75f;
	}

	const float got_fp32 = accumulate_fp32_storage(samples.ptr(), COUNT);
	const float got_fp16 = accumulate_fp16_storage(samples.ptr(), COUNT);

	const float err_fp32 = Math::abs(got_fp32 - 1.0f);
	const float err_fp16 = Math::abs(got_fp16 - 1.0f);

	// fp32 lands on the true mean.
	CHECK(err_fp32 < 1.0e-3f);
	// fp16 does measurably worse. This is the defect the format change fixes.
	CHECK(err_fp16 > err_fp32);
}

TEST_CASE("[PathTracer][Accumulator] fp16 discards the increment past ~4096 samples") {
	// At n = 4096 the blend weight is 1/4097 ~= 2.44e-4. fp16's spacing in [1,2)
	// is 2^-10 ~= 9.77e-4, so an increment this small rounds away completely.
	const float prev = 1.0f;
	const float sample = 2.0f;
	const float w = 1.0f / 4097.0f;
	const float running = prev + (sample - prev) * w;

	// fp32 keeps the increment.
	CHECK(running > prev);

	// fp16 storage throws it away: the average is frozen.
	const float stored = Math::half_to_float(Math::make_half_float(running));
	const float stored_prev = Math::half_to_float(Math::make_half_float(prev));
	CHECK(stored == stored_prev);
}

} // namespace TestPTAccumulator
```

- [ ] **Step 2: Build tests and run to verify they pass as a characterization of current behaviour**

```bash
scons platform=windows target=editor tests=yes
```

Run:

```bash
bin/godot.windows.editor.x86_64.exe --test "*Accumulator*"
```

Expected: both PASS. These tests characterize *why* fp16 is wrong — they are the written justification for the format change, and they must keep passing afterward (they test the math, not the engine format).

- [ ] **Step 3: Change the accumulator format to fp32**

In `render_forward_clustered.cpp`, at the `RB_TEX_RAYTRACING_ACCUM` creation (~line 131), change the format:

```cpp
	if (!render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_ACCUM)) {
		render_buffers->create_texture(
				RB_SCOPE_FORWARD_CLUSTERED,
				RB_TEX_RAYTRACING_ACCUM,
				RD::DATA_FORMAT_R32G32B32A32_SFLOAT,
				usage_bits_oidn,
				RD::TEXTURE_SAMPLES_1);
	}
```

In `render_raytracing.h:48`, update the comment to match:

```cpp
#define RB_TEX_RAYTRACING_ACCUM SNAME("rt_accum")       // running-average radiance (R32G32B32A32_SFLOAT)
```

- [ ] **Step 4: Fix the OIDN readback for the new stride**

The OIDN final-denoise path reads the accumulator and assumed 8 bytes/pixel. Three edits in `render_forward_clustered.cpp`.

First, the size guard (~line 1962):

```cpp
		Vector<uint8_t> accum_bytes = RD::get_singleton()->texture_get_data(accum_rid, v);
		ERR_CONTINUE(accum_bytes.size() != (int64_t)width * height * 16);
```

Second, the decode (~lines 2002-2012) becomes a straight float copy:

```cpp
		// Convert accum R32G32B32A32_SFLOAT -> RGB float3.
		{
			const float *src = reinterpret_cast<const float *>(accum_bytes.ptr());
			float *dst = color_f.ptrw();
			for (size_t i = 0; i < pixel_count; i++) {
				dst[i * 3 + 0] = src[i * 4 + 0];
				dst[i * 3 + 1] = src[i * 4 + 1];
				dst[i * 3 + 2] = src[i * 4 + 2];
				// alpha (src[i*4+3]) unused by OIDN color (RGB only).
			}
		}
```

Third, the re-encode (~lines 2060-2074). The destination is still the fp16 `internal_texture`, so only the alpha fetch changes — it now reads a float instead of a half:

```cpp
		Vector<uint8_t> out_bytes;
		out_bytes.resize((int)pixel_count * 8);
		{
			const float *accum_src = reinterpret_cast<const float *>(accum_bytes.ptr());
			uint16_t *dst16 = reinterpret_cast<uint16_t *>(out_bytes.ptrw());
			const float *src = color_f.ptr();
			for (size_t i = 0; i < pixel_count; i++) {
				dst16[i * 4 + 0] = Math::make_half_float(src[i * 3 + 0]);
				dst16[i * 4 + 1] = Math::make_half_float(src[i * 3 + 1]);
				dst16[i * 4 + 2] = Math::make_half_float(src[i * 3 + 2]);
				dst16[i * 4 + 3] = Math::make_half_float(accum_src[i * 4 + 3]); // keep original alpha.
			}
		}
```

- [ ] **Step 5: Full rebuild and verify no validation errors**

```bash
scons platform=windows target=editor tests=yes
```

Run an accumulated still and confirm the log shows no Vulkan storage-image format complaints and OIDN still reports a changed centre pixel:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references -e
```

Expected: `[OIDN-DIAG]` lines show `accum_bytes` equal to `width * height * 16`, and `center in=` differs from `center out=`.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.h tests/servers/rendering/test_pt_accumulator.cpp
git commit -m "fix(pt): store accumulator at fp32 so long accumulations keep converging

The running average was stored as R16G16B16A16_SFLOAT while the raygen shader
declared rgba32f. Beyond the format mismatch, fp16's relative epsilon (~9.8e-4
near 1.0) exceeds the 1/(n+1) blend weight past a few hundred samples, so the
increment rounded away and the image stopped converging well before the
configured accumulation target.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Camera jitter + tent reconstruction filter

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (append filter helpers after the RNG section, ~line 176)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:87-152`

**Interfaces:**
- Consumes: `pcg_hash`, `rand` from `raytracing_inc.glsl`.
- Produces: `vec2 camera_filter_jitter(uvec2 p_pixel, uint p_sample)` returning a sub-pixel offset; `void camera_ray(uvec2 p_pixel, vec2 p_jitter, out vec3 r_origin, out vec3 r_dir)`. Task 6 calls `camera_ray` from inside the convergence branch.

**Scope note:** jitter applies to accumulate mode and to samples 1..N-1 of one-shot mode. Sample 0 stays centred, which is what keeps the depth/velocity/DLSS-RR G-buffer writes (gated on `is_sample_zero`) at pixel centre in one-shot mode. In accumulate mode the driver passes `p_is_sample_zero = true` every frame, so those AOVs become jittered in lockstep with the colour sample — correct for OIDN, and the temporal upscalers are already bypassed while accumulating.

- [ ] **Step 1: Add the filter helpers**

Append to `raytracing_inc.glsl`, after the RNG section (after `rand2`, ~line 176):

```glsl
// ============================================================================
// CAMERA RECONSTRUCTION FILTER
// ============================================================================

/// Inverse CDF of a triangle (tent) distribution of radius 1, mapping u in
/// [0,1) to an offset in [-1, 1]. Filter importance sampling: the sample may
/// land outside the pixel footprint but still accumulates into this pixel,
/// which is what gives triangle reconstruction instead of a box.
float tent_filter_1d(float u) {
	return (u < 0.5) ? (sqrt(2.0 * u) - 1.0) : (1.0 - sqrt(max(0.0, 2.0 - 2.0 * u)));
}

/// Sub-pixel offset for accumulation/loop sample `p_sample`.
/// Sample 0 is centred, matching Cycles (`init_from_camera.h`): the first frame
/// of a preview stays identical to the un-jittered image, and the primary-ray
/// G-buffer writes that fire on sample 0 keep their pixel-centre alignment.
vec2 camera_filter_jitter(uvec2 p_pixel, uint p_sample) {
	if (p_sample == 0u) {
		return vec2(0.5);
	}
	// Dedicated RNG stream: keeping jitter off the path RNG stops sub-pixel
	// position from correlating with shading decisions.
	uint s = pcg_hash(p_pixel.x + p_pixel.y * 65536u + 0x9E3779B9u);
	s = pcg_hash(s + p_sample * 2654435761u);
	float jx = rand(s);
	float jy = rand(s);
	return vec2(0.5) + vec2(tent_filter_1d(jx), tent_filter_1d(jy));
}
```

- [ ] **Step 2: Add the ray builder and jitter the sample loops**

In `scene_raytracing_raygen.glsl`, insert this helper immediately above `void main()` (after `trace_one_sample`, ~line 86):

```glsl
/// Build the primary camera ray for `p_pixel` offset by `p_jitter` (in pixels).
/// Passing vec2(0.5) reproduces the original pixel-centre ray exactly.
void camera_ray(uvec2 p_pixel, vec2 p_jitter, out vec3 r_origin, out vec3 r_dir) {
	const vec2 pixel_center = vec2(p_pixel) + p_jitter;
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);
	const vec2 d = in_uv * 2.0 - 1.0;

	mat4 inv_view = transpose(mat4(scene_data_block.data.inv_view_matrix[0],
			scene_data_block.data.inv_view_matrix[1],
			scene_data_block.data.inv_view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	r_origin = (inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	r_dir = (inv_view * vec4(normalize(target.xyz), 0.0)).xyz;
}
```

Now replace the body of `main()` (lines 87-153) with:

```glsl
void main() {
	uvec2 pixel = gl_LaunchIDEXT.xy;

	// Sample count from specialization constant, frame index from uniform
	const uint samples_per_pixel = RT_GET_SAMPLE_COUNT();
	uint frame_index = uint(get_rt_param(RT_PARAM_FRAME_INDEX));

	const uint max_bounces = RT_GET_MAX_BOUNCES();

	// Phase A accumulation: blend one 1-SPP sample per launch into a persistent
	// running average so a still image converges across driver frames.
	if (get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5) {
		// 0-based accumulation frame the driver injected for this launch.
		uint accum_frame = uint(get_rt_param(RT_PARAM_ACCUM_FRAMES));

		// Jitter the primary ray per accumulated frame. Without this the
		// accumulator averages the same camera ray forever and never
		// anti-aliases, however many frames are driven.
		vec3 origin, direction;
		camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), origin, direction);

		vec3 sample_rad = trace_one_sample(pixel, frame_index, accum_frame, true,
				max_bounces, origin, direction);

		float n = imageLoad(rt_accum_n, ivec2(pixel)).x;
		n = max(n, 0.0);
		float w = 1.0 / (n + 1.0);

		vec3 prev = imageLoad(rt_accum, ivec2(pixel)).rgb;
		vec3 running = mix(prev, sample_rad, w);

		imageStore(rt_accum, ivec2(pixel), vec4(running, 1.0));
		imageStore(rt_accum_n, ivec2(pixel), vec4(n + 1.0));
		imageStore(image, ivec2(pixel), vec4(running, 1.0));
	} else {
		// One-shot path: trace `samples_per_pixel` samples this launch and
		// average. Sample 0 stays centred so the primary-ray G-buffer / depth /
		// velocity writes keep their pixel-centre alignment; samples 1..N-1 are
		// jittered, which is a free anti-aliasing win for realtime SPP > 1.
		vec3 total_radiance = vec3(0.0);
		[[dont_unroll]] for (uint sample_idx = 0u; sample_idx < samples_per_pixel; sample_idx++) {
			bool sz = (sample_idx == 0u);
			vec3 origin, direction;
			camera_ray(pixel, camera_filter_jitter(pixel, sample_idx), origin, direction);
			total_radiance += trace_one_sample(pixel, frame_index, sample_idx, sz,
					max_bounces, origin, direction);
		}
		vec3 final_radiance = total_radiance / float(samples_per_pixel);
		imageStore(image, ivec2(pixel), vec4(final_radiance, 1.0));
	}
}
```

- [ ] **Step 3: Full rebuild (regenerates the .glsl.gen.h)**

```bash
scons platform=windows target=editor tests=yes
```

Expected: builds clean. `scene_raytracing_raygen.glsl.gen.h` is regenerated — do not edit it by hand.

- [ ] **Step 4: Verify anti-aliasing appears**

Render an accumulated still of a scene containing a high-contrast near-diagonal silhouette edge (any hard-edged object against the sky works):

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references -e
```

Set `Environment.pathtracing_accumulate = true` and `pathtracing_accumulation_target = 256`.

Expected: edges show smooth intermediate tones. Before this change the same edge is a hard stairstep at any frame count. Keep the before/after PNGs — Task 4 turns this into an automated check.

- [ ] **Step 5: Verify the realtime path did not regress**

Run the DLSS-RR realtime still path (`pathtracing_accumulate = false`, `pathtracing_denoiser = 1`) and confirm the image is stable and correctly aligned — no shimmer, no half-pixel offset.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl
git commit -m "feat(pt): jitter the primary ray with a tent reconstruction filter

Accumulation previously reused one pixel-centre camera ray for every frame, so
it converged shading noise but produced no anti-aliasing at any frame count.
Each sample now draws a sub-pixel offset from a tent filter on a dedicated RNG
stream. Sample 0 stays centred, matching Cycles, which keeps the sample-0-gated
depth/velocity/DLSS-RR G-buffer writes aligned to the pixel centre.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Linear HDR (EXR) export

**Files:**
- Modify: `servers/rendering/renderer_scene_render.h` (new virtual)
- Modify: `servers/rendering/renderer_rd/renderer_scene_render_rd.h` / `.cpp` (default impl returning empty)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h` / `.cpp` (real impl)
- Modify: `servers/rendering/rendering_server.h`, `servers/rendering/rendering_server_default.h`, `servers/rendering/dummy/` scene-render stub
- Modify: `pipeline_references/render.gd:426-441`

**Interfaces:**
- Consumes: `RB_TEX_RAYTRACING_ACCUM` as `R32G32B32A32_SFLOAT` (Task 1).
- Produces: `RenderingServer.viewport_get_pathtracing_accum_image(RID p_viewport) -> Ref<Image>`, an `Image::FORMAT_RGBAF` holding scene-linear radiance, or an empty ref when path tracing is off / not accumulating.

- [ ] **Step 1: Add the virtual to the scene-render interface**

In `servers/rendering/renderer_scene_render.h`, inside the class, add near the other render-buffer accessors:

```cpp
	// Reads back the path-tracer accumulation buffer as scene-linear float RGBA.
	// Returns an empty ref when the buffer does not exist (path tracing off, or
	// no accumulation has run). Blocking readback: call only after a frame has
	// been drawn.
	virtual Ref<Image> get_pathtracing_accum_image(Ref<RenderSceneBuffers> p_render_buffers) { return Ref<Image>(); }
```

- [ ] **Step 2: Implement it in the Forward+ renderer**

In `render_forward_clustered.h`, declare inside `RenderForwardClustered`:

```cpp
	virtual Ref<Image> get_pathtracing_accum_image(Ref<RenderSceneBuffers> p_render_buffers) override;
```

In `render_forward_clustered.cpp`, add the implementation:

```cpp
Ref<Image> RenderForwardClustered::get_pathtracing_accum_image(Ref<RenderSceneBuffers> p_render_buffers) {
	Ref<RenderSceneBuffersRD> rb = p_render_buffers;
	ERR_FAIL_COND_V(rb.is_null(), Ref<Image>());

	Ref<RenderBufferDataForwardClustered> rb_data = rb->get_custom_data(RB_SCOPE_FORWARD_CLUSTERED);
	ERR_FAIL_COND_V(rb_data.is_null(), Ref<Image>());

	if (!rb_data->rt_has_accum_texture()) {
		return Ref<Image>();
	}

	const RID accum_rid = rb_data->rt_get_accum_texture();
	if (!RD::get_singleton()->texture_is_valid(accum_rid)) {
		return Ref<Image>();
	}

	const Size2i size = rb->get_internal_size();
	ERR_FAIL_COND_V(size.width <= 0 || size.height <= 0, Ref<Image>());

	// View 0 only: still capture is single-view.
	Vector<uint8_t> bytes = RD::get_singleton()->texture_get_data(accum_rid, 0);
	const int64_t expected = (int64_t)size.width * size.height * 16; // RGBA32F
	ERR_FAIL_COND_V_MSG(bytes.size() != expected, Ref<Image>(),
			vformat("Path-tracer accumulator readback size mismatch: got %d, expected %d.",
					(int)bytes.size(), (int)expected));

	return Image::create_from_data(size.width, size.height, false, Image::FORMAT_RGBAF, bytes);
}
```

- [ ] **Step 3: Plumb it through the RenderingServer layers**

In `servers/rendering/rendering_server.h`, add the virtual alongside the other viewport queries:

```cpp
	virtual Ref<Image> viewport_get_pathtracing_accum_image(RID p_viewport) = 0;
```

In `servers/rendering/rendering_server_default.h`, forward it synchronously (mirroring how `texture_2d_get` returns a `Ref<Image>`):

```cpp
	FUNC1RC(Ref<Image>, viewport_get_pathtracing_accum_image, RID)
```

In `servers/rendering/renderer_viewport.cpp` (and its header), resolve the viewport's buffers and delegate:

```cpp
Ref<Image> RendererViewport::viewport_get_pathtracing_accum_image(RID p_viewport) {
	Viewport *viewport = viewport_owner.get_or_null(p_viewport);
	ERR_FAIL_NULL_V(viewport, Ref<Image>());
	ERR_FAIL_COND_V(viewport->render_buffers.is_null(), Ref<Image>());
	return RSG::scene->get_pathtracing_accum_image(viewport->render_buffers);
}
```

Add the matching dummy stub so the headless build keeps linking — in the dummy scene-render header:

```cpp
	virtual Ref<Image> get_pathtracing_accum_image(Ref<RenderSceneBuffers> p_render_buffers) override { return Ref<Image>(); }
```

- [ ] **Step 4: Emit the EXR from the capture driver**

In `pipeline_references/render.gd`, replace the deferred-EXR comment block at lines 431-438 with a real export:

```gdscript
		if accumulate_enabled:
			var exr_path: String = output_path.get_basename() + ".exr"
			var hdr: Image = RenderingServer.viewport_get_pathtracing_accum_image(
					get_viewport().get_viewport_rid())
			if hdr != null and not hdr.is_empty():
				var err: int = hdr.save_exr(exr_path, false)
				if err == OK:
					print("[Render] Linear HDR EXR saved to: ", exr_path)
				else:
					push_warning("[Render] EXR save failed (err %d): %s" % [err, exr_path])
			else:
				push_warning("[Render] Accumulator readback returned no image; EXR skipped.")
			var denoise_note := " with in-process OIDN final-denoise" if oidn_enabled else (" with DLSS-RR reconstruct-final" if dlss_rr_final_enabled else "")
			print("[Render] Accumulated still captured%s (PNG tonemapped + EXR linear)." % denoise_note)
```

- [ ] **Step 5: Rebuild and verify the EXR round-trips**

```bash
scons platform=windows target=editor tests=yes
```

Render an accumulated still, then confirm the EXR exists and is genuinely linear HDR, not a tonemapped copy. In the Godot editor script console or a quick test scene:

```gdscript
var img := Image.load_from_file("res://output/test.exr")
print("format=", img.get_format())          # expect FORMAT_RGBAF / RGBAH
var mx := 0.0
for y in range(img.get_height()):
    for x in range(img.get_width()):
        mx = max(mx, img.get_pixel(x, y).r)
print("max red=", mx)                        # expect > 1.0 on any scene with a light source
```

Expected: `max red > 1.0`, proving highlights above display white survived. A tonemapped buffer would be clamped at 1.0.

- [ ] **Step 6: Confirm it opens in Blender**

Open the EXR in Blender's Image editor. Highlights must remain recoverable when exposure is pulled down — that is the whole point of the format.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_scene_render.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/rendering_server.h servers/rendering/rendering_server_default.h servers/rendering/renderer_viewport.cpp servers/rendering/renderer_viewport.h servers/rendering/dummy pipeline_references/render.gd
git commit -m "feat(pt): export the converged accumulator as linear HDR EXR

Adds viewport_get_pathtracing_accum_image() through the standard RS layering
(virtual -> FUNC forward -> RD impl -> dummy stub) and emits an .exr alongside
the tonemapped .png for accumulated stills. Highlights above display white now
survive capture and stay available for grading.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Convergence & anti-aliasing validation harness

Build this now, not later. Tasks 5 and 6 and every phase after this one are variance-reduction work whose acceptance is an error-vs-sample-count curve, not an eyeballed still.

**Files:**
- Create: `pipeline_references/tests/pt_validation.gd`

**Interfaces:**
- Consumes: `RenderingServer.viewport_get_pathtracing_accum_image` (Task 3); jitter from Task 2.
- Produces: `PTValidation.rmse(a, b) -> float`, `PTValidation.edge_gradient_steps(img, y) -> int`, `PTValidation.convergence_curve(frame_counts) -> Array` — used by Tasks 5 and 6 to prove no regression.

- [ ] **Step 1: Write the harness**

Create `pipeline_references/tests/pt_validation.gd`:

```gdscript
extends Node
class_name PTValidation

## Measurement harness for path-tracer quality work.
##
## Two metrics matter for Phase A:
##   1. convergence_curve() - RMSE against a high-sample reference as a function
##      of accumulated frames. A correct accumulator falls roughly as 1/sqrt(N).
##      A stalled one flattens out. This is what catches an fp16-style defect.
##   2. edge_gradient_steps() - how many intermediate tones a high-contrast edge
##      resolves. Without camera jitter this is 0-1 at any frame count.

## Root-mean-square error between two same-size linear images (RGB only).
static func rmse(p_a: Image, p_b: Image) -> float:
	assert(p_a.get_size() == p_b.get_size(), "rmse: size mismatch")
	var acc := 0.0
	var n := 0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			acc += (ca.r - cb.r) * (ca.r - cb.r)
			acc += (ca.g - cb.g) * (ca.g - cb.g)
			acc += (ca.b - cb.b) * (ca.b - cb.b)
			n += 3
	return sqrt(acc / float(max(n, 1)))

## Counts pixels along scanline `p_y` whose luminance sits strictly between the
## darkest and brightest values on that line. A hard-aliased edge yields 0-1;
## a properly filtered edge yields several.
static func edge_gradient_steps(p_img: Image, p_y: int) -> int:
	var lo := INF
	var hi := -INF
	for x in range(p_img.get_width()):
		var l := _luma(p_img.get_pixel(x, p_y))
		lo = min(lo, l)
		hi = max(hi, l)
	if hi - lo < 1e-4:
		return 0
	var band_lo := lo + (hi - lo) * 0.15
	var band_hi := lo + (hi - lo) * 0.85
	var steps := 0
	for x in range(p_img.get_width()):
		var l := _luma(p_img.get_pixel(x, p_y))
		if l > band_lo and l < band_hi:
			steps += 1
	return steps

static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## Renders the current scene at each frame count in `p_frame_counts`, then
## reports RMSE against a reference rendered at `p_reference_frames`.
## Returns an Array of { "frames": int, "rmse": float }.
func convergence_curve(p_env: Environment, p_frame_counts: Array,
		p_reference_frames: int = 4096) -> Array:
	var vp_rid := get_viewport().get_viewport_rid()

	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_reference_frames
	var reference := await _render_accum(p_env, vp_rid, p_reference_frames)
	assert(reference != null, "convergence_curve: reference render failed")

	var results: Array = []
	for frames in p_frame_counts:
		var img := await _render_accum(p_env, vp_rid, int(frames))
		if img == null:
			push_warning("convergence_curve: render failed at %d frames" % frames)
			continue
		results.append({ "frames": int(frames), "rmse": PTValidation.rmse(img, reference) })
	return results

## Drives a fresh accumulation of exactly `p_frames` frames and reads the
## linear accumulator back. Toggling accumulate off/on forces accum_reset_pending
## in the C++ driver, so each run starts from a cleared buffer.
func _render_accum(p_env: Environment, p_vp_rid: RID, p_frames: int) -> Image:
	p_env.pathtracing_accumulate = false
	await get_tree().process_frame
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for i in range(p_frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return RenderingServer.viewport_get_pathtracing_accum_image(p_vp_rid)

## Prints a curve and asserts it actually descends. A stalled accumulator
## produces a flat tail, which is exactly the fp16 defect Task 1 fixed.
func report_convergence(p_results: Array) -> void:
	print("--- convergence curve ---")
	for r in p_results:
		print("  frames=%5d  rmse=%.6f" % [r["frames"], r["rmse"]])
	if p_results.size() >= 2:
		var first: float = p_results[0]["rmse"]
		var last: float = p_results[p_results.size() - 1]["rmse"]
		print("  reduction: %.2fx" % [first / max(last, 1e-9)])
		assert(last < first * 0.5,
				"Accumulator is not converging: RMSE barely improved with more frames.")
```

- [ ] **Step 2: Run the convergence curve**

Attach `pt_validation.gd` to a node in a test scene containing a hard-edged object against the sky, and call:

```gdscript
var results := await convergence_curve(env, [16, 64, 256, 1024])
report_convergence(results)
```

Expected: RMSE falls monotonically and roughly halves per 4× frames (the 1/sqrt(N) law). With Task 1 reverted, the 256→1024 segment flattens — that is the regression this harness exists to catch.

- [ ] **Step 3: Run the anti-aliasing check**

```gdscript
var img := await _render_accum(env, get_viewport().get_viewport_rid(), 256)
var steps := PTValidation.edge_gradient_steps(img, img.get_height() / 2)
print("edge gradient steps: ", steps)
assert(steps >= 3, "Edge is still hard-aliased; camera jitter is not active.")
```

Expected: `steps >= 3`. Before Task 2 this is 0 or 1 regardless of frame count.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/tests/pt_validation.gd
git commit -m "test(pt): add convergence and anti-aliasing measurement harness

convergence_curve() measures RMSE against a high-sample self-reference across
frame counts, catching accumulator stalls that a single still hides.
edge_gradient_steps() measures whether an edge actually resolves intermediate
tones, catching a missing camera jitter.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Firefly clamp

Fireflies are worse with accumulation than without it: one unlucky high-throughput path leaves a bright pixel that the running average divides down only as 1/N and never removes.

**Files:**
- Modify: `servers/rendering/rendering_server_enums.h` (add slots 9, 10)
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` (mirror the constants)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (slot defines + clamp helper)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:455-534`
- Modify: `scene/resources/environment.h` / `.cpp`
- Modify: `tests/servers/rendering/test_pt_accumulator.cpp` (clamp math test)

**Interfaces:**
- Consumes: `get_rt_param` from `raytracing_inc.glsl`.
- Produces: `vec3 clamp_contribution(vec3 p_c, float p_limit)`; `Environment.pathtracing_clamp_direct` / `pathtracing_clamp_indirect` (float, `0.0` = disabled).

- [ ] **Step 1: Write the failing test for the clamp math**

Append to `tests/servers/rendering/test_pt_accumulator.cpp`, inside the `TestPTAccumulator` namespace:

```cpp
// Mirrors clamp_contribution() in raytracing_inc.glsl. Scales a radiance
// contribution so its largest channel does not exceed p_limit, preserving hue.
static void clamp_contribution_ref(float p_c[3], float p_limit) {
	if (p_limit <= 0.0f) {
		return; // 0 disables clamping.
	}
	const float m = MAX(p_c[0], MAX(p_c[1], p_c[2]));
	if (m > p_limit) {
		const float s = p_limit / m;
		p_c[0] *= s;
		p_c[1] *= s;
		p_c[2] *= s;
	}
}

TEST_CASE("[PathTracer][Clamp] limits the peak channel and preserves hue") {
	float c[3] = { 40.0f, 20.0f, 10.0f };
	clamp_contribution_ref(c, 10.0f);

	CHECK(c[0] == doctest::Approx(10.0f));
	// Ratios are unchanged: 40:20:10 -> 10:5:2.5.
	CHECK(c[1] == doctest::Approx(5.0f));
	CHECK(c[2] == doctest::Approx(2.5f));
}

TEST_CASE("[PathTracer][Clamp] leaves in-range contributions untouched") {
	float c[3] = { 1.0f, 2.0f, 3.0f };
	clamp_contribution_ref(c, 10.0f);

	CHECK(c[0] == doctest::Approx(1.0f));
	CHECK(c[1] == doctest::Approx(2.0f));
	CHECK(c[2] == doctest::Approx(3.0f));
}

TEST_CASE("[PathTracer][Clamp] a limit of zero disables clamping") {
	float c[3] = { 1000.0f, 0.0f, 0.0f };
	clamp_contribution_ref(c, 0.0f);

	CHECK(c[0] == doctest::Approx(1000.0f));
}
```

- [ ] **Step 2: Run the tests to pin down the intended behaviour**

```bash
scons platform=windows target=editor tests=yes
```

Run:

```bash
bin/godot.windows.editor.x86_64.exe --test "*Clamp*"
```

Expected: all three PASS. `clamp_contribution_ref` is the CPU mirror that specifies exactly what the GLSL must do — hue-preserving peak-channel scaling, with `0.0` as the disable sentinel. Write it and the tests together, then port it to GLSL in Step 4. If any case fails here, fix the reference before touching the shader: the GPU behaviour is far harder to debug than this.

- [ ] **Step 3: Add the param slots**

In `servers/rendering/rendering_server_enums.h`, after `PT_PARAM_DLSS_RR_FINAL_FLAG = 8`:

```cpp
	// PT_PARAM_CLAMP_DIRECT: maximum radiance a single direct-lighting contribution
	// may add at the first bounce. 0.0 = disabled. Mirrors Cycles
	// `sample_clamp_direct` (intern/cycles/kernel/data_template.h).
	PT_PARAM_CLAMP_DIRECT = 9,
	// PT_PARAM_CLAMP_INDIRECT: same limit for every contribution after the first
	// bounce. This is the one that kills fireflies; indirect specular paths are
	// where the outliers come from. 0.0 = disabled.
	PT_PARAM_CLAMP_INDIRECT = 10,
```

In `scene_shader_raytracing.h`, alongside the existing mirrors:

```cpp
	static constexpr int RT_PARAM_CLAMP_DIRECT = RSE::PT_PARAM_CLAMP_DIRECT;
	static constexpr int RT_PARAM_CLAMP_INDIRECT = RSE::PT_PARAM_CLAMP_INDIRECT;
```

In `raytracing_inc.glsl`, alongside the other `RT_PARAM_*` defines (replacing the stale "Indices 6-13 reserved" comment):

```glsl
#define RT_PARAM_CLAMP_DIRECT 9 // rt_params[2].x - Max direct contribution (0 = off)
#define RT_PARAM_CLAMP_INDIRECT 10 // rt_params[2].y - Max indirect contribution (0 = off)
// Indices 11-13 reserved for future use
```

- [ ] **Step 4: Add the GLSL clamp helper**

Append to `raytracing_inc.glsl`, after the camera filter section:

```glsl
// ============================================================================
// FIREFLY CLAMPING
// ============================================================================

/// Scales a radiance contribution so its largest channel does not exceed
/// `p_limit`, preserving hue. `p_limit <= 0.0` disables clamping.
///
/// This biases the estimator by design — it is the standard, and Cycles ships
/// the same knob (`sample_clamp_direct` / `sample_clamp_indirect`). Clamping
/// matters more here than in a one-shot renderer: under accumulation a single
/// outlier decays only as 1/N and stays visible for the whole render.
vec3 clamp_contribution(vec3 p_c, float p_limit) {
	if (p_limit <= 0.0) {
		return p_c;
	}
	float m = max(p_c.r, max(p_c.g, p_c.b));
	return (m > p_limit) ? p_c * (p_limit / m) : p_c;
}
```

- [ ] **Step 5: Apply the clamp at the shading site**

In `raytracing_closest_hit_common_inc.glsl`, inside `shade_and_bounce`, replace the emissive line (currently line 458):

```glsl
	// Emissive contribution.
	float clamp_limit = (total_bounces == 0u)
			? get_rt_param(RT_PARAM_CLAMP_DIRECT)
			: get_rt_param(RT_PARAM_CLAMP_INDIRECT);
	ps.radiance += clamp_contribution(ps.throughput * m.emissive, clamp_limit);
```

Note `total_bounces` is read at line 451, above this point, so it is already in scope.

Then replace the NEE accumulation (currently line 533):

```glsl
		ps.radiance += clamp_contribution(ps.throughput * direct_light, clamp_limit);
```

- [ ] **Step 6: Expose the knobs on Environment**

In `scene/resources/environment.h`, add the members and accessors next to the existing pathtracing fields:

```cpp
	float pathtracing_clamp_direct = 0.0f;
	float pathtracing_clamp_indirect = 10.0f;
```

```cpp
	void set_pathtracing_clamp_direct(float p_clamp);
	float get_pathtracing_clamp_direct() const;
	void set_pathtracing_clamp_indirect(float p_clamp);
	float get_pathtracing_clamp_indirect() const;
```

In `environment.cpp`, add the definitions next to `set_pathtracing_accumulation_target`:

```cpp
void Environment::set_pathtracing_clamp_direct(float p_clamp) {
	pathtracing_clamp_direct = MAX(0.0f, p_clamp);
	_update_pathtracing();
}

float Environment::get_pathtracing_clamp_direct() const {
	return pathtracing_clamp_direct;
}

void Environment::set_pathtracing_clamp_indirect(float p_clamp) {
	pathtracing_clamp_indirect = MAX(0.0f, p_clamp);
	_update_pathtracing();
}

float Environment::get_pathtracing_clamp_indirect() const {
	return pathtracing_clamp_indirect;
}
```

Add to `_update_pathtracing()`:

```cpp
	params.write[RSE::PT_PARAM_CLAMP_DIRECT] = pathtracing_clamp_direct;
	params.write[RSE::PT_PARAM_CLAMP_INDIRECT] = pathtracing_clamp_indirect;
```

And bind them in `_bind_methods()`, following the existing pathtracing property pattern:

```cpp
	ClassDB::bind_method(D_METHOD("set_pathtracing_clamp_direct", "clamp"), &Environment::set_pathtracing_clamp_direct);
	ClassDB::bind_method(D_METHOD("get_pathtracing_clamp_direct"), &Environment::get_pathtracing_clamp_direct);
	ClassDB::bind_method(D_METHOD("set_pathtracing_clamp_indirect", "clamp"), &Environment::set_pathtracing_clamp_indirect);
	ClassDB::bind_method(D_METHOD("get_pathtracing_clamp_indirect"), &Environment::get_pathtracing_clamp_indirect);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "pathtracing_clamp_direct", PROPERTY_HINT_RANGE, "0,100,0.01"), "set_pathtracing_clamp_direct", "get_pathtracing_clamp_direct");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "pathtracing_clamp_indirect", PROPERTY_HINT_RANGE, "0,100,0.01"), "set_pathtracing_clamp_indirect", "get_pathtracing_clamp_indirect");
```

- [ ] **Step 7: Rebuild and verify fireflies vanish without flattening the image**

```bash
scons platform=windows target=editor tests=yes
```

Render a scene with a small bright specular source (a glossy sphere under a small intense light) at 256 accumulated frames, with `pathtracing_clamp_indirect = 10.0`.

Expected: isolated white pixels are gone. Then run the Task 4 convergence curve with clamping on and off — the clamped run must still converge (RMSE falling), and overall brightness must not visibly drop. If the image dims noticeably, the limit is too low; raise it.

- [ ] **Step 8: Commit**

```bash
git add servers/rendering/rendering_server_enums.h servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl scene/resources/environment.h scene/resources/environment.cpp tests/servers/rendering/test_pt_accumulator.cpp
git commit -m "feat(pt): add direct/indirect firefly clamping

Adds PT_PARAM_CLAMP_DIRECT/INDIRECT and clamps emissive and NEE contributions
by bounce depth, mirroring Cycles' sample_clamp_direct/indirect. Outliers matter
more under accumulation than in a one-shot render: a single bad path decays only
as 1/N and stays visible for the entire render.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Adaptive sampling

This task buys **speed**, not image quality — it redirects the sample budget toward pixels that are still noisy. It is last in Phase A and can be deferred without blocking Phase B.

**Files:**
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp:135-142` (new variance texture), `:2833-2834` (clear it on reset)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` (new `RB_TEX_*` define)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp:3320-3345` (bind it)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl`
- Modify: `servers/rendering/rendering_server_enums.h` (slot 11), `scene/resources/environment.*`

**Interfaces:**
- Consumes: `camera_ray` / `camera_filter_jitter` (Task 2); the fp32 accumulator (Task 1); `PTValidation.convergence_curve` (Task 4).
- Produces: `RB_TEX_RAYTRACING_VARIANCE` (`R32G32_SFLOAT`, `.x` = running mean luminance, `.y` = Welford M2); `Environment.pathtracing_noise_threshold` (float, `0.0` = disabled).

- [ ] **Step 1: Add the variance texture**

In `render_raytracing.h`, next to the other accumulator defines:

```cpp
#define RB_TEX_RAYTRACING_VARIANCE SNAME("rt_variance") // Welford (mean_luma, M2) per pixel (R32G32_SFLOAT)
```

In `render_forward_clustered.cpp`, alongside the `RB_TEX_RAYTRACING_ACCUM_N` creation:

```cpp
	if (!render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_VARIANCE)) {
		render_buffers->create_texture(
				RB_SCOPE_FORWARD_CLUSTERED,
				RB_TEX_RAYTRACING_VARIANCE,
				RD::DATA_FORMAT_R32G32_SFLOAT,
				usage_bits_oidn, // CAN_COPY_TO_BIT: cleared alongside the accumulator on reset.
				RD::TEXTURE_SAMPLES_1);
	}
```

Add the accessors in `render_forward_clustered.h` next to `rt_get_accum_n_texture`:

```cpp
		bool rt_has_variance_texture() const { return render_buffers->has_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_VARIANCE); }
		RID rt_get_variance_texture() const { return render_buffers->get_texture(RB_SCOPE_FORWARD_CLUSTERED, RB_TEX_RAYTRACING_VARIANCE); }
```

Clear it wherever the accumulator is cleared (`render_forward_clustered.cpp:2833-2834`):

```cpp
			RD::get_singleton()->texture_clear(rb_data->rt_get_variance_texture(), Color(0, 0, 0, 0), 0, 1, 0, 1);
```

Bind it at binding 31 in `render_raytracing.cpp`, following the pattern used for bindings 29 and 30 (~line 3324).

- [ ] **Step 2: Add the noise-threshold param**

In `rendering_server_enums.h`:

```cpp
	// PT_PARAM_NOISE_THRESHOLD: per-pixel relative-error target. Once a pixel's
	// estimated error falls below this, sampling stops for that pixel and the
	// budget goes elsewhere. 0.0 = disabled (sample every pixel every frame).
	// Mirrors Cycles adaptive sampling (intern/cycles/kernel/film/adaptive_sampling.h).
	PT_PARAM_NOISE_THRESHOLD = 11,
```

Mirror it in `scene_shader_raytracing.h` and `raytracing_inc.glsl` exactly as in Task 5 Step 3, and add `Environment.pathtracing_noise_threshold` (default `0.01`) following the Task 5 Step 6 pattern.

- [ ] **Step 3: Track variance and skip converged pixels**

In `scene_raytracing_raygen.glsl`, declare the new image next to `rt_accum_n`:

```glsl
layout(set = 0, binding = 31, rg32f) uniform image2D rt_variance;
```

Replace the accumulate branch of `main()` with:

```glsl
	if (get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5) {
		uint accum_frame = uint(get_rt_param(RT_PARAM_ACCUM_FRAMES));

		float n = max(imageLoad(rt_accum_n, ivec2(pixel)).x, 0.0);
		vec3 prev = imageLoad(rt_accum, ivec2(pixel)).rgb;
		vec2 var_state = imageLoad(rt_variance, ivec2(pixel)).xy;

		// Adaptive sampling: once a pixel's relative standard error drops below
		// the threshold, stop spending samples on it. Needs a minimum sample
		// count first, otherwise early noise luck freezes a pixel prematurely.
		const float MIN_ADAPTIVE_SAMPLES = 16.0;
		float noise_threshold = get_rt_param(RT_PARAM_NOISE_THRESHOLD);
		if (noise_threshold > 0.0 && n >= MIN_ADAPTIVE_SAMPLES) {
			float mean_luma = var_state.x;
			float m2 = var_state.y;
			// Standard error of the mean, relative to the mean itself.
			float variance = m2 / max(n - 1.0, 1.0);
			float std_err = sqrt(variance / n);
			if (std_err < noise_threshold * max(mean_luma, 1e-4)) {
				// Converged: republish the running average and take no sample.
				imageStore(image, ivec2(pixel), vec4(prev, 1.0));
				return;
			}
		}

		vec3 origin, direction;
		camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), origin, direction);

		vec3 sample_rad = trace_one_sample(pixel, frame_index, accum_frame, true,
				max_bounces, origin, direction);

		float w = 1.0 / (n + 1.0);
		vec3 running = mix(prev, sample_rad, w);

		// Welford online variance on sample luminance.
		float luma = dot(sample_rad, vec3(0.2126, 0.7152, 0.0722));
		float delta = luma - var_state.x;
		float new_mean = var_state.x + delta * w;
		float new_m2 = var_state.y + delta * (luma - new_mean);

		imageStore(rt_accum, ivec2(pixel), vec4(running, 1.0));
		imageStore(rt_accum_n, ivec2(pixel), vec4(n + 1.0));
		imageStore(rt_variance, ivec2(pixel), vec4(new_mean, new_m2, 0.0, 0.0));
		imageStore(image, ivec2(pixel), vec4(running, 1.0));
	} else {
```

- [ ] **Step 4: Rebuild and verify the speed win with no quality loss**

```bash
scons platform=windows target=editor tests=yes
```

Run the Task 4 convergence curve twice on the same scene — once with `pathtracing_noise_threshold = 0.0`, once with `0.01`.

Expected: at equal frame counts the RMSE curves stay close (within ~10%), while the adaptive run's wall-clock time per frame drops as more pixels converge. If RMSE is clearly worse, `MIN_ADAPTIVE_SAMPLES` is too low — raise it to 32 and re-measure.

- [ ] **Step 5: Check for convergence-boundary seams**

Inspect a still rendered with the threshold active, especially across smooth gradients.

Expected: no visible blotches where converged regions meet noisy ones. If seams appear, Cycles solves this by dilating the "needs more samples" mask with a two-pass box filter (`adaptive_sampling.h:95-138`); add that as a follow-up compute pass rather than by lowering the threshold.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl servers/rendering/rendering_server_enums.h scene/resources/environment.h scene/resources/environment.cpp
git commit -m "feat(pt): adaptive sampling via per-pixel Welford variance

Tracks running mean luminance and M2 per pixel in a new R32G32F buffer and stops
sampling pixels whose relative standard error falls below the configured noise
threshold, redirecting the budget to noisy regions. Mirrors Cycles adaptive
sampling; the mask-dilation pass is deliberately deferred.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Phase A exit criteria

Before starting Phase B, all of these must hold:

1. `--test "*PathTracer*"` passes.
2. `convergence_curve([16, 64, 256, 1024])` shows RMSE falling roughly as 1/sqrt(N) with **no flat tail**.
3. `edge_gradient_steps(...) >= 3` on a high-contrast edge at 256 frames.
4. A rendered `.exr` opens in Blender with values above 1.0 intact.
5. A small bright specular source leaves no permanent white pixels at 256 frames.
6. The DLSS-RR realtime still path still renders correctly (no regression).

## What Phase A does not deliver

Stated plainly so the result is not mistaken for Cycles parity. After Phase A the still is **sharp, HDR, stable, and efficiently sampled** — but light transport is unchanged. Still open, in later phases:

- Diffuse GI still dies at 2 bounces (`MAX_DIFFUSE_BOUNCES 2u`) → interiors stay flat. **Phase B3.**
- No MIS → glossy reflections of area lights stay noisy. **Phase B2.**
- White-noise sampling → error is clumpy, not filmic grain. **Phase B5.**
- Emissive meshes are not lights. **Phase C1.**
- Glass, SSS, clearcoat, sheen absent, and glTF drops them at import. **Phases D and E.**

The "looks like Cycles" step change arrives in **B3 and B2**, not here. Phase A is what makes that change measurable.
