/**************************************************************************/
/*  env_cdf.cpp                                                           */
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

#include "env_cdf.h"

EnvCDF::EnvCDF() {
}

EnvCDF::~EnvCDF() {
	RD *rd = RD::get_singleton();
	if (rd) {
		if (pipeline.is_valid()) {
			rd->free_rid(pipeline);
			pipeline = RID();
		}
		if (buffer.is_valid()) {
			rd->free_rid(buffer);
			buffer = RID();
		}
	}
	// `shader` is owned by the version, not by us; version_free releases both.
	if (shader_initialized && version.is_valid()) {
		shader_rd.version_free(version);
		version = RID();
	}
	shader = RID();
}

bool EnvCDF::mark_dirty_if_source_changed(RID p_radiance_texture, uint64_t p_source_version) {
	if (has_source && p_radiance_texture == last_radiance_texture && p_source_version == last_source_version) {
		return false;
	}
	mark_dirty();
	return true;
}

void EnvCDF::update(RID p_radiance_texture, RID p_sampler, uint64_t p_source_version) {
	// Called every frame; the common case is "nothing changed".
	if (!dirty) {
		return;
	}

	RD *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	const uint32_t buffer_bytes = FLOAT_COUNT * sizeof(float);

	// Allocate and zero-fill on first use. Zeroing matters: `marginal_total`
	// must read as 0 until a real build has run so consumers can detect
	// "no usable distribution" rather than sampling garbage.
	if (!buffer.is_valid()) {
		buffer = rd->storage_buffer_create(buffer_bytes);
		ERR_FAIL_COND_MSG(!buffer.is_valid(), "EnvCDF: Failed to create the distribution buffer.");
		rd->set_resource_name(buffer, "RT Env CDF Buffer");
		rd->buffer_clear(buffer, 0, buffer_bytes);
	}

	// No sky this frame: leave the buffer alone and stay dirty so a later frame
	// with a valid radiance texture still builds.
	if (!p_radiance_texture.is_valid() || !p_sampler.is_valid()) {
		return;
	}

	if (!shader_initialized) {
		Vector<String> modes;
		modes.push_back("\n");
		shader_rd.initialize(modes);
		version = shader_rd.version_create();
		shader_initialized = true;
	}
	if (!shader.is_valid()) {
		shader = shader_rd.version_get_shader(version, 0);
		ERR_FAIL_COND_MSG(!shader.is_valid(), "EnvCDF: Failed to obtain the env_cdf_build shader.");
	}
	if (!pipeline.is_valid()) {
		pipeline = rd->compute_pipeline_create(shader);
		ERR_FAIL_COND_MSG(!pipeline.is_valid(), "EnvCDF: Failed to create the env_cdf_build pipeline.");
	}

	Vector<RD::Uniform> uniforms;
	{
		RD::Uniform u;
		u.binding = 0;
		u.uniform_type = RD::UNIFORM_TYPE_TEXTURE;
		u.append_id(p_radiance_texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 1;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER;
		u.append_id(p_sampler);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.binding = 2;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.append_id(buffer);
		uniforms.push_back(u);
	}

	// Ephemeral descriptor set from the per-frame linear pool: the radiance
	// texture is owned by the sky and may be freed under us, so nothing about
	// this set is worth caching.
	RID uniform_set = rd->uniform_set_create(uniforms, shader, 0, /*p_linear_pool=*/true);
	ERR_FAIL_COND_MSG(!uniform_set.is_valid(), "EnvCDF: Failed to create the env_cdf_build uniform set.");

	PushConstant pc = {};
	pc.pad0 = 0;
	pc.pad1 = 0;
	pc.pad2 = 0;

	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);

	// Pass 0: one workgroup per row; writes prefix_raw and the raw row sums.
	pc.mode = 0;
	rd->compute_list_set_push_constant(compute_list, &pc, sizeof(PushConstant));
	rd->compute_list_dispatch(compute_list, N_V, 1, 1);

	// The marginal pass reads every row sum the rows pass just wrote.
	rd->compute_list_add_barrier(compute_list);

	// Pass 1: single workgroup; folds in the floor and builds the marginal.
	pc.mode = 1;
	rd->compute_list_set_push_constant(compute_list, &pc, sizeof(PushConstant));
	rd->compute_list_dispatch(compute_list, 1, 1, 1);

	rd->compute_list_end();

	// Drop the RID now that the dispatches are recorded; the underlying
	// descriptor set lives in the linear pool until frame end.
	rd->free_rid(uniform_set);

	last_radiance_texture = p_radiance_texture;
	last_source_version = p_source_version;
	has_source = true;
	dirty = false;
}
