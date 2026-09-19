// Light portals (spec 2026-09-18-light-portals-design.md): a sampling hint for
// the sky, not a light. Transcribed from Cycles 5.3.0-alpha
// kernel/light/background.h (portal facing test, portal pdf, portal sample) and
// kernel/light/area.h (Urena spherical-rectangle sampling); the line cited
// above each function is the original.
//
// Included from raytracing_common_inc.glsl immediately before
// raytracing_env_sampling_inc.glsl, so every stage that has the sky sampler
// has the portals (the miss stage evaluates the portal pdf for MIS and does
// NOT include the light buffer -- hence a buffer of their own).
//
// Requires: get_rt_param (raytracing_common_inc.glsl), RT_PARAM_PORTAL_COUNT
// (raytracing_inc.glsl).

// MIRRORS C++ RT_PortalData (render_raytracing.h), 64 bytes, std430.
struct RTPortalData {
	vec3 position; // Rectangle centre, world space.
	float _pad0;
	vec3 axis_u; // Unit axis along the width (the light's local +X).
	float len_u; // Full width.
	vec3 axis_v; // Unit axis along the height (local +Y).
	float len_v; // Full height.
	vec3 dir; // Facing direction (local -Z); a point P is "in front" when dot(dir, P - position) > 0.
	float _pad1;
};

layout(set = 0, binding = 41, std430) readonly buffer PortalBuffer {
	RTPortalData rt_portals[];
};

#ifndef RT_STAGE_ANY_HIT
int portal_count() {
	return int(get_rt_param(RT_PARAM_PORTAL_COUNT));
}
#else
// The any-hit stage has no params UBO (raytracing_common_inc.glsl guards it
// out) and never samples the sky; the sky sampler still has to compile there.
int portal_count() {
	return 0;
}
#endif

// util/math_base.h:571 safe_asinf.
float portal_safe_asin(float a) {
	return asin(clamp(a, -1.0, 1.0));
}

// util/math_base.h safe_divide: a / b, or 0 when b == 0.
float portal_safe_divide(float a, float b) {
	return (b != 0.0) ? a / b : 0.0;
}

// background.h:153 background_portal_data_fetch_and_check_side.
bool portal_fetch_and_check_side(int p_index, vec3 P, out vec3 r_pos, out vec3 r_dir) {
	r_pos = rt_portals[p_index].position;
	r_dir = rt_portals[p_index].dir;
	// Check whether portal is on the right side.
	return dot(r_dir, P - r_pos) > 1e-4;
}

// area.h:19 area_light_rect_sample -- Urena et al., "An Area-Preserving
// Parametrization for Spherical Rectangles", with Cycles' asin reformulation
// for small rectangles and its planar-pdf fallback. p_light_p is the centre on
// entry and, when p_sample_coord, the sampled point on exit. Returns the
// solid-angle pdf.
float portal_rect_sample(vec3 P, inout vec3 p_light_p, vec3 p_axis_u, float p_len_u, vec3 p_axis_v, float p_len_v, vec2 p_rand, bool p_sample_coord) {
	// Compute local reference system R.
	vec3 x = p_axis_u;
	vec3 y = p_axis_v;
	vec3 z = cross(x, y);
	// Compute rectangle coords in local reference system.
	vec3 dir = p_light_p - P;
	float z0 = dot(dir, z);
	// Flip 'z' to make it point against Q.
	if (z0 > 0.0) {
		z = -z;
		z0 = -z0;
	}
	float xc = dot(dir, x);
	float yc = dot(dir, y);
	float x0 = xc - 0.5 * p_len_u;
	float x1 = xc + 0.5 * p_len_u;
	float y0 = yc - 0.5 * p_len_v;
	float y1 = yc + 0.5 * p_len_v;
	// Compute predefined constants.
	vec4 nz = vec4(-y0, x1, y1, -x0);
	nz /= sqrt(nz * nz + vec4(z0 * z0));
	// asin(x) = pi/2 - acos(x): avoids the cancellation of the acos form for
	// very small rectangles (Cycles' comment at area.h:49).
	float g0 = portal_safe_asin(-nz.x * nz.y);
	float g1 = portal_safe_asin(-nz.y * nz.z);
	float g2 = portal_safe_asin(-nz.z * nz.w);
	float g3 = portal_safe_asin(-nz.w * nz.x);
	float S = -(g0 + g1 + g2 + g3);

	if (p_sample_coord) {
		// Compute predefined constants.
		float b0 = nz.x;
		float b1 = nz.z;
		float b0sq = b0 * b0;
		// Compute cu (area.h:64-72).
		float au = p_rand.x * S + g2 + g3;
		float fu = portal_safe_divide(cos(au) * b0 + b1, sin(au));
		float cu = ((fu >= 0.0) ? 1.0 : -1.0) / sqrt(fu * fu + b0sq); // copysignf(1/sqrt(...), fu)
		cu = clamp(cu, -1.0, 1.0);
		// Compute xu.
		float xu = -(cu * z0) / max(sqrt(1.0 - cu * cu), 1e-7);
		xu = clamp(xu, x0, x1);
		// Compute yv.
		float d2 = xu * xu + z0 * z0;
		float h0 = y0 / sqrt(d2 + y0 * y0);
		float h1 = y1 / sqrt(d2 + y1 * y1);
		float hv = h0 + p_rand.y * (h1 - h0);
		float hv2 = hv * hv;
		float yv = (hv2 < 1.0 - 1e-6) ? hv * sqrt(d2 / (1.0 - hv2)) : y1;

		// Transform (xu, yv, z0) to world coords.
		p_light_p = P + xu * x + yv * y + z0 * z;
	}

	// Return pdf (area.h:89-101): the solid angle is too small to be computed
	// accurately in single precision, or the rectangle is seen edge-on --
	// fall back to the planar pdf.
	vec4 nz2 = nz * nz;
	if (S < 1e-5 || min(min(nz2.x, nz2.y), min(nz2.z, nz2.w)) > 0.99999) {
		float t = length(dir);
		return portal_safe_divide(-t * t * t, z0 * p_len_u * p_len_v);
	}
	return 1.0 / S;
}

// util/math_intersect.h:288 ray_quad_intersect, rectangle only, tmin 1e-4,
// no tmax. p_inv_u / p_inv_v are axis / length, so |u|, |v| <= 0.5 is inside.
bool portal_ray_quad_intersect(vec3 P, vec3 D, vec3 p_quad_p, vec3 p_inv_u, vec3 p_inv_v, vec3 p_quad_n) {
	float denom = dot(D, p_quad_n);
	if (denom == 0.0) {
		return false;
	}
	float t = -(dot(P, p_quad_n) - dot(p_quad_p, p_quad_n)) / denom;
	if (!(t > 1e-4)) {
		return false;
	}
	vec3 hit = P + t * D;
	vec3 inplane = hit - p_quad_p;
	float u = dot(inplane, p_inv_u);
	if (u < -0.5 || u > 0.5) {
		return false;
	}
	float v = dot(inplane, p_inv_v);
	if (v < -0.5 || v > 0.5) {
		return false;
	}
	return true;
}

// background.h:247 background_num_possible_portals.
int portal_num_possible(vec3 P) {
	int n = 0;
	int count = portal_count();
	for (int p = 0; p < count; p++) {
		vec3 pos;
		vec3 dir;
		if (portal_fetch_and_check_side(p, P, pos, dir)) {
			n++;
		}
	}
	return n;
}

// background.h:173 background_portal_pdf. The pdf of direction D under the
// portal strategy at P: the mean over every portal facing P of that portal's
// solid-angle pdf (zero when D misses its quad). p_ignore_portal skips one
// portal's pdf but still counts it (the caller already holds it).
float portal_pdf(vec3 P, vec3 D, int p_ignore_portal, out bool r_is_possible) {
	r_is_possible = false;
	float pdf = 0.0;
	int num_possible = 0;
	int count = portal_count();
	for (int p = 0; p < count; p++) {
		if (p == p_ignore_portal) {
			continue;
		}
		vec3 pos;
		vec3 dir;
		if (!portal_fetch_and_check_side(p, P, pos, dir)) {
			continue;
		}
		// There's a portal that could be sampled from this position.
		r_is_possible = true;
		num_possible++;

		vec3 axis_u = rt_portals[p].axis_u;
		float len_u = rt_portals[p].len_u;
		vec3 axis_v = rt_portals[p].axis_v;
		float len_v = rt_portals[p].len_v;
		if (!portal_ray_quad_intersect(P, D, pos, axis_u / len_u, axis_v / len_v, dir)) {
			continue;
		}
		vec3 light_p = pos;
		pdf += portal_rect_sample(P, light_p, axis_u, len_u, axis_v, len_v, vec2(0.0), false);
	}
	if (p_ignore_portal >= 0) {
		// We have skipped a portal that could be sampled as well.
		num_possible++;
	}
	return (num_possible > 0) ? pdf / float(num_possible) : 0.0;
}

// background.h:260 background_portal_sample. Picks one of the p_num_possible
// facing portals uniformly on rand.y (renormalised), samples a point on it,
// returns the world direction; r_pdf is that portal's pdf / p_num_possible.
vec3 portal_sample(vec3 P, vec2 p_rand, int p_num_possible, out int r_sampled_portal, out float r_pdf) {
	r_sampled_portal = -1;
	r_pdf = 0.0;
	// Pick a portal, then re-normalize rand.y.
	p_rand.y *= float(p_num_possible);
	int portal = min(int(p_rand.y), p_num_possible - 1); // clamp: rand.y == 1.0 exactly would overrun
	p_rand.y -= float(portal);

	int count = portal_count();
	for (int p = 0; p < count; p++) {
		// Search for the sampled portal.
		vec3 pos;
		vec3 dir;
		if (!portal_fetch_and_check_side(p, P, pos, dir)) {
			continue;
		}
		if (portal == 0) {
			// p is the portal to be sampled.
			vec3 light_p = pos;
			r_pdf = portal_rect_sample(P, light_p, rt_portals[p].axis_u, rt_portals[p].len_u, rt_portals[p].axis_v, rt_portals[p].len_v, p_rand, true);
			r_pdf /= float(p_num_possible);
			r_sampled_portal = p;
			return normalize(light_p - P);
		}
		portal--;
	}
	return vec3(0.0);
}
