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
#include "servers/rendering/renderer_rd/storage_rd/ggx_energy_tables.h"

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

// ---------------------------------------------------------------------------
// E2d Task 5b: real multiple-scattering energy compensation for the coat.
//
// CPU mirror of microfacet_ggx_preserve_energy
// (intern/cycles/kernel/closure/bsdf_microfacet.h:432-485). Reuses
// coat_lut_read_1d / coat_lut_read_2d above -- there is deliberately no second
// copy of the table reader.
//
// THE DERIVATION, because the two multipliers below are easy to swap:
//
//   Cycles multiplies the BSDF VALUE by energy_scale = 1/E, and the closure
//   WEIGHT by darkening = (1 + Fms*(1-E)/E) / energy_scale = E + Fms*(1-E).
//   Their product -- the only thing a renderer that carries no separate
//   closure weight can observe -- is
//
//       energy_scale * darkening = 1 + Fms * (1 - E) / E     ... (C)
//
//   which is what a coat BSDF sample or evaluation must be multiplied by.
//
//   BUT the two are NOT interchangeable, because Cycles uses them for two
//   different things and this engine needs BOTH:
//
//     * (C) scales what the coat PAYS OUT (evalCoat, and the coat sampler's
//       weight).
//     * `darkening` alone scales what the coat WITHDRAWS from the layers below
//       it: closure_layering_weight reads bsdf_albedo, which is sc->weight
//       (already multiplied by darkening in preserve_energy) times
//       estimate_albedo -- see bsdf.h:696 and svm/closure.h:172-174.
//
//   That second half is what makes the layer balance. estimate_albedo is the
//   albedo the coat WOULD have if GGX were energy-preserving (the LUT is built
//   from eval.x/eval.y, a Fresnel RATIO with the single-scattering loss divided
//   out -- app/cycles_precompute.cpp:88-130), so the coat's true reflectance is
//   E * C * estimate, i.e. `darkening * estimate`. Withdrawing the raw
//   `estimate` while paying out `E * C * estimate` is exactly the energy leak
//   Task 5's review measured, and multiplying the payout by C alone only moves
//   it from E to E*C (0.915 -> 0.922 at roughness 0.5, normal incidence). Both
//   halves are required.
// ---------------------------------------------------------------------------

static float coat_fss_from_ior(float p_ior) {
	// fresnel_dielectric_Fss, bsdf_util.h:131-137. eta >= 1 branch only:
	// coat_ior is clamped to >= 1 on upload, so the eta < 1 polynomial is
	// unreachable here. Do not port it "for completeness" -- an unreachable
	// branch is an untested branch.
	return (p_ior - 1.0f) / (4.08567f + 1.00071f * p_ior);
}

// E(rough, mu): the directional albedo of a WHITE-Fresnel single-scattering
// GGX lobe. Everything below is built from this one read.
static float coat_ggx_e(float p_coat_roughness, float p_cos_ni) {
	const float alpha = p_coat_roughness * p_coat_roughness;
	const float rough = Math::sqrt(Math::sqrt(alpha * alpha)); // sqrt(sqrt(ax*ay)), ax == ay
	return coat_lut_read_2d(GGX_E_TABLE, rough, p_cos_ni, GGX_E_DIM, GGX_E_DIM);
}

// Fms: the effective Fresnel of the multiply-scattered energy. One Fss is
// cancelled out because it multiplies a BSDF that already carries one bounce
// of Fresnel (bsdf_microfacet.h:474-476).
static float coat_fms(float p_coat_roughness, float p_ior) {
	const float alpha = p_coat_roughness * p_coat_roughness;
	const float rough = Math::sqrt(Math::sqrt(alpha * alpha));
	const float e_avg = coat_lut_read_1d(GGX_EAVG_TABLE, rough, GGX_E_DIM);
	const float fss = coat_fss_from_ior(p_ior);
	return fss * e_avg / (1.0f - fss * (1.0f - e_avg));
}

// (C) above: the multiplier on the coat's BSDF value / sample weight.
static float coat_energy_scale(float p_coat_roughness, float p_cos_ni, float p_ior) {
	const float e = coat_ggx_e(p_coat_roughness, p_cos_ni);
	return 1.0f + coat_fms(p_coat_roughness, p_ior) * (1.0f - e) / e;
}

// Cycles' `darkening`: the multiplier on the coat's LAYERING albedo, i.e. on
// what it withdraws from everything underneath. Written in the algebraically
// reduced form E + Fms*(1-E), which is identical to E * coat_energy_scale.
static float coat_darkening(float p_coat_roughness, float p_cos_ni, float p_ior) {
	const float e = coat_ggx_e(p_coat_roughness, p_cos_ni);
	return e + coat_fms(p_coat_roughness, p_ior) * (1.0f - e);
}

TEST_CASE("[PathTracer][CoatAlbedo] the energy tables are the ones Cycles ships") {
	// Same role as the albedo-table case above: a re-extraction that silently
	// pulls a different or truncated table fails here rather than in an image.
	// Values read directly out of shader.tables.
	CHECK(GGX_E_TABLE[0] == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(GGX_E_TABLE[1] == doctest::Approx(0.980405f).epsilon(1e-6));
	CHECK(GGX_E_TABLE[32] == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(GGX_E_TABLE[33] == doctest::Approx(0.999451f).epsilon(1e-6));
	CHECK(GGX_E_TABLE[1023] == doctest::Approx(0.306853f).epsilon(1e-6));
	CHECK(GGX_EAVG_TABLE[0] == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(GGX_EAVG_TABLE[31] == doctest::Approx(0.409137f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][CoatAlbedo] SSBO offsets are the ones the shader hard-codes") {
	// GLSL cannot include ggx_energy_tables.h, so brdf_inc.glsl mirrors these
	// four constants as #defines (RT_COAT_SSBO_ALBEDO_OFFSET etc.). The
	// static_asserts in the header pin them to the three sizeof()s; this case
	// pins them to the LITERALS written into the shader. Changing the C++ side
	// alone therefore fails here, which is the only cross-language check
	// available -- if you edit this case, edit brdf_inc.glsl in the same commit.
	CHECK(RT_COAT_SSBO_ALBEDO_OFFSET == 0);
	CHECK(RT_COAT_SSBO_E_OFFSET == 4096);
	CHECK(RT_COAT_SSBO_EAVG_OFFSET == 5120);
	CHECK(RT_COAT_SSBO_FLOAT_COUNT == 5152);
	// The offsets alone do not pin the table SHAPE: re-extracting GGX_E_TABLE /
	// GGX_EAVG_TABLE at a different resolution can hold RT_COAT_SSBO_E_OFFSET
	// and RT_COAT_SSBO_EAVG_OFFSET fixed (padding the tail) while every read
	// above them silently samples the wrong sub-rectangle. brdf_inc.glsl mirrors
	// GGX_E_DIM as its own #define (GGX_E_DIM, next to GGX_COAT_TABLE_DIM); this
	// pins that mirror to the literal written into the shader, same as the
	// offsets above -- if you edit this case, edit brdf_inc.glsl in the same commit.
	CHECK(GGX_E_DIM == 32);
	CHECK(GGX_COAT_TABLE_DIM == 16);
}

TEST_CASE("[PathTracer][CoatAlbedo] Fss matches Cycles' dielectric fit") {
	// bsdf_util.h:136, (eta-1)/(4.08567 + 1.00071*eta).
	CHECK(coat_fss_from_ior(1.5f) == doctest::Approx(0.089487f).epsilon(1e-4));
	CHECK(coat_fss_from_ior(1.0f) == doctest::Approx(0.0f).epsilon(1e-6));
	CHECK(coat_fss_from_ior(1.5f) < coat_fss_from_ior(2.0f));
}

TEST_CASE("[PathTracer][CoatAlbedo] energy compensation exceeds 1 and grows with roughness") {
	// The whole point: a rough lobe loses more single-scattering energy, so it
	// needs a larger multiplier back. A stub returning 1.0 fails this.
	const float smooth = coat_energy_scale(0.05f, 0.8f, 1.5f);
	const float rough = coat_energy_scale(0.80f, 0.8f, 1.5f);
	CHECK(smooth >= 1.0f);
	CHECK(rough > smooth);
	// Pin the counterfactual: the old evalMultiScatterApproximation at the
	// coat's F0 = 0.04 is ~1.002 and CANNOT reach this.
	CHECK(rough > 1.01f);
}

TEST_CASE("[PathTracer][CoatAlbedo] compensation is larger where the measured gap was worse") {
	for (float rough : { 0.2f, 0.5f, 0.8f }) {
		for (float mu : { 1.0f, 0.7f, 0.3f }) {
			CAPTURE(rough);
			CAPTURE(mu);
			CHECK(coat_energy_scale(rough, mu, 1.5f) >= 1.0f);
		}
	}
	// Directionally: the compensation must be larger exactly where the measured
	// gap was worse -- rougher, and further from normal incidence.
	CHECK(coat_energy_scale(0.5f, 0.3f, 1.5f) > coat_energy_scale(0.5f, 1.0f, 1.5f));
	CHECK(coat_energy_scale(0.8f, 1.0f, 1.5f) > coat_energy_scale(0.2f, 1.0f, 1.5f));
}

TEST_CASE("[PathTracer][CoatAlbedo] darkening is E times the energy scale, and below 1") {
	// The identity the two reduced forms rest on:
	//   darkening = E + Fms*(1-E)  ==  E * (1 + Fms*(1-E)/E)  ==  E * C.
	// If either function is edited into a different shape, this fails.
	for (float rough : { 0.05f, 0.2f, 0.5f, 0.8f, 1.0f }) {
		for (float mu : { 1.0f, 0.7f, 0.3f, 0.0f }) {
			CAPTURE(rough);
			CAPTURE(mu);
			const float e = coat_ggx_e(rough, mu);
			CHECK(coat_darkening(rough, mu, 1.5f) ==
					doctest::Approx(e * coat_energy_scale(rough, mu, 1.5f)).epsilon(1e-5));
			// E < 1 for any lossy lobe and C is only ~1.04 at its largest, so
			// the coat's true reflectance is always BELOW the LUT's
			// energy-preserving estimate. A darkening >= 1 would mean the coat
			// withdrew more than it can possibly reflect.
			CHECK(coat_darkening(rough, mu, 1.5f) <= 1.0f);
		}
	}
}

TEST_CASE("[PathTracer][CoatAlbedo] withdrawal and payout collapse to the same algebraic form") {
	// NOT an independent measurement of the energy-balance defect -- this is
	// the "darkening is E times the energy scale" identity from the test case
	// twelve lines above, restated with both sides multiplied by the same
	// `coat_weight * estimate` factor:
	//
	// withdrawal = coat_weight * estimate * darkening        (coatLayerAlbedo)
	// payout     = coat_weight * A_ss     * energy_scale     (evalCoat / sampler)
	// with A_ss = E * estimate, because the LUT behind `estimate` divides the
	// single-scattering loss out (cycles_precompute.cpp:88-130).
	//
	// Substituting darkening == E * energy_scale (asserted above) collapses
	// both sides to coat_weight * estimate * E * C algebraically -- so this
	// case is true BY CONSTRUCTION of that substitution, not by any additional
	// evidence that E*C is the right number. It is a guard against the two
	// call sites (coatLayerAlbedo vs. evalCoat/sampler) drifting to different
	// SHAPES of the same formula, nothing more. The real balance measurement
	// -- whether a coated white-furnace scene actually returns 1.0, which is
	// the only check that would catch both formulas being wrong THE SAME WAY
	// -- is pt_coat_gate.gd's PROBE B (its own header comment calls itself
	// "the only real balance instrument"), not this file.
	//
	// The two counterfactuals pinned numerically below are still useful as a
	// regression pin: uncompensated the ratio was E (0.915 at roughness 0.5 /
	// normal incidence); payout-only compensation (the historical half-fix)
	// gives E*C, 0.922.
	const float coat_weight = 0.7f;
	for (float rough : { 0.2f, 0.5f, 0.8f }) {
		for (float mu : { 1.0f, 0.7f, 0.3f }) {
			CAPTURE(rough);
			CAPTURE(mu);
			const float estimate = coat_albedo_estimate(rough, mu, 1.5f);
			const float e = coat_ggx_e(rough, mu);
			const float withdrawal = coat_weight * estimate * coat_darkening(rough, mu, 1.5f);
			const float payout = coat_weight * (e * estimate) * coat_energy_scale(rough, mu, 1.5f);
			CHECK(payout == doctest::Approx(withdrawal).epsilon(1e-5));
			// And the layer never withdraws more than there is.
			CHECK(withdrawal <= 1.0f);
		}
	}
	// Pin the two counterfactuals numerically, so the case documents what it
	// rejects rather than merely rejecting it.
	CHECK(coat_ggx_e(0.5f, 1.0f) == doctest::Approx(0.9153f).epsilon(1e-3));
	CHECK(coat_ggx_e(0.5f, 1.0f) * coat_energy_scale(0.5f, 1.0f, 1.5f) ==
			doctest::Approx(0.9220f).epsilon(1e-3));
}

TEST_CASE("[PathTracer][CoatAlbedo] an ior of exactly 1 is an inert coat") {
	// coat_ior is clamped to >= 1 on upload (render_raytracing.cpp), and at
	// exactly 1 there is no index step, so Fss is 0, Fms is 0, and the
	// compensation must be exactly 1 -- no energy invented from nothing.
	CHECK(coat_fms(0.5f, 1.0f) == doctest::Approx(0.0f).epsilon(1e-6));
	CHECK(coat_energy_scale(0.5f, 0.5f, 1.0f) == doctest::Approx(1.0f).epsilon(1e-6));
	// darkening then reduces to E alone.
	CHECK(coat_darkening(0.5f, 0.5f, 1.0f) == doctest::Approx(coat_ggx_e(0.5f, 0.5f)).epsilon(1e-6));
}

} // namespace TestPTCoatAlbedo
