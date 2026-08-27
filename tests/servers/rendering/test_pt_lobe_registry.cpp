/**************************************************************************/
/*  test_pt_lobe_registry.cpp                                             */
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

TEST_FORCE_LINK(test_pt_lobe_registry)

#include "core/math/math_funcs.h"

namespace TestPTLobeRegistry {

// CPU mirrors of the N-way lobe selection in
// servers/rendering/renderer_rd/shaders/raytracing/brdf_inc.glsl.
// Must stay textually identical to the GLSL modulo type names.
//
// This phase is a pure refactor: at N == 2 every function here must reduce to
// the two-way code it replaces, EXACTLY. These tests pin the two properties a
// rendered image cannot see -- lobe ORDER and CDF ORIENTATION -- because
// getting either wrong produces a statistically identical picture that is
// bitwise unrecognisable, and every GPU gate would still pass.

#define LOBE_SPECULAR 0
#define LOBE_DIFFUSE 1
#define LOBE_COUNT 2

// The single lobe-probability function replacing combinedPdfLobeProbability
// and samplerLobeProbability. Copied from brdf_inc.glsl's shared body.
static float lobe_weight(float p_specular_lum, float p_diffuse_lum) {
	if (p_diffuse_lum < 0.0001f) {
		return 1.0f;
	} else if (p_specular_lum < 0.0001f) {
		return 0.0f;
	}
	return CLAMP(p_specular_lum / (p_specular_lum + p_diffuse_lum), 0.01f, 0.99f);
}

// CDF walk. At N == 2 this must pick LOBE_SPECULAR on exactly the inputs for
// which today's `u < brdfProbability` picks SPECULAR_TYPE.
static int select_lobe(float p_u, const float *p_weights, int p_n) {
	float acc = 0.0f;
	for (int i = 0; i < p_n - 1; i++) {
		acc += p_weights[i];
		if (p_u < acc) {
			return i;
		}
	}
	return p_n - 1;
}

// Sum in registry order: specular term first, then diffuse.
static float combine_pdf(const float *p_weights, const float *p_pdfs, int p_n) {
	float acc = 0.0f;
	for (int i = 0; i < p_n; i++) {
		acc += p_weights[i] * p_pdfs[i];
	}
	return acc;
}

TEST_CASE("[PathTracer][LobeRegistry] specular is index 0") {
	// Not cosmetic. A diffuse-first registry makes `u < cdf[0]` select DIFFUSE
	// exactly where today's `u < brdfProbability` selects SPECULAR, inverting
	// every pixel's lobe choice. The image stays statistically identical, so no
	// gate can see it. This is the phase's likeliest silent failure.
	CHECK(LOBE_SPECULAR == 0);
	CHECK(LOBE_DIFFUSE == 1);
	CHECK(LOBE_COUNT == 2);
}

TEST_CASE("[PathTracer][LobeRegistry] CDF orientation matches the two-way comparison") {
	// Today: `if (rng < brdfProbability) SPECULAR else DIFFUSE`.
	// The CDF must agree at every u, including both boundaries.
	//
	// Swept over BOTH regimes deliberately. An earlier revision tested only
	// p_spec = 0.37, i.e. specular as the minority lobe. A hypothetical
	// select_lobe keying off min/max weight, or special-casing a dominant
	// first lobe, is only distinguishable from positional order when the
	// split is examined from both sides. This suite is the only safety net
	// for lobe order -- no rendered image can see it -- so the sweep is not
	// redundancy.
	const float p_specs[] = { 0.37f, 0.5f, 0.73f };
	for (float p_spec : p_specs) {
		CAPTURE(p_spec);
		const float weights[LOBE_COUNT] = { p_spec, 1.0f - p_spec };

		const float us[] = { 0.0f, 0.1f, p_spec - 0.00001f, p_spec + 0.00001f,
			0.5f, 0.9f, 0.999f };
		for (float u : us) {
			CAPTURE(u);
			const int expected = (u < p_spec) ? LOBE_SPECULAR : LOBE_DIFFUSE;
			CHECK(select_lobe(u, weights, LOBE_COUNT) == expected);
		}
	}
}

TEST_CASE("[PathTracer][LobeRegistry] the inverted registry is measurably different") {
	// Guards the guard: if select_lobe ever became order-insensitive, the test
	// above would pass on a broken implementation. Pin that a diffuse-first
	// ordering genuinely disagrees, so the property being tested is real.
	//
	// Both regimes again, for the reason given above. p_spec = 0.5 is
	// deliberately NOT swept here: at an even split the inverted registry is
	// the same array, so zero disagreements is the correct answer and the
	// test would be asserting against a genuinely orientation-free input.
	const float p_specs[] = { 0.37f, 0.73f };
	for (float p_spec : p_specs) {
		CAPTURE(p_spec);
		const float correct[LOBE_COUNT] = { p_spec, 1.0f - p_spec };
		const float inverted[LOBE_COUNT] = { 1.0f - p_spec, p_spec };

		int disagreements = 0;
		for (int i = 0; i < 100; i++) {
			const float u = (float(i) + 0.5f) / 100.0f;
			if (select_lobe(u, correct, LOBE_COUNT) != select_lobe(u, inverted, LOBE_COUNT)) {
				disagreements++;
			}
		}
		CHECK(disagreements > 20);
	}
}

TEST_CASE("[PathTracer][LobeRegistry] combine_pdf reduces to the two-term form") {
	// Today: pSpec * specularContribution * transmitScale + (1 - pSpec) * pdfDiffuse
	// transmitScale belongs to the SPECULAR lobe's pdf, not to the combination,
	// so it is folded into pdfs[LOBE_SPECULAR] by the caller.
	const float p_spec = 0.42f;
	const float spec_contribution = 3.75f;
	const float transmit_scale = 0.61f;
	const float pdf_diffuse = 0.28f;

	const float weights[LOBE_COUNT] = { p_spec, 1.0f - p_spec };
	const float pdfs[LOBE_COUNT] = { spec_contribution * transmit_scale, pdf_diffuse };

	// NOTE the grouping. C parses `a * b * c` as `(a * b) * c`, so the shader
	// computes (p_spec * spec_contribution) * transmit_scale. The registry folds
	// transmit_scale into the specular pdf ENTRY, computing
	// p_spec * (spec_contribution * transmit_scale). Those differ by 1 ULP in
	// float32 -- the next test records it. `expected` uses the REGISTRY's
	// grouping, so this test verifies the registry's own arithmetic rather than
	// loosening an epsilon to tolerate a difference that should be pinned.
	const float expected = p_spec * (spec_contribution * transmit_scale) + (1.0f - p_spec) * pdf_diffuse;
	CHECK(combine_pdf(weights, pdfs, LOBE_COUNT) == doctest::Approx(expected).epsilon(1e-9));
}

TEST_CASE("[PathTracer][LobeRegistry] the registry reassociates the specular term by 1 ULP") {
	// Recorded, not hidden. Found by the test above before any shader was
	// touched, and ruled during execution: a clean uniform sum is worth one ULP
	// on one term.
	//
	//   shader today: (p_spec * spec) * transmit   -- C's left-to-right grouping
	//   registry:      p_spec * (spec * transmit)  -- transmit folded into the pdf
	//
	// Mathematically equal, 1 ULP apart in float32. Relative difference 1.06e-7,
	// two orders of magnitude BELOW mean_luma's ~1e-5 run-to-run floor on an
	// identical binary, so no gate in this project can resolve it.
	const float p_spec = 0.42f;
	const float spec_contribution = 3.75f;
	const float transmit_scale = 0.61f;

	const float shader_grouping = (p_spec * spec_contribution) * transmit_scale;
	const float registry_grouping = p_spec * (spec_contribution * transmit_scale);

	// They genuinely differ -- if this ever passes as equal, the compiler has
	// reassociated and the pinned magnitudes below stop meaning anything.
	CHECK(shader_grouping != registry_grouping);
	const float rel = Math::abs(shader_grouping - registry_grouping) / shader_grouping;
	CHECK(rel < 2e-7f);
	CHECK(rel > 1e-8f);
}

TEST_CASE("[PathTracer][LobeRegistry] lobe_weight preserves the degenerate branches") {
	// The early returns are behaviour, not optimisation: they are what makes a
	// pure-metal or pure-diffuse surface pick one lobe with certainty.
	CHECK(lobe_weight(0.5f, 0.00001f) == 1.0f);
	CHECK(lobe_weight(0.00001f, 0.5f) == 0.0f);
	// And the clamp bounds hold in between.
	CHECK(lobe_weight(1000.0f, 0.001f) == doctest::Approx(0.99f).epsilon(1e-6));
	CHECK(lobe_weight(0.001f, 1000.0f) == doctest::Approx(0.01f).epsilon(1e-6));
}

} // namespace TestPTLobeRegistry
