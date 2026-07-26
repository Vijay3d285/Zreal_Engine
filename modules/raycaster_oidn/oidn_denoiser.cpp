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

bool OIDNDenoiser::denoise_rt(int p_width, int p_height,
		float *p_color,
		const float *p_albedo,
		const float *p_normal,
		int p_input_spp) {
	ERR_FAIL_NULL_V_MSG(p_color, false, "OIDN denoise: color buffer is null.");
	ERR_FAIL_COND_V_MSG(p_width <= 0 || p_height <= 0, false, "OIDN denoise: invalid dimensions.");
	if (!ensure_device()) {
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
	// RT filter expects physically meaningful radiance; disable post-denoise clean-up of aux.
	oidnSetFilterBool(filter, "cleanAux", false);

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
