extends "res://tests/pt_validation.gd"

## Phase D material-arrival gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_material_data_gate_scene.tscn
##
## WHAT THIS PROVES, AND WHY NOTHING ELSE IN PHASE D PROVES IT.
##
## Task 4 added static_asserts on RT_MaterialData. Those check the C++ side of
## the struct twin ONLY -- nothing in the codebase compares it to the GLSL
## MaterialData. And the headless doctest renderer discards material parameters
## outright (servers/rendering/dummy/storage/material_storage.h:123-124 are both
## no-ops), so no doctest can check that a property reaches the parameter map
## under the right name either.
##
## This gate closes both holes at once: it authors thirteen distinct values in
## GDScript and reads them back out of the shader. A wrong parameter name, a
## wrong struct offset, or a C++/GLSL layout disagreement all show up here as a
## specific field reading the wrong number.
##
## It then renders a SECOND material with clearcoat and anisotropy disabled and
## asserts the shader reads 0 for all three of those fields. That case is not
## redundant: clearcoat's class default is 1.0 and clearcoat_roughness's is 0.5,
## so a material with the feature off is exactly where a wrong value is most
## likely and least visible. See the comment at the feature-off block below.
##
## SCOPE: this proves arrival for the StandardMaterial3D path ONLY.
## debug_visualize() has two call sites in scene_raytracing_raygen.glsl, and
## they are mutually exclusive at compile time: the one at :495-508 (which
## fetches `materials[h.geometry_idx]` because no MaterialData is otherwise in
## scope there) only builds under RT_CUSTOM_HIT_GROUP, and the one at :560-572
## (which passes the already-in-scope `mat`) only builds in the #else branch.
## This gate's scene uses `StandardMaterial3D.new()` as material_override, which
## can only ever take the second path. The custom-hit-group fetch is therefore
## exercised by successful shader compilation and nothing else at runtime -- no
## test in this repo drives it with real values. The residual risk is low
## because that fetch expression is textually identical to the one this gate
## does verify (`materials[h.geometry_idx]` vs. the tested `materials[...]`
## indexing used to build `mat` on the other path), but it is unverified, and a
## custom-hit-group gate scene is out of scope for Phase D.

const MODE_TRANSMISSION_IOR_THICKNESS := 23
const MODE_DENSITY_SPECULAR_SHEENROUGH := 24
const MODE_CLEARCOAT_ANISOTROPY := 25
const MODE_ANISOTROPY_ROTATION := 26
const MODE_ATTENUATION_COLOR := 27
const MODE_SPECULAR_TINT := 28
const MODE_SHEEN_COLOR := 29

## Values are distinct EXCEPT for one pair: V_CLEARCOAT and the blue channel of
## V_SPECULAR_TINT are both 0.55. That collision means this fixture set cannot
## catch every possible layout error: a struct-layout bug that aliased
## `clearcoat` (RT_MaterialData offset 160) onto `specular_tint.b` (offset 136)
## would read 0.55 in both checks and both would pass.
##
## Accepted as residual risk, not fixed by re-cutting the fixture, because those
## two offsets are 24 bytes apart with several other fields between them -- no
## plausible off-by-one (a dropped/duplicated field, a wrong vec3 alignment)
## produces exactly that mapping. A layout bug big enough to alias those two
## specific offsets would have to shift the whole tail of the struct, and any
## such shift disturbs most of the other eleven fields too: 18 of these 19
## checks would still fail. Every other value here is pairwise distinct and
## differs from its own default, so any OTHER field swap fails a specific
## assertion rather than cancelling out.
const V_TRANSMISSION := 0.35
const V_IOR := 1.72
const V_THICKNESS := 2.4
const V_ATTENUATION_DISTANCE := 5.0
const V_ATTENUATION_DENSITY := 0.2   # 1.0 / V_ATTENUATION_DISTANCE
const V_SPECULAR_FACTOR := 0.62
const V_SHEEN_ROUGHNESS := 0.45
const V_ANISOTROPY_ROTATION := 1.1
const V_CLEARCOAT := 0.55
const V_CLEARCOAT_ROUGHNESS := 0.28
const V_ANISOTROPY := 0.83
const V_ATTENUATION_COLOR := Color(0.9, 0.4, 0.15)   # linear
const V_SPECULAR_TINT := Color(0.8, 0.7, 0.55)       # linear
const V_SHEEN_COLOR := Color(0.25, 0.5, 0.75)        # linear

## Debug modes write the material value straight to radiance with no shading, so
## the only error is float storage. This is generous enough for that and far
## tighter than the smallest gap between any two fixture values (0.03).
const TOLERANCE := 1e-4

var _failures: int = 0
var _checks: int = 0

func _ready() -> void:
	var mesh_instance: MeshInstance3D = $MeshInstance3D
	var mat := StandardMaterial3D.new()
	mat.transmission = V_TRANSMISSION
	mat.ior = V_IOR
	mat.thickness = V_THICKNESS
	mat.attenuation_distance = V_ATTENUATION_DISTANCE
	mat.attenuation_color = V_ATTENUATION_COLOR.linear_to_srgb()
	mat.specular_factor = V_SPECULAR_FACTOR
	mat.specular_tint = V_SPECULAR_TINT.linear_to_srgb()
	mat.sheen_color = V_SHEEN_COLOR.linear_to_srgb()
	mat.sheen_roughness = V_SHEEN_ROUGHNESS
	mat.anisotropy_rotation = V_ANISOTROPY_ROTATION
	mat.clearcoat_enabled = true
	mat.clearcoat = V_CLEARCOAT
	mat.clearcoat_roughness = V_CLEARCOAT_ROUGHNESS
	mat.anisotropy_enabled = true
	mat.anisotropy = V_ANISOTROPY
	mesh_instance.material_override = mat

	var env: Environment = $WorldEnvironment.environment
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)

	await _check_mode(env, MODE_TRANSMISSION_IOR_THICKNESS,
			"transmission/ior/thickness",
			Vector3(V_TRANSMISSION, V_IOR, V_THICKNESS))
	await _check_mode(env, MODE_DENSITY_SPECULAR_SHEENROUGH,
			"attenuation_density/specular_factor/sheen_roughness",
			Vector3(V_ATTENUATION_DENSITY, V_SPECULAR_FACTOR, V_SHEEN_ROUGHNESS))
	await _check_mode(env, MODE_CLEARCOAT_ANISOTROPY,
			"clearcoat/clearcoat_roughness/anisotropy",
			Vector3(V_CLEARCOAT, V_CLEARCOAT_ROUGHNESS, V_ANISOTROPY))
	await _check_mode(env, MODE_ANISOTROPY_ROTATION,
			"anisotropy_rotation",
			Vector3(V_ANISOTROPY_ROTATION, 0.0, 0.0))
	await _check_mode(env, MODE_ATTENUATION_COLOR,
			"attenuation_color",
			Vector3(V_ATTENUATION_COLOR.r, V_ATTENUATION_COLOR.g, V_ATTENUATION_COLOR.b))
	await _check_mode(env, MODE_SPECULAR_TINT,
			"specular_tint",
			Vector3(V_SPECULAR_TINT.r, V_SPECULAR_TINT.g, V_SPECULAR_TINT.b))
	await _check_mode(env, MODE_SHEEN_COLOR,
			"sheen_color",
			Vector3(V_SHEEN_COLOR.r, V_SHEEN_COLOR.g, V_SHEEN_COLOR.b))

	# FEATURE-OFF CASE.
	#
	# Everything above renders a material with clearcoat_enabled and
	# anisotropy_enabled BOTH true, which is why the feature-off path went
	# unrendered for the whole of Phase D -- and it is the path almost every
	# real material takes.
	#
	# It matters because clearcoat's class default is 1.0 and
	# clearcoat_roughness's is 0.5, pushed into the parameter map by
	# BaseMaterial3D's constructor for every material ever created, regardless
	# of the feature flag. The path tracer reads that map by name and has no
	# route back to the Feature array, so without the feature gating in
	# BaseMaterial3D::set_clearcoat()/set_feature() every surface in every scene
	# would arrive at the shader carrying a full-strength clear coat.
	#
	# The values below are set but NOT enabled. All three must read 0.
	var mat_off := StandardMaterial3D.new()
	mat_off.clearcoat = V_CLEARCOAT
	mat_off.clearcoat_roughness = V_CLEARCOAT_ROUGHNESS
	mat_off.anisotropy = V_ANISOTROPY
	# A fresh material means a fresh RID, so the RT material cache misses and
	# rebuilds rather than serving the previous material's entry.
	mesh_instance.material_override = mat_off

	await _check_mode(env, MODE_CLEARCOAT_ANISOTROPY,
			"feature-off clearcoat/clearcoat_roughness/anisotropy",
			Vector3(0.0, 0.0, 0.0), true)

	print("")
	if _failures == 0:
		print("PASS: all %d material fields arrived in the shader intact." % _checks)
	else:
		print("FAIL: %d of %d material field checks did not match." % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)

## p_check_all forces all three channels to be compared. The default skips
## channels 1 and 2 when they are expected to be 0, because in single-value modes
## those carry nothing -- but a mode where every field is legitimately expected
## to be 0 (the feature-off case) needs them checked, not skipped.
func _check_mode(p_env: Environment, p_mode: int, p_label: String, p_expected: Vector3,
		p_check_all: bool = false) -> void:
	p_env.set_pathtracing_debug_mode(p_mode)
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 1)
	# Sample the image centre, which the quad fills.
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var got := Vector3(px.r, px.g, px.b)
	for i in 3:
		if not p_check_all and p_expected[i] == 0.0 and i > 0:
			continue # Unused channel in single-value modes.
		_checks += 1
		var delta: float = abs(got[i] - p_expected[i])
		if delta > TOLERANCE:
			_failures += 1
			print("  FAIL  %s[%d]: expected %.6f, got %.6f (delta %.6f)"
					% [p_label, i, p_expected[i], got[i], delta])
		else:
			print("  ok    %s[%d]: %.6f" % [p_label, i, got[i]])
