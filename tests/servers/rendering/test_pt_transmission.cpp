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

static float luminance(const Vector3 &p_rgb) {
	return p_rgb.dot(Vector3(0.2126f, 0.7152f, 0.0722f));
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

// CPU mirror of the F0 arbitration in
// raytracing_closest_hit_common_inc.glsl (roadmap E1, spec section 3.2;
// corrected in the E1 final fix wave -- F1/F2/F3 below).
// Structure ported from Cycles kernel/svm/closure.h:425-435, verified against
// that source directly rather than against the design spec's transcription
// of it, which dropped one statement and conflated two others:
//
//   F1. Cycles' block ends with `if (ior < 1.0f) eta = 1.0f / eta;` after
//       re-deriving eta from F0 (closure.h:432-434). ior_from_f0 always
//       returns >= 1, so for ior < 1 (authorable: material.cpp's ior hint is
//       "0,3,0.001,or_greater") the un-flipped eta lands on the wrong side
//       of 1. Restored below.
//   F2. Cycles keeps f0/eta derivation and the specular_tint completely
//       separate: `eta = ior_from_F0(f0)` uses the UNTINTED scalar `f0`
//       (closure.h:429-431); `specular_tint` is multiplied in only
//       afterward, at closure.h:453, where it can no longer affect eta. eta
//       is therefore derived below from the untinted scalar f0_untinted,
//       never from luminance() of a tinted F0.
//   F3. Cycles re-derives whenever its single `specular_ior_level` knob
//       leaves 0.5. This engine splits that into two independent
//       parameters -- Godot's native `specular` and glTF's
//       `specular_factor` -- and per spec section 3.2
//       (`specular_factor -> specular_ior_level = 0.5 * specular_factor`), a
//       non-default `specular_factor` maps to a non-0.5 `specular_ior_level`
//       exactly as much as a non-default `specular` does. The gate below
//       therefore triggers on EITHER parameter leaving its default.
//
// Godot's 0.16*specular^2 response curve is substituted for Blender's
// 2*level (see brdf_inc.glsl's resolveDielectricF0 for the full derivation);
// specular_factor multiplies f0 directly, matching Cycles' `f0 *= 2.0f *
// specular_ior_level` under that mapping.
static void resolve_f0(float p_ior, float p_specular, float p_specular_factor,
		const Vector3 &p_specular_tint, Vector3 *r_f0, float *r_eta) {
	const float f0_scalar = f0_from_ior(p_ior);
	// UNTINTED scalar F0 (F2): specular_tint is applied only below, to f0,
	// and must never reach eta.
	float f0_untinted = f0_scalar * p_specular_factor;
	// Godot's specular_to_f0 is 0.16*s^2, normalised against the 0.04 reference
	// so this factor is EXACTLY 1.0 at the 0.5 default. That exactness is what
	// makes an untouched material bit-identical to pre-E1.
	f0_untinted *= 4.0f * p_specular * p_specular;

	float eta = p_ior;
	if (p_specular != 0.5f || p_specular_factor != 1.0f) { // F3: gate widened to specular_factor.
		// Cycles re-derives eta from the modified F0 so reflectance and
		// refraction cannot disagree (svm/closure.h:429-431).
		eta = ior_from_f0(f0_untinted);
		if (p_ior < 1.0f) { // F1: restored ior<1 flip (closure.h:432-434).
			eta = 1.0f / eta;
		}
	}

	*r_f0 = Vector3(f0_untinted, f0_untinted, f0_untinted) * p_specular_tint;
	*r_eta = eta;
}

TEST_CASE("[PathTracer][Transmission] F0 arbitration is a no-op at every default") {
	Vector3 f0;
	float eta = 0.0f;
	resolve_f0(1.5f, 0.5f, 1.0f, Vector3(1, 1, 1), &f0, &eta);

	// 0.04 is what specular_to_f0(0.5) produced before E1. Bit-exactness here is
	// the whole no-pixel-change guarantee for untouched materials.
	CHECK(f0.x == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(f0.y == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(f0.z == doctest::Approx(0.04f).epsilon(1e-6));
	CHECK(eta == doctest::Approx(1.5f).epsilon(1e-9));
}

TEST_CASE("[PathTracer][Transmission] F0 arbitration honours tint and factor, and (F3) specular_factor alone re-derives eta") {
	Vector3 f0;
	float eta = 0.0f;
	resolve_f0(1.5f, 0.5f, 0.62f, Vector3(0.8f, 0.7f, 0.55f), &f0, &eta);

	CHECK(f0.x == doctest::Approx(0.04f * 0.62f * 0.8f).epsilon(1e-6));
	CHECK(f0.y == doctest::Approx(0.04f * 0.62f * 0.7f).epsilon(1e-6));
	CHECK(f0.z == doctest::Approx(0.04f * 0.62f * 0.55f).epsilon(1e-6));
	// F3: specular is still 0.5, but specular_factor (0.62) is not, so eta
	// MUST be re-derived now -- from the UNTINTED f0 (0.04 * 0.62 = 0.0248),
	// not from luminance(f0) of the tinted vector above (F2). By hand:
	// ior_from_f0(0.0248) = (1 + sqrt(0.0248)) / (1 - sqrt(0.0248)) = 1.373831.
	CHECK(eta == doctest::Approx(1.373831f).epsilon(1e-5));
	CHECK(eta == doctest::Approx(ior_from_f0(0.04f * 0.62f)).epsilon(1e-6));
}

TEST_CASE("[PathTracer][Transmission] Off-default specular re-derives eta") {
	Vector3 f0;
	float eta = 0.0f;
	resolve_f0(1.5f, 1.0f, 1.0f, Vector3(1, 1, 1), &f0, &eta);

	// 4 * 1.0^2 = 4, so F0 quadruples to Godot's 0.16 at specular = 1.0.
	CHECK(f0.x == doctest::Approx(0.16f).epsilon(1e-6));
	// eta must follow F0 upward, or the surface would refract like glass while
	// reflecting like something denser.
	CHECK(eta > 1.5f);
	CHECK(eta == doctest::Approx(ior_from_f0(0.16f)).epsilon(1e-5));
}

TEST_CASE("[PathTracer][Transmission] F2: specular_tint must not leak into eta") {
	// Same off-default specular as above, but with a strongly saturated,
	// non-uniform tint. luminance() of the OLD (tinted) F0 would have pulled
	// eta toward the tint's luminance; F2 requires eta to come out identical
	// to the untinted case regardless of how extreme the tint is.
	Vector3 f0_white, f0_tinted;
	float eta_white = 0.0f, eta_tinted = 0.0f;
	resolve_f0(1.5f, 1.0f, 1.0f, Vector3(1, 1, 1), &f0_white, &eta_white);
	resolve_f0(1.5f, 1.0f, 1.0f, Vector3(0.05f, 0.9f, 0.95f), &f0_tinted, &eta_tinted);

	// F0 itself DOES pick up the tint...
	CHECK(f0_tinted.x == doctest::Approx(0.16f * 0.05f).epsilon(1e-6));
	CHECK(f0_tinted.y == doctest::Approx(0.16f * 0.9f).epsilon(1e-6));
	CHECK(f0_tinted.z == doctest::Approx(0.16f * 0.95f).epsilon(1e-6));
	// ...but eta must be bit-identical to the untinted derivation, not pulled
	// toward luminance(f0_tinted) (which is far below 0.16).
	CHECK(eta_tinted == doctest::Approx(eta_white).epsilon(1e-6));
	CHECK(eta_tinted == doctest::Approx(ior_from_f0(0.16f)).epsilon(1e-5));

	// Spell the counterfactual out rather than asserting only against the
	// correct value. Two of the four E1 escapes were assertions that were
	// themselves correct but could not distinguish right from wrong, so pin
	// the WRONG answer numerically and require the gap:
	//   luminance(0.16 * (0.05, 0.9, 0.95)) = 0.16 * 0.72290 = 0.1156640
	//   ior_from_f0(0.1156640)              = 2.030733
	//   ior_from_f0(0.16)                   = 2.333333   <- required
	// A 0.30 spread, ~13%. If someone reinstates the F2 defect, the equality
	// above fails AND this inequality fails, so the failure is unambiguous.
	const float eta_if_f2_regressed = ior_from_f0(luminance(f0_tinted));
	CHECK(eta_if_f2_regressed == doctest::Approx(2.030733f).epsilon(1e-5));
	CHECK(Math::abs(eta_tinted - eta_if_f2_regressed) > 0.25f);
}

TEST_CASE("[PathTracer][Transmission] F1: ior < 1 flips the re-derived eta") {
	// ior 0.8 (< 1, legal glTF/KHR_materials_ior) with specular off-default
	// (1.0) so the re-derivation branch fires. f0_untinted =
	// F0_from_ior(0.8) * 4*1.0^2 = ((0.8-1)/(0.8+1))^2 * 4 = 0.049382716.
	// ior_from_f0 of that is 1.571542 -- WITHOUT the ior<1 flip, eta would
	// wrongly land above 1 despite ior itself being below 1. F1 requires the
	// final eta to be the reciprocal, below 1, matching ior's own side of 1.
	Vector3 f0;
	float eta = 0.0f;
	resolve_f0(0.8f, 1.0f, 1.0f, Vector3(1, 1, 1), &f0, &eta);

	const float f0_scalar_expected = f0_from_ior(0.8f) * 4.0f;
	CHECK(f0.x == doctest::Approx(f0_scalar_expected).epsilon(1e-6));
	const float eta_unflipped = ior_from_f0(f0_scalar_expected);
	CHECK(eta_unflipped > 1.0f); // sanity: without F1 this is what eta would wrongly be.
	CHECK(eta == doctest::Approx(1.0f / eta_unflipped).epsilon(1e-5));
	CHECK(eta < 1.0f);
}

TEST_CASE("[PathTracer][Transmission] ior == 0 yields a fully reflective surface") {
	Vector3 f0;
	float eta = 0.0f;
	resolve_f0(0.0f, 0.5f, 1.0f, Vector3(1, 1, 1), &f0, &eta);

	CHECK(f0.x == doctest::Approx(1.0f).epsilon(1e-6));
	CHECK(!Math::is_nan(f0.x));
	CHECK(eta == doctest::Approx(0.0f).epsilon(1e-9));

	// And the closure's Fresnel must report TIR for it at every incidence,
	// so the caller never reaches the 1.0/eta division.
	float cos_t = -999.0f;
	CHECK(fresnel_dielectric(1.0f, 0.0f, &cos_t) == doctest::Approx(1.0f).epsilon(1e-9));
	CHECK(cos_t == -999.0f);
}

TEST_CASE("[PathTracer][Transmission] Absorption follows Beer-Lambert") {
	// sigma_a = (1 - color) * density, matching Cycles' Volume Absorption
	// (kernel/svm/closure.h:1236-1241). NOT the glTF spec's -log(color)/distance;
	// see spec section 4.3 for why Blender's is chosen.
	const Vector3 color = Vector3(0.9f, 0.4f, 0.15f);
	const float density = 0.2f; // attenuation_distance 5.0 -> density 1/5.
	const float d = 3.0f;

	const Vector3 sigma = (Vector3(1, 1, 1) - color) * density;
	// Explicit expected values, computed by hand:
	CHECK(Math::exp(-sigma.x * d) == doctest::Approx(0.941765f).epsilon(1e-5));
	CHECK(Math::exp(-sigma.y * d) == doctest::Approx(0.697676f).epsilon(1e-5));
	CHECK(Math::exp(-sigma.z * d) == doctest::Approx(0.600496f).epsilon(1e-5));

	// A white attenuation colour absorbs nothing regardless of density.
	const Vector3 white_sigma = (Vector3(1, 1, 1) - Vector3(1, 1, 1)) * 999.0f;
	CHECK(Math::exp(-white_sigma.x * d) == doctest::Approx(1.0f).epsilon(1e-9));

	// Zero density (attenuation_distance 0 == infinite) absorbs nothing.
	const Vector3 zero_sigma = (Vector3(1, 1, 1) - color) * 0.0f;
	CHECK(Math::exp(-zero_sigma.y * d) == doctest::Approx(1.0f).epsilon(1e-9));
}

// CPU mirrors of the RT_FLAGS packing in scene_shader_raytracing.h and the
// payload bit helpers in raytracing_inc.glsl (roadmap E1).
static const uint32_t MIRROR_TRANSMISSION_ENABLED = (1u << 10);
static const uint32_t MIRROR_MAX_TRANSMISSION_SHIFT = 11u;
static const uint32_t MIRROR_MAX_TRANSMISSION_MASK = 0xFu;
static const uint32_t MIRROR_MIN_BOUNCE_SHIFT = 4u;
static const uint32_t MIRROR_MIN_BOUNCE_MASK = 0x1Fu;
static const uint32_t MIRROR_SAMPLE_COUNT_SHIFT = 20u;

static uint32_t mirror_get_max_transmission(uint32_t p_flags) {
	return (p_flags >> MIRROR_MAX_TRANSMISSION_SHIFT) & MIRROR_MAX_TRANSMISSION_MASK;
}

static uint32_t mirror_inc_transmission_bounce(uint32_t p_packed) {
	return p_packed + 0x08000001u; // +1 to bits 27-30 and +1 to total (bits 0-7).
}

static uint32_t mirror_get_transmission_bounces(uint32_t p_packed) {
	return (p_packed >> 27u) & 0xFu;
}

TEST_CASE("[PathTracer][Transmission] RT_FLAGS transmission field does not collide") {
	// Bit 10 and the 11-14 field must miss min_bounce (4-8), the emissive flag
	// (9), the sample count (20-27) and max bounces (28-31). A collision here
	// corrupts a NEIGHBOURING field's readback and leaves the render merely
	// plausible rather than visibly wrong -- which is why this is asserted
	// rather than eyeballed.
	const uint32_t transmission_region = MIRROR_TRANSMISSION_ENABLED |
			(MIRROR_MAX_TRANSMISSION_MASK << MIRROR_MAX_TRANSMISSION_SHIFT);
	const uint32_t min_bounce_region = MIRROR_MIN_BOUNCE_MASK << MIRROR_MIN_BOUNCE_SHIFT;
	const uint32_t emissive_flag = (1u << 9);
	const uint32_t sample_count_region = 0xFFu << MIRROR_SAMPLE_COUNT_SHIFT;
	const uint32_t max_bounces_region = 0xFu << 28u;

	CHECK((transmission_region & min_bounce_region) == 0u);
	CHECK((transmission_region & emissive_flag) == 0u);
	CHECK((transmission_region & sample_count_region) == 0u);
	CHECK((transmission_region & max_bounces_region) == 0u);
	CHECK(transmission_region == 0x7C00u); // bits 10-14
}

TEST_CASE("[PathTracer][Transmission] Bounce cap uses 0-as-unset") {
	// Matches resolve_bounce_cap's existing convention for the diffuse and glossy
	// caps (raytracing_inc.glsl), so the same helper is reused and no bias is
	// needed. Cap range is 1-15, NOT 1-16 like its siblings: the counter is 4
	// bits and saturates at 15, so a cap of 16 would silently never fire.
	CHECK(mirror_get_max_transmission(0u) == 0u); // unset
	CHECK(mirror_get_max_transmission(12u << MIRROR_MAX_TRANSMISSION_SHIFT) == 12u);
	CHECK(mirror_get_max_transmission(15u << MIRROR_MAX_TRANSMISSION_SHIFT) == 15u);
}

TEST_CASE("[PathTracer][Transmission] Transmission counter increments total too") {
	uint32_t packed = 0u;
	packed = mirror_inc_transmission_bounce(packed);
	CHECK(mirror_get_transmission_bounces(packed) == 1u);
	CHECK((packed & 0xFFu) == 1u); // total bounces

	for (int i = 0; i < 14; i++) {
		packed = mirror_inc_transmission_bounce(packed);
	}
	CHECK(mirror_get_transmission_bounces(packed) == 15u);
	CHECK((packed & 0xFFu) == 15u);

	// The counter must not bleed into the diffuse (8-15) or glossy (16-23) lanes.
	CHECK(((packed >> 8u) & 0xFFu) == 0u);
	CHECK(((packed >> 16u) & 0xFFu) == 0u);
}

TEST_CASE("[PathTracer][Transmission] Inside-medium flag is bit 31 and independent") {
	const uint32_t INSIDE = (1u << 31);
	uint32_t packed = 0u;
	packed = mirror_inc_transmission_bounce(packed);
	packed |= INSIDE;

	CHECK((packed & INSIDE) != 0u);
	CHECK(mirror_get_transmission_bounces(packed) == 1u); // counter unaffected
	packed &= ~INSIDE;
	CHECK((packed & INSIDE) == 0u);
	CHECK(mirror_get_transmission_bounces(packed) == 1u);

	// Must not collide with sample-zero (24), shadow-ray (25) or terminated (26).
	CHECK((INSIDE & (1u << 24)) == 0u);
	CHECK((INSIDE & (1u << 25)) == 0u);
	CHECK((INSIDE & (1u << 26)) == 0u);
}

// CPU mirror of the reflect-vs-transmit split in dielectricFresnelSplit
// (brdf_inc.glsl). Ported from Cycles bsdf_microfacet.h:844-851 and :299-305.
static float mirror_pdf_reflect(float p_f_real, const Vector3 &p_f0, float p_transmission, float p_eta) {
	// Real Fresnel remapped onto the tinted [F0, 1] range -- Cycles'
	// generalized-Schlick "exponent < 0" branch, bsdf_microfacet.h:299-305.
	const float f0_real = f0_from_ior(p_eta);
	const float s = CLAMP((p_f_real - f0_real) / MAX(1.0f - f0_real, 0.00001f), 0.0f, 1.0f);
	const Vector3 reflectance = p_f0.lerp(Vector3(1, 1, 1), s);
	// Per-channel and derived from the REMAPPED (tinted) reflectance, not the
	// raw Fresnel -- bsdf_microfacet.h:329. This is what makes a tinted
	// dielectric energy-conserving and lets the transmitted lobe carry colour.
	const Vector3 transmittance = (Vector3(1, 1, 1) - reflectance) * p_transmission;
	const float avg_r = (reflectance.x + reflectance.y + reflectance.z) / 3.0f;
	const float avg_t = (transmittance.x + transmittance.y + transmittance.z) / 3.0f;
	const float denom = avg_r + avg_t;
	return (denom > 0.0f) ? (avg_r / denom) : 1.0f;
}

TEST_CASE("[PathTracer][Transmission] Opaque material never transmits") {
	// transmission == 0 must give pdf_reflect == 1 exactly, so the transmit
	// branch is unreachable. This is what makes the dispatch safe.
	float cos_t = 0.0f;
	const float f = fresnel_dielectric(0.7f, 1.5f, &cos_t);
	CHECK(mirror_pdf_reflect(f, Vector3(0.04f, 0.04f, 0.04f), 0.0f, 1.5f) == doctest::Approx(1.0f).epsilon(1e-9));
}

TEST_CASE("[PathTracer][Transmission] Full transmission mostly transmits at normal incidence") {
	float cos_t = 0.0f;
	const float f = fresnel_dielectric(1.0f, 1.5f, &cos_t);
	const float p = mirror_pdf_reflect(f, Vector3(0.04f, 0.04f, 0.04f), 1.0f, 1.5f);
	// At normal incidence 4% reflects, 96% transmits.
	CHECK(p == doctest::Approx(0.04f).epsilon(1e-4));
}

TEST_CASE("[PathTracer][Transmission] Grazing incidence mostly reflects") {
	float cos_t = 0.0f;
	const float f = fresnel_dielectric(0.02f, 1.5f, &cos_t);
	const float p = mirror_pdf_reflect(f, Vector3(0.04f, 0.04f, 0.04f), 1.0f, 1.5f);
	CHECK(p > 0.85f);
}

TEST_CASE("[PathTracer][Transmission] Degenerate ior 1.0 with transmission 0 does not divide by zero") {
	// F_real == 0 and F0 == 0 make both terms zero. The guard must return 1.0
	// rather than NaN -- an unguarded 0/0 here would be silently zeroed by
	// sanitize_payload_value and poison the pixel with no failing test.
	//
	// MUST go through mirror_pdf_reflect itself, not an inline re-derivation:
	// an inline copy with s hardcoded to 0.0f bypasses the remap -- the only
	// real logic in the function under test -- and can't fail when either
	// guard (this one, or mirror_pdf_reflect's) breaks. See the manufactured
	// RED in this task's report for the difference that makes.
	float cos_t = 0.0f;
	const float f = fresnel_dielectric(0.7f, 1.0f, &cos_t);
	CHECK(f == doctest::Approx(0.0f).epsilon(1e-6));

	const float p = mirror_pdf_reflect(f, Vector3(0, 0, 0), 0.0f, 1.0f);

	CHECK(p == doctest::Approx(1.0f).epsilon(1e-9));
	CHECK(!Math::is_nan(p));
}

TEST_CASE("[PathTracer][Transmission] Reflect and transmit probabilities sum to one") {
	float cos_t = 0.0f;
	for (float c = 0.05f; c <= 1.0f; c += 0.15f) {
		const float f = fresnel_dielectric(c, 1.5f, &cos_t);
		const float p = mirror_pdf_reflect(f, Vector3(0.04f, 0.04f, 0.04f), 1.0f, 1.5f);
		CHECK(p >= 0.0f);
		CHECK(p <= 1.0f);
		// NOTE: "(p + (1 - p)) == Approx(1)" was deleted here -- it is an
		// identity true for any finite p, including one from a completely
		// broken split, and cannot fail. The p >= 0 / p <= 1 bounds above are
		// the real content of this test.
	}
}

} // namespace TestPTTransmission
