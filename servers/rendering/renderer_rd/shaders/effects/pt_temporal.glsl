#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Temporal reuse for the path tracer's accumulate route (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md). Blends the frame's
// accumulated radiance with the previous frame's blend, reprojected through depth and both
// frames' view-projections, rejected on depth / normal / miss, clamped to the current 3x3
// neighbourhood. Every formula here is mirrored and pinned by
// tests/servers/rendering/test_pt_temporal.cpp.

layout(set = 0, binding = 0) uniform sampler2D history_color; // previous blend, linear sampler
layout(set = 0, binding = 1) uniform sampler2D history_depth; // previous rt_depth (texelFetch)
layout(set = 0, binding = 2) uniform sampler2D history_normal; // previous normal guide, .a = sample count
layout(rgba32f, set = 0, binding = 3) uniform restrict readonly image2D current_color; // rt_accum
layout(r32f, set = 0, binding = 4) uniform restrict readonly image2D current_depth; // rt_depth
layout(rgba16f, set = 0, binding = 5) uniform restrict readonly image2D current_normal; // rt_accum_normal
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2D blend_color;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D blend_depth;
layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D blend_normal;

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
	float pad0;
	float pad1;
}
params;

// rt_depth is reverse-Z: 0 is the far plane and marks a primary miss. A miss reprojects as a
// point a hair inside the far plane, i.e. by direction, like the raygen's sky velocity.
const float MISS_DEPTH = 1e-7;

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

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.size))) {
		return;
	}

	vec3 cur = imageLoad(current_color, pos).rgb;
	float cur_depth = imageLoad(current_depth, pos).r;
	vec3 cur_normal = imageLoad(current_normal, pos).rgb;
	bool cur_miss = cur_depth <= 0.0;

	float h = 0.0;
	vec3 hist = vec3(0.0);
	uint reason = 0u; // 0 accepted, 1 off-screen or no history, 2 depth or miss mismatch, 3 normal
	if (params.history_valid == 0u) {
		reason = 1u;
	} else {
		vec2 uv = (vec2(pos) + 0.5) / vec2(params.size);
		vec3 p = world_from_depth(params.curr_inv_vp, uv, cur_miss ? MISS_DEPTH : cur_depth);
		vec4 pc = params.prev_vp * vec4(p, 1.0);
		vec2 prev_uv = pc.xy / pc.w * 0.5 + 0.5;
		if (pc.w <= 0.0 || any(lessThan(prev_uv, vec2(0.0))) || any(greaterThanEqual(prev_uv, vec2(1.0)))) {
			reason = 1u;
		} else {
			ivec2 ppos = clamp(ivec2(prev_uv * vec2(params.size)), ivec2(0), params.size - 1);
			float hist_depth = texelFetch(history_depth, ppos, 0).r;
			vec4 hist_n = texelFetch(history_normal, ppos, 0);
			if (cur_miss != (hist_depth <= 0.0)) {
				reason = 2u;
			} else if (!cur_miss) {
				vec3 q = world_from_depth(params.prev_inv_vp, (vec2(ppos) + 0.5) / vec2(params.size), hist_depth);
				if (distance(p, q) > params.depth_tolerance * distance(p, params.curr_cam_pos.xyz)) {
					reason = 2u;
				}
			}
			if (reason == 0u && length(cur_normal) > 1e-3 && length(hist_n.rgb) > 1e-3 &&
					dot(normalize(cur_normal), normalize(hist_n.rgb)) < params.normal_min_dot) {
				reason = 3u;
			}
			if (reason == 0u) {
				h = min(hist_n.a, params.history_cap);
				hist = history_catmull_rom(prev_uv);
			}
		}
	}

	if (h > 0.0) {
		// Variance clip against the current frame's 3x3 neighbourhood (stops trails from
		// reflections and glass, whose surface does not move but whose image does).
		vec3 m1 = vec3(0.0);
		vec3 m2 = vec3(0.0);
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				ivec2 nb = clamp(pos + ivec2(dx, dy), ivec2(0), params.size - 1);
				vec3 c = rgb_to_ycocg(compress(imageLoad(current_color, nb).rgb));
				m1 += c;
				m2 += c * c;
			}
		}
		vec3 mean = m1 / 9.0;
		vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
		vec3 hc = clamp(rgb_to_ycocg(compress(hist)), mean - params.clamp_gamma * sigma, mean + params.clamp_gamma * sigma);
		hist = expand(ycocg_to_rgb(hc));
	}

	float n = params.current_samples;
	vec3 blended = (n * cur + h * hist) / (n + h);
	float count = min(n + h, params.history_cap);

	if (params.debug_mask != 0u) {
		// Green accepted, yellow off-screen/no history, red depth or miss mismatch, blue normal.
		// Divided by the exposure so the tonemapped mask reads at half brightness.
		vec3 mask = reason == 0u ? vec3(0.0, 1.0, 0.0) : (reason == 1u ? vec3(1.0, 1.0, 0.0) : (reason == 2u ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0)));
		blended = mask * 0.5 / max(params.exposure, 1e-4);
	}

	imageStore(blend_color, pos, vec4(blended, 1.0));
	imageStore(blend_depth, pos, vec4(cur_depth));
	imageStore(blend_normal, pos, vec4(cur_normal, count));
}
