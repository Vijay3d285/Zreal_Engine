// Common closest_hit utilities shared by all hit groups.
//
// Required includes (before this file):
//   raytracing_inc.glsl, brdf_inc.glsl, raytracing_hit_inc.glsl, raytracing_lights_inc.glsl,
//   raytracing_material_eval_inc.glsl
//
// Required bindings (before this file):
//   tlas, payload, scene_data_block, geometries[], motion_indices[], materials[], motion_transforms[], bindless_textures[],
//   SAMPLER_* (12 material samplers), rt_params, rt_depth_image,
//   DLSS-RR images (ifdef DLSS_RR_ENABLED)

// ============================================================================
// HIT DATA
// ============================================================================

struct HitData {
	vec3 hit_pos;
	vec3 geometry_normal; // World space, flipped for back-face hits.
	vec3 tangent; // World space.
	vec3 bitangent; // World space.
	vec2 uv; // Raw UV (no material scale/offset applied).
	vec4 color; // Vertex color (white if not present).
	bool is_front_face;
	uint geometry_idx;
};

/// Fetch vertex attributes and transform to world space.
/// Requires hitAttributeEXT HitAttribs and GeometryBuffer/MaterialBuffer bindings.
HitData compute_hit_data() {
	HitData h;
	h.geometry_idx = gl_InstanceCustomIndexEXT;
	GeometryData geom = geometries[h.geometry_idx];

	// Custom hit groups may reference vertex color in their fragment code, so
	// pull all attributes; default HGs can skip color for perf.
#ifdef RT_CUSTOM_HIT_GROUP
	VertexAttributes attrs = fetch_vertex_attributes(geom, attribs, FETCH_ALL);
#else
	VertexAttributes attrs = fetch_vertex_attributes(geom, attribs, FETCH_UV | FETCH_TBN);
#endif
	h.uv = attrs.uv;
	h.color = attrs.color;

	mat3 model_rotation = mat3(gl_ObjectToWorldEXT);
	mat3 normal_matrix = mat3(
			normalize(model_rotation[0]),
			normalize(model_rotation[1]),
			normalize(model_rotation[2]));

#ifdef ENABLE_INTERSECTION_SHADERS
	if ((geom.flags & FLAG_PROCEDURAL) != 0u) {
		h.uv = hit_attribs.bary_or_uv;
		vec3 obj_normal = normalize(unpackSnorm4x8(hit_attribs.packed_normal).xyz);
		vec3 obj_tangent = normalize(unpackSnorm4x8(hit_attribs.packed_tangent).xyz);
		h.geometry_normal = normalize(normal_matrix * obj_normal);
		h.tangent = normalize(normal_matrix * obj_tangent);
		h.bitangent = cross(h.geometry_normal, h.tangent);

		h.is_front_face = (dot(h.geometry_normal, -gl_WorldRayDirectionEXT) > 0.0);
		if (!h.is_front_face) {
			h.geometry_normal = -h.geometry_normal;
		}
	} else
#endif
	{
		// Triangle hit: reuse `attrs` from the top-level fetch (already has
		// UV / TBN from FETCH_UV | FETCH_TBN or FETCH_ALL).
		h.geometry_normal = normalize(normal_matrix * attrs.normal);
		h.tangent = normalize(normal_matrix * attrs.tangent);
		h.bitangent = cross(h.geometry_normal, h.tangent) * attrs.bitangent_sign;

		h.is_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
		if (!h.is_front_face) {
			h.geometry_normal = -h.geometry_normal;
		}
	}

	h.hit_pos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;

	return h;
}

// ============================================================================
// HELPERS
// ============================================================================

vec4 sample_bindless_texture(uint tex_idx, vec2 uv) {
	return texture(sampler2D(bindless_textures[nonuniformEXT(tex_idx)], SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT), uv);
}

/// Sample with point/nearest filtering (for pixel art textures).
vec4 sample_bindless_texture_point(uint tex_idx, vec2 uv) {
	return texture(sampler2D(bindless_textures[nonuniformEXT(tex_idx)], SAMPLER_NEAREST_REPEAT), uv);
}

/// Sample with the appropriate filter based on material flags (bit 2 = point filtering).
vec4 sample_material_texture(uint tex_idx, vec2 uv, uint mat_flags) {
	if ((mat_flags & 4u) != 0u) {
		return sample_bindless_texture_point(tex_idx, uv);
	}
	return sample_bindless_texture(tex_idx, uv);
}

/// Apply tangent-space normal map to geometry normal.
vec3 apply_normal_map(HitData h, vec3 tangent_space_normal, float normal_map_depth) {
	vec3 mapped = h.tangent * tangent_space_normal.x + h.bitangent * tangent_space_normal.y + h.geometry_normal * tangent_space_normal.z;
	return normalize(mix(h.geometry_normal, mapped, normal_map_depth));
}

// ============================================================================
// DEPTH WRITE (primary ray only)
// ============================================================================

/// Write NDC depth for primary ray hits (bounce 0, sample 0 only).
void write_primary_hit_depth(vec3 hit_pos) {
	if (get_total_bounces(payload.packed_bounces_flags) == 0u && is_sample_zero(payload.packed_bounces_flags)) {
		mat4 view_mat = transpose(mat4(scene_data_block.data.view_matrix[0],
				scene_data_block.data.view_matrix[1],
				scene_data_block.data.view_matrix[2],
				vec4(0.0, 0.0, 0.0, 1.0)));
		vec3 view_pos = (view_mat * vec4(hit_pos, 1.0)).xyz;
		vec4 clip_pos = scene_data_block.data.projection_matrix * vec4(view_pos, 1.0);
		float ndc_depth = clip_pos.z / clip_pos.w;
		imageStore(rt_depth_image, ivec2(gl_LaunchIDEXT.xy), vec4(ndc_depth));
	}
}

// ============================================================================
// VELOCITY WRITE (primary ray only, MV-gated)
// ============================================================================

#ifdef ENABLE_INTERSECTION_SHADERS
/// Decode the FP16-compressed PREV_POSITION delta from HitAttribs.
vec3 decode_prev_pos_delta() {
	uint dx_low = (hit_attribs.packed_normal >> 24u) & 0xFFu;
	uint dx_high = (hit_attribs.packed_tangent >> 24u) & 0xFFu;
	float delta_x = unpackHalf2x16(dx_low | (dx_high << 8u)).x;
	vec2 delta_yz = unpackHalf2x16(hit_attribs.prev_pos_delta_yz);
	return vec3(delta_x, delta_yz.x, delta_yz.y);
}
#endif

/// Reconstruct previous-frame mat4 from a compact motion transform entry.
mat4 decode_prev_object_to_world(int motion_idx) {
	InstanceMotionData m = motion_transforms[motion_idx];
	return transpose(mat4(
			vec4(m.prev_xform[0], m.prev_xform[1], m.prev_xform[2], m.prev_xform[3]),
			vec4(m.prev_xform[4], m.prev_xform[5], m.prev_xform[6], m.prev_xform[7]),
			vec4(m.prev_xform[8], m.prev_xform[9], m.prev_xform[10], m.prev_xform[11]),
			vec4(0.0, 0.0, 0.0, 1.0)));
}

/// Write motion vectors for primary ray hits (bounce 0, sample 0 only).
/// Uses unjittered VP matrices matching the raster motion_vectors_store convention.
void write_primary_hit_velocity(vec3 hit_pos) {
	if (get_total_bounces(payload.packed_bounces_flags) != 0u || !is_sample_zero(payload.packed_bounces_flags)) {
		return;
	}

	uint geom_idx = gl_InstanceCustomIndexEXT;
	int mi = motion_indices[geom_idx];

	// Resolve previous-frame model matrix: compact entry if moved, current transform otherwise.
	mat4 prev_model = (mi >= 0) ? decode_prev_object_to_world(mi) : mat4(gl_ObjectToWorldEXT);

	vec3 obj_pos = (mat4(gl_WorldToObjectEXT) * vec4(hit_pos, 1.0)).xyz;
	vec3 prev_obj_pos = obj_pos;

	GeometryData geom = geometries[geom_idx];

#ifdef ENABLE_INTERSECTION_SHADERS
	if ((geom.flags & FLAG_PROCEDURAL) != 0u) {
		prev_obj_pos += decode_prev_pos_delta();
	}
#endif

#ifdef RT_HIT_ATTRIBS_DECLARED
	if ((geom.flags & FLAG_DEFORMED) != 0u) {
		uint64_t prev_addr = packUint2x32(uvec2(geom.prev_vertex_address_lo, geom.prev_vertex_address_hi));
		if (prev_addr != 0ul) {
			uint i0, i1, i2;
			get_triangle_indices(geom, i0, i1, i2);
			vec3 bary = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
			FloatBuffer prev_vb = FloatBuffer(prev_addr);
			uint stride_floats = geom.position_stride >> 2;
			vec3 p0 = vec3(prev_vb.v[i0 * stride_floats + 0u],
					prev_vb.v[i0 * stride_floats + 1u],
					prev_vb.v[i0 * stride_floats + 2u]);
			vec3 p1 = vec3(prev_vb.v[i1 * stride_floats + 0u],
					prev_vb.v[i1 * stride_floats + 1u],
					prev_vb.v[i1 * stride_floats + 2u]);
			vec3 p2 = vec3(prev_vb.v[i2 * stride_floats + 0u],
					prev_vb.v[i2 * stride_floats + 1u],
					prev_vb.v[i2 * stride_floats + 2u]);
			prev_obj_pos = bary.x * p0 + bary.y * p1 + bary.z * p2;
		}
	}
#endif

	vec3 prev_world_pos = (prev_model * vec4(prev_obj_pos, 1.0)).xyz;

	vec2 curr_uv = project_uv(hit_pos, curr_vp_unjittered);
	vec2 prev_uv = project_uv(prev_world_pos, prev_vp_unjittered);

	imageStore(rt_velocity_image, ivec2(gl_LaunchIDEXT.xy), vec4(prev_uv - curr_uv, 0.0, 0.0));
}

// ============================================================================
// ENVIRONMENT FOG (per ray segment)
// ============================================================================

vec3 fog_get_directional_color(uint index) {
	return rt_lights[index].emission;
}

vec3 fog_get_directional_direction(uint index) {
	vec3 world_dir = -normalize(rt_lights[index].position);
	mat3 view_rot = transpose(mat3(
			scene_data_block.data.view_matrix[0].xyz,
			scene_data_block.data.view_matrix[1].xyz,
			scene_data_block.data.view_matrix[2].xyz));
	return view_rot * world_dir;
}

#define FOG_HAS_RADIANCE

vec3 fog_sample_radiance(vec3 vertex, float mip_level) {
	vec3 cube_view = scene_data_block.data.radiance_inverse_xform * vertex;
	float roughness_lod = mip_level * MAX_ROUGHNESS_LOD;
	vec2 border = vec2(scene_data_block.data.radiance_border_size,
			1.0 - scene_data_block.data.radiance_border_size * 2.0);
	vec2 cube_uv = vec3_to_oct_with_border(cube_view, border);
	return textureLod(sampler2D(radiance_octmap, radiance_sampler), cube_uv, roughness_lod).rgb;
}

#include "../fog_inc.glsl"

/// Apply environment fog for the ray segment that was just traversed.
/// Attenuates throughput and adds in-scattered fog color.
void apply_segment_fog(float segment_dist, inout vec3 radiance, inout vec3 throughput) {
	if ((RT_FLAGS & RT_FLAG_FOG_ENABLED) == 0u) {
		return;
	}

	// Build a view-space vertex along the ray direction at the hit distance.
	// fog_process needs view-space position for distance and height calculations.
	mat4 view_mat = transpose(mat4(
			scene_data_block.data.view_matrix[0],
			scene_data_block.data.view_matrix[1],
			scene_data_block.data.view_matrix[2],
			vec4(0.0, 0.0, 0.0, 1.0)));
	vec3 world_hit = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * segment_dist;
	vec3 vertex = (view_mat * vec4(world_hit, 1.0)).xyz;

	vec4 fog = fog_process(scene_data_block.data, vertex);
	radiance += throughput * fog.rgb * fog.a;
	throughput *= (1.0 - fog.a);
}

/// Converts specular parameter [0..1] to dielectric F0.
float specular_to_f0(float specular) {
	return 0.16 * specular * specular;
}

// ============================================================================
// ENVIRONMENT RADIANCE (must match the miss stage exactly)
// ============================================================================

/// Sky radiance arriving from a WORLD-space direction, computed exactly the way
/// the miss stage computes it (scene_raytracing_raygen.glsl, `sky_color` block).
///
/// MIS combines two estimators of ONE integral. If this function and the miss
/// stage disagreed about L_env for the same direction, the two weighted halves
/// would stop summing to the true contribution and the image would gain or lose
/// energy with nothing to flag it -- the weights would still sum to 1, they would
/// just be multiplying different numbers. So every step is mirrored:
///   - the world -> sky rotation via the shared env_world_to_sky(), NOT a
///     locally rebuilt matrix;
///   - vec3_to_oct_with_border() against `radiance_border_size`. `sky->radiance`
///     is a PADDED octmap; the unbordered vec3_to_oct() misses by up to ~14
///     degrees near a sun (that is the defect fixed in 5b89e45501 for the CDF
///     build, and every other octmap consumer in the engine uses the bordered
///     mapping);
///   - IBL_exposure_normalization;
///   - the fog sky-affect mix, which is a pure function of the direction here and
///     therefore reproduces the miss stage's value identically.
vec3 env_sky_radiance(vec3 p_world_dir) {
	vec2 border = vec2(scene_data_block.data.radiance_border_size,
			1.0 - scene_data_block.data.radiance_border_size * 2.0);
	vec2 sky_uv = vec3_to_oct_with_border(env_world_to_sky() * p_world_dir, border);

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

	return sky_color;
}

// ============================================================================
// DEBUG VISUALIZATION
// ============================================================================

#ifdef RT_DEBUG_ENABLED
void debug_visualize(
		int vis_mode,
		vec3 geometry_normal,
		vec3 final_normal,
		vec3 tangent_space_normal,
		vec3 world_tangent,
		vec3 world_bitangent,
		vec2 uv,
		vec3 albedo,
		vec3 orm,
		float metalness,
		float roughness,
		float specular,
		vec3 emissive,
		vec3 V,
		float NdotV) {
	PathState ps = path_unpack(payload);

	if (vis_mode == 1) {
		if (get_total_bounces(ps.packed_bounces_flags) == 0u) {
			ps.packed_bounces_flags = inc_total_bounce(ps.packed_bounces_flags);
			ps.hit_t = gl_HitTEXT;
			ps.offset_normal = geometry_normal;
			ps.next_ray_dir = reflect(gl_WorldRayDirectionEXT, geometry_normal);
			path_pack(payload, ps);
			return;
		} else {
			ps.radiance = geometry_normal * 0.5 + 0.5;
		}
	} else if (vis_mode == 2) {
		ps.radiance = geometry_normal * 0.5 + 0.5;
	} else if (vis_mode == 3) {
		ps.radiance = final_normal * 0.5 + 0.5;
	} else if (vis_mode == 4) {
		ps.radiance = tangent_space_normal * 0.5 + 0.5;
	} else if (vis_mode == 5) {
		ps.radiance = world_tangent * 0.5 + 0.5;
	} else if (vis_mode == 6) {
		ps.radiance = world_bitangent * 0.5 + 0.5;
	} else if (vis_mode == 7) {
		ps.radiance = vec3(fract(uv), 0.0);
	} else if (vis_mode == 8) {
		ps.radiance = albedo;
	} else if (vis_mode == 9) {
		ps.radiance = orm;
	} else if (vis_mode == 10) {
		ps.radiance = DLSSRR_computeDiffuseAlbedo(albedo, metalness);
	} else if (vis_mode == 11) {
		ps.radiance = DLSSRR_computeSpecularAlbedo(albedo, metalness, specular_to_f0(specular), roughness, NdotV);
	} else if (vis_mode == 12) {
		ps.radiance = (final_normal * 0.5 + 0.5) * (1.0 - roughness * 0.5);
	} else if (vis_mode == 13) {
		if (get_total_bounces(ps.packed_bounces_flags) == 0u) {
			if (roughness < MAX_DENOISER_SPECULAR_HIT_THRESHOLD) {
				ps.packed_bounces_flags = inc_total_bounce(ps.packed_bounces_flags);
				ps.radiance = vec3(0.1, 0.1, 0.4);
				ps.hit_t = gl_HitTEXT;
				ps.offset_normal = final_normal;
				ps.next_ray_dir = reflect(gl_WorldRayDirectionEXT, final_normal);
				path_pack(payload, ps);
				return;
			} else {
				ps.radiance = vec3(0.1, 0.1, 0.4);
			}
		} else {
			float spec_hit_t = gl_HitTEXT;
			float v = clamp(log(spec_hit_t + 1.0) / log(1000.0), 0.0, 1.0);
			vec3 color;
			if (v < 0.33) {
				color = mix(vec3(0.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0), v * 3.0);
			} else if (v < 0.66) {
				color = mix(vec3(1.0, 0.0, 0.0), vec3(1.0, 1.0, 0.0), (v - 0.33) * 3.0);
			} else {
				color = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 1.0, 1.0), (v - 0.66) * 3.0);
			}
			ps.radiance = color;
		}
	} else if (vis_mode == 14) {
		ps.radiance = vec3(metalness);
	} else if (vis_mode == 15) {
		ps.radiance = vec3(roughness);
	} else if (vis_mode == 16) {
		mat3 world_to_view = mat3(scene_data_block.data.inv_view_matrix);
		ps.radiance = normalize(world_to_view * final_normal) * 0.5 + 0.5;
	} else if (vis_mode == 17) {
		vec3 diffuse_albedo = DLSSRR_computeDiffuseAlbedo(albedo, metalness);
		vec3 specular_albedo = DLSSRR_computeSpecularAlbedo(albedo, metalness, specular_to_f0(specular), roughness, NdotV);
		ps.radiance = mix(diffuse_albedo, specular_albedo, metalness);
	} else if (vis_mode == 18) {
		ps.radiance = baseColorToSpecularF0(albedo, metalness, specular_to_f0(specular));
	} else if (vis_mode == 19) {
		bool is_front_face = (gl_HitKindEXT == gl_HitKindFrontFacingTriangleEXT);
		ps.radiance = is_front_face ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	} else if (vis_mode == 20) {
		float depth_range = scene_data_block.data.z_far - scene_data_block.data.z_near;
		float d = clamp(gl_HitTEXT / depth_range, 0.0, 1.0);
		ps.radiance = vec3(d);
	} else if (vis_mode == 21) {
		ps.radiance = emissive;
	} else if (vis_mode == 22) {
		// BRDF below-hemisphere fallback visualization. Reflects the two-layer
		// recovery applied in shade_and_bounce:
		//   Layer 1 - shading-normal clamp toward geometry (energy preserving
		//             but flattens detail at grazing angles)
		//   Layer 2 - mirror rejected directions across the geometry plane
		//             (biased; reuses the rejected sample's BRDF weight)
		//
		// We sample both BRDF lobes once with the un-clamped shading normal
		// and once with the clamped shading normal, reusing the same random
		// pair so the two passes are directly comparable.
		//
		// Color legend (ordered cleanest -> most biased):
		//   green   = no rejection in either pass (no fallback needed)
		//   blue    = clamp alone resolves rejection (energy preserving)
		//   yellow  = clamp + mirror (one lobe still mirrored after clamp)
		//   red     = clamp + mirror (both lobes mirrored - most biased pixel)
		//
		// Production output is never black anymore -- yellow/red just indicate
		// where the cheaper Layer-1 clamp could not catch the bump and the
		// biased Layer-2 mirror had to step in. Raise
		// RT_SHADING_NORMAL_CLAMP_THRESHOLD if yellow/red dominate.
		MaterialProperties dbg_mat;
		dbg_mat.baseColor = albedo;
		dbg_mat.metalness = metalness;
		dbg_mat.roughness = roughness;
		dbg_mat.dielectricF0 = specular_to_f0(specular);
		dbg_mat.emissive = vec3(0.0);
		dbg_mat.transmissivness = 0.0;
		dbg_mat.opacity = 1.0;

		vec3 dbg_dir;
		vec3 dbg_weight;
		// Draw both random pairs up front so each (specular/diffuse) test in
		// the un-clamped and clamped pass uses the exact same numbers.
		RNGState dbg_rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		vec2 u_spec_rng = rng_2d(dbg_rng, RT_PRNG_SURFACE_BSDF);
		vec2 u_diff_rng = rng_2d(dbg_rng, RT_PRNG_LIGHT);

		bool u_spec_ok = evalIndirectCombinedBRDF(u_spec_rng, final_normal, geometry_normal, V, dbg_mat, SPECULAR_TYPE, dbg_dir, dbg_weight, vec4(0.0));
		bool u_diff_ok = evalIndirectCombinedBRDF(u_diff_rng, final_normal, geometry_normal, V, dbg_mat, DIFFUSE_TYPE, dbg_dir, dbg_weight, vec4(0.0));

		// Uses the same threshold as shade_and_bounce so the visualization
		// stays in sync with production sampling.
		vec3 N_clamped = clampShadingNormal(final_normal, geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);
		bool c_spec_ok = evalIndirectCombinedBRDF(u_spec_rng, N_clamped, geometry_normal, V, dbg_mat, SPECULAR_TYPE, dbg_dir, dbg_weight, vec4(0.0));
		bool c_diff_ok = evalIndirectCombinedBRDF(u_diff_rng, N_clamped, geometry_normal, V, dbg_mat, DIFFUSE_TYPE, dbg_dir, dbg_weight, vec4(0.0));

		bool all_uncl_ok = u_spec_ok && u_diff_ok;
		bool all_cl_ok = c_spec_ok && c_diff_ok;
		bool any_cl_ok = c_spec_ok || c_diff_ok;

		if (all_uncl_ok) {
			ps.radiance = vec3(0.0, 1.0, 0.0);
		} else if (all_cl_ok) {
			ps.radiance = vec3(0.0, 0.4, 1.0);
		} else if (any_cl_ok) {
			ps.radiance = vec3(1.0, 1.0, 0.0);
		} else {
			ps.radiance = vec3(1.0, 0.0, 0.0);
		}
	}

	ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
	path_pack(payload, ps);
}
#endif // RT_DEBUG_ENABLED

// ============================================================================
// SHADE AND BOUNCE
// ============================================================================

/// Production shading: emissive + NEE direct lighting + BRDF importance sampling + next bounce.
/// Also handles DLSS-RR G-buffer output on primary ray.
void shade_and_bounce(HitData h, MaterialResult m) {
	PathState ps = path_unpack(payload);
	RNGState rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);

	vec3 V = -gl_WorldRayDirectionEXT;

	// Clamp shading normal toward geometry at grazing view angles to keep BRDF above the geometry hemisphere.
	vec3 N = clampShadingNormal(m.normal, h.geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);
	float NdotV = max(dot(N, V), 0.0001);

	uint total_bounces = get_total_bounces(ps.packed_bounces_flags);
	uint diffuse_bounces = get_diffuse_bounces(ps.packed_bounces_flags);
	uint glossy_bounces = get_glossy_bounces(ps.packed_bounces_flags);

	// Environment fog for this ray segment (before surface contribution).
	apply_segment_fog(gl_HitTEXT, ps.radiance, ps.throughput);

	// Emissive contribution.
	float clamp_limit = (total_bounces == 0u)
			? get_rt_param(RT_PARAM_CLAMP_DIRECT)
			: get_rt_param(RT_PARAM_CLAMP_INDIRECT);
	ps.radiance += clamp_contribution(ps.throughput * m.emissive, clamp_limit);

	// Per-lobe limits, matching Cycles: a path stops when the lobe it has been
	// taking exceeds its own cap, not when every budget is exhausted
	// (kernel/integrator/path_state.h:183, :190). This is what replaces the old
	// hardcoded 2-diffuse-bounce ceiling that flattened interior GI.
	const uint max_total = RT_GET_MAX_BOUNCES();
	const uint max_diffuse = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_DIFFUSE_BOUNCE), max_total);
	const uint max_glossy = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_GLOSSY_BOUNCE), max_total);
	if (total_bounces >= max_total || diffuse_bounces >= max_diffuse || glossy_bounces >= max_glossy) {
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
	}

	// BRDF material setup.
	MaterialProperties brdf_mat;
	brdf_mat.baseColor = m.albedo;
	brdf_mat.metalness = m.metalness;
	brdf_mat.roughness = m.roughness;
	brdf_mat.dielectricF0 = specular_to_f0(m.specular);
	brdf_mat.emissive = m.emissive;
	brdf_mat.transmissivness = 0.0;
	brdf_mat.opacity = 1.0;

	vec3 specularF0 = baseColorToSpecularF0(brdf_mat.baseColor, brdf_mat.metalness, brdf_mat.dielectricF0);
	vec3 diffuseReflectance = baseColorToDiffuseReflectance(brdf_mat.baseColor, brdf_mat.metalness);

	// =================================================================
	// DLSS Ray Reconstruction output (primary ray, sample 0 only)
	// =================================================================
#ifdef DLSS_RR_ENABLED
	if (total_bounces == 0u && is_sample_zero(ps.packed_bounces_flags)) {
		ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);

		vec3 diffuse_albedo = DLSSRR_computeDiffuseAlbedo(m.albedo, m.metalness);
		imageStore(dlss_rr_diffuse_albedo, pixel, vec4(diffuse_albedo, 1.0));

		vec3 specular_albedo = DLSSRR_computeSpecularAlbedo(m.albedo, m.metalness, brdf_mat.dielectricF0, m.roughness, NdotV);
		imageStore(dlss_rr_specular_albedo, pixel, vec4(clamp(specular_albedo, vec3(0.0), vec3(1.0)), 1.0)); // match UNORM8 like before - fixes some issues with garbling..

		imageStore(dlss_rr_normal_roughness, pixel, vec4(N, m.roughness));

		// Specular hit distance via inline ray query (only for smooth surfaces).
		float spec_hit_dist = -1.0;
		if (m.roughness < MAX_DENOISER_SPECULAR_HIT_THRESHOLD) {
			vec3 spec_dir = reflect(-V, N);
			vec3 spec_origin = offset_ray_origin(h.hit_pos, spec_dir);

			rayQueryEXT spec_rq;
			rayQueryInitializeEXT(spec_rq, tlas, RT_RAY_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT,
					0xFF, spec_origin, 0.001, spec_dir, 10000.0);
			while (rayQueryProceedEXT(spec_rq)) {
				if (rayQueryGetIntersectionTypeEXT(spec_rq, false) == gl_RayQueryCandidateIntersectionTriangleEXT) {
					if (ray_query_alpha_test(
								rayQueryGetIntersectionInstanceCustomIndexEXT(spec_rq, false),
								rayQueryGetIntersectionPrimitiveIndexEXT(spec_rq, false),
								rayQueryGetIntersectionBarycentricsEXT(spec_rq, false))) {
						rayQueryConfirmIntersectionEXT(spec_rq);
					}
				}
			}
			if (rayQueryGetIntersectionTypeEXT(spec_rq, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
				spec_hit_dist = rayQueryGetIntersectionTEXT(spec_rq, true);
			}
		}
		imageStore(dlss_rr_specular_hit_dist, pixel, vec4(spec_hit_dist));
	}
#endif

	// =================================================================
	// NEE: Next Event Estimation (direct light sampling)
	// =================================================================
	path_pack(payload, ps);

	uint rt_light_count = uint(get_rt_param(RT_PARAM_LIGHT_COUNT));
	if (rt_light_count > 0u) {
		vec3 hit_pos_offset = offset_ray_origin(h.hit_pos, h.geometry_normal);
		bool is_indirect = (diffuse_bounces > 0u);
		vec3 direct_light = lights_evaluate_direct_lighting(
				hit_pos_offset, N, V, brdf_mat, rng, is_indirect, rt_light_count);
		ps.radiance += clamp_contribution(ps.throughput * direct_light, clamp_limit);
	}

	// =================================================================
	// Environment NEE (roadmap C3), MIS-combined with BSDF sky hits.
	//
	// A SEPARATE strategy from the analytic-light reservoir above, which stays
	// exactly as it was and carries NO MIS weight. Two reasons, both from the
	// design spec: the reservoir's selection pdf is a stochastic estimate rather
	// than the exact density MIS requires, and analytic lights are unreachable by
	// BSDF rays in the first place -- there is no second strategy to share with,
	// so weighting them down would simply lose that energy.
	//
	// Deliberately outside the `rt_light_count > 0` guard above: a scene lit only
	// by its sky has no analytic lights at all and is precisely the case this
	// exists for.
	// =================================================================
	{
		vec3 env_dir;
		float env_pdf_val;
		// env_sample() returns r_dir in WORLD space already -- it applies
		// transpose(env_world_to_sky()) internally (Task 3). Rotating it again here
		// would trace into a direction whose pdf is the one reported for a
		// different direction, which is exactly the silent MIS bias the env
		// sampling header warns about.
		if (env_sample(rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val) && dot(env_dir, N) > 0.0) {
			vec3 env_origin = offset_ray_origin(h.hit_pos, h.geometry_normal);
			if (lights_trace_shadow_ray(env_origin, env_dir, 10000.0)) {
				// Same fetch the miss stage performs for this direction: bordered
				// octmap lookup after the shared world -> sky rotation.
				vec3 sky_rad = env_sky_radiance(env_dir);

				// The BRDF VALUE and the BRDF DENSITY must describe the same set
				// of lobes, or the MIS weights partition one integrand while the
				// estimator evaluates another.
				//
				// combinedPdf() zeroes its specular term below
				// RT_MIS_DELTA_ROUGHNESS (brdf_inc.glsl), because a near-delta
				// lobe has no meaningful continuous density -- and correspondingly
				// shade_and_bounce stores RT_MIS_PDF_NONE for such a lobe, so the
				// miss stage gives its sky hit the FULL contribution. If we fed the
				// full evalCombinedBRDF (whose specular term is only floored at
				// alphaSquared = 1e-5, a finite spike whose integral is the entire
				// specular albedo) into that weight, environment NEE would
				// reproduce almost the whole highlight a second time: p_mix at the
				// mirror direction is just the diffuse term, while p_env near a
				// bright sky feature is orders of magnitude larger, so w_env ~= 1
				// exactly where f_spec is largest. A polished sphere under this sky
				// measured 2.92-3.00 against a BSDF-only reference of 1.489 -- a
				// 1.96-2.01x double count, with fireflies to 630 where the correct
				// peak is the sun's own radiance of 20.
				//
				// So drop the specular value in exactly the regime combinedPdf
				// drops the specular density. Delta lobes are unreachable by
				// environment sampling by definition; the BSDF strategy owns them
				// outright, which is what RT_MIS_PDF_NONE already encodes.
				// The dot(N, V) test reproduces evalCombinedBRDF's `Vbackfacing`
				// early-out (brdf_inc.glsl:1061), which evalCombinedBRDFSeparate
				// does NOT perform -- it only rejects Lbackfacing. Without it,
				// swapping to the Separate form would quietly start paying out at
				// grazing shading normals where the combined form returns zero,
				// i.e. it would change the non-delta case too. Everything outside
				// the delta regime stays bit-identical to before this fix.
				vec3 bsdf_val = vec3(0.0);
				if (dot(N, V) > 0.0) {
					vec3 f_diff, f_spec;
					evalCombinedBRDFSeparate(N, env_dir, V, brdf_mat, f_diff, f_spec);
					bsdf_val = (brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS)
							? f_diff
							: (f_diff + f_spec);
				}
				float bsdf_pdf_for_dir = combinedPdf(N, env_dir, V, brdf_mat);

				float w = power_heuristic(env_pdf_val, bsdf_pdf_for_dir);
				vec3 contrib = ps.throughput * bsdf_val * sky_rad * (w / env_pdf_val);
				ps.radiance += clamp_contribution(contrib, clamp_limit);
			}
		}
	}

	// =================================================================
	// BRDF importance sampling for next bounce
	// =================================================================
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	int brdfType;
	if (diffuseLum < 0.0001) {
		brdfType = SPECULAR_TYPE;
	} else if (specularLum < 0.0001) {
		brdfType = DIFFUSE_TYPE;
	} else {
		float brdfProbability = clamp(specularLum / (specularLum + diffuseLum), 0.01, 0.99);
		if (rng_1d(rng, RT_PRNG_LOBE) < brdfProbability) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= brdfProbability;
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= (1.0 - brdfProbability);
		}
	}

	vec2 u = rng_2d(rng, RT_PRNG_SURFACE_BSDF);
	vec3 next_dir;
	vec3 brdf_weight;
	if (!evalIndirectCombinedBRDF(u, N, h.geometry_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
		// Two failure modes:
		//   1) Sample weight is zero (no contribution). Terminate.
		//   2) Sampled direction is below the geometry plane. Recover by
		//      mirroring across the geometry plane (see brdf_inc.glsl). The
		//      mirror is gated by RT_BELOW_HEMISPHERE_RECOVERY_ENABLED; when
		//      disabled, recovery returns false and we terminate the path.
		vec3 recovered_dir;
		if (luminance(brdf_weight) == 0.0 ||
				!recoverBelowHemisphereSample(next_dir, h.geometry_normal, recovered_dir)) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// next_dir is now the MIRRORED direction. Its MIS density is evaluated at
		// this final direction, not at the pre-image -- see the mis_ray_pdf
		// assignment below for why the partition requires that.
		next_dir = recovered_dir;
	}

	ps.throughput *= brdf_weight;

	if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_glossy_bounce(ps.packed_bounces_flags);
	}

	// Hand the next ray back to raygen. PATH_TERMINATED_FLAG stays clear so
	// the raygen loop continues with the reconstructed origin and next_ray_dir.
	ps.hit_t = gl_HitTEXT;
	ps.offset_normal = h.geometry_normal;
	ps.next_ray_dir = next_dir;
	// Next bounce gets its own dimension block, so decision k at depth d always
	// draws from the same dimension across every path in the frame.
	ps.rng_packed = rng_pack(rng_next_bounce(rng));

	// Density the BSDF strategy assigned to the direction we just chose. This is
	// the mixture over both lobes, not just the one that was selected -- see
	// combinedPdf in brdf_inc.glsl.
	//
	// Near-delta specular lobes cannot be reached by environment sampling at all,
	// so anything this ray hits must take the FULL contribution rather than a MIS
	// share. Mirrors Cycles' PATH_RAY_MIS_SKIP.
	//
	// TASK 4 REVISION of Task 1's sentinel policy for the two remaining cases.
	//
	// Task 1 routed BOTH `recovered_sample` and `combinedPdf() == 0.0` to
	// RT_MIS_PDF_NONE as the "conservative" choice. That was sound while the
	// sentinel had no consumer. It is not sound now that environment NEE exists,
	// because the two sides' weights only partition the contribution if they are
	// the SAME function of the SAME direction:
	//
	//     env NEE evaluates   w_env  = power_heuristic(p_env(w), combinedPdf(w))
	//     the miss stage must evaluate
	//                         w_bsdf = power_heuristic(combinedPdf(w), p_env(w))
	//
	// and those sum to exactly 1. RT_MIS_PDF_NONE forces w_bsdf = 1 instead, so
	// wherever env NEE already paid out w_env > 0 for the same direction the sky
	// gets counted 1 + w_env times. Recovery fires on normal-mapped geometry --
	// most of a real scene -- so this was not a rare-case rounding matter.
	//
	//   - recovered_sample: the pre-image density is genuinely the right answer
	//     to "how likely was this sampler to produce this ray", but it is the
	//     WRONG answer here, because env NEE has no way to know a mirroring
	//     happened and evaluates combinedPdf at the final direction. Feeding the
	//     pre-image density in would leave w_env + w_bsdf != 1. Evaluating
	//     combinedPdf(next_dir) on this side too restores the partition. The
	//     recovery hack's own bias (it reuses the rejected sample's BRDF weight)
	//     is pre-existing, orthogonal, and untouched by this.
	//   - combinedPdf() == 0.0 is now stored AS 0.0 and is the correct value:
	//     w_bsdf = ph(0, p_env) = 0 hands the direction entirely to env NEE,
	//     which takes w_env = ph(p_env, 0) = 1. Complementary, so no energy is
	//     lost -- the other strategy collects it. This depends on the miss
	//     stage's `e_pdf > 0.0` guard; see the note there.
	//
	// The delta-specular case keeps RT_MIS_PDF_NONE, and is now genuinely
	// consistent: env NEE drops its specular VALUE in exactly that regime (see
	// the env-NEE block above), so the BSDF strategy owns delta lobes outright
	// and full weight is right.
	if (brdfType == SPECULAR_TYPE && brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS) {
		ps.mis_ray_pdf = RT_MIS_PDF_NONE;
	} else {
		ps.mis_ray_pdf = combinedPdf(N, next_dir, V, brdf_mat);
	}

	path_pack(payload, ps);
}
