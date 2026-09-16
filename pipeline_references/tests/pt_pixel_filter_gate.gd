extends "res://tests/pt_validation.gd"

## Pixel-filter gate (spec 2026-09-16-still-route-pixel-filter-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_pixel_filter_gate_scene.tscn
##
## Measures the camera reconstruction filter's edge-spread function with a
## SLANTED edge: a black quad against a white sky, its right edge tilted by
## atan(1/128) so it drifts one pixel every 128 rows. Each pixel's signed
## distance to the edge is known from the geometry, so sorting every pixel
## by that distance sweeps out the continuous edge profile -- which, for
## filter importance sampling, IS the filter's CDF. An edge placed on a pixel
## centre cannot do this: both the 1.0 and 1.5 windows then read 0 / 0.5 / 1.
##
##   F1 ramp: 10-90% width of the profile. Blackman-Harris widened x2 to
##      +-1.5 px (Cycles' default filter_width 1.5) gives 1.081 px; the
##      +-1.0 window this gate was first run against gives 0.721.
##   F2 symmetry: |(d75 - d50) - (d50 - d25)| <= 0.05 px.
##   F3 energy: image mean == white area fraction (0.5, the edge passes
##      through the image centre) within 0.2%.

const FRAMES := 256
const BINS_PER_PX := 20
const F1_EXPECTED := 1.081
const F1_TOL := 0.08
const F2_TOL := 0.05
const F3_TOL := 0.002
const CAM_DIST := 10.0
const CAM_FOV := 10.0
const SLANT := 1.0 / 128.0 # tan(theta): one pixel of drift per 128 rows

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# The project sets anti_aliasing/quality/use_taa=true, which gives the
	# viewport a 16-phase Halton jitter baked into the projection matrix
	# (renderer_viewport.cpp jitter_phase_count). That is a +-0.5 px box filter
	# CONVOLVED with the one under test: with it on, the +-1.0 window read a
	# 1.06 px ramp instead of its 0.72. render.gd's still route turns both the
	# TAA and any temporal upscaler off, so the gate measures what production
	# renders.
	get_viewport().use_taa = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await get_tree().process_frame
	await get_tree().process_frame

	var env := _new_env(Color(1, 1, 1))
	env.set_pathtracing_max_bounces(1)

	# Black quad: 40 x 40, centred at x = -20 so its right edge is the line
	# x = 0 before the tilt. Rotating about the camera's forward axis (Z) by
	# theta puts the edge at x = -y * tan(theta).
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(40, 40)
	quad.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0, 0, 0)
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.roughness = 1.0
	quad.material_override = mat
	quad.position = Vector3(-20, 0, 0)
	# Rotate about the origin, not the quad's own centre: parent it under a
	# pivot at the origin so the edge line stays through (0, 0).
	var pivot := Node3D.new()
	pivot.rotation = Vector3(0, 0, atan(SLANT))
	add_child(pivot)
	pivot.add_child(quad)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.1
	cam.far = 100.0
	cam.position = Vector3(0, 0, CAM_DIST)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var w := img.get_width()
	var h := img.get_height()
	# Vertical FOV at aspect 1: half-height of the view at the quad plane.
	var half := CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)
	var px := 2.0 * half / float(h) # world units per pixel

	# Bin every pixel by its signed distance (in px) from the edge.
	var nb := 8 * BINS_PER_PX # +-4 px
	var sum := PackedFloat64Array()
	var cnt := PackedInt32Array()
	sum.resize(nb)
	cnt.resize(nb)
	var total := 0.0
	for j in range(h):
		var yc := (1.0 - (float(j) + 0.5) / (float(h) * 0.5)) * half
		var x_edge := -yc * SLANT
		for i in range(w):
			var c := img.get_pixel(i, j)
			var v := (c.r + c.g + c.b) / 3.0
			total += v
			var xc := ((float(i) + 0.5) / (float(w) * 0.5) - 1.0) * half
			var d := (xc - x_edge) / px
			var b := int(floor((d + 4.0) * BINS_PER_PX))
			if b < 0 or b >= nb:
				continue
			sum[b] += v
			cnt[b] += 1
	var esf := PackedFloat64Array()
	var dpos := PackedFloat64Array()
	for b in range(nb):
		if cnt[b] == 0:
			continue
		esf.append(sum[b] / float(cnt[b]))
		dpos.append((float(b) + 0.5) / BINS_PER_PX - 4.0)

	var d10 := _cross(dpos, esf, 0.10)
	var d25 := _cross(dpos, esf, 0.25)
	var d50 := _cross(dpos, esf, 0.50)
	var d75 := _cross(dpos, esf, 0.75)
	var d90 := _cross(dpos, esf, 0.90)
	var ramp := d90 - d10
	var sym := absf((d75 - d50) - (d50 - d25))
	var mean := total / float(w * h)

	print("\n=== F1: edge-spread 10-90% ramp ===")
	print("  ramp %.4f px  (expected %.3f +- %.3f; +-1.0 window would read 0.721)" % [ramp, F1_EXPECTED, F1_TOL])
	_checks += 1
	if absf(ramp - F1_EXPECTED) > F1_TOL:
		_failures.append("F1 ramp: %.4f px vs expected %.3f +- %.3f" % [ramp, F1_EXPECTED, F1_TOL])

	print("\n=== F2: symmetry ===")
	print("  d25 %.4f d50 %.4f d75 %.4f  asym %.4f px (limit %.3f)" % [d25, d50, d75, sym, F2_TOL])
	_checks += 1
	if sym > F2_TOL:
		_failures.append("F2 symmetry: %.4f px (limit %.3f)" % [sym, F2_TOL])

	print("\n=== F3: energy ===")
	print("  image mean %.5f  (expected 0.5 +- %.3f)" % [mean, F3_TOL])
	_checks += 1
	if absf(mean - 0.5) > F3_TOL:
		_failures.append("F3 energy: mean %.5f vs 0.5" % mean)

	print("")
	if _failures.is_empty():
		print("PASS: all %d pixel-filter checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Position (px) where the monotone profile crosses p_level, by linear
## interpolation between the two bins that straddle it.
func _cross(p_d: PackedFloat64Array, p_v: PackedFloat64Array, p_level: float) -> float:
	for k in range(1, p_v.size()):
		if p_v[k - 1] < p_level and p_v[k] >= p_level:
			var t := (p_level - p_v[k - 1]) / maxf(p_v[k] - p_v[k - 1], 1e-9)
			return p_d[k - 1] + t * (p_d[k] - p_d[k - 1])
	return NAN


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
