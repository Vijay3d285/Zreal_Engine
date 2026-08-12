// Vertex POSITION fetch, in object space.
//
// Requires: raytracing_data_inc.glsl (GeometryData, get_aabb_compression_xforms,
// FloatBuffer, Uint32Buffer) and raytracing_inc.glsl (FLAG_COMPRESSED).
//
// This exists because the closest-hit shader does NOT read vertex positions --
// it derives h.hit_pos from gl_WorldRayOriginEXT + dir * gl_HitTEXT and fetches
// only normals and UVs. Emissive light sampling needs real positions in three
// places (the area reduction, the NEE sample point, and the MIS reverse lookup),
// so the decode lives here once rather than three times.
//
// A CPU mirror of the compressed branch lives in
// tests/servers/rendering/test_pt_emissive.cpp; change both together.

/// Object-space position of vertex `p_index`.
vec3 rt_fetch_vertex_position(GeometryData p_geom, uint p_index) {
	if ((p_geom.flags & FLAG_COMPRESSED) != 0u) {
		// Four uint16 across two words: x | (y << 16), then z in the LOW half of
		// word 1. The high half of word 1 is the tangent angle
		// (fetch_tbn_compressed_vertex reads exactly that word for it), so the
		// mask on z is load-bearing, not defensive.
		Uint32Buffer vb = Uint32Buffer(p_geom.vertex_address);
		uint w0 = vb.v[p_index * 2u + 0u];
		uint w1 = vb.v[p_index * 2u + 1u];

		vec3 n = vec3(
				float(w0 & 0xFFFFu),
				float(w0 >> 16),
				float(w1 & 0xFFFFu)) / 65535.0;

		mat4 aabb_xform, inv_aabb_xform;
		get_aabb_compression_xforms(p_geom, aabb_xform, inv_aabb_xform);
		return (aabb_xform * vec4(n, 1.0)).xyz;
	}

	FloatBuffer vb = FloatBuffer(p_geom.vertex_address);
	uint stride_floats = p_geom.position_stride >> 2;
	return vec3(
			vb.v[p_index * stride_floats + 0u],
			vb.v[p_index * stride_floats + 1u],
			vb.v[p_index * stride_floats + 2u]);
}
