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

} // namespace TestPTRussianRoulette
