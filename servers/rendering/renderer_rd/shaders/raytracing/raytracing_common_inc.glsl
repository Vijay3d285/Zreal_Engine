// Shared defines and common bindings for all RT shader stages.
// Include AFTER raytracing_inc.glsl and scene_data_inc.glsl.
// The includer must set exactly one of RT_STAGE_{RAYGEN,MISS,CLOSEST_HIT,ANY_HIT,INTERSECTION}.

// Specialization constant. Bits 0-3: feature flags, 4-8: Russian Roulette
// min_bounce (roadmap B4), 9: emissive-mesh NEE (C1), 10-14: transmission
// enable + bounce cap (roadmap E1), 15-17: per-material feature gating
// (roadmap E3: anisotropy, coat, sheen -- see the defines at the bottom of this
// header), 18-19: free, 20-27: sample count, 28-31: max bounces.
//
// GLSL has no static_assert, so this map is the ONLY bit-allocation record on
// the shader side; its C++ twin is the RaytracingFlags comment in
// scene_shader_raytracing.h. Claim a bit here AND there, in the same commit.
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

// Emissive-mesh next-event estimation (roadmap C1). Bit 9 -- the first free bit
// ABOVE the min_bounce field, which owns 4-8. MUST match
// RT_FLAG_EMISSIVE_LIGHTS_ENABLED in scene_shader_raytracing.h; the C++ side
// carries a static_assert proving no feature flag has encroached on min_bounce.
#define RT_FLAG_EMISSIVE_LIGHTS_ENABLED 512u // 1 << 9
#define RT_GET_EMISSIVE_ENABLED() ((RT_FLAGS & RT_FLAG_EMISSIVE_LIGHTS_ENABLED) != 0u)

// Transmission / rough glass (roadmap E1). Bit 10 -- the first free bit above
// C1's emissive flag at 9. MUST match RT_FLAG_TRANSMISSION_ENABLED in
// scene_shader_raytracing.h; the C++ side carries a static_assert proving the
// whole 10-14 region misses min_bounce, the sample count and max bounces.
#define RT_FLAG_TRANSMISSION_ENABLED 1024u // 1 << 10
#define RT_GET_TRANSMISSION_ENABLED() ((RT_FLAGS & RT_FLAG_TRANSMISSION_ENABLED) != 0u)

// Per-lobe transmission bounce cap, bits 11-14. Stored UNBIASED with 0 meaning
// "unset", matching resolve_bounce_cap's convention for the diffuse and glossy
// caps -- unlike min_bounce, 0 is not a legitimate value here (a cap of 0 would
// mean "no transmission at all", which is what the enable flag is for).
//
// 4 bits, so the range is 1-15 rather than the 1-16 the other caps use. The
// counter in packed_bounces_flags is also 4 bits and saturates at 15, so a cap
// of 16 could never fire. Clamped to (1, 15) to match -- NOT by Environment
// (it has no such property); the clamp is CLAMP(raw, 1, 15) in
// SceneShaderRaytracing::compute_rt_flags() (scene_shader_raytracing.cpp),
// reading the `rendering/pathtracer/max_transmission_bounce` project setting
// (GLOBAL_DEF in rendering_server.cpp). Cycles' own max_transmission_bounce
// default is 12.
#define RT_MAX_TRANSMISSION_BOUNCE_SHIFT 11u
#define RT_MAX_TRANSMISSION_BOUNCE_MASK 0xFu
#define RT_GET_MAX_TRANSMISSION_BOUNCE() ((RT_FLAGS >> RT_MAX_TRANSMISSION_BOUNCE_SHIFT) & RT_MAX_TRANSMISSION_BOUNCE_MASK)

// E3. Bits 15-17. MUST match RT_FLAG_ANISOTROPY_ENABLED / RT_FLAG_COAT_ENABLED /
// RT_FLAG_SHEEN_ENABLED in scene_shader_raytracing.h. These bits ALSO drive
// #define injection via RAYGEN_SHADER_OPTIONS, and that is what the gating
// actually uses: the accessors below are diagnostics only. A specialization
// constant can fold a branch but cannot remove a struct field or size an array,
// which is what this phase needs -- see the spec's section 3.1.
#define RT_FLAG_ANISOTROPY_ENABLED 32768u // 1 << 15
#define RT_FLAG_COAT_ENABLED 65536u // 1 << 16
#define RT_FLAG_SHEEN_ENABLED 131072u // 1 << 17
#define RT_GET_ANISOTROPY_ENABLED() ((RT_FLAGS & RT_FLAG_ANISOTROPY_ENABLED) != 0u)
#define RT_GET_COAT_ENABLED() ((RT_FLAGS & RT_FLAG_COAT_ENABLED) != 0u)
#define RT_GET_SHEEN_ENABLED() ((RT_FLAGS & RT_FLAG_SHEEN_ENABLED) != 0u)

// Transparent shadows (transmissive-shadows spec). Bit 18. MUST match
// RT_FLAG_TRANSMISSIVE_GEOMETRY in scene_shader_raytracing.h.
#define RT_FLAG_TRANSMISSIVE_GEOMETRY 262144u // 1 << 18

// Scene CONTENT, not an Environment toggle: true when any material in the scene
// has transmission > 0. Folds the pass-B loop away entirely when false.
#define RT_GET_TRANSMISSIVE_GEOMETRY() ((RT_FLAGS & RT_FLAG_TRANSMISSIVE_GEOMETRY) != 0u)

// MIRRORS scene_shader_raytracing.h RT_INSTANCE_MASK_* -- change both together.
#define RT_INSTANCE_MASK_OPAQUE 0x01u
#define RT_INSTANCE_MASK_TRANSMISSIVE 0x02u
// Primary, indirect and DLSS-RR probe rays keep seeing everything.
#define RT_INSTANCE_MASK_ALL 0xFFu

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
