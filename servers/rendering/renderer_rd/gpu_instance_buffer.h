/**************************************************************************/
/*  gpu_instance_buffer.h                                                 */
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

#include "servers/rendering/rendering_device.h"

// One entry per renderable instance. Lives permanently on GPU.
// Must match the std430 layout in gpu_cull.glsl exactly.
struct GPUInstanceData {
	float aabb_min[3];
	float lod_distance_0; // switch to LOD1 beyond this distance
	float aabb_max[3];
	float lod_distance_1; // switch to LOD2 beyond this distance
	uint32_t mesh_index;      // index into GPU mesh buffer
	uint32_t material_batch;  // which indirect draw batch this belongs to
	uint32_t flags;           // bit 0 = visible last frame, bit 1 = force draw
	uint32_t lod_level;       // current LOD level (written by feedback pass)
};

static_assert(sizeof(GPUInstanceData) == 48,
		"GPUInstanceData must be 48 bytes to match GLSL std430 layout");

class GPUInstanceBuffer {
public:
	RID buffer;
	uint32_t capacity = 0;
	uint32_t count = 0;
	bool dirty = true;

	void ensure_capacity(RenderingDevice *rd, uint32_t needed);
	void upload(RenderingDevice *rd, const Vector<GPUInstanceData> &data);
	void free_buffer(RenderingDevice *rd);
};
