/**************************************************************************/
/*  oidn_denoiser.cpp                                                     */
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
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/**************************************************************************/

#include "oidn_denoiser.h"

#include "core/error/error_macros.h"
#include "core/string/print_string.h"

void OIDNDenoiser::device_error_callback(void *user_ptr, OIDNError code, const char *message) {
	ERR_PRINT(vformat("OIDN device error (code %d): %s", static_cast<int>(code), message ? message : "<no message>"));
}

bool OIDNDenoiser::ensure_device() {
	if (device) {
		return committed_available;
	}
	if (!oidnIsCPUDeviceSupported()) {
		ERR_PRINT("OIDN CPU device is not supported on this system; final-denoise will be skipped.");
		return false;
	}
	device = oidnNewDevice(OIDN_DEVICE_TYPE_CPU);
	if (!device) {
		ERR_PRINT("oidnNewDevice(CPU) returned null; final-denoise will be skipped.");
		return false;
	}
	oidnSetDeviceErrorFunction(device, device_error_callback, nullptr);
	oidnSetDeviceBool(device, "biquadraticFilter", true); // slightly higher quality, negligible cost for a one-shot.
	oidnCommitDevice(device);
	committed_available = (oidnGetDeviceError(device, nullptr) == OIDN_ERROR_NONE);
	if (!committed_available) {
		ERR_PRINT("OIDN device failed to commit; final-denoise will be skipped.");
	}
	return committed_available;
}

// Cycles' DENOISER_PREFILTER_ACCURATE (intern/cycles/integrator/denoiser_oidn_gpu.cpp):
// each guide is run through its own RT filter -- the guide image as the only input,
// output in place -- before the colour pass, which then trusts them (cleanAux = true).
static bool oidn_prefilter_guide(OIDNDevice p_device, const char *p_name, float *p_buf, int p_width, int p_height) {
	OIDNFilter filter = oidnNewFilter(p_device, "RT");
	ERR_FAIL_COND_V_MSG(!filter, false, "oidnNewFilter(\"RT\") for guide prefilter returned null.");
	oidnSetSharedFilterImage(filter, p_name, p_buf, OIDN_FORMAT_FLOAT3, (size_t)p_width, (size_t)p_height, 0, 0, 0);
	oidnSetSharedFilterImage(filter, "output", p_buf, OIDN_FORMAT_FLOAT3, (size_t)p_width, (size_t)p_height, 0, 0, 0);
	oidnCommitFilter(filter);
	oidnExecuteFilter(filter);
	const OIDNError err = oidnGetDeviceError(p_device, nullptr);
	oidnReleaseFilter(filter);
	ERR_FAIL_COND_V_MSG(err != OIDN_ERROR_NONE, false, vformat("OIDN %s prefilter failed (error %d).", p_name, (int)err));
	return true;
}

bool OIDNDenoiser::denoise_rt(int p_width, int p_height,
		float *p_color,
		float *p_albedo,
		float *p_normal,
		int p_input_spp) {
	ERR_FAIL_NULL_V_MSG(p_color, false, "OIDN denoise: color buffer is null.");
	ERR_FAIL_COND_V_MSG(p_width <= 0 || p_height <= 0, false, "OIDN denoise: invalid dimensions.");
	if (!ensure_device()) {
		return false;
	}

	if (p_albedo && !oidn_prefilter_guide(device, "albedo", p_albedo, p_width, p_height)) {
		return false;
	}
	if (p_normal && !oidn_prefilter_guide(device, "normal", p_normal, p_width, p_height)) {
		return false;
	}

	OIDNFilter filter = oidnNewFilter(device, "RT");
	ERR_FAIL_COND_V_MSG(!filter, false, "oidnNewFilter(\"RT\") returned null.");

	const size_t image_float_count = static_cast<size_t>(p_width) * static_cast<size_t>(p_height) * 3;

	// Color/auxiliaries are host buffers, shared directly with the device via shared images
	// (pixelByteStride/rowByteStride zero -> OIDN computes them from format + width).
	oidnSetSharedFilterImage(filter, "color", p_color, OIDN_FORMAT_FLOAT3,
			static_cast<size_t>(p_width), static_cast<size_t>(p_height), 0, 0, 0);
	// OIDN writes denoised output to the image set as "output"; using the same buffer as
	// "color" makes it denoise in place (RT filter supports input==output).
	oidnSetSharedFilterImage(filter, "output", p_color, OIDN_FORMAT_FLOAT3,
			static_cast<size_t>(p_width), static_cast<size_t>(p_height), 0, 0, 0);

	if (p_albedo) {
		oidnSetSharedFilterImage(filter, "albedo", const_cast<float *>(p_albedo), OIDN_FORMAT_FLOAT3,
				static_cast<size_t>(p_width), static_cast<size_t>(p_height), 0, 0, 0);
	}
	if (p_normal) {
		oidnSetSharedFilterImage(filter, "normal", const_cast<float *>(p_normal), OIDN_FORMAT_FLOAT3,
				static_cast<size_t>(p_width), static_cast<size_t>(p_height), 0, 0, 0);
	}

	// Scene-linear HDR radiance: input and output are untonemapped, may exceed 1.0.
	oidnSetFilterBool(filter, "hdr", true);
	// cleanAux = true: the guides are the accumulated primary albedo / normal -- every sample
	// at its pixel-filter jitter, the same average as the colour (Cycles' denoising passes) --
	// and were just prefiltered by OIDN's own albedo / normal filters above. That is Cycles'
	// DENOISER_PREFILTER_ACCURATE, its default. The earlier cleanAux = false was a mitigation
	// for guides that were one point sample per pixel (the DLSS-RR G-buffers); those made
	// OIDN erase any texture finer than a pixel -- the far half of a 4K still (job 224).
	oidnSetFilterBool(filter, "cleanAux", true);

	(void)p_input_spp; // OIDN RT filter has no per-call SPP parameter; reserved for future calibration.

	oidnCommitFilter(filter);
	OIDNError commit_err = oidnGetDeviceError(device, nullptr);
	if (commit_err != OIDN_ERROR_NONE) {
		ERR_PRINT(vformat("OIDN RT filter failed to commit (error %d). Keeping raw converged image.", static_cast<int>(commit_err)));
		oidnReleaseFilter(filter);
		return false;
	}

	oidnExecuteFilter(filter);

	OIDNError exec_err = oidnGetDeviceError(device, nullptr);
	if (exec_err != OIDN_ERROR_NONE) {
		ERR_PRINT(vformat("OIDN RT filter execution failed (error %d). The color buffer may be partially denoised.", static_cast<int>(exec_err)));
		oidnReleaseFilter(filter);
		return false;
	}

	oidnReleaseFilter(filter);
	return true;
}

bool OIDNDenoiser::is_available() const {
	// A device is created lazily; if we've never denoised, report available so the RT path
	// will attempt the first denoise (which also probes the device). If a prior attempt
	// failed, committed_available sticks false and we report that.
	if (!device) {
		return true; // unprobed; let the first call probe the device.
	}
	return committed_available;
}

OIDNDenoiser::~OIDNDenoiser() {
	if (device) {
		oidnReleaseDevice(device);
		device = nullptr;
		committed_available = false;
	}
}

Ref<PathtraceOIDNDenoiser> OIDNDenoiser::create_oidn_denoiser() {
	return memnew(OIDNDenoiser);
}

void OIDNDenoiser::make_default_denoiser() {
	create_function = create_oidn_denoiser;
}
