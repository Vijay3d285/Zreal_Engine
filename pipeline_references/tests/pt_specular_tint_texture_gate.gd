extends "res://tests/pt_validation.gd"

## specularColorTexture gate.
##
##   bin\godot.windows.editor.x86_64.console.exe --path pipeline_references \
##       res://tests/pt_specular_tint_texture_gate_scene.tscn
##
## Run from the engine repo: the fixture lives at ../tests/data/models/, outside
## res://, and is the same file the importer doctest reads.
##
## WHAT THIS PROVES, AND WHY THE DOCTEST CANNOT.
##
## The doctest ("specularColorTexture is imported onto specular_tint_texture")
## proves the importer puts the right image in the right slot. It cannot see past
## the material: the headless test renderer discards material parameters, so
## whether the texture reaches the path tracer -- and whether the shader applies
## it correctly -- is invisible to it. A clean scons build proves nothing about
## the GLSL either; glsl_builders runs no validator.
##
## This gate imports that same fixture through GLTFDocument, renders it with the
## path tracer, and reads the tint back through the debug vis modes, which call
## resolve_specular_tint() -- the same function shading calls. Four checks:
##
##   UNTEXTURED   the factor arrives unchanged when the texture is removed
##                (regression guard on the pre-existing factor path);
##   TEXTURED     tint = factor * sRGB-decoded texel, the glTF composition;
##   F0 RATIO     resolveDielectricF0's F0 scales by exactly the texel, so the
##                F0 debug modes see the texture too;
##   ETA          eta does NOT move. Cycles applies the tint after deriving eta
##                (svm/closure.h:453), so a coloured texture must never change
##                how the surface refracts.
##
## Falsifiability: before rendering, the gate checks that the two plausible
## wrong outcomes -- texture ignored, and texture applied without its sRGB
## decode -- each land more than 10x the tolerance away from the expected value.
## If a fixture change ever collapsed that margin, the gate refuses to run rather
## than pass on a value it could not have told apart.

const MODE_SPECULAR_TINT := 28
const MODE_F0 := 30
const MODE_ETA := 31

const FIXTURE := "../tests/data/models/material_specular_color_texture.gltf"

## As authored in the fixture: material 0's specularColorFactor (linear) and the
## 8-bit sRGB texel of its specularColorTexture.
const FACTOR := Vector3(0.5, 0.25, 1.0)
const TEXEL_SRGB8 := Vector3(64.0, 128.0, 192.0)

## Debug modes write the value straight to radiance, so the factor-only check
## sees float storage error alone. The textured check adds one hardware 8-bit
## sRGB decode, whose error is well under 1e-3 on any conformant GPU.
const TOLERANCE_FACTOR := 1e-4
const TOLERANCE_TEXTURE := 1e-3
const TOLERANCE_RATIO := 2e-3 # relative, on F0 textured/untextured
const TOLERANCE_ETA := 1e-5

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	print("")
	print("=== specularColorTexture gate ===")

	var path := ProjectSettings.globalize_path("res://").path_join(FIXTURE).simplify_path()
	if not FileAccess.file_exists(path):
		printerr("FAIL: fixture not found at %s. Run this gate from the engine repo's pipeline_references." % path)
		get_tree().quit(1)
		return

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_file(path, state)
	if err != OK:
		printerr("FAIL: GLTFDocument.append_from_file returned %d for %s" % [err, path])
		get_tree().quit(1)
		return

	var textured: BaseMaterial3D = state.get_materials()[0]
	if textured == null or textured.specular_tint_texture == null:
		# Every render check below would be vacuous without this.
		printerr("FAIL: the importer did not set specular_tint_texture on material 0.")
		get_tree().quit(1)
		return

	var untextured: BaseMaterial3D = textured.duplicate() as BaseMaterial3D
	untextured.specular_tint_texture = null

	var texel := Vector3(_srgb_to_linear(TEXEL_SRGB8.x / 255.0),
			_srgb_to_linear(TEXEL_SRGB8.y / 255.0),
			_srgb_to_linear(TEXEL_SRGB8.z / 255.0))
	var expected := FACTOR * texel
	var if_ignored := FACTOR
	var if_not_decoded := FACTOR * (TEXEL_SRGB8 / 255.0)

	if not _separated("texture ignored", expected, if_ignored) \
			or not _separated("sRGB decode skipped", expected, if_not_decoded):
		printerr("FAIL: fixture cannot discriminate; refusing to run.")
		get_tree().quit(1)
		return

	var mesh_instance: MeshInstance3D = $MeshInstance3D
	var env: Environment = $WorldEnvironment.environment
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(1)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)

	# A fresh material means a fresh RID, so the RT material cache rebuilds
	# rather than serving the previous material's entry.
	mesh_instance.material_override = untextured
	var tint_u := await _read(env, MODE_SPECULAR_TINT)
	var f0_u := await _read(env, MODE_F0)
	var eta_u := await _read(env, MODE_ETA)

	mesh_instance.material_override = textured
	var tint_t := await _read(env, MODE_SPECULAR_TINT)
	var f0_t := await _read(env, MODE_F0)
	var eta_t := await _read(env, MODE_ETA)

	print("  expected textured tint : %s" % _fmt(expected))
	print("  if texture ignored     : %s" % _fmt(if_ignored))
	print("  if sRGB decode skipped : %s" % _fmt(if_not_decoded))
	print("")

	_check_vec("UNTEXTURED tint == factor", tint_u, FACTOR, TOLERANCE_FACTOR)
	_check_vec("TEXTURED tint == factor * texel", tint_t, expected, TOLERANCE_TEXTURE)
	for i in 3:
		_checks += 1
		var ratio: float = f0_t[i] / max(f0_u[i], 1e-12)
		var rel: float = abs(ratio - texel[i]) / texel[i]
		if rel > TOLERANCE_RATIO:
			_failures += 1
			print("  FAIL  F0 RATIO[%d]: textured/untextured %.6f, expected texel %.6f (rel %.2e)" % [i, ratio, texel[i], rel])
		else:
			print("  ok    F0 RATIO[%d]: %.6f (texel %.6f)" % [i, ratio, texel[i]])
	_check_vec("ETA unchanged by texture", eta_t, eta_u, TOLERANCE_ETA)

	print("")
	if _failures == 0:
		print("PASS: specularColorTexture reaches the path tracer and composes as glTF specifies (%d checks)." % _checks)
	else:
		print("FAIL: %d of %d checks did not match." % [_failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


func _read(p_env: Environment, p_mode: int) -> Vector3:
	p_env.set_pathtracing_debug_mode(p_mode)
	var img: Image = await _render_accum(p_env, get_viewport().get_viewport_rid(), 1)
	# The box face fills the image centre.
	var px: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	return Vector3(px.r, px.g, px.b)


func _check_vec(p_label: String, p_got: Vector3, p_want: Vector3, p_tol: float) -> void:
	for i in 3:
		_checks += 1
		var delta: float = abs(p_got[i] - p_want[i])
		if delta > p_tol:
			_failures += 1
			print("  FAIL  %s[%d]: expected %.6f, got %.6f (delta %.2e)" % [p_label, i, p_want[i], p_got[i], delta])
		else:
			print("  ok    %s[%d]: %.6f" % [p_label, i, p_got[i]])


## True when the wrong hypothesis is more than 10x the texture tolerance away
## from the expected value in at least one channel -- i.e. the check could fail.
func _separated(p_name: String, p_expected: Vector3, p_wrong: Vector3) -> bool:
	var gap := 0.0
	for i in 3:
		gap = max(gap, abs(p_expected[i] - p_wrong[i]))
	var ok := gap > 10.0 * TOLERANCE_TEXTURE
	print("  margin vs '%s': %.4f (needs > %.4f) %s" % [p_name, gap, 10.0 * TOLERANCE_TEXTURE, "ok" if ok else "TOO SMALL"])
	return ok


func _srgb_to_linear(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


func _fmt(v: Vector3) -> String:
	return "(%.6f, %.6f, %.6f)" % [v.x, v.y, v.z]
