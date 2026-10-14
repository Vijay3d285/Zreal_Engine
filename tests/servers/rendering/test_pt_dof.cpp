/**************************************************************************/
/*  test_pt_dof.cpp                                                       */
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

TEST_FORCE_LINK(test_pt_dof)

#include "core/math/math_funcs.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"

namespace TestPTDof {

// Mirrors of the GLSL in raytracing_inc.glsl (rt_concentric_disk) and
// scene_raytracing_raygen.glsl (camera_ray's thin-lens branch). Keep in lockstep.
static Vector2 concentric_disk(const Vector2 &p_u) {
	const Vector2 o = p_u * 2.0f - Vector2(1.0f, 1.0f);
	if (o.x == 0.0f && o.y == 0.0f) {
		return Vector2();
	}
	float r;
	float theta;
	if (Math::abs(o.x) > Math::abs(o.y)) {
		r = o.x;
		theta = (float)Math::PI * 0.25f * (o.y / o.x);
	} else {
		r = o.y;
		theta = (float)Math::PI * 0.5f - (float)Math::PI * 0.25f * (o.x / o.y);
	}
	return Vector2(r * Math::cos(theta), r * Math::sin(theta));
}

struct LensRay {
	Vector3 origin;
	Vector3 dir;
};

// p_dir_view: normalized pinhole direction in camera space (Godot looks down -Z).
static LensRay thin_lens(const Vector3 &p_dir_view, const Vector2 &p_disk, float p_radius, float p_focus) {
	LensRay ray{ Vector3(), p_dir_view };
	if (p_radius > 0.0f) {
		const Vector3 focal = p_dir_view * (p_focus / -p_dir_view.z);
		ray.origin = Vector3(p_radius * p_disk.x, p_radius * p_disk.y, 0.0f);
		ray.dir = (focal - ray.origin).normalized();
	}
	return ray;
}

TEST_CASE("[PathTracer][DOF] the concentric map stays in the unit disc and preserves area") {
	const int n = 64;
	int inside_half = 0;
	float max_r = 0.0f;
	for (int j = 0; j < n; j++) {
		for (int i = 0; i < n; i++) {
			const Vector2 p = concentric_disk(Vector2((i + 0.5f) / n, (j + 0.5f) / n));
			max_r = MAX(max_r, p.length());
			if (p.length() < 0.5f) {
				inside_half++;
			}
		}
	}
	CHECK(max_r <= 1.0f + 1e-5f);
	// Uniform density: the disc of radius 0.5 holds a quarter of the area.
	CHECK(float(inside_half) / float(n * n) == doctest::Approx(0.25f).epsilon(0.02));
}

TEST_CASE("[PathTracer][DOF] the concentric map covers every direction evenly") {
	// The area test above sees only the radius; a wrong angle would bunch the
	// aperture samples into some directions and blur unevenly.
	const int n = 64;
	// 16 sectors of pi/8: they split each branch region of the map in two, so an angle
	// squeezed inside its own octant is still seen.
	int sector[16] = {};
	for (int j = 0; j < n; j++) {
		for (int i = 0; i < n; i++) {
			// Off-centre grid offsets keep every sample off the |x| == |y| sector boundaries.
			const Vector2 p = concentric_disk(Vector2((i + 0.37f) / n, (j + 0.61f) / n));
			const float a = Math::atan2(p.y, p.x) + (float)Math::PI; // [0, 2 pi]
			sector[MIN(15, int(a / ((float)Math::PI * 0.125f)))]++;
		}
	}
	for (int s = 0; s < 16; s++) {
		CHECK(float(sector[s]) / float(n * n) == doctest::Approx(0.0625f).epsilon(0.05));
	}
}

TEST_CASE("[PathTracer][DOF] every lens point through one pixel meets at the focal point") {
	const Vector3 d = Vector3(0.2f, -0.1f, -1.0f).normalized();
	const float focus = 4.0f;
	const Vector3 focal = d * (focus / -d.z);
	CHECK(focal.z == doctest::Approx(-focus));
	const Vector2 us[4] = { Vector2(0.1f, 0.9f), Vector2(0.7f, 0.3f), Vector2(0.95f, 0.5f), Vector2(0.5f, 0.02f) };
	for (const Vector2 &u : us) {
		const LensRay ray = thin_lens(d, concentric_disk(u), 0.002f, focus);
		const float t = (focal - ray.origin).length();
		const Vector3 hit = ray.origin + ray.dir * t;
		CHECK(hit.distance_to(focal) < 1e-5f);
		CHECK(ray.origin.z == 0.0f);
	}
}

TEST_CASE("[PathTracer][DOF] radius 0 is exactly the pinhole ray") {
	const Vector3 d = Vector3(-0.3f, 0.05f, -1.0f).normalized();
	const LensRay ray = thin_lens(d, concentric_disk(Vector2(0.8f, 0.2f)), 0.0f, 3.0f);
	CHECK(ray.origin == Vector3());
	CHECK(ray.dir == d);
}

} // namespace TestPTDof
