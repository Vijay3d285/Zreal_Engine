extends RefCounted

## NO class_name. A global class name is resolved through
## .godot/global_script_class_cache.cfg, which only the editor's import step
## writes; the live pipeline launches Godot headless straight into main.tscn
## with no .godot/ directory, so `Daylight` was "not declared in the current
## scope" there (2026-09-20) while every editor-imported copy worked. Consumers
## preload this file instead: `const Daylight = preload("res://daylight.gd")`.

## Daylight design for day renders (docs/superpowers/specs/2026-09-19-daylight-design.md).
##
## Pure functions plus one coroutine, shared by the pipeline (render.gd /
## image_glb_creation.gd) and pt_daylight_gate.gd so the gate proves the code
## the pipeline runs. Nothing here touches the scene tree except through the
## node handed to probe().
##
## Units: the tracer reads a white Lambertian surface under a uniform sky of
## radiance L as L (irradiance pi*L), and a DirectionalLight3D of energy E at
## incidence theta reads E*cos(theta), i.e. irradiance pi*E*cos(theta) --
## measured by pt_daylight_gate D2, 2026-09-19. The panorama is normalised so
## a horizontal surface receives irradiance exactly 1 from the sky; the sun
## is then SUN_TO_SKY in the same units, via SUN_ENERGY.

## Direct-normal over diffuse-horizontal irradiance for a 10 AM clear sky:
## ~90 klux direct vs ~18 klux diffuse. The one look-defining constant.
const SUN_TO_SKY := 5.0
const SUN_ENERGY := SUN_TO_SKY / PI  # DirectionalLight3D.light_energy: energy E is irradiance pi*E in the tracer
## Photographic mid-grey: the occupied frame's median after exposure.
const TARGET_MEDIAN := 0.18
## Darkest occupied quarter must reach this after exposure, or a fill is added.
const FLOOR := 0.02
## Pixels above MASK_RATIO x the raw median are sky seen through windows
## (a physical sky is 50-100x the wall) and are excluded from the statistics.
const MASK_RATIO := 8.0
const PROBE_FRAMES := 16
## Statistics are taken at every PROBE_STEP-th pixel in x and y.
const PROBE_STEP := 4
const EXPOSURE_MIN := 0.05
const EXPOSURE_MAX := 50.0
## The fill may supply at most this share of the occupied median.
const FILL_SHARE_CAP := 0.5
const FILL_SCAN_START := 0.01
const FILL_SCAN_STEP := 1.1
const FILL_SCAN_MAX_ITER := 400
## Downsample the panorama to this before integrating (256 x 128 of an
## 8192 x 4096 EXR estimates its full-resolution irradiance within 1%).
const IRRADIANCE_W := 256
const IRRADIANCE_H := 128
## Frames to hold each side of the accumulate off/on edge so the rendering
## server observes the transition (pt_validation.gd RESET_SETTLE_FRAMES).
const RESET_SETTLE_FRAMES := 3

## Local highlight relief (spec 2026-09-28-local-highlight-relief-design.md).
##
## RELIEF_KNEE is in POST-EXPOSURE linear units, the same units the tone curve
## sees. AgX's crossover is 0.18 (middle grey) and its white is 16.29, so a
## sample at 3.0 is already deep in the shoulder and heading for the ceiling
## while one at 1.0 still has room. 3.0 leaves normal bright surfaces --
## a white wall at 0.18, a lamp shade at 1-2 -- completely untouched.
##
## 3.0 is a MEASUREMENT, not a derivation (2026-09-29, knee sweep on job 201 at
## 1080p, knees 4.0 / 3.0 / 2.0; the owner chose 3.0). At knee 3.0 the probe
## measured strength 0.753 and the sun patch's clipping fell to 0.68% at 254+
## and 6.51% at 250+ (23.25% / 24.30% with relief off); the patch median
## reached 248.21 (255 off); the flat wall did not move (168.224, same as
## relief off); the inner annulus (8-48 px outside the patch) darkened 2.83%.
## Knee 4.0 (strength 0.677) left the patch a white slab -- median 252.07, 21.41%
## still at 250+. Knee 2.0 (strength 0.829) was rejected: it reached the patch
## (median 240.28) but visibly dimmed other highlights in the frame -- dark
## smudges under each downlight, dimmed air-conditioner LED strips, the window
## jamb and the side-table lamp. The C++ default of
## rendering/pathtracer/highlight_relief_knee (rendering_server.cpp) must equal
## this, so the decision and the operator agree even if render.gd never runs.
const RELIEF_KNEE := 3.0
## Below this fraction of samples past the knee, do nothing at all: the pass is
## not dispatched and the render is byte-identical to a build without this
## feature. Job 201 measured 4.17% of the FRAME clipped, and its sun patch is
## the case this exists for; 0.01 is well under that and well over the stray
## specular highlight that should not trigger a whole-frame operation.
const RELIEF_MIN_FRACTION := 0.01
## Cap on the gain exponent. At strength s the gain at luminance L is
## 1/(1 + s*(L/knee - 1)), so s = 1.0 halves the gain one knee past the knee.
## Capped so a pathological frame cannot drive the image to black.
const RELIEF_MAX_STRENGTH := 1.0


## Upward-facing irradiance of an equirect panorama (v = 0 is the zenith, as
## Godot's PanoramaSkyMaterial maps it: v = acos(dir.y) / PI):
##   E = sum over rows with theta < pi/2, all columns, of
##       L * cos(theta) * sin(theta) * (2 pi / W) * (pi / H)
## A uniform sky of radiance 1 gives pi. Same integral as
## pt_sky_energy_gate.gd _analytic_outgoing_radiance() without the azimuthal
## shortcut.
static func sky_irradiance(p_img: Image) -> float:
	var img := p_img
	if p_img.get_width() > IRRADIANCE_W or p_img.get_height() > IRRADIANCE_H:
		img = p_img.duplicate()
		# Bicubic at a 32x reduction (8192 -> 256) POINT-SAMPLES: it reads a
		# small neighbourhood around each output texel from the FULL-RES
		# image and ignores the rest, so any feature narrower than the
		# sampling stride -- a sun disc, a bright window -- is normalised by
		# luck, depending only on whether it happens to land under a sample.
		# generate_mipmaps() box-filters the whole image down through every
		# power-of-two level first; INTERPOLATE_TRILINEAR then blends the two
		# mip levels bracketing the target size, so every output texel is an
		# area average of the corresponding source region instead of a
		# point sample of it.
		if img.get_mipmap_count() == 0:
			img.generate_mipmaps()
		img.resize(IRRADIANCE_W, IRRADIANCE_H, Image.INTERPOLATE_TRILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var d_theta := PI / float(h)
	var d_phi := TAU / float(w)
	var e := 0.0
	for y in range(h):
		var theta := (float(y) + 0.5) * d_theta
		if theta >= PI * 0.5:
			break
		var weight := cos(theta) * sin(theta) * d_theta * d_phi
		var row := 0.0
		for x in range(w):
			var c := img.get_pixel(x, y)
			row += (c.r + c.g + c.b) / 3.0
		e += row * weight
	return e


## Mean-RGB luminance of p_step x p_step BOX AVERAGES, row-major. p_step
## must be a power of two (1, 2, 4, 8): each shrink_x2() halves the image
## with an exact 2x2 mean in C++. Box averages rather than point samples:
## the sample median of noisy pixels is biased low (path-tracing noise is
## right-skewed) -- a point-sampled 16-frame probe read 7.5% under the
## 256-frame still on the gate's windowed room; averaging 16 pixels first
## cuts the per-sample variance 16x and the skew with it (spec section 2).
static func subsample(p_img: Image, p_step: int) -> PackedFloat32Array:
	var img: Image = p_img.duplicate()
	var step := maxi(1, p_step)
	assert((step & (step - 1)) == 0, "subsample: p_step must be a power of two") # == binds tighter than & in GDScript
	while step > 1 and img.get_width() >= 2 and img.get_height() >= 2:
		img.shrink_x2()
		step /= 2
	var out := PackedFloat32Array()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			out.append((c.r + c.g + c.b) / 3.0)
	return out


static func _percentile(p_sorted: PackedFloat32Array, p_q: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	var idx := int(floor(p_q * float(p_sorted.size() - 1)))
	return p_sorted[clampi(idx, 0, p_sorted.size() - 1)]


## Occupancy mask + exposure from a probe's luminance samples.
## Returns {raw_median, median, p25, occupied_fraction, exposure, clamped}.
## `median` and `p25` are over the OCCUPIED samples (<= MASK_RATIO x raw median).
static func stats(p_samples: PackedFloat32Array) -> Dictionary:
	var sorted := p_samples.duplicate()
	sorted.sort()
	var raw_median := _percentile(sorted, 0.5)
	var occupied := PackedFloat32Array()
	var cut := raw_median * MASK_RATIO
	for v in sorted:
		if v <= cut:
			occupied.append(v)
		else:
			break # sorted ascending: everything after is excluded too
	var median := _percentile(occupied, 0.5)
	var p25 := _percentile(occupied, 0.25)
	var clamped := false
	var exposure := EXPOSURE_MAX
	if median > 0.0:
		exposure = TARGET_MEDIAN / median
	else:
		clamped = true # a black frame: nothing to expose for
	if exposure < EXPOSURE_MIN or exposure > EXPOSURE_MAX:
		clamped = true
		exposure = clampf(exposure, EXPOSURE_MIN, EXPOSURE_MAX)
	return {
		"raw_median": raw_median,
		"median": median,
		"p25": p25,
		"occupied_fraction": float(occupied.size()) / float(maxi(p_samples.size(), 1)),
		"exposure": exposure,
		"clamped": clamped,
	}


## How much local highlight relief this frame needs, from the SAME samples the
## exposure probe already collected -- no extra render.
##
## Returns {needed: bool, strength: float, clipped_fraction: float}.
## `needed` false always pairs with `strength` EXACTLY 0.0, which is the
## contract the engine's gate relies on: at 0.0 the pass is never dispatched.
##
## strength is driven by the MEDIAN excess of the over-knee samples, not their
## maximum: one runaway firefly must not set the strength for the whole frame.
static func highlight_relief(p_samples: PackedFloat32Array, p_exposure: float) -> Dictionary:
	var off := {"needed": false, "strength": 0.0, "clipped_fraction": 0.0}
	if p_samples.is_empty() or not (p_exposure > 0.0):
		return off
	var over := PackedFloat32Array()
	for v in p_samples:
		var e := v * p_exposure
		if e > RELIEF_KNEE:
			over.append(e)
	var fraction := float(over.size()) / float(p_samples.size())
	if fraction < RELIEF_MIN_FRACTION:
		return {"needed": false, "strength": 0.0, "clipped_fraction": fraction}
	over.sort()
	var median_excess: float = _percentile(over, 0.5) / RELIEF_KNEE - 1.0
	# A median excess of one knee (i.e. 2x the knee) asks for half strength;
	# it saturates smoothly rather than stepping at any particular value.
	var strength: float = RELIEF_MAX_STRENGTH * (median_excess / (median_excess + 1.0))
	return {
		"needed": true,
		"strength": clampf(strength, 0.0, RELIEF_MAX_STRENGTH),
		"clipped_fraction": fraction,
	}


## Fill energy from two probes: p_s0 without the fill, p_s1 with it at energy
## 1.0 (same pixels, same order). Per pixel L(f) = L0 + f (L1 - L0). Scans f
## geometrically from FILL_SCAN_START and returns the first f whose
## p25(f) * e(f) reaches FLOOR, with e(f) = TARGET_MEDIAN / median(f)
## recomputed at every step (the fill lifts the median too). Capped where
## the fill's share of the occupied median, (median(f) - median(0)) /
## median(f), reaches FILL_SHARE_CAP.
## Degenerate input (p_s1 empty, or its size does not match p_s0 -- e.g. the
## second probe's accumulator readback failed) -> no fill: without a real
## second sample there is nothing to mix, and the geometric scan below would
## otherwise run every one of its FILL_SCAN_MAX_ITER iterations against an
## empty/zero mix (stats(empty) is clamped with p25 0, so neither exit
## condition ever fires) and return an energy on the order of
## FILL_SCAN_START * FILL_SCAN_STEP^FILL_SCAN_MAX_ITER -- effectively infinite.
## Loop exhaustion (FILL_SCAN_MAX_ITER steps without either exit condition
## firing) is ALSO no fill, for the same reason: a fill that cannot move the
## median or the darkest quarter -- placed outside the room, above a low
## ceiling, leaking through a doorway rather than into the occupied
## space -- is no fill, not an energy of 0.01 * 1.1^400 pretending to be one.
## p_floor overrides FLOOR (spec F2: ZR_DAYLIGHT_FLOOR forces the trigger for
## a forced test render; stats()'s own exposure target, TARGET_MEDIAN, is
## unaffected).
## Returns {needed, energy, exposure, median, p25, capped, exhausted}.
static func solve_fill(p_s0: PackedFloat32Array, p_s1: PackedFloat32Array, p_floor: float = FLOOR) -> Dictionary:
	var base := stats(p_s0)
	if base["p25"] * base["exposure"] >= p_floor:
		return {"needed": false, "energy": 0.0, "exposure": base["exposure"],
				"median": base["median"], "p25": base["p25"], "capped": false, "exhausted": false}
	if p_s0.is_empty() or p_s1.is_empty() or p_s0.size() != p_s1.size():
		return {"needed": false, "energy": 0.0, "exposure": base["exposure"],
				"median": base["median"], "p25": base["p25"], "capped": false, "exhausted": false}
	var n := mini(p_s0.size(), p_s1.size())
	var f := FILL_SCAN_START
	var mixed := PackedFloat32Array()
	mixed.resize(n)
	for _i in range(FILL_SCAN_MAX_ITER):
		for k in range(n):
			mixed[k] = p_s0[k] + f * (p_s1[k] - p_s0[k])
		var st := stats(mixed)
		var share := 0.0
		if st["median"] > 0.0:
			share = (st["median"] - base["median"]) / st["median"]
		if st["p25"] * st["exposure"] >= p_floor:
			return {"needed": true, "energy": f, "exposure": st["exposure"],
					"median": st["median"], "p25": st["p25"], "capped": false, "exhausted": false}
		if share >= FILL_SHARE_CAP:
			return {"needed": true, "energy": f, "exposure": st["exposure"],
					"median": st["median"], "p25": st["p25"], "capped": true, "exhausted": false}
		f *= FILL_SCAN_STEP
	return {"needed": false, "energy": 0.0, "exposure": base["exposure"],
			"median": base["median"], "p25": base["p25"], "capped": false, "exhausted": true}


## Drives a fresh accumulation of p_frames frames and reads the linear
## accumulator back, subsampled. p_node is any node in the tree (for
## process_frame); p_env the Environment; p_vp the viewport RID.
## Transcribed from pt_validation.gd _render_accum(): the accumulate flag
## must be seen off for several server frames before it is set on again, or
## the driver keeps the old average.
static func probe(p_node: Node, p_env: Environment, p_vp: RID, p_frames: int = PROBE_FRAMES, p_step: int = PROBE_STEP) -> Dictionary:
	var prev_target := p_env.pathtracing_accumulation_target
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	for _i in range(p_frames):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = RenderingServer.viewport_get_pathtracing_accum_image(p_vp)
	p_env.pathtracing_accumulation_target = prev_target
	if img == null or img.is_empty():
		return {"samples": PackedFloat32Array(), "width": 0, "height": 0}
	return {"samples": subsample(img, p_step), "width": img.get_width(), "height": img.get_height()}


## Offscreen counterpart of probe(): the same measurement, taken from a viewport
## that is NOT the one being recorded, in ZERO main-loop iterations.
##
## probe() paces itself on process_frame, so every probe frame is also a frame of
## the main viewport. A video written with --write-movie gets one movie frame per
## main-loop iteration (Main::iteration -> movie_writer->add_frame, which reads the
## MAIN viewport's texture), so a probe spanning 69 iterations puts 69 frames in the
## movie whichever viewport did the tracing. This function spends no iterations: it
## drives RenderingServer.force_draw() itself (force_draw does not reach
## movie_writer->add_frame and does not advance Engine.get_frames_drawn()) and
## returns in the same call. Same protocol and the same number of draws as probe():
## accumulate off for RESET_SETTLE_FRAMES, on for RESET_SETTLE_FRAMES + p_frames,
## read back, subsample.
##
## Contract with the caller (video_render.gd :: _run_daylight_probe):
##  * p_vp is the RID of a 3D SubViewport with render_target_update_mode ALWAYS,
##    sharing the scene's World3D, whose Camera3D resolves p_env through
##    Camera3D.environment; the camera is already on the pose to measure.
##  * p_env is a DUPLICATE of the scene's Environment that no other camera uses:
##    this function writes its accumulate flag and target. (Those are Environment
##    properties, so writing them on the scene's own Environment would switch
##    accumulation on for the recorded viewport too.)
##  * force_draw() draws every viewport in the active list on every call, so the
##    caller must set the recorded viewport's update mode to VIEWPORT_UPDATE_DISABLED
##    for the duration. It must NOT deactivate it: _sort_active_viewports() seeds its
##    list with ROOT viewports and walks down to their children, so a deactivated
##    recorded viewport takes p_vp out of the draw list with it -- p_vp is then never
##    drawn, never gets render buffers, and this function returns nothing.
static func probe_offscreen(p_env: Environment, p_vp: RID, p_frames: int = PROBE_FRAMES, p_step: int = PROBE_STEP) -> Dictionary:
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		RenderingServer.force_draw(false)
	p_env.pathtracing_accumulate = true
	p_env.pathtracing_accumulation_target = p_frames
	for _i in range(RESET_SETTLE_FRAMES + p_frames):
		RenderingServer.force_draw(false)
	var img: Image = RenderingServer.viewport_get_pathtracing_accum_image(p_vp)
	if img == null or img.is_empty():
		return {"samples": PackedFloat32Array(), "width": 0, "height": 0}
	return {"samples": subsample(img, p_step), "width": img.get_width(), "height": img.get_height()}


## Resets the accumulator the same way probe() does, without rendering
## anything: call before the final still so it starts from a cleared buffer.
static func reset_accumulator(p_node: Node, p_env: Environment) -> void:
	p_env.pathtracing_accumulate = false
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
	await RenderingServer.frame_post_draw
	p_env.pathtracing_accumulate = true
	for _i in range(RESET_SETTLE_FRAMES):
		await p_node.get_tree().process_frame
