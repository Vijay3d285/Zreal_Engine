/**************************************************************************/
/*  test_pt_filter_glossy.cpp                                             */
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

TEST_FORCE_LINK(test_pt_filter_glossy)

#include "core/math/math_funcs.h"

namespace TestPTFilterGlossy {

// Mirrors of the GLSL in raytracing_inc.glsl (Filter Glossy). Keep in lockstep.
static uint32_t encode(float p_pdf) {
	if (!(p_pdf > 0.0f) || p_pdf >= 16.0f) {
		return 0u;
	}
	return (uint32_t)MIN(31.0f, Math::floor(3.0f * (4.0f - Math::log(p_pdf) / Math::log(2.0f))) + 1.0f);
}
static float decode(uint32_t p_code) {
	return Math::pow(2.0f, 4.0f - float(p_code - 1u) / 3.0f);
}
static uint32_t update(uint32_t p_code, float p_pdf) {
	return MAX(p_code, encode(p_pdf));
}
static float alpha_floor(uint32_t p_code, float p_fg) {
	if (p_code == 0u || !(p_fg > 0.0f)) {
		return 0.0f;
	}
	const float blur_pdf = p_fg * decode(p_code);
	return blur_pdf < 1.0f ? Math::sqrt(1.0f - blur_pdf) * 0.5f : 0.0f;
}

static float exact_floor(float p_blur_pdf) {
	return p_blur_pdf < 1.0f ? Math::sqrt(1.0f - p_blur_pdf) * 0.5f : 0.0f;
}

TEST_CASE("[PathTracer][FilterGlossy] code 0 means no bounce yet and never blurs") {
	CHECK(alpha_floor(0u, 1.0f) == 0.0f);
	CHECK(alpha_floor(0u, 100.0f) == 0.0f);
}

TEST_CASE("[PathTracer][FilterGlossy] a stored minimum is never smaller than the true one, and within one step") {
	const float step = Math::pow(2.0f, 1.0f / 3.0f);
	for (float p = 1.0f / 64.0f; p < 16.0f; p *= 1.0137f) {
		const uint32_t c = encode(p);
		CHECK(c >= 1u);
		CHECK(c <= 31u);
		const float d = decode(c);
		CHECK(d >= p * (1.0f - 1e-5f));
		CHECK(d < p * step * (1.0f + 1e-5f));
	}
}

TEST_CASE("[PathTracer][FilterGlossy] pdfs of 16 or more, and non-positive pdfs, do not lower the minimum") {
	CHECK(encode(16.0f) == 0u);
	CHECK(encode(1000.0f) == 0u);
	CHECK(encode(0.0f) == 0u);
	CHECK(encode(-1.0f) == 0u);
	CHECK(encode(0.001f) == 31u); // below 2^-6 clamps to the last code
	CHECK(decode(31u) == doctest::Approx(1.0f / 64.0f));
	CHECK(decode(1u) == doctest::Approx(16.0f));
}

TEST_CASE("[PathTracer][FilterGlossy] the running update keeps the smaller pdf") {
	const uint32_t a = update(0u, 0.3f);
	CHECK(a == encode(0.3f));
	CHECK(update(a, 2.0f) == a); // a later, larger pdf does not raise the minimum
	CHECK(update(a, 0.05f) == encode(0.05f)); // a later, smaller pdf lowers it
	CHECK(update(a, 50.0f) == a); // a near-delta pdf never matters
}

TEST_CASE("[PathTracer][FilterGlossy] the floor follows Cycles and is never stronger") {
	CHECK(exact_floor(0.318f) == doctest::Approx(0.4129f).epsilon(1e-3));
	CHECK(exact_floor(1.0f) == 0.0f);
	const uint32_t c = encode(0.318f); // a diffuse bounce, cos/pi at normal incidence
	const float q = alpha_floor(c, 1.0f);
	CHECK(q > 0.0f);
	CHECK(q <= exact_floor(0.318f) + 1e-6f);
	CHECK(q >= exact_floor(0.318f) - 0.03f);
	CHECK(alpha_floor(encode(2.0f), 1.0f) == 0.0f); // blur_pdf >= 1: no blur
	CHECK(alpha_floor(c, 0.0f) == 0.0f); // setting 0: off
	CHECK(alpha_floor(encode(0.001f), 1.0f) <= 0.5f); // never above Cycles' 0.5 cap
}

} // namespace TestPTFilterGlossy
