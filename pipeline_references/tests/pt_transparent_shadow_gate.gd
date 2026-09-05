extends "res://tests/pt_validation.gd"

## Transparent shadows GPU gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transparent_shadow_gate_scene.tscn
##
## WHAT THIS PROVES. Before transparent shadows, lights_trace_shadow_ray used
## gl_RayFlagsTerminateOnFirstHitEXT and returned a boolean, and the any-hit stage
## consulted only alpha cutout -- so a transmissive surface was a full occluder and
## anything enclosed in glass received ZERO direct light from every source
## (analytic, emissive-mesh, and environment NEE all route through that one
## function). This gate measures that directly as a ratio.
##
## The doctest suite cannot catch this: it mirrors GLSL formulas in C++ and never
## executes a shader, and the headless renderer discards material parameters
## entirely. Only a real GPU render through the real shadow path measures it.
##
## THIS GATE IS EXPECTED TO FAIL until the glass-passing pass (the task after
## this one) lands. Task 3 tags transmissive TLAS instances with a cull mask and
## lights_trace_shadow_ray already returns a vec3, but every call site still
## resolves to vec3(0.0) or vec3(1.0) -- the fractional Fresnel transmittance
## this gate measures does not exist yet. Probe 1 is the one that carries the
## gate before that fix: the pre-fix ratio is ~0.0 and cannot satisfy
## [P1_RATIO_MIN, P1_RATIO_MAX] under any tolerance. Probe 2 trivially "passes"
## before the fix (0.0 is below its ceiling) -- that is expected.

const FRAMES := 128

# One pane crossed twice (front and back face) at near-normal incidence, ior 1.5:
# F0 = ((1.5-1)/(1.5+1))^2 = 0.04, so each crossing passes ~0.96 and the pair
# ~0.92. The floor is what carries the gate -- the pre-fix value is 0.0 and
# cannot satisfy it under any tolerance.
const P1_RATIO_MIN := 0.85
const P1_RATIO_MAX := 1.00

# The light (not the pane -- see _measure_ratio's geometry note) tilted to
# 80deg incidence from the horizontal pane's normal.
# Dielectric Fresnel at ior 1.5 reflects ~0.40 there, so the ratio must fall well
# below the near-normal case. A flat (non-Fresnel) attenuation leaves it unchanged
# at ~0.92, so this bound is what distinguishes the two.
const P2_INCIDENCE_DEG := 80.0
const P2_GRAZING_MAX := 0.80

var _failures: Array[String] = []
var _checks: int = 0

func _ready() -> void:
	print("\n=== PROBE 1: interior lit through a pane ===")
	await _probe1_interior_lit()

	print("\n=== PROBE 2: grazing crossing darkens ===")
	await _probe2_grazing_darkens()

	print("")
	if _failures.is_empty():
		print("PASS: all %d transparent-shadow checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## Renders a lit grey floor twice -- once with a glass pane interposed between it
## and the light, once with that pane hidden -- and returns the ratio.
##
## Toggling `visible` rather than building two scenes is deliberate, and is the
## same technique probe 3 of pt_transmission_gate.gd uses: every other term (light
## intensity, BRDF, exposure, tonemap, camera) is bit-identical between the two
## arms, so it cancels in the ratio and what remains is the shadow transmittance
## alone.
func _probe1_interior_lit() -> void:
	var ratio := await _measure_ratio(0.0)
	print("  ratio through pane = %.6f (band %.2f - %.2f)"
			% [ratio, P1_RATIO_MIN, P1_RATIO_MAX])
	_checks += 1
	if ratio < P1_RATIO_MIN or ratio > P1_RATIO_MAX:
		_failures.append("probe1 interior lit: ratio %.6f outside [%.2f, %.2f]"
				% [ratio, P1_RATIO_MIN, P1_RATIO_MAX])


func _probe2_grazing_darkens() -> void:
	var ratio := await _measure_ratio(P2_INCIDENCE_DEG)
	print("  incidence = %.1fdeg, ratio = %.6f (must be < %.2f)"
			% [P2_INCIDENCE_DEG, ratio, P2_GRAZING_MAX])
	_checks += 1
	if ratio >= P2_GRAZING_MAX:
		_failures.append(("probe2 grazing: ratio %.6f is not below %.2f -- Fresnel is "
				+ "not reaching the accumulation, or a flat factor is being applied")
				% [ratio, P2_GRAZING_MAX])


## p_incidence_deg is the DirectionalLight3D's incidence angle from the
## horizontal pane's +Y normal (0 = straight down / near-normal, larger =
## grazing). The pane itself is ALWAYS flat and unrotated -- grazing is
## achieved by tilting the light, not the pane, so the pane never stands up
## into the camera's line of sight edge-on (that was the round-2 defect: a
## rotated pane at 80deg is nearly vertical and the camera ends up looking
## through its edge, contaminating the measurement with something other than
## shadow-ray transmittance).
func _measure_ratio(p_incidence_deg: float) -> float:
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

	# Matches _apply_glb_transmissive_glass in image_glb_creation.gd (size
	# only -- the Y position below is specific to this gate's geometry).
	#
	# GEOMETRY: for a directional light at incidence angle theta from this
	# horizontal pane's normal, a ray reaching a floor point at height
	# y_floor crosses the pane's plane (height y_pane) offset in Z by
	# separation * tan(theta), where separation = y_pane - y_floor. (Proof:
	# the light's local -Z direction at rotation_degrees.x = -(90-theta) is
	# d = (0, -cos(theta), -sin(theta)); tracing a floor hit backward along
	# -d by t = separation / cos(theta) to reach y_pane shifts z by
	# t * sin(theta) = separation * tan(theta).)
	#
	# The measured crop's floor footprint is x in [-0.78, 0.78],
	# z in [-1.246, 0.805] (corner rays of the 0.35-0.65 crop through this
	# camera, computed in the task-4 report). At the old pane position
	# (y=1, separation=2 from the floor at y=-1) the probe-2 offset at
	# theta=80deg was 2 * tan(80deg) = 11.34 units -- far outside this
	# pane's +/-4 half-extent, so the pane was not in the light path at all
	# and probe 2 measured nothing (that was the round-1-era bug, compounded
	# by the round-2 bug of rotating the pane on top of it).
	#
	# Fix: move the pane down to separation = 0.4 (y = -1 + 0.4 = -0.6) and
	# keep its horizontal 8x8 size. At theta=80deg the offset is
	# 0.4 * tan(80deg) = 2.2685 units, so the crop's floor-Z range maps to a
	# pane-crossing-Z range of [-1.246+2.2685, 0.805+2.2685] =
	# [1.0225, 3.0735] -- entirely inside the pane's [-4, 4] half-extent,
	# with 0.9265 units of margin at the near edge. x is unaffected (the
	# light only rotates about X), so [-0.78, 0.78] stays comfortably inside
	# [-4, 4] too. Every ray reaching the measured crop therefore passes
	# through the pane at every incidence angle this gate uses, including
	# theta=0 (probe 1, offset 0, trivially satisfied).
	var pane := MeshInstance3D.new()
	var pane_mesh := BoxMesh.new()
	pane_mesh.size = Vector3(8, 0.05, 8)
	pane.mesh = pane_mesh
	pane.position = Vector3(0, -0.6, 0)
	var glass_mat := StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	glass_mat.transmission = 1.0
	glass_mat.thickness = 0.0
	glass_mat.roughness = 0.0
	glass_mat.metallic = 0.0
	glass_mat.metallic_specular = 0.5
	glass_mat.ior = 1.5
	pane.material_override = glass_mat
	add_child(pane)

	var light := DirectionalLight3D.new()
	# rotation_degrees = (-90, 0, 0) points straight down, which is 0deg from
	# the horizontal pane's +Y normal. For incidence angle p_incidence_deg
	# from that normal the rotation is -(90 - p_incidence_deg).
	light.rotation_degrees = Vector3(-(90.0 - p_incidence_deg), 0, 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var cam := Camera3D.new()
	var cam_pos := Vector3(0, 0.5, 4)
	# look_at_from_position(), not position + look_at(): look_at() requires the
	# node to already be inside the scene tree (it needs a global transform to
	# rebase against), which it is not until add_child() runs. Matches the
	# established pattern in pt_transmission_gate.gd:1020-1031/1463-1481.
	cam.look_at_from_position(cam_pos, Vector3(0, -1, 0), Vector3.UP)
	cam.fov = 30.0
	add_child(cam)
	cam.make_current()

	# Black background and one bounce: the floor must be lit by the directional
	# light through the pane and by nothing else, or the ratio measures ambient
	# rather than shadow transmittance.
	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(1)
	await _settle_sky()

	pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	pane.visible = true
	await _settle()
	var glass_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(glass_img, 0.35, 0.65)

	print("  control mean %.6f, through-glass mean %.6f"
			% [control["mean"], through["mean"]])
	# A black control would make any ratio meaningless and a 0/0 read as a pass.
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- the floor is not lit at "
				% control["mean"] + "all, so the ratio proves nothing")
		return 0.0
	return float(through["mean"]) / float(control["mean"])


# ===========================================================================
# Helpers copied VERBATIM from pt_transmission_gate.gd (not on the shared
# pt_validation.gd base class -- see that file's :570/:603/:624/:633).
# ===========================================================================

## BG_COLOR does NOT populate the path tracer's radiance octmap -- only
## BG_SKY with an actual Sky resource does (env_sky_radiance() /
## env_sample() read radiance_octmap, which the sky pass only fills for a
## real Sky; SkyRD::draw_sky's BG_COLOR/BG_CLEAR_COLOR branch feeds the RASTER
## fog-sky material, a different consumer entirely). A flat single-colour
## panorama is Sky in every direction, matching pt_energy_gate.gd's
## _constant_panorama() pattern -- confirmed empirically: BG_COLOR alone read
## exactly 0.0 on every real-render probe here until switched to this.
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


## Mean (and per-channel means) over an axis-aligned crop given as fractions
## of the image. Mirrors pt_energy_gate.gd's _measure_crop.
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
	return {"r": r, "g": g, "b": b, "mean": (r + g + b) / 3.0, "n": n}


func _settle() -> void:
	for _i in range(3):
		await get_tree().process_frame


## Longer settle for right after _new_env(): the sky pass renders the
## radiance octmap and the env CDF is built from it, and both need a moment --
## a handful of process_frame ticks is not enough (matches pt_energy_gate.gd's
## 2-second wait after building a fresh sky).
func _settle_sky() -> void:
	await get_tree().create_timer(1.0).timeout
