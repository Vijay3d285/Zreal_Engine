// Path guiding for diffuse bounces (roadmap Gap #32, spec
// docs/superpowers/specs/2026-09-22-path-guiding-design.md).
//
// A world-space hash grid of directional histograms. Cell key = (voxel,
// dominant signed normal axis); bins = 8 x 8 in (cos theta, phi) about world
// +Y, exactly equal-area (4 pi / 64 sr each), so the pdf of a direction is
// its bin's weight over the cell's hemisphere total, per steradian.
//
// Two SSBOs: guide_train is written by the raygen (fixed-point atomics, so
// the sum is order-independent and the render repeatable); guide_read is a
// per-frame snapshot the closest-hit samples from, so the density that is
// sampled and the density that is reported through combinedPdf are one frozen
// table. Every function here is pure over those two buffers and the UBO.
//
// CPU twin: tests/servers/rendering/test_pt_guiding.cpp. Keep them literal.
#ifndef RT_GUIDING_INC
#define RT_GUIDING_INC

#define GUIDE_CELLS 262144u
#define GUIDE_BINS 64u
#define GUIDE_STRIDE 65u // 64 bins + the sample count
#define GUIDE_MIN_COUNT 32u
#define GUIDE_FIXED 1024.0
#define GUIDE_MAX_INV_PDF 64.0
// Task 4: the number of diffuse vertices recorded per path for deferred
// training (raygen arrays like `vec3 guide_pos[GUIDE_RECORD]`, bounded by
// `guide_n < GUIDE_RECORD`). This is an ARRAY SIZE, not a bitmask -- it is
// unrelated to the guide_record PathState flag, whose bit value in
// sss_restart.w is 2 (see raytracing_inc.glsl's path_pack/path_unpack).
// Dead in this commit (Task 2: pure functions only, nothing records yet);
// the raygen training loop that consumes it lands in Task 4.
#define GUIDE_RECORD 4
const float GUIDE_BIN_SOLID_ANGLE = 4.0 * PI / 64.0;

layout(set = 0, binding = 42, std430) buffer GuideTrainRW {
	uint guide_train[];
};
layout(set = 0, binding = 43, std430) readonly buffer GuideReadRO {
	uint guide_read[];
};

struct GuideState {
	bool is_active;
	float alpha;
	uint cell;
	float total; // cosine-weighted hemisphere total for Nd, raw fixed units
	vec3 Nd;
};

// Per-invocation vertex state. Inert unless shade_and_bounce looks a cell up;
// combinedPdf's diffuse term reads it so every MIS site sees one density.
GuideState g_guide = GuideState(false, 0.0, 0u, 0.0, vec3(0.0, 1.0, 0.0));

float guide_prob() {
	return get_rt_param(RT_PARAM_GUIDE_PROB);
}

bool guide_enabled() {
	return guide_prob() > 0.0 && get_rt_param(RT_PARAM_GUIDE_CELL) > 0.0;
}

uint guide_nkey(vec3 n) {
	vec3 a = abs(n);
	uint axis = (a.x >= a.y && a.x >= a.z) ? 0u : ((a.y >= a.z) ? 1u : 2u);
	return axis * 2u + ((n[axis] < 0.0) ? 1u : 0u);
}

uint guide_cell_of(vec3 p, vec3 n) {
	float cell = get_rt_param(RT_PARAM_GUIDE_CELL);
	vec3 o = vec3(get_rt_param(RT_PARAM_GUIDE_ORIGIN_X), get_rt_param(RT_PARAM_GUIDE_ORIGIN_X + 1), get_rt_param(RT_PARAM_GUIDE_ORIGIN_X + 2));
	ivec3 v = ivec3(floor((p - o) / cell));
	uint h = uint(v.x) * 0x8DA6B343u ^ uint(v.y) * 0xD8163841u ^ uint(v.z) * 0xCB1AB31Fu ^ guide_nkey(n) * 0x9E3779B9u;
	h ^= h >> 16;
	h *= 0x7FEB352Du;
	h ^= h >> 15;
	h *= 0x846CA68Bu;
	h ^= h >> 16;
	return h & (GUIDE_CELLS - 1u);
}

uint guide_bin_of_dir(vec3 d) {
	float ct = clamp(d.y, -1.0, 1.0);
	uint row = min(uint((ct + 1.0) * 0.5 * 8.0), 7u);
	float phi = atan(d.z, d.x);
	// atan's range is (-PI, PI], so (phi + PI) is mathematically >= 0, but a
	// float32 ULP mismatch between this PI and the hardware atan's internal
	// pi can make phi land a hair below -PI. uint() of a negative value is
	// undefined in GLSL (col could wrap to a huge number that min() then
	// clamps to 7, silently misbinning a direction into the wrong column) --
	// clamp to >= 0 before the cast instead of relying on that UB. Mirrors
	// the same clamp added to bin_of_dir() in the CPU twin.
	uint col = min(uint(max((phi + PI) / (2.0 * PI) * 8.0, 0.0)), 7u);
	return row * 8u + col;
}

vec3 guide_dir_of_bin(uint bin, vec2 u) {
	uint row = bin / 8u;
	uint col = bin % 8u;
	float ct = -1.0 + (float(row) + u.x) * 0.25;
	float phi = -PI + (float(col) + u.y) * (2.0 * PI / 8.0);
	float st = sqrt(max(1.0 - ct * ct, 0.0));
	return vec3(st * cos(phi), ct, st * sin(phi));
}

vec3 guide_bin_center(uint bin) {
	return guide_dir_of_bin(bin, vec2(0.5));
}

float guide_bin_weight(uint cell, uint bin, vec3 Nd) {
	return float(guide_read[cell * GUIDE_STRIDE + bin]) * max(dot(guide_bin_center(bin), Nd), 0.0);
}

GuideState guide_lookup(vec3 p, vec3 n, vec3 Nd) {
	GuideState g = GuideState(false, 0.0, 0u, 0.0, Nd);
	if (!guide_enabled()) {
		return g;
	}
	g.cell = guide_cell_of(p, n);
	if (guide_read[g.cell * GUIDE_STRIDE + GUIDE_BINS] < GUIDE_MIN_COUNT) {
		return g;
	}
	float total = 0.0;
	for (uint b = 0u; b < GUIDE_BINS; b++) {
		total += guide_bin_weight(g.cell, b, Nd);
	}
	if (total <= 0.0) {
		return g;
	}
	g.total = total;
	g.alpha = guide_prob();
	g.is_active = true;
	return g;
}

float guide_pdf(GuideState g, vec3 L) {
	if (!g.is_active) {
		return 0.0;
	}
	return guide_bin_weight(g.cell, guide_bin_of_dir(L), g.Nd) / (g.total * GUIDE_BIN_SOLID_ANGLE);
}

// combinedPdf's diffuse density. Identical to diffusePdf(NdotLd) when the
// vertex is not guided; the mixture when it is. max(NdotLd, 0.0) is
// load-bearing: this is evaluated by MIS for an arbitrary sampled direction
// (e.g. a light sample), which can be below the shading horizon. Fix round 1,
// finding 1: this used to be a bare `NdotLd / PI` with no clamp, so a
// below-horizon L produced a NEGATIVE density reaching combinedPdf/MIS --
// unlike the CPU twin's mix_pdf(), which already clamped. Both now match.
float guide_diffuse_pdf(float NdotLd, vec3 L) {
	// Task 4: the MULTIPLY by the folded constant, not a divide, is load-bearing.
	// combinedPdf's diffuse term now routes through this function at EVERY
	// vertex, and brdf_inc.glsl's diffusePdf() -- the expression it replaces --
	// is `NdotL * ONE_OVER_PI` with ONE_OVER_PI == (1.0f / PI) folded at compile
	// time. `NdotLd / PI` is a different operation that differs from it by up to
	// 1 ULP, which would shift mis_ray_pdf, env NEE and emissive NEE on EVERY
	// existing render and break the guiding-off inertness guarantee (gate G4,
	// and with it all 23 of the repo's other rendered gates). Written as
	// `(1.0 / PI)` rather than ONE_OVER_PI so this file stays independent of
	// brdf_inc.glsl's macros; the two constant expressions fold identically.
	// The CPU twin's mix_pdf() carries the same multiply.
	float p_cos = max(NdotLd, 0.0) * (1.0 / PI);
	if (!g_guide.is_active) {
		return p_cos;
	}
	return (1.0 - g_guide.alpha) * p_cos + g_guide.alpha * guide_pdf(g_guide, L);
}

bool guide_sample(GuideState g, vec2 u, out vec3 L) {
	L = vec3(0.0);
	if (!g.is_active) {
		return false;
	}
	float target = u.x * g.total;
	float cdf = 0.0;
	for (uint b = 0u; b < GUIDE_BINS; b++) {
		float w = guide_bin_weight(g.cell, b, g.Nd);
		if (w <= 0.0) {
			continue;
		}
		if (target < cdf + w || b == GUIDE_BINS - 1u) {
			float residual = clamp((target - cdf) / w, 0.0, 0.999999);
			L = guide_dir_of_bin(b, vec2(residual, u.y));
			return true;
		}
		cdf += w;
	}
	return false;
}

// Fix round 1, finding 4: a saturating atomic add. The original guard read
// `cur = guide_train[idx]` then conditionally called atomicAdd() -- two
// separate, non-atomic steps. Under contention (many raygen invocations
// hitting the same cell/bin in the same frame, which is the expected case
// near convergence), another invocation's add can land between the read and
// the atomicAdd, so the add proceeds anyway and wraps -- silently corrupting
// that bin's trained weight and contradicting this function's own "order-
// independent" invariant. atomicCompSwap retries against the CURRENT value
// on every failed attempt, so the overflow check and the add are one atomic
// unit: either it applies cleanly or it correctly declines because some
// OTHER thread's now-visible add already pushed the total close enough to
// overflow.
void guide_atomic_saturating_add(uint idx, uint add) {
	uint old_val = guide_train[idx];
	for (;;) {
		if (old_val > 0xFFFFFFFFu - add) {
			return; // Would overflow; the cell has learnt what it needs.
		}
		uint prev = atomicCompSwap(guide_train[idx], old_val, old_val + add);
		if (prev == old_val) {
			return; // Swap succeeded.
		}
		old_val = prev; // Another invocation won the race; retry against its value.
	}
}

// Training: value is luminance(L_in) / pdf, already clamped by the caller.
// Saturating: an add that would wrap is skipped (the cell has learnt what it
// needs); integer atomics keep the table order-independent.
void guide_train_vertex(vec3 p, vec3 n, vec3 dir, float value) {
	if (!(value > 0.0)) {
		return;
	}
	uint cell = guide_cell_of(p, n);
	uint idx = cell * GUIDE_STRIDE + guide_bin_of_dir(dir);
	uint add = uint(min(value * GUIDE_FIXED, 4.0e9));
	guide_atomic_saturating_add(idx, add);
	atomicAdd(guide_train[cell * GUIDE_STRIDE + GUIDE_BINS], 1u);
}

#endif // RT_GUIDING_INC
