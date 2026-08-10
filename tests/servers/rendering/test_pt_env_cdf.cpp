/**************************************************************************/
/*  test_pt_env_cdf.cpp                                                   */
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

TEST_FORCE_LINK(test_pt_env_cdf)

#include "core/math/basis.h"
#include "core/math/math_funcs.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"
#include <vector>

namespace TestPTEnvCDF {

// CPU mirror of env_cdf_build.glsl + raytracing_env_sampling_inc.glsl.
// The invariant these tests protect: the pdf used to SAMPLE and the pdf used to
// EVALUATE must be the same function. If they drift apart, MIS produces a
// biased result that still looks like a plausible image.
//
// The mirror covers three levels, because the algebra being right is not enough:
//   1. direction  <- (u, v)          dir_from_uv(), mirrors env_cdf_build.glsl
//   2. octmap uv  <- direction       the BORDERED mapping, mirrors oct_inc.glsl
//   3. the prefix-sum / floor / pdf algebra itself
// Level 3 alone cannot catch a wrong direction convention or a dropped octmap
// border: both still produce a perfectly valid pdf that integrates to 1 and just
// points at the wrong sky.

static const int N_U = 256;
static const int N_V = 128;

struct Dist {
	float floor_value = 0.0f;
	float marginal_total = 0.0f;
	std::vector<float> prefix_raw; // N_V * N_U, row-major inclusive prefix
	std::vector<float> rowsum_adj; // N_V
	std::vector<float> marginal_prefix; // N_V
};

// ---------------------------------------------------------------------------
// Level 1: direction from grid cell centre. Mirrors dir_from_uv() in
// env_cdf_build.glsl. Engine is Y-up.
// ---------------------------------------------------------------------------

static Vector3 dir_from_uv(float p_u, float p_v) {
	const float phi = p_u * 2.0f * float(Math::PI);
	const float theta = p_v * float(Math::PI);
	const float st = Math::sin(theta);
	return Vector3(st * Math::sin(phi), Math::cos(theta), st * Math::cos(phi));
}

// ---------------------------------------------------------------------------
// Level 2: octahedral mapping. Mirrors oct_inc.glsl. The radiance octmap the
// shader samples is PADDED, so the bordered variants are the ones that matter.
// ---------------------------------------------------------------------------

static Vector2 oct_wrap(const Vector2 &p_v) {
	const float sx = (p_v.x >= 0.0f) ? 1.0f : -1.0f;
	const float sy = (p_v.y >= 0.0f) ? 1.0f : -1.0f;
	return Vector2((1.0f - Math::abs(p_v.y)) * sx, (1.0f - Math::abs(p_v.x)) * sy);
}

static Vector2 vec3_to_oct(Vector3 p_n) {
	p_n /= (Math::abs(p_n.x) + Math::abs(p_n.y) + Math::abs(p_n.z));
	Vector2 xy(p_n.x, p_n.y);
	if (p_n.z < 0.0f) {
		xy = oct_wrap(xy);
	}
	return xy * 0.5f + Vector2(0.5f, 0.5f);
}

// p_border.x = padding in UV space, p_border.y = 1 - padding * 2.
static Vector2 vec3_to_oct_with_border(const Vector3 &p_n, const Vector2 &p_border) {
	return vec3_to_oct(p_n) * p_border.y + Vector2(p_border.x, p_border.x);
}

static Vector3 oct_to_vec3(const Vector2 &p_e) {
	Vector3 v(p_e.x, p_e.y, 1.0f - Math::abs(p_e.x) - Math::abs(p_e.y));
	const float t = MAX(-v.z, 0.0f);
	v.x += t * ((v.x >= 0.0f) ? -1.0f : 1.0f);
	v.y += t * ((v.y >= 0.0f) ? -1.0f : 1.0f);
	return v.normalized();
}

// p_border_size = 1 - padding_in_uv_space * 2.
static Vector3 oct_to_vec3_with_border(Vector2 p_uv, float p_border_size) {
	p_uv = (p_uv - Vector2(0.5f, 0.5f)) * (2.0f / p_border_size);
	const bool mask_x = Math::abs(p_uv.x) >= 1.0f;
	const bool mask_y = Math::abs(p_uv.y) >= 1.0f;
	Vector2 c(2.0f * CLAMP(p_uv.x, -1.0f, 1.0f) - p_uv.x, 2.0f * CLAMP(p_uv.y, -1.0f, 1.0f) - p_uv.y);
	// GLSL: uv = mix(uv, -uv, mask.yx)
	return oct_to_vec3(Vector2(mask_y ? -c.x : c.x, mask_x ? -c.y : c.y));
}

// A synthetic stand-in for SkyRD's padded radiance octmap: the octahedron
// occupies only uv in [border, 1 - border], the rest is mirrored padding.
struct OctMap {
	int w = 0;
	float border = 0.0f;
	std::vector<float> texels;
};

// Bright narrow lobe around a fixed direction plus a dim background, evaluated
// in DIRECTION space so the texture genuinely encodes "where the sun is".
static Vector3 sun_dir() {
	return Vector3(0.4f, 0.7f, 0.6f).normalized();
}

static float sun_lum_dir(const Vector3 &p_d) {
	return (p_d.dot(sun_dir()) > 0.995f) ? 800.0f : 0.05f;
}

static OctMap make_padded_octmap(int p_w, float p_border) {
	OctMap m;
	m.w = p_w;
	m.border = p_border;
	m.texels.assign(size_t(p_w) * size_t(p_w), 0.0f);
	const float border_size = 1.0f - p_border * 2.0f;
	for (int py = 0; py < p_w; py++) {
		for (int px = 0; px < p_w; px++) {
			const Vector2 uv((px + 0.5f) / float(p_w), (py + 0.5f) / float(p_w));
			m.texels[size_t(py) * size_t(p_w) + size_t(px)] = sun_lum_dir(oct_to_vec3_with_border(uv, border_size));
		}
	}
	return m;
}

// Nearest-texel fetch, with the border convention supplied by the caller so a
// test can contrast the correct mapping against the unbordered one.
static float octmap_fetch(const OctMap &p_m, const Vector3 &p_d, float p_border_used) {
	const Vector2 uv = vec3_to_oct_with_border(p_d, Vector2(p_border_used, 1.0f - p_border_used * 2.0f));
	const int px = CLAMP(int(uv.x * p_m.w), 0, p_m.w - 1);
	const int py = CLAMP(int(uv.y * p_m.w), 0, p_m.w - 1);
	return p_m.texels[size_t(py) * size_t(p_m.w) + size_t(px)];
}

// ---------------------------------------------------------------------------
// Level 3: the distribution itself.
// ---------------------------------------------------------------------------

// Build from a luminance function of (u, v) in [0,1).
template <typename F>
static Dist build(F p_lum) {
	Dist d;
	d.prefix_raw.assign(N_V * N_U, 0.0f);
	d.rowsum_adj.assign(N_V, 0.0f);
	d.marginal_prefix.assign(N_V, 0.0f);

	std::vector<float> raw(N_V * N_U, 0.0f);
	double total_raw = 0.0;
	for (int y = 0; y < N_V; y++) {
		const float v = (y + 0.5f) / float(N_V);
		const float sin_theta = Math::sin(v * float(Math::PI));
		for (int x = 0; x < N_U; x++) {
			const float u = (x + 0.5f) / float(N_U);
			// max(lum, 0.0) mirrors cell_raw() in env_cdf_build.glsl.
			const float f = MAX(p_lum(u, v), 0.0f) * sin_theta;
			raw[y * N_U + x] = f;
			total_raw += f;
		}
	}

	// Relative floor: keeps the pdf strictly positive everywhere without
	// assuming absolute radiance units.
	d.floor_value = float(1e-4 * (total_raw / double(N_U * N_V)));

	double running_marginal = 0.0;
	for (int y = 0; y < N_V; y++) {
		double running = 0.0;
		for (int x = 0; x < N_U; x++) {
			running += raw[y * N_U + x];
			d.prefix_raw[y * N_U + x] = float(running);
		}
		d.rowsum_adj[y] = float(running + double(N_U) * d.floor_value);
		running_marginal += d.rowsum_adj[y];
		d.marginal_prefix[y] = float(running_marginal);
	}
	d.marginal_total = float(running_marginal);
	return d;
}

// f with the floor folded in, reconstructed from the raw prefix sums.
static float cell_value(const Dist &p_d, int p_y, int p_x) {
	const float lo = (p_x == 0) ? 0.0f : p_d.prefix_raw[p_y * N_U + p_x - 1];
	return (p_d.prefix_raw[p_y * N_U + p_x] - lo) + p_d.floor_value;
}

// pdf over solid angle for the cell containing (u, v).
static double pdf_omega(const Dist &p_d, float p_u, float p_v) {
	const int x = CLAMP(int(p_u * N_U), 0, N_U - 1);
	const int y = CLAMP(int(p_v * N_V), 0, N_V - 1);
	const double func_int = double(p_d.marginal_total) / double(N_U * N_V);
	const double pdf_uv = double(cell_value(p_d, y, x)) / func_int;
	const double sin_theta = Math::sin(double(p_v) * Math::PI);
	return pdf_uv / (2.0 * Math::PI * Math::PI * MAX(sin_theta, 1e-6));
}

// Sample (u, v) by inverting the marginal then the row conditional, then
// interpolating CONTINUOUSLY within the selected cell (mirrors env_sample() in
// raytracing_env_sampling_inc.glsl). Returning the cell centre unconditionally
// (the original form of this function) made the sampled measure a sum of
// N_V*N_U Dirac deltas while pdf_omega() reports a continuous density -- not the
// same measure, so the estimator silently stopped being Monte Carlo. The
// `hi > lo` guards are load-bearing: at fp32 precision consecutive prefix-sum
// entries can be bit-identical (see the task report), which would divide by
// zero without them.
static void sample_uv(const Dist &p_d, float p_r0, float p_r1, float &r_u, float &r_v) {
	const float target_v = p_r1 * p_d.marginal_total;
	int y = 0;
	while (y < N_V - 1 && p_d.marginal_prefix[y] < target_v) {
		y++;
	}
	const float m_lo = (y == 0) ? 0.0f : p_d.marginal_prefix[y - 1];
	const float m_hi = p_d.marginal_prefix[y];
	const float dv = (m_hi > m_lo) ? CLAMP((target_v - m_lo) / (m_hi - m_lo), 0.0f, 1.0f) : 0.5f;

	const float target_u = p_r0 * p_d.rowsum_adj[y];
	int x = 0;
	while (x < N_U - 1) {
		const float adj = p_d.prefix_raw[y * N_U + x] + float(x + 1) * p_d.floor_value;
		if (adj >= target_u) {
			break;
		}
		x++;
	}
	const float cdf_lo = (x == 0) ? 0.0f : p_d.prefix_raw[y * N_U + x - 1] + float(x) * p_d.floor_value;
	const float cdf_hi = p_d.prefix_raw[y * N_U + x] + float(x + 1) * p_d.floor_value;
	const float du = (cdf_hi > cdf_lo) ? CLAMP((target_u - cdf_lo) / (cdf_hi - cdf_lo), 0.0f, 1.0f) : 0.5f;

	r_u = (float(x) + du) / float(N_U);
	r_v = (float(y) + dv) / float(N_V);
}

static float lum_constant(float, float) {
	return 1.0f;
}

static float lum_sun(float p_u, float p_v) {
	// A small bright spot plus a dim background.
	const float du = p_u - 0.25f;
	const float dv = p_v - 0.30f;
	return (du * du + dv * dv < 0.0016f) ? 500.0f : 0.05f;
}

TEST_CASE("[PathTracer][EnvCDF] pdf integrates to 1 over the sphere (constant sky)") {
	const Dist d = build(lum_constant);
	double total = 0.0;
	for (int y = 0; y < N_V; y++) {
		const double v = (y + 0.5) / double(N_V);
		const double theta = v * Math::PI;
		for (int x = 0; x < N_U; x++) {
			const double u = (x + 0.5) / double(N_U);
			// dOmega for this cell = sin(theta) * dTheta * dPhi.
			const double d_omega = Math::sin(theta) * (Math::PI / N_V) * (2.0 * Math::PI / N_U);
			total += pdf_omega(d, float(u), float(v)) * d_omega;
		}
	}
	CHECK(total == doctest::Approx(1.0).epsilon(0.01));
}

TEST_CASE("[PathTracer][EnvCDF] pdf integrates to 1 over the sphere (bright sun)") {
	const Dist d = build(lum_sun);
	double total = 0.0;
	for (int y = 0; y < N_V; y++) {
		const double v = (y + 0.5) / double(N_V);
		const double theta = v * Math::PI;
		for (int x = 0; x < N_U; x++) {
			const double u = (x + 0.5) / double(N_U);
			const double d_omega = Math::sin(theta) * (Math::PI / N_V) * (2.0 * Math::PI / N_U);
			total += pdf_omega(d, float(u), float(v)) * d_omega;
		}
	}
	CHECK(total == doctest::Approx(1.0).epsilon(0.01));
}

TEST_CASE("[PathTracer][EnvCDF] sampling concentrates on the bright region") {
	// The whole point of importance sampling: most samples should land on the sun.
	const Dist d = build(lum_sun);
	int hits = 0;
	const int N = 4096;
	for (int i = 0; i < N; i++) {
		const float r0 = (i % 64 + 0.5f) / 64.0f;
		const float r1 = (i / 64 + 0.5f) / 64.0f;
		float u, v;
		sample_uv(d, r0, r1, u, v);
		const float du = u - 0.25f;
		const float dv = v - 0.30f;
		if (du * du + dv * dv < 0.0016f) {
			hits++;
		}
	}
	// The sun covers ~0.5% of the (u,v) domain but carries most of the energy.
	CHECK(hits > N / 2);
}

TEST_CASE("[PathTracer][EnvCDF] every cell has strictly positive pdf") {
	// A zero-pdf direction with nonzero radiance gives unbounded variance and a
	// biased estimate. This is what the relative floor exists to prevent.
	const Dist d = build(lum_sun);
	for (int y = 0; y < N_V; y++) {
		for (int x = 0; x < N_U; x++) {
			CHECK(cell_value(d, y, x) > 0.0f);
		}
	}
}

TEST_CASE("[PathTracer][EnvCDF] sampled cells round-trip through the pdf lookup") {
	// Sampling returns a cell; evaluating the pdf at that cell's own (u,v) must
	// pick the same cell. This is the sample/evaluate agreement invariant.
	const Dist d = build(lum_sun);
	for (int i = 0; i < 256; i++) {
		const float r0 = (i % 16 + 0.5f) / 16.0f;
		const float r1 = (i / 16 + 0.5f) / 16.0f;
		float u, v;
		sample_uv(d, r0, r1, u, v);
		const int x = CLAMP(int(u * N_U), 0, N_U - 1);
		const int y = CLAMP(int(v * N_V), 0, N_V - 1);
		CHECK(pdf_omega(d, u, v) == doctest::Approx(
				double(cell_value(d, y, x)) /
				(double(d.marginal_total) / double(N_U * N_V)) /
				(2.0 * Math::PI * Math::PI * MAX(Math::sin(double(v) * Math::PI), 1e-6))));
	}
}

TEST_CASE("[PathTracer][EnvCDF] dir_from_uv matches the documented Y-up convention") {
	// The buffer contract promises theta = acos(dir.y), phi = atan(dir.x, dir.z).
	// Task 3 inverts exactly this to evaluate the pdf for a given direction, so a
	// silent change of convention here would desynchronise sample from evaluate.
	for (int y = 0; y < N_V; y += 7) {
		const float v = (y + 0.5f) / float(N_V);
		for (int x = 0; x < N_U; x += 11) {
			const float u = (x + 0.5f) / float(N_U);
			const Vector3 d = dir_from_uv(u, v);

			CHECK(d.length() == doctest::Approx(1.0f).epsilon(1e-4));

			// Polar angle round-trips with no wrapping.
			const float theta = Math::acos(CLAMP(d.y, -1.0f, 1.0f));
			CHECK(theta == doctest::Approx(v * float(Math::PI)).epsilon(1e-4));

			// Azimuth returns (-PI, PI], so the inverse needs fract(), not a bare
			// divide -- a bare divide gives a NEGATIVE u for half the sphere.
			const float phi = Math::atan2(d.x, d.z);
			float u_back = phi / (2.0f * float(Math::PI));
			u_back = u_back - Math::floor(u_back); // fract()
			// u == 0.5 sits exactly on the atan2 branch cut; accept either end.
			const float err = MIN(Math::abs(u_back - u), 1.0f - Math::abs(u_back - u));
			CHECK(err < 1e-3f);
		}
	}
}

TEST_CASE("[PathTracer][EnvCDF] the octmap fetch must use the padded mapping") {
	// SkyRD's radiance octmap is padded: the octahedron occupies only the middle
	// (1 - 2b) of the texture. At the default radiance_size = 256 the single-
	// texture path gives b = 128 / 768 = 0.167, so a plain [0,1] uv reads
	// mirrored padding for directions it does not correspond to. The resulting
	// distribution is still a VALID pdf -- it integrates to 1, every cell is
	// positive, sampling still concentrates somewhere -- it just concentrates on
	// the wrong directions, which is worse than no importance sampling at all.
	const float b = 128.0f / 768.0f;
	const OctMap map = make_padded_octmap(768, b);
	const Vector3 sun = sun_dir();

	// Correct: same bordered mapping the shader and every other consumer use.
	const Dist d_ok = build([&](float u, float v) {
		return octmap_fetch(map, dir_from_uv(u, v), b);
	});
	// The bug: unbordered mapping against the same padded texture.
	const Dist d_bad = build([&](float u, float v) {
		return octmap_fetch(map, dir_from_uv(u, v), 0.0f);
	});

	// Both are well-formed distributions; that is exactly why this fails quietly.
	CHECK(d_ok.marginal_total > 0.0f);
	CHECK(d_bad.marginal_total > 0.0f);

	int hits_ok = 0;
	int hits_bad = 0;
	const int N = 4096;
	for (int i = 0; i < N; i++) {
		const float r0 = (i % 64 + 0.5f) / 64.0f;
		const float r1 = (i / 64 + 0.5f) / 64.0f;
		float u, v;

		sample_uv(d_ok, r0, r1, u, v);
		if (dir_from_uv(u, v).dot(sun) > 0.99f) {
			hits_ok++;
		}

		sample_uv(d_bad, r0, r1, u, v);
		if (dir_from_uv(u, v).dot(sun) > 0.99f) {
			hits_bad++;
		}
	}

	// With the border, the sun dominates the sampled directions.
	CHECK(hits_ok > N / 2);
	// Without it, the samples pile onto some other direction entirely. This is
	// the assertion that would have caught the original defect.
	CHECK(hits_bad < N / 10);
}

// ---------------------------------------------------------------------------
// Fix round 1, Critical 1: env_sample() must draw from a CONTINUOUS density,
// not a lattice of cell centres, or the reported pdf and the actual sampling
// measure disagree and the estimator quietly stops being Monte Carlo.
// ---------------------------------------------------------------------------

TEST_CASE("[PathTracer][EnvCDF] env_sample converges to the analytic sphere integral for a constant sky") {
	// For a spatially-CONSTANT L, unbiased importance sampling requires
	// E[L / pdf(X)] == integral of L over the sphere == 4*PI exactly (up to fp
	// rounding), for ANY resolution of the underlying grid, PROVIDED the reported
	// pdf is the true density of the distribution X is actually drawn from.
	//
	// Returning only the N_U*N_V cell CENTRES (a finite lattice) while reporting
	// a continuous density is a measure mismatch: the estimator degenerates into
	// a fixed midpoint-rule quadrature of theta. That quadrature has a real,
	// nonzero, RESOLUTION-dependent error (not a sample-count-dependent one --
	// more samples do not shrink it): measured directly against THIS test (by
	// temporarily forcing sample_uv() back to cell-centre-only) at
	// +2.423049e-05 relative. With the continuous remap the same test measures
	// -1.150619e-06 relative (residual floor: fp32 storage of the CDF data plus
	// this test's own SUB=4096 per-row quadrature, not the algorithm, which is
	// exact in the continuous limit -- see the task report for the closed-form
	// derivation and both raw numbers). Small enough that the existing
	// "integrates to 1" / "round-trips" tests never see it (both are
	// self-consistent with whatever single point pdf_omega is evaluated at),
	// but real and systematic. The epsilon below (5e-6) sits between the two
	// measured values with margin on both sides.
	//
	// SUB is deliberately enumerated PER ROW against that row's own exact
	// marginal_prefix boundary (not a global r0/r1 grid): a global grid spreads
	// its resolution unevenly across rows and, empirically, its OWN
	// discretization noise (~7e-5 relative at 131072 total samples) swamped the
	// ~2.4e-5 defect it was meant to catch. Per-row enumeration gives every row
	// the same SUB=4096 evenly-spaced coverage of its dv range regardless of the
	// row's probability mass, driving the test's own residual well below the
	// defect size instead of comparable to it. r0 is fixed (0.5): du does not
	// affect pdf_omega() for lum_constant (cell_value is identical across every
	// x in a row when the luminance function does not depend on u), so varying
	// it would add sampling cost without adding precision for this specific L.
	//
	// A first draft of this test averaged (row, dv) pairs with EQUAL weight per
	// row instead of weighting by each row's actual probability mass. That is a
	// different bug from the one under test, but it produced its own spurious
	// error of comparable size (rows near the poles carry much less probability
	// than equatorial rows, so equal weighting over-represents them) -- a
	// reminder that a measurement's own bias can rival the defect it is meant to
	// catch, and is worth checking independently before trusting a pass/fail.
	const Dist d = build(lum_constant);

	// E[1/pdf] = sum_row P(row) * E[1/pdf | row]: each row's contribution MUST be
	// weighted by that row's own probability mass (rowsum_adj[y] / marginal_total)
	// -- rows near the poles carry much less weight than equatorial rows, so
	// averaging (row, dv) pairs with equal weight (one earlier draft of this test
	// did exactly that) over-represents the poles and produces its own, different,
	// spurious bias. Enumerating per row and weighting explicitly avoids both that
	// mistake and the global-r-grid sample imbalance noted above.
	double weighted_avg = 0.0;
	const int SUB = 4096;
	for (int y = 0; y < N_V; y++) {
		const float m_lo = (y == 0) ? 0.0f : d.marginal_prefix[y - 1];
		const float m_hi = d.marginal_prefix[y];
		if (m_hi <= m_lo) {
			continue; // Degenerate row (possible only if floor_value == 0); skip like the dv guard would.
		}
		const double row_prob = double(m_hi - m_lo) / double(d.marginal_total);
		double row_sum_inv_pdf = 0.0;
		for (int k = 0; k < SUB; k++) {
			const float frac = (k + 0.5f) / float(SUB);
			const float target_v = m_lo + frac * (m_hi - m_lo);
			const float r1 = target_v / d.marginal_total;
			float u, v;
			sample_uv(d, 0.5f, r1, u, v);
			const double pdf = pdf_omega(d, u, v);
			REQUIRE(pdf > 0.0); // Every cell has positive pdf (floor); guards the division below.
			row_sum_inv_pdf += 1.0 / pdf; // L == 1 everywhere, so the estimator is just 1/pdf.
		}
		weighted_avg += row_prob * (row_sum_inv_pdf / double(SUB));
	}
	CHECK(weighted_avg == doctest::Approx(4.0 * Math::PI).epsilon(5e-6));
}

// ---------------------------------------------------------------------------
// Fix round 1, Important 4: the world<->sky transform pair (env_world_to_sky(),
// used by both env_sample() and env_pdf() in raytracing_env_sampling_inc.glsl)
// has zero coverage from the rest of this file, which only ever exercises
// SKY-space math. This cannot execute the GLSL directly -- there is no shader
// execution in this test binary -- but it validates the mathematical pattern
// the GLSL depends on: applying an orthonormal matrix W one way and its
// TRANSPOSE (its inverse, since it is orthonormal) the other way must be a
// no-op on the round trip, and therefore leave the pdf unchanged. Using W on
// BOTH legs (the transposed-side bug this guards against -- e.g. sky->world
// implemented as `W * sky_dir` instead of `transpose(W) * sky_dir`) rotates
// the round-tripped direction into the wrong cell and would fail this check.
// ---------------------------------------------------------------------------

TEST_CASE("[PathTracer][EnvCDF] pdf is invariant under an arbitrary orthonormal world<->sky transform") {
	const Dist d = build(lum_sun);

	// An arbitrary orthonormal rotation, unrelated to any specific camera
	// transform -- the invariant under test holds for ANY orthonormal matrix,
	// which is the whole point of using transpose() as the inverse in the GLSL.
	const Basis w = Basis::from_euler(Vector3(0.37f, -1.21f, 0.58f));
	REQUIRE(w.is_orthogonal());

	for (int i = 0; i < 64; i++) {
		const float r0 = (i % 8 + 0.5f) / 8.0f;
		const float r1 = (i / 8 + 0.5f) / 8.0f;
		float u, v;
		sample_uv(d, r0, r1, u, v);
		const Vector3 sky_dir = dir_from_uv(u, v);
		const double pdf_before = pdf_omega(d, u, v);

		// sky -> "world": mirrors env_sample()'s `transpose(world_to_sky) * sky_dir`.
		const Vector3 world_dir = w.transposed().xform(sky_dir);
		// "world" -> sky: mirrors env_pdf()'s `world_to_sky * p_dir`.
		const Vector3 sky_dir_back = w.xform(world_dir);

		CHECK(sky_dir_back.distance_to(sky_dir) < 1e-5f);

		// Evaluate the pdf at the round-tripped direction the way env_pdf() does:
		// invert dir_from_uv, then look up through the same pdf_omega() (mirrors
		// env_pdf_from_uv(), the single shared formula).
		const float theta = Math::acos(CLAMP(sky_dir_back.y, -1.0f, 1.0f));
		float u_back = Math::atan2(sky_dir_back.x, sky_dir_back.z) / (2.0f * float(Math::PI));
		u_back -= Math::floor(u_back); // fract()
		const float v_back = theta / float(Math::PI);

		CHECK(pdf_omega(d, u_back, v_back) == doctest::Approx(pdf_before).epsilon(1e-3));
	}
}

} // namespace TestPTEnvCDF
