# Phase B (B5 + B3): Owen-Scrambled Sobol Sampler and Per-Lobe Bounce Controls — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the path tracer's white-noise PCG sampler with Blender Cycles' Owen-scrambled Sobol-Burley sampler, and replace the hardcoded `MAX_DIFFUSE_BOUNCES 2u` with per-lobe diffuse/glossy bounce limits exposed on `Environment`.

**Architecture:** B5 ports `intern/cycles/kernel/sample/sobol_burley.h` + `sample/util.h` + `util/hash.h` into a new GLSL include, and introduces a Cycles-style `RNGState { pixel, sample_index, offset }` that replaces the mutable `uint rng_state` in the ray payload. Sampling call sites stop drawing from a stream and instead request an explicit *dimension*, which is what makes stratification work. B3 adds two `PT_PARAM` slots (12, 13 — the last two free ones), a glossy-bounce counter in the payload's unused bits 16-23, and the matching `Environment` properties.

**Tech Stack:** C++17 (Godot 4.7 fork), GLSL 4.5 (Vulkan RD ray-tracing stages), SCons, doctest.

## Global Constraints

- **Build command** (always foreground/blocking, never backgrounded):
  `python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes`
- **`tests=yes` is mandatory** for every build in this plan — tasks add doctest cases.
- **Every new test `.cpp` under `tests/` MUST contain `TEST_FORCE_LINK(<file basename>)`** immediately after `#include "tests/test_macros.h"`, or the link fails with `unresolved external symbol force_link_test_<basename>`.
- **Editing any `.glsl` requires a full scons build** so `*.glsl.gen.h` regenerates. Never hand-edit a `.gen.h`.
- **Do not edit `C:\Zlendo2026\ZlenderRender_stage_copy\`.** All pipeline script changes go in `pipeline_references/` only; the user replaces them manually.
- **`PT_PARAM` slot allocation is a hard budget.** `rt_params` is `vec4[4]` = exactly 16 floats. Slots 0-11 and 14-15 are taken. **12 and 13 are the only free slots and this plan consumes both.** Do not add a 17th param without resizing the UBO, `environment_storage.h`'s `float pathtracing_params[16]`, the `rt_ubo` `static_assert(sizeof(rt_ubo) == 48 * sizeof(float))`, and the GLSL `vec4 rt_params[4]` together.
- **Godot code style:** tabs for indentation, `p_` prefix on parameters, `r_` on out-params, Godot copyright header on new files.
- **Cycles parity is the acceptance bar.** Where this plan deliberately diverges from Cycles it says so in a code comment; do not silently "improve" ported math.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl` | **Create** | Pure port of Cycles' Sobol-Burley sampler: direction table, Owen scramble, hashes, `sobol_burley_sample_1D/2D`. No engine types, no bindings. |
| `tests/servers/rendering/test_pt_sobol.cpp` | **Create** | C++ mirror of the above + stratification / range / variance tests. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` | Modify | `RNGState`, dimension constants, payload packing, `rng_1d`/`rng_2d`, bounce-count helpers, filter jitter. |
| `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl` | Modify | RNG init per sample. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl` | Modify | Lobe + direction dimensions, per-bounce dimension advance, per-lobe bounce caps. |
| `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl` | Modify | Light-sample dimension; reservoir loop moved to a decorrelated hash stream. |
| `servers/rendering/rendering_server_enums.h` | Modify | `PT_PARAM_MAX_DIFFUSE_BOUNCE = 12`, `PT_PARAM_MAX_GLOSSY_BOUNCE = 13`. |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h` | Modify | `RT_PARAM_*` mirrors of the two new slots. |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp` | Modify | Raise the `max_bounces` specialization-constant cap 8 → 16. |
| `scene/resources/environment.h` / `.cpp` | Modify | `pathtracing_max_diffuse_bounce` / `_max_glossy_bounce` properties, packing, ClassDB binds. |
| `tests/servers/rendering/test_pt_bounce_limits.cpp` | **Create** | Mirror tests for the bounce bit-packing and the termination rule. |
| `pipeline_references/image_glb_creation.gd` | Modify | Set the new bounce properties on the render Environment. |
| `PATH_TRACER_QUALITY_ROADMAP.md` | Modify | Mark B5/B3 done, record measured convergence numbers. |

---

## Background: what we are porting, and the two divergences

Read this before Task 1. Every citation is a real file in `C:\Users\aiadmin\Desktop\blender_build\blender\`.

**The sampler.** Cycles' default is `SAMPLING_PATTERN_SOBOL_BURLEY` (`intern/cycles/kernel/types.h:122`). Per pixel it computes a scramble seed `rng_pixel = hash_iqnt2d(x, y) ^ seed` (`kernel/sample/pattern.h:143`), then every random draw is `sobol_burley_sample_1D/2D(sample_index, dimension, rng_pixel, mask)` (`kernel/sample/sobol_burley.h:99` and `:126`).

**The critical structural difference from what we have today.** Our `rand(inout uint state)` is a *stream*: each call advances a hash. Cycles' draws are *indexed*: the caller names a dimension. That is not a stylistic difference — it is the entire mechanism. Sobol stratification only holds if "the 2D draw for the BSDF direction" is always dimension set *k* for every path in the frame. A stream cannot guarantee that, because different paths take different branches and therefore consume different numbers of draws. **If you keep a stream and merely swap the hash for Sobol, you get no benefit and possibly visible structured artifacts.**

**Dimension allocation.** Cycles reserves a fixed block of dimensions per bounce: `rng_offset` starts at `PRNG_BOUNCE_NUM` and advances by `PRNG_BOUNCE_NUM` on every bounce (`kernel/integrator/path_state.h:58`, `:241`); within a block, named constants pick the dimension (`kernel/types.h:74-118`). Cycles uses a block of 16; we need far fewer decisions, so we use 8. Earlier dimensions are better stratified (`kernel/sample/pattern.h:20-32`), so the BSDF direction — the highest-variance decision — gets dimension 0 of each block.

**Divergence 1 (deliberate): the light reservoir stays on white noise.** `lights_evaluate_direct_lighting` draws a *variable* number of 1D values (`raytracing_lights_inc.glsl:351` and `:365`, up to `2 * RT_LIGHT_RESERVOIR_SIZE` = 32) because the acceptance draw only happens for lights that pass the range check. Assigning 32 Sobol dimensions per bounce to it would blow up the per-bounce block and spend our best-stratified dimensions on decisions that Cycles does not Sobol-sample either — Cycles' light *tree* descends using a single rescaled random number (`kernel/light/tree.h`). So: the reservoir keeps a PCG stream, but that stream is **seeded from the Sobol state** so it stays decorrelated from everything else. The final light-position sample (`raytracing_lights_inc.glsl:380`) *does* get a real Sobol 2D dimension, because that one is fixed-count and high-variance. Replacing the reservoir wholesale is roadmap item **C2**, not this plan.

**Divergence 2 (deliberate): no sequence-length mask.** Cycles computes `sobol_index_mask = reverse_integer_bits(next_power_of_two(aa_samples - 1) - 1)` (`intern/cycles/scene/integrator.cpp:320`) purely to shorten the inner loop at low sample counts. It is a performance optimization with no effect on the sample values within the block. We pass `0xffffffff` (Cycles' own documented "safe default, least performant" — `kernel/sample/sobol_burley.h:96`) and skip the extra param. Revisit only if profiling shows the raygen loop is hash-bound.

**Bounce limits.** Cycles counts diffuse and glossy bounces separately and terminates the path when the lobe just taken exceeds *its own* cap (`kernel/integrator/path_state.h:183` and `:190`). Blender's shipped defaults are Diffuse 4, Glossy 4, Transmission 12, Total 12 (`intern/cycles/blender/addon/properties.py:765`, `:771`, `:777`). We ship Diffuse 4 / Glossy 4 and raise our total cap from 8 to 16.

**Out of scope, deliberately:** `min_bounce` (no consumer until B4 Russian Roulette) and `max_transmission_bounce` (no transmission path until E1). Both would be dead params today, and there are no free `PT_PARAM` slots to waste on them.

---

### Task 1: Sobol-Burley sampler core (GLSL) + mirrored unit tests

Self-contained mathematical port. Nothing in the renderer calls it yet, so it cannot break a render; it can only fail its own tests.

**Files:**
- Create: `servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl`
- Create: `tests/servers/rendering/test_pt_sobol.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces (GLSL, used by Task 2):
  - `uint sb_hash_iqnt2d(uint p_x, uint p_y)`
  - `uint sb_pcg_owen(uint p_n, uint p_seed)`
  - `float sobol_burley_sample_1D(uint p_index, uint p_dimension, uint p_seed, uint p_mask)`
  - `vec2 sobol_burley_sample_2D(uint p_index, uint p_dimension_set, uint p_seed, uint p_mask)`

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_sobol.cpp`. The Godot copyright header (30 lines) must be copied verbatim from `tests/servers/rendering/test_pt_accumulator.cpp:1-29`; only the filename on line 2 changes to `test_pt_sobol.cpp`. After the header:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_sobol)

#include "core/math/math_funcs.h"

namespace TestPTSobol {

// CPU mirror of servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl.
// These two implementations MUST stay identical — the shader cannot be unit tested
// directly, so this mirror is the only thing standing between a typo in the port and
// a silently wrong sampler. If you touch one, touch the other in the same commit.
//
// Source of truth: Blender Cycles
//   intern/cycles/kernel/sample/sobol_burley.h
//   intern/cycles/kernel/sample/util.h        (reversed_bit_owen)
//   intern/cycles/util/hash.h                 (hash_hp_uint, uint_to_float_excl)

// Direction vectors for the first four Sobol dimensions, bits pre-reversed.
// Verbatim from intern/cycles/kernel/tables.h:81.
static const uint32_t SOBOL_BURLEY_TABLE[4][32] = {
	{
			0x00000001, 0x00000002, 0x00000004, 0x00000008,
			0x00000010, 0x00000020, 0x00000040, 0x00000080,
			0x00000100, 0x00000200, 0x00000400, 0x00000800,
			0x00001000, 0x00002000, 0x00004000, 0x00008000,
			0x00010000, 0x00020000, 0x00040000, 0x00080000,
			0x00100000, 0x00200000, 0x00400000, 0x00800000,
			0x01000000, 0x02000000, 0x04000000, 0x08000000,
			0x10000000, 0x20000000, 0x40000000, 0x80000000,
	},
	{
			0x00000001, 0x00000003, 0x00000005, 0x0000000f,
			0x00000011, 0x00000033, 0x00000055, 0x000000ff,
			0x00000101, 0x00000303, 0x00000505, 0x00000f0f,
			0x00001111, 0x00003333, 0x00005555, 0x0000ffff,
			0x00010001, 0x00030003, 0x00050005, 0x000f000f,
			0x00110011, 0x00330033, 0x00550055, 0x00ff00ff,
			0x01010101, 0x03030303, 0x05050505, 0x0f0f0f0f,
			0x11111111, 0x33333333, 0x55555555, 0xffffffff,
	},
	{
			0x00000001, 0x00000003, 0x00000006, 0x00000009,
			0x00000017, 0x0000003a, 0x00000071, 0x000000a3,
			0x00000116, 0x00000339, 0x00000677, 0x000009aa,
			0x00001601, 0x00003903, 0x00007706, 0x0000aa09,
			0x00010117, 0x0003033a, 0x00060671, 0x000909a3,
			0x00171616, 0x003a3939, 0x00717777, 0x00a3aaaa,
			0x01170001, 0x033a0003, 0x06710006, 0x09a30009,
			0x16160017, 0x3939003a, 0x77770071, 0xaaaa00a3,
	},
	{
			0x00000001, 0x00000003, 0x00000004, 0x0000000a,
			0x0000001f, 0x0000002e, 0x00000045, 0x000000c9,
			0x0000011b, 0x000002a4, 0x0000079a, 0x00000b67,
			0x0000101e, 0x0000302d, 0x00004041, 0x0000a0c3,
			0x0001f104, 0x0002e28a, 0x000457df, 0x000c9bae,
			0x0011a105, 0x002a7289, 0x0079e7db, 0x00b6dba4,
			0x0100011a, 0x030002a7, 0x0400079e, 0x0a000b6d,
			0x1f001001, 0x2e003003, 0x45004004, 0xc900a00a,
	},
};

// GLSL bitfieldReverse().
static uint32_t sb_bit_reverse(uint32_t p_x) {
	p_x = ((p_x & 0x55555555u) << 1) | ((p_x >> 1) & 0x55555555u);
	p_x = ((p_x & 0x33333333u) << 2) | ((p_x >> 2) & 0x33333333u);
	p_x = ((p_x & 0x0f0f0f0fu) << 4) | ((p_x >> 4) & 0x0f0f0f0fu);
	p_x = ((p_x & 0x00ff00ffu) << 8) | ((p_x >> 8) & 0x00ff00ffu);
	return (p_x << 16) | (p_x >> 16);
}

// GLSL 31 - findMSB(). Undefined for 0, same as the shader; callers guard.
static uint32_t sb_clz(uint32_t p_x) {
	uint32_t n = 0;
	while ((p_x & 0x80000000u) == 0) {
		p_x <<= 1;
		n++;
	}
	return n;
}

// Cycles util/hash.h:511.
static uint32_t sb_hash_hp(uint32_t p_i) {
	p_i ^= p_i >> 16;
	p_i *= 0x21f0aaadu;
	p_i ^= p_i >> 15;
	p_i *= 0xd35a2d97u;
	p_i ^= p_i >> 15;
	return p_i ^ 0xe6fe3bebu;
}

// Cycles kernel/sample/util.h:18 (reversed_bit_owen).
static uint32_t sb_pcg_owen(uint32_t p_n, uint32_t p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n += p_seed;
	p_n *= (p_seed >> 16) | 1u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

// Cycles util/hash.h:14 (uint_to_float_excl). The divisor is 4294967808, not 2^32,
// so the result is strictly < 1.0 after float rounding.
static float sb_uint_to_float_excl(uint32_t p_n) {
	return (float)p_n * (1.0f / 4294967808.0f);
}

// Cycles kernel/sample/sobol_burley.h:37.
static float sb_sobol_burley(uint32_t p_rev_bit_index, uint32_t p_dimension, uint32_t p_scramble_seed) {
	uint32_t result = 0;
	if (p_dimension == 0) {
		result = sb_bit_reverse(p_rev_bit_index);
	} else {
		uint32_t i = 0;
		while (p_rev_bit_index != 0) {
			const uint32_t j = sb_clz(p_rev_bit_index);
			result ^= SOBOL_BURLEY_TABLE[p_dimension][i + j];
			i += j + 1;
			p_rev_bit_index <<= j;
			p_rev_bit_index <<= 1;
		}
	}
	result = sb_bit_reverse(sb_pcg_owen(result, p_scramble_seed));
	return sb_uint_to_float_excl(result);
}

static float sobol_burley_sample_1D(uint32_t p_index, uint32_t p_dimension, uint32_t p_seed, uint32_t p_mask) {
	p_seed ^= sb_hash_hp(p_dimension);
	p_index = sb_pcg_owen(sb_bit_reverse(p_index), p_seed ^ 0xbff95bfeu);
	p_index &= p_mask;
	return sb_sobol_burley(p_index, 0, p_seed ^ 0x635c77bdu);
}

static void sobol_burley_sample_2D(uint32_t p_index, uint32_t p_dimension_set, uint32_t p_seed, uint32_t p_mask, float &r_x, float &r_y) {
	p_seed ^= sb_hash_hp(p_dimension_set);
	p_index = sb_pcg_owen(sb_bit_reverse(p_index), p_seed ^ 0xf8ade99au);
	p_index &= p_mask;
	r_x = sb_sobol_burley(p_index, 0, p_seed ^ 0xe0aaaf76u);
	r_y = sb_sobol_burley(p_index, 1, p_seed ^ 0x94964d4eu);
}

// White-noise reference, the sampler we are replacing (raytracing_inc.glsl:159).
static uint32_t pcg_hash(uint32_t p_seed) {
	const uint32_t state = p_seed * 747796405u + 2891336453u;
	const uint32_t word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
	return (word >> 22) ^ word;
}

// Mask for a block of 2^p_log2_count samples, per Cycles integrator.cpp:320:
// reverse_integer_bits(next_power_of_two(n - 1) - 1).
static uint32_t block_mask(int p_log2_count) {
	return sb_bit_reverse((1u << p_log2_count) - 1u);
}

TEST_CASE("[PathTracer][Sobol] 1D samples stay in [0, 1)") {
	const uint32_t seed = 0x1234abcdu;
	for (uint32_t i = 0; i < 4096; i++) {
		const float v = sobol_burley_sample_1D(i, 3, seed, 0xffffffffu);
		CHECK(v >= 0.0f);
		CHECK(v < 1.0f);
	}
}

TEST_CASE("[PathTracer][Sobol] 2D samples stay in [0, 1)") {
	const uint32_t seed = 0x5f356495u;
	for (uint32_t i = 0; i < 4096; i++) {
		float x, y;
		sobol_burley_sample_2D(i, 1, seed, 0xffffffffu, x, y);
		CHECK(x >= 0.0f);
		CHECK(x < 1.0f);
		CHECK(y >= 0.0f);
		CHECK(y < 1.0f);
	}
}

TEST_CASE("[PathTracer][Sobol] first 2^k 1D samples hit every stratum exactly once") {
	// A (0,1)-sequence: the first 2^k points fall one per 1/2^k interval.
	// Owen scrambling and the Burley index shuffle both preserve this.
	// White noise does not, which is the entire point of the change.
	const int k = 6;
	const uint32_t n = 1u << k;
	const uint32_t mask = block_mask(k);

	for (uint32_t seed_i = 0; seed_i < 8; seed_i++) {
		const uint32_t seed = sb_hash_hp(seed_i);
		int hits[64] = {};
		for (uint32_t i = 0; i < n; i++) {
			const float v = sobol_burley_sample_1D(i, 0, seed, mask);
			hits[(int)(v * (float)n)]++;
		}
		for (uint32_t b = 0; b < n; b++) {
			CHECK(hits[b] == 1);
		}
	}
}

TEST_CASE("[PathTracer][Sobol] first 2^k 2D samples hit every grid cell exactly once") {
	// A (0,2)-sequence: for 2^(2m) points every 2^m x 2^m cell holds exactly one.
	const uint32_t n = 256; // 2^8 points over a 16x16 grid.
	const uint32_t mask = block_mask(8);

	for (uint32_t seed_i = 0; seed_i < 8; seed_i++) {
		const uint32_t seed = sb_hash_hp(seed_i);
		int hits[16][16] = {};
		for (uint32_t i = 0; i < n; i++) {
			float x, y;
			sobol_burley_sample_2D(i, 0, seed, mask, x, y);
			hits[(int)(x * 16.0f)][(int)(y * 16.0f)]++;
		}
		for (int cx = 0; cx < 16; cx++) {
			for (int cy = 0; cy < 16; cy++) {
				CHECK(hits[cx][cy] == 1);
			}
		}
	}
}

TEST_CASE("[PathTracer][Sobol] different pixel seeds produce different sequences") {
	// Per-pixel Owen scrambling must decorrelate neighbours, otherwise the whole
	// image shares one point set and the "noise" becomes a visible fixed pattern.
	const uint32_t seed_a = sb_hash_hp(11);
	const uint32_t seed_b = sb_hash_hp(12);
	int identical = 0;
	for (uint32_t i = 0; i < 256; i++) {
		const float a = sobol_burley_sample_1D(i, 0, seed_a, 0xffffffffu);
		const float b = sobol_burley_sample_1D(i, 0, seed_b, 0xffffffffu);
		if (Math::is_equal_approx(a, b)) {
			identical++;
		}
	}
	CHECK(identical < 4);
}

TEST_CASE("[PathTracer][Sobol] different dimensions are decorrelated") {
	const uint32_t seed = sb_hash_hp(7);
	int identical = 0;
	for (uint32_t i = 0; i < 256; i++) {
		const float a = sobol_burley_sample_1D(i, 0, seed, 0xffffffffu);
		const float b = sobol_burley_sample_1D(i, 1, seed, 0xffffffffu);
		if (Math::is_equal_approx(a, b)) {
			identical++;
		}
	}
	CHECK(identical < 4);
}

TEST_CASE("[PathTracer][Sobol] integrates a smooth 2D function far better than white noise") {
	// The actual value proposition: at equal sample count the estimator error is
	// dramatically lower. Integral of x*y over the unit square is 0.25.
	const uint32_t n = 256;
	const uint32_t mask = block_mask(8);
	const uint32_t seed = sb_hash_hp(99);

	double sobol_sum = 0.0;
	for (uint32_t i = 0; i < n; i++) {
		float x, y;
		sobol_burley_sample_2D(i, 0, seed, mask, x, y);
		sobol_sum += (double)x * (double)y;
	}
	const double sobol_err = Math::abs(sobol_sum / (double)n - 0.25);

	double white_sum = 0.0;
	uint32_t state = seed;
	for (uint32_t i = 0; i < n; i++) {
		state = pcg_hash(state);
		const double x = (double)state / 4294967296.0;
		state = pcg_hash(state);
		const double y = (double)state / 4294967296.0;
		white_sum += x * y;
	}
	const double white_err = Math::abs(white_sum / (double)n - 0.25);

	CHECK(sobol_err < 0.002);
	CHECK(sobol_err < white_err);
}

} // namespace TestPTSobol
```

- [ ] **Step 2: Build with tests and run them to verify they fail**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Then:

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*Sobol*"
```

Expected: all 7 cases **pass** on the C++ mirror alone. That is correct and expected — the mirror is the implementation under test at this step. The failing artifact is the *shader*, which does not exist yet and is verified by inspection in Step 4. If any case fails here, the port has a typo; fix the mirror against the Cycles source before continuing.

- [ ] **Step 3: Write the GLSL sampler**

Create `servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl`:

```glsl
// Owen-scrambled, shuffled Sobol sampler ("Practical Hash-based Owen Scrambling",
// Burley 2020), ported verbatim from Blender Cycles:
//   intern/cycles/kernel/sample/sobol_burley.h   (the sampler)
//   intern/cycles/kernel/sample/util.h           (reversed_bit_owen)
//   intern/cycles/util/hash.h                    (hash_hp_uint, hash_iqnt2d, uint_to_float_excl)
//   intern/cycles/kernel/tables.h:81             (direction vectors)
//
// A CPU mirror of this file lives in tests/servers/rendering/test_pt_sobol.cpp and
// carries the unit tests. Change both together or the tests stop meaning anything.
//
// Why this replaces PCG: white noise scatters error into clumps that read as
// splotchy grain and denoise badly. An Owen-scrambled Sobol sequence is stratified,
// so at equal sample count the residual error is fine and even. The property only
// holds if each decision is drawn from a FIXED dimension index every path — see
// RNGState in raytracing_inc.glsl.

// Direction vectors for the first four Sobol dimensions, stored bit-reversed
// (the hash-based Owen scramble needs them reversed anyway).
// Flattened to 1D as [dimension * 32 + i]; only dimensions 0 and 1 are reachable
// through the 1D/2D entry points, 2 and 3 are kept for a future 3D/4D draw.
const uint SOBOL_BURLEY_TABLE[128] = uint[128](
		// Dimension 0.
		0x00000001u, 0x00000002u, 0x00000004u, 0x00000008u,
		0x00000010u, 0x00000020u, 0x00000040u, 0x00000080u,
		0x00000100u, 0x00000200u, 0x00000400u, 0x00000800u,
		0x00001000u, 0x00002000u, 0x00004000u, 0x00008000u,
		0x00010000u, 0x00020000u, 0x00040000u, 0x00080000u,
		0x00100000u, 0x00200000u, 0x00400000u, 0x00800000u,
		0x01000000u, 0x02000000u, 0x04000000u, 0x08000000u,
		0x10000000u, 0x20000000u, 0x40000000u, 0x80000000u,
		// Dimension 1.
		0x00000001u, 0x00000003u, 0x00000005u, 0x0000000fu,
		0x00000011u, 0x00000033u, 0x00000055u, 0x000000ffu,
		0x00000101u, 0x00000303u, 0x00000505u, 0x00000f0fu,
		0x00001111u, 0x00003333u, 0x00005555u, 0x0000ffffu,
		0x00010001u, 0x00030003u, 0x00050005u, 0x000f000fu,
		0x00110011u, 0x00330033u, 0x00550055u, 0x00ff00ffu,
		0x01010101u, 0x03030303u, 0x05050505u, 0x0f0f0f0fu,
		0x11111111u, 0x33333333u, 0x55555555u, 0xffffffffu,
		// Dimension 2.
		0x00000001u, 0x00000003u, 0x00000006u, 0x00000009u,
		0x00000017u, 0x0000003au, 0x00000071u, 0x000000a3u,
		0x00000116u, 0x00000339u, 0x00000677u, 0x000009aau,
		0x00001601u, 0x00003903u, 0x00007706u, 0x0000aa09u,
		0x00010117u, 0x0003033au, 0x00060671u, 0x000909a3u,
		0x00171616u, 0x003a3939u, 0x00717777u, 0x00a3aaaau,
		0x01170001u, 0x033a0003u, 0x06710006u, 0x09a30009u,
		0x16160017u, 0x3939003au, 0x77770071u, 0xaaaa00a3u,
		// Dimension 3.
		0x00000001u, 0x00000003u, 0x00000004u, 0x0000000au,
		0x0000001fu, 0x0000002eu, 0x00000045u, 0x000000c9u,
		0x0000011bu, 0x000002a4u, 0x0000079au, 0x00000b67u,
		0x0000101eu, 0x0000302du, 0x00004041u, 0x0000a0c3u,
		0x0001f104u, 0x0002e28au, 0x000457dfu, 0x000c9baeu,
		0x0011a105u, 0x002a7289u, 0x0079e7dbu, 0x00b6dba4u,
		0x0100011au, 0x030002a7u, 0x0400079eu, 0x0a000b6du,
		0x1f001001u, 0x2e003003u, 0x45004004u, 0xc900a00au);

/// Hash Prospector mixer (Cycles `hash_hp_uint`).
uint sb_hash_hp(uint p_i) {
	p_i ^= p_i >> 16u;
	p_i *= 0x21f0aaadu;
	p_i ^= p_i >> 15u;
	p_i *= 0xd35a2d97u;
	p_i ^= p_i >> 15u;
	// The xor only stops 0 mapping to 0; the constant is arbitrary.
	return p_i ^ 0xe6fe3bebu;
}

/// Per-pixel decorrelation hash (Cycles `hash_iqnt2d`).
uint sb_hash_iqnt2d(uint p_x, uint p_y) {
	const uint qx = 1103515245u * ((p_x >> 1u) ^ p_y);
	const uint qy = 1103515245u * ((p_y >> 1u) ^ p_x);
	return 1103515245u * (qx ^ (qy >> 3u));
}

/// Base-2 Owen scramble of a bit-reversed integer (Cycles `reversed_bit_owen`).
uint sb_pcg_owen(uint p_n, uint p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n += p_seed;
	p_n *= (p_seed >> 16u) | 1u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

/// [0, uint_max] -> [0.0, 1.0). Dividing by 4294967808 rather than 2^32 keeps the
/// result strictly below 1.0 after float rounding (Cycles `uint_to_float_excl`).
float sb_uint_to_float_excl(uint p_n) {
	return float(p_n) * (1.0 / 4294967808.0);
}

/// One dimension of an Owen-scrambled Sobol sample.
float sb_sobol_burley(uint p_rev_bit_index, uint p_dimension, uint p_scramble_seed) {
	uint result = 0u;

	if (p_dimension == 0u) {
		// Dimension 0 is plain Van der Corput; the fast path matters because
		// padding reuses dimension 0 more than any other.
		result = bitfieldReverse(p_rev_bit_index);
	} else {
		uint i = 0u;
		while (p_rev_bit_index != 0u) {
			// GLSL has no clz; findMSB is defined for non-zero input, which the
			// loop condition guarantees.
			const uint j = uint(31 - findMSB(p_rev_bit_index));
			// `i` counts bits consumed so far and the loop ends once every bit is
			// shifted out, so i + j <= 31 and the index stays inside the block.
			result ^= SOBOL_BURLEY_TABLE[p_dimension * 32u + i + j];
			i += j + 1u;
			// Split because a shift of 32 is undefined.
			p_rev_bit_index <<= j;
			p_rev_bit_index <<= 1u;
		}
	}

	result = bitfieldReverse(sb_pcg_owen(result, p_scramble_seed));
	return sb_uint_to_float_excl(result);
}

/// 1D Owen-scrambled, shuffled Sobol sample. Different `p_dimension` values are
/// uncorrelated. `p_mask` limits the sequence length for speed; 0xffffffff is the
/// safe maximum-length default.
float sobol_burley_sample_1D(uint p_index, uint p_dimension, uint p_seed, uint p_mask) {
	p_seed ^= sb_hash_hp(p_dimension);
	p_index = sb_pcg_owen(bitfieldReverse(p_index), p_seed ^ 0xbff95bfeu);
	p_index &= p_mask;
	return sb_sobol_burley(p_index, 0u, p_seed ^ 0x635c77bdu);
}

/// 2D Owen-scrambled, shuffled Sobol sample. The two dimensions within one set are
/// stratified against each other; different sets are uncorrelated. Note that a 1D
/// and a 2D draw with the same index/dimension/seed are also uncorrelated, so the
/// two entry points can be mixed freely.
vec2 sobol_burley_sample_2D(uint p_index, uint p_dimension_set, uint p_seed, uint p_mask) {
	p_seed ^= sb_hash_hp(p_dimension_set);
	p_index = sb_pcg_owen(bitfieldReverse(p_index), p_seed ^ 0xf8ade99au);
	p_index &= p_mask;
	return vec2(
			sb_sobol_burley(p_index, 0u, p_seed ^ 0xe0aaaf76u),
			sb_sobol_burley(p_index, 1u, p_seed ^ 0x94964d4eu));
}
```

- [ ] **Step 4: Diff the GLSL against the C++ mirror line by line**

Read both files side by side and confirm every constant matches: `0x21f0aaad`, `0xd35a2d97`, `0xe6fe3beb`, `0x3d20adea`, `0x05526c56`, `0x53a22864`, `4294967808.0`, `0xbff95bfe`, `0x635c77bd`, `0xf8ade99a`, `0xe0aaaf76`, `0x94964d4e`, `1103515245`, and all 128 table entries. A single wrong digit produces a sampler that still *looks* random and silently loses stratification. There is no automated check for this — do it by eye.

- [ ] **Step 5: Build to verify the new include compiles**

The file is `*_inc.glsl`, so `servers/rendering/renderer_rd/shaders/SCsub` globs it automatically — no SCsub edit is needed. It is compiled to a header even though nothing includes it yet.

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Expected: build succeeds, and `sobol_burley_inc.glsl.gen.h` appears next to the source.

- [ ] **Step 6: Run the full test suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: all cases pass, count increased by 7 over the previous baseline.

- [ ] **Step 7: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl tests/servers/rendering/test_pt_sobol.cpp
git commit -m "feat(pt): port Cycles' Owen-scrambled Sobol-Burley sampler to GLSL"
```

---

### Task 2: Replace the PCG stream with dimension-indexed Sobol draws

The structural change. After this task the renderer samples exactly like Cycles.

**Files:**
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/scene_raytracing_raygen.glsl:54`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:404-405, 535, 552, 561`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_lights_inc.glsl:214, 233, 266, 305, 338, 351, 365, 380, 426, 461, 475`

**Interfaces:**
- Consumes (from Task 1): `sb_hash_iqnt2d`, `sobol_burley_sample_1D`, `sobol_burley_sample_2D`.
- Produces (used by Task 4):
  - `struct RNGState { uint pixel; uint sample_index; uint offset; }`
  - `RNGState rng_init(uvec2 p_pixel, uint p_sample_index)`
  - `float rng_1d(RNGState p_rng, uint p_dim)` / `vec2 rng_2d(RNGState p_rng, uint p_dim)`
  - `uint rng_pack(RNGState p_rng)` / `RNGState rng_unpack(uint p_packed, uvec2 p_pixel)`
  - `RNGState rng_next_bounce(RNGState p_rng)`
  - `uint rng_side_stream(RNGState p_rng, uint p_dim)`
  - `PathPayload.rng_packed` and `PathState.rng_packed` (renamed from `rng_state`)

- [ ] **Step 1: Add the include and the RNG layer to `raytracing_inc.glsl`**

At the top of the file, after the existing `#include "../oct_inc.glsl"` lines, add:

```glsl
#include "sobol_burley_inc.glsl"
```

Replace the whole `RANDOM NUMBER GENERATION` block (currently `raytracing_inc.glsl:154-181`) with:

```glsl
// ============================================================================
// RANDOM NUMBER GENERATION
// ============================================================================
//
// Two samplers coexist here on purpose.
//
// 1. Sobol-Burley (rng_1d / rng_2d) is the production sampler and mirrors Cycles.
//    Every draw names an explicit DIMENSION rather than advancing a stream. That
//    is the whole mechanism: stratification only holds if a given decision uses
//    the same dimension on every path in the frame, and a stream cannot promise
//    that because different paths branch differently. Never convert these back
//    into "advance and return" helpers.
//
// 2. PCG (pcg_hash / rand) survives for the light reservoir loop, which draws a
//    variable number of values per shading point (raytracing_lights_inc.glsl).
//    Giving that loop 2 * RT_LIGHT_RESERVOIR_SIZE Sobol dimensions would spend
//    our best-stratified dimensions on the decision Cycles itself does not Sobol
//    sample -- its light tree descends on one rescaled number (kernel/light/tree.h).
//    Replacing the reservoir with a power-weighted selector is roadmap item C2.
//    Until then the stream is at least SEEDED from the Sobol state so it stays
//    decorrelated from the rest of the path.

/// PCG random number generator - improved XSH-RR variant with better avalanche.
uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

/// Random float in [0, 1) from a mutable PCG stream. Reservoir loop only.
float rand(inout uint state) {
	state = pcg_hash(state);
	return float(state) / 4294967296.0;
}

/// Fixed scramble seed. Cycles randomizes this per frame when pixel jitter is on;
/// we keep it constant so a given accumulation frame index always reproduces the
/// same image, which the validation harness depends on. Sample decorrelation
/// across frames comes from the sample index, not from reseeding.
const uint RT_SAMPLER_SEED = 0x5f356495u;

// Dimension allocation, mirroring Cycles' PathTraceDimension (kernel/types.h:72).
// Each bounce owns a block of RT_PRNG_BOUNCE_NUM consecutive dimensions; the
// constants below index within the current block. Earlier dimensions are better
// stratified, so the highest-variance decision (the BSDF direction) gets 0.
// Cycles uses a block of 16; we have fewer decisions, so 8 with room to grow.
#define RT_PRNG_BOUNCE_NUM 8u
#define RT_PRNG_FILTER 0u // 2D, init block only: sub-pixel reconstruction filter.
#define RT_PRNG_SURFACE_BSDF 0u // 2D: BSDF direction sample.
#define RT_PRNG_LIGHT 2u // 2D: position on the selected light.
#define RT_PRNG_LOBE 4u // 1D: diffuse-vs-specular lobe choice.
#define RT_PRNG_TERMINATE 5u // 1D: reserved for B4 Russian Roulette.
#define RT_PRNG_RESERVOIR 6u // 1D: seeds the reservoir's PCG side stream.

/// Sampler state for one path. `pixel` is the per-pixel Owen scramble seed,
/// `sample_index` selects the point in the sequence, and `offset` is the base
/// dimension of the current bounce's block.
struct RNGState {
	uint pixel;
	uint sample_index;
	uint offset;
};

/// Per-pixel scramble seed (Cycles `path_rng_pixel_init`, pattern.h:143).
uint rng_pixel_seed(uvec2 p_pixel) {
	return sb_hash_iqnt2d(p_pixel.x, p_pixel.y) ^ RT_SAMPLER_SEED;
}

/// Start a path. Block 0 is reserved for the camera/init decisions (the pixel
/// filter), so shading starts at block 1 -- same convention as Cycles, which
/// initializes rng_offset to PRNG_BOUNCE_NUM (path_state.h:58).
RNGState rng_init(uvec2 p_pixel, uint p_sample_index) {
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_sample_index;
	r.offset = RT_PRNG_BOUNCE_NUM;
	return r;
}

/// Advance to the next bounce's dimension block (Cycles path_state.h:241).
RNGState rng_next_bounce(RNGState p_rng) {
	RNGState r = p_rng;
	r.offset += RT_PRNG_BOUNCE_NUM;
	return r;
}

/// 1D draw from dimension `p_dim` of the current block. Does not mutate state.
float rng_1d(RNGState p_rng, uint p_dim) {
	// 0xffffffff = maximum sequence length. Cycles derives a shorter mask from the
	// sample count purely to shorten this loop; it does not change the values.
	return sobol_burley_sample_1D(p_rng.sample_index, p_rng.offset + p_dim, p_rng.pixel, 0xffffffffu);
}

/// 2D draw from dimension set `p_dim` of the current block. Does not mutate state.
vec2 rng_2d(RNGState p_rng, uint p_dim) {
	return sobol_burley_sample_2D(p_rng.sample_index, p_rng.offset + p_dim, p_rng.pixel, 0xffffffffu);
}

/// Seed for a PCG side stream that is decorrelated from every Sobol dimension.
/// Used only where the draw count is data-dependent (the light reservoir).
uint rng_side_stream(RNGState p_rng, uint p_dim) {
	return pcg_hash(p_rng.pixel ^ pcg_hash(p_rng.sample_index * 2654435761u + p_rng.offset + p_dim));
}

/// Pack the travelling part of the state into the payload's 32 bits:
/// [sample_index:20][offset:12]. `pixel` is not packed -- every ray-tracing stage
/// can recompute it from gl_LaunchIDEXT, so it costs nothing to carry.
/// 20 bits covers 1,048,575 samples (the accumulation target caps at 8192) and
/// 12 bits covers 4095 dimensions (16 bounces x 8 = 128).
uint rng_pack(RNGState p_rng) {
	return (min(p_rng.sample_index, 0xFFFFFu) << 12u) | (p_rng.offset & 0xFFFu);
}

RNGState rng_unpack(uint p_packed, uvec2 p_pixel) {
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_packed >> 12u;
	r.offset = p_packed & 0xFFFu;
	return r;
}
```

- [ ] **Step 2: Rename the payload field in `raytracing_inc.glsl`**

In `struct PathPayload` (line 49) change:

```glsl
	uint rng_state; //  4 bytes - RNG state for PCG
```

to:

```glsl
	uint rng_packed; //  4 bytes - packed [sample_index:20][dimension offset:12]
```

In `struct PathState` (line 60) change `uint rng_state;` to `uint rng_packed;`.

In `path_unpack` (line 74) change `s.rng_state = p.rng_state;` to `s.rng_packed = p.rng_packed;`.

In `path_pack` (line 89) change `p.rng_state = s.rng_state;` to `p.rng_packed = s.rng_packed;`.

The payload stays 32 bytes; only the name and meaning change.

- [ ] **Step 3: Move the pixel filter onto Sobol dimension 0**

Replace the body of `camera_filter_jitter` (`raytracing_inc.glsl:232-243`) with:

```glsl
vec2 camera_filter_jitter(uvec2 p_pixel, uint p_sample) {
	if (p_sample == 0u) {
		return vec2(0.5);
	}
	// Dimension block 0 (the init block), dimension RT_PRNG_FILTER. This is the
	// best-stratified pair in the whole sequence, which is what anti-aliasing
	// wants: the sub-pixel positions of N samples should tile the pixel evenly
	// rather than clump. Shading draws start at block 1 and are decorrelated.
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_sample;
	r.offset = 0u;
	vec2 u = rng_2d(r, RT_PRNG_FILTER);
	return vec2(0.5) + vec2(bh_filter_1d(u.x), bh_filter_1d(u.y));
}
```

The `BH_INV_CDF_HALF` table, `bh_inv_cdf_half` and `bh_filter_1d` above it are unchanged.

- [ ] **Step 4: Initialize the sampler in raygen**

In `scene_raytracing_raygen.glsl`, replace line 54:

```glsl
	ps.rng_state = init_rng(p_pixel, p_frame_index, p_sample_idx);
```

with:

> **CORRECTED 2026-08-08 after review.** This step originally specified
> `rng_init(p_pixel, p_frame_index * RT_GET_SAMPLE_COUNT() + p_sample_idx)` for both
> modes. That is **wrong in accumulate mode**: `p_frame_index` comes from
> `p_state->frame_counter++` (`render_raytracing.cpp:3080`), which increments on every
> dispatch and is never reset when accumulation resets — only `accum_frame` is. The
> compound index therefore (a) is not the contiguous power-of-two prefix Sobol's
> stratification guarantee requires, (b) makes renders non-reproducible run to run,
> breaking the guarantee `RT_SAMPLER_SEED` advertises and the validation harness relies
> on, and (c) saturates the 20-bit packed field in long sessions, stalling convergence.
> Measured effect of the correction: validation-scene convergence reduction rose from
> 5.99x to 9.80x. The corrected form is below.

Make the sequence index mode-dependent by computing it at each call site rather than
inside `trace_one_sample`. Replace the `(p_frame_index, p_sample_idx)` parameter pair
with a single `uint p_rng_sample_index`, and initialize from it:

```glsl
	// One continuous Sobol sequence per pixel. The caller supplies the sequence
	// index because only it knows the mode: the accumulate branch passes the
	// accumulation frame index (contiguous, and reset with the accumulator, so a
	// given frame always reproduces the same image), while the one-shot branch
	// passes frame_index * spp + sample_idx so successive realtime frames do not
	// replay the same points.
	ps.rng_packed = rng_pack(rng_init(p_pixel, p_rng_sample_index));
```

Accumulate call site: pass `accum_frame` — the same value
`camera_filter_jitter(pixel, accum_frame)` already uses one line above.
One-shot call site: pass `frame_index * samples_per_pixel + sample_idx`. That path can
still in principle saturate the 20-bit field in a very long session; say so in the
comment rather than implying it cannot.

Note: `init_rng` no longer exists after Step 1 — this is its only call site.

- [ ] **Step 5: Switch the closest-hit shading draws to named dimensions**

In `raytracing_closest_hit_common_inc.glsl`, inside `shade_and_bounce` after `PathState ps = path_unpack(payload);` (line 443), add:

```glsl
	RNGState rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
```

Replace the NEE call (line 534-535):

```glsl
		vec3 direct_light = lights_evaluate_direct_lighting(
				hit_pos_offset, N, V, brdf_mat, ps.rng_state, is_indirect, rt_light_count);
```

with:

```glsl
		vec3 direct_light = lights_evaluate_direct_lighting(
				hit_pos_offset, N, V, brdf_mat, rng, is_indirect, rt_light_count);
```

Replace the lobe choice (line 552):

```glsl
		if (rand(ps.rng_state) < brdfProbability) {
```

with:

```glsl
		if (rng_1d(rng, RT_PRNG_LOBE) < brdfProbability) {
```

Replace the direction draw (line 561):

```glsl
	vec2 u = rand2(ps.rng_state);
```

with:

```glsl
	vec2 u = rng_2d(rng, RT_PRNG_SURFACE_BSDF);
```

Immediately before the final `path_pack(payload, ps);` of the function (line 594), advance the block:

```glsl
	// Next bounce gets its own dimension block, so decision k at depth d always
	// draws from the same dimension across every path in the frame.
	ps.rng_packed = rng_pack(rng_next_bounce(rng));
```

Finally, in the debug-visualization block, replace lines 404-405:

```glsl
		vec2 u_spec_rng = rand2(ps.rng_state);
		vec2 u_diff_rng = rand2(ps.rng_state);
```

with:

```glsl
		RNGState dbg_rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		vec2 u_spec_rng = rng_2d(dbg_rng, RT_PRNG_SURFACE_BSDF);
		vec2 u_diff_rng = rng_2d(dbg_rng, RT_PRNG_LIGHT);
```

- [ ] **Step 6: Switch the light sampling to `RNGState`**

In `raytracing_lights_inc.glsl`, change the three function signatures that currently thread `inout uint rng_state`:

Line 214:
```glsl
bool lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist, inout uint rng_state) {
```
becomes
```glsl
bool lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist) {
```
The shadow payload at line 233 sets `shadow_ps.rng_state = 0u;` — change that to `shadow_ps.rng_packed = 0u;`. The shadow ray never samples, so it needs no state and the parameter was already unused for anything but forwarding. Update the three call sites (lines 305, 426, 475) to drop the last argument.

Line 266 (the light-evaluation helper) — change `inout uint rng_state` to `RNGState p_rng` and update its call site at line 461 to pass `p_rng` through.

Line 338 (`lights_evaluate_direct_lighting`) — change `inout uint rng_state,` to `RNGState p_rng,`.

Replace the reservoir loop draws. Line 351:
```glsl
		uint idx = min(uint(rand(rng_state) * float(light_count)), light_count - 1u);
```
Line 365:
```glsl
			if (rand(rng_state) < 1.0 / float(valid_found)) {
```
Insert before the loop (before line 350):
```glsl
	// Data-dependent draw count -- see the sampler note in raytracing_inc.glsl.
	// PCG side stream, decorrelated from every Sobol dimension. Roadmap C2 replaces
	// this loop with power-weighted selection, at which point it becomes a fixed
	// number of draws and can move onto Sobol dimensions.
	uint reservoir_stream = rng_side_stream(p_rng, RT_PRNG_RESERVOIR);
```
and change both `rand(rng_state)` calls to `rand(reservoir_stream)`.

Replace the light-position draw (line 380):
```glsl
	vec2 u = rand2(rng_state);
```
with:
```glsl
	vec2 u = rng_2d(p_rng, RT_PRNG_LIGHT);
```

- [ ] **Step 7: Build**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Expected: clean build. If the compiler reports an undefined `rand2`, a call site was missed — `rand2` is deliberately gone; grep for it and convert the site to a named dimension. `rand` (single) survives only for the reservoir stream.

- [ ] **Step 8: Verify no stream-style draws survive**

```bash
git grep -n "rng_state\|rand2(" -- "servers/rendering/renderer_rd/shaders/raytracing/"
```

Expected: **no output**. Any hit is a call site still on the old stream, which silently loses stratification for that decision.

- [ ] **Step 9: Run the full test suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: all cases pass, same count as at the end of Task 1.

- [ ] **Step 10: Visual smoke test**

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

Expected: the scene renders, the harness prints its convergence table, and the image shows no structured artifacts — no diagonal banding, no repeating tiles, no per-pixel colour blocks. Structured artifacts here mean the dimension allocation is wrong (usually two decisions sharing a dimension). Grain that looks *finer and more even* than before is the intended outcome; keep the numbers for Task 3.

- [ ] **Step 11: Commit**

```bash
git add servers/rendering/renderer_rd/shaders/raytracing/
git commit -m "feat(pt): replace the PCG stream with dimension-indexed Sobol draws"
```

---

### Task 3: Measure and record the B5 convergence improvement

B5 is a variance-reduction change. A single frame does not demonstrate it; an error-vs-sample-count curve does.

**Files:**
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: the working sampler from Task 2.
- Produces: recorded numbers, no code.

- [ ] **Step 1: Capture the pre-change baseline**

```bash
git stash list && git log --oneline -3
```

Check out the commit *before* Task 2 into a scratch worktree, build it, and run the validation scene, saving the printed RMSE-vs-sample-count table. If a baseline from an earlier session is already recorded in the roadmap, reuse it and skip this step rather than spending a full rebuild.

- [ ] **Step 2: Run the harness on the new sampler**

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

Record the RMSE at each sample count in the sweep.

- [ ] **Step 3: Check the acceptance criterion**

> **CORRECTED 2026-08-08 after measurement.** The second half of this criterion
> originally read "and the low-sample end (16-64) improves by more than the high-sample
> end — stratification pays most when samples are scarce." **That is backwards and was a
> defect in this plan.** White-noise Monte Carlo converges at RMSE ∝ N^-0.5. Any working
> QMC sampler converges faster, so the *ratio* between them, ∝ N^(p-0.5) with p > 0.5,
> necessarily **grows** with N. A shrinking ratio would mean Sobol was converging
> *slower* than white noise — the signature of a broken sampler, not a healthy one. The
> original wording confused the perceptual argument (blue-noise-like error is less
> objectionable at low spp) with RMSE-ratio behaviour. Corrected criterion below.

> **CORRECTED AGAIN 2026-08-08 after review.** The revision above added a "consistency
> check": that the end-to-end improvement ratio should equal
> `(N_last/N_first)^(p_sobol - p_pcg)`. **That check is a tautology and must not be
> used.** Because each exponent is fitted *only* from the two endpoints,
> `32^(p_sob - p_pcg)` expands to `(S_16/S_512)/(P_16/P_512)`, and the "measured"
> ratio-of-ratios `(P_512/S_512)/(P_16/S_16)` expands to the same expression — the same
> four numbers regrouped by commutativity of division. It agrees to floating-point
> precision for *any* input, including data from a broken sampler, so it can never fail
> and validates nothing. Replaced below with a check against the data the fit does not
> use.

Accept when both hold:

1. **No regression.** RMSE is lower with Sobol than with PCG at every point in the sweep.
2. **Steeper convergence.** The fitted exponent is clearly steeper for Sobol than for PCG. Fit each end-to-end by `p = log(RMSE_first / RMSE_last) / log(N_last / N_first)`; expect PCG near 0.5 and Sobol clearly above it.

Then, as a genuine (falsifiable) check, validate the two-point fit against the **middle points it does not use**: predict `RMSE(N) = RMSE_first * (N / N_first)^(-p)` at each intermediate N and compare to measurement. This can fail, and what it tells you matters:

- Deviations within roughly ±5% mean a single power law summarizes the curve well.
- Larger deviations mean the fit is a crude summary, not that the sampler is broken — a QMC sampler's *local* convergence rate legitimately varies across the sweep. Record the deviation rather than hiding it, and say plainly that the exponent is a two-point secant slope, not a regression over all sampled points.
- A sampler whose measured RMSE falls *below* its own fit at the low-N end while rising above it at the high-N end is the shape to be suspicious of, since that is what a partially-correlated sampler looks like.

Report the harness's own warnings alongside the numbers. In particular, if it warns that the reference frame count is less than 4x the longest run, that caveat belongs in the record — it bears directly on the endpoint the whole fit is anchored to.

If RMSE is *worse* anywhere, stop and re-check the dimension allocation before recording anything: two decisions sharing a dimension index is the usual cause, and it produces correlation that is worse than white noise.

- [ ] **Step 4: Update the roadmap**

In `PATH_TRACER_QUALITY_ROADMAP.md`, mark **B5** done under Phase B, and replace its *Accept* line with the measured table, e.g.:

```markdown
**B5. Owen-scrambled Sobol / blue-noise sampler** — *Gap #6* — **DONE**
Sobol-Burley with per-pixel Owen scrambling, dimension-indexed draws
(`sobol_burley_inc.glsl`, `RNGState` in `raytracing_inc.glsl`). Two deliberate
divergences from Cycles, both documented in the shader: the light reservoir keeps a
seeded PCG side stream (fixed by C2), and the sequence-length mask is omitted
(performance only).
*Measured:* RMSE vs 2048-sample reference — <fill in: N=16, 64, 256 for PCG vs Sobol>.
```

- [ ] **Step 5: Commit**

```bash
git add PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "docs(pt): record measured B5 convergence improvement"
```

---

### Task 4: Per-lobe bounce controls (B3)

Removes the hardcoded `MAX_DIFFUSE_BOUNCES 2u` — the reason interior GI reads flat.

**Files:**
- Modify: `servers/rendering/rendering_server_enums.h:811-813`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h:106-107`
- Modify: `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp:651`
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl` (param defines, bounce helpers)
- Modify: `servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl:451-452, 464, 583-587`
- Modify: `scene/resources/environment.h:197, 227, 424-425, 440-441`
- Modify: `scene/resources/environment.cpp:635-642, 716-734, 1594`
- Create: `tests/servers/rendering/test_pt_bounce_limits.cpp`

**Interfaces:**
- Consumes (from Task 2): nothing directly; both tasks touch `raytracing_inc.glsl` and `raytracing_closest_hit_common_inc.glsl`, so run Task 2 first to avoid a conflict.
- Produces:
  - C++: `RSE::PT_PARAM_MAX_DIFFUSE_BOUNCE = 12`, `RSE::PT_PARAM_MAX_GLOSSY_BOUNCE = 13`
  - GDScript: `Environment.pathtracing_max_diffuse_bounce`, `Environment.pathtracing_max_glossy_bounce` (int, 1-16, default 4), and `pathtracing_max_bounces` range widened to 1-16
  - GLSL: `get_glossy_bounces(uint)`, `inc_glossy_bounce(uint)`

- [ ] **Step 1: Write the failing test**

Create `tests/servers/rendering/test_pt_bounce_limits.cpp` with the Godot copyright header copied verbatim from `tests/servers/rendering/test_pt_accumulator.cpp:1-29` (filename on line 2 becomes `test_pt_bounce_limits.cpp`), then:

```cpp
#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_bounce_limits)

#include <cstdint>

namespace TestPTBounceLimits {

// CPU mirror of the bounce bookkeeping in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl.
// packed_bounces_flags layout:
//   bits  0-7   total bounces
//   bits  8-15  diffuse bounces
//   bits 16-23  glossy bounces
//   bit  24     SAMPLE_ZERO_FLAG
//   bit  25     SHADOW_RAY_FLAG
//   bit  26     PATH_TERMINATED_FLAG
// The three counters share one uint, so an increment is a single add of a
// constant with the right bit offsets -- which is exactly the kind of thing that
// is easy to get wrong by one nibble and impossible to spot in a render.

static uint32_t get_total_bounces(uint32_t p_packed) {
	return p_packed & 0xFFu;
}
static uint32_t get_diffuse_bounces(uint32_t p_packed) {
	return (p_packed >> 8) & 0xFFu;
}
static uint32_t get_glossy_bounces(uint32_t p_packed) {
	return (p_packed >> 16) & 0xFFu;
}
static uint32_t inc_diffuse_bounce(uint32_t p_packed) {
	return p_packed + 0x101u; // +1 total, +1 diffuse
}
static uint32_t inc_glossy_bounce(uint32_t p_packed) {
	return p_packed + 0x10001u; // +1 total, +1 glossy
}

// Mirror of the termination rule in shade_and_bounce. Cycles terminates when the
// lobe just taken exceeds ITS OWN cap (kernel/integrator/path_state.h:183, :190),
// not when both are exhausted. A cap of 0 means "unset" and falls back to the
// total limit -- Environment always writes >= 1, so 0 only reaches the shader from
// a raw RenderingServer environment that never set the params.
static uint32_t effective_cap(uint32_t p_cap, uint32_t p_max_total) {
	return (p_cap == 0) ? p_max_total : p_cap;
}

static bool should_terminate(uint32_t p_packed, uint32_t p_max_total, uint32_t p_max_diffuse, uint32_t p_max_glossy) {
	const uint32_t max_d = effective_cap(p_max_diffuse, p_max_total);
	const uint32_t max_g = effective_cap(p_max_glossy, p_max_total);
	return get_total_bounces(p_packed) >= p_max_total ||
			get_diffuse_bounces(p_packed) >= max_d ||
			get_glossy_bounces(p_packed) >= max_g;
}

TEST_CASE("[PathTracer][Bounces] counters pack into disjoint bit fields") {
	uint32_t p = 0;
	p = inc_diffuse_bounce(p);
	p = inc_diffuse_bounce(p);
	p = inc_glossy_bounce(p);

	CHECK(get_total_bounces(p) == 3);
	CHECK(get_diffuse_bounces(p) == 2);
	CHECK(get_glossy_bounces(p) == 1);
}

TEST_CASE("[PathTracer][Bounces] incrementing does not disturb the flag bits") {
	const uint32_t SAMPLE_ZERO_FLAG = 1u << 24;
	const uint32_t PATH_TERMINATED_FLAG = 1u << 26;

	uint32_t p = SAMPLE_ZERO_FLAG | PATH_TERMINATED_FLAG;
	for (int i = 0; i < 40; i++) {
		p = (i % 2 == 0) ? inc_diffuse_bounce(p) : inc_glossy_bounce(p);
	}

	CHECK((p & SAMPLE_ZERO_FLAG) != 0);
	CHECK((p & PATH_TERMINATED_FLAG) != 0);
	CHECK(get_total_bounces(p) == 40);
	CHECK(get_diffuse_bounces(p) == 20);
	CHECK(get_glossy_bounces(p) == 20);
}

TEST_CASE("[PathTracer][Bounces] a diffuse path stops at the diffuse cap") {
	uint32_t p = 0;
	int depth = 0;
	while (!should_terminate(p, 16, 4, 4)) {
		p = inc_diffuse_bounce(p);
		depth++;
	}
	CHECK(depth == 4);
	CHECK(get_glossy_bounces(p) == 0);
}

TEST_CASE("[PathTracer][Bounces] a glossy path stops at the glossy cap") {
	uint32_t p = 0;
	int depth = 0;
	while (!should_terminate(p, 16, 4, 6)) {
		p = inc_glossy_bounce(p);
		depth++;
	}
	CHECK(depth == 6);
}

TEST_CASE("[PathTracer][Bounces] the total cap still wins when it is the tightest") {
	uint32_t p = 0;
	int depth = 0;
	while (!should_terminate(p, 3, 8, 8)) {
		p = (depth % 2 == 0) ? inc_diffuse_bounce(p) : inc_glossy_bounce(p);
		depth++;
	}
	CHECK(depth == 3);
}

TEST_CASE("[PathTracer][Bounces] an unset cap of 0 falls back to the total limit") {
	// A raw RenderingServer environment leaves pathtracing_params zeroed. Treating
	// 0 as "terminate immediately" would render such a scene black.
	uint32_t p = 0;
	int depth = 0;
	while (!should_terminate(p, 5, 0, 0)) {
		p = inc_diffuse_bounce(p);
		depth++;
	}
	CHECK(depth == 5);
}

TEST_CASE("[PathTracer][Bounces] the old hardcoded 2-diffuse limit is strictly tighter") {
	// Regression guard for the actual defect: MAX_DIFFUSE_BOUNCES was 2u, so
	// interior GI died two diffuse hops from the camera.
	uint32_t old_p = 0;
	int old_depth = 0;
	while (!should_terminate(old_p, 16, 2, 2)) {
		old_p = inc_diffuse_bounce(old_p);
		old_depth++;
	}

	uint32_t new_p = 0;
	int new_depth = 0;
	while (!should_terminate(new_p, 16, 4, 4)) {
		new_p = inc_diffuse_bounce(new_p);
		new_depth++;
	}

	CHECK(old_depth == 2);
	CHECK(new_depth == 4);
}

} // namespace TestPTBounceLimits
```

- [ ] **Step 2: Build and run the new tests**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

```bash
bin/godot.windows.editor.x86_64.exe --test --test-case="*Bounces*"
```

Expected: all 7 cases pass against the mirror. As in Task 1 the mirror is the specification; the shader is brought into agreement next.

- [ ] **Step 3: Add the two `PT_PARAM` slots**

In `servers/rendering/rendering_server_enums.h`, replace the `// Indices 12-13 reserved` gap between `PT_PARAM_NOISE_THRESHOLD = 11` (line 811) and `PT_PARAM_LIGHT_COUNT = 14` (line 813) with:

```cpp
	// PT_PARAM_MAX_DIFFUSE_BOUNCE: maximum number of diffuse reflection bounces a
	// path may take before it terminates, independent of the total bounce limit.
	// Mirrors Cycles' `max_diffuse_bounce` (kernel/integrator/path_state.h:183);
	// Blender ships 4. 0 means "unset" and falls back to PT_PARAM_MAX_BOUNCES so a
	// raw RenderingServer environment that never wrote these params still renders.
	PT_PARAM_MAX_DIFFUSE_BOUNCE = 12,
	// PT_PARAM_MAX_GLOSSY_BOUNCE: same, for glossy/specular reflection bounces
	// (Cycles `max_glossy_bounce`, path_state.h:190). Blender ships 4.
	PT_PARAM_MAX_GLOSSY_BOUNCE = 13,
```

**These are the last two free slots.** Add a comment above `PT_PARAM_VIS_MODE` noting the array is now full:

```cpp
	// NOTE: slots 0-15 are ALL allocated. `rt_params` is a vec4[4] in GLSL and
	// `float pathtracing_params[16]` in environment_storage.h; adding a 17th param
	// means resizing the UBO, the storage array, the rt_ubo static_assert in
	// render_raytracing.cpp, and the GLSL declaration together.
```

- [ ] **Step 4: Mirror the slots C++-side and GLSL-side**

In `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h`, after line 106:

```cpp
	static constexpr int RT_PARAM_MAX_DIFFUSE_BOUNCE = RSE::PT_PARAM_MAX_DIFFUSE_BOUNCE;
	static constexpr int RT_PARAM_MAX_GLOSSY_BOUNCE = RSE::PT_PARAM_MAX_GLOSSY_BOUNCE;
```

In `servers/rendering/renderer_rd/shaders/raytracing/raytracing_inc.glsl`, replace the line `// Indices 12-13 reserved for future use` (line 30) with:

```glsl
#define RT_PARAM_MAX_DIFFUSE_BOUNCE 12 // rt_params[3].x - Diffuse bounce cap (0 = use MAX_BOUNCES)
#define RT_PARAM_MAX_GLOSSY_BOUNCE 13 // rt_params[3].y - Glossy bounce cap (0 = use MAX_BOUNCES)
```

- [ ] **Step 5: Add the glossy counter and drop the hardcoded limit**

In `raytracing_inc.glsl`, extend the bounce helpers block (lines 95-110):

```glsl
// Bounce count helpers.
// Layout: bits 0-7 total, bits 8-15 diffuse, bits 16-23 glossy, bits 24+ flags.
uint get_total_bounces(uint packed) {
	return packed & 0xFFu;
}
uint get_diffuse_bounces(uint packed) {
	return (packed >> 8u) & 0xFFu;
}
uint get_glossy_bounces(uint packed) {
	return (packed >> 16u) & 0xFFu;
}
uint pack_bounces(uint total, uint diffuse) {
	return total | (diffuse << 8u);
}
uint inc_diffuse_bounce(uint packed) {
	return packed + 0x101u; // +1 total, +1 diffuse
}
uint inc_glossy_bounce(uint packed) {
	return packed + 0x10001u; // +1 total, +1 glossy
}

/// Resolve a per-lobe cap, treating 0 as "unset" and falling back to the total
/// limit. Environment always writes >= 1; 0 only arrives from a raw
/// RenderingServer environment that never set the pathtracing params, and
/// terminating those paths immediately would render the scene black.
uint resolve_bounce_cap(float p_param, uint p_max_total) {
	uint cap = uint(max(p_param, 0.0));
	return (cap == 0u) ? p_max_total : cap;
}
```

Delete `inc_total_bounce` and the `#define MAX_DIFFUSE_BOUNCES 2u` (line 142). Keep `#define MAX_DENOISER_SPECULAR_HIT_THRESHOLD 0.25` on the line after it.

- [ ] **Step 6: Apply the caps in the integrator**

In `raytracing_closest_hit_common_inc.glsl`, after line 452 add the glossy read:

```glsl
	uint glossy_bounces = get_glossy_bounces(ps.packed_bounces_flags);
```

Replace the bounce-limit check (line 464):

```glsl
	if (total_bounces >= RT_GET_MAX_BOUNCES() || diffuse_bounces >= MAX_DIFFUSE_BOUNCES) {
```

with:

```glsl
	// Per-lobe limits, matching Cycles: a path stops when the lobe it has been
	// taking exceeds its own cap, not when every budget is exhausted
	// (kernel/integrator/path_state.h:183, :190). This is what replaces the old
	// hardcoded 2-diffuse-bounce ceiling that flattened interior GI.
	const uint max_total = RT_GET_MAX_BOUNCES();
	const uint max_diffuse = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_DIFFUSE_BOUNCE), max_total);
	const uint max_glossy = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_GLOSSY_BOUNCE), max_total);
	if (total_bounces >= max_total || diffuse_bounces >= max_diffuse || glossy_bounces >= max_glossy) {
```

Replace the counter update (lines 583-587):

```glsl
	if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_total_bounce(ps.packed_bounces_flags);
	}
```

with:

```glsl
	if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_glossy_bounce(ps.packed_bounces_flags);
	}
```

- [ ] **Step 7: Raise the total bounce ceiling from 8 to 16**

In `servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.cpp:651`:

```cpp
		max_bounces = MAX(1u, MIN(8u, (uint32_t)p_env_params[RT_PARAM_MAX_BOUNCES]));
```

becomes:

```cpp
		// Cycles' shipped default total is 12 (blender/addon/properties.py); 8 was
		// clipping requests the pipeline already makes. This is a specialization
		// constant, so a higher ceiling costs nothing until a scene asks for it.
		max_bounces = MAX(1u, MIN(16u, (uint32_t)p_env_params[RT_PARAM_MAX_BOUNCES]));
```

- [ ] **Step 8: Expose the properties on `Environment`**

In `scene/resources/environment.h`, change line 197:

```cpp
	int pathtracing_max_bounces = 3;
```

to:

```cpp
	int pathtracing_max_bounces = 8;
	// Cycles' shipped defaults (blender/addon/properties.py:765, :771).
	int pathtracing_max_diffuse_bounce = 4;
	int pathtracing_max_glossy_bounce = 4;
```

After line 441 (`float get_pathtracing_noise_threshold() const;`) add:

```cpp
	void set_pathtracing_max_diffuse_bounce(int p_bounces);
	int get_pathtracing_max_diffuse_bounce() const;
	void set_pathtracing_max_glossy_bounce(int p_bounces);
	int get_pathtracing_max_glossy_bounce() const;
```

In `scene/resources/environment.cpp`, change `set_pathtracing_max_bounces` (line 636):

```cpp
	pathtracing_max_bounces = CLAMP(p_bounces, 1, 8);
```

to:

```cpp
	pathtracing_max_bounces = CLAMP(p_bounces, 1, 16);
```

After `get_pathtracing_noise_threshold` (line 714) add:

```cpp
void Environment::set_pathtracing_max_diffuse_bounce(int p_bounces) {
	pathtracing_max_diffuse_bounce = CLAMP(p_bounces, 1, 16);
	_update_pathtracing();
}

int Environment::get_pathtracing_max_diffuse_bounce() const {
	return pathtracing_max_diffuse_bounce;
}

void Environment::set_pathtracing_max_glossy_bounce(int p_bounces) {
	pathtracing_max_glossy_bounce = CLAMP(p_bounces, 1, 16);
	_update_pathtracing();
}

int Environment::get_pathtracing_max_glossy_bounce() const {
	return pathtracing_max_glossy_bounce;
}
```

In `_update_pathtracing()` after line 732 add:

```cpp
	params.write[RSE::PT_PARAM_MAX_DIFFUSE_BOUNCE] = (float)pathtracing_max_diffuse_bounce;
	params.write[RSE::PT_PARAM_MAX_GLOSSY_BOUNCE] = (float)pathtracing_max_glossy_bounce;
```

In `_bind_methods()` after line 1588 add:

```cpp
	ClassDB::bind_method(D_METHOD("set_pathtracing_max_diffuse_bounce", "bounces"), &Environment::set_pathtracing_max_diffuse_bounce);
	ClassDB::bind_method(D_METHOD("get_pathtracing_max_diffuse_bounce"), &Environment::get_pathtracing_max_diffuse_bounce);
	ClassDB::bind_method(D_METHOD("set_pathtracing_max_glossy_bounce", "bounces"), &Environment::set_pathtracing_max_glossy_bounce);
	ClassDB::bind_method(D_METHOD("get_pathtracing_max_glossy_bounce"), &Environment::get_pathtracing_max_glossy_bounce);
```

Change the `pathtracing_max_bounces` property hint (line 1594) from `"1,8,1"` to `"1,16,1"`, and add after it:

```cpp
	ADD_PROPERTY(PropertyInfo(Variant::INT, "pathtracing_max_diffuse_bounce", PROPERTY_HINT_RANGE, "1,16,1"), "set_pathtracing_max_diffuse_bounce", "get_pathtracing_max_diffuse_bounce");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "pathtracing_max_glossy_bounce", PROPERTY_HINT_RANGE, "1,16,1"), "set_pathtracing_max_glossy_bounce", "get_pathtracing_max_glossy_bounce");
```

- [ ] **Step 9: Build**

```bash
python -m SCons platform=windows target=editor arch=x86_64 d3d12=no tests=yes
```

Expected: clean build. An `undeclared identifier MAX_DIFFUSE_BOUNCES` means a call site outside `shade_and_bounce` still references the deleted define — grep and convert it.

- [ ] **Step 10: Run the full test suite**

```bash
bin/godot.windows.editor.x86_64.exe --test
```

Expected: all cases pass, count increased by 7 over the end of Task 3.

- [ ] **Step 11: Verify the caps actually bite on the GPU**

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references res://tests/pt_validation_scene.tscn
```

Then edit `pipeline_references/tests/run_pt_validation.gd:192` to add `env.set_pathtracing_max_diffuse_bounce(1)` and re-run. Expected: the second render is visibly darker in shadowed corners — one diffuse bounce means no colour bleeding. Revert the edit (do not commit it). If the two renders are identical, the param is not reaching the shader; check the slot numbers agree across `rendering_server_enums.h`, `scene_shader_raytracing.h`, and `raytracing_inc.glsl`.

- [ ] **Step 12: Commit**

```bash
git add servers/rendering/ scene/resources/environment.h scene/resources/environment.cpp tests/servers/rendering/test_pt_bounce_limits.cpp
git commit -m "feat(pt): replace the hardcoded diffuse bounce cap with per-lobe limits"
```

---

### Task 5: Wire the new controls into the render pipeline and close out Phase B

**Files:**
- Modify: `pipeline_references/image_glb_creation.gd:804-811`
- Modify: `PATH_TRACER_QUALITY_ROADMAP.md`

**Interfaces:**
- Consumes: `Environment.set_pathtracing_max_diffuse_bounce` / `_max_glossy_bounce` from Task 4.
- Produces: nothing downstream.

**Reminder:** edit `pipeline_references/` only. `C:\Zlendo2026\ZlenderRender_stage_copy\` is the user's production copy and they replace files there by hand.

- [ ] **Step 1: Set the bounce controls on the render Environment**

In `pipeline_references/image_glb_creation.gd`, replace lines 804-811:

```gdscript
	# Day: 12 bounces (interior GI off the sun), night: 8 (mostly emissive). SPP stays moderate;
	# DLSS-RR temporally integrates 1 sample/frame across the drive-frame count.
	if day_render:
		env.set_pathtracing_max_bounces(12)
		env.set_pathtracing_samples_per_pixel(20)
	else:
		env.set_pathtracing_max_bounces(8)
		env.set_pathtracing_samples_per_pixel(10)
```

with:

```gdscript
	# Day: 12 bounces (interior GI off the sun), night: 8 (mostly emissive). SPP stays moderate;
	# DLSS-RR temporally integrates 1 sample/frame across the drive-frame count.
	#
	# NOTE: before Phase B3 the engine silently clamped max_bounces to 8, so the 12
	# requested below was never honoured. The ceiling is now 16 and this line means
	# what it says.
	if day_render:
		env.set_pathtracing_max_bounces(12)
		env.set_pathtracing_samples_per_pixel(20)
	else:
		env.set_pathtracing_max_bounces(8)
		env.set_pathtracing_samples_per_pixel(10)

	# Per-lobe bounce limits (Phase B3). Before this the integrator hardcoded a cap of
	# TWO diffuse bounces regardless of max_bounces, which is why interior corners and
	# ceilings read flat and lifeless: light could not make three diffuse hops to reach
	# them. Blender's shipped defaults are 4 diffuse / 4 glossy; raising diffuse costs
	# render time roughly linearly and buys softer, warmer indirect light.
	env.set_pathtracing_max_diffuse_bounce(4)
	env.set_pathtracing_max_glossy_bounce(4)
```

- [ ] **Step 2: Parse-check the GDScript before running anything**

```bash
bin/godot.windows.editor.x86_64.exe --path pipeline_references --headless --quit --check-only --script res://image_glb_creation.gd
```

Expected: no `SCRIPT ERROR: Parse Error` output. Do not skip this — an unbound method or a typo'd enum name here fails at the user's pipeline, not here.

- [ ] **Step 3: Update the roadmap**

In `PATH_TRACER_QUALITY_ROADMAP.md`, mark **B3** done:

```markdown
**B3. Per-type bounce controls** — *Gap #4* — **DONE**
`MAX_DIFFUSE_BOUNCES 2u` is gone. Diffuse and glossy counters now live in
`packed_bounces_flags` bits 8-15 and 16-23, capped by `PT_PARAM_MAX_DIFFUSE_BOUNCE`
(12) and `PT_PARAM_MAX_GLOSSY_BOUNCE` (13) and exposed as
`Environment.pathtracing_max_diffuse_bounce` / `_max_glossy_bounce` (default 4/4,
Blender's shipped values). The total ceiling rose 8 -> 16.
**Deferred on purpose:** `min_bounce` (no consumer until B4 Russian Roulette) and
`max_transmission_bounce` (no transmission path until E1). Both would be dead
params, and **slots 0-15 are now fully allocated** -- either one needs the params
UBO resized first.
```

Also update the ordering summary at the bottom of the file — `B3` and `B5` are done, so the remaining Phase B work is `B1 -> B2 -> B4`.

- [ ] **Step 4: Commit**

```bash
git add pipeline_references/image_glb_creation.gd PATH_TRACER_QUALITY_ROADMAP.md
git commit -m "feat(pipeline): set per-lobe bounce limits and close out Phase B3/B5"
```

- [ ] **Step 5: Hand the user a comparison render**

Report to the user, with these exact steps for them to run:

1. Copy `pipeline_references/image_glb_creation.gd` over their production copy.
2. Set `PHASE_A_OFFLINE_STILL := true` and `PHASE_A_FINAL := "none"` (OIDN still destroys alpha-blended geometry — see the Phase F defect note in the roadmap).
3. Render the same interior at `PHASE_A_ACCUM_TARGET := 256`.

What to expect, and what *not* to:
- **Grain** should be finer and more even at the same sample count — that is B5.
- **Shadowed corners and ceilings** should be brighter and warmer — that is B3.
- **Fabric** will still not read as cloth. It needs a sheen/Charlie lobe (**E2**) and is not addressed here.
- **The glass table** will still be opaque under OIDN and correct without it. Transmission inside the path tracer is **E1**, gated behind the **D** material-import work.

---

## Self-Review

**Spec coverage.** The plan covers roadmap B5 (Sobol sampler: Tasks 1-3) and B3 (per-lobe bounce controls: Tasks 4-5). The roadmap's B5 line also mentions blue-noise modes and the per-pixel `nested_uniform_scramble_base4(morton2d(...))` seed — that seed belongs to Cycles' `SAMPLING_PATTERN_BLUE_NOISE_*` paths, **not** to Sobol-Burley, which uses `hash_iqnt2d(x, y) ^ seed` (`kernel/sample/pattern.h:143` vs `:156`). The roadmap conflated the two. This plan implements Sobol-Burley, which is Cycles' default and the right target for high-sample offline stills; blue noise mainly helps at 1 spp during viewport navigation. Task 3 Step 4 corrects the roadmap text. The roadmap's B3 line also lists `min_bounce` and `max_transmission_bounce`; both are deliberately deferred with the reason recorded in Task 5 Step 3, because there are no free param slots and no consumers.

**Placeholder scan.** No TBD/TODO steps; every code step carries the literal code, every command is runnable, and every "expected" line states an observable outcome. The one genuinely unfillable value is the measured RMSE table in Task 3 Step 4, which is marked `<fill in: ...>` because it is data the run produces.

**Type consistency.** `RNGState` fields (`pixel`, `sample_index`, `offset`) are used identically in Tasks 2 and 4. `rng_1d`/`rng_2d`/`rng_pack`/`rng_unpack`/`rng_next_bounce`/`rng_side_stream` signatures declared in Task 2's Interfaces block match every call site. `PathPayload.rng_packed` is renamed once in Task 2 Step 2 and referenced consistently after. `RT_PARAM_MAX_DIFFUSE_BOUNCE`/`RT_PARAM_MAX_GLOSSY_BOUNCE` (12/13) agree across `rendering_server_enums.h`, `scene_shader_raytracing.h`, and `raytracing_inc.glsl`. `inc_glossy_bounce` adds `0x10001u` in both the C++ mirror and the GLSL. `inc_total_bounce` is deleted in Task 4 Step 5 and its only call site is replaced in Step 6.
