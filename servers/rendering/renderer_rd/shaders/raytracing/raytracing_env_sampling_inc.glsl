// Environment (sky) importance sampling for NEE.
// Requires: the EnvDist SSBO at set 0 binding 34 (Task 2, env_cdf.h) and
// `scene_data_block` (raytracing_common_inc.glsl) for the world<->sky rotation.
//
// A CPU mirror of the sky-space math lives in tests/servers/rendering/test_pt_env_cdf.cpp.
//
// CRITICAL INVARIANT: env_sample() and env_pdf_from_uv() must agree exactly.
// A BSDF ray that hits the sky is weighted against the pdf this file reports for
// its direction; if sampling and evaluation use different formulas, MIS is biased
// and no convergence test will catch it.
//
// COORDINATE SPACE (see env_cdf.h:50-93, "CONTRACT FOR CONSUMERS"): the CDF grid
// lives in SKY/OCTMAP space, not world space -- env_cdf_build.glsl walks cell
// centres straight into the octmap mapping with no rotation applied. Directions
// used to trace rays, and directions read back from a ray (e.g. gl_WorldRayDirectionEXT
// on a miss), are WORLD space. env_direction_from_uv() / env_uv_from_direction() /
// env_pdf_from_uv() below operate purely in sky space and must not be handed a
// world-space direction directly. env_sample() and env_pdf() are the world-facing
// entry points and do the rotation, using the exact same matrix the miss shader
// already uses to look up the sky (scene_raytracing_raygen.glsl, `sky_dir` block):
//
//     mat3 camera_basis = mat3(scene_data_block.data.inv_view_matrix);
//     mat3 world_to_sky = scene_data_block.data.radiance_inverse_xform * camera_basis;
//
// copied verbatim -- see env_world_to_sky() below. world_to_sky is orthonormal, so
// its inverse is its transpose; env_sample() uses that to go sky -> world after
// sampling. Both directions MUST use this identical matrix or an MIS weight built
// from one side's pdf and the other side's ray is evaluating two different
// distributions and silently biases the image.
//
// SCOPE NOTE: this file references `scene_data_block`, which is declared in
// raytracing_common_inc.glsl (set 0 binding 2), not in scene_data_inc.glsl (which
// only defines the SceneData struct). It is therefore included from
// scene_raytracing_raygen.glsl AFTER "raytracing_common_inc.glsl" in every stage
// block, not from raytracing_inc.glsl -- raytracing_inc.glsl is included before
// scene_data_inc.glsl in all five stages (required for MAX_VIEWS), so a
// scene_data_block reference placed there would fail to compile.

#define ENV_N_U 256
#define ENV_N_V 128
#define ENV_PI 3.141592653589

layout(set = 0, binding = 34, std430) restrict readonly buffer EnvDistRO {
	float floor_value;
	float marginal_total;
	float data[];
}
env_dist;

#define ENV_PREFIX_RAW_OFFSET 0
#define ENV_ROWSUM_ADJ_OFFSET (ENV_N_V * ENV_N_U)
#define ENV_MARGINAL_PREFIX_OFFSET (ENV_N_V * ENV_N_U + ENV_N_V)

/// Y-up SKY-space direction for a (u, v) in [0,1)^2. Matches env_cdf_build.glsl's
/// dir_from_uv() and ies_lookup_inc.glsl's convention. NOT a world-space direction
/// -- see the file header.
vec3 env_direction_from_uv(vec2 p_uv) {
	float phi = p_uv.x * 2.0 * ENV_PI;
	float theta = p_uv.y * ENV_PI;
	float st = sin(theta);
	return vec3(st * sin(phi), cos(theta), st * cos(phi));
}

/// Inverse of env_direction_from_uv. Takes a SKY-space direction.
vec2 env_uv_from_direction(vec3 p_dir) {
	float theta = acos(clamp(p_dir.y, -1.0, 1.0));
	float phi = atan(p_dir.x, p_dir.z);
	// atan(y, x) returns (-PI, PI]; a bare divide gives a NEGATIVE u for half the
	// sphere. The buffer contract (env_cdf.h:69-77) mandates fract(), not an
	// if-guarded add -- the two are numerically equivalent over this domain, but
	// fract() is what the contract and the CPU mirror (test_pt_env_cdf.cpp,
	// "dir_from_uv matches the documented Y-up convention") name explicitly.
	float u = fract(phi / (2.0 * ENV_PI));
	return vec2(u, theta / ENV_PI);
}

/// f for a cell, with the relative floor folded in. Parameter order (y, x)
/// matches the CPU mirror's cell_value(d, p_y, p_x) -- kept aligned deliberately
/// so a future side-by-side diff of the two files does not have to mentally
/// transpose the argument order.
float env_cell_value(int p_y, int p_x) {
	int idx = ENV_PREFIX_RAW_OFFSET + p_y * ENV_N_U + p_x;
	float lo = (p_x == 0) ? 0.0 : env_dist.data[idx - 1];
	return (env_dist.data[idx] - lo) + env_dist.floor_value;
}

/// Solid-angle pdf for the cell containing p_uv (SKY-space uv). THE shared formula
/// -- env_sample() and env_pdf() both route through this and only this. This is
/// already the correct density for a sampler that jitters CONTINUOUSLY within the
/// cell (not one that always returns the cell centre) -- see env_sample()'s (du, dv)
/// remap below, which is what makes the two agree as measures, not just as numbers.
float env_pdf_from_uv(vec2 p_uv) {
	if (env_dist.marginal_total <= 0.0) {
		return 0.0;
	}
	int x = clamp(int(p_uv.x * float(ENV_N_U)), 0, ENV_N_U - 1);
	int y = clamp(int(p_uv.y * float(ENV_N_V)), 0, ENV_N_V - 1);
	float func_int = env_dist.marginal_total / float(ENV_N_U * ENV_N_V);
	float pdf_uv = env_cell_value(y, x) / func_int;
	float sin_theta = sin(p_uv.y * ENV_PI);
	return pdf_uv / (2.0 * ENV_PI * ENV_PI * max(sin_theta, 1e-6));
}

/// world_to_sky rotation, copied verbatim from the miss shader's `sky_dir` block
/// (scene_raytracing_raygen.glsl). Orthonormal: transpose() is its inverse.
mat3 env_world_to_sky() {
	mat3 camera_basis = mat3(scene_data_block.data.inv_view_matrix);
	return scene_data_block.data.radiance_inverse_xform * camera_basis;
}

/// pdf for an arbitrary WORLD-space direction. Converts world -> sky, then routes
/// through the same env_pdf_from_uv() that env_sample() uses.
///
/// NaN firewall: unlike env_sample() (which fails closed on a non-positive
/// marginal_total), this function has no such gate on its input -- p_dir can come
/// from a degenerate BSDF sample. A NaN pdf would poison a MIS weight downstream
/// (power_heuristic(NaN, x) is NaN, not a clamped value), so scrub it here the same
/// way sanitize_payload_value() (raytracing_inc.glsl) scrubs the payload.
float env_pdf(vec3 p_dir) {
	vec3 sky_dir = env_world_to_sky() * p_dir;
	float pdf = env_pdf_from_uv(env_uv_from_direction(sky_dir));
	pdf = isnan(pdf) ? 0.0 : pdf;
	return max(pdf, 0.0);
}

/// Sample a direction proportional to sky radiance. Returns false when no usable
/// distribution exists (no environment, or an all-black sky). r_dir is WORLD-space,
/// ready to trace.
///
/// Cell selection (binary search) picks a CELL, but the pdf env_pdf_from_uv()
/// reports is a CONTINUOUS density over (u, v) -- the density of "pick a cell
/// proportional to its value, then pick a point uniformly inside it". Returning
/// the cell centre for every sample would make the actual sampled measure a sum of
/// ENV_N_U*ENV_N_V Dirac deltas while the reported density stays continuous: not
/// the same measure, so `env_pdf(env_sample(...))` still round-trips and the pdf
/// still integrates to 1, but the MIS/NEE estimator silently stops being a Monte
/// Carlo estimator of the sky integral -- it degenerates into a fixed-resolution
/// quadrature that does not converge with more samples. Fixed by inverting the
/// CDF continuously within the selected cell (the standard pbrt/Cycles remap):
/// (du, dv) is where `target` fell between the cell's lower and upper prefix-sum
/// bounds, linearly, so cell interiors are covered with positive probability
/// instead of only their centres.
bool env_sample(vec2 p_rand, out vec3 r_dir, out float r_pdf) {
	r_dir = vec3(0.0, 1.0, 0.0);
	r_pdf = 0.0;
	if (env_dist.marginal_total <= 0.0) {
		return false;
	}

	// Invert the marginal (binary search over rows).
	float target_v = p_rand.y * env_dist.marginal_total;
	int lo = 0;
	int hi = ENV_N_V - 1;
	while (lo < hi) {
		int mid = (lo + hi) >> 1;
		if (env_dist.data[ENV_MARGINAL_PREFIX_OFFSET + mid] < target_v) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	int y = lo;

	// Continuous position within row y. The `m_hi > m_lo` guard is load-bearing,
	// not defensive: at fp32 precision consecutive marginal_prefix entries CAN be
	// bit-identical (a dim row next to a near-zero floor contribution), in which
	// case target_v lands exactly on both bounds and the interpolant is undefined
	// without the guard -- fall back to the cell centre (dv = 0.5) in that case.
	float m_lo = (y == 0) ? 0.0 : env_dist.data[ENV_MARGINAL_PREFIX_OFFSET + y - 1];
	float m_hi = env_dist.data[ENV_MARGINAL_PREFIX_OFFSET + y];
	float dv = (m_hi > m_lo) ? clamp((target_v - m_lo) / (m_hi - m_lo), 0.0, 1.0) : 0.5;

	// Invert the row conditional. The stored prefixes are of the RAW f, so the
	// floor is added arithmetically here -- see the layout note in the plan.
	float target_u = p_rand.x * env_dist.data[ENV_ROWSUM_ADJ_OFFSET + y];
	lo = 0;
	hi = ENV_N_U - 1;
	while (lo < hi) {
		int mid = (lo + hi) >> 1;
		float adj = env_dist.data[ENV_PREFIX_RAW_OFFSET + y * ENV_N_U + mid] +
				float(mid + 1) * env_dist.floor_value;
		if (adj < target_u) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	int x = lo;

	// Continuous position within cell (x, y). Same fp32-tie guard as above: with a
	// bright sun, prefix_raw magnitudes swamp the floor's ulp contribution and
	// consecutive adj() values can coincide exactly (see the file's Step-3 note in
	// the task report for the concrete magnitudes).
	float cdf_lo = (x == 0) ? 0.0 : env_dist.data[ENV_PREFIX_RAW_OFFSET + y * ENV_N_U + x - 1] +
			float(x) * env_dist.floor_value;
	float cdf_hi = env_dist.data[ENV_PREFIX_RAW_OFFSET + y * ENV_N_U + x] +
			float(x + 1) * env_dist.floor_value;
	float du = (cdf_hi > cdf_lo) ? clamp((target_u - cdf_lo) / (cdf_hi - cdf_lo), 0.0, 1.0) : 0.5;

	vec2 uv = vec2((float(x) + du) / float(ENV_N_U), (float(y) + dv) / float(ENV_N_V));
	vec3 sky_dir = env_direction_from_uv(uv);
	r_dir = transpose(env_world_to_sky()) * sky_dir; // sky -> world.
	r_pdf = env_pdf_from_uv(uv);
	return r_pdf > 0.0;
}
