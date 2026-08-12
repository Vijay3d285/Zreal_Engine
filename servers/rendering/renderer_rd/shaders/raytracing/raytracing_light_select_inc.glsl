// Importance-weighted light selection for analytic-light NEE (roadmap C2).
//
// Requires: raytracing_lights_inc.glsl (RTLightData, RT_LIGHT_TYPE_*,
// lights_attenuation_from_dist_sq, the rt_lights SSBO) and brdf_inc.glsl
// (luminance). Include it AFTER those.
//
// Replaces the uniform k=16 mini-batch reservoir, whose defect is VARIANCE: with
// 41 lights it never even considered the brightest one at 67.4% of shading
// points ((40/41)^16), and compensated by scaling up the draws that did find it,
// producing a heavy-tailed estimator. Measured at 9.8x-16.5x the equal-time RMSE
// of this selector on that configuration (task-3 report).
//
// Its pdf was also ESTIMATED rather than known (valid_count_estimate is a random
// variable). The design spec expected that to BIAS the converged image under
// range culling via E[1/X] != 1/E[X]; the culled energy gate measured no shift,
// because the reciprocal is never taken -- the estimator multiplies by
// valid_count_estimate, whose expectation is exactly the valid count. The pre-C2
// estimator is exactly unbiased, culling or not; see raytracing_lights_inc.glsl's
// control-path comment for the full argument.
// An exactly-known pdf is still worth having: it is what lets the selection
// density be chosen freely (by power) instead of being pinned to uniform.
//
// THE INVARIANT THIS FILE MUST PRESERVE: a light with weight 0 is never
// selected, so zero weight must imply zero contribution. Otherwise the
// estimator silently loses energy -- a converged image that is simply wrong.
// Three cases where the naive weight violates that are handled below and each
// is marked. See docs/superpowers/specs/2026-08-11-power-weighted-light-selection-design.md
// section 3.2, and tests/servers/rendering/test_pt_light_select.cpp.

#ifndef RT_LIGHT_WEIGHT_FLOOR
#define RT_LIGHT_WEIGHT_FLOOR 1e-3
#endif

/// Importance of `p_light` at `p_hit_pos`. Always >= 0.
float lights_select_weight(vec3 p_hit_pos, RTLightData p_light, bool p_is_indirect_bounce) {
	// Magnitude, not signed luminance: RenderRaytracing::gather_lights() applies
	// sign = -1 for a negative light (`light_is_negative`), so emission arrives
	// negative in every channel. A signed weight would corrupt the CDF. The sign
	// is uniform across channels, so abs(luminance(e)) == luminance(abs(e)).
	float mag = abs(luminance(p_light.emission));
	if (mag <= 0.0) {
		return 0.0;
	}

	// indirect_energy multiplies the contribution for every type on indirect
	// bounces -- all three shading sites in raytracing_lights_inc.glsl compute
	// `indirect_mul`: one in lights_eval_rect_light, and one in each of the
	// positional (omni+spot) and directional branches of
	// lights_evaluate_direct_lighting. So zero here means zero contribution
	// there -- matched, no bias.
	float indirect_factor = p_is_indirect_bounce ? p_light.indirect_energy : 1.0;
	if (indirect_factor <= 0.0) {
		return 0.0;
	}

	// Directional: no distance falloff, no cone, no range.
	if (p_light.type == RT_LIGHT_TYPE_DIRECTIONAL) {
		return mag * indirect_factor;
	}

	vec3 to_light = p_light.position - p_hit_pos;
	float dist_sq = dot(to_light, to_light);
	float dist = sqrt(dist_sq);

	// HAZARD 1 -- rect range. Shading range-tests the SAMPLED point on the quad
	// (the max_range_squared early-out in lights_eval_rect_light, which tests
	// `sample_point`, not the centre) while this knows only the centre, so a rect
	// straddling the boundary would weigh 0 with part of it still lit. Expand by a conservative bound on
	// the half-diagonal. (length(U) + length(V) >= |U +/- V| for any U, V.)
	float near_dist = dist;
	if (p_light.type == RT_LIGHT_TYPE_RECT) {
		// For RECT, spot_direction is aliased to axisU -- lights_eval_rect_light
		// opens with `vec3 axisU = light.spot_direction;`. It is NOT a cone axis.
		vec3 axis_u = p_light.spot_direction;
		vec3 axis_v = vec3(p_light.rect_axis_v[0], p_light.rect_axis_v[1], p_light.rect_axis_v[2]);
		near_dist = max(0.0, dist - (length(axis_u) + length(axis_v)));
	}
	if (p_light.max_range_squared != 0.0 && near_dist * near_dist > p_light.max_range_squared) {
		return 0.0;
	}

	// _from_dist, not _from_dist_sq: `dist` is already in hand above, and the
	// _sq entry point would take a second sqrt of a value already rooted.
	float atten = lights_attenuation_from_dist(dist, p_light.inv_max_range, p_light.attenuation);

	float spot_factor = 1.0;
	// Gated on type, NOT on the falloff fields being populated: RECT lights also
	// carry a cos_spot_angle (RenderRaytracing::gather_lights() emits them as
	// spots with angle >= 179.9) and reusing it here would cone-cull a quad.
	if (p_light.type == RT_LIGHT_TYPE_SPOT) {
		vec3 L = to_light / max(dist, 1e-4);
		float scos = dot(-L, p_light.spot_direction);

		// HAZARD 2 -- spot cone. For a sphere light of radius r the SAMPLED
		// direction can be inside the cone while the centre direction is outside,
		// so widen the test by the angular radius asin(r/d). Done with the cosine
		// addition formula to avoid an acos/cos round trip:
		// cos(a + b) = cos a cos b - sin a sin b.
		float sin_b = clamp(p_light.radius / max(dist, 1e-4), 0.0, 1.0);
		float cos_b = sqrt(max(0.0, 1.0 - sin_b * sin_b));
		float cos_a = p_light.cos_spot_angle;
		float sin_a = sqrt(max(0.0, 1.0 - cos_a * cos_a));
		if (scos <= cos_a * cos_b - sin_a * sin_b) {
			return 0.0;
		}

		// CLAMPED TO 1.0, unlike the shading path's spot_rim, which is
		// `max(1e-4, ...)` in the positional (omni+spot) branch of
		// lights_evaluate_direct_lighting.
		// Widening the cone above admits directions between the widened and the
		// true cone on purpose, and for exactly those the raw ratio exceeds 1,
		// making 1 - pow(ratio, k) NEGATIVE. A negative weight corrupts the CDF
		// walk far worse than the zero the widening exists to prevent.
		float spot_rim = clamp((1.0 - scos) / (1.0 - p_light.cos_spot_angle), 1e-4, 1.0);

		// LINEAR, where the shading path raises spot_rim to inv_spot_attenuation.
		// pow() is a transcendental and this runs 2N times per shading point; the
		// exponent only reshapes how samples are distributed INSIDE the cone, and
		// cannot introduce bias, because the ONLY thing that can zero a spot's
		// weight is the widened cone test above, which is preserved exactly.
		// Both forms are 1 on the axis and 0 at the rim, so the floor still takes
		// over in the same place. Off-axis points whose true falloff is steeper
		// than linear are oversampled relative to their contribution -- variance,
		// bought for two fewer pow() per spot light per pass.
		// Exact when inv_spot_attenuation == 1.0.
		spot_factor = 1.0 - spot_rim;
	}

	// HAZARD 3 -- both continuous factors decay smoothly to zero at a boundary
	// the light's own extent straddles. The floor sits under their PRODUCT, after
	// the discrete tests above have already returned 0 for lights that truly
	// contribute nothing. Under each factor separately it would leak weight to
	// out-of-range lights; over the product it cannot, because those already
	// returned. Cost is variance on a rare configuration, which is the correct
	// direction to trade against a bias.
	float spatial = max(atten * spot_factor, RT_LIGHT_WEIGHT_FLOOR);

	return mag * spatial * indirect_factor;
}

/// Draw one light proportional to lights_select_weight(). Returns false when
/// every light weighs zero, which means every light contributes zero -- black is
/// the correct answer there, NOT a uniform fallback. A fallback would resume
/// sampling lights that provably contribute nothing.
///
/// Two passes over the <=64-light array (RT_LIGHTS_MAX in render_raytracing.h).
/// The second pass recomputes the weights rather than caching them: a 64-float
/// local array in a raytracing stage will very likely spill to scratch memory,
/// and the occupancy loss costs more than the arithmetic it saves.
bool lights_select(vec3 p_hit_pos, uint p_light_count, bool p_is_indirect_bounce, float p_u,
		out uint r_index, out float r_pdf) {
	r_index = 0u;
	r_pdf = 0.0;

	// Pass 1: normalizer.
	float total = 0.0;
	for (uint i = 0u; i < p_light_count; i++) {
		total += lights_select_weight(p_hit_pos, rt_lights[i], p_is_indirect_bounce);
	}
	// Written as !(total > 0.0) so a NaN normalizer takes this branch too.
	if (!(total > 0.0)) {
		return false;
	}

	// Pass 2: walk to u * total.
	float target = p_u * total;
	float running = 0.0;
	uint last_pos = 0u;
	float last_w = 0.0;
	for (uint i = 0u; i < p_light_count; i++) {
		float w = lights_select_weight(p_hit_pos, rt_lights[i], p_is_indirect_bounce);
		if (w <= 0.0) {
			continue;
		}
		last_pos = i;
		last_w = w;
		running += w;
		if (running > target) {
			r_index = i;
			r_pdf = w / total;
			return true;
		}
	}

	// Drift guard. The two passes sum the same values in the same order, but a
	// GPU compiler is free to reassociate/fuse each pass's additions differently,
	// so pass 2's running sum can end up strictly less than pass 1's total.
	// NOT reachable by varying p_u alone for a fixed total -- p_u * total can
	// never land at or past the real running sum through rounding when both
	// passes agree on total; do not try to construct a p_u that triggers this.
	// Answer with the last positive-weight light -- never an index past the array,
	// and never a zero-weight light (which would be a pdf of 0 on a taken path).
	if (last_w > 0.0) {
		r_index = last_pos;
		r_pdf = last_w / total;
		return true;
	}
	return false; // Unreachable while total > 0; kept so every path returns.
}
