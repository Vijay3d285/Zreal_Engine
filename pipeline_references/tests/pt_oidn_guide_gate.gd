extends "res://tests/pt_validation.gd"

## OIDN guide gate (spec 2026-09-16-oidn-accumulated-guides-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_oidn_guide_gate_scene.tscn
##
## One quad fills the 256x256 frame, textured 1:1 with a checker: period 4 px
## on the left half, period 32 px on the right. Uniform white sky, one bounce,
## so every sample's radiance is the albedo itself (a furnace) and the raw
## 256-frame accumulation is the pixel-filtered checker with no noise. OIDN
## then runs as the still route's final pass. Detail retention = std-dev of
## OIDN's output over a region / std-dev of the raw accumulation over it.
##
##   G1 fine   : retention on the period-4 half   >= RETAIN_MIN
##   G2 coarse : retention on the period-32 half  >= RETAIN_MIN
##   G3 parity : |G1 - G2| <= PARITY_MAX -- "no blur that grows with texture
##               frequency per pixel", which is what blur with distance is.
##
## With the guides being one point sample per pixel (the DLSS-RR G-buffers),
## the fine half's guide is a noisy binary pattern that disagrees with the
## filtered colour and OIDN erases the checker; with the guides accumulated
## like the colour (Cycles' denoising passes) it keeps it.

const FRAMES := 256
const RETAIN_MIN := 0.85
const PARITY_MAX := 0.10
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const FINE_PERIOD := 4
const COARSE_PERIOD := 32

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# Same viewport contract as render.gd's still route, ALL of it: the project
	# defaults are msaa_3d=2, screen_space_aa=1 (FXAA), use_taa=true and
	# use_debanding=true, and every one of them is a post-process on the image
	# this gate reads back. With FXAA left on, the fine checker read 0.64
	# retention while OIDN's own output at the same pixels was intact -- the
	# blur was the gate's, not the denoiser's. HDR 2D so the viewport image
	# comes back linear (FORMAT_RGBH) for a like-for-like std-dev.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().use_hdr_2d = true
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_oidn_denoise(true)

	# 256x256 checker, no mipmaps (a mipmapped texture would be prefiltered by
	# the sampler and there would be nothing for the denoiser to lose).
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var period := FINE_PERIOD if x < 128 else COARSE_PERIOD
			var half := period / 2
			var on := ((x / half) + (y / half)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var tex := ImageTexture.create_from_image(img)

	# Quad exactly filling the view at CAM_DIST: side = 2 * CAM_DIST * tan(fov/2).
	var side := 2.0 * CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(side, side)
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.roughness = 1.0
	quad.material_override = mat
	add_child(quad)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	var raw: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	# OIDN fires on the frame the accumulator reaches its target and lands in
	# the viewport texture on the next blit; give it two frames.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out: Image = get_viewport().get_texture().get_image()
	if out.get_format() != Image.FORMAT_RGBH:
		_failures.append("viewport image is %d, not FORMAT_RGBH -- use_hdr_2d did not take" % out.get_format())
		_finish()
		return

	# Diagnostic dump (ZR_GATE_DUMP=<dir>): raw accumulation and OIDN output as
	# PFM, for running oidnDenoise.exe offline with synthetic guides.
	var dump_dir := OS.get_environment("ZR_GATE_DUMP")
	if dump_dir != "":
		_save_pfm(raw, dump_dir.path_join("raw.pfm"))
		_save_pfm(out, dump_dir.path_join("out.pfm"))

	var fine_raw := _std(raw, 24, 40, 104, 216)
	var fine_out := _std(out, 24, 40, 104, 216)
	var coarse_raw := _std(raw, 152, 40, 232, 216)
	var coarse_out := _std(out, 152, 40, 232, 216)
	var g1 := fine_out / maxf(fine_raw, 1e-6)
	var g2 := coarse_out / maxf(coarse_raw, 1e-6)

	print("\n=== G1: fine checker (period %d px) retention ===" % FINE_PERIOD)
	print("  raw std %.5f  oidn std %.5f  retention %.4f (min %.2f)" % [fine_raw, fine_out, g1, RETAIN_MIN])
	_checks += 1
	if g1 < RETAIN_MIN:
		_failures.append("G1 fine retention %.4f < %.2f" % [g1, RETAIN_MIN])

	print("\n=== G2: coarse checker (period %d px) retention ===" % COARSE_PERIOD)
	print("  raw std %.5f  oidn std %.5f  retention %.4f (min %.2f)" % [coarse_raw, coarse_out, g2, RETAIN_MIN])
	_checks += 1
	if g2 < RETAIN_MIN:
		_failures.append("G2 coarse retention %.4f < %.2f" % [g2, RETAIN_MIN])

	print("\n=== G3: fine/coarse parity ===")
	print("  |G1 - G2| = %.4f (max %.2f)" % [absf(g1 - g2), PARITY_MAX])
	_checks += 1
	if absf(g1 - g2) > PARITY_MAX:
		_failures.append("G3 parity |%.4f - %.4f| > %.2f" % [g1, g2, PARITY_MAX])
	_finish()


## Little-endian float32 RGB PFM (rows bottom-up), the format oidnDenoise reads.
func _save_pfm(p_img: Image, p_path: String) -> void:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("PF
%d %d
-1.0
" % [w, h])
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


## Population std-dev of the mean-of-RGB over [x0,x1) x [y0,y1).
func _std(p_img: Image, p_x0: int, p_y0: int, p_x1: int, p_y1: int) -> float:
	var n := 0
	var s := 0.0
	var s2 := 0.0
	for y in range(p_y0, p_y1):
		for x in range(p_x0, p_x1):
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			s += v
			s2 += v * v
			n += 1
	var m := s / float(maxi(n, 1))
	return sqrt(maxf(s2 / float(maxi(n, 1)) - m * m, 0.0))


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN-guide checks passed." % _checks)
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
