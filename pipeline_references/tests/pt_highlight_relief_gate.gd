extends "res://tests/pt_validation.gd"

# Preloaded, not a global class name: the live pipeline has no class cache.
const Daylight = preload("res://daylight.gd")

## Local highlight relief gate (spec 2026-09-28-local-highlight-relief-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_highlight_relief_gate_scene.tscn
##
## Fixture: a closed Lambertian box with a small, very bright emissive patch on
## the floor several stops above the room -- the minimum that reproduces the
## production case (a sun patch the room's exposure cannot hold).
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
## Two deviations from the task-4 brief's script, both required for this to be
## a real instrument rather than one that always reads the same regardless of
## whether relief runs (task-4-report.md has the full account):
##   - Measurement reads get_viewport().get_texture().get_image() (HDR 2D)
##     after two settle frames, not _render_accum()'s return value. Relief
##     writes get_internal_texture(); the accumulator _render_accum() returns
##     is a different RID relief never touches, so H1-H3 as originally written
##     measured off vs on identically no matter what the operator did.
##   - H4 renders a fixture with the hot patch omitted (_render_fixture(0.0,
##     false)) instead of reusing `off`, which is this gate's own H1-H3 room
##     with relief simply disabled -- it clips by construction (see H1's
##     premise check) and so can only fail an "unlit fixture" assertion.

const FRAMES := 64
const STRENGTH := 0.5
const KNEE := 4.0
const SETTING_STRENGTH := "rendering/pathtracer/highlight_relief_strength"
const SETTING_KNEE := "rendering/pathtracer/highlight_relief_knee"
const ALBEDO := 0.5
# H1's bar is the production acceptance restated on this fixture. It is NOT
# tunable downward: if the operator cannot reach it, that is a design failure
# to report (spec, "Gate").
const H1_MIN_REDUCTION := 0.40
const H2_TOL := 0.01
# H3 has no defensible value before the blur radius is measured. Run the gate
# once, read the printed annulus ratio, and set this to that value plus a
# stated margin, with the measurement and date in this comment.
#
# 2026-09-28 measurements (task-4-report.md has the full account):
#   - This gate's own committed config (OIDN off, DLSS-RR final off): annulus
#     darkening 0.0000. NOT a real "no halo" reading -- relief never dispatches
#     in this config at all (see _render_fixture's comment and the report):
#     rt_accum_target, which gates relief's one-shot dispatch, is only computed
#     render_forward_clustered.cpp:2319 `if (rt_oidn_active || rt_dlss_rr_final_active)`,
#     with no branch for relief. H1 catches this (reduction 0.000, fails the
#     40% bar) so this 0.0 cannot be read as "halo is controlled."
#   - Diagnostic-only run (OIDN forced on so relief actually dispatches, not
#     committed): annulus darkening 0.1537, a large halo -- consistent with
#     the sparse-comb downsample footprint flagged in Task 2's review. Per the
#     task-4 brief, a large H3 reading is reported, not used to silently widen
#     this bound. Left at its provisional 0.05 pending that investigation.
#     Measured identically (0.1537) against both the stale bd3ab79f31 binary
#     and a binary rebuilt from HEAD (9ef05f315e, confirmed via --version) --
#     see task-4-report.md's "stale-binary confound" section.
const H3_MAX_DARKENING := 0.05

# Crops, as fractions y0 y1 x0 x1.
const PATCH := [0.55, 0.75, 0.40, 0.60]
const ANNULUS := [0.76, 0.86, 0.40, 0.60]
const WALL := [0.10, 0.30, 0.10, 0.30]

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
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

	var clip_off := _clipped_fraction(off, PATCH)
	var clip_on := _clipped_fraction(on, PATCH)
	var reduction := 1.0 - (clip_on / maxf(clip_off, 1e-9))
	print("  patch clipped: off %.4f on %.4f -> reduction %.3f (bar %.2f)" % [clip_off, clip_on, reduction, H1_MIN_REDUCTION])
	_check_true("H1 premise: the fixture actually clips with relief off", clip_off > 0.05,
			"(%.4f -- if this is ~0 the patch is not bright enough)" % clip_off)
	_check_true("H1 patch clipping falls >= %.0f%%" % (100.0 * H1_MIN_REDUCTION),
			reduction >= H1_MIN_REDUCTION, "(%.3f)" % reduction)

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
		hot.emission_energy_multiplier = 60.0 # several stops over the room
		_quad(Vector3(0.0, 0.01, 0.4), Vector2(1.0, 1.0), Vector3(-90.0, 0.0, 0.0), hot)
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
