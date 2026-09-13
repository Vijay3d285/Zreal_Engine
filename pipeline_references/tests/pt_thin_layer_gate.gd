extends "res://tests/pt_validation.gd"

## Thin-layer gate (roadmap Gap #26).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_thin_layer_gate_scene.tscn
##
## WHAT THIS PROVES. After a ray passes THROUGH a surface (Transparent BSDF
## pass-through, or a transmissive-lobe sample) the next ray must be able to hit
## anything at any distance except the triangle it just left. Before the fix
## the restart carried two margins -- t_min = 1 mm and a Wachter-Binder origin
## offset of 256 ulps (0.24 mm at |z| = 14) -- and a surface inside either
## margin was never hit. The measured casualty was the aquarium water whose
## front face sits 0.14 mm behind the glass (spec 2026-09-13-self-skip-...).
##
## FIXTURE. pt_transparent_alpha_gate.gd's layout (camera looking straight
## down -Z, 6x6 pane dead-on, 20x20 emissive backdrop), shifted by Z_OFF = +16
## so the origin-offset margin at the pane (|z| ~= 14 -> 0.24 mm) is ALSO larger
## than the 0.1 mm gap; at the sibling gate's z = -2 only the 1 mm t_min would
## be exercised. The pane is a SINGLE-SIDED QuadMesh (one face, back-culled),
## so there is exactly one through-event per ray: a double-sided box pane's
## back face is a second blend surface whose diffuse share reflects whatever
## is behind it, which moved the controls to 0.44 / 0.37 on the first run and
## made "theory 0.5" light-dependent. A teal emissive PLATE the size of the
## pane sits GAP behind that one face. Every probe is a ratio: through-pane /
## plate-alone (pane hidden), so emission, exposure and tonemap cancel.
##
##   T1  blend pane alpha 0.5, plate 0.1 mm behind   -> 0.5 (half the plate)
##   T2  blend pane alpha 0.5, plate 5 mm behind     -> 0.5, equal to T1 +-0.5%
##   T3  blend pane alpha 0.5, no plate (backdrop)   -> 0.5, equal to the
##       pre-fix reading +-0.5% (bounds the shared-edge double-pass property)
##   T4a converted-glass pane, plate 5 mm behind     -> pre-fix reading +-0.5%
##   T4b converted-glass pane, plate 0.1 mm behind   -> equal to T4a +-0.5%
##
## T1 and T4b are RED on the engine before the fix by construction: the plate is
## inside both margins and the ray restarts past it, so they read the backdrop
## (different colour, different ratio). T2, T3, T4a hold the fix to zero
## collateral. T3_REF_PREFIX / T4A_REF_PREFIX are the readings of THIS gate on
## the pre-fix engine (build 9c2fe35ffe + spec commit), recorded before the
## fix so the post-fix assertion can newly fail.

const FRAMES := 128
const Z_OFF := 16.0

const CAM_POS := Vector3(0, 0, 5 + Z_OFF)
const CAM_TARGET := Vector3(0, 0, -5 + Z_OFF)
const CAM_FOV := 25.0
const PANE_SIZE := Vector2(6, 6)
const PANE_Z := -2.0 + Z_OFF
const PLATE_SIZE := Vector3(6, 6, 0.05)
const BACKDROP_SIZE := Vector3(20, 20, 0.1)
const BACKDROP_Z := -5.0 + Z_OFF
const BACKDROP_EMISSION := Color(0.6, 0.5, 0.4)
const PLATE_EMISSION := Color(0.06, 0.50, 0.71)
const EMISSION_ENERGY := 3.0

const GAP_THIN := 0.0001 # 0.1 mm -- inside both pre-fix margins
const GAP_WIDE := 0.005 # 5 mm -- outside both

const BLEND_ALPHA := 0.5
const HALF_MIN := 0.47
const HALF_MAX := 0.53
const REL_TOL := 0.005

# Pre-fix readings of T3 and T4a on this gate. Filled in by Task 1 Step 3 from
# the red run; -1.0 means "not yet recorded" and fails the check on purpose.
const T3_REF_PREFIX := 0.500002 # pre-fix, engine e18c37c544 (shaders of 9c2fe35ffe), 2026-09-13
const T4A_REF_PREFIX := 0.991734 # pre-fix, same run

var _failures: Array[String] = []
var _checks: int = 0


func _ready() -> void:
	print("\n=== T1: blend pane, plate 0.1 mm behind ===")
	var t1 := await _measure_layer_ratio("blend", GAP_THIN)
	print("  T1 ratio = %.6f (theory 0.5)" % t1)
	_check_band("T1", t1, HALF_MIN, HALF_MAX)

	print("\n=== T2: blend pane, plate 5 mm behind ===")
	var t2 := await _measure_layer_ratio("blend", GAP_WIDE)
	print("  T2 ratio = %.6f (theory 0.5)" % t2)
	_check_band("T2", t2, HALF_MIN, HALF_MAX)
	_check_rel("T2 vs T1", t2, t1)

	print("\n=== T3: blend pane, no plate ===")
	var t3 := await _measure_layer_ratio("blend", -1.0)
	print("  T3 ratio = %.6f (theory 0.5, pre-fix ref %.6f)" % [t3, T3_REF_PREFIX])
	_check_band("T3", t3, HALF_MIN, HALF_MAX)
	_check_rel("T3 vs pre-fix", t3, T3_REF_PREFIX)

	print("\n=== T4a: converted-glass pane, plate 5 mm behind ===")
	var t4a := await _measure_layer_ratio("glass", GAP_WIDE)
	print("  T4a ratio = %.6f (pre-fix ref %.6f)" % [t4a, T4A_REF_PREFIX])
	_check_rel("T4a vs pre-fix", t4a, T4A_REF_PREFIX)

	print("\n=== T4b: converted-glass pane, plate 0.1 mm behind ===")
	var t4b := await _measure_layer_ratio("glass", GAP_THIN)
	print("  T4b ratio = %.6f" % t4b)
	_check_rel("T4b vs T4a", t4b, t4a)

	print("")
	if _failures.is_empty():
		print("PASS: all %d thin-layer checks passed." % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		get_tree().quit(1)


func _check_band(p_name: String, p_v: float, p_lo: float, p_hi: float) -> void:
	_checks += 1
	if p_v < p_lo or p_v > p_hi:
		_failures.append("%s: ratio %.6f outside [%.2f, %.2f]" % [p_name, p_v, p_lo, p_hi])


func _check_rel(p_name: String, p_v: float, p_ref: float) -> void:
	_checks += 1
	if p_ref <= 0.0:
		_failures.append("%s: reference %.6f is not a valid reading" % [p_name, p_ref])
		return
	var rel := absf(p_v - p_ref) / p_ref
	if rel > REL_TOL:
		_failures.append("%s: %.6f vs %.6f differ by %.2f%% (max %.1f%%)"
				% [p_name, p_v, p_ref, rel * 100.0, REL_TOL * 100.0])


## Builds backdrop + optional plate + pane + camera, renders with the pane
## hidden (control) and visible (through), returns through/control over the
## centre crop. `p_kind` is "blend" (alphaMode BLEND, alpha 0.5, what the
## glTF importer produces) or "glass" (what the pipeline's
## _apply_glb_transmissive_glass produces: opaque, transmission 1, thin-walled,
## IOR 1.2). `p_gap` < 0 means no plate; the pane then sits over the backdrop.
func _measure_layer_ratio(p_kind: String, p_gap: float) -> float:
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
	backdrop_mat.emission_energy_multiplier = EMISSION_ENERGY
	backdrop.material_override = backdrop_mat
	add_child(backdrop)

	if p_gap >= 0.0:
		# The pane is a single quad at exactly PANE_Z; the plate's FRONT face
		# must be exactly p_gap behind it.
		var plate := MeshInstance3D.new()
		var plate_mesh := BoxMesh.new()
		plate_mesh.size = PLATE_SIZE
		plate.mesh = plate_mesh
		plate.position = Vector3(0, 0, PANE_Z - p_gap - PLATE_SIZE.z * 0.5)
		var plate_mat := StandardMaterial3D.new()
		plate_mat.emission_enabled = true
		plate_mat.emission = PLATE_EMISSION
		plate_mat.emission_energy_multiplier = EMISSION_ENERGY
		plate.material_override = plate_mat
		add_child(plate)

	var pane := MeshInstance3D.new()
	# QuadMesh faces +Z (toward the camera) and is back-culled: one surface.
	var pane_mesh := QuadMesh.new()
	pane_mesh.size = PANE_SIZE
	pane.mesh = pane_mesh
	pane.position = Vector3(0, 0, PANE_Z)
	var pane_mat := StandardMaterial3D.new()
	if p_kind == "blend":
		pane_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		pane_mat.albedo_color = Color(1, 1, 1, BLEND_ALPHA)
	else:
		# Mirrors image_glb_creation.gd::_apply_glb_transmissive_glass.
		pane_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		pane_mat.albedo_color = Color(1, 1, 1, 1)
		pane_mat.metallic = 0.0
		pane_mat.metallic_specular = 0.5
		pane_mat.roughness = 0.0
		pane_mat.transmission = 1.0
		pane_mat.ior = 1.2
		pane_mat.thickness = 0.0
	pane.material_override = pane_mat
	add_child(pane)

	var cam := Camera3D.new()
	# look_at_from_position() BEFORE add_child() -- see pt_transparent_alpha_gate.gd.
	cam.look_at_from_position(CAM_POS, CAM_TARGET, Vector3.UP)
	cam.fov = CAM_FOV
	add_child(cam)
	cam.make_current()

	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(4)
	await _settle_sky()

	pane.visible = false
	var control_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var control := _measure_crop(control_img, 0.35, 0.65)

	pane.visible = true
	await _settle()
	var through_img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var through := _measure_crop(through_img, 0.35, 0.65)

	print("  control mean %.6f (r %.4f g %.4f b %.4f), through mean %.6f (r %.4f g %.4f b %.4f)"
			% [control["mean"], control["r"], control["g"], control["b"],
				through["mean"], through["r"], through["g"], through["b"]])
	if control["mean"] < 1e-6:
		_checks += 1
		_failures.append("control render is black (%.8f) -- nothing behind the pane is visible"
				% control["mean"])
		return 0.0
	return float(through["mean"]) / float(control["mean"])


# ===========================================================================
# Helpers copied VERBATIM from pt_transparent_alpha_gate.gd (which copied them
# from pt_transparent_shadow_gate.gd; not on the shared base class).
# ===========================================================================

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


func _settle_sky() -> void:
	await get_tree().create_timer(1.0).timeout
