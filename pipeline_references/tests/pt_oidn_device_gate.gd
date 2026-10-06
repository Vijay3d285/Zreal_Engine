extends "res://tests/pt_validation.gd"

## OIDN device gate -- T1 of docs/superpowers/specs/2026-10-01-video-oidn-design.md.
##
## Same fixture as pt_oidn_guide_gate (a 256x256 checker quad under a white sky) but only
## FRAMES accumulation frames, so OIDN has real noise to remove -- the video route's regime.
##
## Two invocations. They compare across PROCESSES because renders are bit-deterministic
## across runs on this build, while a second accumulation inside one process would draw
## different noise (the RNG frame counter keeps advancing):
##
##   1) CPU reference:
##      ZR_OIDN_GATE_DEVICE=cpu ZR_GATE_DUMP=<dir> godot ... pt_oidn_device_gate_scene.tscn
##      -> writes <dir>/oidn_device_cpu.pfm
##   2) CUDA vs reference:
##      ZR_OIDN_GATE_DEVICE=cuda ZR_OIDN_DEVICE_REF=<dir>/oidn_device_cpu.pfm godot ...
##
## Without ZR_OIDN_DEVICE_REF (the gate suite) only D1/D2 run: the denoise executes on the
## requested device and actually removes noise. Suite mode CANNOT detect a silent CPU fallback
## -- a CPU denoise removes the noise just as well, so D1/D2 pass either way. Only the
## ZR_OIDN_DEVICE_REF mode can (D3 below: identical output to the CPU reference means CUDA
## never ran).
##
##   D1 premise : the raw accumulation is noisy (else OIDN has nothing to do and D4 is vacuous)
##   D2 denoise : OIDN reduces the noise in a flat region by more than half
##   D3 device  : the CUDA output differs from the CPU reference in more than 1% of floats.
##                Identical output means CUDA never ran (silent CPU fallback); measured on
##                job 201, CUDA vs CPU differ in 99.97% of floats.
##   D4 quality : no pixel 2+ display levels from the CPU reference. Measured on job 201:
##                CUDA high 0.0000%; CUDA BALANCED 80.41% -- the bar catches a real drop.

const FRAMES := 2
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const FINE_PERIOD := 4
const COARSE_PERIOD := 32
const NOISY_MIN := 0.01          # D1: flat-region std of the raw accumulation must exceed this
const DENOISE_RATIO_MAX := 0.5   # D2: denoised std / raw std in the same region
const DIFFER_MIN := 0.01         # D3: fraction of floats that must differ from the CPU reference
const SETTING := "rendering/pathtracer/oidn_device"

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	var device := OS.get_environment("ZR_OIDN_GATE_DEVICE").strip_edges().to_lower()
	if device == "":
		device = "cuda"
	ProjectSettings.set_setting(SETTING, 1 if device == "cuda" else 0)
	print("\n=== OIDN device gate: device=%s, %d accumulation frames ===" % [device, FRAMES])

	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# The still route's viewport contract (see pt_oidn_guide_gate.gd for why each line).
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

	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			var period := FINE_PERIOD if x < 128 else COARSE_PERIOD
			var half := period / 2
			var on := ((x / half) + (y / half)) % 2 == 0
			img.set_pixel(x, y, Color(0.9, 0.9, 0.9) if on else Color(0.1, 0.1, 0.1))
	var tex := ImageTexture.create_from_image(img)
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
	# OIDN fires on the frame the accumulator reaches its target and lands in the viewport
	# texture on the next blit; give it two frames (as pt_oidn_guide_gate does).
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out: Image = get_viewport().get_texture().get_image()
	if out.get_format() != Image.FORMAT_RGBH:
		_failures.append("viewport image is %d, not FORMAT_RGBH -- use_hdr_2d did not take" % out.get_format())
		_finish()
		return

	var dump_dir := OS.get_environment("ZR_GATE_DUMP")
	if dump_dir != "":
		_save_pfm(out, dump_dir.path_join("oidn_device_%s.pfm" % device))

	# A flat dark square of the coarse checker (period 32 px, so 16 px squares): x 128-143 is
	# one square column; y 8-15 sits inside one square. Away from the edges, only noise varies.
	var raw_std := _std(raw, 132, 8, 140, 15)
	var out_std := _std(out, 132, 8, 140, 15)
	print("  flat-region std: raw %.5f  denoised %.5f  (ratio %.3f)" % [raw_std, out_std, out_std / maxf(raw_std, 1e-9)])
	_check_true("D1 premise: the raw accumulation is noisy", raw_std > NOISY_MIN, "(%.5f)" % raw_std)
	_check_true("D2 OIDN removed more than half the noise", out_std < DENOISE_RATIO_MAX * raw_std,
			"(%.5f vs %.5f)" % [out_std, raw_std])

	var ref_path := OS.get_environment("ZR_OIDN_DEVICE_REF")
	if ref_path == "":
		print("  D3/D4 SKIP: set ZR_OIDN_DEVICE_REF to the CPU run's oidn_device_cpu.pfm")
	else:
		var ref := _load_pfm(ref_path)
		if ref == null:
			_check_true("D3/D4 reference readable", false, ref_path)
		else:
			var differ := 0
			var total := 0
			var two_plus := 0
			var max_levels := 0
			for y in range(out.get_height()):
				for x in range(out.get_width()):
					var a := out.get_pixel(x, y)
					var b := ref.get_pixel(x, y)
					for c in range(3):
						total += 1
						if a[c] != b[c]:
							differ += 1
					var d := maxi(absi(_level(a.r) - _level(b.r)), maxi(absi(_level(a.g) - _level(b.g)), absi(_level(a.b) - _level(b.b))))
					max_levels = maxi(max_levels, d)
					if d >= 2:
						two_plus += 1
			var frac := float(differ) / float(maxi(total, 1))
			print("  vs CPU reference: floats differing %.2f%%, pixels 2+ levels %d, max %d levels" % [100.0 * frac, two_plus, max_levels])
			_check_true("D3 the CUDA output is not the CPU output (CUDA actually ran)", frac > DIFFER_MIN, "(%.4f)" % frac)
			_check_true("D4 no pixel 2+ display levels from the CPU reference", two_plus == 0,
					"(%d pixels, max %d levels)" % [two_plus, max_levels])
	_finish()


## Linear -> 8-bit sRGB display level. The fixture renders with TONE_MAPPER_LINEAR, so the
## viewport's linear value is what the display would encode.
func _level(p_linear: float) -> int:
	var v := clampf(p_linear, 0.0, 1.0)
	var s := 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
	return int(round(s * 255.0))


func _check_true(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	_checks += 1
	if p_ok:
		print("  PASS %s %s" % [p_name, p_detail])
	else:
		print("  FAIL %s %s" % [p_name, p_detail])
		_failures.append("%s %s" % [p_name, p_detail])


func _std(p_img: Image, p_x0: int, p_y0: int, p_x1: int, p_y1: int) -> float:
	var vals := PackedFloat32Array()
	for y in range(p_y0, p_y1):
		for x in range(p_x0, p_x1):
			var c := p_img.get_pixel(x, y)
			vals.append((c.r + c.g + c.b) / 3.0)
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= float(maxi(vals.size(), 1))
	var acc := 0.0
	for v in vals:
		acc += (v - mean) * (v - mean)
	return sqrt(acc / float(maxi(vals.size(), 1)))


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
	if f.get_line().strip_edges() != "PF":
		return null
	var dims := f.get_line().strip_edges().split(" ")
	var w := int(dims[0])
	var h := int(dims[1])
	f.get_line() # scale (-1.0: little-endian)
	var img := Image.create(w, h, false, Image.FORMAT_RGBF)
	var data := StreamPeerBuffer.new()
	data.data_array = f.get_buffer(w * h * 12)
	data.big_endian = false
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var r := data.get_float()
			var g := data.get_float()
			var b := data.get_float()
			img.set_pixel(x, y, Color(r, g, b))
	return img


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d OIDN-device checks passed." % _checks)
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
