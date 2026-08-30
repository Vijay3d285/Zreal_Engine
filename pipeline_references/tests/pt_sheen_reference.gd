extends "res://tests/pt_validation.gd"

## E2e Task 6: the Cycles VELVET reference comparison harness.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_sheen_reference_scene.tscn
##
## Renders a velvet sphere in three arms under a spatially uniform environment
## of radiance 1.0, prints the per-channel whole-image mean of each, and saves
## each arm to a linear EXR. A companion Blender/Cycles script renders the SAME
## sphere with the SAME numbers through Blender's Principled BSDF; a third
## script differences the two.
##
## WHY THE ARMS ARE WHAT THEY ARE
##   velvet      -- sheen ON at Cycles' own default sheen roughness. The headline.
##   nosheen     -- byte-identical except sheen_color == 0. Subtracting this arm
##                  from each sheen arm INSIDE EACH ENGINE cancels every
##                  base-diffuse and base-specular term, Gap #17's
##                  evalMultiScatterApproximation pedestal included, leaving
##                  exactly what the sheen layer contributes: its own reflection
##                  minus the withdrawal it takes from the base.
##   velvetsharp -- the same sheen at roughness 0.30.
##   velvetrough -- the same sheen at roughness 0.80.
##                  The sheen LTC table is indexed (cosNI, roughness),
##                  TRANSPOSED relative to the coat's (roughness, mu). Arms at
##                  three separated roughnesses are the only CROSS-ENGINE
##                  evidence that the axis order is right: a transposition
##                  changes the roughness response shape, which one arm cannot
##                  see and three arms can.
##
## SHEEN ROUGHNESS IS NOT OPTIONAL. Godot defaults `sheen_roughness` to 0
## (scene/resources/material.h:579) while Cycles' Principled defaults it to 0.5,
## and 90 of the 1024 LTC cells fail the invalid-LTC test -- all of them in the
## lowest roughness rows. A velvet scene that sets `sheen_color` and leaves
## roughness alone renders NO SHEEN AT ALL, measures a zero delta against its own
## control, and reads as a suspiciously good match. Both arms set it explicitly.
##
## COLOUR SPACE, the trap this phase family has hit twice.
## `render_raytracing.cpp:1827` sRGB-DECODES `sheen_color` on upload, exactly as
## `:1595` does to `albedo` -- Cycles' sockets are linear. So every colour here
## is authored `Color(<linear>).linear_to_srgb()` and Blender is handed the same
## `<linear>` number. Each renderer is compared against the same authored LINEAR
## value, never field-for-field against the other. The round trip through the
## engine's own Color methods is printed below so the claim is checkable.
##
## COORDINATE MAPPING (Godot Y-up -> Blender Z-up): blender(x,y,z) = godot(x,-z,y).
## Camera godot (0,0,2.5) look_at origin, 20 deg VERTICAL fov <-> blender
## (0,-2.5,0) rot (90,0,0), sensor_fit VERTICAL, angle radians(20).
## Sphere radius 1.0 at distance 2.5 subtends 23.58 deg against a 14.14 deg
## diagonal half-angle, so EVERY PIXEL IN EVERY RENDER IS A SPHERE HIT and the
## whole-image mean is a surface-only statistic with no background to mask off.

const RES := 256
const FRAMES := 256
const SKY_RADIANCE := 1.0

# --- authored LINEAR values; Blender is handed these same numbers verbatim ---
const BASE_LINEAR := Color(0.12, 0.02, 0.03)   # deep red velvet base
const BASE_ROUGHNESS := 0.6
const BASE_METALLIC := 0.0
# sheen_color IS Cycles' sheen_weight * sheen_tint: brdf_inc.glsl:334-338 folds
# the weight into the colour, and svm/closure.h:123-124 forms the closure weight
# as `sheen_weight * rgb_to_spectrum(sheen_tint) * weight`. The Blender arm
# therefore sets Sheen Weight = 1.0 and Sheen Tint = this same linear triple.
# Three distinct channels so the per-channel ratios carry information.
const SHEEN_LINEAR := Color(0.75, 0.70, 0.55)
# THREE sheen roughnesses, not one. The Zeltner lobe is grazing-concentrated at
# low roughness: reading the shipped LUT directly, the sheen albedo at
# cosNI 0.5 is 0.0216 at roughness 0.30 but 0.3808 at 0.80 -- an 18x span. A
# single arm at 0.30 would put ~0.8% of the image on the scale being measured
# and the cross-engine ratio would be mostly noise; a single arm at 0.80 would
# never visit the part of the table where the lobe is narrow. 0.50 is Cycles'
# own Principled default, chosen for that reason and not for its result.
const SHEEN_ROUGHNESS_A := 0.30
const SHEEN_ROUGHNESS_B := 0.50
const SHEEN_ROUGHNESS_C := 0.80

var _sphere: MeshInstance3D
var _mat: StandardMaterial3D
var _out_dir := ""


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(RES, RES)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_out_dir = OS.get_environment("ZR_SHEENREF_OUT")

	await get_tree().process_frame
	await get_tree().process_frame

	var env := _build_scene()
	await get_tree().create_timer(1.0).timeout

	print("\n=== E2e Cycles velvet reference (tag 'godot') ===")
	print("resolution: %dx%d, accumulated frames: %d, max_bounces: 3" % [RES, RES, FRAMES])
	_print_roundtrip("BASE ", BASE_LINEAR)
	_print_roundtrip("SHEEN", SHEEN_LINEAR)

	var vp := get_viewport().get_viewport_rid()
	var arms := [
		["velvet", SHEEN_LINEAR, SHEEN_ROUGHNESS_B],
		["nosheen", Color(0, 0, 0), SHEEN_ROUGHNESS_B],
		["velvetsharp", SHEEN_LINEAR, SHEEN_ROUGHNESS_A],
		["velvetrough", SHEEN_LINEAR, SHEEN_ROUGHNESS_C],
	]
	for arm in arms:
		var tag: String = arm[0]
		var sheen: Color = arm[1]
		var srough: float = arm[2]
		_mat.sheen_color = sheen.linear_to_srgb()
		_mat.sheen_roughness = srough
		# The material write reaches the rendering server asynchronously; the
		# accumulator must not start before the new material has landed or the
		# first frames of the arm carry the PREVIOUS arm's sheen.
		for _i in range(8):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw

		var img: Image = await _render_accum(env, vp, FRAMES)
		if img == null:
			print("FAIL - accumulator readback returned null for arm %s" % tag)
			get_tree().quit(1)
			return
		var m := _channel_means(img)
		print("GODOT %-12s sheen_linear=(%.6f,%.6f,%.6f) sheen_rough=%.2f  mean_r=%.8f mean_g=%.8f mean_b=%.8f mean=%.8f (n=%d)"
				% [tag, sheen.r, sheen.g, sheen.b, srough,
				   m[0], m[1], m[2], (m[0] + m[1] + m[2]) / 3.0, RES * RES])
		if _out_dir != "":
			var p := _out_dir.path_join("godot_%s.exr" % tag)
			var err: int = img.save_exr(p, false)
			if err != OK:
				print("  WARNING: save_exr returned %d for %s" % [err, p])

	print("\n=== DONE ===")
	get_tree().quit(0)


## Whole-image per-channel mean. Every pixel is a sphere hit (see the header's
## solid-angle arithmetic), so no masking is needed and none is done -- a mask
## would be a place for a silent divergence from the Blender side to hide.
func _channel_means(p_img: Image) -> Array:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var w := p_img.get_width()
	var h := p_img.get_height()
	for y in range(h):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
	var n := float(w * h)
	return [r / n, g / n, b / n]


## Prints the authored linear value, the sRGB number actually stored on the
## material, and the linear value the engine recovers from it. If the middle
## column is what a reader hands Blender, the comparison is broken -- this is
## the §7.7 error, printed so it cannot happen silently.
func _print_roundtrip(p_tag: String, p_linear: Color) -> void:
	var s := p_linear.linear_to_srgb()
	var back := s.srgb_to_linear()
	print("%s linear=(%.8f,%.8f,%.8f) -> authored srgb=(%.8f,%.8f,%.8f) -> engine decode=(%.8f,%.8f,%.8f)"
			% [p_tag, p_linear.r, p_linear.g, p_linear.b, s.r, s.g, s.b, back.r, back.g, back.b])


func _constant_panorama() -> ImageTexture:
	var pano := Image.create(64, 32, false, Image.FORMAT_RGBF)
	pano.fill(Color(SKY_RADIANCE, SKY_RADIANCE, SKY_RADIANCE))
	return ImageTexture.create_from_image(pano)


func _build_scene() -> Environment:
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = _constant_panorama()
	sky_mat.energy_multiplier = 1.0

	var sky := Sky.new()
	# PROCESS_MODE_REALTIME force-clamps the radiance size to 256, which quietly
	# changes what the environment CDF is built from (sky.cpp).
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.sky_material = sky_mat

	var env := Environment.new()
	# BG_SKY with a real Sky resource is MANDATORY -- BG_COLOR renders pure black
	# to the path tracer (roadmap F3).
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	env.set_pathtracing_enabled(true)
	# A lone convex sphere cannot re-hit itself, so bounce depth is not a free
	# variable here; matched to the Cycles side's 3 anyway.
	env.set_pathtracing_max_bounces(3)
	env.set_pathtracing_samples_per_pixel(1) # ignored while accumulating
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	# Clamping is a deliberate bias and would eat the energy being measured.
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sphere = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 64
	sm.rings = 32
	_sphere.mesh = sm
	_sphere.position = Vector3.ZERO

	_mat = StandardMaterial3D.new()
	_mat.albedo_color = BASE_LINEAR.linear_to_srgb()
	_mat.metallic = BASE_METALLIC
	_mat.roughness = BASE_ROUGHNESS
	# No coat: `coat_normal` is not shipped, and with coat_weight 0 Cycles' sheen
	# normal `mix(N, coat_normal, coat_weight)` (svm/closure.h:127-129) collapses
	# to N on both sides, so the one geometric divergence between the engines is
	# held at zero rather than left free.
	_mat.clearcoat_enabled = false
	_sphere.material_override = _mat
	add_child(_sphere)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 2.5)
	cam.fov = 20.0 # vertical; Camera3D defaults to KEEP_HEIGHT
	add_child(cam)
	cam.make_current()
	cam.look_at(Vector3.ZERO, Vector3.UP)

	return env
