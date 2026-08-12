/**************************************************************************/
/*  test_pt_light_select.cpp                                              */
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

TEST_FORCE_LINK(test_pt_light_select)

#include "core/math/math_funcs.h"
#include "core/math/vector3.h"

#include <vector>

namespace TestPTLightSelect {

// CPU mirror of the light-selection weight and CDF walk in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_light_select_inc.glsl.
//
// STANDING CAVEAT, restated because it is load-bearing: the doctest binary never
// executes GLSL. Every case in this file would still pass if the shader were
// reverted and this mirror left untouched. The evidence that the SHADER is
// correct comes from pipeline_references/tests/pt_light_gate.gd (energy
// conservation) and pt_light_rmse.gd (variance), which render real frames.
//
// The property this file exists to protect is that ZERO WEIGHT IMPLIES ZERO
// CONTRIBUTION. A light with weight 0 is never selected, so if it could still
// contribute, the estimator silently loses that energy -- a converged image that
// is simply wrong, which no convergence or performance test detects.

static const float RT_LIGHT_WEIGHT_FLOOR = 1e-3f;

static const uint32_t LIGHT_TYPE_OMNI = 0;
static const uint32_t LIGHT_TYPE_DIRECTIONAL = 1;
static const uint32_t LIGHT_TYPE_RECT = 2;
static const uint32_t LIGHT_TYPE_SPOT = 3;

// Mirror of the fields of RTLightData that the weight reads. Deliberately NOT
// the full 160-byte struct: this file tests the weight function, not std430
// layout parity (that is covered by the static_asserts in render_raytracing.h).
struct MirrorLight {
	Vector3 position;
	uint32_t type = LIGHT_TYPE_OMNI;
	Vector3 emission = Vector3(1, 1, 1);
	float radius = 0.0f;
	float attenuation = 2.0f;
	float inv_max_range = -1.0f;
	float max_range_squared = 0.0f;
	float indirect_energy = 1.0f;
	float inv_spot_attenuation = 1.0f;
	float cos_spot_angle = 0.0f;
	Vector3 spot_direction = Vector3(0, 0, -1); // For RECT this is axisU.
	Vector3 rect_axis_v = Vector3(0, 0, 0);
};

static float mirror_luminance(const Vector3 &p_c) {
	return p_c.x * 0.2126f + p_c.y * 0.7152f + p_c.z * 0.0722f;
}

// Mirror of lights_attenuation_from_dist_sq().
static float mirror_attenuation(float p_dist_sq, float p_inv_max_range, float p_decay) {
	if (p_dist_sq <= 0.0f) {
		return 1.0f;
	}
	const float distance = Math::sqrt(p_dist_sq);
	float atten = MIN(Math::pow(MAX(distance, 0.0001f), -p_decay), 1.0f);
	if (p_inv_max_range >= 0.0f) {
		float nd = distance * p_inv_max_range;
		nd *= nd;
		nd *= nd;
		nd = MAX(1.0f - nd, 0.0f);
		nd *= nd;
		return atten * nd;
	}
	return atten;
}

// Mirror of lights_select_weight().
static float mirror_weight(const Vector3 &p_hit_pos, const MirrorLight &p_light, bool p_is_indirect) {
	const float mag = Math::abs(mirror_luminance(p_light.emission));
	if (mag <= 0.0f) {
		return 0.0f;
	}
	const float indirect_factor = p_is_indirect ? p_light.indirect_energy : 1.0f;
	if (indirect_factor <= 0.0f) {
		return 0.0f;
	}
	if (p_light.type == LIGHT_TYPE_DIRECTIONAL) {
		return mag * indirect_factor;
	}

	const Vector3 to_light = p_light.position - p_hit_pos;
	const float dist_sq = to_light.length_squared();
	const float dist = Math::sqrt(dist_sq);

	float near_dist = dist;
	if (p_light.type == LIGHT_TYPE_RECT) {
		const float rect_extent = p_light.spot_direction.length() + p_light.rect_axis_v.length();
		near_dist = MAX(0.0f, dist - rect_extent);
	}
	if (p_light.max_range_squared != 0.0f && near_dist * near_dist > p_light.max_range_squared) {
		return 0.0f;
	}

	const float atten = mirror_attenuation(dist_sq, p_light.inv_max_range, p_light.attenuation);

	float spot_factor = 1.0f;
	if (p_light.type == LIGHT_TYPE_SPOT) {
		const Vector3 L = to_light / MAX(dist, 1e-4f);
		const float scos = (-L).dot(p_light.spot_direction);
		const float sin_b = CLAMP(p_light.radius / MAX(dist, 1e-4f), 0.0f, 1.0f);
		const float cos_b = Math::sqrt(MAX(0.0f, 1.0f - sin_b * sin_b));
		const float cos_a = p_light.cos_spot_angle;
		const float sin_a = Math::sqrt(MAX(0.0f, 1.0f - cos_a * cos_a));
		const float cos_widened = cos_a * cos_b - sin_a * sin_b;
		if (scos <= cos_widened) {
			return 0.0f;
		}
		// CLAMPED TO 1.0. Directions between cos_widened and cos_spot_angle are
		// admitted on purpose (that is what widening the cone means), and for
		// exactly those the raw ratio exceeds 1, making 1 - pow(...) NEGATIVE.
		// A negative weight corrupts the CDF far worse than the zero this
		// widening exists to avoid.
		const float spot_rim = CLAMP((1.0f - scos) / (1.0f - p_light.cos_spot_angle), 1e-4f, 1.0f);
		spot_factor = 1.0f - Math::pow(spot_rim, p_light.inv_spot_attenuation);
	}

	const float spatial = MAX(atten * spot_factor, RT_LIGHT_WEIGHT_FLOOR);
	return mag * spatial * indirect_factor;
}

// Conservative: true if ANY sample within the light's extent can produce a
// nonzero contribution. Mirrors the shader's CONTRIBUTION zero-tests, not the
// weight's. Keep it that way -- a version derived from mirror_weight() would
// assert only that mirror_weight equals itself.
static bool light_can_contribute(const Vector3 &p_hit_pos, const MirrorLight &p_light, bool p_is_indirect) {
	if (Math::abs(mirror_luminance(p_light.emission)) <= 0.0f) {
		return false;
	}
	if (p_is_indirect && p_light.indirect_energy <= 0.0f) {
		return false;
	}
	if (p_light.type == LIGHT_TYPE_DIRECTIONAL) {
		return true;
	}
	const Vector3 to_light = p_light.position - p_hit_pos;
	const float dist = to_light.length();

	if (p_light.max_range_squared != 0.0f) {
		// Shading range-tests the SAMPLED point: the centre for omni/spot
		// (raytracing_lights_inc.glsl:408), a point on the quad for rect (:315).
		float nearest = dist;
		if (p_light.type == LIGHT_TYPE_RECT) {
			nearest = MAX(0.0f, dist - (p_light.spot_direction.length() + p_light.rect_axis_v.length()));
		}
		if (nearest * nearest > p_light.max_range_squared) {
			return false;
		}
	}
	if (p_light.type == LIGHT_TYPE_SPOT) {
		// Shading rejects on scos <= cos_spot_angle (:436) using the SAMPLED
		// direction, which for a sphere light of radius r ranges over an
		// angular disc of half-angle asin(r/d) around the centre direction.
		const Vector3 L = to_light / MAX(dist, 1e-4f);
		const float scos = (-L).dot(p_light.spot_direction);
		const float sin_b = CLAMP(p_light.radius / MAX(dist, 1e-4f), 0.0f, 1.0f);
		const float cos_b = Math::sqrt(MAX(0.0f, 1.0f - sin_b * sin_b));
		const float cos_a = p_light.cos_spot_angle;
		const float sin_a = Math::sqrt(MAX(0.0f, 1.0f - cos_a * cos_a));
		if (scos <= cos_a * cos_b - sin_a * sin_b) {
			return false;
		}
	}
	return true;
}

TEST_CASE("[PathTracer][LightSelect] a light that can contribute always has positive weight") {
	// THE load-bearing case. Equivalent to "weight == 0 implies contribution == 0",
	// stated in the direction that fails loudly.
	uint32_t seed = 0x9E3779B9u;
	auto next = [&seed]() {
		seed = seed * 1664525u + 1013904223u;
		return float(seed >> 8) / float(1u << 24);
	};

	const uint32_t types[4] = { LIGHT_TYPE_OMNI, LIGHT_TYPE_DIRECTIONAL, LIGHT_TYPE_RECT, LIGHT_TYPE_SPOT };
	for (int trial = 0; trial < 20000; trial++) {
		MirrorLight l;
		l.type = types[trial & 3];
		l.position = Vector3(next() * 20.0f - 10.0f, next() * 20.0f - 10.0f, next() * 20.0f - 10.0f);
		// Emission spans zero, positive, and NEGATIVE (light_is_negative).
		const float e = next() * 4.0f - 1.0f;
		l.emission = Vector3(e, e * 0.5f, e * 2.0f);
		l.radius = next() * 2.0f;
		l.attenuation = next() * 3.0f;
		const bool finite_range = next() < 0.7f;
		const float range = 1.0f + next() * 15.0f;
		l.inv_max_range = finite_range ? 1.0f / range : -1.0f;
		l.max_range_squared = finite_range ? range * range : 0.0f;
		l.indirect_energy = (next() < 0.2f) ? 0.0f : next() * 2.0f;
		l.cos_spot_angle = next();
		l.inv_spot_attenuation = 0.1f + next() * 4.0f;
		const Vector3 d(next() * 2.0f - 1.0f, next() * 2.0f - 1.0f, next() * 2.0f - 1.0f);
		l.spot_direction = (d.length() > 1e-4f) ? d.normalized() : Vector3(0, 0, -1);
		if (l.type == LIGHT_TYPE_RECT) {
			l.spot_direction = d * 0.5f; // axisU, NOT normalized -- it is a half-extent vector.
			l.rect_axis_v = Vector3(next(), next(), next()) * 0.5f;
		}

		const Vector3 p(next() * 20.0f - 10.0f, next() * 20.0f - 10.0f, next() * 20.0f - 10.0f);
		const bool indirect = (trial & 4) != 0;

		if (light_can_contribute(p, l, indirect)) {
			const float w = mirror_weight(p, l, indirect);
			CHECK_MESSAGE(w > 0.0f, "trial ", trial, " type ", l.type, ": contributing light got weight 0");
		}
	}
}

TEST_CASE("[PathTracer][LightSelect] no weight is ever negative") {
	// The spot-rim clamp. Without it, a direction between the widened cone and
	// the true cone yields spot_rim > 1 and 1 - pow(spot_rim, k) < 0.
	MirrorLight l;
	l.type = LIGHT_TYPE_SPOT;
	l.cos_spot_angle = 0.8f; // ~36.9 degree half-angle
	l.inv_spot_attenuation = 1.0f;
	l.spot_direction = Vector3(0, 0, -1);
	l.position = Vector3(0, 0, 0);
	l.radius = 2.0f; // wide enough to widen the cone substantially
	l.emission = Vector3(1, 1, 1);

	// Sweep the shading point around the cone edge, from inside to well outside.
	bool saw_widened_admission = false;
	for (int i = 0; i <= 200; i++) {
		const float angle = float(i) * 0.01f; // 0 .. 2 rad
		const Vector3 p(Math::sin(angle) * 5.0f, 0.0f, -Math::cos(angle) * 5.0f);
		const float w = mirror_weight(p, l, false);
		CHECK(w >= 0.0f);
		const Vector3 L = (l.position - p).normalized();
		const float scos = (-L).dot(l.spot_direction);
		if (w > 0.0f && scos <= l.cos_spot_angle) {
			saw_widened_admission = true; // outside the TRUE cone, still weighted
		}
	}
	// If this never fires the sweep missed the band the clamp protects, and the
	// non-negativity checks above proved nothing about it.
	CHECK(saw_widened_admission);
}

TEST_CASE("[PathTracer][LightSelect] a negative light gets positive weight") {
	// compute_light_energy() applies sign = -1 for light_is_negative
	// (render_raytracing.cpp:2755), so emission arrives negative in every channel.
	// A signed luminance weight would go negative and corrupt the CDF.
	MirrorLight neg;
	neg.type = LIGHT_TYPE_OMNI;
	neg.position = Vector3(0, 3, 0);
	neg.emission = Vector3(-2.0f, -2.0f, -2.0f);

	MirrorLight pos = neg;
	pos.emission = Vector3(2.0f, 2.0f, 2.0f);

	const Vector3 p(0, 0, 0);
	CHECK(mirror_weight(p, neg, false) > 0.0f);
	// Magnitude governs placement, so equal magnitudes weigh equally.
	CHECK(mirror_weight(p, neg, false) == doctest::Approx(mirror_weight(p, pos, false)));
}

TEST_CASE("[PathTracer][LightSelect] a rect straddling its range boundary keeps weight") {
	// Shading range-tests the sampled point on the quad (raytracing_lights_inc.glsl:315);
	// the weight knows only the centre. Without the half-diagonal expansion this
	// rect weighs 0 while half of it is still lit.
	MirrorLight l;
	l.type = LIGHT_TYPE_RECT;
	l.position = Vector3(0, 0, 10.5f);
	l.spot_direction = Vector3(2, 0, 0); // axisU half-width
	l.rect_axis_v = Vector3(0, 2, 0); // axisV half-height
	l.inv_max_range = 1.0f / 10.0f;
	l.max_range_squared = 100.0f; // centre at 10.5 is OUTSIDE, near edge is inside
	l.emission = Vector3(5, 5, 5);

	const Vector3 p(0, 0, 0);
	REQUIRE(light_can_contribute(p, l, false));
	CHECK(mirror_weight(p, l, false) > 0.0f);
}

TEST_CASE("[PathTracer][LightSelect] a sphere light reaching into the spot cone keeps weight") {
	// The centre direction lies outside the cone; part of the sphere does not.
	MirrorLight l;
	l.type = LIGHT_TYPE_SPOT;
	l.spot_direction = Vector3(0, 0, -1);
	l.cos_spot_angle = Math::cos(0.30f); // 0.30 rad half-angle
	l.inv_spot_attenuation = 1.0f;
	l.radius = 1.5f;
	l.emission = Vector3(3, 3, 3);
	// Shading point at 0.35 rad off axis at distance 5: outside 0.30, but
	// asin(1.5/5) = 0.304 rad of angular radius reaches in.
	const float a = 0.35f;
	l.position = Vector3(0, 0, 0);
	const Vector3 p(Math::sin(a) * 5.0f, 0.0f, -Math::cos(a) * 5.0f);

	const Vector3 L = (l.position - p).normalized();
	REQUIRE((-L).dot(l.spot_direction) <= l.cos_spot_angle); // genuinely outside the true cone
	CHECK(mirror_weight(p, l, false) > 0.0f);
}

TEST_CASE("[PathTracer][LightSelect] the floor is under the product, not each factor") {
	// Distinguishes a product-level floor from a per-factor one. A per-factor
	// floor passes every straddle case above while leaking weight to lights that
	// are genuinely out of range -- so without this case the two implementations
	// are indistinguishable.
	MirrorLight out_of_range;
	out_of_range.type = LIGHT_TYPE_OMNI;
	out_of_range.position = Vector3(0, 0, 50.0f);
	out_of_range.inv_max_range = 1.0f / 5.0f;
	out_of_range.max_range_squared = 25.0f;
	out_of_range.emission = Vector3(1000, 1000, 1000);
	CHECK(mirror_weight(Vector3(0, 0, 0), out_of_range, false) == 0.0f);

	// In range but with both spatial factors driven tiny: lands exactly on the floor.
	MirrorLight faint;
	faint.type = LIGHT_TYPE_OMNI;
	faint.position = Vector3(0, 0, 4.999f);
	faint.inv_max_range = 1.0f / 5.0f;
	faint.max_range_squared = 25.0f;
	faint.attenuation = 2.0f;
	faint.emission = Vector3(1, 1, 1);
	const float w = mirror_weight(Vector3(0, 0, 0), faint, false);
	CHECK(w == doctest::Approx(mirror_luminance(faint.emission) * RT_LIGHT_WEIGHT_FLOOR));

	// DISCRIMINATING case. The two OMNI configurations above cannot tell a
	// product-level floor apart from a per-factor one: OMNI pins spot_factor at
	// exactly 1.0, and max(A*1,F) == max(A,F)*max(1,F) for any A (both reduce to
	// max(A,F) because max(1,F) == 1 when F < 1). A SPOT light is required so
	// atten and spot_factor are BOTH free variables, and the two formulas only
	// diverge when one factor sits strictly below the floor while the other sits
	// meaningfully above it.
	//
	// Construction (worked by hand, not tuned against the code under test):
	//   - cos_spot_angle = 0, radius = 0 -> cos_widened = cos_spot_angle = 0,
	//     so spot_rim = (1 - scos) / (1 - 0) = 1 - scos, and with
	//     inv_spot_attenuation = 1, spot_factor = 1 - spot_rim = scos exactly.
	//   - dist = sqrt(2), attenuation = 2 (default), no range window
	//     -> atten = 1 / dist^2 = 1 / 2 = 0.5 exactly.
	//   - Pick scos = 0.0002 (comfortably above the scos <= 0 gate, ~2000x
	//     float epsilon, and comfortably below the 1e-3 floor): spot_factor = 0.0002.
	//   - atten * spot_factor = 0.5 * 0.0002 = 0.0001, which is BELOW the floor
	//     (1e-3), so the product formula's floor engages:
	//       product:    max(0.5 * 0.0002, 1e-3) = max(0.0001, 0.001) = 0.001
	//     while the per-factor formula does not, because atten = 0.5 alone
	//     clears the floor:
	//       per-factor: max(0.5, 1e-3) * max(0.0002, 1e-3) = 0.5 * 0.001 = 0.0005
	//   0.001 != 0.0005 -- the two formulas now disagree, which is the property
	//   this case exists to pin. Emission is (1,1,1) so mag == 1 and the
	//   expected weight equals the floor value directly.
	MirrorLight spot;
	spot.type = LIGHT_TYPE_SPOT;
	spot.position = Vector3(0, 0, 0);
	spot.spot_direction = Vector3(0, 0, -1);
	spot.cos_spot_angle = 0.0f;
	spot.radius = 0.0f;
	spot.inv_spot_attenuation = 1.0f;
	spot.attenuation = 2.0f;
	spot.emission = Vector3(1, 1, 1);

	const float dist = Math::sqrt(2.0f);
	const float target_scos = 0.0002f;
	const float pz = -target_scos * dist;
	const float px = Math::sqrt(MAX(0.0f, dist * dist - pz * pz));
	const Vector3 spot_p(px, 0.0f, pz);

	const float spot_w = mirror_weight(spot_p, spot, false);
	CHECK(spot_w == doctest::Approx(RT_LIGHT_WEIGHT_FLOOR));
}

TEST_CASE("[PathTracer][LightSelect] zero indirect energy weighs zero only on indirect bounces") {
	MirrorLight l;
	l.type = LIGHT_TYPE_OMNI;
	l.position = Vector3(0, 2, 0);
	l.emission = Vector3(1, 1, 1);
	l.indirect_energy = 0.0f;

	const Vector3 p(0, 0, 0);
	CHECK(mirror_weight(p, l, false) > 0.0f); // direct: contributes, must be weighted
	CHECK(mirror_weight(p, l, true) == 0.0f); // indirect: contributes nothing, matched
}

} // namespace TestPTLightSelect
