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

// ---------------------------------------------------------------------------
// C1 Task 4: the NEE pdf.
// ---------------------------------------------------------------------------

// Mirror of emissive_pdf_solid_angle(). pdf_A = P(inst) * (1/prim_count) * (1/area_tri),
// then converted to the solid-angle measure the BSDF pdf lives in.
//
// The cos threshold is the SAME constant emissive_sample() rejects on
// (EMISSIVE_MIN_COS_LIGHT). A looser guard here would let the reverse lookup
// report a huge NEE density for directions NEE can never draw, and Task 5's power
// heuristic would then delete that BSDF hit's energy.
static const float MIN_COS_LIGHT = 1e-5f;

static float mirror_pdf_solid_angle(float p_prob_inst, uint32_t p_prim_count,
		float p_area_tri, float p_dist, float p_cos_light) {
	if (p_prim_count == 0 || p_area_tri <= 0.0f || p_cos_light <= MIN_COS_LIGHT) {
		return 0.0f;
	}
	const float pdf_a = p_prob_inst * (1.0f / float(p_prim_count)) * (1.0f / p_area_tri);
	return pdf_a * (p_dist * p_dist) / p_cos_light;
}

TEST_CASE("[PathTracer][Emissive] the area pdf composes and normalises") {
	// Two instances, 4 and 1 triangles, all of unit area. Summing
	// P(inst) * P(tri|inst) * area over every triangle must give exactly 1.
	const float probs[2] = { 0.3f, 0.7f };
	const uint32_t prims[2] = { 4, 1 };
	float total = 0.0f;
	for (int i = 0; i < 2; i++) {
		for (uint32_t t = 0; t < prims[i]; t++) {
			const float pdf_a = probs[i] * (1.0f / float(prims[i])) * (1.0f / 1.0f);
			total += pdf_a * 1.0f; // integrate the density over the triangle's area
		}
	}
	CHECK(total == doctest::Approx(1.0f));
}

TEST_CASE("[PathTracer][Emissive] grazing angles INFLATE the solid-angle pdf") {
	// pdf_omega = pdf_A * d^2 / cos. A sign or reciprocal slip here is invisible
	// head-on (cos == 1) and only shows at grazing angles, so test there.
	const float head_on = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 1.0f);
	const float grazing = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 0.05f);
	CHECK(head_on == doctest::Approx(4.0f));
	CHECK(grazing > head_on);
	CHECK(grazing == doctest::Approx(4.0f / 0.05f));
}

TEST_CASE("[PathTracer][Emissive] distance enters the pdf quadratically") {
	const float near_pdf = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 1.0f, 1.0f);
	const float far_pdf = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 3.0f, 1.0f);
	CHECK(far_pdf == doctest::Approx(near_pdf * 9.0f));
}

TEST_CASE("[PathTracer][Emissive] a back-facing sample contributes nothing") {
	// Front-face-only, matching lights_eval_rect_light's cos_theta <= 1e-5 reject.
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, 0.0f) == 0.0f);
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, -0.5f) == 0.0f);
}

TEST_CASE("[PathTracer][Emissive] the pdf and the sampler agree on the cos threshold") {
	// The sampler rejects at cos <= MIN_COS_LIGHT, so the density must be zero over
	// exactly the same set. If this guard were the looser `<= 0`, then for cos in
	// (0, 1e-5] the REVERSE lookup would report a density of order 1/cos -- up to
	// 1e5 times the BSDF pdf -- for a direction NEE never produces, and Task 5's
	// power heuristic would give that BSDF hit weight ~0 and delete its energy.
	//
	// Straddle the threshold: at it, and just past it.
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, MIN_COS_LIGHT) == 0.0f);
	CHECK(mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, MIN_COS_LIGHT * 0.5f) == 0.0f);

	const float just_over = mirror_pdf_solid_angle(1.0f, 1, 1.0f, 2.0f, MIN_COS_LIGHT * 2.0f);
	CHECK(just_over > 0.0f);
	// And it really is the 1/cos blow-up that would have been reported below the
	// threshold -- the guard is suppressing a large number, not a negligible one.
	CHECK(just_over == doctest::Approx(4.0f / (MIN_COS_LIGHT * 2.0f)));
	CHECK(just_over > 1e5f);
}

TEST_CASE("[PathTracer][Emissive] a degenerate or empty instance yields no pdf") {
	CHECK(mirror_pdf_solid_angle(1.0f, 0, 1.0f, 2.0f, 1.0f) == 0.0f);
	CHECK(mirror_pdf_solid_angle(1.0f, 4, 0.0f, 2.0f, 1.0f) == 0.0f);
}

TEST_CASE("[PathTracer][Emissive] all four pdf factors are simultaneously live") {
	// THE GAP THE FIVE CASES ABOVE LEAVE. Every one of them pins `area_tri` at
	// exactly 1 or 0 and `prob_inst` at exactly 1, so an implementation that
	// dropped either factor entirely would pass all five. The pdf is a product of
	// four terms; each has to be non-extremal and mutually distinct at least
	// once, against a closed form rather than an inequality.
	//
	//   pdf_A     = 0.35 * (1/7) * (1/2.5) = 0.02
	//   pdf_omega = 0.02 * 1.5^2 / 0.4     = 0.1125
	const float prob = 0.35f;
	const uint32_t prims = 7;
	const float area = 2.5f;
	const float dist = 1.5f;
	const float cosl = 0.4f;
	const float pdf = mirror_pdf_solid_angle(prob, prims, area, dist, cosl);
	CHECK(pdf == doctest::Approx(0.1125f));

	// And each factor moves the answer by its own predicted ratio, independently
	// of the others -- so no factor can be silently folded into a neighbour.
	CHECK(mirror_pdf_solid_angle(prob * 2.0f, prims, area, dist, cosl)
					== doctest::Approx(pdf * 2.0f));
	CHECK(mirror_pdf_solid_angle(prob, prims * 2u, area, dist, cosl)
					== doctest::Approx(pdf * 0.5f));
	CHECK(mirror_pdf_solid_angle(prob, prims, area * 2.0f, dist, cosl)
					== doctest::Approx(pdf * 0.5f));
	CHECK(mirror_pdf_solid_angle(prob, prims, area, dist * 2.0f, cosl)
					== doctest::Approx(pdf * 4.0f));
	CHECK(mirror_pdf_solid_angle(prob, prims, area, dist, cosl * 2.0f)
					== doctest::Approx(pdf * 0.5f));

	// KNOWN BLIND SPOT, recorded rather than papered over: prim_count and
	// area_tri both enter as reciprocals of a single product, so exchanging the
	// two is arithmetically invisible in the RETURNED VALUE and no choice of
	// inputs can separate them here. What does separate them is their GUARDS -- a
	// zero prim_count and a zero area are rejected by different clauses (the case
	// above) -- and the shader's types: one is a uint triangle count used to index
	// the mesh, the other a float world-space area.
}

// Mirror of emissive_pdf_solid_angle_for_hit()'s FIRST step: recovering P(inst)
// for an ALREADY-KNOWN slot by differencing the CDF, rather than by walking it
// the way selection does. Task 5's MIS weight for a BSDF ray that lands on an
// emitter depends on this agreeing exactly with what selection would have
// reported for the same slot; if it does not, the two strategies weight one
// direction with two different densities and the partition stops summing to 1.
static float mirror_prob_from_cdf_bucket(const std::vector<float> &p_prefix, float p_total, uint32_t p_slot) {
	if (!(p_total > 0.0f) || p_slot >= (uint32_t)p_prefix.size()) {
		return 0.0f;
	}
	const float lo = (p_slot == 0) ? 0.0f : p_prefix[p_slot - 1];
	const float w = p_prefix[p_slot] - lo;
	return (w > 0.0f) ? (w / p_total) : 0.0f;
}

TEST_CASE("[PathTracer][Emissive] the reverse P(inst) lookup matches the forward walk") {
	// Powers {1, 7, 0, 2}: an interior bucket, the FIRST bucket (whose lower edge
	// is the implicit 0 rather than prefix[-1] -- an off-by-one there is invisible
	// on every other slot), a zero-width bucket, and the last.
	std::vector<float> cdf = { 1.0f, 8.0f, 8.0f, 10.0f };
	const float total = 10.0f;

	CHECK(mirror_prob_from_cdf_bucket(cdf, total, 0) == doctest::Approx(0.1f));
	CHECK(mirror_prob_from_cdf_bucket(cdf, total, 1) == doctest::Approx(0.7f));
	CHECK(mirror_prob_from_cdf_bucket(cdf, total, 2) == 0.0f);
	CHECK(mirror_prob_from_cdf_bucket(cdf, total, 3) == doctest::Approx(0.2f));

	// The probabilities of the reachable buckets sum to 1: a reverse lookup that
	// forgot to divide by total, or differenced the wrong neighbour, would not.
	float sum = 0.0f;
	for (uint32_t s = 0; s < 4; s++) {
		sum += mirror_prob_from_cdf_bucket(cdf, total, s);
	}
	CHECK(sum == doctest::Approx(1.0f));

	// Agreement with the forward walk, slot for slot, over a full sweep of u.
	for (int i = 0; i < 4000; i++) {
		const float u = (float(i) + 0.5f) / 4000.0f;
		uint32_t slot = 0;
		float prob = 0.0f, remap = 0.0f;
		REQUIRE(mirror_select_instance(cdf, total, u, slot, prob, remap));
		CHECK(mirror_prob_from_cdf_bucket(cdf, total, slot) == doctest::Approx(prob));
	}

	// The disabled-feature gate, from the other direction: an all-zero
	// distribution yields no probability for any slot, and an out-of-range slot
	// yields none either.
	CHECK(mirror_prob_from_cdf_bucket(cdf, 0.0f, 1) == 0.0f);
	CHECK(mirror_prob_from_cdf_bucket(cdf, total, 4) == 0.0f);
}

// Mirror of emissive_orient_normal(). Returns the GEOMETRIC normal -- the world
// cross product, never the vertex normal -- turned to face the side the surface
// emits from, which is the side a back-face-culled BSDF ray can hit.
//
// p_use_naive_matrix selects the WRONG normal transform (the basis itself rather
// than its inverse transpose) so a test can show the two disagree.
static Vector3 mirror_orient_normal(const Transform3D &p_xform, const Vector3 &p0,
		const Vector3 &p1, const Vector3 &p2, const Vector3 &p_n_obj,
		bool p_use_naive_matrix = false) {
	const Vector3 w0 = p_xform.xform(p0);
	const Vector3 w1 = p_xform.xform(p1);
	const Vector3 w2 = p_xform.xform(p2);
	const Vector3 ng = (w1 - w0).cross(w2 - w0).normalized();
	const Vector3 n_world = p_use_naive_matrix
			? p_xform.basis.xform(p_n_obj)
			: p_xform.basis.inverse().transposed().xform(p_n_obj);
	return (ng.dot(n_world) < 0.0f) ? -ng : ng;
}

TEST_CASE("[PathTracer][Emissive] the emitting side comes from the vertex normal, not the winding") {
	// THE BUG THIS CASE EXISTS FOR, found by instrumenting a real frame in C1 Task
	// 4: taking cross(p1-p0, p2-p0) as the emitter's outward normal. Godot winds
	// its meshes opposite to the CCW convention that cross product assumes, so on a
	// box emitter above a floor it pointed INWARD -- 62.6% of NEE samples landed on
	// the far side of the emitter and were killed by their own shadow ray, 36.5%
	// were rejected as back-facing, and 0.9% survived. The image did not change,
	// which is why only a measurement caught it.
	const Vector3 n_obj(0, 1, 0);
	// Wound so the raw cross product AGREES with the vertex normal.
	const Vector3 a0(0, 0, 0), a1(1, 0, 0), a2(0, 0, -1);
	// The same triangle with two vertices exchanged: raw cross product now OPPOSES
	// the vertex normal. Both must yield the SAME emitting side.
	const Vector3 b0(0, 0, 0), b1(0, 0, -1), b2(1, 0, 0);

	const Transform3D id;
	CHECK(mirror_orient_normal(id, a0, a1, a2, n_obj).is_equal_approx(Vector3(0, 1, 0)));
	CHECK(mirror_orient_normal(id, b0, b1, b2, n_obj).is_equal_approx(Vector3(0, 1, 0)));

	// And the raw cross product really does disagree between the two windings, so
	// the case would fail against an implementation that skipped the orientation.
	const Vector3 raw_a = (a1 - a0).cross(a2 - a0).normalized();
	const Vector3 raw_b = (b1 - b0).cross(b2 - b0).normalized();
	CHECK(raw_a.is_equal_approx(-raw_b));

	// A MIRRORING transform (negative determinant) flips the world-space winding
	// while leaving the outward side where it was. No winding convention can see
	// this; only the vertex normal can.
	Transform3D mirrored;
	mirrored.basis = Basis::from_scale(Vector3(-1, 1, 1));
	const Vector3 mirrored_raw = (mirrored.xform(a1) - mirrored.xform(a0))
										 .cross(mirrored.xform(a2) - mirrored.xform(a0))
										 .normalized();
	CHECK(mirrored_raw.is_equal_approx(Vector3(0, -1, 0))); // the winding flipped
	CHECK(mirror_orient_normal(mirrored, a0, a1, a2, n_obj).is_equal_approx(Vector3(0, 1, 0)));
}

TEST_CASE("[PathTracer][Emissive] orientation needs the INVERSE TRANSPOSE, not the basis") {
	// Under non-uniform scale the naive `basis * n` test reduces to sign(g . n) in
	// OBJECT space, which is scale-blind; the correct inverse-transpose test
	// weights each component by 1/s^2. Here they disagree in SIGN, so an
	// implementation using the basis directly would orient this emitter backwards.
	//
	// Object-space triangle chosen so its geometric normal is (-0.5, 1, 0):
	// g . n = 0.5 > 0 (naive: aligned) while g.x/1 + g.y/100 = -0.49 < 0 under
	// scale (1, 10, 1) (correct: opposed).
	const Vector3 n_obj = Vector3(1, 1, 0).normalized();
	const Vector3 p0(0, 0, 0);
	const Vector3 p1(0, 0, 1); // edge along +z
	const Vector3 p2(1, 0.5f, 0); // in the plane perpendicular to (-0.5, 1, 0)

	// Confirm the object-space geometric normal really is the (-0.5, 1, 0) direction.
	const Vector3 g_obj = (p1 - p0).cross(p2 - p0);
	CHECK(g_obj.normalized().is_equal_approx(Vector3(-0.5f, 1.0f, 0.0f).normalized()));
	CHECK(g_obj.dot(n_obj) > 0.0f); // naive test says "aligned"

	Transform3D scaled;
	scaled.basis = Basis::from_scale(Vector3(1, 10, 1));

	const Vector3 correct = mirror_orient_normal(scaled, p0, p1, p2, n_obj, false);
	const Vector3 naive = mirror_orient_normal(scaled, p0, p1, p2, n_obj, true);
	CHECK(correct.is_equal_approx(-naive));

	// Pin WHICH one is right rather than only that they differ: the emitting side
	// is the one the properly transformed vertex normal points to.
	const Vector3 n_world = scaled.basis.inverse().transposed().xform(n_obj);
	CHECK(correct.dot(n_world) > 0.0f);
	CHECK(naive.dot(n_world) < 0.0f);

	// Under UNIFORM scale the two matrices differ only by a positive factor, so
	// the naive form happens to agree -- which is exactly why a suite that only
	// tested uniform scale would not notice.
	Transform3D uniform;
	uniform.basis = Basis::from_scale(Vector3(3, 3, 3));
	CHECK(mirror_orient_normal(uniform, p0, p1, p2, n_obj, false)
					.is_equal_approx(mirror_orient_normal(uniform, p0, p1, p2, n_obj, true)));
}

// Mirror of the sqrt-warped barycentric draw in emissive_sample():
//     su = sqrt(u.x);  b = (1 - su, su * (1 - u.y), su * u.y)
//
// p_warp selects the CONTROL: false drops the sqrt, which is the mistake this
// exists to catch. It still produces valid barycentrics, so nothing crashes and
// nothing looks wrong -- the points just bunch toward p0 while the pdf keeps
// reporting the constant 1/area. That is a pure energy error with no other symptom.
static Vector3 mirror_barycentric_warp(float p_ux, float p_uy, bool p_warp = true) {
	const float su = p_warp ? Math::sqrt(p_ux) : p_ux;
	return Vector3(1.0f - su, su * (1.0f - p_uy), su * p_uy);
}

// Mirror of the triangle draw, which reuses the CDF bucket remainder rather than
// spending a second random dimension.
static uint32_t mirror_triangle_index(float p_remap, uint32_t p_prim_count) {
	return MIN((uint32_t)(p_remap * (float)p_prim_count), p_prim_count - 1u);
}

TEST_CASE("[PathTracer][Emissive] the barycentric warp yields valid barycentrics") {
	// Non-negative and summing to 1 at every corner of the unit square and across
	// its interior. A negative component would place the sample OUTSIDE the
	// triangle, where the emitter does not exist.
	for (int i = 0; i <= 20; i++) {
		for (int j = 0; j <= 20; j++) {
			const float ux = float(i) / 20.0f;
			const float uy = float(j) / 20.0f;
			const Vector3 b = mirror_barycentric_warp(ux, uy);
			CHECK(b.x >= 0.0f);
			CHECK(b.y >= 0.0f);
			CHECK(b.z >= 0.0f);
			CHECK(b.x + b.y + b.z == doctest::Approx(1.0f));
		}
	}
	// The three vertices are reachable, so no part of the emitter is excluded.
	CHECK(mirror_barycentric_warp(0.0f, 0.0f).is_equal_approx(Vector3(1, 0, 0)));
	CHECK(mirror_barycentric_warp(1.0f, 0.0f).is_equal_approx(Vector3(0, 1, 0)));
	CHECK(mirror_barycentric_warp(1.0f, 1.0f).is_equal_approx(Vector3(0, 0, 1)));
}

TEST_CASE("[PathTracer][Emissive] warped samples are UNIFORM over the triangle") {
	// The pdf is the constant 1/area_tri, which is only the right density if the
	// points are uniform by AREA. Drop the sqrt and they concentrate toward p0
	// while the pdf is unchanged -- brightening one corner of every emitter and
	// darkening the rest, with no failing test anywhere else in this suite.
	//
	// The test triangle is SCALENE and away from the origin, so no symmetry of the
	// triangle itself can mask a directional bias.
	const Vector3 a(1.0f, -2.0f, 0.5f);
	const Vector3 b(4.5f, 0.25f, -1.0f);
	const Vector3 c(0.0f, 3.0f, 2.25f);

	// Medial subdivision: the midpoint triangle splits any triangle into four
	// pieces of EXACTLY one quarter of the area each -- three corner pieces and a
	// central one. So a uniform draw must land in each with probability 1/4.
	// Which piece a point falls in is decided from its recovered barycentrics:
	// corner i iff that coordinate is >= 0.5, central otherwise.
	const int N = 200;
	int warped[4] = { 0, 0, 0, 0 };
	int control[4] = { 0, 0, 0, 0 };
	for (int i = 0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			// Stratified sweep of the unit square, sampling cell centres.
			const float ux = (float(i) + 0.5f) / float(N);
			const float uy = (float(j) + 0.5f) / float(N);

			for (int pass = 0; pass < 2; pass++) {
				const Vector3 bc = mirror_barycentric_warp(ux, uy, pass == 0);
				// Build the actual world point, then RECOVER its barycentrics from
				// sub-triangle areas rather than reusing `bc`. That way the case
				// exercises the whole object-space composition and not just the
				// formula it came from.
				const Vector3 p = bc.x * a + bc.y * b + bc.z * c;
				const float total = (b - a).cross(c - a).length();
				const float wa = (b - p).cross(c - p).length() / total;
				const float wb = (p - a).cross(c - a).length() / total;
				const float wc = (b - a).cross(p - a).length() / total;
				REQUIRE(wa + wb + wc == doctest::Approx(1.0f).epsilon(0.001));

				int bucket = 3; // central
				if (wa >= 0.5f) {
					bucket = 0;
				} else if (wb >= 0.5f) {
					bucket = 1;
				} else if (wc >= 0.5f) {
					bucket = 2;
				}
				if (pass == 0) {
					warped[bucket]++;
				} else {
					control[bucket]++;
				}
			}
		}
	}

	const float n = float(N * N);
	for (int k = 0; k < 4; k++) {
		CHECK(float(warped[k]) / n == doctest::Approx(0.25f).epsilon(0.02));
	}

	// THE CONTROL, so this case cannot pass vacuously: without the sqrt the corner
	// at p0 collects far more than its quarter. If this ever stops failing, the
	// uniformity assertion above has stopped meaning anything.
	CHECK(float(control[0]) / n > 0.4f);
}

TEST_CASE("[PathTracer][Emissive] the triangle draw covers every triangle and never overruns") {
	// The remainder handed in is emissive_select_instance's, which clamps to
	// 0.99999994 -- the largest float below 1. That value times prim_count must
	// still land on the LAST triangle and not one past it.
	const float CDF_REMAP_MAX = 0.99999994f;

	CHECK(mirror_triangle_index(0.0f, 1) == 0);
	CHECK(mirror_triangle_index(CDF_REMAP_MAX, 1) == 0);
	CHECK(mirror_triangle_index(0.0f, 12) == 0);
	CHECK(mirror_triangle_index(CDF_REMAP_MAX, 12) == 11);
	CHECK(mirror_triangle_index(CDF_REMAP_MAX, 256) == 255);
	// A count large enough that (1 - 2^-24) * count rounds up in float, which is
	// where an unguarded uint() cast would step off the end of the mesh.
	CHECK(mirror_triangle_index(CDF_REMAP_MAX, 100000u) < 100000u);
	// The clamp is load-bearing, not defensive: at a remap of exactly 1 the cast
	// alone yields prim_count.
	CHECK(mirror_triangle_index(1.0f, 12) == 11);

	// Every triangle is reachable and the draw is uniform over them, which is the
	// (1 / prim_count) factor the pdf claims. A sweep, since the remainder is a
	// rescaled CDF bucket and must span the whole unit interval.
	const uint32_t prim_count = 12;
	const int N = 120000;
	std::vector<int> hits(prim_count, 0);
	for (int i = 0; i < N; i++) {
		const float remap = MIN((float(i) + 0.5f) / float(N), CDF_REMAP_MAX);
		const uint32_t t = mirror_triangle_index(remap, prim_count);
		REQUIRE(t < prim_count);
		hits[t]++;
	}
	for (uint32_t t = 0; t < prim_count; t++) {
		CHECK(float(hits[t]) / float(N) == doctest::Approx(1.0f / float(prim_count)).epsilon(0.01));
	}
}

// ============================================================================
// THE MIS PARTITION (C1 Task 5)
// ============================================================================

// Mirror of power_heuristic (raytracing_inc.glsl).
static float mirror_power_heuristic(float p_a, float p_b) {
	const float a2 = p_a * p_a;
	const float b2 = p_b * p_b;
	const float d = a2 + b2;
	return (d > 0.0f) ? (a2 / d) : 0.0f;
}

// Mirror of the emissive-hit weight decision in shade_and_bounce()
// (raytracing_closest_hit_common_inc.glsl). `p_slot` is
// emissive_slot_for_instance(gl_InstanceCustomIndexEXT), which is -1 both for a
// non-emitter and whenever the distribution is empty; `p_mis_ray_pdf` is
// ps.mis_ray_pdf, negative on the RT_MIS_PDF_NONE sentinel.
//
// The three conditions are ANDed in the shader in this order for a reason the
// arithmetic here cannot show: with the feature off all three emissive bindings
// are the same 16-byte zero-filled fallback, so the slot lookup must not happen
// until RT_GET_EMISSIVE_ENABLED() has short-circuited.
static float mirror_bsdf_emissive_weight(bool p_emissive_enabled, int p_slot,
		float p_mis_ray_pdf, float p_light_pdf) {
	if (p_emissive_enabled && p_mis_ray_pdf > 0.0f && p_slot >= 0) {
		return mirror_power_heuristic(p_mis_ray_pdf, p_light_pdf);
	}
	return 1.0f;
}

TEST_CASE("[PathTracer][Emissive] the MIS partition sums to exactly one") {
	// Both halves must be formed from the SAME two pdfs in the SAME measure, or
	// the emissive surface is counted twice (sum > 1) or dimmed (sum < 1).
	const float pairs[6][2] = {
		{ 1.0f, 1.0f }, { 0.001f, 5.0f }, { 5.0f, 0.001f },
		{ 1e-6f, 1e6f }, { 3.7f, 0.42f }, { 100.0f, 100.0f }
	};
	for (const auto &p : pairs) {
		const float w_nee = mirror_power_heuristic(p[0], p[1]);
		const float w_bsdf = mirror_power_heuristic(p[1], p[0]);
		CHECK(w_nee + w_bsdf == doctest::Approx(1.0f));
	}
}

TEST_CASE("[PathTracer][Emissive] an unreachable strategy takes the whole weight") {
	// A near-delta specular bounce carries RT_MIS_PDF_NONE and must not be
	// weighted down against a strategy that could not have produced it. Modelled
	// here as the sentinel path: weight 1, unconditionally.
	const float light_pdf = 12.5f;
	const float bsdf_pdf_sentinel = -1.0f; // RT_MIS_PDF_NONE
	const float w = (bsdf_pdf_sentinel < 0.0f) ? 1.0f : mirror_power_heuristic(bsdf_pdf_sentinel, light_pdf);
	CHECK(w == doctest::Approx(1.0f));
}

TEST_CASE("[PathTracer][Emissive] a zero light pdf hands the BSDF full weight") {
	// Where emissive NEE cannot reach (back face, degenerate triangle), its pdf
	// is 0 and the BSDF half must collect the whole contribution -- otherwise the
	// energy is deleted rather than redistributed.
	CHECK(mirror_power_heuristic(4.2f, 0.0f) == doctest::Approx(1.0f));
	CHECK(mirror_power_heuristic(0.0f, 4.2f) == doctest::Approx(0.0f));
}

TEST_CASE("[PathTracer][Emissive] the weight is the POWER heuristic, not the balance heuristic") {
	// THE GAP THE THREE CASES ABOVE LEAVE, and it is not academic. The balance
	// heuristic a/(a+b) ALSO sums to one, ALSO gives 1 at b == 0 and 0 at a == 0,
	// so it satisfies every assertion above -- yet it is a measurably different
	// (higher-variance) partition, and it is NOT what emissive_sample() already
	// uses on the NEE side. If the two halves picked different heuristics the sum
	// would stop being one and the surface would be miscounted, which is exactly
	// the failure no sum-to-one test written against a single heuristic can see.
	//
	// beta = 2 is pinned against a closed form at a point where the two differ:
	//   power   : 2^2 / (2^2 + 1^2) = 4/5 = 0.8
	//   balance : 2   / (2   + 1)   = 2/3 = 0.6667
	CHECK(mirror_power_heuristic(2.0f, 1.0f) == doctest::Approx(0.8f));
	CHECK(mirror_power_heuristic(2.0f, 1.0f) != doctest::Approx(2.0f / 3.0f));

	// And the exponent itself: doubling BOTH pdfs must leave the weight alone
	// (scale invariance, true of any beta), while the RATIO must enter squared.
	// At a ratio of 3 the weights are 9/10 vs 1/10 -- balance would say 3/4, 1/4.
	CHECK(mirror_power_heuristic(6.0f, 3.0f) == doctest::Approx(0.8f));
	CHECK(mirror_power_heuristic(3.0f, 1.0f) == doctest::Approx(0.9f));
	CHECK(mirror_power_heuristic(1.0f, 3.0f) == doctest::Approx(0.1f));
}

TEST_CASE("[PathTracer][Emissive] the BSDF hit is weighted only where NEE could also reach it") {
	// Mirror of shade_and_bounce()'s gate. Three independent conditions have to be
	// true before the emissive hit is scaled down at all; each one going false on
	// its own must restore the full contribution, because in each case emissive NEE
	// could NOT have produced this direction and there is no second strategy to
	// share with. Weighting any of them down deletes energy outright.
	//
	// The pdfs below are the measurement scene's own order of magnitude: a 0.6-unit
	// emitter at ~5 units gives pdf_omega ~ 11 sr^-1 against a Lambertian
	// combinedPdf of ~0.32.
	const float light_pdf = 11.0f;
	const float bsdf_pdf = 0.32f;

	// All three live: the surface really is reachable both ways, so the weight is
	// the heuristic's -- and it is nearly all NEE's.
	const float w_live = mirror_bsdf_emissive_weight(true, 3, bsdf_pdf, light_pdf);
	CHECK(w_live == doctest::Approx(mirror_power_heuristic(bsdf_pdf, light_pdf)));
	CHECK(w_live < 0.01f); // ~0.00084 -- the double count is what this removes.
	CHECK(w_live > 0.0f); // ...but it is NOT zero: the BSDF half is not deleted.

	// Feature off: NEE never ran, so the hit keeps everything. (Also the case in
	// which emissive_slot[] must not be read at all -- see the shader gate.)
	CHECK(mirror_bsdf_emissive_weight(false, 3, bsdf_pdf, light_pdf) == doctest::Approx(1.0f));

	// Not an emitter in the distribution: slot -1. This covers the DEFORMED and
	// custom-hit-group exclusions, which are unbiased only because of this line.
	CHECK(mirror_bsdf_emissive_weight(true, -1, bsdf_pdf, light_pdf) == doctest::Approx(1.0f));

	// Sentinel BSDF pdf (RT_MIS_PDF_NONE, and the 0.0 that cannot occur because
	// shade_and_bounce stores the sentinel instead): camera ray or near-delta
	// specular bounce, unreachable by NEE.
	CHECK(mirror_bsdf_emissive_weight(true, 3, -1.0f, light_pdf) == doctest::Approx(1.0f));
	CHECK(mirror_bsdf_emissive_weight(true, 3, 0.0f, light_pdf) == doctest::Approx(1.0f));

	// A slot of 0 is a VALID emitter, not a falsy "no slot". An implementation
	// that tested `slot` for truth rather than for `>= 0` would hand slot 0 the
	// full weight and double-count the first emitter in the distribution.
	CHECK(mirror_bsdf_emissive_weight(true, 0, bsdf_pdf, light_pdf) < 0.01f);

	// Zero light pdf inside the live branch -- the emitter is in the distribution
	// but NEE cannot draw THIS direction (back face, degenerate triangle). Full
	// weight, from the heuristic itself rather than from the gate.
	CHECK(mirror_bsdf_emissive_weight(true, 3, bsdf_pdf, 0.0f) == doctest::Approx(1.0f));

	// THE CONTROL, so the case cannot pass vacuously: a gate that always took the
	// weighted branch would drive the "feature off" and "not an emitter" rows to
	// w_live, and that is not 1. If this ever stops holding, every == 1.0 check
	// above has stopped distinguishing anything.
	CHECK(w_live != doctest::Approx(1.0f));
}

TEST_CASE("[PathTracer][Emissive] the two halves partition the measurement scene's emitter") {
	// The end-to-end statement of the acceptance criterion, in the units the probe
	// measures. `pipeline_references/tests/pt_emissive_compile_scene.tscn` reads
	// 0.0609 with the feature off (BSDF hits only) and 0.1216 with it on and no
	// weight -- a 99.7% double count. With the partition applied the two strategies
	// must sum back to ONE copy of the same radiance, at every ratio the scene's
	// geometry can produce, not just the one measured.
	const float bsdf_pdf = 0.32f; // Lambertian, cos-weighted.
	const float radiance = 0.0609f; // One copy, in the probe's units.

	// A sweep over emitter solid angles from "fills the hemisphere" to "pinhole".
	const float light_pdfs[7] = { 0.05f, 0.32f, 1.0f, 11.0f, 250.0f, 1e4f, 1e6f };
	for (float light_pdf : light_pdfs) {
		const float w_bsdf = mirror_bsdf_emissive_weight(true, 3, bsdf_pdf, light_pdf);
		const float w_nee = mirror_power_heuristic(light_pdf, bsdf_pdf);
		CHECK((w_bsdf + w_nee) * radiance == doctest::Approx(radiance));
	}

	// Unweighted, the same sum is 2x -- which is the number the probe actually
	// reports today, and the one this task exists to remove.
	CHECK((1.0f + mirror_power_heuristic(11.0f, bsdf_pdf)) * radiance
					== doctest::Approx(0.1216f).epsilon(0.01));
}

} // namespace TestPTEmissive
