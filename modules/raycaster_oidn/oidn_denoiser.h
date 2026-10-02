/**************************************************************************/
/*  oidn_denoiser.h                                                       */
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
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/**************************************************************************/

#pragma once

#include "servers/rendering/renderer_rd/pathtrace_oidn_denoiser.h"

#include "core/templates/vector.h"

#include <OpenImageDenoise/oidn.h>

// Concrete OIDN-backed implementation of PathtraceOIDNDenoiser. Uses the in-process OIDN
// C API (link-time against OpenImageDenoise.lib, runtime against the OpenImageDenoise*.dll
// plugin set in thirdparty/oidn/bin).
//
// Two device paths, chosen per denoise by the project setting rendering/pathtracer/oidn_device:
//  * CPU (0, the default): the original path, unchanged -- a device per denoiser object and host
//    buffers shared with OIDN. The still route uses it.
//  * CUDA (1): spec docs/superpowers/specs/2026-10-01-video-oidn-design.md. ONE device, buffer
//    set and filter set for the whole process, mirroring Cycles
//    (intern/cycles/integrator/denoiser_oidn_gpu.cpp, which keeps them until the passes or the
//    quality change). The caller creates a denoiser object per denoise, so per-object CUDA
//    state would mean a CUDA context per video frame. Any CUDA failure falls back to the CPU
//    path for that denoise and every later one in the process.
class OIDNDenoiser : public PathtraceOIDNDenoiser {
	GDCLASS(OIDNDenoiser, PathtraceOIDNDenoiser)

	OIDNDevice device = nullptr;
	bool committed_available = false;

	// Lazy device creation. Returns true if a usable CPU device exists.
	bool ensure_device();
	static void device_error_callback(void *user_ptr, OIDNError code, const char *message);

	// The original CPU denoise, unchanged.
	bool denoise_rt_cpu(int p_width, int p_height,
			float *p_color,
			float *p_albedo,
			float *p_normal,
			int p_input_spp);

	// ---- CUDA path: process-lifetime state shared by every OIDNDenoiser object. ----
	struct CUDAState {
		OIDNDevice device = nullptr;
		OIDNBuffer color = nullptr;
		OIDNBuffer albedo = nullptr;
		OIDNBuffer normal = nullptr;
		OIDNFilter albedo_filter = nullptr;
		OIDNFilter normal_filter = nullptr;
		OIDNFilter rt_filter = nullptr;
		int width = 0;
		int height = 0;
		bool has_albedo = false;
		bool has_normal = false;
		bool failed = false; // sticky for the process
		bool announced = false; // the first successful CUDA denoise is logged once
		Vector<float> readback; // host scratch: the output lands here first, p_color only on success
	};
	static CUDAState cuda;
	static void cuda_fail(const String &p_reason);
	static bool cuda_check(const char *p_where);
	static void cuda_release_filters_and_buffers();
	static bool cuda_ensure_device();
	static bool cuda_configure(int p_width, int p_height, bool p_albedo, bool p_normal);
	static bool cuda_denoise(int p_width, int p_height, float *p_color, float *p_albedo, float *p_normal);

protected:
	static Ref<PathtraceOIDNDenoiser> create_oidn_denoiser();

public:
	// Values of rendering/pathtracer/oidn_device.
	enum {
		DEVICE_SETTING_CPU = 0,
		DEVICE_SETTING_CUDA = 1,
	};

	~OIDNDenoiser();

	bool denoise_rt(int p_width, int p_height,
			float *p_color,
			float *p_albedo,
			float *p_normal,
			int p_input_spp) override;
	bool is_available() const override;

	// Called from the module register_types to wire this implementation into the
	// renderer-side PathtraceOIDNDenoiser factory (see pathtrace_oidn_denoiser.h).
	static void make_default_denoiser();
	// Releases the process-lifetime CUDA device, buffers and filters. Called from
	// uninitialize_raycaster_oidn_module.
	static void release_shared_cuda();
};
