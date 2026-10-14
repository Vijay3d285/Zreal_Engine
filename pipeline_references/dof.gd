extends RefCounted

## Thin-lens depth of field for day stills (spec 2026-10-13-pt-depth-of-field-design.md).
## Pure functions; render.gd calls them right after the daylight probe, which has just
## rendered the exact view with no lens, so the primary-hit depth is already there.
## Preloaded (const Dof = preload("res://dof.gd")), never a class_name: production
## runs with no .godot/ class cache.

## The owner's pick from the f/11 - f/8 - f/5.6 test renders. 0.0 = off.
const DOF_F_STOP := 8.0
## Full-frame 36 x 24 mm: Godot's fov is vertical, so the 24 mm height sets the lens.
const SENSOR_HEIGHT_MM := 24.0
const FOCUS_MIN_M := 0.5
const FOCUS_MAX_M := 25.0
## Under this share of central pixels hitting geometry (a shot out of a window), no DoF.
const MIN_HIT_FRACTION := 0.10
## Centre-weighted: the middle 50% x 50% of the frame.
const CENTRE_FRACTION := 0.5
const GRID_STRIDE := 8


static func focal_length_mm(p_fov_deg: float) -> float:
	return 0.5 * SENSOR_HEIGHT_MM / tan(deg_to_rad(p_fov_deg) * 0.5)


## Blender's aperture: radius = focal length / (2 x f-number).
static func aperture_radius_m(p_fov_deg: float, p_f_stop: float) -> float:
	if p_f_stop <= 0.0:
		return 0.0
	return focal_length_mm(p_fov_deg) / (2.0 * p_f_stop) / 1000.0


## Distance along the view axis (-z in camera space) of an NDC point, through the inverse
## of the camera's depth-corrected projection -- the plane the lens focuses on.
static func axial_distance(p_inv_proj: Projection, p_ndc: Vector3) -> float:
	var v := p_inv_proj * Vector4(p_ndc.x, p_ndc.y, p_ndc.z, 1.0)
	return -v.z / v.w


## Median axial distance of the central region's hits, clamped. p_depth: rt_depth
## (FORMAT_RF, reverse-Z NDC depth, 0.0 = miss).
static func measure_focus(p_depth: Image, p_inv_proj: Projection, p_stride: int = GRID_STRIDE) -> Dictionary:
	var off := {"ok": false, "distance": 0.0, "hits": 0, "samples": 0, "hit_fraction": 0.0, "centre_distance": 0.0}
	if p_depth == null or p_depth.is_empty():
		return off
	var w := p_depth.get_width()
	var h := p_depth.get_height()
	var x0 := int(w * (1.0 - CENTRE_FRACTION) * 0.5)
	var y0 := int(h * (1.0 - CENTRE_FRACTION) * 0.5)
	var x1 := int(w * (1.0 + CENTRE_FRACTION) * 0.5)
	var y1 := int(h * (1.0 + CENTRE_FRACTION) * 0.5)
	var dists := PackedFloat32Array()
	var samples := 0
	for y in range(y0, y1, maxi(p_stride, 1)):
		for x in range(x0, x1, maxi(p_stride, 1)):
			samples += 1
			var d := p_depth.get_pixel(x, y).r
			if d > 0.0:
				dists.append(axial_distance(p_inv_proj, _ndc(x, y, w, h, d)))
	var cd := p_depth.get_pixel(w / 2, h / 2).r
	off["centre_distance"] = axial_distance(p_inv_proj, _ndc(w / 2, h / 2, w, h, cd)) if cd > 0.0 else 0.0
	off["samples"] = samples
	off["hits"] = dists.size()
	off["hit_fraction"] = float(dists.size()) / float(maxi(samples, 1))
	if off["hit_fraction"] < MIN_HIT_FRACTION:
		return off
	dists.sort()
	off["ok"] = true
	off["distance"] = clampf(dists[dists.size() / 2], FOCUS_MIN_M, FOCUS_MAX_M)
	return off


## Pixel centre -> NDC, the raygen's convention (camera_ray: d = (pixel + 0.5) / size * 2 - 1).
static func _ndc(p_x: int, p_y: int, p_w: int, p_h: int, p_depth: float) -> Vector3:
	return Vector3((p_x + 0.5) / p_w * 2.0 - 1.0, (p_y + 0.5) / p_h * 2.0 - 1.0, p_depth)
