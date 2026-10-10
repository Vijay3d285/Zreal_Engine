/**************************************************************************/
/*  test_pt_temporal.cpp                                                  */
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

TEST_FORCE_LINK(test_pt_temporal)

#include "servers/rendering/renderer_rd/effects/pt_temporal_state.h"

#include "core/math/math_funcs.h"
#include "core/math/vector3.h"

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

} // namespace TestPTTemporal
