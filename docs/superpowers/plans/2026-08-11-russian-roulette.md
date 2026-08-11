# Russian Roulette Path Termination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terminate low-throughput paths stochastically and scale the survivors by `1/p`, so the average path gets shorter without biasing the estimator.

**Architecture:** A `min_bounce` threshold travels from a project setting into the raytracing specialization-constant word, where the shader reads it as a compile-time constant. A single block in `shade_and_bounce` applies the roulette after the throughput update.

**Tech Stack:** C++17 (Godot 4.7 fork), GLSL 4.5 (Vulkan RD ray tracing), SCons, doctest.

**Spec:** `docs/superpowers/specs/2026-08-11-russian-roulette-design.md` — read §3.1a before Task 1; it explains why this is a project setting and not an `Environment` property.

## Global Constraints

- **Build command**, always FOREGROUND and BLOCKING, never backgrounded:
  `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes`
  The shell tool caps at 10 minutes and a cold build exceeds that — if cut off, **run the same command again**; object files persist and each run makes progress. Only stop if the build FAILS with errors.
- **`tests=yes` is mandatory** on every build.
- **Every new test `.cpp` under `tests/` MUST contain `TEST_FORCE_LINK(<file basename>)`** immediately after `#include "tests/test_macros.h"`, or the link fails with `unresolved external symbol force_link_test_<basename>`.
- **Editing any `.glsl` requires a full scons build** so `*.glsl.gen.h` regenerate. Never hand-edit a `.gen.h`; they are gitignored.
- **Do not edit `C:\Zlendo2026\ZlenderRender_stage_copy\`.** Pipeline script changes go in `pipeline_references/` only.
- **Godot style:** tabs, `p_` prefix on parameters, `r_` on out-params, Godot copyright header on new files (canonical copy: `tests/servers/rendering/test_pt_accumulator.cpp` lines 1-29).
- **Do not `git add -A` or `git add .`.** Stage only files you deliberately changed.
- **`max_component` does not exist in this codebase.** Write `max(max(x.r, x.g), x.b)` inline, as `effects/smaa_edge_detection.glsl:86` does.
- **The C++ and GLSL halves of the flags word are hand-maintained twins.** `scene_shader_raytracing.h` and `raytracing_common_inc.glsl` must agree on every shift and mask, or the shader silently reads the wrong field.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `servers/rendering/rendering_server.cpp` | Modify | Register the `russian_roulette_min_bounce` project setting |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` | Modify | `RT_MIN_BOUNCE_SHIFT`/`MASK`, `rt_flags_pack` gains the field |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp` | Modify | `compute_rt_flags` reads the setting and passes it through |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl` | Modify | `RT_GET_MIN_BOUNCE()` — the GLSL twin |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Modify | The Russian Roulette block itself |
| `tests/servers/rendering/test_pt_russian_roulette.cpp` | **Create** | Bit-packing round-trip and RR estimator math |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Modify | Close out B4, record measurements and the compatibility note |

---

### Task 1: Carry `min_bounce` into the shader

Nothing reads the value yet, so **this task must not change the rendered image.**

**Files:**
- Modify: `servers/rendering/rendering_server.cpp:3832` (beside the other `rendering/pathtracer/*` settings)
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:86-121`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp:641-669`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl:14-21`
- Create: `tests/servers/rendering/test_pt_russian_roulette.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - C++ `SceneShaderRaytracing::RT_MIN_BOUNCE_SHIFT = 4`, `RT_MIN_BOUNCE_MASK = 0x1F`
  - C++ `rt_flags_pack(uint32_t p_flags, uint32_t p_sample_count, uint32_t p_max_bounces, uint32_t p_min_bounce)`
  - GLSL `RT_GET_MIN_BOUNCE()` → `uint`, the resolved `min_bounce` (0-16)
  - Project setting `rendering/pathtracer/russian_roulette_min_bounce`, default 3

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_russian_roulette.cpp`. Copy the 30-line Godot copyright header verbatim from `tests/servers/rendering/test_pt_accumulator.cpp:1-29`, changing only the filename on line 2. Then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_russian_roulette)

#include "core/math/math_funcs.h"

namespace TestPTRussianRoulette {

// CPU mirrors of the specialization-flags packing in
// servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h and
// its GLSL twin RT_GET_MIN_BOUNCE() in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl.
//
// These two are hand-maintained twins. If a shift or mask drifts, the shader
// reads a different field than the CPU wrote and Russian Roulette silently uses
// the wrong threshold -- the image stays plausible and no other test fails.
// This is the only check that catches that.

static const uint32_t RT_SAMPLE_COUNT_SHIFT = 20;
static const uint32_t RT_SAMPLE_COUNT_MASK = 0xFF;
static const uint32_t RT_MAX_BOUNCES_SHIFT = 28;
static const uint32_t RT_MAX_BOUNCES_MASK = 0xF;
static const uint32_t RT_MIN_BOUNCE_SHIFT = 4;
static const uint32_t RT_MIN_BOUNCE_MASK = 0x1F;

// Mirror of rt_flags_pack().
static uint32_t flags_pack(uint32_t p_flags, uint32_t p_sample_count, uint32_t p_max_bounces, uint32_t p_min_bounce) {
	uint32_t result = p_flags;
	result |= (p_sample_count & RT_SAMPLE_COUNT_MASK) << RT_SAMPLE_COUNT_SHIFT;
	result |= (MAX(1u, MIN(16u, p_max_bounces)) - 1u) << RT_MAX_BOUNCES_SHIFT;
	// Biased by +1 so stored 0 means "unset". 0 is a LEGITIMATE min_bounce
	// (roulette from the first bounce), so it cannot double as the sentinel.
	result |= ((MIN(16u, p_min_bounce) + 1u) & RT_MIN_BOUNCE_MASK) << RT_MIN_BOUNCE_SHIFT;
	return result;
}

// Mirror of RT_GET_MIN_BOUNCE().
static uint32_t get_min_bounce(uint32_t p_rt_flags) {
	const uint32_t stored = (p_rt_flags >> RT_MIN_BOUNCE_SHIFT) & RT_MIN_BOUNCE_MASK;
	return (stored == 0u) ? 3u : (stored - 1u);
}

// Mirror of RT_GET_MAX_BOUNCES().
static uint32_t get_max_bounces(uint32_t p_rt_flags) {
	return ((p_rt_flags >> RT_MAX_BOUNCES_SHIFT) & RT_MAX_BOUNCES_MASK) + 1u;
}

// Mirror of RT_GET_SAMPLE_COUNT().
static uint32_t get_sample_count(uint32_t p_rt_flags) {
	return MAX(1u, (p_rt_flags >> RT_SAMPLE_COUNT_SHIFT) & RT_SAMPLE_COUNT_MASK);
}

TEST_CASE("[PathTracer][RussianRoulette] min_bounce round-trips through the flags word") {
	for (uint32_t mb = 0; mb <= 16; mb++) {
		const uint32_t packed = flags_pack(0u, 64u, 8u, mb);
		CHECK(get_min_bounce(packed) == mb);
	}
}

TEST_CASE("[PathTracer][RussianRoulette] stored zero resolves to the default of 3") {
	// A flags word with the min_bounce field never written -- the state a caller
	// that predates this field would produce.
	const uint32_t packed = 0u;
	CHECK(get_min_bounce(packed) == 3u);
}

TEST_CASE("[PathTracer][RussianRoulette] min_bounce does not collide with its neighbours") {
	// Feature flags occupy bits 0-3, sample count 20-27, max bounces 28-31.
	// Writing min_bounce must leave all three intact, and writing them must
	// leave min_bounce intact.
	const uint32_t feature_flags = 0xFu; // all four feature bits set
	for (uint32_t mb = 0; mb <= 16; mb++) {
		const uint32_t packed = flags_pack(feature_flags, 255u, 16u, mb);
		CHECK((packed & 0xFu) == feature_flags);
		CHECK(get_sample_count(packed) == 255u);
		CHECK(get_max_bounces(packed) == 16u);
		CHECK(get_min_bounce(packed) == mb);
	}
}

TEST_CASE("[PathTracer][RussianRoulette] min_bounce occupies only bits 4-8") {
	// The field is 5 bits wide. Anything outside that range must stay clear when
	// only min_bounce is written.
	for (uint32_t mb = 0; mb <= 16; mb++) {
		const uint32_t packed = flags_pack(0u, 0u, 1u, mb);
		CHECK((packed & ~(RT_MIN_BOUNCE_MASK << RT_MIN_BOUNCE_SHIFT)) == 0u);
	}
}

} // namespace TestPTRussianRoulette
```

- [ ] **Step 2: Build and run the new tests**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*RussianRoulette*"
```

Expected: 4 cases pass. As in earlier phases of this project, the C++ mirror is both the specification and the code under test — the C++ and GLSL are brought into agreement in Steps 3-5 and checked against the mirror by eye.

- [ ] **Step 3: Register the project setting**

In `servers/rendering/rendering_server.cpp`, immediately after the existing `rendering/pathtracer/multimesh_merged_blas_max_triangles` line (~`:3838`), add:

```cpp
	// Russian Roulette (roadmap B4): paths shorter than this many bounces are never
	// terminated, so direct light and the first indirect bounces are never rouletted.
	// 3 matches Cycles' historical Min Bounces. Setting this >= max_bounces disables
	// Russian Roulette entirely. This is a SPECIALIZATION CONSTANT -- changing it
	// recompiles the raytracing pipeline, which is correct for a per-render setting.
	GLOBAL_DEF(PropertyInfo(Variant::INT, "rendering/pathtracer/russian_roulette_min_bounce", PROPERTY_HINT_RANGE, "0,16,1"), 3);
```

Use `GLOBAL_DEF`, not `GLOBAL_DEF_RST` — no restart is needed, because `compute_rt_flags` reads it with `GLOBAL_GET` every frame and the pipeline recompiles when the flags word changes. This matches `use_shader_execution_reordering` at `:3832`.

- [ ] **Step 4: Add the C++ half of the twin**

In `scene_shader_raytracing.h`, after the `RT_MAX_BOUNCES_MASK` line (~`:90`), add:

```cpp
	// Russian Roulette minimum bounce (roadmap B4). Stored BIASED by +1 so that a
	// stored 0 means "unset" and resolves to the default: 0 is a legitimate
	// min_bounce (roulette from the first bounce), so it cannot double as the
	// sentinel the way PT_PARAM_MAX_DIFFUSE_BOUNCE's 0 does.
	// 5 bits so the range reaches 16 and Russian Roulette can be fully disabled at
	// max_bounces = 16. Bits 4-19 of the flags word are otherwise unused.
	constexpr static uint32_t RT_MIN_BOUNCE_SHIFT = 4;
	constexpr static uint32_t RT_MIN_BOUNCE_MASK = 0x1F;
```

Then replace `rt_flags_pack` (~`:115-121`) with:

```cpp
	static inline uint32_t rt_flags_pack(uint32_t p_flags, uint32_t p_sample_count, uint32_t p_max_bounces, uint32_t p_min_bounce) {
		uint32_t result = p_flags;
		result |= (p_sample_count & RT_SAMPLE_COUNT_MASK) << RT_SAMPLE_COUNT_SHIFT;
		// Max bounces is offset by 1 (0=1 bounce, 15=16 bounces)
		result |= (MAX(1u, MIN(16u, p_max_bounces)) - 1u) << RT_MAX_BOUNCES_SHIFT;
		// Min bounce is offset by 1 so stored 0 can mean "unset" -- see above.
		result |= ((MIN(16u, p_min_bounce) + 1u) & RT_MIN_BOUNCE_MASK) << RT_MIN_BOUNCE_SHIFT;
		return result;
	}
```

**`rt_flags_pack` gains a parameter.** Find every call site (`git grep -n "rt_flags_pack"`) and update it. If a call site has no meaningful `min_bounce`, pass `3` rather than `0` — `0` would mean "roulette from the first bounce" if the bias were ever removed, and 3 is the default this plan ships.

- [ ] **Step 5: Read the setting in `compute_rt_flags`**

In `scene_shader_raytracing.cpp`, in `compute_rt_flags` (`:641`), add the local beside the others and read the setting beside the existing `GLOBAL_GET`:

```cpp
	uint32_t flags = RT_FLAG_NONE;
	uint32_t sample_count = 1;
	uint32_t max_bounces = 8;
	// Russian Roulette threshold (roadmap B4). A project setting rather than an
	// Environment param because pathtracing_params[16] is full and this value is
	// only ever needed CPU-side, to build the specialization constant -- see the
	// spec's section 3.1a.
	uint32_t min_bounce = 3;
```

and immediately after the existing SER block (`:664-666`):

```cpp
	{
		const int raw = (int)GLOBAL_GET("rendering/pathtracer/russian_roulette_min_bounce");
		min_bounce = (uint32_t)CLAMP(raw, 0, 16);
	}
```

then change the return to:

```cpp
	return rt_flags_pack(flags, sample_count, max_bounces, min_bounce);
```

- [ ] **Step 6: Add the GLSL half of the twin**

In `raytracing_common_inc.glsl`, after the `RT_GET_MAX_BOUNCES()` line (`:20`), add:

```glsl
// Russian Roulette minimum bounce (roadmap B4). MUST match RT_MIN_BOUNCE_SHIFT /
// RT_MIN_BOUNCE_MASK in scene_shader_raytracing.h -- these are hand-maintained
// twins and a drift makes the shader read the wrong field with no failing test.
// Stored biased by +1: stored 0 means "unset" and resolves to the default 3,
// because 0 is a legitimate min_bounce (roulette from the first bounce).
#define RT_MIN_BOUNCE_SHIFT 4u
#define RT_MIN_BOUNCE_MASK 0x1Fu
#define RT_GET_MIN_BOUNCE() (((RT_FLAGS >> RT_MIN_BOUNCE_SHIFT) & RT_MIN_BOUNCE_MASK) == 0u ? 3u : ((((RT_FLAGS >> RT_MIN_BOUNCE_SHIFT) & RT_MIN_BOUNCE_MASK)) - 1u))
```

- [ ] **Step 7: Diff the twins by eye**

Read `scene_shader_raytracing.h`'s `RT_MIN_BOUNCE_*` block, `raytracing_common_inc.glsl`'s, and the CPU mirror in `test_pt_russian_roulette.cpp` side by side. Confirm all three agree on: the shift (4), the mask (`0x1F`), the `+1` bias direction, and that stored `0` resolves to `3`. Record in your report that you did this and what you compared — a drift here is invisible at runtime.

- [ ] **Step 8: Build, run the full suite, and confirm the image is unchanged**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: full suite passes with 4 more cases than the previous baseline of 1421.

Then confirm nothing moved. Nothing reads `RT_GET_MIN_BOUNCE()` yet, so the image must be identical:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_sky_rmse_scene.tscn
```

Report the converged mean and compare it against the pre-change build. If it moved, the flags word disturbed something — report it rather than explaining it away.

- [ ] **Step 9: Commit**

```bash
git add servers/rendering/rendering_server.cpp servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp servers/rendering/renderer_rd/shaders/raytracing/raytracing_common_inc.glsl tests/servers/rendering/test_pt_russian_roulette.cpp
git commit -m "feat(pt): carry a Russian Roulette min_bounce into the raytracing flags word"
```

---

### Task 2: Apply the roulette

This task changes the image.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:743-750`
- Modify: `tests/servers/rendering/test_pt_russian_roulette.cpp`

**Interfaces:**
- Consumes: `RT_GET_MIN_BOUNCE()` (Task 1).
- Produces: nothing for later tasks.

- [ ] **Step 1: Write the failing test**

Append to `tests/servers/rendering/test_pt_russian_roulette.cpp`, inside the existing `namespace TestPTRussianRoulette`, before the closing brace:

```cpp
// CPU mirror of the Russian Roulette block in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl.
//
// The property these tests exist to protect is UNBIASEDNESS: terminating a path
// with probability (1 - p) while scaling survivors by 1/p leaves the expected
// contribution unchanged. A wrong 1/p still produces a plausible image -- it just
// converges to the wrong answer, which no convergence test detects.

struct RRResult {
	bool terminated;
	double throughput;
};

// Mirrors: p = min(sqrt(max_component(throughput)), 1.0);
//          if (p <= 0 || rand >= p) terminate; else throughput /= p;
static RRResult rr_apply(double p_throughput, double p_rand, uint32_t p_depth, uint32_t p_min_bounce) {
	RRResult r;
	r.terminated = false;
	r.throughput = p_throughput;
	if (p_depth <= p_min_bounce) {
		return r; // Never rouletted below the threshold.
	}
	const double p = MIN(Math::sqrt(p_throughput), 1.0);
	if (p <= 0.0 || p_rand >= p) {
		r.terminated = true;
		r.throughput = 0.0;
		return r;
	}
	r.throughput = p_throughput / p;
	return r;
}

TEST_CASE("[PathTracer][RussianRoulette] the estimator is unbiased") {
	// Sweep rand uniformly over [0,1) and average the outcome. The mean must come
	// back to the original throughput: survivors scaled by 1/p exactly compensate
	// for the paths that were killed.
	const uint32_t N = 100000;
	for (double t : { 0.01, 0.05, 0.25, 0.5, 0.81 }) {
		double sum = 0.0;
		for (uint32_t i = 0; i < N; i++) {
			const double u = (i + 0.5) / double(N);
			sum += rr_apply(t, u, 8u, 3u).throughput;
		}
		CHECK((sum / double(N)) == doctest::Approx(t).epsilon(0.001));
	}
}

TEST_CASE("[PathTracer][RussianRoulette] paths at or below min_bounce are never terminated") {
	for (uint32_t depth = 0; depth <= 3; depth++) {
		// Throughput near zero and the worst possible roll -- still must survive.
		const RRResult r = rr_apply(1e-6, 0.999999, depth, 3u);
		CHECK(r.terminated == false);
		CHECK(r.throughput == doctest::Approx(1e-6));
	}
	// One bounce past the threshold, the same path is terminated.
	CHECK(rr_apply(1e-6, 0.999999, 4u, 3u).terminated == true);
}

TEST_CASE("[PathTracer][RussianRoulette] a zero-throughput path terminates and never divides") {
	// p == 0 here. A naive `rand > p` test would let rand == 0.0 through and then
	// divide by zero, producing an Inf that the accumulator never washes out.
	const RRResult r = rr_apply(0.0, 0.0, 8u, 3u);
	CHECK(r.terminated == true);
	CHECK(r.throughput == doctest::Approx(0.0));
}

TEST_CASE("[PathTracer][RussianRoulette] bright paths are never terminated and never rescaled") {
	// sqrt(throughput) >= 1 clamps p to 1, so every roll survives with throughput
	// unchanged -- the roulette must cost nothing where it can save nothing.
	for (double t : { 1.0, 4.0, 100.0 }) {
		for (double u : { 0.0, 0.5, 0.999999 }) {
			const RRResult r = rr_apply(t, u, 8u, 3u);
			CHECK(r.terminated == false);
			CHECK(r.throughput == doctest::Approx(t));
		}
	}
}

TEST_CASE("[PathTracer][RussianRoulette] termination probability follows sqrt, not luminance") {
	// Cycles uses sqrt(max_component) deliberately -- it terminates LATER than a
	// naive luminance-based rule, to better match the view transform. An earlier
	// revision of PATH_TRACER_QUALITY_ROADMAP.md specified
	// clamp(luminance, 0.05, 0.95) and that was wrong. This pins the reference.
	// At throughput 0.25, sqrt gives p = 0.5; the naive rule would give 0.25.
	const uint32_t N = 100000;
	uint32_t survived = 0;
	for (uint32_t i = 0; i < N; i++) {
		const double u = (i + 0.5) / double(N);
		if (!rr_apply(0.25, u, 8u, 3u).terminated) {
			survived++;
		}
	}
	CHECK((double(survived) / double(N)) == doctest::Approx(0.5).epsilon(0.01));
}
```

- [ ] **Step 2: Build and run**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*RussianRoulette*"
```

Expected: 9 cases pass (4 from Task 1, 5 new).

- [ ] **Step 3: Add the roulette to the shader**

In `raytracing_closest_hit_common_inc.glsl`, find this existing block (~`:743-750`):

```glsl
	ps.throughput *= brdf_weight;

	if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_glossy_bounce(ps.packed_bounces_flags);
	}
```

Immediately after it — before the `// Hand the next ray back to raygen` comment — insert:

```glsl
	// =================================================================
	// Russian Roulette (roadmap B4).
	// =================================================================
	// Terminates low-throughput paths with probability (1 - p) and scales the
	// survivors by 1/p, so the expected contribution is unchanged and the average
	// path gets shorter.
	//
	// sqrt() is deliberate and matches Cycles (kernel/integrator/path_state.h:296-305):
	// it terminates LATER than naive luminance-based roulette, which better matches
	// the view transform. max_component, NOT luminance -- an earlier revision of
	// PATH_TRACER_QUALITY_ROADMAP.md specified clamp(luminance, 0.05, 0.95) and that
	// was wrong.
	//
	// The bounce counters were incremented just above, so min_bounce = 3 means the
	// first three bounces are never rouletted -- the part of the path carrying the
	// most energy is left alone.
	//
	// Environment NEE for this vertex was already paid further up; that contribution
	// is valid whether or not the path continues. Roulette governs only the
	// continuation, and it scales throughput only -- mis_ray_pdf is a directional
	// density and is unaffected, so no MIS weight changes.
	{
		uint rr_depth = get_total_bounces(ps.packed_bounces_flags);
		if (rr_depth > RT_GET_MIN_BOUNCE()) {
			float rr_p = min(sqrt(max(max(ps.throughput.r, ps.throughput.g), ps.throughput.b)), 1.0);
			// p == 0 is reachable (a fully absorbed path). rng_1d can return exactly
			// 0.0, which a naive `> p` test would let through and then divide by zero,
			// producing an Inf the accumulator never washes out.
			if (rr_p <= 0.0 || rng_1d(rng, RT_PRNG_TERMINATE) >= rr_p) {
				ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
				path_pack(payload, ps);
				return;
			}
			ps.throughput /= rr_p;
		}
	}
```

`RT_PRNG_TERMINATE` is `5u` and was reserved for exactly this in B5 (`raytracing_inc.glsl:258`) — no dimension-block widening is needed and there is no collision with `RT_PRNG_ENV 7u`.

- [ ] **Step 4: Verify the off-by-one against the code, not the comment**

Read `get_total_bounces`, `inc_diffuse_bounce` and `inc_glossy_bounce` in `raytracing_inc.glsl`. Confirm that the increment above raises the *total* counter (bits 0-7) and not only the per-lobe one, and therefore that a path at its first surface hit reaches the roulette block with `rr_depth == 1`. State in your report which value `rr_depth` takes at the first, second, third and fourth surface hit, and confirm that with `min_bounce = 3` the first roulette happens at the fourth. If the answer differs from that, **report it rather than adjusting the comparison to match the comment.**

- [ ] **Step 5: Build and run the full suite**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: full suite passes, 9 cases more than the pre-Task-1 baseline of 1421.

- [ ] **Step 6: Confirm the roulette actually fires**

A roulette that never triggers passes every test above and delivers nothing. Prove it is live before measuring it in Task 3:

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_sky_rmse_scene.tscn
```

Run it twice: once with the project setting at its default of 3, and once with `rendering/pathtracer/russian_roulette_min_bounce` set to 16 (which disables the roulette, since `max_bounces` is at most 16). Report the frame time for both. **If the two are identical, the roulette is not firing** — report that rather than proceeding.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl tests/servers/rendering/test_pt_russian_roulette.cpp
git commit -m "feat(pt): terminate low-throughput paths with Russian Roulette"
```

---

### Task 3: Measure and close out B4

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Measure bias and equal-time RMSE**

Scene: `pipeline_references/tests/pt_sky_rmse_scene.tscn` — it has the occluder depth (courtyard, slatted canopy, spheres) that makes deep paths exist to terminate.

Take the roulette-off baseline by setting the project setting to 16, **not** by reverting the shader — that isolates the roulette from every other change and needs no rebuild. If you do need a shader-level baseline, use `git checkout <rev> -- <path>` and never `git stash` on an already-committed path, which is a silent no-op that made one measurement in the previous phase measure itself.

Two numbers are required, and the second is the one that decides whether this shipped a win:

1. **Bias.** Converged mean over 2000+ accumulated frames, roulette on vs off, matching within run-to-run noise. **Establish the noise band by repeated runs — do not assume it.** The previous phase found a +0.38% offset that looked like noise until three runs showed the spread was 0.04%.
2. **Equal-time RMSE.** The roulette trades variance for speed. Frame time alone is not the metric: if noise rises more than proportionally, that is a loss disguised as a win. Report frame time *and* equal-time RMSE, dividing the sample-count RMSE ratio by `sqrt(time_ratio)` as in the previous phase.

**Report whichever way it comes out.** A measured regression, reported clearly, is a successful outcome for this step. Do not tune the scene until the numbers agree.

- [ ] **Step 2: Update the roadmap**

In `PATH_TRACER_QUALITY_ROADMAP.md`, mark **B4** done and record, factually:

- the measured bias figure and the noise band it was judged against;
- frame time and equal-time RMSE, both;
- that `min_bounce` is a **project setting**, `rendering/pathtracer/russian_roulette_min_bounce`, and therefore **global rather than per-`Environment`** — with the reason (`pathtracing_params[16]` is full; see the spec's §3.1a);
- the compatibility note: **default 3 means the roulette is on for every existing project**, so renders get faster and marginally noisier at equal sample count without anyone opting in. This is the same class of silent change as `pathtracing_max_bounces` 3 → 8 in B3, which the roadmap already documents;
- that setting `min_bounce >= max_bounces` disables the roulette.

Update the ordering summary: **Phase B is complete.** Remaining is Phase C — **C1**, **C2** — then D, E, F.

- [ ] **Step 3: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): record Russian Roulette results and close out B4"
```

---

## Self-Review

**1. Spec coverage.** §2 goals 1-4 map to Task 2 (termination + unbiasedness), Task 2 Step 3's `min_bounce` guard, Task 1 (exposure), and Task 3 Step 1 (equal-time measurement). §3.1's 5-bit biased encoding is Task 1 Steps 4/6 and tested in Task 1 Step 1. §3.1a's project-setting transport is Task 1 Steps 3/5. §3.2's default and compatibility note are Task 1 Step 3 and Task 3 Step 2. §3.3's `sqrt`/`max_component` choice is Task 2 Step 3, pinned by a dedicated test. §4's placement and the `p <= 0` guard are Task 2 Steps 3-4. §5's "no MIS interaction" is recorded in the shader comment. §6's four layers are Task 1. §7's five tests are Tasks 1-2. §8's two acceptance numbers are Task 3 Step 1. §9's limitations are Task 3 Step 2.

**2. Placeholder scan.** No TBD/TODO. Every code step carries literal code; every command is runnable. Three steps deliberately require *verify then report* rather than assume: Task 1 Step 7 (twin agreement), Task 2 Step 4 (the off-by-one), and Task 2 Step 6 (that the roulette fires at all). Each states what to report and forbids adjusting the code to match the comment.

**3. Type consistency.** `rt_flags_pack(uint32_t, uint32_t, uint32_t, uint32_t)` is declared in Task 1's Interfaces, defined in Task 1 Step 4, and called in Task 1 Step 5 with that signature; Step 4 also directs a sweep of every existing call site, since the arity changed. `RT_GET_MIN_BOUNCE()` returns `uint` and is defined in Task 1 Step 6, consumed in Task 2 Step 3. `RT_MIN_BOUNCE_SHIFT = 4` / `RT_MIN_BOUNCE_MASK = 0x1F` appear identically in the C++ (Step 4), the GLSL (Step 6), and the CPU mirror (Task 1 Step 1). `RT_PRNG_TERMINATE` is pre-existing at `5u`. `get_total_bounces`, `set_path_terminated`, `path_pack` and `rng_1d(RNGState, uint)` are all pre-existing and were verified to exist with these signatures before this plan was written.

**One correction made during planning, recorded because it was a real defect.** The spec's §3.1 originally claimed packing `min_bounce` into the flags word meant "no params-UBO change, no parity risk." That was only half true: it solved shader-side *storage* while leaving no channel to carry the value from configuration into `compute_rt_flags`, which reads only the full `pathtracing_params` array. The fix is §3.1a — a project setting, with direct precedent five lines away in the same function. Two consequences follow: the setting is **global rather than per-`Environment`**, which narrows what was originally agreed and is recorded as an accepted trade-off rather than an oversight; and the `Environment` property, ClassDB binding and `Environment.xml` layers drop out of the plan entirely, making Task 1 substantially smaller than the spec first implied.
