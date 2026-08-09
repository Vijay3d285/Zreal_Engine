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

/// f for a cell, with the relative floor folded in.
float env_cell_value(int p_x, int p_y) {
	int idx = ENV_PREFIX_RAW_OFFSET + p_y * ENV_N_U + p_x;
	float lo = (p_x == 0) ? 0.0 : env_dist.data[idx - 1];
	return (env_dist.data[idx] - lo) + env_dist.floor_value;
}

/// Solid-angle pdf for the cell containing p_uv (SKY-space uv). THE shared formula
/// -- env_sample() and env_pdf() both route through this and only this.
float env_pdf_from_uv(vec2 p_uv) {
	if (env_dist.marginal_total <= 0.0) {
		return 0.0;
	}
	int x = clamp(int(p_uv.x * float(ENV_N_U)), 0, ENV_N_U - 1);
	int y = clamp(int(p_uv.y * float(ENV_N_V)), 0, ENV_N_V - 1);
	float func_int = env_dist.marginal_total / float(ENV_N_U * ENV_N_V);
	float pdf_uv = env_cell_value(x, y) / func_int;
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
float env_pdf(vec3 p_dir) {
	vec3 sky_dir = env_world_to_sky() * p_dir;
	return env_pdf_from_uv(env_uv_from_direction(sky_dir));
}

/// Sample a direction proportional to sky radiance. Returns false when no usable
/// distribution exists (no environment, or an all-black sky). r_dir is WORLD-space,
/// ready to trace.
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

	vec2 uv = vec2((float(x) + 0.5) / float(ENV_N_U), (float(y) + 0.5) / float(ENV_N_V));
	vec3 sky_dir = env_direction_from_uv(uv);
	r_dir = transpose(env_world_to_sky()) * sky_dir; // sky -> world.
	r_pdf = env_pdf_from_uv(uv);
	return r_pdf > 0.0;
}
