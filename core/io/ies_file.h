/**************************************************************************/
/*  ies_file.h                                                            */
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

// IES (Illuminating Engineering Society) photometric file parser.
// Parses IESNA LM-63 format files (all photometric Types A, B, C),
// normalizes them to Type C spherical coordinates (matching Blender Cycles),
// and packs the result into a flat float array for GPU upload.
//
// Reference: Blender Cycles intern/cycles/util/ies.h/.cpp

#include "core/string/ustring.h"
#include "core/templates/vector.h"

class IESFile {
public:
	// Photometric type as defined in the IESNA LM-63 standard.
	enum PhotometricType {
		TYPE_C = 1, // Most common; horizontal=azimuth, vertical=elevation from nadir.
		TYPE_B = 2, // Polar axis horizontal; used for some European fixtures.
		TYPE_A = 3, // Automotive road-lighting type.
	};

	// Load from raw IES text content string.
	// Returns true on success. On failure, the object is left in an empty state.
	bool load(const String &p_content);

	// Returns true if the file has been successfully parsed and is ready to pack.
	bool is_valid() const { return !v_angles.is_empty() && !h_angles.is_empty(); }

	// Returns the total number of floats that pack() will write.
	// Layout: [h_num][v_num][h_angles...][v_angles...][intensity[h0][v0..vN-1]...]
	int packed_size() const;

	// Write packed data into p_data (caller must allocate packed_size() floats).
	void pack(float *p_data) const;

	// Clear all parsed data; resets to empty state.
	void clear();

private:
	// Parsed angle grids (stored in radians after process()).
	Vector<float> v_angles; // Vertical angles, 0..π (nadir to zenith).
	Vector<float> h_angles; // Horizontal angles, 0..2π.

	// Intensity grid: intensity[h_index][v_index], in watts/sr.
	// After processing, spans the full sphere (or uses symmetry flags).
	Vector<Vector<float>> intensity;

	// Photometric type extracted from the file.
	PhotometricType photometric_type = TYPE_C;

	// --- Internal parsing helpers ---

	// Parse raw IES text. Fills v_angles, h_angles, intensity in degrees.
	// Returns false on malformed input.
	bool parse(const String &p_content);

	// Normalize to full Type-C spherical representation in radians.
	// Called after parse() on success.
	void process();

	void process_type_a();
	void process_type_b();
	void process_type_c();
};
