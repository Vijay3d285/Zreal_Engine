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

## Frames to hold each side of the accumulate off/on edge so the rendering
## server definitely observes the transition (see _render_accum).
const RESET_SETTLE_FRAMES := 3

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

	var ref_luma := mean_luma(reference)
	print("  reference: %d frames, mean_luma=%.5f" % [p_reference_frames, ref_luma])

	var results: Array = []
	for frames in p_frame_counts:
		var img := await _render_accum(p_env, vp_rid, int(frames))
		if img == null:
			push_warning("convergence_curve: render failed at %d frames" % frames)
			continue
		# Unqualified static call: referring to our own class_name here would need the
		# .godot class-name cache to exist, which it may not on a fresh checkout.
		var e := rmse(img, reference)
		var l := mean_luma(img)
		print("  run %5d frames: rmse=%.6f mean_luma=%.5f" % [int(frames), e, l])
		results.append({ "frames": int(frames), "rmse": e, "mean_luma": l })
	return results

## Drives a fresh accumulation of exactly `p_frames` frames and reads the
## linear accumulator back. Toggling accumulate off/on forces accum_reset_pending
## in the C++ driver, so each run starts from a cleared buffer.
func _render_accum(p_env: Environment, p_vp_rid: RID, p_frames: int) -> Image:
	# Adaptive sampling early-outs converged pixels, freezing them and flattening
	# the tail of the convergence curve. This harness must measure the
	# UN-accelerated estimator for the 1/sqrt(N) law to hold, so disable it here.
	p_env.pathtracing_noise_threshold = 0.0

	# Force the driver to observe a genuine true->false->true transition on the
	# accumulate flag; that edge is what sets accum_reset_pending and zeroes the
	# per-pixel sample counter. A single idle frame is NOT enough — the property
	# write reaches the rendering server asynchronously, so if both writes land
	# within one server frame the driver never sees the "off" state and simply
	# keeps accumulating. That produces a curve where every run is the same
	# already-converged image and RMSE *rises* as it drifts from the reference.
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame

	for i in range(p_frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return RenderingServer.viewport_get_pathtracing_accum_image(p_vp_rid)


## Mean luminance of an image — a cheap sanity probe. Two renders of the same
## scene must land within a few percent of each other; a large gap means the
## accumulator did not reset (or the readback grabbed a stale buffer).
static func mean_luma(p_img: Image) -> float:
	var acc := 0.0
	var n := 0
	# Stride-sample: full-res per-pixel iteration is slow in GDScript and this is
	# only a diagnostic.
	var step := maxi(1, int(p_img.get_width() / 128))
	for y in range(0, p_img.get_height(), step):
		for x in range(0, p_img.get_width(), step):
			acc += _luma(p_img.get_pixel(x, y))
			n += 1
	return acc / float(maxi(n, 1))

## Prints the curve and judges convergence in TWO ways: the overall reduction
## across the sweep, AND whether the final consecutive segment is still improving.
## The second check is the one that matters: the regression this harness exists
## to catch is a LATE-stage stall (e.g. an fp16 accumulator freezing at high
## sample counts) where early segments converge normally but the tail flattens.
## A first-vs-last check alone is fooled by the healthy early segments.
##
## Returns an Array of human-readable failure strings — empty means healthy.
## It deliberately does NOT assert: an assert aborts the whole run, so a caller
## that wants to perform further checks (or report every failure at once) could
## never reach them. Callers gate on the returned array.
##
## NOTE: assumes p_frame_counts was ascending (as in the usage example).
func report_convergence(p_results: Array) -> Array:
	var failures: Array = []
	print("--- convergence curve ---")
	for r in p_results:
		print("  frames=%5d  rmse=%.6f" % [r["frames"], r["rmse"]])
	if p_results.size() < 2:
		return failures

	var first: float = p_results[0]["rmse"]
	var last: float = p_results[p_results.size() - 1]["rmse"]
	var first_n: float = float(p_results[0]["frames"])
	var last_n: float = float(p_results[p_results.size() - 1]["frames"])
	var got: float = first / max(last, 1e-9)

	# The achievable reduction is set by the sweep width, not by a fixed constant:
	# error falls as 1/sqrt(N), so going from first_n to last_n samples can at best
	# improve by sqrt(last_n/first_n). A narrow sweep (e.g. 16 -> 64 = 2.0x ceiling)
	# can never clear a hardcoded 2x bar, which would fail a perfectly healthy
	# accumulator. Demand a fraction of the theoretical ceiling instead. The gap is
	# expected: the reference render carries its own noise, which adds in quadrature
	# and compresses the measured ratio.
	var ideal: float = sqrt(max(last_n / max(first_n, 1.0), 1.0))
	var required: float = ideal * 0.6
	print("  reduction: %.2fx (theoretical ceiling %.2fx, need >= %.2fx)" % [got, ideal, required])
	if got < required:
		failures.append("convergence: RMSE fell only %.2fx across the sweep; expected >= %.2fx for %d -> %d samples."
				% [got, required, int(first_n), int(last_n)])

	# AND the final segment (largest sample counts) must still be dropping.
	# A stalled tail gives last ~= prev (ratio ~1.0), which fails this; a
	# healthy 1/sqrt(N) segment gives last well below prev.
	var prev: float = p_results[p_results.size() - 2]["rmse"]
	if last >= prev * 0.98:
		failures.append("convergence: FLAT TAIL — RMSE stopped falling at high sample counts (%.6f -> %.6f). This is the fp16-style late stall this harness guards against."
				% [prev, last])
	return failures
