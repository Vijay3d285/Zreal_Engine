// Emissive-mesh light distribution: the GLSL view of the buffers
// EmissiveLights (storage_rd/emissive_lights.h) builds with
// emissive_area_build.glsl.
//
// Requires: raytracing_data_inc.glsl (GeometryData) for the geometry the slot
// table points into.
//
// NOT YET INCLUDED BY ANY STAGE. C1 Task 3 builds the distribution; the NEE that
// samples it arrives in Task 4, which is what will include this file. Until then
// these blocks are compiled by nothing, so a change here is only validated once
// a consumer exists. The C++ side already supplies bindings 35-37 every frame
// (render_raytracing.cpp, update_uniform_set), including a zero-filled fallback
// when `rendering/pathtracer/emissive_mesh_lights` is off -- providing a uniform
// the shader does not declare is harmless, the reverse is not.
//
// CONTRACT: gate on `emissive_cdf.total_power > 0.0` BEFORE reading anything
// else here. That is the one value guaranteed meaningful in the fallback buffer
// bound when the feature is disabled; `emissive_instances[]` and
// `emissive_slot[]` are then backed by only 16 bytes and indexing them is out of
// bounds.

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

layout(set = 0, binding = 35, std430) restrict readonly buffer EmissiveInstancesRO {
	EmissiveInstance emissive_instances[];
};

layout(set = 0, binding = 36, std430) restrict readonly buffer EmissiveCDFRO {
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
layout(set = 0, binding = 37, std430) restrict readonly buffer EmissiveSlotRO {
	int emissive_slot[];
};

#define EMISSIVE_INSTANCES_MAX 256u
