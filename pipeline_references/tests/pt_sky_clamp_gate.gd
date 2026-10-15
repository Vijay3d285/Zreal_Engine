extends "res://tests/pt_validation.gd"

## Sky miss clamp gate (spec docs/superpowers/specs/2026-10-14-pt-sky-miss-clamp-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_sky_clamp_gate_scene.tscn
##
## The miss stage clamps the sky a ray reaches with Cycles' rule: film_write_background clamps
## with film_clamp_light(bounce - 1) (kernel/film/light_passes.h:638), i.e. by the vertex that
## cast the ray. Our total_bounces already counts the bounce that produced the ray, so total <= 1
## at the miss takes clamp_direct and anything later takes clamp_indirect.
##
## Each check renders one scene twice, with clamps (direct/indirect) 0/0 and 0/10, and asserts
## mean(0/10) / mean(0/0) over the centre crop. The sky is a uniform RGBF panorama of radiance
## SKY, so a sky sample is ~100x the indirect limit: a clamp that applies cuts it to ~1%, one
## that does not leaves the ratio at 1.0, and noise cannot sit in between.
##
##   S1 camera sees the sky                  total 0 at the miss   1.0 +- 0.001
##      guard: the 0/0 crop mean is >= 10x the limit, so the clamp can bite at all
##   S3 sky through one alpha-0 BLEND pane   total 1               1.0 +- 0.001
##   F1 grey floor, first surface's bounce   total 1               1.0 +- 0.01
##   S2 sky through a solid glass slab       total 2               <= 0.5
##
## S2's expected value: the front-face reflection (F ~0.04, total 1) stays unclamped, about 40;
## the twice-refracted share (~0.92) is cut to 10 per sample, about 9; so ~0.05.
## F1's counterfactual (the rejected total_bounces == 0 rule): the bounce ray's sky is cut to ~10
## against ~214 x w per sample (linear albedo 0.214 of sRGB 0.5), which leaves the env-NEE share
## of the floor (1 - ln(17)/16 = 0.18 of it under a uniform sky) plus ~10/214: about 0.2.
##
## READINGS (2026-10-14, session 2 Active, 128 frames, 256x256), ratio 0/10 over 0/0:
##   pre-change binary   S1 1.000000  S3 1.000000  F1 1.000001  S2 1.000000  -> FAIL (S2)
##   fault, == 0u        S1 1.000000  S3 0.010000  F1 0.234869  S2 0.010000  -> FAIL (S3, F1)
##   this rule, <= 1u    S1 1.000000  S3 1.000000  F1 1.000001  S2 0.049615  -> PASS
##   rule as a factor    S1 1.000000  S3 0.999999  F1 0.999999  S2 0.049615  -> PASS
##     on mis_w (39cc5512d3, 2026-10-15; clamps 0/0 byte-identical to the pre-change binary)
## The S1 guard read 100 (sky 1000 / limit 10) on all four. Under the fault even S2's total-1
## front reflection is clamped, hence 0.010 there against 0.050 under the rule.

const SKY := 1000.0
const FRAMES := 128
const CLAMP_INDIRECT := 10.0
const EXACT_TOL := 0.001
const F1_TOL := 0.01
const S2_MAX := 0.5

# Camera on the -Z axis and a 6x6 pane at z = -2: pt_transparent_alpha_gate.gd's geometry, which
# keeps the pane over the whole 0.35-0.65 crop.
const CAM_POS := Vector3(0, 0, 5)
const CAM_TARGET := Vector3(0, 0, -5)
const CAM_FOV := 25.0
const PANE_SIZE := Vector3(6, 6, 0.05)
const PANE_Z := -2.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== S1: camera sees the sky (total 0 at the miss) ===")
	var s1: Dictionary = await _clamp_ratio("s1", 2)
	_check("S1 camera sky", s1["ratio"], 1.0 - EXACT_TOL, 1.0 + EXACT_TOL)
	_check("S1 guard: sky / limit", float(s1["off"]) / CLAMP_INDIRECT, 10.0, INF)

	print("\n=== S3: sky through one alpha-0 BLEND pane (total 1) ===")
	var s3: Dictionary = await _clamp_ratio("s3", 2)
	_check("S3 alpha pane", s3["ratio"], 1.0 - EXACT_TOL, 1.0 + EXACT_TOL)

	print("\n=== F1: grey floor, the first surface's bounce ray (total 1) ===")
	var f1: Dictionary = await _clamp_ratio("f1", 1)
	_check("F1 first bounce", f1["ratio"], 1.0 - F1_TOL, 1.0 + F1_TOL)

	print("\n=== S2: sky through a solid glass slab (total 2) ===")
	var s2: Dictionary = await _clamp_ratio("s2", 4)
	_check("S2 solid glass", s2["ratio"], 0.0, S2_MAX)

	print("")
	if _failures.is_empty():
		print("PASS: all %d sky-clamp checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check(p_name: String, p_value: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	print("  %s: %.6f (band [%.3f, %.3f])" % [p_name, p_value, p_lo, p_hi])
	if p_value < p_lo or p_value > p_hi:
		_failures.append("%s: %.6f outside [%.3f, %.3f]" % [p_name, p_value, p_lo, p_hi])


## Builds scene p_scene, renders it with clamps 0/0 and then 0/CLAMP_INDIRECT, and returns
## {off, on, ratio} for the centre crop. Only clamp_indirect changes between the two renders;
## clamp_direct stays 0, as in production.
func _clamp_ratio(p_scene: String, p_bounces: int) -> Dictionary:
	for c in get_children():
		c.queue_free()
	await get_tree().process_frame

	var cam_pos := CAM_POS
	var cam_target := CAM_TARGET
	var cam_fov := CAM_FOV
	match p_scene:
		"s1":
			_add_offscreen_box()
		"s3":
			_add_pane(_alpha_pane_material())
		"s2":
			_add_pane(_glass_material())
		"f1":
			_add_floor()
			# pt_shadow_visibility_gate.gd's floor view.
			cam_pos = Vector3(0, 0.5, 4)
			cam_target = Vector3(0, -1, 0)
			cam_fov = 30.0
	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child(): see pt_transparent_alpha_gate.gd.
	cam.look_at_from_position(cam_pos, cam_target, Vector3.UP)
	cam.fov = cam_fov
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(SKY, SKY, SKY))
	env.set_pathtracing_max_bounces(p_bounces)
	await get_tree().create_timer(1.0).timeout

	var vp_rid := get_viewport().get_viewport_rid()
	env.set_pathtracing_clamp_indirect(0.0)
	var off_img: Image = await _render_accum(env, vp_rid, FRAMES)
	var off: float = _measure_crop(off_img, 0.35, 0.65)["mean"]
	env.set_pathtracing_clamp_indirect(CLAMP_INDIRECT)
	var on_img: Image = await _render_accum(env, vp_rid, FRAMES)
	var on: float = _measure_crop(on_img, 0.35, 0.65)["mean"]
	print("  crop mean: clamps 0/0 %.6f, 0/%.0f %.6f" % [off, CLAMP_INDIRECT, on])
	if off < 1e-6:
		_checks += 1
		_failures.append("%s: control render is black (%.8f)" % [p_scene, off])
		return {"off": off, "on": on, "ratio": 0.0}
	return {"off": off, "on": on, "ratio": on / off}


## S1 has nothing in view; this box behind the camera only keeps the TLAS non-empty.
func _add_offscreen_box() -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	mi.mesh = mesh
	mi.position = Vector3(0, 0, 20)
	add_child(mi)


func _add_pane(p_mat: StandardMaterial3D) -> void:
	var pane := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = PANE_SIZE
	pane.mesh = mesh
	pane.position = Vector3(0, 0, PANE_Z)
	pane.material_override = p_mat
	add_child(pane)


## What the glTF importer produces for alphaMode BLEND (pt_transparent_alpha_gate.gd). Alpha 0:
## every camera ray passes through (one inc_transmission_bounce), so it meets the sky at total 1.
func _alpha_pane_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	m.albedo_color = Color(1, 1, 1, 0.0)
	return m


## Production window glass, as image_glb_creation.gd _apply_glb_transmissive_glass sets it:
## solid (thickness > 0 is the flag), clear, IOR 1.5, metallic_specular 0.5 (the no-op that keeps
## eta == ior). A camera ray refracts in at the front face and out at the back face: total 2.
func _glass_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	m.no_depth_test = false
	m.metallic = 0.0
	m.transmission = 1.0
	m.ior = 1.5
	m.metallic_specular = 0.5
	m.thickness = 0.05
	m.albedo_color = Color(1, 1, 1, 1)
	m.roughness = 0.0
	m.emission_enabled = false
	return m


## An open grey floor: nothing above it, so every bounce ray from it meets the sky at total 1.
## albedo_color is sRGB: 0.5 shades as linear 0.214 (pt_energy_gate.gd's note).
func _add_floor() -> void:
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(200, 0.1, 200)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, -1, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.5, 0.5, 0.5)
	floor_mat.roughness = 1.0
	floor_mat.metallic = 0.0
	floor_mi.material_override = floor_mat
	add_child(floor_mi)


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
