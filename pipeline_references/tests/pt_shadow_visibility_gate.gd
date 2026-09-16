extends "res://tests/pt_validation.gd"

## Shadow-visibility gate (spec 2026-09-16-shadow-visibility-and-clamp-design.md,
## roadmap Gap #30).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_shadow_visibility_gate_scene.tscn
##
## Cycles' per-object "Ray Visibility: Shadow" -- an object without the bit is
## never hit by a shadow ray but is still seen by camera and bounce rays. Godot's
## switch for it is GeometryInstance3D.cast_shadow = OFF; the pipeline already
## sets it on window-asset glass, and until Gap #30 the tracer ignored it, so
## no daylight entered a glazed room (job 225: sun + sky alone rendered black).
##
## Same fixture as pt_transparent_shadow_gate: a grey floor at y = -1, a
## 30x30 card at y = 1 (above the camera at y = 0.5, so no camera ray can hit
## it), a directional light straight down, black sky, one bounce. Each probe
## is the crop's mean with the card / without it.
##
##   V1 opaque card, cast_shadow ON  : <= BLOCK_MAX   (control -- it shadows)
##   V2 opaque card, cast_shadow OFF : 1.0 +- PASS_TOL (shadow rays ignore it)
##   V3 glass pane,  cast_shadow ON  : <= BLOCK_MAX   (Gap #22 still blocks)
##   V4 opaque card, cast_shadow OFF, placed at y = 0 IN the camera's view:
##      <= BLOCK_MAX -- camera rays still see it; only shadow rays do not.

const FRAMES := 128
const BLOCK_MAX := 0.005
const PASS_TOL := 0.02

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== V1: opaque card, cast_shadow ON (control) ===")
	var v1 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, 1.0)
	_check("V1 control", v1, 0.0, BLOCK_MAX)

	print("\n=== V2: opaque card, cast_shadow OFF ===")
	var v2 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, 1.0)
	_check("V2 shadow-off", v2, 1.0 - PASS_TOL, 1.0 + PASS_TOL)

	print("\n=== V3: glass pane, cast_shadow ON (Gap #22 guard) ===")
	var v3 := await _ratio(true, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, 1.0)
	_check("V3 glass blocks", v3, 0.0, BLOCK_MAX)

	print("\n=== V4: opaque card, cast_shadow OFF, in view (camera guard) ===")
	var v4 := await _ratio(false, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, 0.0)
	_check("V4 camera sees it", v4, 0.0, BLOCK_MAX)

	print("")
	if _failures.is_empty():
		print("PASS: all %d shadow-visibility checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	print("  %s: ratio %.6f (band [%.3f, %.3f])" % [p_name, p_value, p_lo, p_hi])
	if p_value < p_lo or p_value > p_hi:
		_failures.append("%s: ratio %.6f outside [%.3f, %.3f]" % [p_name, p_value, p_lo, p_hi])


## Floor crop with the card divided by the crop without it. p_card_y = 1.0
## puts the card above the camera (only shadow rays can meet it); 0.0 puts it
## between camera and floor (camera rays meet it first).
func _ratio(p_glass: bool, p_cast: int, p_card_y: float) -> float:
	for c in get_children():
		c.queue_free()

	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(6, 0.1, 6)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, -1, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.5, 0.5, 0.5)
	floor_mat.roughness = 1.0
	floor_mat.metallic = 0.0
	floor_mi.material_override = floor_mat
	add_child(floor_mi)

	var card_mat := StandardMaterial3D.new()
	if p_glass:
		card_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		card_mat.transmission = 1.0
		card_mat.thickness = 0.0
		card_mat.roughness = 0.0
		card_mat.metallic = 0.0
		card_mat.metallic_specular = 0.5
		card_mat.ior = 1.5
	else:
		card_mat.albedo_color = Color(0, 0, 0)
		card_mat.roughness = 1.0
		card_mat.metallic = 0.0
		card_mat.metallic_specular = 0.0
	var card := MeshInstance3D.new()
	var card_mesh := BoxMesh.new()
	card_mesh.size = Vector3(30, 0.05, 30)
	card.mesh = card_mesh
	card.position = Vector3(0, p_card_y, 0)
	card.material_override = card_mat
	card.cast_shadow = p_cast
	add_child(card)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-90, 0, 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0, 0.5, 4), Vector3(0, -1, 0), Vector3.UP)
	cam.fov = 30.0
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(1)
	await get_tree().create_timer(1.0).timeout

	card.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)
	card.visible = true
	for _i in range(3):
		await get_tree().process_frame
	var with_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var with_card := _measure_crop(with_img, 0.35, 0.65)
	print("  control mean %.6f, with-card mean %.6f" % [control["mean"], with_card["mean"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f)" % control["mean"])
		return 0.0
	return float(with_card["mean"]) / float(control["mean"])


func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
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


func _measure_crop(p_img: Image, p_lo: float, p_hi: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	var inv := 1.0 / float(maxi(n, 1))
	return {"mean": (r + g + b) * inv / 3.0, "n": n}
