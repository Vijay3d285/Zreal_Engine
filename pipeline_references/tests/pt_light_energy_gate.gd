extends "res://tests/pt_validation.gd"

## Gap #23 GPU gate: multi-scatter energy under an ANALYTIC (delta) light.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_light_energy_gate_scene.tscn
##
## Every Cycles comparison before this one was environment-lit. The
## environment-NEE site got Cycles' multi-scatter compensation in Gap #17 (and
## the emissive-NEE site with it), but the three analytic-light NEE sites in
## raytracing_lights_inc.glsl (:604 directional, :782 omni/spot, :835) never
## did. The note left there -- "analytic lights have no second strategy to
## disagree with, so reported rather than changed" -- is correct about MIS and
## beside the point about energy: for a delta light NEE is the ONLY estimator,
## so its uncompensated specular value IS the render. Every rough specular
## surface under the sun or a lamp is short by 1/E(rough, mu): ~20-40% on a
## rough metal, 0.4-4% of the lobe on a dielectric. No furnace could see it,
## because furnaces are environment-lit.
##
## A sphere under a single delta DirectionalLight3D from the camera's direction,
## a BLACK sky. Arms: a white Lambertian CONTROL, three white metals at
## roughness 0.3 / 0.6 / 0.9, a mid-grey dielectric at 0.6. THE COMPARISON IS
## RATIO-TO-CONTROL in each engine: Godot's light_energy and Cycles' sun
## strength are different units, and a Lambertian under the same light in the
## same framing cancels the unit, the N.L distribution and the framing exactly.
## Only the BRDF is left.
##
## FRAMING matched to tools/cycles_comparison/cycles_light_energy.py: distance
## 2.5 along (1,1,1), 20 deg vertical FOV, 256x256, sphere overfills. The
## light shines along -(1,1,1), i.e. from the camera.

const FRAMES := 256
const LIGHT_ENERGY := 3.0
# tag, base (linear, grey), metallic, roughness, metallic_specular
const ARMS := [
	{ "tag": "lambert", "base": 1.0, "metallic": 0.0, "roughness": 1.0, "spec": 0.0 },
	{ "tag": "metal03", "base": 1.0, "metallic": 1.0, "roughness": 0.3, "spec": 0.5 },
	{ "tag": "metal06", "base": 1.0, "metallic": 1.0, "roughness": 0.6, "spec": 0.5 },
	{ "tag": "metal09", "base": 1.0, "metallic": 1.0, "roughness": 0.9, "spec": 0.5 },
	{ "tag": "plastic06", "base": 0.5, "metallic": 0.0, "roughness": 0.6, "spec": 0.5 },
]
# Blender 5.2.1, tools/cycles_comparison/cycles_light_energy.py: each arm's
# mean divided by the Lambertian control's, sun strength 3, angle 0, 1024
# samples. Parallel to ARMS.
const CYCLES_RATIO := [1.0, 1.58024949, 1.20756751, 0.86657359, 0.52264674]
const BAR := 0.02

var _sphere: MeshInstance3D
var _cam: Camera3D
var _light: DirectionalLight3D
var _failures: Array[String] = []


func _black_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(0.0, 0.0, 0.0))
	return ImageTexture.create_from_image(pano)


func _build_scene() -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = _black_panorama()
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	# BG_SKY with a real Sky resource, radiance 0: the path tracer needs the
	# resource to exist (pt_sheen_gate.gd), and black is what this gate wants.
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(3)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	_sphere.mesh = sm
	add_child(_sphere)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = 20.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_cam.position = Vector3(1.4433757, 1.4433757, 1.4433757) # normalize(1,1,1) * 2.5
	_cam.look_at(Vector3.ZERO, Vector3.UP)

	_light = DirectionalLight3D.new()
	_light.light_energy = LIGHT_ENERGY
	_light.light_color = Color(1, 1, 1)
	_light.light_angular_distance = 0.0 # delta
	add_child(_light)
	# A DirectionalLight3D shines along its -Z; put +Z on the direction TOWARD
	# the light, (1,1,1), the same construction pt_sheen_gate.gd's probe E2 uses.
	var zc := Vector3(1.0, 1.0, 1.0).normalized()
	var xc := Vector3.UP.cross(zc).normalized()
	_light.global_transform = Transform3D(Basis(xc, zc.cross(xc), zc), Vector3.ZERO)

	get_viewport().world_3d.environment = env
	return env


func _material(p_arm: Dictionary) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var b: float = p_arm["base"]
	# Pre-encode: render_raytracing.cpp:1585 runs albedo_color through
	# srgb_to_linear (pt_sheen_gate.gd probe F documents the round trip).
	m.albedo_color = Color(b, b, b).linear_to_srgb()
	m.metallic = p_arm["metallic"]
	m.roughness = p_arm["roughness"]
	m.metallic_specular = p_arm["spec"]
	return m


func _measure(p_img: Image) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	for y in range(h):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			acc += (c.r + c.g + c.b) / 3.0
	return acc / float(maxi(w * h, 1))


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(2.0).timeout
	var vp_rid := get_viewport().get_viewport_rid()

	print("\n=== DELTA LIGHT: rough surfaces under one directional light, black sky ===")
	var means: Array[float] = []
	for arm in ARMS:
		_sphere.material_override = _material(arm)
		var img: Image = await _render_accum(env, vp_rid, FRAMES)
		if img == null:
			_failures.append("delta light: accumulator readback returned null on arm %s" % arm["tag"])
			break
		var mean := _measure(img)
		means.append(mean)
		print("  %-10s mean=%.8f" % [arm["tag"], mean])

	if means.size() == ARMS.size():
		print("  %-10s %12s %12s %9s" % ["arm", "ours/ctl", "Cycles/ctl", "% off"])
		for i in range(ARMS.size()):
			var ratio: float = means[i] / means[0]
			var cyc: float = CYCLES_RATIO[i]
			var err: float = ratio / cyc - 1.0
			print("  %-10s %12.8f %12.8f %8.3f%%" % [ARMS[i]["tag"], ratio, cyc, err * 100.0])
			if i > 0 and absf(err) > BAR:
				_failures.append(("delta light arm %s: ratio-to-control %.8f vs Cycles %.8f, %+.3f%% -- outside the " +
						"%.1f%% bar. The analytic-light NEE path's specular energy does not match Cycles (Gap #23).")
						% [ARMS[i]["tag"], ratio, cyc, err * 100.0, BAR * 100.0])

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - light energy gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - " + f)
		get_tree().quit(1)
