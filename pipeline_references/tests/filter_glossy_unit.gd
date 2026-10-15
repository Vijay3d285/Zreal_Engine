extends SceneTree

# Preloaded, not global class names: the live pipeline has no class cache.
const VideoGlb = preload("res://video_glb_creation.gd")
const PtValidation = preload("res://tests/pt_validation.gd")

## Headless checks for where Filter Glossy and blue-noise sampling are turned off
## (specs 2026-10-14-pt-filter-glossy-design.md Results, 2026-10-15-pt-blue-noise-sampling-design.md):
##   - the DLSS-RR video route, whose daylight probe runs the accumulate variant while its
##     frames run the one-shot variant that has neither;
##   - the path-tracer gates, whose baselines were measured without them.
##
## Run it from a copy of pipeline_references WITHOUT .godot/ (the repo's class cache has a
## duplicate CustomShapeGenerator):
##   bin\godot.windows.editor.x86_64.console.exe --headless --path <copy> \
##       -s res://tests/filter_glossy_unit.gd

const FILTER_GLOSSY := "rendering/pathtracer/filter_glossy"
const SAMPLING_PATTERN := "rendering/pathtracer/sampling_pattern"

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float) -> void:
	_checks += 1
	print("  %s: %s (expected %s)" % [p_name, str(p_value), str(p_expected)])
	if not is_equal_approx(p_value, p_expected):
		_failures.append("%s: %s, expected %s" % [p_name, str(p_value), str(p_expected)])


func _setting(p_name: String) -> float:
	return float(ProjectSettings.get_setting(p_name, -1.0))


func _set_both_on() -> void:
	ProjectSettings.set_setting(FILTER_GLOSSY, 1.0)
	ProjectSettings.set_setting(SAMPLING_PATTERN, 1)


func _video_mode(p_mode: String) -> void:
	_set_both_on()
	OS.set_environment("ZR_VIDEO_DENOISER", p_mode)
	var v = VideoGlb.new()
	v._resolve_video_denoiser()
	OS.unset_environment("ZR_VIDEO_DENOISER")


func _initialize() -> void:
	print("[filter_glossy_unit]")
	_video_mode("dlssrr")
	_check("dlssrr video turns Filter Glossy off", _setting(FILTER_GLOSSY), 0.0)
	_check("dlssrr video uses the classic sampling pattern", _setting(SAMPLING_PATTERN), 0.0)
	_video_mode("oidn")
	_check("oidn video leaves Filter Glossy on", _setting(FILTER_GLOSSY), 1.0)
	_check("oidn video keeps blue-noise sampling", _setting(SAMPLING_PATTERN), 1.0)

	# root joins the tree only after _initialize returns, so the gate's ENTER_TREE (and the
	# check) happen on the first idle frame.
	_set_both_on()
	root.add_child(PtValidation.new())
	_finish.call_deferred()


func _finish() -> void:
	_check("a gate entering the tree pins Filter Glossy off", _setting(FILTER_GLOSSY), 0.0)
	_check("a gate entering the tree pins the classic sampling pattern", _setting(SAMPLING_PATTERN), 0.0)
	if _failures.is_empty():
		print("PASS: all %d placement checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL: " + f)
		quit(1)
