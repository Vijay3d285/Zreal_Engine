// Emissive-mesh light distribution: the GLSL view of the buffers
// EmissiveLights (storage_rd/emissive_lights.h) builds with
// emissive_area_build.glsl.
//
// Requires: raytracing_data_inc.glsl (GeometryData) for the geometry the slot
// table points into.
//
// INCLUDED BY THE CLOSEST_HIT STAGE ONLY, from raytracing_closest_hit_common_inc.glsl,
// at the point where sample_material_texture() (which emissive_radiance needs) is
// already defined and raytracing_lights_inc.glsl (lights_trace_shadow_ray) and
// brdf_inc.glsl have already been included. Nothing else needs the distribution:
// raygen and miss never sample it, and any_hit does not even declare the RT params
// block. The C++ side supplies bindings 35-37 every frame (render_raytracing.cpp,
// update_uniform_set), including a zero-filled fallback when
// `rendering/pathtracer/emissive_mesh_lights` is off -- providing a uniform the
// shader does not declare is harmless, the reverse is not.
//
// Additionally requires (all satisfied at the include site):
//   geometries[], materials[], scene_data_block, rng_1d/rng_2d + the
//   RT_PRNG_EMISSIVE_* dimensions, rt_fetch_vertex_position,
//   get_triangle_indices_ex, fetch_uv, power_heuristic, combinedPdf,
//   evalCombinedBRDFSeparate, baseColorToSpecularF0, evalMultiScatterApproximation.
//
// CONTRACT: gate on `emissive_cdf.total_power > 0.0` BEFORE reading anything
// else here. That is the one value guaranteed meaningful in the fallback buffer
// bound when the feature is disabled; `emissive_instances[]` and
// `emissive_slot[]` are then backed by only 16 bytes and indexing them is out of
// bounds.
//
// NOTE ON `restrict`: none of the three blocks below carry it, deliberately.
// When the feature is off, render_raytracing.cpp binds the SAME 16-byte
// zero-filled fallback buffer to all three bindings, so they genuinely alias.
// `restrict` is a promise to the compiler that a block's memory is reached
// through no other name, and that promise would be false on the off path -- which
// is the path every scene takes by default. All three are readonly, so the
// aliasing is harmless in fact, but a false `restrict` is undefined behaviour
// rather than a missed optimisation, and there is nothing to optimise here: these
// are read-only loads.

// Verbatim twin of C++ EmissiveLights::EmissiveInstanceGPU (std430, 80 bytes).
// `total_area` and `power` are written by the GPU build, not by the CPU.
struct EmissiveInstance {
	uint geometry_index; // Index into geometries[]; also the TLAS instance index.
	uint prim_count;
	float total_area; // World-space, summed over the instance's triangles.
	float power; // luminance(emission) * total_area.
	float xform[12]; // object->world, transposed 3x4.
	vec3 emission;
	float _pad;
};

layout(set = 0, binding = 35, std430) readonly buffer EmissiveInstancesRO {
	EmissiveInstance emissive_instances[];
};

layout(set = 0, binding = 36, std430) readonly buffer EmissiveCDFRO {
	float total_power;
	float _cdf_pad0;
	float _cdf_pad1;
	float _cdf_pad2;
	// Inclusive prefix sum of power, padded out to EMISSIVE_INSTANCES_MAX with
	// the running total so all 256 buckets can be walked without knowing the live
	// count: every bucket past the count has zero width.
	float prefix[];
}
emissive_cdf;

// Indexed by gl_InstanceCustomIndex, so this is sized to the FULL TLAS instance
// count -- not to the emitter count and not to EMISSIVE_INSTANCES_MAX. Holds the
// instance's slot in emissive_instances[], or -1 when it is not an emitter.
layout(set = 0, binding = 37, std430) readonly buffer EmissiveSlotRO {
	int emissive_slot[];
};

#define EMISSIVE_INSTANCES_MAX 256u

// Smallest cos between the shadow ray and the emitter's normal that still counts
// as front-facing. Declared once and used by BOTH emissive_sample() (which
// rejects the draw) and emissive_pdf_solid_angle() (which zeroes the density), so
// the forward and reverse directions cannot disagree about which samples exist.
// Value matches lights_eval_rect_light's cos_theta reject.
#define EMISSIVE_MIN_COS_LIGHT 1e-5

// ============================================================================
// EMITTED RADIANCE -- THE ONE COMPOSITION SITE (C1 Task 4)
// ============================================================================

/// The exposure factor every emitted-radiance value in the engine carries.
///
/// Split out from emissive_radiance() below for exactly one caller: the CUSTOM
/// HIT GROUP path in scene_raytracing_raygen.glsl, whose `emission` comes out of
/// user shader code rather than out of a MaterialData, and so cannot be composed
/// by the MaterialData form. Everything else goes through emissive_radiance().
vec3 emissive_apply_exposure(vec3 p_emission) {
	return p_emission * scene_data_block.data.emissive_exposure_normalization;
}

/// THE one place emitted radiance is composed. Both the NEE site and the
/// emissive-hit site call this.
///
/// It is shared rather than duplicated because m.emissive is NOT just
/// emission_color * emission_strength -- every composition site in
/// scene_raytracing_raygen.glsl also multiplies by
/// scene_data_block.data.emissive_exposure_normalization. If NEE and the BSDF
/// hit composed emission differently, the two MIS strategies would estimate
/// different integrands while sharing a weight required to sum to 1 -- which is
/// structurally the defect behind B2's open +2.4% converged-mean shift.
vec3 emissive_radiance(MaterialData p_mat, vec2 p_uv) {
	vec3 e;
	if ((p_mat.flags & 2u) != 0u) { // RT_MAT_FLAG_HAS_EMISSION_TEX
		e = sample_material_texture(p_mat.emission_texture_idx, p_uv, p_mat.flags).rgb * p_mat.emission_color * p_mat.emission_strength;
	} else {
		e = p_mat.emission_color * p_mat.emission_strength;
	}
	return emissive_apply_exposure(e);
}

// ============================================================================
// DISTRIBUTION QUERIES (C1 Task 4)
// ============================================================================

/// Transposed 3x4 -> column-major mat4. Verbatim twin of unpack_xform() in
/// emissive_area_build.glsl, which is what computed the areas this pdf divides
/// by; the two must agree or the sample point and the density describe different
/// triangles.
mat4 emissive_unpack_xform(EmissiveInstance p_e) {
	return mat4(
			vec4(p_e.xform[0], p_e.xform[4], p_e.xform[8], 0.0),
			vec4(p_e.xform[1], p_e.xform[5], p_e.xform[9], 0.0),
			vec4(p_e.xform[2], p_e.xform[6], p_e.xform[10], 0.0),
			vec4(p_e.xform[3], p_e.xform[7], p_e.xform[11], 1.0));
}

/// World-space vertices of one triangle of an emitter, plus the vertex indices
/// (the caller needs them again for the UV fetch).
///
/// rt_fetch_vertex_position() returns OBJECT space -- and for a compressed mesh
/// it has already de-normalised through the mesh AABB, which is why `p_xform` is
/// blas_transform * aabb^-1 rather than the TLAS instance transform. Same input
/// the area pass integrated over.
void emissive_fetch_triangle_world(GeometryData p_geom, mat4 p_xform, uint p_prim,
		out vec3 r_p0, out vec3 r_p1, out vec3 r_p2,
		out uint r_i0, out uint r_i1, out uint r_i2) {
	get_triangle_indices_ex(p_geom, p_prim, r_i0, r_i1, r_i2);
	r_p0 = (p_xform * vec4(rt_fetch_vertex_position(p_geom, r_i0), 1.0)).xyz;
	r_p1 = (p_xform * vec4(rt_fetch_vertex_position(p_geom, r_i1), 1.0)).xyz;
	r_p2 = (p_xform * vec4(rt_fetch_vertex_position(p_geom, r_i2), 1.0)).xyz;
}

/// Geometric normal of a triangle, oriented to the side the surface actually
/// EMITS from -- which is the side a BSDF ray can hit, since every camera and
/// bounce ray is traced under gl_RayFlagsCullBackFacingTrianglesEXT.
///
/// The cross product alone does NOT give that side, and this is measured rather
/// than assumed. With the raw cross(p1-p0, p2-p0) on a box emitter directly above
/// a Lambertian floor, 62.6% of NEE samples landed on the FAR side of the emitter
/// and were then killed by their own shadow ray, 36.5% were rejected as
/// back-facing, and 0.9% survived -- the exact signature of an inward-pointing
/// normal. Godot winds its meshes the other way round from the CCW convention
/// that cross product assumes. The sign also flips under any transform with
/// negative determinant, which no winding convention can tell you about.
///
/// So orient against the interpolated VERTEX normal, the same quantity
/// compute_hit_data() builds h.geometry_normal from on the BSDF-hit side. The two
/// MIS strategies then agree on which face emits without either of them hardcoding
/// a winding convention.
///
/// The GEOMETRIC normal is what gets returned, not the vertex normal: the
/// area-to-solid-angle Jacobian is a property of the triangle's plane, and using a
/// smoothed shading normal in it would be the wrong density.
///
/// A mesh with no normal attribute leaves fetch_tbn() at its (0,1,0) default and
/// the orientation is then arbitrary -- but such a mesh has no defined front face
/// for the raster path either.
vec3 emissive_orient_normal(vec3 p_ng_world, GeometryData p_geom, mat4 p_xform,
		uint p_i0, uint p_i1, uint p_i2) {
	TBNResult tbn = fetch_tbn(p_geom, p_i0, p_i1, p_i2, vec3(1.0 / 3.0));
	// Normals transform by the inverse transpose. mat3(p_xform) is the wrong
	// matrix for this the moment an instance carries non-uniform scale or shear,
	// and emitters routinely do.
	vec3 n_world = transpose(inverse(mat3(p_xform))) * tbn.normal;
	return (dot(p_ng_world, n_world) < 0.0) ? -p_ng_world : p_ng_world;
}

/// Walks the power CDF. Returns the chosen slot, its selection probability, and
/// the remainder RESCALED to [0,1) so the triangle draw can reuse the same
/// random number.
///
/// The rescale is load-bearing: without it the triangle picked would be
/// correlated with WHICH instance was picked, and a whole band of triangles
/// would be unreachable on some emitters. CPU mirror: mirror_select_instance()
/// in tests/servers/rendering/test_pt_emissive.cpp.
///
/// All EMISSIVE_INSTANCES_MAX buckets are walkable because the build pads the
/// tail with the running total, but the loop never actually runs past the live
/// count: rng_1d() is strictly < 1, so `target` is strictly below the total and
/// some live bucket must straddle it.
bool emissive_select_instance(float p_u, out uint r_slot, out float r_prob, out float r_remap) {
	r_slot = 0u;
	r_prob = 0.0;
	r_remap = 0.0;

	float total = emissive_cdf.total_power;
	if (!(total > 0.0)) {
		return false;
	}

	float target = p_u * total;
	float lo = 0.0;
	for (uint i = 0u; i < EMISSIVE_INSTANCES_MAX; i++) {
		float hi = emissive_cdf.prefix[i];
		float w = hi - lo;
		if (w > 0.0 && target < hi) {
			r_slot = i;
			r_prob = w / total;
			r_remap = clamp((target - lo) / w, 0.0, 0.99999994);
			return true;
		}
		lo = hi;
	}

	// Drift guard. Unreachable in exact arithmetic (see above), but total_power
	// is a serially accumulated float and prefix[] is the same sum recorded a
	// term at a time, so `target` can land a few ULP past the last bucket's top.
	// Fall back to the last positive-weight bucket rather than dropping the
	// sample. Mirrors the identical fallback in mirror_select_instance().
	lo = 0.0;
	for (uint i = 0u; i < EMISSIVE_INSTANCES_MAX; i++) {
		float w = emissive_cdf.prefix[i] - lo;
		if (w > 0.0) {
			r_slot = i;
			r_prob = w / total;
			r_remap = 0.0;
		}
		lo = emissive_cdf.prefix[i];
	}
	return r_prob > 0.0;
}

/// P(inst) for an ALREADY-KNOWN slot, by differencing the CDF instead of walking
/// it. Task 5's MIS weight for a BSDF ray that lands on an emitter needs the
/// density NEE would have assigned to the same direction, and that starts here.
/// Slot 0's lower edge is the implicit 0, not prefix[-1].
float emissive_prob_for_slot(uint p_slot) {
	float total = emissive_cdf.total_power;
	if (!(total > 0.0) || p_slot >= EMISSIVE_INSTANCES_MAX) {
		return 0.0;
	}
	float lo = (p_slot == 0u) ? 0.0 : emissive_cdf.prefix[p_slot - 1u];
	float w = emissive_cdf.prefix[p_slot] - lo;
	return (w > 0.0) ? (w / total) : 0.0;
}

/// The emitter slot for a TLAS instance, or -1 when it is not in the
/// distribution -- and -1 whenever there is no distribution at all.
///
/// THE CONTRACT GATE IS INSIDE, which is the whole reason this exists rather than
/// callers indexing `emissive_slot[]` themselves. When
/// `rendering/pathtracer/emissive_mesh_lights` is off -- and also when it is ON
/// but EmissiveLights has no valid buffers yet, which the spec constant cannot
/// tell you about (render_raytracing.cpp binds the fallback on
/// `emissive_active && emissive_lights.is_valid()`) -- all three bindings are the
/// same 16-byte zero-filled buffer, so `emissive_slot[]` is effectively
/// zero-length and indexing it by gl_InstanceCustomIndex is out of bounds.
/// That read does not fault reliably; it returns whatever is there.
///
/// -1 is the right answer on that path and not merely a safe one: with no
/// distribution NEE cannot have sampled anything, so the BSDF hit is the only
/// strategy and must take the full weight.
int emissive_slot_for_instance(uint p_instance_custom_index) {
	if (!(emissive_cdf.total_power > 0.0)) {
		return -1;
	}
	return emissive_slot[p_instance_custom_index];
}

/// Area-measure density of the sampling scheme, converted to the SOLID-ANGLE
/// measure the BSDF pdf lives in so the two can be combined by MIS:
///
///     pdf_A     = P(inst) * (1 / prim_count) * (1 / area_tri)
///     pdf_omega = pdf_A * dist^2 / cos_light
///
/// Front-face-only by construction -- a cos_light at or below
/// EMISSIVE_MIN_COS_LIGHT means the sampled point faces away (or is edge-on) and
/// the estimator is zero there, matching lights_eval_rect_light's cos_theta reject
/// and the back-face culling the BSDF ray itself is traced under.
///
/// THE THRESHOLD IS THE SAME CONSTANT emissive_sample() REJECTS ON, and that is
/// not tidiness. If this guard were the looser `<= 0.0` while the sampler rejected
/// at 1e-5, then for cos_light in (0, 1e-5] the REVERSE lookup would report a huge
/// NEE density for a direction NEE can never produce -- and Task 5's power
/// heuristic would drive that BSDF hit's weight to ~0 and delete the energy. The
/// measure is vanishing, the failure is silent, and agreeing costs nothing.
///
/// CPU mirror: mirror_pdf_solid_angle() in tests/servers/rendering/test_pt_emissive.cpp.
float emissive_pdf_solid_angle(float p_prob_inst, uint p_prim_count,
		float p_area_tri, float p_dist, float p_cos_light) {
	if (p_prim_count == 0u || p_area_tri <= 0.0 || p_cos_light <= EMISSIVE_MIN_COS_LIGHT) {
		return 0.0;
	}
	float pdf_a = p_prob_inst * (1.0 / float(p_prim_count)) * (1.0 / p_area_tri);
	return pdf_a * (p_dist * p_dist) / p_cos_light;
}

/// The same density, recovered from a HIT rather than from a draw: the reverse
/// lookup Task 5 needs when a BSDF ray lands on an emitter and has to know what
/// weight NEE would have given that direction.
///
/// p_slot comes from emissive_slot[gl_InstanceCustomIndexEXT]; p_primitive_id from
/// gl_PrimitiveID; p_L is the UNIT direction from the shading point toward the hit,
/// i.e. gl_WorldRayDirectionEXT, the same orientation NEE's own L carries; p_dist
/// is the distance between them.
///
/// IT TAKES A DIRECTION, NOT A COS, AND IT LOOKS UP ITS OWN GEOMETRY. Both are
/// deliberate narrowings of what a caller can get wrong:
///
///   - cos_light is computed HERE, from emissive_orient_normal(), which is the
///     same function and the same triangle emissive_sample() uses. Handing it in
///     would let Task 5 derive it from the hit's h.geometry_normal instead --
///     oriented by compute_hit_data() through gl_HitKindEXT and the vertex normal
///     matrix, a genuinely different code path -- and on any emitter whose winding
///     opposes its vertex normal the reverse density would then disagree with the
///     forward one. No compile error, no failing test, a biased MIS partition.
///
///   - the geometry index comes from emissive_instances[p_slot], not from a
///     parameter. A caller that passed a slot and a geometry index belonging to
///     different instances would silently integrate over the wrong mesh; the pair
///     cannot be mismatched if only one of them is passed.
///
/// The area is recomputed for the single triangle that was hit -- NOT read from
/// the instance's total_area, which is the sum over all of them.
float emissive_pdf_solid_angle_for_hit(uint p_slot, uint p_primitive_id, vec3 p_L, float p_dist) {
	// The contract gate, first, before any other block in this file is touched:
	// when the feature is off all three bindings are the same 16-byte zero-filled
	// fallback and emissive_instances[] is out of bounds.
	if (!(emissive_cdf.total_power > 0.0)) {
		return 0.0;
	}
	float prob_inst = emissive_prob_for_slot(p_slot);
	if (!(prob_inst > 0.0)) {
		return 0.0;
	}

	EmissiveInstance e = emissive_instances[p_slot];
	if (p_primitive_id >= e.prim_count) {
		return 0.0;
	}

	GeometryData geom = geometries[e.geometry_index];
	mat4 xform = emissive_unpack_xform(e);
	vec3 p0, p1, p2;
	uint i0, i1, i2;
	emissive_fetch_triangle_world(geom, xform, p_primitive_id, p0, p1, p2, i0, i1, i2);

	vec3 ng_raw = cross(p1 - p0, p2 - p0);
	float area_tri = 0.5 * length(ng_raw);
	if (!(area_tri > 0.0)) {
		return 0.0;
	}
	vec3 Ng = emissive_orient_normal(ng_raw / (2.0 * area_tri), geom, xform, i0, i1, i2);
	float cos_light = dot(-p_L, Ng);

	return emissive_pdf_solid_angle(prob_inst, e.prim_count, area_tri, p_dist, cos_light);
}

// ============================================================================
// NEXT EVENT ESTIMATION (C1 Task 4)
// ============================================================================

/// One direct-lighting sample of the emissive-mesh distribution.
///
/// `p_hit_pos` is the ALREADY-OFFSET shading point (offset_ray_origin), the same
/// point the shadow ray starts from, so the distance in the pdf and the distance
/// the shadow ray is limited to are the same number.
///
/// Returns the contribution BEFORE throughput and firefly clamping; the caller
/// applies both, matching the neighbouring analytic and environment NEE blocks.
///
/// Carries the MIS weight for the NEE half. The other half -- weighting the
/// emissive radiance a BSDF ray collects when it lands on an emitter -- lives at
/// the emissive accumulation in shade_and_bounce()
/// (raytracing_closest_hit_common_inc.glsl) and goes through
/// emissive_pdf_solid_angle_for_hit() above. The two are power_heuristic() over
/// the SAME two densities with the arguments swapped, so they sum to exactly one.
/// Change the density either half uses and you must change both.
bool emissive_sample(vec3 p_hit_pos, vec3 p_N, vec3 p_V, MaterialProperties p_mat,
		RNGState p_rng, out vec3 r_contribution) {
	r_contribution = vec3(0.0);

	// THE CONTRACT GATE, first and on every path into this file. `total_power` is
	// the only value that is meaningful in the zero-filled fallback bound when the
	// feature is off; emissive_instances[] and emissive_slot[] are backed by 16
	// bytes there and indexing them is out of bounds.
	if (!(emissive_cdf.total_power > 0.0)) {
		return false;
	}

	uint slot;
	float prob_inst;
	float remap;
	if (!emissive_select_instance(rng_1d(p_rng, RT_PRNG_EMISSIVE_SELECT), slot, prob_inst, remap)) {
		return false;
	}

	EmissiveInstance e = emissive_instances[slot];
	if (e.prim_count == 0u) {
		return false;
	}

	// Uniform over the instance's triangles, reusing the rescaled CDF remainder
	// rather than spending a second random dimension. min() guards remap == 1 - eps
	// rounding up to prim_count.
	uint tri = min(uint(remap * float(e.prim_count)), e.prim_count - 1u);

	GeometryData geom = geometries[e.geometry_index];
	mat4 xform = emissive_unpack_xform(e);
	vec3 p0, p1, p2;
	uint i0, i1, i2;
	emissive_fetch_triangle_world(geom, xform, tri, p0, p1, p2, i0, i1, i2);

	// Unnormalised geometric normal doubles as the area: |cross| == 2 * area.
	vec3 ng_raw = cross(p1 - p0, p2 - p0);
	float area_tri = 0.5 * length(ng_raw);
	if (!(area_tri > 0.0)) {
		return false; // Degenerate triangle: no measure, no sample.
	}
	vec3 Ng = emissive_orient_normal(ng_raw / (2.0 * area_tri), geom, xform, i0, i1, i2);

	// Uniform point on the triangle. sqrt warp: a plain (u, v) pair would
	// concentrate samples toward one vertex and the constant 1/area density would
	// then be the wrong one.
	vec2 u2 = rng_2d(p_rng, RT_PRNG_EMISSIVE_POINT);
	float su = sqrt(u2.x);
	vec3 bary = vec3(1.0 - su, su * (1.0 - u2.y), su * u2.y);
	vec3 light_pos = bary.x * p0 + bary.y * p1 + bary.z * p2;

	vec3 to_light = light_pos - p_hit_pos;
	float dist = length(to_light);
	if (!(dist > 0.0)) {
		return false;
	}
	vec3 L = to_light / dist;

	// BOTH CHEAP REJECTIONS COME BEFORE THE SHADOW RAY. A shadow ray is a BVH
	// traversal; these are two dot products. Same ordering as the fix already
	// applied to the positional analytic-light branch.
	float cos_light = dot(-L, Ng);
	if (cos_light <= EMISSIVE_MIN_COS_LIGHT) {
		return false; // Back of the emitter, or edge-on.
	}
	if (dot(p_N, L) <= 0.0) {
		return false; // Below the shading hemisphere.
	}

	float pdf_omega = emissive_pdf_solid_angle(prob_inst, e.prim_count, area_tri, dist, cos_light);
	if (!(pdf_omega > 0.0)) {
		return false;
	}

	if (!lights_trace_shadow_ray(p_hit_pos, L, dist)) {
		return false;
	}

	// The BRDF VALUE and the BRDF DENSITY must describe the same set of lobes, or
	// the MIS weight partitions one integrand while the estimator evaluates
	// another. Both adjustments below are the ones the environment-NEE block in
	// raytracing_closest_hit_common_inc.glsl already carries, for reasons that
	// apply here verbatim -- read that block's comments for the measurements.
	//
	//   - the dot(N, V) guard reproduces evalCombinedBRDF's Vbackfacing early-out,
	//     which evalCombinedBRDFSeparate does not perform;
	//   - the specular VALUE is dropped below RT_MIS_DELTA_ROUGHNESS because
	//     combinedPdf() drops the specular DENSITY there, and Task 5 will hand
	//     delta lobes to the BSDF strategy outright;
	//   - the multiple-scattering factor is applied because sampleSpecularMicrofacet
	//     folds it into the weight the BSDF strategy realises, while evalMicrofacet
	//     does not.
	//   - E2d fix round 1: the COAT is treated exactly as the environment-NEE block
	//     treats it, because this path has the identical structure -- a second MIS
	//     strategy paired against combinedPdf through power_heuristic below. So it
	//     gets a near-delta guard keyed on the COAT's own roughness, matching
	//     coatPdf's cutoff. Its multiple-scattering compensation is NOT applied
	//     here: E2d Task 5b moved it inside evalCoat, where no NEE site can
	//     forget it. The base terms arrive already attenuated by the coat, inside
	//     evalCombinedBRDFSeparate.
	vec3 bsdf_val = vec3(0.0);
	if (dot(p_N, p_V) > 0.0) {
		vec3 f_diff, f_spec, f_coat;
		evalCombinedBRDFSeparate(p_N, L, p_V, p_mat, f_diff, f_spec, f_coat);

#if MICROFACET_DISTRIBUTION == GGX
		float ms_alpha = p_mat.roughness * p_mat.roughness;
		float NdotV = max(dot(p_N, p_V), 0.0001);
		vec3 specular_f0 = baseColorToSpecularF0(p_mat.baseColor, p_mat.metalness, p_mat.dielectricF0);
		f_spec *= evalMultiScatterApproximation(ms_alpha, NdotV, specular_f0);
		// E2d Task 5b: the coat's compensation moved inside evalCoat (real
		// Cycles preserve_energy via coatEnergyScale), so f_coat arrives
		// already compensated. See the matching note in the environment-NEE
		// block of raytracing_closest_hit_common_inc.glsl.
#endif

		bsdf_val = (p_mat.roughness < RT_MIS_DELTA_ROUGHNESS) ? f_diff : (f_diff + f_spec);
		if (p_mat.coatRoughness >= RT_MIS_DELTA_ROUGHNESS) {
			bsdf_val += f_coat;
		}
	}

	// Emitted radiance at the sampled point, through THE shared composition.
	MaterialData emat = materials[e.geometry_index];
	vec2 emissive_uv = fetch_uv(geom, i0, i1, i2, bary) * emat.uv1_scale + emat.uv1_offset;
	vec3 radiance = emissive_radiance(emat, emissive_uv);

	float w = power_heuristic(pdf_omega, combinedPdf(p_N, L, p_V, p_mat));
	r_contribution = bsdf_val * radiance * (w / pdf_omega);
	return true;
}
