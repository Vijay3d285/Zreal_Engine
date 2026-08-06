/**************************************************************************/
/*  test_pt_accumulator.cpp                                               */
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

} // namespace TestPTAccumulator
