#[compute]

#version 450

#VERSION_DEFINES

#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_ARB_gpu_shader_int64 : require

#include "raytracing_inc.glsl"

#include "raytracing_data_inc.glsl"
#include "raytracing_vertex_inc.glsl"

// Builds the emissive-instance sampling distribution for C1.
//
// Two dispatches, mirroring env_cdf_build.glsl's rows/marginal split:
//   MODE_AREA one workgroup per emissive instance; reduces the summed
//             WORLD-SPACE triangle area and writes power = luminance * area.
//   MODE_CDF  one workgroup total; prefix-sums power over <= 256 instances.
//
// World space, not object space: scaling an object-space area by s^2 is only
// valid under uniform scale, and instances routinely carry non-uniform scale.
// The transform is therefore applied per vertex, before the cross product.
//
// `xform` is the OBJECT->world transform, which for a compressed mesh is NOT the
// TLAS instance transform: rt_fetch_vertex_position() already de-normalises
// through the mesh AABB, so the C++ side divides that factor back out before
// uploading (see EmissiveLights::InstanceInput and gather_emissive_instances()).

#define MODE_AREA 0u
#define MODE_CDF 1u
#define EMISSIVE_MAX 256u

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct EmissiveInstance {
	uint geometry_index;
	uint prim_count;
	float total_area; // written by MODE_AREA
	float power; // written by MODE_AREA
	float xform[12]; // object->world, transposed 3x4
	vec3 emission;
	float _pad;
};

layout(set = 0, binding = 0, std430) restrict buffer EmissiveInstances {
	EmissiveInstance inst[];
}
emissive;

layout(set = 0, binding = 1, std430) restrict buffer EmissiveCDF {
	float total_power;
	float _pad0;
	float _pad1;
	float _pad2;
	float prefix[]; // EMISSIVE_MAX entries
}
cdf;

layout(set = 0, binding = 2, std430) readonly buffer Geometries {
	GeometryData geometries[];
};

layout(push_constant, std430) uniform Params {
	uint mode;
	uint count;
	uint pad0;
	uint pad1;
}
params;

shared float s_area[64];

mat4 unpack_xform(EmissiveInstance e) {
	// Transposed 3x4 -> column-major mat4, matching
	// MaterialStorage::store_transform_transposed_3x4 on the C++ side.
	return mat4(
			vec4(e.xform[0], e.xform[4], e.xform[8], 0.0),
			vec4(e.xform[1], e.xform[5], e.xform[9], 0.0),
			vec4(e.xform[2], e.xform[6], e.xform[10], 0.0),
			vec4(e.xform[3], e.xform[7], e.xform[11], 1.0));
}

void main() {
	if (params.mode == MODE_AREA) {
		uint slot = gl_WorkGroupID.x;
		if (slot >= params.count) {
			// Uniform across the whole workgroup (slot is the workgroup id), so no
			// thread is left waiting at the barriers below.
			return;
		}
		EmissiveInstance e = emissive.inst[slot];
		GeometryData geom = geometries[e.geometry_index];
		mat4 xf = unpack_xform(e);

		float local_sum = 0.0;
		for (uint prim = gl_LocalInvocationID.x; prim < e.prim_count; prim += 64u) {
			uint i0, i1, i2;
			get_triangle_indices_ex(geom, prim, i0, i1, i2);
			vec3 p0 = (xf * vec4(rt_fetch_vertex_position(geom, i0), 1.0)).xyz;
			vec3 p1 = (xf * vec4(rt_fetch_vertex_position(geom, i1), 1.0)).xyz;
			vec3 p2 = (xf * vec4(rt_fetch_vertex_position(geom, i2), 1.0)).xyz;
			local_sum += 0.5 * length(cross(p1 - p0, p2 - p0));
		}

		s_area[gl_LocalInvocationID.x] = local_sum;
		barrier();
		for (uint s = 32u; s > 0u; s >>= 1u) {
			if (gl_LocalInvocationID.x < s) {
				s_area[gl_LocalInvocationID.x] += s_area[gl_LocalInvocationID.x + s];
			}
			barrier();
		}

		if (gl_LocalInvocationID.x == 0u) {
			float area = s_area[0];
			float lum = dot(e.emission, vec3(0.2126, 0.7152, 0.0722));
			emissive.inst[slot].total_area = area;
			emissive.inst[slot].power = max(lum, 0.0) * area;
		}
		return;
	}

	// MODE_CDF: one workgroup, serial prefix sum over <= 256 entries.
	if (gl_LocalInvocationID.x != 0u || gl_WorkGroupID.x != 0u) {
		return;
	}
	float running = 0.0;
	for (uint i = 0u; i < params.count; i++) {
		running += emissive.inst[i].power;
		cdf.prefix[i] = running;
	}
	// Pad the tail so a consumer may walk all EMISSIVE_MAX buckets without
	// knowing the count: every bucket past `count` has zero width.
	for (uint i = params.count; i < EMISSIVE_MAX; i++) {
		cdf.prefix[i] = running;
	}
	cdf.total_power = running;
}
