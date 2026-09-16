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
##   S1 energy: white solid SSS sphere in a uniform furnace reads <= 1.0 and
##      within 3% of Cycles' white SSS sphere (0.97527). NOT "within 2% of a
##      white diffuse sphere": Cycles itself reads 0.97527 against its own white
##      diffuse 0.99967 -- the walk's 256-step cap and the 0.2 alpha floor cost
##      it 2.4%, and matching Cycles means carrying the same loss.
##   S2 Cycles: albedo 0.8 sphere, radius (1,0.2,0.1)*0.05, ior 1.4, within 5%
##      of CYCLES_REF_S2 per channel.
##   S4 fallback: S2's material with radius 0 equals plain diffuse to 0.5%.
##   S5 isolation: a plain diffuse sphere seen THROUGH a glass pane must read
##      the same whether or not an off-screen SSS cube turns the feature bit
##      on (RT_SSS_ENABLED). Added after the first cut put the exit flag on
##      bit 27 of packed_bounces_flags -- the transmission counter's low bit --
##      and every path with an odd number of glass crossings restarted from
##      the origin. S1-S4 have no glass and cannot see that class of fault.
##
## The translucent share is BSDF-owned: no NEE strategy draws a direction
## below the horizon (the transmissive-lobe rule), so S3's light arrives by the
## sampled ray hitting the emissive backdrop with MIS weight 1. Before E3 the
## sheet is a plain Lambertian and S3 reads 0.0.

const FRAMES := 128
const SHEET_ALBEDO := 0.8
const S3_TOL := 0.02
const S_FRAMES := 256
const S_BOUNCES := 12
const S1_TOL := 0.03
const S2_TOL := 0.05
const S4_TOL := 0.005
const S5_TOL := 0.01
# tools/cycles_comparison/cycles_sss_sphere.py, Blender 5.2.1, 2048 spp,
# 12 bounces, 2026-09-15.
const CYCLES_REF_S2 := Vector3(0.82585410, 0.77649382, 0.77084864)
const CYCLES_REF_DIFFUSE := 0.79974588
const CYCLES_REF_SSS_WHITE := 0.97526848

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

	print("
=== S1: white solid SSS sphere, furnace ===")
	var s1_sss := await _sphere_mean(_sss_material(1.0, 1.0, Color(1, 1, 1), 0.05))
	var s1_dif := await _sphere_mean(_sss_material(1.0, 0.0, Color(1, 1, 1), 0.05))
	var m1s := (s1_sss.x + s1_sss.y + s1_sss.z) / 3.0
	var m1d := (s1_dif.x + s1_dif.y + s1_dif.z) / 3.0
	print("  sss %.6f  diffuse %.6f  Cycles sss %.6f" % [m1s, m1d, CYCLES_REF_SSS_WHITE])
	_checks += 1
	if m1s > 1.0 + 1e-3 or absf(m1s / CYCLES_REF_SSS_WHITE - 1.0) > S1_TOL:
		_failures.append("S1 energy: sss %.6f vs Cycles %.6f (diffuse control %.6f)" % [m1s, CYCLES_REF_SSS_WHITE, m1d])

	print("
=== S2: albedo 0.8, radius (1,0.2,0.1)*0.05 vs Cycles ===")
	var s2 := await _sphere_mean(_sss_material(0.8, 1.0, Color(1.0, 0.2, 0.1), 0.05))
	print("  ours RGB %s  Cycles %s" % [s2, CYCLES_REF_S2])
	for i in range(3):
		_checks += 1
		var off := absf(s2[i] / maxf(CYCLES_REF_S2[i], 1e-9) - 1.0)
		if off > S2_TOL:
			_failures.append("S2 channel %d: %.6f vs Cycles %.6f (%.2f%%)" % [i, s2[i], CYCLES_REF_S2[i], off * 100.0])

	print("
=== S4: radius 0 falls back to diffuse ===")
	var s4 := await _sphere_mean(_sss_material(0.8, 1.0, Color(0, 0, 0), 0.05))
	var s4_dif := await _sphere_mean(_sss_material(0.8, 0.0, Color(1, 1, 1), 0.05))
	var m4 := (s4.x + s4.y + s4.z) / 3.0
	var m4d := (s4_dif.x + s4_dif.y + s4_dif.z) / 3.0
	print("  radius-0 %.6f  diffuse %.6f  (Cycles diffuse %.6f)" % [m4, m4d, CYCLES_REF_DIFFUSE])
	_checks += 1
	if absf(m4 / maxf(m4d, 1e-9) - 1.0) > S4_TOL:
		_failures.append("S4 fallback: %.6f vs diffuse %.6f" % [m4, m4d])

	print("
=== S5: diffuse sphere through glass, feature bit off vs on ===")
	var plain := _sss_material(0.8, 0.0, Color(1, 1, 1), 0.05)
	var s5_off := await _sphere_mean(plain, true, _sss_material(0.8, 0.0, Color(1, 1, 1), 0.05))
	var s5_on := await _sphere_mean(plain, true, _sss_material(0.8, 1.0, Color(1.0, 0.2, 0.1), 0.05))
	var m5o := (s5_off.x + s5_off.y + s5_off.z) / 3.0
	var m5n := (s5_on.x + s5_on.y + s5_on.z) / 3.0
	print("  bit off %.6f  bit on %.6f" % [m5o, m5n])
	_checks += 1
	if absf(m5n / maxf(m5o, 1e-9) - 1.0) > S5_TOL:
		_failures.append("S5 isolation: through glass, feature bit on %.6f vs off %.6f" % [m5n, m5o])

	_finish()


## Sphere furnace, framing matched to pt_glass_energy_gate.gd and
## tools/cycles_comparison/cycles_sss_sphere.py: unit sphere, camera at
## normalize(1,1,1) * 2.5, FOV 20, constant sky radiance 1.0, mean over the
## whole 256x256 image (the sphere overfills it).
## p_pane: a solid glass pane (the pipeline's converted-glass recipe: IOR 1.5,
## thickness 0.05, roughness 0) 0.5 m in front of the sphere, filling the view.
## p_offscreen: material of a 20 cm cube 6 m behind the camera -- out of frame,
## a negligible fraction of the sphere's hemisphere, but its material decides
## whether the tracer compiles with RT_SSS_ENABLED.
func _sphere_mean(p_mat: StandardMaterial3D, p_pane: bool = false, p_offscreen: StandardMaterial3D = null) -> Vector3:
	for c in get_children():
		c.queue_free()
	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(S_BOUNCES)
	if p_pane:
		var pane := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(3.0, 3.0, 0.02)
		pane.mesh = pm
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(1, 1, 1)
		pmat.metallic = 0.0
		pmat.metallic_specular = 0.5
		pmat.roughness = 0.0
		pmat.transmission = 1.0
		pmat.ior = 1.5
		pmat.thickness = 0.05
		pane.material_override = pmat
		pane.position = Vector3(1.4433757, 1.4433757, 1.4433757).normalized() * 1.5
		pane.look_at(Vector3.ZERO, Vector3.UP)
		add_child(pane)
	if p_offscreen != null:
		var cube := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(0.2, 0.2, 0.2)
		cube.mesh = cm
		cube.material_override = p_offscreen
		cube.position = Vector3(1.4433757, 1.4433757, 1.4433757).normalized() * 8.5
		add_child(cube)
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	sphere.mesh = sm
	sphere.material_override = p_mat
	add_child(sphere)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.fov = 20.0
	cam.position = Vector3(1.4433757, 1.4433757, 1.4433757)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	await get_tree().create_timer(2.0).timeout
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), S_FRAMES)
	var acc := Vector3.ZERO
	var n := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b)
			n += 1
	return acc / float(maxi(n, 1))


func _sss_material(p_albedo: float, p_weight: float, p_radius: Color, p_scale: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo).linear_to_srgb()
	m.metallic = 0.0
	m.metallic_specular = 0.0
	m.roughness = 1.0
	m.ior = 1.4
	if p_weight > 0.0:
		m.subsurf_scatter_enabled = true
		m.subsurf_scatter_strength = p_weight
		m.subsurf_scatter_transmittance_enabled = true
		m.subsurf_scatter_transmittance_color = p_radius.linear_to_srgb()
		m.subsurf_scatter_transmittance_depth = p_scale
	return m


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
