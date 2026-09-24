/**************************************************************************/
/*  test_pt_guiding.cpp                                                   */
/**************************************************************************/
/* CPU mirror of raytracing_guiding_inc.glsl (Gap #32). The invariant:    */
/* the density used to SAMPLE a guided direction and the density REPORTED */
/* through combinedPdf must be one function. A drift is a bias that still */
/* looks like a plausible image; gate G0 catches it late, this catches it */
/* at build time.                                                          */
/**************************************************************************/

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_pt_guiding)

#include "core/math/math_funcs.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"
#include <vector>

namespace TestPTGuiding {

// Matches raytracing_inc.glsl's `#define PI 3.141592653589f` exactly (a float
// literal, not Math::PI truncated from double at each use site): the functions
// below are a literal twin of GLSL float32 arithmetic, and Math::PI is a
// double that silently upgrades a "float" expression's precision at every use,
// which can round differently than doing the whole expression in float32 the
// way the shader does. Statistical/Monte-Carlo helpers below (sphere_dir's
// callers doing Riemann sums, etc.) still use Math::PI on purpose -- they are
// not part of the bit-level twin, just numerical estimators.
static const float PI_F = 3.141592653589f;

static const int BINS = 64;
static const float BIN_SOLID_ANGLE = 4.0f * PI_F / 64.0f;

// guide_bin_of_dir: 8 rows in cos(theta) over world +Y, 8 columns in phi = atan2(z, x).
static int bin_of_dir(const Vector3 &d) {
	float ct = CLAMP(d.y, -1.0f, 1.0f);
	int row = MIN(int((ct + 1.0f) * 0.5f * 8.0f), 7);
	float phi = Math::atan2(d.z, d.x);
	// atan2's range is (-PI, PI], so phi + PI_F is mathematically >= 0, but
	// phi can come back a float32 ULP more negative than -PI_F when the
	// hardware's internal pi differs from PI_F in its last bit -- clamp
	// before the cast: GLSL's uint(negative) is undefined behaviour (col
	// wraps to a huge value that then clamps to 7), while a bare C++ int
	// cast of a small negative float truncates to 0. Clamping the quotient
	// to >= 0 on BOTH sides makes them agree (col 0) instead of silently
	// diverging (7 vs 0) on this edge case.
	int col = MIN(int(MAX((phi + PI_F) / (2.0f * PI_F) * 8.0f, 0.0f)), 7);
	return row * 8 + col;
}

// guide_dir_of_bin: uniform in the bin's (cos theta, phi) rectangle == uniform in solid angle.
static Vector3 dir_of_bin(int bin, const Vector2 &u) {
	int row = bin / 8;
	int col = bin % 8;
	float ct = -1.0f + (float(row) + u.x) * 0.25f;
	float phi = -PI_F + (float(col) + u.y) * (2.0f * PI_F / 8.0f);
	float st = Math::sqrt(MAX(1.0f - ct * ct, 0.0f));
	return Vector3(st * Math::cos(phi), ct, st * Math::sin(phi));
}

static Vector3 bin_center(int bin) {
	return dir_of_bin(bin, Vector2(0.5f, 0.5f));
}

// guide_nkey: dominant signed axis, 0..5.
static uint32_t nkey(const Vector3 &n) {
	Vector3 a = n.abs();
	int axis = (a.x >= a.y && a.x >= a.z) ? 0 : ((a.y >= a.z) ? 1 : 2);
	return uint32_t(axis) * 2u + (n[axis] < 0.0f ? 1u : 0u);
}

// guide_cell_of: lowbias32 over the voxel and the normal key, masked to 2^18.
static uint32_t cell_of(const Vector3 &p, const Vector3 &n, const Vector3 &origin, float cell) {
	int32_t vx = int32_t(Math::floor((p.x - origin.x) / cell));
	int32_t vy = int32_t(Math::floor((p.y - origin.y) / cell));
	int32_t vz = int32_t(Math::floor((p.z - origin.z) / cell));
	uint32_t h = uint32_t(vx) * 0x8DA6B343u ^ uint32_t(vy) * 0xD8163841u ^ uint32_t(vz) * 0xCB1AB31Fu ^ nkey(n) * 0x9E3779B9u;
	h ^= h >> 16;
	h *= 0x7FEB352Du;
	h ^= h >> 15;
	h *= 0x846CA68Bu;
	h ^= h >> 16;
	return h & (262144u - 1u);
}

// A cell's cosine-weighted bin weights for a lobe normal Nd, and their total.
static float bin_weight(const std::vector<uint32_t> &bins, int bin, const Vector3 &Nd) {
	return float(bins[bin]) * MAX(bin_center(bin).dot(Nd), 0.0f);
}

static float total_weight(const std::vector<uint32_t> &bins, const Vector3 &Nd) {
	float t = 0.0f;
	for (int b = 0; b < BINS; b++) {
		t += bin_weight(bins, b, Nd);
	}
	return t;
}

// guide_pdf: weight of L's bin over the total, per steradian.
static float guide_pdf(const std::vector<uint32_t> &bins, const Vector3 &Nd, float total, const Vector3 &L) {
	if (total <= 0.0f) {
		return 0.0f;
	}
	return bin_weight(bins, bin_of_dir(L), Nd) / (total * BIN_SOLID_ANGLE);
}

// guide_sample: CDF over the cosine-weighted bins with u.x, residual reused
// for the in-bin cos(theta) coordinate, u.y for phi.
static bool guide_sample(const std::vector<uint32_t> &bins, const Vector3 &Nd, float total, const Vector2 &u, Vector3 &r_L) {
	if (total <= 0.0f) {
		return false;
	}
	float target = u.x * total;
	float cdf = 0.0f;
	for (int b = 0; b < BINS; b++) {
		float w = bin_weight(bins, b, Nd);
		if (w <= 0.0f) {
			continue;
		}
		if (target < cdf + w || b == BINS - 1) {
			float residual = CLAMP((target - cdf) / w, 0.0f, 0.999999f);
			r_L = dir_of_bin(b, Vector2(residual, u.y));
			return true;
		}
		cdf += w;
	}
	return false;
}

// The diffuse lobe's density under guiding: (1 - a) cos/pi + a * guide. The
// MAX(NdotLd, 0.0f) clamp is load-bearing: guide_diffuse_pdf() is evaluated by
// MIS for an arbitrary sampled direction, which can be below the shading
// horizon (NdotLd < 0). Fix round 1, finding 1: the GLSL twin omitted this
// clamp (`p_cos = NdotLd / PI`), so a below-horizon L produced a NEGATIVE
// combinedPdf term reaching MIS -- fixed in raytracing_guiding_inc.glsl's
// guide_diffuse_pdf() to match this clamp exactly.
//
// Task 4: the cosine term is a MULTIPLY by the folded (1 / PI), mirroring the
// GLSL twin, which had to match brdf_inc.glsl's diffusePdf() bit-for-bit once
// combinedPdf started routing its diffuse term through guide_diffuse_pdf() at
// every vertex (see that function's comment -- a 1-ULP divide/multiply
// difference there breaks the guiding-off inertness guarantee).
static float mix_pdf(float alpha, float NdotLd, float guide) {
	return (1.0f - alpha) * (MAX(NdotLd, 0.0f) * (1.0f / PI_F)) + alpha * guide;
}

static Vector3 sphere_dir(float u, float v) {
	float ct = 1.0f - 2.0f * u;
	float st = Math::sqrt(MAX(1.0f - ct * ct, 0.0f));
	float phi = 2.0f * Math::PI * v;
	return Vector3(st * Math::cos(phi), ct, st * Math::sin(phi));
}

TEST_CASE("[PathTracer][Guiding] bins tile the sphere with equal solid angle") {
	// 256 x 256 stratified directions over an (equal-area-in-cos(theta),
	// equal-area-in-phi) grid, against an (equal-area-in-cos(theta),
	// equal-area-in-phi) binning, with N an exact multiple of 8 in both axes:
	// every bin should get EXACTLY N*N/64 hits (a double-precision Python
	// mirror of this exact loop measures zero variance -- min == max ==
	// 1024). Fix round 1, minor finding: +-10% (over 100x looser than the
	// true float64 floor) would silently pass a bug that misassigns several
	// percent of samples. +-2% leaves headroom only for float32 boundary
	// jitter (a handful of samples landing exactly on a bin edge), not for a
	// real defect.
	std::vector<int> hits(BINS, 0);
	const int N = 256;
	for (int i = 0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			hits[bin_of_dir(sphere_dir((i + 0.5f) / N, (j + 0.5f) / N))]++;
		}
	}
	for (int b = 0; b < BINS; b++) {
		CHECK(hits[b] > int(N * N / 64.0 * 0.98));
		CHECK(hits[b] < int(N * N / 64.0 * 1.02));
	}
}

TEST_CASE("[PathTracer][Guiding] dir_of_bin lands in its own bin everywhere inside the bin") {
	for (int b = 0; b < BINS; b++) {
		for (int i = 0; i < 8; i++) {
			for (int j = 0; j < 8; j++) {
				Vector3 d = dir_of_bin(b, Vector2((i + 0.5f) / 8.0f, (j + 0.5f) / 8.0f));
				CHECK(bin_of_dir(d) == b);
			}
		}
	}
}

TEST_CASE("[PathTracer][Guiding] pdf integrates to 1 over the hemisphere of Nd") {
	std::vector<uint32_t> bins(BINS, 0);
	for (int b = 0; b < BINS; b++) {
		bins[b] = 1u + uint32_t((b * 37) % 11) * 200u; // uneven but positive
	}
	Vector3 Nd = Vector3(0.3f, 0.8f, -0.5f).normalized();
	float total = total_weight(bins, Nd);
	// Riemann sum over the sphere; bins whose CENTRE is below the horizon have weight 0.
	const int N = 400;
	double integral = 0.0;
	for (int i = 0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			Vector3 d = sphere_dir((i + 0.5f) / N, (j + 0.5f) / N);
			integral += guide_pdf(bins, Nd, total, d) * (4.0 * Math::PI / (N * N));
		}
	}
	CHECK(integral == doctest::Approx(1.0).epsilon(0.01));
}

TEST_CASE("[PathTracer][Guiding] the sampler's frequencies match the pdf it reports") {
	std::vector<uint32_t> bins(BINS, 1u);
	bins[bin_of_dir(Vector3(1, 0, 0))] = 5000u; // a "sun patch" toward +X
	bins[bin_of_dir(Vector3(0, 1, 0))] = 1000u;
	Vector3 Nd = Vector3(0, 1, 0);
	float total = total_weight(bins, Nd);
	std::vector<int> hits(BINS, 0);
	const int N = 512;
	int drawn = 0;
	for (int i = 0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			Vector3 L;
			if (guide_sample(bins, Nd, total, Vector2((i + 0.5f) / N, (j + 0.5f) / N), L)) {
				hits[bin_of_dir(L)]++;
				drawn++;
			}
		}
	}
	CHECK(drawn == N * N);
	// Fix round 1, finding 3: `expected` used to be recomputed inline from
	// bin_weight()/total, bypassing guide_pdf() entirely -- a defect confined
	// to guide_pdf() (the function combinedPdf() actually calls through
	// guide_diffuse_pdf()) could not fail this test, even though this test
	// exists specifically to catch the sampler and the reported pdf drifting
	// apart. Routing through guide_pdf(bin_center(b)) instead calls the same
	// function under test that guide_sample() is being checked against: a
	// bug in guide_pdf() (e.g. wrong bin lookup, a missing /BIN_SOLID_ANGLE,
	// or a wrong `total`) now shows up as `expected` disagreeing with the
	// empirical sampling frequency, exactly as this test's name promises.
	// bin_center(b) is a legitimate representative direction for bin b's
	// (constant-across-the-bin) weight: "dir_of_bin lands in its own bin"
	// guarantees bin_of_dir(bin_center(b)) == b.
	for (int b = 0; b < BINS; b++) {
		float expected = guide_pdf(bins, Nd, total, bin_center(b)) * BIN_SOLID_ANGLE; // = pdf * solid angle
		float observed = float(hits[b]) / float(drawn);
		if (expected > 0.005f) {
			CHECK(observed == doctest::Approx(expected).epsilon(0.05));
		} else {
			CHECK(observed < 0.01f);
		}
	}
}

TEST_CASE("[PathTracer][Guiding] the mixture density is positive wherever the cosine lobe is") {
	// Fix round 1, finding 2: bin 3 is row 0 (bin/8 == 0), whose CENTRE sits
	// well below the horizon for Nd=(0,1,0) (ct = -0.875) -- bin_weight()
	// clamps to 0 there, so total == 0, guide_pdf() always returns 0, and the
	// original assertion collapsed to `0.5f * MAX(NdotL,0)/PI > 0`, true by
	// construction and incapable of ever exercising the guide term. Train a
	// bin whose centre is ABOVE the horizon instead (row 4, ct = +0.125) so
	// total > 0 and guide_pdf() actually contributes.
	std::vector<uint32_t> bins(BINS, 0u);
	const int trained_bin = 4 * 8 + 3; // row 4 (above the horizon for Nd), col 3
	bins[trained_bin] = 100u;
	Vector3 Nd = Vector3(0, 1, 0);
	float total = total_weight(bins, Nd);
	REQUIRE(total > 0.0f); // guards against this test silently going vacuous again

	for (int i = 0; i < 64; i++) {
		Vector3 d = sphere_dir((i + 0.5f) / 64.0f, 0.37f);
		float NdotL = d.dot(Nd);
		float p = mix_pdf(0.5f, NdotL, guide_pdf(bins, Nd, total, d));
		if (NdotL > 0.0f) {
			CHECK(p > 0.0f);
		}
	}

	// Isolate the guide term (alpha = 1, so the cosine fallback contributes
	// nothing): density must be positive INSIDE the trained bin and exactly
	// zero everywhere else. This is what the loop above cannot catch on its
	// own -- with alpha = 0.5 the cosine term alone keeps p > 0 almost
	// everywhere regardless of whether guide_pdf() or the alpha-mixing is
	// broken. At alpha = 1 this fails if: guide_pdf() silently returns 0
	// for the trained bin (e.g. a wrong bin lookup or an inverted weight),
	// or if the mixture formula drops/ignores alpha and always adds the
	// cosine term (density would then be nonzero outside the trained bin
	// too, where it must be exactly 0).
	Vector3 inside = bin_center(trained_bin);
	CHECK(mix_pdf(1.0f, inside.dot(Nd), guide_pdf(bins, Nd, total, inside)) > 0.0f);
	for (int b = 0; b < BINS; b++) {
		if (b == trained_bin) {
			continue;
		}
		Vector3 outside = bin_center(b);
		float NdotL = outside.dot(Nd);
		if (NdotL <= 0.0f) {
			continue; // the loop above already only claims positivity above the horizon
		}
		CHECK(mix_pdf(1.0f, NdotL, guide_pdf(bins, Nd, total, outside)) == doctest::Approx(0.0f));
	}
}

TEST_CASE("[PathTracer][Guiding] the two faces of a wall get different cells") {
	Vector3 origin(-2, 0, -1.5);
	float cell = 0.15f;
	Vector3 p(0.0f, 1.5f, 1.5f); // a point on the front wall
	uint32_t a = cell_of(p, Vector3(0, 0, -1), origin, cell);
	uint32_t b = cell_of(p, Vector3(0, 0, 1), origin, cell);
	CHECK(a != b);
	CHECK(a < 262144u);
	// Fix round 1, minor finding: re-calling cell_of() with the exact same
	// arguments and checking it against `a` (itself computed by that same
	// call) is true for ANY pure function purely by construction -- it
	// cannot fail no matter how the hash is implemented, so it caught
	// nothing. Pin it to a value computed independently (float32 lowbias32
	// simulation, voxel (13, 10, 20), nkey 5) instead: a future edit that
	// changes any of the magic constants, the shift amounts, or vx/vy/vz's
	// rounding now actually has something to disagree with.
	CHECK(a == 165561u);
	CHECK(b == 225800u);
	// Two points 1 mm apart in the same voxel share a cell; across a voxel edge they may not.
	CHECK(cell_of(p + Vector3(0.001f, 0, 0), Vector3(0, 0, -1), origin, cell) == a);
}

TEST_CASE("[PathTracer][Guiding] nkey splits the six axis directions") {
	CHECK(nkey(Vector3(1, 0, 0)) != nkey(Vector3(-1, 0, 0)));
	CHECK(nkey(Vector3(0, 1, 0)) != nkey(Vector3(0, -1, 0)));
	CHECK(nkey(Vector3(0, 0, 1)) != nkey(Vector3(0, 0, -1)));
	CHECK(nkey(Vector3(0.9f, 0.3f, 0.1f)) == nkey(Vector3(1, 0, 0)));
	CHECK(nkey(Vector3(0, 1, 0)) < 6u);
}

} // namespace TestPTGuiding
