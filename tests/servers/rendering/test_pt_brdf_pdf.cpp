/**************************************************************************/
/*  test_pt_brdf_pdf.cpp                                                  */
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

TEST_FORCE_LINK(test_pt_brdf_pdf)

#include "core/math/math_funcs.h"

namespace TestPTBrdfPdf {

// CPU mirrors of the pdf formulas in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// A pdf that is not normalized silently biases MIS: the image still looks
// plausible, it just converges to the wrong answer. These tests integrate each
// pdf numerically over the hemisphere and assert it comes to 1.

// brdf_inc.glsl: diffusePdf() — cosine-weighted hemisphere.
static double diffuse_pdf(double p_n_dot_l) {
	return p_n_dot_l / Math::PI;
}

// brdf_inc.glsl: sampleGGXVNDFReflectionPdf().
// PDF of the microfacet normal is (G1 * D); the 1/(4*NdotV) comes from the
// Jacobian of the reflection operator.
static double ggx_d(double p_alpha_sq, double p_n_dot_h) {
	const double b = (p_alpha_sq - 1.0) * p_n_dot_h * p_n_dot_h + 1.0;
	return p_alpha_sq / (Math::PI * b * b);
}

static double smith_g1_ggx(double p_alpha_sq, double p_n_dot_v) {
	const double n_dot_v_sq = p_n_dot_v * p_n_dot_v;
	return 2.0 / (Math::sqrt(((p_alpha_sq * (1.0 - n_dot_v_sq)) + n_dot_v_sq) / n_dot_v_sq) + 1.0);
}

static double vndf_reflection_pdf(double p_alpha_sq, double p_n_dot_h, double p_n_dot_v) {
	return ggx_d(p_alpha_sq, p_n_dot_h) * smith_g1_ggx(p_alpha_sq, p_n_dot_v) / (4.0 * p_n_dot_v);
}

// Integrate f(theta, phi) over the hemisphere with a regular grid.
// dOmega = sin(theta) dTheta dPhi.
static double integrate_hemisphere(double (*p_f)(double, double, double), double p_param, double p_n_dot_v) {
	const int N_THETA = 400;
	const int N_PHI = 400;
	double sum = 0.0;
	for (int i = 0; i < N_THETA; i++) {
		const double theta = (i + 0.5) * (Math::PI * 0.5) / N_THETA;
		for (int j = 0; j < N_PHI; j++) {
			const double phi = (j + 0.5) * (2.0 * Math::PI) / N_PHI;
			sum += p_f(theta, phi, p_param == 0.0 ? p_n_dot_v : p_param) * Math::sin(theta);
		}
	}
	return sum * (Math::PI * 0.5 / N_THETA) * (2.0 * Math::PI / N_PHI);
}

static double diffuse_integrand(double p_theta, double /*p_phi*/, double /*p_unused*/) {
	return diffuse_pdf(Math::cos(p_theta));
}

TEST_CASE("[PathTracer][BrdfPdf] cosine-weighted hemisphere pdf integrates to 1") {
	const double total = integrate_hemisphere(diffuse_integrand, 1.0, 1.0);
	CHECK(total == doctest::Approx(1.0).epsilon(0.005));
}

TEST_CASE("[PathTracer][BrdfPdf] cosine pdf is non-negative and zero at grazing") {
	CHECK(diffuse_pdf(0.0) == doctest::Approx(0.0));
	CHECK(diffuse_pdf(1.0) > 0.0);
	CHECK(diffuse_pdf(1.0) == doctest::Approx(1.0 / Math::PI));
}

// Review round 1, finding 4: a blanket `sum > 0.70` bound (needed to
// accommodate the genuine below-horizon loss at alpha=0.6, see below) is
// nearly non-discriminating -- e.g. dropping Smith_G1 entirely gives
// 0.990/0.925/0.790 (still passes > 0.70), and using 1/(4*LdotH) instead of
// the correct 1/(4*NdotV) gives 1.000/0.940/0.769 (also still passes). Both
// are plausible transcription bugs against brdf_inc.glsl. Asserting each
// alpha against its own precomputed expected value with a tight epsilon
// catches both: dropping Smith_G1 or swapping the denominator shifts every
// value by more than 0.01.
struct GGXPdfCase {
	double alpha;
	// Expected value of the N=600 quadrature below at NdotV=0.8, computed
	// independently (Python, float64, same formula, N=600) -- see the task 1
	// fix report for the derivation. NOT copied from the review's rounded
	// 0.989/0.914/0.754; those matched to 3 decimals but these are the actual
	// digits produced by this exact quadrature at this exact N.
	double expected_sum;
};

TEST_CASE("[PathTracer][BrdfPdf] GGX VNDF reflection pdf integrates to its expected value over the hemisphere") {
	// VNDF sampling is exact for the visible-normal distribution, so integrating
	// the reflection pdf over outgoing directions returns 1 up to the amount of
	// mass reflected below the horizon -- which grows with roughness and is NOT
	// small at alpha=0.6 (measured ~25% loss at NdotV=0.8; the below-horizon
	// loss is real microfacet-BRDF behavior, not a bug in this formula or in
	// brdf_inc.glsl).
	const GGXPdfCase cases[] = {
		{ 0.1, 0.988848 },
		{ 0.3, 0.913944 },
		{ 0.6, 0.754081 },
	};
	const double n_dot_v = 0.8;
	const int N = 600;
	for (const GGXPdfCase &c : cases) {
		const double alpha_sq = c.alpha * c.alpha;
		double sum = 0.0;
		for (int i = 0; i < N; i++) {
			const double theta = (i + 0.5) * (Math::PI * 0.5) / N;
			for (int j = 0; j < N; j++) {
				const double phi = (j + 0.5) * (2.0 * Math::PI) / N;
				// Outgoing direction L in a frame where N = +Z and V lies in the XZ plane.
				const double lx = Math::sin(theta) * Math::cos(phi);
				const double ly = Math::sin(theta) * Math::sin(phi);
				const double lz = Math::cos(theta);
				const double vx = Math::sqrt(1.0 - n_dot_v * n_dot_v);
				const double vz = n_dot_v;
				double hx = vx + lx, hy = ly, hz = vz + lz;
				const double hlen = Math::sqrt(hx * hx + hy * hy + hz * hz);
				if (hlen < 1e-9) {
					continue;
				}
				hx /= hlen;
				hy /= hlen;
				hz /= hlen;
				if (hz <= 0.0) {
					continue;
				}
				sum += vndf_reflection_pdf(alpha_sq, hz, n_dot_v) * Math::sin(theta) *
						(Math::PI * 0.5 / N) * (2.0 * Math::PI / N);
			}
		}
		// scale(0.0) turns epsilon into a TRUE relative tolerance
		// (|sum - expected| <= epsilon * |expected|). doctest::Approx's default
		// scale of 1.0 would otherwise inflate the effective tolerance to
		// ~epsilon*(1+expected) (~0.017-0.02 here), which is loose enough that
		// dropping Smith_G1 (see the comment above) slips through undetected
		// at alpha=0.1. With scale(0.0), epsilon(0.01) means what it says: 1%.
		CHECK(sum == doctest::Approx(c.expected_sum).epsilon(0.01).scale(0.0));
	}
}

TEST_CASE("[PathTracer][BrdfPdf] power heuristic is a partition of unity") {
	// Mirrors power_heuristic() in raytracing_inc.glsl. The two strategies'
	// weights must sum to exactly 1, or MIS gains or loses energy.
	auto ph = [](double a, double b) { return (a * a) / (a * a + b * b); };
	for (double a : { 0.01, 0.5, 3.0, 100.0 }) {
		for (double b : { 0.02, 0.7, 5.0, 250.0 }) {
			CHECK(ph(a, b) + ph(b, a) == doctest::Approx(1.0));
		}
	}
	CHECK(ph(1.0, 0.0) == doctest::Approx(1.0));
}

// -----------------------------------------------------------------------
// Lobe selection probability (combinedPdf's pSpec / shade_and_bounce's
// brdfProbability). Review round 1, finding 5: the mixture pdf test further
// below originally hardcoded a weight (0.3) that appears in neither GLSL
// site's own math -- it never tested that THIS formula (luminance-weighted
// specular vs. diffuse reflectance, with its 0.0001 epsilon branches and
// [0.01, 0.99] clamp) is what actually produces the weight. This table tests
// the formula in closed form (no quadrature, no integration error), so it is
// far more sensitive than the mixture integral test below can ever be, and
// it exercises both epsilon branches and both clamp saturations.
// -----------------------------------------------------------------------

struct RGB {
	double r = 0.0, g = 0.0, b = 0.0;
};

// brdf_inc.glsl: luminance().
static double rgb_luminance(RGB p_c) {
	return p_c.r * 0.2126 + p_c.g * 0.7152 + p_c.b * 0.0722;
}

// brdf_inc.glsl: baseColorToSpecularF0() -- lerp(dielectricF0, baseColor, metalness).
static RGB rgb_specular_f0(RGB p_base_color, double p_metalness, double p_dielectric_f0) {
	return RGB{
		p_dielectric_f0 + p_metalness * (p_base_color.r - p_dielectric_f0),
		p_dielectric_f0 + p_metalness * (p_base_color.g - p_dielectric_f0),
		p_dielectric_f0 + p_metalness * (p_base_color.b - p_dielectric_f0),
	};
}

// brdf_inc.glsl: baseColorToDiffuseReflectance() -- baseColor * (1 - metalness).
static RGB rgb_diffuse_reflectance(RGB p_base_color, double p_metalness) {
	const double k = 1.0 - p_metalness;
	return RGB{ p_base_color.r * k, p_base_color.g * k, p_base_color.b * k };
}

// brdf_inc.glsl: combinedPdf()'s pSpec derivation, transcribed verbatim
// (same epsilon branches, same clamp bounds).
static double mixture_p_spec(RGB p_base_color, double p_metalness, double p_dielectric_f0) {
	const RGB specular_f0 = rgb_specular_f0(p_base_color, p_metalness, p_dielectric_f0);
	const RGB diffuse_reflectance = rgb_diffuse_reflectance(p_base_color, p_metalness);
	const double specular_lum = rgb_luminance(specular_f0);
	const double diffuse_lum = rgb_luminance(diffuse_reflectance);
	if (diffuse_lum < 0.0001) {
		return 1.0;
	}
	if (specular_lum < 0.0001) {
		return 0.0;
	}
	const double ratio = specular_lum / (specular_lum + diffuse_lum);
	return (ratio < 0.01) ? 0.01 : ((ratio > 0.99) ? 0.99 : ratio);
}

struct PSpecCase {
	const char *name;
	RGB base_color;
	double metalness;
	double dielectric_f0;
	double expected_p_spec;
};

TEST_CASE("[PathTracer][BrdfPdf] lobe selection probability matches combinedPdf's pSpec formula") {
	const PSpecCase cases[] = {
		// Pure metal: diffuse reflectance is exactly zero -> diffuseLum < 0.0001 branch.
		{ "pure metal", RGB{ 1.0, 1.0, 1.0 }, 1.0, 0.04, 1.0 },
		// Zero dielectric F0, non-metal: specular reflectance is exactly zero -> specularLum < 0.0001 branch.
		{ "zero-F0 dielectric", RGB{ 0.5, 0.5, 0.5 }, 0.0, 0.0, 0.0 },
		// Near-metal: true ratio ~0.999 -> clamps to the 0.99 ceiling.
		{ "near-metal (high clamp)", RGB{ 1.0, 1.0, 1.0 }, 0.999, 0.04, 0.99 },
		// Near-zero specular contribution, still above the 0.0001 floor: true ratio ~0.002 -> clamps to the 0.01 floor.
		{ "near-zero specular (low clamp)", RGB{ 1.0, 1.0, 1.0 }, 0.001, 0.001, 0.01 },
		// Typical colored dielectric, unsaturated: exercises the plain ratio branch with no clamp.
		// Reused below as the mixture-pdf test's material, so that test also
		// exercises this exact formula rather than a magic constant.
		{ "colored dielectric (unsaturated)", RGB{ 0.8, 0.2, 0.3 }, 0.0, 0.04, 0.10672928117829127 },
	};
	for (const PSpecCase &c : cases) {
		INFO("case: ", c.name);
		const double p_spec = mixture_p_spec(c.base_color, c.metalness, c.dielectric_f0);
		// Closed-form, no quadrature -- tight absolute tolerance, just covers
		// double round-trip precision between this file's hand-derived
		// constants and the formula. NOTE: deliberately NOT using
		// `.scale(0.0)` here (unlike the two checks below) -- two of these
		// expected values are exactly 0.0, and doctest::Approx's comparison is
		// a strict `<`, so an expected value of 0.0 with scale(0.0) produces a
		// zero-width tolerance that fails even on an exact match.
		CHECK(p_spec == doctest::Approx(c.expected_p_spec).epsilon(0.000001));
	}
}

// brdf_inc.glsl: combinedPdf() — mixture of the diffuse and specular lobe pdfs,
// weighted by the same lobe-selection probability shade_and_bounce uses. A
// mixture of two normalized pdfs with weights summing to 1 would be exactly
// normalized IF the specular lobe pdf were itself exactly normalized -- it
// isn't (see the GGX VNDF test above: below-horizon loss at alpha=0.6 leaves
// it at ~0.754), so the true expected total here is
// `pSpec * I_spec + (1 - pSpec) * I_diff`, not a bare 1.0. Asserting against
// that precomputed value (rather than "close to 1") is what makes this test
// sensitive to a wrong weight or a dropped term -- see finding 5's review
// note that the old `Approx(1.0).epsilon(0.02)` bound only barely caught a
// 0.5-instead-of-0.3 pSpec error.
//
// pSpec here is the SAME formula-derived value the table above verifies
// independently (colored dielectric case), not a hardcoded constant: if the
// lobe-selection formula in combinedPdf ever drifts from
// baseColorToSpecularF0/baseColorToDiffuseReflectance/luminance, this pulls
// the wrong weight into the mixture too, and the assertion below is what
// would catch it.
static double g_mixture_p_spec = mixture_p_spec(RGB{ 0.8, 0.2, 0.3 }, 0.0, 0.04);
static double g_mixture_alpha_sq = 0.6 * 0.6;
static double g_mixture_n_dot_v = 0.8;

static double mixture_integrand(double p_theta, double p_phi, double /*p_unused*/) {
	const double n_dot_l = Math::cos(p_theta);
	if (n_dot_l <= 0.0) {
		return 0.0;
	}

	const double lx = Math::sin(p_theta) * Math::cos(p_phi);
	const double ly = Math::sin(p_theta) * Math::sin(p_phi);
	const double lz = n_dot_l;
	const double vx = Math::sqrt(1.0 - g_mixture_n_dot_v * g_mixture_n_dot_v);
	const double vz = g_mixture_n_dot_v;
	double hx = vx + lx, hy = ly, hz = vz + lz;
	const double hlen = Math::sqrt(hx * hx + hy * hy + hz * hz);
	if (hlen < 1e-9) {
		return diffuse_pdf(n_dot_l) * (1.0 - g_mixture_p_spec);
	}
	hx /= hlen;
	hy /= hlen;
	hz /= hlen;
	if (hz <= 0.0) {
		return diffuse_pdf(n_dot_l) * (1.0 - g_mixture_p_spec);
	}

	const double pdf_spec = vndf_reflection_pdf(g_mixture_alpha_sq, hz, g_mixture_n_dot_v);
	const double pdf_diff = diffuse_pdf(n_dot_l);
	return g_mixture_p_spec * pdf_spec + (1.0 - g_mixture_p_spec) * pdf_diff;
}

TEST_CASE("[PathTracer][BrdfPdf] mixture pdf integrates to its expected value at a formula-derived pSpec") {
	// Expected value computed independently (Python, float64, same formula and
	// N=400 grid as integrate_hemisphere) for g_mixture_p_spec ~= 0.106729,
	// alpha=0.6, NdotV=0.8 -- see the task 1 fix report for the derivation.
	// scale(0.0) makes epsilon a true relative tolerance: a pSpec error of
	// 0.05 (about half the true weight) shifts the total by ~0.0123, well
	// outside this ~0.0029 window; the old blanket `Approx(1.0).epsilon(0.02)`
	// bound only barely caught a much larger 0.5-instead-of-0.3 error.
	const double expected_total = 0.9737555983119189;
	const double total = integrate_hemisphere(mixture_integrand, 1.0, g_mixture_n_dot_v);
	CHECK(total == doctest::Approx(expected_total).epsilon(0.003).scale(0.0));
}

} // namespace TestPTBrdfPdf
