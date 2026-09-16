extends "res://tests/pt_validation.gd"

## Subsurface gate (E3, roadmap Gap #13 remainder).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_subsurface_gate_scene.tscn
##
## Probes (spec 2026-09-15-e3-subsurface-scattering-design.md):
##   S3 thin-wall: a thin-wall SSS sheet (weight 1, albedo A) between the camera
##      and an emissive backdrop, camera side black. The translucent half of
##      the OpenPBR split lets 0.5 * A * L_backdrop through; the diffuse half
##      sees only black. Ratio sheet/backdrop = 0.5 * A within 2%.
##   S1 energy (Task 4): white solid SSS sphere in a uniform furnace <= 1.0 and
##      within 2% of a white diffuse sphere.
##   S2 Cycles (Task 4): albedo 0.8 sphere, radius (1,0.2,0.1)*0.05, ior 1.4,
##      within 5% of CYCLES_REF per channel.
##   S4 fallback (Task 4): S2's material with radius 0 equals plain diffuse
##      to 0.5%.
##
## The translucent share is BSDF-owned: no NEE strategy draws a direction
## below the horizon (the transmissive-lobe rule), so S3's light arrives by the
## sampled ray hitting the emissive backdrop with MIS weight 1. Before E3 the
## sheet is a plain Lambertian and S3 reads 0.0.

const FRAMES := 128
const SHEET_ALBEDO := 0.8
const S3_TOL := 0.02

const CAM_POS := Vector3(0, 0, 5)
const CAM_TARGET := Vector3(0, 0, -5)
const CAM_FOV := 25.0
const SHEET_Z := -2.0
const BACKDROP_Z := -5.0
const BACKDROP_EMISSION := Color(0.6, 0.5, 0.4)
const EMISSION_ENERGY := 3.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n=== S3: thin-wall sheet, translucent share ===")
	var s3 := await _probe_s3()
	var s3_theory := 0.5 * SHEET_ALBEDO
	print("  S3 ratio = %.6f (theory %.4f)" % [s3, s3_theory])
	_checks += 1
	if absf(s3 - s3_theory) > S3_TOL * s3_theory:
		_failures.append("S3 thin-wall: %.6f vs %.4f (%.1f%% off, max %.0f%%)"
				% [s3, s3_theory, (s3 / s3_theory - 1.0) * 100.0, S3_TOL * 100.0])

	_finish()


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("PASS: all %d subsurface checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Backdrop + single-sided thin-wall sheet, black sky. Ratio of the centre crop
## with the sheet visible to the crop with it hidden.
func _probe_s3() -> float:
	for c in get_children():
		c.queue_free()

	var backdrop := MeshInstance3D.new()
	var bm := BoxMesh.new()
	# EFFECTIVELY INFINITE. The translucent lobe is cosine-weighted about -N and
	# the ratio integrates the WHOLE far hemisphere: a 20x20 backdrop 3 m away
	# subtends only 73 degrees and the 8.6% of the cosine weight beyond it hit
	# black sky (measured 0.747 against 0.80 before this was widened). 400x400
	# is the furnace-slab convention (pt_glass_energy_gate.gd).
	bm.size = Vector3(400, 400, 0.1)
	backdrop.mesh = bm
	backdrop.position = Vector3(0, 0, BACKDROP_Z)
	var bmat := StandardMaterial3D.new()
	bmat.emission_enabled = true
	bmat.emission = BACKDROP_EMISSION
	bmat.emission_energy_multiplier = EMISSION_ENERGY
	backdrop.material_override = bmat
	add_child(backdrop)

	var sheet := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(6, 6)
	sheet.mesh = qm
	sheet.position = Vector3(0, 0, SHEET_Z)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(SHEET_ALBEDO, SHEET_ALBEDO, SHEET_ALBEDO).linear_to_srgb()
	smat.metallic = 0.0
	smat.metallic_specular = 0.0
	smat.roughness = 1.0
	smat.subsurf_scatter_enabled = true
	smat.subsurf_scatter_strength = 1.0
	smat.subsurf_scatter_transmittance_enabled = true
	smat.subsurf_scatter_transmittance_color = Color(1, 1, 1)
	smat.subsurf_scatter_transmittance_depth = 0.0 # thin-wall
	sheet.material_override = smat
	add_child(sheet)

	var cam := Camera3D.new()
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(4)
	await get_tree().create_timer(1.0).timeout

	sheet.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)
	sheet.visible = true
	for _i in range(3):
		await get_tree().process_frame
	var through_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(through_img, 0.35, 0.65)
	print("  control mean %.6f, through mean %.6f" % [control["mean"], through["mean"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("S3 control is black")
		return 0.0
	return float(through["mean"]) / float(control["mean"])


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
	return {"r": r * inv, "g": g * inv, "b": b * inv, "mean": (r + g + b) * inv / 3.0}
