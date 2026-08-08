// Owen-scrambled, shuffled Sobol sampler ("Practical Hash-based Owen Scrambling",
// Burley 2020), ported verbatim from Blender Cycles:
//   intern/cycles/kernel/sample/sobol_burley.h   (the sampler)
//   intern/cycles/kernel/sample/util.h           (reversed_bit_owen)
//   intern/cycles/util/hash.h                    (hash_hp_uint, hash_iqnt2d, uint_to_float_excl)
//   intern/cycles/kernel/tables.h:81             (direction vectors)
//
// A CPU mirror of this file lives in tests/servers/rendering/test_pt_sobol.cpp and
// carries the unit tests. Change both together or the tests stop meaning anything.
//
// Why this replaces PCG: white noise scatters error into clumps that read as
// splotchy grain and denoise badly. An Owen-scrambled Sobol sequence is stratified,
// so at equal sample count the residual error is fine and even. The property only
// holds if each decision is drawn from a FIXED dimension index every path — see
// RNGState in raytracing_inc.glsl.

// Direction vectors for the first four Sobol dimensions, stored bit-reversed
// (the hash-based Owen scramble needs them reversed anyway).
// Flattened to 1D as [dimension * 32 + i]; only dimensions 0 and 1 are reachable
// through the 1D/2D entry points, 2 and 3 are kept for a future 3D/4D draw.
const uint SOBOL_BURLEY_TABLE[128] = uint[128](
		// Dimension 0.
		0x00000001u, 0x00000002u, 0x00000004u, 0x00000008u,
		0x00000010u, 0x00000020u, 0x00000040u, 0x00000080u,
		0x00000100u, 0x00000200u, 0x00000400u, 0x00000800u,
		0x00001000u, 0x00002000u, 0x00004000u, 0x00008000u,
		0x00010000u, 0x00020000u, 0x00040000u, 0x00080000u,
		0x00100000u, 0x00200000u, 0x00400000u, 0x00800000u,
		0x01000000u, 0x02000000u, 0x04000000u, 0x08000000u,
		0x10000000u, 0x20000000u, 0x40000000u, 0x80000000u,
		// Dimension 1.
		0x00000001u, 0x00000003u, 0x00000005u, 0x0000000fu,
		0x00000011u, 0x00000033u, 0x00000055u, 0x000000ffu,
		0x00000101u, 0x00000303u, 0x00000505u, 0x00000f0fu,
		0x00001111u, 0x00003333u, 0x00005555u, 0x0000ffffu,
		0x00010001u, 0x00030003u, 0x00050005u, 0x000f000fu,
		0x00110011u, 0x00330033u, 0x00550055u, 0x00ff00ffu,
		0x01010101u, 0x03030303u, 0x05050505u, 0x0f0f0f0fu,
		0x11111111u, 0x33333333u, 0x55555555u, 0xffffffffu,
		// Dimension 2.
		0x00000001u, 0x00000003u, 0x00000006u, 0x00000009u,
		0x00000017u, 0x0000003au, 0x00000071u, 0x000000a3u,
		0x00000116u, 0x00000339u, 0x00000677u, 0x000009aau,
		0x00001601u, 0x00003903u, 0x00007706u, 0x0000aa09u,
		0x00010117u, 0x0003033au, 0x00060671u, 0x000909a3u,
		0x00171616u, 0x003a3939u, 0x00717777u, 0x00a3aaaau,
		0x01170001u, 0x033a0003u, 0x06710006u, 0x09a30009u,
		0x16160017u, 0x3939003au, 0x77770071u, 0xaaaa00a3u,
		// Dimension 3.
		0x00000001u, 0x00000003u, 0x00000004u, 0x0000000au,
		0x0000001fu, 0x0000002eu, 0x00000045u, 0x000000c9u,
		0x0000011bu, 0x000002a4u, 0x0000079au, 0x00000b67u,
		0x0000101eu, 0x0000302du, 0x00004041u, 0x0000a0c3u,
		0x0001f104u, 0x0002e28au, 0x000457dfu, 0x000c9baeu,
		0x0011a105u, 0x002a7289u, 0x0079e7dbu, 0x00b6dba4u,
		0x0100011au, 0x030002a7u, 0x0400079eu, 0x0a000b6du,
		0x1f001001u, 0x2e003003u, 0x45004004u, 0xc900a00au);

/// Hash Prospector mixer (Cycles `hash_hp_uint`).
uint sb_hash_hp(uint p_i) {
	p_i ^= p_i >> 16u;
	p_i *= 0x21f0aaadu;
	p_i ^= p_i >> 15u;
	p_i *= 0xd35a2d97u;
	p_i ^= p_i >> 15u;
	// The xor only stops 0 mapping to 0; the constant is arbitrary.
	return p_i ^ 0xe6fe3bebu;
}

/// Per-pixel decorrelation hash (Cycles `hash_iqnt2d`).
uint sb_hash_iqnt2d(uint p_x, uint p_y) {
	const uint qx = 1103515245u * ((p_x >> 1u) ^ p_y);
	const uint qy = 1103515245u * ((p_y >> 1u) ^ p_x);
	return 1103515245u * (qx ^ (qy >> 3u));
}

/// Base-2 Owen scramble of a bit-reversed integer (Cycles `reversed_bit_owen`).
uint sb_pcg_owen(uint p_n, uint p_seed) {
	p_n ^= p_n * 0x3d20adeau;
	p_n += p_seed;
	p_n *= (p_seed >> 16u) | 1u;
	p_n ^= p_n * 0x05526c56u;
	p_n ^= p_n * 0x53a22864u;
	return p_n;
}

/// [0, uint_max] -> [0.0, 1.0). Dividing by 4294967808 rather than 2^32 keeps the
/// result strictly below 1.0 after float rounding (Cycles `uint_to_float_excl`).
float sb_uint_to_float_excl(uint p_n) {
	return float(p_n) * (1.0 / 4294967808.0);
}

/// One dimension of an Owen-scrambled Sobol sample.
float sb_sobol_burley(uint p_rev_bit_index, uint p_dimension, uint p_scramble_seed) {
	uint result = 0u;

	if (p_dimension == 0u) {
		// Dimension 0 is plain Van der Corput; the fast path matters because
		// padding reuses dimension 0 more than any other.
		result = bitfieldReverse(p_rev_bit_index);
	} else {
		uint i = 0u;
		while (p_rev_bit_index != 0u) {
			// GLSL has no clz; findMSB is defined for non-zero input, which the
			// loop condition guarantees.
			const uint j = uint(31 - findMSB(p_rev_bit_index));
			// `i` counts bits consumed so far and the loop ends once every bit is
			// shifted out, so i + j <= 31 and the index stays inside the block.
			result ^= SOBOL_BURLEY_TABLE[p_dimension * 32u + i + j];
			i += j + 1u;
			// Split because a shift of 32 is undefined.
			p_rev_bit_index <<= j;
			p_rev_bit_index <<= 1u;
		}
	}

	result = bitfieldReverse(sb_pcg_owen(result, p_scramble_seed));
	return sb_uint_to_float_excl(result);
}

/// 1D Owen-scrambled, shuffled Sobol sample. Different `p_dimension` values are
/// uncorrelated. `p_mask` limits the sequence length for speed; 0xffffffff is the
/// safe maximum-length default.
float sobol_burley_sample_1D(uint p_index, uint p_dimension, uint p_seed, uint p_mask) {
	p_seed ^= sb_hash_hp(p_dimension);
	p_index = sb_pcg_owen(bitfieldReverse(p_index), p_seed ^ 0xbff95bfeu);
	p_index &= p_mask;
	return sb_sobol_burley(p_index, 0u, p_seed ^ 0x635c77bdu);
}

/// 2D Owen-scrambled, shuffled Sobol sample. The two dimensions within one set are
/// stratified against each other; different sets are uncorrelated. Note that a 1D
/// and a 2D draw with the same index/dimension/seed are also uncorrelated, so the
/// two entry points can be mixed freely.
vec2 sobol_burley_sample_2D(uint p_index, uint p_dimension_set, uint p_seed, uint p_mask) {
	p_seed ^= sb_hash_hp(p_dimension_set);
	p_index = sb_pcg_owen(bitfieldReverse(p_index), p_seed ^ 0xf8ade99au);
	p_index &= p_mask;
	return vec2(
			sb_sobol_burley(p_index, 0u, p_seed ^ 0xe0aaaf76u),
			sb_sobol_burley(p_index, 1u, p_seed ^ 0x94964d4eu));
}
