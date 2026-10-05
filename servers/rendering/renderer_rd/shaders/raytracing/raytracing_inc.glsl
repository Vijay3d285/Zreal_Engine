// Shared definitions for raytracing shaders (raygen, miss, closest_hit, any_hit).
// Must be included before scene_data_inc.glsl since it defines MAX_VIEWS.
#include "../oct_inc.glsl"

#include "sobol_burley_inc.glsl"

#define MAX_VIEWS 2

#ifndef PI
#define PI 3.141592653589f
#endif

// ============================================================================
// RT_PARAMS INDICES - Must match RT_PARAM_* in scene_shader_raytracing.h
// ============================================================================
// rt_params is a vec4[4] uniform buffer (16 floats total)
// Access: rt_params[idx >> 2][idx & 3] or get_rt_param(idx)
#define RT_PARAM_VIS_MODE 0 // rt_params[0].x - Debug visualization mode (0 = disabled)
#define RT_PARAM_SAMPLE_COUNT 1 // rt_params[0].y - Samples per pixel
#define RT_PARAM_MAX_BOUNCES 2 // rt_params[0].z - Maximum ray bounces
#define RT_PARAM_DENOISER 3 // rt_params[0].w - Denoiser selection (0=none, 1=DLSS RR)
#define RT_PARAM_ACCUM_FLAG 4 // rt_params[1].x - 1.0 = accumulate across frames, 0.0 = one-shot
#define RT_PARAM_ACCUM_FRAMES 5 // rt_params[1].y - 0-based accumulation frame index (driver-injected)
// Indices 6-8 are taken by PT_PARAM_OIDN_FLAG, PT_PARAM_ACCUM_TARGET, and
// PT_PARAM_DLSS_RR_FINAL_FLAG (defined C++-side in rendering_server_enums.h);
// they are not read by GLSL, so do not reuse them here.
#define RT_PARAM_CLAMP_DIRECT 9 // rt_params[2].y - Max direct contribution (0 = off)
#define RT_PARAM_CLAMP_INDIRECT 10 // rt_params[2].z - Max indirect contribution (0 = off)
#define RT_PARAM_NOISE_THRESHOLD 11 // rt_params[2].w - Adaptive sampling relative-error target (0 = off)
#define RT_PARAM_MAX_DIFFUSE_BOUNCE 12 // rt_params[3].x - Diffuse bounce cap (0 = use MAX_BOUNCES)
#define RT_PARAM_MAX_GLOSSY_BOUNCE 13 // rt_params[3].y - Glossy bounce cap (0 = use MAX_BOUNCES)
#define RT_PARAM_LIGHT_COUNT 14 // rt_params[3].z - Number of active lights in light buffer
#define RT_PARAM_FRAME_INDEX 15 // rt_params[3].w - Frame counter for temporal variation
// F2 volumetrics (roadmap Gap #16). rt_params grew from 4 to 10 vec4s; these
// live in the second block. All linear, energy applied on the CPU.
#define RT_PARAM_VOLUME_SIGMA_T 16 // rt_params[4].x - extinction per metre (Environment.volumetric_fog_density)
#define RT_PARAM_VOLUME_G 17 // rt_params[4].y - Henyey-Greenstein anisotropy
#define RT_PARAM_PORTAL_COUNT 18 // rt_params[4].z - live light portals (raytracing_portal_inc.glsl)
#define RT_PARAM_VOLUME_ALBEDO_R 20 // rt_params[5].xyz - single-scattering albedo
#define RT_PARAM_VOLUME_EMISSION_R 24 // rt_params[6].xyz - emission per metre, already x energy x density
#define RT_PARAM_VOLUME_BOX_MIN_X 28 // rt_params[7].xyz - world-space box (the scene's AABB, padded 1 cm)
#define RT_PARAM_VOLUME_BOX_MAX_X 32 // rt_params[8].xyz
#define RT_PARAM_GUIDE_PROB 35 // rt_params[8].w - path-guiding mixture probability (0 = off)
#define RT_PARAM_GUIDE_ORIGIN_X 36 // rt_params[9].xyz - guide grid origin (the TLAS AABB min)
#define RT_PARAM_GUIDE_CELL 39 // rt_params[9].w - guide voxel edge in metres (0 = off)

// ============================================================================
// PATHTRACING PAYLOAD (48 bytes nominal, fp32 radiance/throughput)
// ============================================================================
// Radiance and throughput are fp32: the previous fp16 packing clamped radiance
// at 65504 and banded in deep specular tails. `mis_ray_pdf` carries the BSDF pdf
// of the ray that produced this segment, so the miss shader can form a MIS
// weight against the environment pdf. A NEGATIVE value means "no MIS, use
// weight 1" -- see RT_MIS_PDF_NONE below.
//
// NOTE ON SIZE: 56 bytes (48 before Gap #26) assumes vec3 packs at 12 bytes in
// the payload. Some drivers pad vec3 to 16, making the effective size 64. Either
// way both stages declare the identical struct so they agree; the frame-time
// measurement in Step 8 is what tells us whether the growth cost anything.

/// "No triangle to skip." A restart with skip_geom == RT_SKIP_NONE uses the
/// pre-Gap-#26 margins (offset_ray_origin + t_min 0.001) and is byte-identical
/// to the engine before the fix.
const uint RT_SKIP_NONE = 0xFFFFFFFFu;

struct PathPayload {
	vec3 radiance; // 12 bytes
	vec3 throughput; // 12 bytes
	uint packed_bounces_flags; //  4 bytes - [flags:8][glossy:8][diffuse:8][total:8]
	uint rng_packed; //  4 bytes - packed [sample_index:20][dimension offset:12]
	float hit_t; //  4 bytes - ray distance, used by raygen to rebuild origin
	uint oct_offset_nrm; //  4 bytes - packUnorm2x16(vec3_to_oct(offset normal))
	uint oct_next_dir; //  4 bytes - packUnorm2x16(vec3_to_oct(next direction))
	float mis_ray_pdf; //  4 bytes - BSDF pdf of this segment, <0 = no MIS
	// Gap #26. The triangle a THROUGH-event (Transparent BSDF pass-through,
	// transmissive-lobe sample) just crossed. The raygen restarts such a ray at
	// the exact hit point with t_min = 0 and the any-hit stage refuses this one
	// triangle by identity -- Cycles' ray->self.prim -- so a surface 0.1 mm
	// behind a pane is hit instead of being skipped by a distance margin.
	uint skip_geom; //  4 bytes - gl_InstanceCustomIndexEXT, or RT_SKIP_NONE
	uint skip_prim; //  4 bytes - gl_PrimitiveID within that geometry
	// E3. sss_restart: where the next ray starts after a random walk -- the walk's
	// exit is not on the current ray, so origin + dir * hit_t cannot express it.
	// The path's small flags ride in the 4th word. Without RT_OIDN_FEATURES that is
	// sss_restart.w, a float carrying 0..3: 1.0 while that restart is pending (the
	// "SSS exit" flag), 2 = guide_record (Gap #32). The flags live HERE and not in
	// packed_bounces_flags because that word has no free bit: [total:8][diffuse:8]
	// [glossy:8] then 24 sample-zero, 25 shadow, 26 terminated, 27-30 the transmission
	// counter, 31 inside-medium. A first cut put the SSS flag at bit 27 and every path
	// with an odd number of glass crossings restarted from (0,0,0). 16 bytes; the
	// struct is 80.
	//
	// RT_OIDN_FEATURES (the accumulate / Phase A pipeline only: sample-count field 0 in
	// the RT flags word, see scene_shader_raytracing.cpp) turns that word into a plain
	// uint, sss_bits: bit 0 sss_exit, bit 1 guide_record, bit 2 feat_pending (OIDN
	// guides), bits 8-15 / 16-23 / 24-31 the OIDN feature throughput r / g / b as unorm8
	// (spec 2026-10-04-oidn-guide-feature-passthrough-design.md; Cycles'
	// denoising_feature_throughput, a product of albedos in [0, 1], quantised exactly as
	// packUnorm4x8 does, so 1.0 round-trips). Same 16 bytes, so the payload stays 92:
	// every NEE shadow ray copies the whole payload and keeps it live across its
	// traceRayEXT, and a dedicated 4-byte word cost the DLSS-RR one-shot path 2.9% per
	// frame although the new code never runs there. That path compiles without the define,
	// i.e. the pre-feature source and layout.
#ifdef RT_OIDN_FEATURES
	vec3 sss_restart;
	uint sss_bits;
#else
	vec4 sss_restart;
#endif
	// Light portals. The vertex whose BSDF sample produced this ray -- the
	// point its NEE used. The sky pdf now depends on the position (which
	// portals face it, and their solid angle from it), so the miss stage must
	// evaluate it HERE, not at gl_WorldRayOriginEXT: after an alpha
	// pass-through the ray restarts at the pane (Gap #26) with mis_ray_pdf
	// untouched, and a pdf taken from the pane would not be the one the NEE
	// weight was built from -- the two MIS weights would no longer sum to 1.
	// Cycles keeps ray.P at the scattering vertex across a transparent bounce
	// (shade_surface.h:573-576) for the same reason. 12 bytes; struct is 92.
	vec3 mis_origin;
};

/// Sentinel: this ray has no meaningful BSDF pdf, so anything it hits takes the
/// full contribution (MIS weight 1). Used for primary camera rays and for
/// near-delta specular lobes that environment sampling can never reach.
/// Mirrors Cycles' PATH_RAY_MIS_SKIP.
const float RT_MIS_PDF_NONE = -1.0;
// F2: the miss stage marks a bounded trace that ended inside the fog box (a
// scatter event) with this sentinel in mis_ray_pdf; raygen shades it.
const float RT_MIS_PDF_VOLUME_SCATTER = -3.0;
// F2: MaterialProperties.phaseG below this means "a surface" -- the NEE sites
// evaluate the BRDF. Above it, the value IS the Henyey-Greenstein g and the
// sites evaluate the phase function instead.
const float RT_PHASE_SURFACE = -2.0;
// The unbounded ray length. Was a bare 10000.0 at every trace and in the miss
// stage's far-point; F2 needs to compare a ray's tmax against it.
const float RT_RAY_TMAX = 10000.0;

/// Below this roughness a specular lobe is treated as delta for MIS purposes.
/// An independent, tighter cutoff than MAX_DENOISER_SPECULAR_HIT_THRESHOLD
/// (0.25, used for the DLSS-RR specular-hit-distance query) -- the two are not
/// related and do not need to match.
const float RT_MIS_DELTA_ROUGHNESS = 0.03;

/// A/B switch for environment NEE (roadmap C3), kept permanently as measurement
/// scaffolding rather than deleted after the phase -- the same standing precedent
/// as RT_LIGHT_SELECT_UNIFORM (raytracing_lights_inc.glsl) and
/// COMBINE_BRDFS_WITH_FRESNEL (brdf_inc.glsl).
///   1 = environment NEE + the sky-hit MIS weight (production)
///   0 = BSDF sampling alone, every sky hit taking MIS weight 1
///
/// BOTH HALVES MOVE TOGETHER, and that is the whole point of having one switch
/// instead of two. Disabling only the NEE shadow ray would leave the miss stage
/// still scaling every BSDF sky hit by power_heuristic(bsdf_pdf, env_pdf) < 1,
/// so the control would not be "BSDF-only" -- it would be BSDF-only with a
/// fraction of its energy deleted, and any comparison against it would read as a
/// brightening that is really just the missing half of a partition.
///
/// It exists because the +2.4% converged-mean shift on dielectric specular
/// surfaces is defined as (MIS on) - (BSDF only), so neither figure alone can
/// tell you whether that defect is present. Before this switch the only way to
/// take the second figure was to check the raytracing shaders out at a pre-MIS
/// commit (de2ce2c248) and rebuild, which also reverts every unrelated change
/// made since and therefore cannot be used to measure anything on a current
/// tree.
#define RT_ENV_NEE_ENABLED 1

/// Upper bound applied to radiance/throughput when packing the payload. The
/// old fp16 packing pinned values at 65504 as an (unintentional) side effect;
/// fp32 packing has no such firewall. Without one, a single NaN/Inf sample
/// (e.g. from a degenerate BRDF evaluation) propagates unclamped into
/// rt_accum's running average (scene_raytracing_raygen.glsl) and poisons that
/// pixel for the rest of the accumulation, since one bad sample never decays
/// out of a mean. 1e6 is far above any plausible legitimate radiance in this
/// renderer but far below the range where downstream math (squaring,
/// tonemapping) would itself start overflowing.
const float RT_PAYLOAD_VALUE_CLAMP = 1e6;

/// Sanitizes a radiance/throughput value before it is packed into the
/// payload: NaN -> 0 (clamp()'s behavior on NaN is implementation-defined per
/// the GLSL spec, so NaN must be scrubbed explicitly before clamping), then
/// clamped to [0, RT_PAYLOAD_VALUE_CLAMP] (also catches +/-Inf, since Inf
/// compares greater/less than any finite bound).
vec3 sanitize_payload_value(vec3 v) {
	vec3 safe = mix(v, vec3(0.0), isnan(v));
	return clamp(safe, vec3(0.0), vec3(RT_PAYLOAD_VALUE_CLAMP));
}

/// Unpacked working copy of the payload.
struct PathState {
	vec3 radiance;
	vec3 throughput;
	uint packed_bounces_flags;
	uint rng_packed;
	float hit_t;
	vec3 offset_normal;
	vec3 next_ray_dir;
	float mis_ray_pdf;
	uint skip_geom;
	uint skip_prim;
	vec3 sss_restart;
	bool sss_exit;
	bool guide_record; // this vertex drew the diffuse lobe at density mis_ray_pdf (Gap #32)
	vec3 mis_origin;
#ifdef RT_OIDN_FEATURES
	vec3 feat_throughput; // OIDN guide: product of the specular albedos deferred through
	bool feat_pending; // OIDN guide: this sample has not written its guide yet
#endif
};

PathState path_unpack(PathPayload p) {
	PathState s;
	s.radiance = max(p.radiance, vec3(0.0));
	s.throughput = max(p.throughput, vec3(0.0));
	s.packed_bounces_flags = p.packed_bounces_flags;
	s.rng_packed = p.rng_packed;
	s.hit_t = p.hit_t;
	s.offset_normal = oct_to_vec3(unpackUnorm2x16(p.oct_offset_nrm) * 2.0 - 1.0);
	s.next_ray_dir = oct_to_vec3(unpackUnorm2x16(p.oct_next_dir) * 2.0 - 1.0);
	s.mis_ray_pdf = p.mis_ray_pdf;
	s.skip_geom = p.skip_geom;
	s.skip_prim = p.skip_prim;
#ifdef RT_OIDN_FEATURES
	s.sss_restart = p.sss_restart;
	// sss_bits: bit 0 sss_exit, bit 1 guide_record, bit 2 feat_pending, bits 8-31 the
	// OIDN feature throughput as three unorm8 (see PathPayload).
	s.sss_exit = (p.sss_bits & 1u) != 0u;
	s.guide_record = (p.sss_bits & 2u) != 0u;
	s.feat_pending = (p.sss_bits & 4u) != 0u;
	s.feat_throughput = unpackUnorm4x8(p.sss_bits >> 8u).rgb;
#else
	s.sss_restart = p.sss_restart.xyz;
	// sss_restart.w carries two bits as a small integer: 1 = sss_exit, 2 = guide_record.
	uint sss_bits = uint(p.sss_restart.w + 0.5);
	s.sss_exit = (sss_bits & 1u) != 0u;
	s.guide_record = (sss_bits & 2u) != 0u;
#endif
	s.mis_origin = p.mis_origin;
	return s;
}

void path_pack(inout PathPayload p, PathState s) {
	p.radiance = sanitize_payload_value(s.radiance);
	p.throughput = sanitize_payload_value(s.throughput);
	p.packed_bounces_flags = s.packed_bounces_flags;
	p.rng_packed = s.rng_packed;
	p.hit_t = s.hit_t;
	p.oct_offset_nrm = packUnorm2x16(vec3_to_oct(s.offset_normal));
	p.oct_next_dir = packUnorm2x16(vec3_to_oct(s.next_ray_dir));
	p.mis_ray_pdf = s.mis_ray_pdf;
	p.skip_geom = s.skip_geom;
	p.skip_prim = s.skip_prim;
#ifdef RT_OIDN_FEATURES
	p.sss_restart = s.sss_restart;
	// packUnorm4x8(vec4(t.rgb, 0)) puts r, g, b in bits 0-23; << 8 moves them to 8-31 and
	// drops the empty w byte. Same quantisation as the old dedicated word.
	p.sss_bits = (s.sss_exit ? 1u : 0u) | (s.guide_record ? 2u : 0u) | (s.feat_pending ? 4u : 0u) |
			(packUnorm4x8(vec4(s.feat_throughput, 0.0)) << 8u);
#else
	p.sss_restart = vec4(s.sss_restart, float((s.sss_exit ? 1u : 0u) | (s.guide_record ? 2u : 0u)));
#endif
	p.mis_origin = s.mis_origin;
}

// Bounce count helpers.
// Layout: bits 0-7 total, bits 8-15 diffuse, bits 16-23 glossy, bits 24+ flags.
uint get_total_bounces(uint packed) {
	return packed & 0xFFu;
}
uint get_diffuse_bounces(uint packed) {
	return (packed >> 8u) & 0xFFu;
}
uint get_glossy_bounces(uint packed) {
	return (packed >> 16u) & 0xFFu;
}
// NOTE: retained for debug_visualize()'s single-bounce debug-ray flag (below),
// which is unrelated to the diffuse/glossy lobe accounting this task adds --
// it is not a call site this task's bounce-limit rework touches.
uint inc_total_bounce(uint packed) {
	return packed + 1u;
}
uint inc_diffuse_bounce(uint packed) {
	return packed + 0x101u;
} // +1 to both total and diffuse
uint inc_glossy_bounce(uint packed) {
	return packed + 0x10001u;
} // +1 to both total and glossy

// Transmission bounce counter, bits 27-30 (roadmap E1). The byte lanes for
// total/diffuse/glossy are full, so this lives in the flags region above the
// terminated flag at 26. 4 bits -- 0 to 15 -- but inc_transmission_bounce does
// NOT saturate there itself (fix round 1, M1): it is a plain `+ 0x08000001u`,
// so incrementing PAST 15 carries into bit 31, INSIDE_MEDIUM_FLAG, flipping it
// unpredictably; if that bit was already set, the add wraps the ENTIRE word
// to zero, silently clearing every bounce counter and every flag. The caller
// is therefore responsible for never calling this once
// get_transmission_bounces() == 15 -- see the `min(..., 15u)` clamp on
// max_transmission at the cap site in shade_and_bounce
// (raytracing_closest_hit_common_inc.glsl), which is what actually keeps this
// safe. Reachable without it whenever RT_GET_MAX_TRANSMISSION_BOUNCE() is 0
// (a raw RenderingServer with the setting unset resolves the cap to
// max_total, up to 16) -- matched by the project-setting-driven CLAMP(1, 15)
// on the cap for the normal (non-raw) path (NOT Environment -- it has no such
// property; see raytracing_common_inc.glsl's RT_MAX_TRANSMISSION_BOUNCE_SHIFT
// comment for the actual source: scene_shader_raytracing.cpp's
// compute_rt_flags(), reading rendering_server.cpp's
// `rendering/pathtracer/max_transmission_bounce` GLOBAL_DEF).
uint get_transmission_bounces(uint packed) {
	return (packed >> 27u) & 0xFu;
}
uint inc_transmission_bounce(uint packed) {
	return packed + 0x08000001u;
} // +1 to both total and transmission

/// Resolve a per-lobe cap, treating 0 as "unset" and falling back to the total
/// limit. Environment always writes >= 1; 0 only arrives from a raw
/// RenderingServer environment that never set the pathtracing params, and
/// terminating those paths immediately would render the scene black. Also
/// clamps the upper bound to p_max_total so a raw environment_set_pathtracing_params
/// write of an oversized per-lobe cap cannot exceed the overall bounce budget --
/// mirrors Environment::set_pathtracing_max_diffuse_bounce/_max_glossy_bounce's
/// own CLAMP(1, 16), which a direct RenderingServer caller bypasses.
uint resolve_bounce_cap(float p_param, uint p_max_total) {
	uint cap = uint(max(p_param, 0.0));
	return (cap == 0u) ? p_max_total : min(cap, p_max_total);
}

// Sample 0 flag (bit 24) - only write DLSS RR outputs on first sample
const uint SAMPLE_ZERO_FLAG = (1u << 24);
uint set_sample_zero(uint packed) {
	return packed | SAMPLE_ZERO_FLAG;
}
bool is_sample_zero(uint packed) {
	return (packed & SAMPLE_ZERO_FLAG) != 0u;
}

// Shadow ray flag (bit 25) - indicates this ray is a shadow/occlusion test
const uint SHADOW_RAY_FLAG = (1u << 25);
uint set_shadow_ray(uint packed) {
	return packed | SHADOW_RAY_FLAG;
}
bool is_shadow_ray(uint packed) {
	return (packed & SHADOW_RAY_FLAG) != 0u;
}

const uint PATH_TERMINATED_FLAG = (1u << 26);

// E3's subsurface-exit flag is PathState.sss_exit / bit 0 of PathPayload.sss_bits,
// not a bit here -- bits 27-30 are the transmission counter below.
uint set_path_terminated(uint packed) {
	return packed | PATH_TERMINATED_FLAG;
}
uint clear_path_terminated(uint packed) {
	return packed & ~PATH_TERMINATED_FLAG;
}
bool is_path_terminated(uint packed) {
	return (packed & PATH_TERMINATED_FLAG) != 0u;
}

// Inside-medium flag (bit 31). Set when a ray refracts INTO a solid, cleared
// when it exits. Raygen reads it to decide whether to drop
// gl_RayFlagsCullBackFacingTrianglesEXT for the next trace: a refracted ray
// must hit the FAR side of the glass, which is a back face and is otherwise
// invisible. Every non-transmissive path traces with byte-identical flags.
const uint INSIDE_MEDIUM_FLAG = (1u << 31);
uint set_inside_medium(uint packed) {
	return packed | INSIDE_MEDIUM_FLAG;
}
uint clear_inside_medium(uint packed) {
	return packed & ~INSIDE_MEDIUM_FLAG;
}
bool is_inside_medium(uint packed) {
	return (packed & INSIDE_MEDIUM_FLAG) != 0u;
}

// Bounce limits
#define MAX_DENOISER_SPECULAR_HIT_THRESHOLD 0.25

// ============================================================================
// CONSTANTS
// ============================================================================
const uint OFFSET_NONE = 0xFFFFFFFFu;
const uint FLAG_COMPRESSED = 1u;
const uint FLAG_PROCEDURAL = 2u;
// Set when the BLAS uses a per-frame-deformed vertex buffer.
const uint FLAG_DEFORMED = 4u;

// ============================================================================
// RANDOM NUMBER GENERATION
// ============================================================================
//
// Two samplers coexist here on purpose.
//
// 1. Sobol-Burley (rng_1d / rng_2d) is the production sampler and mirrors Cycles.
//    Every draw names an explicit DIMENSION rather than advancing a stream. That
//    is the whole mechanism: stratification only holds if a given decision uses
//    the same dimension on every path in the frame, and a stream cannot promise
//    that because different paths branch differently. Never convert these back
//    into "advance and return" helpers.
//
// 2. PCG (pcg_hash / rand) survives for the RT_LIGHT_SELECT_UNIFORM control path
//    (raytracing_lights_inc.glsl): the pre-C2 mini-batch reservoir it gates draws
//    a variable number of values per shading point. Giving that loop
//    2 * RT_LIGHT_RESERVOIR_SIZE Sobol dimensions would spend our best-stratified
//    dimensions on the decision Cycles itself does not Sobol sample -- its light
//    tree descends on one rescaled number (kernel/light/tree.h). Roadmap item C2
//    replaced the reservoir with a power-weighted selector for production; this
//    stream now serves only that A/B control path. It is at least SEEDED from
//    the Sobol state so it stays decorrelated from the rest of the path.

/// PCG random number generator - improved XSH-RR variant with better avalanche.
uint pcg_hash(uint seed) {
	uint state = seed * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

/// Random float in [0, 1) from a mutable PCG stream. Reservoir loop only.
float rand(inout uint state) {
	state = pcg_hash(state);
	return float(state) / 4294967296.0;
}

/// Fixed scramble seed. Cycles randomizes this per frame when pixel jitter is on;
/// we keep it constant so a given accumulation frame index always reproduces the
/// same image, which the validation harness depends on. Sample decorrelation
/// across frames comes from the sample index, not from reseeding.
const uint RT_SAMPLER_SEED = 0x5f356495u;

// Dimension allocation, mirroring Cycles' PathTraceDimension (kernel/types.h:72).
// Each bounce owns a block of RT_PRNG_BOUNCE_NUM consecutive dimensions; the
// constants below index within the current block. Earlier dimensions are better
// stratified, so the highest-variance decision (the BSDF direction) gets 0.
// Cycles uses a block of 16 (kernel/types.h PathTraceDimension); we were at 8
// with every slot taken, and C1's emissive NEE needs three more dimensions.
// WIDENING THIS RE-STRATIFIES EVERY BOUNCE: rng_next_bounce advances `offset` by
// RT_PRNG_BOUNCE_NUM, so each bounce after the first now draws from a different
// Sobol dimension than it did at 8. The estimator stays unbiased -- every
// dimension of the sequence is equidistributed -- but the image changes at any
// finite sample count, and the converged mean must not. That is gated
// separately (pt_emissive_gate.gd, gate 3) before any lighting change lands.
//
// A 2D draw occupies exactly ONE slot in this numbering, not two. rng_2d passes a single
// `p_rng.offset + p_dim` as sobol_burley_sample_2D's p_dimension_set argument, and that
// function produces both vec2 components by varying the internal sb_sobol_burley axis
// (0u/1u) -- it never reads p_dimension_set+1 (sobol_burley_inc.glsl). So RT_PRNG_LIGHT
// (2D) and RT_PRNG_ENV (2D) each still reserve only their own listed value. Slot 3 is
// simply unused (RT_PRNG_LIGHT is 2u, RT_PRNG_LOBE is 4u) -- that gap is leftover headroom
// from an earlier layout, not evidence of a two-slot-per-2D-draw convention.
#define RT_PRNG_BOUNCE_NUM 16u
#define RT_PRNG_FILTER 0u // 2D, init block only: sub-pixel reconstruction filter.
#define RT_PRNG_SURFACE_BSDF 0u // 2D: BSDF direction sample.
#define RT_PRNG_LIGHT 2u // 2D: position on the selected light.
#define RT_PRNG_LOBE 4u // 1D: diffuse-vs-specular lobe choice.
#define RT_PRNG_TERMINATE 5u // 1D: Russian Roulette survival (B4).
#define RT_PRNG_LIGHT_SELECT 6u // 1D: which analytic light to sample (C2).
#define RT_PRNG_ENV 7u // 2D: direction sample on the environment (C3).
#define RT_PRNG_EMISSIVE_SELECT 8u // 1D: emissive instance + triangle (C1).
#define RT_PRNG_EMISSIVE_POINT 9u // 2D: barycentric point on that triangle (C1).
#define RT_PRNG_TRANSPARENT 10u // 1D: transparent-vs-shade choice (alpha closure).
#define RT_PRNG_TRANSMIT 11u // 1D: reflect-vs-transmit choice inside the dielectric closure (E1).
#define RT_PRNG_VOLUME 12u // 1D: free-flight distance through the fog box (F2).
#define RT_PRNG_GUIDE 13u // 1D: guided-vs-cosine coin at a diffuse draw (Gap #32).
// Slots 12-15 are free. Earlier dimensions are better stratified, so the
// highest-variance decision (the BSDF direction) keeps 0.

/// Sampler state for one path. `pixel` is the per-pixel Owen scramble seed,
/// `sample_index` selects the point in the sequence, and `offset` is the base
/// dimension of the current bounce's block.
struct RNGState {
	uint pixel;
	uint sample_index;
	uint offset;
};

/// Per-pixel scramble seed (Cycles `path_rng_pixel_init`, pattern.h:143).
uint rng_pixel_seed(uvec2 p_pixel) {
	return sb_hash_iqnt2d(p_pixel.x, p_pixel.y) ^ RT_SAMPLER_SEED;
}

/// Start a path. Block 0 is reserved for the camera/init decisions (the pixel
/// filter), so shading starts at block 1 -- same convention as Cycles, which
/// initializes rng_offset to PRNG_BOUNCE_NUM (path_state.h:58).
RNGState rng_init(uvec2 p_pixel, uint p_sample_index) {
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_sample_index;
	r.offset = RT_PRNG_BOUNCE_NUM;
	return r;
}

/// Advance to the next bounce's dimension block (Cycles path_state.h:241).
RNGState rng_next_bounce(RNGState p_rng) {
	RNGState r = p_rng;
	r.offset += RT_PRNG_BOUNCE_NUM;
	return r;
}

/// 1D draw from dimension `p_dim` of the current block. Does not mutate state.
float rng_1d(RNGState p_rng, uint p_dim) {
	// 0xffffffff = maximum sequence length. Cycles derives a shorter mask from the
	// sample count purely to shorten this loop. The mask does change the values --
	// `index &= mask` truncates the shuffled index, so a different Sobol point is
	// drawn -- what it PRESERVES is the stratification property (see test_pt_sobol.cpp,
	// "first 2^k samples hit every stratum/cell exactly once", which passes at both
	// a block_mask(k) and at 0xffffffffu).
	return sobol_burley_sample_1D(p_rng.sample_index, p_rng.offset + p_dim, p_rng.pixel, 0xffffffffu);
}

/// 2D draw from dimension set `p_dim` of the current block. Does not mutate state.
vec2 rng_2d(RNGState p_rng, uint p_dim) {
	return sobol_burley_sample_2D(p_rng.sample_index, p_rng.offset + p_dim, p_rng.pixel, 0xffffffffu);
}

/// Seed for a PCG side stream that is decorrelated from every Sobol dimension.
/// Used only by the RT_LIGHT_SELECT_UNIFORM control path (the pre-C2 light
/// reservoir), which is the one remaining caller with a data-dependent draw count.
uint rng_side_stream(RNGState p_rng, uint p_dim) {
	return pcg_hash(p_rng.pixel ^ pcg_hash(p_rng.sample_index * 2654435761u + p_rng.offset + p_dim));
}

/// Pack the travelling part of the state into the payload's 32 bits:
/// [sample_index:20][offset:12]. `pixel` is not packed -- every ray-tracing stage
/// can recompute it from gl_LaunchIDEXT, so it costs nothing to carry.
/// 20 bits covers 1,048,575 samples and 12 bits covers 4095 dimensions
/// (16 bounces x 16 = 256, ample headroom below the 4095 cap). In accumulate
/// mode the caller passes the raw accum_frame (scene_raytracing_raygen.glsl),
/// which the accumulation target caps at 8192, so that mode is nowhere near the limit.
///
/// In one-shot mode the caller passes frame_index * stride + sample_idx, where
/// stride is rt_next_pow2_ge(samples_per_pixel) and frame_index is a
/// session-lifetime dispatch counter that never resets. sample_index therefore
/// grows by `stride` every dispatch and CAN exceed 0xFFFFF (1,048,576): at
/// stride 32 (the production day-branch stride for samples_per_pixel=20) that
/// takes 1,048,576 / 32 = 32,768 dispatched frames. Past that point the clamp
/// below saturates sample_index and every subsequent draw for a pixel reuses
/// one Sobol point, freezing that pixel's noise pattern for the rest of the
/// session. Accepted for the realtime one-shot path, but NOT a hypothetical
/// edge case for this repository: pipeline_references/image_glb_creation.gd
/// ships PHASE_A_OFFLINE_STILL := false, so one-shot is the default
/// still-render route, not merely a preview mode.
uint rng_pack(RNGState p_rng) {
	return (min(p_rng.sample_index, 0xFFFFFu) << 12u) | (p_rng.offset & 0xFFFu);
}

RNGState rng_unpack(uint p_packed, uvec2 p_pixel) {
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_packed >> 12u;
	r.offset = p_packed & 0xFFFu;
	return r;
}

/// Smallest power of two >= p_n, for p_n >= 1. Used to give the one-shot RNG
/// sequence index a power-of-two stride (scene_raytracing_raygen.glsl) so the
/// per-frame window `[frame_index * stride, frame_index * stride + spp)` is a
/// power-of-two-aligned Sobol prefix even when samples_per_pixel itself is not
/// a power of two -- an unaligned window is not a stratified prefix and measured
/// ~20% worse RMSE than the aligned form at production sample counts.
uint rt_next_pow2_ge(uint p_n) {
	// findMSB(0) is defined as -1 by the GLSL spec, so p_n == 1 (p_n - 1 == 0)
	// correctly falls out to 1u << 0u == 1.
	return 1u << uint(findMSB(max(p_n, 1u) - 1u) + 1);
}

// ============================================================================
// CAMERA RECONSTRUCTION FILTER
// ============================================================================

// Blackman-Harris pixel reconstruction filter, matching Blender Cycles.
//
// Cycles evaluates the Blackman-Harris window over its half-profile [0, 1],
// builds an inverted CDF from it, and looks the sub-pixel offset up from that
// table (intern/cycles/scene/film.cpp: filter_func_blackman_harris +
// util_cdf_inverted; applied in kernel/camera/camera.h: raster += lookup_table_read).
// Cycles' DEFAULT filter_width is 1.5 (intern/cycles/blender/addon/properties.py,
// `filter_width ... default=1.5`), and filter_table() widens it x2, so offsets
// span +/-1.5 pixels around the pixel centre. RT_PIXEL_FILTER_WIDTH below is
// that 1.5. (It was 1.0 until 2026-09-16 on the belief that Cycles' default
// was 1.0; the pixel-filter gate's 10-90% edge ramp read 0.72 px against
// Cycles' 1.08.)
//
// The window is strongly centre-weighted: half the samples land within
// +/-0.29 px of the centre (+/-0.19 at width 1.0), the rest fall away
// smoothly to the +/-1.5 px edge. That shape, not the radius alone, is what
// keeps fine detail while still ramping a hard edge over ~1.1 px.
//
// Table below is the inverse CDF of the half-profile sampled at 33 points,
// generated from the same formula Cycles uses, on a NORMALISED radius [0, 1];
// bh_filter_1d scales it by RT_PIXEL_FILTER_WIDTH, so the shape is width-free.
const float RT_PIXEL_FILTER_WIDTH = 1.5;
const float BH_INV_CDF_HALF[33] = float[33](
		0.000000, 0.011217, 0.022451, 0.033716, 0.045031, 0.056412,
		0.067877, 0.079445, 0.091136, 0.102972, 0.114976, 0.127173,
		0.139592, 0.152265, 0.165227, 0.178518, 0.192186, 0.206285,
		0.220880, 0.236047, 0.251880, 0.268495, 0.286038, 0.304696,
		0.324718, 0.346446, 0.370366, 0.397209, 0.428163, 0.465364,
		0.513365, 0.585604, 1.000000);

/// Inverse CDF of the Blackman-Harris half-profile: maps a in [0,1] to a
/// normalized radius in [0,1], linearly interpolating the table.
float bh_inv_cdf_half(float a) {
	float t = clamp(a, 0.0, 1.0) * 32.0;
	int i = min(int(t), 31);
	return mix(BH_INV_CDF_HALF[i], BH_INV_CDF_HALF[i + 1], t - float(i));
}

/// Blackman-Harris filter offset in [-RT_PIXEL_FILTER_WIDTH, RT_PIXEL_FILTER_WIDTH]
/// for u in [0,1). Filter importance sampling: the sample may land outside the
/// pixel footprint but still accumulates into this pixel, which is what
/// performs the reconstruction.
float bh_filter_1d(float u) {
	float s = 2.0 * u - 1.0;
	return sign(s) * bh_inv_cdf_half(abs(s)) * RT_PIXEL_FILTER_WIDTH;
}

/// Sub-pixel offset for accumulation/loop sample `p_sample`.
/// Sample 0 is centred, matching Cycles (`init_from_camera.h`): the first frame
/// of a preview stays identical to the un-jittered image, and the primary-ray
/// G-buffer writes that fire on sample 0 keep their pixel-centre alignment.
vec2 camera_filter_jitter(uvec2 p_pixel, uint p_sample) {
	if (p_sample == 0u) {
		return vec2(0.5);
	}
	// Dimension block 0 (the init block), dimension RT_PRNG_FILTER. This is the
	// best-stratified pair in the whole sequence, which is what anti-aliasing
	// wants: the sub-pixel positions of N samples should tile the pixel evenly
	// rather than clump. Shading draws start at block 1 and are decorrelated.
	RNGState r;
	r.pixel = rng_pixel_seed(p_pixel);
	r.sample_index = p_sample;
	r.offset = 0u;
	vec2 u = rng_2d(r, RT_PRNG_FILTER);
	return vec2(0.5) + vec2(bh_filter_1d(u.x), bh_filter_1d(u.y));
}

// ============================================================================
// FIREFLY CLAMPING
// ============================================================================

/// Scales a radiance contribution so its largest channel does not exceed
/// `p_limit`, preserving hue. `p_limit <= 0.0` disables clamping.
///
/// This biases the estimator by design — it is the standard, and Cycles ships
/// the same knob (`sample_clamp_direct` / `sample_clamp_indirect`). Clamping
/// matters more here than in a one-shot renderer: under accumulation a single
/// outlier decays only as 1/N and stays visible for the whole render.
vec3 clamp_contribution(vec3 p_c, float p_limit) {
	if (p_limit <= 0.0) {
		return p_c;
	}
	float m = max(p_c.r, max(p_c.g, p_c.b));
	return (m > p_limit) ? p_c * (p_limit / m) : p_c;
}

// ============================================================================
// MULTIPLE IMPORTANCE SAMPLING
// ============================================================================

/// Power heuristic with beta = 2, matching Cycles (intern/cycles/kernel/light/sample.h).
/// power_heuristic(a, b) + power_heuristic(b, a) == 1 exactly, which is what makes
/// the combined estimator unbiased: the two strategies' weights partition the
/// contribution rather than scaling it.
float power_heuristic(float p_a, float p_b) {
	float a2 = p_a * p_a;
	float b2 = p_b * p_b;
	float denom = a2 + b2;
	return (denom > 0.0) ? (a2 / denom) : 0.0;
}

// ============================================================================
// RAY ORIGIN OFFSET (prevents self-intersection)
// Wachter-Binder method: offsets in integer float representation so the
// displacement scales naturally with position magnitude.
// ============================================================================
float _offset_component(float p, float n_comp, int of_comp) {
	const float origin = 1.0 / 32.0;
	const float float_scale = 1.0 / 65536.0;
	int shifted = floatBitsToInt(p) + ((p >= 0.0) ? of_comp : -of_comp);
	float p_i = intBitsToFloat(shifted);
	return (abs(p) < origin) ? (p + float_scale * n_comp) : p_i;
}

vec3 offset_ray_origin(vec3 p, vec3 n) {
	const float int_scale = 256.0;
	ivec3 of = ivec3(int_scale * n);
	return vec3(
			_offset_component(p.x, n.x, of.x),
			_offset_component(p.y, n.y, of.y),
			_offset_component(p.z, n.z, of.z));
}
