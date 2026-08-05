/**************************************************************************/
/*  ies_file.cpp                                                          */
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

// IES photometric file parser.
// Based on Blender Cycles intern/cycles/util/ies.cpp (Blender main branch, 2026-08-01).
//
// Key algorithmic decisions (matching Cycles exactly):
//   - Candela → Watts: multiply by 4π / 177.83 = 0.0706650768394
//     (177.83 is the luminous efficacy of the D65 standard illuminant in lm/W;
//      4π converts from cd=W/sr to total watts over the sphere)
//   - All photometric types are normalized to Type C spherical coords in radians.
//   - Half-profiles (0-90° or 0-180° horizontal symmetry) are expanded to 0-360°.

#include "ies_file.h"

#include "core/math/math_funcs.h"
#include "core/string/ustring.h"

// ---------------------------------------------------------------------------
// Tokenizer helpers
// ---------------------------------------------------------------------------

// Simple line-based tokenizer for IES files.
// IES files use both \n and \r\n line endings and space/tab separators.
struct IESTokenizer {
	Vector<String> lines;
	int line_idx = 0;
	Vector<String> cur_tokens;
	int tok_idx = 0;

	void init(const String &p_content) {
		lines = p_content.split("\n");
		line_idx = 0;
		tok_idx = 0;
		cur_tokens.clear();
	}

	// Advance to the next token (across lines as needed). Returns false when exhausted.
	bool next_token(String &r_token) {
		while (true) {
			while (tok_idx < cur_tokens.size()) {
				String t = cur_tokens[tok_idx++].strip_edges();
				if (!t.is_empty()) {
					r_token = t;
					return true;
				}
			}
			if (line_idx >= lines.size()) {
				return false;
			}
			String line = lines[line_idx++].strip_edges().replace("\r", "");
			cur_tokens = line.split(" ");
			tok_idx = 0;
			// Also split on tabs
			Vector<String> merged;
			for (const String &s : cur_tokens) {
				Vector<String> sub = s.split("\t");
				for (const String &ss : sub) {
					if (!ss.is_empty()) {
						merged.push_back(ss);
					}
				}
			}
			cur_tokens = merged;
		}
	}

	bool next_float(float &r_val) {
		String t;
		if (!next_token(t)) {
			return false;
		}
		r_val = t.to_float();
		return true;
	}

	bool next_int(int &r_val) {
		String t;
		if (!next_token(t)) {
			return false;
		}
		r_val = t.to_int();
		return true;
	}

	// Returns the current full line (for keyword scanning).
	String current_raw_line() const {
		if (line_idx <= 0 || line_idx > lines.size()) {
			return String();
		}
		return lines[line_idx - 1];
	}

	// Scan forward until a line starting with p_keyword is found.
	// Returns true and positions the tokenizer just after that line on success.
	bool seek_line_starting_with(const String &p_keyword) {
		// Reset token state so we restart from line boundaries.
		cur_tokens.clear();
		tok_idx = 0;
		for (int i = line_idx; i < lines.size(); i++) {
			String stripped = lines[i].strip_edges();
			if (stripped.begins_with(p_keyword)) {
				line_idx = i + 1;
				return true;
			}
		}
		return false;
	}
};

// ---------------------------------------------------------------------------
// IESFile::load
// ---------------------------------------------------------------------------

bool IESFile::load(const String &p_content) {
	clear();
	if (!parse(p_content)) {
		clear();
		return false;
	}
	process();
	return is_valid();
}

// ---------------------------------------------------------------------------
// IESFile::parse
// ---------------------------------------------------------------------------

bool IESFile::parse(const String &p_content) {
	IESTokenizer tok;
	tok.init(p_content);

	// --- 1. Find the TILT= marker (mandatory in all IESNA formats) ---
	bool found_tilt = tok.seek_line_starting_with("TILT=");
	if (!found_tilt) {
		// Try without strict line-start (some exporters put TILT= inline).
		tok.init(p_content);
		String t;
		bool ok = false;
		while (tok.next_token(t)) {
			if (t.begins_with("TILT=")) {
				ok = true;
				// The tilt mode is the part after '='.
				String tilt_mode = t.substr(5);
				if (tilt_mode == "INCLUDE") {
					// Skip: lamp-to-luminaire geometry angle count, angles, factors.
					int angle_count = 0;
					if (!tok.next_int(angle_count)) {
						return false;
					}
					// Skip 1 (tilt geometry type) + angle_count angles + angle_count factors.
					for (int i = 0; i < 1 + angle_count * 2; i++) {
						float dummy;
						tok.next_float(dummy);
					}
				}
				// TILT=NONE or TILT=INCLUDE (already handled) — continue to header.
				break;
			}
		}
		if (!ok) {
			return false;
		}
	} else {
		// Tokenizer is positioned after the TILT= line.
		// The entire TILT= line was already skipped by seek_line_starting_with.
		// Check what came after TILT= on that same line.
		// We use a secondary scan of the line we just passed.
		// Since seek_line_starting_with consumed the line, re-read it from the lines array.
		String tilt_line = (tok.line_idx > 0 && tok.line_idx <= tok.lines.size())
				? tok.lines[tok.line_idx - 1].strip_edges()
				: String();
		String tilt_mode = tilt_line.substr(5); // After "TILT="
		tilt_mode = tilt_mode.strip_edges();

		if (tilt_mode == "INCLUDE") {
			// Skip tilt data: geometry-type int, angle_count ints+floats.
			int angle_count = 0;
			if (!tok.next_int(angle_count)) {
				return false;
			}
			for (int i = 0; i < 1 + angle_count * 2; i++) {
				float dummy;
				tok.next_float(dummy);
			}
		}
	}

	// --- 2. Read the lamp descriptor line ---
	// Format: num_lamps  lumens_per_lamp  candela_multiplier
	//         v_angles_count  h_angles_count  photometric_type
	//         geometry_units  width  length  height

	int num_lamps = 0;
	float lumens_per_lamp = 0.0f;
	float candela_multiplier = 0.0f;
	int v_angles_count = 0;
	int h_angles_count = 0;
	int phot_type_int = 0;
	int geometry_units = 0;
	float width_m = 0.0f, length_m = 0.0f, height_m = 0.0f;

	if (!tok.next_int(num_lamps)) {
		return false;
	}
	if (!tok.next_float(lumens_per_lamp)) {
		return false;
	}
	if (!tok.next_float(candela_multiplier)) {
		return false;
	}
	if (!tok.next_int(v_angles_count)) {
		return false;
	}
	if (!tok.next_int(h_angles_count)) {
		return false;
	}
	if (!tok.next_int(phot_type_int)) {
		return false;
	}
	if (!tok.next_int(geometry_units)) {
		return false;
	}
	if (!tok.next_float(width_m)) {
		return false;
	}
	if (!tok.next_float(length_m)) {
		return false;
	}
	if (!tok.next_float(height_m)) {
		return false;
	}

	// Validate angle counts.
	if (v_angles_count <= 0 || h_angles_count <= 0) {
		return false;
	}

	// Set photometric type (default to C if unrecognized).
	switch (phot_type_int) {
		case 1:
			photometric_type = TYPE_C;
			break;
		case 2:
			photometric_type = TYPE_B;
			break;
		case 3:
			photometric_type = TYPE_A;
			break;
		default:
			photometric_type = TYPE_C;
			break;
	}

	// --- 3. Compute scaling factor ---
	// candela_multiplier scales all intensity values.
	// ballast_factor and ballast_lamp_factor may follow in the next "line".
	float ballast_factor = 0.0f;
	float ballast_lamp_factor = 0.0f;
	float input_watts = 0.0f;

	if (!tok.next_float(ballast_factor)) {
		return false;
	}
	if (!tok.next_float(ballast_lamp_factor)) {
		return false;
	}
	if (!tok.next_float(input_watts)) {
		return false;
	}

	// Combined scaling factor:
	float factor = candela_multiplier * ballast_factor * ballast_lamp_factor;

	// Candela → Watts conversion:
	// 4π / 177.83 ≈ 0.0706650768394
	// 177.83 lm/W is the luminous efficacy of the D65 standard illuminant.
	// 4π converts from W/sr to total watts (what our path tracer expects).
	factor *= 0.0706650768394f;

	// --- 4. Read vertical angles ---
	v_angles.resize(v_angles_count);
	for (int i = 0; i < v_angles_count; i++) {
		float a;
		if (!tok.next_float(a)) {
			return false;
		}
		v_angles.write[i] = a; // Stored in degrees; converted to radians in process().
	}

	// --- 5. Read horizontal angles ---
	h_angles.resize(h_angles_count);
	for (int i = 0; i < h_angles_count; i++) {
		float a;
		if (!tok.next_float(a)) {
			return false;
		}
		h_angles.write[i] = a;
	}

	// --- 6. Read intensity grid (h_angles_count × v_angles_count) ---
	intensity.resize(h_angles_count);
	for (int h = 0; h < h_angles_count; h++) {
		intensity.write[h].resize(v_angles_count);
		for (int v = 0; v < v_angles_count; v++) {
			float val;
			if (!tok.next_float(val)) {
				return false;
			}
			intensity.write[h].write[v] = val * factor;
		}
	}

	return true;
}

// ---------------------------------------------------------------------------
// IESFile::process  — Type normalization + degree→radian conversion
// ---------------------------------------------------------------------------

void IESFile::process() {
	switch (photometric_type) {
		case TYPE_A:
			process_type_a();
			break;
		case TYPE_B:
			process_type_b();
			break;
		case TYPE_C:
		default:
			process_type_c();
			break;
	}

	// Convert all angles from degrees to radians.
	for (int i = 0; i < v_angles.size(); i++) {
		v_angles.write[i] = Math::deg_to_rad(v_angles[i]);
	}
	for (int i = 0; i < h_angles.size(); i++) {
		h_angles.write[i] = Math::deg_to_rad(h_angles[i]);
	}
}

// ---------------------------------------------------------------------------
// Type C processing
// IES Type C: vertical 0°=nadir (straight down), 90°=horizontal, 180°=zenith.
// Horizontal 0°..360°; common symmetry subsets: 0°, 0-90°, 0-180°, 0-360°.
// ---------------------------------------------------------------------------
void IESFile::process_type_c() {
	if (h_angles.is_empty() || v_angles.is_empty()) {
		return;
	}

	// Some files are tabulated from 90° to 270° instead of 0° to 180°; shift them
	// back so every symmetry case below sees a profile starting at 0°.
	if (Math::is_equal_approx(h_angles[0], 90.0f)) {
		for (int h = 0; h < h_angles.size(); h++) {
			h_angles.write[h] -= 90.0f;
		}
	}

	// Rotationally symmetric profile (a single horizontal angle, the common case
	// for downlights and COB spots). The GPU lookup interpolates between
	// horizontal samples and rejects any direction outside
	// [h_angles[0], h_angles[last]] — with a lone sample that range is degenerate
	// and every direction is rejected, making the light contribute nothing.
	// Duplicate the row across a full 0-360° span, as Cycles does.
	if (h_angles.size() == 1) {
		Vector<float> row = intensity[0]; // Copy first: push_back may reallocate.
		h_angles.write[0] = 0.0f;
		h_angles.push_back(360.0f);
		intensity.push_back(row);
	}

	// Expand horizontal symmetry to full 0-360° if needed.
	float h_last = h_angles[h_angles.size() - 1];

	if (Math::is_equal_approx(h_last, 90.0f)) {
		// Quarter-sphere: mirror to 180°, then mirror again to 360°.
		int orig_h = h_angles.size();
		// Add 91-180° mirror.
		for (int h = orig_h - 2; h >= 0; h--) {
			Vector<float> row = intensity[h];
			h_angles.push_back(180.0f - h_angles[h]);
			intensity.push_back(row);
		}
		// Now we have 0-180°. Mirror to 360°.
		int half_h = h_angles.size();
		for (int h = half_h - 2; h >= 0; h--) {
			Vector<float> row = intensity[h];
			h_angles.push_back(360.0f - h_angles[h]);
			intensity.push_back(row);
		}
	} else if (Math::is_equal_approx(h_last, 180.0f)) {
		// Half-sphere: mirror to get 181-360°.
		int orig_h = h_angles.size();
		for (int h = orig_h - 2; h >= 0; h--) {
			Vector<float> row = intensity[h];
			h_angles.push_back(360.0f - h_angles[h]);
			intensity.push_back(row);
		}
	}
	// If already 0-360°: nothing to do.

	// Ensure angles are truly 0..360 (some files write 360 as 0+360).
	// Sort is not needed; IESNA requires angles in ascending order.
}

// ---------------------------------------------------------------------------
// Type B processing
// Type B: polar axis is horizontal (fixture tilted 90°).
// Vertical angles correspond to tilt from the horizontal axis,
// horizontal angles rotate around it.
// Normalize to Type C by swapping/mirroring axes.
// ---------------------------------------------------------------------------
void IESFile::process_type_b() {
	// Mirror vertical angles around 0 if needed (Type B verticals can be −90..+90).
	// Shift all vertical angles by +90 so they become 0..180 (Type C range).
	for (int i = 0; i < v_angles.size(); i++) {
		v_angles.write[i] += 90.0f;
	}

	// Horizontal symmetry expansion (same as Type C).
	process_type_c();
}

// ---------------------------------------------------------------------------
// Type A processing (automotive)
// Type A: horizontal is road direction, vertical rotates around it.
// Shift vertical angles by +90, invert horizontal.
// ---------------------------------------------------------------------------
void IESFile::process_type_a() {
	// Offset vertical angles by +90°.
	for (int i = 0; i < v_angles.size(); i++) {
		v_angles.write[i] += 90.0f;
	}

	// Invert horizontal angles (Type A uses opposite sign convention).
	for (int i = 0; i < h_angles.size(); i++) {
		h_angles.write[i] = -h_angles[i];
	}

	// Mirror if needed.
	process_type_c();
}

// ---------------------------------------------------------------------------
// IESFile::packed_size
// ---------------------------------------------------------------------------

int IESFile::packed_size() const {
	if (!is_valid()) {
		return 0;
	}
	int h_num = h_angles.size();
	int v_num = v_angles.size();
	return 2 + h_num + v_num + h_num * v_num;
}

// ---------------------------------------------------------------------------
// IESFile::pack
// ---------------------------------------------------------------------------

void IESFile::pack(float *p_data) const {
	ERR_FAIL_COND(!is_valid());
	ERR_FAIL_NULL(p_data);

	int h_num = h_angles.size();
	int v_num = v_angles.size();
	int idx = 0;

	// Header: dimensions (stored as int bit-pattern in float).
	p_data[idx++] = *(const float *)&h_num; // intBitsToFloat(h_num)
	p_data[idx++] = *(const float *)&v_num;

	// Horizontal angles.
	for (int h = 0; h < h_num; h++) {
		p_data[idx++] = h_angles[h];
	}

	// Vertical angles.
	for (int v = 0; v < v_num; v++) {
		p_data[idx++] = v_angles[v];
	}

	// Intensity grid: row-major [h][v].
	for (int h = 0; h < h_num; h++) {
		const Vector<float> &row = intensity[h];
		for (int v = 0; v < v_num; v++) {
			p_data[idx++] = (v < row.size()) ? row[v] : 0.0f;
		}
	}
}

// ---------------------------------------------------------------------------
// IESFile::clear
// ---------------------------------------------------------------------------

void IESFile::clear() {
	v_angles.clear();
	h_angles.clear();
	intensity.clear();
	photometric_type = TYPE_C;
}
