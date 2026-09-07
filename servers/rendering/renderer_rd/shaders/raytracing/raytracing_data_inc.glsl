// Shared data structures for raytracing shaders.
// Requires: GL_EXT_buffer_reference, GL_ARB_gpu_shader_int64, raytracing_inc.glsl (for OFFSET_NONE/FLAG_*)

// ============================================================================
// BUFFER REFERENCES
// ============================================================================
layout(buffer_reference, std430) readonly buffer FloatBuffer {
	float v[];
};
layout(buffer_reference, std430) readonly buffer Uint32Buffer {
	uint v[];
};

// ============================================================================
// GEOMETRY DATA (matches C++ RT_GeometryData, 128 bytes)
// ============================================================================
struct GeometryData {
	uint64_t vertex_address;
	uint64_t attribute_address;
	uint64_t index_address;

	uint vertex_count;
	uint position_stride;
	uint normal_byte_offset;
	uint normal_stride;
	uint tangent_byte_offset;
	uint tangent_stride;

	uint attribute_stride;
	uint uv_byte_offset;
	uint uv_scale_packed; // fp16 x, fp16 y
	uint index_format;
	uint primitive_count;
	uint flags;
	float aabb_size_x;
	float aabb_size_y;
	float aabb_size_z;

	// Byte offset of the vertex color attribute inside `attribute_stride`,
	// or OFFSET_NONE if the mesh has no vertex colors.
	uint color_byte_offset;

	float aabb_pos_x;
	float aabb_pos_y;
	float aabb_pos_z;

	// For deformed geometry: previous-frame position buffer used for motion vectors.
	uint prev_vertex_address_lo;
	uint prev_vertex_address_hi;

	uint _pad[5];
};

// ============================================================================
// TRIANGLE INDEX FETCHING
// ============================================================================

/// Core implementation taking an explicit primitive ID (works in any shader
/// stage -- hit shaders reach it through the get_triangle_indices() wrapper in
/// raytracing_hit_inc.glsl, the emissive area-reduction compute pass calls it
/// directly).
void get_triangle_indices_ex(in GeometryData geom, uint primitive_id, out uint i0, out uint i1, out uint i2) {
	if (geom.index_format == 2u) {
		i0 = primitive_id * 3u;
		i1 = primitive_id * 3u + 1u;
		i2 = primitive_id * 3u + 2u;
	} else if (geom.index_address != 0ul) {
		Uint32Buffer idx = Uint32Buffer(geom.index_address);
		if (geom.index_format == 0u) {
			uint byte_off = primitive_id * 6u;
			uint word0 = idx.v[byte_off >> 2];
			uint word1 = idx.v[(byte_off >> 2) + 1u];
			if ((byte_off & 3u) == 0u) {
				i0 = word0 & 0xFFFFu;
				i1 = word0 >> 16;
				i2 = word1 & 0xFFFFu;
			} else {
				i0 = word0 >> 16;
				i1 = word1 & 0xFFFFu;
				i2 = word1 >> 16;
			}
		} else {
			i0 = idx.v[primitive_id * 3u];
			i1 = idx.v[primitive_id * 3u + 1u];
			i2 = idx.v[primitive_id * 3u + 2u];
		}
	} else {
		i0 = i1 = i2 = 0u;
	}
}

void get_aabb_compression_xforms(GeometryData geom, out mat4 aabb_xform, out mat4 inv_aabb_xform) {
	if ((geom.flags & FLAG_COMPRESSED) == 0u) {
		aabb_xform = mat4(1.0);
		inv_aabb_xform = mat4(1.0);
		return;
	}
	vec3 aabb_sz = vec3(geom.aabb_size_x, geom.aabb_size_y, geom.aabb_size_z);
	vec3 aabb_po = vec3(geom.aabb_pos_x, geom.aabb_pos_y, geom.aabb_pos_z);
	aabb_xform = mat4(
			vec4(aabb_sz.x, 0.0, 0.0, 0.0),
			vec4(0.0, aabb_sz.y, 0.0, 0.0),
			vec4(0.0, 0.0, aabb_sz.z, 0.0),
			vec4(aabb_po, 1.0));
	vec3 inv_sz = 1.0 / aabb_sz;
	inv_aabb_xform = mat4(
			vec4(inv_sz.x, 0.0, 0.0, 0.0),
			vec4(0.0, inv_sz.y, 0.0, 0.0),
			vec4(0.0, 0.0, inv_sz.z, 0.0),
			vec4(-aabb_po * inv_sz, 1.0));
}

// ============================================================================
// PER-INSTANCE MOTION DATA (matches C++ RT_InstanceMotionData, 48 bytes)
// ============================================================================
struct InstanceMotionData {
	float prev_xform[12]; // Previous object-to-world (mat3x4, transposed 3x4)
};

// ============================================================================
// MATERIAL DATA (matches C++ layout, 192 bytes)
// ============================================================================
#define RT_MAT_FLAG_BLEND 8u // Bit 3. MIRRORS RT_MAT_FLAG_BLEND in render_raytracing.h.

struct MaterialData {
	uint albedo_texture_idx;
	uint normal_texture_idx;
	uint orm_texture_idx;
	uint emission_texture_idx;

	vec4 albedo_color;
	vec3 emission_color;
	float emission_strength;

	float metallic;
	float roughness;
	float ao_strength;
	uint flags; // Bit 0: has_normal_map, Bit 1: has_emission, Bit 2: point_filter, Bit 3: blend

	vec2 uv1_scale; // UV1 scale (default 1,1)
	vec2 uv1_offset; // UV1 offset (default 0,0)

	float normal_map_depth; // Normal map strength (default 1.0)
	float specular; // Dielectric specular [0..1], default 0.5 -> F0 = 0.04.
	uint64_t uniform_address; // BDA for custom shader uniform buffer (0 = none)

	// --- Phase D: glTF material extension data. Nothing reads these yet. ---
	float transmission;
	float ior;
	float thickness;
	float attenuation_density; // Reciprocal of attenuation_distance; 0 = none.
	vec3 attenuation_color;
	float specular_factor;
	vec3 specular_tint;
	float sheen_roughness;
	vec3 sheen_color;
	float anisotropy_rotation; // Radians.
	float clearcoat;
	float clearcoat_roughness;
	float anisotropy;
	float clearcoat_ior; // E2d. Was _pad0.
	vec3 clearcoat_tint; // E2d. std430 aligns this to offset 176.
	float _pad0;
};
