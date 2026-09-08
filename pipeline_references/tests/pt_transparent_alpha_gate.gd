extends "res://tests/pt_validation.gd"

## Transparent BSDF closure GPU gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_transparent_alpha_gate_scene.tscn
##
## WHAT THIS PROVES. alphaMode BLEND surfaces used to be dropped from the TLAS
## and drawn by a second, rasterized renderer. This measures that a blended pane
## is now TRACED: the radiance behind it must read (1 - alpha) of the control,
## and two stacked panes must read (1 - alpha)^2. The squared case is the one
## that proves layers compose -- a single-pane probe cannot distinguish "one
## layer applied" from "one layer applied twice".
##
## THIS GATE IS EXPECTED TO FAIL on probes 1 and 2 until the alpha-blend TLAS
## closure (the task after this one) lands. Alpha-blended surfaces are still
## dropped from the acceleration structure and composited by a separate raster
## pass today, so the traced image does not contain the panes at all -- whatever
## the raster overlay contributes will not land on 0.5 or 0.25 under path-traced
## accumulation. Probe 3 is a same-day control: an alpha=1.0 BLEND pane is fully
## opaque, and Godot's raster overlay already composites a fully-opaque blend
## surface indistinguishably from a TRANSPARENCY_DISABLED one today, so probe 3
## is not expected to move when Task 3 lands -- it exists to catch Task 3
## accidentally changing alpha=1.0 behaviour, not to prove the closure works.
##
## GEOMETRY, summary (full arithmetic in task-2-report.md). Everything sits on
## the camera's own view axis: camera at (0,0,5) looking straight down -Z at
## (0,0,-5) via look_at_from_position (called BEFORE add_child -- see the two
## black-render regressions this project has already hit from getting that
## order backwards). Because the camera has no rotation off that axis, every
## ray's world-space direction has a strictly negative Z component (forward is
## exactly -Z, so dir.z = -1/len(...) < 0 for any finite screen offset), so
## world-space Z decreases monotonically with distance along EVERY ray in the
## frame, not just the crop. That turns "does the pane sit between camera and
## backdrop" into a plain Z-ordering check: camera z=5 > pane1 z=-2 > pane2
## z=-3 > backdrop z=-5, so any ray that reaches the backdrop has already
## crossed both panes. The panes are 6x6 boxes (half-extent 3) facing the
## camera dead-on (their wide face normal is +-Z, parallel to the view axis --
## the most face-on orientation possible, i.e. not edge-on), and the backdrop
## is a 20x20 box; both comfortably cover the whole measured 0.35-0.65 crop at
## their respective depths (worst-case crop half-extent computed in the report
## is under 1.0 world unit against a 3-unit pane half-extent and a 10-unit
## backdrop half-extent).

const FRAMES := 128
const P_ALPHA := 0.5

# One pane at alpha 0.5: half the background survives.
const P1_MIN := 0.47
const P1_MAX := 0.53
# Two stacked panes: 0.5^2 = 0.25.
const P2_MIN := 0.22
const P2_MAX := 0.28
# alpha = 1.0 must be indistinguishable from an opaque pane.
const P3_MAX_DELTA := 0.005

# Shared scene constants (see the geometry note above and task-2-report.md).
const CAM_POS := Vector3(0, 0, 5)
const CAM_TARGET := Vector3(0, 0, -5)
const CAM_FOV := 25.0
const PANE_SIZE := Vector3(6, 6, 0.05)
const PANE1_Z := -2.0
const PANE2_Z := -3.0
const BACKDROP_SIZE := Vector3(20, 20, 0.1)
const BACKDROP_Z := -5.0
const BACKDROP_EMISSION := Color(0.6, 0.5, 0.4)
const BACKDROP_EMISSION_ENERGY := 3.0

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	print("\n=== PROBE 1: one blended pane at alpha 0.5 ===")
	await _probe1_single_pane()
	print("\n=== PROBE 2: two stacked panes compose ===")
	await _probe2_two_panes()
	print("\n=== PROBE 3: alpha 1.0 is opaque ===")
	await _probe3_opaque_control()
	print("")
	if _failures.is_empty():
		print("PASS: all %d transparent-alpha checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


## One blended pane between the camera and an emissive backdrop. Expected
## ratio (1 - P_ALPHA) = 0.5 once alpha-blended surfaces are traced; today the
## pane is invisible to the path tracer entirely, so this must fail.
func _probe1_single_pane() -> void:
	var ratio := await _measure_ratio(P_ALPHA, 1)
	print("  ratio through one pane (alpha=%.2f) = %.6f (band %.2f - %.2f, theory 0.5)"
			% [P_ALPHA, ratio, P1_MIN, P1_MAX])
	_checks += 1
	if ratio < P1_MIN or ratio > P1_MAX:
		_failures.append("probe1 single pane: ratio %.6f outside [%.2f, %.2f]"
				% [ratio, P1_MIN, P1_MAX])


## Two stacked panes, each alpha 0.5. Expected ratio (1 - 0.5)^2 = 0.25 once
## alpha blending composes correctly through the TLAS; a gate that only ran
## probe 1 could not tell "one layer applied" from "one layer applied twice",
## which is why this probe exists.
func _probe2_two_panes() -> void:
	var ratio := await _measure_ratio(P_ALPHA, 2)
	print("  ratio through two panes (alpha=%.2f each) = %.6f (band %.2f - %.2f, theory 0.25)"
			% [P_ALPHA, ratio, P2_MIN, P2_MAX])
	_checks += 1
	if ratio < P2_MIN or ratio > P2_MAX:
		_failures.append("probe2 two panes: ratio %.6f outside [%.2f, %.2f]"
				% [ratio, P2_MIN, P2_MAX])


## A fully-opaque BLEND pane (alpha = 1.0) must look the same as a genuinely
## opaque (TRANSPARENCY_DISABLED) pane. Renders the identical emissive pane
## twice, varying only `transparency`, and asserts the crop means are within
## P3_MAX_DELTA of each other. This is a same-day control (see the header
## note) -- it is not expected to change when Task 3 lands, so it guards
## against Task 3 regressing full-opacity blend surfaces rather than proving
## the closure itself.
func _probe3_opaque_control() -> void:
	var blend_mean := await _render_pane_mean(BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS)
	var opaque_mean := await _render_pane_mean(BaseMaterial3D.TRANSPARENCY_DISABLED)
	print("  blend(alpha=1.0) mean %.6f, opaque mean %.6f"
			% [blend_mean, opaque_mean])
	_checks += 1
	# Guards the same degenerate case as _measure_ratio's control-is-black
	# check: if the pane itself is unlit, any delta near zero is vacuous, not
	# evidence the two paths render identically.
	if opaque_mean < 1e-6:
		_failures.append("probe3 opaque control: opaque-pane render is black (%.8f) -- "
				% opaque_mean + "the pane is not lit at all, so the comparison proves nothing")
		return
	var delta := absf(blend_mean - opaque_mean)
	if delta > P3_MAX_DELTA:
		_failures.append(("probe3 opaque control: delta %.6f exceeds max %.4f -- alpha=1.0 "
				+ "blend pane (mean %.6f) is distinguishable from a truly opaque pane "
				+ "(mean %.6f)")
				% [delta, P3_MAX_DELTA, blend_mean, opaque_mean])


## Renders a single emissive pane with the given `transparency` mode and
## returns the measured crop mean. Used by probe 3 to compare an alpha=1.0
## BLEND pane against a TRANSPARENCY_DISABLED one; no backdrop is needed
## because the pane itself is opaque and emissive, so it is the only thing the
## camera can see through the measured crop.
##
## GEOMETRY: identical camera/pane placement to _measure_ratio's single-pane
## case (pane at PANE1_Z) -- see the file header note and task-2-report.md for
## the full crop-coverage and non-edge-on arithmetic, which is unaffected by
## `transparency` or by the absence of a backdrop.
func _render_pane_mean(p_transparency: int) -> float:
	for c in get_children():
		c.queue_free()

	var pane := MeshInstance3D.new()
	var pane_mesh := BoxMesh.new()
	pane_mesh.size = PANE_SIZE
	pane.mesh = pane_mesh
	pane.position = Vector3(0, 0, PANE1_Z)
	var pane_mat := StandardMaterial3D.new()
	pane_mat.transparency = p_transparency
	pane_mat.albedo_color = Color(1, 1, 1, 1.0)
	pane_mat.emission_enabled = true
	pane_mat.emission = BACKDROP_EMISSION
	pane_mat.emission_energy_multiplier = BACKDROP_EMISSION_ENERGY
	pane.material_override = pane_mat
	add_child(pane)

	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child(): look_at() requires the node
	# already be inside the scene tree, which it is not until add_child()
	# runs. Getting this order backwards has produced two black renders in
	# this project already (pt_transparent_shadow_gate.gd, pt_transmission_gate.gd).
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	# Black background: the pane's own emission is the only light source in
	# frame, so nothing outside the pane can contaminate the mean.
	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(2)
	await _settle_sky()

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var stats := _measure_crop(img, 0.35, 0.65)
	return float(stats["mean"])


## Renders an emissive backdrop with `p_pane_count` alpha-blended panes (each
## at albedo alpha p_alpha) interposed between it and the camera -- once with
## the panes hidden (control) and once visible -- and returns the ratio.
## Toggling `visible` rather than building two scenes is the same technique
## probe 3 of pt_transmission_gate.gd and _measure_ratio of
## pt_transparent_shadow_gate.gd use: every other term (backdrop emission,
## camera, exposure, tonemap) is bit-identical between the two arms, so it
## cancels in the ratio and what remains is the panes' own transmittance.
##
## GEOMETRY (full arithmetic in task-2-report.md). The camera looks straight
## down -Z with no rotation off that axis (CAM_POS -> CAM_TARGET is purely a
## -Z displacement), so every ray's world-space direction has dir.z < 0
## regardless of screen position -- world Z decreases monotonically with
## distance along every ray in the frame. Object Z-order along every ray is
## therefore: camera (z=5) -> pane 1 (z=-2) -> pane 2 (z=-3) -> backdrop
## (z=-5), so any ray reaching the backdrop has already crossed both panes,
## and the panes' 6x6 (half-extent 3) faces are perpendicular to the view axis
## (dead-on, not edge-on) and comfortably cover the measured 0.35-0.65 crop's
## footprint at their depths (see report: crop half-extent under 1.0 unit at
## both pane depths, against a 3-unit pane half-extent). The 20x20 backdrop
## (half-extent 10) covers the crop footprint at its depth with even larger
## margin.
func _measure_ratio(p_alpha: float, p_pane_count: int) -> float:
	for c in get_children():
		c.queue_free()

	var backdrop := MeshInstance3D.new()
	var backdrop_mesh := BoxMesh.new()
	backdrop_mesh.size = BACKDROP_SIZE
	backdrop.mesh = backdrop_mesh
	backdrop.position = Vector3(0, 0, BACKDROP_Z)
	var backdrop_mat := StandardMaterial3D.new()
	backdrop_mat.emission_enabled = true
	backdrop_mat.emission = BACKDROP_EMISSION
	backdrop_mat.emission_energy_multiplier = BACKDROP_EMISSION_ENERGY
	backdrop.material_override = backdrop_mat
	add_child(backdrop)

	var pane_depths: Array[float] = [PANE1_Z]
	if p_pane_count == 2:
		pane_depths.append(PANE2_Z)

	var panes: Array[MeshInstance3D] = []
	for pz in pane_depths:
		var pane := MeshInstance3D.new()
		var pane_mesh := BoxMesh.new()
		pane_mesh.size = PANE_SIZE
		pane.mesh = pane_mesh
		pane.position = Vector3(0, 0, pz)
		var pane_mat := StandardMaterial3D.new()
		# What the glTF importer produces for alphaMode: BLEND, and what makes
		# ShaderData::rt_uses_alpha_blending() (Task 1) return true.
		pane_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		pane_mat.albedo_color = Color(1, 1, 1, p_alpha)
		pane.material_override = pane_mat
		add_child(pane)
		panes.append(pane)

	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child(): see _render_pane_mean's note.
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(2)
	await _settle_sky()

	for pane in panes:
		pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	for pane in panes:
		pane.visible = true
	await _settle()
	var through_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(through_img, 0.35, 0.65)

	print("  control mean %.6f, through-pane mean %.6f"
			% [control["mean"], through["mean"]])
	# A black control would make any ratio meaningless and a 0/0 read as a pass.
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- the backdrop is not visible at "
				% control["mean"] + "all, so the ratio proves nothing")
		return 0.0
	return float(through["mean"]) / float(control["mean"])


# ===========================================================================
# Helpers copied VERBATIM from pt_transparent_shadow_gate.gd (not on the
# shared pt_validation.gd base class -- see that file's :452/:485/:506/:515).
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
