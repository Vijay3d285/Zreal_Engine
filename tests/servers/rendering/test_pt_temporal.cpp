/**************************************************************************/
/*  test_pt_temporal.cpp                                                  */
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

TEST_FORCE_LINK(test_pt_temporal)

#include "servers/rendering/renderer_rd/effects/pt_temporal_state.h"

namespace TestPTTemporal {

TEST_CASE("[PathTracer][Temporal] the first frame has no history, the second does") {
	PTTemporalState s;
	CHECK_FALSE(s.begin_frame(Size2i(64, 32)));
	s.end_frame(Projection());
	CHECK(s.begin_frame(Size2i(64, 32)));
}

TEST_CASE("[PathTracer][Temporal] a size change drops the history") {
	PTTemporalState s;
	s.begin_frame(Size2i(64, 32));
	s.end_frame(Projection());
	CHECK_FALSE(s.begin_frame(Size2i(128, 32)));
	s.end_frame(Projection());
	CHECK(s.begin_frame(Size2i(128, 32)));
}

TEST_CASE("[PathTracer][Temporal] the read side alternates and the write side is the other one") {
	PTTemporalState s;
	CHECK(s.read_index == 0u);
	CHECK(s.write_index() == 1u);
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.read_index == 1u);
	CHECK(s.write_index() == 0u);
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.read_index == 0u);
}

TEST_CASE("[PathTracer][Temporal] invalidate starts over") {
	PTTemporalState s;
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	s.begin_frame(Size2i(8, 8));
	s.end_frame(Projection());
	CHECK(s.frames_denoised == 2u);
	s.invalidate();
	CHECK(s.frames_denoised == 0u);
	CHECK_FALSE(s.begin_frame(Size2i(8, 8)));
}

TEST_CASE("[PathTracer][Temporal] end_frame keeps the camera for the next frame") {
	PTTemporalState s;
	Projection p;
	p.columns[3][0] = 2.5f;
	s.begin_frame(Size2i(8, 8));
	s.end_frame(p);
	CHECK(s.prev_vp.columns[3][0] == doctest::Approx(2.5f));
}

TEST_CASE("[PathTracer][Temporal] the sample offset continues the sequence only while the reuse is on") {
	CHECK(PTTemporalState::sample_offset(0, 24, 48) == 0u);
	CHECK(PTTemporalState::sample_offset(3, 24, 48) == 72u);
	CHECK(PTTemporalState::sample_offset(3, 24, 0) == 0u);
}

} // namespace TestPTTemporal
