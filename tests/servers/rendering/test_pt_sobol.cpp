/**************************************************************************/
/*  test_pt_sobol.cpp                                                     */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_sobol)

#include "core/math/math_funcs.h"

namespace TestPTSobol {

// CPU mirror of servers/rendering/renderer_rd/shaders/raytracing/sobol_burley_inc.glsl.
// These two implementations MUST stay identical — the shader cannot be unit tested
// directly, so this mirror is the only thing standing between a typo in the port and
// a silently wrong sampler. If you touch one, touch the other in the same commit.
//
// Source of truth: Blender Cycles
//   intern/cycles/kernel/sample/sobol_burley.h
//   intern/cycles/kernel/sample/util.h        (reversed_bit_owen)
//   intern/cycles/util/hash.h                 (hash_hp_uint, uint_to_float_excl)

// Direction vectors for the first four Sobol dimensions, bits pre-reversed.
// Verbatim from intern/cycles/kernel/tables.h:81.
static const uint32_t SOBOL_BURLEY_TABLE[4][32] = {
	{
			0x00000001, 0x00000002, 0x00000004, 0x00000008,
			0x00000010, 0x00000020, 0x00000040, 0x00000080,
			0x00000100, 0x00000200, 0x00000400, 0x00000800,
			0x00001000, 0x00002000, 0x00004000, 0x00008000,
			0x00010000, 0x00020000, 0x00040000, 0x00080000,
			0x00100000, 0x00200000, 0x00400000, 0x00800000,
			0x01000000, 0x02000000, 0x04000000, 0x08000000,
			0x10000000, 0x20000000, 0x40000000, 0x80000000,
	},
	{
			0x00000001, 0x00000003, 0x00000005, 0x0000000f,
			0x00000011, 0x00000033, 0x00000055, 0x000000ff,
			0x00000101, 0x00000303, 0x00000505, 0x00000f0f,
			0x00001111, 0x00003333, 0x00005555, 0x0000ffff,
			0x00010001, 0x00030003, 0x00050005, 0x000f000f,
			0x00110011, 0x00330033, 0x00550055, 0x00ff00ff,
			0x01010101, 0x03030303, 0x05050505, 0x0f0f0f0f,
			0x11111111, 0x33333333, 0x55555555, 0xffffffff,
	},
	{
			0x00000001, 0x00000003, 0x00000006, 0x00000009,
			0x00000017, 0x0000003a, 0x00000071, 0x000000a3,
			0x00000116, 0x00000339, 0x00000677, 0x000009aa,
			0x00001601, 0x00003903, 0x00007706, 0x0000aa09,
			0x00010117, 0x0003033a, 0x00060671, 0x000909a3,
			0x00171616, 0x003a3939, 0x00717777, 0x00a3aaaa,
			0x01170001, 0x033a0003, 0x06710006, 0x09a30009,
			0x16160017, 0x3939003a, 0x77770071, 0xaaaa00a3,
	},
	{
			0x00000001, 0x00000003, 0x00000004, 0x0000000a,
			0x0000001f, 0x0000002e, 0x00000045, 0x000000c9,
			0x0000011b, 0x000002a4, 0x0000079a, 0x00000b67,
			0x0000101e, 0x0000302d, 0x00004041, 0x0000a0c3,
			0x0001f104, 0x0002e28a, 0x000457df, 0x000c9bae,
			0x0011a105, 0x002a7289, 0x0079e7db, 0x00b6dba4,
			0x0100011a, 0x030002a7, 0x0400079e, 0x0a000b6d,
			0x1f001001, 0x2e003003, 0x45004004, 0xc900a00a,
	},
};

// GLSL bitfieldReverse().
static uint32_t sb_bit_reverse(uint32_t p_x) {
	p_x = ((p_x & 0x55555555u) << 1) | ((p_x >> 1) & 0x55555555u);
	p_x = ((p_x & 0x33333333u) << 2) | ((p_x >> 2) & 0x33333333u);
	p_x = ((p_x & 0x0f0f0f0fu) << 4) | ((p_x >> 4) & 0x0f0f0f0fu);
	p_x = ((p_x & 0x00ff00ffu) << 8) | ((p_x >> 8) & 0x00ff00ffu);
	return (p_x << 16) | (p_x >> 16);
}

// GLSL 31 - findMSB(). Undefined for 0, same as the shader; callers guard.
static uint32_t sb_clz(uint32_t p_x) {
	uint32_t n = 0;
	while ((p_x & 0x80000000u) == 0) {
		p_x <<= 1;
		n++;
	}
	return n;
}

// Cycles util/hash.h:511.
static uint32_t sb_hash_hp(uint32_t p_i) {
	p_i ^= p_i >> 16;
	p_i *= 0x21f0aaadu;
	p_i ^= p_i >> 15;
	p_i *= 0xd35a2d97u;
	p_i ^= p_i >> 15;
	return p_i ^ 0xe6fe3bebu;
}

// Cycles kernel/sample/util.h:18 (reversed_bit_owen).
static uint32_t sb_pcg_owen(uint32_t p_n, uint32_t p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n += p_seed;
	p_n *= (p_seed >> 16) | 1u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

// Cycles util/hash.h:14 (uint_to_float_excl). The divisor is 4294967808, not 2^32,
// so the result is strictly < 1.0 after float rounding.
static float sb_uint_to_float_excl(uint32_t p_n) {
	return (float)p_n * (1.0f / 4294967808.0f);
}

// Cycles kernel/sample/sobol_burley.h:37.
static float sb_sobol_burley(uint32_t p_rev_bit_index, uint32_t p_dimension, uint32_t p_scramble_seed) {
	uint32_t result = 0;
	if (p_dimension == 0) {
		result = sb_bit_reverse(p_rev_bit_index);
	} else {
		uint32_t i = 0;
		while (p_rev_bit_index != 0) {
			const uint32_t j = sb_clz(p_rev_bit_index);
			result ^= SOBOL_BURLEY_TABLE[p_dimension][i + j];
			i += j + 1;
			p_rev_bit_index <<= j;
			p_rev_bit_index <<= 1;
		}
	}
	result = sb_bit_reverse(sb_pcg_owen(result, p_scramble_seed));
	return sb_uint_to_float_excl(result);
}

static float sobol_burley_sample_1D(uint32_t p_index, uint32_t p_dimension, uint32_t p_seed, uint32_t p_mask) {
	p_seed ^= sb_hash_hp(p_dimension);
	p_index = sb_pcg_owen(sb_bit_reverse(p_index), p_seed ^ 0xbff95bfeu);
	p_index &= p_mask;
	return sb_sobol_burley(p_index, 0, p_seed ^ 0x635c77bdu);
}

static void sobol_burley_sample_2D(uint32_t p_index, uint32_t p_dimension_set, uint32_t p_seed, uint32_t p_mask, float &r_x, float &r_y) {
	p_seed ^= sb_hash_hp(p_dimension_set);
	p_index = sb_pcg_owen(sb_bit_reverse(p_index), p_seed ^ 0xf8ade99au);
	p_index &= p_mask;
	r_x = sb_sobol_burley(p_index, 0, p_seed ^ 0xe0aaaf76u);
	r_y = sb_sobol_burley(p_index, 1, p_seed ^ 0x94964d4eu);
}

// White-noise reference, the sampler we are replacing (raytracing_inc.glsl:159).
static uint32_t pcg_hash(uint32_t p_seed) {
	const uint32_t state = p_seed * 747796405u + 2891336453u;
	const uint32_t word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
	return (word >> 22) ^ word;
}

// Mask for a block of 2^p_log2_count samples, per Cycles integrator.cpp:320:
// reverse_integer_bits(next_power_of_two(n - 1) - 1).
static uint32_t block_mask(int p_log2_count) {
	return sb_bit_reverse((1u << p_log2_count) - 1u);
}

TEST_CASE("[PathTracer][Sobol] 1D samples stay in [0, 1)") {
	const uint32_t seed = 0x1234abcdu;
	for (uint32_t i = 0; i < 4096; i++) {
		const float v = sobol_burley_sample_1D(i, 3, seed, 0xffffffffu);
		CHECK(v >= 0.0f);
		CHECK(v < 1.0f);
	}
}

TEST_CASE("[PathTracer][Sobol] 2D samples stay in [0, 1)") {
	const uint32_t seed = 0x5f356495u;
	for (uint32_t i = 0; i < 4096; i++) {
		float x, y;
		sobol_burley_sample_2D(i, 1, seed, 0xffffffffu, x, y);
		CHECK(x >= 0.0f);
		CHECK(x < 1.0f);
		CHECK(y >= 0.0f);
		CHECK(y < 1.0f);
	}
}

// Shared body for the 1D stratification property, parameterized on the mask so it
// can be exercised both at the length-shortened mask Cycles derives from the sample
// count (block_mask) AND at 0xffffffffu -- the mask the shader (raytracing_inc.glsl
// rng_1d/rng_2d) actually always passes in production. `index &= mask` truncates
// which Sobol point is drawn, so the two masks are not redundant checks of the same
// thing; both must independently preserve the stratification property.
static void check_1d_stratification(uint32_t p_mask) {
	const int k = 6;
	const uint32_t n = 1u << k;

	for (uint32_t seed_i = 0; seed_i < 8; seed_i++) {
		const uint32_t seed = sb_hash_hp(seed_i);
		int hits[64] = {};
		for (uint32_t i = 0; i < n; i++) {
			const float v = sobol_burley_sample_1D(i, 0, seed, p_mask);
			hits[(int)(v * (float)n)]++;
		}
		for (uint32_t b = 0; b < n; b++) {
			CHECK(hits[b] == 1);
		}
	}
}

TEST_CASE("[PathTracer][Sobol] first 2^k 1D samples hit every stratum exactly once (block_mask)") {
	// A (0,1)-sequence: the first 2^k points fall one per 1/2^k interval.
	// Owen scrambling and the Burley index shuffle both preserve this.
	// White noise does not, which is the entire point of the change.
	check_1d_stratification(block_mask(6));
}

TEST_CASE("[PathTracer][Sobol] first 2^k 1D samples hit every stratum exactly once (production mask 0xffffffff)") {
	// Same property, at the mask value the shader actually uses (rng_1d/rng_2d in
	// raytracing_inc.glsl pass 0xffffffffu unconditionally) -- this is the case the
	// stratification guarantee needs to hold for in the shipped renderer.
	check_1d_stratification(0xffffffffu);
}

// Shared body for the 2D stratification property; see check_1d_stratification above
// for why both masks are exercised.
static void check_2d_stratification(uint32_t p_mask) {
	const uint32_t n = 256; // 2^8 points over a 16x16 grid.

	for (uint32_t seed_i = 0; seed_i < 8; seed_i++) {
		const uint32_t seed = sb_hash_hp(seed_i);
		int hits[16][16] = {};
		for (uint32_t i = 0; i < n; i++) {
			float x, y;
			sobol_burley_sample_2D(i, 0, seed, p_mask, x, y);
			hits[(int)(x * 16.0f)][(int)(y * 16.0f)]++;
		}
		for (int cx = 0; cx < 16; cx++) {
			for (int cy = 0; cy < 16; cy++) {
				CHECK(hits[cx][cy] == 1);
			}
		}
	}
}

TEST_CASE("[PathTracer][Sobol] first 2^k 2D samples hit every grid cell exactly once (block_mask)") {
	// A (0,2)-sequence: for 2^(2m) points every 2^m x 2^m cell holds exactly one.
	check_2d_stratification(block_mask(8));
}

TEST_CASE("[PathTracer][Sobol] first 2^k 2D samples hit every grid cell exactly once (production mask 0xffffffff)") {
	// Same property, at the mask value the shader actually uses in production.
	check_2d_stratification(0xffffffffu);
}

TEST_CASE("[PathTracer][Sobol] different pixel seeds produce different sequences") {
	// Per-pixel Owen scrambling must decorrelate neighbours, otherwise the whole
	// image shares one point set and the "noise" becomes a visible fixed pattern.
	const uint32_t seed_a = sb_hash_hp(11);
	const uint32_t seed_b = sb_hash_hp(12);
	int identical = 0;
	for (uint32_t i = 0; i < 256; i++) {
		const float a = sobol_burley_sample_1D(i, 0, seed_a, 0xffffffffu);
		const float b = sobol_burley_sample_1D(i, 0, seed_b, 0xffffffffu);
		if (Math::is_equal_approx(a, b)) {
			identical++;
		}
	}
	CHECK(identical < 4);
}

TEST_CASE("[PathTracer][Sobol] different dimensions are decorrelated") {
	const uint32_t seed = sb_hash_hp(7);
	int identical = 0;
	for (uint32_t i = 0; i < 256; i++) {
		const float a = sobol_burley_sample_1D(i, 0, seed, 0xffffffffu);
		const float b = sobol_burley_sample_1D(i, 1, seed, 0xffffffffu);
		if (Math::is_equal_approx(a, b)) {
			identical++;
		}
	}
	CHECK(identical < 4);
}

TEST_CASE("[PathTracer][Sobol] integrates a smooth 2D function far better than white noise") {
	// The actual value proposition: at equal sample count the estimator error is
	// dramatically lower. Integral of x*y over the unit square is 0.25.
	const uint32_t n = 256;
	const uint32_t mask = block_mask(8);
	const uint32_t seed = sb_hash_hp(99);

	double sobol_sum = 0.0;
	for (uint32_t i = 0; i < n; i++) {
		float x, y;
		sobol_burley_sample_2D(i, 0, seed, mask, x, y);
		sobol_sum += (double)x * (double)y;
	}
	const double sobol_err = Math::abs(sobol_sum / (double)n - 0.25);

	double white_sum = 0.0;
	uint32_t state = seed;
	for (uint32_t i = 0; i < n; i++) {
		state = pcg_hash(state);
		const double x = (double)state / 4294967296.0;
		state = pcg_hash(state);
		const double y = (double)state / 4294967296.0;
		white_sum += x * y;
	}
	const double white_err = Math::abs(white_sum / (double)n - 0.25);

	CHECK(sobol_err < 0.002);
	CHECK(sobol_err < white_err);
}

} // namespace TestPTSobol
