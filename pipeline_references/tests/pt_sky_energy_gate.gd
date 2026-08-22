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

	var b256: float = await _probe_b_at(Sky.RADIANCE_SIZE_256, "radiance 256")
	_verdict["b256"] = b256
	if b256 > 0.0 and absf(b256 - 1.0) > TOLERANCE:
		_failures.append("probe B (radiance 256): ratio %.5f vs 1.0 (limit %.0f%%)"
				% [b256, TOLERANCE * 100.0])

	var b2048: float = await _probe_b_at(Sky.RADIANCE_SIZE_2048, "radiance 2048")
	_verdict["b2048"] = b2048
	if b2048 > 0.0 and absf(b2048 - 1.0) > TOLERANCE:
		_failures.append("probe B (radiance 2048): ratio %.5f vs 1.0 (limit %.0f%%)"
				% [b2048, TOLERANCE * 100.0])

	# PROBE C -- the resolution comparison itself.
	#
	# Same panorama, same geometry, same integrator; only Sky.radiance_size
	# differs. Physics does not depend on a texture size, so ANY difference here
	# is energy the radiance map lost. This is the one probe in the file that
	# needs neither an analytic model nor another renderer to be conclusive.
	if b256 > 0.0 and b2048 > 0.0:
		var res_delta: float = absf(b2048 - b256) / maxf(b256, 1e-9)
		print("\n=== PROBE C: resolution sensitivity ===")
		print("  ratio at 256  : %.5f" % b256)
		print("  ratio at 2048 : %.5f" % b2048)
		print("  relative shift: %.3f%%" % (res_delta * 100.0))
		_verdict["c_shift"] = res_delta
		if res_delta > TOLERANCE:
			_failures.append("probe C: response moved %.3f%% between radiance 256 and 2048 -- the radiance map is losing energy (Mechanism B)"
					% (res_delta * 100.0))

	await _probe_d()
	_print_verdict()

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


const PANO_W := 2048
const PANO_H := 1024
const BAND_BASE := 0.02
const BAND_BRIGHT := 200.0


## A dim base with two narrow bright bands, mirrored about the equator.
##
## MIRRORED ON PURPOSE. This gate must not assume whether the engine's lat-long
## v = 0 is +Y or -Y. A top-bottom symmetric panorama presents identical content
## to the upward hemisphere under either convention, so _analytic_outgoing_radiance()
## is correct without the gate ever having to know -- and the probe measures
## ENERGY rather than accidentally testing orientation.
##
## Each band is p_bright_rows texel rows out of PANO_H, an angular width of
## p_bright_rows * PI / PANO_H. At the default of 1 row that is PI/1024, far
## thinner than a 256px octmap texel (PI/256 at best). A point sampler either
## hits it or misses it; an area average preserves it. That gap is what probe C
## measures.
func _banded_panorama(p_bright_rows: int) -> ImageTexture:
	var pano := Image.create(PANO_W, PANO_H, false, Image.FORMAT_RGBF)
	pano.fill(Color(BAND_BASE, BAND_BASE, BAND_BASE))
	var y_top := int(PANO_H * 0.25)
	var y_bot := PANO_H - 1 - y_top
	for i in range(p_bright_rows):
		for x in range(PANO_W):
			pano.set_pixel(x, y_top + i, Color(BAND_BRIGHT, BAND_BRIGHT, BAND_BRIGHT))
			pano.set_pixel(x, y_bot - i, Color(BAND_BRIGHT, BAND_BRIGHT, BAND_BRIGHT))
	return ImageTexture.create_from_image(pano)


## Outgoing radiance of an upward-facing Lambertian patch of reflectance ALBEDO
## under the panorama, computed from the IMAGE -- never from a render.
##
##   E   = integral over upper hemisphere of L(w) cos(theta) dw
##   L_o = ALBEDO * E / PI
##
## The panorama is azimuthally uniform by construction, so the phi integral is
## just a factor of 2*PI and the sum runs over rows only:
##
##   E = sum over rows with theta < PI/2 of  L(row) * 2*PI * cos(theta) * sin(theta) * dtheta
##
## with dtheta = PI / PANO_H and theta measured from the pole at v = 0. Because
## the panorama is mirrored, whichever pole that is, the upper hemisphere sees
## the same values -- so summing the v < 0.5 half is correct either way.
func _analytic_outgoing_radiance(p_img: Image) -> float:
	var h := p_img.get_height()
	var d_theta := PI / float(h)
	var e := 0.0
	for y in range(h):
		var theta := (float(y) + 0.5) * d_theta
		if theta >= PI * 0.5:
			continue
		# Azimuthally uniform: one sample per row is exact.
		var c := p_img.get_pixel(0, y)
		var l := (c.r + c.g + c.b) / 3.0
		e += l * TAU * cos(theta) * sin(theta) * d_theta
	return ALBEDO * e / PI


## PROBE B -- peaked sky, Lambertian plane, against the analytic integral.
##
## Returns the measured/analytic ratio so probe C can compare two resolutions.
## A Lambertian plane integrates the whole upper hemisphere, so its response is
## proportional to the sky's INTEGRAL -- which is the energy quantity that a
## point-subsampled radiance map fails to preserve.
func _probe_b_at(p_radiance_size: int, p_label: String) -> float:
	var pano_tex := _banded_panorama(1)
	var env := _build_scene(pano_tex, p_radiance_size)
	_plane.visible = true
	_look_down()
	await get_tree().create_timer(2.0).timeout

	var analytic := _analytic_outgoing_radiance(pano_tex.get_image())

	print("\n=== PROBE B [%s]: banded sky, Lambertian albedo %.3f ===" % [p_label, ALBEDO])
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	if img == null:
		_failures.append("probe B [%s]: accumulator readback returned null" % p_label)
		return -1.0
	var s := _measure_crop(img, 0.25, 0.75)
	var ratio: float = s["mean"] / maxf(analytic, 1e-9)
	print("  analytic L_o : %.5f  (from the panorama image)" % analytic)
	print("  measured     : %.5f  (R %.5f  G %.5f  B %.5f)" % [s["mean"], s["r"], s["g"], s["b"]])
	print("  ratio        : %.5f" % ratio)
	return ratio


## PROBE D -- read IBL_exposure_normalization straight off the GPU.
##
## env_sky_radiance() multiplies sky radiance by this scalar
## (raytracing_closest_hit_common_inc.glsl:306). Cycles has no equivalent. Vis
## mode 34 reports it in the red channel at any pixel covering geometry, so the
## value is OBSERVED rather than inferred from a brightness ratio -- inferring
## it would assume the rest of the sky path is correct, which is what the gate
## is testing.
func _probe_d() -> void:
	var env := _build_scene(_constant_panorama(), Sky.RADIANCE_SIZE_256)
	_plane.visible = true
	_look_down()
	await get_tree().create_timer(2.0).timeout

	env.set_pathtracing_debug_mode(34)
	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), 4)
	env.set_pathtracing_debug_mode(0)
	if img == null:
		_failures.append("probe D: accumulator readback returned null")
		return
	var s := _measure_crop(img, 0.4, 0.6)
	print("\n=== PROBE D: IBL_exposure_normalization ===")
	print("  value : %.6f" % s["r"])
	_verdict["d_ibl"] = s["r"]
	if absf(s["r"] - 1.0) > TOLERANCE:
		_failures.append("probe D: IBL_exposure_normalization is %.6f, not 1.0 -- it scales sky radiance and Cycles has no counterpart (Mechanism A)"
				% s["r"])


## Reads the four numbers against a rule fixed BEFORE the measurement, so the
## conclusion is read off rather than argued for afterwards.
func _print_verdict() -> void:
	var a: float = _verdict.get("a_ratio", -1.0)
	var b256: float = _verdict.get("b256", -1.0)
	var b2048: float = _verdict.get("b2048", -1.0)
	var shift: float = _verdict.get("c_shift", -1.0)
	var ibl: float = _verdict.get("d_ibl", -1.0)

	print("\n=== VERDICT ===")
	print("  A constant-sky ratio        : %.5f" % a)
	print("  B ratio @ radiance 256      : %.5f" % b256)
	print("  B ratio @ radiance 2048     : %.5f" % b2048)
	print("  C resolution shift          : %.3f%%" % (shift * 100.0))
	print("  D IBL_exposure_normalization: %.6f" % ibl)

	var a_off := absf(a - 1.0) > TOLERANCE
	var res_sensitive := shift > TOLERANCE

	if a_off and not res_sensitive:
		print("  -> MECHANISM A. A scalar dims the sky at every peakedness and the")
		print("     response does not move with resolution. Probe D names the value.")
	elif res_sensitive:
		print("  -> MECHANISM B. The response moves with radiance-map resolution, so")
		print("     energy is lost in the map. The fix is to stop borrowing the raster")
		print("     IBL map and sample the panorama directly (spec 5.2).")
	elif not a_off and not res_sensitive and absf(b256 - 1.0) <= TOLERANCE:
		print("  -> NEITHER. Both engine-side mechanisms are clean, so the 23%% is a")
		print("     measurement artefact in the Cycles-side setup (colour management,")
		print("     or gen_panorama.py's own scaling). Spec 8.7: correct roadmap 7.4")
		print("     and make NO engine change.")
	else:
		print("  -> INCONCLUSIVE. Probe B is off while A is clean and resolution does")
		print("     not matter, which fits no modelled mechanism. Do not guess a fix;")
		print("     widen the sweep before changing any engine code.")
