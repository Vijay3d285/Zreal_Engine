/**************************************************************************/
/*  test_pt_sheen.cpp                                                     */
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

TEST_FORCE_LINK(test_pt_sheen)

#include "core/math/math_funcs.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"
#include "servers/rendering/renderer_rd/storage_rd/sheen_ltc_table.h"

namespace TestPTSheen {

// CPU mirrors of Cycles' Zeltner sheen
// (intern/cycles/kernel/closure/bsdf_sheen.h:27-110) and its view-dependent
// frame (intern/cycles/kernel/sample/mapping.h:55-68).
//
// THE LUT AXES ARE (cos_NI, roughness). The coat tables in the same SSBO are
// (roughness, mu). Transposed. Both go through a 2D reader with the same
// signature, so a swap is a compile-clean, in-range, wrong-everywhere defect.

// Endpoint-aligned 2D read, identical in shape to the coat's
// (intern/cycles/kernel/util/lookup_table.h:32-46).
static float sheen_lut_read_2d(int p_base, float p_x, float p_y) {
	const int d = SHEEN_LTC_DIM;
	p_y = CLAMP(p_y, 0.0f, 1.0f) * float(d - 1);
	const int yi = MIN(int(p_y), d - 1);
	const int yn = MIN(yi + 1, d - 1);
	const float ty = p_y - float(yi);

	p_x = CLAMP(p_x, 0.0f, 1.0f) * float(d - 1);
	const int xi = MIN(int(p_x), d - 1);
	const int xn = MIN(xi + 1, d - 1);
	const float tx = p_x - float(xi);

	const float r0 = (1.0f - tx) * SHEEN_LTC_TABLE[p_base + d * yi + xi] +
			tx * SHEEN_LTC_TABLE[p_base + d * yi + xn];
	if (ty == 0.0f) {
		return r0;
	}
	const float r1 = (1.0f - tx) * SHEEN_LTC_TABLE[p_base + d * yn + xi] +
			tx * SHEEN_LTC_TABLE[p_base + d * yn + xn];
	return (1.0f - ty) * r0 + ty * r1;
}

struct SheenData {
	Vector3 T, B, N;
	float a = 0.0f, b = 0.0f, albedo = 0.0f;
	bool valid = false;
};

// mapping.h:55-68. The frame is VIEW-DEPENDENT -- nothing else in this BRDF is.
//
// READ THE THRESHOLD CAREFULLY. Cycles normalizes FIRST:
//     *b = safe_normalize(cross(N, T));
//     if (len_squared(*b) < 0.99f) { make_orthonormals(N, a, b); }
// safe_normalize (math_float3.h:527-531) returns the ORIGINAL vector when the
// length is zero, so len_squared(*b) is 1 after a successful normalize and 0
// only when the cross product was exactly zero. The test fires ONLY on true
// degeneracy -- V exactly parallel to N.
//
// Testing the RAW cross product instead would make len_squared = sin^2(theta),
// which is < 0.99 below ~84 degrees, sending nearly every practical view down
// the fallback. An earlier revision of this mirror did exactly that.
static void sheen_make_frame(const Vector3 &p_n, const Vector3 &p_v, Vector3 &r_t, Vector3 &r_b) {
	const Vector3 raw = p_n.cross(p_v);
	const real_t t = raw.length();
	const Vector3 b = (t != 0.0f) ? raw / t : raw; // safe_normalize
	if (b.length_squared() < 0.99f) {
		// Cycles' make_orthonormals, math_float3.h:741-750, verbatim.
		Vector3 a;
		if (p_n.x != p_n.y || p_n.x != p_n.z) {
			a = Vector3(p_n.z - p_n.y, p_n.x - p_n.z, p_n.y - p_n.x); // (1,1,1) x N
		} else {
			a = Vector3(p_n.z - p_n.y, p_n.x + p_n.z, -p_n.y - p_n.x); // (-1,1,1) x N
		}
		r_t = a.normalized();
		r_b = p_n.cross(r_t);
		return;
	}
	r_b = b;
	r_t = r_b.cross(p_n);
}

static SheenData sheen_setup(const Vector3 &p_n, const Vector3 &p_v, float p_roughness) {
	SheenData d;
	d.N = p_n;
	sheen_make_frame(p_n, p_v, d.T, d.B);
	const float rough = CLAMP(p_roughness, 1e-3f, 1.0f);
	const float cos_ni = p_n.dot(p_v);
	d.a = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, cos_ni, rough);
	d.b = sheen_lut_read_2d(SHEEN_LTC_B_OFFSET, cos_ni, rough);
	d.albedo = sheen_lut_read_2d(SHEEN_LTC_ALBEDO_OFFSET, cos_ni, rough);
	// bsdf_sheen.h:44-49 -- the closure is dropped, not merely dimmed.
	d.valid = !(Math::abs(d.a) < 1e-5f || d.albedo < 1e-5f);
	return d;
}

// bsdf_sheen.h:70-74. pdf and eval are THE SAME VALUE -- the LTC is perfectly
// importance-sampled, so the sample weight is exactly 1.
static float sheen_eval(const SheenData &p_d, const Vector3 &p_l) {
	const Vector3 lo(p_l.dot(p_d.T), p_l.dot(p_d.B), p_l.dot(p_d.N));
	const float len_sqr = (p_d.a * lo.x + p_d.b * lo.z) * (p_d.a * lo.x + p_d.b * lo.z) +
			(p_d.a * lo.y) * (p_d.a * lo.y) + lo.z * lo.z;
	const float q = p_d.a / len_sqr;
	return (1.0f / float(Math::PI)) * MAX(lo.z, 0.0f) * q * q;
}

// mapping.h:21-41. Concentric (Shirley-Chiu) square-to-disk mapping -- NOT the
// naive r=sqrt(u1), phi=TAU*u2 polar mapping an earlier revision of this
// mirror used. Both are unbiased samplers of the unit disk and pdf == eval is
// invariant to which one is used (the pdf formula reacts to where lo lands,
// not the u1/u2 -> lo map that got it there), so the deviation was harmless
// to this file's own tests. It is matched to Cycles anyway because Task 3 may
// lift this straight into the GLSL sampler, where "equivalent enough" is not
// the bar -- matching the reference is.
static Vector2 sheen_sample_uniform_disk(float p_u1, float p_u2) {
	const float a = 2.0f * p_u1 - 1.0f;
	const float b = 2.0f * p_u2 - 1.0f;
	if (a == 0.0f && b == 0.0f) {
		return Vector2(0.0f, 0.0f);
	}
	float r, phi;
	if (a * a > b * b) {
		r = a;
		phi = (float(Math::PI) / 4.0f) * (b / a);
	} else {
		r = b;
		phi = (float(Math::PI) / 2.0f) - (float(Math::PI) / 4.0f) * (a / b);
	}
	return Vector2(r * Math::cos(phi), r * Math::sin(phi));
}

// bsdf_sheen.h:83-99. Returns the direction AND the pdf, because Cycles does
// (`*pdf = val; *eval = make_spectrum(val);` at :97-99) and because a sampler
// that returns only a direction cannot be checked against the evaluator.
static Vector3 sheen_sample(const SheenData &p_d, float p_u1, float p_u2, float &r_pdf) {
	const Vector2 disk = sheen_sample_uniform_disk(p_u1, p_u2);
	const float diskZ = Math::sqrt(MAX(0.0f, 1.0f - (disk.x * disk.x + disk.y * disk.y)));
	Vector3 lo(disk.x - diskZ * p_d.b, disk.y, diskZ * p_d.a);
	lo.normalize();
	// The sampler's OWN pdf expression, from its own localO -- not a call into
	// sheen_eval. Keeping them separate is what makes the identity testable.
	const float len_sqr = (p_d.a * lo.x + p_d.b * lo.z) * (p_d.a * lo.x + p_d.b * lo.z) +
			(p_d.a * lo.y) * (p_d.a * lo.y) + lo.z * lo.z;
	const float q = p_d.a / len_sqr;
	r_pdf = (1.0f / float(Math::PI)) * lo.z * q * q;
	return p_d.T * lo.x + p_d.B * lo.y + p_d.N * lo.z;
}

TEST_CASE("[PathTracer][Sheen] the table is the one Cycles ships") {
	// Guards a re-extraction silently pulling a different or truncated table.
	// Values read directly out of shader.tables at these indices.
	CHECK(SHEEN_LTC_DIM == 32);
	CHECK(SHEEN_LTC_A_OFFSET == 0);
	CHECK(SHEEN_LTC_B_OFFSET == 1024);
	CHECK(SHEEN_LTC_ALBEDO_OFFSET == 2048);

	// Measured directly from shader.tables (all 1024 values per block):
	//   transformA in [0.0,      0.87958]
	//   transformB in [-0.18133, 0.00196]
	//   albedo     in [0.0,      0.74973]
	// transformA and albedo are BOTH entirely non-negative and BOTH bounded
	// within [0, 1] -- an "is this a plausible albedo" in-range check cannot
	// tell those two blocks apart from each other, only from transformB
	// (the only block that ever goes negative). An A<->albedo swap would
	// pass an in-range-only check silently; this is why Fix round 1 flagged
	// the original version of this test.
	bool a_has_negative = false;
	bool b_has_negative = false;
	bool albedo_has_negative = false;
	for (int i = 0; i < 1024; i++) {
		CAPTURE(i);
		const float av = SHEEN_LTC_TABLE[SHEEN_LTC_A_OFFSET + i];
		const float bv = SHEEN_LTC_TABLE[SHEEN_LTC_B_OFFSET + i];
		const float alv = SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + i];
		if (av < 0.0f) {
			a_has_negative = true;
		}
		if (bv < 0.0f) {
			b_has_negative = true;
		}
		if (alv < 0.0f) {
			albedo_has_negative = true;
		}
		// Still worth keeping: albedo must be <= 1 everywhere (a real
		// property of an albedo, even though it does not discriminate
		// against transformA alone).
		CHECK(alv <= 1.0f);
	}
	CHECK(b_has_negative); // only transformB goes negative
	CHECK_FALSE(a_has_negative);
	CHECK_FALSE(albedo_has_negative);

	// A and albedo, told apart from EACH OTHER by literal pinned values at a
	// raw (non-interpolated) table index -- an A<->albedo block swap puts
	// the wrong number at this index, which the sign/range checks above
	// cannot catch since both blocks are non-negative and <= 1 throughout.
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_A_OFFSET + 32] == doctest::Approx(0.01941f).epsilon(1e-4));
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_B_OFFSET + 32] == doctest::Approx(-0.00232f).epsilon(1e-4));
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + 32] == doctest::Approx(0.05839f).epsilon(1e-4));
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_A_OFFSET + 32] != SHEEN_LTC_TABLE[SHEEN_LTC_B_OFFSET + 32]);
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_A_OFFSET + 32] != SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + 32]);
	CHECK(SHEEN_LTC_TABLE[SHEEN_LTC_B_OFFSET + 32] != SHEEN_LTC_TABLE[SHEEN_LTC_ALBEDO_OFFSET + 32]);
}

TEST_CASE("[PathTracer][Sheen] the LUT axes are (cos_NI, roughness), not the transpose") {
	// THE case this file exists for. Read at a point where the two orders give
	// different answers, and assert they differ -- a probe on the diagonal
	// (cos_ni == roughness) cannot tell them apart and would pass either way.
	const float cos_ni = 0.2f;
	const float rough = 0.8f;
	const float correct = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, cos_ni, rough);
	const float transposed = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, rough, cos_ni);
	CHECK(correct != transposed);
	// And pin the magnitude of the confusion, so this cannot pass on two values
	// that merely differ in the last bit.
	CHECK(Math::abs(correct - transposed) > 0.01f);

	// The diagonal is where the two orders agree, and it is WHY the probe
	// above sits at (0.2, 0.8) instead: at cos_ni == roughness, swapping the
	// arguments reads the identical point, so "correct" and "transposed" are
	// not two different reads here -- they are the same call written twice.
	// (An earlier revision of this test called sheen_lut_read_2d twice with
	// literally identical arguments and asserted equality, which is true of
	// any deterministic function and proves nothing; this version keeps the
	// swap explicit so the no-op is visible instead of hidden.)
	const float diag_correct = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, 0.5f, 0.5f);
	const float diag_transposed = sheen_lut_read_2d(SHEEN_LTC_A_OFFSET, 0.5f, 0.5f); // x==y: swap is a no-op
	CHECK(diag_correct == diag_transposed);
}

TEST_CASE("[PathTracer][Sheen] pdf equals eval, exactly") {
	// The LTC is perfectly importance-sampled. This is a free instrument: any
	// transcription slip that breaks the identity is caught with no GPU.
	// Asserted with == because they are literally the same expression in
	// Cycles (bsdf_sheen.h:73-74), not two computations that happen to agree.
	const Vector3 n(0.0f, 0.0f, 1.0f);
	const Vector3 v = Vector3(0.4f, 0.1f, 0.9f).normalized();
	const SheenData d = sheen_setup(n, v, 0.5f);
	REQUIRE(d.valid);

	for (int i = 1; i <= 8; i++) {
		for (int j = 1; j <= 8; j++) {
			const float u1 = float(i) / 9.0f;
			const float u2 = float(j) / 9.0f;
			CAPTURE(u1);
			CAPTURE(u2);
			float sample_pdf = 0.0f;
			const Vector3 l = sheen_sample(d, u1, u2, sample_pdf);
			const float eval_val = sheen_eval(d, l);

			// The real property: the SAMPLER's pdf, computed from its own
			// local-frame direction, equals the EVALUATOR's value for the same
			// world direction. Two independent code paths, one number.
			//
			// Approx, not ==, and the reason is specific: the sampler builds
			// localO directly, while the evaluator receives the world-space
			// direction and projects it back onto the frame. That round trip
			// costs a few ulp. The tolerance measures the round trip, it does
			// not hide a discrepancy -- 1e-5 is far tighter than any real
			// transcription error would be.
			CHECK(eval_val > 0.0f);
			CHECK(sample_pdf == doctest::Approx(eval_val).epsilon(1e-5));
		}
	}

	// Prove the case can fail: two different draws must give different pdfs,
	// so the assertion above is not trivially satisfied by a constant.
	float pdf_a = 0.0f;
	float pdf_b = 0.0f;
	const Vector3 la = sheen_sample(d, 0.2f, 0.3f, pdf_a);
	const Vector3 lb = sheen_sample(d, 0.8f, 0.7f, pdf_b);
	CHECK(la != lb);
	CHECK(Math::abs(pdf_a - pdf_b) > 1e-6f);
}

TEST_CASE("[PathTracer][Sheen] the view-dependent frame is orthonormal and V-aligned") {
	const Vector3 n(0.0f, 0.0f, 1.0f);
	// V MUST have a nonzero y component. Fix round 1 found that the original
	// V=(0.6,0,0.8) has y==0, and for any V confined to the xz-plane,
	// cross(N,V) has zero y-component under BOTH the fallback and a correct
	// view-dependent read -- so v.dot(b) == 0 held vacuously and this case
	// was passing through the (buggy, at the time) fallback branch without
	// ever exercising the view-dependent path it claims to test.
	const Vector3 v = Vector3(0.5f, 0.3f, 0.8f).normalized();
	Vector3 t, b;
	sheen_make_frame(n, v, t, b);
	CHECK(t.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(b.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(t.dot(b) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(t.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(b.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	// B is perpendicular to the view plane, so V has no B component. This is
	// what makes the frame view-dependent rather than arbitrary -- a frame that
	// ignored V would fail here.
	CHECK(Math::abs(v.dot(b)) < 1e-5f);

	// Prove this actually took the NON-fallback branch, not merely that the
	// resulting frame happens to be orthonormal (the fallback is orthonormal
	// too). The fallback frame for N ignores V entirely, so if V's
	// contribution were being silently dropped, (t, b) here would equal the
	// fallback's (t, b) for this same N.
	Vector3 fallback_t, fallback_b;
	sheen_make_frame(n, n, fallback_t, fallback_b);
	CHECK((t - fallback_t).length() > 0.01f);
	CHECK((b - fallback_b).length() > 0.01f);
}

TEST_CASE("[PathTracer][Sheen] the degenerate frame fallback fires at normal incidence") {
	// V parallel to N is the centre of every sphere facing camera, not an
	// exotic corner. cross(N, V) is zero there, and the frame must still come
	// out orthonormal rather than NaN.
	const Vector3 n(0.0f, 0.0f, 1.0f);
	Vector3 t, b;
	sheen_make_frame(n, n, t, b);
	CHECK(t.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(b.length() == doctest::Approx(1.0f).epsilon(1e-5));
	CHECK(t.dot(b) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(t.dot(n) == doctest::Approx(0.0f).epsilon(1e-5));
	CHECK(!Math::is_nan(t.x));
	CHECK(!Math::is_nan(b.x));

	// Not just "orthonormal" -- equals what Cycles' make_orthonormals
	// actually produces for this N, computed inline from the same formula
	// (math_float3.h:724-750) rather than hardcoded, so this fails if the
	// (1,1,1)xN / (-1,1,1)xN branch selection or the a/b roles get swapped.
	Vector3 expected_a;
	if (n.x != n.y || n.x != n.z) {
		expected_a = Vector3(n.z - n.y, n.x - n.z, n.y - n.x);
	} else {
		expected_a = Vector3(n.z - n.y, n.x + n.z, -n.y - n.x);
	}
	expected_a.normalize();
	const Vector3 expected_b = n.cross(expected_a);
	CHECK((t - expected_a).length() < 1e-5f);
	CHECK((b - expected_b).length() < 1e-5f);

	// And the sheen still evaluates finitely through that frame.
	const SheenData d = sheen_setup(n, n, 0.5f);
	if (d.valid) {
		float pdf = 0.0f;
		const Vector3 l = sheen_sample(d, 0.5f, 0.5f, pdf);
		CHECK(!Math::is_nan(sheen_eval(d, l)));
		CHECK(!Math::is_nan(pdf));
	}
}

TEST_CASE("[PathTracer][Sheen] the invalid-LTC skip is reachable and drops the closure") {
	// Cycles sets CLOSURE_NONE_ID and sample_weight = 0 when |a| < 1e-5 or
	// albedo < 1e-5 (bsdf_sheen.h:44-49). If no input in the legal domain can
	// trigger it, the branch is dead and this test says so instead of pretending
	// to cover it.
	int invalid_count = 0;
	for (int i = 0; i <= 32; i++) {
		for (int j = 0; j <= 32; j++) {
			const float cos_ni = float(i) / 32.0f;
			const float rough = float(j) / 32.0f;
			const Vector3 n(0.0f, 0.0f, 1.0f);
			const Vector3 v = Vector3(Math::sqrt(MAX(0.0f, 1.0f - cos_ni * cos_ni)), 0.0f, cos_ni).normalized();
			if (!sheen_setup(n, v, rough).valid) {
				invalid_count++;
			}
		}
	}
	// Report the count rather than asserting a specific number: what matters is
	// that the guard is not decorative. Grazing incidence is where it fires.
	CAPTURE(invalid_count);
	CHECK(invalid_count > 0);
}

} // namespace TestPTSheen
