///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2016, Intel Corporation
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of
// the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// File changes (yyyy-mm-dd)
// 2016-09-07: filip.strugar@intel.com: first commit
// 2020-12-05: clayjohn: convert to Vulkan and Godot
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#[compute]

#version 450

#VERSION_DEFINES

#define INTELSSAO_MAIN_DISK_SAMPLE_COUNT (32)
const vec4 sample_pattern[INTELSSAO_MAIN_DISK_SAMPLE_COUNT] = {
	vec4(0.78488064, 0.56661671, 1.500000, -0.126083), vec4(0.26022232, -0.29575172, 1.500000, -1.064030), vec4(0.10459357, 0.08372527, 1.110000, -2.730563), vec4(-0.68286800, 0.04963045, 1.090000, -0.498827),
	vec4(-0.13570161, -0.64190155, 1.250000, -0.532765), vec4(-0.26193795, -0.08205118, 0.670000, -1.783245), vec4(-0.61177456, 0.66664219, 0.710000, -0.044234), vec4(0.43675563, 0.25119025, 0.610000, -1.167283),
	vec4(0.07884444, 0.86618668, 0.640000, -0.459002), vec4(-0.12790935, -0.29869005, 0.600000, -1.729424), vec4(-0.04031125, 0.02413622, 0.600000, -4.792042), vec4(0.16201244, -0.52851415, 0.790000, -1.067055),
	vec4(-0.70991218, 0.47301072, 0.640000, -0.335236), vec4(0.03277707, -0.22349690, 0.600000, -1.982384), vec4(0.68921727, 0.36800742, 0.630000, -0.266718), vec4(0.29251814, 0.37775412, 0.610000, -1.422520),
	vec4(-0.12224089, 0.96582592, 0.600000, -0.426142), vec4(0.11071457, -0.16131058, 0.600000, -2.165947), vec4(0.46562141, -0.59747696, 0.600000, -0.189760), vec4(-0.51548797, 0.11804193, 0.600000, -1.246800),
	vec4(0.89141309, -0.42090443, 0.600000, 0.028192), vec4(-0.32402530, -0.01591529, 0.600000, -1.543018), vec4(0.60771245, 0.41635221, 0.600000, -0.605411), vec4(0.02379565, -0.08239821, 0.600000, -3.809046),
	vec4(0.48951152, -0.23657045, 0.600000, -1.189011), vec4(-0.17611565, -0.81696892, 0.600000, -0.513724), vec4(-0.33930185, -0.20732205, 0.600000, -1.698047), vec4(-0.91974425, 0.05403209, 0.600000, 0.062246),
	vec4(-0.15064627, -0.14949332, 0.600000, -1.896062), vec4(0.53180975, -0.35210401, 0.600000, -0.758838), vec4(0.41487166, 0.81442589, 0.600000, -0.505648), vec4(-0.24106961, -0.32721516, 0.600000, -1.665244)
};

// these values can be changed (up to SSAO_MAX_TAPS) with no changes required elsewhere; values for 4th and 5th preset are ignored but array needed to avoid compilation errors
// the actual number of texture samples is two times this value (each "tap" has two symmetrical depth texture samples)
const int num_taps[5] = { 3, 8, 16, 0, 0 };

#define SSAO_TILT_SAMPLES_ENABLE_AT_QUALITY_PRESET (99) // to disable simply set to 99 or similar
#define SSAO_TILT_SAMPLES_AMOUNT (0.4)
//
#define SSAO_HALOING_REDUCTION_ENABLE_AT_QUALITY_PRESET (1) // to disable simply set to 99 or similar
#define SSAO_HALOING_REDUCTION_AMOUNT (0.6) // values from 0.0 - 1.0, 1.0 means max weighting (will cause artifacts, 0.8 is more reasonable)
//
#define SSAO_NORMAL_BASED_EDGES_ENABLE_AT_QUALITY_PRESET (2) // to disable simply set to 99 or similar
#define SSAO_NORMAL_BASED_EDGES_DOT_THRESHOLD (0.5) // use 0-0.1 for super-sharp normal-based edges
//
#define SSAO_DETAIL_AO_ENABLE_AT_QUALITY_PRESET (1) // whether to use detail; to disable simply set to 99 or similar
//
// WARNING: The MIP generation on the C++ side will be enabled on quality preset 2 regardless of
// this value, so if changing here, change the C++ side too.
#define SSAO_DEPTH_MIPS_ENABLE_AT_QUALITY_PRESET (2)
#define SSAO_DEPTH_MIPS_GLOBAL_OFFSET (-4.3) // best noise/quality/performance tradeoff, found empirically
//
// WARNING: The edge handling is hard-coded to 'disabled' on quality level 0, and enabled above,
// on the C++ side; while toggling it here will work for testing purposes, it will not yield
// performance gains (or correct results).
#define SSAO_DEPTH_BASED_EDGES_ENABLE_AT_QUALITY_PRESET (1)
//
#define SSAO_REDUCE_RADIUS_NEAR_SCREEN_BORDER_ENABLE_AT_QUALITY_PRESET (1)

#define SSAO_MAX_TAPS 32
#define SSAO_ADAPTIVE_TAP_BASE_COUNT 5
#define SSAO_ADAPTIVE_TAP_FLEXIBLE_COUNT (SSAO_MAX_TAPS - SSAO_ADAPTIVE_TAP_BASE_COUNT)
#define SSAO_DEPTH_MIP_LEVELS 4

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2DArray source_depth_mipmaps;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image2D source_normal;
layout(set = 0, binding = 2) uniform Constants { //get into a lower set
	vec4 rotation_matrices[20];
}
constants;

#ifdef ADAPTIVE
layout(rg8, set = 1, binding = 0) uniform restrict readonly image2DArray source_ssao;
layout(set = 1, binding = 1) uniform sampler2D source_importance;
layout(set = 1, binding = 2, std430) buffer Counter {
	uint sum;
}
counter;
#endif

layout(rg8, set = 2, binding = 0) uniform restrict writeonly image2D dest_image;

// This push_constant is full - 128 bytes - if you need to add more data, consider adding to the uniform buffer instead
layout(push_constant, std430) uniform Params {
	ivec2 screen_size;
	int pass;
	int quality;

	vec2 half_screen_pixel_size;
	int size_multiplier;
	float detail_intensity;

	vec2 NDC_to_view_mul;
	vec2 NDC_to_view_add;

	vec2 pad2;
	vec2 half_screen_pixel_size_x025;

	float radius;
	float intensity;
	float shadow_power;
	float shadow_clamp;

	float fade_out_mul;
	float fade_out_add;
	float horizon_angle_threshold;
	float inv_radius_near_limit;

	bool is_orthogonal;
	float neg_inv_radius;
	float load_counter_avg_div;
	float adaptive_sample_limit;

	ivec2 pass_coord_offset;
	vec2 pass_uv_offset;
}
params;

// packing/unpacking for edges; 2 bits per edge mean 4 gradient values (0, 0.33, 0.66, 1) for smoother transitions!
float pack_edges(vec4 p_edgesLRTB) {
	p_edgesLRTB = round(clamp(p_edgesLRTB, 0.0, 1.0) * 3.05);
	return dot(p_edgesLRTB, vec4(64.0 / 255.0, 16.0 / 255.0, 4.0 / 255.0, 1.0 / 255.0));
}

vec3 NDC_to_view_space(vec2 p_pos, float p_viewspace_depth) {
	if (params.is_orthogonal) {
		return vec3((params.NDC_to_view_mul * p_pos.xy + params.NDC_to_view_add), p_viewspace_depth);
	} else {
		return vec3((params.NDC_to_view_mul * p_pos.xy + params.NDC_to_view_add) * p_viewspace_depth, p_viewspace_depth);
	}
}

vec4 calculate_edges(const float p_center_z, const float p_left_z, const float p_right_z, const float p_top_z, const float p_bottom_z) {
	// slope-sensitive depth-based edge detection
	vec4 edgesLRTB = vec4(p_left_z, p_right_z, p_top_z, p_bottom_z) - p_center_z;
	vec4 edgesLRTB_slope_adjusted = edgesLRTB + edgesLRTB.yxwz;
	edgesLRTB = min(abs(edgesLRTB), abs(edgesLRTB_slope_adjusted));
	return clamp((1.3 - edgesLRTB / (p_center_z * 0.040)), 0.0, 1.0);
}

vec3 load_normal(ivec2 p_pos) {
	vec3 encoded_normal = normalize(imageLoad(source_normal, p_pos).xyz * 2.0 - 1.0);
	encoded_normal.z = -encoded_normal.z;
	return encoded_normal;
}

vec3 load_normal(ivec2 p_pos, ivec2 p_offset) {
	vec3 encoded_normal = normalize(imageLoad(source_normal, p_pos + p_offset).xyz * 2.0 - 1.0);
	encoded_normal.z = -encoded_normal.z;
	return encoded_normal;
}

// ---- GTAO: Ground-Truth Ambient Occlusion (Jimenez 2016) ----
// Replaces Intel ASSAO hemisphere-point sampling with horizon-based sweeping.

#define GTAO_PI 3.14159265
#define GTAO_PI_HALF 1.5707963

const int gtao_directions[5] = { 2, 3, 4, 6, 6 };
const int gtao_steps[5] = { 4, 6, 8, 10, 10 };

float interleaved_gradient_noise(vec2 p_pos) {
	return fract(52.9829189 * fract(dot(p_pos, vec2(0.06711056, 0.00583715))));
}

float gtao_integrate_arc(float p_h1, float p_h2, float p_n_angle) {
	float cos_n = cos(p_n_angle);
	float sin_n = sin(p_n_angle);
	return 0.25 * (-cos(2.0 * p_h1 - p_n_angle) + cos_n + 2.0 * p_h1 * sin_n
	             + (-cos(2.0 * p_h2 - p_n_angle) + cos_n + 2.0 * p_h2 * sin_n));
}

void generate_SSAO_shadows_internal(out float r_shadow_term, out vec4 r_edges, out float r_weight, const vec2 p_pos, int p_quality_level, bool p_adaptive_base) {
	vec2 pos_rounded = trunc(p_pos);
	uvec2 upos = uvec2(pos_rounded);
	float pix_z, pix_left_z, pix_top_z, pix_right_z, pix_bottom_z;

	vec4 valuesUL = textureGather(source_depth_mipmaps, vec3(pos_rounded * params.half_screen_pixel_size, params.pass));
	vec4 valuesBR = textureGather(source_depth_mipmaps, vec3((pos_rounded + vec2(1.0)) * params.half_screen_pixel_size, params.pass));

	pix_z = valuesUL.y;
	pix_left_z = valuesUL.x;
	pix_top_z = valuesUL.z;
	pix_right_z = valuesBR.z;
	pix_bottom_z = valuesBR.x;

	vec2 normalized_screen_pos = pos_rounded * params.half_screen_pixel_size + params.half_screen_pixel_size_x025;
	vec3 pix_center_pos = NDC_to_view_space(normalized_screen_pos, pix_z);

	uvec2 full_res_coord = upos * 2 * params.size_multiplier + params.pass_coord_offset.xy;
	vec3 pixel_normal = load_normal(ivec2(full_res_coord));

	const vec2 pixel_size_at_center = NDC_to_view_space(normalized_screen_pos.xy + params.half_screen_pixel_size, pix_center_pos.z).xy - pix_center_pos.xy;

	vec4 edgesLRTB = vec4(1.0, 1.0, 1.0, 1.0);
	if (!p_adaptive_base && (p_quality_level >= SSAO_DEPTH_BASED_EDGES_ENABLE_AT_QUALITY_PRESET)) {
		edgesLRTB = calculate_edges(pix_z, pix_left_z, pix_right_z, pix_top_z, pix_bottom_z);
	}

	if (!p_adaptive_base && (p_quality_level >= SSAO_NORMAL_BASED_EDGES_ENABLE_AT_QUALITY_PRESET)) {
		vec3 nl = load_normal(ivec2(full_res_coord), ivec2(-2, 0));
		vec3 nr = load_normal(ivec2(full_res_coord), ivec2(2, 0));
		vec3 nt = load_normal(ivec2(full_res_coord), ivec2(0, -2));
		vec3 nb = load_normal(ivec2(full_res_coord), ivec2(0, 2));
		const float dt = SSAO_NORMAL_BASED_EDGES_DOT_THRESHOLD;
		vec4 ne;
		ne.x = clamp((dot(pixel_normal, nl) + dt), 0.0, 1.0);
		ne.y = clamp((dot(pixel_normal, nr) + dt), 0.0, 1.0);
		ne.z = clamp((dot(pixel_normal, nt) + dt), 0.0, 1.0);
		ne.w = clamp((dot(pixel_normal, nb) + dt), 0.0, 1.0);
		edgesLRTB *= ne;
	}

	// --- GTAO core ---
	vec3 view_dir = params.is_orthogonal ? vec3(0.0, 0.0, 1.0) : normalize(pix_center_pos);

	float world_radius = params.radius;
	float too_close_limit = clamp(length(pix_center_pos) * params.inv_radius_near_limit, 0.0, 1.0) * 0.8 + 0.2;
	world_radius *= too_close_limit;
	float screen_radius = (0.85 * world_radius) / pixel_size_at_center.x;

	if (!p_adaptive_base && (p_quality_level >= SSAO_REDUCE_RADIUS_NEAR_SCREEN_BORDER_ENABLE_AT_QUALITY_PRESET)) {
		float near_border = min(min(normalized_screen_pos.x, 1.0 - normalized_screen_pos.x), min(normalized_screen_pos.y, 1.0 - normalized_screen_pos.y));
		screen_radius *= clamp(10.0 * near_border + 0.6, 0.0, 1.0);
	}

	screen_radius = max(screen_radius, 2.0);
	float falloff_radius_sq = world_radius * world_radius;

	int num_directions = gtao_directions[p_quality_level];
	int num_steps = gtao_steps[p_quality_level];

	float noise_rotation = interleaved_gradient_noise(pos_rounded + vec2(params.pass * 5)) * GTAO_PI;
	float noise_offset = interleaved_gradient_noise(pos_rounded * 3.73 + vec2(params.pass * 7 + 11)) * 0.3 + 0.15;

	float ao_sum = 0.0;
	float dir_step = GTAO_PI / float(num_directions);

	for (int dir_idx = 0; dir_idx < num_directions; dir_idx++) {
		float phi = dir_step * (float(dir_idx) + 0.5) + noise_rotation;
		vec2 dir_screen = vec2(cos(phi), sin(phi));
		vec2 step_uv = dir_screen * screen_radius * params.half_screen_pixel_size / float(num_steps);

		vec3 slice_dir_vs = normalize(vec3(dir_screen * pixel_size_at_center, 0.0));
		vec3 slice_plane_normal = normalize(cross(slice_dir_vs, view_dir));
		vec3 proj_normal = pixel_normal - slice_plane_normal * dot(pixel_normal, slice_plane_normal);
		float pnl = max(length(proj_normal), 1e-6);
		float cos_n = clamp(dot(proj_normal / pnl, view_dir), -1.0, 1.0);
		float n_angle = -sign(dot(proj_normal, slice_dir_vs)) * acos(cos_n);

		float h_front = params.horizon_angle_threshold - GTAO_PI_HALF;
		float h_back = params.horizon_angle_threshold - GTAO_PI_HALF;

		for (int s = 0; s < num_steps; s++) {
			float t = (float(s) + noise_offset) / float(num_steps);
			float mip_level = (p_quality_level >= SSAO_DEPTH_MIPS_ENABLE_AT_QUALITY_PRESET) ? clamp(log2(t * screen_radius * 0.25), 0.0, float(SSAO_DEPTH_MIP_LEVELS - 1)) : 0.0;

			// Forward sample
			vec2 uv_f = normalized_screen_pos + step_uv * (t * float(num_steps));
			float z_f = textureLod(source_depth_mipmaps, vec3(uv_f, params.pass), mip_level).x;
			vec3 df = NDC_to_view_space(uv_f, z_f) - pix_center_pos;
			float dsq_f = dot(df, df);
			float comb_f = clamp(1.0 - dsq_f / falloff_radius_sq, 0.0, 1.0) * clamp(df.z * params.neg_inv_radius + 1.0, 0.0, 1.0);
			if (dsq_f > 1e-6) {
				vec3 dn_f = df * inversesqrt(dsq_f);
				float hf = acos(clamp(dot(dn_f, view_dir), -1.0, 1.0)) * sign(dot(dn_f, slice_dir_vs));
				h_front = max(h_front, mix(h_front, hf, comb_f));
			}

			// Backward sample
			vec2 uv_b = normalized_screen_pos - step_uv * (t * float(num_steps));
			float z_b = textureLod(source_depth_mipmaps, vec3(uv_b, params.pass), mip_level).x;
			vec3 db = NDC_to_view_space(uv_b, z_b) - pix_center_pos;
			float dsq_b = dot(db, db);
			float comb_b = clamp(1.0 - dsq_b / falloff_radius_sq, 0.0, 1.0) * clamp(db.z * params.neg_inv_radius + 1.0, 0.0, 1.0);
			if (dsq_b > 1e-6) {
				vec3 dn_b = db * inversesqrt(dsq_b);
				float hb = acos(clamp(dot(dn_b, view_dir), -1.0, 1.0)) * -sign(dot(dn_b, slice_dir_vs));
				h_back = max(h_back, mix(h_back, hb, comb_b));
			}
		}

		float h1c = max(-h_back, n_angle - GTAO_PI_HALF);
		float h2c = min(h_front, n_angle + GTAO_PI_HALF);
		ao_sum += clamp(gtao_integrate_arc(h1c, h2c, n_angle), 0.0, 1.0);
	}

	float visibility = ao_sum / float(num_directions);

	if (p_adaptive_base) {
		r_shadow_term = visibility;
		r_edges = vec4(0.0);
		r_weight = float(num_directions * num_steps * 2);
		return;
	}

	float fade_out = clamp(pix_center_pos.z * params.fade_out_mul + params.fade_out_add, 0.0, 1.0);
	if (!p_adaptive_base && (p_quality_level >= SSAO_DEPTH_BASED_EDGES_ENABLE_AT_QUALITY_PRESET)) {
		float ef = clamp((1.0 - edgesLRTB.x - edgesLRTB.y) * 0.35, 0.0, 1.0) + clamp((1.0 - edgesLRTB.z - edgesLRTB.w) * 0.35, 0.0, 1.0);
		fade_out *= clamp(1.0 - ef, 0.0, 1.0);
	}

	float obscurance = params.intensity * (1.0 - visibility);
	obscurance = min(obscurance, params.shadow_clamp);
	obscurance *= fade_out;

	float occlusion = 1.0 - obscurance;
	occlusion = pow(clamp(occlusion, 0.0, 1.0), params.shadow_power);

	r_shadow_term = occlusion;
	r_edges = edgesLRTB;
	r_weight = float(num_directions * num_steps * 2);
}

void main() {
	float out_shadow_term;
	float out_weight;
	vec4 out_edges;
	ivec2 ssC = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(ssC, params.screen_size))) { //too large, do nothing
		return;
	}

	vec2 uv = vec2(gl_GlobalInvocationID) + vec2(0.5);
#ifdef SSAO_BASE
	generate_SSAO_shadows_internal(out_shadow_term, out_edges, out_weight, uv, params.quality, true);

	imageStore(dest_image, ivec2(gl_GlobalInvocationID.xy), vec4(out_shadow_term, out_weight / (float(SSAO_ADAPTIVE_TAP_BASE_COUNT) * 4.0), 0.0, 0.0));
#else
	generate_SSAO_shadows_internal(out_shadow_term, out_edges, out_weight, uv, params.quality, false); // pass in quality levels
	if (params.quality == 0) {
		out_edges = vec4(1.0);
	}

	imageStore(dest_image, ivec2(gl_GlobalInvocationID.xy), vec4(out_shadow_term, pack_edges(out_edges), 0.0, 0.0));
#endif
}
