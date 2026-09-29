/**************************************************************************/
/*  local_highlight.cpp                                                   */
/**************************************************************************/

#include "local_highlight.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#define RB_SCOPE_RELIEF SNAME("local_highlight")
#define RB_TEX_RELIEF_LUMA SNAME("relief_luma")

namespace RendererRD {

LocalHighlight::LocalHighlight() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_DOWNSAMPLE\n");
	modes.push_back("\n#define MODE_APPLY\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	for (int i = 0; i < MODE_MAX; i++) {
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, i));
	}
}

LocalHighlight::~LocalHighlight() {
	shader.version_free(shader_version);
}

void LocalHighlight::process(Ref<RenderSceneBuffersRD> p_render_buffers, float p_strength, float p_exposure, float p_knee, bool p_debug) {
	ERR_FAIL_COND(p_render_buffers.is_null());
	ERR_FAIL_COND(!(p_strength > 0.0f)); // caller gates; see the header.
	ERR_FAIL_COND(!(p_exposure > 0.0f));
	ERR_FAIL_COND(!(p_knee > 0.0f));

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);

	const Size2i internal_size = p_render_buffers->get_internal_size();
	// 1/16 in each axis, floored at 1 so a tiny viewport (the gates render at
	// 256x256, and a future caller might be smaller still) cannot produce a
	// zero-sized dispatch.
	const Size2i luma_size = Size2i(MAX(1, internal_size.width / 16), MAX(1, internal_size.height / 16));

	if (!p_render_buffers->has_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA)) {
		p_render_buffers->create_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA,
				RD::DATA_FORMAT_R16G16B16A16_SFLOAT,
				RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT,
				RD::TEXTURE_SAMPLES_1, luma_size);
	}
	RID luma = p_render_buffers->get_texture(RB_SCOPE_RELIEF, RB_TEX_RELIEF_LUMA);
	RID color = p_render_buffers->get_internal_texture();

	RID linear_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	PushConstant push_constant = {};
	push_constant.src_size[0] = internal_size.width;
	push_constant.src_size[1] = internal_size.height;
	push_constant.dst_size[0] = luma_size.width;
	push_constant.dst_size[1] = luma_size.height;
	push_constant.strength = p_strength;
	push_constant.exposure = p_exposure;
	push_constant.knee = p_knee;
	push_constant.debug = p_debug ? 1u : 0u;

	RD::get_singleton()->draw_command_begin_label("Local Highlight Relief");
	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();

	{
		RID sh = shader.version_get_shader(shader_version, MODE_DOWNSAMPLE);
		ERR_FAIL_COND(sh.is_null());
		RD::Uniform u_src(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, color }));
		RD::Uniform u_dst(RD::UNIFORM_TYPE_IMAGE, 1, luma);
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_DOWNSAMPLE]);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u_src, u_dst), 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, luma_size.width, luma_size.height, 1);
	}

	// The apply pass reads what the downsample pass wrote.
	RD::get_singleton()->compute_list_add_barrier(compute_list);

	{
		RID sh = shader.version_get_shader(shader_version, MODE_APPLY);
		ERR_FAIL_COND(sh.is_null());
		RD::Uniform u_src(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear_sampler, luma }));
		RD::Uniform u_dst(RD::UNIFORM_TYPE_IMAGE, 1, color);
		RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[MODE_APPLY]);
		RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u_src, u_dst), 0);
		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(compute_list, internal_size.width, internal_size.height, 1);
	}

	RD::get_singleton()->compute_list_end();
	RD::get_singleton()->draw_command_end_label();
}

} //namespace RendererRD
