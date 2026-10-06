/**************************************************************************/
/*  test_pt_rt_flags_variant_key.cpp                                      */
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

TEST_FORCE_LINK(test_pt_rt_flags_variant_key)

#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_raytracing.h"

namespace TestPTRtFlagsVariantKey {

// Unlike the CPU mirrors in test_pt_russian_roulette.cpp, these cases call the REAL
// SceneShaderRaytracing::compute_rt_flags(). The property under test is the pipeline-variant
// key: the sample-count field of the packed rt_flags word is 0 exactly when the environment's
// accumulate flag is set (the Phase A raygen branch never reads the count), and
// _ensure_variant_compile_context() turns that 0 into `#define RT_OIDN_FEATURES`, which compiles
// the OIDN guide-feature code into the accumulate variant ONLY. A drift here is silent in both
// directions: a one-shot word with field 0 would compile the guide code into the DLSS-RR
// one-shot pipeline (a performance and identity regression), and an accumulate word with a
// non-zero field would leave OIDN stills and video without their guides, a plausible-looking
// but wrong render. Nothing else in the suite would fail.

using RendererSceneRenderImplementation::SceneShaderRaytracing;

// Environment pathtracing_params[16], the layout compute_rt_flags() reads.
struct EnvParams {
	float p[16];
	EnvParams(float p_accumulate, float p_sample_count) {
		for (int i = 0; i < 16; i++) {
			p[i] = 0.0f;
		}
		p[SceneShaderRaytracing::RT_PARAM_SAMPLE_COUNT] = p_sample_count;
		p[SceneShaderRaytracing::RT_PARAM_MAX_BOUNCES] = 8.0f;
		p[SceneShaderRaytracing::RT_PARAM_ACCUM_FLAG] = p_accumulate;
	}
};

static uint32_t sample_count_field(uint32_t p_rt_flags) {
	return (p_rt_flags >> SceneShaderRaytracing::RT_SAMPLE_COUNT_SHIFT) & SceneShaderRaytracing::RT_SAMPLE_COUNT_MASK;
}

static uint32_t flags_for(const EnvParams &p_params) {
	return SceneShaderRaytracing::compute_rt_flags(p_params.p, false, false);
}

TEST_CASE("[PathTracer][VariantKey] the accumulate flag packs sample-count field 0") {
	// Whatever the one-shot sample count says, accumulate wins: the field is the variant key.
	for (float spp : { 0.0f, 1.0f, 3.0f, 4.0f, 127.0f, 128.0f, 1000.0f }) {
		const EnvParams params(1.0f, spp);
		CHECK(sample_count_field(flags_for(params)) == 0u);
	}
}

TEST_CASE("[PathTracer][VariantKey] one-shot packs a sample-count field of at least 1") {
	// 0 and 1 both mean one sample; 4 and 6 pass through unchanged (6 is the DLSS-RR video
	// job's samples-per-pixel: its one-shot raygen loop traces exactly that many samples);
	// 127 is the field's top; 128 and 1000 must CLAMP to 127 (a masked 128 would read as 0 --
	// the accumulate key -- and silently switch variants).
	struct Case {
		float spp;
		uint32_t expected_field;
	};
	const Case cases[] = {
		{ 0.0f, 1u },
		{ 1.0f, 1u },
		{ 4.0f, 4u },
		{ 6.0f, 6u },
		{ 127.0f, 127u },
		{ 128.0f, 127u },
		{ 1000.0f, 127u },
	};
	for (const Case &c : cases) {
		const EnvParams params(0.0f, c.spp);
		const uint32_t field = sample_count_field(flags_for(params));
		CHECK(field >= 1u);
		CHECK(field == c.expected_field);
	}
}

TEST_CASE("[PathTracer][VariantKey] no environment params is a one-shot word") {
	// RT active with no pathtracing environment: compute_rt_flags(nullptr, ...).
	CHECK(sample_count_field(SceneShaderRaytracing::compute_rt_flags(nullptr, false, false)) >= 1u);
}

TEST_CASE("[PathTracer][VariantKey] the accumulate flag test is strictly greater than 0.5") {
	// The raygen branch is `get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5`; the key must agree with it
	// on every value, so exactly 0.5 is one-shot.
	CHECK(sample_count_field(flags_for(EnvParams(0.0f, 4.0f))) >= 1u);
	CHECK(sample_count_field(flags_for(EnvParams(0.4999f, 4.0f))) >= 1u);
	CHECK(sample_count_field(flags_for(EnvParams(0.5f, 4.0f))) >= 1u);
	CHECK(sample_count_field(flags_for(EnvParams(0.5001f, 4.0f))) == 0u);
	CHECK(sample_count_field(flags_for(EnvParams(1.0f, 4.0f))) == 0u);
}

TEST_CASE("[PathTracer][VariantKey] the accumulate and one-shot words differ only in the sample-count field") {
	// Same environment, accumulate on vs off. Every other bit of the word -- feature flags,
	// bounce caps, the +1-biased min_bounce field -- must be identical, or a job that toggles
	// accumulate (every DLSS-RR daylight probe does) would also be switching unrelated variants.
	const uint32_t field_bits = SceneShaderRaytracing::RT_SAMPLE_COUNT_MASK << SceneShaderRaytracing::RT_SAMPLE_COUNT_SHIFT;
	for (float denoiser : { float(RSE::PT_DENOISER_NONE), float(RSE::PT_DENOISER_DLSS_RAY_RECONSTRUCTION) }) {
		for (float max_bounces : { 1.0f, 8.0f, 16.0f }) {
			for (float spp : { 1.0f, 4.0f, 127.0f }) {
				EnvParams one_shot(0.0f, spp);
				EnvParams accumulate(1.0f, spp);
				one_shot.p[SceneShaderRaytracing::RT_PARAM_DENOISER] = denoiser;
				accumulate.p[SceneShaderRaytracing::RT_PARAM_DENOISER] = denoiser;
				one_shot.p[SceneShaderRaytracing::RT_PARAM_MAX_BOUNCES] = max_bounces;
				accumulate.p[SceneShaderRaytracing::RT_PARAM_MAX_BOUNCES] = max_bounces;

				const uint32_t word_one_shot = flags_for(one_shot);
				const uint32_t word_accumulate = flags_for(accumulate);
				CHECK(((word_one_shot ^ word_accumulate) & ~field_bits) == 0u);
				// And the words really are two different variants: the field is the whole difference.
				CHECK(word_one_shot != word_accumulate);
			}
		}
	}
}

TEST_CASE("[PathTracer][VariantKey] the accumulate word is never zero") {
	// render_raytracing.h's accum_last_rt_flags uses 0 as "nothing seen yet" and relies on a
	// settled word never being 0. With sample-count field 0 on the accumulate word, that rests
	// on the min_bounce field, stored +1-biased so it is non-zero whatever the value.
	for (float denoiser : { float(RSE::PT_DENOISER_NONE), float(RSE::PT_DENOISER_DLSS_RAY_RECONSTRUCTION) }) {
		EnvParams params(1.0f, 4.0f);
		params.p[SceneShaderRaytracing::RT_PARAM_DENOISER] = denoiser;
		CHECK(flags_for(params) != 0u);
	}
}

} // namespace TestPTRtFlagsVariantKey
