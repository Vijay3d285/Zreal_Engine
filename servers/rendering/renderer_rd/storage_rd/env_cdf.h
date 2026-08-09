/**************************************************************************/
/*  env_cdf.h                                                             */
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

// EnvCDF: owns the GPU-side 2D importance-sampling distribution over the sky.
//
// The distribution is built by env_cdf_build.glsl into a single storage buffer
// laid out as (all floats, std430):
//
//   [0]                       floor_value
//   [1]                       marginal_total
//   [2 .. 2+N_V*N_U)          prefix_raw    (row-major inclusive prefix of raw f)
//   [.. + N_V)                rowsum_adj    (per-row sum WITH the floor folded in)
//   [.. + N_V)                marginal_prefix (inclusive prefix over rowsum_adj)
//
// A CPU mirror of the build lives in tests/servers/rendering/test_pt_env_cdf.cpp.
//
// `marginal_total == 0` means "no usable distribution": the buffer is allocated
// and zero-filled on first use, and only a successful GPU build writes a nonzero
// total. Consumers must treat 0 as "do not sample the environment".

#include "servers/rendering/renderer_rd/shaders/raytracing/env_cdf_build.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

class EnvCDF {
	static constexpr uint32_t N_U = 256;
	static constexpr uint32_t N_V = 128;
	static constexpr uint32_t FLOAT_COUNT = 2 + N_V * N_U + N_V + N_V;

	RID buffer;
	RID shader;
	RID pipeline;
	bool dirty = true;

	// Push constant mirror of the `Params` block in env_cdf_build.glsl.
	struct PushConstant {
		uint32_t mode; // 0 = rows, 1 = marginal
		uint32_t pad0;
		uint32_t pad1;
		uint32_t pad2;
	};

	// Backing ShaderRD object + version. `shader` above is the variant RID pulled
	// out of `version`; both are created lazily on the first real build so that
	// merely constructing an EnvCDF costs nothing.
	EnvCdfBuildShaderRD shader_rd;
	RID version;
	bool shader_initialized = false;

	// Source the buffer was last built from. The RD sky code has no callback that
	// says "the radiance octmap changed", so the caller hands us the texture RID
	// plus an opaque version token derived from the sky's regeneration state; a
	// change in either means the octmap contents may have moved.
	RID last_radiance_texture;
	uint64_t last_source_version = 0;
	bool has_source = false;

public:
	void mark_dirty() { dirty = true; }
	// No-ops when not dirty. p_radiance_texture may be invalid, in which case the
	// buffer is left as-is and callers must not sample the environment.
	void update(RID p_radiance_texture, RID p_sampler, uint64_t p_source_version = 0);
	RID get_buffer() const { return buffer; }
	bool is_valid() const { return buffer.is_valid(); }

	// Returns true and marks dirty when the radiance texture RID or the caller's
	// source-version token differs from the pair the current buffer was built
	// from. p_source_version is opaque here; render_raytracing.cpp derives it
	// from the sky's radiance-regeneration state.
	bool mark_dirty_if_source_changed(RID p_radiance_texture, uint64_t p_source_version);

	EnvCDF();
	~EnvCDF();
};
