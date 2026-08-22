extends "res://tests/pt_validation.gd"

## E2a GPU gate: ABSOLUTE sky energy, against the authored panorama.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_sky_energy_gate_scene.tscn
##
## WHY THIS EXISTS WHEN pt_energy_gate.gd ALREADY TESTS ENERGY.
##
## pt_energy_gate.gd Gate 1 is already an analytic furnace test -- constant sky,
## Lambertian plane, asserting L_o = rho * L to 1% -- and it passes. It proves
## the integrator is correct GIVEN whatever radiance the renderer sees.
##
## It cannot prove the renderer sees the right radiance. Its expected value is
## `ALBEDO * l_sky` where l_sky is measured FROM THE RENDER (pt_energy_gate.gd
## :206, :222), so any loss upstream of both the sky pass and the surface pass
## cancels exactly. Its own header says so: "The gate is a RATIO against this,
## so no global sky scale can fake a pass or a failure."
##
## A ~23% uniform environment dimming versus Cycles (roadmap 7.4) IS a global
## sky scale. That gate is blind to it by construction -- the same shape as all
## four defects E1 shipped through a green suite: an assertion that is correct
## but cannot fail in the direction that matters.
##
## Every assertion in THIS file compares against a value computed from the
## SOURCE PANORAMA, never from a render.
##
## Four probes:
##   A. Constant sky, sky-only. Invariant to resolution, so it reads the
##      scalar path alone (Mechanism A).
##   B. Peaked sky, Lambertian plane, against an irradiance integral computed
##      in GDScript from the panorama image (Mechanism B).
##   C. Probe B repeated at two Sky.radiance_size values. If the response moves
##      with resolution, energy is being lost in the radiance map -- proof, not
##      inference.
##   D. IBL_exposure_normalization read directly off the GPU via vis mode 34.

const SKY_RADIANCE := 0.5 # Authored constant radiance for probe A.
const ALBEDO := 0.5 # LINEAR reflectance of the probe plane.
const TOLERANCE := 0.02 # 2 percent, per spec section 8.
const FRAMES := 128

var _plane: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []
var _verdict: Dictionary = {}


func _build_scene(p_panorama: ImageTexture, p_radiance_size: int) -> Environment:
	for c in get_children():
		c.queue_free()

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = p_panorama
	sky_mat.energy_multiplier = 1.0

	var sky := Sky.new()
	sky.sky_material = sky_mat
	# QUALITY, not REALTIME: sky.cpp:593-595 force-clamps a REALTIME sky's
	# radiance map to REAL_TIME_SIZE (256, sky.h:248) and warns. Probe C needs
	# the size to actually take effect, so this must not be REALTIME.
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = p_radiance_size

	var env := Environment.new()
	# BG_SKY with a real Sky resource is MANDATORY. BG_COLOR renders pure black
	# to the path tracer -- env_sky_radiance() reads radiance_octmap, which the
	# sky pass only populates for BG_SKY (roadmap F3).
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(4)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(200.0, 200.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO)
	mat.metallic = 0.0
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_plane = MeshInstance3D.new()
	_plane.mesh = plane_mesh
	_plane.material_override = mat
	add_child(_plane)

	get_viewport().world_3d.environment = env
	return env


## Mean over an axis-aligned crop given as fractions of the image.
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
	return { "r": r * inv, "g": g * inv, "b": b * inv,
			"mean": (r + g + b) * inv / 3.0, "n": n }


func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


func _look_up() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(90.0, 0.0, 0.0)


func _look_down() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated sweep would take
	# hours. Disable content scaling so the viewport follows the window.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame

	await _probe_a()

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - sky energy gate green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


## PROBE A -- constant sky, sky-only, absolute.
##
## The plane is hidden, so every camera ray misses and reaches the miss shader
## with mis_ray_pdf == RT_MIS_PDF_NONE, giving MIS weight exactly 1. The pixel
## is therefore authored_radiance * IBL_exposure_normalization, with no BSDF,
## no NEE and no integrator involved.
##
## A constant sky is invariant to RESOLUTION, so this probe is blind to
## Mechanism B by construction and reads Mechanism A alone. That is the point:
## it is the only probe here whose result has a single possible cause.
func _probe_a() -> void:
	var env := _build_scene(_constant_panorama(), Sky.RADIANCE_SIZE_256)
	_plane.visible = false
	_look_up()
	# The sky pass renders the radiance octmap and the env CDF is built from it;
	# both need a moment before the first measurement.
	await get_tree().create_timer(2.0).timeout

	print("\n=== PROBE A: constant sky, authored L = %.5f ===" % SKY_RADIANCE)
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 16)
	if img == null:
		_failures.append("probe A: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.25, 0.75)
	var ratio: float = s["mean"] / SKY_RADIANCE
	print("  authored  : %.5f" % SKY_RADIANCE)
	print("  measured  : %.5f  (R %.5f  G %.5f  B %.5f)" % [s["mean"], s["r"], s["g"], s["b"]])
	print("  ratio     : %.5f" % ratio)
	_verdict["a_ratio"] = ratio

	if absf(ratio - 1.0) > TOLERANCE:
		_failures.append("probe A: sky reads %.5f vs %.5f authored, ratio %.5f (limit %.0f%%)"
				% [s["mean"], SKY_RADIANCE, ratio, TOLERANCE * 100.0])
