/**************************************************************************/
/*  emissive_lights.h                                                     */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

// EmissiveLights: owns the GPU-side power-weighted distribution over emissive
// mesh instances (roadmap C1), so next-event estimation can sample glowing
// geometry directly instead of waiting for a BSDF ray to stumble onto it.
//
// Three buffers, all built by emissive_area_build.glsl:
//
//   instance_buffer  EmissiveInstance[INSTANCES_MAX]   (80 bytes each, std430)
//                    geometry_index / prim_count / object->world transform /
//                    emission are filled by the CPU; total_area and power are
//                    written by MODE_AREA on the GPU.
//   cdf_buffer       { float total_power; vec3 pad; float prefix[INSTANCES_MAX]; }
//                    inclusive prefix sum of power, written by MODE_CDF.
//   slot_buffer      int32 per TLAS INSTANCE (not per emitter): the emissive
//                    slot for that instance, or -1. Indexed by
//                    gl_InstanceCustomIndex, so it is sized to the full instance
//                    count.
//
// CONTRACT FOR CONSUMERS
//
// 1. `total_power == 0` means "no usable distribution". The buffers are
//    allocated and zero-filled on first use and only a successful GPU build
//    writes a nonzero total, so a consumer that gates on this value never reads
//    stale or uninitialised data -- including when the feature is switched off
//    entirely, in which case the caller binds a zero-filled fallback instead.
//
// 2. `prefix[]` is padded out to INSTANCES_MAX with the running total, so a
//    consumer may walk all 256 buckets without knowing the live count: every
//    bucket past the count has zero width and can never be selected.
//
// 3. Area and power are WORLD space. Instances carry non-uniform scale, under
//    which the "object-space area times s^2" shortcut is wrong, so the build
//    transforms each vertex before the cross product.
//
// A CPU mirror of the selection walk lives in
// tests/servers/rendering/test_pt_emissive.cpp.

#include "core/math/color.h"
#include "core/math/transform_3d.h"
#include "core/templates/local_vector.h"
#include "servers/rendering/renderer_rd/shaders/raytracing/emissive_area_build.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

class EmissiveLights {
public:
	static constexpr uint32_t INSTANCES_MAX = 256;

	struct InstanceInput {
		uint32_t geometry_index = 0;
		uint32_t prim_count = 0;
		// OBJECT->world. For a compressed mesh this is NOT the TLAS instance
		// transform: rt_fetch_vertex_position() already de-normalises through the
		// mesh AABB, so the caller divides that factor back out. See
		// RenderRaytracing::gather_emissive_instances().
		Transform3D xform;
		Color emission;
	};

private:
	// GPU twin of the GLSL `EmissiveInstance` struct in emissive_area_build.glsl.
	// std430:
	//   0  geometry_index  4
	//   4  prim_count      4
	//   8  total_area      4   (GPU-written)
	//   12 power           4   (GPU-written)
	//   16 xform[12]       48  (array stride 4)
	//   64 emission (vec3) 12  (16-byte aligned)
	//   76 _pad            4
	struct alignas(16) EmissiveInstanceGPU {
		uint32_t geometry_index;
		uint32_t prim_count;
		float total_area;
		float power;
		float xform[12];
		float emission[3];
		float _pad;
	};

	static_assert(sizeof(EmissiveInstanceGPU) == 80, "EmissiveInstance must be 80 bytes for std430");
	static_assert(offsetof(EmissiveInstanceGPU, xform) == 16, "xform must sit at offset 16");
	static_assert(offsetof(EmissiveInstanceGPU, emission) == 64, "emission is a vec3 and must be 16-byte aligned");

	// { float total_power; float pad[3]; float prefix[INSTANCES_MAX]; }
	static constexpr uint32_t CDF_BUFFER_BYTES = 16 + INSTANCES_MAX * sizeof(float);

	// Push constant mirror of the `Params` block in emissive_area_build.glsl.
	struct PushConstant {
		uint32_t mode; // 0 = area reduction, 1 = prefix sum
		uint32_t count;
		uint32_t pad0;
		uint32_t pad1;
	};

	RID instance_buffer;
	RID cdf_buffer;
	RID slot_buffer;
	uint32_t slot_buffer_capacity = 0; // Bytes; grow-only.

	// Bound at binding 3 and never read by the shader. Its only job is to be the
	// far end of a tracked dependency chain -- see ORDERING_SCRATCH_BYTES and the
	// long comment in update(). 16 bytes because that is the smallest allocation
	// the RD backend will make; only the first 4 are ever written.
	RID ordering_scratch_buffer;
	static constexpr uint32_t ORDERING_SCRATCH_BYTES = 16;

	RID shader;
	RID pipeline;
	bool dirty = true;
	uint32_t count = 0;

	// Backing ShaderRD object + version. `shader` above is the variant RID pulled
	// out of `version`; both are created lazily on the first real build so that
	// merely constructing an EmissiveLights costs nothing.
	EmissiveAreaBuildShaderRD shader_rd;
	RID version;
	bool shader_initialized = false;
	bool _ensure_shader();

	uint64_t last_token = 0;
	bool has_token = false;

	LocalVector<EmissiveInstanceGPU> upload_scratch;

public:
	// Rebuilds when the token differs from the last build. The token must cover
	// the instance SET, their TRANSFORMS and their EMISSION -- see the comment in
	// the .cpp for why a single handle is not enough.
	void mark_dirty_if_token_changed(uint64_t p_token);
	void mark_dirty() { dirty = true; }

	// p_geometry_buffer is the existing RT geometry SSBO; the compute pass reads
	// vertex data through the BDA pointers inside it.
	//
	// p_ordering_src_buffers is the set of per-frame-baked vertex buffers the
	// build will read through those BDA pointers -- in practice the active merged
	// MultiMesh vertex buffers. They are NOT read by this class; four bytes are
	// copied out of each one purely to create a render-graph edge that orders this
	// build after whatever rebaked them. See the comment in update(); passing an
	// empty list is correct when there is nothing per-frame-baked to order
	// against, and silently dropping a buffer that IS reintroduces the race.
	void update(const LocalVector<InstanceInput> &p_instances, RID p_geometry_buffer,
			const LocalVector<int32_t> &p_slot_table, uint64_t p_token,
			const LocalVector<RID> &p_ordering_src_buffers);

	RID get_instance_buffer() const { return instance_buffer; }
	RID get_cdf_buffer() const { return cdf_buffer; }
	RID get_slot_buffer() const { return slot_buffer; }
	uint32_t get_count() const { return count; }
	bool is_valid() const { return instance_buffer.is_valid(); }

	void free_resources();
	~EmissiveLights();
};

} // namespace RendererRD
