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

#include "core/math/math_funcs.h"
#include <vector>

namespace TestPTEnvCDF {

// CPU mirror of env_cdf_build.glsl + raytracing_env_sampling_inc.glsl.
// The invariant these tests protect: the pdf used to SAMPLE and the pdf used to
// EVALUATE must be the same function. If they drift apart, MIS produces a
// biased result that still looks like a plausible image.

static const int N_U = 256;
static const int N_V = 128;

struct Dist {
	float floor_value = 0.0f;
	float marginal_total = 0.0f;
	std::vector<float> prefix_raw; // N_V * N_U, row-major inclusive prefix
	std::vector<float> rowsum_adj; // N_V
	std::vector<float> marginal_prefix; // N_V
};

// Build from a luminance function of (u, v) in [0,1).
static Dist build(float (*p_lum)(float, float)) {
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
			const float f = p_lum(u, v) * sin_theta;
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

// Sample (u, v) by inverting the marginal then the row conditional.
static void sample_uv(const Dist &p_d, float p_r0, float p_r1, float &r_u, float &r_v) {
	const float target_v = p_r1 * p_d.marginal_total;
	int y = 0;
	while (y < N_V - 1 && p_d.marginal_prefix[y] < target_v) {
		y++;
	}
	const float target_u = p_r0 * p_d.rowsum_adj[y];
	int x = 0;
	while (x < N_U - 1) {
		const float adj = p_d.prefix_raw[y * N_U + x] + float(x + 1) * p_d.floor_value;
		if (adj >= target_u) {
			break;
		}
		x++;
	}
	r_u = (x + 0.5f) / float(N_U);
	r_v = (y + 0.5f) / float(N_V);
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

} // namespace TestPTEnvCDF
