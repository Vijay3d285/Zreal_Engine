/**************************************************************************/
/*  test_pt_bounce_limits.cpp                                             */
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
