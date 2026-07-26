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

#include <OpenImageDenoise/oidn.h>

// Concrete OIDN-backed implementation of PathtraceOIDNDenoiser. Uses the in-process OIDN
// C API (link-time against OpenImageDenoise.lib, runtime against the OpenImageDenoise*.dll
// plugin set in thirdparty/oidn/bin). The device/filter are created lazily on first denoise
// and torn down in the destructor. CPU device only for now (GPU-OIDN would avoid the
// GPU<->CPU round trip but has no precedent in this fork).
class OIDNDenoiser : public PathtraceOIDNDenoiser {
	GDCLASS(OIDNDenoiser, PathtraceOIDNDenoiser)

	OIDNDevice device = nullptr;
	bool committed_available = false;

	// Lazy device creation. Returns true if a usable CPU device exists.
	bool ensure_device();
	static void device_error_callback(void *user_ptr, OIDNError code, const char *message);

protected:
	static Ref<PathtraceOIDNDenoiser> create_oidn_denoiser();

public:
	~OIDNDenoiser();

	bool denoise_rt(int p_width, int p_height,
			float *p_color,
			const float *p_albedo,
			const float *p_normal,
			int p_input_spp) override;
	bool is_available() const override;

	// Called from the module register_types to wire this implementation into the
	// renderer-side PathtraceOIDNDenoiser factory (see pathtrace_oidn_denoiser.h).
	static void make_default_denoiser();
};
