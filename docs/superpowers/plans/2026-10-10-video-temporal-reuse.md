# Video Temporal Reuse Implementation Plan

> **Status 2026-10-11: closed by the owner after Task 4** (no gain at the same render time; the pass
> ships off). Tasks 4 Step 2 onward and Task 5 were not executed. Outcome and numbers: the spec's
> "Outcome" section.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Blend each delivered video frame's 24-sample accumulation with the previous frames' (reprojected, rejected, clamped) before OIDN, so edges and fine detail stop flickering without adding render time.

**Architecture:** A new compute pass (`PTTemporal` effect + `pt_temporal.glsl`) runs once per delivered frame in the OIDN final-denoise step of `render_forward_clustered.cpp`. It reads `rt_accum`, `rt_depth` and `rt_accum_normal`, reprojects a ping-pong history (colour, depth, normal + sample count) through both frames' view-projections, and writes the blend into the other history set; OIDN then reads that set instead of `rt_accum`. Frame-to-frame bookkeeping lives in a pure C++ `PTTemporalState` on `RTViewportState`; the accumulate route's Sobol index advances by `frames_denoised * target` while the reuse is on. Two project settings switch it; the video route sets them.

**Tech Stack:** Godot 4.7 fork (C++17, RenderingDevice/Vulkan, GLSL 450 compute), doctest (`tests/`), GDScript (`pipeline_references`), Python 3 measurement scripts in `.superpowers/sdd/2026-10-08-video-parity/`.

**Spec:** `docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md`

## Global Constraints

- Settings: `rendering/pathtracer/temporal_history_samples` (int, default **0 = off**), `rendering/pathtracer/temporal_clamp_gamma` (float, default **1.0**). Debug-only: `rendering/pathtracer/temporal_debug` (bool, default false).
- Off must change nothing: with the cap at 0 the new binary renders **byte-identical** frames to the current one.
- Video route sets the cap to **48** for Phase A with OIDN (`VIDEO_TEMPORAL_HISTORY_SAMPLES := 48`); stills never set it.
- Reject history when: previous UV off-screen; **depth**: history world position more than **2%** of the camera distance from the current one; **normal**: dot of current and history normals **< 0.9**; a miss (depth 0) only matches a miss.
- History radiance read with a **5-tap Catmull-Rom** filter; depth and normal **nearest-texel**.
- Clamp: current frame's **3x3** neighbourhood, mean +/- gamma * sigma per channel in **YCoCg of exposure-scaled radiance compressed by x/(1+x)**, clipped history mapped back to linear.
- Blend in linear radiance: `h = min(history_count, cap)`; `out = (24*current + h*history)/(24 + h)`; stored count `min(24 + h, cap)`.
- Sample index with the reuse on: `accum_frame + frames_denoised * target (+ ZR_SEED_OFFSET)`; `RT_PARAM_ADAPTIVE_SAMPLE` keeps the unshifted index.
- History invalid on the first denoise, after a viewport resize, and whenever the cap is 0; anything unexpected (missing texture, size mismatch) means "no history".
- Success (job 210, keyframes 204-215, 24 spp, vs `seg_new128`): noise change **<= 0.65** overall and **<= 1.1** on edges; **<= 43.5 s** per delivered frame. No trails: per-frame error vs the reference drops overall, no class gets worse, worst 0.1% no higher than today's; repeated on the fastest 12 keyframes.
- Build: `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes` run through the **PowerShell** tool (bare `scons` is not on PATH; production's binary is built with `tests=yes`).
- One Godot process at a time. Before any render check `tasklist | grep -i godot`; never touch a Godot process running from `C:\Zlendo2026\`.
- GLSL: never use the reserved identifiers `active`, `filter`, `input`, `output`, `sample`, `common`, `partition`, `resource`. A clean build proves nothing about GLSL: grep the render log for `Error compiling`.

## Review Focus

1. **Viewport resized mid-sequence** -> the history is dropped and that frame renders exactly as without the reuse. Pinned in Task 1 (`a size change drops the history`).
2. **A camera cut** (a jump between keyframes) -> every pixel's history is rejected; nothing from the old view survives. Pinned in Task 4 Step 6 (debug-mask cut test, accepted fraction < 1%).
3. **Sky / view through a window** (primary miss, depth 0) -> history accepted only miss-to-miss, never mixed with a hit. Pinned in Task 2 (`misses only match misses`) and checked on the debug mask in Task 3.
4. **The daylight probe's offscreen viewport and the cap switched off** -> the pass never runs where OIDN does not fire or the cap is 0. Pinned in Task 3 Step 9 (log: every `[PT-TEMPORAL]` line has the 3840x2160 size; none with the cap at 0).
5. **Static camera (OIDN latch)** -> one blend per camera position, never a frame blended with itself twice. Pinned in Task 3 Step 9 (static job: exactly one `[PT-TEMPORAL]` line per run with the reuse on).

---

### Task 1: PTTemporalState -- frame-to-frame bookkeeping

**Files:**
- Create: `servers/rendering/renderer_rd/effects/pt_temporal_state.h`
- Create: `tests/servers/rendering/test_pt_temporal.cpp`

**Interfaces:**
- Produces: `struct PTTemporalState` with members `bool history_valid`, `Size2i history_size`, `uint32_t read_index`, `uint32_t frames_denoised`, `Projection prev_vp`; methods `static uint32_t sample_offset(uint32_t p_frames_denoised, uint32_t p_target, int p_cap)`, `bool begin_frame(const Size2i &p_size)`, `void end_frame(const Projection &p_vp)`, `uint32_t write_index() const`, `void invalidate()`.

- [ ] **Step 1: Write the failing tests**

Create `tests/servers/rendering/test_pt_temporal.cpp` (copy the 30-line licence header from `tests/servers/rendering/test_pt_accumulator.cpp` lines 1-29, with the file name changed), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_temporal)

#include "servers/rendering/renderer_rd/effects/pt_temporal_state.h"

namespace TestPTTemporal {

TEST_CASE("[PathTracer][Temporal] the first frame has no history, the second does") {
	PTTemporalState s;
	CHECK_FALSE(s.begin_frame(Size2i(64, 32)));
	s.end_frame(Projection());
	CHECK(s.begin_frame(Size2i(64, 32)));
}

TEST_CASE("[PathTracer][Temporal] a size change drops the history") {
	PTTemporalState s;
	s.begin_frame(Size2i(64, 32));
	s.end_frame(Projection());
	CHECK_FALSE(s.begin_frame(Size2i(128, 32)));
	s.end_frame(Projection());
	CHECK(s.begin_frame(Size2i(128, 32)));
}

TEST_CASE("[PathTracer][Temporal] the read side alternates and the write side is the other one") {
	PTTemporalState s;
	CHECK(s.read_index == 0u);
	CHECK(s.write_index() == 1u);
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.read_index == 1u);
	CHECK(s.write_index() == 0u);
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.read_index == 0u);
}

TEST_CASE("[PathTracer][Temporal] invalidate starts over") {
	PTTemporalState s;
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.frames_denoised == 2u);
	s.invalidate();
	CHECK(s.frames_denoised == 0u);
	CHECK_FALSE(s.begin_frame(Size2i(8, 8)));
}

TEST_CASE("[PathTracer][Temporal] end_frame keeps the camera for the next frame") {
	PTTemporalState s;
	Projection p;
	p.columns[3][0] = 2.5f;
	s.begin_frame(Size2i(8, 8));
	s.end_frame(p);
	CHECK(s.prev_vp.columns[3][0] == doctest::Approx(2.5f));
}

TEST_CASE("[PathTracer][Temporal] the sample offset continues the sequence only while the reuse is on") {
	CHECK(PTTemporalState::sample_offset(0, 24, 48) == 0u);
	CHECK(PTTemporalState::sample_offset(3, 24, 48) == 72u);
	CHECK(PTTemporalState::sample_offset(3, 24, 0) == 0u);
}

} // namespace TestPTTemporal
```

- [ ] **Step 2: Build and confirm the build fails**

Run (PowerShell): `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Select-Object -Last 15`
Expected: compile error `pt_temporal_state.h: No such file or directory` (or MSVC C1083).

- [ ] **Step 3: Write the header**

Create `servers/rendering/renderer_rd/effects/pt_temporal_state.h` (licence header as in `effects/local_highlight.h`):

```cpp
#pragma once

#include "core/math/projection.h"
#include "core/math/vector2i.h"

// Frame-to-frame bookkeeping for the path tracer's temporal reuse (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md). Pure C++, no
// RenderingDevice, so tests/servers/rendering/test_pt_temporal.cpp drives it directly.
// Lives on RTViewportState, apart from the accumulator: the video route resets the
// accumulator every frame (accumulate off/on), and that must not touch the history.
struct PTTemporalState {
	bool history_valid = false; // the read-side history holds a previous frame of history_size
	Size2i history_size;
	uint32_t read_index = 0; // which of the two history sets holds the previous frame
	uint32_t frames_denoised = 0; // frames blended since the reuse was switched on
	Projection prev_vp; // previous delivered frame's view-projection (depth-corrected)

	// Accumulate-route Sobol offset: frame k traces points k*target .. k*target+target-1, so
	// its pixel-filter jitter lands in new places and edges converge across frames.
	static uint32_t sample_offset(uint32_t p_frames_denoised, uint32_t p_target, int p_cap) {
		return p_cap > 0 ? p_frames_denoised * p_target : 0u;
	}

	// Once per delivered frame, before the blend. False on the first frame, after a size
	// change, and after invalidate().
	bool begin_frame(const Size2i &p_size) {
		if (p_size != history_size) {
			history_valid = false;
			history_size = p_size;
		}
		return history_valid;
	}

	// After the blend wrote the write side: it becomes the read side for the next frame.
	void end_frame(const Projection &p_vp) {
		read_index = 1u - read_index;
		prev_vp = p_vp;
		history_valid = true;
		frames_denoised++;
	}

	uint32_t write_index() const { return 1u - read_index; }

	// The reuse is off: the next frame it runs on starts with no history.
	void invalidate() {
		history_valid = false;
		frames_denoised = 0;
	}
};
```

- [ ] **Step 4: Build and run the tests**

Run (PowerShell): `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Select-Object -Last 4`
Expected: `scons: done building targets.`
Run (Bash): `bin/godot.windows.editor.x86_64.console.exe --test --test-case="*Temporal*" 2>&1 | tail -5`
Expected: `test cases: 6 | 6 passed | 0 failed`

- [ ] **Step 5: Commit**

```bash
git add servers/rendering/renderer_rd/effects/pt_temporal_state.h tests/servers/rendering/test_pt_temporal.cpp
git commit -m "feat(pt): PTTemporalState -- history bookkeeping for temporal reuse"
```

---

### Task 2: The blend pass -- pt_temporal.glsl and the PTTemporal effect

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl`
- Create: `servers/rendering/renderer_rd/effects/pt_temporal.h`
- Create: `servers/rendering/renderer_rd/effects/pt_temporal.cpp`
- Modify: `tests/servers/rendering/test_pt_temporal.cpp` (append the math mirror and its tests)

**Interfaces:**
- Consumes: nothing from Task 1 (the caller in Task 3 joins them).
- Produces: `class RendererRD::PTTemporal` with `struct Inputs { RID current_color, current_depth, current_normal; Projection curr_vp, prev_vp; Vector3 curr_cam_pos; uint32_t read_index; bool history_valid; float exposure, clamp_gamma, current_samples, history_cap; bool debug_mask; }` and `RID process(Ref<RenderSceneBuffersRD> p_render_buffers, const Inputs &p_in)` returning the written colour texture (invalid RID = nothing dispatched).

- [ ] **Step 1: Write the math mirror tests (they pin what the shader must compute)**

Append to `tests/servers/rendering/test_pt_temporal.cpp`, inside `namespace TestPTTemporal`, after the existing cases:

```cpp
// --- Mirror of pt_temporal.glsl. Same pattern as test_pt_accumulator.cpp: the shader cannot be
// --- unit-tested, so its arithmetic is written here once and pinned; the shader cites this file.

struct Blend {
	float value;
	float count;
};

// pt_temporal.glsl main(): blend by sample count, h = 0 when the history was rejected.
static Blend temporal_blend(float p_current, float p_history, float p_history_count, float p_current_samples, float p_cap, bool p_accepted) {
	const float h = p_accepted ? MIN(p_history_count, p_cap) : 0.0f;
	return { (p_current_samples * p_current + h * p_history) / (p_current_samples + h), MIN(p_current_samples + h, p_cap) };
}

// depth test: world positions within p_tol of the camera distance.
static bool depth_ok(const Vector3 &p_cur, const Vector3 &p_hist, const Vector3 &p_cam, float p_tol) {
	return p_cur.distance_to(p_hist) <= p_tol * p_cur.distance_to(p_cam);
}

// normal test; a zero (missing) normal on either side does not reject.
static bool normal_ok(const Vector3 &p_a, const Vector3 &p_b, float p_min_dot) {
	if (p_a.length() <= 1e-3f || p_b.length() <= 1e-3f) {
		return true;
	}
	return p_a.normalized().dot(p_b.normalized()) >= p_min_dot;
}

// a miss (depth 0) only matches a miss.
static bool miss_ok(float p_cur_depth, float p_hist_depth) {
	return (p_cur_depth <= 0.0f) == (p_hist_depth <= 0.0f);
}

static float compress(float p_c, float p_exposure) {
	const float e = MAX(p_c, 0.0f) * p_exposure;
	return e / (1.0f + e);
}

static float expand(float p_c, float p_exposure) {
	const float k = MIN(p_c, 0.9999f);
	return k / (1.0f - k) / p_exposure;
}

static Vector3 rgb_to_ycocg(const Vector3 &p_c) {
	return Vector3(0.25f * p_c.x + 0.5f * p_c.y + 0.25f * p_c.z, 0.5f * p_c.x - 0.5f * p_c.z, -0.25f * p_c.x + 0.5f * p_c.y - 0.25f * p_c.z);
}

static Vector3 ycocg_to_rgb(const Vector3 &p_c) {
	const float t = p_c.x - p_c.z;
	return Vector3(t + p_c.y, p_c.x + p_c.z, t - p_c.y);
}

// Catmull-Rom weights for the 4 taps around a sample at fraction p_f in [0, 1).
static void catmull_rom_weights(float p_f, float r_w[4]) {
	r_w[0] = p_f * (-0.5f + p_f * (1.0f - 0.5f * p_f));
	r_w[1] = 1.0f + p_f * p_f * (-2.5f + 1.5f * p_f);
	r_w[2] = p_f * (0.5f + p_f * (2.0f - 1.5f * p_f));
	r_w[3] = p_f * p_f * (-0.5f + 0.5f * p_f);
}

TEST_CASE("[PathTracer][Temporal] counts run 24, 48, 48 at cap 48") {
	Blend b = temporal_blend(1.0f, 0.0f, 0.0f, 24.0f, 48.0f, false); // first frame: no history
	CHECK(b.count == doctest::Approx(24.0f));
	b = temporal_blend(1.0f, 0.0f, b.count, 24.0f, 48.0f, true);
	CHECK(b.count == doctest::Approx(48.0f));
	b = temporal_blend(1.0f, 0.0f, b.count, 24.0f, 48.0f, true);
	CHECK(b.count == doctest::Approx(48.0f));
}

TEST_CASE("[PathTracer][Temporal] the steady state gives the history two thirds of the weight") {
	const Blend b = temporal_blend(1.0f, 0.0f, 48.0f, 24.0f, 48.0f, true);
	CHECK(b.value == doctest::Approx(1.0f / 3.0f));
}

TEST_CASE("[PathTracer][Temporal] a rejected pixel is exactly the current frame") {
	const Blend b = temporal_blend(0.734f, 9.0f, 48.0f, 24.0f, 48.0f, false);
	CHECK(b.value == 0.734f);
}

TEST_CASE("[PathTracer][Temporal] depth tolerance is 2 percent of the camera distance") {
	const Vector3 cam(0, 0, 0);
	const Vector3 p(0, 0, -3);
	CHECK(depth_ok(p, Vector3(0, 0, -3.03f), cam, 0.02f)); // 1%
	CHECK_FALSE(depth_ok(p, Vector3(0, 0, -3.09f), cam, 0.02f)); // 3%
}

TEST_CASE("[PathTracer][Temporal] normals within about 25 degrees pass") {
	const Vector3 n(0, 1, 0);
	CHECK(normal_ok(n, Vector3(0, Math::cos(Math::deg_to_rad(20.0f)), Math::sin(Math::deg_to_rad(20.0f))), 0.9f));
	CHECK_FALSE(normal_ok(n, Vector3(0, Math::cos(Math::deg_to_rad(30.0f)), Math::sin(Math::deg_to_rad(30.0f))), 0.9f));
	CHECK(normal_ok(n, Vector3(), 0.9f));
}

TEST_CASE("[PathTracer][Temporal] misses only match misses") {
	CHECK(miss_ok(0.0f, 0.0f));
	CHECK(miss_ok(0.3f, 0.2f));
	CHECK_FALSE(miss_ok(0.0f, 0.2f));
	CHECK_FALSE(miss_ok(0.3f, 0.0f));
}

TEST_CASE("[PathTracer][Temporal] the clamp space round-trips") {
	const float exposure = 3.79f;
	for (float v : { 0.0f, 0.01f, 0.25f, 1.0f, 7.5f, 60.0f }) {
		CHECK(expand(compress(v, exposure), exposure) == doctest::Approx(v).epsilon(1e-3));
	}
	const Vector3 c(0.2f, 0.5f, 0.9f);
	const Vector3 r = ycocg_to_rgb(rgb_to_ycocg(c));
	CHECK(r.x == doctest::Approx(c.x));
	CHECK(r.y == doctest::Approx(c.y));
	CHECK(r.z == doctest::Approx(c.z));
}

TEST_CASE("[PathTracer][Temporal] Catmull-Rom weights sum to one") {
	for (float f : { 0.0f, 0.25f, 0.5f, 0.75f, 0.999f }) {
		float w[4];
		catmull_rom_weights(f, w);
		CHECK(w[0] + w[1] + w[2] + w[3] == doctest::Approx(1.0f));
	}
}
```

Also add `#include "core/math/vector3.h"` and `#include "core/math/math_funcs.h"` under the existing include.

- [ ] **Step 2: Build and run the tests; they pass at once (they pin arithmetic, no engine code yet)**

Run (PowerShell): `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Select-Object -Last 4`
Run (Bash): `bin/godot.windows.editor.x86_64.console.exe --test --test-case="*Temporal*" 2>&1 | tail -5`
Expected: `test cases: 14 | 14 passed | 0 failed`. Then mutate once to prove the tests bite: change `p_tol * p_cur.distance_to(p_cam)` to `2.0f * p_tol * p_cur.distance_to(p_cam)`, rebuild, expect the depth case to FAIL, and revert.

- [ ] **Step 3: Write the shader**

Create `servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl`:

```glsl
#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Temporal reuse for the path tracer's accumulate route (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md). Blends the frame's
// accumulated radiance with the previous frame's blend, reprojected through depth and both
// frames' view-projections, rejected on depth / normal / miss, clamped to the current 3x3
// neighbourhood. Every formula here is mirrored and pinned by
// tests/servers/rendering/test_pt_temporal.cpp.

layout(set = 0, binding = 0) uniform sampler2D history_color; // previous blend, linear sampler
layout(set = 0, binding = 1) uniform sampler2D history_depth; // previous rt_depth (texelFetch)
layout(set = 0, binding = 2) uniform sampler2D history_normal; // previous normal guide, .a = sample count
layout(rgba32f, set = 0, binding = 3) uniform restrict readonly image2D current_color; // rt_accum
layout(r32f, set = 0, binding = 4) uniform restrict readonly image2D current_depth; // rt_depth
layout(rgba16f, set = 0, binding = 5) uniform restrict readonly image2D current_normal; // rt_accum_normal
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2D blend_color;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D blend_depth;
layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D blend_normal;

layout(set = 0, binding = 9, std140) uniform Params {
	mat4 curr_inv_vp;
	mat4 prev_vp;
	mat4 prev_inv_vp;
	vec4 curr_cam_pos;
	ivec2 size;
	float exposure;
	float clamp_gamma;
	float current_samples;
	float history_cap;
	uint history_valid;
	uint debug_mask;
	float depth_tolerance;
	float normal_min_dot;
	float pad0;
	float pad1;
}
params;

// rt_depth is reverse-Z: 0 is the far plane and marks a primary miss. A miss reprojects as a
// point a hair inside the far plane, i.e. by direction, like the raygen's sky velocity.
const float MISS_DEPTH = 1e-7;

vec3 compress(vec3 c) {
	vec3 e = max(c, vec3(0.0)) * params.exposure;
	return e / (1.0 + e);
}

vec3 expand(vec3 c) {
	vec3 k = min(c, vec3(0.9999));
	return k / (1.0 - k) / params.exposure;
}

vec3 rgb_to_ycocg(vec3 c) {
	return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 ycocg_to_rgb(vec3 c) {
	float t = c.x - c.z;
	return vec3(t + c.y, c.x + c.z, t - c.y);
}

vec3 world_from_depth(mat4 inv_vp, vec2 uv, float depth) {
	vec4 w = inv_vp * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return w.xyz / w.w;
}

// 5-tap Catmull-Rom through the bilinear sampler (the 4x4 kernel with its corners dropped).
vec3 history_catmull_rom(vec2 uv) {
	vec2 tex_size = vec2(params.size);
	vec2 sample_pos = uv * tex_size;
	vec2 tex_pos1 = floor(sample_pos - 0.5) + 0.5;
	vec2 f = sample_pos - tex_pos1;
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec2 w12 = w1 + w2;
	vec2 tex_pos0 = (tex_pos1 - 1.0) / tex_size;
	vec2 tex_pos3 = (tex_pos1 + 2.0) / tex_size;
	vec2 tex_pos12 = (tex_pos1 + w2 / w12) / tex_size;
	vec3 acc = textureLod(history_color, vec2(tex_pos12.x, tex_pos0.y), 0.0).rgb * (w12.x * w0.y);
	acc += textureLod(history_color, vec2(tex_pos0.x, tex_pos12.y), 0.0).rgb * (w0.x * w12.y);
	acc += textureLod(history_color, tex_pos12, 0.0).rgb * (w12.x * w12.y);
	acc += textureLod(history_color, vec2(tex_pos3.x, tex_pos12.y), 0.0).rgb * (w3.x * w12.y);
	acc += textureLod(history_color, vec2(tex_pos12.x, tex_pos3.y), 0.0).rgb * (w12.x * w3.y);
	float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	return max(acc / wsum, vec3(0.0));
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.size))) {
		return;
	}

	vec3 cur = imageLoad(current_color, pos).rgb;
	float cur_depth = imageLoad(current_depth, pos).r;
	vec3 cur_normal = imageLoad(current_normal, pos).rgb;
	bool cur_miss = cur_depth <= 0.0;

	float h = 0.0;
	vec3 hist = vec3(0.0);
	uint reason = 0u; // 0 accepted, 1 off-screen or no history, 2 depth or miss mismatch, 3 normal
	if (params.history_valid == 0u) {
		reason = 1u;
	} else {
		vec2 uv = (vec2(pos) + 0.5) / vec2(params.size);
		vec3 p = world_from_depth(params.curr_inv_vp, uv, cur_miss ? MISS_DEPTH : cur_depth);
		vec4 pc = params.prev_vp * vec4(p, 1.0);
		vec2 prev_uv = pc.xy / pc.w * 0.5 + 0.5;
		if (pc.w <= 0.0 || any(lessThan(prev_uv, vec2(0.0))) || any(greaterThanEqual(prev_uv, vec2(1.0)))) {
			reason = 1u;
		} else {
			ivec2 ppos = clamp(ivec2(prev_uv * vec2(params.size)), ivec2(0), params.size - 1);
			float hist_depth = texelFetch(history_depth, ppos, 0).r;
			vec4 hist_n = texelFetch(history_normal, ppos, 0);
			if (cur_miss != (hist_depth <= 0.0)) {
				reason = 2u;
			} else if (!cur_miss) {
				vec3 q = world_from_depth(params.prev_inv_vp, (vec2(ppos) + 0.5) / vec2(params.size), hist_depth);
				if (distance(p, q) > params.depth_tolerance * distance(p, params.curr_cam_pos.xyz)) {
					reason = 2u;
				}
			}
			if (reason == 0u && length(cur_normal) > 1e-3 && length(hist_n.rgb) > 1e-3 &&
					dot(normalize(cur_normal), normalize(hist_n.rgb)) < params.normal_min_dot) {
				reason = 3u;
			}
			if (reason == 0u) {
				h = min(hist_n.a, params.history_cap);
				hist = history_catmull_rom(prev_uv);
			}
		}
	}

	if (h > 0.0) {
		// Variance clip against the current frame's 3x3 neighbourhood (stops trails from
		// reflections and glass, whose surface does not move but whose image does).
		vec3 m1 = vec3(0.0);
		vec3 m2 = vec3(0.0);
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				ivec2 nb = clamp(pos + ivec2(dx, dy), ivec2(0), params.size - 1);
				vec3 c = rgb_to_ycocg(compress(imageLoad(current_color, nb).rgb));
				m1 += c;
				m2 += c * c;
			}
		}
		vec3 mean = m1 / 9.0;
		vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
		vec3 hc = clamp(rgb_to_ycocg(compress(hist)), mean - params.clamp_gamma * sigma, mean + params.clamp_gamma * sigma);
		hist = expand(ycocg_to_rgb(hc));
	}

	float n = params.current_samples;
	vec3 blended = (n * cur + h * hist) / (n + h);
	float count = min(n + h, params.history_cap);

	if (params.debug_mask != 0u) {
		// Green accepted, yellow off-screen/no history, red depth or miss mismatch, blue normal.
		// Divided by the exposure so the tonemapped mask reads at half brightness.
		vec3 mask = reason == 0u ? vec3(0.0, 1.0, 0.0) : (reason == 1u ? vec3(1.0, 1.0, 0.0) : (reason == 2u ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0)));
		blended = mask * 0.5 / max(params.exposure, 1e-4);
	}

	imageStore(blend_color, pos, vec4(blended, 1.0));
	imageStore(blend_depth, pos, vec4(cur_depth));
	imageStore(blend_normal, pos, vec4(cur_normal, count));
}
```

Check: `grep -n -w 'active\|filter\|input\|output\|sample\|common\|partition\|resource' servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl` returns nothing outside comments.

- [ ] **Step 4: Write the effect class**

Create `servers/rendering/renderer_rd/effects/pt_temporal.h` (licence header as in `local_highlight.h`):

```cpp
#pragma once

#include "core/math/projection.h"
#include "core/math/vector3.h"
#include "servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Temporal reuse for the path tracer's accumulate route (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md). Owns the blend pass and
// two ping-pong history sets on the render buffers (scope "pt_temporal"). The caller keeps the
// frame-to-frame state in RTViewportState::temporal (PTTemporalState) and passes read_index.
class PTTemporal {
	struct Params { // std140, mirrors pt_temporal.glsl
		float curr_inv_vp[16];
		float prev_vp[16];
		float prev_inv_vp[16];
		float curr_cam_pos[4];
		int32_t size[2];
		float exposure;
		float clamp_gamma;
		float current_samples;
		float history_cap;
		uint32_t history_valid;
		uint32_t debug_mask;
		float depth_tolerance;
		float normal_min_dot;
		float pad[2];
	};
	static_assert(sizeof(Params) == 256, "PTTemporal::Params must match the std140 block in pt_temporal.glsl");

	PtTemporalShaderRD shader;
	RID shader_version;
	RID pipeline;
	RID params_buffer;

	void _ensure_history(Ref<RenderSceneBuffersRD> p_render_buffers, const Size2i &p_size);

public:
	struct Inputs {
		RID current_color; // rt_accum, RGBA32F
		RID current_depth; // rt_depth, R32F
		RID current_normal; // rt_accum_normal, RGBA16F
		Projection curr_vp; // depth-corrected, as render_raytracing.cpp builds curr_vp_unjittered
		Projection prev_vp;
		Vector3 curr_cam_pos;
		uint32_t read_index = 0;
		bool history_valid = false;
		float exposure = 1.0f;
		float clamp_gamma = 1.0f;
		float current_samples = 1.0f;
		float history_cap = 0.0f;
		bool debug_mask = false;
	};

	PTTemporal();
	~PTTemporal();

	// Blends into history set 1 - read_index and returns its colour texture (RGBA32F, alpha 1),
	// which the OIDN step reads in place of rt_accum. Invalid RID: nothing was dispatched.
	RID process(Ref<RenderSceneBuffersRD> p_render_buffers, const Inputs &p_in);
};

} // namespace RendererRD
```

Create `servers/rendering/renderer_rd/effects/pt_temporal.cpp` (licence header):

```cpp
#include "pt_temporal.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#define RB_SCOPE_PT_TEMPORAL SNAME("pt_temporal")

namespace RendererRD {

static const StringName &_hist_name(int p_kind, uint32_t p_index) {
	static const StringName names[3][2] = {
		{ StringName("hist_color_0"), StringName("hist_color_1") },
		{ StringName("hist_depth_0"), StringName("hist_depth_1") },
		{ StringName("hist_normal_0"), StringName("hist_normal_1") },
	};
	return names[p_kind][p_index & 1u];
}

PTTemporal::PTTemporal() {
	Vector<String> modes;
	modes.push_back("\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	pipeline = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, 0));
	params_buffer = RD::get_singleton()->uniform_buffer_create(sizeof(Params));
}

PTTemporal::~PTTemporal() {
	RD::get_singleton()->free_rid(params_buffer);
	shader.version_free(shader_version);
}

void PTTemporal::_ensure_history(Ref<RenderSceneBuffersRD> p_render_buffers, const Size2i &p_size) {
	const uint32_t usage = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	const RD::DataFormat formats[3] = { RD::DATA_FORMAT_R32G32B32A32_SFLOAT, RD::DATA_FORMAT_R32_SFLOAT, RD::DATA_FORMAT_R16G16B16A16_SFLOAT };
	for (int kind = 0; kind < 3; kind++) {
		for (uint32_t i = 0; i < 2; i++) {
			if (!p_render_buffers->has_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(kind, i))) {
				p_render_buffers->create_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(kind, i), formats[kind], usage, RD::TEXTURE_SAMPLES_1, p_size);
			}
		}
	}
}

RID PTTemporal::process(Ref<RenderSceneBuffersRD> p_render_buffers, const Inputs &p_in) {
	ERR_FAIL_COND_V(p_render_buffers.is_null(), RID());
	ERR_FAIL_COND_V(!(p_in.history_cap > 0.0f), RID()); // caller gates on the cap.
	RD *rd = RD::get_singleton();
	ERR_FAIL_COND_V(!rd->texture_is_valid(p_in.current_color) || !rd->texture_is_valid(p_in.current_depth) || !rd->texture_is_valid(p_in.current_normal), RID());

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL_V(material_storage, RID());
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL_V(uniform_set_cache, RID());

	const Size2i size = p_render_buffers->get_internal_size();
	_ensure_history(p_render_buffers, size);
	const uint32_t r = p_in.read_index & 1u;
	const uint32_t w = 1u - r;

	Params params = {};
	MaterialStorage::store_camera(p_in.curr_vp.inverse(), params.curr_inv_vp);
	MaterialStorage::store_camera(p_in.prev_vp, params.prev_vp);
	MaterialStorage::store_camera(p_in.prev_vp.inverse(), params.prev_inv_vp);
	params.curr_cam_pos[0] = p_in.curr_cam_pos.x;
	params.curr_cam_pos[1] = p_in.curr_cam_pos.y;
	params.curr_cam_pos[2] = p_in.curr_cam_pos.z;
	params.size[0] = size.width;
	params.size[1] = size.height;
	params.exposure = p_in.exposure > 0.0f ? p_in.exposure : 1.0f;
	params.clamp_gamma = p_in.clamp_gamma;
	params.current_samples = MAX(p_in.current_samples, 1.0f);
	params.history_cap = p_in.history_cap;
	params.history_valid = p_in.history_valid ? 1u : 0u;
	params.debug_mask = p_in.debug_mask ? 1u : 0u;
	params.depth_tolerance = 0.02f;
	params.normal_min_dot = 0.9f;
	rd->buffer_update(params_buffer, 0, sizeof(Params), &params);

	RID linear = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID hist_color = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(0, r));
	RID hist_depth = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(1, r));
	RID hist_normal = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(2, r));
	RID out_color = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(0, w));
	RID out_depth = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(1, w));
	RID out_normal = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(2, w));

	RID sh = shader.version_get_shader(shader_version, 0);
	ERR_FAIL_COND_V(sh.is_null(), RID());
	RD::Uniform u0(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear, hist_color }));
	RD::Uniform u1(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest, hist_depth }));
	RD::Uniform u2(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest, hist_normal }));
	RD::Uniform u3(RD::UNIFORM_TYPE_IMAGE, 3, p_in.current_color);
	RD::Uniform u4(RD::UNIFORM_TYPE_IMAGE, 4, p_in.current_depth);
	RD::Uniform u5(RD::UNIFORM_TYPE_IMAGE, 5, p_in.current_normal);
	RD::Uniform u6(RD::UNIFORM_TYPE_IMAGE, 6, out_color);
	RD::Uniform u7(RD::UNIFORM_TYPE_IMAGE, 7, out_depth);
	RD::Uniform u8(RD::UNIFORM_TYPE_IMAGE, 8, out_normal);
	RD::Uniform u9(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, params_buffer);

	rd->draw_command_begin_label("PT Temporal Reuse");
	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u0, u1, u2, u3, u4, u5, u6, u7, u8, u9), 0);
	rd->compute_list_dispatch_threads(compute_list, size.width, size.height, 1);
	rd->compute_list_end();
	rd->draw_command_end_label();
	return out_color;
}

} // namespace RendererRD
```

- [ ] **Step 5: Build and run the tests**

Run (PowerShell): `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Select-Object -Last 4`
Expected: `scons: done building targets.` (`pt_temporal.glsl.gen.h` generated; the class compiles though nothing calls it yet).
Run (Bash): `bin/godot.windows.editor.x86_64.console.exe --test --test-case="*Temporal*" 2>&1 | tail -3`
Expected: `14 passed | 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl servers/rendering/renderer_rd/effects/pt_temporal.h servers/rendering/renderer_rd/effects/pt_temporal.cpp tests/servers/rendering/test_pt_temporal.cpp
git commit -m "feat(pt): PTTemporal blend pass -- reproject, reject, clamp, blend by sample count"
```

---

### Task 3: Engine integration, off-path proof, first render

**Files:**
- Modify: `servers/rendering/rendering_server.cpp` (after the `adaptive_min_samples` GLOBAL_DEF, ~line 3886)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.h` (include + `RTViewportState::temporal`)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp` (~line 4367, the `RT_PARAM_ACCUM_FRAMES` line)
- Modify: `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h` (~line 842, member) and `.cpp` (constructor ~6797, destructor ~6831, `_oidn_final_denoise_accumulator` ~1992, call site ~3295)

**Interfaces:**
- Consumes: `PTTemporalState` (Task 1), `RendererRD::PTTemporal::Inputs` / `process()` (Task 2).
- Produces: project settings `rendering/pathtracer/temporal_history_samples`, `temporal_clamp_gamma`, `temporal_debug`; log line `[PT-TEMPORAL] fire N: WxH history=0|1 read=R cap=C gamma=G`.

- [ ] **Step 1: Register the settings**

In `servers/rendering/rendering_server.cpp`, after the `adaptive_min_samples` GLOBAL_DEF:

```cpp
	// Temporal reuse (spec 2026-10-10-video-temporal-reuse-design.md): each delivered frame of the
	// accumulate route is blended with the previous frames before OIDN. The cap is how many
	// samples the history may count for; 0 = off (byte-identical to no reuse). The video route
	// sets 48. The gamma is the width of the 3x3 neighbourhood clamp in standard deviations.
	GLOBAL_DEF(PropertyInfo(Variant::INT, "rendering/pathtracer/temporal_history_samples", PROPERTY_HINT_RANGE, "0,1024,1"), 0);
	GLOBAL_DEF(PropertyInfo(Variant::FLOAT, "rendering/pathtracer/temporal_clamp_gamma", PROPERTY_HINT_RANGE, "0.25,4.0,0.05"), 1.0);
	// Debug: the blend writes an accept/reject mask instead of the image (green accepted, yellow
	// off-screen or no history, red depth/miss mismatch, blue normal).
	GLOBAL_DEF(PropertyInfo(Variant::BOOL, "rendering/pathtracer/temporal_debug"), false);
```

- [ ] **Step 2: Add the state to RTViewportState**

In `render_raytracing.h`, add `#include "servers/rendering/renderer_rd/effects/pt_temporal_state.h"` with the other includes, and inside `struct RTViewportState`, after `bool relief_applied_to_current = false;`:

```cpp
	// Temporal reuse (spec 2026-10-10-video-temporal-reuse-design.md): history bookkeeping. Kept
	// apart from the accumulator fields above, whose reset runs every video frame.
	PTTemporalState temporal;
```

- [ ] **Step 3: Continue the sample sequence while the reuse is on**

In `render_raytracing.cpp`, replace

```cpp
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_ACCUM_FRAMES] = float(p_state->accum_frame + zr_seed_offset());
```

with

```cpp
		// Temporal reuse: each delivered frame continues the Sobol sequence (frame k traces points
		// k*target..k*target+target-1) so its pixel-filter jitter lands in new places and edges
		// converge across frames. 0 while the reuse is off: byte-identical to before.
		const uint32_t temporal_offset = PTTemporalState::sample_offset(p_state->temporal.frames_denoised,
				(uint32_t)MAX(0.0f, rt_ubo.params[SceneShaderRaytracing::RT_PARAM_ACCUM_TARGET]),
				(int)GLOBAL_GET("rendering/pathtracer/temporal_history_samples"));
		rt_ubo.params[SceneShaderRaytracing::RT_PARAM_ACCUM_FRAMES] = float(p_state->accum_frame + zr_seed_offset() + temporal_offset);
```

(`RT_PARAM_ADAPTIVE_SAMPLE` a few lines below keeps `float(p_state->accum_frame)`: leave it.)

- [ ] **Step 4: Own the effect**

In `render_forward_clustered.h`: `#include "servers/rendering/renderer_rd/effects/pt_temporal.h"` next to the `local_highlight.h` include, and after `RendererRD::LocalHighlight *local_highlight = nullptr;`:

```cpp
	RendererRD::PTTemporal *pt_temporal = nullptr;
```

In `render_forward_clustered.cpp`, after `local_highlight = memnew(RendererRD::LocalHighlight);`:

```cpp
	pt_temporal = memnew(RendererRD::PTTemporal);
```

and after the `local_highlight` memdelete block in the destructor:

```cpp
	if (pt_temporal) {
		memdelete(pt_temporal);
		pt_temporal = nullptr;
	}
```

- [ ] **Step 5: Let the OIDN step read the blend**

In `_oidn_final_denoise_accumulator`, add a last parameter `RID p_color_source` to the signature (no default) and replace

```cpp
		const RID accum_rid = p_rb_data->rt_get_accum_texture();
```

with

```cpp
		// Temporal reuse hands over its blend (RGBA32F, alpha 1, same layout); else rt_accum.
		const RID accum_rid = p_color_source.is_valid() ? p_color_source : p_rb_data->rt_get_accum_texture();
```

- [ ] **Step 6: Run the blend at the call site**

At the call site (`_oidn_final_denoise_accumulator(rb_data.ptr(), rb, rt_state, rt_oidn_active, rt_accum_target);`), replace that one line with:

```cpp
		// Temporal reuse (spec 2026-10-10-video-temporal-reuse-design.md). Same gate as the
		// helper's own fire test, so it runs exactly once per delivered frame, and only where OIDN
		// fires (never on the daylight probe's raw-accumulator viewport).
		RID temporal_color;
		const int temporal_cap = (int)GLOBAL_GET("rendering/pathtracer/temporal_history_samples");
		if (rt_state && temporal_cap <= 0) {
			rt_state->temporal.invalidate();
		} else if (rt_state && pt_temporal && !rt_state->oidn_denoise_done && rt_state->accum_enabled &&
				rt_state->accum_frame >= rt_accum_target && rb_data->rt_has_depth_texture() &&
				rb_data->rt_has_accum_normal_texture() && p_render_data->scene_data) {
			Projection correction;
			correction.set_depth_correction(true);
			const Projection curr_vp = (correction * p_render_data->scene_data->cam_projection) *
					Projection(p_render_data->scene_data->cam_transform.affine_inverse());
			const bool history_valid = rt_state->temporal.begin_frame(rb->get_internal_size());
			RendererRD::PTTemporal::Inputs in;
			in.current_color = rb_data->rt_get_accum_texture();
			in.current_depth = rb_data->rt_get_depth_texture();
			in.current_normal = rb_data->rt_get_accum_normal_texture();
			in.curr_vp = curr_vp;
			in.prev_vp = rt_state->temporal.prev_vp;
			in.curr_cam_pos = p_render_data->scene_data->cam_transform.origin;
			in.read_index = rt_state->temporal.read_index;
			in.history_valid = history_valid;
			in.exposure = p_render_data->environment.is_valid() ? environment_get_exposure(p_render_data->environment) : 1.0f;
			in.clamp_gamma = (float)GLOBAL_GET("rendering/pathtracer/temporal_clamp_gamma");
			in.current_samples = float(rt_accum_target);
			in.history_cap = float(temporal_cap);
			in.debug_mask = (bool)GLOBAL_GET("rendering/pathtracer/temporal_debug");
			temporal_color = pt_temporal->process(rb, in);
			if (temporal_color.is_valid()) {
				static int s_temporal_logs = 0;
				if (s_temporal_logs < 8) {
					s_temporal_logs++;
					print_line(vformat("[PT-TEMPORAL] fire %d: %dx%d history=%d read=%d cap=%d gamma=%s",
							(int)rt_state->temporal.frames_denoised, rb->get_internal_size().width, rb->get_internal_size().height,
							(int)history_valid, (int)rt_state->temporal.read_index, temporal_cap, String::num(in.clamp_gamma, 2)));
				}
				rt_state->temporal.end_frame(curr_vp);
			} else {
				rt_state->temporal.invalidate(); // nothing dispatched: no history to build on.
			}
		}
		_oidn_final_denoise_accumulator(rb_data.ptr(), rb, rt_state, rt_oidn_active, rt_accum_target, temporal_color);
```

- [ ] **Step 7: Build and run the unit tests**

Run (PowerShell): `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes 2>&1 | Select-Object -Last 4` -> `scons: done building targets.`
Run (Bash): `bin/godot.windows.editor.x86_64.console.exe --test --test-case="*Temporal*" 2>&1 | tail -3` -> `14 passed | 0 failed`.

- [ ] **Step 8: Prove the off path is byte-identical**

Run from `.superpowers/sdd/2026-10-08-video-parity/` (Bash; `bin_prod/` holds the 9743d7a527-era production binary `76b50bb4ee7c` with its DLLs; `v0_prod` already holds its static render):

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-08-video-parity
tasklist | grep -i godot  # must print nothing
bash run_seg.sh v0_t3 job210_new_kf210_static5.json new 24
grep -c 'Error compiling' v0_t3/run.log  # expect 0
for f in $(cd v0_prod && ls frame*.png | tail -5); do cmp -s v0_prod/$f v0_t3/$f && echo "$f identical" || echo "$f DIFFERENT"; done
bash run_seg.sh v0s_t3 seg_new_full.json new 24
for f in $(cd seg_new && ls frame*.png | tail -12); do cmp -s seg_new/$f v0s_t3/$f && echo "$f identical" || echo "$f DIFFERENT"; done
grep -c 'PT-TEMPORAL' v0_t3/run.log v0s_t3/run.log  # expect 0 and 0
```

Expected: 5/5 and 12/12 identical, no `[PT-TEMPORAL]` lines. If the segment comparison differs, first re-render `seg_new` with `ZR_BIN=$PWD/bin_prod/godot.windows.editor.x86_64.console.exe` to establish whether the moving segment is reproducible on one binary before suspecting the change (memory: pt-render-is-nondeterministic).

- [ ] **Step 9: First render with the reuse on**

Add a scratch hook to `.superpowers/sdd/2026-10-08-video-parity/patch_scratch.py` (after hook 8):

```python
# 9. ZR_TEMPORAL_CAP / ZR_TEMPORAL_GAMMA / ZR_TEMPORAL_DEBUG: temporal reuse settings for tuning.
#    Anchored on the Phase A block's oidn_device line, which comes AFTER the line Task 4 adds
#    (right after the noise threshold), so these overrides win over the route's own value.
patch("video_glb_creation.gd",
      "\t\tProjectSettings.set_setting(\"rendering/pathtracer/oidn_device\", 1) # CUDA (Task 1)\n",
      "\t\tProjectSettings.set_setting(\"rendering/pathtracer/oidn_device\", 1) # CUDA (Task 1)\n"
      "\t\tfor _zr_kv in [[\"ZR_TEMPORAL_CAP\", \"rendering/pathtracer/temporal_history_samples\"], [\"ZR_TEMPORAL_GAMMA\", \"rendering/pathtracer/temporal_clamp_gamma\"], [\"ZR_TEMPORAL_DEBUG\", \"rendering/pathtracer/temporal_debug\"]]:\n"
      "\t\t\tvar _zr_v := OS.get_environment(_zr_kv[0])\n"
      "\t\t\tif _zr_v != \"\":\n"
      "\t\t\t\tProjectSettings.set_setting(_zr_kv[1], _zr_v.to_float() if _zr_kv[0] == \"ZR_TEMPORAL_GAMMA\" else (_zr_v == \"1\" if _zr_kv[0] == \"ZR_TEMPORAL_DEBUG\" else _zr_v.to_int()))\n"
      "\t\t\t\tprint(\"[ZRMEAS] %s=%s\" % [_zr_kv[0], _zr_v])\n",
      "temporal settings", required=False)
```

Dry-run it on copies before rendering: `S=<scratchpad>/pt; rm -rf "$S"; mkdir -p "$S"; cp ../../../pipeline_references/video_render.gd ../../../pipeline_references/video_glb_creation.gd "$S"/; python patch_scratch.py "$S" | grep temporal` -> `patched temporal settings`.

Then render the moving segment with the debug mask and with the reuse on, plus the static job once:

```bash
bash run_seg.sh t3_mask seg_new_full.json new 24 "ZR_TEMPORAL_CAP=48 ZR_TEMPORAL_DEBUG=1"
bash run_seg.sh t3_on seg_new_full.json new 24 "ZR_TEMPORAL_CAP=48"
bash run_seg.sh t3_static job210_new_kf210_static5.json new 24 "ZR_TEMPORAL_CAP=48"
for r in t3_mask t3_on t3_static; do echo "$r $(cat $r/done) errors $(grep -c 'Error compiling' $r/run.log)"; grep 'PT-TEMPORAL' $r/run.log | head -3; done
python - <<'EOF'
import glob
import numpy as np
from PIL import Image
for f in sorted(glob.glob("t3_mask/frame*.png"))[-11:]:
    a = np.asarray(Image.open(f).convert("RGB")).astype(np.int32)
    g = (a[..., 1] > a[..., 0] + 20) & (a[..., 1] > a[..., 2] + 20)
    print(f, "accepted (green) %.1f%%" % (100 * g.mean()))
EOF
```

Expected: no `Error compiling`; every `[PT-TEMPORAL]` line shows `3840x2160` (Review Focus 4); `t3_static` has exactly **one** `[PT-TEMPORAL]` line (Review Focus 5); the mask frames after the first are mostly green (>= 80% accepted) with yellow only along the frame border and red/blue along silhouettes. A mask that is mostly red means a convention mismatch (y flip or depth): stop and fix before Task 4. Open one mask frame and confirm the window region is green (Review Focus 3).

- [ ] **Step 10: Commit**

```bash
git add servers/rendering/rendering_server.cpp servers/rendering/renderer_rd/forward_clustered/render_raytracing.h servers/rendering/renderer_rd/forward_clustered/render_raytracing.cpp servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp
git commit -m "feat(pt): wire temporal reuse into the OIDN step (off by default, byte-identical off)"
```

---

### Task 4: Video route switch and acceptance against the success criteria

**Files:**
- Modify: `pipeline_references/video_glb_creation.gd` (constants near `VIDEO_OIDN_ACCUM_TARGET`, and the Phase A block after `env.set_pathtracing_noise_threshold(0.0)`)
- Create (workspace, git-ignored): `.superpowers/sdd/2026-10-08-video-parity/trail_check.py`, `select_fast.py`

**Interfaces:**
- Consumes: the three settings (Task 3).
- Produces: `const VIDEO_TEMPORAL_HISTORY_SAMPLES := 48` in `video_glb_creation.gd`.

- [ ] **Step 1: Write the acceptance checker first**

Create `.superpowers/sdd/2026-10-08-video-parity/trail_check.py`:

```python
"""Temporal-reuse acceptance (spec 2026-10-10, criteria 3 and 4).

usage: python trail_check.py <run> <baseline 24-spp run> <128-spp reference>
Prints the noise change (noise_decomp's measure) and, per frame against the reference, the error
overall, per class (classes from each reference frame), and the worst 0.1% -- for the run and the
baseline -- then PASS/FAIL lines for: overall noise <= 0.65, edges <= 1.1, error drops overall,
no class worse, worst 0.1% no higher.
"""
import glob
import subprocess
import sys

import numpy as np
from PIL import Image

K = np.array([0.2126, 0.7152, 0.0722], np.float32)
run, base, ref = sys.argv[1:4]


def load(r):
    return [np.asarray(Image.open(f).convert("RGB")).astype(np.float32) @ K for f in sorted(glob.glob(r + "/frame*.png"))[-12:]]


def box(l, r):
    k = 2 * r + 1
    p = np.pad(l, r, mode="edge")
    c = np.pad(np.cumsum(np.cumsum(p, 0), 1), ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / float(k * k)


def classes(l):
    b = box(l, 2)
    g = np.zeros_like(l)
    g[1:-1, 1:-1] = np.maximum(np.abs(b[1:-1, 2:] - b[1:-1, :-2]), np.abs(b[2:, 1:-1] - b[:-2, 1:-1])) / 2.0
    return {"flat": g < 2.0, "edges": g >= 6.0, "dark": l < np.percentile(l, 25), "bright": l > np.percentile(l, 75)}


R, F, B = load(ref), load(run), load(base)
assert len(R) == len(F) == len(B) == 12, (len(R), len(F), len(B))


def errors(X):
    out = {"all": [], "flat": [], "edges": [], "dark": [], "bright": [], "worst": []}
    for x, r in zip(X, R):
        d = np.abs(x - r)
        out["all"].append(np.sqrt((d ** 2).mean()))
        for k, m in classes(r).items():
            out[k].append(np.sqrt((d[m] ** 2).mean()))
        out["worst"].append(np.percentile(d, 99.9))
    return {k: float(np.mean(v)) for k, v in out.items()}


def noise(X):
    acc = {"all": [], "edges": []}
    for t in range(11):
        n = (X[t + 1] - X[t]) - (R[t + 1] - R[t])
        acc["all"].append(np.abs(n).mean())
        acc["edges"].append(np.abs(n[classes(R[t])["edges"]]).mean())
    return {k: float(np.mean(v)) for k, v in acc.items()}


er, eb, nr, nb = errors(F), errors(B), noise(F), noise(B)
print(f"noise change  run all {nr['all']:.2f} edges {nr['edges']:.2f} | baseline all {nb['all']:.2f} edges {nb['edges']:.2f}")
print("error vs ref  " + "  ".join(f"{k} {er[k]:.2f}/{eb[k]:.2f}" for k in er) + "   (run/baseline)")
checks = [
    ("noise all <= 0.65", nr["all"] <= 0.65),
    ("noise edges <= 1.1", nr["edges"] <= 1.1),
    ("error drops overall", er["all"] < eb["all"]),
    ("no class worse", all(er[k] <= eb[k] + 1e-6 for k in ("flat", "edges", "dark", "bright"))),
    ("worst 0.1% no higher", er["worst"] <= eb["worst"] + 1e-6),
]
for name, ok in checks:
    print(("PASS " if ok else "FAIL ") + name)
sys.exit(0 if all(ok for _, ok in checks) else 1)
```

Run it on two existing runs that must FAIL (proves it can fail): `python trail_check.py seg_new seg_new seg_new128` -> exit 1 (`noise all <= 0.65` FAIL, `error drops overall` FAIL).

- [ ] **Step 2: Turn the reuse on in the video route**

In `pipeline_references/video_glb_creation.gd`, after the `const VIDEO_OIDN_CLAMP_INDIRECT` line:

```gdscript
# Temporal reuse (spec docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md): each
# delivered frame is blended with the previous ones before OIDN, the history counting for up to
# this many samples. Job 210, keyframes 204-215, 24 spp: <fill in from Step 4's measured numbers
# before committing>.
const VIDEO_TEMPORAL_HISTORY_SAMPLES := 48
```

and in the Phase A block, right after `env.set_pathtracing_noise_threshold(0.0)` (in the scratch copies this line is rewritten by hook 8; edit the repo file, where it is literal):

```gdscript
		ProjectSettings.set_setting("rendering/pathtracer/temporal_history_samples",
				VIDEO_TEMPORAL_HISTORY_SAMPLES if _video_denoiser == "oidn" else 0)
```

Note: `patch_scratch.py` hook 8 anchors on `\t\tenv.set_pathtracing_noise_threshold(0.0)\n` and keeps working because the new line follows it.

- [ ] **Step 3: Reproducibility (criterion 2)**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine/.superpowers/sdd/2026-10-08-video-parity
bash run_seg.sh t4_a seg_new_full.json new 24
bash run_seg.sh t4_b seg_new_full.json new 24
for f in $(cd t4_a && ls frame*.png | tail -12); do cmp -s t4_a/$f t4_b/$f && echo "$f identical" || echo "$f DIFFERENT"; done
grep -h 'PT-TEMPORAL' t4_a/run.log | head -3
```

Expected: 12/12 identical; `[PT-TEMPORAL]` lines with `cap=48`.

- [ ] **Step 4: Flicker, error and time on the segment (criteria 3 and 4)**

```bash
python trail_check.py t4_a seg_new seg_new128
python - <<'EOF'
import glob, os, statistics as st
for r in ("seg_new", "t4_a"):
    t = [os.path.getmtime(f) for f in sorted(glob.glob(f"{r}/frame*.png"))]
    print(r, "s per delivered frame", round(st.median([b - a for a, b in zip(t, t[1:])][-11:]), 1))
EOF
python noise_decomp.py t4_a seg_new128
```

Expected: all five PASS lines; `t4_a` <= 43.5 s per delivered frame.

- [ ] **Step 5: The fastest 12 keyframes (criterion 4 repeated)**

Create `.superpowers/sdd/2026-10-08-video-parity/select_fast.py`:

```python
"""Pick the 12 consecutive keyframes of a job where the camera moves most (position + aim),
and write a segment job for them. usage: python select_fast.py <job.json> <out.json>"""
import json
import math
import subprocess
import sys

job = json.load(open(sys.argv[1], encoding="utf-8"))
kfs = job["video_animation"]["keyframes"]


def pose(kf):
    c = kf["threejs_camera_data"]
    p = c["position"]
    t = c.get("target", c.get("lookAt", p))
    return (p["x"], p["y"], p["z"]), (t["x"] - p["x"], t["y"] - p["y"], t["z"] - p["z"])


def step(a, b):
    (pa, da), (pb, db) = pose(a), pose(b)
    move = math.dist(pa, pb)
    na, nb = math.hypot(*da) or 1.0, math.hypot(*db) or 1.0
    turn = math.degrees(math.acos(max(-1.0, min(1.0, sum(x * y for x, y in zip(da, db)) / (na * nb)))))
    return move + 10.0 * turn  # cm + 10 cm per degree


steps = [step(kfs[i], kfs[i + 1]) for i in range(len(kfs) - 1)]
best = max(range(len(kfs) - 11), key=lambda s: sum(steps[s:s + 11]))
print("fastest window starts at keyframe", best, "score", round(sum(steps[best:best + 11]), 1))
subprocess.run([sys.executable, "../../../pipeline_references/tests/video_oidn/make_segment_job.py",
                sys.argv[1], sys.argv[2], "--start", str(best), "--count", "12"], check=True)
```

Then:

```bash
python select_fast.py inputs/job210_new_full.json inputs/seg_fast.json
bash run_seg.sh fast_128 seg_fast.json new 128 "ZR_TEMPORAL_CAP=0"
bash run_seg.sh fast_24 seg_fast.json new 24 "ZR_TEMPORAL_CAP=0"
bash run_seg.sh fast_on seg_fast.json new 24
python trail_check.py fast_on fast_24 fast_128
```

Expected: all five PASS lines (the noise thresholds were set for the slow segment; if only `noise all`/`noise edges` fail here while the three trail checks pass, record the numbers and continue -- the trail checks are this step's criterion).

- [ ] **Step 6: A camera cut is rejected everywhere (Review Focus 2)**

```bash
python - <<'EOF'
import copy, json
j = json.load(open("inputs/job210_new_full.json", encoding="utf-8"))
a = j["video_animation"]
k = a["keyframes"]
a["keyframes"] = [dict(copy.deepcopy(kf), frame=i) for i, kf in enumerate(k[100:106] + [k[300]])]
a["duration_seconds"] = 7 / float(a.get("fps", 60.0))
json.dump(j, open("inputs/seg_cut.json", "w", encoding="utf-8"))
EOF
bash run_seg.sh cut_mask seg_cut.json new 24 "ZR_TEMPORAL_DEBUG=1"
python - <<'EOF'
import glob
import numpy as np
from PIL import Image
f = sorted(glob.glob("cut_mask/frame*.png"))[-1]
a = np.asarray(Image.open(f).convert("RGB")).astype(np.int32)
g = (a[..., 1] > a[..., 0] + 20) & (a[..., 1] > a[..., 2] + 20)
print(f, "accepted after the cut %.2f%%" % (100 * g.mean()))
EOF
```

Expected: accepted < 1% on the last frame (the cut).

- [ ] **Step 7: If any trail check failed -- tune, do not ship**

Re-run Steps 4 and 5 with `"ZR_TEMPORAL_CAP=24"` and with `"ZR_TEMPORAL_GAMMA=0.75"` (one variable at a time), record every result in `results.md`, and stop to show the owner the trade-off (spec: "show the owner the trade-off before anything ships"). Do not change `VIDEO_TEMPORAL_HISTORY_SAMPLES` without the owner's choice.

- [ ] **Step 8: Clips and crops for the owner (criterion 5)**

```bash
python - <<'EOF'
import glob, subprocess
from PIL import Image
FF = "C:/Zlendo2026/ZlenderRender_stage_copy/ffmpeg/bin/ffmpeg.exe"
for a, b, out in (("seg_new", "t4_a", "temporal_compare_slow.mp4"), ("fast_24", "fast_on", "temporal_compare_fast.mp4")):
    fa, fb = sorted(glob.glob(a + "/frame*.png"))[-12:], sorted(glob.glob(b + "/frame*.png"))[-12:]
    for i, (x, y) in enumerate(zip(fa, fb)):
        A, B = Image.open(x).convert("RGB"), Image.open(y).convert("RGB")
        o = Image.new("RGB", (A.width * 2, A.height)); o.paste(A, (0, 0)); o.paste(B, (A.width, 0))
        o.resize((A.width, A.height // 2)).save(f"cmp_{i:03d}.png")
    subprocess.run([FF, "-y", "-loglevel", "error", "-stream_loop", "4", "-framerate", "12", "-i", "cmp_%03d.png",
                    "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", out], check=True)
    print("wrote", out, "(left: today, right: temporal reuse; 12 frames looped at 12 fps)")
EOF
```

Then the 2x crops (glossy table and vase, window edge, an edge the camera uncovers) of delivered frame 7, today vs reuse:

```bash
python - <<'EOF'
import glob
from PIL import Image
a = Image.open(sorted(glob.glob("seg_new/frame*.png"))[-6]).convert("RGB")
b = Image.open(sorted(glob.glob("t4_a/frame*.png"))[-6]).convert("RGB")
boxes = {"table_vase": (1700, 1450, 2300, 1850), "window_edge": (1250, 500, 1650, 900), "uncovered_edge": (2450, 1650, 2850, 2050)}
for name, bx in boxes.items():
    w, h = bx[2] - bx[0], bx[3] - bx[1]
    o = Image.new("RGB", (4 * w, 2 * h))
    o.paste(a.crop(bx).resize((2 * w, 2 * h), Image.NEAREST), (0, 0))
    o.paste(b.crop(bx).resize((2 * w, 2 * h), Image.NEAREST), (2 * w, 0))
    o.save(f"temporal_crop_{name}.png")
    print("wrote", f"temporal_crop_{name}.png", "(left today, right reuse)")
EOF
```

Look at each crop before sending (a box that misses its subject in this camera pose gets moved, by looking at the full frame). Copy the two clips and three crops to the repo root and send them to the owner with SendUserFile.

- [ ] **Step 9: Record and commit**

Fill the measured numbers into the `VIDEO_TEMPORAL_HISTORY_SAMPLES` comment (replace the `<fill in ...>` text with the Step 4 line: noise all / edges, s per frame) and append a "Temporal reuse" section to `results.md` with every Step 3-7 number.

```bash
git add pipeline_references/video_glb_creation.gd
git commit -m "feat(video): temporal reuse on for the OIDN video route (cap 48)"
```

---

### Task 5: Ship preparation

**Files:**
- Modify: `pipeline_references/production_root/README.md` (shipping table + measurements)
- Modify: `docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md` (Status line + a "Measured" section)

**Interfaces:**
- Consumes: Task 4's numbers.
- Produces: shipping instructions for the owner.

- [ ] **Step 1: Confirm production-copy parity**

```bash
cd /c/Users/aiadmin/Desktop/Engine_Build_test/Zreal_Engine
P=/c/Zlendo2026/ZlenderRender_stage_copy/godot_project
diff <(tr -d '\r' < pipeline_references/video_glb_creation.gd) <(tr -d '\r' < $P/video_glb_creation.gd) | grep '^[<>]' | grep -v '^<\s*#' | head -40
md5sum bin/godot.windows.editor.x86_64.exe
```

Expected: only the 2026-10-08 fixes and the two temporal lines differ (the owner may already have shipped 628905059f; then only the temporal lines).

- [ ] **Step 2: Update the README**

Append to `pipeline_references/production_root/README.md` (the numbers come from the `results.md` "Temporal reuse" section written in Task 4 Step 9; the binary md5 from Step 1):

```markdown
## 2026-10-10: temporal reuse (less flicker when the camera moves)

Copy over the production counterparts:

| From (this repo) | To (production) |
|---|---|
| `bin/godot.windows.editor.x86_64.exe` (md5 ...) | `godot/bin/godot.windows.editor.x86_64.exe` |
| `bin/godot.windows.editor.x86_64.console.exe` | `godot/bin/godot.windows.editor.x86_64.console.exe` |
| `pipeline_references/video_glb_creation.gd` | `godot_project/video_glb_creation.gd` |

Keep production's DLLs (OIDN, Streamline) as they are. The engine change does nothing unless
`video_glb_creation.gd` turns it on, so the binary alone changes no output.

Measured on job 210 (4K, 24 spp, camera moving):

| | s per frame | flicker overall / edges | error vs 128 spp |
|---|---|---|---|
| before | 41.4 | 0.97 / 1.84 | 1.82 |
| with temporal reuse | ... | ... / ... | ... |

To turn it off: set `VIDEO_TEMPORAL_HISTORY_SAMPLES := 0` in `video_glb_creation.gd`.
```

Fill every `...` from `results.md`; production runs `godot/bin/godot.windows.editor.x86_64.console.exe` (main.py GODOT_BIN_DIR).

- [ ] **Step 3: Close the spec**

Set the spec's Status line to "landed <date> ... (commits ...)" and append "## Measured" with Task 4's tables.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/production_root/README.md docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md
git commit -m "docs(ship): temporal reuse -- shipping notes and measurements"
```
