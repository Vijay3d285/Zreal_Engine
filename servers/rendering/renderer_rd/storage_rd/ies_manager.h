/**************************************************************************/
/*  ies_manager.h                                                         */
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

// IESManager: manages a slot table of parsed IES photometric profiles.
//
// Design mirrors Blender Cycles LightManager IES slot system:
//   - Hash-based deduplication: identical IES content shares one GPU slot.
//   - Reference counting: slots freed only when all users release them.
//   - Thread safety: all slot mutations protected by a Mutex.
//   - Dirty flag: signals when device_update() must re-upload the GPU buffer.
//
// The GPU buffer layout (matching Cycles DeviceScene::ies_lights):
//   [ offset_table: N floats, where float == intBitsToFloat(byte_offset_into_data) ]
//   [ packed_profile_0 ][ packed_profile_1 ] ...
//
// Offset table entries use intBitsToFloat(-1) to signal an invalid/empty slot.

#include "core/io/ies_file.h"
#include "core/os/mutex.h"
#include "core/string/ustring.h"
#include "core/templates/local_vector.h"
#include "servers/rendering/rendering_device.h"

class IESManager {
public:
	// Maximum number of unique IES profiles supported simultaneously.
	// Matches Blender Cycles behaviour (no hard cap, but 256 covers all real-world cases).
	static constexpr int IES_MAX_SLOTS = 256;

	IESManager() {}
	~IESManager() { clear(); }

	// Add an IES profile from raw text content.
	// If identical content already exists (by hash), returns the existing slot and increments its refcount.
	// Returns -1 on parse failure or if the slot table is full.
	int add_ies(const String &p_content);

	// Convenience: read a .ies file from disk and call add_ies().
	// Returns -1 if the file cannot be read or fails to parse.
	int add_ies_from_file(const String &p_filepath);

	// Decrement the reference count for the given slot.
	// When the count reaches 0, the slot is freed and needs_update is set.
	void remove_ies(int p_slot);

	// Upload all valid slots to GPU.
	// Creates or resizes r_ies_buffer as needed using p_rd.
	// r_ies_buffer_bytes tracks the current allocation size (caller owns).
	// Clears needs_update on success.
	void device_update(RenderingDevice *p_rd, RID &r_ies_buffer, uint32_t &r_ies_buffer_bytes);

	// Returns true if any add/remove has occurred since the last device_update().
	bool is_dirty() const { return needs_update; }

	// Free all slots and release the GPU buffer.
	void clear();

private:
	struct IESSlot {
		IESFile ies; // Parsed profile data.
		uint32_t hash = 0; // Hash of the raw content string. 0 = empty slot.
		int users = 0; // Reference count.
	};

	LocalVector<IESSlot> slots;
	Mutex mutex;
	bool needs_update = false;

	// Find an empty slot (users==0, hash==0) or append a new one.
	// Must be called with the mutex held. Returns -1 if IES_MAX_SLOTS is reached.
	int _find_or_create_empty_slot();
};
