extends "res://tests/pt_validation.gd"

## OIDN guide pass-through gate (spec 2026-10-04-oidn-guide-feature-passthrough-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_oidn_guide_passthrough_gate_scene.tscn
##
## 256x256. Top half: a uniform sky. Bottom half: a 4-px checker card. Five columns,
## seen through a plane 5 m from the camera: OPEN | an ALPHA pane authored like the
## production window (Mat_A38_Window_Glass_001) | a smooth thin GLASS pane (the material
## _apply_glb_transmissive_glass produces) | a MIRROR (smooth metal, linear base 0.5) |
## a DARK GLOSS dielectric (smooth, linear base 0.02). 6 accumulated samples -- NOT the OIDN
## video route's count (it ships 4, VIDEO_OIDN_ACCUM_TARGET; 6 is the DLSS-RR video job's
## one-shot count) -- then OIDN, with ZR_OIDN_DUMP pointed at a temp dir so the gate reads
## the guides OIDN actually received.
##
##   F0 dumps  : the four OIDN dumps exist at 256x256 and OIDN changed the image
##   F1 premise: colour behind the alpha pane / open, per row, in [F1_MIN, F1_MAX]
##   F2 written: unwritten guide pixels behind the alpha and glass panes <= UNWRITTEN_MAX,
##               per row
##   F3 alpha  : guide albedo behind the alpha pane within ALPHA_TOL of the authored mix
##   F4 glass  : checker guide-albedo std behind the glass / open >= GLASS_DETAIL_MIN
##   F5 open   : open guides as authored -- sky albedo == sky colour, checker mean ==
##               the texture's linear mean
##   F6 result : INFORMATIVE print of the OIDN output checker std behind each pane / open
##               (it passed on the build before the fix, so it is not a check)
##   F7 mirror : a smooth metal DEFERS with throughput F (0.5 at normal incidence): its
##               guide albedo is MIRROR_TOL-close to 0.5 * the open sky's, per row
##               (the reflection leaves past the camera into the sky)
##   F8 dark   : a dark glossy dielectric WRITES, as Cycles does (w_diff 0.0192 vs
##               w_spec 0.04: 4 * 0.0192 > 0.0592): its guide albedo is DARK_TOL-close
##               to its diffuse albedo 0.02, per row
##
## On the build before the fix, a surface seen through an alpha pane is bounce 1
## (inc_transmission_bounce adds to the total) and writes no guide: F2 reads about 80%
## unwritten, and F3 reads 0.10x (sky) and 0.14x (checker). The glass's guide is the
## pane's own flat white: F4 about 0. F7 and F8 guard the deferral rule's weights: with
## the DLSS-RR specular helper (Karis' fit x 2.0) the mirror's throughput saturates at 1
## and the dark gloss defers instead of writing.

const FRAMES := 6
const SKY := Color(0.5, 0.6, 0.8)
const PANE_ALPHA := 0.033
const PANE_BASE_LINEAR := 0.7067
const PANE_ROUGHNESS := 0.0916
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const PANE_Z := 5.0

const F1_MIN := 0.95
const F1_MAX := 1.05
const UNWRITTEN_MAX := 0.01
const ALPHA_TOL := 0.05
const GLASS_DETAIL_MIN := 0.85
const F5_SKY_TOL := 1e-3
const F5_CHECK_TOL := 0.02
const MIRROR_TOL := 0.05
const DARK_TOL := 0.05
const MIRROR_BASE_LINEAR := 0.5
const DARK_BASE_LINEAR := 0.02

# Regions [x0, x1) x [y0, y1) in pixels, image y down. Column edges are at multiples of
# 51.2; every region keeps a margin (the open one spans whole 8-px checker periods).
const COLS := {"open": [8, 48], "alpha": [58, 96], "glass": [110, 148], "mirror": [162, 200], "dark": [212, 250]}
const ROWS := {"sky": [8, 120], "checker": [136, 248]}

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# The still route's viewport contract, as pt_oidn_guide_gate.gd.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	var dump_dir := ProjectSettings.globalize_path("user://pt_oidn_guide_passthrough_gate")
	DirAccess.make_dir_recursive_absolute(dump_dir)
	for n in ["oidn_color.pfm", "oidn_albedo.pfm", "oidn_normal.pfm", "oidn_output.pfm"]:
		DirAccess.remove_absolute(dump_dir.path_join(n))
	OS.set_environment("ZR_OIDN_DUMP", dump_dir)

	var env := _new_env(SKY)
	env.set_pathtracing_max_bounces(6)
	env.set_pathtracing_oidn_denoise(true)

	var side := 2.0 * CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)

	# Checker card, bottom half, 1:1 with the pixels (256 x 128 texels), 4-px cells.
	var img := Image.create(256, 128, false, Image.FORMAT_RGB8)
	for y in range(128):
		for x in range(256):
			var on := ((x / 4) + (y / 4)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var card := MeshInstance3D.new()
	var cq := QuadMesh.new()
	cq.size = Vector2(side, side * 0.5)
	card.mesh = cq
	card.position = Vector3(0, -side * 0.25, 0)
	var cm := StandardMaterial3D.new()
	cm.albedo_texture = ImageTexture.create_from_image(img)
	cm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	cm.metallic = 0.0
	cm.metallic_specular = 0.0
	cm.roughness = 1.0
	card.material_override = cm
	add_child(card)

	# The four panes, each one column (w / 5) wide and the full frame tall at PANE_Z.
	var w := 2.0 * (CAM_DIST - PANE_Z) * tan(deg_to_rad(CAM_FOV) * 0.5)

	# Authored like Mat_A38_Window_Glass_001. albedo_color is sRGB-encoded; glTF's
	# baseColorFactor is linear, so author the linear 0.7067 through linear_to_srgb().
	var am := StandardMaterial3D.new()
	var pane_srgb := Color(PANE_BASE_LINEAR, PANE_BASE_LINEAR, PANE_BASE_LINEAR).linear_to_srgb()
	am.albedo_color = Color(pane_srgb.r, pane_srgb.g, pane_srgb.b, PANE_ALPHA)
	am.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	am.cull_mode = BaseMaterial3D.CULL_DISABLED
	am.metallic = 0.0
	am.roughness = PANE_ROUGHNESS
	_add_pane(Vector3(-0.2 * w, 0.0, PANE_Z), w, am)

	# The material _apply_glb_transmissive_glass produces (video_glb_creation.gd).
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	gm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	gm.no_depth_test = false
	gm.metallic = 0.0
	gm.transmission = 1.0
	gm.ior = 1.5
	gm.metallic_specular = 0.5
	gm.thickness = 0.0
	gm.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	gm.roughness = 0.0
	_add_pane(Vector3(0.0, 0.0, PANE_Z), w, gm)

	# A mirror: smooth metal, linear base 0.5. It faces the camera, so its reflection
	# leaves past the camera into the sky. Cycles defers through it with F = 0.5.
	var mm := StandardMaterial3D.new()
	var mirror_srgb := Color(MIRROR_BASE_LINEAR, MIRROR_BASE_LINEAR, MIRROR_BASE_LINEAR).linear_to_srgb()
	mm.albedo_color = Color(mirror_srgb.r, mirror_srgb.g, mirror_srgb.b, 1.0)
	mm.metallic = 1.0
	mm.roughness = 0.0
	_add_pane(Vector3(0.2 * w, 0.0, PANE_Z), w, mm)

	# A dark glossy dielectric: smooth, linear base 0.02. Cycles WRITES here (w_diff =
	# 0.02 * (1 - 0.04) = 0.0192, w_spec = 0.04, and 4 * 0.0192 > 0.0592).
	var dm := StandardMaterial3D.new()
	var dark_srgb := Color(DARK_BASE_LINEAR, DARK_BASE_LINEAR, DARK_BASE_LINEAR).linear_to_srgb()
	dm.albedo_color = Color(dark_srgb.r, dark_srgb.g, dark_srgb.b, 1.0)
	dm.metallic = 0.0
	dm.roughness = 0.0
	dm.metallic_specular = 0.5
	_add_pane(Vector3(0.4 * w, 0.0, PANE_Z), w, dm)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	# OIDN fires on the frame the accumulator reaches its target; give it two frames.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var col := _read_pfm(dump_dir.path_join("oidn_color.pfm"))
	var alb := _read_pfm(dump_dir.path_join("oidn_albedo.pfm"))
	var nrm := _read_pfm(dump_dir.path_join("oidn_normal.pfm"))
	var out := _read_pfm(dump_dir.path_join("oidn_output.pfm"))

	print("\n=== F0: OIDN dumps ===")
	_checks += 1
	var have := not col.is_empty() and not alb.is_empty() and not nrm.is_empty() and not out.is_empty()
	if not have or col.w != 256 or col.h != 256:
		_failures.append("F0 dumps missing or not 256x256 under %s" % dump_dir)
		_finish()
		return
	var changed := absf(_luma_std(out, COLS.open, ROWS.checker) - _luma_std(col, COLS.open, ROWS.checker)) > 1e-6
	print("  four dumps present; OIDN changed the image: %s" % changed)
	if not changed:
		_failures.append("F0 OIDN output equals its input -- OIDN did not run")

	print("\n=== F1: premise (colour behind the alpha pane / open) ===")
	for row in ["sky", "checker"]:
		_checks += 1
		var r := _luma_mean(col, COLS.alpha, ROWS[row]) / maxf(_luma_mean(col, COLS.open, ROWS[row]), 1e-6)
		print("  %-8s %.4f  (want [%.2f, %.2f])" % [row, r, F1_MIN, F1_MAX])
		if r < F1_MIN or r > F1_MAX:
			_failures.append("F1 %s colour ratio %.4f outside [%.2f, %.2f]" % [row, r, F1_MIN, F1_MAX])

	print("\n=== F2: guides written behind each pane ===")
	for pane in ["alpha", "glass"]:
		for row in ["sky", "checker"]:
			_checks += 1
			var u := _unwritten(alb, nrm, COLS[pane], ROWS[row])
			print("  %-6s %-8s unwritten %.2f%%  (max %.0f%%)" % [pane, row, u * 100.0, UNWRITTEN_MAX * 100.0])
			if u > UNWRITTEN_MAX:
				_failures.append("F2 %s/%s unwritten %.2f%% > %.0f%%" % [pane, row, u * 100.0, UNWRITTEN_MAX * 100.0])

	print("\n=== F3: guide albedo behind the alpha pane ===")
	for row in ["sky", "checker"]:
		_checks += 1
		var open_m := _luma_mean(alb, COLS.open, ROWS[row])
		var want := (1.0 - PANE_ALPHA) * open_m + PANE_ALPHA * PANE_BASE_LINEAR
		var got := _luma_mean(alb, COLS.alpha, ROWS[row])
		var rel := got / maxf(want, 1e-6)
		print("  %-8s got %.4f want %.4f  ratio %.4f  (tol %.0f%%)" % [row, got, want, rel, ALPHA_TOL * 100.0])
		if absf(rel - 1.0) > ALPHA_TOL:
			_failures.append("F3 %s alpha-pane albedo %.4f vs %.4f (ratio %.4f)" % [row, got, want, rel])

	print("\n=== F4: checker detail in the guide behind the glass ===")
	_checks += 1
	var g4 := _luma_std(alb, COLS.glass, ROWS.checker) / maxf(_luma_std(alb, COLS.open, ROWS.checker), 1e-6)
	print("  std ratio %.4f  (min %.2f)" % [g4, GLASS_DETAIL_MIN])
	if g4 < GLASS_DETAIL_MIN:
		_failures.append("F4 glass guide detail %.4f < %.2f" % [g4, GLASS_DETAIL_MIN])

	print("\n=== F5: open guides as authored ===")
	_checks += 1
	var sky_l := 0.2126 * SKY.r + 0.7152 * SKY.g + 0.0722 * SKY.b
	var sky_got := _luma_mean(alb, COLS.open, ROWS.sky)
	print("  sky albedo %.5f want %.5f" % [sky_got, sky_l])
	if absf(sky_got - sky_l) > F5_SKY_TOL:
		_failures.append("F5 open sky albedo %.5f != %.5f" % [sky_got, sky_l])
	_checks += 1
	var tex_mean := 0.5 * (Color(0.9, 0.9, 0.9).srgb_to_linear().r + Color(0.1, 0.1, 0.1).srgb_to_linear().r)
	var chk_got := _luma_mean(alb, COLS.open, ROWS.checker)
	print("  checker albedo mean %.5f want %.5f" % [chk_got, tex_mean])
	if absf(chk_got / tex_mean - 1.0) > F5_CHECK_TOL:
		_failures.append("F5 open checker albedo %.5f vs %.5f" % [chk_got, tex_mean])

	# INFORMATIVE, not a check. Task 5 Step 3 ran this on the build before the fix and it
	# PASSED there (output std ratio 0.9790 alpha, 0.9745 glass): at 256 px with a 4-px
	# high-contrast checker the colour carries the detail and OIDN keeps it whatever the
	# guides say, so F6 cannot tell the two builds apart. The guide checks F2-F4 carry the
	# defect; the visible effect is judged on the production window (Task 5 Step 7).
	print("\n=== F6 (informative): denoised checker detail behind each pane ===")
	var open_out := _luma_std(out, COLS.open, ROWS.checker)
	for pane in ["alpha", "glass"]:
		var r6 := _luma_std(out, COLS[pane], ROWS.checker) / maxf(open_out, 1e-6)
		var r6raw := _luma_std(col, COLS[pane], ROWS.checker) / maxf(_luma_std(col, COLS.open, ROWS.checker), 1e-6)
		print("  %-6s output std ratio %.4f (raw colour ratio %.4f)  (informative, no threshold)" % [pane, r6, r6raw])

	print("\n=== F7: a smooth metal defers with its Fresnel (mirror, base %.2f) ===" % MIRROR_BASE_LINEAR)
	var open_sky := _luma_mean(alb, COLS.open, ROWS.sky)
	for row in ["sky", "checker"]:
		_checks += 1
		var want7 := MIRROR_BASE_LINEAR * open_sky
		var got7 := _luma_mean(alb, COLS.mirror, ROWS[row])
		var rel7 := got7 / maxf(want7, 1e-6)
		print("  %-8s got %.4f want %.4f  ratio %.4f  (tol %.0f%%)" % [row, got7, want7, rel7, MIRROR_TOL * 100.0])
		if absf(rel7 - 1.0) > MIRROR_TOL:
			_failures.append("F7 %s mirror albedo %.4f vs %.4f (ratio %.4f)" % [row, got7, want7, rel7])

	print("\n=== F8: a dark glossy dielectric writes its diffuse albedo (base %.2f) ===" % DARK_BASE_LINEAR)
	for row in ["sky", "checker"]:
		_checks += 1
		var got8 := _luma_mean(alb, COLS.dark, ROWS[row])
		var rel8 := got8 / DARK_BASE_LINEAR
		print("  %-8s got %.4f want %.4f  ratio %.4f  (tol %.0f%%)" % [row, got8, DARK_BASE_LINEAR, rel8, DARK_TOL * 100.0])
		if absf(rel8 - 1.0) > DARK_TOL:
			_failures.append("F8 %s dark-gloss albedo %.4f vs %.4f (ratio %.4f)" % [row, got8, DARK_BASE_LINEAR, rel8])

	_finish()


func _add_pane(p_pos: Vector3, p_w: float, p_mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(p_w / 5.0, p_w)
	mi.mesh = q
	mi.position = p_pos
	mi.material_override = p_mat
	add_child(mi)


# Little-endian PFM as _oidn_write_pfm writes it: "PF\n<w> <h>\n-1.0\n", rows bottom-up.
func _read_pfm(p_path: String) -> Dictionary:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return {}
	var magic := f.get_line().strip_edges()
	var dims := f.get_line().strip_edges().split(" ", false)
	var scale := float(f.get_line().strip_edges())
	if magic != "PF" or dims.size() != 2 or scale >= 0.0:
		return {}
	var w := int(dims[0])
	var h := int(dims[1])
	var buf := f.get_buffer(w * h * 12)
	if buf.size() != w * h * 12:
		return {}
	return {"w": w, "h": h, "data": buf}


func _px(p_img: Dictionary, p_x: int, p_y: int) -> Vector3:
	var o: int = (((p_img.h - 1 - p_y) * p_img.w) + p_x) * 12
	var d: PackedByteArray = p_img.data
	return Vector3(d.decode_float(o), d.decode_float(o + 4), d.decode_float(o + 8))


func _luma3(p_c: Vector3) -> float:
	return 0.2126 * p_c.x + 0.7152 * p_c.y + 0.0722 * p_c.z


func _luma_mean(p_img: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var acc := 0.0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			acc += _luma3(_px(p_img, x, y))
			n += 1
	return acc / float(n)


func _luma_std(p_img: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var m := _luma_mean(p_img, p_cols, p_rows)
	var acc := 0.0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			var dl := _luma3(_px(p_img, x, y)) - m
			acc += dl * dl
			n += 1
	return sqrt(acc / float(n))


# A guide pixel nothing wrote: albedo exactly 0 and the readback's (0, 0, 1) fallback
# for a zero-length normal (render_forward_clustered.cpp, the normal conversion).
func _unwritten(p_alb: Dictionary, p_nrm: Dictionary, p_cols: Array, p_rows: Array) -> float:
	var bad := 0
	var n := 0
	for y in range(p_rows[0], p_rows[1]):
		for x in range(p_cols[0], p_cols[1]):
			var a := _px(p_alb, x, y)
			var nn := _px(p_nrm, x, y)
			if a.x + a.y + a.z == 0.0 and nn.distance_to(Vector3(0, 0, 1)) < 1e-4:
				bad += 1
			n += 1
	return float(bad) / float(n)


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN guide pass-through checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
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
	return env
