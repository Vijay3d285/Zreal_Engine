// ies_lookup_inc.glsl
// Bicubic IES photometric profile lookup in spherical coordinates.
//
// Mirrors Blender Cycles kernel/util/ies.h (kernel_ies_interp).
//
// Directions are supplied in the LIGHT'S LOCAL frame, where the fixture aims
// along -Z. That is Godot's light convention (SpotLight3D's cone points down
// local -Z) and also Blender's, so the angle formulas match Cycles verbatim and
// no Y-up/Z-up fixup is needed here — the caller's world->local rotation handles
// it (see lights_world_to_light_local in raytracing_lights_inc.glsl).
//
//   Vertical angle  : acos(-dir.z)       [0 = along the aim axis (IES nadir), π = behind]
//   Horizontal angle: atan(dir.y, dir.x) + π  [0..2π]
//
// Requires:
//   layout(set=0, binding=IES_BUFFER_BINDING, std430) readonly buffer IESBuffer { float ies_data[]; };
//
// IES buffer layout (set by IESManager::device_update):
//   [0..N-1]   : offset table — floatBitsToInt(ies_data[slot]) = int byte-offset into buffer,
//                or -1 if the slot is invalid.
//   [N..]      : packed profile data for each valid slot.
//
// Packed profile layout per slot (produced by IESFile::pack):
//   [floatBitsToInt(ies_data[ofs+0])] = h_num
//   [floatBitsToInt(ies_data[ofs+1])] = v_num
//   [ies_data[ofs+2 .. ofs+2+h_num-1]]              = h_angles (radians, ascending)
//   [ies_data[ofs+2+h_num .. ofs+2+h_num+v_num-1]]  = v_angles (radians, ascending)
//   [ies_data[ofs+2+h_num+v_num ..]]                 = intensity[h][v] row-major

#ifndef IES_BUFFER_BINDING
#define IES_BUFFER_BINDING 31
#endif

layout(set = 0, binding = IES_BUFFER_BINDING, std430) readonly buffer IESBuffer {
	float ies_data[];
};

// ---------------------------------------------------------------------------
// Cubic interpolation kernel (Catmull-Rom flavour, matching Cycles).
// ---------------------------------------------------------------------------
float ies_cubic_interp(float t, float f0, float f1, float f2, float f3) {
	float a = -0.5 * f0 + 1.5 * f1 - 1.5 * f2 + 0.5 * f3;
	float b = f0 - 2.5 * f1 + 2.0 * f2 - 0.5 * f3;
	float c = -0.5 * f0 + 0.5 * f2;
	float d = f1;
	return ((a * t + b) * t + c) * t + d;
}

// ---------------------------------------------------------------------------
// Read intensity from the packed grid with clamped boundary.
// h_idx and v_idx may be out of range; we clamp them.
// ---------------------------------------------------------------------------
float ies_read_intensity(int ofs, int h_num, int v_num, int h_idx, int v_idx) {
	h_idx = clamp(h_idx, 0, h_num - 1);
	v_idx = clamp(v_idx, 0, v_num - 1);
	int data_start = ofs + 2 + h_num + v_num;
	return ies_data[data_start + h_idx * v_num + v_idx];
}

// ---------------------------------------------------------------------------
// Lookup a single row (4 vertical samples) with cubic interpolation.
// ---------------------------------------------------------------------------
float ies_interp_vertical(int ofs, int h_num, int v_num, int h_idx, float v_frac, int v_lo) {
	float f0 = ies_read_intensity(ofs, h_num, v_num, h_idx, v_lo - 1);
	float f1 = ies_read_intensity(ofs, h_num, v_num, h_idx, v_lo);
	float f2 = ies_read_intensity(ofs, h_num, v_num, h_idx, v_lo + 1);
	float f3 = ies_read_intensity(ofs, h_num, v_num, h_idx, v_lo + 2);
	return ies_cubic_interp(v_frac, f0, f1, f2, f3);
}

// ---------------------------------------------------------------------------
// ies_lookup — main entry point.
//
// p_slot   : slot index (-1 = no profile → returns 1.0 for isotropic fallback).
// p_dir    : direction FROM the light TO the shaded point, in the LIGHT'S LOCAL
//            frame (unnormalized is fine). Callers rotate the world-space
//            direction with lights_world_to_light_local().
// Returns  : intensity multiplier ≥ 0.
// ---------------------------------------------------------------------------
float ies_lookup(int p_slot, vec3 p_dir) {
	// No profile: isotropic (multiplier = 1.0).
	if (p_slot < 0) {
		return 1.0;
	}

	// Read the offset table entry for this slot.
	int ofs = floatBitsToInt(ies_data[p_slot]);
	if (ofs < 0) {
		// Invalid / empty slot — treat as isotropic.
		return 1.0;
	}

	// Read grid dimensions.
	int h_num = floatBitsToInt(ies_data[ofs]);
	int v_num = floatBitsToInt(ies_data[ofs + 1]);
	if (h_num <= 0 || v_num <= 0) {
		return 1.0;
	}

	// Compute spherical angles in the light's local frame (aim axis = -Z).
	vec3 d = normalize(p_dir);
	float v_angle = acos(clamp(-d.z, -1.0, 1.0));      // 0 = along the aim axis (IES nadir), π = behind.
	float h_angle = atan(d.y, d.x) + PI;                // 0..2π.

	// --- Vertical range check ---
	float v_min = ies_data[ofs + 2 + h_num];
	float v_max = ies_data[ofs + 2 + h_num + v_num - 1];
	if (v_angle < v_min || v_angle > v_max) {
		return 0.0;
	}

	// --- Horizontal range check / wraparound ---
	// A profile with a single horizontal sample is rotationally symmetric. Its
	// [h_min, h_max] range is degenerate, so the range test below would reject
	// every direction and the light would contribute nothing. IESFile::process()
	// expands such profiles to a full 0-360° span, but guard here as well so a
	// malformed profile dims the light rather than extinguishing it.
	bool h_symmetric = (h_num == 1);

	float h_min = ies_data[ofs + 2];
	float h_max = ies_data[ofs + 2 + h_num - 1];
	bool h_wrap = h_symmetric || abs(h_max - h_min - 2.0 * PI) < 0.01; // Full 360° coverage.

	if (h_symmetric) {
		// Azimuth is irrelevant; no range test needed.
	} else if (h_wrap) {
		// Normalize h_angle into [h_min, h_min + 2π).
		while (h_angle < h_min) {
			h_angle += 2.0 * PI;
		}
		while (h_angle >= h_min + 2.0 * PI) {
			h_angle -= 2.0 * PI;
		}
	} else if (h_angle < h_min || h_angle > h_max) {
		return 0.0;
	}

	// --- Find surrounding vertical grid cell (linear scan) ---
	int v_lo = 0;
	for (int i = 0; i < v_num - 1; i++) {
		float va = ies_data[ofs + 2 + h_num + i];
		float vb = ies_data[ofs + 2 + h_num + i + 1];
		if (v_angle >= va && v_angle <= vb) {
			v_lo = i;
			break;
		}
	}
	float v_a = ies_data[ofs + 2 + h_num + v_lo];
	float v_b = ies_data[ofs + 2 + h_num + v_lo + 1];
	float v_frac = (v_b > v_a) ? (v_angle - v_a) / (v_b - v_a) : 0.0;

	// Rotationally symmetric: interpolate the single row vertically and stop.
	// Reading h_angles[1] below would run off the end of a one-entry table.
	if (h_symmetric) {
		return max(ies_interp_vertical(ofs, h_num, v_num, 0, v_frac, v_lo), 0.0);
	}

	// --- Find surrounding horizontal grid cell ---
	int h_lo = 0;
	for (int i = 0; i < h_num - 1; i++) {
		float ha = ies_data[ofs + 2 + i];
		float hb = ies_data[ofs + 2 + i + 1];
		if (h_angle >= ha && h_angle <= hb) {
			h_lo = i;
			break;
		}
	}
	float h_a = ies_data[ofs + 2 + h_lo];
	float h_b = ies_data[ofs + 2 + h_lo + 1];
	float h_frac = (h_b > h_a) ? (h_angle - h_a) / (h_b - h_a) : 0.0;

	// --- Bicubic interpolation ---
	// First interpolate vertically at 4 horizontal positions.
	int h_idx_m1 = h_wrap ? ((h_lo - 1 + h_num) % h_num) : clamp(h_lo - 1, 0, h_num - 1);
	int h_idx_0  = h_lo;
	int h_idx_p1 = h_wrap ? ((h_lo + 1) % h_num) : clamp(h_lo + 1, 0, h_num - 1);
	int h_idx_p2 = h_wrap ? ((h_lo + 2) % h_num) : clamp(h_lo + 2, 0, h_num - 1);

	float g0 = ies_interp_vertical(ofs, h_num, v_num, h_idx_m1, v_frac, v_lo);
	float g1 = ies_interp_vertical(ofs, h_num, v_num, h_idx_0,  v_frac, v_lo);
	float g2 = ies_interp_vertical(ofs, h_num, v_num, h_idx_p1, v_frac, v_lo);
	float g3 = ies_interp_vertical(ofs, h_num, v_num, h_idx_p2, v_frac, v_lo);

	float result = ies_cubic_interp(h_frac, g0, g1, g2, g3);

	// Clamp: cubic interpolation can produce small negative overshoots.
	return max(result, 0.0);
}
