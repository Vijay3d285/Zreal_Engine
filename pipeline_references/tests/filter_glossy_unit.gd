extends SceneTree

# Preloaded, not global class names: the live pipeline has no class cache.
const VideoGlb = preload("res://video_glb_creation.gd")
const PtValidation = preload("res://tests/pt_validation.gd")

## Headless checks for where Filter Glossy is turned off
## (spec docs/superpowers/specs/2026-10-14-pt-filter-glossy-design.md, Results):
##   - the DLSS-RR video route, whose daylight probe runs the accumulate variant while its
##     frames run the one-shot variant that has no Filter Glossy;
##   - the path-tracer gates, whose baselines were measured without it.
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/filter_glossy_unit.gd

const SETTING := "rendering/pathtracer/filter_glossy"

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float) -> void:
	_checks += 1
	print("  %s: %s (expected %s)" % [p_name, str(p_value), str(p_expected)])
	if not is_equal_approx(p_value, p_expected):
		_failures.append("%s: %s, expected %s" % [p_name, str(p_value), str(p_expected)])


func _filter_glossy() -> float:
	return float(ProjectSettings.get_setting(SETTING, -1.0))


func _video_mode(p_mode: String) -> float:
	ProjectSettings.set_setting(SETTING, 1.0)
	OS.set_environment("ZR_VIDEO_DENOISER", p_mode)
	var v = VideoGlb.new()
	v._resolve_video_denoiser()
	OS.unset_environment("ZR_VIDEO_DENOISER")
	return _filter_glossy()


func _initialize() -> void:
	print("[filter_glossy_unit]")
	_check("dlssrr video turns Filter Glossy off", _video_mode("dlssrr"), 0.0)
	_check("oidn video leaves Filter Glossy on", _video_mode("oidn"), 1.0)

	# root joins the tree only after _initialize returns, so the gate's ENTER_TREE (and the
	# check) happen on the first idle frame.
	ProjectSettings.set_setting(SETTING, 1.0)
	root.add_child(PtValidation.new())
	_finish.call_deferred()


func _finish() -> void:
	_check("a gate entering the tree pins Filter Glossy off", _filter_glossy(), 0.0)
	if _failures.is_empty():
		print("PASS: all %d Filter Glossy placement checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL: " + f)
		quit(1)
