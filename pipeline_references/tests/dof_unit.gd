extends SceneTree

# Preloaded, not a global class name: the live pipeline has no class cache.
const Dof = preload("res://dof.gd")

## Headless unit checks for dof.gd (spec 2026-10-13-pt-depth-of-field-design.md).
##
##   bin\godot.windows.editor.x86_64.console.exe --headless --path pipeline_references \
##       -s res://tests/dof_unit.gd

var _failures: Array[String] = []
var _checks := 0


func _check(p_name: String, p_value: float, p_expected: float, p_tol: float) -> void:
	_checks += 1
	var err := absf(p_value - p_expected) / maxf(absf(p_expected), 1e-9)
	print("  %s: %.6f vs %.6f (tol %.2f%%)" % [p_name, p_value, p_expected, 100.0 * p_tol])
	if err > p_tol:
		_failures.append("%s: %.6f vs %.6f" % [p_name, p_value, p_expected])


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	print("  %s: %s %s" % [p_name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
		_failures.append("%s %s" % [p_name, p_detail])


## The engine's convention: Godot's depth-corrected (flip-y, reverse-Z) projection,
## the same matrix the raygen writes rt_depth with.
func _proj() -> Projection:
	return Projection.create_depth_correction(true) * Projection.create_perspective(45.0, 16.0 / 9.0, 0.05, 500.0)


## NDC depth the engine would store for a point at axial distance p_d straight ahead.
func _ndc_depth(p_proj: Projection, p_d: float) -> float:
	var c := p_proj * Vector4(0.0, 0.0, -p_d, 1.0)
	return c.z / c.w


## p_w x p_h depth image: the central 50% x 50% filled per p_centre(x, y) -> axial metres
## (<= 0 = miss), everything outside the centre at 10 m (must be ignored).
func _depth_image(p_w: int, p_h: int, p_centre: Callable) -> Image:
	var proj := _proj()
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RF)
	for y in range(p_h):
		for x in range(p_w):
			var inside := x >= p_w / 4 and x < p_w * 3 / 4 and y >= p_h / 4 and y < p_h * 3 / 4
			var d: float = p_centre.call(x, y) if inside else 10.0
			img.set_pixel(x, y, Color(_ndc_depth(proj, d) if d > 0.0 else 0.0, 0, 0))
	return img


func _initialize() -> void:
	var inv := _proj().inverse()

	# D1: the depth round-trips to the axial distance.
	for d in [0.5, 3.0, 6.4, 25.0]:
		_check("D1 axial(%.1f m)" % d, Dof.axial_distance(inv, Vector3(0.0, 0.0, _ndc_depth(_proj(), d))), d, 1e-3)

	# D2: uniform 3 m centre -> focus 3 m; the 10 m border is ignored.
	var r2 := Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 3.0), inv, 1)
	_check_true("D2 ok", r2["ok"])
	_check("D2 focus", r2["distance"], 3.0, 0.01)
	_check("D2 centre pixel", r2["centre_distance"], 3.0, 0.01)

	# D3: median, not mean: 70% of the centre at 3 m, 30% at 10 m -> 3 m.
	var r3 := Dof.measure_focus(_depth_image(64, 36, func(x, _y): return 3.0 if (x % 10) < 7 else 10.0), inv, 1)
	_check("D3 median ignores the far 30%", r3["distance"], 3.0, 0.01)

	# D4: misses are dropped, not read as distance 0.
	var r4 := Dof.measure_focus(_depth_image(64, 36, func(x, _y): return 4.0 if x % 2 == 0 else 0.0), inv, 1)
	_check_true("D4 ok with 50% hits", r4["ok"])
	_check("D4 focus from hits only", r4["distance"], 4.0, 0.01)

	# D5: fewer than 10% hits -> off.
	var r5 := Dof.measure_focus(_depth_image(64, 36, func(x, y): return 4.0 if (x + y * 64) % 20 == 0 else 0.0), inv, 1)
	_check_true("D5 off under 10% hits", not r5["ok"], "hit_fraction %.3f" % r5["hit_fraction"])
	_check("D5 distance 0 when off", r5["distance"], 0.0, 1e-9)

	# D6: clamp to [0.5, 25] m.
	_check("D6 clamp near", Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 0.2), inv, 1)["distance"], 0.5, 1e-6)
	_check("D6 clamp far", Dof.measure_focus(_depth_image(64, 36, func(_x, _y): return 60.0), inv, 1)["distance"], 25.0, 1e-6)

	# D7: the lens from the field of view (24 mm-high full-frame sensor).
	_check("D7 focal length at 45 deg", Dof.focal_length_mm(45.0), 28.9706, 1e-4)
	_check("D7 radius at f/8", Dof.aperture_radius_m(45.0, 8.0), 0.00181066, 1e-4)
	_check("D7 f-stop 0 is off", Dof.aperture_radius_m(45.0, 0.0), 0.0, 1e-9)

	# D8: an empty image never crashes and is off.
	var r8 := Dof.measure_focus(Image.new(), inv)
	_check_true("D8 empty image -> off", not r8["ok"] and r8["distance"] == 0.0)

	print("")
	if _failures.is_empty():
		print("PASS: all %d dof unit checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		quit(1)
