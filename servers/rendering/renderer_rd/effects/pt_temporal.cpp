/**************************************************************************/
/*  pt_temporal.cpp                                                       */
/**************************************************************************/

#include "pt_temporal.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#define RB_SCOPE_PT_TEMPORAL SNAME("pt_temporal")

namespace RendererRD {

static const StringName &_hist_name(int p_kind, uint32_t p_index) {
	static const StringName names[3][2] = {
		{ StringName("hist_color_0"), StringName("hist_color_1") },
		{ StringName("hist_depth_0"), StringName("hist_depth_1") },
		{ StringName("hist_normal_0"), StringName("hist_normal_1") },
	};
	return names[p_kind][p_index & 1u];
}

PTTemporal::PTTemporal() {
	Vector<String> modes;
	modes.push_back("\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	pipeline = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, 0));
	params_buffer = RD::get_singleton()->uniform_buffer_create(sizeof(Params));
}

PTTemporal::~PTTemporal() {
	RD::get_singleton()->free_rid(params_buffer);
	shader.version_free(shader_version);
}

void PTTemporal::_ensure_history(Ref<RenderSceneBuffersRD> p_render_buffers, const Size2i &p_size) {
	const uint32_t usage = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	const RD::DataFormat formats[3] = { RD::DATA_FORMAT_R32G32B32A32_SFLOAT, RD::DATA_FORMAT_R32_SFLOAT, RD::DATA_FORMAT_R16G16B16A16_SFLOAT };
	for (int kind = 0; kind < 3; kind++) {
		for (uint32_t i = 0; i < 2; i++) {
			if (!p_render_buffers->has_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(kind, i))) {
				p_render_buffers->create_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(kind, i), formats[kind], usage, RD::TEXTURE_SAMPLES_1, p_size);
			}
		}
	}
}

RID PTTemporal::process(Ref<RenderSceneBuffersRD> p_render_buffers, const Inputs &p_in) {
	ERR_FAIL_COND_V(p_render_buffers.is_null(), RID());
	ERR_FAIL_COND_V(!(p_in.history_cap > 0.0f), RID()); // caller gates on the cap.
	RD *rd = RD::get_singleton();
	ERR_FAIL_COND_V(!rd->texture_is_valid(p_in.current_color) || !rd->texture_is_valid(p_in.current_depth) || !rd->texture_is_valid(p_in.current_normal), RID());

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL_V(material_storage, RID());
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL_V(uniform_set_cache, RID());

	const Size2i size = p_render_buffers->get_internal_size();
	_ensure_history(p_render_buffers, size);
	const uint32_t r = p_in.read_index & 1u;
	const uint32_t w = 1u - r;

	Params params = {};
	MaterialStorage::store_camera(p_in.curr_vp.inverse(), params.curr_inv_vp);
	MaterialStorage::store_camera(p_in.prev_vp, params.prev_vp);
	MaterialStorage::store_camera(p_in.prev_vp.inverse(), params.prev_inv_vp);
	params.curr_cam_pos[0] = p_in.curr_cam_pos.x;
	params.curr_cam_pos[1] = p_in.curr_cam_pos.y;
	params.curr_cam_pos[2] = p_in.curr_cam_pos.z;
	params.size[0] = size.width;
	params.size[1] = size.height;
	params.exposure = p_in.exposure > 0.0f ? p_in.exposure : 1.0f;
	params.clamp_gamma = p_in.clamp_gamma;
	params.current_samples = MAX(p_in.current_samples, 1.0f);
	params.history_cap = p_in.history_cap;
	params.history_valid = p_in.history_valid ? 1u : 0u;
	params.debug_mask = p_in.debug_mask ? 1u : 0u;
	params.depth_tolerance = 0.02f;
	params.normal_min_dot = 0.9f;
	rd->buffer_update(params_buffer, 0, sizeof(Params), &params);

	RID linear = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID hist_color = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(0, r));
	RID hist_depth = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(1, r));
	RID hist_normal = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(2, r));
	RID out_color = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(0, w));
	RID out_depth = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(1, w));
	RID out_normal = p_render_buffers->get_texture(RB_SCOPE_PT_TEMPORAL, _hist_name(2, w));

	RID sh = shader.version_get_shader(shader_version, 0);
	ERR_FAIL_COND_V(sh.is_null(), RID());
	RD::Uniform u0(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ linear, hist_color }));
	RD::Uniform u1(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest, hist_depth }));
	RD::Uniform u2(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest, hist_normal }));
	RD::Uniform u3(RD::UNIFORM_TYPE_IMAGE, 3, p_in.current_color);
	RD::Uniform u4(RD::UNIFORM_TYPE_IMAGE, 4, p_in.current_depth);
	RD::Uniform u5(RD::UNIFORM_TYPE_IMAGE, 5, p_in.current_normal);
	RD::Uniform u6(RD::UNIFORM_TYPE_IMAGE, 6, out_color);
	RD::Uniform u7(RD::UNIFORM_TYPE_IMAGE, 7, out_depth);
	RD::Uniform u8(RD::UNIFORM_TYPE_IMAGE, 8, out_normal);
	RD::Uniform u9(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 9, params_buffer);

	rd->draw_command_begin_label("PT Temporal Reuse");
	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set_cache->get_cache(sh, 0, u0, u1, u2, u3, u4, u5, u6, u7, u8, u9), 0);
	rd->compute_list_dispatch_threads(compute_list, size.width, size.height, 1);
	rd->compute_list_end();
	rd->draw_command_end_label();
	return out_color;
}

} // namespace RendererRD
