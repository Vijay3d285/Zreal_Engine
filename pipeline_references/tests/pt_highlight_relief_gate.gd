extends "res://tests/pt_validation.gd"

# Preloaded, not a global class name: the live pipeline has no class cache.
const Daylight = preload("res://daylight.gd")

## Local highlight relief gate (spec 2026-09-28-local-highlight-relief-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_highlight_relief_gate_scene.tscn
##
## Fixture: a closed Lambertian box with a large, very bright emissive patch on
## the floor several stops above the room -- the minimum that reproduces the
## production case (a sun patch the room's exposure cannot hold). See "Why the
## patch is this big" below for how it is sized.
##
##   H0 inert  : relief off renders identically to the recorded baseline.
##   H1 relief : patch clipping falls by at least H1_MIN_REDUCTION.
##   H2 midtone: wall mean moves less than H2_TOL. A highlight operator must
##               not behave like an exposure change.
##   H3 halo   : the annulus just outside the patch does not darken by more
##               than H3_MAX_DARKENING.
##   H4 gate   : a frame with no blown area gets strength 0 and is identical
##               to the same frame with the feature compiled in but off.
##
## Deviations from the task-4 brief's script (task-4-report.md has the full
## account of each). Round 1, both required for this to be a real instrument
## rather than one that reads the same regardless of whether relief runs:
##   - Measurement reads get_viewport().get_texture().get_image() (HDR 2D)
##     after two settle frames, not _render_accum()'s return value. Relief
##     writes get_internal_texture(); the accumulator _render_accum() returns
##     is a different RID relief never touches, so H1-H3 as originally written
##     measured off vs on identically no matter what the operator did.
##   - H4 renders a fixture with the hot patch omitted (_render_fixture(0.0,
##     false)) instead of reusing `off`, which is this gate's own H1-H3 room
##     with relief simply disabled -- it clips by construction (see H1's
##     premise check) and so can only fail an "unlit fixture" assertion.
## Round 2 (2026-09-29), after the dispatch fix and the job 201 measurement:
##   - The knee is Daylight.RELIEF_KNEE (3.0), not a private 4.0.
##   - The patch is large relative to the blur (SIZE 512, PATCH_SIDE 2.0), with
##     its emission scaled to keep the room where it was (HOT_EMISSION).
##   - Crops are checked against the camera's own projection of the patch.
##   - Informational lines print the patch ceiling and a ring profile; they are
##     not checks. ZR_GATE_DUMP writes off.pfm / on.pfm.
##
## Why the patch is this big. The first fixture (256 px frame, 1 m patch, 102 x
## 50 px on screen) was measured on the fixed engine at 0.020 reduction and
## 15.6% annulus darkening, while job 201 -- a real render of the case this
## operator exists for -- passed all three production bars (sun-patch clipping
## 23.25% -> 4.46% at knee 4.0, flat wall unchanged to four decimals, 1.80%
## darkening at 8-48 px). Independent evidence that the operator works, against
## a gate that said it did not, means the gate was not exercising the case: the
## blur reaches BLUR_PX = 32 px each side, and a patch 1.6 reaches tall never
## gets to the plateau where the gain is set by the patch alone. Job 201's
## sunlit patch is about 250 px across against the same 32 px (62,526 lit
## pixels), about 8 reaches; this fixture is 7-13 x 5 (427 x 163 px, 228 wide at
## the far edge).
##
## The risk in that argument is real and worth saying: enlarging a fixture until
## a gate passes is tuning the instrument to get the answer wanted. What keeps
## it honest here is (1) the size was fixed from a ratio measured on job 201 and
## the shader's own reach, before the run, not adjusted to the result; (2) the
## first enlarged run failed H2 (emission 60 over 4x the area lit the walls past
## the knee) and the one change made in response was forced by area, not by the
## outcome; (3) an exact numpy port of local_highlight.glsl predicted this
## fixture's readings before it ran and matched them (patch interior 5.133 by the
## closed form at the measured 17.77 vs 5.132 measured, 1-8 px ring 21.0% vs
## 22.8%, everything past 8 px exactly 0); and
## (4) H1_MIN_REDUCTION was not touched and H1 still fails -- see the note on it
## below. What this fixture does NOT do is reproduce job 201's halo: its patch
## edge is a hard step, so the operator's darkening stays inside 8 px of the
## edge here, where job 201's soft-edged, textured patch shows 4.68% at 8-24 px
## and 1.59% at 24-48 px.

const FRAMES := 64
const STRENGTH := 0.5
# The knee the pipeline uses, not a private copy: render.gd writes
# Daylight.RELIEF_KNEE into the project setting and the C++ default matches it,
# so this gate must measure at that knee or it tests a configuration nobody runs.
# (2026-09-29: 4.0 -> 3.0 with the job 201 knee sweep; this gate's own copy of
# 4.0 would otherwise have silently kept measuring the old value.)
const KNEE := Daylight.RELIEF_KNEE
const SETTING_STRENGTH := "rendering/pathtracer/highlight_relief_strength"
const SETTING_KNEE := "rendering/pathtracer/highlight_relief_knee"
const ALBEDO := 0.5
# H1's bar is the production acceptance restated on this fixture. It is NOT
# tunable downward: if the operator cannot reach it, that is a design failure
# to report (spec, "Gate").
#
# 2026-09-29: this check FAILS on the representative fixture (reduction 0.000)
# and the reason is in how it counts, not in the fixture size. It counts patch
# pixels at or above the knee (_clipped_fraction). For a uniform region at
# luminance L the operator returns L / (1 + s (L/knee - 1)), which is above the
# knee for every L above it and only approaches knee/s from below as L grows, so
# a pixel that starts over the knee ends over it whatever the patch size or
# strength; only pixels dimmer than their own blurred surroundings can fall
# under. Job 201's criterion is different: pixels at 254+ AFTER the tone curve,
# which saturates well above the knee, so relief's output can leave that band.
# Measured on this fixture's patch crop (interior 17.77 -> 5.13): the count of
# pixels >= T falls by 0.000 for every T up to 4.8 and by 1.000 for every T from
# 5.5 up -- a step at the operator's output level, so the verdict is set by where
# T is put, not by whether relief works. Not changed here: choosing a different
# "would clip" line for this gate is a decision about what the gate means (see
# task-4-report.md round 2).
const H1_MIN_REDUCTION := 0.40
const H2_TOL := 0.01
# H3 had no defensible value before the blur radius was measured. It is now set
# from a measurement, on this fixture, with the reasoning below.
#
# 2026-09-29: annulus (8-48 px below the patch, the band job 201's ring_near
# used) darkening measured 0.0000 on this fixture at strength 0.50, knee 3.00,
# on a build of 1508348733 + the knee change, in identical repeat runs (renders
# are deterministic on this build, so there is no run-to-run spread to size a
# margin from). Margin +0.02, absolute: it covers driver and GPU differences
# and small fixture edits, and stays well under the 5% production acceptance
# (job 201: 1.80% at knee 4.0, 2.83% at knee 3.0) so a pass here cannot hide a
# halo production would reject.
#
# What this bound guards and what it does not: with this fixture's hard patch
# edge the gain field is 1.0 beyond about 8 px from the edge (the blurred
# luminance falls under the knee), so a reading of exactly 0 is the operator's
# design, and H3 catches a change that pushes the halo OUT of that core (a wider
# blur, a lower knee at fixed contrast). The halo itself -- 22.8% at 1-8 px on
# this fixture -- is in the informational ring profile, not in H3.
#
# History: on 2026-09-28 the committed gate read 0.0000 because relief never
# dispatched with both denoisers off (rt_accum_target was only computed when
# OIDN or DLSS-RR-final was on; fixed in 1508348733), and a forced-dispatch
# diagnostic on the small fixture read 0.1537. Neither is a measurement of this
# fixture; both are kept here so the number's provenance is not lost.
const H3_MAX_DARKENING := 0.02

# Frame size and patch size. The blur footprint is a fixed number of PIXELS
# (see BLUR_PX), so what decides whether the fixture exercises the operator is
# the patch's size in pixels, not in metres: SIZE and PATCH_SIDE are two knobs
# on one ratio. At 512 px a 2.0 m patch centred on the floor projects to about
# 427 x 163 px overall (228 px wide at the far edge), i.e. 13 x 5 blur reaches
# at most. The first fixture (256 px, 1.0 m) projected to 102 x 50 px, 3 x 1.6.
const SIZE := 512
const PATCH_SIDE := 2.0
const PATCH_CZ := 0.0
# The blur's reach, read off local_highlight.glsl: each luma texel is the mean of
# a 16 x 16 source box (16 taps, 4 px apart), and the apply pass upsamples the
# luma map bilinearly, so a pixel's gain depends on texels up to one texel away:
# 16 px of box plus 16 px of upsample reach is 32 px each side of a pixel.
const BLUR_PX := 32
# Job 201's own inner-annulus definition (8-48 px outside the patch, in pixels)
# so this gate's H3 reads the same band the production measurement did.
const ANNULUS_NEAR_PX := 8
const ANNULUS_FAR_PX := 48

# The patch's luminance. The brief's 1 m patch at 60 put 60 x 1 m^2 of emitted
# power into the room and left the walls at 1.28, under the knee. The 2 m patch
# is four times the area, so the same 60 would put 240 in and push the walls to
# 3.40 -- past the knee, where relief acts on them legitimately and H2 fails for
# a reason that has nothing to do with the operator (measured, attempt 1 in
# task-4-report.md round 2). Emission scales as 1/area so the same power goes
# into the room and it stays under the knee (walls 1.47 here): 60 / 4 = 15. Independent cross-check: job 201's
# probe measured strength 0.753 at knee 3.0, which Daylight.highlight_relief
# inverts to a median over-knee sample of 3.0 * (1 + 0.753 / (1 - 0.753)) = 12.2
# post-exposure -- the same order as 15, and about 4x the knee either way.
const HOT_EMISSION := 15.0

# Crops, as fractions y0 y1 x0 x1. At SIZE 512 the patch projects to a trapezoid
# inside x 43-469, y 238-402 -- 228 px wide at the far edge, 427 at the near one
# (checked at run time by the "geometry" premises below):
#   PATCH   : y 271-369, x 164-348  -- at least BLUR_PX inside the trapezoid
#   ANNULUS : y 410-450, x 102-410  -- 8-48 px below the patch's near edge
#   WALL    : y 51-154,  x 51-154   -- the far wall, >= 2 blur reaches away
const PATCH := [0.53, 0.72, 0.32, 0.68]
const ANNULUS := [0.80, 0.88, 0.20, 0.80]
const WALL := [0.10, 0.30, 0.10, 0.30]

var _failures: Array[String] = []
var _checks: int = 0
var _cam: Camera3D
var _patch_px := Rect2()


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(SIZE, SIZE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	# Relief (like OIDN) lands in the viewport texture, not the raw accumulator
	# viewport_get_pathtracing_accum_image() reads -- see _render_fixture(). Without
	# HDR 2D that readback is 8-bit sRGB and every bright pixel this gate measures
	# would already be clamped to 1.0 before the KNEE=4.0 check ever saw it.
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== H0/H1/H2/H3: relief off vs on at strength %.2f ===" % STRENGTH)
	var off := await _render_fixture(0.0)
	var on := await _render_fixture(STRENGTH)
	_check_geometry()

	# Diagnostic dump (ZR_GATE_DUMP=<dir>, same variable the sibling gates use):
	# the relief-off and relief-on frames as PFM. off.pfm captured on a binary
	# built BEFORE the feature is the baseline H0 compares against
	# (ZR_RELIEF_BASELINE_REF).
	var dump_dir := OS.get_environment("ZR_GATE_DUMP")
	if dump_dir != "":
		_save_pfm(off, dump_dir.path_join("off.pfm"))
		_save_pfm(on, dump_dir.path_join("on.pfm"))

	var clip_off := _clipped_fraction(off, PATCH)
	var clip_on := _clipped_fraction(on, PATCH)
	var reduction := 1.0 - (clip_on / maxf(clip_off, 1e-9))
	print("  patch clipped: off %.4f on %.4f -> reduction %.3f (bar %.2f)" % [clip_off, clip_on, reduction, H1_MIN_REDUCTION])
	_check_true("H1 premise: the fixture actually clips with relief off", clip_off > 0.05,
			"(%.4f -- if this is ~0 the patch is not bright enough)" % clip_off)
	_check_true("H1 patch clipping falls >= %.0f%%" % (100.0 * H1_MIN_REDUCTION),
			reduction >= H1_MIN_REDUCTION, "(%.3f)" % reduction)

	# Informational, not a check. relief maps a uniform region at luminance L to
	# L / (1 + s (L/knee - 1)), which stays >= knee for every L >= knee and tends
	# to knee/s from below as L grows -- so a patch pixel that starts above the
	# knee ends above it, and the ">= KNEE" count H1 uses can fall only for
	# pixels dimmer than their own blurred surroundings (texture, edges).
	print("  patch interior mean: off %.3f on %.3f (knee %.2f, strength %.2f -> ceiling knee/strength %.2f)" % [
			_crop(off, PATCH), _crop(on, PATCH), KNEE, STRENGTH, KNEE / STRENGTH])

	# Informational ring profile, the fixture's counterpart of job 201's (there,
	# knee 3.0, 8-bit luma: 1-8 px 7.49%, 8-24 px 4.68%, 24-48 px 1.59%): how much
	# the linear mean falls at each distance below the patch's near edge. H3 reads
	# the 8-48 px band only; this shows where in it the halo actually lives.
	for band in [[1, 8], [8, 24], [24, 48], [48, 96]]:
		var ring := _ring_rect(band[0], band[1])
		print("  ring %2d-%2d px below the patch: off %.4f on %.4f -> darkening %.4f" % [
				band[0], band[1], _rect_mean(off, ring), _rect_mean(on, ring),
				1.0 - _rect_mean(on, ring) / maxf(_rect_mean(off, ring), 1e-9)])

	var wall_off := _crop(off, WALL)
	var wall_on := _crop(on, WALL)
	print("  wall mean: off %.6f on %.6f" % [wall_off, wall_on])
	_check("H2 wall mean unmoved", wall_on / maxf(wall_off, 1e-9), 1.0, H2_TOL)

	var ann_off := _crop(off, ANNULUS)
	var ann_on := _crop(on, ANNULUS)
	var darkening := 1.0 - (ann_on / maxf(ann_off, 1e-9))
	print("  annulus: off %.6f on %.6f -> darkening %.4f (bar %.2f)" % [ann_off, ann_on, darkening, H3_MAX_DARKENING])
	_check_true("H3 no halo beyond %.0f%%" % (100.0 * H3_MAX_DARKENING),
			darkening <= H3_MAX_DARKENING, "(%.4f)" % darkening)

	print("\n=== H0: relief off vs the recorded baseline ===")
	var ref_path := OS.get_environment("ZR_RELIEF_BASELINE_REF")
	if ref_path == "":
		print("  SKIP: set ZR_RELIEF_BASELINE_REF to a PFM captured on the pre-change binary")
	else:
		var ref := _load_pfm(ref_path)
		if ref == null:
			_check_true("H0 baseline readable", false, ref_path)
		else:
			var d := _max_abs_diff(off, ref)
			print("  max abs diff vs baseline %.10f" % d)
			_check_true("H0 relief off == baseline", d == 0.0, "(%.10f)" % d)

	print("\n=== H4: an unlit fixture asks for no relief ===")
	# A genuinely dim fixture, not `off`: `off` is this gate's own H1-H3 room WITH
	# the hot patch and relief simply disabled, so it clips by construction (H1's
	# premise check above requires clip_off > 0.05). Feeding it here would assert
	# that the decision function must say "not needed" about a frame this same
	# gate just proved is blown -- an assertion that can only fail correctly and
	# never test the claim in the docstring above. _render_fixture(0.0, false)
	# omits the hot quad entirely: floor/walls/ceiling/lamp only.
	var dim := await _render_fixture(0.0, false)
	var r := Daylight.highlight_relief(_samples_from(dim), 1.0)
	print("  clipped fraction %.4f -> strength %.3f (%s)" % [r["clipped_fraction"], r["strength"], "ON" if r["needed"] else "off"])
	_check_true("H4 dim frame gets exactly zero strength", (not r["needed"]) and r["strength"] == 0.0)

	print("")
	if _failures.is_empty():
		print("PASS: all %d highlight-relief checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (%+.2f%%, tol %.0f%%)" % [p_name, p_value, p_expected, 100.0 * (p_value / p_expected - 1.0), 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f, %.2f%% off" % [p_name, p_value, p_expected, 100.0 * err])


func _check_true(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s %s %s" % ["PASS" if p_ok else "FAIL", p_name, p_detail])
	if not p_ok:
		_failures.append("%s %s" % [p_name, p_detail])


## The crops are only meaningful if they sit where the constants above say: the
## patch interior inside the patch by a full blur reach, the annulus in the
## 8-48 px band below the patch and in front of it, the wall clear of the patch
## by two reaches. Measured from the camera's own projection of the patch, so a
## change to the camera, SIZE or PATCH_SIDE that moves the patch fails here
## instead of quietly reading the wrong pixels.
func _check_geometry() -> void:
	# The patch is a trapezoid on screen (perspective: the far edge is narrower),
	# so its bounding box overstates where patch pixels are. Corners in order
	# around the quad; the bounding box is used only for the annulus and wall.
	var quad := PackedVector2Array()
	for c in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
		quad.append(_cam.unproject_position(Vector3(c[0] * PATCH_SIDE * 0.5, 0.01, PATCH_CZ + c[1] * PATCH_SIDE * 0.5)))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in quad:
		lo = lo.min(p)
		hi = hi.max(p)
	var patch := Rect2(lo, hi - lo)
	_patch_px = patch
	print("  patch projects to a trapezoid, x %.0f-%.0f  y %.0f-%.0f  (far edge x %.0f-%.0f; %.0f x %.0f px overall; blur reach %d px)" % [
			lo.x, hi.x, lo.y, hi.y, quad[0].x, quad[1].x, patch.size.x, patch.size.y, BLUR_PX])
	# Every corner of the PATCH crop must be inside the quad and at least BLUR_PX
	# from each of its four edges, so the crop only sees pixels whose gain is set
	# by the patch alone. (A bounding-box test passed a crop whose top corners were
	# on the floor: 9.5% of its pixels were not patch.)
	var interior := _crop_px(PATCH)
	var clearance := INF
	var inside := true
	for corner in [interior.position, Vector2(interior.end.x, interior.position.y),
			interior.end, Vector2(interior.position.x, interior.end.y)]:
		inside = inside and Geometry2D.is_point_in_polygon(corner, quad)
		for i in range(4):
			var q := Geometry2D.get_closest_point_to_segment(corner, quad[i], quad[(i + 1) % 4])
			clearance = minf(clearance, corner.distance_to(q))
	_check_true("geometry: PATCH crop lies >= %d px inside the patch" % BLUR_PX,
			inside and clearance >= float(BLUR_PX), "(crop %s, nearest patch edge %.1f px)" % [interior, clearance])
	var ann := _crop_px(ANNULUS)
	var near := ann.position.y - patch.end.y
	var far := ann.end.y - patch.end.y
	_check_true("geometry: ANNULUS crop is the %d-%d px band below the patch" % [ANNULUS_NEAR_PX, ANNULUS_FAR_PX],
			absf(near - ANNULUS_NEAR_PX) <= 2.0 and absf(far - ANNULUS_FAR_PX) <= 2.0
			and ann.position.x >= patch.position.x + BLUR_PX and ann.end.x <= patch.end.x - BLUR_PX,
			"(band %.0f-%.0f px below, x %.0f-%.0f)" % [near, far, ann.position.x, ann.end.x])
	var wall := _crop_px(WALL)
	_check_true("geometry: WALL crop is >= %d px from the patch" % (2 * BLUR_PX),
			not patch.grow(2 * BLUR_PX).intersects(wall), "(wall %s)" % wall)


## The strip [p_near, p_far) px below the patch's near edge, over the ANNULUS
## crop's horizontal extent.
func _ring_rect(p_near: int, p_far: int) -> Rect2:
	var a := _crop_px(ANNULUS)
	return Rect2(a.position.x, _patch_px.end.y + float(p_near), a.size.x, float(p_far - p_near))


func _rect_mean(p_img: Image, p_r: Rect2) -> float:
	var acc := 0.0
	var n := 0
	for y in range(int(p_r.position.y), int(p_r.end.y)):
		for x in range(int(p_r.position.x), int(p_r.end.x)):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))


func _crop_px(p_r: Array) -> Rect2:
	var y0 := float(SIZE) * float(p_r[0])
	var y1 := float(SIZE) * float(p_r[1])
	var x0 := float(SIZE) * float(p_r[2])
	var x1 := float(SIZE) * float(p_r[3])
	return Rect2(x0, y0, x1 - x0, y1 - y0)


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await get_tree().process_frame


func _lambert(p_albedo_linear: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo_linear, p_albedo_linear, p_albedo_linear).linear_to_srgb()
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	return m


func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## A closed box with a small, very bright emissive square on the floor. The
## emissive patch stands in for a sun patch: it is several stops above
## everything else, which is the only property the operator cares about.
## p_hot_patch = false omits the patch entirely -- H4's genuinely-dim fixture.
func _build_fixture(p_hot_patch: bool = true) -> void:
	var mat := _lambert(ALBEDO)
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 4.0), Vector3(-90.0, 0.0, 0.0), mat) # floor
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 4.0), Vector3(90.0, 0.0, 0.0), mat) # ceiling
	_quad(Vector3(0.0, 1.5, -2.0), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), mat) # back
	_quad(Vector3(-2.0, 1.5, 0.0), Vector2(4.0, 3.0), Vector3(0.0, 90.0, 0.0), mat) # left
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(4.0, 3.0), Vector3(0.0, -90.0, 0.0), mat) # right
	if p_hot_patch:
		var hot := StandardMaterial3D.new()
		hot.albedo_color = Color(1, 1, 1)
		hot.emission_enabled = true
		hot.emission = Color(1, 1, 1)
		hot.emission_energy_multiplier = HOT_EMISSION
		_quad(Vector3(0.0, 0.01, PATCH_CZ), Vector2(PATCH_SIDE, PATCH_SIDE), Vector3(-90.0, 0.0, 0.0), hot)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 4.0
	lamp.omni_range = 12.0
	add_child(lamp)
	lamp.position = Vector3(0.0, 2.7, 0.0)


func _render_fixture(p_strength: float, p_hot_patch: bool = true) -> Image:
	await _clear()
	ProjectSettings.set_setting(SETTING_KNEE, KNEE)
	ProjectSettings.set_setting(SETTING_STRENGTH, p_strength)
	_build_fixture(p_hot_patch)
	var cam := Camera3D.new()
	_cam = cam
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.5, 2.6)
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.3, 0.0), Vector3.UP)
	cam.make_current()
	var env := _new_env()
	await get_tree().create_timer(1.0).timeout
	var _raw := await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	# _render_accum's return value is RSG::scene->get_pathtracing_accum_image(),
	# which in render_forward_clustered.cpp reads rt_get_accum_texture() -- the
	# raw running-average accumulator. Local highlight relief, exactly like the
	# OIDN final denoise immediately above it in the C++ dispatch order, reads
	# and writes get_internal_texture() instead (local_highlight.cpp: "RID color
	# = p_render_buffers->get_internal_texture()"), a distinct RID relief latches
	# on the SAME frame the accumulator reaches its target. Reading the accum
	# image straight from _render_accum() therefore cannot observe relief at all
	# -- confirmed empirically: off and on came back byte-identical. Sibling gate
	# pt_oidn_guide_gate.gd hit the identical issue for OIDN and fixed it the same
	# way: give the post-convergence blit two frames, then read the viewport
	# texture (which mirrors internal_texture) instead of the accumulator.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGBH and img.get_format() != Image.FORMAT_RGBAH:
		push_error("viewport image is format %d, not RGBH/RGBAH -- use_hdr_2d did not take; bright pixels are already clamped to 1.0" % img.get_format())
	ProjectSettings.set_setting(SETTING_STRENGTH, 0.0)
	return img


func _new_env() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)
	env.set_pathtracing_max_bounces(8)
	return env


func _crop(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
			n += 1
	return acc / float(maxi(n, 1))


## Fraction of the crop at or above the knee -- the linear-buffer stand-in for
## "would clip", since this gate's tonemapper is LINEAR.
func _clipped_fraction(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var hits := 0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var c := p_img.get_pixel(x, y)
			if (c.r + c.g + c.b) / 3.0 >= KNEE:
				hits += 1
			n += 1
	return float(hits) / float(maxi(n, 1))


func _samples_from(p_img: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for y in range(0, p_img.get_height(), 4):
		for x in range(0, p_img.get_width(), 4):
			var c := p_img.get_pixel(x, y)
			out.append((c.r + c.g + c.b) / 3.0)
	return out


func _max_abs_diff(p_a: Image, p_b: Image) -> float:
	var m := 0.0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			m = maxf(m, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return m


func _save_pfm(p_img: Image, p_path: String) -> void:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("PF\n%d %d\n-1.0\n" % [w, h])
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			buf.put_float(c.r)
			buf.put_float(c.g)
			buf.put_float(c.b)
	f.store_buffer(buf.data_array)
	f.close()


func _load_pfm(p_path: String) -> Image:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return null
	var magic := f.get_line()
	var dims := f.get_line().split(" ")
	f.get_line()
	if magic != "PF" or dims.size() != 2:
		return null
	var w := int(dims[0])
	var h := int(dims[1])
	var img := Image.create(w, h, false, Image.FORMAT_RGBF)
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var r := f.get_float()
			var g := f.get_float()
			var b := f.get_float()
			img.set_pixel(x, y, Color(r, g, b))
	return img
