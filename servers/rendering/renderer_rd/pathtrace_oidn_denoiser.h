/**************************************************************************/
/*  pathtrace_oidn_denoiser.h                                             */
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
/* the following conditions:                                               */
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

#include "core/object/ref_counted.h"

// Abstract renderer-side interface for an in-process OIDN `RT` final-denoise of a
// converged path-tracing accumulator. Lives in the renderer layer so the RT render path
// (render_forward_clustered.cpp) can call it without depending on the optional
// `raycaster_oidn` module. The module supplies a concrete implementation and registers
// it by setting `create_function` at module init (mirroring LightmapDenoiser /
// LightmapRaycaster's factory-pointer pattern, scene/3d/lightmapper.h). If no module is
// linked, `create()` returns null and the RT path keeps the raw converged result.
//
// This mirrors LightmapDenoiser (scene/3d/lightmapper.h): a RefCounted base with a GDCLASS
// macro is the established pattern even for C++-only instantiation — it enables Ref<>
// lifetime management without requiring ClassDB registration or a _bind_methods override.
class PathtraceOIDNDenoiser : public RefCounted {
	GDCLASS(PathtraceOIDNDenoiser, RefCounted)

public:
	// Factory hook the optional `raycaster_oidn` module sets at module-init. Public so the
	// module's register_types can assign it without friending (the module lives outside the
	// renderer, so a protected/private member would be inaccessible there). Returns a Ref
	// because memnew() of a RefCounted subclass yields a Ref<T>
	// (core/os/memory.h::memnew_result), matching the LightmapRaycaster/LightmapDenoiser
	// factory-pointer convention. (GDCLASS above expands to a private section, so this must
	// live under an explicit `public:` label to be reachable from the module.)
	static Ref<PathtraceOIDNDenoiser> (*create_function)();

	// One-shot final denoise of a converged PT accumulator.
	//
	// Operates purely on CPU float buffers (scene-linear, HDR). The caller is responsible
	// for the GPU<->CPU round trip: read the converged accumulator (RGBAF/A) + the albedo
	// and normal AOVs to CPU, run denoise_rt, then upload the returned `p_color` buffer
	// back. In-place: the denoised color is written back into `p_color`.
	//
	// p_width, p_height   - pixel dimensions of color/albedo/normal.
	// p_color             - color buffer, layout = float3 per pixel (RGB, scene-linear),
	//                        `p_width * p_height * 3` floats. Denoised in place. Cannot be null.
	// p_albedo            - optional diffuse albedo AOV, float3 per pixel (in [0,1]). May be null to
	//                        run color-only denoising (lower quality).
	// p_normal            - optional view-space normal AOV, float3 per pixel (length-normalized).
	//                        May be null.
	// p_input_spp         - effective accumulated sample count (informative; OIDN does not require it).
	//
	// Returns true on success; false (with an engine error logged) if the OIDN device/filter
	// could not be created or run. On failure `p_color` is left untouched so the caller still
	// has the raw converged image.
	virtual bool denoise_rt(int p_width, int p_height,
			float *p_color,
			float *p_albedo,
			float *p_normal,
			int p_input_spp) = 0;

	// Whether this implementation is ready to denoise at all (device created, weights loaded).
	// Returning false here lets the RT path decide to keep the raw image rather than spin OIDN.
	virtual bool is_available() const = 0;

	// Convenience factory: returns a concrete instance if the module linked one in, else a
	// null Ref. Callers should use is_null() to detect the no-module case.
	static Ref<PathtraceOIDNDenoiser> create();
};
