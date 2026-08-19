/**************************************************************************/
/*  test_pt_transmission.cpp                                              */
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

TEST_FORCE_LINK(test_pt_transmission)

#include "core/math/math_funcs.h"

namespace TestPTTransmission {

// CPU mirrors of the transmission math in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// Ported from Blender Cycles: intern/cycles/kernel/closure/bsdf_util.h:47-108.
// These must stay textually identical to the GLSL modulo type names -- a drift
// makes this suite pass while the shader is wrong.

static float sqr(float x) {
	return x * x;
}

static float f0_from_ior(float p_ior) {
	return sqr((p_ior - 1.0f) / (p_ior + 1.0f));
}

static float ior_from_f0(float p_f0) {
	const float sqrt_f0 = Math::sqrt(CLAMP(p_f0, 0.0f, 0.99f));
	return (1.0f + sqrt_f0) / (1.0f - sqrt_f0);
}

// Returns reflectance; writes the cosine of the transmitted angle (negative,
// relative to the surface normal). Returns exactly 1.0 on total internal
// reflection, in which case r_cos_theta_t is left untouched and no transmitted
// direction exists.
static float fresnel_dielectric(float p_cos_theta_i, float p_eta, float *r_cos_theta_t) {
	const float eta_cos_theta_t_sq = sqr(p_eta) - (1.0f - sqr(p_cos_theta_i));
	if (eta_cos_theta_t_sq <= 0.0f) {
		return 1.0f; // Total internal reflection.
	}
	const float cos_theta_i = Math::abs(p_cos_theta_i);
	const float cos_theta_t = -Math::sqrt(eta_cos_theta_t_sq) / p_eta;
	if (r_cos_theta_t) {
		*r_cos_theta_t = cos_theta_t;
	}
	// Amplitudes of the reflected s- and p-polarised waves.
	const float r_s = (cos_theta_i + p_eta * cos_theta_t) / (cos_theta_i - p_eta * cos_theta_t);
	const float r_p = (cos_theta_t + p_eta * cos_theta_i) / (p_eta * cos_theta_i - cos_theta_t);

	// Squared amplitude gives the fraction of reflected energy.
	return (sqr(r_s) + sqr(r_p)) * 0.5f;
}

static Vector3 refract_angle(const Vector3 &p_incident, const Vector3 &p_normal, float p_cos_theta_t, float p_inv_eta) {
	return (p_inv_eta * p_normal.dot(p_incident) + p_cos_theta_t) * p_normal - p_inv_eta * p_incident;
}

TEST_CASE("[PathTracer][Transmission] F0 and IOR round-trip") {
	// Cycles bsdf_util.h:290-293. Glass at 1.5 is the canonical 4% dielectric,
	// and it is the value Godot's own specular default of 0.5 already produces
	// via specular_to_f0 (0.16 * 0.5^2 = 0.04). The two conventions coinciding
	// here is what makes the Phase E1 F0 arbitration a no-op at defaults.
	CHECK(f0_from_ior(1.5f) == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(f0_from_ior(1.0f) == doctest::Approx(0.0f).epsilon(1e-9));

	// ior == 0.0 is LEGAL glTF (KHR_materials_ior permits it as a signal value)
	// and Phase D imports it without complaint. It must yield a fully reflective
	// surface, not a NaN.
	CHECK(f0_from_ior(0.0f) == doctest::Approx(1.0f).epsilon(1e-9));

	CHECK(ior_from_f0(f0_from_ior(1.5f)) == doctest::Approx(1.5f).epsilon(1e-4));
	CHECK(ior_from_f0(f0_from_ior(2.4f)) == doctest::Approx(2.4f).epsilon(1e-4));
}

TEST_CASE("[PathTracer][Transmission] Fresnel at normal incidence equals F0") {
	float cos_t = 0.0f;
	CHECK(fresnel_dielectric(1.0f, 1.5f, &cos_t) == doctest::Approx(0.04f).epsilon(1e-5));
	CHECK(cos_t == doctest::Approx(-1.0f).epsilon(1e-6));
}

TEST_CASE("[PathTracer][Transmission] Fresnel reaches 1 at grazing incidence") {
	float cos_t = 0.0f;
	CHECK(fresnel_dielectric(0.001f, 1.5f, &cos_t) > 0.99f);
}

TEST_CASE("[PathTracer][Transmission] Total internal reflection at and past critical angle") {
	// Exiting glass into air: eta = 1/1.5. Critical angle is asin(eta) = 41.81deg,
	// so cos(critical) = 0.745356. AT the critical angle eta_cos_theta_t_sq is
	// exactly zero and the <= 0 test must already fire -- an implementation using
	// < 0 would leak a zero-length transmitted direction here.
	const float eta = 1.0f / 1.5f;
	const float cos_critical = Math::cos(Math::asin(eta));
	float cos_t = -999.0f;

	CHECK(fresnel_dielectric(cos_critical, eta, &cos_t) == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(cos_t == -999.0f); // Untouched: no transmitted direction exists.

	// Past critical (shallower angle, smaller cosine) stays fully reflective.
	CHECK(fresnel_dielectric(cos_critical * 0.5f, eta, &cos_t) == doctest::Approx(1.0f).epsilon(1e-9));
	CHECK(cos_t == -999.0f);

	// Just inside critical still transmits.
	CHECK(fresnel_dielectric(cos_critical * 1.05f, eta, &cos_t) < 1.0f);
	CHECK(cos_t != -999.0f);
}

TEST_CASE("[PathTracer][Transmission] Refraction obeys Snell's law") {
	// Incident 45deg from the normal, entering glass (eta = 1.5).
	const Vector3 N = Vector3(0, 0, 1);
	const float cos_i = Math::cos(Math::deg_to_rad(45.0f));
	const float sin_i = Math::sin(Math::deg_to_rad(45.0f));
	const Vector3 wi = Vector3(sin_i, 0, cos_i); // Points AWAY from the surface.

	float cos_t = 0.0f;
	fresnel_dielectric(cos_i, 1.5f, &cos_t);
	const Vector3 wo = refract_angle(wi, N, cos_t, 1.0f / 1.5f);

	CHECK(wo.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(wo.z < 0.0f); // Transmitted: below the surface.

	// Snell: sin(theta_t) = sin(theta_i) / eta.
	const float sin_t = Math::sqrt(wo.x * wo.x + wo.y * wo.y);
	CHECK(sin_t == doctest::Approx(sin_i / 1.5f).epsilon(1e-4));
}

TEST_CASE("[PathTracer][Transmission] Refraction at normal incidence does not bend") {
	const Vector3 N = Vector3(0, 0, 1);
	const Vector3 wi = Vector3(0, 0, 1);
	float cos_t = 0.0f;
	fresnel_dielectric(1.0f, 1.5f, &cos_t);
	const Vector3 wo = refract_angle(wi, N, cos_t, 1.0f / 1.5f);

	CHECK(wo.x == doctest::Approx(0.0f).epsilon(1e-6));
	CHECK(wo.y == doctest::Approx(0.0f).epsilon(1e-6));
	CHECK(wo.z == doctest::Approx(-1.0f).epsilon(1e-6));
}

} // namespace TestPTTransmission
