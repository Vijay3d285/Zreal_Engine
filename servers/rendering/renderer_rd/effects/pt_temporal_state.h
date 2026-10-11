/**************************************************************************/
/*  pt_temporal_state.h                                                   */
/**************************************************************************/

#pragma once

#include "core/math/projection.h"
#include "core/math/vector2i.h"

// Frame-to-frame bookkeeping for the path tracer's temporal reuse (spec
// docs/superpowers/specs/2026-10-10-video-temporal-reuse-design.md). Pure C++, no
// RenderingDevice, so tests/servers/rendering/test_pt_temporal.cpp drives it directly.
// Lives on RTViewportState, apart from the accumulator: the video route resets the
// accumulator every frame (accumulate off/on), and that must not touch the history.
struct PTTemporalState {
	bool history_valid = false; // the read-side history holds a previous frame of history_size
	Size2i history_size;
	uint32_t read_index = 0; // which of the two history sets holds the previous frame
	uint32_t frames_denoised = 0; // frames blended since the reuse was switched on
	Projection prev_vp; // previous delivered frame's view-projection (depth-corrected)

	// Once per delivered frame, before the blend. False on the first frame, after a size
	// change, and after invalidate().
	bool begin_frame(const Size2i &p_size) {
		if (p_size != history_size) {
			history_valid = false;
			history_size = p_size;
		}
		return history_valid;
	}

	// After the blend wrote the write side: it becomes the read side for the next frame.
	void end_frame(const Projection &p_vp) {
		read_index = 1u - read_index;
		prev_vp = p_vp;
		history_valid = true;
		frames_denoised++;
	}

	uint32_t write_index() const { return 1u - read_index; }

	// The reuse is off: the next frame it runs on starts with no history.
	void invalidate() {
		history_valid = false;
		frames_denoised = 0;
	}
};
