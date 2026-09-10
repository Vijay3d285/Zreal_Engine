/**************************************************************************/
/*  test_pt_ms_energy.cpp                                                 */
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

TEST_FORCE_LINK(test_pt_ms_energy)

#include "core/math/math_funcs.h"
#include "servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h"

namespace TestPTMsEnergy {

// CPU mirror of evalMultiScatterEnergy / ggxE / ggxEavg in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl, which mirror
// microfacet_ggx_preserve_energy
// (intern/cycles/kernel/closure/bsdf_microfacet.h:466-485).
//
// THIS FILE DOES NOT EXECUTE THE SHADER. The doctest binary never runs GLSL --
// every one of these assertions would still pass if the shader were reverted and
// this mirror left untouched. It guards the ARITHMETIC only. The evidence that
// the shader itself is right is pt_anisotropy_gate.gd's white furnace, and
// nothing here substitutes for it.
//
// THE INDEXING IS ENDPOINT-ALIGNED, NOT HALF-TEXEL-CENTERED, matching
// ggxLutRead1D/2D. A hardware-filtered texture would be off by half a texel
// everywhere -- it would compile, render, and be silently wrong.

static float ms_lut_read_1d(const float *p_data, float p_x, int p_size) {
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

static float ms_lut_read_2d(const float *p_data, float p_x, float p_y, int p_xsize, int p_ysize) {
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(p_ysize - 1);
	const int index = MIN(int(p_y), p_ysize - 1);
	const int nindex = MIN(index + 1, p_ysize - 1);
	const float t = p_y - float(index);
	const float data0 = ms_lut_read_1d(p_data + p_xsize * index, p_x, p_xsize);
	if (t == 0.0f) {
		return data0;
	}
	return (1.0f - t) * data0 + t * ms_lut_read_1d(p_data + p_xsize * nindex, p_x, p_xsize);
}

static const int MS_E_DIM = 32;

static float ms_ggx_e(float p_alpha, float p_cos_nv) {
	const float rough = Math::sqrt(p_alpha); // = sqrt(sqrt(ax*ay)); ax*ay == alpha^2.
	return ms_lut_read_2d(GGX_E_TABLE, rough, p_cos_nv, MS_E_DIM, MS_E_DIM);
}

static float ms_ggx_eavg(float p_alpha) {
	const float rough = Math::sqrt(p_alpha);
	return ms_lut_read_1d(GGX_EAVG_TABLE, rough, MS_E_DIM);
}

// Fss = mix(F0, F90, 1/21). See section 5.3 of
// docs/superpowers/specs/2026-09-10-ggx-multiscatter-energy-design.md for why one
// constant covers both Cycles' F82 metallic branch and its generalized-Schlick
// dielectric branch.
static float ms_energy_factor(float p_alpha, float p_cos_nv, float p_f0, float p_f90) {
	const float e = ms_ggx_e(p_alpha, p_cos_nv);
	const float eavg = ms_ggx_eavg(p_alpha);
	const float missing = (1.0f - e) / e;
	const float fss = p_f0 + (p_f90 - p_f0) * (1.0f / 21.0f);
	const float fms = fss * eavg / (1.0f - fss * (1.0f - eavg));
	return 1.0f + fms * missing;
}

TEST_CASE("[PathTracer][MsEnergy] a white lobe is compensated to exactly unity") {
	// THE LOAD-BEARING CASE. For the furnace material (albedo 1, metallic 1)
	// F0 == F90 == 1, so Fss = mix(1, 1, 1/21) = 1 and
	// Fms = Eavg / (1 - (1 - Eavg)) = Eavg / Eavg = 1. The factor therefore
	// collapses to exactly 1/E, and a single-scattering lobe of directional
	// albedo E multiplied by 1/E returns exactly 1.
	//
	// This is why pt_anisotropy_gate.gd's white furnace must read 1.0 by
	// DERIVATION rather than by tuning. If this case ever fails, the furnace
	// cannot pass and no tolerance change will rescue it.
	const float alphas[] = { 0.0f, 0.04f, 0.16f, 0.5f, 0.81f, 1.0f };
	const float mus[] = { 0.05f, 0.3f, 0.5f, 0.7f, 1.0f };
	for (float alpha : alphas) {
		for (float mu : mus) {
			const float e = ms_ggx_e(alpha, mu);
			const float factor = ms_energy_factor(alpha, mu, 1.0f, 1.0f);
			CHECK(e * factor == doctest::Approx(1.0f).epsilon(1e-5));
		}
	}
}

TEST_CASE("[PathTracer][MsEnergy] E is read on the (rough, mu) axes, not transposed") {
	// A transposed read compiles, renders, and is wrong. These four anchors
	// pin the convention: E is 1 everywhere at zero roughness, and falls
	// monotonically as roughness rises at fixed mu.
	CHECK(ms_ggx_e(0.0f, 0.2f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_ggx_e(0.0f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_ggx_e(0.16f, 1.0f) > ms_ggx_e(0.81f, 1.0f));
	CHECK(ms_ggx_e(0.81f, 1.0f) > ms_ggx_e(1.0f, 1.0f));
}

TEST_CASE("[PathTracer][MsEnergy] reference values match the table by hand") {
	// Computed directly from GGX_E_TABLE / GGX_EAVG_TABLE with the same
	// endpoint-aligned reads. alpha = roughness^2, so alpha 0.16 is
	// roughness 0.4 and alpha 0.81 is roughness 0.9.
	CHECK(ms_ggx_e(0.16f, 0.7f) == doctest::Approx(0.950187f).epsilon(1e-5));
	CHECK(ms_ggx_eavg(0.16f) == doctest::Approx(0.940142f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.16f, 0.7f, 0.04f, 1.0f) == doctest::Approx(1.004246f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.16f, 0.7f, 1.0f, 1.0f) == doctest::Approx(1.052424f).epsilon(1e-5));

	CHECK(ms_ggx_e(0.81f, 0.5f) == doctest::Approx(0.535442f).epsilon(1e-5));
	CHECK(ms_ggx_eavg(0.81f) == doctest::Approx(0.502403f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.81f, 0.5f, 0.04f, 1.0f) == doctest::Approx(1.039027f).epsilon(1e-5));
	CHECK(ms_energy_factor(0.81f, 0.5f, 1.0f, 1.0f) == doctest::Approx(1.867616f).epsilon(1e-5));
}

TEST_CASE("[PathTracer][MsEnergy] a mirror needs no compensation") {
	// At alpha 0 there is no multiple scattering to recover, so the factor is
	// exactly 1 for every F0. This is what keeps pt_energy_gate's roughness-0.02
	// `smooth` sphere essentially unmoved by this change.
	CHECK(ms_energy_factor(0.0f, 1.0f, 0.04f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(ms_energy_factor(0.0f, 0.3f, 1.0f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][MsEnergy] the factor never darkens and rises with roughness") {
	// Energy compensation adds energy back; it can never remove any. A factor
	// below 1 would mean the table or the Fms algebra is inverted.
	const float mus[] = { 0.1f, 0.5f, 1.0f };
	for (float mu : mus) {
		CHECK(ms_energy_factor(0.16f, mu, 0.5f, 1.0f) >= 1.0f);
		CHECK(ms_energy_factor(0.81f, mu, 0.5f, 1.0f) >= ms_energy_factor(0.16f, mu, 0.5f, 1.0f));
	}
}

} // namespace TestPTMsEnergy
