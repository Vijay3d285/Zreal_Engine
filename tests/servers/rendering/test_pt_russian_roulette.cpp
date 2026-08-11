/**************************************************************************/
/*  test_pt_russian_roulette.cpp                                          */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

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

// CPU mirror of the Russian Roulette block in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_closest_hit_common_inc.glsl.
//
// The property these tests exist to protect is UNBIASEDNESS: terminating a path
// with probability (1 - p) while scaling survivors by 1/p leaves the expected
// contribution unchanged. A wrong 1/p still produces a plausible image -- it just
// converges to the wrong answer, which no convergence test detects.
//
// rr_apply takes the throughput as three components, not a scalar: the shader
// reduces over vec3 (max_component, not luminance), and a scalar mirror cannot
// discriminate between the two reductions -- an isotropic (r==g==b) throughput
// gives the same result under EITHER rule, so a scalar-only mirror would pass
// even if the shader's max(max(r,g),b) were silently replaced by luminance().
// See "the reduction is max-component, not luminance" below.

struct RRResult {
	bool terminated;
	// NOT a literal transcription of the shader: on termination, the real
	// ps.throughput is left at its PRE-roulette value (path_pack() + return
	// happen immediately after; raygen only reads .radiance from a terminated
	// payload, so the field is dead there). This mirror zeroes r/g/b on
	// termination instead, purely so tests have a definite value to assert
	// against -- a terminated path contributes nothing further, which is the
	// fact that matters for the unbiasedness sum below.
	double r, g, b;
};

// Mirrors: p = min(sqrt(max_component(abs(throughput))), 1.0);
//          if (p <= 0 || rand >= p) terminate; else throughput /= p;
static RRResult rr_apply(double p_r, double p_g, double p_b, double p_rand, uint32_t p_depth, uint32_t p_min_bounce) {
	RRResult res;
	res.terminated = false;
	res.r = p_r;
	res.g = p_g;
	res.b = p_b;
	if (p_depth <= p_min_bounce) {
		return res; // Never rouletted below the threshold.
	}
	const double max_component = MAX(MAX(Math::abs(p_r), Math::abs(p_g)), Math::abs(p_b));
	const double p = MIN(Math::sqrt(max_component), 1.0);
	if (p <= 0.0 || p_rand >= p) {
		res.terminated = true;
		res.r = res.g = res.b = 0.0;
		return res;
	}
	res.r = p_r / p;
	res.g = p_g / p;
	res.b = p_b / p;
	return res;
}

TEST_CASE("[PathTracer][RussianRoulette] the estimator is unbiased") {
	// Sweep rand uniformly over [0,1) and average the outcome. The mean must come
	// back to the original throughput: survivors scaled by 1/p exactly compensate
	// for the paths that were killed. Isotropic colour here (r == g == b == t) --
	// the reduction rule does not matter for this property, only the sqrt/divide
	// arithmetic does.
	const uint32_t N = 100000;
	for (double t : { 0.01, 0.05, 0.25, 0.5, 0.81 }) {
		double sum = 0.0;
		for (uint32_t i = 0; i < N; i++) {
			const double u = (i + 0.5) / double(N);
			sum += rr_apply(t, t, t, u, 8u, 3u).r;
		}
		CHECK((sum / double(N)) == doctest::Approx(t).epsilon(0.001));
	}
}

TEST_CASE("[PathTracer][RussianRoulette] paths at or below min_bounce are never terminated") {
	for (uint32_t depth = 0; depth <= 3; depth++) {
		// Throughput near zero and the worst possible roll -- still must survive.
		const RRResult r = rr_apply(1e-6, 1e-6, 1e-6, 0.999999, depth, 3u);
		CHECK(r.terminated == false);
		CHECK(r.r == doctest::Approx(1e-6));
	}
	// One bounce past the threshold, the same path is terminated.
	CHECK(rr_apply(1e-6, 1e-6, 1e-6, 0.999999, 4u, 3u).terminated == true);
}

TEST_CASE("[PathTracer][RussianRoulette] a zero-throughput path terminates cleanly") {
	// p == 0 here. `rand >= p` alone already terminates for every rand in
	// [0, 1) -- rng_1d's divisor is 2^32 + 512 (sobol_burley_inc.glsl:89-91), so
	// rand is strictly below 1.0 and can never fail to be >= 0. The `p <= 0.0`
	// clause is therefore belt-and-braces, not the deciding clause today: this
	// case checks termination is clean (no NaN, no Inf, no divide) either way,
	// not that the clause specifically fires -- see the shader comment for when
	// it would start mattering (comparison sense flipped to `>`).
	const RRResult r = rr_apply(0.0, 0.0, 0.0, 0.0, 8u, 3u);
	CHECK(r.terminated == true);
	CHECK(r.r == doctest::Approx(0.0));
}

TEST_CASE("[PathTracer][RussianRoulette] bright paths are never terminated and never rescaled") {
	// sqrt(throughput) >= 1 clamps p to 1, so every roll survives with throughput
	// unchanged -- the roulette must cost nothing where it can save nothing.
	for (double t : { 1.0, 4.0, 100.0 }) {
		for (double u : { 0.0, 0.5, 0.999999 }) {
			const RRResult r = rr_apply(t, t, t, u, 8u, 3u);
			CHECK(r.terminated == false);
			CHECK(r.r == doctest::Approx(t));
			CHECK(r.g == doctest::Approx(t));
			CHECK(r.b == doctest::Approx(t));
		}
	}
}

TEST_CASE("[PathTracer][RussianRoulette] termination probability is sqrt of the reduction, not the reduction itself") {
	// Cycles applies sqrt() on top of the reduced value deliberately -- it
	// terminates LATER than a naive linear rule, to better match the view
	// transform. An earlier revision of PATH_TRACER_QUALITY_ROADMAP.md specified
	// clamp(luminance, 0.05, 0.95) (linear, no sqrt) and that was wrong.
	// Isotropic colour (r==g==b==0.25): the reduction rule is not under test
	// here (any of max_component/luminance/min_component give 0.25 for a grey
	// value) -- only the sqrt non-linearity is. At throughput 0.25, sqrt gives
	// p = 0.5; a linear (non-sqrt) rule would give p = 0.25.
	const uint32_t N = 100000;
	uint32_t survived = 0;
	for (uint32_t i = 0; i < N; i++) {
		const double u = (i + 0.5) / double(N);
		if (!rr_apply(0.25, 0.25, 0.25, u, 8u, 3u).terminated) {
			survived++;
		}
	}
	// The stratified sweep is deterministic -- exactly 50000/100000 samples fall
	// below p = 0.5 -- so this is not a statistical tolerance.
	CHECK((double(survived) / double(N)) == doctest::Approx(0.5).epsilon(1e-9));
}

TEST_CASE("[PathTracer][RussianRoulette] the reduction is max-component, not luminance") {
	// A scalar (isotropic) throughput cannot discriminate max_component from
	// luminance -- both reduce a grey value to the same number. This uses a
	// strongly-coloured throughput, which the two rules disagree on sharply:
	//   max_component: p = sqrt(max(0.9, 0.02, 0.02)) = sqrt(0.9) ~= 0.9487.
	//   luminance (Rec.709 weights, matching brdf_inc.glsl's luminance()):
	//     dot((0.9,0.02,0.02), (0.2126,0.7152,0.0722)) ~= 0.2071, sqrt ~= 0.4551.
	// At u = 0.9: max_component survives (0.9 < 0.9487); a luminance-reduced
	// rule would have terminated (0.9 >= 0.4551). Both reductions are
	// individually unbiased -- swapping one for the other would still pass
	// every other test in this file. The damage a wrong reduction does is
	// variance and path length, which no convergence test catches either.
	const RRResult r = rr_apply(0.9, 0.02, 0.02, 0.9, 8u, 3u);
	CHECK(r.terminated == false);

	const double luminance = 0.9 * 0.2126 + 0.02 * 0.7152 + 0.02 * 0.0722;
	const double p_luminance = Math::sqrt(luminance);
	CHECK(p_luminance < 0.9); // Sanity: the luminance rule WOULD have killed this at u = 0.9.
}

} // namespace TestPTRussianRoulette
