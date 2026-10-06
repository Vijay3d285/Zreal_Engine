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
#include "core/config/project_settings.h"
#include <cstring>

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

bool OIDNDenoiser::denoise_rt_cpu(int p_width, int p_height,
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

// ---------------------------------------------------------------------------------------------
// Device dispatch (spec 2026-10-01-video-oidn-design.md). CPU, the default, runs the original
// code above unchanged. CUDA runs the persistent path below and falls back to CPU on any
// failure, so a frame is never left undenoised because the GPU path broke.
// ---------------------------------------------------------------------------------------------
bool OIDNDenoiser::denoise_rt(int p_width, int p_height,
		float *p_color,
		float *p_albedo,
		float *p_normal,
		int p_input_spp) {
	// The same guards denoise_rt_cpu() applies, taken BEFORE the CUDA path: a null colour buffer
	// or a non-positive size is the caller's bug, and must not reach cuda_denoise() where it
	// would mark CUDA failed for the rest of the process.
	ERR_FAIL_NULL_V_MSG(p_color, false, "OIDN denoise: color buffer is null.");
	ERR_FAIL_COND_V_MSG(p_width <= 0 || p_height <= 0, false, "OIDN denoise: invalid dimensions.");
	const int requested = (int)GLOBAL_GET("rendering/pathtracer/oidn_device");
	if (requested == DEVICE_SETTING_CUDA && !cuda.failed) {
		if (cuda_denoise(p_width, p_height, p_color, p_albedo, p_normal)) {
			return true;
		}
		// cuda_denoise() logged the reason and marked CUDA failed. p_color still holds the raw
		// input (the CUDA output is only copied into it on success), so the CPU path below
		// denoises the right image.
	}
	return denoise_rt_cpu(p_width, p_height, p_color, p_albedo, p_normal, p_input_spp);
}

OIDNDenoiser::CUDAState OIDNDenoiser::cuda;

void OIDNDenoiser::cuda_fail(const String &p_reason) {
	if (!cuda.failed) {
		ERR_PRINT(vformat("[OIDN] CUDA unavailable/failed (%s); using CPU for the rest of this process.", p_reason));
	}
	cuda.failed = true;
	cuda_release_filters_and_buffers();
	if (cuda.device) {
		oidnReleaseDevice(cuda.device);
		cuda.device = nullptr;
	}
}

// Reads and clears the CUDA device's error state. No error callback is installed for this
// device, so polling here is the single place errors surface.
bool OIDNDenoiser::cuda_check(const char *p_where) {
	const char *message = nullptr;
	const OIDNError err = oidnGetDeviceError(cuda.device, &message);
	if (err == OIDN_ERROR_NONE) {
		return true;
	}
	cuda_fail(vformat("%s: error %d, %s", p_where, (int)err, message ? message : "<no message>"));
	return false;
}

void OIDNDenoiser::cuda_release_filters_and_buffers() {
	OIDNFilter *filters[] = { &cuda.albedo_filter, &cuda.normal_filter, &cuda.rt_filter };
	for (OIDNFilter *f : filters) {
		if (*f) {
			oidnReleaseFilter(*f);
			*f = nullptr;
		}
	}
	OIDNBuffer *buffers[] = { &cuda.color, &cuda.albedo, &cuda.normal };
	for (OIDNBuffer *b : buffers) {
		if (*b) {
			oidnReleaseBuffer(*b);
			*b = nullptr;
		}
	}
	cuda.width = 0;
	cuda.height = 0;
	cuda.has_albedo = false;
	cuda.has_normal = false;
}

bool OIDNDenoiser::cuda_ensure_device() {
	if (cuda.device) {
		return true;
	}
	if (!oidnIsCUDADeviceSupported(0)) {
		cuda_fail("oidnIsCUDADeviceSupported(0) is false");
		return false;
	}
	// Cycles' exact call (integrator/denoiser_oidn_gpu.cpp:234): an explicit device id and a
	// NULL stream -- "directly using the stream from the DeviceQueue returns 'invalid resource
	// handle'". cudaStream_t is typedef'd by oidn.h itself; no CUDA headers are needed.
	const int device_id = 0;
	const cudaStream_t stream = nullptr;
	cuda.device = oidnNewCUDADevice(&device_id, &stream, 1);
	if (!cuda.device) {
		cuda_fail("oidnNewCUDADevice returned null");
		return false;
	}
	oidnCommitDevice(cuda.device);
	return cuda_check("oidnCommitDevice");
}

// Buffers and filters for one frame size and pass set. Committing a filter loads the network
// weights, so they are committed once here and only EXECUTED per frame.
bool OIDNDenoiser::cuda_configure(int p_width, int p_height, bool p_albedo, bool p_normal) {
	if (cuda.rt_filter && cuda.width == p_width && cuda.height == p_height &&
			cuda.has_albedo == p_albedo && cuda.has_normal == p_normal) {
		return true;
	}
	cuda_release_filters_and_buffers();
	const size_t w = (size_t)p_width;
	const size_t h = (size_t)p_height;
	const size_t bytes = w * h * 3 * sizeof(float);

	auto new_buffer = [&](OIDNBuffer &r_buf, const char *p_name) -> bool {
		r_buf = oidnNewBuffer(cuda.device, bytes);
		if (!r_buf) {
			cuda_fail(vformat("oidnNewBuffer(%s) returned null", p_name));
			return false;
		}
		return cuda_check(p_name);
	};
	auto new_rt_filter = [&](OIDNFilter &r_filter, const char *p_name) -> bool {
		r_filter = oidnNewFilter(cuda.device, "RT");
		if (!r_filter) {
			cuda_fail(vformat("oidnNewFilter(RT) for %s returned null", p_name));
			return false;
		}
		// Quality pinned to HIGH on every filter, as Cycles does (denoiser_oidn_base.cpp:33-45).
		// It is OIDN 2.5.0's default today (measured: 156.57 vs 156.63 ms; BALANCED 76.74 ms and
		// 80.4% of pixels 2+ levels off) -- pinned so an OIDN upgrade cannot lower it silently.
		oidnSetFilterInt(r_filter, "quality", OIDN_QUALITY_HIGH);
		return true;
	};

	if (!new_buffer(cuda.color, "color")) {
		return false;
	}
	if (p_albedo && !new_buffer(cuda.albedo, "albedo")) {
		return false;
	}
	if (p_normal && !new_buffer(cuda.normal, "normal")) {
		return false;
	}

	// Guide prefilters -- Cycles' DENOISER_PREFILTER_ACCURATE, as the CPU path does: each guide
	// through its own RT filter, in place, before the colour pass trusts it (cleanAux).
	if (p_albedo) {
		if (!new_rt_filter(cuda.albedo_filter, "albedo prefilter")) {
			return false;
		}
		oidnSetFilterImage(cuda.albedo_filter, "albedo", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnSetFilterImage(cuda.albedo_filter, "output", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnCommitFilter(cuda.albedo_filter);
		if (!cuda_check("commit albedo prefilter")) {
			return false;
		}
	}
	if (p_normal) {
		if (!new_rt_filter(cuda.normal_filter, "normal prefilter")) {
			return false;
		}
		oidnSetFilterImage(cuda.normal_filter, "normal", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnSetFilterImage(cuda.normal_filter, "output", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
		oidnCommitFilter(cuda.normal_filter);
		if (!cuda_check("commit normal prefilter")) {
			return false;
		}
	}

	if (!new_rt_filter(cuda.rt_filter, "colour")) {
		return false;
	}
	// In place, as Cycles does (denoise_run sets "color" and "output" to the same device memory).
	oidnSetFilterImage(cuda.rt_filter, "color", cuda.color, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	oidnSetFilterImage(cuda.rt_filter, "output", cuda.color, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	if (p_albedo) {
		oidnSetFilterImage(cuda.rt_filter, "albedo", cuda.albedo, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	}
	if (p_normal) {
		oidnSetFilterImage(cuda.rt_filter, "normal", cuda.normal, OIDN_FORMAT_FLOAT3, w, h, 0, 0, 0);
	}
	// Same two flags as the CPU path: scene-linear HDR, and guides already prefiltered.
	oidnSetFilterBool(cuda.rt_filter, "hdr", true);
	oidnSetFilterBool(cuda.rt_filter, "cleanAux", true);
	oidnCommitFilter(cuda.rt_filter);
	if (!cuda_check("commit colour filter")) {
		return false;
	}

	// The host scratch the output is read back into. Checked: a failed resize leaves the vector at
	// its previous (possibly smaller) size, and oidnReadBuffer would then write past its end.
	if (cuda.readback.resize((Vector<float>::Size)(w * h * 3)) != OK) {
		cuda_fail(vformat("readback scratch allocation failed (%d floats)", (int64_t)(w * h * 3)));
		return false;
	}
	cuda.width = p_width;
	cuda.height = p_height;
	cuda.has_albedo = p_albedo;
	cuda.has_normal = p_normal;
	return true;
}

bool OIDNDenoiser::cuda_denoise(int p_width, int p_height, float *p_color, float *p_albedo, float *p_normal) {
	if (!cuda_ensure_device()) {
		return false;
	}
	if (!cuda_configure(p_width, p_height, p_albedo != nullptr, p_normal != nullptr)) {
		return false;
	}
	const size_t bytes = (size_t)p_width * (size_t)p_height * 3 * sizeof(float);

	// oidnWriteBuffer / oidnExecuteFilter / oidnReadBuffer are the SYNCHRONOUS variants (each has
	// a separate *Async twin in oidn.h), so no explicit oidnSyncDevice is needed.
	oidnWriteBuffer(cuda.color, 0, bytes, p_color);
	if (p_albedo) {
		oidnWriteBuffer(cuda.albedo, 0, bytes, p_albedo);
	}
	if (p_normal) {
		oidnWriteBuffer(cuda.normal, 0, bytes, p_normal);
	}
	if (!cuda_check("oidnWriteBuffer")) {
		return false;
	}
	if (cuda.albedo_filter) {
		oidnExecuteFilter(cuda.albedo_filter);
		if (!cuda_check("execute albedo prefilter")) {
			return false;
		}
	}
	if (cuda.normal_filter) {
		oidnExecuteFilter(cuda.normal_filter);
		if (!cuda_check("execute normal prefilter")) {
			return false;
		}
	}
	oidnExecuteFilter(cuda.rt_filter);
	if (!cuda_check("execute colour filter")) {
		return false;
	}
	// Into the scratch first: a failed read must not leave p_color half-overwritten, because the
	// CPU fallback denoises p_color next.
	oidnReadBuffer(cuda.color, 0, bytes, cuda.readback.ptrw());
	if (!cuda_check("oidnReadBuffer")) {
		return false;
	}
	memcpy(p_color, cuda.readback.ptr(), bytes);

	if (!cuda.announced) {
		cuda.announced = true;
		print_line(vformat("[OIDN] denoising on CUDA (quality HIGH, %dx%d)", p_width, p_height));
	}
	return true;
}

void OIDNDenoiser::release_shared_cuda() {
	cuda_release_filters_and_buffers();
	if (cuda.device) {
		oidnReleaseDevice(cuda.device);
		cuda.device = nullptr;
	}
	cuda.readback.clear();
	cuda.failed = false;
	cuda.announced = false;
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
