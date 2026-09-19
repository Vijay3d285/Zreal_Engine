extends "res://tests/pt_validation.gd"

## Light portals gate (spec 2026-09-18-light-portals-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_portal_gate_scene.tscn
##
## An AreaLight3D with area_portal is a sampling hint for the sky, not a
## light: from every shading point that faces it, half of the sky samples
## are aimed through its rectangle (Cycles' portal, background.h:333). It
## emits nothing. Fixture: a closed 4 x 3 x 3 m white room (albedo linear
## 0.8), one 1.2 x 1.0 m opening in the x = -2 wall (sill y = 0.9), uniform
## world 1.0, no lamps, 16 bounces (max, diffuse and glossy). Camera (0, 1.5, 1.2) looking at
## (0, 1.2, -1.5), 60 deg vertical FOV: only the back wall, the floor and a
## strip of ceiling are in frame. Cycles half:
## tools/cycles_comparison/cycles_portal_room.py.
##
##   P1 unbiased  : portal on / off at FRAMES_HI, back-wall and floor crops
##                  -> 1 +- 1 %
##   P2 variance  : per-pixel RMS of the back-wall crop at FRAMES_LO against
##                  the FRAMES_HI render, on / off -> must be < P2_BAR (< 1)
##   P3 Cycles    : portal on at FRAMES_HI, crop means vs Cycles +- 3 %
##   P4 side test : the portal flipped (facing outdoors: nothing in the room
##                  faces it) vs off at FRAMES_LO -> max abs diff <= the
##                  build's own repeat floor (off rendered twice)
##   P5 area light: a 1 x 1 m AreaLight3D (normalize off) over a floor vs the
##                  179.9 deg spot-rect of the same size and energy -> 1 +- 1 %
##
## albedo_color is sRGB-encoded: linear values are authored through
## linear_to_srgb(). The portal flag is set with set("area_portal", true) so a
## binary without the property runs the gate (and fails P2/P5) instead of
## failing to parse.

var FRAMES_HI: int = 1024 if OS.get_environment("ZR_GATE_FRAMES") == "" else int(OS.get_environment("ZR_GATE_FRAMES"))
const FRAMES_LO := 16
const TOL := 0.01
const BAR_CYCLES := 0.03
# Task 4 captures the on/off RMS ratio on the first green build and writes
# it here with margin; 0.0 makes P2 fail loudly until then.
const P2_BAR := 0.0
# Cycles 5.2.1, cycles_portal_room.py, 1024 spp, 16 bounces, captured 2026-09-18
# (Task 1 Step 2): portal on: wall 0.076156 floor 0.070482; no-portal control
# 0.076143 / 0.070287. (At 8 bounces both sides: Cycles 0.069613 / 0.063858,
# ours -2.6% / -3.3% -- bounce counting, not sampling; hence 16.)
const CYCLES_P3_WALL := 0.076156
const CYCLES_P3_FLOOR := 0.070482

const ALBEDO := 0.8
const WALL_ROWS := [0.30, 0.60, 0.30, 0.70]
const FLOOR_ROWS := [0.90, 0.98, 0.30, 0.70]

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

	var probe_light := AreaLight3D.new()
	print("AreaLight3D.area_portal present: ", "area_portal" in probe_light)
	probe_light.free()

	print("\n=== P1: unbiased, portal on / off at %d frames ===" % FRAMES_HI)
	var on_hi := await _render_room("on", FRAMES_HI)
	var off_hi := await _render_room("off", FRAMES_HI)
	var wall_on := _crop(on_hi, WALL_ROWS)
	var wall_off := _crop(off_hi, WALL_ROWS)
	var floor_on := _crop(on_hi, FLOOR_ROWS)
	var floor_off := _crop(off_hi, FLOOR_ROWS)
	print("  wall on %.6f off %.6f | floor on %.6f off %.6f" % [wall_on, wall_off, floor_on, floor_off])
	_check("P1 wall on/off", wall_on / maxf(wall_off, 1e-9), 1.0, TOL)
	_check("P1 floor on/off", floor_on / maxf(floor_off, 1e-9), 1.0, TOL)

	print("\n=== P2: variance at %d frames ===" % FRAMES_LO)
	var on_lo := await _render_room("on", FRAMES_LO)
	var off_lo := await _render_room("off", FRAMES_LO)
	var rms_on := _rms(on_lo, on_hi, WALL_ROWS)
	var rms_off := _rms(off_lo, off_hi, WALL_ROWS)
	var p2 := rms_on / maxf(rms_off, 1e-9)
	print("  RMS on %.6f off %.6f ratio %.4f (bar %.4f)" % [rms_on, rms_off, p2, P2_BAR])
	_checks += 1
	if P2_BAR <= 0.0 or P2_BAR >= 1.0:
		_failures.append("P2 variance: bar not captured (P2_BAR = %.4f)" % P2_BAR)
	elif p2 > P2_BAR:
		_failures.append("P2 variance: on/off RMS ratio %.4f above bar %.4f" % [p2, P2_BAR])

	print("\n=== P3: portal on vs Cycles ===")
	_check_vs("P3 wall vs Cycles", wall_on, CYCLES_P3_WALL, BAR_CYCLES)
	_check_vs("P3 floor vs Cycles", floor_on, CYCLES_P3_FLOOR, BAR_CYCLES)

	print("\n=== P4: flipped portal (nothing faces it) vs off ===")
	var off_lo_b := await _render_room("off", FRAMES_LO)
	var flipped_lo := await _render_room("flipped", FRAMES_LO)
	var floor_diff := _max_abs_diff(off_lo, off_lo_b)
	var flip_diff := _max_abs_diff(flipped_lo, off_lo)
	print("  repeat floor %.8f | flipped vs off %.8f" % [floor_diff, flip_diff])
	_checks += 1
	if flip_diff > floor_diff:
		_failures.append("P4 side test: flipped vs off max abs diff %.8f above the repeat floor %.8f" % [flip_diff, floor_diff])

	print("\n=== P5: AreaLight3D as a rect light vs the spot-rect convention ===")
	var area_img := await _render_rect_light("area", 256)
	var spot_img := await _render_rect_light("spot", 256)
	var area_v := _crop(area_img, [0.40, 0.60, 0.40, 0.60])
	var spot_v := _crop(spot_img, [0.40, 0.60, 0.40, 0.60])
	print("  area %.6f spot-rect %.6f" % [area_v, spot_v])
	_check("P5 area / spot-rect", area_v / maxf(spot_v, 1e-9), 1.0, TOL)

	print("")
	if _failures.is_empty():
		print("PASS: all %d portal checks passed." % _checks)
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


func _check_vs(p_name: String, p_value: float, p_ref: float, p_bar: float) -> void:
	_checks += 1
	if p_ref <= 0.0:
		_failures.append("%s: Cycles reference not captured (constant is %.6f)" % [p_name, p_ref])
		return
	var err := absf(p_value - p_ref) / p_ref
	print("  %s: %.6f vs Cycles %.6f  (%+.2f%%, bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * (p_value / p_ref - 1.0), 100.0 * p_bar])
	if err > p_bar:
		_failures.append("%s: %.6f vs Cycles %.6f, %.2f%% off (bar %.0f%%)" % [p_name, p_value, p_ref, 100.0 * err, 100.0 * p_bar])


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


## One inward-facing quad: centre, size (width, height), and the rotation
## that turns a +Z-facing QuadMesh toward the room.
func _quad(p_center: Vector3, p_size: Vector2, p_rot_deg: Vector3, p_mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = p_size
	mi.mesh = q
	mi.material_override = p_mat
	mi.position = p_center
	mi.rotation_degrees = p_rot_deg
	add_child(mi)


## The room. Same numbers as cycles_portal_room.py room_quads(): x [-2,2],
## y [0,3], z [-1.5,1.5]; opening in the x = -2 wall, z [-0.6,0.6],
## y [0.9,1.9].
func _build_room(p_mat: Material) -> void:
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 3.0), Vector3(-90.0, 0.0, 0.0), p_mat) # floor, faces +Y
	_quad(Vector3(0.0, 3.0, 0.0), Vector2(4.0, 3.0), Vector3(90.0, 0.0, 0.0), p_mat) # ceiling, faces -Y
	_quad(Vector3(0.0, 1.5, -1.5), Vector2(4.0, 3.0), Vector3(0.0, 0.0, 0.0), p_mat) # back, faces +Z
	_quad(Vector3(0.0, 1.5, 1.5), Vector2(4.0, 3.0), Vector3(0.0, 180.0, 0.0), p_mat) # front, faces -Z
	_quad(Vector3(2.0, 1.5, 0.0), Vector2(3.0, 3.0), Vector3(0.0, -90.0, 0.0), p_mat) # right, faces -X
	# Left wall (faces +X), four quads around the opening.
	_quad(Vector3(-2.0, 0.45, 0.0), Vector2(3.0, 0.9), Vector3(0.0, 90.0, 0.0), p_mat) # below
	_quad(Vector3(-2.0, 2.45, 0.0), Vector2(3.0, 1.1), Vector3(0.0, 90.0, 0.0), p_mat) # above
	_quad(Vector3(-2.0, 1.4, -1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z < -0.6
	_quad(Vector3(-2.0, 1.4, 1.05), Vector2(0.9, 1.0), Vector3(0.0, 90.0, 0.0), p_mat) # z > 0.6


## Builds the room with the portal "on", "off" or "flipped" and returns the
## accumulated frame.
func _render_room(p_portal: String, p_frames: int) -> Image:
	await _clear()
	_build_room(_lambert(ALBEDO))

	if p_portal != "off":
		var portal := AreaLight3D.new()
		portal.name = "Portal"
		portal.area_size = Vector2(1.2, 1.0)
		portal.area_normalize_energy = false
		portal.light_energy = 0.0
		portal.shadow_enabled = false
		portal.set("area_portal", true)
		add_child(portal)
		portal.position = Vector3(-2.0, 1.4, 0.0)
		var facing := Vector3(1.0, 0.0, 0.0) if p_portal == "on" else Vector3(-1.0, 0.0, 0.0)
		portal.look_at(portal.position + facing, Vector3.UP) # -Z toward `facing`

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 1.5, 1.2)
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.2, -1.5), Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(1.0)
	# 16 bounces of every kind, as the Cycles script sets max/diffuse/glossy:
	# the Environment defaults are Cycles' defaults (diffuse 4), and in a room
	# lit through one small opening the diffuse cap alone was a -25% bias; at
	# 8 the residual bounce-counting difference was still -3%.
	env.set_pathtracing_max_bounces(16)
	env.set_pathtracing_max_diffuse_bounce(16)
	env.set_pathtracing_max_glossy_bounce(16)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)


## P5 fixture: a 4 x 4 floor (albedo 0.8) lit from 1 m above by a 1 x 1 m
## rectangle facing down, either an AreaLight3D or the 179.9 deg spot-rect
## (size = half-width, spot_angle_attenuation = half-height). Black world.
func _render_rect_light(p_kind: String, p_frames: int) -> Image:
	await _clear()
	_quad(Vector3(0.0, 0.0, 0.0), Vector2(4.0, 4.0), Vector3(-90.0, 0.0, 0.0), _lambert(ALBEDO))

	var light: Light3D
	if p_kind == "area":
		var a := AreaLight3D.new()
		a.area_size = Vector2(1.0, 1.0)
		a.area_normalize_energy = false
		a.set_param(Light3D.PARAM_RANGE, 10.0)
		a.set_param(Light3D.PARAM_ATTENUATION, 1.0)
		light = a
	else:
		var s := SpotLight3D.new()
		s.spot_angle = 180.0
		s.light_size = 0.5
		s.spot_angle_attenuation = 0.5
		s.spot_range = 10.0
		s.spot_attenuation = 1.0
		light = s
	light.light_energy = 1.0
	light.light_specular = 0.0
	light.shadow_enabled = false
	add_child(light)
	light.position = Vector3(0.0, 1.0, 0.0)
	light.rotation_degrees = Vector3(-90.0, 0.0, 0.0) # -Z points down

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	cam.position = Vector3(0.0, 2.5, 3.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	cam.make_current()

	var env := _new_env_sky(0.0)
	env.set_pathtracing_max_bounces(2)
	await get_tree().create_timer(1.0).timeout
	return await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)


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


## Per-pixel RMS of p_img against p_ref over a crop (luminance mean of RGB).
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


func _max_abs_diff(p_a: Image, p_b: Image) -> float:
	var m := 0.0
	for y in range(p_a.get_height()):
		for x in range(p_a.get_width()):
			var a := p_a.get_pixel(x, y)
			var b := p_b.get_pixel(x, y)
			m = maxf(m, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return m


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
