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
//
// E2e Task 4 fix round 1: RESYNCED with brdf_inc.glsl's repaired body. This
// mirror held the PRE-REPAIR form (`for i < p_n - 1` / no zero skip /
// `return p_n - 1`) while the shader had already moved on, and the file header
// four lines above says the two must stay textually identical -- so a
// contributor obeying that instruction could have ported this body BACK into
// the shader and reintroduced a live divide-by-zero, with nothing red to stop
// them. Three lines differed; all three are below.
//
// `p_n` stays a parameter rather than becoming the shader's LOBE_COUNT: the
// mirror's own LOBE_COUNT is the N == 2 baseline the first case pins, and the
// higher-N cases pass 3 or 4 explicitly.
static int select_lobe(float p_u, const float *p_weights, int p_n) {
	float acc = 0.0f;
	int last = 0;
	for (int i = 0; i < p_n; i++) {
		if (p_weights[i] <= 0.0f) {
			continue;
		}
		last = i;
		acc += p_weights[i];
		if (p_u < acc) {
			return i;
		}
	}
	return last;
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
	// READ THIS BEFORE TRUSTING THIS CASE. It checks the THREE #defines at the
	// top of THIS FILE against literals, in the same translation unit. Nothing
	// links them to brdf_inc.glsl. **It cannot detect a GLSL-side divergence.**
	// Invert `#define LOBE_SPECULAR` / `LOBE_DIFFUSE` in the shader and every
	// pixel's lobe choice flips while all six cases here still pass.
	//
	// It is kept because it pins the mirror the other five cases are built on:
	// if someone edits the mirror's constants to "fix" a failure, this fails
	// first and names why. That is its whole job. The property it is named for
	// -- that the SHADER puts specular at index 0 -- has no automated
	// instrument at all: no rendered image can see an inverted registry (the
	// picture stays statistically identical and every GPU gate passes), and a
	// CPU mirror cannot see the shader. Structural review is the only
	// instrument, which is why design 6.3 names it explicitly.
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
	// split is examined from both sides. This is the only automated pin on
	// the CDF's ORIENTATION -- no rendered image can see it -- so the sweep is
	// not redundancy. (It pins the orientation of the mirror below, which is
	// textually identical to the GLSL; the shader's own lobe ORDER is covered
	// only by structural review, see the first case in this file.)
	const float p_specs[] = { 0.37f, 0.5f, 0.73f };
	for (float p_spec : p_specs) {
		CAPTURE(p_spec);
		const float weights[LOBE_COUNT] = { p_spec, 1.0f - p_spec };

		// p_spec itself is included deliberately: without it, mutating
		// select_lobe's `u < acc` to `u <= acc` passes every case. Measure-zero
		// at runtime, but this is the only pin on the predicate.
		const float us[] = { 0.0f, 0.1f, p_spec - 0.00001f, p_spec,
			p_spec + 0.00001f, 0.5f, 0.9f, 0.999f };
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
	//
	// Consequence, stated plainly: this case does NOT verify reduction to the
	// pre-E2c two-term expression -- the next case is what measures the gap
	// between them. And note that SUMMATION ORDER cannot be pinned here at
	// all: IEEE-754 addition is commutative bit-exactly, so reversing
	// combine_pdf's loop at N == 2 returns an identical float. Order only
	// becomes observable at N >= 3, where associativity, not commutativity, is
	// what bites. Until then the roadmap's summation-order property rests on
	// structural review, not on this file.
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
	// Mathematically equal, 1 ULP apart in float32 AT THESE INPUTS -- this is a
	// measurement at one triple, not a bound; (a*b)*c vs a*(b*c) can differ by
	// ~2 ULP in general. Two relative figures get quoted and they measure
	// different things: 6.2e-8 is the gap on the SPECULAR TERM (what `rel`
	// below computes), 1.06e-7 is the gap on the FULL combined expression with
	// these constants. Both are orders of magnitude BELOW mean_luma's ~1e-5
	// run-to-run floor on an identical binary, so no gate in this project can
	// resolve either.
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

TEST_CASE("[PathTracer][LobeRegistry] select_lobe never returns a zero-weight lobe") {
	// LOAD-BEARING for E2d. Task 5 appends the coat at index 2, and on an
	// uncoated material its weight is 0. select_lobe falls through to
	// `return p_n - 1` -- the coat -- for any u at or above the running weight
	// sum, and the sampler divides throughput by the selected lobe's weight.
	// If that fallback were reachable with a zero-weight lobe last, the render
	// would grow NaNs at a rate no mean-based gate would attribute correctly.
	//
	// An earlier version of this case asserted `p + (1.0f - p) == 1.0f` over a
	// list of p values. That is true for EVERY float32 p as a consequence of
	// IEEE-754 rounding, so it could not fail, and it never called the real
	// weight function -- the same defect class the case was written to close.
	//
	// This version calls the REAL lobe_weight, builds the pair exactly as the
	// sampler does (w1 = 1 - w0), appends the zero third entry Task 5 appends,
	// and asserts on select_lobe's OUTPUT. w1 is a COMPLEMENT of whatever w0
	// comes back, not an independent call, so w0 + w1 == 1.0 by construction
	// regardless of where lobe_weight's clamp bounds sit -- an ordinary clamp
	// retuning (e.g. narrowing [0.01, 0.99] to [0.02, 0.98]) leaves this case
	// green, because select_lobe never sees anything but a complementary pair.
	// What it actually fails on: select_lobe's accumulation/threshold logic
	// falling through to the zero-weight index 2 for some w0 in lobe_weight's
	// real output range and some u the sampler can hand it -- i.e. if the
	// diffuse weight is ever computed some other way than `1 - w0`, or if
	// select_lobe's accumulation changes, at any of the w0 magnitudes and u
	// values exercised below. It would also fail if lobe_weight's clamp
	// bounds were widened to include exactly 0.0 or 1.0 (the one way a clamp
	// change reaches this test, since it makes w0 or w1 non-positive).
	const float lums[][2] = {
		{ 0.04f, 0.5f }, { 0.5f, 0.04f }, { 1.0f, 1.0f },
		{ 0.9f, 0.1f }, { 0.001f, 0.999f }, { 0.37f, 0.63f },
		{ 2.5f, 0.125f }, { 0.125f, 2.5f },
	};
	// 0.99999994f is the largest float32 strictly below 1.0. rng_1d returns
	// [0,1) (sb_uint_to_float_excl, sobol_burley_inc.glsl:118), so that is the
	// worst case the sampler can actually hand select_lobe.
	const float us[] = { 0.0f, 0.5f, 0.9f, 0.999f, 0.999999f, 0.99999994f };

	for (const float *lum : lums) {
		CAPTURE(lum[0]);
		CAPTURE(lum[1]);
		const float w0 = lobe_weight(lum[0], lum[1]);
		const float weights3[3] = { w0, 1.0f - w0, 0.0f };

		for (float u : us) {
			CAPTURE(u);
			const int selected = select_lobe(u, weights3, 3);
			// The real assertion: whatever lobe comes back must have weight the
			// sampler can divide by.
			CHECK(weights3[selected] > 0.0f);
			// And with a zero third entry it must specifically never be index 2.
			CHECK(selected != 2);
		}
	}
}

TEST_CASE("[PathTracer][LobeRegistry] four lobes: a trailing zero weight is never selected") {
	// E2e Task 4 fix round 1. THE INSTRUMENT FOR THE REPAIR, and the reason the
	// case below it is not enough on its own.
	//
	// The pre-existing zero-weight case (above) builds only {w0, 1 - w0, 0}, and
	// `fl(w0 + fl(1 - w0)) == 1.0f` for EVERY float32 w0 -- so `u < acc` always
	// fires at i == 1 and the fallthrough is unreachable. That case therefore
	// passes against the pre-repair body AND the repaired one; it cannot see the
	// thing that changed.
	//
	// At FOUR weights it can. The sampler builds
	//     w0 = (1 - coatMass) * pSpec
	//     w1 = (1 - coatMass) * (1 - pSpec)
	//     w2 = coatMass
	//     w3 = sheenMass, which is exactly 0 on every material without sheen
	// and those four sum to 1 only in exact arithmetic. The pre-repair body
	// stopped the loop at p_n - 1, so it accumulated w0..w2 and fell through to
	// index 3 -- the ZERO one -- whenever fl(w0 + w1 + w2) landed below u. The
	// caller then divides throughput by that zero.
	//
	// The window is real, not theoretical: at pSpec = lobe_weight(0.04, 0.5) =
	// 0.0740740672f and coatMass = 0.0397f the sum is 0.999999881f, which is
	// 5.96e-08 BELOW the largest u the sampler can draw. rng_1d bottoms out in
	// sb_uint_to_float_excl (sobol_burley_inc.glsl), whose largest output is
	// 0.99999994f, so that gap is live at run time.
	const float lums[][2] = {
		{ 0.04f, 0.5f }, { 0.5f, 0.04f }, { 1.0f, 1.0f },
		{ 0.9f, 0.1f }, { 0.001f, 0.999f }, { 0.37f, 0.63f },
		{ 2.5f, 0.125f }, { 0.125f, 2.5f },
	};
	// 0.99999994f is the largest float32 strictly below 1.0 and the worst case
	// the sampler can hand select_lobe.
	const float us[] = { 0.0f, 0.5f, 0.9f, 0.999f, 0.999999f, 0.99999994f };

	int zero_weight_selections = 0;
	// GUARDS THE GUARD. If a future change made the four weights always sum to
	// exactly 1.0f, this case would go on passing while testing nothing -- the
	// unfalsifiable-instrument failure this project has already paid for twice.
	// Counting how many (pSpec, coatMass) pairs actually land in the residue
	// window, and asserting that count is positive, makes the case fail loudly
	// if it ever stops exercising the property it is named for.
	int residue_pairs = 0;

	for (const float *lum : lums) {
		const float p_spec = lobe_weight(lum[0], lum[1]);
		// Swept, not sampled: coat_lobe_weight's clamp range is [0.01, 0.99],
		// and which values inside it produce a short sum is a float-rounding
		// property with no usable closed form.
		for (int ci = 100; ci <= 9900; ci++) {
			const float coat_mass = float(ci) / 10000.0f;
			const float base_share = 1.0f - coat_mass;
			// Built exactly as shade_and_bounce and combined_pdf build them,
			// with sheen_mass == 0 (every material without sheen), so
			// after_sheen is exactly 1.0f and drops out.
			const float weights4[4] = {
				base_share * p_spec,
				base_share * (1.0f - p_spec),
				coat_mass,
				0.0f
			};
			const float acc = (weights4[0] + weights4[1]) + weights4[2];
			if (acc < 0.99999994f) {
				residue_pairs++;
			}
			for (float u : us) {
				const int selected = select_lobe(u, weights4, 4);
				// The general property, deliberately not "selected != 3": it
				// survives a future reordering of the registry.
				if (!(weights4[selected] > 0.0f)) {
					zero_weight_selections++;
				}
			}
		}
	}

	CHECK(zero_weight_selections == 0);
	CHECK(residue_pairs > 0);
}

TEST_CASE("[PathTracer][LobeRegistry] four lobes: the measured residue pair, pinned") {
	// The single (pSpec, coatMass) pair the case above finds first, pinned as a
	// named regression so the failure is readable rather than a count. Values
	// measured in float32, not derived:
	//
	//   p_spec   = lobe_weight(0.04f, 0.5f) = 0.0740740672f
	//   coatMass = 0.0397f
	//   w0 = 0.071133323f  w1 = 0.889166594f  w2 = 0.0397000015f  w3 = 0
	//   w0 + w1 + w2       = 0.999999881f
	//   largest sampler u  = 0.99999994f      (gap 5.96e-08)
	//
	// Pre-repair body: acc never reaches u, the loop stops at p_n - 1, and it
	// returns index 3 with weight 0.
	// Repaired body:   index 3 is skipped as zero-weight and it returns the
	// last non-zero index, 2.
	const float p_spec = lobe_weight(0.04f, 0.5f);
	const float coat_mass = 0.0397f;
	const float base_share = 1.0f - coat_mass;
	const float weights4[4] = {
		base_share * p_spec,
		base_share * (1.0f - p_spec),
		coat_mass,
		0.0f
	};

	// The premise. If float32 rounding ever stopped producing a short sum here
	// the assertion below would become vacuous, so state the premise as its own
	// check rather than trusting it.
	CHECK((weights4[0] + weights4[1]) + weights4[2] < 0.99999994f);

	const int selected = select_lobe(0.99999994f, weights4, 4);
	CHECK(weights4[selected] > 0.0f);
}

} // namespace TestPTLobeRegistry
