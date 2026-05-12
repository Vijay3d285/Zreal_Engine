/**************************************************************************/
/*  gpu_instance_buffer.cpp                                               */
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

#include "gpu_instance_buffer.h"

void GPUInstanceBuffer::ensure_capacity(RenderingDevice *rd, uint32_t needed) {
	if (needed <= capacity) {
		return;
	}
	uint32_t new_cap = MAX(needed, capacity * 2);
	new_cap = MAX(new_cap, 256u);
	if (buffer.is_valid()) {
		rd->free_rid(buffer);
	}
	buffer = rd->storage_buffer_create(new_cap * sizeof(GPUInstanceData));
	capacity = new_cap;
	dirty = true;
}

void GPUInstanceBuffer::upload(RenderingDevice *rd,
		const Vector<GPUInstanceData> &data) {
	ensure_capacity(rd, (uint32_t)data.size());
	count = (uint32_t)data.size();
	if (count == 0) {
		return;
	}
	rd->buffer_update(buffer, 0, count * sizeof(GPUInstanceData), data.ptr());
	dirty = false;
}

void GPUInstanceBuffer::free_buffer(RenderingDevice *rd) {
	if (buffer.is_valid()) {
		rd->free_rid(buffer);
		buffer = RID();
	}
	capacity = 0;
	count = 0;
}
