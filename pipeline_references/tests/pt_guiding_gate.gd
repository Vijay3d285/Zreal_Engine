extends "res://tests/pt_validation.gd"

## Path-guiding gate (spec 2026-09-22-path-guiding-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_guiding_gate_scene.tscn
##
## Room: the portal gate's closed Lambertian box (4 x 3 x 3 m, opening in the
## -X wall) with a sun through the opening putting a patch on the floor; the
## camera looks at the +X wall, which the patch lights only by bounce. The
## guiding switch is the project setting rendering/pathtracer/guiding_probability.
##
##   G0 unbiased  : wall mean, FRAMES_HI, guiding 0 vs 0.5, within TOL_G0
##                  after the repeat floor is measured with ZR_SEED_OFFSET.
##   G1 variance  : wall grain at FRAMES_LO, guided <= G1_RATIO x unguided.
##   G2 repeat    : two guided FRAMES_LO renders, max abs diff == repeat floor.
##   G3 instrument: vis mode 45 after 16 guided frames, count channel >= 32/256.
##   G4 inert     : guiding 0 at FRAMES_LO == the pre-change baseline PFM
##                  (ZR_GUIDE_BASELINE=<path> writes it on the old binary;
##                  ZR_GUIDE_BASELINE_REF=<path> compares against it).
##   G5 cost      : ms per frame, guided / unguided <= G5_RATIO.

const FRAMES_LO := 256
var FRAMES_HI: int = 1024 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const GUIDE_PROB := 0.5
const TOL_G0 := 0.01
const G1_RATIO := 0.5
const G5_RATIO := 1.25
const VIS_GUIDE_CELL := 45
const ALBEDO := 0.5
# +X wall crop (camera at x = -1.2 looking +X): rows 0.30-0.60, cols 0.35-0.65.
const WALL_ROWS := [0.30, 0.60, 0.35, 0.65]
const SETTING := "rendering/pathtracer/guiding_probability"

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
	await get_tree().process_frame
	await get_tree().process_frame

	var baseline_out := OS.get_environment("ZR_GUIDE_BASELINE")
	if baseline_out != "":
		var img := await _render_scene(0.0, FRAMES_LO)
		_save_pfm(img, baseline_out)
		print("baseline written: %s (wall mean %.6f)" % [baseline_out, _crop(img, WALL_ROWS)])
		get_tree().quit(0)
		return

	# G0-G5 are added by Tasks 4 and 5.
	print("PASS: scaffold only.")
	get_tree().quit(0)


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


# The portal gate's room verbatim: a 4 x 3 x 3 box, opening 1.2 x 1.0 in the -X wall.
func _build_room(p_mat: Material) -> void:
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 3.0), Vector3(-90.0, 0.0, 0.0), p_mat) # floor, faces +Y
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 3.0), Vector3(90.0, 0.0, 0.0), p_mat) # ceiling, faces -Y
	_quad(Vector3(0.0, 1.5, -1.5), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), p_mat) # back, faces +Z
	_quad(Vector3(0.0, 1.5, 1.5), Vector2(4.0, 3.0), Vector3(0.0, 180.0, 0.0), p_mat) # front, faces -Z
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(3.0, 3.0), Vector3(0.0, -90.0, 0.0), p_mat) # right (+X wall), faces -X
	_quad(Vector3(-2.0, 0.45, 0.0), Vector2(3.0, 0.9), Vector3(0.0, 90.0, 0.0), p_mat) # below the opening
	_quad(Vector3(-2.0, 2.45, 0.0), Vector2(3.0, 1.1), Vector3(0.0, 90.0, 0.0), p_mat) # above
	_quad(Vector3(-2.0, 1.4, -1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z < -0.6
	_quad(Vector3(-2.0, 1.4, 1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z > 0.6


func _new_env_sky(p_radiance: float) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(Color(p_radiance, p_radiance, p_radiance))
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
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


## Sun at 45 deg elevation, coming in through the -X opening toward +X and
## down: its patch lands on the floor around x ~ 0..1. Energy 5/pi so the
## sun : sky irradiance is 5 : 1 (memory: DirectionalLight energy E is
## irradiance pi*E).
func _add_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.light_energy = 5.0 / PI
	sun.light_color = Color(1, 1, 1)
	sun.shadow_enabled = true
	sun.light_angular_distance = 0.5
	add_child(sun)
	sun.rotation_degrees = Vector3(-45.0, -90.0, 0.0) # -Z of the light points +X and 45 deg down


## One render of the fixture at guiding probability p_guide. p_vis != 0 switches
## the debug vis mode AFTER the accumulation has trained (see G3): the switch
## resets the accumulator but not the guide (spec section 1).
func _render_scene(p_guide: float, p_frames: int, p_vis: int = 0) -> Image:
	await _clear()
	ProjectSettings.set_setting(SETTING, p_guide)
	_build_room(_lambert(ALBEDO))
	_add_sun()
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(-1.2, 1.5, 0.0)
	add_child(cam)
	cam.look_at(Vector3(2.0, 1.5, 0.0), Vector3.UP)
	cam.make_current()
	var env := _new_env_sky(1.0)
	env.set_pathtracing_max_bounces(12)
	env.set_pathtracing_max_diffuse_bounce(12)
	env.set_pathtracing_max_glossy_bounce(12)
	await get_tree().create_timer(1.0).timeout
	var img := await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	if p_vis == 0:
		return img
	env.set_pathtracing_debug_mode(p_vis)
	for _i in range(RESET_SETTLE_FRAMES):
		await get_tree().process_frame
	for _i in range(16):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var vis := RenderingServer.viewport_get_pathtracing_accum_image(get_viewport().get_viewport_rid())
	env.set_pathtracing_debug_mode(0)
	return vis


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


func _crop_channel(p_img: Image, p_r: Array, p_ch: int) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			acc += p_img.get_pixel(x, y)[p_ch]
			n += 1
	return acc / float(maxi(n, 1))


func _rms(p_img: Image, p_ref: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * float(p_r[0])), int(h * float(p_r[1]))):
		for x in range(int(w * float(p_r[2])), int(w * float(p_r[3]))):
			var a := p_img.get_pixel(x, y)
			var b := p_ref.get_pixel(x, y)
			var d := (a.r + a.g + a.b) / 3.0 - (b.r + b.g + b.b) / 3.0
			acc += d * d
			n += 1
	return sqrt(acc / float(maxi(n, 1)))


## The daylight spec's grain statistic: RMS of the residual against a 5 x 5
## box mean, over the crop, divided by the crop mean.
func _grain(p_img: Image, p_r: Array) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var y0 := int(h * float(p_r[0]))
	var y1 := int(h * float(p_r[1]))
	var x0 := int(w * float(p_r[2]))
	var x1 := int(w * float(p_r[3]))
	var acc := 0.0
	var mean_acc := 0.0
	var n := 0
	for y in range(y0 + 2, y1 - 2):
		for x in range(x0 + 2, x1 - 2):
			var box := 0.0
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var c := p_img.get_pixel(x + dx, y + dy)
					box += (c.r + c.g + c.b) / 3.0
			box /= 25.0
			var p := p_img.get_pixel(x, y)
			var v := (p.r + p.g + p.b) / 3.0
			acc += (v - box) * (v - box)
			mean_acc += v
			n += 1
	var mean := mean_acc / float(maxi(n, 1))
	return sqrt(acc / float(maxi(n, 1))) / maxf(mean, 1e-9)


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
	f.get_line() # scale
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
