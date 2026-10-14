/**************************************************************************/
/*  test_pt_relief.cpp                                                    */
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

TEST_FORCE_LINK(test_pt_relief)

#include "core/math/math_funcs.h"
#include "core/templates/local_vector.h"

namespace TestPTRelief {

// Mirror of local_highlight.glsl MODE_APPLY's luminance lookup: the luminance the gain is
// computed from, for a pixel at coarse-texel coordinate (p_tx, p_ty) whose own luminance is
// p_own. Coarse cells are the 1/16 mean-luminance map, row-major p_cw x p_ch. Keep in lockstep.
static const float RANGE_SIGMA_STOPS = 1.0f;

static float relief_luma(const LocalVector<float> &p_cells, int p_cw, int p_ch, float p_tx, float p_ty, float p_own) {
	// Edge-aware (joint bilateral) upsampling: the 4 x 4 nearest cells, each weighted by a
	// tent of radius 2 cells and by how close its log luminance is to the pixel's own, so a
	// pixel only takes the brightness of cells like itself.
	const int bx = (int)Math::floor(p_tx) - 1;
	const int by = (int)Math::floor(p_ty) - 1;
	const float own_log = Math::log2(MAX(p_own, 1e-6f));
	float acc = 0.0f;
	float wsum = 0.0f;
	for (int y = 0; y < 4; y++) {
		for (int x = 0; x < 4; x++) {
			const int cx = bx + x;
			const int cy = by + y;
			const float ws = MAX(0.0f, 1.0f - Math::abs(cx - p_tx) * 0.5f) * MAX(0.0f, 1.0f - Math::abs(cy - p_ty) * 0.5f);
			const float l = p_cells[CLAMP(cy, 0, p_ch - 1) * p_cw + CLAMP(cx, 0, p_cw - 1)];
			const float dl = Math::log2(MAX(l, 1e-6f)) - own_log;
			const float w = ws * (Math::exp(-0.5f * dl * dl / (RANGE_SIGMA_STOPS * RANGE_SIGMA_STOPS)) + 1e-6f);
			acc += w * l;
			wsum += w;
		}
	}
	return acc / MAX(wsum, 1e-12f);
}

// A 16 x 10 coarse map: cells x < 8 are a sun patch (20.0), x >= 8 the darker room (0.3).
static LocalVector<float> step_field() {
	LocalVector<float> cells;
	for (int y = 0; y < 10; y++) {
		for (int x = 0; x < 16; x++) {
			cells.push_back(x < 8 ? 20.0f : 0.3f);
		}
	}
	return cells;
}

// Coarse coordinate of full-resolution pixel p (the shader: uv = (p + 0.5) / src, texel = uv * dst - 0.5).
static float coarse(int p_px) {
	return (p_px + 0.5f) / 16.0f - 0.5f;
}

TEST_CASE("[PathTracer][Relief] a uniform field returns its value for any pixel") {
	LocalVector<float> cells;
	for (int i = 0; i < 16 * 10; i++) {
		cells.push_back(8.0f);
	}
	CHECK(relief_luma(cells, 16, 10, coarse(100), 4.3f, 3.0f) == doctest::Approx(8.0f));
	CHECK(relief_luma(cells, 16, 10, coarse(100), 4.3f, 30.0f) == doctest::Approx(8.0f));
}

TEST_CASE("[PathTracer][Relief] a dark pixel beside a sun patch is not darkened with it") {
	// Pixel 128 is the first dark pixel right of the patch edge (cell 8 starts at pixel 128).
	const LocalVector<float> cells = step_field();
	CHECK(relief_luma(cells, 16, 10, coarse(128), 4.5f, 0.3f) <= 0.33f);
	CHECK(relief_luma(cells, 16, 10, coarse(140), 4.5f, 0.3f) <= 0.33f);
}

TEST_CASE("[PathTracer][Relief] a bright pixel at the patch edge gets the patch's value") {
	// Pixel 127 is the last patch pixel: no brighter rim inside the patch either.
	const LocalVector<float> cells = step_field();
	CHECK(relief_luma(cells, 16, 10, coarse(127), 4.5f, 20.0f) >= 18.0f);
	CHECK(relief_luma(cells, 16, 10, coarse(115), 4.5f, 20.0f) >= 18.0f);
}

TEST_CASE("[PathTracer][Relief] black pixels and black cells stay finite") {
	LocalVector<float> cells;
	for (int i = 0; i < 16 * 10; i++) {
		cells.push_back(i % 3 == 0 ? 0.0f : 5.0f);
	}
	const float l = relief_luma(cells, 16, 10, coarse(64), 3.2f, 0.0f);
	CHECK(Math::is_finite(l));
	CHECK(l >= 0.0f);
}

} // namespace TestPTRelief
