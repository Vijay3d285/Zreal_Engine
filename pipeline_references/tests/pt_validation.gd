extends Node
class_name PTValidation

## Measurement harness for path-tracer quality work.
##
## Two metrics matter for Phase A:
##   1. convergence_curve() - RMSE against a high-sample reference as a function
##      of accumulated frames. A correct accumulator falls roughly as 1/sqrt(N).
##      A stalled one flattens out. This is what catches an fp16-style defect.
##   2. edge_gradient_steps() - how many intermediate tones a high-contrast edge
##      resolves. Without camera jitter this is 0-1 at any frame count.

## Root-mean-square error between two same-size linear images (RGB only).
static func rmse(p_a: Image, p_b: Image) -> float:
	assert(p_a.get_size() == p_b.get_size(), "rmse: size mismatch")
	var acc := 0.0
	var n := 0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var ca := p_a.get_pixel(x, y)
			var cb := p_b.get_pixel(x, y)
			acc += (ca.r - cb.r) * (ca.r - cb.r)
			acc += (ca.g - cb.g) * (ca.g - cb.g)
			acc += (ca.b - cb.b) * (ca.b - cb.b)
			n += 3
	return sqrt(acc / float(max(n, 1)))

## Counts pixels along scanline `p_y` whose luminance sits strictly between the
## darkest and brightest values on that line. A hard-aliased edge yields 0-1;
## a properly filtered edge yields several.
static func edge_gradient_steps(p_img: Image, p_y: int) -> int:
	var lo := INF
	var hi := -INF
	for x in range(p_img.get_width()):
		var l := _luma(p_img.get_pixel(x, p_y))
		lo = min(lo, l)
		hi = max(hi, l)
	if hi - lo < 1e-4:
		return 0
	var band_lo := lo + (hi - lo) * 0.15
	var band_hi := lo + (hi - lo) * 0.85
	var steps := 0
	for x in range(p_img.get_width()):
		var l := _luma(p_img.get_pixel(x, p_y))
		if l > band_lo and l < band_hi:
			steps += 1
	return steps

static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## Renders the current scene at each frame count in `p_frame_counts`, then
## reports RMSE against a reference rendered at `p_reference_frames`.
## Returns an Array of { "frames": int, "rmse": float }.
func convergence_curve(p_env: Environment, p_frame_counts: Array,
		p_reference_frames: int = 4096) -> Array:
	var vp_rid := get_viewport().get_viewport_rid()

	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_reference_frames
	var reference := await _render_accum(p_env, vp_rid, p_reference_frames)
	assert(reference != null, "convergence_curve: reference render failed")

	var results: Array = []
	for frames in p_frame_counts:
		var img := await _render_accum(p_env, vp_rid, int(frames))
		if img == null:
			push_warning("convergence_curve: render failed at %d frames" % frames)
			continue
		results.append({ "frames": int(frames), "rmse": PTValidation.rmse(img, reference) })
	return results

## Drives a fresh accumulation of exactly `p_frames` frames and reads the
## linear accumulator back. Toggling accumulate off/on forces accum_reset_pending
## in the C++ driver, so each run starts from a cleared buffer.
func _render_accum(p_env: Environment, p_vp_rid: RID, p_frames: int) -> Image:
	p_env.pathtracing_accumulate = false
	await get_tree().process_frame
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for i in range(p_frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return RenderingServer.viewport_get_pathtracing_accum_image(p_vp_rid)

## Prints the curve and asserts convergence in TWO ways: the overall reduction
## from first to last, AND that the final consecutive segment is still improving.
## The second check is the one that matters: the regression this harness exists
## to catch is a LATE-stage stall (e.g. an fp16 accumulator freezing at high
## sample counts) where early segments converge normally but the tail flattens.
## A first-vs-last check alone is fooled by the healthy early segments.
## NOTE: assumes p_frame_counts was ascending (as in the usage example).
func report_convergence(p_results: Array) -> void:
	print("--- convergence curve ---")
	for r in p_results:
		print("  frames=%5d  rmse=%.6f" % [r["frames"], r["rmse"]])
	if p_results.size() >= 2:
		var first: float = p_results[0]["rmse"]
		var last: float = p_results[p_results.size() - 1]["rmse"]
		print("  reduction: %.2fx" % [first / max(last, 1e-9)])
		# Overall the curve must fall substantially across the whole sweep.
		assert(last < first * 0.5,
				"Accumulator is not converging: RMSE barely improved from first to last.")
		# AND the final segment (largest sample counts) must still be dropping.
		# A stalled tail gives last ~= prev (ratio ~1.0), which fails this; a
		# healthy 1/sqrt(N) segment gives last well below prev.
		var prev: float = p_results[p_results.size() - 2]["rmse"]
		assert(last < prev * 0.98,
				"Accumulator stalled in the final segment: RMSE stopped falling at high sample counts (the fp16-style late stall this harness guards against).")
