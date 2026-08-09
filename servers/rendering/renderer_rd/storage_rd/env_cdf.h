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
//
// ---------------------------------------------------------------------------
// CONTRACT FOR CONSUMERS (read this before hand-writing a GLSL mirror)
// ---------------------------------------------------------------------------
//
// 1. COORDINATE SPACE. The (u, v) grid lives in SKY / OCTMAP space, not world
//    space. env_cdf_build.glsl walks cell centres straight into
//    `vec3_to_oct_with_border()` with no transform, exactly as the sky's own
//    radiance lookup does *after* it has rotated into sky space:
//
//        mat3 world_to_sky = radiance_inverse_xform * camera_basis;   // raygen
//        vec3 sky_dir      = world_to_sky * world_dir;
//
//    (`scene_raytracing_raygen.glsl`, the `sky_dir` / `sky_uv` block.) A consumer
//    must therefore apply `world_to_sky` before evaluating the pdf for a world
//    direction, and the INVERSE (`transpose(world_to_sky)`, it is orthonormal)
//    after sampling a (u, v) to get a world-space direction. Skipping either
//    rotates the sampling distribution off the sky and silently maximises
//    variance instead of reducing it.
//
// 2. AZIMUTH WRAP. The grid is parameterised as
//        theta = v * PI          dir.y = cos(theta)      (engine is Y-up)
//        phi   = u * 2 * PI      dir   = (sin(theta)*sin(phi), cos(theta),
//                                         sin(theta)*cos(phi))
//    Inverting it uses `phi = atan(dir.x, dir.z)`, which returns (-PI, PI].
//    So the inverse is `u = fract(phi / (2*PI))`, NOT `phi / (2*PI)` -- the
//    unwrapped form yields a NEGATIVE u for half the sphere and, after the
//    int() truncation in the cell lookup, aliases onto the wrong column.
//    `v = acos(clamp(dir.y, -1, 1)) / PI` needs no wrap.
//
// 3. THE sin(theta) IS ALREADY IN THE DATA. `cell_raw()` stores
//    `luminance * sin(theta)`, so the stored value is already a solid-angle
//    density up to normalisation. The cell's solid angle is
//        dOmega = 2 * PI^2 * sin(theta) * du * dv
//    and the pdf over solid angle divides by that factor exactly ONCE:
//        func_int = marginal_total / (N_U * N_V)
//        pdf_uv   = cell_value / func_int
//        pdf_w    = pdf_uv / (2 * PI^2 * max(sin(theta), 1e-6))
//    Dividing by sin(theta) a second time (a natural mistake, since the build
//    multiplied by it) over-weights the poles and biases MIS.
//
// 4. The radiance octmap is PADDED. Cell values are fetched through
//    `vec3_to_oct_with_border(dir, vec2(b, 1 - 2b))` with
//    `b = SkyRD::sky_get_uv_border_size()`. Any consumer that re-fetches the
//    octmap itself must use the same bordered mapping.

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
		float border; // SkyRD::sky_get_uv_border_size() of the radiance octmap.
		uint32_t pad0;
		uint32_t pad1;
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
	// p_border is SkyRD::sky_get_uv_border_size() for the sky that owns
	// p_radiance_texture (see contract note 4 above).
	void update(RID p_radiance_texture, RID p_sampler, float p_border, uint64_t p_source_version = 0);
	RID get_buffer() const { return buffer; }
	bool is_valid() const { return buffer.is_valid(); }

	// Marks dirty when the radiance texture RID or the caller's source-version
	// token differs from the pair the current buffer was built from.
	// p_source_version is opaque here; render_raytracing.cpp derives it from the
	// sky's radiance-regeneration state and its uv border size.
	void mark_dirty_if_source_changed(RID p_radiance_texture, uint64_t p_source_version);

	EnvCDF();
	~EnvCDF();
};
