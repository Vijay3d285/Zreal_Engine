/**************************************************************************/
/*  test_pt_accumulator.cpp                                               */
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

TEST_FORCE_LINK(test_pt_accumulator)

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

} // namespace TestPTAccumulator
