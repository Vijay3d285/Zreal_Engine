#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Temporal stabilisation of the path tracer's DENOISED frames (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md, amendment 2026-10-11). Runs
// after OIDN: blends the denoised frame with the previous stabilised frame, reprojected through
// depth and both frames' view-projections. The geometric tests reject against the current 3x3
// neighbourhood (the depth and guides come from jittered samples, so an edge pixel alone flips
// surfaces from frame to frame); then the history is clipped to the current neighbourhood, which
// after OIDN is clean -- before OIDN the same clip biased dark on skewed Monte Carlo noise.
// Every formula here is mirrored and pinned by tests/servers/rendering/test_pt_temporal.cpp.

layout(set = 0, binding = 0) uniform sampler2D history_color; // previous stabilised frame, linear sampler
layout(set = 0, binding = 1) uniform sampler2D history_depth; // previous rt_depth (texelFetch)
layout(set = 0, binding = 2) uniform sampler2D history_normal; // previous normal guide, .a = sample count
layout(rgba16f, set = 0, binding = 3) uniform restrict readonly image2D current_color; // denoised RT colour
layout(r32f, set = 0, binding = 4) uniform restrict readonly image2D current_depth; // rt_depth
layout(rgba16f, set = 0, binding = 5) uniform restrict readonly image2D current_normal; // rt_accum_normal
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D blend_color;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D blend_depth;
layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D blend_normal;
layout(set = 0, binding = 10) uniform sampler2D history_albedo; // previous albedo guide (texelFetch)
layout(rgba16f, set = 0, binding = 11) uniform restrict readonly image2D current_albedo; // rt_accum_albedo
layout(rgba16f, set = 0, binding = 12) uniform restrict writeonly image2D blend_albedo;
// Debug mask, its own target so the history always holds the real blend.
layout(rgba16f, set = 0, binding = 13) uniform restrict writeonly image2D debug_out;

layout(set = 0, binding = 9, std140) uniform Params {
	mat4 curr_inv_vp;
	mat4 prev_vp;
	mat4 prev_inv_vp;
	vec4 curr_cam_pos;
	ivec2 size;
	float exposure;
	float clamp_gamma;
	float current_samples;
	float history_cap;
	uint history_valid;
	uint debug_mask;
	float depth_tolerance;
	float normal_min_dot;
	float albedo_tolerance;
	float pad1;
}
params;

// rt_depth is reverse-Z: 0 is the far plane and marks a primary miss. A miss reprojects as a
// point a hair inside the far plane, i.e. by direction, like the raygen's sky velocity.
const float MISS_DEPTH = 1e-7;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 compress(vec3 c) {
	vec3 e = max(c, vec3(0.0)) * params.exposure;
	return e / (1.0 + e);
}

vec3 expand(vec3 c) {
	vec3 k = min(c, vec3(0.9999));
	return k / (1.0 - k) / params.exposure;
}

vec3 rgb_to_ycocg(vec3 c) {
	return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 ycocg_to_rgb(vec3 c) {
	float t = c.x - c.z;
	return vec3(t + c.y, c.x + c.z, t - c.y);
}

vec3 world_from_depth(mat4 inv_vp, vec2 uv, float depth) {
	vec4 w = inv_vp * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return w.xyz / w.w;
}

// 5-tap Catmull-Rom through the bilinear sampler (the 4x4 kernel with its corners dropped).
vec3 history_catmull_rom(vec2 uv) {
	vec2 tex_size = vec2(params.size);
	vec2 sample_pos = uv * tex_size;
	vec2 tex_pos1 = floor(sample_pos - 0.5) + 0.5;
	vec2 f = sample_pos - tex_pos1;
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec2 w12 = w1 + w2;
	vec2 tex_pos0 = (tex_pos1 - 1.0) / tex_size;
	vec2 tex_pos3 = (tex_pos1 + 2.0) / tex_size;
	vec2 tex_pos12 = (tex_pos1 + w2 / w12) / tex_size;
	vec3 acc = textureLod(history_color, vec2(tex_pos12.x, tex_pos0.y), 0.0).rgb * (w12.x * w0.y);
	acc += textureLod(history_color, vec2(tex_pos0.x, tex_pos12.y), 0.0).rgb * (w0.x * w12.y);
	acc += textureLod(history_color, tex_pos12, 0.0).rgb * (w12.x * w12.y);
	acc += textureLod(history_color, vec2(tex_pos3.x, tex_pos12.y), 0.0).rgb * (w3.x * w12.y);
	acc += textureLod(history_color, vec2(tex_pos12.x, tex_pos3.y), 0.0).rgb * (w12.x * w3.y);
	float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	return max(acc / wsum, vec3(0.0));
}

// test_pt_temporal.cpp normal_ok(): a zero (missing) normal on either side does not reject.
bool normal_matches(vec3 a, vec3 b) {
	if (length(a) <= 1e-3 || length(b) <= 1e-3) {
		return true;
	}
	return dot(normalize(a), normalize(b)) >= params.normal_min_dot;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.size))) {
		return;
	}

	vec3 cur = imageLoad(current_color, pos).rgb;
	float cur_depth = imageLoad(current_depth, pos).r;
	vec3 cur_normal = imageLoad(current_normal, pos).rgb;
	vec3 cur_albedo = imageLoad(current_albedo, pos).rgb;
	vec3 cam = params.curr_cam_pos.xyz;

	float h = 0.0;
	vec3 hist = vec3(0.0);
	// 0 accepted, 1 off-screen or no history, 2 depth, 3 normal, 4 albedo guide, 5 accepted but clipped
	uint reason = 1u;
	if (params.history_valid != 0u) {
		vec2 uv = (vec2(pos) + 0.5) / vec2(params.size);
		vec3 p = world_from_depth(params.curr_inv_vp, uv, cur_depth <= 0.0 ? MISS_DEPTH : cur_depth);
		vec4 pc = params.prev_vp * vec4(p, 1.0);
		vec2 prev_uv = pc.xy / pc.w * 0.5 + 0.5;
		if (pc.w > 0.0 && all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThan(prev_uv, vec2(1.0)))) {
			// The current 3x3 neighbourhood: hit-distance range, misses, albedo range, normals,
			// and the clip box (mean and spread in compressed YCoCg).
			float d_min = 1e30;
			float d_max = 0.0;
			bool has_hit = false;
			bool any_miss = false;
			vec3 a_min = vec3(1e30);
			vec3 a_max = vec3(-1e30);
			vec3 nbr_normal[9];
			vec3 c_m1 = vec3(0.0);
			vec3 c_m2 = vec3(0.0);
			int k = 0;
			for (int dy = -1; dy <= 1; dy++) {
				for (int dx = -1; dx <= 1; dx++) {
					ivec2 nb = clamp(pos + ivec2(dx, dy), ivec2(0), params.size - 1);
					float nd = imageLoad(current_depth, nb).r;
					if (nd <= 0.0) {
						any_miss = true;
					} else {
						float dist = distance(world_from_depth(params.curr_inv_vp, (vec2(nb) + 0.5) / vec2(params.size), nd), cam);
						d_min = min(d_min, dist);
						d_max = max(d_max, dist);
						has_hit = true;
					}
					vec3 na = imageLoad(current_albedo, nb).rgb;
					a_min = min(a_min, na);
					a_max = max(a_max, na);
					nbr_normal[k] = imageLoad(current_normal, nb).rgb;
					k++;
					vec3 cc = rgb_to_ycocg(compress(imageLoad(current_color, nb).rgb));
					c_m1 += cc;
					c_m2 += cc * cc;
				}
			}

			ivec2 ppos = clamp(ivec2(prev_uv * vec2(params.size)), ivec2(0), params.size - 1);
			float hist_depth = texelFetch(history_depth, ppos, 0).r;
			vec4 hist_n = texelFetch(history_normal, ppos, 0);
			vec3 hist_a = texelFetch(history_albedo, ppos, 0).rgb;

			// test_pt_temporal.cpp depth_range_ok()
			bool depth_ok;
			if (hist_depth <= 0.0) {
				depth_ok = any_miss;
			} else {
				float hist_dist = distance(world_from_depth(params.prev_inv_vp, (vec2(ppos) + 0.5) / vec2(params.size), hist_depth), cam);
				depth_ok = has_hit && hist_dist >= d_min * (1.0 - params.depth_tolerance) && hist_dist <= d_max * (1.0 + params.depth_tolerance);
			}
			// test_pt_temporal.cpp normal_best_ok()
			bool normal_ok = length(hist_n.rgb) <= 1e-3;
			for (int i = 0; i < 9 && !normal_ok; i++) {
				normal_ok = normal_matches(nbr_normal[i], hist_n.rgb);
			}
			// test_pt_temporal.cpp albedo_range_ok()
			bool albedo_ok = all(greaterThanEqual(hist_a, a_min - params.albedo_tolerance)) && all(lessThanEqual(hist_a, a_max + params.albedo_tolerance));

			if (!depth_ok) {
				reason = 2u;
			} else if (!normal_ok) {
				reason = 3u;
			} else if (!albedo_ok) {
				reason = 4u;
			} else {
				// test_pt_temporal.cpp clip_to_box(), per channel in compressed YCoCg
				vec3 mean = c_m1 / 9.0;
				vec3 sigma = sqrt(max(c_m2 / 9.0 - mean * mean, vec3(0.0)));
				vec3 hc = rgb_to_ycocg(compress(history_catmull_rom(prev_uv)));
				vec3 clipped = clamp(hc, mean - params.clamp_gamma * sigma, mean + params.clamp_gamma * sigma);
				reason = any(notEqual(clipped, hc)) ? 5u : 0u;
				hist = expand(ycocg_to_rgb(clipped));
				h = min(hist_n.a, params.history_cap);
			}
		}
	}

	float n = params.current_samples;
	vec3 blended = (n * cur + h * hist) / (n + h);
	float count = min(n + h, params.history_cap);

	if (params.debug_mask != 0u) {
		// Green accepted, yellow off-screen/no history, red depth, blue normal, magenta albedo
		// guide, cyan accepted but clipped. Divided by the exposure so the tonemapped mask reads
		// at half brightness.
		vec3 mask = reason == 0u ? vec3(0.0, 1.0, 0.0) : (reason == 1u ? vec3(1.0, 1.0, 0.0) : (reason == 2u ? vec3(1.0, 0.0, 0.0) : (reason == 3u ? vec3(0.0, 0.0, 1.0) : (reason == 4u ? vec3(1.0, 0.0, 1.0) : vec3(0.0, 1.0, 1.0)))));
		imageStore(debug_out, pos, vec4(mask * 0.5 / max(params.exposure, 1e-4), 1.0));
	}

	imageStore(blend_color, pos, vec4(blended, 1.0));
	imageStore(blend_depth, pos, vec4(cur_depth));
	imageStore(blend_normal, pos, vec4(cur_normal, count));
	imageStore(blend_albedo, pos, vec4(cur_albedo, 1.0));
}
