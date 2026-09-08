#[raygen]

#version 460

#extension GL_EXT_control_flow_attributes : enable

#VERSION_DEFINES

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
// clang-format on

#pragma shader_stage(raygen)
#extension GL_EXT_ray_tracing : enable
#ifdef USE_SER
#extension GL_EXT_shader_invocation_reorder : enable
#endif

#define GLSL 1
#define RT_STAGE_RAYGEN 1
#include "raytracing_common_inc.glsl"

layout(set = 0, binding = 0, rgba32f) uniform image2D image;
layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;

// Phase A accumulation buffers (bound by render_raytracing.cpp update_uniform_set).
// `accum` holds the running-average radiance; `accum_n` the per-pixel sample count.
// `rt_accum` is R32G32B32A32_SFLOAT and `rt_accum_n` is R32_SFLOAT on the C++ side
// (mirrors the existing `image` <-> RB_TEX_RAYTRACING R16F bind).
layout(set = 0, binding = 29, rgba32f) uniform image2D rt_accum;
layout(set = 0, binding = 30, r32f) uniform image2D rt_accum_n;
// Adaptive sampling (Task 6): Welford (running mean luminance, M2) per pixel.
// Bound at 33, not 31 -- binding 31 is IES_BUFFER_BINDING (ies_lookup_inc.glsl)
// and 32 is the motion-transforms SSBO (declared further down in this file); both
// already occupy the scene raytracing set. See render_raytracing.cpp update_uniform_set.
layout(set = 0, binding = 33, rg32f) uniform image2D rt_variance;

layout(location = 0) rayPayloadEXT PathPayload payload;

// Traces a single camera path and returns the accumulated radiance. Shared by
// the one-shot SPP loop and the Phase A accumulator. File-scope because GLSL
// forbids nested function definitions.
// `p_rng_sample_index` is the point in the per-pixel Sobol sequence this path
// draws from. The caller computes it, because only the caller knows which mode
// it is in and Sobol's stratification guarantee needs a contiguous 0,1,2,...
// prefix -- it cannot be reconstructed correctly inside this function from a
// frame counter and a sample index alone (see rng_init call sites in main()).
// When `p_is_sample_zero` is true, the primary-ray G-buffer / depth /
// velocity / DLSS-RR writes fire (matches the original SAMPLE_ZERO_FLAG).
vec3 trace_one_sample(uvec2 p_pixel, uint p_rng_sample_index, bool p_is_sample_zero,
		uint p_max_bounces, vec3 p_origin, vec3 p_dir) {
	PathState ps;
	ps.radiance = vec3(0.0);
	ps.throughput = vec3(1.0);
	ps.packed_bounces_flags = p_is_sample_zero ? set_sample_zero(0u) : 0u;
	ps.rng_packed = rng_pack(rng_init(p_pixel, p_rng_sample_index));
	// The camera ray has no preceding BSDF sample, so sky seen directly through a
	// window takes its full contribution.
	ps.mis_ray_pdf = RT_MIS_PDF_NONE;

	vec3 ray_origin = p_origin;
	vec3 ray_dir = p_dir;

	// A transparent pass-through (the alpha closure in shade_and_bounce) returns
	// BEFORE the per-lobe cap block, so it is the only surface interaction that
	// can push total_bounces past max_total without the path being terminated --
	// its own budget is the transmission counter instead. The loop therefore has
	// to hold BOTH budgets, or the iteration count silently becomes the real cap
	// and a surface behind a couple of alpha layers goes dark before NEE ever
	// runs on it.
	//
	// The cap is resolved the SAME way shade_and_bounce resolves it
	// (raytracing_closest_hit_common_inc.glsl) rather than read raw: with the
	// project setting unset RT_GET_MAX_TRANSMISSION_BOUNCE() is 0, which
	// resolve_bounce_cap turns into max_total while the raw read would widen
	// this loop by nothing at all -- reintroducing the exact starvation this
	// exists to prevent. min(.., 15u) mirrors the 4-bit counter clamp there.
	const uint iteration_limit = p_max_bounces +
			min(resolve_bounce_cap(float(RT_GET_MAX_TRANSMISSION_BOUNCE()), p_max_bounces), 15u);
	[[dont_unroll]] for (uint bounce = 0u; bounce <= iteration_limit; bounce++) {
		path_pack(payload, ps);

		// Roadmap E1: a ray travelling INSIDE a solid must see back faces to find
		// the far surface. Every other ray traces with byte-identical flags to
		// pre-E1, which is what keeps opaque scenes unchanged.
		uint ray_flags = is_inside_medium(ps.packed_bounces_flags)
				? (RT_RAY_FLAGS & ~gl_RayFlagsCullBackFacingTrianglesEXT)
				: RT_RAY_FLAGS;

#ifdef USE_SER
		hitObjectEXT hitObject;
		hitObjectTraceRayEXT(hitObject, tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, 0.001, ray_dir, 10000.0, 0);

		// Reorder with a coherence hint that has 8 bits
		uint hint = 0;
		if (hitObjectIsHitEXT(hitObject)) {
			// TODO: This hint barely does anything. There is a lot of untapped potential here.
			hint = hitObjectGetInstanceIdEXT(hitObject);
		}
		reorderThreadEXT(hitObject, hint, 8);

		hitObjectExecuteShaderEXT(hitObject, 0);
#else
		traceRayEXT(tlas, ray_flags, 0xFF, 0, 0, 0, ray_origin, 0.001, ray_dir, 10000.0, 0);
#endif

		ps = path_unpack(payload);
		if (is_path_terminated(ps.packed_bounces_flags)) {
			break;
		}
		// Reconstruct the next ray origin from the current ray + hit distance, apply bias
		vec3 hit_pos = ray_origin + ray_dir * ps.hit_t;
		ray_origin = offset_ray_origin(hit_pos, ps.offset_normal);
		ray_dir = ps.next_ray_dir;
	}

	return ps.radiance;
}

/// Build the primary camera ray for `p_pixel` offset by `p_jitter` (in pixels).
/// Passing vec2(0.5) reproduces the original pixel-centre ray exactly.
void camera_ray(uvec2 p_pixel, vec2 p_jitter, out vec3 r_origin, out vec3 r_dir) {
	const vec2 pixel_center = vec2(p_pixel) + p_jitter;
	const vec2 in_uv = pixel_center / vec2(gl_LaunchSizeEXT.xy);
	const vec2 d = in_uv * 2.0 - 1.0;

	mat4 inv_view = transpose(mat4(scene_data_block.data.inv_view_matrix[0],
			scene_data_block.data.inv_view_matrix[1],
			scene_data_block.data.inv_view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));

	vec4 target = scene_data_block.data.inv_projection_matrix * vec4(d.x, d.y, 1.0, 1.0);
	r_origin = (inv_view * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	r_dir = (inv_view * vec4(normalize(target.xyz), 0.0)).xyz;
}

void main() {
	uvec2 pixel = gl_LaunchIDEXT.xy;

	// Sample count from specialization constant, frame index from uniform
	const uint samples_per_pixel = RT_GET_SAMPLE_COUNT();
	uint frame_index = uint(get_rt_param(RT_PARAM_FRAME_INDEX));

	const uint max_bounces = RT_GET_MAX_BOUNCES();

	// Phase A accumulation: blend one 1-SPP sample per launch into a persistent
	// running average so a still image converges across driver frames.
	if (get_rt_param(RT_PARAM_ACCUM_FLAG) > 0.5) {
		uint accum_frame = uint(get_rt_param(RT_PARAM_ACCUM_FRAMES));

		float n = max(imageLoad(rt_accum_n, ivec2(pixel)).x, 0.0);
		vec3 prev = imageLoad(rt_accum, ivec2(pixel)).rgb;
		vec2 var_state = imageLoad(rt_variance, ivec2(pixel)).xy;

		// Adaptive sampling: once a pixel's relative standard error drops below
		// the threshold, stop spending samples on it. Needs a minimum sample
		// count first, otherwise early noise luck freezes a pixel prematurely.
		const float MIN_ADAPTIVE_SAMPLES = 16.0;
		float noise_threshold = get_rt_param(RT_PARAM_NOISE_THRESHOLD);
		if (noise_threshold > 0.0 && n >= MIN_ADAPTIVE_SAMPLES) {
			float mean_luma = var_state.x;
			float m2 = var_state.y;
			// Standard error of the mean, relative to the mean itself.
			float variance = m2 / max(n - 1.0, 1.0);
			float std_err = sqrt(variance / n);
			if (std_err < noise_threshold * max(mean_luma, 1e-4)) {
				// Converged: republish the running average and take no sample.
				imageStore(image, ivec2(pixel), vec4(prev, 1.0));
				return;
			}
		}

		// Jitter the primary ray per accumulated frame. Without this the
		// accumulator averages the same camera ray forever and never
		// anti-aliases, however many frames are driven.
		vec3 origin, direction;
		camera_ray(pixel, camera_filter_jitter(pixel, accum_frame), origin, direction);

		// accum_frame alone: contiguous, resets with the accumulator (unlike
		// frame_index, which is a session-lifetime dispatch counter and never
		// resets -- see render_raytracing.cpp frame_counter). This keeps the
		// Sobol sample index matching the pixel filter's index above and makes
		// a given accum_frame draw the same point every time it recurs, which
		// is what makes the render reproducible across accumulation cycles.
		vec3 sample_rad = trace_one_sample(pixel, accum_frame, true,
				max_bounces, origin, direction);

		float w = 1.0 / (n + 1.0);
		vec3 running = mix(prev, sample_rad, w);

		// Welford online variance on sample luminance.
		float luma = dot(sample_rad, vec3(0.2126, 0.7152, 0.0722));
		float delta = luma - var_state.x;
		float new_mean = var_state.x + delta * w;
		float new_m2 = var_state.y + delta * (luma - new_mean);

		imageStore(rt_accum, ivec2(pixel), vec4(running, 1.0));
		imageStore(rt_accum_n, ivec2(pixel), vec4(n + 1.0));
		imageStore(rt_variance, ivec2(pixel), vec4(new_mean, new_m2, 0.0, 0.0));
		imageStore(image, ivec2(pixel), vec4(running, 1.0));
	} else {
		// One-shot path: trace `samples_per_pixel` samples this launch and
		// average. Sample 0 stays centred so the primary-ray G-buffer / depth /
		// velocity writes keep their pixel-centre alignment; samples 1..N-1 are
		// jittered, which is a free anti-aliasing win for realtime SPP > 1.
		vec3 total_radiance = vec3(0.0);
		// Power-of-two stride so `frame_index * stride` always lands on an aligned
		// boundary of the Sobol sequence, keeping the per-frame window
		// [frame_index*stride, frame_index*stride+samples_per_pixel) a genuinely
		// stratified prefix. `frame_index * samples_per_pixel` does NOT have this
		// property unless samples_per_pixel is itself a power of two -- production
		// runs at 20 and 10 spp, so the unaligned form measured ~20% worse RMSE
		// than this aligned one at those sample counts. Do not hardcode a stride:
		// samples_per_pixel has no C++-side upper clamp (only a UI range hint) and
		// the packed sample-count field is 8 bits, so spp can legitimately exceed 32.
		uint one_shot_stride = rt_next_pow2_ge(samples_per_pixel);
		[[dont_unroll]] for (uint sample_idx = 0u; sample_idx < samples_per_pixel; sample_idx++) {
			bool sz = (sample_idx == 0u);
			vec3 origin, direction;
			camera_ray(pixel, camera_filter_jitter(pixel, sample_idx), origin, direction);
			// frame_index is the session-lifetime dispatch counter (never resets in
			// this mode either), so successive realtime frames do not replay the
			// same points. See rng_pack()'s saturation caveat in raytracing_inc.glsl
			// for what happens once frame_index * one_shot_stride grows past the
			// 20-bit packed sample_index field.
			total_radiance += trace_one_sample(pixel, frame_index * one_shot_stride + sample_idx, sz,
					max_bounces, origin, direction);
		}
		vec3 final_radiance = total_radiance / float(samples_per_pixel);
		imageStore(image, ivec2(pixel), vec4(final_radiance, 1.0));
	}
}

#[miss]

#version 460

#VERSION_DEFINES

#pragma shader_stage(miss)
#extension GL_EXT_ray_tracing : enable

#define GLSL 1
#define RT_STAGE_MISS 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
#include "brdf_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

layout(location = 0) rayPayloadInEXT PathPayload payload;

layout(set = 0, binding = 7) uniform texture2D radiance_octmap;
layout(set = 0, binding = 8) uniform sampler radiance_sampler;

void main() {
	PathState ps = path_unpack(payload);

#if !defined(USE_SER)
	// Shadow rays that miss mean the light is visible (no occluder).
	if (is_shadow_ray(ps.packed_bounces_flags)) {
		ps.radiance = vec3(1.0);
		path_pack(payload, ps);
		return;
	}
#endif

	// Miss always ends the path.
	ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);

#ifdef RT_DEBUG_ENABLED
	{
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
		// Specular hit distance: the first-bounce closest_hit pre-seeds the
		// "no hit" color into radiance, so a missed reflection just keeps it.
		if (VIS_MODE == 13 && get_total_bounces(ps.packed_bounces_flags) > 0u) {
			path_pack(payload, ps);
			return;
		}
	}
#endif // RT_DEBUG_ENABLED

	// Primary ray miss: write depth, velocity, and DLSS RR defaults (sample 0 only).
	{
		uint total_bounces = get_total_bounces(ps.packed_bounces_flags);
		if (total_bounces == 0u && is_sample_zero(ps.packed_bounces_flags)) {
			ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);

			imageStore(rt_depth_image, pixel, vec4(0.0));

			// Sky velocity: reproject a far-plane point using unjittered VPs.
			{
				vec3 far_world = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * 10000.0;
				vec2 curr_uv = project_uv(far_world, curr_vp_unjittered);
				vec2 prev_uv = project_uv(far_world, prev_vp_unjittered);
				imageStore(rt_velocity_image, pixel, vec4(prev_uv - curr_uv, 0.0, 0.0));
			}
		}
	}

	// Shared with env_sample()/env_pdf() (raytracing_env_sampling_inc.glsl) so the
	// sky lookup here and the environment-NEE pdf can never drift apart.
	mat3 world_to_sky = env_world_to_sky();
	vec3 sky_dir = world_to_sky * gl_WorldRayDirectionEXT;

	vec2 border = vec2(scene_data_block.data.radiance_border_size,
			1.0 - scene_data_block.data.radiance_border_size * 2.0);
	vec2 sky_uv = vec3_to_oct_with_border(sky_dir, border);

	vec3 sky_color = textureLod(sampler2D(radiance_octmap, radiance_sampler), sky_uv, 0.0).rgb;
	sky_color *= scene_data_block.data.IBL_exposure_normalization;

	if ((RT_FLAGS & RT_FLAG_FOG_ENABLED) != 0u) {
		vec3 fog_color = scene_data_block.data.fog_light_color;

		if (scene_data_block.data.fog_aerial_perspective > 0.0) {
			vec3 sky_fog = textureLod(sampler2D(radiance_octmap, radiance_sampler), sky_uv, 1.0).rgb;
			sky_fog *= scene_data_block.data.IBL_exposure_normalization;
			fog_color = mix(fog_color, sky_fog, scene_data_block.data.fog_aerial_perspective);
		}

		sky_color = mix(sky_color, fog_color, scene_data_block.data.fog_sky_affect);
	}

#ifdef DLSS_RR_ENABLED
	{
		uint total_bounces = get_total_bounces(ps.packed_bounces_flags);
		if (total_bounces == 0u && is_sample_zero(ps.packed_bounces_flags)) {
			ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);
			imageStore(dlss_rr_diffuse_albedo, pixel, vec4(sky_color, 1.0));
			imageStore(dlss_rr_specular_albedo, pixel, vec4(0.0));
			imageStore(dlss_rr_normal_roughness, pixel, vec4(-gl_WorldRayDirectionEXT, 0.0));
			imageStore(dlss_rr_specular_hit_dist, pixel, vec4(-1.0));
		}
	}
#endif

	// MIS: this ray reached the sky by BSDF sampling. Environment NEE
	// (shade_and_bounce, raytracing_closest_hit_common_inc.glsl) fires an
	// independent shadow ray at the sky from every shading point, so without a
	// weight the same light path would be counted twice. power_heuristic(a, b) and
	// power_heuristic(b, a) sum to exactly 1, so the two strategies partition this
	// contribution instead of duplicating it.
	//
	// A negative mis_ray_pdf is the RT_MIS_PDF_NONE sentinel, meaning environment
	// NEE contributes nothing here, so this strategy must take the full
	// contribution -- weighting it down would lose energy with no other strategy to
	// make it up. See the governing rule at shade_and_bounce's mis_ray_pdf
	// assignment for the full case list and the measurements behind it: a primary
	// camera ray, a backfacing-V shading point, a mirrored/recovered sample, a
	// near-delta specular bounce, and a direction combinedPdf() cannot describe.
	float mis_w = 1.0;
	if (ps.mis_ray_pdf >= 0.0) {
		float e_pdf = env_pdf(gl_WorldRayDirectionEXT);
		// The e_pdf > 0.0 guard covers a scene with no sky at all: marginal_total
		// == 0 makes env_pdf() return 0 for every direction, env NEE therefore
		// contributes w_env = 0 everywhere, and this strategy must take the whole
		// contribution. Without the guard power_heuristic(x, 0) is fine but
		// power_heuristic(0, 0) returns 0 for a zero denominator, so a
		// mis_ray_pdf that was itself 0 would silently delete the sky. Note this
		// guard does NOT rescue the mis_ray_pdf == 0 case in a scene that HAS a
		// sky: env_cdf_build.glsl floors every cell at 1e-4 * mean, so e_pdf is
		// strictly positive everywhere and the guard never fires. That case is
		// handled at the source, by mapping a zero pdf to the sentinel above.
		mis_w = (e_pdf > 0.0) ? power_heuristic(ps.mis_ray_pdf, e_pdf) : 1.0;
	}
	vec3 sky_contribution = ps.throughput * sky_color * mis_w;

#ifdef RT_DEBUG_ENABLED
	{
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
		if (VIS_MODE == 20) {
			ps.radiance = vec3(1.0);
		} else if (VIS_MODE == 0) {
			ps.radiance += sky_contribution;
		} else {
			ps.radiance = sky_color;
		}
	}
#else
	ps.radiance += sky_contribution;
#endif // RT_DEBUG_ENABLED

	path_pack(payload, ps);
}

#[closest_hit]

#version 460

#VERSION_DEFINES

#pragma shader_stage(closest_hit)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_ray_query : enable
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_EXT_nonuniform_qualifier : require
#ifdef USE_SER
#extension GL_EXT_shader_invocation_reorder : enable
#endif

#define GLSL 1
#define RT_STAGE_CLOSEST_HIT 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
#include "brdf_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

#define attribs hit_attribs.bary_or_uv
#define RT_HIT_ATTRIBS_DECLARED

#include "raytracing_hit_inc.glsl"

layout(set = 0, binding = 1) uniform accelerationStructureEXT tlas;
layout(location = 0) rayPayloadInEXT PathPayload payload;

layout(set = 1, binding = 0) uniform texture2D bindless_textures[];

#include "raytracing_samplers_inc.glsl"

// clang-format off
layout(set = 0, binding = 3, std430) readonly buffer GeometryBuffer {
	GeometryData geometries[];
};

layout(set = 0, binding = 4, std430) readonly buffer MotionIndexBuffer {
	int motion_indices[];
};

layout(set = 0, binding = 5, std430) readonly buffer MaterialBuffer {
	MaterialData materials[];
};
// clang-format on

#include "raytracing_lights_inc.glsl"

// clang-format off
layout(set = 0, binding = 32, std430) readonly buffer MotionTransforms {
	InstanceMotionData motion_transforms[];
};
// clang-format on

layout(set = 0, binding = 7) uniform texture2D radiance_octmap;
layout(set = 0, binding = 8) uniform sampler radiance_sampler;

// clang-format off
#include "raytracing_material_eval_inc.glsl"
#include "raytracing_closest_hit_common_inc.glsl"
// clang-format on

// ============================================================================
// CUSTOM SHADER GLOBALS (injected by ShaderCompiler for HG1+)
// ============================================================================
#ifdef RT_CUSTOM_HIT_GROUP
#include "raytracing_custom_globals_inc.glsl"
#endif

// ============================================================================
// MAIN
// ============================================================================
void main() {
	HitData h = compute_hit_data();
	write_primary_hit_depth(h.hit_pos);
	write_primary_hit_velocity(h.hit_pos);

#ifdef RT_CUSTOM_HIT_GROUP
	uint rt_geometry_idx = h.geometry_idx;
	vec3 rt_hit_pos = h.hit_pos;
	vec2 rt_uv = h.uv;
	vec4 rt_color = h.color;
	vec3 rt_normal = h.geometry_normal;
	vec3 rt_tangent = h.tangent;
	vec3 rt_bitangent = h.bitangent;
	bool rt_front_face = h.is_front_face;

#include "raytracing_custom_fragment_inc.glsl"

	// Build MaterialResult from fragment outputs.
	MaterialResult m;
	m.albedo = albedo;
	m.alpha = alpha;
	m.roughness = roughness;
	m.metalness = metallic;
	m.specular = specular;
	// A custom hit group's `emission` is whatever its user shader code wrote, so
	// there is no MaterialData to compose it from and the full emissive_radiance()
	// form does not apply. It still goes through the SHARED exposure factor rather
	// than restating it -- that factor is the part every composition site has in
	// common, and the part a second copy would drift on.
	//
	// This value CAN differ from what emissive_radiance() would return for the same
	// surface, because the user shader is free to emit anything. That is why
	// gather_emissive_instances() excludes custom-hit-group instances from the
	// emissive distribution outright (render_raytracing.cpp, beside the procedural
	// and deformed skips) -- NEE composes radiance from materials[], so an emitter
	// whose real radiance comes from user code would otherwise light the scene with
	// a value it does not emit, and after Task 5 would give the two MIS strategies
	// different integrands while sharing a weight required to sum to 1.
	m.emissive = emissive_apply_exposure(emission);
	m.normal = normalize(mat3(inv_view_matrix) * normal); // view space -> world space

	// Custom hit groups have no MaterialData to draw extension parameters from,
	// and a user shader has no way to author them. Opaque, which keeps this path
	// on the pre-E1 dispatch branch in shade_and_bounce.
	m.transmission = 0.0;
	m.ior = 1.5;
	m.thickness = 0.0;
	m.attenuation = vec3(0.0);
	m.specular_tint = vec3(1.0);
	m.specular_factor = 1.0;
	// A custom hit group authors its own alpha and its own blending; the
	// RT_MAT_FLAG_BLEND bit in materials[] describes the StandardMaterial3D this
	// ShaderMaterial replaced, not this shader. Opaque keeps every custom
	// ShaderMaterial on the pre-existing path, matching m.transmission above.
	m.blends = false;

	// Apply normal map if it was written.
	if (normal_map != vec3(0.5, 0.5, 1.0)) {
		vec3 ts_normal;
		ts_normal.xy = normal_map.xy * 2.0 - 1.0;
		ts_normal.z = sqrt(max(0.0, 1.0 - dot(ts_normal.xy, ts_normal.xy)));
		m.normal = apply_normal_map(h, ts_normal, normal_map_depth);
	}

#ifdef RT_DEBUG_ENABLED
	{
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
		if (VIS_MODE != 0) {
			vec3 V = -gl_WorldRayDirectionEXT;
			float NdotV = max(dot(m.normal, V), 0.0001);
			vec3 orm = vec3(1.0, m.roughness, m.metalness);
			debug_visualize(VIS_MODE, h.geometry_normal, m.normal, normal_map,
					h.tangent, h.bitangent, h.uv, m.albedo, orm, m.metalness, m.roughness, m.specular, m.emissive, V, NdotV,
					materials[h.geometry_idx]);
			return;
		}
	}
#endif // RT_DEBUG_ENABLED
	shade_and_bounce(h, m);
#else
	// HG0: StandardMaterial3D evaluation.
	MaterialData mat = materials[h.geometry_idx];
	vec2 uv = h.uv * mat.uv1_scale + mat.uv1_offset;

	// Normal mapping.
	vec3 tangent_space_normal = vec3(0.0, 0.0, 1.0);
	vec3 final_normal = h.geometry_normal;
	if ((mat.flags & 1u) != 0u) {
		vec3 normal_sample = sample_bindless_texture(mat.normal_texture_idx, uv).rgb;
		tangent_space_normal.xy = normal_sample.xy * 2.0 - 1.0;
		tangent_space_normal.z = sqrt(max(0.0, 1.0 - dot(tangent_space_normal.xy, tangent_space_normal.xy)));
		final_normal = apply_normal_map(h, tangent_space_normal, mat.normal_map_depth);
	}

	// Texture sampling.
	vec4 albedo_tex = sample_material_texture(mat.albedo_texture_idx, uv, mat.flags);
	vec3 albedo = albedo_tex.rgb * mat.albedo_color.rgb;
	vec3 orm = sample_material_texture(mat.orm_texture_idx, uv, mat.flags).rgb;
	float roughness = saturate(orm.g * mat.roughness);
	float metalness = saturate(orm.b * mat.metallic);

	// THE single composition of emitted radiance, shared verbatim with emissive
	// NEE (raytracing_emissive_inc.glsl). This site and the NEE site are the two
	// MIS strategies Task 5 will weight against each other, and a weight pair that
	// sums to 1 is only meaningful if both halves estimate the SAME integrand --
	// so they call one function rather than two expressions that look alike.
	//
	// The inlined form this replaced had an extra `emission_strength > 0.0` guard
	// on the NO-TEXTURE branch only. For every strength the engine can produce it
	// is redundant -- color * 0 * exposure is already vec3(0), and
	// emission_energy_multiplier's range starts at 0 (material.cpp:3605) -- so the
	// value does not move. It differed only for a NEGATIVE strength set past the
	// Inspector by script, and there the old code was already self-inconsistent:
	// the textured branch multiplied a negative through while this one clamped it.
	// Uniformly multiplying it out is the coherent behaviour, and such an emitter
	// is excluded from the NEE distribution anyway (gather_emissive_instances
	// qualifies on lum * strength > 1e-4).
	vec3 emissive = emissive_radiance(mat, uv);

	// Build MaterialResult.
	MaterialResult m;
	m.albedo = albedo;
	m.alpha = albedo_tex.a * mat.albedo_color.a;
	m.roughness = roughness;
	m.metalness = metalness;
	m.specular = mat.specular;
	m.emissive = emissive;
	m.normal = final_normal;

	// Roadmap E1. `mat` is the MaterialData Phase D widened to 176 bytes.
	// ior is left RAW here; shade_and_bounce resolves it against `specular`
	// alongside F0, because the two must be derived together or reflectance and
	// refraction can disagree (spec section 3.2).
	m.transmission = mat.transmission;
	m.ior = mat.ior;
	m.thickness = mat.thickness;
	// Cycles' Volume Absorption coefficient, svm/closure.h:1236-1241.
	m.attenuation = (vec3(1.0) - mat.attenuation_color) * mat.attenuation_density;
	m.specular_tint = mat.specular_tint;
	m.specular_factor = mat.specular_factor;
	// Transparent BSDF closure. Keyed on the material FLAG (glTF alphaMode BLEND
	// -> ShaderData::rt_uses_alpha_blending), never on `m.alpha < 1.0`: an
	// alpha-SCISSOR cutout is also in the TLAS and its base-colour alpha can sit
	// between the scissor threshold and 1.0, so an alpha-value test would make
	// every cutout translucent.
	m.blends = (mat.flags & RT_MAT_FLAG_BLEND) != 0u;

#ifdef RT_DEBUG_ENABLED
	{
		int VIS_MODE = int(get_rt_param(RT_PARAM_VIS_MODE));
		if (VIS_MODE != 0) {
			vec3 V = -gl_WorldRayDirectionEXT;
			float NdotV = max(dot(m.normal, V), 0.0001);
			debug_visualize(VIS_MODE, h.geometry_normal, final_normal, tangent_space_normal,
					h.tangent, h.bitangent, uv, albedo, orm, metalness, roughness, mat.specular, emissive, V, NdotV,
					mat);
			return;
		}
	}
#endif // RT_DEBUG_ENABLED
	shade_and_bounce(h, m);
#endif
}

#[any_hit]

#version 460

#VERSION_DEFINES

#pragma shader_stage(any_hit)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#define GLSL 1
#define RT_STAGE_ANY_HIT 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

#define attribs hit_attribs.bary_or_uv
#define RT_HIT_ATTRIBS_DECLARED

#include "raytracing_hit_inc.glsl"

layout(location = 0) rayPayloadInEXT PathPayload payload;

// clang-format off
layout(set = 0, binding = 3, std430) readonly buffer GeometryBuffer {
	GeometryData geometries[];
};

layout(set = 0, binding = 4, std430) readonly buffer MotionIndexBuffer {
	int motion_indices[];
};

layout(set = 0, binding = 5, std430) readonly buffer MaterialBuffer {
	MaterialData materials[];
};
// clang-format on

layout(set = 1, binding = 0) uniform texture2D bindless_textures[];

#include "raytracing_samplers_inc.glsl"

// clang-format off
layout(set = 0, binding = 32, std430) readonly buffer MotionTransforms {
	InstanceMotionData motion_transforms[];
};
// clang-format on

// ============================================================================
// CUSTOM SHADER GLOBALS (injected for per-HG any-hit)
// ============================================================================
#ifdef RT_CUSTOM_HIT_GROUP
#include "raytracing_custom_globals_inc.glsl"
#endif

void main() {
	uint geometry_idx = gl_InstanceCustomIndexEXT;
	GeometryData geom = geometries[geometry_idx];

	uint i0, i1, i2;
	get_triangle_indices(geom, i0, i1, i2);
	vec3 bary = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

#ifdef RT_CUSTOM_HIT_GROUP
	// Compute hit data inline (cannot include closest_hit_common_inc here).
	uint rt_geometry_idx = geometry_idx;
	vec2 rt_uv = fetch_uv(geom, i0, i1, i2, bary);
	TBNResult ah_tbn = fetch_tbn(geom, i0, i1, i2, bary);

	mat3 model_rotation = mat3(gl_ObjectToWorldEXT);
	mat3 normal_matrix = mat3(
			normalize(model_rotation[0]),
			normalize(model_rotation[1]),
			normalize(model_rotation[2]));

	vec3 rt_normal = normalize(normal_matrix * ah_tbn.normal);
	vec3 rt_tangent = normalize(normal_matrix * ah_tbn.tangent);
	vec3 rt_bitangent = cross(rt_normal, rt_tangent) * ah_tbn.bitangent_sign;

	bool rt_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
	if (!rt_front_face) {
		rt_normal = -rt_normal;
	}

	vec3 rt_hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;
	vec4 rt_color = fetch_color(geom, i0, i1, i2, bary);

#include "raytracing_custom_fragment_inc.glsl"

	if (alpha_scissor_threshold > 0.0 && alpha < alpha_scissor_threshold) {
		ignoreIntersectionEXT;
	}
#else
	// HG0: Standard material alpha test.
	vec2 uv = fetch_uv(geom, i0, i1, i2, bary);
	MaterialData mat = materials[geometry_idx];
	uv = uv * mat.uv1_scale + mat.uv1_offset;
	float alpha = texture(sampler2D(bindless_textures[nonuniformEXT(mat.albedo_texture_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv).a;
	alpha *= mat.albedo_color.a;

	// The 0.5 test is a CUTOUT threshold (alpha scissor), and it is the right
	// answer for a scissor material -- but it is the wrong one for a BLEND
	// material, which is now in the TLAS as well. A blend surface at alpha 0.3
	// must reach closest-hit and be passed through by the Transparent BSDF with
	// probability 0.7; discarding the intersection here instead makes it pass
	// through with probability 1.0, i.e. renders it perfectly invisible. That is
	// precisely the "the fish are missing" symptom this closure exists to fix,
	// and it would hit exactly the soft-edged foliage and fin textures whose
	// alpha spends most of its range below 0.5.
	//
	// Blend materials therefore commit every intersection and let the closure in
	// shade_and_bounce weigh them. Scissor materials are unaffected: RT_MAT_FLAG_BLEND
	// is set from rt_uses_alpha_blending(), whose `!uses_alpha_clip` term excludes
	// a pure cutout (scene_shader_forward_clustered.h).
	if (alpha < 0.5 && (mat.flags & RT_MAT_FLAG_BLEND) == 0u) {
		ignoreIntersectionEXT;
	}
#endif
}

#[intersection]

#version 460

#VERSION_DEFINES

#pragma shader_stage(intersection)
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#define GLSL 1
#define RT_STAGE_INTERSECTION 1

// clang-format off
#include "raytracing_inc.glsl"
#include "../scene_data_inc.glsl"
#include "raytracing_data_inc.glsl"
#include "raytracing_common_inc.glsl"
// clang-format on

// Write all attributes and report the intersection. Transparently delta-compresses
// PREV_POSITION into spare .w bytes of packed_normal/tangent + prev_pos_delta_yz.
#define report_intersection(t_hit, kind)                                                      \
	{                                                                                         \
		vec3 _obj_hit = gl_ObjectRayOriginEXT + gl_ObjectRayDirectionEXT * (t_hit);           \
		vec3 _delta = any(isnan(m_PREV_POSITION)) ? vec3(0.0) : (m_PREV_POSITION - _obj_hit); \
		uint _n4 = packSnorm4x8(vec4(m_HIT_NORMAL, 0.0));                                     \
		uint _t4 = packSnorm4x8(vec4(m_HIT_TANGENT, 0.0));                                    \
		uint _dx = packHalf2x16(vec2(_delta.x, 0.0));                                         \
		hit_attribs.bary_or_uv = m_HIT_UV;                                                    \
		hit_attribs.packed_normal = (_n4 & 0x00FFFFFFu) | ((_dx & 0xFFu) << 24u);             \
		hit_attribs.packed_tangent = (_t4 & 0x00FFFFFFu) | (((_dx >> 8u) & 0xFFu) << 24u);    \
		hit_attribs.prev_pos_delta_yz = packHalf2x16(vec2(_delta.y, _delta.z));               \
		reportIntersectionEXT(t_hit, kind);                                                   \
	}

#ifdef RT_CUSTOM_HIT_GROUP

// clang-format off
layout(set = 0, binding = 3, std430) readonly buffer GeometryBuffer {
	GeometryData geometries[];
};

layout(set = 0, binding = 5, std430) readonly buffer MaterialBuffer {
	MaterialData materials[];
};
// clang-format on

layout(set = 1, binding = 0) uniform texture2D bindless_textures[];

#include "raytracing_samplers_inc.glsl"

layout(buffer_reference, std140) readonly buffer CustomMaterialUniforms{
	/* RT_CUSTOM_UNIFORM_MEMBERS */
};

/* RT_CUSTOM_TEXTURE_DEFINES */

// File-scope built-ins accessible from user helper functions in globals.
float global_time = scene_data_block.data.time;
float global_prev_time = 0.0;
mat4 read_model_matrix = mat4(0.0);
mat4 m_INV_MODEL_MATRIX = mat4(0.0);
mat4 read_view_matrix = transpose(mat4(scene_data_block.data.view_matrix[0], scene_data_block.data.view_matrix[1], scene_data_block.data.view_matrix[2], vec4(0.0, 0.0, 0.0, 1.0)));
mat4 inv_view_matrix = transpose(mat4(scene_data_block.data.inv_view_matrix[0], scene_data_block.data.inv_view_matrix[1], scene_data_block.data.inv_view_matrix[2], vec4(0.0, 0.0, 0.0, 1.0)));
mat4 projection_matrix = scene_data_block.data.projection_matrix;
mat4 inv_projection_matrix = scene_data_block.data.inv_projection_matrix;
vec2 read_viewport_size = scene_data_block.data.viewport_size;
float m_Z_NEAR = scene_data_block.data.z_near;
float m_Z_FAR = scene_data_block.data.z_far;

uint64_t _rt_material_address;
#define material CustomMaterialUniforms(_rt_material_address)

/* RT_CUSTOM_INTERSECTION_GLOBALS */

#endif

void main() {
#ifdef RT_CUSTOM_HIT_GROUP
	// Writable outputs.
	vec2 m_HIT_UV = vec2(0.0);
	vec3 m_HIT_NORMAL = vec3(0.0, 1.0, 0.0);
	vec3 m_HIT_TANGENT = vec3(1.0, 0.0, 0.0);
	vec3 m_PREV_POSITION = vec3(uintBitsToFloat(0x7FC00000u)); // NaN sentinel = not set.

	// Per-invocation built-ins (require RT intrinsics, only available in main).
	vec3 m_ORIGIN = gl_ObjectRayOriginEXT;
	vec3 m_DIRECTION = gl_ObjectRayDirectionEXT;
	vec3 m_WORLD_ORIGIN = gl_WorldRayOriginEXT;
	vec3 m_WORLD_DIRECTION = gl_WorldRayDirectionEXT;
	float m_T_MIN = gl_RayTminEXT;
	float m_T_MAX = gl_RayTmaxEXT;
	global_prev_time = scene_data_block.prev_data.time;

	// Resolve custom material uniforms via BDA (assigns file-scope address).
	uint rt_geometry_idx = gl_InstanceCustomIndexEXT;
	MaterialData rt_mat = materials[rt_geometry_idx];
	_rt_material_address = rt_mat.uniform_address;

	// Per-primitive AABB bounds (available when expose_aabb_bounds is enabled).
	GeometryData rt_geom = geometries[rt_geometry_idx];
	vec3 m_AABB_MIN = vec3(0.0);
	vec3 m_AABB_MAX = vec3(0.0);
	if (rt_geom.vertex_address != 0ul) {
		FloatBuffer aabb_buf = FloatBuffer(rt_geom.vertex_address);
		int base = int(gl_PrimitiveID) * 6;
		m_AABB_MIN = vec3(aabb_buf.v[base + 0], aabb_buf.v[base + 1], aabb_buf.v[base + 2]);
		m_AABB_MAX = vec3(aabb_buf.v[base + 3], aabb_buf.v[base + 4], aabb_buf.v[base + 5]);
	}

	mat4 rt_aabb_xform;
	mat4 rt_inv_aabb_xform;
	get_aabb_compression_xforms(rt_geom, rt_aabb_xform, rt_inv_aabb_xform);
	read_model_matrix = mat4(gl_ObjectToWorldEXT) * rt_inv_aabb_xform;
	m_INV_MODEL_MATRIX = rt_aabb_xform * mat4(gl_WorldToObjectEXT);

	/* RT_CUSTOM_INTERSECTION_CODE */

#else
	// Base-variant fallback: never executed at runtime (the intersection
	// stage is always rebuilt per-HG with RT_CUSTOM_HIT_GROUP defined).
	// Only touch unconditional HitAttribs fields so the base variant parses.
	hit_attribs.bary_or_uv = vec2(0.0);
	reportIntersectionEXT(gl_RayTminEXT, 0u);
#endif
}
