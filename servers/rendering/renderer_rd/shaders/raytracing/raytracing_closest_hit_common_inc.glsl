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

// Emissive-mesh light sampling (roadmap C1). Included HERE and not at the top of
// the stage: emissive_radiance() calls sample_material_texture(), defined a few
// lines above, and emissive_sample() calls lights_trace_shadow_ray() and the BRDF
// library, both already in scope by the time this file is included. Anything
// earlier and the include does not compile; anything later and shade_and_bounce
// below cannot see it.
//
// It also brings the composition of emitted radiance itself into scope for
// scene_raytracing_raygen.glsl's closest_hit main(), which fills m.emissive
// through it -- so the NEE estimator and the BSDF-hit estimator are the same
// expression by construction rather than by inspection.
#include "raytracing_emissive_inc.glsl"

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
		float NdotV,
		MaterialData dbg_material) {
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
		ps.radiance = DLSSRR_computeSpecularAlbedo(albedo, metalness, vec3(specular_to_f0(specular)), roughness, NdotV);
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
		vec3 specular_albedo = DLSSRR_computeSpecularAlbedo(albedo, metalness, vec3(specular_to_f0(specular)), roughness, NdotV);
		ps.radiance = mix(diffuse_albedo, specular_albedo, metalness);
	} else if (vis_mode == 18) {
		ps.radiance = baseColorToSpecularF0(albedo, metalness, vec3(specular_to_f0(specular)));
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
		dbg_mat.dielectricF0 = vec3(specular_to_f0(specular));
		dbg_mat.emissive = vec3(0.0);
		dbg_mat.transmissivness = 0.0;
		dbg_mat.eta = 1.5; // Unused while transmissivness is 0.0; see MaterialProperties.eta.
		dbg_mat.opacity = 1.0;
		// E2b Task 3 Step 5. Uninitialized struct fields are undefined in GLSL --
		// this vis mode calls evalIndirectCombinedBRDF below, which DOES consume
		// anisotropy through prepareBRDFData, so leaving these unset here would
		// read garbage.
		dbg_mat.anisotropy = dbg_material.anisotropy;
		dbg_mat.anisotropyRotation = dbg_material.anisotropy_rotation; // already RADIANS
		dbg_mat.tangent = world_tangent;
		// E2d Task 5, same rule as the E2b note above: uninitialized struct fields
		// are undefined in GLSL. evalIndirectCombinedBRDF below is only ever called
		// here with SPECULAR_TYPE/DIFFUSE_TYPE, so the coat is not read -- set them
		// anyway, and with production's clamps, so this probe never diverges from
		// shade_and_bounce for a reason that has nothing to do with what it measures.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));

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
	} else if (vis_mode == 23) {
		// Phase D material-arrival probes. Raw, unscaled values: the
		// accumulation target is float, so nothing needs remapping and values
		// above 1.0 survive readback intact.
		ps.radiance = vec3(dbg_material.transmission, dbg_material.ior, dbg_material.thickness);
	} else if (vis_mode == 24) {
		ps.radiance = vec3(dbg_material.attenuation_density, dbg_material.specular_factor, dbg_material.sheen_roughness);
	} else if (vis_mode == 25) {
		ps.radiance = vec3(dbg_material.clearcoat, dbg_material.clearcoat_roughness, dbg_material.anisotropy);
	} else if (vis_mode == 26) {
		ps.radiance = vec3(dbg_material.anisotropy_rotation, 0.0, 0.0);
	} else if (vis_mode == 27) {
		ps.radiance = dbg_material.attenuation_color;
	} else if (vis_mode == 28) {
		ps.radiance = dbg_material.specular_tint;
	} else if (vis_mode == 29) {
		ps.radiance = dbg_material.sheen_color;
	} else if (vis_mode == 30 || vis_mode == 31) {
		// Resolved dielectric F0 (30) and resolved eta (31) after the E1
		// arbitration, RAW and unscaled.
		//
		// This calls the SAME resolveDielectricF0 that shade_and_bounce calls
		// (Task 3). That is the entire point of the gate: a second inlined copy
		// of the formula here would let the gate pass while the renderer used
		// something else -- validating the test's own arithmetic rather than the
		// shipped code. F0 is the value most able to fail silently, because a
		// wrong one still looks like plausible glass.
		vec3 dbg_f0;
		float dbg_eta;
		resolveDielectricF0(dbg_material.ior, specular, dbg_material.specular_factor,
				dbg_material.specular_tint, dbg_f0, dbg_eta);
		ps.radiance = (vis_mode == 30) ? dbg_f0 : vec3(dbg_eta);
	} else if (vis_mode == 32) {
		// Fix round 2, detector 1: pdf parity -- RETIRED as a two-function
		// comparison by E2c (Task 3). combinedPdfLobeProbability and
		// samplerLobeProbability, the deliberately-duplicated pair this mode
		// used to compare side by side, are deleted: combinedPdf and
		// shade_and_bounce's sampler now both call the SAME registry function,
		// lobeWeight (brdf_inc.glsl). A pdf-only desync between "combinedPdf's
		// view" and "the sampler's view" of the lobe-selection probability is
		// therefore no longer a possible outcome of any code path -- there is
		// only one call site left to be wrong, and if it is, both consumers
		// are wrong THE SAME WAY, which a same-formula-side-by-side ratio can
		// never detect regardless of how many call sites feed it (a ratio of
		// two evaluations of one formula is 1.0 by construction, a tautology,
		// not a comparison). Reporting a synthetic 1.0 here would be exactly
		// that: a probe that cannot fail.
		//
		// The live detector for "is this formula's VALUE correct" (as opposed
		// to "do two call sites of it agree") is RT_DEBUG_ANISO_PDF_PARITY
		// (vis mode 35, pt_anisotropy_gate) -- E2b's self-normalizing
		// instrument. It draws real directions from the real sampler and
		// checks the empirical mean of 1/pdf against the domain's known
		// measure, so a pdf wrong by a factor k reads back as 1/k on an
		// instrument that has no second copy of the formula to agree with
		// itself against; that is what makes it able to fail.
		//
		// This mode is kept, not deleted, so debug tooling built against
		// MODE_PDF_PARITY (pipeline_references/tests/pt_transmission_gate.gd,
		// probe 9) keeps a live, non-tautological signal rather than reading
		// undefined values: it reports lobeWeight's single real value in the
		// r channel ONLY, so a consumer checking it against an analytic
		// reference is still testing the real formula. g and b are 0.0 --
		// fix round 1 found that repeating the value into g/b and hard-coding
		// b to 1.0 (an earlier draft of this fix) left probe 9's "ratio"
		// assertion comparing a compile-time constant to 1.0: unfalsifiable
		// by ANY input, worse than the tautology this fix set out to retire,
		// since it needed zero formula evaluations, not two. Do not restore
		// that pattern; see probe 9's own header comment for the corrected
		// assertion set (one real analytic check, not three).
		MaterialProperties dbg_mat;
		dbg_mat.baseColor = albedo;
		dbg_mat.metalness = metalness;
		dbg_mat.roughness = roughness;
		vec3 dbg_f0_32;
		float dbg_eta_32;
		resolveDielectricF0(dbg_material.ior, specular, dbg_material.specular_factor,
				dbg_material.specular_tint, dbg_f0_32, dbg_eta_32);
		dbg_mat.dielectricF0 = dbg_f0_32;
		dbg_mat.emissive = vec3(0.0);
		dbg_mat.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? dbg_material.transmission : 0.0;
		dbg_mat.eta = dbg_eta_32;
		dbg_mat.opacity = 1.0;
		// E2b Task 3 Step 5. Not consumed by lobeWeight below, but a
		// MaterialProperties field left unset is undefined in GLSL regardless
		// of whether this call site happens to read it.
		dbg_mat.anisotropy = dbg_material.anisotropy;
		dbg_mat.anisotropyRotation = dbg_material.anisotropy_rotation; // already RADIANS
		dbg_mat.tangent = world_tangent;
		// E2d Task 5. Not consumed by lobeWeight below (the coat has its own
		// coatLobeWeight), but undefined-if-unset applies here too.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));

		// E2d Task 5b. This used to emit the bare lobeWeight(dbg_mat), but since
		// E2d the sampler's actual weights[LOBE_SPECULAR] is `baseShare * pSpec`
		// (raytracing_closest_hit_common_inc.glsl, the three-lobe selection
		// block) -- the two coincide only when baseShare == 1, i.e. only on an
		// uncoated material. Reporting the unscaled value would have made this
		// probe say something other than what its name claims for exactly the
		// materials E2d exists for, and Task 6 is about to capture a baseline
		// through it.
		//
		// Reconstructed from the SAME two functions the sampler calls, in the
		// same order, on the same unclamped dot(N, V) -- not re-derived. At
		// clearcoat == 0 coatLobeWeight returns literal 0.0, baseShare is
		// exactly 1.0f, and `1.0f * pSpec == pSpec` is the IEEE multiplicative
		// identity, so every existing reading of this mode (pt_transmission_gate
		// probe 9, whose material is a StandardMaterial3D with the default
		// clearcoat of 0) is bit-unchanged.
		// There is no `N` in this function's scope -- debug_visualize receives
		// final_normal and geometry_normal, and shade_and_bounce's N is the
		// CLAMPED shading normal. Rebuild it with the same call and the same
		// threshold vis mode 22 already uses eleven lines above, so cosNI here
		// is the same expression the sampler feeds coatLobeWeight, not the
		// floored NdotV parameter (which is max(dot(m.normal, V), 0.0001) --
		// a different, pre-clamp normal).
		vec3 N_clamped32 = clampShadingNormal(final_normal, geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);
		float pSpec = lobeWeight(dbg_mat);
		float dbgBaseShare32 = 1.0 - coatLobeWeight(dbg_mat, dot(N_clamped32, V));
		ps.radiance = vec3(dbgBaseShare32 * pSpec, 0.0, 0.0);
	} else if (vis_mode == 33) {
		// Fix round 2, detector 2: hemisphere-guard firing rate. Accumulates
		// float(wrongNg || wrongN) across many samples via the standard
		// accumulation buffer -- each accumulated frame draws ONE independent
		// stochastic transmissive-lobe sample (calling sampleTransmissiveLobe,
		// the SAME production function shade_and_bounce calls, not a
		// re-inlined copy) and this mode emits 1.0 if the guard would have
		// rejected it, 0.0 otherwise. The average over N accumulated frames is
		// the empirical guard-firing rate.
		//
		// Why "high variance, lost in Monte Carlo noise" is NOT the right
		// mental model here (corrected from an earlier, wrong explanation):
		// brdf_inc.glsl's transmit branch clamps NdotL to -1e-5, and
		// specularSampleWeight -> Smith_G2_Over_G1_Height_Correlated goes to
		// ~0 as NdotL -> 0. Every sample the hemisphere guard would reject
		// ALREADY carries weight ~1e-5 regardless of whether the guard fires
		// -- the effect on a RENDERED MEAN is bounded at ~1e-5 by that
		// unrelated downstream clamp, not "buried in noise". This detector
		// sidesteps that entirely by measuring the RAW REJECTION RATE
		// directly, before any weight is ever applied.
		MaterialProperties dbg_mat;
		dbg_mat.baseColor = albedo;
		dbg_mat.metalness = metalness;
		dbg_mat.roughness = roughness;
		vec3 dbg_f0_33;
		float dbg_eta_33;
		resolveDielectricF0(dbg_material.ior, specular, dbg_material.specular_factor,
				dbg_material.specular_tint, dbg_f0_33, dbg_eta_33);
		dbg_mat.dielectricF0 = dbg_f0_33;
		dbg_mat.emissive = vec3(0.0);
		dbg_mat.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? dbg_material.transmission : 0.0;
		dbg_mat.eta = dbg_eta_33;
		dbg_mat.opacity = 1.0;
		// E2b Task 3 Step 5. Consumed below via prepareBRDFData (dbg_transData)
		// to derive ax/ay/anisoPhi for sampleTransmissiveLobe's aniso sampling.
		dbg_mat.anisotropy = dbg_material.anisotropy;
		dbg_mat.anisotropyRotation = dbg_material.anisotropy_rotation; // already RADIANS
		dbg_mat.tangent = world_tangent;
		// E2d Task 5. sampleTransmissiveLobe below never touches the coat, but
		// undefined-if-unset applies here too.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));

		vec3 dbg_specularF0 = baseColorToSpecularF0(dbg_mat.baseColor, dbg_mat.metalness, dbg_mat.dielectricF0);
		float dbg_alpha = dbg_mat.roughness * dbg_mat.roughness;

		// MUST use the CLAMPED shading normal, exactly as shade_and_bounce's
		// own `N = clampShadingNormal(m.normal, h.geometry_normal, V,
		// RT_SHADING_NORMAL_CLAMP_THRESHOLD)` does -- fix round 2 self-review
		// caught this: reading the raw final_normal here does not carry the
		// "always on V's side" guarantee geometry_normal has by construction
		// (compute_hit_data flips geometry_normal toward V; nothing flips the
		// raw shading normal), which the hemisphere check's own correctness
		// (and this detector's ability to show the pre-fix ordering
		// collapsing the rate to ~0) depends on.
		//
		// Known, deliberate limitation (fix round 3): dbg_mat.eta above is set
		// straight to dbg_eta_33 with no front/back-face inversion (compare
		// shade_and_bounce's own `h.is_front_face ? resolved_eta :
		// (1.0/resolved_eta)`), and debug_visualize only ever runs on primary,
		// front-face hits -- so this detector only ever exercises eta > 1,
		// which is the half of the guard that is unreachable BY THEOREM (see
		// _probe10_guard_firing_rate's header comment in pt_transmission_gate.gd
		// for the proof). Its non-zero signal comes entirely from wrongNg
		// firing via normal-map divergence, never from wrongN via the eta < 1
		// mechanism that matters on production's back-face exit path. This is
		// a known coverage gap in this detector, not a claim that the guard is
		// otherwise dead.
		vec3 dbg_N = clampShadingNormal(final_normal, geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);

		// E2b: ax/ay/anisoPhi for THIS hit's dbg_N, via prepareBRDFData -- the
		// same tangent-projection formula every other consumer uses, so this
		// detector cannot silently derive the anisotropy frame a different way
		// than production does. L is unused for these three fields.
		BrdfData dbg_transData = prepareBRDFData(dbg_N, V, V, dbg_mat);

		RNGState dbg_rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		vec2 dbg_u_xy = rng_2d(dbg_rng, RT_PRNG_SURFACE_BSDF);
		float dbg_u_z = rng_1d(dbg_rng, RT_PRNG_TRANSMIT);
		vec3 dbg_u3 = vec3(dbg_u_xy, dbg_u_z);

		vec3 dbg_next_dir;
		vec3 dbg_weight;
		bool dbg_is_transmit;
		bool dbg_wrong_hemisphere;
		bool dbg_ok = sampleTransmissiveLobe(V, dbg_N, geometry_normal, dbg_alpha, dbg_alpha * dbg_alpha,
				dbg_specularF0, dbg_mat.eta, dbg_mat.transmissivness, dbg_material.thickness == 0.0,
				dbg_transData.ax, dbg_transData.ay, dbg_transData.anisoPhi, dbg_transData.anisoActive, dbg_u3,
				dbg_next_dir, dbg_weight, dbg_is_transmit, dbg_wrong_hemisphere);
		// Fix round 2 self-review: the thin-walled override this defect
		// reorders around ONLY applies when isTransmit is true (`if
		// (isTransmit && thin_walled)`), so only TRANSMIT-lobe rejections are
		// affected by the ordering bug -- REFLECT-lobe rejections (a
		// completely separate, unrelated below-hemisphere phenomenon at high
		// roughness, the same kind clampShadingNormal/recoverBelowHemisphereSample
		// exist to handle for opaque materials) are untouched either way and,
		// at these settings, turned out to dominate the unconditional rate,
		// masking the defect entirely (measured identically with and without
		// the break in early testing). Channels, all as float(ok && ...):
		//   r: wrong_hemisphere AND is_transmit -- the numerator for the
		//      TRANSMIT-conditional rate, the one this defect can move to 0.
		//   g: is_transmit -- the denominator (fraction of samples that took
		//      the transmit lobe at all).
		//   b: wrong_hemisphere unconditionally -- kept for reference/context
		//      only, NOT the detector's pass/fail signal.
		ps.radiance = vec3(
				(dbg_ok && dbg_is_transmit && dbg_wrong_hemisphere) ? 1.0 : 0.0,
				(dbg_ok && dbg_is_transmit) ? 1.0 : 0.0,
				(dbg_ok && dbg_wrong_hemisphere) ? 1.0 : 0.0);
	} else if (vis_mode == 34) {
		// E2a probe D: the scalar this shader multiplies sky radiance by.
		//
		// env_sky_radiance() does `sky_color *= IBL_exposure_normalization`.
		// Cycles has no equivalent scalar, so if this is not 1.0 it is a direct
		// candidate for the ~23% environment dimming (roadmap 7.4).
		//
		// It is reported rather than inferred on purpose. Deriving it from a
		// brightness ratio would assume the rest of the sky path is correct,
		// which is exactly what the gate is testing -- the same circularity
		// the E1 closeout had to retract from roadmap 7.1's calibration
		// argument. Raw and unscaled, matching mode 23's convention.
		ps.radiance = vec3(scene_data_block.data.IBL_exposure_normalization, 0.0, 0.0);
	} else if (vis_mode == 35) {
		// E2b pdf/sampler parity. Fix round 1 (C2, CRITICAL): the original R-vs-G
		// single-sample comparison described below is a TAUTOLOGY -- traced
		// symbolically, R and G resolve to the identical expression with the
		// identical inputs, so a genuinely wrong pdf formula (a missing factor,
		// wrong G1, swapped ax/ay) would still read R == G and pass. See the
		// comment further down (at dbg_valid35) for the full trace and for the
		// REAL instrument this mode now also computes in its B channel.
		//
		// R = the density the SAMPLER actually realises, G = what
		// sampleGGXVNDFReflectionPdfAniso reports for the same direction, both
		// now hemisphere-guarded to match production's own early-out --
		// retained as a confirmation diagnostic, not as the probe's real signal.
		//
		// This calls the SAME functions the integrator calls, not re-inlined
		// copies -- a second copy here would validate the probe's own arithmetic
		// rather than the shipped code. Same reason vis mode 32 exists (E1).
		//
		// R (dbg_sampler_pdf): sampleSpecularMicrofacet is the ACTUAL specular
		// sampler shade_and_bounce dispatches to (via evalIndirectCombinedBRDF's
		// SPECULAR_TYPE branch, brdf_inc.glsl's `sampleSpecular` macro). Calling
		// it here with a real RNG draw produces a real local-space Llocal. Its
		// half-vector is recovered from reflection symmetry -- Llocal ==
		// reflect(-Vlocal, Hlocal) implies Hlocal == normalize(Vlocal + Llocal)
		// for whatever Hlocal the sampler actually drew -- then fed into
		// sampleGGXVNDFReflectionPdfAniso, the SAME low-level pdf primitive G
		// below calls. This is "the density the sampler realises" because H
		// comes from the geometry of what the shipped sampler returned, not
		// from re-running its RNG a second time.
		//
		// G (dbg_reported_pdf): combinedPdf -- the SAME function shade_and_bounce
		// calls at its mis_ray_pdf assignment -- evaluated at the WORLD-space
		// direction the sampler just realised. The gate's probe-2 material is
		// fully metallic (diffuseLum == 0, so lobeWeight returns
		// exactly 1.0) and non-transmissive (transmitScale == 1.0 exactly), so
		// combinedPdf's diffuse+specular mixture collapses bit-exactly onto its
		// own internal sampleGGXVNDFReflectionPdfAniso call -- but reached
		// through combinedPdf's INDEPENDENTLY-coded world-to-local rotation
		// (brdf_inc.glsl:1770-1787), not R's. A rotation-convention desync
		// between the SAMPLING side and the REPORTING side -- exactly Task 3's
		// two frame fixes (evalMicrofacet's world-to-local transform and
		// pre-rotating the tangent before prepareBRDFData) -- would show up
		// here as R != G, but ONLY at a shading normal not aligned with world
		// Z: getRotationToZAxis((0,0,1)) is the identity and would hide it
		// completely. The gate must therefore sample a sphere (or a tilted
		// plane), never a Z-facing quad.
		MaterialProperties dbg_mat;
		dbg_mat.baseColor = albedo;
		dbg_mat.metalness = metalness;
		dbg_mat.roughness = roughness;
		vec3 dbg_f0_35;
		float dbg_eta_35;
		resolveDielectricF0(dbg_material.ior, specular, dbg_material.specular_factor,
				dbg_material.specular_tint, dbg_f0_35, dbg_eta_35);
		dbg_mat.dielectricF0 = dbg_f0_35;
		dbg_mat.emissive = vec3(0.0);
		dbg_mat.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? dbg_material.transmission : 0.0;
		dbg_mat.eta = dbg_eta_35;
		dbg_mat.opacity = 1.0;
		dbg_mat.anisotropy = dbg_material.anisotropy;
		dbg_mat.anisotropyRotation = dbg_material.anisotropy_rotation; // already RADIANS
		dbg_mat.tangent = world_tangent;
		// E2d Task 5. LOAD-BEARING here, not merely hygienic: this probe calls
		// combinedPdf below, and combinedPdf now reads coatWeight/coatRoughness/
		// coatIor through coatLobeWeight and coatPdf. Left unset these are
		// undefined, and pt_anisotropy_gate's E[1/pdf] reading -- which must stay
		// at 2*PI -- would drift on garbage that has nothing to do with anisotropy.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));

		// Same clamped shading normal shade_and_bounce actually bounces from
		// (mirrors vis mode 33's dbg_N) -- on a sphere this is well away from
		// world Z almost everywhere, which is what makes this probe able to
		// see the two frame fixes at all.
		vec3 dbg_N35 = clampShadingNormal(final_normal, geometry_normal, V, RT_SHADING_NORMAL_CLAMP_THRESHOLD);

		// ax/ay/anisoPhi for THIS hit's dbg_N35, via prepareBRDFData -- the same
		// tangent-projection formula every other consumer uses (L is unused for
		// these three fields; mirrors mode 33's dbg_transData).
		BrdfData dbg_data35 = prepareBRDFData(dbg_N35, V, V, dbg_mat);

		float4 dbg_qToZ35 = getRotationToZAxis(dbg_N35);
		vec3 dbg_Vlocal35 = rotatePoint(dbg_qToZ35, V);

		float dbg_alpha35 = dbg_mat.roughness * dbg_mat.roughness;
		vec3 dbg_specularF0_35 = baseColorToSpecularF0(dbg_mat.baseColor, dbg_mat.metalness, dbg_mat.dielectricF0);

		RNGState dbg_rng35 = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		vec2 dbg_u35 = rng_2d(dbg_rng35, RT_PRNG_SURFACE_BSDF);

		vec3 dbg_weight35;
		vec3 dbg_Llocal35 = sampleSpecularMicrofacet(dbg_Vlocal35, dbg_alpha35, dbg_alpha35 * dbg_alpha35,
				dbg_specularF0_35, dbg_data35.ax, dbg_data35.ay, dbg_data35.anisoPhi, dbg_data35.anisoActive,
				dbg_u35, dbg_weight35);

		// Reflection symmetry recovers the half-vector the sampler drew without
		// re-deriving it any other way: Llocal == reflect(-Vlocal, Hlocal) for
		// ANY Hlocal implies Hlocal == normalize(Vlocal + Llocal).
		vec3 dbg_Hlocal35 = normalize(dbg_Vlocal35 + dbg_Llocal35);
		vec3 dbg_Vaniso35 = rotateAboutZ(dbg_Vlocal35, -dbg_data35.anisoPhi);
		vec3 dbg_Haniso35 = rotateAboutZ(dbg_Hlocal35, -dbg_data35.anisoPhi);
		// Matches combinedPdf's own VdotH clamp (brdf_inc.glsl:1846) so R and G
		// are not compared under two different clamp conventions.
		float dbg_VdotH35 = max(0.00001, dot(dbg_Vlocal35, dbg_Hlocal35));

		float dbg_sampler_pdf = sampleGGXVNDFReflectionPdfAniso(dbg_Vaniso35, dbg_Haniso35,
				dbg_data35.ax, dbg_data35.ay, dbg_VdotH35);

		vec3 dbg_dir35 = normalize(rotatePoint(invertRotation(dbg_qToZ35), dbg_Llocal35));

		// Fix round 1, C2 (CRITICAL): the ORIGINAL construction here compared
		// dbg_sampler_pdf against combinedPdf(dbg_N35, dbg_dir35, V, dbg_mat) with
		// no hemisphere check. Traced symbolically, both resolve to the SAME
		// expression: prepareBRDFData(Nlocal=(0,0,1), ...) inside combinedPdf
		// makes getRotationToZAxis((0,0,1)) the identity, so combinedPdf
		// recomputes the identical anisoPhi/ax/ay and calls the identical
		// sampleGGXVNDFReflectionPdfAniso -- so R == G by construction for ANY
		// correct OR incorrect pdf formula; the probe could never fail on the
		// defect class it exists to catch. The non-zero diffs fix round 0
		// measured were an artifact of combinedPdf's OWN
		// `if (dot(N,L) <= 0.0) return 0.0;` early-out (brdf_inc.glsl:1745-1749)
		// firing on samples this harness fed it with no matching guard --
		// production never calls combinedPdf that way (evalIndirectCombinedBRDF
		// rejects below-hemisphere directions before shade_and_bounce ever
		// reaches the mis_ray_pdf assignment), so that zero was not a desync, it
		// was this probe asking a question production never asks. Guarding both
		// sides to the SAME hemisphere condition production itself enforces
		// collapses R and G back to agreement (fix round 1 measured ~1e-6 across
		// every combination, pure fp32 round-trip noise) -- which is itself
		// confirmation of the tautology, not a passing test: two genuinely
		// independent implementations do not collapse that tightly by
		// coincidence.
		bool dbg_valid35 = dot(dbg_N35, dbg_dir35) > 0.0;
		float dbg_reported_pdf = dbg_valid35 ? combinedPdf(dbg_N35, dbg_dir35, V, dbg_mat) : 0.0;
		float dbg_sampler_pdf_guarded = dbg_valid35 ? dbg_sampler_pdf : 0.0;

		// Fix round 1, C2 item 3: the REAL instrument. R vs G above cannot
		// detect a wrong pdf FORMULA because they are the same formula evaluated
		// twice -- guarding only proves the tautology, it does not fix it. This
		// is the actual independent check: self-normalized importance sampling.
		// Draw L ~ p_true (whatever density sampleSpecularMicrofacet ACTUALLY
		// realises -- its closed form is never needed) and accumulate 1/G(L)
		// with G = combinedPdf, the SAME reporting function production uses for
		// mis_ray_pdf. If G == p_true everywhere on p_true's support,
		// E[1/G(L)] = integral over that support of p_true(L)/G(L) dL =
		// integral of 1 dL = the support's solid-angle measure -- 2*PI for the
		// upper hemisphere, independent of the LOBE SHAPE of p_true or G, so it
		// cannot be gamed by two copies of the same (right or wrong) formula the
		// way R/G above could. A wrong G (a missing factor, swapped ax/ay, a
		// wrong G1) shifts the accumulated mean away from 2*PI. The gate
		// accumulates this over many frames via the standard accumulation
		// buffer and averages again over every pixel on the sphere; both are
		// real draws from the real sampler.
		float dbg_self_norm35 = (dbg_valid35 && dbg_reported_pdf > 0.0) ? (1.0 / dbg_reported_pdf) : 0.0;

		// R = old-style sampler-reconstructed pdf, now hemisphere-guarded (fix
		// round 1's confirmation diagnostic -- expect R == G to fp32 noise). G =
		// combinedPdf's report, now hemisphere-guarded to match. B = the real
		// instrument's per-sample contribution, 1/G(L) or 0 -- the gate
		// accumulates and averages B against 2*PI. Raw and unscaled, matching
		// mode 23's convention.
		ps.radiance = vec3(dbg_sampler_pdf_guarded, dbg_reported_pdf, dbg_self_norm35);
	} else if (vis_mode == 36) {
		// E2d arrival gate: r = clearcoat, g = clearcoat_roughness,
		// b = (clearcoat_ior - 1.0) so the 1.5 default reads 0.5 rather than
		// saturating. Tint gets its own mode -- packing five numbers into
		// three channels is how a field silently reads as its neighbour.
		ps.radiance = vec3(dbg_material.clearcoat, dbg_material.clearcoat_roughness,
				dbg_material.clearcoat_ior - 1.0);
	} else if (vis_mode == 37) {
		// E2d arrival gate: the tint, straight through.
		ps.radiance = dbg_material.clearcoat_tint;
	} else if (vis_mode == 38) {
		// E2d: coatAlbedoEstimate evaluated on the GPU, so the gate can compare
		// it against test_pt_coat_albedo.cpp's CPU mirror. A transcription slip
		// between the two -- a swapped F0/z, a half-texel index -- produces a
		// plausible render and no failing test WITHOUT this readout, because
		// the estimate only ever appears multiplied into an attenuation.
		//
		// r = estimate at this hit's cos(N,V); g = estimate forced to cosNI 1.0
		// (normal incidence, must approach F0); b = forced to cosNI 0.0
		// (grazing, must approach 1).
		//
		// Uses the NdotV parameter (dot(final_normal, V), floor-clamped to
		// 0.0001 by the caller) rather than a bare `dot(N, V)`: this function has
		// no `N` in scope -- that identifier is a local of shade_and_bounce(),
		// a different function below -- NdotV is the already-computed equivalent
		// quantity other debug modes in this function already use (see vis
		// modes 11/17 above, DLSSRR_computeSpecularAlbedo's NdotV argument).
		ps.radiance = vec3(
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, NdotV, dbg_material.clearcoat_ior),
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, 1.0, dbg_material.clearcoat_ior),
				coatAlbedoEstimate(dbg_material.clearcoat_roughness, 0.0, dbg_material.clearcoat_ior));
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

	// Beer-Lambert absorption through a solid (roadmap E1).
	//
	// Applied at the EXIT hit: a back-face hit on a transmissive material with
	// thickness > 0. gl_HitTEXT at that hit IS the distance travelled inside a
	// closed mesh, so this needs no payload state and no medium stack.
	//
	// attenuation is (1 - attenuation_color) * attenuation_density, Cycles'
	// Volume Absorption coefficient (kernel/svm/closure.h:1236-1241). Note this
	// diverges from the glTF spec's attenuationColor^(d/attenuationDistance);
	// Blender's is chosen because acceptance is a Cycles reference image and
	// Blender renders imported glTF this way. See spec section 4.3.
	//
	// KNOWN LIMITATION: exact for a single closed mesh, wrong for nested or
	// interpenetrating transmissive volumes, which would need a medium stack.
	//
	// This multiply reads INSIDE_MEDIUM_FLAG (gate added below) but never
	// WRITES it: once the gate below is satisfied, the ray really did
	// traverse gl_HitTEXT of medium to reach this hit regardless of what the
	// BSDF dispatch further down decides to do next (transmit out, or reflect
	// internally and stay inside). The flag means "the ray about to be
	// traced is inside a solid," which is not knowable until AFTER that
	// dispatch runs -- see the symmetric toggle at the bounce-accounting block
	// below (fix round 1, C2). Clearing it here would be the old C2 bug all
	// over again: a back-face hit that samples an internal reflection (TIR
	// near the critical angle, or a stray diffuse-lobe draw) would clear the
	// flag while the ray is still inside, so its next segment re-enables
	// back-face culling, misses the interior wall it needs to find, and
	// escapes to sky -- leaked, over-bright energy at grazing angles on any
	// solid glass sphere or gem.
	// Gated on is_inside_medium (E1 final fix wave, part 2), in addition to the
	// pre-existing thickness/transmission checks. Without it, a CAMERA ray that
	// hits a back face DIRECTLY -- reachable on any double-sided (CULL_DISABLED)
	// transmissive material, since back-face culling is what would otherwise
	// keep such a hit from ever being the FIRST hit of a path -- reads
	// gl_HitTEXT as the whole camera-to-surface distance and applies Beer-
	// Lambert over it as if that distance were a path length through glass.
	// With a short attenuation_distance this reads solid black on a surface
	// the camera ray never actually travelled through.
	//
	// is_inside_medium is exactly the right signal for THIS gate specifically
	// (unlike its use at the eta flip a few dozen lines below, where the
	// header comment there documents it as WRONG for thin-walled materials):
	// set_inside_medium/clear_inside_medium are themselves gated on
	// `m.thickness > 0.0` at the bounce-accounting block below, the identical
	// condition already required to reach this line, so there is no thin-
	// walled gap to inherit here. A ray only arrives at a back-face hit with
	// the flag set if some earlier segment actually entered through a front
	// face of a thickness > 0.0 material -- i.e. gl_HitTEXT is a real
	// in-medium path length -- which is exactly the case this multiply is
	// meant to model.
	if (RT_GET_TRANSMISSION_ENABLED() && !h.is_front_face && m.transmission > 0.0 && m.thickness > 0.0 &&
			is_inside_medium(ps.packed_bounces_flags)) {
		ps.throughput *= exp(-m.attenuation * gl_HitTEXT);
	}

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

	// Emissive contribution, MIS-weighted against emissive NEE (roadmap C1).
	float clamp_limit = (total_bounces == 0u)
			? get_rt_param(RT_PARAM_CLAMP_DIRECT)
			: get_rt_param(RT_PARAM_CLAMP_INDIRECT);

	// An emissive surface is reachable by BOTH strategies -- emissive NEE samples
	// it from the previous vertex, and the BSDF ray traced from that same vertex
	// can land on it -- so its radiance has to be SPLIT by a pair of weights
	// summing to 1. Without this every glowing surface is counted twice; the
	// measured double count on pt_emissive_compile_scene.tscn was +99.7%, and it is
	// the identical defect B2 fixed for the sky.
	//
	// THE OTHER HALF IS emissive_sample()'s `power_heuristic(pdf_omega,
	// combinedPdf(...))`. The two are built from the same two densities in the same
	// (solid-angle) measure, swapped, which is what makes them sum to exactly one:
	//   NEE  : ph(light_pdf, bsdf_pdf)
	//   here : ph(bsdf_pdf,  light_pdf)
	//
	// EVERY PATH OUT OF THE GATE WITH WEIGHT 1.0 IS DELIBERATE, and each is a case
	// where NEE could not have produced this direction, so there is no second
	// strategy to share with and weighting down would DELETE energy rather than
	// redistribute it:
	//
	//   - feature off. NEE never ran.
	//   - ps.mis_ray_pdf <= 0.0, i.e. RT_MIS_PDF_NONE. A camera ray (raygen seeds
	//     the sentinel), a near-delta specular bounce, or a below-hemisphere
	//     recovery -- see the mis_ray_pdf assignment at the bottom of this function
	//     for why each is unreachable by any NEE strategy.
	//   - slot < 0. Not in the distribution: a non-emitter, or an emitter excluded
	//     for being DEFORMED or a CUSTOM HIT GROUP (gather_emissive_instances).
	//     Those exclusions are unbiased ONLY because of this line.
	//   - light_pdf == 0.0 inside the branch. The instance is an emitter but NEE
	//     cannot draw THIS direction: back face, degenerate triangle, or a
	//     primitive past prim_count. power_heuristic(bsdf_pdf, 0) is 1.0, so the
	//     surface is still lit correctly -- no extra branch needed, and none wanted.
	//
	// gl_WorldRayDirectionEXT is the direction FROM the shading point TOWARD this
	// hit -- the same orientation NEE's own L carries (note V = -gl_WorldRayDirectionEXT
	// above). emissive_pdf_solid_angle_for_hit() takes that direction rather than a
	// cosine on purpose: it derives cos_light through emissive_orient_normal(), the
	// same function emissive_sample() uses, so the forward and reverse densities
	// cannot disagree about which face emits.
	//
	// The slot lookup is INSIDE the gate and carries the `total_power > 0.0`
	// contract itself (emissive_slot_for_instance): with the feature off,
	// emissive_slot[] is backed by a 16-byte fallback and reading it is out of
	// bounds. GLSL's && short-circuits, so RT_GET_EMISSIVE_ENABLED() -- a
	// specialization constant, folded at compile time -- removes the lookup
	// entirely from a build with the feature off.
	float emissive_mis_weight = 1.0;
	if (RT_GET_EMISSIVE_ENABLED() && ps.mis_ray_pdf > 0.0) {
		int emissive_slot_index = emissive_slot_for_instance(gl_InstanceCustomIndexEXT);
		if (emissive_slot_index >= 0) {
			float emissive_light_pdf = emissive_pdf_solid_angle_for_hit(
					uint(emissive_slot_index), uint(gl_PrimitiveID),
					gl_WorldRayDirectionEXT, gl_HitTEXT);
			emissive_mis_weight = power_heuristic(ps.mis_ray_pdf, emissive_light_pdf);
		}
	}
	ps.radiance += clamp_contribution(ps.throughput * m.emissive * emissive_mis_weight, clamp_limit);

	// Per-lobe limits, matching Cycles: a path stops when the lobe it has been
	// taking exceeds its own cap, not when every budget is exhausted
	// (kernel/integrator/path_state.h:183, :190). This is what replaces the old
	// hardcoded 2-diffuse-bounce ceiling that flattened interior GI.
	const uint max_total = RT_GET_MAX_BOUNCES();
	const uint max_diffuse = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_DIFFUSE_BOUNCE), max_total);
	const uint max_glossy = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_GLOSSY_BOUNCE), max_total);
	// Roadmap E1. The cap comes from RT_FLAGS rather than rt_params because all
	// sixteen rt_params slots are assigned -- the same reason B4's min_bounce and
	// C1's emissive enable are project settings rather than Environment params
	// (scene_shader_raytracing.cpp:643-648). resolve_bounce_cap is reused because
	// this field also uses 0-as-unset.
	//
	// min(..., 15u) (fix round 1, M1) is load-bearing, not defensive: the
	// transmission-bounce counter is only 4 bits (raytracing_inc.glsl) and
	// inc_transmission_bounce does not itself saturate at 15 -- incrementing
	// past it carries into INSIDE_MEDIUM_FLAG (bit 31) and can wrap the whole
	// packed word to zero if that bit was already set, silently clearing every
	// counter and flag. resolve_bounce_cap alone can return up to max_total
	// (16) when RT_GET_MAX_TRANSMISSION_BOUNCE() is 0 (a raw RenderingServer
	// with the setting unset), so this clamp is what actually prevents that.
	const uint max_transmission = min(resolve_bounce_cap(float(RT_GET_MAX_TRANSMISSION_BOUNCE()), max_total), 15u);
	const uint transmission_bounces = get_transmission_bounces(ps.packed_bounces_flags);
	if (total_bounces >= max_total || diffuse_bounces >= max_diffuse || glossy_bounces >= max_glossy ||
			transmission_bounces >= max_transmission) {
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
	}

	// BRDF material setup.
	MaterialProperties brdf_mat;
	brdf_mat.baseColor = m.albedo;
	brdf_mat.metalness = m.metalness;
	brdf_mat.roughness = m.roughness;
	// F0 / IOR arbitration (roadmap E1, spec section 3.2). Phase D left F0
	// double-specified between Godot's `specular` and the glTF ior /
	// specular_factor / specular_tint triple; this is where it is resolved.
	//
	// Structure is Cycles' (kernel/svm/closure.h:426-431): IOR is the source of
	// truth, the artist-facing specular knob is a multiplier that no-ops at its
	// 0.5 default, and eta is re-derived from the modified F0 when it is not 0.5
	// so reflectance and refraction cannot disagree.
	//
	// The RESPONSE CURVE is Godot's, not Blender's: 4*specular^2 is
	// specular_to_f0 (0.16*s^2) normalised against the 0.04 reference, so it is
	// EXACTLY 1.0 at 0.5 and preserves Godot's shape away from it. Blender uses
	// 2*level; the two agree only at 0.5 (0.08 vs 0.16 at specular = 1.0).
	//
	// At every default -- ior 1.5, specular 0.5, specular_factor 1.0, white tint
	// -- this yields exactly vec3(0.04) and eta 1.5, identical to the
	// specular_to_f0(0.5) this line replaced. That is arithmetic, not a
	// measurement, and it is why untouched materials cannot shift.
	// See resolveDielectricF0 in brdf_inc.glsl for why IOR wins and why the
	// specular knob is a multiplier that no-ops at 0.5.
	float resolved_eta;
	resolveDielectricF0(m.ior, m.specular, m.specular_factor, m.specular_tint,
			brdf_mat.dielectricF0, resolved_eta);
	brdf_mat.emissive = m.emissive;
	// Roadmap E1. This replaces the `transmissivness = 0.0` hardcode that made
	// glass vanish. RT_GET_TRANSMISSION_ENABLED() is a specialization constant,
	// folded at compile time, so a build with the feature off compiles the whole
	// transmissive path away rather than paying a runtime branch.
	brdf_mat.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? m.transmission : 0.0;
	// eta must be the RELATIVE index for the interface THIS hit represents, and
	// it must be flipped identically to how sampleDielectricMicrofacet sampled
	// the direction being evaluated -- combinedPdf reads brdf_mat.eta too, and
	// the two disagreeing here is the exact defect class already open as B2's
	// +2.4% converged-mean error (PATH_TRACER_QUALITY_ROADMAP.md).
	//
	// h.is_front_face, not is_inside_medium(ps.packed_bounces_flags), is
	// authoritative: it is a property of THIS interface (front face = ray
	// currently outside the medium, about to enter; back face = ray currently
	// inside the medium, about to exit), decided the same way Cycles keys eta
	// off SD_BACKFACING (kernel/svm/closure.h:426-431). is_inside_medium is
	// path-history bookkeeping for raygen's ray-flags decision (Step 8), not a
	// per-hit fact, and stays wrong for one case even after fix round 1 (C2)
	// made its maintenance symmetric with the actual transmit/reflect outcome:
	// a THIN-walled material (m.thickness == 0.0) never sets the flag at all
	// (Step 5 gates it on thickness > 0), yet a back-side hit on a thin
	// surface still needs the flipped Fresnel split -- is_inside_medium would
	// read false there and silently skip the flip. h.is_front_face carries no
	// such gap; it is correct for both the thick-medium and the thin-walled
	// case from the same one-line expression.
	//
	// Guard on the reciprocal itself (E1 final fix wave, part 2). ior == 0.0
	// is legal glTF and resolveDielectricF0 correctly resolves it to
	// resolved_eta == 0.0 (F0 == 1.0, fully reflective) -- but
	// fresnel_dielectric's caller contract (brdf_inc.glsl:392-395) forbids
	// computing 1.0/eta before it returns, and an eagerly-flipped eta == 0.0
	// here is an infinity reaching every downstream consumer. Reachable on a
	// CULL_DISABLED (double-sided) transmissive material even after
	// render_raytracing.cpp floors ior at 0.0 at upload, because 0.0 itself
	// is still legal: a back face is then directly camera-visible with no
	// inside-medium flag set, so this ternary's else-branch is the very
	// first thing to touch it. eta == 0.0 already means "always TIR" in
	// fresnel_dielectric regardless of sign (eta_cos_theta_t_sq is <= 0.0 for
	// every cos_theta_i when eta == 0.0), so leaving it un-flipped in that
	// case is physically correct, not merely defensive.
	brdf_mat.eta = h.is_front_face ? resolved_eta : ((resolved_eta > 0.0) ? (1.0 / resolved_eta) : resolved_eta);
	brdf_mat.opacity = 1.0;
	// E2b Task 3 Step 5. The production path -- consumed by prepareBRDFData
	// (evalIndirectCombinedBRDF's specular sample, combinedPdf, evalCombinedBRDFSeparate)
	// everywhere brdf_mat flows below. MaterialResult m does not carry
	// anisotropy (Phase D never forwarded it there), so read it straight from
	// the MaterialData binding, same as debug_visualize's dbg_material param.
	MaterialData raw_mat = materials[h.geometry_idx];
	brdf_mat.anisotropy = raw_mat.anisotropy;
	brdf_mat.anisotropyRotation = raw_mat.anisotropy_rotation; // already RADIANS
	brdf_mat.tangent = h.tangent;
	// E2d coat. Read from raw_mat for the same reason anisotropy is: MaterialResult
	// carries no clearcoat fields, so the MaterialData binding is the only source.
	//
	// Cycles' clamps, svm/closure.h:148-150, all four reproduced. coatWeight is the
	// ONLY gate: clearcoat and clearcoat_roughness are feature-gated to 0 when
	// FEATURE_CLEARCOAT is off (scene/resources/material.cpp:2270,2277) while
	// clearcoat_ior and clearcoat_tint are published unconditionally (:2294,:2304),
	// so a material with the feature disabled still arrives here carrying a valid
	// ior of 1.5 and a white tint. Gating on either of those would switch the coat
	// on for every uncoated material in the scene.
	brdf_mat.coatWeight = max(raw_mat.clearcoat, 0.0);
	brdf_mat.coatRoughness = clamp(raw_mat.clearcoat_roughness, 0.0, 1.0);
	brdf_mat.coatIor = max(raw_mat.clearcoat_ior, 1.0);
	brdf_mat.coatTint = max(raw_mat.clearcoat_tint, vec3(0.0));

	vec3 specularF0 = baseColorToSpecularF0(brdf_mat.baseColor, brdf_mat.metalness, brdf_mat.dielectricF0);
	// Fix round 1, I2: the transmission weight used to be applied to THIS
	// local via a separate `*=` below, but this local's only consumer is
	// diffuseLum a few lines down (lobe-selection probability) -- it never
	// reached any BSDF VALUE, since NEE and evalIndirectCombinedBRDF both get
	// their diffuseReflectance from prepareBRDFData's own (until this fix,
	// unscaled) call. The estimator then divided by brdfProbability
	// afterwards, so the diffuse layer was delivered at FULL strength: glass
	// emitted a full diffuse lobe plus the full dielectric closure, and the
	// old comment here claiming this "dims NEE" and is "required for energy
	// conservation" was false. Now baseColorToDiffuseReflectance itself
	// applies the transmission weight (brdf_inc.glsl), so this call,
	// prepareBRDFData's, and combinedPdf's all derive from one formula with
	// one input and cannot desync. Factor is exactly 1.0 when transmissivness
	// is 0 -- bit-identical to pre-E1 on every non-glass material.
	vec3 diffuseReflectance = baseColorToDiffuseReflectance(brdf_mat.baseColor, brdf_mat.metalness, brdf_mat.transmissivness);

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
					vec3 f_diff, f_spec, f_coat;
					evalCombinedBRDFSeparate(N, env_dir, V, brdf_mat, f_diff, f_spec, f_coat);

					// GGX multiple-scattering compensation. sampleSpecularMicrofacet
					// folds `ms` into the weight it hands back (brdf_inc.glsl:905),
					// so the BSDF strategy's realised integrand is ms * f_spec --
					// but evalMicrofacet (:918), which is what
					// evalCombinedBRDFSeparate calls, applies no such factor. Two
					// strategies whose weights sum to 1 must estimate the SAME
					// integrand; without this the env half pays the
					// single-scattering value while the BSDF half pays the
					// compensated one, and the difference is lost in proportion to
					// w_env. Measured on a roughness-0.6 metal sphere: 1.344
					// against a BSDF-only reference of 1.708, a 21% energy loss.
					// ms is 1 + F0 * Ems, which is ~1.22-1.37 in that configuration.
					//
					// Note the same asymmetry exists between sampling and evaluation
					// for the ANALYTIC light path (raytracing_lights_inc.glsl also
					// calls evalCombinedBRDFSeparate). That is a pre-existing engine
					// inconsistency and NOT an MIS partition bug -- analytic lights
					// have no second strategy to disagree with -- so it is reported
					// rather than changed here.
#if MICROFACET_DISTRIBUTION == GGX
					float ms_alpha = brdf_mat.roughness * brdf_mat.roughness;
					f_spec *= evalMultiScatterApproximation(ms_alpha, NdotV, specularF0);
					// E2d Task 5b: NO coat factor here any more. The coat's
					// compensation is coatEnergyScale (real Cycles
					// preserve_energy, not the 1 + F0*Ems approximation, which at
					// the coat's F0 = 0.04 is ~1.002 and recovers nothing), and it
					// now lives INSIDE evalCoat -- so f_coat arrives already
					// compensated and multiplying again here would double it.
					// Moved inside because there are four NEE call sites and only
					// two of them ever applied the external factor.
#endif

					bsdf_val = (brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS)
							? f_diff
							: (f_diff + f_spec);
					// E2d fix round 1: the coat's delta guard is keyed on the COAT's
					// roughness, not the base's. That separation is the reason the
					// coat has its own out-parameter -- folded into f_spec, a rough
					// NEE-able coat would have been deleted by the line above
					// whenever the base underneath happened to be a near-mirror.
					// coatPdf drops the coat's DENSITY on exactly this predicate, and
					// shade_and_bounce stores RT_MIS_PDF_NONE for a coat sample in
					// the same regime, so value and density agree.
					if (brdf_mat.coatRoughness >= RT_MIS_DELTA_ROUGHNESS) {
						bsdf_val += f_coat;
					}
				}
				float bsdf_pdf_for_dir = combinedPdf(N, env_dir, V, brdf_mat);

				float w = power_heuristic(env_pdf_val, bsdf_pdf_for_dir);
				vec3 contrib = ps.throughput * bsdf_val * sky_rad * (w / env_pdf_val);
				ps.radiance += clamp_contribution(contrib, clamp_limit);
			}
		}
	}

	// =================================================================
	// Emissive-mesh NEE (roadmap C1).
	//
	// A THIRD strategy, independent of both blocks above: glowing geometry is
	// invisible to the analytic-light reservoir (it is not in rt_lights[]) and to
	// environment sampling (it is not the sky), so before this the only way to
	// find it was for a BSDF ray to stumble onto it -- which is why a small bright
	// emitter used to be almost pure noise.
	//
	// Gated on a SPECIALIZATION CONSTANT, so a build with the feature off compiles
	// this away entirely rather than paying a runtime branch. There was no enable
	// to copy: environment NEE is unconditional, guarded only by env_sample()
	// returning false.
	//
	// The estimator carries its own MIS weight, `power_heuristic(pdf_omega,
	// combinedPdf(...))`. Its matching half -- scaling down the emissive radiance a
	// bounce ray collects when it lands on an emitter -- is applied at the emissive
	// accumulation near the top of this function. The two are the same power
	// heuristic over the same two densities with the arguments swapped, so they
	// partition each emissive surface rather than counting it twice.
	// =================================================================
	if (RT_GET_EMISSIVE_ENABLED()) {
		vec3 emissive_direct;
		vec3 emissive_origin = offset_ray_origin(h.hit_pos, h.geometry_normal);
		if (emissive_sample(emissive_origin, N, V, brdf_mat, rng, emissive_direct)) {
			ps.radiance += clamp_contribution(ps.throughput * emissive_direct, clamp_limit);
		}
	}

	// =================================================================
	// BRDF importance sampling for next bounce
	// =================================================================
	float specularLum = luminance(specularF0);
	float diffuseLum = luminance(diffuseReflectance);

	// E2d. cosNI is the UNCLAMPED dot(N, V), and combinedPdf computes the very
	// same expression from the same N and V -- the two splits have to agree
	// direction by direction or MIS partitions one integrand while the estimator
	// evaluates another (the B2 defect class).
	float cosNI = dot(N, V);
	// TWO quantities, deliberately. coatLayerAlbedo is the RAW throughput
	// withdrawal; coatMass is the CLAMPED selection probability. Fix round 1 split
	// them -- see the two-roles block above coatLayerAlbedo in brdf_inc.glsl for
	// the energy error the clamped one caused when it was used for both.
	float coatAlbedo = coatLayerAlbedo(brdf_mat, cosNI);
	float coatMass = coatLobeWeight(brdf_mat, cosNI);

	int brdfType;
	bool tookCoatLobe = false;
	// DEVIATION FROM THE TASK 5 BRIEF, deliberate. The brief replaces only the
	// weights block, which lives in the `else` of this three-way branch -- but the
	// first two arms return WITHOUT drawing a lobe or dividing throughput, so a
	// coat placed only in the `else` would be silently inert on exactly the
	// materials E2d exists for: `diffuseLum < 0.0001` is a pure metal, and
	// metal-plus-coat IS car paint, the phase's own stated acceptance target
	// (E2d spec, section 5 point 4 and section 7 point 4). Gating both fast paths
	// on `coatMass <= 0.0` keeps them
	// available to uncoated materials and routes coated ones through the general
	// selection instead.
	//
	// This preserves the phase invariant exactly. coatLobeWeight returns literal
	// 0.0f below the 1e-5 cutoff and otherwise clamps to [0.01, 0.99], so
	// `coatMass <= 0.0` is true for precisely the uncoated case; at clearcoat == 0
	// each condition reduces to the identical expression it replaced, evaluated in
	// the identical order, and the identical arm is taken.
	//
	// The general path handles both degenerate cases correctly on its own:
	// lobeWeight returns exactly 1.0 when diffuseLum is negligible and exactly 0.0
	// when specularLum is, so one base weight becomes exactly 0 -- and selectLobe
	// can never RETURN that index, because a zero increment leaves `acc` where the
	// previous iteration already failed `u < acc`. The surviving divisor is
	// baseShare >= 0.01, never zero.
	if (coatMass <= 0.0 && diffuseLum < 0.0001) {
		brdfType = SPECULAR_TYPE;
	} else if (coatMass <= 0.0 && specularLum < 0.0001) {
		brdfType = DIFFUSE_TYPE;
	} else {
		// E2c: routed through the N-way lobe registry (brdf_inc.glsl) --
		// lobeWeight computes the same clamp(...) formula the old
		// samplerLobeProbability/combinedPdfLobeProbability pair duplicated,
		// and selectLobe replaces the direct `u < brdfProbability` compare.
		// Exactly ONE rng_1d(rng, RT_PRNG_LOBE) draw, consumed once, below.
		// LOBE_SPECULAR == 0 is picked on `u < weights[0]` -- the identical
		// condition the old `<` compare used, so this is a routing change,
		// not a behaviour change. See RT_DEBUG_PDF_PARITY (vis mode 32) for
		// why the duplication this replaces is retired, not restored.
		//
		// E2d: the coat takes coatMass of the selection mass; the base lobes split
		// what is left, in their existing proportion. Specular stays at index 0.
		// At coatMass == 0 baseShare is exactly 1.0f and multiplying by exactly
		// 1.0f is the IEEE identity, so both base weights are bit-identical to the
		// E2c form, and weights[LOBE_COAT] == 0.0 is unreachable by selectLobe.
		float baseShare = 1.0 - coatMass;
		float pSpec = lobeWeight(brdf_mat);

		float weights[LOBE_COUNT];
		weights[LOBE_SPECULAR] = baseShare * pSpec;
		weights[LOBE_DIFFUSE] = baseShare * (1.0 - pSpec);
		weights[LOBE_COAT] = coatMass;

		// STILL exactly one draw, consumed once, unremapped and unrescaled. A
		// second draw or a remap here shifts every subsequent sample in the path --
		// statistically valid, bitwise different everywhere, and invisible to every
		// gate.
		int lobe = selectLobe(rng_1d(rng, RT_PRNG_LOBE), weights);
		if (lobe == LOBE_COAT) {
			brdfType = COAT_TYPE;
			tookCoatLobe = true;
			// Fix round 1: `coatWeight /`, not a bare `1 /`. The other two lobes
			// divide by their selection probability alone because their CLOSURE
			// weight is 1; the coat's is not. Cycles allocates the coat closure with
			// `coat_weight * weight` (svm/closure.h), which is why the spec writes
			// its albedo as `coat_weight * w * estimate` (section 4.1), so the MC
			// factor here is closure weight over selection probability.
			//
			// Shipped without it, the coat returned 1/coatWeight too much light --
			// at coatWeight 0.5 over a white base a furnace reads 1.025, and
			// "coat plus attenuated base never exceeds 1" is acceptance criterion 1.
			// The base was attenuated by coatWeight*estimate while the coat paid out
			// as though coatWeight were 1, so the two halves of the layer did not
			// balance.
			ps.throughput *= brdf_mat.coatWeight / weights[LOBE_COAT];
		} else if (lobe == LOBE_SPECULAR) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= weights[LOBE_SPECULAR];
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= weights[LOBE_DIFFUSE];
		}
	}

	// E2d: the layering half. Without it the coat is ADDITIVE -- a lobe that
	// returns light the base still returns in full -- which is the wrong render,
	// which is why the lobe and this block land in one commit.
	if (!tookCoatLobe && brdf_mat.coatWeight > 0.00001) {
		// THIS IS A THROUGHPUT FACTOR, NOT A SELECTION PROBABILITY. It must not be
		// folded into weights[] above -- see the selection-vs-throughput block at
		// the top of brdf_inc.glsl's registry section. Folding it in and
		// renormalising would still integrate to the right mean (MIS is unbiased
		// for ANY weights summing to 1 pointwise), so the error would be
		// mean-preserving and invisible to every rendered gate this project has.
		//
		// Fix round 1: routed through coatLayeringTransmittance, the SAME function
		// evalCombinedBRDFSeparate calls for every NEE path, fed the same RAW
		// coatAlbedo. Before that, BSDF sampling applied a layer NEE knew nothing
		// about, so the two MIS strategies estimated different integrands. The
		// attenuation and the Beer's-law tint remain two separate steps inside that
		// function, per Cycles (svm/closure.h:155 vs :178).
		//
		// Note it takes coatAlbedo, NOT coatMass -- the clamp on coatMass exists
		// only to bound the sampler's divisor and has no radiometric meaning.
		ps.throughput *= coatLayeringTransmittance(brdf_mat, cosNI, coatAlbedo);
	}

	vec2 u = rng_2d(rng, RT_PRNG_SURFACE_BSDF);
	vec3 next_dir;
	vec3 brdf_weight;
	bool recovered_sample = false;

	bool took_transmissive_lobe = false;
	bool transmissive_sample_ok = false;
	if (brdfType == SPECULAR_TYPE && brdf_mat.transmissivness > 0.0) {
		float alpha = brdf_mat.roughness * brdf_mat.roughness;
		float3 u3 = float3(u, rng_1d(rng, RT_PRNG_TRANSMIT));
		// E2b: ax/ay/anisoPhi for THIS hit's N, via prepareBRDFData -- the same
		// tangent-projection formula every other consumer uses (V is a dummy L,
		// unused for these three fields).
		BrdfData transData = prepareBRDFData(N, V, V, brdf_mat);
		// Fix round 2: calls sampleTransmissiveLobe (brdf_inc.glsl), which
		// encapsulates sampling, the hemisphere-consistency guard, and the
		// thin-walled override IN THE ORDER fix round 1's I1 established --
		// see that function's doc comment for the full reasoning and
		// RT_DEBUG_GUARD_FIRING_RATE for the detector this extraction makes
		// possible.
		bool isTransmit;
		bool wrongHemisphere;
		if (sampleTransmissiveLobe(V, N, h.geometry_normal, alpha, alpha * alpha, specularF0,
					brdf_mat.eta, brdf_mat.transmissivness, m.thickness == 0.0,
					transData.ax, transData.ay, transData.anisoPhi, transData.anisoActive, u3,
					next_dir, brdf_weight, isTransmit, wrongHemisphere)) {
			transmissive_sample_ok = !wrongHemisphere;
			took_transmissive_lobe = isTransmit;
		}
		if (!transmissive_sample_ok || luminance(brdf_weight) == 0.0) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
	}

	if (!transmissive_sample_ok && !evalIndirectCombinedBRDF(u, N, h.geometry_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
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
		// next_dir is now the MIRRORED direction, carrying the REJECTED sample's
		// brdf_weight. That makes it density-matched to nothing this code can
		// evaluate, which is why it takes MIS weight 1 -- see the mis_ray_pdf
		// assignment below, where both candidate policies are measured.
		next_dir = recovered_dir;
		recovered_sample = true;
	}

	ps.throughput *= brdf_weight;

	if (took_transmissive_lobe) {
		ps.packed_bounces_flags = inc_transmission_bounce(ps.packed_bounces_flags);
		// Symmetric toggle (fix round 1, C2), replacing a one-way set: a
		// transmit sample crossing a THICK surface either enters the solid
		// (front face) or leaves it (back face) -- the flag must follow
		// whichever direction this transmit actually went, every time, not
		// just be set once on entry. Any OTHER outcome at this hit --
		// internal reflection (took_transmissive_lobe false) or a diffuse-lobe
		// draw -- leaves the flag exactly as it already was, which is correct:
		// the ray's medium residency did not change because it did not cross
		// the interface. Thin-walled surfaces (m.thickness == 0.0) never enter
		// a medium at all, so the flag is untouched for them regardless of
		// isTransmit.
		if (m.thickness > 0.0) {
			ps.packed_bounces_flags = h.is_front_face
					? set_inside_medium(ps.packed_bounces_flags)
					: clear_inside_medium(ps.packed_bounces_flags);
		}
	} else if (brdfType == DIFFUSE_TYPE) {
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
	} else {
		ps.packed_bounces_flags = inc_glossy_bounce(ps.packed_bounces_flags);
	}

	// =================================================================
	// Russian Roulette (roadmap B4).
	// =================================================================
	// Terminates low-throughput paths with probability (1 - p) and scales the
	// survivors by 1/p, so the expected contribution is unchanged and the average
	// path gets shorter.
	//
	// sqrt() is deliberate and matches Cycles (kernel/integrator/path_state.h:296-305):
	// it terminates LATER than naive luminance-based roulette, which better matches
	// the view transform. max_component, NOT luminance -- an earlier revision of
	// PATH_TRACER_QUALITY_ROADMAP.md specified clamp(luminance, 0.05, 0.95) and that
	// was wrong.
	//
	// The bounce counters were incremented just above, so min_bounce = 3 means the
	// first three bounces are never rouletted -- the part of the path carrying the
	// most energy is left alone.
	//
	// Environment NEE for this vertex was already paid further up; that contribution
	// is valid whether or not the path continues. Roulette governs only the
	// continuation, and it scales throughput only -- mis_ray_pdf is a directional
	// density and is unaffected, so no MIS weight changes.
	{
		uint rr_depth = get_total_bounces(ps.packed_bounces_flags);
		if (rr_depth > RT_GET_MIN_BOUNCE()) {
			// abs() matches Cycles' reduce_max(fabs(throughput)) (path_state.h:296-305).
			// This is a genuine guard, not a no-op: apply_segment_fog() (above) does
			// `throughput *= (1.0 - fog.a)`, and with fog_mode = DEPTH, fog.a =
			// pow(fog_z, fog_depth_curve) * fog_density (fog_inc.glsl) can exceed 1.0
			// because fog_density's property hint is "0,1,0.0001,or_greater"
			// (environment.cpp) -- so throughput can go negative here. sqrt() of a
			// negative is undefined in GLSL, and the NaN it would produce flows
			// through both comparisons below as false (survive), then
			// `throughput /= rr_p` propagates it until sanitize_payload_value()
			// (path_pack, above) zeroes the path out silently.
			float rr_p = min(sqrt(max(max(abs(ps.throughput.r), abs(ps.throughput.g)), abs(ps.throughput.b))), 1.0);
			// rng_1d's divisor is 2^32 + 512 (sobol_burley_inc.glsl), so its result is
			// strictly < 1.0 -- `rand >= p` alone already terminates every path with
			// p == 0. The `rr_p <= 0.0` clause is therefore belt-and-braces, not
			// load-bearing today: it only matters if the comparison sense above is
			// ever changed from `>=` to `>`, which would otherwise let rand == 0.0
			// through at p == 0 and divide by zero.
			if (rr_p <= 0.0 || rng_1d(rng, RT_PRNG_TERMINATE) >= rr_p) {
				ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
				path_pack(payload, ps);
				return;
			}
			ps.throughput /= rr_p;
		}
	}

	// Hand the next ray back to raygen. PATH_TERMINATED_FLAG stays clear so
	// the raygen loop continues with the reconstructed origin and next_ray_dir.
	ps.hit_t = gl_HitTEXT;
	// Raygen offsets the next ray origin ALONG this normal
	// (scene_raytracing_raygen.glsl). A refracted ray is heading INTO the
	// surface, so it must be offset the other way or it restarts outside the
	// glass and immediately re-hits the face it just crossed. Negating here
	// costs no payload space -- the field is already oct-packed.
	ps.offset_normal = took_transmissive_lobe ? -h.geometry_normal : h.geometry_normal;
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
	// THE GOVERNING RULE, of which every branch below is an instance: this ray may
	// be weighted DOWN only where environment NEE actually pays something. Wherever
	// env NEE's estimator is structurally zero, the BSDF strategy is the only one
	// there is and must take weight 1 -- otherwise the contribution is deleted with
	// nothing to collect it. Each case was measured against a BSDF-only reference
	// build on the gate's directional scene (pipeline_references/tests).
	//
	//   - dot(N, V) <= 0. A property of the SHADING POINT, not of any one
	//     direction: the env-NEE block above is gated on it (reproducing
	//     evalCombinedBRDF's Vbackfacing early-out), so at such a vertex env NEE
	//     contributes nothing in EVERY direction -- while combinedPdf, which never
	//     tests V against the hemisphere, returns a positive density that would
	//     scale this ray down. clampShadingNormal only REDUCES backfacing V, it does
	//     not eliminate it, so on strongly normal-mapped geometry this is common:
	//     without this guard, 0.836 against a reference of 1.415, a 41% loss.
	//
	//   - recovered_sample (a mirrored below-hemisphere sample). Task 4 fix round 1
	//     replaced this sentinel with combinedPdf(next_dir), reasoning that both
	//     sides must evaluate one function at one direction for w_env + w_bsdf to
	//     equal 1. That reasoning is sound as far as it goes, and it does remove a
	//     genuine double count -- but it rests on an assumption that is false here:
	//     that this ray's estimator is density-matched to combinedPdf and merely
	//     needs the right weight. It is not. Recovery MIRRORS the direction while
	//     keeping the REJECTED sample's brdf_weight, so the ray is not drawn from
	//     combinedPdf(next_dir), nor from any density this code knows. No weight
	//     function turns it into a correct estimator of its share, so the choice is
	//     empirical rather than principled -- and it is not close:
	//         sentinel (full weight)      1.42042 vs reference 1.41451  (+0.42%)
	//         combinedPdf(next_dir)       0.94549 vs reference 1.41451  (-33%)
	//     The +0.42% IS the double count, and it is real; it is simply two orders of
	//     magnitude smaller than the loss incurred by "fixing" it. Reverted to the
	//     sentinel deliberately. The real repair is to make recovery produce a
	//     density-matched sample, which is Task 1's mechanism to change, not this
	//     one's.
	//
	//   - combinedPdf() == 0.0. Also full weight, and it is easy to talk yourself
	//     out of this one: w_bsdf = ph(0, p_env) = 0 supposedly hands the direction
	//     to env NEE, which takes w_env = ph(p_env, 0) = 1. But that w_env = 1
	//     multiplies a ZERO ESTIMATOR -- every direction for which combinedPdf
	//     returns 0 is one where env NEE's own VALUE is zero too (dot(N,L) <= 0 is
	//     exactly evalCombinedBRDFSeparate's Lbackfacing rejection, and the V ~= -L
	//     branch is caught by the env-NEE block's dot(N,V) guard). Both strategies
	//     pay nothing and the throughput is discarded. Nor does the miss stage's
	//     `e_pdf > 0.0` guard rescue it: env_cdf_build.glsl floors every cell at
	//     1e-4 * mean, so env_pdf() is strictly positive everywhere a sky exists.
	//     These directions are reachable -- sampleSpecularMicrofacet CLAMPS NdotL to
	//     1e-5 rather than rejecting, while evalIndirectCombinedBRDF rejects only
	//     against the GEOMETRY plane. Measured energy difference on the gate is
	//     below its noise floor (1.70843 vs 1.70802) because the specular sample
	//     weight vanishes on the same NdotL -> 0 limit, but the deletion is real and
	//     the guard is free.
	//
	//   - near-delta specular. Env NEE drops its specular VALUE in exactly that
	//     regime (see the env-NEE block above), so the BSDF strategy owns delta
	//     lobes outright. Mirrors Cycles' PATH_RAY_MIS_SKIP.
	//
	//   - took_transmissive_lobe. Environment NEE draws only directions with
	//     dot(env_dir, N) > 0 and combinedPdf returns 0 for NdotL <= 0, so NO
	//     NEE strategy can reach a transmitted direction. The BSDF strategy owns
	//     it outright and must take full weight -- sky seen through glass is
	//     paid once, in full. This is the same rule as the near-delta case, not
	//     a new exception.
	//
	//   - near-delta COAT (E2d). The same rule as near-delta specular, keyed on
	//     the coat's OWN roughness: coatPdf (brdf_inc.glsl) returns 0.0 below
	//     RT_MIS_DELTA_ROUGHNESS for exactly this reason, so without this clause a
	//     mirror coat would report a mixture pdf built only from the base lobes --
	//     a density that does not describe how the direction was actually drawn.
	//     Unreachable while clearcoat is 0, since brdfType is never COAT_TYPE then.
	if (took_transmissive_lobe || recovered_sample || dot(N, V) <= 0.0 ||
			(brdfType == SPECULAR_TYPE && brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS) ||
			(brdfType == COAT_TYPE && brdf_mat.coatRoughness < RT_MIS_DELTA_ROUGHNESS)) {
		ps.mis_ray_pdf = RT_MIS_PDF_NONE;
	} else {
		float bsdf_pdf = combinedPdf(N, next_dir, V, brdf_mat);
		ps.mis_ray_pdf = (bsdf_pdf > 0.0) ? bsdf_pdf : RT_MIS_PDF_NONE;
	}

	path_pack(payload, ps);
}
