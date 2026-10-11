/**************************************************************************/
/*  pt_temporal.h                                                         */
/**************************************************************************/

#pragma once

#include "core/math/projection.h"
#include "core/math/vector3.h"
#include "servers/rendering/renderer_rd/shaders/effects/pt_temporal.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Temporal stabilisation of the path tracer's denoised frames (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md, amendment 2026-10-11: after
// OIDN). Owns the blend pass and
// two ping-pong history sets on the render buffers (scope "pt_temporal"). The caller keeps the
// frame-to-frame state in RTViewportState::temporal (PTTemporalState) and passes read_index.
class PTTemporal {
	struct Params { // std140, mirrors pt_temporal.glsl
		float curr_inv_vp[16];
		float prev_vp[16];
		float prev_inv_vp[16];
		float curr_cam_pos[4];
		int32_t size[2];
		float exposure;
		float clamp_gamma;
		float current_samples;
		float history_cap;
		uint32_t history_valid;
		uint32_t debug_mask;
		float depth_tolerance;
		float normal_min_dot;
		float albedo_tolerance;
		float pad;
	};
	static_assert(sizeof(Params) == 256, "PTTemporal::Params must match the std140 block in pt_temporal.glsl");

	PtTemporalShaderRD shader;
	RID shader_version;
	RID pipeline;
	RID params_buffer;

	void _ensure_history(Ref<RenderSceneBuffersRD> p_render_buffers, const Size2i &p_size);

public:
	struct Inputs {
		RID current_color; // the denoised RT colour (RB_TEX_RAYTRACING), RGBA16F
		RID current_depth; // rt_depth, R32F
		RID current_normal; // rt_accum_normal, RGBA16F
		RID current_albedo; // rt_accum_albedo, RGBA16F (guides defer through glass and mirror-like reflections)
		Projection curr_vp; // depth-corrected, as render_raytracing.cpp builds curr_vp_unjittered
		Projection prev_vp;
		Vector3 curr_cam_pos;
		uint32_t read_index = 0;
		bool history_valid = false;
		float exposure = 1.0f;
		float clamp_gamma = 1.25f;
		float current_samples = 1.0f;
		float history_cap = 0.0f;
		bool debug_mask = false;
	};

	PTTemporal();
	~PTTemporal();

	// Blends into history set 1 - read_index and returns the texture to show (RGBA16F, the format
	// of the RT colour it is copied into): the blend, or the debug mask when debug_mask is set (the
	// history holds the blend either way). Invalid RID: nothing was dispatched.
	RID process(Ref<RenderSceneBuffersRD> p_render_buffers, const Inputs &p_in);
};

} // namespace RendererRD
