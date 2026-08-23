/**************************************************************************/
/*  test_pt_anisotropy.cpp                                                */
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

TEST_FORCE_LINK(test_pt_anisotropy)

#include "core/math/math_funcs.h"

namespace TestPTAnisotropy {

// CPU mirrors of the anisotropy math in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// The aspect/ax/ay mapping is shared verbatim with Blender Cycles
// (intern/cycles/kernel/svm/closure.h:311-313) AND with this engine's own
// Forward+ raster (shaders/scene_forward_lights_inc.glsl:272-274).
// These must stay textually identical to the GLSL modulo type names -- a
// drift makes this suite pass while the shader is wrong.

static float sqr(float x) {
	return x * x;
}

// SIGNED anisotropy on purpose. Cycles saturatefs to [0,1] and carries the
// other orientation in its rotation; Godot's raster does not, and the two are
// NOT equivalent (see the eccentricity test below). glTF has no sign, so every
// imported material lands in a >= 0 where they agree exactly.
static float aniso_aspect(float p_anisotropy) {
	return Math::sqrt(1.0f - p_anisotropy * 0.9f);
}

static void aniso_alphas(float p_roughness, float p_anisotropy, float *r_ax, float *r_ay) {
	const float alpha = p_roughness * p_roughness;
	const float aspect = aniso_aspect(p_anisotropy);
	*r_ax = alpha / aspect;
	*r_ay = alpha * aspect;
}

// Anisotropic GGX NDF. H is in the anisotropy-aligned tangent frame, z along N.
static float ggx_d_aniso(const Vector3 &p_h, float p_ax, float p_ay) {
	const float d = sqr(p_h.x / p_ax) + sqr(p_h.y / p_ay) + sqr(p_h.z);
	return 1.0f / (Math::PI * p_ax * p_ay * sqr(d));
}

// Anisotropic Smith lambda, height-correlated partner of ggx_d_aniso.
static float smith_lambda_aniso(const Vector3 &p_v, float p_ax, float p_ay) {
	const float num = sqr(p_ax * p_v.x) + sqr(p_ay * p_v.y);
	return (-1.0f + Math::sqrt(1.0f + num / sqr(p_v.z))) * 0.5f;
}

// The shipped ISOTROPIC forms, copied from brdf_inc.glsl so the reduction is
// checked against the real thing rather than against a restatement.
static float ggx_d_iso(float p_alpha_squared, float p_ndoth) {
	const float b = ((p_alpha_squared - 1.0f) * p_ndoth * p_ndoth + 1.0f);
	return p_alpha_squared / (Math::PI * b * b);
}

TEST_CASE("[PathTracer][Anisotropy] aspect is exactly 1 at anisotropy 0") {
	// This exactness is the whole no-pixel-change guarantee. sqrt(1.0) must be
	// bit-exact, not approximately 1.
	CHECK(aniso_aspect(0.0f) == 1.0f);

	float ax = 0.0f, ay = 0.0f;
	aniso_alphas(0.35f, 0.0f, &ax, &ay);
	CHECK(ax == ay);
	CHECK(ax == doctest::Approx(0.35f * 0.35f).epsilon(1e-9));
}

TEST_CASE("[PathTracer][Anisotropy] anisotropic D reduces to the shipped isotropic D") {
	// At ax == ay the algebra collapses:
	//   1/(PI*a^2*((Hx^2+Hy^2)/a^2 + Hz^2)^2) == a^2/(PI*((a^2-1)*NdotH^2+1)^2)
	// using Hz = NdotH and Hx^2+Hy^2 = 1-NdotH^2. Asserted numerically across
	// roughness and angle rather than trusted.
	const float roughnesses[] = { 0.05f, 0.2f, 0.5f, 0.9f };
	// 0.999 not 1.0 on purpose -- see the cancellation test below. At exactly
	// NdotH = 1 the SHIPPED isotropic reference loses ~0.27% to float32
	// cancellation at small alpha, so comparing against it there measures the
	// reference's precision, not this formula's correctness.
	const float ndoths[] = { 0.15f, 0.5f, 0.8f, 0.999f };

	for (float r : roughnesses) {
		float ax = 0.0f, ay = 0.0f;
		aniso_alphas(r, 0.0f, &ax, &ay);
		const float alpha = r * r;
		const float alpha_sq = alpha * alpha;

		for (float ndoth : ndoths) {
			// Build an H with this NdotH, split arbitrarily between x and y so
			// both anisotropic axes are exercised.
			const float s = Math::sqrt(MAX(0.0f, 1.0f - ndoth * ndoth));
			const Vector3 h(s * 0.6f, s * 0.8f, ndoth);

			CHECK(ggx_d_aniso(h, ax, ay) == doctest::Approx(ggx_d_iso(alpha_sq, ndoth)).epsilon(1e-5));
		}
	}
}

TEST_CASE("[PathTracer][Anisotropy] the shipped isotropic D loses precision at NdotH = 1") {
	// Recorded, not worked around. Found by this suite during E2b implementation.
	//
	// GGX_D computes b = (alphaSquared - 1) * NdotH^2 + 1. At NdotH == 1 that is
	// alphaSquared - 1 + 1: subtract 1 from a number near 1, then add it back.
	// In float32 the low bits are gone. At roughness 0.05 (alphaSquared 6.25e-6)
	// the result carries ~0.27% error; the anisotropic form, which never forms
	// that difference, is the ACCURATE one.
	//
	// This matters more than a corner case sounds: NdotH near 1 at low roughness
	// is exactly where a sharp specular highlight lives.
	//
	// It is ALSO why prepareBRDFData branches to the isotropic path at
	// anisotropy == 0 rather than routing everything through the anisotropic
	// form. Taking the more accurate path unconditionally would silently shift
	// every polished material and break the no-pixel-change guarantee. The
	// engine keeps its existing behaviour where anisotropy is off; the accuracy
	// improvement applies only where anisotropy is actually used.
	const float alpha = 0.05f * 0.05f;
	const float alpha_sq = alpha * alpha;
	float ax = 0.0f, ay = 0.0f;
	aniso_alphas(0.05f, 0.0f, &ax, &ay);

	const Vector3 h_normal(0.0f, 0.0f, 1.0f);
	const float d_aniso = ggx_d_aniso(h_normal, ax, ay);
	const float d_iso = ggx_d_iso(alpha_sq, 1.0f);

	// At NdotH == 1 the true value is exactly 1/(PI*alphaSquared).
	const float exact = 1.0f / (float(Math::PI) * alpha_sq);
	CHECK(d_aniso == doctest::Approx(exact).epsilon(1e-5));

	// The shipped reference is measurably off there -- pinned so that if someone
	// ever makes GGX_D numerically stable, this test fails and tells them the
	// branch in prepareBRDFData can be revisited.
	CHECK(d_iso != doctest::Approx(exact).epsilon(1e-4));
	CHECK(Math::abs(d_iso - exact) / exact > 0.002f);
}

TEST_CASE("[PathTracer][Anisotropy] SIGNED convention, with the Cycles alternative pinned") {
	// The design decision, made falsifiable. Godot feeds the signed value
	// straight in; Cycles saturates and adds 90 degrees of rotation. Those give
	// DIFFERENT eccentricities, so this test pins BOTH numbers -- asserting only
	// the one we chose could not distinguish the conventions.
	float ax = 0.0f, ay = 0.0f;
	aniso_alphas(1.0f, -0.5f, &ax, &ay); // roughness 1 so alpha == 1
	const float ours = ay / ax;

	float cax = 0.0f, cay = 0.0f;
	aniso_alphas(1.0f, 0.5f, &cax, &cay); // Cycles: |a|, orientation via rotation
	const float cycles = cax / cay;

	CHECK(ours == doctest::Approx(1.450f).epsilon(1e-3));
	CHECK(cycles == doctest::Approx(1.818f).epsilon(1e-3));
	// They must NOT coincide -- if they ever do, the two conventions have been
	// conflated somewhere and this test has stopped discriminating.
	CHECK(Math::abs(ours - cycles) > 0.3f);
}

TEST_CASE("[PathTracer][Anisotropy] positive and negative anisotropy swap the stretched axis") {
	float px = 0.0f, py = 0.0f, nx = 0.0f, ny = 0.0f;
	aniso_alphas(0.4f, 0.6f, &px, &py);
	aniso_alphas(0.4f, -0.6f, &nx, &ny);

	CHECK(px > py); // positive: x is the stretched axis
	CHECK(nx < ny); // negative: y is
}

} // namespace TestPTAnisotropy
