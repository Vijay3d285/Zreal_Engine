/**************************************************************************/
/*  test_pt_emissive.cpp                                                  */
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

TEST_FORCE_LINK(test_pt_emissive)

#include "core/math/math_funcs.h"
#include "core/math/transform_3d.h"
#include "core/math/vector3.h"
#include "core/templates/hashfuncs.h"

#include <algorithm>
#include <vector>

namespace TestPTEmissive {

// CPU mirrors of the emissive-light sampling maths in
// servers/rendering/renderer_rd/shaders/raytracing/raytracing_vertex_inc.glsl and
// raytracing_emissive_inc.glsl.
//
// STANDING CAVEAT: the doctest binary never executes GLSL. Every case here would
// still pass if the shaders were reverted and these mirrors left untouched. The
// evidence that the SHADERS are right is pipeline_references/tests/pt_emissive_gate.gd,
// which renders real frames and asserts that enabling emissive NEE does not move
// the converged mean.

// Mirror of the COMPRESSED branch of rt_fetch_vertex_position(). Compressed
// vertices are four uint16 across two words: x | (y << 16) in word 0, z in the
// low half of word 1 (the high half is the tangent angle -- see
// fetch_tbn_compressed_vertex, which reads exactly that word). Normalised to [0,1]
// and mapped through the mesh AABB.
static Vector3 mirror_decode_compressed_position(uint32_t p_word0, uint32_t p_word1,
		const Vector3 &p_aabb_pos, const Vector3 &p_aabb_size) {
	const Vector3 n(
			float(p_word0 & 0xFFFFu) / 65535.0f,
			float(p_word0 >> 16) / 65535.0f,
			float(p_word1 & 0xFFFFu) / 65535.0f);
	return Vector3(
			p_aabb_pos.x + n.x * p_aabb_size.x,
			p_aabb_pos.y + n.y * p_aabb_size.y,
			p_aabb_pos.z + n.z * p_aabb_size.z);
}

// Mirror of the UNCOMPRESSED branch of rt_fetch_vertex_position(). p_position_stride
// is in BYTES (matches GeometryData::position_stride); the shader converts it to a
// float-element stride via `>> 2` before indexing. The engine's REAL value here is
// 12 (sizeof(float)*3): the standard non-2D uncompressed case, confirmed at
// render_raytracing.cpp:838 (per-surface RT_GeometryData fill) and :2154 (merged
// multimesh buffer, commented "float3, uncompressed"). It also emits 8
// (sizeof(float)*2) for ARRAY_FLAG_USE_2D_VERTICES surfaces (render_raytracing.cpp:656,
// 834) -- not exercised here. Any OTHER stride used below (e.g. one wider than a
// tightly-packed float3, as if extra attributes were interleaved after the
// position) is synthetic: it exists only to exercise the `>> 2` conversion and the
// per-vertex indexing arithmetic independently of the real value, not as a claim
// about what the engine emits.
static Vector3 mirror_decode_uncompressed_position(const std::vector<float> &p_buffer,
		uint32_t p_index, uint32_t p_position_stride_bytes) {
	const uint32_t stride_floats = p_position_stride_bytes >> 2;
	const uint32_t base = p_index * stride_floats;
	return Vector3(p_buffer[base + 0], p_buffer[base + 1], p_buffer[base + 2]);
}

// Mirror of the world-space triangle area used by the area-reduction pass.
static float mirror_triangle_area_world(const Transform3D &p_xform,
		const Vector3 &p0, const Vector3 &p1, const Vector3 &p2) {
	const Vector3 w0 = p_xform.xform(p0);
	const Vector3 w1 = p_xform.xform(p1);
	const Vector3 w2 = p_xform.xform(p2);
	return 0.5f * (w1 - w0).cross(w2 - w0).length();
}

TEST_CASE("[PathTracer][Emissive] compressed position decode spans the AABB") {
	const Vector3 aabb_pos(-2.0f, 5.0f, 0.25f);
	const Vector3 aabb_size(4.0f, 1.0f, 8.0f);

	// All-zero words -> the AABB minimum corner.
	CHECK(mirror_decode_compressed_position(0u, 0u, aabb_pos, aabb_size)
					.is_equal_approx(aabb_pos));
	// Saturated words -> the maximum corner.
	const Vector3 hi = mirror_decode_compressed_position(0xFFFFFFFFu, 0x0000FFFFu, aabb_pos, aabb_size);
	CHECK(hi.is_equal_approx(aabb_pos + aabb_size));

	// The tangent angle lives in the HIGH half of word 1 and must not leak into z.
	// Without the & 0xFFFF mask, z would read ~65535/65535 instead of 0.
	const Vector3 z_zero = mirror_decode_compressed_position(0u, 0xFFFF0000u, aabb_pos, aabb_size);
	CHECK(z_zero.z == doctest::Approx(aabb_pos.z));
}

TEST_CASE("[PathTracer][Emissive] compressed decode keeps x, y and z distinct") {
	// Every earlier case sets x == y (both 0, or both saturated), so a decode
	// with x and y swapped would pass all of them. Distinct non-extremal values
	// in all three components are what actually pin the word layout.
	const Vector3 aabb_pos(-2.0f, 5.0f, 0.25f);
	const Vector3 aabb_size(4.0f, 1.0f, 8.0f);

	const uint32_t xu = 16384u; // ~0.25
	const uint32_t yu = 49151u; // ~0.75
	const uint32_t zu = 32768u; // ~0.50
	const uint32_t tangent = 0x1234u; // high half of word 1: must not reach z
	const uint32_t w0 = xu | (yu << 16);
	const uint32_t w1 = zu | (tangent << 16);

	const Vector3 p = mirror_decode_compressed_position(w0, w1, aabb_pos, aabb_size);
	CHECK(p.x == doctest::Approx(aabb_pos.x + (float(xu) / 65535.0f) * aabb_size.x));
	CHECK(p.y == doctest::Approx(aabb_pos.y + (float(yu) / 65535.0f) * aabb_size.y));
	CHECK(p.z == doctest::Approx(aabb_pos.z + (float(zu) / 65535.0f) * aabb_size.z));
}

TEST_CASE("[PathTracer][Emissive] uncompressed position decode respects stride and index") {
	// Real engine stride: 12 bytes (float3) -- see the mirror's comment above
	// for the render_raytracing.cpp citations. A second, larger, SYNTHETIC
	// stride (20 bytes / 5 floats, as if extra interleaved data followed the
	// position) checks the `>> 2` conversion and indexing arithmetic
	// independently of the real value; it is not a claim about what the engine
	// emits. Both sub-cases use a vertex index > 0 -- a stride bug is invisible
	// at index 0 regardless of the stride, and a `>> 2` bug is invisible if
	// every stride tested is the same.
	{
		// stride 12 (3 floats/vertex), vertex index 2.
		std::vector<float> buf = {
			0.0f, 0.0f, 0.0f, // vertex 0 (unused)
			0.0f, 0.0f, 0.0f, // vertex 1 (unused)
			1.5f, -2.5f, 3.25f, // vertex 2 -- the one under test
		};
		const Vector3 p = mirror_decode_uncompressed_position(buf, 2u, 12u);
		CHECK(p.is_equal_approx(Vector3(1.5f, -2.5f, 3.25f)));
	}
	{
		// stride 20 (5 floats/vertex: 3 position + 2 padding), vertex index 1.
		std::vector<float> buf = {
			10.0f, 20.0f, 30.0f, 99.0f, 99.0f, // vertex 0 (unused, w/ padding)
			4.0f, 5.0f, 6.0f, 99.0f, 99.0f, // vertex 1 -- the one under test
		};
		const Vector3 p = mirror_decode_uncompressed_position(buf, 1u, 20u);
		CHECK(p.is_equal_approx(Vector3(4.0f, 5.0f, 6.0f)));
	}
}

TEST_CASE("[PathTracer][Emissive] world area is correct under NON-UNIFORM scale") {
	// The "object-space area x s^2" shortcut is only valid under uniform scale.
	// This case has three distinct scale factors AND a rotation, so a shortcut
	// implementation cannot pass it.
	const Vector3 p0(0, 0, 0), p1(1, 0, 0), p2(0, 1, 0);
	CHECK(mirror_triangle_area_world(Transform3D(), p0, p1, p2) == doctest::Approx(0.5f));

	Transform3D scaled;
	scaled.basis.scale(Vector3(2.0f, 3.0f, 5.0f));
	// The triangle lies in the XY plane, so only x and y scaling affect its area.
	CHECK(mirror_triangle_area_world(scaled, p0, p1, p2) == doctest::Approx(0.5f * 2.0f * 3.0f));

	// Rotate FIRST, then scale non-uniformly: S*R tilts the triangle out of the
	// XY plane and only then stretches it, so the z scale participates and no
	// per-axis shortcut reproduces the answer. (R*S would be a rigid rotation
	// applied after the scale, which preserves area and would leave this at 3.)
	Transform3D rotated = scaled;
	rotated.basis = scaled.basis * Basis(Vector3(1, 0, 0), Math::PI / 4.0f);
	const float a = mirror_triangle_area_world(rotated, p0, p1, p2);
	CHECK(a > 0.0f);
	CHECK(a != doctest::Approx(0.5f * 2.0f * 3.0f));
	// Pinned to the closed form: the legs become S*R*(1,0,0) = (2,0,0) and
	// S*R*(0,1,0) = (0, 3*sqrt(2)/2, 5*sqrt(2)/2), whose cross product has
	// length sqrt(2)*sqrt(34) = sqrt(68). Half of that is the area. An
	// inequality alone would also pass on a wrong-but-different answer.
	CHECK(a == doctest::Approx(0.5f * Math::sqrt(68.0f)));
}

TEST_CASE("[PathTracer][Emissive] a degenerate triangle has zero area") {
	const Vector3 p(1.0f, 2.0f, 3.0f);
	CHECK(mirror_triangle_area_world(Transform3D(), p, p, p) == doctest::Approx(0.0f));
	// Collinear, not coincident -- the cross product must still vanish.
	CHECK(mirror_triangle_area_world(Transform3D(), Vector3(0, 0, 0), Vector3(1, 1, 1), Vector3(2, 2, 2))
					== doctest::Approx(0.0f));
}

// ---------------------------------------------------------------------------
// C1 Task 3: the emissive-instance distribution.
// ---------------------------------------------------------------------------

static const uint32_t MAT_FLAG_HAS_EMISSION_TEX = 2u;
static const uint32_t EMISSIVE_INSTANCES_MAX = 256;

static float mirror_luminance(const Vector3 &p_c) {
	return p_c.x * 0.2126f + p_c.y * 0.7152f + p_c.z * 0.0722f;
}

// Mirror of the CPU-side qualification test in gather_emissive_instances().
static bool mirror_is_emissive(uint32_t p_flags, const Vector3 &p_emission_color, float p_strength) {
	if ((p_flags & MAT_FLAG_HAS_EMISSION_TEX) != 0u) {
		return true;
	}
	return mirror_luminance(p_emission_color) * p_strength > 1e-4f;
}

static const uint32_t GEOM_FLAG_COMPRESSED = 1u;
static const uint32_t GEOM_FLAG_PROCEDURAL = 2u;
static const uint32_t GEOM_FLAG_DEFORMED = 4u;

// Mirror of the GEOMETRY-side exclusions in gather_emissive_instances(), which
// run before the material qualification above. Three separate reasons, and the
// bits are adjacent, so a mask typo silently swaps one exclusion for another.
static bool mirror_geometry_eligible(uint32_t p_geom_flags, uint32_t p_prim_count) {
	if ((p_geom_flags & GEOM_FLAG_PROCEDURAL) != 0u) {
		return false; // No triangles: the vertex address points at AABB data.
	}
	if (p_prim_count == 0u) {
		return false;
	}
	// Deformed geometry is excluded on purpose: its area would go stale (the
	// rebuild token does not cover vertex data), and a stale area is a BIASED
	// pdf. Absent from the distribution is unbiased -- slot stays -1, NEE never
	// selects it, and MIS gives the BSDF ray full weight.
	if ((p_geom_flags & GEOM_FLAG_DEFORMED) != 0u) {
		return false;
	}
	return true;
}

// Mirror of the two-sided power computation for one emissive instance.
//
// This spans a C++/GLSL boundary and neither side alone is meaningful:
// gather_emissive_instances() folds emission_strength INTO the uploaded colour
// (`emission = emission_color * emission_strength`), and only then does
// emissive_area_build.glsl's MODE_AREA take the luminance of that product and
// multiply by the reduced world area (`power = max(lum, 0) * area`). The strength
// therefore reaches `power` solely through the C++ fold -- dropping it leaves a
// shader that still compiles, a distribution that is still internally consistent,
// and every emitter's power wrong by a factor of `strength`.
static float mirror_instance_power(const Vector3 &p_emission_color, float p_strength, float p_area) {
	const Vector3 folded(
			p_emission_color.x * p_strength,
			p_emission_color.y * p_strength,
			p_emission_color.z * p_strength);
	return MAX(mirror_luminance(folded), 0.0f) * p_area;
}

// Mirror of the CDF walk in emissive_select_instance(). Returns the selected
// slot and rescales the remainder within its bucket to [0,1) for the triangle
// draw. r_remap MUST span the full unit interval across a bucket or the
// triangle choice becomes correlated with the instance choice.
static bool mirror_select_instance(const std::vector<float> &p_cdf, float p_total,
		float p_u, uint32_t &r_slot, float &r_prob, float &r_remap) {
	r_slot = 0;
	r_prob = 0.0f;
	r_remap = 0.0f;
	if (!(p_total > 0.0f) || p_cdf.empty()) {
		return false;
	}
	const float target = p_u * p_total;
	float lo = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_cdf.size(); i++) {
		const float hi = p_cdf[i];
		const float w = hi - lo;
		if (w > 0.0f && target < hi) {
			r_slot = i;
			r_prob = w / p_total;
			r_remap = CLAMP((target - lo) / w, 0.0f, 0.99999994f);
			return true;
		}
		lo = hi;
	}
	// Drift guard: fall back to the last positive-weight bucket.
	lo = 0.0f;
	for (uint32_t i = 0; i < (uint32_t)p_cdf.size(); i++) {
		const float w = p_cdf[i] - lo;
		if (w > 0.0f) {
			r_slot = i;
			r_prob = w / p_total;
			r_remap = 0.0f;
		}
		lo = p_cdf[i];
	}
	return r_prob > 0.0f;
}

// Mirror of the object->world transform gather_emissive_instances() uploads per
// instance. This is NOT simply blas_transforms[i].
//
// For a COMPRESSED surface the BLAS is built on the raw UNORM16 vertex data, so
// its coordinates live in the mesh's normalised [0,1]^3 box and the TLAS instance
// transform carries the AABB de-normalisation:
//     blas_transform = instance * aabb        (render_raytracing.cpp:2514, :2668)
// But rt_fetch_vertex_position() already applies `aabb` itself on the compressed
// branch (raytracing_vertex_inc.glsl, via get_aabb_compression_xforms), so it
// returns OBJECT space. Handing the compute pass blas_transform would therefore
// apply the AABB scale and offset TWICE and inflate every compressed emitter's
// area by the AABB volume factor. The transform that maps
// rt_fetch_vertex_position()'s output to world is blas_transform * aabb^-1.
//
// For an uncompressed surface the engine writes aabb_size = (1,1,1) and
// aabb_pos = (0,0,0) (render_raytracing.cpp:885-892), so `aabb` is the identity
// and the correction is a no-op -- which is exactly why a suite that only ever
// tested uncompressed geometry would not notice the bug.
static Transform3D mirror_object_to_world(const Transform3D &p_blas_xform, bool p_compressed,
		const Vector3 &p_aabb_pos, const Vector3 &p_aabb_size) {
	if (!p_compressed) {
		return p_blas_xform;
	}
	Transform3D aabb;
	aabb.basis = Basis::from_scale(p_aabb_size);
	aabb.origin = p_aabb_pos;
	return p_blas_xform * aabb.affine_inverse();
}

TEST_CASE("[PathTracer][Emissive] qualification covers textured and coloured emitters") {
	// A texture-only emitter has emission_color forced to (1,1,1) and strength 1
	// by the C++ material fill, but qualification must not depend on that -- an
	// emitter whose colour is black and whose light comes entirely from a texture
	// must still qualify, or its energy is silently lost.
	CHECK(mirror_is_emissive(MAT_FLAG_HAS_EMISSION_TEX, Vector3(0, 0, 0), 0.0f));
	CHECK(mirror_is_emissive(0u, Vector3(1, 1, 1), 1.0f));
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(1, 1, 1), 0.0f));
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(0, 0, 0), 100.0f));
	// Just under and just over the 1e-4 threshold on luminance x strength.
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(1, 1, 1), 5e-5f));
	CHECK(mirror_is_emissive(0u, Vector3(1, 1, 1), 5e-4f));
	// The luminance weights are per-channel and must not be interchangeable: a
	// pure-blue emitter is 0.0722 of a pure-green one, so a swapped or averaged
	// weight vector changes which side of the threshold each lands on.
	CHECK(mirror_is_emissive(0u, Vector3(0, 1, 0), 2e-4f)); // 0.7152 * 2e-4 > 1e-4
	CHECK_FALSE(mirror_is_emissive(0u, Vector3(0, 0, 1), 2e-4f)); // 0.0722 * 2e-4 < 1e-4
}

TEST_CASE("[PathTracer][Emissive] geometry exclusions are by flag, not by accident") {
	// An ordinary static emitter with triangles is the only eligible shape.
	CHECK(mirror_geometry_eligible(0u, 12u));
	// COMPRESSED is NOT an exclusion -- compressed emitters are fully supported,
	// they just need the aabb^-1 correction (see the transform case below). This
	// is the assertion that stops someone widening the mask to "any flag set".
	CHECK(mirror_geometry_eligible(GEOM_FLAG_COMPRESSED, 12u));

	// Procedural: no triangles to integrate over.
	CHECK_FALSE(mirror_geometry_eligible(GEOM_FLAG_PROCEDURAL, 12u));
	// Deformed: excluded to avoid a stale total_area, which would be a biased pdf.
	CHECK_FALSE(mirror_geometry_eligible(GEOM_FLAG_DEFORMED, 12u));
	// A compressed mesh that also deforms is still excluded -- the deformed bit
	// must be tested independently, not as an equality against the whole word.
	CHECK_FALSE(mirror_geometry_eligible(GEOM_FLAG_COMPRESSED | GEOM_FLAG_DEFORMED, 12u));

	// Zero primitives is its own exclusion, independent of any flag: it must bite
	// on otherwise-eligible geometry too, or an empty surface reaches the area
	// pass and dispatches a workgroup that reduces to zero.
	CHECK_FALSE(mirror_geometry_eligible(0u, 0u));
	CHECK_FALSE(mirror_geometry_eligible(GEOM_FLAG_COMPRESSED, 0u));
}

TEST_CASE("[PathTracer][Emissive] power folds in strength, area and the luma weights") {
	// Every input is deliberately non-unit and the colour is non-uniform across
	// channels, so no factor can hide inside another: strength 1 would hide the
	// fold, area 1 would hide the area, and a grey colour would let any luma
	// weighting pass.
	const Vector3 color(0.2f, 0.6f, 0.9f);
	const float strength = 3.5f;
	const float area = 2.75f;

	const float expected_lum = 0.2f * 0.2126f + 0.6f * 0.7152f + 0.9f * 0.0722f;
	CHECK(mirror_instance_power(color, strength, area)
					== doctest::Approx(expected_lum * strength * area));

	// THE REGRESSION THIS CASE EXISTS FOR: if the C++ fold is dropped and the
	// shader takes the luminance of the raw colour, power loses exactly a factor
	// of `strength`. Pin that the two differ, and by how much.
	const float unfolded = MAX(mirror_luminance(color), 0.0f) * area;
	CHECK(unfolded != doctest::Approx(mirror_instance_power(color, strength, area)));
	CHECK(mirror_instance_power(color, strength, area) == doctest::Approx(unfolded * strength));

	// Power is linear in each factor independently.
	CHECK(mirror_instance_power(color, strength * 2.0f, area)
					== doctest::Approx(2.0f * mirror_instance_power(color, strength, area)));
	CHECK(mirror_instance_power(color, strength, area * 3.0f)
					== doctest::Approx(3.0f * mirror_instance_power(color, strength, area)));

	// The channel weights must be the real ones, not interchangeable: the same
	// energy moved from blue to green is over nine times the power.
	const float green = mirror_instance_power(Vector3(0, 1, 0), strength, area);
	const float blue = mirror_instance_power(Vector3(0, 0, 1), strength, area);
	CHECK(green == doctest::Approx(0.7152f * strength * area));
	CHECK(blue == doctest::Approx(0.0722f * strength * area));
	CHECK(green > blue * 9.0f);

	// A zero-area instance contributes nothing however bright, and a black
	// emitter contributes nothing however large -- both are the CDF's zero-width
	// bucket case, which selection must never return.
	CHECK(mirror_instance_power(color, strength, 0.0f) == doctest::Approx(0.0f));
	CHECK(mirror_instance_power(Vector3(0, 0, 0), strength, area) == doctest::Approx(0.0f));

	// Negative emission is clamped rather than subtracting power from the total,
	// which would corrupt the prefix sum into a non-monotonic CDF.
	CHECK(mirror_instance_power(Vector3(-1.0f, -1.0f, -1.0f), strength, area) == doctest::Approx(0.0f));
}

TEST_CASE("[PathTracer][Emissive] instance selection frequency matches power") {
	// Prefix sums of powers {1, 7, 0, 2}: a zero-power instance must never be
	// selected, and the rest in proportion.
	std::vector<float> cdf = { 1.0f, 8.0f, 8.0f, 10.0f };
	const float total = 10.0f;

	const int N = 100000;
	int counts[4] = { 0, 0, 0, 0 };
	for (int i = 0; i < N; i++) {
		const float u = (float(i) + 0.5f) / float(N);
		uint32_t slot = 0;
		float prob = 0.0f, remap = 0.0f;
		REQUIRE(mirror_select_instance(cdf, total, u, slot, prob, remap));
		REQUIRE(slot < 4);
		counts[slot]++;
		CHECK(prob > 0.0f);
		CHECK(remap >= 0.0f);
		CHECK(remap < 1.0f);
	}
	CHECK(counts[2] == 0);
	CHECK(float(counts[0]) / float(N) == doctest::Approx(0.1f).epsilon(0.005));
	CHECK(float(counts[1]) / float(N) == doctest::Approx(0.7f).epsilon(0.005));
	CHECK(float(counts[3]) / float(N) == doctest::Approx(0.2f).epsilon(0.005));
}

TEST_CASE("[PathTracer][Emissive] the bucket remainder spans the unit interval") {
	// If the remap does not cover [0,1), the triangle drawn from it is correlated
	// with WHICH instance was picked -- a whole region of triangles becomes
	// unreachable on some instances. Sweep one bucket and check coverage.
	std::vector<float> cdf = { 1.0f, 8.0f, 10.0f };
	const float total = 10.0f;

	float lo_seen = 1.0f, hi_seen = 0.0f;
	int in_bucket = 0;
	for (int i = 0; i < 20000; i++) {
		const float u = (float(i) + 0.5f) / 20000.0f;
		uint32_t slot = 0;
		float prob = 0.0f, remap = 0.0f;
		REQUIRE(mirror_select_instance(cdf, total, u, slot, prob, remap));
		if (slot == 1) { // the wide middle bucket
			in_bucket++;
			lo_seen = MIN(lo_seen, remap);
			hi_seen = MAX(hi_seen, remap);
		}
	}
	REQUIRE(in_bucket > 1000);
	CHECK(lo_seen < 0.01f);
	CHECK(hi_seen > 0.99f);
}

TEST_CASE("[PathTracer][Emissive] the slot table round-trips and is sized by INSTANCE count") {
	// emissive_slot[] is indexed by gl_InstanceCustomIndex, so it must be sized to
	// the FULL instance count -- not to INSTANCES_MAX. Sizing it to the emissive
	// count would read out of bounds for any scene with more instances than
	// emitters, which is every scene, and the read would not fault reliably.
	const uint32_t instance_count = 9;
	const std::vector<uint32_t> emissive_instances = { 2, 5, 8 };

	std::vector<int32_t> slots(instance_count, -1);
	for (uint32_t s = 0; s < (uint32_t)emissive_instances.size(); s++) {
		slots[emissive_instances[s]] = (int32_t)s;
	}

	CHECK(slots.size() == instance_count);
	// Sized by the instance count, and by neither of the two wrong things it
	// could plausibly be sized by.
	CHECK(slots.size() != emissive_instances.size());
	CHECK(slots.size() != (size_t)EMISSIVE_INSTANCES_MAX);
	for (uint32_t i = 0; i < instance_count; i++) {
		const bool is_emissive =
				std::find(emissive_instances.begin(), emissive_instances.end(), i) != emissive_instances.end();
		if (is_emissive) {
			REQUIRE(slots[i] >= 0);
			CHECK(emissive_instances[slots[i]] == i); // round-trips to its own slot
		} else {
			CHECK(slots[i] == -1);
		}
	}
}

TEST_CASE("[PathTracer][Emissive] an all-zero distribution selects nothing") {
	std::vector<float> cdf = { 0.0f, 0.0f };
	uint32_t slot = 99;
	float prob = -1.0f, remap = -1.0f;
	CHECK_FALSE(mirror_select_instance(cdf, 0.0f, 0.5f, slot, prob, remap));
	CHECK(prob == 0.0f);

	std::vector<float> empty;
	CHECK_FALSE(mirror_select_instance(empty, 1.0f, 0.5f, slot, prob, remap));
}

// Mirror of the rebuild token composed at the end of gather_emissive_instances().
// One entry per KEPT emitter, in slot order.
struct MirrorTokenEntry {
	uint32_t geometry_index = 0;
	uint32_t prim_count = 0;
	// Merged-MultiMesh rebake stamp, 0 for instances that did not come from that
	// path. A merged MM bakes its per-instance transforms into the merged VERTEX
	// buffer, so when its instances move NOTHING else in this struct changes --
	// not the transform, not the emission, not the primitive count. This field is
	// the only thing standing between that and a permanently stale area.
	uint64_t merge_stamp = 0;
	Transform3D xform;
	Vector3 emission;
};

static uint64_t mirror_token(uint32_t p_instance_count, const std::vector<MirrorTokenEntry> &p_kept) {
	uint32_t h = hash_murmur3_one_32(p_instance_count);
	h = hash_murmur3_one_32((uint32_t)p_kept.size(), h);
	uint32_t h2 = hash_murmur3_one_32(p_instance_count, 0x9E3779B9u);
	h2 = hash_murmur3_one_32((uint32_t)p_kept.size(), h2);

	for (const MirrorTokenEntry &e : p_kept) {
		float xf[12];
		// Same 12 floats the GPU receives, in the same order.
		xf[0] = e.xform.basis.rows[0][0];
		xf[1] = e.xform.basis.rows[0][1];
		xf[2] = e.xform.basis.rows[0][2];
		xf[3] = e.xform.origin.x;
		xf[4] = e.xform.basis.rows[1][0];
		xf[5] = e.xform.basis.rows[1][1];
		xf[6] = e.xform.basis.rows[1][2];
		xf[7] = e.xform.origin.y;
		xf[8] = e.xform.basis.rows[2][0];
		xf[9] = e.xform.basis.rows[2][1];
		xf[10] = e.xform.basis.rows[2][2];
		xf[11] = e.xform.origin.z;

		h = hash_murmur3_one_32(e.geometry_index, h);
		h = hash_murmur3_one_32(e.prim_count, h);
		h = hash_murmur3_one_64(e.merge_stamp, h);
		h2 = hash_murmur3_one_32(e.geometry_index, h2);
		h2 = hash_murmur3_one_32(e.prim_count, h2);
		h2 = hash_murmur3_one_64(e.merge_stamp, h2);
		for (int k = 0; k < 12; k++) {
			h = hash_murmur3_one_float(xf[k], h);
			h2 = hash_murmur3_one_float(xf[k], h2);
		}
		h = hash_murmur3_one_float(e.emission.x, h);
		h = hash_murmur3_one_float(e.emission.y, h);
		h = hash_murmur3_one_float(e.emission.z, h);
		h2 = hash_murmur3_one_float(e.emission.x, h2);
		h2 = hash_murmur3_one_float(e.emission.y, h2);
		h2 = hash_murmur3_one_float(e.emission.z, h2);
	}
	return (uint64_t(hash_fmix32(h2)) << 32) | uint64_t(hash_fmix32(h));
}

TEST_CASE("[PathTracer][Emissive] every rebuild-token input is live") {
	// The token is compared for equality every frame and a match means "do not
	// rebuild". So an input the token cannot see is an input that silently
	// freezes the distribution -- which is exactly how the environment CDF once
	// baked an all-zero sky and never revisited it. Each sub-case perturbs ONE
	// input and requires the token to move.
	MirrorTokenEntry base;
	base.geometry_index = 3;
	base.prim_count = 24;
	base.merge_stamp = 0;
	base.xform.basis = Basis(Vector3(0, 1, 0), 0.37f).scaled(Vector3(1.25f, 0.75f, 2.0f));
	base.xform.origin = Vector3(1.5f, -0.25f, 4.0f);
	base.emission = Vector3(0.8f, 0.4f, 0.1f);

	const uint32_t instance_count = 40;
	const std::vector<MirrorTokenEntry> kept = { base };
	const uint64_t t0 = mirror_token(instance_count, kept);

	// Identical input must reproduce the token, or the distribution rebuilds
	// every frame and the dirty flag is pointless.
	CHECK(mirror_token(instance_count, kept) == t0);

	SUBCASE("a moved emitter") {
		std::vector<MirrorTokenEntry> k = kept;
		k[0].xform.origin.y += 0.001f;
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("a rotated emitter with an unchanged origin") {
		// Rotation lives in the basis, not the origin -- a token that hashed only
		// the translation would pass every other case here.
		std::vector<MirrorTokenEntry> k = kept;
		k[0].xform.basis = k[0].xform.basis * Basis(Vector3(1, 0, 0), 0.05f);
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("a re-coloured emitter") {
		std::vector<MirrorTokenEntry> k = kept;
		k[0].emission.z += 0.01f;
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("a NON-emissive instance appended at the end") {
		// Every emitter's index, transform and emission is untouched, but the slot
		// table must grow to cover the new gl_InstanceCustomIndex.
		CHECK(mirror_token(instance_count + 1, kept) != t0);
	}
	SUBCASE("a merged MultiMesh whose instances moved") {
		// THE case this field exists for: the merged vertex buffer is rebaked, so
		// the world geometry moved, yet geometry_index, prim_count, xform and
		// emission are all bit-identical. Only the rebake stamp differs.
		std::vector<MirrorTokenEntry> k = kept;
		k[0].merge_stamp = 1;
		const uint64_t t1 = mirror_token(instance_count, k);
		CHECK(t1 != t0);
		// And it must keep discriminating as the stamp advances, not merely on the
		// first 0 -> nonzero step.
		k[0].merge_stamp = 2;
		CHECK(mirror_token(instance_count, k) != t1);
		// A change confined to the HIGH word must register too: the stamp is 64-bit
		// and a 32-bit truncation would drop it.
		k[0].merge_stamp = uint64_t(1) << 40;
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("an emitter that lost triangles") {
		std::vector<MirrorTokenEntry> k = kept;
		k[0].prim_count = 23;
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("the same emitter at a different instance index") {
		std::vector<MirrorTokenEntry> k = kept;
		k[0].geometry_index = 4;
		CHECK(mirror_token(instance_count, k) != t0);
	}
	SUBCASE("a second emitter appearing") {
		std::vector<MirrorTokenEntry> k = kept;
		MirrorTokenEntry second = base;
		second.geometry_index = 9;
		k.push_back(second);
		CHECK(mirror_token(instance_count, k) != t0);
	}
}

TEST_CASE("[PathTracer][Emissive] compressed emitters use blas_transform x aabb^-1") {
	// The area pass multiplies rt_fetch_vertex_position()'s OBJECT-space output by
	// the transform this mirror produces. Passing blas_transforms[i] straight
	// through would double-apply the AABB de-normalisation on compressed meshes.
	const Vector3 aabb_pos(-2.0f, 5.0f, 0.25f);
	const Vector3 aabb_size(4.0f, 1.0f, 8.0f); // deliberately non-uniform

	Transform3D instance;
	instance.basis = Basis(Vector3(0, 1, 0), Math::PI / 3.0f).scaled(Vector3(1.5f, 2.5f, 0.5f));
	instance.origin = Vector3(7.0f, -3.0f, 11.0f);

	Transform3D aabb;
	aabb.basis = Basis::from_scale(aabb_size);
	aabb.origin = aabb_pos;

	// What build_tlas() pushes into blas_transforms for a compressed surface.
	const Transform3D blas_xform = instance * aabb;

	const Transform3D recovered = mirror_object_to_world(blas_xform, true, aabb_pos, aabb_size);
	CHECK(recovered.is_equal_approx(instance));
	// And it is genuinely different from the raw BLAS transform, so the case
	// would fail against an implementation that skipped the correction.
	CHECK_FALSE(blas_xform.is_equal_approx(instance));

	// The end-to-end invariant: the world triangle must be the same whether it is
	// reached from normalised BLAS coordinates or from object space.
	const Vector3 n0(0.1f, 0.8f, 0.35f), n1(0.9f, 0.2f, 0.6f), n2(0.4f, 0.45f, 0.95f);
	const Vector3 o0 = aabb.xform(n0), o1 = aabb.xform(n1), o2 = aabb.xform(n2);
	const float area_via_object = mirror_triangle_area_world(recovered, o0, o1, o2);
	const float area_via_blas = mirror_triangle_area_world(blas_xform, n0, n1, n2);
	CHECK(area_via_object > 0.0f);
	CHECK(area_via_object == doctest::Approx(area_via_blas));
	// The uncorrected path is not merely different, it is wrong by a large factor.
	CHECK(mirror_triangle_area_world(blas_xform, o0, o1, o2) != doctest::Approx(area_via_object));

	// Uncompressed geometry carries an identity AABB, so the correction is inert.
	CHECK(mirror_object_to_world(instance, false, Vector3(0, 0, 0), Vector3(1, 1, 1))
					.is_equal_approx(instance));
}

} // namespace TestPTEmissive
