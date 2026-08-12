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
