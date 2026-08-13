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

// ORDERING SCRATCH -- DECLARED ON PURPOSE, NEVER READ. DO NOT DELETE.
//
// This block exists solely to give the render graph a dependency it cannot
// otherwise see. MODE_AREA's real vertex reads go through the buffer-device
// addresses inside GeometryData (rt_fetch_vertex_position), and a BDA read is
// invisible to the graph's resource tracking -- it tracks what a uniform set
// DECLARES, not what a shader dereferences. So without this, nothing orders this
// pass against multimesh_merge.glsl, which rebakes a merged MultiMesh's vertex
// buffer in the same frame.
//
// The C++ side (EmissiveLights::update) copies four meaningless bytes out of
// every active merged vertex buffer into the buffer bound here, immediately
// before this dispatch, forming a chain of TRACKED accesses:
//
//     merge dispatch (STORAGE_BUFFER_READ_WRITE, so SHADER_WRITE)
//         -> buffer copy (COPY_FROM on the merged buffer, COPY_TO on this one)
//             -> this dispatch (STORAGE_BUFFER_READ on this one, SHADER_READ)
//
// Each link is a real read-after-write the graph resolves into a level ordering
// plus a barrier (rendering_device_graph.cpp:580-582 pushes a GLOBAL memory
// barrier alongside the per-buffer one, and a global VkMemoryBarrier is not
// scoped to a buffer, which is what makes the BDA read safe).
//
// The bytes copied in are garbage and are never looked at. Reading from this
// block would not make it more correct, only slower. But DELETING it -- or the
// copy, or the binding -- silently removes the ordering, and the symptom is a
// wrong total_area computed from half-written vertices and then frozen into the
// distribution for an entire accumulated still render.
layout(set = 0, binding = 3, std430) restrict readonly buffer OrderingScratch {
	// Runtime-sized deliberately: it makes the reflected block length 0, which is
	// what lets uniform_set_create accept a buffer of any size here
	// (rendering_device.cpp:4781, "If 0, then it's sized on link time").
	uint _never_read[];
}
ordering_scratch;

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
