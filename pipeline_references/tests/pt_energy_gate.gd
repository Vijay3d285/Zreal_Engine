extends "res://tests/pt_validation.gd"

## Path-tracer ENERGY gates for environment NEE + MIS.
##
## MIS's failure mode is losing or double-counting energy while still producing a
## plausible image. Neither gate below is a quality metric; both are conservation
## checks, and both are meant to be re-runnable whenever the integrator changes.
##
##   bin\godot.windows.editor.x86_64.exe --path pipeline_references \
##       res://tests/pt_energy_gate_scene.tscn
##
## Env vars:
##   ZR_GATE_MODE    "constant" | "directional" | "both"  (default "both")
##   ZR_GATE_FRAMES  accumulated frames per measurement   (default 256)
##
## ---------------------------------------------------------------------------
## GATE 1 - constant sky. Absolute, analytic.
##
## Constant-radiance environment L = 1.0, one unoccluded Lambertian plane of
## albedo rho = 0.5, no analytic lights, camera looking straight down:
##
##     L_o = integral_hemisphere (rho / PI) * L * cos(theta) dw  =  rho * L
##
##     ~0.50 -> correct;  ~1.00 -> the two strategies double-count (a weight is
##     missing);  ~0.25 -> one side is weighted twice.
##
## The mean alone is NOT sufficient: an environment-NEE block that never fires,
## combined with a miss shader taking weight 1, also lands on exactly rho*L. So
## the gate also reports per-pixel std-dev. Under a CONSTANT sky plain BSDF
## sampling is a zero-variance estimator -- every cosine-sampled path carries
## throughput exactly rho onto radiance exactly L -- so spread > 0 at an
## unchanged mean proves the BSDF half is being weighted down AND that
## environment NEE is putting back exactly the energy the weight removed.
##
## ---------------------------------------------------------------------------
## GATE 2 - directional sky. Relative, against a stored reference.
##
## A constant sky is invariant to rotation, to the octmap border, and to the cell
## lookup, so it is blind to every direction-dependent defect -- including the
## whole class of bugs fixed earlier in this phase. Gate 2 uses a high-contrast
## sky (a bright patch of ~4.6% solid angle at radiance 20 against a 0.02 base,
## 1000:1) and measures two surfaces:
##
##   smooth  - a roughness-0.02 metallic sphere. This is the one that matters.
##             Near-delta specular lobes are unreachable by environment sampling,
##             so the sky reflection must come from the BSDF strategy ALONE. If
##             environment NEE also contributes there, the highlight is counted
##             twice and the sphere renders up to 2x too bright.
##   diffuse - the Lambertian plane again, as a control: it must NOT move.
##
## A SPHERE rather than a flat smooth plane is deliberate. `env_world_to_sky()`
## folds in the camera basis, so which world direction a given panorama texel
## ends up in is not predictable from the scene description; a flat mirror's
## single reflected direction could land on dim sky and the test would quietly
## measure nothing. A sphere reflects essentially every direction at once, so the
## bright patch is guaranteed to appear on it whatever the rotation works out to.
##
## Gate 2 has no closed form -- it is a comparison against numbers captured from
## a BSDF-only build. Update REF_* only alongside a deliberate integrator change,
## and say so in the commit.

const ALBEDO := 0.5 # LINEAR reflectance.
const SKY_RADIANCE := 1.0
const TOLERANCE := 0.01 # 1 percent, per the brief.

# Gate 2 reference, captured at 256 frames / 256x256 from a BSDF-only build --
# the raytracing shaders checked out at de2ce2c248, i.e. before environment NEE
# and the MIS weights existed. Both figures were stable across repeat runs
# (smooth 1.48916 / 1.48892, diffuse 0.37311 / 0.37311), and the reference's
# max pixel was exactly 20.0026: a mirror reflecting a radiance-20 sky patch
# should peak at the patch's own radiance and nothing higher, which is a useful
# independent sanity check on any future re-capture.
const REF_SMOOTH := 1.48904
const REF_DIFFUSE := 0.37311
const REF_TOLERANCE := 0.02 # 2 percent; gate 2 is a stochastic comparison.

var _plane: MeshInstance3D
var _sphere: MeshInstance3D
var _cam: Camera3D
var _failures: Array[String] = []


func _ready() -> void:
	# project.godot renders at 3840x2160 with stretch mode "viewport", so the 3D
	# render target ignores --resolution and an accumulated path-traced sweep would
	# take hours. Disable content scaling so the viewport follows the window.
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(256, 256)
	# Otherwise the per-frame timings below just measure the display refresh.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	await get_tree().process_frame
	await get_tree().process_frame
	print("viewport render size: %s" % str(get_viewport().get_visible_rect().size))

	var frames := 256
	var f_env := OS.get_environment("ZR_GATE_FRAMES")
	if f_env.is_valid_int():
		frames = maxi(32, f_env.to_int())

	var mode := OS.get_environment("ZR_GATE_MODE")
	if mode == "":
		mode = "both"

	if mode == "constant" or mode == "both":
		await _gate_constant(frames)
	if mode == "directional" or mode == "both":
		await _gate_directional(frames)

	print("\n=== RESULT ===")
	if _failures.is_empty():
		print("PASS - all energy gates green.")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		get_tree().quit(1)


# ---------------------------------------------------------------------------
# GATE 1 - constant sky
# ---------------------------------------------------------------------------
func _gate_constant(p_frames: int) -> void:
	var env := _build_scene(_constant_panorama())
	_sphere.visible = false
	_look_down()
	# The sky's radiance octmap is rendered by the sky pass and the env CDF is
	# built from it; both need a moment before the first measurement.
	await get_tree().create_timer(2.0).timeout

	print("\n=== GATE 1: constant sky L=%.3f, Lambertian albedo %.3f ===" % [SKY_RADIANCE, ALBEDO])

	# Pass A: plane hidden, so every camera ray misses and lands on the sky with
	# mis_ray_pdf == RT_MIS_PDF_NONE (weight 1). Measures L_env as the renderer
	# actually sees it, absorbing IBL_exposure_normalization, the sky shader's own
	# scaling and the octmap round trip. The gate is a RATIO against this, so no
	# global sky scale can fake a pass or a failure.
	_plane.visible = false
	var sky_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 16)
	if sky_img == null:
		_failures.append("gate 1: accumulator readback returned null (sky pass)")
		return
	var l_sky: float = _measure_crop(sky_img, 0.25, 0.75)["mean"]
	print("  [A] sky-only mean radiance : %.5f" % l_sky)

	# Pass B: the plane.
	_plane.visible = true
	for _i in range(4):
		await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	var dt := Time.get_ticks_msec() - t0
	if img == null:
		_failures.append("gate 1: accumulator readback returned null")
		return
	var stats := _measure_crop(img, 0.25, 0.75)
	print("  [B] %d frames in %d ms (%.3f ms/frame at 256x256)" % [p_frames, dt, float(dt) / float(p_frames)])

	var expected: float = ALBEDO * l_sky
	var err: float = absf(stats["mean"] - expected) / maxf(expected, 1e-9)
	print("      measured  : %.5f  (R %.5f  G %.5f  B %.5f)" % [stats["mean"], stats["r"], stats["g"], stats["b"]])
	print("      expected  : %.5f  (rho * L_env)" % expected)
	print("      rel error : %.3f%%" % (err * 100.0))
	if err > TOLERANCE:
		_failures.append("gate 1 energy: %.5f vs %.5f expected, %.3f%% off (limit %.1f%%)"
				% [stats["mean"], expected, err * 100.0, TOLERANCE * 100.0])

	# Pass C: the variance proof described in the header.
	var few := 4
	var noisy: Image = await _render_accum(env, get_viewport().get_viewport_rid(), few)
	if noisy != null:
		var ns := _measure_crop(noisy, 0.25, 0.75)
		var sd := _stddev_crop(noisy, ns["mean"], 0.25, 0.75)
		print("  [C] %d-frame per-pixel std-dev : %.6f (mean %.5f)" % [few, sd, ns["mean"]])
		print("      %s" % ("both MIS strategies live (BSDF-only would be exactly 0)" if sd > 1e-5
				else "ZERO SPREAD - the MIS split is NOT running"))
		if sd <= 1e-5:
			_failures.append("gate 1 liveness: zero per-pixel spread under a constant sky - the MIS split is not running")


# ---------------------------------------------------------------------------
# GATE 2 - directional sky
# ---------------------------------------------------------------------------
func _gate_directional(p_frames: int) -> void:
	var env := _build_scene(_sun_panorama())
	await get_tree().create_timer(2.0).timeout

	print("\n=== GATE 2: directional sky (bright patch 20.0 vs base 0.02) ===")

	# Smooth pass: roughness-0.02 metallic sphere, nothing else.
	_plane.visible = false
	_sphere.visible = true
	_look_at_sphere()
	for _i in range(4):
		await get_tree().process_frame
	var s_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	if s_img == null:
		_failures.append("gate 2: accumulator readback returned null (smooth pass)")
		return
	var smooth := _measure_disc(s_img, 0.45)
	print("  [smooth ] mirror sphere mean : %.5f   (max pixel %.4f over %d px)"
			% [smooth["mean"], smooth["max"], smooth["n"]])

	# Diffuse pass: the Lambertian plane, as a control.
	_sphere.visible = false
	_plane.visible = true
	_look_down()
	for _i in range(4):
		await get_tree().process_frame
	var d_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), p_frames)
	if d_img == null:
		_failures.append("gate 2: accumulator readback returned null (diffuse pass)")
		return
	var diffuse := _measure_crop(d_img, 0.25, 0.75)
	print("  [diffuse] plane mean         : %.5f" % diffuse["mean"])

	if REF_SMOOTH <= 0.0 or REF_DIFFUSE <= 0.0:
		print("  (no reference captured yet - record these as REF_SMOOTH / REF_DIFFUSE)")
		return

	var s_err: float = absf(smooth["mean"] - REF_SMOOTH) / REF_SMOOTH
	var d_err: float = absf(diffuse["mean"] - REF_DIFFUSE) / REF_DIFFUSE
	print("  smooth  vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_SMOOTH, smooth["mean"] / REF_SMOOTH, s_err * 100.0])
	print("  diffuse vs reference %.5f : ratio %.4f  (%.2f%% off)" % [REF_DIFFUSE, diffuse["mean"] / REF_DIFFUSE, d_err * 100.0])
	if s_err > REF_TOLERANCE:
		_failures.append("gate 2 smooth: %.5f vs reference %.5f, ratio %.4f. A ratio near 2 means the near-delta specular sky highlight is being counted by BOTH strategies."
				% [smooth["mean"], REF_SMOOTH, smooth["mean"] / REF_SMOOTH])
	if d_err > REF_TOLERANCE:
		_failures.append("gate 2 diffuse: %.5f vs reference %.5f, ratio %.4f (the diffuse control must not move)."
				% [diffuse["mean"], REF_DIFFUSE, diffuse["mean"] / REF_DIFFUSE])


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------
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
	r *= inv
	g *= inv
	b *= inv
	return { "r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n }


## Mean over a centred disc of radius `p_radius` in units of half the smaller
## image dimension. Used for the sphere so the measurement never picks up sky
## pixels outside the silhouette.
func _measure_disc(p_img: Image, p_radius: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	var rad := p_radius * float(mini(w, h)) * 0.5
	var rad2 := rad * rad
	var acc := 0.0
	var peak := 0.0
	var n := 0
	for y in range(h):
		for x in range(w):
			var dx := float(x) + 0.5 - cx
			var dy := float(y) + 0.5 - cy
			if dx * dx + dy * dy > rad2:
				continue
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			acc += v
			peak = maxf(peak, v)
			n += 1
	return { "mean": acc / float(maxi(n, 1)), "max": peak, "n": n }


func _stddev_crop(p_img: Image, p_mean: float, p_lo: float, p_hi: float) -> float:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var acc := 0.0
	var n := 0
	for y in range(int(h * p_lo), int(h * p_hi)):
		for x in range(int(w * p_lo), int(w * p_hi)):
			var c := p_img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0 - p_mean
			acc += v * v
			n += 1
	return sqrt(acc / float(maxi(n, 1)))


# ---------------------------------------------------------------------------
# Scene
# ---------------------------------------------------------------------------
func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


## Dim base with one bright lat-lon patch. u in [0.2,0.5], v in [0.4,0.5] is
## theta in [72deg, 90deg], so the patch covers 0.3 * (cos72 - cos90) / 2 = 4.6%
## of the sphere -- small enough to be strongly directional, large enough that it
## lands on many pixels of the mirror sphere whatever the sky rotation is.
func _sun_panorama() -> ImageTexture:
	var w := 128
	var h := 64
	var pano := Image.create(w, h, false, Image.FORMAT_RGBF)
	pano.fill(Color(0.02, 0.02, 0.02))
	for y in range(int(h * 0.40), int(h * 0.50)):
		for x in range(int(w * 0.20), int(w * 0.50)):
			pano.set_pixel(x, y, Color(20.0, 20.0, 20.0))
	return ImageTexture.create_from_image(pano)


func _look_down() -> void:
	_cam.position = Vector3(0.0, 2.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)


func _look_at_sphere() -> void:
	_cam.position = Vector3(0.0, 0.0, 4.0)
	_cam.rotation_degrees = Vector3.ZERO


func _build_scene(p_panorama: ImageTexture) -> Environment:
	for c in get_children():
		c.queue_free()

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = p_panorama
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

	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(4)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias; it must be off or it eats the very energy
	# these gates are measuring.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_cam = Camera3D.new()
	_cam.fov = 55.0
	add_child(_cam)
	_cam.make_current()
	_look_down()

	# The diffuse plane: large enough that its edges are far outside the view,
	# thin box so the top face is a genuine single-sided surface under back-face
	# culling.
	_plane = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(200.0, 0.2, 200.0)
	_plane.mesh = bm
	_plane.position = Vector3(0.0, -0.1, 0.0)
	var mat := StandardMaterial3D.new()
	# ALBEDO is the LINEAR reflectance the analytic answer is written in, but
	# render_raytracing.cpp:1492 runs albedo_color through srgb_to_linear() before
	# it reaches the BRDF. Pre-encode so the shader ends up with exactly ALBEDO.
	# Without this the plane reads 0.21404 = srgb_to_linear(0.5), which looks
	# exactly like a 57% MIS energy loss and is really just a colour-space round
	# trip. This trap cost real debugging time once; do not "simplify" it away.
	mat.albedo_color = Color(ALBEDO, ALBEDO, ALBEDO).linear_to_srgb()
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Kills the dielectric specular lobe (F0 = 0.16 * specular^2), leaving a pure
	# Lambertian BRDF whose directional-hemispherical reflectance is exactly rho.
	# At the default specular = 0.5 the surface also carries an F0 = 0.04 lobe and
	# the analytic answer above no longer holds.
	mat.metallic_specular = 0.0
	_plane.material_override = mat
	add_child(_plane)

	# The near-delta mirror. metallic = 1 makes specularF0 = albedo and
	# diffuseReflectance = 0, so this surface is reached ONLY through the specular
	# lobe; roughness 0.02 is below RT_MIS_DELTA_ROUGHNESS (0.03), which is the
	# regime environment sampling must not contribute to.
	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 96
	sm.rings = 48
	_sphere.mesh = sm
	_sphere.position = Vector3.ZERO
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(1.0, 1.0, 1.0)
	smat.metallic = 1.0
	smat.roughness = 0.02
	_sphere.material_override = smat
	add_child(_sphere)
	_sphere.visible = false

	return env
