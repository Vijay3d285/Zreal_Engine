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

} // namespace TestPTEmissive
