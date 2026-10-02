/**************************************************************************/
/*  register_types.cpp                                                    */
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
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                */
/**************************************************************************/

#include "register_types.h"

#include "oidn_denoiser.h"

#include "core/object/class_db.h"

void initialize_raycaster_oidn_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}
	// Wire the OIDN-backed PathtraceOIDNDenoiser into the renderer-side factory so the RT
	// render path (render_forward_clustered.cpp) can call it without a hard link to this
	// module. Mirrors modules/raycast/s LightmapRaycasterEmbree::make_default_raycaster().
	OIDNDenoiser::make_default_denoiser();
}

void uninitialize_raycaster_oidn_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}
	// The CUDA path's device, buffers and filters live for the process (spec
	// 2026-10-01-video-oidn-design.md); this is where they end.
	OIDNDenoiser::release_shared_cuda();
	// Clear the factory so the renderer stops reaching into a torn-down module. Concrete
	// OIDNDenoiser instances created earlier are RefCounted and freed when their last
	// reference drops (held by the RT render path's local scope).
	PathtraceOIDNDenoiser::create_function = nullptr;
}
