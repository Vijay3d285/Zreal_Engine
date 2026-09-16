// Light sampling and Next Event Estimation (NEE) for raytracing.
// Requires: raytracing_inc.glsl, brdf_inc.glsl, tlas at binding 1, payload at location 0.
// Note: ray_query_alpha_test() still requires GL_EXT_ray_query (used by DLSS-RR path).
//
// IES photometric profiles are supported via ies_lookup_inc.glsl.
// Each RTLightData carries an ies_slot (-1 = none) and ies_strength multiplier.
#include "ies_lookup_inc.glsl"

// ============================================================================
// Light Types and Constants
// ============================================================================

#define RT_LIGHT_TYPE_OMNI 0 // Point light with radius (soft shadows)
#define RT_LIGHT_TYPE_DIRECTIONAL 1 // Sun/moon with angular size
#define RT_LIGHT_TYPE_RECT 2 // Area / rectangle light
#define RT_LIGHT_TYPE_SPOT 3 // Spot light with cone falloff

// A/B switch for roadmap C2, kept permanently as measurement scaffolding rather
// than deleted after the phase. Precedent: COMBINE_BRDFS_WITH_FRESNEL
// (defined in brdf_inc.glsl) is the only reason B2's +2.4% converged-mean shift could
// be pinned to a specific line instead of guessed at.
//   0 = power-weighted CDF (production)
//   1 = the pre-C2 uniform k=16 mini-batch reservoir
#ifndef RT_LIGHT_SELECT_UNIFORM
#define RT_LIGHT_SELECT_UNIFORM 0
#endif

#if RT_LIGHT_SELECT_UNIFORM
// Reservoir sampling batch size for stochastic light selection.
#ifndef RT_LIGHT_RESERVOIR_SIZE
#define RT_LIGHT_RESERVOIR_SIZE 16
#endif
#endif

// ============================================================================
// Light Data (matches C++ RT_LightData, 128 bytes, std430)
// ============================================================================

struct RTLightData {
	vec3 position; // World pos (omni/spot) or direction (directional).
	uint type; // RT_LIGHT_TYPE_*.
	vec3 emission; // HDR emission color (color * energy).
	float radius; // Light size (omni/spot) or angular radius (directional).
	float attenuation; // Attenuation exponent (2=inverse-square, 1=linear).
	float inv_max_range; // 1/range (-1 = infinite).
	float max_range_squared; // range^2 (0 = infinite).
	float specular_amount; // Godot specular multiplier [0..1].
	float indirect_energy; // Godot indirect energy multiplier.
	float inv_spot_attenuation; // Spot cone softness.
	float cos_spot_angle; // Cosine of spot cone half-angle.
	float shadow_enabled; // 1.0 = trace shadow rays, 0.0 = skip (shadowless fill). Must match C++ _pad0 position.
	vec3 spot_direction; // Spot direction (normalized, world space).
	float rect_half_height; // rect: half-height scalar (0 for non-rect)
	float rect_axis_v[3]; // rect: axisV half-height world vector (float[3] to match C++ std430 packing)
	float _pad2;
	int ies_slot; // IES profile slot index (-1 = no IES).
	float ies_strength; // IES intensity multiplier.
	// Light basis columns in world space: [0..2] = local X, [3..5] = local Y,
	// [6..8] = local Z. Orthonormal, so world->local is the transpose (three
	// dot products). Used only to evaluate IES profiles in the light's frame.
	float ies_basis[9];
	float _ies_pad[2]; // Pad to 160 bytes total (matches C++ RT_LightData).
};

// Rotate a world-space direction into the light's local frame, where the fixture
// aims along -Z (Godot light convention, matching Blender/Cycles).
vec3 lights_world_to_light_local(RTLightData light, vec3 world_dir) {
	return vec3(
			dot(world_dir, vec3(light.ies_basis[0], light.ies_basis[1], light.ies_basis[2])),
			dot(world_dir, vec3(light.ies_basis[3], light.ies_basis[4], light.ies_basis[5])),
			dot(world_dir, vec3(light.ies_basis[6], light.ies_basis[7], light.ies_basis[8])));
}

// Light buffer SSBO (binding provided by the including shader via RT_LIGHT_BUFFER_BINDING).
#ifndef RT_LIGHT_BUFFER_BINDING
#define RT_LIGHT_BUFFER_BINDING 13
#endif

layout(set = 0, binding = RT_LIGHT_BUFFER_BINDING, std430) readonly buffer LightBuffer {
	RTLightData rt_lights[];
};

// Godot-style windowed distance attenuation, from a squared distance.
// window = (1 - (d/range)^4)^2, combined with pow(d, -decay).
// Shared verbatim by the shading path (via lights_get_attenuation) and by the
// light-selection weight (lights_select_weight). These MUST stay one function:
// if the weight's falloff drifts from the contribution's falloff, the estimator
// divides by a pdf that does not match the density it sampled from.
// Distance form. Callers that already hold the distance use this directly:
// lights_select_weight needs `dist` anyway (for the rect half-diagonal bound and
// the spot cone), and routing it through the _from_dist_sq entry point made it
// pay a second sqrt of a value it had already taken the root of.
float lights_attenuation_from_dist(float p_dist, float p_inv_max_range, float p_decay) {
	if (p_dist <= 0.0) {
		return 1.0; // Directional: no distance attenuation.
	}

	// Clamped only for the decay term, matching the original expression exactly:
	// the window below uses the RAW distance.
	float safe_distance = max(p_dist, 0.0001);

	// Fast path for the inverse-square default. pow() is a transcendental and
	// lights_select_weight evaluates this 2N times per shading point, so on a
	// 40-light scene the exponent form costs 80 pow() where the scene almost
	// always wants exactly 1/d^2. Godot's LIGHT_PARAM_ATTENUATION defaults to 2.0
	// and the offline pipeline never overrides it. Any other exponent falls
	// through to pow() unchanged, so this is a speed path, not a behaviour change.
	float atten;
	if (p_decay == 2.0) {
		atten = min(1.0 / (safe_distance * safe_distance), 1.0);
	} else {
		atten = min(pow(safe_distance, -p_decay), 1.0);
	}

	// Windowed falloff if range is finite (inv_max_range >= 0).
	if (p_inv_max_range >= 0.0) {
		float nd = p_dist * p_inv_max_range;
		nd *= nd;
		nd *= nd; // nd^4
		nd = max(1.0 - nd, 0.0);
		nd *= nd; // nd^2 window
		return atten * nd;
	}

	return atten;
}

float lights_attenuation_from_dist_sq(float p_dist_sq, float p_inv_max_range, float p_decay) {
	if (p_dist_sq <= 0.0) {
		return 1.0; // Directional: no distance attenuation.
	}
	return lights_attenuation_from_dist(sqrt(p_dist_sq), p_inv_max_range, p_decay);
}

// Importance-weighted selection (roadmap C2). Included here, after RTLightData
// and the rt_lights SSBO, because it reads both.
#include "raytracing_light_select_inc.glsl"

// ============================================================================
// Unified Cone Sampling (for sphere, directional, spot lights)
// ============================================================================

struct LightSample {
	vec3 cone_axis; // Direction to sample around (normalized).
	float cos_theta_max; // Cone half-angle cosine (1.0 = point, 0.0 = hemisphere).
	vec3 emission; // Light radiance.
	float distance_sq; // Squared distance to light (0 = directional).
	float max_distance; // Max shadow ray distance.
};

// Build orthonormal basis from a single direction.
void lights_build_basis(vec3 dir, out vec3 tangent, out vec3 bitangent) {
	vec3 up = abs(dir.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	tangent = normalize(cross(up, dir));
	bitangent = cross(dir, tangent);
}

// Transform local direction to world space around axis.
vec3 lights_local_to_world(vec3 local_dir, vec3 axis) {
	vec3 tangent, bitangent;
	lights_build_basis(axis, tangent, bitangent);
	return local_dir.x * tangent + local_dir.y * bitangent + local_dir.z * axis;
}

// Prepare unified cone sample from any light type.
LightSample lights_prepare_sample(vec3 hit_pos, RTLightData light) {
	LightSample s;

	vec3 to_light = light.position - hit_pos;
	float dist_sq = dot(to_light, to_light);
	float inv_dist = inversesqrt(dist_sq + 1e-10);
	float dist = dist_sq * inv_dist;

	float is_directional = (light.type == RT_LIGHT_TYPE_DIRECTIONAL) ? 1.0 : 0.0;

	// Cone axis.
	vec3 sphere_axis = to_light * inv_dist;
	vec3 dir_axis = -normalize(light.position);
	s.cone_axis = mix(sphere_axis, dir_axis, is_directional);

	// Distance (0 for directional = no falloff).
	s.distance_sq = mix(dist_sq, 0.0, is_directional);

	// Cone angle from subtended solid angle.
	float sin_theta_sphere = clamp(light.radius * inv_dist, 0.0, 1.0);
	float cos_theta_sphere = sqrt(max(0.0, 1.0 - sin_theta_sphere * sin_theta_sphere));
	float cos_theta_dir = cos(light.radius);
	s.cos_theta_max = mix(cos_theta_sphere, cos_theta_dir, is_directional);
	s.cos_theta_max = min(s.cos_theta_max, 0.999999);

	s.emission = light.emission;

	// Max shadow ray distance.
	float sphere_max = dist + light.radius;
	float dir_max = 10000.0;
	s.max_distance = mix(sphere_max, dir_max, is_directional);

	return s;
}

// Sample a direction within the light's cone.
vec3 lights_sample_cone(LightSample ls, vec2 u, out float pdf) {
	float cos_theta = 1.0 - u.x * (1.0 - ls.cos_theta_max);
	float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
	float phi = 2.0 * PI * u.y;

	vec3 local_dir = vec3(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta);
	vec3 L = lights_local_to_world(local_dir, ls.cone_axis);

	float solid_angle = 2.0 * PI * (1.0 - ls.cos_theta_max);
	pdf = 1.0 / max(solid_angle, 1e-10);

	return L;
}

// ============================================================================
// Attenuation
// ============================================================================

// Thin LightSample-typed wrapper over lights_attenuation_from_dist_sq (defined
// above, right after the rt_lights SSBO). Kept here because LightSample isn't
// declared until after that point.
float lights_get_attenuation(LightSample ls, float inv_max_range, float decay) {
	return lights_attenuation_from_dist_sq(ls.distance_sq, inv_max_range, decay);
}

// Per-light specular multiplier.
float lights_get_specular_multiplier(float specular_amount, float roughness) {
	if (specular_amount >= 0.0) {
		return specular_amount;
	} else {
		float r3 = roughness * roughness * roughness;
		return mix(0.0, r3, -specular_amount);
	}
}

// ============================================================================
// Inline Alpha Test (shared by all ray query proceed loops)
// ============================================================================

/// Inline alpha test for ray query candidates. Returns true if the hit is opaque (alpha >= 0.5).
/// Mirrors the any-hit shader logic for use with inline ray queries.
bool ray_query_alpha_test(uint geometry_idx, uint primitive_id, vec2 candidate_bary) {
	vec3 bary = vec3(1.0 - candidate_bary.x - candidate_bary.y, candidate_bary.x, candidate_bary.y);

	GeometryData geom = geometries[geometry_idx];
	uint i0, i1, i2;
	get_triangle_indices_ex(geom, primitive_id, i0, i1, i2);
	vec2 uv = fetch_uv(geom, i0, i1, i2, bary);

	MaterialData mat = materials[geometry_idx];
	uv = uv * mat.uv1_scale + mat.uv1_offset;
	float alpha = texture(sampler2D(bindless_textures[nonuniformEXT(mat.albedo_texture_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv).a;
	alpha *= mat.albedo_color.a;

	return alpha >= 0.5;
}

// ============================================================================
// Shadow Ray (traceRayEXT pipeline)
// ============================================================================

float rt_max_component(vec3 v) {
	return max(v.x, max(v.y, v.z));
}

// Below this the ray is treated as blocked. Deliberately small: the returned
// value multiplies a light contribution that may be thousands of nits for a sun,
// so an aggressive epsilon clips real light rather than pruning a dead ray.
#define RT_SHADOW_ATTEN_EPSILON 1e-4

/// Returns per-channel light transmittance along the shadow ray.
///   vec3(0.0) = fully occluded, vec3(1.0) = clear, anything between = the
///   product of `transmission * (1 - F)` over every transmissive crossing.
///
/// PASS A traces only RT_INSTANCE_MASK_OPAQUE and answers the binary
/// occlusion question. Uses SkipClosestHitShader so only any_hit (alpha test)
/// and miss are invoked; TerminateOnFirstHit exits on the first confirmed
/// opaque hit.
///
/// PASS B then walks the transmissive-masked instances that pass A deliberately
/// no longer sees. Since Gap #22 (2026-09-13) it applies Cycles' rule: a BLEND
/// material's (1 - alpha) Transparent share passes the ray, and every other
/// crossing -- the dielectric share, a non-blend refractive pane -- blocks it
/// outright. The two halves are one unit: narrowing pass A without pass B culls
/// glass out of the shadow test entirely (glass casts no shadow), and pass B
/// without the narrowing double-counts every pane. Pass B must keep running
/// whatever the Environment transmission toggle says: the TLAS mask is a
/// material property, so pass A still cannot see the pane, and only pass B is
/// left to occlude it.
vec3 lights_trace_shadow_ray(vec3 origin, vec3 direction, float max_dist) {
#ifdef USE_SER
	hitObjectEXT hitObject;
	hitObjectTraceRayEXT(hitObject, tlas,
			gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
			RT_INSTANCE_MASK_OPAQUE, 0, 0, 0,
			origin, 0.001, direction, max_dist - 0.001, 0);

	if (hitObjectIsHitEXT(hitObject)) {
		return vec3(0.0);
	}
#else
	/// The miss shader writes radiance = vec3(1.0) for shadow rays (visible).
	/// If an opaque hit occurs, miss is never called and radiance stays vec3(0.0).
	// Save full payload, set up shadow ray, then restore after trace.
	PathPayload saved_payload = payload;

	PathState shadow_ps;
	shadow_ps.radiance = vec3(0.0);
	shadow_ps.throughput = vec3(0.0);
	shadow_ps.packed_bounces_flags = set_shadow_ray(0u);
	shadow_ps.rng_packed = 0u;
	shadow_ps.hit_t = 0.0;
	shadow_ps.offset_normal = vec3(0.0, 0.0, 1.0);
	shadow_ps.next_ray_dir = vec3(0.0, 0.0, 1.0);
	shadow_ps.mis_ray_pdf = RT_MIS_PDF_NONE;
	// Every field, or the any-hit stage reads whatever the registers held:
	// an uninitialised skip id that happened to be (0, 0) made shadow rays
	// skip instance 0 / triangle 0, and which garbage you get moved with the
	// payload layout (pt_transmission_gate probe 6 went 4.07 -> 5.04 when the
	// E3 payload grew by four bytes).
	shadow_ps.skip_geom = RT_SKIP_NONE;
	shadow_ps.skip_prim = RT_SKIP_NONE;
	shadow_ps.sss_restart = vec3(0.0);
	shadow_ps.sss_exit = false;
	path_pack(payload, shadow_ps);

	traceRayEXT(tlas,
			gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
			RT_INSTANCE_MASK_OPAQUE, 0, 0, 0,
			origin, 0.001, direction, max_dist - 0.001, 0);

	// Unpack to check visibility (miss shader packs radiance = 1.0).
	shadow_ps = path_unpack(payload);
	bool visible = shadow_ps.radiance.x > 0.5;

	payload = saved_payload;

	if (!visible) {
		return vec3(0.0);
	}
#endif

	// PASS B -- transmissive accumulation. Runs only when pass A found no opaque
	// occluder AND the scene actually contains transmissive geometry (a
	// specialization constant, so this whole block folds away otherwise).
	//
	// This is an inline ray query rather than any-hit accumulation on purpose.
	// Any-hit would require clearing FORCE_OPAQUE on transmissive instances
	// (render_raytracing.cpp:2991), and that bit is shared with the primary and
	// indirect rays -- every ray in the scene would start invoking any-hit on all
	// glass to pay for a shadow-path fix.
	//
	// ONLY the geometry gate belongs here. RT_GET_TRANSMISSIVE_GEOMETRY() is scene
	// content ("a transmissive instance exists"); when it is false there is nothing
	// in RT_INSTANCE_MASK_TRANSMISSIVE for the loop to find, so returning vec3(1.0)
	// is exactly right -- pass A already answered for every instance in the scene.
	//
	// RT_GET_TRANSMISSION_ENABLED() (the Environment toggle) MUST NOT gate this
	// early return, and a previous revision that added it here made glass cast NO
	// shadow at all. The reason is that the TLAS cull mask does not depend on the
	// toggle: rt_instance_mask_from_features (render_raytracing.cpp) derives the
	// mask from RT_FLAG_TRANSMISSIVE_GEOMETRY -- set per material from
	// `mat.transmission > 0.0f` -- or the per-surface alpha-blend signal, and from
	// nothing else. Neither term consults the toggle. So a pane is
	// masked TRANSMISSIVE whatever the toggle says, and pass A -- culled to
	// RT_INSTANCE_MASK_OPAQUE -- cannot see it. Early-returning vec3(1.0) here left
	// nothing occluding it in either pass, while the BSDF was drawing that same pane
	// as fully opaque (raytracing_closest_hit_common_inc.glsl:1468,
	// `transmissivness = RT_GET_TRANSMISSION_ENABLED() ? m.transmission : 0.0`).
	//
	// Since Gap #22 (2026-09-13) the toggle plays no part in the accumulation
	// either: a non-blend transmissive crossing drives atten to zero whether the
	// toggle is on or off -- a FULL occluder, Cycles' rule for refractive glass.
	// Only a BLEND material's (1 - alpha) Transparent share passes.
	if (!RT_GET_TRANSMISSIVE_GEOMETRY()) {
		return vec3(1.0);
	}

	vec3 atten = vec3(1.0);
	float t_min = 0.001;
	uint max_crossings = max(1u, RT_GET_MAX_TRANSMISSION_BOUNCE());

	float t_max = max_dist - 0.001;

	for (uint i = 0u; i < max_crossings; i++) {
		// The advance below can push t_min past the light for a pane sitting almost
		// exactly at max_dist. rayQueryInitializeEXT requires tMin <= tMax, so stop
		// rather than issue an out-of-spec query. Behaviourally a no-op -- an empty
		// interval could not have produced a hit anyway.
		if (t_min > t_max) {
			break;
		}

		rayQueryEXT rq;
		// gl_RayFlagsOpaqueEXT so the query commits transmissive hits directly
		// without an any-hit candidate step -- these instances carry FORCE_OPAQUE
		// and we want each crossing reported, not alpha-tested. Note RT_RAY_FLAGS
		// (back-face culling) is deliberately NOT used: the exit face of a pane is
		// a back face and it is exactly the second crossing we need to count.
		//
		// gl_RayFlagsTerminateOnFirstHitEXT is deliberately ABSENT, unlike pass A.
		// That flag commits whichever intersection in [t_min, t_max] traversal
		// happens to reach first -- BVH order, implementation-defined -- not the
		// nearest one. Pass A can use it because it asks a boolean question where
		// any hit is the answer. This loop instead marches t_min past each hit's t,
		// so committing a far hit silently DISCARDS every crossing between the old
		// t_min and it, under-counting panes and over-brightening the shadow. Without
		// the flag the query runs to completion and commits the genuine closest hit,
		// which is exactly the semantics this march needs; the cost is a full
		// traversal per crossing instead of an early-out.
		rayQueryInitializeEXT(rq, tlas,
				gl_RayFlagsOpaqueEXT,
				RT_INSTANCE_MASK_TRANSMISSIVE,
				origin, t_min, direction, t_max);
		while (rayQueryProceedEXT(rq)) {
		}
		if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
			break;
		}

		uint geometry_idx = rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true);
		uint prim_id = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
		vec2 cb = rayQueryGetIntersectionBarycentricsEXT(rq, true);
		float hit_t = rayQueryGetIntersectionTEXT(rq, true);

		GeometryData geom = geometries[geometry_idx];
		MaterialData mat = materials[geometry_idx];
		uint i0, i1, i2;
		get_triangle_indices_ex(geom, prim_id, i0, i1, i2);
		vec3 bary = vec3(1.0 - cb.x - cb.y, cb.x, cb.y);

		// GAP #22 (2026-09-13): THE DIELECTRIC SHARE BLOCKS THE SHADOW RAY.
		// This is Cycles' rule (surface_shader_transparency(): a shadow ray passes
		// a Transparent BSDF's extinction and nothing else). Until today pass B
		// let the ray through a refractive interface at transmission*(1-F),
		// which double-counted the sky with the refracted BSDF path -- the two
		// MIS strategies did not estimate the same integrand, because the
		// pass-through used smooth Fresnel while the lobe transmits with the
		// rough microfacet transmittance. Measured on the white glass furnace
		// as +2.4% / +7.3% / +8.6% at roughness 0.3 / 0.6 / 0.9 (roadmap
		// 11.14, 11.22). Light behind glass now arrives the way it does in
		// Cycles: through refracted bounce paths (BSDF sampling, MIS weight 1
		// for a near-delta lobe), never through a shadow ray -- so a delta lamp
		// cannot light the inside of a glass object, and glass casts a solid
		// shadow for its dielectric share. Only the Transparent-BSDF share of a
		// BLEND material, (1 - alpha), passes -- identical to Cycles' mix.
		//
		// A non-blend transmissive instance therefore zeroes atten at its first
		// crossing and the epsilon early-out below returns vec3(0.0): a full
		// occluder, exactly what pass A does for opaque geometry. Pass A cannot
		// do the job itself -- its RT_INSTANCE_MASK_OPAQUE cull never sees a
		// transmissive instance -- which is why pass B still runs for them.
		// RT_GET_TRANSMISSION_ENABLED() no longer enters here: on or off, the
		// dielectric share blocks, which is also what the BSDF draws with it off.
		//
		// The (1 - m_alpha) share is taken ONLY for BLEND materials: an
		// alpha-scissor material's base-colour alpha can sit below 1.0 while the
		// texel is meant to be fully solid, same reason the closure itself
		// branches on RT_MAT_FLAG_BLEND rather than on alpha directly
		// (raytracing_material_eval_inc.glsl:22). Fetch m_alpha with
		// ray_query_alpha_test's exact pattern (this file, above).
		vec2 uv = fetch_uv(geom, i0, i1, i2, bary);
		uv = uv * mat.uv1_scale + mat.uv1_offset;
		float m_alpha = texture(sampler2D(bindless_textures[nonuniformEXT(mat.albedo_texture_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv).a;
		m_alpha *= mat.albedo_color.a;
		float pass_through = ((mat.flags & RT_MAT_FLAG_BLEND) != 0u) ? (1.0 - m_alpha) : 0.0;
		atten *= pass_through;
		if (rt_max_component(atten) < RT_SHADOW_ATTEN_EPSILON) {
			return vec3(0.0);
		}

		// Scale-relative advance. A fixed epsilon is swallowed by float precision
		// at large t and the loop would re-hit the same pane until the cap.
		t_min = hit_t * (1.0 + 1e-4) + 1e-4;
	}

	// Cap reached with attenuation left: return what accumulated, so deep glass
	// dims rather than going black.
	return atten;
}

// ============================================================================
// Rectangle light sampling (uniform area, NEE)
// ============================================================================
vec3 lights_eval_rect_light(
		vec3 hit_pos,
		vec3 N,
		vec3 V,
		RTLightData light,
		vec2 u,
		float light_select_pdf,
		bool is_indirect_bounce,
		MaterialProperties material) {

	// 1. Sample random point on the quad
	vec3 axisU = light.spot_direction; // half-width vector
	vec3 axisV = vec3(light.rect_axis_v[0], light.rect_axis_v[1], light.rect_axis_v[2]); // half-height vector
	float su = u.x * 2.0 - 1.0; // [-1, 1]
	float sv = u.y * 2.0 - 1.0;
	vec3 sample_point = light.position + su * axisU + sv * axisV;

	// 2. Direction from shading point to sample point
	vec3 to_light = sample_point - hit_pos;
	float dist_sq = dot(to_light, to_light);
	float dist = sqrt(dist_sq);
	vec3 L = to_light / max(dist, 0.0001);

	// 3. Cosine of angle between shadow ray and light normal
	vec3 light_normal = normalize(cross(axisV, axisU)); // Emit along local -Z (Godot SpotLight forward)
	float cos_theta = dot(-L, light_normal);
	if (cos_theta <= 1e-5) {
		return vec3(0.0);
	}

	// 4. Check shading normal
	float NdotL = dot(N, L);
	if (NdotL <= 0.0) {
		return vec3(0.0);
	}

	// 5. Area and area-to-solid-angle PDF conversion
	float area = 4.0 * length(axisU) * length(axisV);
	float area_pdf = 1.0 / max(area, 1e-10);
	float solid_ang_pdf = area_pdf * dist_sq / cos_theta;

	// 6. Range check
	if (light.max_range_squared != 0.0 && dist_sq > light.max_range_squared) {
		return vec3(0.0);
	}

	// 7. Shadow ray
	vec3 shadow_atten = vec3(1.0);
	if (light.shadow_enabled > 0.5) {
		shadow_atten = lights_trace_shadow_ray(hit_pos, L, dist);
		if (rt_max_component(shadow_atten) <= 0.0) {
			return vec3(0.0);
		}
	}

	// 8. Attenuation (inverse-square + windowed)
	LightSample ls_atten;
	ls_atten.distance_sq = dist_sq;
	float atten = lights_get_attenuation(ls_atten, light.inv_max_range, light.attenuation);

	// 9. BRDF
	//
	// E2d fix round 1, THE ANALYTIC-LIGHT RULE (all three sites in this file --
	// rect here, positional and directional below -- follow it identically):
	//
	//   * The coat term IS added. Before this, NEE evaluated the unlayered base
	//     while BSDF sampling applied the coat's attenuation, so a coated surface
	//     lost its direct-light highlight and kept base light the coat should have
	//     absorbed. The base terms now arrive already attenuated, inside
	//     evalCombinedBRDFSeparate.
	//   * THE multiple-scattering factor IS applied (Gap #23, 2026-09-11), via
	//     evalMultiScatterFactorForMaterial -- the same dispatcher the env- and
	//     emissive-NEE sites use underneath. The earlier rule here said "no factor,
	//     because analytic lights have no second MIS strategy to agree with". That
	//     was correct about MIS and wrong about energy: with no second strategy,
	//     this value IS the render, and omitting Cycles' 1/E left every rough
	//     specular surface under the sun or a lamp short by exactly that factor --
	//     a white metal at roughness 0.9 under one directional light read 43% of
	//     Cycles, predicted to 0.1% by 1/E alone (pt_light_energy_gate.gd). The
	//     coat is NOT multiplied: its compensation (coatEnergyScale) already lives
	//     inside evalCoat, as at the other NEE sites.
	//   * NO RT_MIS_DELTA_ROUGHNESS guard, for the same reason -- these sites have
	//     never had one. The guard exists to hand delta lobes to the BSDF strategy
	//     outright; with no competing strategy here it would simply delete a
	//     mirror coat's direct highlight with nothing to collect it.
	//   * The coat DOES take spec_mul. That is Godot's per-light `specular` knob,
	//     an artistic scale on that light's specular response, and a clearcoat
	//     highlight is specular response from that light. Deriving a second
	//     multiplier from coatRoughness would make one light's knob behave
	//     differently for the coat than for the base with nothing to justify it.
	//   * E2e: the SHEEN term is added, and it does NOT take spec_mul. Godot's
	//     per-light `specular` knob scales that light's specular response, and
	//     sheen is not specular response -- Cycles labels the closure
	//     LABEL_DIFFUSE (bsdf_sheen.h:110) and the LTC is a near-cosine lobe. It
	//     rides with brdf_diffuse for the same reason brdf_diffuse does not take
	//     the knob either. No near-delta guard and no ms factor, per the rule
	//     above and because the Zeltner LTC is already a multiple-scattering fit.
	vec3 brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen;
	evalCombinedBRDFSeparate(N, L, V, material, brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen);
#if MICROFACET_DISTRIBUTION == GGX
	brdf_specular *= evalMultiScatterFactorForMaterial(N, V, material); // Gap #23
#endif
	float spec_mul = lights_get_specular_multiplier(light.specular_amount, material.roughness);
	vec3 brdf_value = brdf_diffuse + brdf_specular * spec_mul + brdf_coat * spec_mul + brdf_sheen;

	// 10. Combine — divide by solid angle pdf
	float indirect_mul = is_indirect_bounce ? light.indirect_energy : 1.0;
	vec3 radiance = light.emission / max(area, 1e-5);
	vec3 contribution = brdf_value * radiance * atten * indirect_mul;
	return contribution * shadow_atten / max(light_select_pdf * solid_ang_pdf, 1e-10);
}

// ============================================================================
// Next Event Estimation (NEE) - Direct Light Sampling
// ============================================================================

// Evaluate direct lighting using NEE with stochastic light selection.
// Production path: power-weighted CDF draw with an exact pdf (roadmap C2).
// RT_LIGHT_SELECT_UNIFORM=1 switches to the pre-C2 uniform mini-batch reservoir,
// kept as A/B measurement scaffolding.
vec3 lights_evaluate_direct_lighting(
		vec3 hit_pos,
		vec3 N,
		vec3 V,
		MaterialProperties material,
		RNGState p_rng,
		bool is_indirect_bounce,
		uint light_count) {
	if (light_count == 0u) {
		return vec3(0.0);
	}

#if RT_LIGHT_SELECT_UNIFORM
	// PRE-C2 CONTROL PATH. Uniform mini-batch reservoir. Its defect is VARIANCE,
	// not bias: with 41 lights and k=16 the brightest light is never even
	// considered at 67.4% of shading points ((40/41)^16), and every draw that does
	// find it is scaled up to compensate, so the estimator is heavy-tailed.
	// Measured at 9.8x-16.5x the equal-time RMSE of the production path below
	// (task-3 report).
	//
	// NOTE, corrected by measurement: light_select_pdf here is ESTIMATED rather
	// than known, and the design spec expected that to BIAS the converged image
	// whenever range culling rejected anything. It does not, and the culled gate
	// showed no shift. This estimator is EXACTLY UNBIASED, culling or not:
	//
	//   * it MULTIPLIES the contribution by valid_count_estimate = N*m/k
	//     (contribution / pdf), never by its reciprocal, so Jensen never enters;
	//   * given valid_found = m > 0 the reservoir's pick is uniform over the VALID
	//     lights, and that conditional law does not depend on m, so
	//     E[f(L_sel) | m] = mean(f over valid) for every m > 0;
	//   * the m == 0 early-out below does NOT bias it either. The estimator's
	//     value is f(L_sel) * N*m/k, which is 0 when m == 0, so
	//     m * 1{m >= 1} == m identically and E[N*m/k] = V with no dropout term.
	//
	//   => E[estimator] = mean(f over valid) * V = sum over valid f, exactly.
	//
	// Kept only to A/B the change.
	const uint k = uint(min(RT_LIGHT_RESERVOIR_SIZE, int(light_count)));
	uint valid_found = 0u;
	uint selected_idx = 0u;

	uint reservoir_stream = rng_side_stream(p_rng, RT_PRNG_LIGHT_SELECT);
	for (uint i = 0u; i < k; i++) {
		uint idx = min(uint(rand(reservoir_stream) * float(light_count)), light_count - 1u);
		RTLightData test_light = rt_lights[idx];

		bool is_positional = (test_light.type == RT_LIGHT_TYPE_OMNI || test_light.type == RT_LIGHT_TYPE_SPOT || test_light.type == RT_LIGHT_TYPE_RECT);
		bool is_valid = !is_positional;
		if (!is_valid) {
			vec3 to_l = test_light.position - hit_pos;
			float d2 = dot(to_l, to_l);
			is_valid = (test_light.max_range_squared == 0.0 || d2 <= test_light.max_range_squared);
		}

		if (is_valid) {
			valid_found++;
			if (rand(reservoir_stream) < 1.0 / float(valid_found)) {
				selected_idx = idx;
			}
		}
	}

	if (valid_found == 0u) {
		return vec3(0.0);
	}

	float valid_count_estimate = float(light_count) * (float(valid_found) / float(k));
	float light_select_pdf = 1.0 / max(valid_count_estimate, 1.0);
#else
	// Power-weighted CDF (roadmap C2). One Sobol draw, exact pdf.
	uint selected_idx;
	float light_select_pdf;
	if (!lights_select(hit_pos, light_count, is_indirect_bounce,
				rng_1d(p_rng, RT_PRNG_LIGHT_SELECT), selected_idx, light_select_pdf)) {
		// Every light weighs zero, so every light contributes zero.
		return vec3(0.0);
	}
#endif

	RTLightData light = rt_lights[selected_idx];
	vec2 u = rng_2d(p_rng, RT_PRNG_LIGHT);

	// === POSITIONAL LIGHT PATH (omni + spot) ===
	if (light.type == RT_LIGHT_TYPE_OMNI || light.type == RT_LIGHT_TYPE_SPOT) {
		vec3 to_light = light.position - hit_pos;
		float dist_sq = dot(to_light, to_light);

		// Early out: outside max range.
		if (light.max_range_squared != 0.0 && dist_sq > light.max_range_squared) {
			return vec3(0.0);
		}

		float dist = sqrt(dist_sq);
		vec3 L;
		float shadow_dist;

		if (light.radius <= 0.01) {
			// True point light: exact direction.
			L = to_light / max(dist, 0.0001);
			shadow_dist = dist;
		} else {
			// Sphere light: cone sampling for soft shadows.
			LightSample ls = lights_prepare_sample(hit_pos, light);
			float light_pdf;
			L = lights_sample_cone(ls, u, light_pdf);
			float t_center = dot(to_light, L);
			vec3 perp = to_light - t_center * L;
			float perp_sq = dot(perp, perp);
			float dt = sqrt(max(0.0, light.radius * light.radius - perp_sq));
			shadow_dist = max(0.0, t_center - dt);
		}

		// Spot cone early-out.
		float spot_atten = 1.0;
		if (light.type == RT_LIGHT_TYPE_SPOT) {
			float scos = dot(-L, light.spot_direction);
			if (scos <= light.cos_spot_angle) {
				return vec3(0.0);
			}
			float spot_rim = max(1e-4, (1.0 - scos) / (1.0 - light.cos_spot_angle));
			spot_atten = 1.0 - pow(spot_rim, light.inv_spot_attenuation);
		}

		// Below-horizon early-out, BEFORE the shadow ray. evalCombinedBRDFSeparate
		// rejects on data.Lbackfacing, which is defined as exactly `NdotL <= 0.0`
		// (prepareBRDFData in brdf_inc.glsl), and returns (0,0,0) for BOTH lobes --
		// so this branch and the full path already produce an identical vec3(0.0).
		// The only difference is that the full path pays a complete BVH traversal
		// first. This is one dot product.
		//
		// The RECT and DIRECTIONAL branches of this function already gate this way;
		// only the positional branch traced first and asked afterwards. On a diffuse
		// surface roughly half of all selected directions land below the horizon, so
		// this removes about half the shadow rays outright.
		//
		// C2 is what made this worth doing. Uniform selection mostly picked the many
		// cheap shadowless fill lights, so few samples reached a traversal at all;
		// power-weighted selection concentrates on the few bright lights, which in a
		// typical interior are exactly the ones with shadow_enabled = true.
		if (dot(N, L) <= 0.0) {
			return vec3(0.0);
		}

		// Shadow test — skipped entirely when shadow_enabled == 0.0 (shadowless fill light).
		// This matches Blender Cycles behaviour: light contributes full radiance with
		// no occlusion ray, casting no shadows while still illuminating the scene.
		vec3 shadow_atten = vec3(1.0);
		if (light.shadow_enabled > 0.5) {
			shadow_atten = lights_trace_shadow_ray(hit_pos, L, shadow_dist);
			if (rt_max_component(shadow_atten) <= 0.0) {
				return vec3(0.0);
			}
		}

		// Evaluate BRDF (diffuse + specular + coat separately for specular_amount
		// control). E2d fix round 1: see THE ANALYTIC-LIGHT RULE in
		// lights_eval_rect_light above for why the coat is added plainly here, with
		// no multiple-scatter factor and no near-delta guard.
		vec3 brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen;
		evalCombinedBRDFSeparate(N, L, V, material, brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen);
#if MICROFACET_DISTRIBUTION == GGX
		brdf_specular *= evalMultiScatterFactorForMaterial(N, V, material); // Gap #23
#endif

		// Distance attenuation.
		LightSample ls_atten;
		ls_atten.distance_sq = dist_sq;
		float atten = lights_get_attenuation(ls_atten, light.inv_max_range, light.attenuation) * spot_atten;

		float spec_mul = lights_get_specular_multiplier(light.specular_amount, material.roughness);
		vec3 brdf_value = brdf_diffuse + brdf_specular * spec_mul + brdf_coat * spec_mul + brdf_sheen;

		float indirect_mul = is_indirect_bounce ? light.indirect_energy : 1.0;

		// Apply IES photometric profile modulation. The profile is evaluated in
		// the light's local frame, so rotating the light aims the beam exactly as
		// it would a real fixture.
		float ies_factor = 1.0;
		if (light.ies_slot >= 0) {
			vec3 ies_dir = lights_world_to_light_local(light, hit_pos - light.position);
			ies_factor = ies_lookup(light.ies_slot, ies_dir) * light.ies_strength;
		}

		// NdotL is already included in brdf_value (evalLambertian/evalMicrofacet bake it in).
		vec3 contribution = brdf_value * light.emission * atten * indirect_mul * ies_factor;
		return contribution * shadow_atten / max(light_select_pdf, 1e-10);
	}
	// === RECT LIGHT PATH ===
	else if (light.type == RT_LIGHT_TYPE_RECT) {
		return lights_eval_rect_light(
				hit_pos, N, V, light, u,
				light_select_pdf, is_indirect_bounce, material);
	}
	// === CONE LIGHT PATH (directional) ===
	else {
		LightSample ls = lights_prepare_sample(hit_pos, light);
		float light_pdf;
		vec3 L = lights_sample_cone(ls, u, light_pdf);

		float NdotL = dot(N, L);
		if (NdotL <= 0.0) {
			return vec3(0.0);
		}

		// Shadow test for directional light — skipped when shadow_enabled == 0.0.
		vec3 shadow_atten = vec3(1.0);
		if (light.shadow_enabled > 0.5) {
			shadow_atten = lights_trace_shadow_ray(hit_pos, L, ls.max_distance);
			if (rt_max_component(shadow_atten) <= 0.0) {
				return vec3(0.0);
			}
		}

		// E2d fix round 1: see THE ANALYTIC-LIGHT RULE in lights_eval_rect_light.
		vec3 brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen;
		evalCombinedBRDFSeparate(N, L, V, material, brdf_diffuse, brdf_specular, brdf_coat, brdf_sheen);
#if MICROFACET_DISTRIBUTION == GGX
		brdf_specular *= evalMultiScatterFactorForMaterial(N, V, material); // Gap #23
#endif

		float spec_mul = lights_get_specular_multiplier(light.specular_amount, material.roughness);
		vec3 brdf_value = brdf_diffuse + brdf_specular * spec_mul + brdf_coat * spec_mul + brdf_sheen;

		float indirect_mul = is_indirect_bounce ? light.indirect_energy : 1.0;

		// No IES modulation here: a photometric distribution has no meaning for a
		// light at infinite distance, so gather_lights() forces ies_slot = -1 for
		// every directional light (render_raytracing.cpp).
		return brdf_value * light.emission * indirect_mul * shadow_atten / max(light_select_pdf, 1e-10);
	}
}
