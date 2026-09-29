/**************************************************************************/
/*  local_highlight.h                                                     */
/**************************************************************************/

#pragma once

#include "servers/rendering/renderer_rd/shaders/effects/local_highlight.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

namespace RendererRD {

// Local highlight relief (spec 2026-09-28-local-highlight-relief-design.md).
//
// Divides the colour buffer by a smooth gain derived from a heavily blurred
// luminance, so a blown region slides down the tone curve as a whole while its
// own high-frequency detail survives. Runs between the OIDN denoise and the
// tone curve; the buffer it reads is SCENE-LINEAR AND PRE-EXPOSURE, which is
// why process() takes the exposure and applies it when locating the knee.
class LocalHighlight {
	enum Mode {
		MODE_DOWNSAMPLE,
		MODE_APPLY,
		MODE_MAX
	};

	struct PushConstant {
		int32_t src_size[2];
		int32_t dst_size[2];
		float strength;
		float exposure;
		float knee;
		uint32_t debug;
	};

	LocalHighlightShaderRD shader;
	RID shader_version;
	RID pipelines[MODE_MAX];

public:
	LocalHighlight();
	~LocalHighlight();

	// p_strength == 0.0 is not a valid call: the CALLER must skip dispatch
	// entirely so a gated-off frame runs no shader at all.
	void process(Ref<RenderSceneBuffersRD> p_render_buffers, float p_strength, float p_exposure, float p_knee, bool p_debug);
};

} //namespace RendererRD
