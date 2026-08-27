/**************************************************************************/
/*  test_pt_coat_albedo.cpp                                               */
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

TEST_FORCE_LINK(test_pt_coat_albedo)

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/storage_rd/ggx_coat_albedo_table.h"

namespace TestPTCoatAlbedo {

// CPU mirrors of Cycles' lookup_table_read* (intern/cycles/kernel/util/lookup_table.h)
// and bsdf_microfacet_estimate_albedo's dielectric branch
// (intern/cycles/kernel/closure/bsdf_microfacet.h:556-579).
//
// THE INDEXING IS ENDPOINT-ALIGNED, NOT HALF-TEXEL-CENTERED. Cycles maps
// [0,1] onto [0, size-1] and lerps between integer entries. A hardware 3D
// texture sampler maps [0,1] onto texel CENTERS instead, which is off by half
// a texel everywhere -- it compiles, it renders, and it is silently wrong.
// The midpoint cases below are what tell the two apart.

static float coat_lut_read_1d(const float *p_data, float p_x, int p_size) {
	p_x = CLAMP(p_x, 0.0f, 1.0f) * float(p_size - 1);
	const int index = MIN(int(p_x), p_size - 1);
	const int nindex = MIN(index + 1, p_size - 1);
	const float t = p_x - float(index);
	const float data0 = p_data[index];
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * p_data[nindex];
}

static float coat_lut_read_2d(const float *p_data, float p_x, float p_y, int p_xsize, int p_ysize) {
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(p_ysize - 1);
	const int index = MIN(int(p_y), p_ysize - 1);
	const int nindex = MIN(index + 1, p_ysize - 1);
	const float t = p_y - float(index);
	const float data0 = coat_lut_read_1d(p_data + p_xsize * index, p_x, p_xsize);
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * coat_lut_read_1d(p_data + p_xsize * nindex, p_x, p_xsize);
}

static float coat_lut_read_3d(float p_x, float p_y, float p_z) {
	const int d = GGX_COAT_TABLE_DIM;
	p_z = CLAMP(p_z, 0.0f, 1.0f) * float(d - 1);
	const int index = MIN(int(p_z), d - 1);
	const int nindex = MIN(index + 1, d - 1);
	const float t = p_z - float(index);
	const float data0 = coat_lut_read_2d(GGX_COAT_ALBEDO_TABLE + d * d * index, p_x, p_y, d, d);
	if (t == 0.0f) {
		return data0;
	}
	const float data1 = coat_lut_read_2d(GGX_COAT_ALBEDO_TABLE + d * d * nindex, p_x, p_y, d, d);
	return (1.0f - t) * data0 + t * data1;
}

// q = (ior-1)/(ior+1). F0 SQUARES it; z takes its square ROOT. Opposite
// directions from the same quantity -- swapping them type-checks and is wrong.
static float coat_f0_from_ior(float p_ior) {
	const float q = (p_ior - 1.0f) / (p_ior + 1.0f);
	return q * q;
}

static float coat_z_from_ior(float p_ior) {
	return Math::sqrt(Math::abs((p_ior - 1.0f) / (p_ior + 1.0f)));
}

static float coat_albedo_estimate(float p_coat_roughness, float p_cos_ni, float p_ior) {
	const float alpha = p_coat_roughness * p_coat_roughness;
	const float rough = Math::sqrt(Math::sqrt(alpha * alpha)); // sqrt(sqrt(ax*ay)), ax == ay
	const float z = coat_z_from_ior(p_ior);
	const float s = coat_lut_read_3d(rough, p_cos_ni, z);
	return Math::lerp(coat_f0_from_ior(p_ior), 1.0f, s);
}

TEST_CASE("[PathTracer][CoatAlbedo] the table is the one Cycles ships") {
	// Guards against a re-extraction silently pulling a different table or a
	// truncated one. Values read directly out of shader.tables at these
	// indices; index = x + 16*y + 256*z.
	CHECK(GGX_COAT_ALBEDO_TABLE[256] == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[257] == doctest::Approx(0.702628f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[272] == doctest::Approx(0.144157f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[2184] == doctest::Approx(0.037176f).epsilon(1e-6));
	CHECK(GGX_COAT_ALBEDO_TABLE[3840] == doctest::Approx(0.504788f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] reads at grid points return entries exactly") {
	// Endpoint-aligned: u = i/15 lands EXACTLY on entry i, t == 0, early-out.
	// A half-texel-centered sampler returns a blend here instead.
	const float u1 = 1.0f / 15.0f;
	CHECK(coat_lut_read_3d(0.0f, 0.0f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(u1, 0.0f, u1) == doctest::Approx(0.702628f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(0.0f, u1, u1) == doctest::Approx(0.144157f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] midpoints lerp between neighbours") {
	// THE case that separates endpoint-aligned from half-texel-centered.
	// Halfway between x=0 and x=1 at y=0, z=1 must be the mean of 0.996991
	// and 0.702628. A half-texel sampler reads somewhere else entirely, and
	// this table's gradient here is steep enough that it cannot coincide.
	const float u1 = 1.0f / 15.0f;
	const float expected_x = 0.5f * (0.996991f + 0.702628f);
	CHECK(coat_lut_read_3d(0.5f * u1, 0.0f, u1) == doctest::Approx(expected_x).epsilon(1e-5));

	const float expected_y = 0.5f * (0.996991f + 0.144157f);
	CHECK(coat_lut_read_3d(0.0f, 0.5f * u1, u1) == doctest::Approx(expected_y).epsilon(1e-5));
}

TEST_CASE("[PathTracer][CoatAlbedo] out-of-range inputs saturate, they do not wrap") {
	// cos_NI is NOT clamped by Cycles before the read (bsdf_microfacet.h:504);
	// the saturate inside the table read absorbs it onto the cos_NI = 0 row.
	const float u1 = 1.0f / 15.0f;
	CHECK(coat_lut_read_3d(0.0f, -0.5f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	CHECK(coat_lut_read_3d(0.0f, 0.0f, u1) == doctest::Approx(0.996991f).epsilon(1e-6));
	// Top edge clamps rather than reading past the end.
	CHECK(coat_lut_read_3d(1.0f, 1.0f, 1.0f) == doctest::Approx(GGX_COAT_ALBEDO_TABLE[4095]).epsilon(1e-6));
	CHECK(coat_lut_read_3d(2.0f, 2.0f, 2.0f) == doctest::Approx(GGX_COAT_ALBEDO_TABLE[4095]).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] F0 and z are built from q in opposite directions") {
	// ior 1.5 -> q = 0.2. F0 = 0.04 (the familiar dielectric value); z = sqrt(0.2).
	const float q = (1.5f - 1.0f) / (1.5f + 1.0f);
	CHECK(q == doctest::Approx(0.2f).epsilon(1e-6));
	CHECK(coat_f0_from_ior(1.5f) == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(coat_z_from_ior(1.5f) == doctest::Approx(0.4472136f).epsilon(1e-6));
	// Pin the counterfactual: swapping them is NOT a near miss, it is 10x off.
	CHECK(Math::abs(coat_f0_from_ior(1.5f) - coat_z_from_ior(1.5f)) > 0.4f);
}

TEST_CASE("[PathTracer][CoatAlbedo] the estimate is bounded and rises toward grazing") {
	// At normal incidence the estimate must approach F0; at grazing it must
	// approach 1. Both are physical facts about Fresnel, independent of the
	// table, so this fails if the y axis is inverted -- a mistake no rendered
	// image would make obvious.
	const float at_normal = coat_albedo_estimate(0.1f, 1.0f, 1.5f);
	const float at_grazing = coat_albedo_estimate(0.1f, 0.0f, 1.5f);
	CHECK(at_normal == doctest::Approx(0.04f).epsilon(0.02));
	CHECK(at_grazing > 0.5f);
	CHECK(at_grazing > at_normal);
	CHECK(at_normal >= 0.0f);
	CHECK(at_grazing <= 1.0f);
}

} // namespace TestPTCoatAlbedo
