extends "res://tests/pt_validation.gd"

## Daylight design gate (spec 2026-09-19-daylight-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_daylight_gate_scene.tscn
##
## Every number here is computed from the source panorama or from the sun's
## energy, never from a render (pt_sky_energy_gate.gd's rule). Sky: a
## synthetic 512 x 256 equirect, zenith 1.2 -> horizon 0.6 (linear in
## theta), ground 0.3, whose irradiance Daylight.sky_irradiance() puts near
## 2.4 -- so a forgotten multiplier reads 2.4x, not 1x.
##
##   D0 control : card under the UNnormalised sky reads E_sky / pi (proves the
##                multiplier is what moves D1, not the integral)
##   D1 sky     : card, sky normalised (energy_multiplier = 1 / E_sky) -> 1/pi
##   D2 sun     : D1 + sun at 45 deg elevation, light_energy SUN_ENERGY
##                (= SUN_TO_SKY / pi: a DirectionalLight3D of energy E is
##                irradiance pi*E in the tracer, as in Godot's raster --
##                measured here 2026-09-19) -> (1 + 5 cos 45) / pi
##   D3 exposure: windowed room probe, then a FRAMES_HI still: occupied
##                median x e -> 0.18
##   D4 no fill : windowed room -> p25 x e >= 0.02, solver says no fill
##   D5 fill    : dark room (opening bricked, albedo 0.3, one corner omni):
##                solver places DaylightFill; rendered with it, p25 x e = 0.02
##                and median x e = 0.18
##   D6 mask    : camera facing the window: excluded fraction vs the window's
##                projected area
##
## albedo_color is sRGB-encoded: linear values are authored through
## linear_to_srgb(). Tolerances: 3% on D0-D2 (pt_sky_energy_gate probe B
## found a 1.5-2.2% peaked-sky shortfall, Gap #27; this sky is smooth but
## the same estimator is under test).

var FRAMES_HI: int = 256 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const TOL_ENERGY := 0.03
const TOL_EXPOSURE := 0.05
const TOL_FLOOR := 0.10
const TOL_MASK := 0.20
const ALBEDO := 0.8
const ALBEDO_DARK := 0.3
const PANO_W := 512
const PANO_H := 256
const SKY_ZENITH := 1.2
const SKY_HORIZON := 0.6
const SKY_GROUND := 0.3
const SUN_ELEVATION_DEG := 45.0
# Card crop: the down-looking camera sees only the card (2 x 2 m from 1 m,
# 90 deg FOV would just fit; 60 deg sees the middle 1.15 m). Centre 40%.
const CARD_ROWS := [0.30, 0.70, 0.30, 0.70]

var _failures: Array[String] = []
var _checks: int = 0
var _pano: Image


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

	_pano = _gradient_panorama()
	var e_sky := Daylight.sky_irradiance(_pano)
	print("gate sky E_sky = %.5f (uniform 1 would be %.5f)" % [e_sky, PI])
	_checks += 1
	if absf(e_sky - 1.0) < 0.2:
		_failures.append("gate sky irradiance %.4f is too close to 1: the normalisation could not be told from no-op" % e_sky)

	print("\n=== D0: control, card under the unnormalised sky ===")
	var ctrl := await _card_scene(1.0, false)
	_check("D0 card x pi vs E_sky", _crop(ctrl, CARD_ROWS) * PI, e_sky, TOL_ENERGY)

	print("\n=== D1: sky normalised to unit irradiance ===")
	var d1 := await _card_scene(1.0 / e_sky, false)
	_check("D1 card x pi", _crop(d1, CARD_ROWS) * PI, 1.0, TOL_ENERGY)

	print("\n=== D2: + sun at %.0f deg, light_energy %.4f (sun:sky %.1f) ===" % [SUN_ELEVATION_DEG, Daylight.SUN_ENERGY, Daylight.SUN_TO_SKY])
	var d2 := await _card_scene(1.0 / e_sky, true)
	var expected_d2 := 1.0 + Daylight.SUN_TO_SKY * cos(deg_to_rad(90.0 - SUN_ELEVATION_DEG))
	_check("D2 card x pi", _crop(d2, CARD_ROWS) * PI, expected_d2, TOL_ENERGY)

	print("")
	if _failures.is_empty():
		print("PASS: all %d daylight checks passed." % _checks)
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


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s: %s %s" % [p_name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
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


## One quad: centre, size (width, height), and the rotation that turns a
## +Z-facing QuadMesh the way it should face.
func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## Radiance depends on elevation only: SKY_ZENITH at v = 0 falling linearly
## in theta to SKY_HORIZON at the equator, SKY_GROUND below. Mipmapped as the
## pipeline's EXR is.
func _gradient_panorama() -> Image:
	var img := Image.create(PANO_W, PANO_H, false, Image.FORMAT_RGBF)
	for y in range(PANO_H):
		var theta := (float(y) + 0.5) / float(PANO_H) * PI
		var l := SKY_GROUND
		if theta < PI * 0.5:
			l = lerpf(SKY_ZENITH, SKY_HORIZON, theta / (PI * 0.5))
		for x in range(PANO_W):
			img.set_pixel(x, y, Color(l, l, l))
	img.generate_mipmaps()
	return img


func _new_env(p_pano: Image, p_multiplier: float) -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(p_pano)
	sky_mat.filter = true
	sky_mat.energy_multiplier = p_multiplier
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_1024
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
	env.set_pathtracing_max_bounces(16)
	env.set_pathtracing_max_diffuse_bounce(16)
	env.set_pathtracing_max_glossy_bounce(16)
	return env


## A 2 x 2 m white horizontal card, alone under the sky, seen from 1 m above
## straight down. The sun, when on, is a DirectionalLight3D shining along
## its -Z; it is rotated so the light comes from SUN_ELEVATION_DEG above the
## horizon (incidence 90 - elevation on the horizontal card).
func _card_scene(p_multiplier: float, p_sun: bool) -> Image:
	await _clear()
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(2.0, 2.0), Vector3(-90.0, 0.0, 0.0), _lambert(1.0)) # faces +Y
	if p_sun:
		var sun := DirectionalLight3D.new()
		sun.light_energy = Daylight.SUN_ENERGY
		sun.light_color = Color(1.0, 1.0, 1.0)
		sun.light_angular_distance = 0.0
		sun.shadow_enabled = true
		add_child(sun)
		# -Z must point DOWN toward the card at the given elevation: rotate
		# about X by -(elevation) so a light at elevation 90 points straight down.
		sun.rotation_degrees = Vector3(-SUN_ELEVATION_DEG, 0.0, 0.0)
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.0, 0.0)
	add_child(cam)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # look straight down
	cam.make_current()
	var env := _new_env(_pano, p_multiplier)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES_HI)


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
