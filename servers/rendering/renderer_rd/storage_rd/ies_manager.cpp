/**************************************************************************/
/*  ies_manager.cpp                                                       */
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

#include "ies_manager.h"

#include "core/io/file_access.h"
#include "core/string/string_name.h"

// ---------------------------------------------------------------------------
// IESManager::add_ies
// ---------------------------------------------------------------------------

int IESManager::add_ies(const String &p_content) {
	if (p_content.is_empty()) {
		return -1;
	}

	uint32_t content_hash = p_content.hash();

	MutexLock lock(mutex);

	// 1. Check for existing slot with the same hash (deduplication).
	for (uint32_t i = 0; i < slots.size(); i++) {
		if (slots[i].hash == content_hash && slots[i].users > 0) {
			slots[i].users++;
			return (int)i;
		}
	}

	// 2. Find an empty slot or append a new one.
	int slot = _find_or_create_empty_slot();
	if (slot < 0) {
		ERR_PRINT("IESManager: Slot table full (max " + itos(IES_MAX_SLOTS) + " profiles).");
		return -1;
	}

	// 3. Parse the IES content.
	if (!slots[slot].ies.load(p_content)) {
		ERR_PRINT("IESManager: Failed to parse IES content.");
		return -1;
	}

	slots[slot].hash = content_hash;
	slots[slot].users = 1;
	needs_update = true;
	return slot;
}

// ---------------------------------------------------------------------------
// IESManager::add_ies_from_file
// ---------------------------------------------------------------------------

int IESManager::add_ies_from_file(const String &p_filepath) {
	Ref<FileAccess> f = FileAccess::open(p_filepath, FileAccess::READ);
	if (f.is_null()) {
		ERR_PRINT(vformat("IESManager: Cannot open IES file '%s'.", p_filepath));
		return -1;
	}
	String content = f->get_as_text();
	return add_ies(content);
}

// ---------------------------------------------------------------------------
// IESManager::remove_ies
// ---------------------------------------------------------------------------

void IESManager::remove_ies(int p_slot) {
	if (p_slot < 0) {
		return;
	}

	MutexLock lock(mutex);

	if (p_slot >= (int)slots.size()) {
		return;
	}

	IESSlot &s = slots[p_slot];
	if (s.users <= 0) {
		return;
	}

	s.users--;
	if (s.users == 0) {
		s.ies.clear();
		s.hash = 0;
		needs_update = true;
	}
}

// ---------------------------------------------------------------------------
// IESManager::device_update
// ---------------------------------------------------------------------------

void IESManager::device_update(RenderingDevice *p_rd, RID &r_ies_buffer, uint32_t &r_ies_buffer_bytes) {
	ERR_FAIL_NULL(p_rd);

	MutexLock lock(mutex);

	// --- Step 1: Trim trailing empty slots ---
	while (!slots.is_empty() && slots[slots.size() - 1].users == 0 && slots[slots.size() - 1].hash == 0) {
		slots.resize(slots.size() - 1);
	}

	uint32_t num_slots = slots.size();

	// --- Step 2: Calculate total packed data size ---
	uint32_t packed_total = 0;
	for (uint32_t i = 0; i < num_slots; i++) {
		if (slots[i].users > 0 && slots[i].ies.is_valid()) {
			packed_total += (uint32_t)slots[i].ies.packed_size();
		}
	}

	// Total buffer size: offset_table (num_slots floats) + packed data.
	uint32_t total_floats = num_slots + packed_total;

	if (total_floats == 0) {
		// No profiles; free the buffer if it exists.
		if (r_ies_buffer.is_valid()) {
			p_rd->free_rid(r_ies_buffer);
			r_ies_buffer = RID();
			r_ies_buffer_bytes = 0;
		}
		needs_update = false;
		return;
	}

	// --- Step 3: Build CPU-side buffer ---
	Vector<float> cpu_data;
	cpu_data.resize(total_floats);
	float *data = cpu_data.ptrw();

	// Fill offset table and pack each profile.
	uint32_t write_offset = num_slots; // Packed data starts after the offset table.
	for (uint32_t i = 0; i < num_slots; i++) {
		if (slots[i].users > 0 && slots[i].ies.is_valid()) {
			// Store offset as int-in-float (matching Cycles __int_as_float convention).
			int ofs = (int)write_offset;
			data[i] = *(const float *)&ofs;
			slots[i].ies.pack(data + write_offset);
			write_offset += (uint32_t)slots[i].ies.packed_size();
		} else {
			// Invalid slot marker: -1.
			int invalid = -1;
			data[i] = *(const float *)&invalid;
		}
	}

	// --- Step 4: Upload to GPU ---
	uint32_t buf_bytes = total_floats * sizeof(float);

	if (r_ies_buffer.is_valid()) {
		// Resize if the byte count has changed.
		if (r_ies_buffer_bytes != buf_bytes) {
			p_rd->free_rid(r_ies_buffer);
			r_ies_buffer = RID();
			r_ies_buffer_bytes = 0;
		}
	}

	if (!r_ies_buffer.is_valid()) {
		r_ies_buffer = p_rd->storage_buffer_create(buf_bytes);
		ERR_FAIL_COND_MSG(!r_ies_buffer.is_valid(), "IESManager: Failed to create GPU buffer.");
		r_ies_buffer_bytes = buf_bytes;
	}

	p_rd->buffer_update(r_ies_buffer, 0, buf_bytes, data);
	needs_update = false;
}

// ---------------------------------------------------------------------------
// IESManager::clear
// ---------------------------------------------------------------------------

void IESManager::clear() {
	MutexLock lock(mutex);
	slots.clear();
	needs_update = false;
}

// ---------------------------------------------------------------------------
// IESManager::_find_or_create_empty_slot  (called with mutex held)
// ---------------------------------------------------------------------------

int IESManager::_find_or_create_empty_slot() {
	// Prefer recycling existing empty slots.
	for (uint32_t i = 0; i < slots.size(); i++) {
		if (slots[i].users == 0 && slots[i].hash == 0) {
			return (int)i;
		}
	}

	// Append a new slot if under the cap.
	if ((int)slots.size() >= IES_MAX_SLOTS) {
		return -1;
	}

	slots.push_back(IESSlot());
	return (int)(slots.size() - 1);
}
