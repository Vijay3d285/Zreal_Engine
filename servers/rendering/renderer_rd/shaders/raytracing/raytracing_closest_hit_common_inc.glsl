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
	// The SMOOTH, vertex-interpolated normal -- Cycles' sd->N, NOT its Ng. World
	// space, flipped toward the incoming ray on back-face hits. Ray-origin
	// offsets and the shading frame are built on it. (The name predates F1; it
	// is kept because ~40 sites read it and its meaning has not changed.)
	vec3 geometry_normal;
	// F1: the triangle's TRUE plane normal -- Cycles' sd->Ng. World space, unit
	// length, oriented so dot(face_normal, -ray_dir) > 0. Every "is this
	// direction inside the surface" test in the integrator is against THIS
	// (bsdf_microfacet.h:863, bsdf_diffuse.h:65 test Ng), and
	// ensure_valid_specular_reflection rotates toward it. For procedural
	// (intersection-shader) geometry it equals geometry_normal.
	vec3 face_normal;
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
		h.face_normal = h.geometry_normal;
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

		// F1: true face normal from the three vertex positions. Three extra BDA
		// reads per closest hit; Cycles gets Ng free from its intersector, we do
		// not. Edges are transformed by the full object-to-world rotation/scale
		// (NOT the normalised normal_matrix) so a non-uniformly scaled instance
		// still gets the plane of the world-space triangle.
		{
			uint fi0, fi1, fi2;
			get_triangle_indices(geom, fi0, fi1, fi2);
			vec3 p0 = rt_fetch_vertex_position(geom, fi0);
			vec3 p1 = rt_fetch_vertex_position(geom, fi1);
			vec3 p2 = rt_fetch_vertex_position(geom, fi2);
			vec3 e1 = model_rotation * (p1 - p0);
			vec3 e2 = model_rotation * (p2 - p0);
			vec3 ng = cross(e1, e2);
			float ng_len2 = dot(ng, ng);
			// Degenerate triangle: fall back to the smooth normal rather than NaN.
			h.face_normal = (ng_len2 > 1e-20) ? ng * inversesqrt(ng_len2) : h.geometry_normal;
			// Orient toward the ray, as Cycles flips Ng for back-facing hits
			// (shader_setup_from_ray). Independent of winding convention.
			if (dot(h.face_normal, -gl_WorldRayDirectionEXT) < 0.0) {
				h.face_normal = -h.face_normal;
			}
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
		vec3 face_normal,
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
		// BRDF below-face rejection visualization. Since F1 shade_and_bounce
		// applies Cycles' ensure_valid_specular_reflection to the shading normal
		// and REJECTS (terminates) any sample that lands below the true face --
		// there is no mirror recovery any more.
		//
		// We sample both BRDF lobes once with the raw normal-mapped normal and
		// once with the corrected normal, reusing the same random pair so the
		// two passes are directly comparable.
		//
		// Color legend (ordered cleanest -> most rejected):
		//   green   = no rejection in either pass (correction not needed)
		//   blue    = the correction alone resolves the rejection
		//   yellow  = one lobe still rejected after the correction (path ends)
		//   red     = both lobes rejected after the correction
		//
		// Yellow/red is where production terminates paths -- Cycles' LABEL_NONE.
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
		dbg_mat.smoothNormal = geometry_normal;
		dbg_mat.bumpNormal = final_normal;
		dbg_mat.phaseG = RT_PHASE_SURFACE;
		// E2d Task 5, same rule as the E2b note above: uninitialized struct fields
		// are undefined in GLSL. evalIndirectCombinedBRDF below is only ever called
		// here with SPECULAR_TYPE/DIFFUSE_TYPE, so the coat is not read -- set them
		// anyway, and with production's clamps, so this probe never diverges from
		// shade_and_bounce for a reason that has nothing to do with what it measures.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));
		// E2e Task 4, same undefined-if-unset rule as the E2b/E2d notes above.
		// Production's clamps: sheenColor is max(.., 0) (Cycles closure.h:120's
		// `max(sheen_tint, zero)`) and sheenRoughness is left RAW here --
		// provably harmless, not merely convenient: clamp(x, 1e-3, 1) ==
		// clamp(clamp(x, 0, 1), 1e-3, 1) for every finite x, so sheenSetup's
		// own internal [1e-3, 1] clamp (bsdf_sheen.h:33) makes production's
		// extra [0,1] pre-clamp a no-op on any value this debug path can
		// produce; skipping it here changes nothing.
		dbg_mat.sheenColor = max(dbg_material.sheen_color, vec3(0.0));
		dbg_mat.sheenRoughness = dbg_material.sheen_roughness;
		dbg_mat.sssWeight = 0.0;
		dbg_mat.sssThin = false;
		dbg_mat.sssRadius = vec3(0.0);
		dbg_mat.sssScale = 0.0;

		vec3 dbg_dir;
		vec3 dbg_weight;
		// Draw both random pairs up front so each (specular/diffuse) test in
		// the un-clamped and clamped pass uses the exact same numbers.
		RNGState dbg_rng = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		vec2 u_spec_rng = rng_2d(dbg_rng, RT_PRNG_SURFACE_BSDF);
		vec2 u_diff_rng = rng_2d(dbg_rng, RT_PRNG_LIGHT);

		bool u_spec_ok = evalIndirectCombinedBRDF(u_spec_rng, final_normal, face_normal, V, dbg_mat, SPECULAR_TYPE, dbg_dir, dbg_weight, vec4(0.0));
		bool u_diff_ok = evalIndirectCombinedBRDF(u_diff_rng, final_normal, face_normal, V, dbg_mat, DIFFUSE_TYPE, dbg_dir, dbg_weight, vec4(0.0));

		// The same correction shade_and_bounce applies (F1); "clamped" below
		// means "corrected", and the rejection plane is the true face.
		vec3 N_clamped = ensureValidSpecularReflection(face_normal, V, final_normal);
		bool c_spec_ok = evalIndirectCombinedBRDF(u_spec_rng, N_clamped, face_normal, V, dbg_mat, SPECULAR_TYPE, dbg_dir, dbg_weight, vec4(0.0));
		bool c_diff_ok = evalIndirectCombinedBRDF(u_diff_rng, N_clamped, face_normal, V, dbg_mat, DIFFUSE_TYPE, dbg_dir, dbg_weight, vec4(0.0));

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
	} else if (vis_mode == 43) {
		// E3 arrival gate: the subsurface radius (transmittance_color), raw.
		// 43/44, NOT 41/42: 41 is pt_sheen_gate's MODE_SHEEN_LTC (its arm sits
		// later in this chain and was shadowed for one build -- the sheen gate
		// caught it). Vis-mode numbers are claimed by the gates, not by an
		// enum; grep `:= 4` in pipeline_references/tests before taking one.
		ps.radiance = dbg_material.sss_radius;
	} else if (vis_mode == 44) {
		// E3 arrival gate: r = sss_weight, g = sss_scale, b = thin-wall flag.
		ps.radiance = vec3(dbg_material.sss_weight, dbg_material.sss_scale,
				((dbg_material.flags & RT_MAT_FLAG_SSS_THIN) != 0u) ? 1.0 : 0.0);
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
		dbg_mat.smoothNormal = geometry_normal;
		dbg_mat.bumpNormal = final_normal;
		dbg_mat.phaseG = RT_PHASE_SURFACE;
		// E2d Task 5. Not consumed by lobeWeight below (the coat has its own
		// coatLobeWeight), but undefined-if-unset applies here too.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));
		// E2e Task 4, same undefined-if-unset rule as the E2b/E2d notes above.
		// Production's clamps: sheenColor is max(.., 0) (Cycles closure.h:120's
		// `max(sheen_tint, zero)`) and sheenRoughness is left RAW here --
		// provably harmless, not merely convenient: clamp(x, 1e-3, 1) ==
		// clamp(clamp(x, 0, 1), 1e-3, 1) for every finite x, so sheenSetup's
		// own internal [1e-3, 1] clamp (bsdf_sheen.h:33) makes production's
		// extra [0,1] pre-clamp a no-op on any value this debug path can
		// produce; skipping it here changes nothing.
		dbg_mat.sheenColor = max(dbg_material.sheen_color, vec3(0.0));
		dbg_mat.sheenRoughness = dbg_material.sheen_roughness;
		dbg_mat.sssWeight = 0.0;
		dbg_mat.sssThin = false;
		dbg_mat.sssRadius = vec3(0.0);
		dbg_mat.sssScale = 0.0;

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
		//
		// E2e Task 4 extends the reconstruction by one layer, for exactly the
		// reason E2d added the first: the sampler's weights[LOBE_SPECULAR] is now
		// `afterSheen * (1 - coatMass) * pSpec`, so a two-factor reconstruction
		// would again say something other than this probe's name on the materials
		// the phase exists for. At sheenColor == 0 sheenLobeWeight returns literal
		// 0.0, dbgAfterSheen32 is exactly 1.0f, and `1.0f * x == x` leaves every
		// existing reading of this mode bit-unchanged.
		vec3 N_clamped32 = ensureValidSpecularReflection(face_normal, V, final_normal);
		float pSpec = lobeWeight(dbg_mat);
		float dbgAfterSheen32 = 1.0 - sheenLobeWeight(dbg_mat, N_clamped32, V);
		float dbgBaseShare32 = dbgAfterSheen32 * (1.0 - coatLobeWeight(dbg_mat, dot(N_clamped32, V)));
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
		dbg_mat.smoothNormal = geometry_normal;
		dbg_mat.bumpNormal = final_normal;
		dbg_mat.phaseG = RT_PHASE_SURFACE;
		// E2d Task 5. sampleTransmissiveLobe below never touches the coat, but
		// undefined-if-unset applies here too.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));
		// E2e Task 4, same undefined-if-unset rule as the E2b/E2d notes above.
		// Production's clamps: sheenColor is max(.., 0) (Cycles closure.h:120's
		// `max(sheen_tint, zero)`) and sheenRoughness is left RAW here --
		// provably harmless, not merely convenient: clamp(x, 1e-3, 1) ==
		// clamp(clamp(x, 0, 1), 1e-3, 1) for every finite x, so sheenSetup's
		// own internal [1e-3, 1] clamp (bsdf_sheen.h:33) makes production's
		// extra [0,1] pre-clamp a no-op on any value this debug path can
		// produce; skipping it here changes nothing.
		dbg_mat.sheenColor = max(dbg_material.sheen_color, vec3(0.0));
		dbg_mat.sheenRoughness = dbg_material.sheen_roughness;
		dbg_mat.sssWeight = 0.0;
		dbg_mat.sssThin = false;
		dbg_mat.sssRadius = vec3(0.0);
		dbg_mat.sssScale = 0.0;

		vec3 dbg_specularF0 = baseColorToSpecularF0(dbg_mat.baseColor, dbg_mat.metalness, dbg_mat.dielectricF0);
		float dbg_alpha = dbg_mat.roughness * dbg_mat.roughness;

		// MUST use the CORRECTED shading normal, exactly as shade_and_bounce's
		// own `N = ensureValidSpecularReflection(h.face_normal, V, m.normal)`
		// does (F1) -- fix round 2 self-review
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
		vec3 dbg_N = ensureValidSpecularReflection(face_normal, V, final_normal);

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
		bool dbg_ok = sampleTransmissiveLobe(V, dbg_N, face_normal, dbg_alpha, dbg_alpha * dbg_alpha, // F1: production passes h.face_normal
				dbg_specularF0, dbg_mat.eta, dbg_mat.transmissivness, dbg_material.thickness == 0.0,
#ifdef RT_ANISOTROPY_ENABLED
				dbg_transData.ax, dbg_transData.ay, dbg_transData.anisoPhi, dbg_transData.anisoActive,
#endif
				dbg_u3,
				dbg_next_dir, dbg_weight, dbg_is_transmit, dbg_wrong_hemisphere);
		// Fix round 2 self-review: the thin-walled override this defect
		// reorders around ONLY applies when isTransmit is true (`if
		// (isTransmit && thin_walled)`), so only TRANSMIT-lobe rejections are
		// affected by the ordering bug -- REFLECT-lobe rejections (a
		// completely separate, unrelated below-hemisphere phenomenon at high
		// roughness, the same kind the F1 face-normal rejection handles for
		// opaque materials) are untouched either way and,
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
		dbg_mat.smoothNormal = geometry_normal;
		dbg_mat.bumpNormal = final_normal;
		dbg_mat.phaseG = RT_PHASE_SURFACE;
		// E2d Task 5. LOAD-BEARING here, not merely hygienic: this probe calls
		// combinedPdf below, and combinedPdf now reads coatWeight/coatRoughness/
		// coatIor through coatLobeWeight and coatPdf. Left unset these are
		// undefined, and pt_anisotropy_gate's E[1/pdf] reading -- which must stay
		// at 2*PI -- would drift on garbage that has nothing to do with anisotropy.
		dbg_mat.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));
		// E2e Task 4, same undefined-if-unset rule as the E2b/E2d notes above.
		// Production's clamps: sheenColor is max(.., 0) (Cycles closure.h:120's
		// `max(sheen_tint, zero)`) and sheenRoughness is left RAW here --
		// provably harmless, not merely convenient: clamp(x, 1e-3, 1) ==
		// clamp(clamp(x, 0, 1), 1e-3, 1) for every finite x, so sheenSetup's
		// own internal [1e-3, 1] clamp (bsdf_sheen.h:33) makes production's
		// extra [0,1] pre-clamp a no-op on any value this debug path can
		// produce; skipping it here changes nothing.
		dbg_mat.sheenColor = max(dbg_material.sheen_color, vec3(0.0));
		dbg_mat.sheenRoughness = dbg_material.sheen_roughness;
		dbg_mat.sssWeight = 0.0;
		dbg_mat.sssThin = false;
		dbg_mat.sssRadius = vec3(0.0);
		dbg_mat.sssScale = 0.0;

		// Same clamped shading normal shade_and_bounce actually bounces from
		// (mirrors vis mode 33's dbg_N) -- on a sphere this is well away from
		// world Z almost everywhere, which is what makes this probe able to
		// see the two frame fixes at all.
		vec3 dbg_N35 = ensureValidSpecularReflection(face_normal, V, final_normal);

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
				dbg_specularF0_35,
				// Gap #21 cause (a): eta/metalness now select the base Fresnel model.
				dbg_mat.eta, dbg_mat.metalness,
#ifdef RT_ANISOTROPY_ENABLED
				dbg_data35.ax, dbg_data35.ay, dbg_data35.anisoPhi, dbg_data35.anisoActive,
#endif
				dbg_u35, dbg_weight35);

		// Reflection symmetry recovers the half-vector the sampler drew without
		// re-deriving it any other way: Llocal == reflect(-Vlocal, Hlocal) for
		// ANY Hlocal implies Hlocal == normalize(Vlocal + Llocal).
		vec3 dbg_Hlocal35 = normalize(dbg_Vlocal35 + dbg_Llocal35);
		// E3 Task 2. This probe's R channel mirrors combinedPdf's specular
		// density, so it has to take the SAME arm combinedPdf takes: the
		// anisotropic VNDF pdf when the anisotropy state is compiled in, and
		// specularPdf (combinedPdf's own `else`) when it is not. Leaving the
		// anisotropic call here with the state removed would not compile; leaving
		// it while combinedPdf took the isotropic branch would make R and G
		// disagree by construction and turn a correct build into a failing gate.
		// The mode's REAL instrument, dbg_self_norm35, reads combinedPdf alone and
		// is unaffected either way.
#ifdef RT_ANISOTROPY_ENABLED
		vec3 dbg_Vaniso35 = rotateAboutZ(dbg_Vlocal35, -dbg_data35.anisoPhi);
		vec3 dbg_Haniso35 = rotateAboutZ(dbg_Hlocal35, -dbg_data35.anisoPhi);
		// Matches combinedPdf's own VdotH clamp (brdf_inc.glsl:1846) so R and G
		// are not compared under two different clamp conventions.
		float dbg_VdotH35 = max(0.00001, dot(dbg_Vlocal35, dbg_Hlocal35));

		float dbg_sampler_pdf = sampleGGXVNDFReflectionPdfAniso(dbg_Vaniso35, dbg_Haniso35,
				dbg_data35.ax, dbg_data35.ay, dbg_VdotH35);
#else
		float dbg_sampler_pdf = specularPdf(dbg_alpha35, dbg_alpha35 * dbg_alpha35,
				max(0.00001, dbg_Hlocal35.z), max(0.00001, dbg_Vlocal35.z),
				max(0.00001, dot(dbg_Llocal35, dbg_Hlocal35)));
#endif

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
	} else if (vis_mode == 39) {
		// E2d Task 6, probe A: the coat's MULTIPLE-SCATTERING energy tables,
		// evaluated on the GPU so pt_coat_gate can compare them against
		// test_pt_coat_albedo.cpp's CPU mirror.
		//
		// WHY THIS MODE HAS TO EXIST. coatGgxE / coatEnergyScale / coatDarkening
		// (brdf_inc.glsl) are GLSL TRANSCRIPTIONS of CPU functions the doctest
		// suite covers -- but doctest cannot execute GLSL, so the transcriptions
		// themselves have no automated test at all. Every failure mode of a
		// transcription is silent here: a transposed LUT axis
		// (ggxLutRead2D(base, cosNI, rough, ...) instead of
		// (base, rough, cosNI, ...)), a swapped RT_COAT_SSBO_E_OFFSET /
		// RT_COAT_SSBO_EAVG_OFFSET, a 32<->16 dimension slip. All three compile,
		// all three return plausible numbers inside [0,1], and all three only
		// ever reach the image multiplied into an attenuation or a payout where
		// nothing distinguishes them from a slightly different coat.
		//
		// r = E(coat_roughness, cosNI)          -- GGX_E_TABLE, 32x32
		// g = coatEnergyScale(...)              -- PAYOUT multiplier, adds GGX_EAVG_TABLE
		// b = coatDarkening(...)                -- WITHDRAWAL multiplier
		//
		// cosNI is the NdotV parameter, i.e. dot(final_normal, V) floor-clamped
		// to 0.0001 by the caller -- the same quantity vis mode 38 reads, and the
		// same quantity evalCoat feeds coatEnergyScale (there it is
		// coatData.NdotV). Deliberately NOT forced to a constant 1.0: the gate's
		// assertion table is at cosNI == 1.0, and it obtains that from GEOMETRY (a
		// quad squarely facing a narrow-FOV camera, cosNI >= 0.9987 over the
		// crop, where E moves by ~1e-4 -- see pt_coat_gate.gd's probe A comment).
		// Forcing the value here would have made the probe unable to see a wrong
		// cosNI reaching these functions at all.
		//
		// The three arguments carry the SAME clamps shade_and_bounce applies when
		// it builds brdf_mat (raytracing_closest_hit_common_inc.glsl, the
		// brdf_mat.coat* block), not the raw material fields vis mode 38 reads --
		// so what this mode measures is what production evaluates.
		float dbg_ccr39 = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		float dbg_ccior39 = max(dbg_material.clearcoat_ior, 1.0);
		ps.radiance = vec3(
				coatGgxE(dbg_ccr39, NdotV),
				coatEnergyScale(dbg_ccr39, NdotV, dbg_ccior39),
				coatDarkening(dbg_ccr39, NdotV, dbg_ccior39));
	} else if (vis_mode == 40) {
		// E2d Task 6, probe D: THREE-LOBE self-normalising pdf instrument.
		//
		// WHY NOT VIS MODE 35. E2b's instrument draws its direction from
		// sampleSpecularMicrofacet ALONE and accumulates 1/combinedPdf(L). That
		// reads 2*PI only because the anisotropy gate's material is fully
		// metallic and uncoated, which makes combinedPdf's mixture collapse onto
		// the single specular density the draw came from. Point mode 35 at a
		// COATED material and the identity no longer holds even for a perfectly
		// correct pdf: the draw is still p_specular while the report is
		// baseShare*p_spec + coatMass*p_coat, and
		// E_{L~p_spec}[1/G(L)] != 2*PI whenever G != p_spec. A gate built on mode
		// 35 at clearcoat > 0 would therefore fail on correct code, which is why
		// this task adds a second mode instead of repointing that one (a
		// documented deviation from the Task 6 brief; see task-6-report.md).
		//
		// THE IDENTITY THIS MODE USES. Draw L from the FULL production mixture --
		// the same coatLobeWeight/lobeWeight/selectLobe sequence shade_and_bounce
		// runs, then evalIndirectCombinedBRDF, the real sampler -- and accumulate
		// 1/combinedPdf(L). If combinedPdf reports the density the mixture
		// actually realises, E[1/G(L)] is the support's solid-angle measure,
		// 2*PI for the upper hemisphere, INDEPENDENT of every lobe's shape and of
		// the mixture weights. A pdf wrong by a factor k reads back 1/k.
		//
		// What that makes it able to catch, which nothing else in this tree can:
		// the coat term entering combinedPdf's mixture with a weight the sampler
		// does not use (or vice versa), and coatPdf describing different geometry
		// from sampleCoatMicrofacet. Both are mean-preserving MIS desyncs --
		// invisible in any rendered furnace.
		//
		// The three-line dbg_w40[...] assembly below is a HAND COPY of
		// shade_and_bounce's weights[...] block (search this file for
		// `weights[LOBE_COAT] = coatMass`), not a call into it -- there is no
		// shared function for that step, only for the
		// non-trivial terms feeding it (coatLobeWeight, lobeWeight are the
		// shipped functions; selectLobe, evalIndirectCombinedBRDF, combinedPdf
		// below are too). The two copies are textually identical today, which
		// makes this mode's comparison true, but true BY CONSTRUCTION of that
		// duplication rather than by construction of a live call -- if
		// shade_and_bounce's split formula changes and this copy is not
		// updated in lockstep, this mode keeps comparing combinedPdf against a
		// stale split and would not notice. What it actually compares is: this
		// mode's copy of the selection split (built from the same shipped
		// coatLobeWeight/lobeWeight calls shade_and_bounce makes) against
		// combinedPdf's reported density for a direction drawn from that
		// split. Vis mode 32 (pt_coat_gate.gd's probe F) is what reads a
		// production-computed split value directly -- `(1 - coatLobeWeight) *
		// lobeWeight` -- with no second copy to diverge from.
		MaterialProperties dbg_mat40;
		dbg_mat40.baseColor = albedo;
		dbg_mat40.metalness = metalness;
		dbg_mat40.roughness = roughness;
		vec3 dbg_f0_40;
		float dbg_eta_40;
		resolveDielectricF0(dbg_material.ior, specular, dbg_material.specular_factor,
				dbg_material.specular_tint, dbg_f0_40, dbg_eta_40);
		dbg_mat40.dielectricF0 = dbg_f0_40;
		dbg_mat40.emissive = vec3(0.0);
		dbg_mat40.transmissivness = RT_GET_TRANSMISSION_ENABLED() ? dbg_material.transmission : 0.0;
		dbg_mat40.eta = dbg_eta_40;
		dbg_mat40.opacity = 1.0;
		dbg_mat40.anisotropy = dbg_material.anisotropy;
		dbg_mat40.anisotropyRotation = dbg_material.anisotropy_rotation; // already RADIANS
		dbg_mat40.tangent = world_tangent;
		dbg_mat40.smoothNormal = geometry_normal;
		dbg_mat40.bumpNormal = final_normal;
		dbg_mat40.phaseG = RT_PHASE_SURFACE;
		dbg_mat40.coatWeight = max(dbg_material.clearcoat, 0.0);
		dbg_mat40.coatRoughness = clamp(dbg_material.clearcoat_roughness, 0.0, 1.0);
		dbg_mat40.coatIor = max(dbg_material.clearcoat_ior, 1.0);
		dbg_mat40.coatTint = max(dbg_material.clearcoat_tint, vec3(0.0));
		// E2e Task 4. LOAD-BEARING here: this probe calls both selectLobe and
		// combinedPdf below, and both now read the sheen fields.
		dbg_mat40.sheenColor = max(dbg_material.sheen_color, vec3(0.0));
		dbg_mat40.sheenRoughness = dbg_material.sheen_roughness;
		dbg_mat40.sssWeight = 0.0;
		dbg_mat40.sssThin = false;
		dbg_mat40.sssRadius = vec3(0.0);
		dbg_mat40.sssScale = 0.0;

		// Same clamped shading normal shade_and_bounce bounces from (mirrors vis
		// modes 33/35). On a sphere this is well away from world Z almost
		// everywhere, which is what keeps E2b's two frame fixes live here too.
		vec3 dbg_N40 = ensureValidSpecularReflection(face_normal, V, final_normal);
		// UNCLAMPED dot(N, V), matching shade_and_bounce's cosNI and combinedPdf's
		// -- data.NdotV is floored at 1e-5 and would silently desync the two.
		float dbg_cosNI40 = dot(dbg_N40, V);

		// E3 Task 2: mirrors shade_and_bounce's own gating exactly -- a compiled-out
		// layer's mass is a literal 0.0f, so this probe's copy of the split stays
		// textually identical to production's in every combination, which is the
		// property the comment above says makes the comparison meaningful.
#ifdef RT_COAT_ENABLED
		float dbg_coatMass40 = coatLobeWeight(dbg_mat40, dbg_cosNI40);
#else
		float dbg_coatMass40 = 0.0;
#endif
		float dbg_pSpec40 = lobeWeight(dbg_mat40);
		// E2e Task 4. The array is sized by LOBE_COUNT, which is now 4 -- leaving
		// the fourth entry unwritten would hand selectLobe an undefined weight,
		// which is not a subtle failure but the whole probe reading garbage. The
		// split mirrors shade_and_bounce's exactly (sheen off the top, then coat
		// from what remains); at sheenColor == 0 dbg_afterSheen40 is exactly 1.0f
		// and every entry is bit-identical to the E2d form.
#ifdef RT_SHEEN_ENABLED
		float dbg_sheenMass40 = sheenLobeWeight(dbg_mat40, dbg_N40, V);
#else
		float dbg_sheenMass40 = 0.0;
#endif
		float dbg_afterSheen40 = 1.0 - dbg_sheenMass40;
		float dbg_baseShare40 = dbg_afterSheen40 * (1.0 - dbg_coatMass40);
		float dbg_w40[LOBE_COUNT];
		dbg_w40[LOBE_SPECULAR] = dbg_baseShare40 * dbg_pSpec40;
		dbg_w40[LOBE_DIFFUSE] = dbg_baseShare40 * (1.0 - dbg_pSpec40);
#ifdef RT_COAT_ENABLED
		dbg_w40[LOBE_COAT] = dbg_afterSheen40 * dbg_coatMass40;
#endif
#ifdef RT_SHEEN_ENABLED
		dbg_w40[LOBE_SHEEN] = dbg_sheenMass40;
#endif

		RNGState dbg_rng40 = rng_unpack(ps.rng_packed, gl_LaunchIDEXT.xy);
		int dbg_lobe40 = selectLobe(rng_1d(dbg_rng40, RT_PRNG_LOBE), dbg_w40);
		int dbg_brdfType40 = SPECULAR_TYPE;
		// E3 Task 2: the DIFFUSE arm is hoisted to the head of the chain so the
		// two conditional arms can be #ifdef'd off the tail without leaving a
		// dangling `else if`. All three tests are equality against the SAME
		// integer and are therefore mutually exclusive, so reordering them is
		// exactly equivalent -- no dead placeholder branch is introduced.
		if (dbg_lobe40 == LOBE_DIFFUSE) {
			dbg_brdfType40 = DIFFUSE_TYPE;
#ifdef RT_COAT_ENABLED
		} else if (dbg_lobe40 == LOBE_COAT) {
			dbg_brdfType40 = COAT_TYPE;
#endif
#ifdef RT_SHEEN_ENABLED
		} else if (dbg_lobe40 == LOBE_SHEEN) {
			dbg_brdfType40 = SHEEN_TYPE;
#endif
		}

		vec2 dbg_u40 = rng_2d(dbg_rng40, RT_PRNG_SURFACE_BSDF);
		vec3 dbg_dir40 = vec3(0.0);
		vec3 dbg_weight40 = vec3(0.0);
		bool dbg_ok40 = evalIndirectCombinedBRDF(dbg_u40, dbg_N40, geometry_normal, V,
				dbg_mat40, dbg_brdfType40, dbg_dir40, dbg_weight40, vec4(0.0));

		// Same hemisphere guard mode 35 applies, and for the same reason:
		// combinedPdf's own `dot(N,L) <= 0` early-out returns 0.0, which is not a
		// desync but a question production never asks (evalIndirectCombinedBRDF
		// has already rejected those directions via dbg_ok40).
		bool dbg_valid40 = dbg_ok40 && dot(dbg_N40, dbg_dir40) > 0.0;
		float dbg_reported40 = dbg_valid40 ? combinedPdf(dbg_N40, dbg_dir40, V, dbg_mat40) : 0.0;
		float dbg_selfnorm40 = (dbg_valid40 && dbg_reported40 > 0.0) ? (1.0 / dbg_reported40) : 0.0;

		// r = 1.0 when the draw was accepted, 0.0 otherwise. Accumulated, this is
		// the ACCEPTANCE RATE, and the gate needs it: every rejected sample
		// contributes 0 to b, so E[b] converges to 2*PI only if acceptance is ~1.
		// Without r a low acceptance rate would look exactly like a pdf that is
		// too large, and the gate would report the wrong defect.
		// g = combinedPdf's report for the drawn direction (diagnostic).
		// b = 1/G(L) or 0 -- the real instrument, averaged against 2*PI.
		ps.radiance = vec3(dbg_valid40 ? 1.0 : 0.0, dbg_reported40, dbg_selfnorm40);
	} else if (vis_mode == 41) {
		// E2e Task 3: sheenSetup's transformA/transformB/albedo, evaluated on
		// the GPU so the gate can compare them against test_pt_sheen.cpp's CPU
		// mirror. Follows vis mode 38's pattern (coatAlbedoEstimate) and reads
		// nothing sheenSetup itself does not already clamp/derive.
		//
		// THIS IS THE INSTRUMENT FOR THE AXIS ORDER. Task 1 Step 4 established
		// that the CPU tests structurally cannot catch a transposed
		// sheenLutRead2D(base, cosNI, roughness) call at sheenSetup's own call
		// site -- swapping the two arguments there compiles, stays in range,
		// and every CPU test stays green, because the CPU tests exercise the
		// reader function directly and never the GLSL call site that feeds it.
		// Task 5's gate reads this mode at a point where the transposed order
		// gives a different answer, the same way vis mode 39 is the only
		// instrument that can catch a transposed ggxLutRead2D call.
		//
		// r = transformA, g = 0.5 + 0.5*transformB, b = ltcAlbedo, all read at
		// this hit's clamped shading normal, the view vector, and the material's
		// (unclamped -- sheenSetup clamps internally) sheen_roughness.
		//
		// E2e Task 5: THE GREEN CHANNEL IS SIGN-ENCODED, AND IT HAS TO BE.
		// Task 3 shipped this mode emitting the raw `dbg_sheen41.b`, and the
		// first run of pt_sheen_gate.gd read it back as EXACTLY 0.000000 where
		// the CPU mirror of sheen_ltc_table.h says -0.094282. The path is not
		// the shader's: every payload write goes through path_pack ->
		// sanitize_payload_value (raytracing_inc.glsl:88-91), which clamps
		// radiance to [0, RT_PAYLOAD_VALUE_CLAMP], and path_unpack applies
		// max(p.radiance, 0) again on the way back out. A NEGATIVE debug value
		// therefore cannot survive the payload at all.
		//
		// transformB is negative in 909 of the table's 1024 cells and its whole
		// range is [-0.181330, 0.001960], so the raw form made this channel read
		// a constant 0 over 89% of the table -- an instrument that could not see
		// the quantity it was added for, and could not fail. 0.5 + 0.5*b maps
		// [-1, 1] onto [0, 1] with an order of magnitude of headroom over the
		// real range; the gate decodes with b = 2*(g - 0.5).
		//
		// The other two channels are unaffected: transformA is in [0, 0.879580]
		// and the albedo in [0, 0.749730], both non-negative over the whole
		// table, so they are still emitted raw.
		vec3 dbg_N41 = ensureValidSpecularReflection(face_normal, V, final_normal);
		SheenData dbg_sheen41 = sheenSetup(dbg_N41, V, dbg_material.sheen_roughness);
		ps.radiance = vec3(dbg_sheen41.a, 0.5 + 0.5 * dbg_sheen41.b, dbg_sheen41.albedo);
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
	// Gap #26: the skip id describes the segment that just ENDED. Cleared here
	// so every outcome of this hit defaults to "no skip"; only the two
	// through-events below set it again.
	ps.skip_geom = RT_SKIP_NONE;
	ps.skip_prim = RT_SKIP_NONE;
#ifdef RT_SSS_ENABLED
	// E3: this hit is the EXIT of a random walk (ps.sss_exit). Cycles'
	// subsurface_shader_data_setup replaces the whole shader with a diffuse
	// closure of weight 1 on the bump-mapped normal: no emission, no specular,
	// no coat/sheen/transmission, no second subsurface here. The walk already
	// paid the albedo; the exit is a WHITE Lambertian.
	const bool sss_exit_hit = ps.sss_exit;
	if (sss_exit_hit) {
		ps.sss_exit = false;
		m.albedo = vec3(1.0);
		m.alpha = 1.0;
		m.blends = false;
		m.metalness = 0.0;
		m.specular = 0.0;
		m.emissive = vec3(0.0);
		m.transmission = 0.0;
		m.roughness = 1.0;
	}
#else
	const bool sss_exit_hit = false;
#endif

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

	// F1: Cycles' bump-map correction (bsdf_util.h:322). Returns m.normal
	// untouched unless the mirror direction of V would enter the true face; then
	// rotates it toward h.face_normal by the minimum angle. Everything below --
	// NEE, env NEE, emissive NEE, the sampler, the MIS pdf, the guide normals --
	// shades from THIS N.
	vec3 N = ensureValidSpecularReflection(h.face_normal, V, m.normal);
	float NdotV = max(dot(N, V), 0.0001);

	uint total_bounces = get_total_bounces(ps.packed_bounces_flags);
	uint diffuse_bounces = get_diffuse_bounces(ps.packed_bounces_flags);
	uint glossy_bounces = get_glossy_bounces(ps.packed_bounces_flags);

	// Environment fog for this ray segment (before surface contribution).
	apply_segment_fog(gl_HitTEXT, ps.radiance, ps.throughput);

	// Overall bounce budget, and the transmission budget the transparent closure
	// below spends. HOISTED above the transparent branch (they used to live in
	// the per-lobe cap block further down) because that branch needs them and
	// must not be reached through the diffuse/glossy caps: a transparent
	// pass-through takes neither lobe, so terminating it on a lobe budget would
	// black out whatever is behind an alpha surface for no physical reason. The
	// cap block below reuses these -- the min(.., 15u) clamp is load-bearing and
	// exists exactly once.
	//
	// min(..., 15u) (fix round 1, M1) is not defensive: the transmission-bounce
	// counter is only 4 bits (raytracing_inc.glsl) and inc_transmission_bounce
	// does not itself saturate at 15 -- incrementing past it carries into
	// INSIDE_MEDIUM_FLAG (bit 31) and can wrap the whole packed word to zero if
	// that bit was already set, silently clearing every counter and flag.
	// resolve_bounce_cap alone can return up to max_total (16) when
	// RT_GET_MAX_TRANSMISSION_BOUNCE() is 0 (a raw RenderingServer with the
	// setting unset), so this clamp is what actually prevents that. The raygen
	// loop bound resolves the same cap the same way.
	const uint max_total = RT_GET_MAX_BOUNCES();
	const uint max_transmission = min(resolve_bounce_cap(float(RT_GET_MAX_TRANSMISSION_BOUNCE()), max_total), 15u);
	const uint transmission_bounces = get_transmission_bounces(ps.packed_bounces_flags);

	// Transparent BSDF closure (Cycles' CLOSURE_BSDF_TRANSPARENT_ID). A material
	// that BLENDS passes the ray straight through with probability (1 - alpha);
	// the complementary alpha share is shaded normally below. Stochastic rather
	// than accumulative so the choice is order independent and stacked layers
	// each contribute at their own weight.
	//
	// Placed AFTER segment fog -- the ray really did travel gl_HitTEXT of fog to
	// reach this surface -- but BEFORE the emissive contribution and before NEE:
	// a ray that passes through contributes no emission and does no direct
	// lighting at this vertex, because no scattering event happened here.
	//
	// Gated on the BLEND flag, not on alpha < 1: alpha-SCISSOR materials are
	// already in the TLAS and their base-colour alpha can exceed the scissor
	// threshold while remaining below 1.0, so an alpha-value test would turn
	// every cutout translucent. The `m.alpha < 1.0` term is the second half of
	// the gate, not the whole of it -- it is what makes an alpha = 1.0 BLEND
	// surface shade identically to an opaque one.
	if (m.blends && m.alpha < 1.0) {
		if (transmission_bounces >= max_transmission) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		if (rng_1d(rng, RT_PRNG_TRANSPARENT) < (1.0 - m.alpha)) {
			// Straight through. Throughput is unchanged: the stochastic draw
			// already carries the (1 - alpha) weight, so the branch weight is 1.
			ps.packed_bounces_flags = inc_transmission_bounce(ps.packed_bounces_flags);
			ps.hit_t = gl_HitTEXT;
			// h.geometry_normal is flipped toward the incoming ray by
			// compute_hit_data, and raygen offsets the next origin ALONG this
			// normal (offset_ray_origin, scene_raytracing_raygen.glsl), so it
			// must be negated to land PAST the surface rather than in front of
			// it -- the same reason the transmissive lobe negates below.
			ps.offset_normal = -h.geometry_normal;
			ps.next_ray_dir = gl_WorldRayDirectionEXT;
			// Gap #26: through-event. The next ray may hit anything at any
			// distance except this triangle.
			ps.skip_geom = gl_InstanceCustomIndexEXT;
			ps.skip_prim = gl_PrimitiveID;
			ps.rng_packed = rng_pack(rng_next_bounce(rng));
			// INSIDE_MEDIUM_FLAG is deliberately untouched. It means "the ray
			// about to be traced is inside a solid", and it drives both the
			// back-face-culling drop in raygen and the Beer-Lambert multiply at
			// the top of this function. A transparent pass-through is not a
			// refraction: it enters no medium and travels no path length through
			// one, so toggling the flag here would either start absorbing over a
			// distance the ray never spent in glass, or clear it out from under a
			// ray that is genuinely still inside one.
			//
			// mis_ray_pdf is untouched for the same reason: no scattering event
			// occurred, so the next vertex's MIS weight must still describe the
			// lobe that produced this ray, at the vertex that produced it.
			path_pack(payload, ps);
			return;
		}
	}

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
	// max_total, max_transmission and transmission_bounces are hoisted above the
	// transparent closure earlier in this function -- that branch needs them and
	// must sit above this block. Roadmap E1: the transmission cap comes from
	// RT_FLAGS rather than rt_params because all sixteen rt_params slots are
	// assigned -- the same reason B4's min_bounce and C1's emissive enable are
	// project settings rather than Environment params
	// (scene_shader_raytracing.cpp:643-648).
	const uint max_diffuse = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_DIFFUSE_BOUNCE), max_total);
	const uint max_glossy = resolve_bounce_cap(get_rt_param(RT_PARAM_MAX_GLOSSY_BOUNCE), max_total);
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
	// (Step 5 gates it on thickness > 0).
	//
	// GAP #24 (2026-09-12): A THIN-WALLED SURFACE MUST NOT FLIP ETA ON ITS
	// BACK FACE. The earlier text here said the opposite -- "a back-side hit
	// on a thin surface still needs the flipped Fresnel split" -- and that
	// produced the fish-tank side-panel mirrors (roadmap 11.17). A thin wall
	// has no interior: the ray was NOT bent at the first face, so the second
	// face of a double-sided slab (every glTF glass pane is authored
	// doubleSided) is hit from behind at the SAME angle the outer face saw.
	// With eta flipped to 1/ior that is total internal reflection for every
	// angle past asin(1/ior) -- 41.8 degrees at 1.5, 56.4 at the pipeline's
	// 1.2 -- and the pane turns into a 100% mirror exactly where a side panel
	// is viewed, while staying clear near normal incidence. Cycles' thin wall
	// (bsdf_thin_glass_fresnel, bsdf_microfacet.h:1236-1280) evaluates the
	// sheet's back side at the REFRACTED angle and 1/ior, which by reciprocity
	// is the front-side reflectance again: a thin sheet cannot TIR, and its
	// back face carries the exterior Fresnel. So does ours now, from either
	// face. THICK media (thickness > 0) keep the flip: there the ray really
	// did refract into the medium, and the exit face really can TIR.
	// pt_transmission_gate.gd probe 3b holds this at 70 degrees: T = 0.17
	// before, [0.66, 0.72] expected.
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
	brdf_mat.eta = (h.is_front_face || m.thickness == 0.0)
			? resolved_eta
			: ((resolved_eta > 0.0) ? (1.0 / resolved_eta) : resolved_eta); // Gap #24: thin walls never flip.
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
	// F1: the two normals bump_shadowing_term keys on; see MaterialProperties.
	brdf_mat.smoothNormal = h.geometry_normal;
	brdf_mat.bumpNormal = m.normal;
	brdf_mat.phaseG = RT_PHASE_SURFACE; // F2: a surface, not a scatter point
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
	// E2e sheen. Read from raw_mat for the same reason the coat is: MaterialResult
	// carries no sheen fields.
	//
	// Cycles' clamps, svm/closure.h:120-121. sheen_tint is max(.., 0) and
	// sheen_roughness is saturatef()'d there; sheenSetup ALSO clamps roughness
	// to [1e-3, 1] internally (bsdf_sheen.h:33). The two are mathematically
	// IDENTICAL for finite input -- clamp(x, 1e-3, 1) == clamp(clamp(x, 0, 1),
	// 1e-3, 1) for every finite x -- so this explicit [0,1] step exists to
	// mirror Cycles' own saturatef() call, not because sheenSetup's clamp
	// would otherwise be reached by an out-of-range value; the debug sites
	// above that skip it are not thereby unsafe. sheenColor is the ONLY gate;
	// a material with no sheen still arrives here carrying whatever roughness
	// it was authored with, so gating on roughness would switch sheen on
	// scene-wide.
	brdf_mat.sheenColor = max(raw_mat.sheen_color, vec3(0.0));
	brdf_mat.sheenRoughness = clamp(raw_mat.sheen_roughness, 0.0, 1.0);
#ifdef RT_SSS_ENABLED
	// E3. Cycles bssrdf_setup: a channel whose radius (after scale) is below
	// BSSRDF_MIN_RADIUS is diffuse for that channel; if all three are, the
	// material has no subsurface closure at all. Anisotropy is fixed at 0.
	brdf_mat.sssWeight = clamp(raw_mat.sss_weight, 0.0, 1.0);
	brdf_mat.sssThin = (raw_mat.flags & RT_MAT_FLAG_SSS_THIN) != 0u;
	brdf_mat.sssScale = max(raw_mat.sss_scale, 0.0);
	brdf_mat.sssRadius = max(raw_mat.sss_radius * brdf_mat.sssScale, vec3(0.0));
	if (!brdf_mat.sssThin && max(max(brdf_mat.sssRadius.r, brdf_mat.sssRadius.g), brdf_mat.sssRadius.b) < 1e-8) {
		brdf_mat.sssWeight = 0.0;
	}
	if (sss_exit_hit) {
		brdf_mat.coatWeight = 0.0;
		brdf_mat.sheenColor = vec3(0.0);
		brdf_mat.sssWeight = 0.0;
		brdf_mat.transmissivness = 0.0;
		brdf_mat.dielectricF0 = vec3(0.0);
	}
#else
	brdf_mat.sssWeight = 0.0;
	brdf_mat.sssThin = false;
	brdf_mat.sssRadius = vec3(0.0);
	brdf_mat.sssScale = 0.0;
#endif

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
		rt_accum_guide_sample(pixel, diffuse_albedo, N);

		// Specular hit distance via inline ray query (only for smooth surfaces).
		float spec_hit_dist = -1.0;
		if (m.roughness < MAX_DENOISER_SPECULAR_HIT_THRESHOLD) {
			vec3 spec_dir = reflect(-V, N);
			vec3 spec_origin = offset_ray_origin(h.hit_pos, spec_dir);

			rayQueryEXT spec_rq;
			rayQueryInitializeEXT(spec_rq, tlas, RT_RAY_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT,
					0xFF, spec_origin, 0.001, spec_dir, RT_RAY_TMAX);
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
#if RT_ENV_NEE_ENABLED
	{
		vec3 env_dir;
		float env_pdf_val;
		// env_sample() returns r_dir in WORLD space already -- it applies
		// transpose(env_world_to_sky()) internally (Task 3). Rotating it again here
		// would trace into a direction whose pdf is the one reported for a
		// different direction, which is exactly the silent MIS bias the env
		// sampling header warns about.
		if (env_sample(h.hit_pos, rng_2d(rng, RT_PRNG_ENV), env_dir, env_pdf_val) && (dot(env_dir, N) > 0.0 || dot(env_dir, diffuseLobeNormal(N, brdf_mat)) > 0.0)) { // F1 approach C
			vec3 env_origin = offset_ray_origin(h.hit_pos, h.geometry_normal);
			vec3 env_shadow_atten = lights_trace_shadow_ray(env_origin, env_dir, RT_RAY_TMAX);
			if (rt_max_component(env_shadow_atten) > 0.0) {
				// Same fetch the miss stage performs for this direction: bordered
				// octmap lookup after the shared world -> sky rotation.
				vec3 sky_rad = env_sky_radiance(env_dir) * env_shadow_atten;

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
					vec3 f_diff, f_spec, f_coat, f_sheen;
					evalCombinedBRDFSeparate(N, env_dir, V, brdf_mat, f_diff, f_spec, f_coat, f_sheen);

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
					// Gap #20: routed through the dielectric dispatcher so a
					// transmissive surface's reflected lobe is compensated here
					// exactly as the sampler compensates it.
					f_spec *= evalMultiScatterFactorDielectric(ms_alpha,
							ggxRoughForMaterial(ms_alpha, brdf_mat, N), NdotV, specularF0,
							brdf_mat.eta, brdf_mat.transmissivness);
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
					// E2e: sheen is added UNCONDITIONALLY, with no near-delta
					// guard and no multiple-scattering factor.
					//   * No delta guard: the Zeltner LTC has no near-delta
					//     regime at all. combinedPdf's sheen term is likewise
					//     ungated, so adding it here keeps value and density
					//     describing the same lobe set -- which is the only thing
					//     those guards exist to preserve. Copying the coat's
					//     guard would have keyed sheen's visibility on a
					//     roughness that governs a different lobe.
					//   * No ms factor: evalMultiScatterApproximation is a GGX
					//     correction. The sheen LTC is ALREADY a multiple-
					//     scattering fit (Zeltner 2022), and the BSDF strategy's
					//     realised weight for a sheen sample is sheenColor *
					//     ltcAlbedo -- exactly what evalSheen returns times
					//     eval/pdf == 1 -- so the two strategies already estimate
					//     one integrand.
					bsdf_val += f_sheen;
				}
				float bsdf_pdf_for_dir = combinedPdf(N, env_dir, V, brdf_mat);

				float w = power_heuristic(env_pdf_val, bsdf_pdf_for_dir);
				vec3 contrib = ps.throughput * bsdf_val * sky_rad * (w / env_pdf_val);
				ps.radiance += clamp_contribution(contrib, clamp_limit);
			}
		}
	}
#endif // RT_ENV_NEE_ENABLED

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
	// E3 Task 2: cosNI exists only to feed coatLobeWeight, so it is gated with
	// it. A compiled-out layer's mass becomes a literal 0.0f, which makes every
	// downstream expression an IEEE identity on the surviving terms rather than a
	// restructured formula -- see combinedPdf's matching note, and note that the
	// two must stay textually parallel or the split desyncs.
#ifdef RT_COAT_ENABLED
	float cosNI = dot(N, V);
	// coatMass is the CLAMPED selection probability. Fix round 1 (E2d) also
	// needed the RAW throughput withdrawal, coatLayerAlbedo, here; E2e moved
	// that call inside layerTransmittanceAbove, at the point below where the
	// selected lobe is actually known -- same function, same inputs, so the
	// value is bit-identical to computing it here. See the two-roles block
	// above coatLayerAlbedo in brdf_inc.glsl for the energy error the clamped
	// one caused when it was used for both roles.
	float coatMass = coatLobeWeight(brdf_mat, cosNI);
#else
	float coatMass = 0.0;
#endif
	// E2e. Sheen's selection mass, on the SAME world-space N and V combinedPdf
	// feeds sheenLobeWeight -- the two splits have to agree direction by
	// direction for the same reason cosNI above does. sheenLobeWeight takes N and
	// V rather than cosNI because sheenSetup derives cosNI = dot(N, V) itself,
	// which keeps the invalid-LTC test at one site; see its doc comment.
#ifdef RT_SHEEN_ENABLED
	float sheenMass = sheenLobeWeight(brdf_mat, N, V);
#else
	float sheenMass = 0.0;
#endif

	int brdfType;
	// E2e: the lobe actually selected, in every branch including the two fast
	// paths below (which never call selectLobe but still resolve to a known
	// lobe). layerTransmittanceAbove reads this to decide self-attenuation,
	// replacing the old `tookCoatLobe` bool.
	int lobe;
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
	//
	// E2e adds `sheenMass <= 0.0` to both fast paths, for the identical reason
	// E2d added `coatMass <= 0.0`: a sheen material that took the specular fast
	// path would never draw a lobe, so its sheen would be inert on exactly the
	// materials this phase exists for (a pure-metal fast path plus fuzz is
	// brushed metal; the diffuse one plus fuzz is velvet, the phase's own
	// acceptance target). Appended AFTER the coat clause rather than in front of
	// it so the existing short-circuit prefix is untouched; at sheenColor == 0
	// sheenLobeWeight returns literal 0.0, the added conjunct is true, and the
	// identical arm is taken on the identical evaluation order.
	// E3 adds `sssMass <= 0.0` to both fast paths for the identical reason
	// again: a subsurface material with no specular would take the diffuse fast
	// path and never draw the subsurface lobe.
#ifdef RT_SSS_ENABLED
	float sssMass = sssSelectShare(brdf_mat);
#else
	const float sssMass = 0.0;
#endif
	if (coatMass <= 0.0 && sheenMass <= 0.0 && sssMass <= 0.0 && diffuseLum < 0.0001) {
		brdfType = SPECULAR_TYPE;
		lobe = LOBE_SPECULAR;
	} else if (coatMass <= 0.0 && sheenMass <= 0.0 && sssMass <= 0.0 && specularLum < 0.0001) {
		brdfType = DIFFUSE_TYPE;
		lobe = LOBE_DIFFUSE;
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
		//
		// E2e: sheen takes its mass FIRST, off the whole, and the coat then takes
		// its share of what sheen leaves -- matching the withdrawal order in
		// layerTransmittanceAbove, which matches Cycles' allocation order (sheen
		// svm/closure.h:115, coat :146). The four weights sum to 1 in exact
		// arithmetic; selectLobe absorbs the float residue by falling through to
		// the last NON-ZERO lobe (see its comment -- that repair exists because
		// appending a fourth, usually-zero entry is what made the residue window
		// reachable).
		//
		// At sheenMass == 0 afterSheen is exactly 1.0f, so `afterSheen * x == x`
		// is the IEEE multiplicative identity and all three E2d weights are
		// bit-identical.
		float afterSheen = 1.0 - sheenMass;
		float baseShare = afterSheen * (1.0 - coatMass);
		float pSpec = lobeWeight(brdf_mat);

		float weights[LOBE_COUNT];
		weights[LOBE_SPECULAR] = baseShare * pSpec;
#ifdef RT_SSS_ENABLED
		// E3: the diffuse share splits by sssSelectShare (see brdf_inc.glsl),
		// the same function combinedPdf and evalCombinedBRDFSeparate use.
		weights[LOBE_DIFFUSE] = baseShare * (1.0 - pSpec) * (1.0 - sssSelectShare(brdf_mat));
		weights[LOBE_SUBSURFACE] = baseShare * (1.0 - pSpec) * sssSelectShare(brdf_mat);
#else
		weights[LOBE_DIFFUSE] = baseShare * (1.0 - pSpec);
#endif
#ifdef RT_COAT_ENABLED
		weights[LOBE_COAT] = afterSheen * coatMass;
#endif
#ifdef RT_SHEEN_ENABLED
		weights[LOBE_SHEEN] = sheenMass;
#endif

		// STILL exactly one draw, consumed once, unremapped and unrescaled. A
		// second draw or a remap here shifts every subsequent sample in the path --
		// statistically valid, bitwise different everywhere, and invisible to every
		// gate. E2e did NOT add a second draw for sheen: the fourth weight joins
		// the same CDF this one draw walks.
		lobe = selectLobe(rng_1d(rng, RT_PRNG_LOBE), weights);
		// E3 Task 2: the SPECULAR arm is hoisted to the head of the chain so the
		// two layer arms can be #ifdef'd off the middle without leaving a
		// dangling `else if`. Every test is equality against the same integer
		// `lobe` and the trailing `else` was already the catch-all for DIFFUSE,
		// so the mapping is unchanged for every value selectLobe can return --
		// this is a reordering of mutually exclusive tests, not a behaviour
		// change, and it introduces no dead placeholder branch.
		if (lobe == LOBE_SPECULAR) {
			brdfType = SPECULAR_TYPE;
			ps.throughput /= weights[LOBE_SPECULAR];
#ifdef RT_SHEEN_ENABLED
		} else if (lobe == LOBE_SHEEN) {
			brdfType = SHEEN_TYPE;
			// Divide by the selection probability ALONE, like specular and
			// diffuse and unlike the coat. The coat needs an extra `coatWeight *`
			// because sampleCoatMicrofacet's weight omits the closure weight;
			// evalIndirectCombinedBRDF's SHEEN_TYPE arm returns the FULL closure
			// weight (sheenColor * ltcAlbedo), so applying a second factor here
			// would double it -- the mirror image of the E2d fix-round-1 bug.
			ps.throughput /= weights[LOBE_SHEEN];
#endif
#ifdef RT_COAT_ENABLED
		} else if (lobe == LOBE_COAT) {
			brdfType = COAT_TYPE;
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
#endif
#ifdef RT_SSS_ENABLED
		} else if (lobe == LOBE_SUBSURFACE) {
			brdfType = SUBSURFACE_TYPE;
			ps.throughput /= weights[LOBE_SUBSURFACE];
#endif
		} else {
			brdfType = DIFFUSE_TYPE;
			ps.throughput /= weights[LOBE_DIFFUSE];
		}
	}

	// E2d: the layering half. Without it the coat is ADDITIVE -- a lobe that
	// returns light the base still returns in full -- which is the wrong render,
	// which is why the lobe and this block land in one commit.
	//
	// E2e: routed through layerTransmittanceAbove(brdf_mat, N, V, lobe), the
	// same walk evalCombinedBRDFSeparate now uses. Passing the actually-selected
	// `lobe` replaces the old `!tookCoatLobe` guard: at lobe == LOBE_COAT the
	// walk's `lobeIndex < LOBE_COAT` test is false, so it returns exactly
	// (1,1,1) without ever calling coatLayeringTransmittance -- bit-identical
	// to skipping this block entirely, which is what the old guard did. The
	// outer coatWeight epsilon check stays: it is what keeps this block (and
	// the sqrt/pow inside the Beer's-law branch of coatLayeringTransmittance)
	// off the hot path for every uncoated material, not a correctness guard --
	// layerTransmittanceAbove is already a no-op at coatWeight == 0 because
	// coatLayerAlbedo returns literal 0.0f there.
	//
	// E2e Task 4: the guard is "any layer at all", not "coat". A sheen-only
	// material has coatWeight == 0 and would have skipped the withdrawal
	// entirely, making sheen ADDITIVE on the BSDF-sampling side while
	// evalCombinedBRDFSeparate withdrew it on the NEE side -- two strategies,
	// two integrands. Same defect the coat's own guard would have had if E2d had
	// written it as `if (clearcoat_roughness > 0)`.
	//
	// E3 Task 2: each disjunct is compiled out with its layer, and with neither
	// compiled in the whole block goes. That is correct, not merely an
	// optimisation: layerTransmittanceAbove returns exactly float3(1,1,1) with no
	// layers, so `ps.throughput *=` it would be the IEEE multiplicative identity.
#if defined(RT_COAT_ENABLED) || defined(RT_SHEEN_ENABLED)
#if defined(RT_COAT_ENABLED) && defined(RT_SHEEN_ENABLED)
	if (brdf_mat.coatWeight > 0.00001 || sheenMaxTint(brdf_mat) > 0.00001) {
#elif defined(RT_COAT_ENABLED)
	if (brdf_mat.coatWeight > 0.00001) {
#else
	if (sheenMaxTint(brdf_mat) > 0.00001) {
#endif
		// THIS IS A THROUGHPUT FACTOR, NOT A SELECTION PROBABILITY. It must not be
		// folded into weights[] above -- see the selection-vs-throughput block at
		// the top of brdf_inc.glsl's registry section. Folding it in and
		// renormalising would still integrate to the right mean (MIS is unbiased
		// for ANY weights summing to 1 pointwise), so the error would be
		// mean-preserving and invisible to every rendered gate this project has.
		//
		// Fix round 1: routed through coatLayeringTransmittance, the SAME function
		// evalCombinedBRDFSeparate calls for every NEE path, fed the same RAW
		// coatAlbedo (now computed inside layerTransmittanceAbove itself, from the
		// same cosNI). Before that, BSDF sampling applied a layer NEE knew nothing
		// about, so the two MIS strategies estimated different integrands. The
		// attenuation and the Beer's-law tint remain two separate steps inside that
		// function, per Cycles (svm/closure.h:155 vs :178).
		//
		// E2e: N and V rather than cosNI. layerTransmittanceAbove derives
		// dot(N, V) internally from the same two vectors, so the coat sees the
		// identical unclamped expression; sheen additionally needs the pair to
		// reach sheenSetup. At lobe == LOBE_SHEEN the walk's `lobeIndex <
		// LOBE_SHEEN` is false and `< LOBE_COAT` is false too, so it returns
		// exactly (1,1,1) -- sheen never attenuates itself and nothing sits
		// above it.
		ps.throughput *= layerTransmittanceAbove(brdf_mat, N, V, lobe);
	}
#endif // RT_COAT_ENABLED || RT_SHEEN_ENABLED

	vec2 u = rng_2d(rng, RT_PRNG_SURFACE_BSDF);
	vec3 next_dir;
	vec3 brdf_weight;

	bool took_transmissive_lobe = false;
	bool transmissive_sample_ok = false;
	if (brdfType == SPECULAR_TYPE && brdf_mat.transmissivness > 0.0) {
		float alpha = brdf_mat.roughness * brdf_mat.roughness;
		float3 u3 = float3(u, rng_1d(rng, RT_PRNG_TRANSMIT));
		// E2b: ax/ay/anisoPhi for THIS hit's N, via prepareBRDFData -- the same
		// tangent-projection formula every other consumer uses (V is a dummy L,
		// unused for these three fields).
		// E3 Task 2: this whole BrdfData exists only to supply the four aniso
		// arguments below, so it is gated with them -- otherwise the transmissive
		// path would still pay a full prepareBRDFData per bounce for a struct
		// nothing reads.
#ifdef RT_ANISOTROPY_ENABLED
		BrdfData transData = prepareBRDFData(N, V, V, brdf_mat);
#endif
		// Fix round 2: calls sampleTransmissiveLobe (brdf_inc.glsl), which
		// encapsulates sampling, the hemisphere-consistency guard, and the
		// thin-walled override IN THE ORDER fix round 1's I1 established --
		// see that function's doc comment for the full reasoning and
		// RT_DEBUG_GUARD_FIRING_RATE for the detector this extraction makes
		// possible.
		bool isTransmit;
		bool wrongHemisphere;
		// F1: the hemisphere guard inside is Cycles' dot(Ng, wo) test
		// (bsdf_microfacet.h:863) -- against the TRUE face, not the smooth normal.
		if (sampleTransmissiveLobe(V, N, h.face_normal, alpha, alpha * alpha, specularF0,
					brdf_mat.eta, brdf_mat.transmissivness, m.thickness == 0.0,
#ifdef RT_ANISOTROPY_ENABLED
					transData.ax, transData.ay, transData.anisoPhi, transData.anisoActive,
#endif
					u3,
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

#ifdef RT_SSS_ENABLED
	// E3 thin-wall: the translucent half of bsdf_thin_subsurface_setup, a
	// Lambertian about -N (bsdf_translucent). Cosine sample about -N, closure
	// weight 0.5 * w * baseColor, and the ray continues on the far side. No NEE strategy draws below the horizon, so this direction is
	// BSDF-owned with MIS weight 1 -- mis_ray_pdf is set to NONE below through
	// sss_thin_through, the same rule as took_transmissive_lobe.
	bool sss_thin_through = false;
	if (brdfType == SUBSURFACE_TYPE && brdf_mat.sssThin) {
		float4 qRot = getRotationToZAxis(N);
		float3 local_dir = sampleHemisphere(u);
		local_dir.z = -local_dir.z;
		next_dir = normalize(rotatePoint(invertRotation(qRot), local_dir));
		// CLOSURE weight, as every other arm returns it: the translucent lobe's
		// weight is 0.5 * w * baseColor (bsdf_thin_subsurface_setup), and its
		// Lambertian eval/pdf is 1. shade_and_bounce has already divided the
		// throughput by the selection probability (0.5 * w), so the two cancel
		// to baseColor in expectation -- returning baseColor HERE would pay the
		// lobe twice (measured: S3 read 0.80 instead of 0.40).
		brdf_weight = sssSelectShare(brdf_mat) * brdf_mat.baseColor;
		if (dot(next_dir, h.geometry_normal) >= 0.0 || luminance(brdf_weight) == 0.0) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		transmissive_sample_ok = true; // skip evalIndirectCombinedBRDF below
		sss_thin_through = true;
	} else if (brdfType == SUBSURFACE_TYPE) {
		// E3 solid: Cycles subsurface_entry_bounce + subsurface_random_walk.
		// Entry direction: a GGX VNDF microfacet at alpha = roughness^2,
		// refracted at 1/ior -- direction only, no BSDF/pdf factor (Cycles'
		// own note: "we only really care about the directional distribution").
		float sss_ior = clamp(brdf_mat.eta > 0.0 ? brdf_mat.eta : 1.4, 1.01, 3.8);
		float ent_alpha = brdf_mat.roughness * brdf_mat.roughness;
		float4 qRot = getRotationToZAxis(N);
		float3 V_local = rotatePoint(qRot, V);
		float3 H_local = sampleGGXVNDF(V_local, float2(ent_alpha, ent_alpha), u);
		float3 H = normalize(rotatePoint(invertRotation(qRot), H_local));
		float neta = 1.0 / sss_ior;
		float cos_HI = dot(H, V);
		float arg = 1.0 - neta * neta * (1.0 - cos_HI * cos_HI);
		bool entry_ok = (cos_HI > 0.0) && (arg >= 0.0);
		vec3 wo = vec3(0.0);
		if (entry_ok) {
			float dnp = max(sqrt(arg), 1e-7);
			float nK = neta * cos_HI - dnp;
			wo = -(neta * V) + nK * H;
			entry_ok = dot(h.face_normal, wo) < 0.0; // F1: Cycles tests Ng here (bsdf_microfacet.h:863).
		}
		if (!entry_ok) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// Closure weight over selection probability: the base colour (Cycles'
		// closure weight is base_color * w * layering; the w cancelled against
		// the selection division above), then the walk divides the albedo back
		// out and re-adds it through scattering.
		ps.throughput *= brdf_mat.baseColor;
		vec3 exit_pos;
		vec3 exit_dir;
		uint seed = ps.rng_packed ^ (uint(gl_PrimitiveID) * 0x9E3779B9u) ^ floatBitsToUint(h.hit_pos.x + h.hit_pos.z);
		if (!sss_random_walk(h.hit_pos, wo, N, brdf_mat.baseColor, brdf_mat.sssRadius, ps.throughput, seed,
					uint(gl_InstanceID), uint(gl_PrimitiveID), exit_pos, exit_dir)) {
			ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
			path_pack(payload, ps);
			return;
		}
		// Re-aim: the next ray starts 2 mm past the exit point along the walk
		// direction and points back at it (Cycles: P += D*tmax*2; D = -D), so
		// the exit face is the next closest hit, from outside, and is shaded
		// as a white Lambertian under ps.sss_exit.
		const float SSS_EXIT_DELTA = 0.002;
		ps.sss_restart = exit_pos + exit_dir * SSS_EXIT_DELTA;
		ps.next_ray_dir = -exit_dir;
		ps.offset_normal = exit_dir;
		ps.hit_t = gl_HitTEXT;
		ps.packed_bounces_flags = inc_diffuse_bounce(ps.packed_bounces_flags);
		ps.sss_exit = true;
		ps.mis_ray_pdf = RT_MIS_PDF_NONE;
		ps.mis_origin = h.hit_pos;
		ps.rng_packed = rng_pack(rng_next_bounce(rng));
		path_pack(payload, ps);
		return;
	}
#else
	const bool sss_thin_through = false;
#endif
	if (!transmissive_sample_ok && !evalIndirectCombinedBRDF(u, N, h.face_normal, V, brdf_mat, brdfType, next_dir, brdf_weight, vec4(0.0))) {
		// Zero weight, or a direction below the TRUE face. Cycles returns
		// LABEL_NONE for both (bsdf_microfacet.h:863, bsdf_diffuse.h:65) and the
		// path ends. F1 removed the mirror-and-keep-the-weight recovery that stood
		// here: it handed a rejected sample's weight to a direction drawn from no
		// density this code knows, and was over-bright at grazing angles by its
		// own admission (pt_bump_correction_gate probe A read > 1 in a furnace).
		ps.packed_bounces_flags = set_path_terminated(ps.packed_bounces_flags);
		path_pack(payload, ps);
		return;
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
	} else if (brdfType == DIFFUSE_TYPE || brdfType == SHEEN_TYPE || brdfType == SUBSURFACE_TYPE) {
		// E2e: sheen counts as a DIFFUSE bounce, not a glossy one. Cycles labels
		// the sheen closure LABEL_REFLECT | LABEL_DIFFUSE (bsdf_sheen.h:110), and
		// the LTC is a wide, near-cosine lobe -- classifying it as glossy would
		// let a velvet surface spend the glossy budget and skip the diffuse
		// bounce cap that MAX_DIFFUSE_BOUNCES exists to enforce.
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
	// Gap #26: a transmissive-lobe sample is a through-event (thin or thick).
	if (took_transmissive_lobe) {
		ps.skip_geom = gl_InstanceCustomIndexEXT;
		ps.skip_prim = gl_PrimitiveID;
	}
	// Raygen offsets the next ray origin ALONG this normal
	// (scene_raytracing_raygen.glsl). A refracted ray is heading INTO the
	// surface, so it must be offset the other way or it restarts outside the
	// glass and immediately re-hits the face it just crossed. Negating here
	// costs no payload space -- the field is already oct-packed.
	// E3: a thin-wall translucent sample restarts on the FAR side, like a refraction.
	ps.offset_normal = (took_transmissive_lobe || sss_thin_through) ? -h.geometry_normal : h.geometry_normal;
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
	//     scale this ray down. ensureValidSpecularReflection does not eliminate
	//     backfacing V either, so on strongly normal-mapped geometry this is common:
	//     without this guard, 0.836 against a reference of 1.415, a 41% loss.
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
	if (took_transmissive_lobe || sss_thin_through || dot(N, V) <= 0.0 ||
			(brdfType == SPECULAR_TYPE && brdf_mat.roughness < RT_MIS_DELTA_ROUGHNESS) ||
			(brdfType == COAT_TYPE && brdf_mat.coatRoughness < RT_MIS_DELTA_ROUGHNESS)) {
		ps.mis_ray_pdf = RT_MIS_PDF_NONE;
	} else {
		float bsdf_pdf = combinedPdf(N, next_dir, V, brdf_mat);
		ps.mis_ray_pdf = (bsdf_pdf > 0.0) ? bsdf_pdf : RT_MIS_PDF_NONE;
	}
	// Light portals: the sky pdf the miss stage weighs this ray against is
	// evaluated from the same point the env NEE above used (h.hit_pos).
	ps.mis_origin = h.hit_pos;

	path_pack(payload, ps);
}
