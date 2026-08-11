// Shared defines and common bindings for all RT shader stages.
// Include AFTER raytracing_inc.glsl and scene_data_inc.glsl.
// The includer must set exactly one of RT_STAGE_{RAYGEN,MISS,CLOSEST_HIT,ANY_HIT,INTERSECTION}.

// Specialization constant. Bits 0-3: feature flags, 4-8: Russian Roulette
// min_bounce (roadmap B4), 9-19: free, 20-27: sample count, 28-31: max bounces.
// Bounces widened from 3 to 4 bits (Task 4, B3) to lift the ceiling from 8 to
// 16; sample count's shift moved down by one to make room without touching
// its own 8-bit width (the feature-flags region only ever used bits 0-3).
layout(constant_id = 0) const uint RT_FLAGS = 0u;

#define RT_FLAG_DLSS_RR_ENABLED (1u << 1)
#define RT_FLAG_FOG_ENABLED (1u << 2)

#define RT_SAMPLE_COUNT_SHIFT 20u
#define RT_SAMPLE_COUNT_MASK 0xFFu
#define RT_GET_SAMPLE_COUNT() max(1u, (RT_FLAGS >> RT_SAMPLE_COUNT_SHIFT) & RT_SAMPLE_COUNT_MASK)

#define RT_MAX_BOUNCES_SHIFT 28u
#define RT_MAX_BOUNCES_MASK 0xFu
#define RT_GET_MAX_BOUNCES() (((RT_FLAGS >> RT_MAX_BOUNCES_SHIFT) & RT_MAX_BOUNCES_MASK) + 1u)

// Russian Roulette minimum bounce (roadmap B4). MUST match RT_MIN_BOUNCE_SHIFT /
// RT_MIN_BOUNCE_MASK in scene_shader_raytracing.h -- these are hand-maintained
// twins and a drift makes the shader read the wrong field with no failing test.
// Stored biased by +1: stored 0 means "unset" and resolves to the default 3,
// because 0 is a legitimate min_bounce (roulette from the first bounce).
#define RT_MIN_BOUNCE_SHIFT 4u
#define RT_MIN_BOUNCE_MASK 0x1Fu
#define RT_GET_MIN_BOUNCE() (((RT_FLAGS >> RT_MIN_BOUNCE_SHIFT) & RT_MIN_BOUNCE_MASK) == 0u ? 3u : ((((RT_FLAGS >> RT_MIN_BOUNCE_SHIFT) & RT_MIN_BOUNCE_MASK)) - 1u))

// Cull back faces by default; double-sided instances override via CULL_DISABLE flag.
#define RT_RAY_FLAGS gl_RayFlagsCullBackFacingTrianglesEXT

layout(set = 0, binding = 2, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
}
scene_data_block;

layout(set = 0, binding = 14, std430) readonly buffer GlobalShaderUniformData {
	vec4 data[256];
}
global_shader_uniforms;

#ifndef RT_STAGE_ANY_HIT

layout(set = 0, binding = 6, std140) uniform RaytracingParams {
	vec4 rt_params[4];
	mat4 prev_vp_unjittered;
	mat4 curr_vp_unjittered;
};

float get_rt_param(uint idx) {
	return rt_params[idx >> 2u][idx & 3u];
}

/// Project a world-space point to UV through an unjittered VP.
vec2 project_uv(vec3 world_pos, mat4 vp) {
	vec4 clip = vp * vec4(world_pos, 1.0);
	return clip.xy / clip.w * 0.5 + 0.5;
}

#ifdef DLSS_RR_ENABLED
layout(set = 0, binding = 9, rgba16f) uniform image2D dlss_rr_diffuse_albedo;
layout(set = 0, binding = 10, rgba16f) uniform image2D dlss_rr_specular_albedo;
layout(set = 0, binding = 11, rgba16f) uniform image2D dlss_rr_normal_roughness;
layout(set = 0, binding = 12, r16f) uniform image2D dlss_rr_specular_hit_dist;
#endif

// Binding 14 is reserved for GlobalShaderUniformData (declared above).
// Samplers occupy 16-27 (see raytracing_samplers_inc.glsl); velocity sits at
// the first free slot past them so we do not collide with either.
layout(set = 0, binding = 28, rg16f) uniform image2D rt_velocity_image;
layout(set = 0, binding = 15, r32f) uniform image2D rt_depth_image;

#endif // !RT_STAGE_ANY_HIT

// Shared hitAttributeEXT layout for all hit-group stages.
// Vulkan requires every shader in a hit group to agree on this layout.
#if defined(RT_STAGE_CLOSEST_HIT) || defined(RT_STAGE_ANY_HIT) || defined(RT_STAGE_INTERSECTION)
struct HitAttribs {
	vec2 bary_or_uv;
#ifdef ENABLE_INTERSECTION_SHADERS
	uint packed_normal; // xyz: snorm8 normal,  w: delta.x FP16 low byte.
	uint packed_tangent; // xyz: snorm8 tangent, w: delta.x FP16 high byte.
	uint prev_pos_delta_yz; // packHalf2x16(delta.y, delta.z).
#endif
};
hitAttributeEXT HitAttribs hit_attribs;
#endif

// Environment (sky) importance sampling (Task 3). Included here, unconditionally
// and outside every stage-specific #if above, so every stage that includes this
// file -- present and any added later -- gets env_sample()/env_pdf() automatically.
// scene_data_block (declared above at binding 2) is in scope by construction: this
// line is textually after it. See raytracing_env_sampling_inc.glsl's header for why
// it cannot live in raytracing_inc.glsl instead (that file precedes scene_data_block's
// declaration in every stage).
#include "raytracing_env_sampling_inc.glsl"
