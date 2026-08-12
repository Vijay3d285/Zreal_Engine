/**************************************************************************/
/*  emissive_lights.cpp                                                   */
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

#include "emissive_lights.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"

using namespace RendererRD;

EmissiveLights::~EmissiveLights() {
	free_resources();
}

void EmissiveLights::free_resources() {
	RD *rd = RD::get_singleton();
	if (rd) {
		if (pipeline.is_valid()) {
			rd->free_rid(pipeline);
		}
		if (instance_buffer.is_valid()) {
			rd->free_rid(instance_buffer);
		}
		if (cdf_buffer.is_valid()) {
			rd->free_rid(cdf_buffer);
		}
		if (slot_buffer.is_valid()) {
			rd->free_rid(slot_buffer);
		}
		// `shader` is owned by the version, not by us; version_free releases both.
		// It drives RenderingDevice internally, so it belongs inside this guard
		// alongside the free_rid calls above.
		if (shader_initialized && version.is_valid()) {
			shader_rd.version_free(version);
		}
	}
	pipeline = RID();
	instance_buffer = RID();
	cdf_buffer = RID();
	slot_buffer = RID();
	slot_buffer_capacity = 0;
	version = RID();
	shader = RID();
	shader_initialized = false;
	count = 0;
	has_token = false;
	dirty = true;
}

void EmissiveLights::mark_dirty_if_token_changed(uint64_t p_token) {
	// The trigger is a TOKEN over the instance set, their transforms and their
	// emission -- never a single RID or handle. The environment CDF (env_cdf.cpp)
	// was originally keyed on the radiance texture's RID, which is stable while its
	// CONTENTS are still empty: the first build baked an all-zero distribution and
	// the trigger never fired again, silently disabling sky NEE for the whole run.
	if (has_token && p_token == last_token) {
		return;
	}
	mark_dirty();
}

bool EmissiveLights::_ensure_shader() {
	if (!shader_initialized) {
		Vector<String> modes;
		modes.push_back("\n");
		shader_rd.initialize(modes);
		version = shader_rd.version_create();
		shader_initialized = true;
	}
	if (!shader.is_valid()) {
		shader = shader_rd.version_get_shader(version, 0);
		ERR_FAIL_COND_V_MSG(!shader.is_valid(), false, "EmissiveLights: Failed to obtain the emissive_area_build shader.");
	}
	if (!pipeline.is_valid()) {
		pipeline = RD::get_singleton()->compute_pipeline_create(shader);
		ERR_FAIL_COND_V_MSG(!pipeline.is_valid(), false, "EmissiveLights: Failed to create the emissive_area_build pipeline.");
	}
	return true;
}

void EmissiveLights::update(const LocalVector<InstanceInput> &p_instances, RID p_geometry_buffer,
		const LocalVector<int32_t> &p_slot_table, uint64_t p_token) {
	RD *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	// Allocate and zero-fill on first use. Zeroing matters: `total_power` must
	// read as 0 until a real build has run so consumers can detect "no usable
	// distribution" rather than sampling garbage.
	if (!instance_buffer.is_valid()) {
		instance_buffer = rd->storage_buffer_create(INSTANCES_MAX * sizeof(EmissiveInstanceGPU));
		ERR_FAIL_COND_MSG(!instance_buffer.is_valid(), "EmissiveLights: Failed to create the instance buffer.");
		rd->set_resource_name(instance_buffer, "RT Emissive Instance Buffer");
		rd->buffer_clear(instance_buffer, 0, INSTANCES_MAX * sizeof(EmissiveInstanceGPU));
	}
	if (!cdf_buffer.is_valid()) {
		cdf_buffer = rd->storage_buffer_create(CDF_BUFFER_BYTES);
		ERR_FAIL_COND_MSG(!cdf_buffer.is_valid(), "EmissiveLights: Failed to create the CDF buffer.");
		rd->set_resource_name(cdf_buffer, "RT Emissive CDF Buffer");
		rd->buffer_clear(cdf_buffer, 0, CDF_BUFFER_BYTES);
	}
	// The slot table is indexed by gl_InstanceCustomIndex, so it is sized by the
	// FULL instance count. A minimum of one entry keeps the binding valid for an
	// empty scene; the shader cannot reach it, because with no instances there is
	// no gl_InstanceCustomIndex to index it with.
	const uint32_t slot_bytes = MAX((uint32_t)p_slot_table.size(), 1u) * sizeof(int32_t);
	if (slot_bytes > slot_buffer_capacity) {
		if (slot_buffer.is_valid()) {
			rd->free_rid(slot_buffer);
		}
		slot_buffer = rd->storage_buffer_create(slot_bytes);
		ERR_FAIL_COND_MSG(!slot_buffer.is_valid(), "EmissiveLights: Failed to create the slot buffer.");
		rd->set_resource_name(slot_buffer, "RT Emissive Slot Buffer");
		slot_buffer_capacity = slot_bytes;
		rd->buffer_clear(slot_buffer, 0, slot_bytes);
		// A fresh, larger allocation holds none of the previous contents, so the
		// table has to be re-uploaded even if the token says nothing changed.
		mark_dirty();
	}

	// Called every frame; the common case is "nothing changed".
	if (!dirty) {
		return;
	}

	const uint32_t new_count = MIN((uint32_t)p_instances.size(), INSTANCES_MAX);

	// No emitters, or no geometry to read vertices through: leave the distribution
	// empty. `total_power` must be cleared rather than left at its last value, or
	// a scene that loses its last emitter would keep sampling a stale CDF that
	// indexes instances no longer in the buffer.
	if (new_count == 0 || !p_geometry_buffer.is_valid()) {
		rd->buffer_clear(cdf_buffer, 0, CDF_BUFFER_BYTES);
		if (!p_slot_table.is_empty()) {
			rd->buffer_update(slot_buffer, 0, p_slot_table.size() * sizeof(int32_t), p_slot_table.ptr());
		}
		count = 0;
		last_token = p_token;
		has_token = true;
		dirty = false;
		return;
	}

	if (!_ensure_shader()) {
		// Stay dirty so a later frame retries; the buffers are still zero-filled,
		// so consumers see "no distribution" in the meantime.
		return;
	}

	upload_scratch.resize(new_count);
	for (uint32_t i = 0; i < new_count; i++) {
		const InstanceInput &in = p_instances[i];
		EmissiveInstanceGPU &out = upload_scratch[i];
		out.geometry_index = in.geometry_index;
		out.prim_count = in.prim_count;
		// Written by MODE_AREA, but seeded so a dispatch that never runs cannot
		// leave a previous build's power in place.
		out.total_area = 0.0f;
		out.power = 0.0f;
		MaterialStorage::store_transform_transposed_3x4(in.xform, out.xform);
		out.emission[0] = in.emission.r;
		out.emission[1] = in.emission.g;
		out.emission[2] = in.emission.b;
		out._pad = 0.0f;
	}

	rd->buffer_update(instance_buffer, 0, new_count * sizeof(EmissiveInstanceGPU), upload_scratch.ptr());
	if (!p_slot_table.is_empty()) {
		rd->buffer_update(slot_buffer, 0, p_slot_table.size() * sizeof(int32_t), p_slot_table.ptr());
	}

	Vector<RD::Uniform> uniforms;
	{
		RD::Uniform u;
		u.binding = 0;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.append_id(instance_buffer);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 1;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.append_id(cdf_buffer);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 2;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.append_id(p_geometry_buffer);
		uniforms.push_back(u);
	}

	// Ephemeral descriptor set from the per-frame linear pool: the geometry buffer
	// is owned by the per-viewport RT state and is reallocated whenever it grows,
	// so nothing about this set is worth caching.
	RID uniform_set = rd->uniform_set_create(uniforms, shader, 0, /*p_linear_pool=*/true);
	ERR_FAIL_COND_MSG(!uniform_set.is_valid(), "EmissiveLights: Failed to create the emissive_area_build uniform set.");

	PushConstant pc = {};
	pc.count = new_count;
	pc.pad0 = 0;
	pc.pad1 = 0;

	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);

	// Pass 0: one workgroup per emissive instance; reduces world-space area and
	// writes power.
	pc.mode = 0;
	rd->compute_list_set_push_constant(compute_list, &pc, sizeof(PushConstant));
	rd->compute_list_dispatch(compute_list, new_count, 1, 1);

	// The prefix-sum pass reads every power the area pass just wrote.
	rd->compute_list_add_barrier(compute_list);

	// Pass 1: single workgroup, serial inclusive prefix sum.
	pc.mode = 1;
	rd->compute_list_set_push_constant(compute_list, &pc, sizeof(PushConstant));
	rd->compute_list_dispatch(compute_list, 1, 1, 1);

	rd->compute_list_end();

	// Drop the RID now that the dispatches are recorded; the underlying
	// descriptor set lives in the linear pool until frame end.
	rd->free_rid(uniform_set);

	count = new_count;
	last_token = p_token;
	has_token = true;
	dirty = false;
}
