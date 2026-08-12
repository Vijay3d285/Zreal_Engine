// Importance-weighted light selection for analytic-light NEE (roadmap C2).
//
// Requires: raytracing_lights_inc.glsl (RTLightData, RT_LIGHT_TYPE_*,
// lights_attenuation_from_dist_sq, the rt_lights SSBO) and brdf_inc.glsl
// (luminance). Include it AFTER those.
//
// Replaces the uniform k=16 mini-batch reservoir, which had two defects: with
// 41 lights it never even considered the brightest one at ~60% of shading
// points, and its pdf was ESTIMATED (valid_count_estimate is a random variable,
// and E[1/X] != 1/E[X]), so the density was biased whenever range culling
// rejected anything.
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
	// Magnitude, not signed luminance: compute_light_energy() applies sign = -1
	// for a negative light (render_raytracing.cpp:2755), so emission arrives
	// negative in every channel. A signed weight would corrupt the CDF. The sign
	// is uniform across channels, so abs(luminance(e)) == luminance(abs(e)).
	float mag = abs(luminance(p_light.emission));
	if (mag <= 0.0) {
		return 0.0;
	}

	// indirect_energy multiplies the contribution for every type on indirect
	// bounces (raytracing_lights_inc.glsl:336, :462, :505), so zero here means
	// zero contribution there -- matched, no bias.
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
	// (:315) while this knows only the centre, so a rect straddling the boundary
	// would weigh 0 with part of it still lit. Expand by a conservative bound on
	// the half-diagonal. (length(U) + length(V) >= |U +/- V| for any U, V.)
	float near_dist = dist;
	if (p_light.type == RT_LIGHT_TYPE_RECT) {
		// For RECT, spot_direction is aliased to axisU (:284) -- it is NOT a cone axis.
		vec3 axis_u = p_light.spot_direction;
		vec3 axis_v = vec3(p_light.rect_axis_v[0], p_light.rect_axis_v[1], p_light.rect_axis_v[2]);
		near_dist = max(0.0, dist - (length(axis_u) + length(axis_v)));
	}
	if (p_light.max_range_squared != 0.0 && near_dist * near_dist > p_light.max_range_squared) {
		return 0.0;
	}

	float atten = lights_attenuation_from_dist_sq(dist_sq, p_light.inv_max_range, p_light.attenuation);

	float spot_factor = 1.0;
	// Gated on type, NOT on the falloff fields being populated: RECT lights also
	// carry a cos_spot_angle (they are spots with angle >= 179.9, see
	// render_raytracing.cpp:2887) and reusing it here would cone-cull a quad.
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

		// CLAMPED TO 1.0, unlike the shading path's max(1e-4, ...) at :439.
		// Widening the cone above admits directions between the widened and the
		// true cone on purpose, and for exactly those the raw ratio exceeds 1,
		// making 1 - pow(ratio, k) NEGATIVE. A negative weight corrupts the CDF
		// walk far worse than the zero the widening exists to prevent.
		float spot_rim = clamp((1.0 - scos) / (1.0 - p_light.cos_spot_angle), 1e-4, 1.0);
		spot_factor = 1.0 - pow(spot_rim, p_light.inv_spot_attenuation);
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
