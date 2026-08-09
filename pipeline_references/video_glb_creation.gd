extends Node3D

# video_glb_creation.gd
# Scene builder for VIDEO rendering.
# Mirrors image_glb_creation.gd logic but handles the VIDEO JSON format:
#   - floor_plan_data may be flat or layered (new 2.0.0 export)
#   - lines/vertices/holes/areas/items can arrive as ARRAYS or DICTIONARIES
#   - Camera is driven per-frame by video_render.gd via threejs_camera_data
#   - All floor-plan coordinates use the resolved scene unit scale (legacy cm, 2.0.0 mm)

const ENABLE_DUPLICATION = true
const LOW_TEXTURE_QUALITY = false

var _tracked_assets = []
var _window_sunlight_data = [] # Collected during hole building, used to place window sunlights
var _door_hole_data = [] # Collected during hole building, used for subtle door fill lights
var _exterior_assets = [] # Tracks trees/plants/etc for shadow optimization
var day_render = true
var _glb_cache := {}
var _texture_cache := {}
var lighting_profile = "day"
const ENABLE_PROCEDURAL_WINDOW_GRID_CASTER = false
# Global kill-switch for reflection probe material hotspot blurring.
# true  -> apply wood/floor roughness + specular constraints to prevent
#          white corner reflections from SSR + Fresnel at grazing angles.
# false -> keep raw material values (disable fix)
const USE_REFLECTION_PROBE_HOTSPOT_FIX = true
# Multiplier applied to all floor/ceiling UV repeat counts.
# Values > 1.0 make tiles appear smaller (denser tiling). 2.0 = tiles are 50% smaller.
# Must match FLOOR_CEIL_TEXTURE_DENSITY_BOOST in image_glb_creation.gd.
const FLOOR_CEIL_TEXTURE_DENSITY_BOOST: float = 2.0
# Global kill-switch for the UnrealPostFX compositor effect (tonemapping, CDL,
# vignette, chromatic aberration, film grain).
const USE_POST_FX = true
var _lighting_locked = false
var _lighting_setup_done = false
var _frozen_lighting_profile = "day"
var _frozen_camera_pose = null
var _scene_built = false # TRUE after first full build — prevents light/asset accumulation
var _dir_light = null
var _directional_light_authoring_locked = false
var _lighting_color_mood: String = "day"
var _lighting_illumination_scale: float = 1.0
# Count of ceiling_mount fixtures — used by sqrt normalisation to prevent
# N fixtures contributing N× the intended luminance additively.
var _ceiling_fixture_count: int = 1
var _scene_unit_scale: float = 0.01
var _scene_rotation_is_radians: bool = false
var _scene_plan_rotation_radians: float = 0.0
var _scene_plan_pivot: Vector2 = Vector2.ZERO
var _floor_plan_root_data: Dictionary = {}
var structure_builder

func _accumulate_plan_bounds(raw_vertex, bounds: Array) -> bool:
	if typeof(raw_vertex) != TYPE_DICTIONARY:
		return false
	if not raw_vertex.has("x") or not raw_vertex.has("y"):
		return false
	var vx = float(raw_vertex.get("x", 0.0))
	var vy = float(raw_vertex.get("y", 0.0))
	bounds[0] = min(bounds[0], vx)
	bounds[1] = min(bounds[1], vy)
	bounds[2] = max(bounds[2], vx)
	bounds[3] = max(bounds[3], vy)
	return true

func _resolve_scene_unit_scale(data: Dictionary, geom_data = {}) -> float:
	var version := ""
	if typeof(geom_data) == TYPE_DICTIONARY and geom_data.has("version"):
		version = str(geom_data.get("version", "")).strip_edges()
	elif typeof(data) == TYPE_DICTIONARY and data.has("version"):
		version = str(data.get("version", "")).strip_edges()
	if version == "2.0.0":
		return 0.001
	return 0.01

func _resolve_scene_rotation_is_radians(data: Dictionary, geom_data = {}) -> bool:
	var version := ""
	if typeof(geom_data) == TYPE_DICTIONARY and geom_data.has("version"):
		version = str(geom_data.get("version", "")).strip_edges()
	elif typeof(data) == TYPE_DICTIONARY and data.has("version"):
		version = str(data.get("version", "")).strip_edges()
	return version == "2.0.0"

func _resolve_scene_plan_rotation_radians(data: Dictionary, geom_data = {}) -> float:
	var version := ""
	if typeof(geom_data) == TYPE_DICTIONARY and geom_data.has("version"):
		version = str(geom_data.get("version", "")).strip_edges()
	elif typeof(data) == TYPE_DICTIONARY and data.has("version"):
		version = str(data.get("version", "")).strip_edges()
	if version == "2.0.0":
		return 0.0
	var angle_deg := 0.0
	if typeof(geom_data) == TYPE_DICTIONARY and geom_data.has("directionangle"):
		angle_deg = float(geom_data.get("directionangle", 0.0))
	elif typeof(data) == TYPE_DICTIONARY and data.has("directionangle"):
		angle_deg = float(data.get("directionangle", 0.0))
	return -deg_to_rad(angle_deg)

func _rotation_to_radians(raw_rotation: float) -> float:
	if _scene_rotation_is_radians:
		return raw_rotation
	return deg_to_rad(raw_rotation)

func _world_yaw_from_source_rotation(raw_rotation: float) -> float:
	# Match the image renderer: legacy payloads use degrees, 2.0.0 uses radians.
	return -_rotation_to_radians(raw_rotation)

func _item_front_axis_correction() -> float:
	# Video rendering keeps the authored front axis as-is.
	return 0.0

func _resolve_item_altitude_value(item: Dictionary) -> float:
	# Prefer the explicit properties.altitude payload when both are present.
	# Some exports keep a stale top-level altitude alongside the edited value.
	if item.has("properties") and typeof(item["properties"]) == TYPE_DICTIONARY:
		var props = item["properties"]
		if props.has("altitude"):
			return get_dimension_value(props["altitude"], 0.0)
	if item.has("altitude"):
		return get_dimension_value(item["altitude"], 0.0)
	return 0.0

func _resolve_scene_plan_pivot(data: Dictionary, geom_data = {}) -> Vector2:
	var source = geom_data if typeof(geom_data) == TYPE_DICTIONARY and not geom_data.is_empty() else data
	if typeof(source) != TYPE_DICTIONARY or source.is_empty():
		return Vector2.ZERO

	var bounds = [INF, INF, -INF, -INF]
	var found := false

	if source.has("layers") and typeof(source["layers"]) == TYPE_DICTIONARY:
		var layers_dict = source["layers"]
		var selected_layer = str(source.get("selectedLayer", "")).strip_edges()
		var layer_ids: Array = []
		if selected_layer != "" and layers_dict.has(selected_layer):
			layer_ids.append(selected_layer)
		else:
			for layer_id in layers_dict:
				layer_ids.append(layer_id)

		for layer_id in layer_ids:
			var layer = layers_dict.get(layer_id, {})
			if typeof(layer) != TYPE_DICTIONARY:
				continue
			var vertices = {}
			if layer.has("vertices") and typeof(layer["vertices"]) == TYPE_DICTIONARY:
				vertices = layer["vertices"]
			elif source.has("vertices") and typeof(source["vertices"]) == TYPE_DICTIONARY:
				vertices = source["vertices"]
			if vertices.is_empty() or not layer.has("areas") or typeof(layer["areas"]) != TYPE_DICTIONARY:
				continue
			for area_id in layer["areas"]:
				var area = layer["areas"][area_id]
				if typeof(area) != TYPE_DICTIONARY or not area.has("vertices"):
					continue
				for vid in area["vertices"]:
					var vs = str(vid)
					if vertices.has(vs):
						found = _accumulate_plan_bounds(vertices[vs], bounds) or found
			if found:
				break

	if not found and source.has("vertices") and typeof(source["vertices"]) == TYPE_DICTIONARY:
		for vertex_id in source["vertices"]:
			found = _accumulate_plan_bounds(source["vertices"][vertex_id], bounds) or found

	if not found:
		return Vector2.ZERO

	return Vector2((bounds[0] + bounds[2]) * 0.5, (bounds[1] + bounds[3]) * 0.5)

func _plan_point_2d(x: float, y: float) -> Vector2:
	var point = Vector2(x, y) - _scene_plan_pivot
	if abs(_scene_plan_rotation_radians) > 0.000001:
		point = point.rotated(_scene_plan_rotation_radians)
	point += _scene_plan_pivot
	return point

func _transform_camera_plan_point(point: Vector3) -> Vector3:
	var transformed = _plan_point_2d(point.x, point.z)
	return Vector3(
		transformed.x * _scene_unit_scale,
		point.y * _scene_unit_scale,
		transformed.y * _scene_unit_scale
	)

func _transform_plan_point_meters(point: Vector3) -> Vector3:
	if abs(_scene_plan_rotation_radians) < 0.000001:
		return point
	var scale = max(_scene_unit_scale, 0.000001)
	var transformed = _plan_point_2d(point.x / scale, point.z / scale)
	return Vector3(transformed.x * scale, point.y, transformed.y * scale)

func _camera_cm_to_m(point: Vector3) -> Vector3:
	return Vector3(point.x * 0.01, point.y * 0.01, point.z * 0.01)

func _resolve_directional_light_transform(data: Dictionary) -> Dictionary:
	var result = {
		"has_position": false,
		"position": Vector3.ZERO,
		"has_target": false,
		"target": Vector3.ZERO
	}
	if typeof(data) != TYPE_DICTIONARY:
		return result

	var sources: Array = []
	if data.has("directional_light") and typeof(data["directional_light"]) == TYPE_DICTIONARY:
		sources.append(data["directional_light"])
	if data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
		sources.append(data["_lightingSettings"])

	for source in sources:
		if not result["has_position"]:
			if source.has("position") and typeof(source["position"]) == TYPE_DICTIONARY:
				result["position"] = parse_vec3(source["position"])
				result["has_position"] = true
			elif source.has("directionalPosition") and typeof(source["directionalPosition"]) == TYPE_DICTIONARY:
				result["position"] = parse_vec3(source["directionalPosition"])
				result["has_position"] = true

		if not result["has_target"]:
			if source.has("target") and typeof(source["target"]) == TYPE_DICTIONARY:
				result["target"] = parse_vec3(source["target"])
				result["has_target"] = true
			elif source.has("directionalTarget") and typeof(source["directionalTarget"]) == TYPE_DICTIONARY:
				result["target"] = parse_vec3(source["directionalTarget"])
				result["has_target"] = true

	return result

func _resolve_color_mood(data: Dictionary) -> String:
	var candidate := ""
	if typeof(data) != TYPE_DICTIONARY:
		return "day"

	if data.has("colorMood"):
		candidate = str(data["colorMood"])
	elif data.has("color_mood"):
		candidate = str(data["color_mood"])
	elif data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
		var lighting_settings = data["_lightingSettings"]
		if lighting_settings.has("colorMood"):
			candidate = str(lighting_settings["colorMood"])

	candidate = candidate.to_lower().strip_edges()
	if candidate == "":
		return "day"
	if candidate in ["warm", "soft", "neutral", "nuetral", "day", "cool"]:
		return "neutral" if candidate == "nuetral" else candidate
	if "warm" in candidate:
		return "warm"
	if "soft" in candidate:
		return "soft"
	if "neutral" in candidate:
		return "neutral"
	if "nuetral" in candidate:
		return "neutral"
	if "cool" in candidate:
		return "cool"
	if "day" in candidate:
		return "day"
	return "day"

func _resolve_illumination_scale(data: Dictionary) -> float:
	var level := 5
	if typeof(data) != TYPE_DICTIONARY:
		return 1.0

	if data.has("illuminationLevel"):
		level = int(data["illuminationLevel"])
	elif data.has("illumination_level"):
		level = int(data["illumination_level"])
	elif data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
		var lighting_settings = data["_lightingSettings"]
		if lighting_settings.has("illuminationLevel"):
			level = int(lighting_settings["illuminationLevel"])
		elif lighting_settings.has("illumination_level"):
			level = int(lighting_settings["illumination_level"])

	level = int(clamp(level, 1, 5))
	return float(level) * 0.2

func _get_color_mood_light_color(role: String) -> Color:
	var mood := _lighting_color_mood
	match mood:
		"warm":
			match role:
				"ambient":
					# Desaturated neutral warm-gray to keep shadows clean and realistic
					return Color(0.85, 0.82, 0.80)
				"fixture":
					# Realistic 2700K warm white (soft gold/yellow-white)
					return Color(1.0, 0.84, 0.66)
				"fill":
					# Soft cream bounce fill
					return Color(1.0, 0.94, 0.88)
				_:
					return Color(1.0, 0.92, 0.85)
		"soft":
			match role:
				"ambient":
					# Desaturated soft neutral-cream
					return Color(0.92, 0.88, 0.85)
				"fixture":
					# Soft warm-white (3000K mood)
					return Color(1.0, 0.88, 0.72)
				"fill":
					return Color(1.0, 0.96, 0.90)
				_:
					return Color(1.0, 0.95, 0.88)
		"neutral":
			match role:
				"ambient":
					# Desaturated clean white-gray
					return Color(0.95, 0.94, 0.93)
				"fixture":
					# Clean neutral white (4000K)
					return Color(1.0, 0.94, 0.88)
				"fill":
					return Color(0.98, 0.96, 0.95)
				_:
					return Color(0.96, 0.95, 0.94)
		"cool":
			match role:
				"ambient":
					# Desaturated soft cool gray
					return Color(0.90, 0.92, 0.95)
				"fixture":
					# Crisp cool white (5500K) - no longer heavy blue
					return Color(0.92, 0.96, 1.0)
				"fill":
					return Color(0.93, 0.95, 0.98)
				_:
					return Color(0.94, 0.96, 0.98)
		"day":
			match role:
				"ambient":
					# Neutral bright gray/white
					return Color(0.95, 0.95, 0.96)
				"fixture":
					# Daylight crisp white (6500K)
					return Color(0.95, 0.98, 1.0)
				"fill":
					return Color(0.98, 0.99, 1.0)
				_:
					return Color(0.97, 0.98, 0.99)
		_:
			match role:
				"ambient":
					return Color(0.84, 0.88, 0.94)
				"fixture":
					return Color(1.0, 0.98, 0.95)
				"fill":
					return Color(0.98, 0.99, 1.0)
				_:
					return Color(1.0, 0.99, 0.95)

# ─────────────────────────────────────────────────────────────────
# Entry-point (called by video_render.gd)
# ─────────────────────────────────────────────────────────────────
# ==============================================================================
# SCENE INITIALIZATION (MAIN ENTRY POINT)
# ==============================================================================
# WHY IT EXISTS: This is the main conductor function. It triggers the entire 
# rendering pipeline in order: setting global scales, generating lighting, 
# building 3D walls/floors, building custom stairs/shapes, and loading furniture.
# ==============================================================================
func build_scene(data):
	structure_builder = preload("res://structure.gd").new(self)
	# ── First frame: resolve and lock lighting profile + camera pose ──────────
	if not _lighting_locked:
		lighting_profile = _resolve_lighting_profile(data)
		day_render = lighting_profile != "night"
		_frozen_lighting_profile = lighting_profile
		_frozen_camera_pose = _extract_camera_pose(data)
		_lighting_locked = true
	else:
		lighting_profile = _frozen_lighting_profile
		day_render = lighting_profile != "night"

	# ── Subsequent frames: scene geometry + lighting already built, skip ──────
	# This is the key fix: geometry, lights, and assets are added as persistent
	# child nodes. Re-running build_architecture / load_assets every frame
	# stacks duplicate lights causing whitish overexposure on all frames after 1.
	if _scene_built:
		print("[VideoGLB] Frame skip — scene already built, reusing geometry and lighting.")
		return

	# Unwrap floor_plan_data (may be a JSON string or already a dict)
	var geom_data = data
	if data.has("floor_plan_data"):
		var fp = data["floor_plan_data"]
		if typeof(fp) == TYPE_STRING:
			var json = JSON.new()
			var err = json.parse(fp)
			if err == OK:
				geom_data = json.data
				print("[VideoGLB] Parsed floor_plan_data from string.")
			else:
				print("[VideoGLB] ERROR parsing floor_plan_data: ", json.get_error_message())
		else:
			geom_data = fp

	_floor_plan_root_data = geom_data if typeof(geom_data) == TYPE_DICTIONARY else {}
	_scene_unit_scale = _resolve_scene_unit_scale(data, geom_data)
	_scene_rotation_is_radians = _resolve_scene_rotation_is_radians(data, geom_data)
	_scene_plan_rotation_radians = _resolve_scene_plan_rotation_radians(data, geom_data)
	_scene_plan_pivot = _resolve_scene_plan_pivot(data, geom_data)
	print("[VideoGLB] Using scene unit scale: ", _scene_unit_scale, " m/source-unit")
	print("[VideoGLB] Using plan rotation: ", rad_to_deg(_scene_plan_rotation_radians), " deg | pivot=", _scene_plan_pivot)

	# ── Unwrap layers structure ───────────────────────────────────────────────
	# scene_optimizer_video.py writes geometry inside geom_data["layers"][layer_id].
	# Flatten the selected (or first) layer up to the top level so all downstream
	# functions (build_architecture, load_assets, lighting bounds) can find
	# lines / vertices / holes / areas / items without knowing about layers.
	if false and geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		var layers = geom_data["layers"]
		var layer_id = geom_data.get("selectedLayer", "")
		var layer = null
		if layer_id != "" and layers.has(layer_id):
			layer = layers[layer_id]
		else:
			# Fall back to the first layer
			var first_key = layers.keys()[0] if layers.size() > 0 else ""
			if first_key != "":
				layer_id = first_key
				layer = layers[first_key]
		if layer != null and typeof(layer) == TYPE_DICTIONARY:
			print("[VideoGLB] Unwrapping layer '", layer_id, "' from layers dict.")
			# Merge layer contents into a flat working copy so existing code works
			var flat = {}
			for k in geom_data:
				if k != "layers":
					flat[k] = geom_data[k]
			for k in layer:
				flat[k] = layer[k]
			geom_data = flat
		else:
			print("[VideoGLB] WARNING: layers dict found but no valid layer could be selected.")

	var cam_pose = _frozen_camera_pose if _frozen_camera_pose != null else _extract_camera_pose(data)
	setup_lighting(data, geom_data, cam_pose)
	var show_all_floors = data.get("showAllFloors", null)
	if geom_data.has("showAllFloors"):
		show_all_floors = geom_data["showAllFloors"]

	_window_sunlight_data.clear()
	_door_hole_data.clear()
	build_architecture(geom_data, cam_pose.get("position", Vector3.ZERO), show_all_floors)
	build_structures(geom_data)
	load_assets(geom_data)
	
	# Port from image renderer: localized per-area probes give accurate parallax-correct
	# reflections on marble/tile/polished surfaces. Must run AFTER load_assets so all
	# geometry is in the scene tree before probes are placed.
	_generate_localized_reflection_probes(geom_data)
	
	_build_custom_lights(geom_data)
	
	if day_render:
		_create_window_portal_lights()
		if _dir_light != null and not _directional_light_authoring_locked:
			_orient_directional_light_from_windows(_dir_light, cam_pose)
		
		# VoxelGI for high-quality day bounce lighting
		_setup_voxel_gi(geom_data)
	else:
		if _dir_light != null:
			_dir_light.visible = false
			print("[VideoGLB] Directional light disabled for night render.")
	
	_apply_anisotropic_filtering_to_all(self)
	if USE_REFLECTION_PROBE_HOTSPOT_FIX:
		_apply_reflection_hotspot_fix_to_all(self)

	# Mark scene as fully built — all subsequent frames skip directly above ↑
	_scene_built = true

func _apply_anisotropic_filtering_to_all(node: Node) -> void:
	var meshes = _get_all_meshes(node)
	for m in meshes:
		if not m.mesh: continue
		for i in range(m.mesh.get_surface_count()):
			var mat = m.get_active_material(i)
			if mat == null:
				mat = m.mesh.surface_get_material(i)
			if mat and mat is BaseMaterial3D:
				mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

# ─────────────────────────────────────────────────────────────────
# Reflection Probe Hotspot Fix — mirrors image_glb_creation.gd
# Surface-type-aware: wood floors get high roughness (soft blur),
# marble/tile keeps low roughness (preserves sharp reflections),
# generic floors get a mid-roughness cap only.
# Only runs when USE_REFLECTION_PROBE_HOTSPOT_FIX = true.
# ─────────────────────────────────────────────────────────────────
func _apply_reflection_hotspot_fix_to_all(node: Node) -> void:
	var meshes = _get_all_meshes(node)
	for m in meshes:
		if not m.mesh: continue
		for i in range(m.mesh.get_surface_count()):
			var mat = m.get_active_material(i)
			if mat == null:
				mat = m.mesh.surface_get_material(i)
			if mat == null or not (mat is StandardMaterial3D):
				continue
			var sm := mat as StandardMaterial3D

			# Use multiple name sources — override name is empty for JSON-built geometry.
			# Priority: override_name → mesh surface name → material resource path/name
			# → albedo TEXTURE path (most reliable: texture filenames contain "marble", "wood" etc.)
			var surf_name = m.get_surface_override_material_name(i)
			if surf_name == "":
				surf_name = m.mesh.surface_get_name(i)
			if surf_name == "" and mat.resource_path != "":
				surf_name = mat.resource_path.get_file()
			elif surf_name == "" and mat.resource_name != "":
				surf_name = mat.resource_name
			# ── Most reliable: the albedo texture URL (from JSON mapUrl) ──────────
	
			if surf_name == "" and sm.albedo_texture != null:
				var tex_path = sm.albedo_texture.resource_path
				if tex_path == "" and sm.albedo_texture.resource_name != "":
					tex_path = sm.albedo_texture.resource_name
				if tex_path != "":
					surf_name = tex_path.get_file()
			surf_name = surf_name.to_lower()

			# ── Color-based fallback for unmarked bright polished surfaces ───────
			# If surface name is still empty and albedo is near-white and low roughness
			# it is almost certainly a marble/polished tile floor — force correct settings.
			var is_bright_neutral = false
			if surf_name == "":
				var c = sm.albedo_color
				# Near-white OR light grey → likely marble/tile
				is_bright_neutral = (c.r > 0.70 and c.g > 0.70 and c.b > 0.70 and sm.roughness > 0.35)

			# Detect material categories by surface name keywords
			var is_marble = "marble" in surf_name or "stone" in surf_name or "polished" in surf_name or "granit" in surf_name
			var is_tile = "tile" in surf_name or "ceramic" in surf_name or "porcelain" in surf_name or "travert" in surf_name
			var is_wood = "wood" in surf_name or "parquet" in surf_name or "plank" in surf_name or "oak" in surf_name or "walnut" in surf_name or "timber" in surf_name
			var is_floor = "floor" in surf_name or "ground" in surf_name

			# Treat bright neutral unmarked surfaces as marble/tile (polished floor default)
			if is_bright_neutral:
				is_marble = true


			if is_marble or is_tile:
				# ── Marble / polished tile: KEEP sharp reflections ──
				# Only clamp to prevent 100% mirror, allow natural gloss.
				sm.roughness = clamp(sm.roughness, 0.08, 0.20)
				sm.metallic_specular = min(sm.metallic_specular, 0.65)
				sm.metallic = 0.0
				# Subtle clearcoat for depth without blown highlights
				sm.clearcoat_enabled = true
				sm.clearcoat = 0.15
				sm.clearcoat_roughness = 0.12

			elif is_wood:
				# ── Wood: soft blurred reflection, no hotspot ──
				sm.metallic = 0.0
				sm.roughness = 0.25
				sm.metallic_specular = 0.2
				sm.clearcoat_enabled = false
				sm.clearcoat = 0.0
				sm.anisotropy_enabled = false

			elif is_floor:
				# ── Generic floor (unknown material): moderate roughness cap ──
				# Prevents mirror-like look without eliminating reflections entirely.
				sm.roughness = max(sm.roughness, 0.18)
				sm.metallic_specular = min(sm.metallic_specular, 0.5)
				sm.metallic = 0.0
				sm.clearcoat_enabled = false

			else:
				# ── All other surfaces: global sanity clamp only ──
				# Do NOT override — preserves wall, furniture, glass materials.
				sm.roughness = clamp(sm.roughness, 0.05, 1.0)
				sm.metallic_specular = min(sm.metallic_specular, 0.5)

# ─────────────────────────────────────────────────────────────────
# Localized per-area ReflectionProbe — ported from image_glb_creation.gd
# Creates one small probe per room area (box_projection, UPDATE_ONCE) for
# accurate parallax-correct reflections on marble, tile, and polished floors.
# Also places low-intensity probes at door/window holes to capture openings
# without letting HDR exterior light bleed into the whole room reflection.
# ─────────────────────────────────────────────────────────────────
func _generate_localized_reflection_probes(geom_data: Dictionary) -> void:
	var work = geom_data
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		var selected = str(geom_data.get("selectedLayer", ""))
		var layers = geom_data["layers"]
		if selected != "" and layers.has(selected):
			work = layers[selected]
		elif layers.size() > 0:
			work = layers[layers.keys()[0]]

	if typeof(work) != TYPE_DICTIONARY: return
	if not work.has("areas") or not work.has("vertices"): return

	var areas = work["areas"]
	var vertices = work["vertices"]
	var lines = work.get("lines", {})

	var layer_alt = 0.0
	if work.has("altitude"):
		var alt = work["altitude"]
		if typeof(alt) == TYPE_DICTIONARY and alt.has("length"):
			layer_alt = float(alt["length"]) * _scene_unit_scale
		else:
			layer_alt = float(alt) * _scene_unit_scale

	# ── 1. Room area probes ───────────────────────────────────────────
	for aid in areas:
		var area = areas[aid]
		if typeof(area) != TYPE_DICTIONARY or not area.has("vertices"): continue

		var mn_x = 1e20; var mx_x = -1e20
		var mn_z = 1e20; var mx_z = -1e20
		var got = false

		for vid in area["vertices"]:
			var key = str(vid)
			if not vertices.has(key): continue
			var v = vertices[key]
			var p = _plan_point_2d(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
			var x = p.x * _scene_unit_scale
			var z = p.y * _scene_unit_scale
			mn_x = min(mn_x, x); mx_x = max(mx_x, x)
			mn_z = min(mn_z, z); mx_z = max(mx_z, z)
			got = true

		if not got: continue

		var ceil_h = 2.8
		if area.has("ceiling_properties"):
			var cp = area["ceiling_properties"]
			if typeof(cp) == TYPE_DICTIONARY and cp.has("height"):
				var h = float(cp["height"]) * _scene_unit_scale
				if h > 0.1: ceil_h = h

		var center = Vector3((mn_x + mx_x) * 0.5, layer_alt + ceil_h * 0.5, (mn_z + mx_z) * 0.5)
		var extent_x = max(2.0, mx_x - mn_x)
		var extent_z = max(2.0, mx_z - mn_z)

		var probe = ReflectionProbe.new()
		probe.name = "AreaProbe_" + str(aid)
		probe.position = center
		probe.size = Vector3(extent_x * 0.85, ceil_h * 0.85, extent_z * 0.85)
		probe.box_projection = true
		probe.interior = true
		probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
		probe.enable_shadows = false
		probe.intensity = 0.4 # higher than image (0.2) so marble is visible in video
		probe.mesh_lod_threshold = 1.5
		probe.cull_mask = 1
		add_child(probe)
		print("[VideoGLB] AreaProbe ", aid, " at ", center, " size ", probe.size)

	# ── 2. Door / window probes ──────────────────────────────────────
	var all_holes = work.get("holes", {})
	if typeof(lines) != TYPE_DICTIONARY: return
	for lid in lines:
		var line = lines[lid]
		if typeof(line) != TYPE_DICTIONARY or not line.has("holes"): continue
		var verts_arr = line.get("vertices", [])
		if verts_arr.size() < 2: continue
		var v1_id = str(verts_arr[0])
		var v2_id = str(verts_arr[1])
		if not vertices.has(v1_id) or not vertices.has(v2_id): continue
		var p1r = vertices[v1_id]
		var p2r = vertices[v2_id]
		var pt1 = _plan_point_2d(float(p1r.get("x", 0.0)), float(p1r.get("y", 0.0))) * _scene_unit_scale
		var pt2 = _plan_point_2d(float(p2r.get("x", 0.0)), float(p2r.get("y", 0.0))) * _scene_unit_scale
		var lp1 = Vector3(pt1.x, layer_alt, pt1.y)
		var lp2 = Vector3(pt2.x, layer_alt, pt2.y)

		for hole_id in line["holes"]:
			var hid = str(hole_id)
			if not all_holes.has(hid): continue
			var hole = all_holes[hid]
			var h_type = str(hole.get("type", ""))
			if h_type != "window" and h_type != "door": continue

			var h_w = get_dimension_value(hole.get("width", 0)) * _scene_unit_scale
			var h_h = get_dimension_value(hole.get("height", 0)) * _scene_unit_scale
			var h_a = get_dimension_value(hole.get("altitude", 0)) * _scene_unit_scale

			var raw_off = float(hole.get("offset", 0.0))
			if hole.has("properties") and hole["properties"].has("offset"):
				raw_off = float(hole["properties"]["offset"])
			var wall_len = lp1.distance_to(lp2)
			var off_r = clamp((raw_off * _scene_unit_scale) / wall_len, 0.0, 1.0) if raw_off > 1.0 and wall_len > 0.0001 else raw_off

			var hole_pos = lp1.lerp(lp2, off_r)
			hole_pos.y = layer_alt + h_a + h_h / 2.0

			var hp = ReflectionProbe.new()
			hp.name = "HoleProbe_" + hid
			hp.position = hole_pos
			hp.size = Vector3(max(2.0, h_w * 1.5), max(2.0, h_h * 1.5), 2.0)
			hp.box_projection = true
			hp.interior = true
			hp.update_mode = ReflectionProbe.UPDATE_ALWAYS
			hp.enable_shadows = false
			hp.intensity = 0.1 # low — prevents HDR outdoor bleed across room
			hp.mesh_lod_threshold = 1.5
			hp.cull_mask = 1
			add_child(hp)
# ==============================================================================
# PHOTOREALISTIC LIGHTING SETUP
# ==============================================================================
# WHY IT EXISTS: To dynamically build realistic lighting based on the requested 
# "mood" (e.g. warm, cool, night, day). It sets up the sun, ambient bounce 
# lighting (SDFGI), screen-space indirect lighting (SSIL), and colour grading 
# to ensure the final render looks like a photograph instead of a flat game.
# ==============================================================================
func setup_lighting(data, geom_data = {}, cam_pose_override = null):
	if _lighting_setup_done:
		print("[VideoGLB] Lighting already initialized; reusing first-frame setup.")
		return
	var lighting = _get_lighting_profile_settings()
	_lighting_color_mood = _resolve_color_mood(data)
	if lighting_profile == "day":
		# Day videos should stay neutral; mood tinting is reserved for night.
		_lighting_color_mood = "day"
	_lighting_illumination_scale = _resolve_illumination_scale(data)
	# Pre-count ceiling fixtures for sqrt energy normalisation.
	if typeof(geom_data) == TYPE_DICTIONARY:
		_ceiling_fixture_count = max(1, _count_ceiling_fixture_lights(geom_data))
		print("[VideoGLB] Lighting mood=", _lighting_color_mood, " illumination_scale=", _lighting_illumination_scale, " ceiling_fixtures=", _ceiling_fixture_count, " sqrt_factor=", snappedf(sqrt(float(_ceiling_fixture_count)), 0.01))
	else:
		print("[VideoGLB] Lighting mood=", _lighting_color_mood, " illumination_scale=", _lighting_illumination_scale)

	# Extract camera pose for light anchor and room bounds
	var cam_pose = cam_pose_override if cam_pose_override != null else _extract_camera_pose(data)
	var cam_pos: Vector3 = cam_pose["position"]
	var cam_target: Vector3 = cam_pose["target"]
	var cam_forward: Vector3 = (cam_target - cam_pos).normalized()
	if cam_forward.length() < 0.001:
		cam_forward = Vector3(0, 0, -1)
	var cam_right = cam_forward.cross(Vector3.UP).normalized()
	if cam_right.length() < 0.001:
		cam_right = Vector3.RIGHT
	var light_anchor = cam_target
	var room_info = _extract_room_lighting_bounds(geom_data)
	var room_center: Vector3 = room_info.get("center", light_anchor)
	var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
	var room_ceiling_y: float = room_info.get("ceiling_y", room_center.y + 2.8)

	# ── Rendering Overrides for 4K / Shadows ──
	# Increased from 4096 to 8192 for crisp high-res window shadows
	# 16384 ensures the sun's shadow map is tack sharp across the room
	var _vp_h = get_viewport().size.y
	var _shadow_atlas = 8192
	if _vp_h >= 2000:
		_shadow_atlas = 16384
	elif _vp_h >= 1300:
		_shadow_atlas = 8192
	else:
		_shadow_atlas = 4096
	RenderingServer.directional_shadow_atlas_set_size(_shadow_atlas, false)
	print("[Shadow] Viewport height=", _vp_h, " → shadow atlas=", _shadow_atlas)

	# ── Primary Directional Light (Sun / Moon) ─────────────────────────────────
	var dir_light = DirectionalLight3D.new()
	dir_light.name = "Sun"
	# Sun casts crisp realistic shadows — interior fixtures handle fill, not the sun.
	dir_light.shadow_enabled = true
	dir_light.shadow_bias = 0.006
	dir_light.shadow_normal_bias = 0.65
	if day_render:
		# Soft 10AM shadows: shadow_blur+angular_distance control penumbra width.
		# 0.18 angular was razor-sharp (tiny sun disc). 0.8 gives natural soft edges.
		dir_light.shadow_blur = 1.2 # Soft penumbra
		dir_light.light_angular_distance = 0.8 # Larger sun disc = wider shadow softness
		dir_light.directional_shadow_max_distance = 30.0
	else:
		dir_light.shadow_blur = 1.2
		dir_light.light_angular_distance = 0.5
		dir_light.directional_shadow_max_distance = 120.0
	dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	dir_light.directional_shadow_blend_splits = true
	dir_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY

	var directional_transform = _resolve_directional_light_transform(data)
	_directional_light_authoring_locked = false

	var dir_energy = lighting["dir_energy"]
	var dir_color = lighting["dir_color"]
	if day_render:
		# Reduced from 2.8 — was blowing out wall surfaces and making shadows too harsh.
		# 2.0 gives natural 10AM brightness without overexposure.
		dir_energy = 2.0
		dir_color = Color(1.0, 0.835, 0.50) # 10AM sunlight — warm golden white
		print("[Sun] Day render: 10AM sunlight energy=2.0, warm golden color (soft shadows).")
	else:
		# Night: read from JSON as before — authored moods still apply.
		if data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
			var ls = data["_lightingSettings"]
			if ls.has("directional"):
				dir_energy = float(ls.get("directional", dir_energy))
			if ls.has("directionalColor") and typeof(ls["directionalColor"]) == TYPE_DICTIONARY:
				var ls_color = ls["directionalColor"]
				dir_color = Color(
					float(ls_color.get("r", dir_color.r)),
					float(ls_color.get("g", dir_color.g)),
					float(ls_color.get("b", dir_color.b))
				)
		if data.has("directional_light"):
			var l = data["directional_light"]
			dir_energy = float(l.get("intensity", dir_energy))
			if l.has("color") and typeof(l["color"]) == TYPE_DICTIONARY:
				var c = l["color"]
				dir_color = Color(
					float(c.get("r", dir_color.r)),
					float(c.get("g", dir_color.g)),
					float(c.get("b", dir_color.b))
				)

	if day_render:
		dir_light.light_energy = dir_energy # hardcoded physical sun — no scale
		dir_light.light_color = dir_color # hardcoded golden color — no mood tint
	else:
		var mood_dir_color = _get_color_mood_light_color("directional")
		dir_light.light_energy = dir_energy * _lighting_illumination_scale
		dir_light.light_color = Color(
			dir_color.r * mood_dir_color.r,
			dir_color.g * mood_dir_color.g,
			dir_color.b * mood_dir_color.b
		)

	# CRITICAL: add_child BEFORE setting position/look_at, otherwise look_at fails
	# because the node has no coordinate space.
	_dir_light = dir_light
	add_child(dir_light)

	if directional_transform["has_position"]:
		var pos = directional_transform["position"]
		if abs(_scene_plan_rotation_radians) > 0.000001:
			pos = _transform_plan_point_meters(pos)
		dir_light.position = pos
		_directional_light_authoring_locked = true
	if directional_transform["has_target"]:
		var target_pos: Vector3 = directional_transform["target"]
		if abs(_scene_plan_rotation_radians) > 0.000001:
			target_pos = _transform_plan_point_meters(target_pos)
		if dir_light.position.distance_to(target_pos) > 0.001:
			dir_light.look_at(target_pos, Vector3.UP)
		_directional_light_authoring_locked = true

	if _directional_light_authoring_locked:
		print("[VideoGLB] Using authored directional light transform from JSON.")

	# ── Sky / Environment ──────────────────────────────────────────────────────
	var env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.radiance_size = Sky.RADIANCE_SIZE_1024
	env.sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var exr_path = ""
	if data.has("environment_url") and data["environment_url"] != null and data["environment_url"] != "":
		exr_path = str(data["environment_url"])
	else:
		exr_path = ProjectSettings.globalize_path(lighting["sky_exr"])

	var sky_material_set = false
	if FileAccess.file_exists(exr_path):
		var exr_image = Image.new()
		var load_err = exr_image.load(exr_path)
		if load_err == OK:
			exr_image.generate_mipmaps()
			var sky_tex = ImageTexture.create_from_image(exr_image)
			var panorama_mat = PanoramaSkyMaterial.new()
			panorama_mat.panorama = sky_tex
			panorama_mat.filter = true
			env.sky.sky_material = panorama_mat
			sky_material_set = true
			print("[VideoGLB] Loaded EXR sky: ", exr_path)
		else:
			print("[VideoGLB] Warning: Failed to load EXR: ", exr_path, " Error: ", load_err)
	else:
		print("[VideoGLB] Warning: EXR sky file not found: ", exr_path)

	if not sky_material_set:
		var sky_mat = ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = lighting["sky_top_color"]
		sky_mat.sky_horizon_color = lighting["sky_horizon_color"]
		sky_mat.ground_bottom_color = lighting["ground_bottom_color"]
		sky_mat.ground_horizon_color = lighting["ground_horizon_color"]
		sky_mat.sun_angle_max = lighting["sun_angle_max"]
		sky_mat.sun_curve = lighting["sun_curve"]
		env.sky.sky_material = sky_mat
		print("[VideoGLB] Using fallback procedural sky")

	# ── Ambient Light ──────────────────────────────────────────────────────────
	# Use COLOR ambient for enclosed rooms — avoids sky-light bleeding at corners.
	if day_render:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 1.0 # Full sky contribution
		print("[Ambient] Day: using SKY as ambient source (EXR panorama lights interior).")
	else:
		# Night: use COLOR ambient so authored mood colors apply
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		var mood_ambient_color = _get_color_mood_light_color("ambient")
		env.ambient_light_color = Color(
			lighting["ambient_color"].r * mood_ambient_color.r,
			lighting["ambient_color"].g * mood_ambient_color.g,
			lighting["ambient_color"].b * mood_ambient_color.b
		)
		env.ambient_light_energy = lighting["ambient_energy"] * _lighting_illumination_scale

	# ── Tone Mapping ──────────────────────────────────────────────────────────
	# ── Dynamic Tone Mapping (based on mood) ──────────────────────────────────
	var mood_key := _lighting_color_mood.to_lower()
	if day_render:
		# DAY RENDERS: Switched back to ACES as requested for photorealism.
		# The higher sun energy (5.5) will compensate for ACES highlight compression.
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
	else:
		match mood_key:
			"soft", "day":
				env.tonemap_mode = Environment.TONE_MAPPER_ACES
			"cool":
				env.tonemap_mode = Environment.TONE_MAPPER_ACES
			"warm", "neutral":
				env.tonemap_mode = Environment.TONE_MAPPER_AGX
			_:
				env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	env.tonemap_exposure = lighting["tonemap_exposure"]
	if day_render:
		# exposure=1.5: matches image render for consistent day brightness.
		env.tonemap_exposure = 1.5
		# ambient_light_energy=6.0: sky dome energy sampled from all directions
		# to fill dark corners and shadowed walls without casting shadows.
		env.ambient_light_energy = 6.0
		env.ambient_light_color = Color(1.0, 0.835, 0.50) # warm golden sky
		print("[Lighting] Day: exposure=1.5, sky ambient energy=6.0")
	if not day_render:
		# Keep our authored ambient energy from the profile instead of crushing it
		if mood_key == "warm":
			env.ambient_light_energy = lighting["ambient_energy"] * 1.2 * _lighting_illumination_scale
		else:
			env.ambient_light_energy = lighting["ambient_energy"] * _lighting_illumination_scale

	if env.tonemap_mode == Environment.TONE_MAPPER_AGX:
		env.tonemap_white = lighting.get("tonemap_agx_white", lighting["tonemap_white"])
		# AGX contrast is applied via exposure adjustment (baked into exposure).
		env.tonemap_exposure *= lighting.get("tonemap_agx_contrast", 1.0)
		# Warm mood: slightly boost AGX exposure for richer shadows
		if mood_key == "warm":
			env.tonemap_exposure *= 1.08
	else:
		env.tonemap_white = lighting["tonemap_white"]

	# ── SDFGI ─────────────────────────────────────────────────────────────────
	# DAY: SDFGI ON at artifact-safe low settings.
	# The ceiling dots come from HIGH energy + high bounce_feedback.
	# At energy=0.25 + bounce=0.20 + high biases, SDFGI provides
	# GI bounce for dark walls/ceiling without the probe grid showing.
	env.sdfgi_enabled = not day_render
	env.sdfgi_min_cell_size = 0.2 # Coarser grid = fewer probe boundaries visible
	env.sdfgi_cascades = 6 # Fewer cascades for interior-only scene
	env.sdfgi_use_occlusion = true
	env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_100_PERCENT
	if day_render:
		# SAFE artifact-free day values.
		# Dots appear on light-colored ceilings when energy > ~0.40.
		# High biases push probes far from surfaces so probe grid never shows.
		env.sdfgi_normal_bias = 2.5 # Very high — probes far from ceiling surface
		env.sdfgi_probe_bias = 2.0 # Prevents surface self-intersection
		env.sdfgi_bounce_feedback = 0.15 # Very low — no recursive noise amplification
		env.sdfgi_energy = 0.30 # Below dot-visibility threshold for light ceilings
		print("[GI] Day SDFGI: Disabled in favor of VoxelGI.")
	else:
		env.sdfgi_normal_bias = 1.0
		env.sdfgi_probe_bias = 1.0
		if mood_key == "warm":
			env.sdfgi_bounce_feedback = 0.60
			env.sdfgi_energy = 0.70
		else:
			env.sdfgi_bounce_feedback = 0.55
			env.sdfgi_energy = 0.62


	# --- Screen-Space Indirect Light (SSIL) ---
	# DAY: ON at very low artifact-safe intensity.
	# Artifacts appear at intensity ≥0.8. At 0.20 with sharpness=0.0,
	# SSIL provides smooth bounce from sunlit floor to dark walls/ceiling
	# without generating the screen-space wave pattern.
	env.ssil_enabled = true
	env.ssil_sharpness = 0.0 # Fully soft — no sharp sampling edges to create patterns
	env.ssil_normal_rejection = 0.9 # Aggressive rejection to skip ceiling self-sampling
	if day_render:
		env.ssil_radius = 3.0
		env.ssil_intensity = 0.25 # Below wave-pattern threshold, still provides bounce
		print("[GI] Day SSIL: intensity=0.25 (artifact-safe bounce)")
	else:
		if mood_key == "warm":
			env.ssil_radius = 4.0
			env.ssil_intensity = 0.8
		else:
			env.ssil_radius = 4.0
			env.ssil_intensity = 0.8

	# --- Screen-Space Ambient Occlusion (SSAO) ---
	# DAY: Re-enabled at SAFE LOW settings for contact shadows under furniture.
	# Previously disabled because intensity=2.0 created ceiling dot noise.
	# At intensity=0.8 + power=1.2 it provides contact shadows without visible noise.
	# This is what gives the sofa/plants their dark underside — without it everything floats.
	if day_render:
		# Force FULL-RESOLUTION SSAO at 4K.
		# half_size=false → runs at 3840×2160, not 1920×1080.
		ProjectSettings.set_setting("rendering/environment/ssao/quality", 3) # HIGH
		ProjectSettings.set_setting("rendering/environment/ssao/half_size", false)
		RenderingServer.environment_set_ssao_quality(
			RenderingServer.ENV_SSAO_QUALITY_HIGH,
			false, # half_size=FALSE = full resolution at 4K
			0.5,
			10,
			0.0,
			10.0
		)
		env.ssao_enabled = true
		env.ssao_radius = 1.2
		env.ssao_intensity = 2.2
		env.ssao_power = 2.0
		env.ssao_detail = 1.0
		env.ssao_horizon = 0.06
		env.ssao_sharpness = 0.7
		# KEY FIX: ssao_light_affect makes SSAO darken direct lights too (portal SpotLight,
		# AmbientOmni). Without this, SSAO only darkens sky ambient (0.45) which is
		# invisible against the portal (2.0) and omni (0.6) direct lights.
		env.ssao_light_affect = 0.7 # 0=ambient only, 1=full direct+ambient
		print("[AO] Day: SSAO HIGH full-res, light_affect=0.7 for visible contact shadows everywhere.")
	else:
		env.ssao_enabled = true
		env.ssao_radius = 0.4
		env.ssao_intensity = 1.8
		env.ssao_power = 1.3
		env.ssao_detail = 0.5
		env.ssao_horizon = 0.06
		env.ssao_sharpness = 0.5

	# --- Screen-Space Reflections ---
	env.ssr_enabled = true
	env.ssr_max_steps = 64 # default 64, increase for longer reflections
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.2

	# ── Glow / Bloom ───────────────────────────────────────────────────────
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	if day_render:
		env.glow_intensity = 0.18
		env.glow_bloom = 0.04
		env.glow_hdr_threshold = 0.85 # Only the very brightest window glass triggers bloom
		env.glow_hdr_scale = 1.0
		env.glow_map_strength = 0.0
	elif mood_key == "warm":
		env.glow_intensity = lighting["glow_intensity"]
		env.glow_bloom = lighting["glow_bloom"]
		env.glow_hdr_threshold = lighting["glow_hdr_threshold"]
		env.glow_hdr_scale = lighting["glow_hdr_scale"]
		env.glow_map_strength = 0.0
	else:
		env.glow_intensity = lighting["glow_intensity"]
		env.glow_bloom = lighting["glow_bloom"]
		env.glow_hdr_threshold = lighting["glow_hdr_threshold"]
		env.glow_hdr_scale = lighting["glow_hdr_scale"]

	# ── Volumetric Fog — subtle warm atmospheric haze for day ───────────────
	if day_render:
		# Very subtle warm dust/haze visible in shafts of sunlight.
		# Creates the atmospheric light scattering seen in the reference image.
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.001 # Very subtle — barely visible haze
		env.volumetric_fog_albedo = Color(0.97, 0.97, 0.98) # Neutral white — fog scatters directional light colour as-is, no extra yellow tint
		env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env.volumetric_fog_emission_energy = 0.0
		env.volumetric_fog_gi_inject = 0.5
		env.volumetric_fog_anisotropy = 0.8 # Forward scattering — haze shows in sunbeam direction
		print("[Fog] Day: warm volumetric haze enabled (density=0.008)")
	elif mood_key == "warm":
		env.volumetric_fog_enabled = false
		env.volumetric_fog_density = 0.01
		env.volumetric_fog_albedo = Color(1.0, 0.95, 0.88)
		env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env.volumetric_fog_emission_energy = 0.0
	else:
		env.volumetric_fog_enabled = false

	# ── Colour Grading ──
	env.adjustment_enabled = true
	if day_render:
		env.adjustment_brightness = 0.95
		# Contrast 1.25 deepens the gap between lit and shadow areas.
		# 1.05 was too flat — shadow under sofa/plants looked same as lit floor. so 1.08
		env.adjustment_contrast = 1.10
		env.adjustment_saturation = 1.05
	else:
		env.adjustment_brightness = 0.92 # Slightly lower exposure → darks get darker (Coohom-match)
		env.adjustment_contrast = 1.35 # S-curve depth — was 1.06 (flat), Coohom is ~1.35
		env.adjustment_saturation = 1.10

	# ── NVIDIA RTX Path Tracing ────────────────────────────────────────────────
	# DLSS Ray Reconstruction handles denoising + temporal AA for video frames.
	# Lower SPP and bounces than image render since DLSS RR reconstructs detail
	# from noisy input and the temporal history across frames helps convergence.
	# PathtracingDenoiser enum values (from rendering_server_enums.h):
	#   PT_DENOISER_NONE = 0
	#   PT_DENOISER_DLSS_RAY_RECONSTRUCTION = 1
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_max_bounces(6) # 6 bounces — DLSS RR denoises so fewer bounces suffice
	env.set_pathtracing_samples_per_pixel(6) # 4 SPP — DLSS RR handles the rest (denoising + AA)
	env.set_pathtracing_denoiser(1) # 1 = PT_DENOISER_DLSS_RAY_RECONSTRUCTION
	env.set("raytracing_params", PackedFloat32Array([0.0, 0.0, 0.0, 1.0]))
	print("[VideoGLB] NVIDIA PT enabled: bounces=6, spp=4, denoiser=DLSS_RR")

	# Reflection probes are now localized per room and generated automatically via _generate_localized_reflection_probes.

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# ── Scene Fill Lights ──────────────────────────────────────────────────────
	if lighting_profile == "day" or lighting_profile == "sunset":
		var fill = OmniLight3D.new()
		fill.name = "FillLight"
		fill.position = Vector3(room_center.x, room_ceiling_y - 0.55, room_center.z)
		fill.light_energy = lighting["fill_energy"] * _lighting_illumination_scale * 0.01
		fill.omni_range = max(room_extent.x, room_extent.y) * 2.5 + 10.0
		var mood_fill_color = _get_color_mood_light_color("fill")
		fill.light_color = Color(
			lighting["fill_color"].r * mood_fill_color.r,
			lighting["fill_color"].g * mood_fill_color.g,
			lighting["fill_color"].b * mood_fill_color.b
		)
		fill.light_specular = 0.0
		fill.shadow_enabled = false
		add_child(fill)

		# Symmetric front/back fill avoids camera-direction brightness splits
		var fill_offset = max(room_extent.x, room_extent.y) * 0.28
		var fill_front = OmniLight3D.new()
		fill_front.name = "FrontFillLight"
		fill_front.position = Vector3(room_center.x, room_ceiling_y - 0.9, room_center.z) + cam_forward * fill_offset
		fill_front.light_energy = lighting["front_back_fill_energy"] * _lighting_illumination_scale * 0.01
		fill_front.omni_range = max(room_extent.x, room_extent.y) * 1.6 + 4.0
		fill_front.light_color = Color(
			lighting["front_back_fill_color"].r * mood_fill_color.r,
			lighting["front_back_fill_color"].g * mood_fill_color.g,
			lighting["front_back_fill_color"].b * mood_fill_color.b
		)
		fill_front.light_specular = 0.0
		fill_front.shadow_enabled = false
		add_child(fill_front)

		var fill_back = OmniLight3D.new()
		fill_back.name = "BackFillLight"
		fill_back.position = Vector3(room_center.x, room_ceiling_y - 0.9, room_center.z) - cam_forward * fill_offset
		fill_back.light_energy = lighting["front_back_fill_energy"] * _lighting_illumination_scale * 0.01
		fill_back.omni_range = max(room_extent.x, room_extent.y) * 1.6 + 4.0
		fill_back.light_color = Color(
			lighting["front_back_fill_color"].r * mood_fill_color.r,
			lighting["front_back_fill_color"].g * mood_fill_color.g,
			lighting["front_back_fill_color"].b * mood_fill_color.b
		)
		fill_back.light_specular = 0.0
		fill_back.shadow_enabled = false
		add_child(fill_back)
	else:
		var fill = OmniLight3D.new()
		fill.name = "FillLight"
		fill.position = Vector3(room_center.x, room_ceiling_y - 0.55, room_center.z)
		fill.light_energy = lighting["fill_energy"] * _lighting_illumination_scale * 0.01
		fill.omni_range = max(room_extent.x, room_extent.y) * 2.2 + 7.0
		var mood_fill_color = _get_color_mood_light_color("fill")
		fill.light_color = Color(
			lighting["fill_color"].r * mood_fill_color.r,
			lighting["fill_color"].g * mood_fill_color.g,
			lighting["fill_color"].b * mood_fill_color.b
		)
		fill.light_specular = 0.0
		fill.shadow_enabled = false
		add_child(fill)

	_lighting_setup_done = true
	print("[VideoGLB] Photorealistic lighting setup complete. profile=", lighting_profile)

func _setup_voxel_gi(geom_data):
	print("[VoxelGI] Setting up VoxelGI for Day Render...")
	var room_info = _extract_room_lighting_bounds(geom_data)
	var room_center: Vector3 = room_info.get("center", Vector3.ZERO) # room_center might not be cached globally here
	var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
	var room_ceiling_y: float = room_info.get("ceiling_y", room_center.y + 2.8)

	var vgi = VoxelGI.new()
	vgi.name = "DayVoxelGI"
	vgi.position = Vector3(room_center.x, room_ceiling_y * 0.5, room_center.z)
	
	# Add padding to ensure walls are fully captured. Extent is half-size, so multiply by 2 for full width/depth.
	vgi.size = Vector3(room_extent.x * 2.0 + 3.0, room_ceiling_y + 2.0, room_extent.y * 2.0 + 3.0)
	
	# SUBDIV_256 gives better quality for archviz
	vgi.subdiv = VoxelGI.SUBDIV_256
	
	add_child(vgi)
	print("[VoxelGI] VoxelGI node added. Size: ", vgi.size, " Position: ", vgi.position)
	print("[VoxelGI] Baking...")
	vgi.bake()
	print("[VoxelGI] Bake complete.")

# ─────────────────────────────────────────────────────────────────
func _orient_directional_light_from_windows(dir_light: DirectionalLight3D, cam_pose_override = null):
	if _window_sunlight_data.size() == 0:
		return

	# ── Step 0: Camera Orientation ────────────────────────────────────────
	# We want sunlight to favor windows the camera is looking at.
	var cam_pose = cam_pose_override
	if cam_pose == null:
		cam_pose = _frozen_camera_pose
	if cam_pose == null:
		cam_pose = {"position": Vector3.ZERO, "target": Vector3(0, 0, -1)}
	
	var cam_pos: Vector3 = cam_pose["position"]
	var cam_target: Vector3 = cam_pose["target"]
	var cam_forward = (cam_target - cam_pos).normalized()
	cam_forward.y = 0.0 # horizontal view direction
	if cam_forward.length() < 0.001:
		cam_forward = Vector3(0, 0, -1)
	cam_forward = cam_forward.normalized()

	# ── Step 1: Weighted outer_dir ────────────────────────────────────────
	# Instead of a simple average, we weight windows based on their visibility 
	# and alignment with the camera to create a "backlit/side-lit" cinematic look.
	var weighted_outer_dir := Vector3.ZERO
	var total_weight := 0.0
	
	for win in _window_sunlight_data:
		var win_center = win["center"] as Vector3
		var win_inner = win["inner_dir"] as Vector3
		win_inner.y = 0.0
		win_inner = win_inner.normalized()
		
		# Score 1: Is the window actually in front of the camera's lens?
		var to_win = (win_center - cam_pos).normalized()
		to_win.y = 0.0
		var fov_score = max(0.0, cam_forward.dot(to_win)) # 1.0 = directly in center of view
		
		# Score 2: Is the window on a wall the camera is facing?
		# (If looking at a window, its inner_dir points back at the camera)
		var visibility_score = max(0.0, win_inner.dot(-cam_forward))
		
		# Score 3: Are there exterior assets (trees/plants) outside this window?
		# We want to favor windows that will cast interesting shadows.
		var asset_bonus = 0.0
		for ext in _exterior_assets:
			var asset_pos = ext["position"] as Vector3
			var dist_to_win = win_center.distance_to(asset_pos)
			if dist_to_win < 6.0: # within 6 meters of window
				# Check if asset is actually "outside" the window (in the direction of outer_dir)
				var to_asset = (asset_pos - win_center).normalized()
				var alignment = (win["outer_dir"] as Vector3).dot(to_asset)
				if alignment > 0.0: # asset is outside
					asset_bonus += 2.5 * (1.0 - dist_to_win / 6.0) * alignment

		# Weight calculation: prioritize windows in FOV and on facing walls.
		# This ensures light "shines back" towards the camera through windows.
		var weight = (fov_score * 2.0) + (visibility_score * 3.5) + asset_bonus + 0.1 # 0.1 baseline fallback
		
		weighted_outer_dir += (win["outer_dir"] as Vector3) * weight
		total_weight += weight

	var avg_outer_dir = weighted_outer_dir / total_weight
	avg_outer_dir.y = 0.0 # flatten — elevation handled separately below
	if avg_outer_dir.length() < 0.001:
		avg_outer_dir = Vector3(1, 0, 0) # safe fallback
	avg_outer_dir = avg_outer_dir.normalized()

	# ── Step 2: Sun elevation per lighting profile ────────────────────────
	# This is the downward angle of sunlight.
	var elevation_deg: float
	match lighting_profile:
		"day": elevation_deg = 28.0 # slightly lower for longer, more dramatic shadows
		"sunset": elevation_deg = 8.0 # high grazing golden hour light
		"night": elevation_deg = 55.0 # moon, steep and cool
		_: elevation_deg = 28.0

	# ── Step 3: Build a direction vector from outer_dir + elevation ───────
	# Sun ray direction: horizontal component = -avg_outer_dir (sun comes from outside)
	var elevation_rad := deg_to_rad(elevation_deg)
	var sun_dir := Vector3(
		- avg_outer_dir.x,
		- sin(elevation_rad), # negative = pointing downward
		- avg_outer_dir.z
	).normalized()

	# ── Step 4: Orient the directional light ─────────────────────────────
	# Place the virtual sun far away and look_at the weighted center of openings.
	var weighted_center := Vector3.ZERO
	for win in _window_sunlight_data:
		weighted_center += (win["center"] as Vector3)
	weighted_center /= float(_window_sunlight_data.size())

	dir_light.position = weighted_center - sun_dir * 50.0
	if dir_light.position.distance_to(weighted_center) > 0.001:
		dir_light.look_at(weighted_center, Vector3.UP)

	print("[VideoGLB] Dynamic Sunlight oriented: cam_forward=", cam_forward,
		  " weighted_outer=", avg_outer_dir, " elevation=", elevation_deg)

# Removed _create_window_sunlights (legacy SpotLight method) in favor of DirectionalLight.

# ─────────────────────────────────────────────────────────────────
# Parse vec3 helper
# ─────────────────────────────────────────────────────────────────
func parse_vec3(d):
	if typeof(d) == TYPE_DICTIONARY:
		return Vector3(d.get("x", 0), d.get("y", 0), d.get("z", 0))
	return Vector3.ZERO

func _get_floor_plan_layer_map(data) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	if data.has("layers") and typeof(data["layers"]) == TYPE_DICTIONARY:
		return data["layers"]
	return {}

func _layer_has_geometry(layer) -> bool:
	if typeof(layer) != TYPE_DICTIONARY:
		return false
	for key in ["lines", "vertices", "areas", "items", "holes", "structures"]:
		if not layer.has(key):
			continue
		var value = layer[key]
		if typeof(value) == TYPE_DICTIONARY and value.size() > 0:
			return true
		if typeof(value) == TYPE_ARRAY and value.size() > 0:
			return true
	return false

func _get_layer_altitude(layer) -> float:
	if typeof(layer) != TYPE_DICTIONARY:
		return 0.0
	if not layer.has("altitude"):
		return 0.0
	var alt = layer["altitude"]
	if typeof(alt) == TYPE_DICTIONARY and alt.has("length"):
		return float(alt["length"]) * _scene_unit_scale
	elif typeof(alt) == TYPE_INT or typeof(alt) == TYPE_FLOAT:
		return float(alt) * _scene_unit_scale
	elif typeof(alt) == TYPE_STRING and alt.is_valid_float():
		return float(alt) * _scene_unit_scale
	return 0.0

func _get_render_layer_altitude(layer, show_all_floors: bool) -> float:
	if not show_all_floors:
		return 0.0
	return _get_layer_altitude(layer)

func _get_primary_layer_id(data, layer_map: Dictionary = {}) -> String:
	var layers = layer_map
	if layers.size() == 0:
		layers = _get_floor_plan_layer_map(data)
	if layers.size() == 0:
		return ""

	var selected_layer = str(data.get("selectedLayer", ""))
	if selected_layer != "" and layers.has(selected_layer):
		var selected = layers[selected_layer]
		if typeof(selected) == TYPE_DICTIONARY and _layer_has_geometry(selected):
			return selected_layer

	for layer_id in layers.keys():
		var layer = layers[layer_id]
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		if _layer_has_geometry(layer):
			return str(layer_id)

	var first_key = layers.keys()[0] if layers.size() > 0 else ""
	return str(first_key)

func _resolve_lighting_profile(data: Dictionary) -> String:
	var string_keys = ["lighting_profile", "time_of_day", "render_time", "environment_preset"]
	for key in string_keys:
		if data.has(key):
			var value = str(data[key]).to_lower().strip_edges()
			if "sunset" in value or "dusk" in value or "evening" in value:
				return "sunset"
			if "night" in value:
				return "night"
			if "day" in value or "morning" in value or "afternoon" in value:
				return "day"

	if bool(data.get("sunset_render", false)):
		return "sunset"
	if bool(data.get("night_render", false)):
		return "night"
	if data.has("day_render"):
		return "day" if bool(data["day_render"]) else "night"
	return "day"

func _get_lighting_profile_settings() -> Dictionary:
	match lighting_profile:
		"night":
			return {
				"sky_exr": "res://night.exr",
				"dir_energy": 0.06,
				"dir_color": Color(0.55, 0.62, 0.90),
				"sky_top_color": Color(0.01, 0.02, 0.05),
				"sky_horizon_color": Color(0.04, 0.06, 0.10),
				"ground_bottom_color": Color(0.005, 0.005, 0.01),
				"ground_horizon_color": Color(0.03, 0.05, 0.08),
				"sun_angle_max": 10.0,
				"sun_curve": 0.05,
				"ambient_color": Color(0.20, 0.24, 0.34),
				"ambient_energy": 0.05,
				"tonemap_exposure": 0.45,
				"tonemap_white": 4.8,
				"tonemap_agx_white": 14.0,
				"tonemap_agx_contrast": 1.12,
				"glow_intensity": 0.26,
				"glow_bloom": 0.10,
				"glow_hdr_threshold": 1.15,
				"glow_hdr_scale": 2.1,
				"fill_energy": 0.05,
				"fill_color": Color(0.5, 0.55, 0.8),
				"front_back_fill_energy": 0.02,
				"front_back_fill_color": Color(0.58, 0.64, 0.88)
			}
		"sunset":
			return {
				"sky_exr": "res://day.exr",
				"dir_energy": 1.65,
				"dir_color": Color(1.0, 0.63, 0.38),
				"sky_top_color": Color(0.20, 0.24, 0.42),
				"sky_horizon_color": Color(1.0, 0.56, 0.34),
				"ground_bottom_color": Color(0.09, 0.05, 0.03),
				"ground_horizon_color": Color(0.42, 0.22, 0.14),
				"sun_angle_max": 18.0,
				"sun_curve": 0.22,
				"ambient_color": Color(0.62, 0.50, 0.42),
				"ambient_energy": 0.28,
				"tonemap_exposure": 0.78,
				"tonemap_white": 4.6,
				"tonemap_agx_white": 16.0,
				"tonemap_agx_contrast": 1.30,
				"glow_intensity": 0.28,
				"glow_bloom": 0.11,
				"glow_hdr_threshold": 1.10,
				"glow_hdr_scale": 2.15,
				"fill_energy": 0.15,
				"fill_color": Color(1.0, 0.80, 0.60),
				"front_back_fill_energy": 0.07,
				"front_back_fill_color": Color(1.0, 0.82, 0.64)
			}
		_:
			return {
				"sky_exr": "res://day.exr",
				"dir_energy": 1.0,
				"dir_color": Color(1.0, 0.835, 0.50),
				"sky_top_color": Color(0.25, 0.40, 0.78),
				"sky_horizon_color": Color(0.75, 0.80, 0.90),
				"ground_bottom_color": Color(0.08, 0.06, 0.04),
				"ground_horizon_color": Color(0.30, 0.28, 0.22),
				"sun_angle_max": 30.0,
				"sun_curve": 0.15,
				"ambient_color": Color(0.76, 0.77, 0.78),
				"ambient_energy": 0.15,
				"tonemap_exposure": 0.72,
				"tonemap_white": 5.0,
				"tonemap_agx_white": 16.29,
				"tonemap_agx_contrast": 1.18,
				"glow_intensity": 0.22,
				"glow_bloom": 0.08,
				"glow_hdr_threshold": 1.35,
				"glow_hdr_scale": 1.9,
				"fill_energy": 0.10,
				"fill_color": Color(1.0, 0.97, 0.90),
				"front_back_fill_energy": 0.03,
				"front_back_fill_color": Color(0.99, 0.97, 0.93)
			}

# ─────────────────────────────────────────────────────────────────
# Camera pose extractor
# ─────────────────────────────────────────────────────────────────
func _extract_camera_pose(data: Dictionary) -> Dictionary:
	var cam_pos = Vector3(0, 1.6, 6)
	var cam_target = Vector3.ZERO
	var found = false

	# Try video_animation first keyframe (camera coords are in cm)
	if data.has("video_animation") and data["video_animation"] != null:
		var anim = data["video_animation"]
		var keyframes = anim.get("keyframes", [])
		if keyframes.size() > 0:
			var kf0 = keyframes[0]
			var tjs = kf0.get("threejs_camera_data", null)
			if tjs != null and typeof(tjs) == TYPE_DICTIONARY:
				if tjs.has("position") and typeof(tjs["position"]) == TYPE_DICTIONARY:
					var p = tjs["position"]
					cam_pos = _camera_cm_to_m(Vector3(
						float(p.get("x", 0)),
						float(p.get("y", 0)),
						float(p.get("z", 0))
					))
					found = true
				if tjs.has("lookAt") and typeof(tjs["lookAt"]) == TYPE_DICTIONARY:
					var la = tjs["lookAt"]
					cam_target = _camera_cm_to_m(Vector3(
						float(la.get("x", 0)),
						float(la.get("y", 0)),
						float(la.get("z", 0))
					))

	if not found and data.has("threejs_camera") and typeof(data["threejs_camera"]) == TYPE_DICTIONARY:
		var tc = data["threejs_camera"]
		if tc.has("position") and typeof(tc["position"]) == TYPE_DICTIONARY:
			cam_pos = _camera_cm_to_m(Vector3(
				float(tc["position"].get("x", 0)),
				float(tc["position"].get("y", 0)),
				float(tc["position"].get("z", 0))
			))
			found = true
		if tc.has("target") and typeof(tc["target"]) == TYPE_DICTIONARY:
			cam_target = _camera_cm_to_m(Vector3(
				float(tc["target"].get("x", 0)),
				float(tc["target"].get("y", 0)),
				float(tc["target"].get("z", 0))
			))

	if not found:
		cam_pos = Vector3(0, 1.6, 6)
	if cam_target.distance_to(cam_pos) < 0.001:
		cam_target = cam_pos + Vector3(0, 0, -1)

	return {"position": cam_pos, "target": cam_target}

# ─────────────────────────────────────────────────────────────────
# Room bounds extractor — for lighting (ported from image_glb_creation.gd)
# ─────────────────────────────────────────────────────────────────
func _extract_room_lighting_bounds(geom_data) -> Dictionary:
	var out = {
		"center": Vector3.ZERO,
		"extent": Vector2(6.0, 6.0),
		"ceiling_y": 2.8
	}
	if typeof(geom_data) != TYPE_DICTIONARY:
		return out

	# Normalise array-format data to dict format for bounds extraction
	var layer_data = geom_data
	var layer_map = _get_floor_plan_layer_map(geom_data)
	if layer_map.size() > 0:
		var primary_layer_id = _get_primary_layer_id(geom_data, layer_map)
		if primary_layer_id != "" and layer_map.has(primary_layer_id):
			layer_data = layer_map[primary_layer_id]
	layer_data = _arrays_to_dicts(layer_data)

	if not layer_data.has("areas") or not layer_data.has("vertices"):
		return out

	var areas = layer_data["areas"]
	var vertices = layer_data["vertices"]
	if typeof(areas) != TYPE_DICTIONARY or typeof(vertices) != TYPE_DICTIONARY or areas.size() == 0:
		return out

	var min_x = 1e20; var max_x = -1e20
	var min_z = 1e20; var max_z = -1e20
	var got_any = false

	for aid in areas:
		var area = areas[aid]
		if typeof(area) != TYPE_DICTIONARY or not area.has("vertices"):
			continue
		for vid in area["vertices"]:
			var key = str(vid)
			if not vertices.has(key):
				continue
			var v = vertices[key]
			var x = float(v.get("x", 0.0)) * _scene_unit_scale
			var z = float(v.get("y", 0.0)) * _scene_unit_scale
			min_x = min(min_x, x); max_x = max(max_x, x)
			min_z = min(min_z, z); max_z = max(max_z, z)
			got_any = true

	if not got_any:
		return out

	var ceil_h = 2.8
	for aid in areas:
		var area = areas[aid]
		if typeof(area) != TYPE_DICTIONARY:
			continue
		if area.has("ceiling_properties"):
			var cp = area["ceiling_properties"]
			if typeof(cp) == TYPE_DICTIONARY and cp.has("height"):
				var h = float(cp["height"]) * _scene_unit_scale
				if h > 0.1:
					ceil_h = h
				break

	out["center"] = Vector3((min_x + max_x) * 0.5, ceil_h * 0.5, (min_z + max_z) * 0.5)
	out["extent"] = Vector2(max(2.0, max_x - min_x), max(2.0, max_z - min_z))
	out["ceiling_y"] = ceil_h
	return out

# ─────────────────────────────────────────────────────────────────
# Ceiling visibility helpers
# ─────────────────────────────────────────────────────────────────
func _camera_requires_ceiling(cam_pos: Vector3, layer_altitude: float, ceil_height: float, polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	var ceiling_y = layer_altitude + ceil_height
	if cam_pos.y > ceiling_y - 0.01:
		return false
	var p2 = Vector2(cam_pos.x, cam_pos.z)
	return _point_in_polygon(p2, polygon)

func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside = false
	var j = poly.size() - 1
	for i in range(poly.size()):
		var pi = poly[i]
		var pj = poly[j]
		var intersect = ((pi.y > p.y) != (pj.y > p.y))
		if intersect:
			var denom = pj.y - pi.y
			if abs(denom) < 0.000001:
				denom = 0.000001
			var x_at = (pj.x - pi.x) * (p.y - pi.y) / denom + pi.x
			if p.x < x_at:
				inside = !inside
		j = i
	return inside

# ─────────────────────────────────────────────────────────────────
# Architecture — converts arrays to lookup dicts then calls shared builder
# ─────────────────────────────────────────────────────────────────
# ==============================================================================
# BASE ARCHITECTURE GENERATION (WALLS, FLOORS, CEILINGS)
# ==============================================================================
# WHY IT EXISTS: This converts flat 2D lines and area data from the JSON layout 
# into physical 3D meshes. It mathematically extrudes the walls upwards, draws 
# polygons for floors/ceilings, and cuts holes (booleans) where windows and 
# doors need to go.
# ==============================================================================
func build_architecture(data, cam_pos = null, show_all_floors_override = null):
	print("[VideoGLB] Building Architecture...")

	var layer_data = _arrays_to_dicts(data)
	var layer_map = _get_floor_plan_layer_map(data)

	if layer_map.size() > 0:
		var show_all_floors = data.get("showAllFloors", true)
		if show_all_floors_override != null:
			show_all_floors = bool(show_all_floors_override)

		# Determine render_mode (video is almost always INTERIOR but respect override)
		var render_mode = data.get("render_mode", "INTERIOR")

		if show_all_floors:
			print("[VideoGLB] showAllFloors=true â€” building ceilings.")
		else:
			print("[VideoGLB] showAllFloors=false â€” ceilings hidden unless camera is inside.")

		var layer_ids = layer_map.keys()
		if not show_all_floors:
			var primary_layer_id = _get_primary_layer_id(data, layer_map)
			layer_ids = []
			if primary_layer_id != "":
				layer_ids.append(primary_layer_id)

		for layer_id in layer_ids:
			if not layer_map.has(layer_id):
				continue
			var layer = layer_map[layer_id]
			if typeof(layer) != TYPE_DICTIONARY:
				continue
			var layer_flat = _arrays_to_dicts(layer)
			if not layer_flat.has("lines") or not layer_flat.has("vertices"):
				continue
			print("[VideoGLB] Layer ", layer_id,
				"  Lines: ", layer_flat["lines"].size(),
				"  Vertices: ", layer_flat["vertices"].size(),
				"  Holes: ", layer_flat.get("holes", {}).size(),
				"  Areas: ", layer_flat.get("areas", {}).size())
			_build_layer_geometry(layer_flat, _get_render_layer_altitude(layer, show_all_floors), show_all_floors, cam_pos, render_mode)
		return

	if not layer_data.has("lines") or not layer_data.has("vertices"):
		print("[VideoGLB] WARNING: No lines/vertices found in floor_plan_data.")
		return

	print("[VideoGLB] Lines: ", layer_data["lines"].size(),
		"  Vertices: ", layer_data["vertices"].size(),
		"  Holes: ", layer_data.get("holes", {}).size(),
		"  Areas: ", layer_data.get("areas", {}).size())

	var show_all_floors = data.get("showAllFloors", true)
	if show_all_floors_override != null:
		show_all_floors = bool(show_all_floors_override)

	# Determine render_mode (video is almost always INTERIOR but respect override)
	var render_mode = data.get("render_mode", "INTERIOR")

	if show_all_floors:
		print("[VideoGLB] showAllFloors=true — building ceilings.")
	else:
		print("[VideoGLB] showAllFloors=false — ceilings hidden unless camera is inside.")

	_build_layer_geometry(layer_data, 0.0, show_all_floors, cam_pos, render_mode)

# Convert list-format arrays to id-keyed dicts (matching image_glb_creation.gd layout)
func _arrays_to_dicts(data: Dictionary) -> Dictionary:
	var out = {}

	# Vertices
	var raw_v = data.get("vertices", null)
	if typeof(raw_v) == TYPE_ARRAY:
		var d = {}
		for v in raw_v:
			if typeof(v) == TYPE_DICTIONARY and v.has("id"):
				d[str(v["id"])] = v
		out["vertices"] = d
	elif typeof(raw_v) == TYPE_DICTIONARY:
		out["vertices"] = raw_v

	# Lines
	var raw_l = data.get("lines", null)
	if typeof(raw_l) == TYPE_ARRAY:
		var d = {}
		for l in raw_l:
			if typeof(l) == TYPE_DICTIONARY and l.has("id"):
				d[str(l["id"])] = l
		out["lines"] = d
	elif typeof(raw_l) == TYPE_DICTIONARY:
		out["lines"] = raw_l

	# Holes
	var raw_h = data.get("holes", null)
	if typeof(raw_h) == TYPE_ARRAY:
		var d = {}
		for h in raw_h:
			if typeof(h) == TYPE_DICTIONARY and h.has("id"):
				d[str(h["id"])] = h
		out["holes"] = d
	elif typeof(raw_h) == TYPE_DICTIONARY:
		out["holes"] = raw_h

	# Areas
	var raw_a = data.get("areas", null)
	if typeof(raw_a) == TYPE_ARRAY:
		var d = {}
		for a in raw_a:
			if typeof(a) == TYPE_DICTIONARY and a.has("id"):
				d[str(a["id"])] = a
		out["areas"] = d
	elif typeof(raw_a) == TYPE_DICTIONARY:
		out["areas"] = raw_a

	# Items
	var raw_i = data.get("items", null)
	if typeof(raw_i) == TYPE_ARRAY:
		out["items"] = raw_i
	elif typeof(raw_i) == TYPE_DICTIONARY:
		out["items"] = raw_i

	var raw_s = data.get("structures", null)
	if typeof(raw_s) == TYPE_ARRAY:
		var d = {}
		for s in raw_s:
			if typeof(s) == TYPE_DICTIONARY and s.has("id"):
				d[str(s["id"])] = s
		out["structures"] = d
	elif typeof(raw_s) == TYPE_DICTIONARY:
		out["structures"] = raw_s

	return out

# ─────────────────────────────────────────────────────────────────
# Wall facing direction — mirrors frontend getWallFacingDirection()
# Returns "inner-left", "inner-right", or "" (fallback to centroid)
# ─────────────────────────────────────────────────────────────────
func _get_wall_facing_direction(line: Dictionary, vertices: Dictionary, areas: Dictionary) -> String:
	var v1_id = str(line["vertices"][0])
	var v2_id = str(line["vertices"][1])
	if not vertices.has(v1_id) or not vertices.has(v2_id):
		return ""

	var vA = vertices[v1_id]
	var vB = vertices[v2_id]
	var ax = float(vA["x"]); var ay = float(vA["y"])
	var bx = float(vB["x"]); var by = float(vB["y"])

	var dir = Vector2(bx - ax, by - ay).normalized()
	var left_normal = Vector2(-dir.y, dir.x)
	var right_normal = Vector2(dir.y, -dir.x)
	var mid = Vector2((ax + bx) * 0.5, (ay + by) * 0.5)
	var left_sample = mid + left_normal * 5.0
	var right_sample = mid + right_normal * 5.0

	var best_result = ""
	var best_area_id = ""

	# ── T-Junction fix: Geometry2D boundary-distance check ───────────────────
	# Instead of requiring both endpoints to be named room corners, check whether
	# each wall endpoint lies ON a boundary segment. Handles T-junction walls.
	var snap_dist = 0.05 / max(_scene_unit_scale, 0.000001) # 5 cm in source units

	for area_id in areas:
		var area = areas[area_id]
		if not area.has("vertices"):
			continue
		var area_verts = area["vertices"]

		var area_polygon: Array = []
		for vid in area_verts:
			var vs = str(vid)
			if vertices.has(vs):
				var v = vertices[vs]
				area_polygon.append(Vector2(float(v["x"]), float(v["y"])))
		if area_polygon.size() < 3:
			continue

		# Geometry2D segment-distance test for T-junction membership
		var wall_a = Vector2(ax, ay)
		var wall_b = Vector2(bx, by)
		var v1_on_boundary = false
		var v2_on_boundary = false
		var n_pts = area_polygon.size()
		for ei in range(n_pts):
			var ea: Vector2 = area_polygon[ei]
			var eb: Vector2 = area_polygon[(ei + 1) % n_pts]
			if not v1_on_boundary and Geometry2D.get_closest_point_to_segment(wall_a, ea, eb).distance_to(wall_a) <= snap_dist:
				v1_on_boundary = true
			if not v2_on_boundary and Geometry2D.get_closest_point_to_segment(wall_b, ea, eb).distance_to(wall_b) <= snap_dist:
				v2_on_boundary = true
			if v1_on_boundary and v2_on_boundary:
				break
		if not (v1_on_boundary and v2_on_boundary):
			continue

		var left_inside = _is_point_in_polygon(left_sample, area_polygon)
		var right_inside = _is_point_in_polygon(right_sample, area_polygon)

		var result = ""
		if left_inside and not right_inside:
			result = "inner-left"
		elif right_inside and not left_inside:
			result = "inner-right"
		else:
			continue

		# Deterministic: smallest area_id wins (handles shared walls between rooms)
		if best_result == "" or area_id < best_area_id:
			best_result = result
			best_area_id = area_id

	return best_result

# Ray-casting point-in-polygon (matches frontend isPointInPolygon)
func _is_point_in_polygon(point: Vector2, polygon: Array) -> bool:
	var inside = false
	var n = polygon.size()
	var j = n - 1
	for i in range(n):
		var xi = polygon[i].x; var yi = polygon[i].y
		var xj = polygon[j].x; var yj = polygon[j].y
		var intersect = ((yi > point.y) != (yj > point.y)) and \
			(point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi)
		if intersect:
			inside = not inside
		j = i
	return inside

# ─────────────────────────────────────────────────────────────────
# Wall face material resolver — mirrors image_glb_creation.gd
# Priority: asset_urls block → inner/outer_properties → cross-fallback → null
# ─────────────────────────────────────────────────────────────────
func _resolve_wall_face_material(line: Dictionary, face: String, wall_facing: String = "") -> Variant:
	var lookup_face = face
	# When a wall runs right-to-left, the authored face payloads are effectively
	# reversed relative to the rendered wall sides. Flip the lookup so the
	# room-facing side still receives the intended material.
	if wall_facing == "inner-left":
		lookup_face = "outer" if face == "inner" else "inner"
	var prop_key = lookup_face + "_properties"
	var other_face = "outer" if lookup_face == "inner" else "inner"
	var other_prop_key = other_face + "_properties"
	var has_face_material = false
	if line.has(prop_key) and typeof(line[prop_key]) == TYPE_DICTIONARY:
		var face_props = line[prop_key]
		has_face_material = face_props.has("material") and typeof(face_props["material"]) == TYPE_DICTIONARY
	if not has_face_material and line.has(other_prop_key) and typeof(line[other_prop_key]) == TYPE_DICTIONARY:
		var other_props = line[other_prop_key]
		has_face_material = other_props.has("material") and typeof(other_props["material"]) == TYPE_DICTIONARY

	# 1. asset_urls block
	if line.has("asset_urls") and typeof(line["asset_urls"]) == TYPE_DICTIONARY:
		var au = line["asset_urls"]
		if au.has(lookup_face) and typeof(au[lookup_face]) == TYPE_DICTIONARY:
			var block = au[lookup_face]
			var mat_data = {}

			if block.has("mapUrl") and block["mapUrl"] != null and str(block["mapUrl"]) != "":
				mat_data["mapUrl"] = block["mapUrl"]
			elif block.has("texture_urls") and typeof(block["texture_urls"]) == TYPE_ARRAY and block["texture_urls"].size() > 0:
				mat_data["mapUrl"] = block["texture_urls"][0]

			if block.has("normalUrl") and block["normalUrl"] != null and str(block["normalUrl"]) != "":
				mat_data["normalUrl"] = block["normalUrl"]

			if block.has("roughnessUrl") and block["roughnessUrl"] != null and str(block["roughnessUrl"]) != "":
				mat_data["roughnessUrl"] = block["roughnessUrl"]

			var fallback_color = block.get("fallback_color", "")
			if fallback_color == null or str(fallback_color).strip_edges() == "":
				fallback_color = ""
			if fallback_color != "":
				mat_data["color"] = str(fallback_color)

			if block.has("texture_scale_x") or block.has("texture_scale_y"):
				var sx = float(block.get("texture_scale_x", 1.0))
				var sy = float(block.get("texture_scale_y", 1.0))
				mat_data["scale"] = [sx if sx > 0 else 1.0, sy if sy > 0 else 1.0]
			elif block.has("repeat") and typeof(block["repeat"]) == TYPE_ARRAY:
				mat_data["repeat"] = block["repeat"]

			if mat_data.size() > 0:
				var has_texture = mat_data.has("mapUrl") or mat_data.has("normalUrl") or mat_data.has("roughnessUrl")
				var has_color = mat_data.has("color")
				if has_texture or (has_color and not has_face_material):
					return mat_data

	# 2. inner_properties / outer_properties
	if line.has(prop_key) and typeof(line[prop_key]) == TYPE_DICTIONARY:
		var props = line[prop_key]
		if props.has("material") and typeof(props["material"]) == TYPE_DICTIONARY:
			return props["material"]

	# 3. Cross-fallback
	if line.has(other_prop_key) and typeof(line[other_prop_key]) == TYPE_DICTIONARY:
		var props = line[other_prop_key]
		if props.has("material") and typeof(props["material"]) == TYPE_DICTIONARY:
			return props["material"]

	return null

# ─────────────────────────────────────────────────────────────────
# Core geometry builder — full parity with image_glb_creation.gd
# ─────────────────────────────────────────────────────────────────
# ==============================================================================
# CUSTOM SHAPES AND STRUCTURES
# ==============================================================================
# WHY IT EXISTS: Handles complex, non-standard geometry that isn't a basic wall. 
# This builds multi-level staircases, pillars, ramps, and custom-shaped walls 
# using Godot's CSG (Constructive Solid Geometry) to mathematically carve out 
# physical blocks.
# ==============================================================================
func build_structures(data):
	var layer_data = _arrays_to_dicts(data)

	if data.has("layers") and typeof(data["layers"]) == TYPE_DICTIONARY:
		var layers_dict = data["layers"]
		var show_all_floors = data.get("showAllFloors", true)
		var layer_ids = layers_dict.keys()

		if not show_all_floors:
			var primary_layer_id = _get_primary_layer_id(data, layers_dict)
			layer_ids = []
			if primary_layer_id != "":
				layer_ids.append(primary_layer_id)

		for layer_id in layer_ids:
			if not layers_dict.has(layer_id):
				continue
			var layer = layers_dict[layer_id]
			if typeof(layer) != TYPE_DICTIONARY:
				continue

			var layer_flat = _arrays_to_dicts(layer)
			if layer_flat.has("structures"):
				_load_layer_structures(layer_flat["structures"], _get_render_layer_altitude(layer, show_all_floors), str(layer_id))
	
	if layer_data.has("structures"):
		_load_layer_structures(layer_data["structures"], 0.0, "root")

func _load_layer_structures(structures, layer_altitude, layer_id := ""):
	for structure_id in structures:
		var structure
		if typeof(structures) == TYPE_DICTIONARY:
			structure = structures[structure_id]
		else:
			structure = structure_id
		if typeof(structure) != TYPE_DICTIONARY:
			continue
		if structure.has("visible") and structure["visible"] == false:
			continue
		_build_structure_mesh(structure, layer_altitude, layer_id)

func _build_structure_mesh(structure: Dictionary, layer_altitude: float, layer_id := "") -> void:
	var structure_type = str(structure.get("structure_type", structure.get("type", ""))).to_lower()
	if structure_type == "":
		return

	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var scale_factor = _scene_unit_scale
	var width = get_dimension_value(props.get("width", structure.get("width", 100))) * scale_factor
	var depth = get_dimension_value(props.get("depth", structure.get("depth", 100))) * scale_factor
	var height = get_dimension_value(props.get("height", structure.get("height", 100))) * scale_factor
	var altitude = get_dimension_value(props.get("altitude", structure.get("altitude", 0))) * scale_factor

	var root = Node3D.new()
	root.name = "Structure_%s_%s" % [structure_type, str(structure.get("id", "unknown"))]
	var root_xy = _plan_point_2d(float(structure.get("x", 0)), float(structure.get("y", 0)))
	root.position = Vector3(
		root_xy.x * scale_factor,
		layer_altitude + altitude,
		root_xy.y * scale_factor
	)

	var rot = 0.0
	if structure.has("rotation"):
		rot = float(structure["rotation"])
	elif props.has("rotation"):
		rot = float(props["rotation"])
	root.rotation.y = _world_yaw_from_source_rotation(rot)
	if structure.has("rotationX"):
		root.rotation.x = float(structure["rotationX"])
	if structure.has("rotationZ"):
		root.rotation.z = float(structure["rotationZ"])
	root.scale = Vector3(
		-1.0 if bool(structure.get("flipX", false)) else 1.0,
		1.0,
		-1.0 if bool(structure.get("flipZ", false)) else 1.0
	)
	add_child(root)

	var mat_data = structure_builder._resolve_structure_material(structure, structure_type)
	match structure_type:
		"partitionwall":
			structure_builder._add_partitionwall_structure(root, structure, width, depth, height, mat_data)
		"squarecolumn", "flue", "beam":
			structure_builder._add_box_structure(root, structure_type, width, depth, height, mat_data)
		"circlecolumn":
			structure_builder._add_cylinder_structure(root, width, depth, height, mat_data)
		"ramp":
			structure_builder._add_ramp_structure(root, width, depth, height, mat_data)
		"step":
			structure_builder._add_step_structure(root, structure, width, depth, height, mat_data)
		"falseceiling":
			structure_builder._add_false_ceiling_structure(root, structure, width, depth, height, mat_data)
		"staircase":
			structure_builder._add_staircase_structure(root, structure, width, depth, height, mat_data)
		"sunshade":
			structure_builder._add_sunshade_structure(root, structure, width, depth, height, mat_data)
		"niche":
			structure_builder._add_niche_structure(root, width, depth, height, mat_data)
		"baywindowsill":
			structure_builder._add_baywindowsill_structure(root, width, depth, mat_data)
		"flooropening":
			pass # handled by _add_floor_opening_cutters
		_:
			structure_builder._add_box_structure(root, structure_type, width, depth, height, mat_data)


func _build_layer_geometry(layer_data, layer_altitude, show_all_floors = true, cam_pos = null, render_mode: String = "INTERIOR"):
	var csg = CSGCombiner3D.new()
	csg.use_collision = true
	add_child(csg)

	var lines = layer_data["lines"]
	var vertices = layer_data["vertices"]
	var scale_factor = _scene_unit_scale # source units → metres

	var all_holes = {}
	if layer_data.has("holes"):
		all_holes = layer_data["holes"]

	var areas = {}
	if layer_data.has("areas"):
		areas = layer_data["areas"]

	var structures = {}
	if layer_data.has("structures") and typeof(layer_data["structures"]) == TYPE_DICTIONARY:
		structures = layer_data["structures"]

	# ── Room centroid (fallback for walls with no named area) ──────────────────
	var room_centroid = Vector3.ZERO
	var centroid_count = 0
	for area_id in areas:
		var area = areas[area_id]
		if not area.has("vertices"): continue
		for v_id in area["vertices"]:
			var vs = str(v_id)
			if vertices.has(vs):
				var v = vertices[vs]
				room_centroid += Vector3(float(v["x"]), 0.0, float(v["y"])) * scale_factor
				centroid_count += 1
	if centroid_count > 0:
		room_centroid /= centroid_count
	var has_centroid = centroid_count > 0

	print("[VideoGLB] Layer has ", lines.size(), " lines. Room centroid: ", room_centroid)

	# ── 1. Build Walls ─────────────────────────────────────────────────────────
	for line_id in lines:
		var line = lines[line_id]
		if line.has("visible") and line["visible"] == false: continue
		if not line.has("vertices") or line["vertices"].size() < 2: continue

		var wall_csg = CSGCombiner3D.new()
		wall_csg.name = "WallCSG_" + str(line_id)
		wall_csg.use_collision = true
		add_child(wall_csg)

		var v1_id = str(line["vertices"][0])
		var v2_id = str(line["vertices"][1])
		if not vertices.has(v1_id) or not vertices.has(v2_id): continue

		var v1_data = vertices[v1_id]
		var v2_data = vertices[v2_id]

		# ── Wall Alignment Offset ────────────────────────────────────────────────
		# Shift the base endpoints in 2D plan space (source units) BEFORE
		# converting to 3D so the wall aligns with the frontend's 2D editor.
		# Cascades automatically to center, diff, wall_angle, and all holes.
		var v1_x = float(v1_data["x"]); var v1_y = float(v1_data["y"])
		var v2_x = float(v2_data["x"]); var v2_y = float(v2_data["y"])

		var alignment = "center"
		if line.has("properties") and line["properties"].has("alignment"):
			alignment = str(line["properties"]["alignment"]).to_lower().strip_edges()

		# wall_thickness_val in source units (before * scale_factor)
		var wall_thickness_val = 20.0
		if line.has("properties") and line["properties"].has("thickness"):
			wall_thickness_val = get_dimension_value(line["properties"]["thickness"], 20.0)

		var dir_2d = (Vector2(v2_x, v2_y) - Vector2(v1_x, v1_y)).normalized()
		var left_normal_2d = Vector2(dir_2d.y, -dir_2d.x) # 90° CCW in frontend Y-down space
		var right_normal_2d = Vector2(-dir_2d.y, dir_2d.x) # 90° CW

		var align_offset_2d = Vector2.ZERO
		if alignment == "left":
			# Left edge on the line → bulk extrudes right → shift center rightward
			align_offset_2d = right_normal_2d * (wall_thickness_val / 2.0)
		elif alignment == "right":
			# Right edge on the line → bulk extrudes left → shift center leftward
			align_offset_2d = left_normal_2d * (wall_thickness_val / 2.0)

		var p1 = Vector3(v1_x + align_offset_2d.x, 0.0, v1_y + align_offset_2d.y) * scale_factor
		var p2 = Vector3(v2_x + align_offset_2d.x, 0.0, v2_y + align_offset_2d.y) * scale_factor

		var diff = p2 - p1
		var length = diff.length()
		var center = (p1 + p2) / 2.0
		var height = 240.0 * scale_factor # default

		if line.has("properties") and line["properties"].has("height"):
			var h_prop = line["properties"]["height"]
			if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
				height = float(h_prop["length"]) * scale_factor
			else:
				height = float(h_prop) * scale_factor

		var wall_thickness = 0.2
		if line.has("properties") and line["properties"].has("thickness"):
			var t_prop = line["properties"]["thickness"]
			wall_thickness = get_dimension_value(t_prop, 20.0) * scale_factor

		var wall_angle = - atan2(diff.z, diff.x)
		var wall_pos = Vector3(center.x, layer_altitude, center.z)

		# Keep a tiny seam gap so adjacent colored walls do not overlap.
		# This avoids visible color/texture blending at wall joins while
		# staying effectively invisible in the final render.
		var wall_join_gap = 0.001
		var corner_length = max(length - wall_join_gap, 0.05)

		# Generate dynamic polygon profile supporting peaked/sloped ceilings
		var half_l = corner_length / 2.0
		var poly_pts = PackedVector2Array()
		
		var custom_height = null
		if line.has("properties") and line["properties"].has("customHeight"):
			custom_height = line["properties"]["customHeight"]
			
		var max_h = height
		if typeof(custom_height) == TYPE_DICTIONARY and length > 0.001:
			var left_h = float(custom_height.get("left", height / scale_factor)) * scale_factor
			var right_h = float(custom_height.get("right", height / scale_factor)) * scale_factor
			var center_h = float(custom_height.get("center", height / scale_factor)) * scale_factor
			var center_x_ratio = 0.5
			if custom_height.has("centerX"):
				center_x_ratio = float(custom_height["centerX"]) * scale_factor / length
			center_x_ratio = clamp(center_x_ratio, 0.001, 0.999)
			
			var actual_center_x = - half_l + corner_length * center_x_ratio
			poly_pts.push_back(Vector2(-half_l, 0))
			poly_pts.push_back(Vector2(half_l, 0))
			poly_pts.push_back(Vector2(half_l, right_h))
			poly_pts.push_back(Vector2(actual_center_x, center_h))
			poly_pts.push_back(Vector2(-half_l, left_h))
			max_h = max(max(left_h, right_h), center_h)
		else:
			poly_pts.push_back(Vector2(-half_l, 0))
			poly_pts.push_back(Vector2(half_l, 0))
			poly_pts.push_back(Vector2(half_l, height))
			poly_pts.push_back(Vector2(-half_l, height))

		var poly_span = Vector2(corner_length, max_h)

		# ── Determine inner/outer facing (mirrors frontend exactly) ───────────
		var wall_facing = _get_wall_facing_direction(line, vertices, areas)

		var inner_sign = 1.0 # +1 → +Z is inner, -1 → -Z is inner
		if wall_facing == "inner-left":
			inner_sign = 1.0
		elif wall_facing == "inner-right":
			inner_sign = -1.0
		else:
			# No area polygon found — fall back to centroid dot-product
			var wall_basis = Basis(Vector3.UP, wall_angle)
			var wall_normal_world = wall_basis * Vector3(0, 0, 1)
			if has_centroid:
				var to_centroid = room_centroid - center
				to_centroid.y = 0.0
				if to_centroid.dot(wall_normal_world) < 0:
					inner_sign = -1.0
			wall_facing = "inner-left" if inner_sign > 0 else "inner-right"

		print("[VideoGLB] Wall ", line_id, " facing: ", wall_facing, " inner_sign: ", inner_sign)

		# ── Resolve inner/outer material data ─────────────────────────────────
		var inner_mat_data = _resolve_wall_face_material(line, "inner", wall_facing)
		var outer_mat_data = _resolve_wall_face_material(line, "outer", wall_facing)

		# ── Build structural CSGPolygon3D wall ─────────────────────────────────────
		var wall = CSGPolygon3D.new()
		wall.polygon = poly_pts
		wall.depth = wall_thickness
		wall.position = wall_pos + Basis(Vector3.UP, wall_angle) * Vector3(0, 0, wall_thickness / 2.0)
		wall.rotation.y = wall_angle

		var outer_mat: StandardMaterial3D
		if outer_mat_data != null:
			outer_mat = create_material(outer_mat_data)
		else:
			outer_mat = StandardMaterial3D.new()
			outer_mat.albedo_color = Color(0.82, 0.82, 0.82)

		var inner_mat_for_wall: StandardMaterial3D
		if inner_mat_data != null:
			inner_mat_for_wall = create_material(inner_mat_data)
		else:
			inner_mat_for_wall = StandardMaterial3D.new()
			inner_mat_for_wall.albedo_color = Color(0.82, 0.82, 0.82)

		if render_mode == "INTERIOR":
			# INTERIOR: camera is inside — structural wall uses inner material.
			# Prevents outer brick/stone textures from bleeding through.
			inner_mat_for_wall.cull_mode = BaseMaterial3D.CULL_DISABLED
			inner_mat_for_wall = _apply_architecture_texture_scale(
				inner_mat_for_wall,
				inner_mat_data,
				poly_span
			)
			wall.material = inner_mat_for_wall
		else:
			# EXTERIOR: camera is outside — structural wall uses outer material.
			outer_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			outer_mat = _apply_architecture_texture_scale(
				outer_mat,
				outer_mat_data,
				poly_span
			)
			wall.material = outer_mat

		wall_csg.add_child(wall)

		# ── Dual overlay panels (INTERIOR mode only) ───────────────────────────
		var inner_csg: CSGCombiner3D = null
		var outer_csg: CSGCombiner3D = null

		if render_mode == "INTERIOR":
			var face_t = 0.003 # 3 mm — clears Z-fighting at close range
			var wall_basis = Basis(Vector3.UP, wall_angle)

			# Inner overlay panel (room-facing side)
			if inner_mat_data != null:
				var inner_offset = wall_thickness / 2.0 + face_t / 2.0
				var inner_world = wall_pos + wall_basis * Vector3(0, 0, inner_offset * inner_sign)

				inner_csg = CSGCombiner3D.new()
				inner_csg.position = inner_world
				inner_csg.rotation.y = wall_angle
				add_child(inner_csg)

				var inner_box = CSGPolygon3D.new()
				inner_box.polygon = poly_pts
				inner_box.depth = face_t
				inner_box.position = Vector3(0, 0, face_t / 2.0)
				var inner_mat = create_material(inner_mat_data)
				inner_mat = _apply_architecture_texture_scale(
					inner_mat,
					inner_mat_data,
					poly_span
				)
				# CULL_DISABLED: panel must be visible from both sides so the wall
				# does not disappear when the camera steps just outside the room footprint.
				inner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				inner_box.material = inner_mat
				inner_csg.add_child(inner_box)

			# Outer overlay panel (exterior-facing side)
			if outer_mat_data != null:
				var outer_offset = wall_thickness / 2.0 + face_t / 2.0
				var outer_world = wall_pos + wall_basis * Vector3(0, 0, outer_offset * (-inner_sign))

				outer_csg = CSGCombiner3D.new()
				outer_csg.position = outer_world
				outer_csg.rotation.y = wall_angle
				add_child(outer_csg)

				var outer_box = CSGPolygon3D.new()
				outer_box.polygon = poly_pts
				outer_box.depth = face_t
				outer_box.position = Vector3(0, 0, face_t / 2.0)
				var outer_panel_mat = create_material(outer_mat_data)
				outer_panel_mat = _apply_architecture_texture_scale(
					outer_panel_mat,
					outer_mat_data,
					poly_span
				)
				# CULL_DISABLED: exterior panel must render from inside the room too.
				outer_panel_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				outer_box.material = outer_panel_mat
				outer_csg.add_child(outer_box)

		# ── Holes (Doors / Windows) ────────────────────────────────────────────
		if line.has("holes"):
			for hole_id in line["holes"]:
				var hid = str(hole_id)
				if not all_holes.has(hid): continue
				var hole = all_holes[hid]

				var h_width = get_dimension_value(hole.get("width", 0)) * scale_factor
				var h_height = get_dimension_value(hole.get("height", 0)) * scale_factor
				var h_alt = get_dimension_value(hole.get("altitude", 0)) * scale_factor

				if hole.has("properties"):
					var props = hole["properties"]
					if props.has("width"): h_width = get_dimension_value(props["width"]) * scale_factor
					if props.has("height"): h_height = get_dimension_value(props["height"]) * scale_factor
					if props.has("altitude"): h_alt = get_dimension_value(props["altitude"]) * scale_factor

				var offset_ratio = 0.5
				var raw_offset = 0.0
				if hole.has("offset"):
					raw_offset = float(hole["offset"])
				elif hole.has("properties") and hole["properties"].has("offset"):
					raw_offset = float(hole["properties"]["offset"])
				if raw_offset > 1.0:
					if length > 0.0001:
						# Convert absolute source units to metres, then to a wall ratio.
						offset_ratio = clamp((raw_offset * scale_factor) / length, 0.0, 1.0)
					else:
						offset_ratio = raw_offset
				else:
					offset_ratio = raw_offset

				var hole_pos_xz = p1.lerp(p2, offset_ratio)
				var h_center_pos = hole_pos_xz
				h_center_pos.y = layer_altitude + h_alt + h_height / 2.0

				if h_width < 0.01 or h_height < 0.01:
					continue

				# 1. Cut through structural wall
				var hole_csg = CSGBox3D.new()
				hole_csg.operation = CSGBox3D.OPERATION_SUBTRACTION
				hole_csg.size = Vector3(h_width, h_height, wall_thickness + 0.2)
				hole_csg.position = h_center_pos
				hole_csg.rotation.y = wall_angle
				wall_csg.add_child(hole_csg)

				# 2a. Cut through inner overlay panel
				if inner_csg != null:
					var inner_hole = CSGBox3D.new()
					inner_hole.operation = CSGBox3D.OPERATION_SUBTRACTION
					inner_hole.size = Vector3(h_width, h_height, 0.5)
					var delta_w = h_center_pos - inner_csg.position
					var local_pos = Basis(Vector3.UP, wall_angle).transposed() * delta_w
					inner_hole.position = local_pos
					inner_csg.add_child(inner_hole)

				# 2b. Cut through outer overlay panel
				if outer_csg != null:
					var outer_hole = CSGBox3D.new()
					outer_hole.operation = CSGBox3D.OPERATION_SUBTRACTION
					outer_hole.size = Vector3(h_width, h_height, 0.5)
					var delta_o = h_center_pos - outer_csg.position
					var local_pos_o = Basis(Vector3.UP, wall_angle).transposed() * delta_o
					outer_hole.position = local_pos_o
					outer_csg.add_child(outer_hole)

				# 3. Exterior black blocker
				if hole.get("is_exterior_black", false):
					var blocker = CSGBox3D.new()
					blocker.size = Vector3(h_width + 0.02, h_height + 0.02, 0.01)
					blocker.position = h_center_pos
					blocker.rotation.y = wall_angle
					var black_mat = StandardMaterial3D.new()
					black_mat.albedo_color = Color.BLACK
					blocker.material = black_mat
					add_child(blocker)

				# 4. Door / window GLB asset
				if hole.has("asset_urls"):
					var urls = hole["asset_urls"]
					var model_path = ""
					if urls.has("GLB_File_URL") and urls["GLB_File_URL"] != null:
						model_path = str(urls["GLB_File_URL"])
					elif urls.has("glb_Url") and urls["glb_Url"] != null:
						model_path = str(urls["glb_Url"])

					if model_path != "":
						if not FileAccess.file_exists(model_path):
							if FileAccess.file_exists("res://" + model_path): model_path = "res://" + model_path
							elif FileAccess.file_exists("./" + model_path): model_path = "./" + model_path

						if FileAccess.file_exists(model_path):
							var glTF = GLTFDocument.new()
							var glTFState = GLTFState.new()
							var error = glTF.append_from_file(model_path, glTFState)
							if error == OK:
								var asset_node = glTF.generate_scene(glTFState)
								if asset_node:
									add_child(asset_node)
									_sanitize_glb_lights(asset_node)

									var aabb = _get_hierarchy_aabb(asset_node)
									var dims = aabb.size
									if dims.x == 0: dims.x = 1.0
									if dims.y == 0: dims.y = 1.0
									if dims.z == 0: dims.z = 1.0

									var scale_x = h_width / dims.x
									var scale_y = h_height / dims.y
									var scale_z = wall_thickness / dims.z

									var bounds_y_min = aabb.position.y * scale_y

									asset_node.position = h_center_pos
									asset_node.position.y = (layer_altitude + h_alt) - bounds_y_min
									asset_node.rotation.y = wall_angle

									var flip_x = -1.0 if hole.get("flipX", false) else 1.0
									var flip_z = -1.0 if hole.get("flipZ", false) else 1.0
									asset_node.scale = Vector3(scale_x * flip_x, scale_y, scale_z * flip_z)

									# Smart shadow control: frame/mullion meshes keep shadows ON
									# (cast grid pattern), glass panes get shadows OFF.
									_apply_item_materials(asset_node, hole)
									_fix_glass_materials_for_shadows(asset_node)
									print("[VideoGLB] Loaded hole asset: ", model_path, " scale: ", asset_node.scale, " (shadows: handled by material)")

									# Keep the actual window GLB only.
									# The procedural grid fallback can add visible extra bars
									# around windows, so it stays opt-in.
									var frame_casters := _count_shadow_casters(asset_node)
									if ENABLE_PROCEDURAL_WINDOW_GRID_CASTER and frame_casters == 0 and h_alt > 0.15:
										var wall_basis_g = Basis(Vector3.UP, wall_angle)
										var outer_dir_g = wall_basis_g * Vector3(0, 0, 1) * (-inner_sign)
										_add_window_grid_shadow_caster(
											h_center_pos, h_width, h_height,
											wall_angle, outer_dir_g, layer_altitude
										)
										print("[VideoGLB]   GLB had no frame casters — added procedural grid")
							else:
								print("[VideoGLB] Failed to load hole GLTF: ", model_path, " Error: ", error)

						_tracked_assets.append({
							"type": "hole_asset",
							"id": hole.get("id", "unknown"),
							"name": hole.get("name", "unknown"),
							"path": model_path
						})

				# -- 5. Determine hole type for light collection --------
				var hole_type_sun := str(hole.get("type", "")).to_lower()
				var hole_name_sun := str(hole.get("name", "")).to_lower()
				var is_window_for_sun := hole_type_sun == "window" or "window" in hole_name_sun

				# Glass detection for door fill lights
				var hole_has_glass := false
				if not is_window_for_sun and hole.has("asset_urls"):
					# Check if the loaded asset contains glass meshes
					for child in get_children():
						if child.name.begins_with("WindowPortalSpot_") or child.name.begins_with("DoorFillSpot_"):
							continue
						# asset_node was already added as child above
					pass

				# Collect WINDOW openings for window portal lights
				if is_window_for_sun:
					var wall_basis_sun = Basis(Vector3.UP, wall_angle)
					var wall_normal_sun = wall_basis_sun * Vector3(0, 0, 1)
					var outer_direction = wall_normal_sun * (-inner_sign)
					var inner_direction = wall_normal_sun * inner_sign
					_window_sunlight_data.append({
						"center": h_center_pos,
						"width": h_width,
						"height": h_height,
						"altitude": h_alt,
						"wall_angle": wall_angle,
						"outer_dir": outer_direction,
						"inner_dir": inner_direction,
						"layer_altitude": layer_altitude
					})
					print("[VideoGLB] Collected WINDOW opening for sunlight: pos=", h_center_pos, " size=", Vector2(h_width, h_height), " alt=", h_alt)
				else:
					# Non-window hole (door, opening, etc.) — collect for door fill SpotLight
					var wall_basis_d = Basis(Vector3.UP, wall_angle)
					var wall_normal_d = wall_basis_d * Vector3(0, 0, 1)
					_door_hole_data.append({
						"center": h_center_pos,
						"width": h_width,
						"height": h_height,
						"inner_dir": wall_normal_d * inner_sign,
						"hole_type": hole_type_sun,
						"has_glass": hole_has_glass
					})
					print("[VideoGLB] Collected non-window opening (", hole_type_sun, ") for door fill light: ", hole_name_sun)

		# ── 6. Add Wall Shapes (CustomShapes) ──────────────────────────────────
		# Build hole rects in wall-local 2D: X=along-wall from p1, Y=height from floor.
		var wall_local_hole_rects: Array = []
		if line.has("holes"):
			for hole_id in line["holes"]:
				var hid = str(hole_id)
				if not all_holes.has(hid): continue
				var hole = all_holes[hid]
				var hw = get_dimension_value(hole.get("width", 0)) * scale_factor
				var hh = get_dimension_value(hole.get("height", 0)) * scale_factor
				var ha = get_dimension_value(hole.get("altitude", 0)) * scale_factor
				if hole.has("properties"):
					var props = hole["properties"]
					if props.has("width"): hw = get_dimension_value(props["width"]) * scale_factor
					if props.has("height"): hh = get_dimension_value(props["height"]) * scale_factor
					if props.has("altitude"): ha = get_dimension_value(props["altitude"]) * scale_factor
				if hw < 0.01 or hh < 0.01: continue
				var raw_off = 0.0
				if hole.has("offset"): raw_off = float(hole["offset"])
				elif hole.has("properties") and hole["properties"].has("offset"):
					raw_off = float(hole["properties"]["offset"])
				var off_ratio = raw_off
				if raw_off > 1.0:
					var wl = p1.distance_to(p2)
					if wl > 0.0001:
						off_ratio = clamp((raw_off * scale_factor) / wl, 0.0, 1.0)
				var h_cx_along = off_ratio * length
				var hole_rect = PackedVector2Array()
				hole_rect.append(Vector2(h_cx_along - hw * 0.5, ha))
				hole_rect.append(Vector2(h_cx_along + hw * 0.5, ha))
				hole_rect.append(Vector2(h_cx_along + hw * 0.5, ha + hh))
				hole_rect.append(Vector2(h_cx_along - hw * 0.5, ha + hh))
				wall_local_hole_rects.append(hole_rect)

		var faces_to_check = []
		var inner_props_key = "outer_properties" if wall_facing == "inner-left" else "inner_properties"
		var outer_props_key = "inner_properties" if wall_facing == "inner-left" else "outer_properties"

		if line.has(inner_props_key) and line[inner_props_key].has("customShapes"):
			faces_to_check.append({"shapes": line[inner_props_key]["customShapes"], "side": inner_sign})
		if line.has(outer_props_key) and line[outer_props_key].has("customShapes"):
			faces_to_check.append({"shapes": line[outer_props_key]["customShapes"], "side": - inner_sign})
			
		for face_data in faces_to_check:
			var shapes_arr = face_data["shapes"]
			var side_sign = face_data["side"]
			
			for shape_idx in range(shapes_arr.size()):
				var shape = shapes_arr[shape_idx]
				if not shape.has("points") or typeof(shape["points"]) != TYPE_ARRAY or shape["points"].size() < 3:
					continue
					
				var shape_poly_pts = PackedVector2Array()
				var min_x = 999999.0; var max_x = -999999.0
				var min_y = 999999.0; var max_y = -999999.0
				
				for pt in shape["points"]:
					var px = float(pt.get("x", 0)) * scale_factor
					if side_sign < 0:
						px = length - px
					# Frontend Y=0 is ceiling, Y=height is floor. Godot Y=0 is floor.
					var py = height - (float(pt.get("y", 0)) * scale_factor)
					shape_poly_pts.append(Vector2(px, py))
					
					if px < min_x: min_x = px
					if px > max_x: max_x = px
					if py < min_y: min_y = py
					if py > max_y: max_y = py
					
				# Enforce CCW winding for CSGPolygon3D to avoid normal flipping
				var signed_area = 0.0
				for pi in range(shape_poly_pts.size()):
					var pa = shape_poly_pts[pi]
					var pb = shape_poly_pts[(pi + 1) % shape_poly_pts.size()]
					signed_area += (pa.x * pb.y - pb.x * pa.y)
				if signed_area < 0:
					shape_poly_pts.reverse()

				# ── Clip hole areas out of this shape ─────────────────────────────
				var clipped_fragments: Array = [shape_poly_pts]
				for hole_rect in wall_local_hole_rects:
					var next_fragments: Array = []
					for frag in clipped_fragments:
						var remaining = Geometry2D.clip_polygons(frag, hole_rect)
						if remaining.is_empty():
							pass
						else:
							for r in remaining:
								if r.size() >= 3:
									next_fragments.append(r)
					clipped_fragments = next_fragments
					if clipped_fragments.is_empty():
						break

				if clipped_fragments.is_empty():
					print("[VideoGLB] customShape fully clipped by holes — skipped")
					continue

				# ── Step 1: Detect createOpening flag ─────────────────────────────
				var is_opening = false
				if shape.has("createOpening"):
					var val = shape["createOpening"]
					if typeof(val) == TYPE_BOOL:
						is_opening = val
					else:
						is_opening = (str(val).to_lower() == "true")

				var shape_poly_span = Vector2(max_x - min_x, max_y - min_y)
				var s_basis = Basis(Vector3.UP, wall_angle)
				var local_z = s_basis * Vector3(0, 0, 1)
				var offset_amt = 0.001 * shape_idx

				var frag_idx = 0
				for frag_poly in clipped_fragments:
					var poly = CSGPolygon3D.new()
					poly.polygon = frag_poly
					var shape_depth = 0.02
					if shape.has("thickness"):
						shape_depth = get_dimension_value(shape["thickness"], 20.0) * scale_factor
					
					# ── Step 2: Override depth + operation for openings ─────────
					if is_opening:
						shape_depth = wall_thickness + 0.2
						poly.operation = CSGShape3D.OPERATION_SUBTRACTION
					poly.depth = shape_depth
					
					if shape.has("material") and not is_opening:
						var smat = create_material(shape["material"])
						smat = _apply_architecture_texture_scale(smat, shape["material"], shape_poly_span)
						poly.material = smat
					else:
						if not is_opening:
							var smat = StandardMaterial3D.new()
							smat.albedo_color = Color(1, 1, 1)
							poly.material = smat
					
					# ── Step 3: Position — opening centres on wall; surface shape sits on face ──
					var s_pos = p1
					s_pos.y = layer_altitude
					if is_opening:
						# Forward offset so CSGPolygon3D (extrudes 0→-depth) spans wall centre
						s_pos += local_z * (shape_depth / 2.0)
					else:
						if side_sign > 0:
							s_pos += local_z * (wall_thickness / 2.0 + shape_depth + offset_amt)
						else:
							s_pos += local_z * (-wall_thickness / 2.0 - shape_depth - offset_amt)
					
					poly.position = s_pos
					poly.basis = s_basis
					# Opening: must be a CSG child of wall_csg to subtract from the structural wall.
					# Surface shapes go to the scene root as visual overlays.
					if is_opening:
						wall_csg.add_child(poly)
					else:
						add_child(poly)
					
					# ── Step 4: Cut same hole into inner_csg and outer_csg layers ───
					# Use FRESH instances (not .duplicate()) to avoid cached-geometry artefacts.
					if is_opening:
						if inner_csg != null:
							var inner_hole = CSGPolygon3D.new()
							inner_hole.polygon = frag_poly
							inner_hole.depth = shape_depth
							inner_hole.operation = CSGShape3D.OPERATION_SUBTRACTION
							var delta = poly.position - inner_csg.position
							inner_hole.position = delta.rotated(Vector3.UP, -wall_angle)
							inner_hole.basis = Basis()
							inner_csg.add_child(inner_hole)
						if outer_csg != null:
							var outer_hole = CSGPolygon3D.new()
							outer_hole.polygon = frag_poly
							outer_hole.depth = shape_depth
							outer_hole.operation = CSGShape3D.OPERATION_SUBTRACTION
							var delta_o = poly.position - outer_csg.position
							outer_hole.position = delta_o.rotated(Vector3.UP, -wall_angle)
							outer_hole.basis = Basis()
							outer_csg.add_child(outer_hole)
					
					frag_idx += 1

				print("[VideoGLB] Added custom shape on wall ", line_id, " side ", side_sign, " is_opening=", is_opening, " fragments=", frag_idx)

	# ── 2. Build Floors and Ceilings from Areas ────────────────────────────────
	# max_wall_height: include ALL walls (visible and invisible) so invisible
	# structural dividers contribute correctly to the layer's ceiling height.
	var max_wall_height = 0.0
	var max_wall_thickness = 0.2 * scale_factor
	for lid in lines:
		var l = lines[lid]
		if l.has("properties") and l["properties"].has("height"):
			var h_prop = l["properties"]["height"]
			var wh = 0.0
			if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
				wh = float(h_prop["length"]) * scale_factor
			else:
				wh = float(h_prop) * scale_factor
			if wh > max_wall_height:
				max_wall_height = wh
		if l.has("properties") and l["properties"].has("thickness"):
			var wt = get_dimension_value(l["properties"]["thickness"], 20.0) * scale_factor
			if wt > max_wall_thickness:
				max_wall_thickness = wt
	if max_wall_height < 0.1:
		max_wall_height = 280.0 * scale_factor

	# ── External Areas ──────────────────────────────────────────────────────────
	if layer_data.has("externalAreas") and typeof(layer_data["externalAreas"]) == TYPE_DICTIONARY:
		print("[VideoGLB] Building Floors for ", layer_data["externalAreas"].size(), " external areas.")
		for area_id in layer_data["externalAreas"]:
			var area = layer_data["externalAreas"][area_id]
			if typeof(area) != TYPE_DICTIONARY or not area.has("vertices") or area["vertices"].size() < 3:
				continue
			var polygon = PackedVector2Array()
			for v_id in area["vertices"]:
				var vs = str(v_id)
				if vertices.has(vs):
					polygon.append(Vector2(float(vertices[vs]["x"]) * scale_factor, float(vertices[vs]["y"]) * scale_factor))
			if polygon.size() < 3: continue
			
			var signed_area = 0.0
			for pi in range(polygon.size()):
				var pa = polygon[pi]; var pb = polygon[(pi + 1) % polygon.size()]
				signed_area += (pa.x * pb.y - pb.x * pa.y)
			signed_area *= 0.5
			if signed_area < 0: polygon.reverse()
			
			var floor_depth = 0.1
			if area.has("properties") and typeof(area["properties"]) == TYPE_DICTIONARY and area["properties"].has("thickness"):
				var t = float(area["properties"]["thickness"]) * scale_factor
				if t > 0.001: floor_depth = t
				
			var floor_poly = CSGPolygon3D.new()
			floor_poly.polygon = polygon
			floor_poly.mode = CSGPolygon3D.MODE_DEPTH
			floor_poly.depth = floor_depth
			floor_poly.rotation.x = PI / 2
			# Push external areas below the main floor by their full depth + a margin to avoid Z-fighting
			floor_poly.position.y = layer_altitude - floor_depth - 0.01
			
			var floor_span = _get_polygon_world_span(polygon)
			if area.has("material") and typeof(area["material"]) == TYPE_DICTIONARY:
				var f_mat = create_material(area["material"])
				f_mat = _apply_architecture_texture_scale(f_mat, area["material"], floor_span)
				floor_poly.material = f_mat
			else:
				var floor_mat = StandardMaterial3D.new()
				floor_mat.albedo_color = Color(0.3, 0.6, 0.3)
				floor_poly.material = floor_mat
				
			var floor_csg = CSGCombiner3D.new()
			floor_csg.name = "ExternalAreaCSG_" + str(area_id)
			floor_csg.use_collision = true
			add_child(floor_csg)
			floor_csg.add_child(floor_poly)

	if layer_data.has("areas"):
		print("[VideoGLB] Building Floors/Ceilings for ", layer_data["areas"].size(), " areas.")
		for area_id in layer_data["areas"]:
			var area = layer_data["areas"][area_id]
			if not area.has("vertices") or area["vertices"].size() < 3:
				continue

			var polygon = PackedVector2Array()
			for v_id in area["vertices"]:
				var vs = str(v_id)
				if vertices.has(vs):
					var v = vertices[vs]
					polygon.append(Vector2(float(v["x"]) * scale_factor, float(v["y"]) * scale_factor))

			if polygon.size() < 3:
				continue

			# Enforce CCW winding (required by CSGPolygon3D)
			var signed_area = 0.0
			for pi in range(polygon.size()):
				var pa = polygon[pi]
				var pb = polygon[(pi + 1) % polygon.size()]
				signed_area += (pa.x * pb.y - pb.x * pa.y)
			signed_area *= 0.5
			if signed_area < 0:
				polygon.reverse()

			var uv_polygon = polygon.duplicate()
			# Expand polygon outward to fill wall-thickness gaps at edges
			polygon = _expand_polygon_outward(polygon, max_wall_thickness / 2.0)

			# ── Floor ──────────────────────────────────────────────────────────
			var floor_depth = 0.1
			if area.has("floor_properties") and typeof(area["floor_properties"]) == TYPE_DICTIONARY:
				var fp2 = area["floor_properties"]
				if fp2.has("thickness"):
					var t = float(fp2["thickness"]) * scale_factor
					if t > 0.001: floor_depth = t

			var floor_poly = CSGPolygon3D.new()
			floor_poly.polygon = polygon
			floor_poly.mode = CSGPolygon3D.MODE_DEPTH
			floor_poly.depth = floor_depth
			floor_poly.rotation.x = PI / 2
			floor_poly.position.y = layer_altitude
			# Use the expanded polygon span because CSGPolygon3D normalises
			# its UVs to [0,1] over the expanded bounding box, not the
			# original one.  Measuring from the smaller original polygon
			# caused every tile to appear ~3-4 % oversized.
			var floor_span = _get_polygon_world_span(polygon)

			if area.has("floor_properties") and typeof(area["floor_properties"]) == TYPE_DICTIONARY and area["floor_properties"].has("material"):
				var f_mat = create_material(area["floor_properties"]["material"])
				f_mat = _apply_architecture_texture_scale(
					f_mat,
					area["floor_properties"]["material"],
					floor_span
				)
				floor_poly.material = f_mat
			else:
				var floor_mat = StandardMaterial3D.new()
				floor_mat.albedo_color = Color(0.8, 0.8, 0.8)
				floor_poly.material = floor_mat

			var floor_csg = CSGCombiner3D.new()
			floor_csg.name = "FloorCSG_" + str(area_id)
			floor_csg.use_collision = true
			add_child(floor_csg)

			structure_builder._add_floor_opening_cutters(floor_csg, structures, str(area_id), layer_altitude, floor_depth, scale_factor)
			floor_csg.add_child(floor_poly)

			# ── Paving Pattern Overlay ─────────────────────────────────────────
			# When the frontend has set floor_properties.paving (pattern != 'none')
			# we generate per-tile CSGPolygon3D slabs clipped to the room polygon,
			# sitting 2 mm above the base floor slab so they always win z-fighting.
			if area.has("floor_properties") and typeof(area["floor_properties"]) == TYPE_DICTIONARY:
				var floor_props = area["floor_properties"]
				if floor_props.has("paving") and typeof(floor_props["paving"]) == TYPE_DICTIONARY:
					var pav = floor_props["paving"]
					var pav_pattern = str(pav.get("pattern", "none")).strip_edges().to_lower()
					if pav_pattern != "none" and pav_pattern != "":
						var pav_material_data = floor_props.get("material", {})
						_build_paving_overlay(
							str(area_id),
							pav_pattern,
							pav,
							uv_polygon,
							layer_altitude,
							floor_span,
							pav_material_data
						)
						print("[Paving] Applied pattern '", pav_pattern, "' to area ", area_id)

			if area.has("floor_properties") and typeof(area["floor_properties"]) == TYPE_DICTIONARY and area["floor_properties"].has("customShapes"):
				for shape_idx in range(area["floor_properties"]["customShapes"].size()):
					var shape = area["floor_properties"]["customShapes"][shape_idx]
					if not shape.has("points") or typeof(shape["points"]) != TYPE_ARRAY or shape["points"].size() < 3: continue
					var shape_pts = PackedVector2Array()
					var min_x = 999999.0; var max_x = -999999.0
					var min_y = 999999.0; var max_y = -999999.0
					for pt in shape["points"]:
						var p = _plan_point_2d(float(pt.get("x", 0)), float(pt.get("y", 0)))
						var scaled_p = p * scale_factor
						shape_pts.append(scaled_p)
						if scaled_p.x < min_x: min_x = scaled_p.x
						if scaled_p.x > max_x: max_x = scaled_p.x
						if scaled_p.y < min_y: min_y = scaled_p.y
						if scaled_p.y > max_y: max_y = scaled_p.y
					var shape_signed_area = 0.0
					for pi in range(shape_pts.size()):
						var pa = shape_pts[pi]
						var pb = shape_pts[(pi + 1) % shape_pts.size()]
						shape_signed_area += (pa.x * pb.y - pb.x * pa.y)
					if shape_signed_area < 0: shape_pts.reverse()
					var s_poly = CSGPolygon3D.new()
					s_poly.polygon = shape_pts
					s_poly.mode = CSGPolygon3D.MODE_DEPTH
					var shape_depth = 0.010
					if shape.has("thickness"):
						shape_depth = get_dimension_value(shape["thickness"], 10.0) * scale_factor
					s_poly.depth = shape_depth
					s_poly.rotation.x = PI / 2
					# Sit 5 mm above floor base (avoids z-fighting with paving)
					s_poly.position.y = layer_altitude + 0.005 + 0.001 * shape_idx
					if shape.has("material"):
						var smat = create_material(shape["material"])
						var span = Vector2(max_x - min_x, max_y - min_y)
						smat = _apply_architecture_texture_scale(smat, shape["material"], span)
						s_poly.material = smat
					add_child(s_poly)

			# ── Ceiling ────────────────────────────────────────────────────────
			var ceil_height = max_wall_height

			if area.has("properties") and typeof(area["properties"]) == TYPE_DICTIONARY:
				var h_prop = area["properties"].get("height", null)
				if h_prop != null:
					var h_val = 0.0
					if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
						h_val = float(h_prop["length"]) * scale_factor
					elif typeof(h_prop) == TYPE_INT or typeof(h_prop) == TYPE_FLOAT:
						h_val = float(h_prop) * scale_factor
					if h_val >= 1.5:
						# 1.5 m safety threshold: ignore sub-1.5 m values (curbs, outdoor
						# half-walls, or typos like 300 mm) to prevent ceiling collapse.
						ceil_height = min(h_val, max_wall_height)

			if ceil_height == max_wall_height and area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY:
				var cp = area["ceiling_properties"]
				if cp.has("height"):
					var ch_val = 0.0
					if typeof(cp["height"]) == TYPE_DICTIONARY and cp["height"].has("length"):
						ch_val = float(cp["height"]["length"]) * scale_factor
					elif typeof(cp["height"]) == TYPE_INT or typeof(cp["height"]) == TYPE_FLOAT:
						ch_val = float(cp["height"]) * scale_factor
					elif typeof(cp["height"]) == TYPE_STRING and cp["height"].is_valid_float():
						ch_val = float(cp["height"]) * scale_factor
					if ch_val >= 1.5:
						# 1.5 m safety threshold
						ceil_height = min(ch_val, max_wall_height)

			if ceil_height < 0.1:
				ceil_height = max_wall_height

			var ceil_depth = 0.1
			if area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY:
				var cp = area["ceiling_properties"]
				if cp.has("thickness"):
					var t = float(cp["thickness"]) * scale_factor
					if t > 0.001: ceil_depth = t
			if ceil_depth < 0.05:
				ceil_depth = 0.05

			var ceil_poly = CSGPolygon3D.new()
			ceil_poly.polygon = polygon
			ceil_poly.mode = CSGPolygon3D.MODE_DEPTH
			ceil_poly.depth = ceil_depth
			ceil_poly.rotation.x = PI / 2
			ceil_poly.position.y = layer_altitude + ceil_height - ceil_depth
			# Match floor: use expanded polygon span for UV accuracy.
			var ceil_span = _get_polygon_world_span(polygon)

			if area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY and area["ceiling_properties"].has("material"):
				var c_mat = create_material(area["ceiling_properties"]["material"])
				c_mat = _apply_architecture_texture_scale(
					c_mat,
					area["ceiling_properties"]["material"],
					ceil_span
				)
				ceil_poly.material = c_mat
			else:
				var ceil_mat = StandardMaterial3D.new()
				ceil_mat.albedo_color = Color(0.95, 0.95, 0.95)
				ceil_poly.material = ceil_mat

			# Ceiling visibility gate
			var has_visibility_prop = false
			var ceil_is_visible = true
			
			if area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY:
				var cp = area["ceiling_properties"]
				has_visibility_prop = cp.has("visible") or cp.has("isvisible") or cp.has("isVisible")
				if has_visibility_prop:
					if cp.has("visible"): ceil_is_visible = bool(cp["visible"])
					elif cp.has("isvisible"): ceil_is_visible = bool(cp["isvisible"])
					else: ceil_is_visible = bool(cp["isVisible"])
			
			if not has_visibility_prop:
				ceil_is_visible = show_all_floors
			
			print("[VideoGLB] Ceiling visible: ", ceil_is_visible, " | showAllFloors: ", show_all_floors, " | has_prop: ", has_visibility_prop)

			var is_visible = ceil_is_visible
			
			# EXTRA EXCEPTION: Hide ceiling if camera is ABOVE it (e.g. for top-down renders)
			# ONLY apply if we don't have an explicit visibility property.
			if is_visible and cam_pos != null and not has_visibility_prop:
				var ceiling_world_y = layer_altitude + ceil_height
				if cam_pos.y > (ceiling_world_y + 0.1): # Tiny margin
					is_visible = false
					print("[VideoGLB] Hiding Ceiling automatically: Camera height (", cam_pos.y, ") is above ceiling Y (", ceiling_world_y, ")")
			
			# Portal-based fallback for show_all_floors=false
			# Only fallback if we don't have an explicit property.
			if not is_visible and not show_all_floors and cam_pos != null and not has_visibility_prop:
				if _camera_requires_ceiling(cam_pos, layer_altitude, ceil_height, polygon):
					is_visible = true

			if not is_visible:
				continue

			var ceil_csg = CSGCombiner3D.new()
			ceil_csg.name = "CeilingCSG_" + str(area_id)
			ceil_csg.use_collision = true
			add_child(ceil_csg)
			ceil_csg.add_child(ceil_poly)
			
			if area.has("ceiling_properties") and typeof(area["ceiling_properties"]) == TYPE_DICTIONARY and area["ceiling_properties"].has("customShapes"):
				for shape_idx in range(area["ceiling_properties"]["customShapes"].size()):
					var shape = area["ceiling_properties"]["customShapes"][shape_idx]
					if not shape.has("points") or typeof(shape["points"]) != TYPE_ARRAY or shape["points"].size() < 3: continue
					var shape_pts = PackedVector2Array()
					var min_x = 999999.0; var max_x = -999999.0
					var min_y = 999999.0; var max_y = -999999.0
					for pt in shape["points"]:
						var p = _plan_point_2d(float(pt.get("x", 0)), float(pt.get("y", 0)))
						var scaled_p = p * scale_factor
						shape_pts.append(scaled_p)
						if scaled_p.x < min_x: min_x = scaled_p.x
						if scaled_p.x > max_x: max_x = scaled_p.x
						if scaled_p.y < min_y: min_y = scaled_p.y
						if scaled_p.y > max_y: max_y = scaled_p.y
					var shape_signed_area = 0.0
					for pi in range(shape_pts.size()):
						var pa = shape_pts[pi]
						var pb = shape_pts[(pi + 1) % shape_pts.size()]
						shape_signed_area += (pa.x * pb.y - pb.x * pa.y)
					if shape_signed_area > 0: shape_pts.reverse()
					var s_poly = CSGPolygon3D.new()
					s_poly.polygon = shape_pts
					s_poly.mode = CSGPolygon3D.MODE_DEPTH
					var shape_depth = 0.005
					if shape.has("thickness"):
						shape_depth = get_dimension_value(shape["thickness"], 5.0) * scale_factor
					# Extend depth by 10mm to ensure it connects to the ceiling
					s_poly.depth = shape_depth + 0.010
					s_poly.rotation.x = PI / 2
					# Top of the shape anchors to bottom of the ceiling, dropping down by shape_depth
					s_poly.position.y = (layer_altitude + ceil_height - ceil_depth) - shape_depth - 0.001 * shape_idx
					if shape.has("material"):
						var smat = create_material(shape["material"])
						var span = Vector2(max_x - min_x, max_y - min_y)
						smat = _apply_architecture_texture_scale(smat, shape["material"], span)
						s_poly.material = smat
					add_child(s_poly)
			print("[VideoGLB] Floor/Ceiling area: ", area_id, " ceil_h=", ceil_height, " floor_depth=", floor_depth)

# ─────────────────────────────────────────────────────────────────
# Polygon helpers (ported from image_glb_creation.gd)
# ─────────────────────────────────────────────────────────────────
func _expand_polygon_outward(polygon: PackedVector2Array, offset: float) -> PackedVector2Array:
	var n = polygon.size()
	if n < 3 or offset < 0.0001:
		return polygon

	var expanded = PackedVector2Array()
	for i in range(n):
		var prev_pt = polygon[(i - 1 + n) % n]
		var curr_pt = polygon[i]
		var next_pt = polygon[(i + 1) % n]

		var e1 = curr_pt - prev_pt
		var e2 = next_pt - curr_pt

		var n1 = Vector2(e1.y, -e1.x).normalized()
		var n2 = Vector2(e2.y, -e2.x).normalized()

		var bisector = (n1 + n2)
		if bisector.length() < 0.0001:
			bisector = n1
		else:
			bisector = bisector.normalized()

		var cos_half = n1.dot(bisector)
		if abs(cos_half) < 0.1:
			cos_half = 0.1

		var move_dist = offset / cos_half
		expanded.append(curr_pt + bisector * move_dist)

	return expanded

# Returns the world-space span (width, depth) of a polygon in metres.
# CSGPolygon3D normalises UVs to [0,1] and does NOT expose a uv_xform
# property, so texture tiling must be controlled through the material's
# uv1_scale instead.  The caller multiplies uv1_scale by this span so
# that the JSON repeat values tile per metre, not per polygon.
func _get_polygon_world_span(polygon: PackedVector2Array) -> Vector2:
	if polygon.size() < 3:
		return Vector2(1.0, 1.0)

	var min_x = 1e20; var max_x = -1e20
	var min_y = 1e20; var max_y = -1e20
	for p in polygon:
		min_x = min(min_x, p.x); max_x = max(max_x, p.x)
		min_y = min(min_y, p.y); max_y = max(max_y, p.y)

	return Vector2(max(0.001, max_x - min_x), max(0.001, max_y - min_y))

func _apply_architecture_texture_scale(mat: StandardMaterial3D, mat_data: Dictionary, surface_size: Vector2) -> StandardMaterial3D:
	if mat == null or typeof(mat_data) != TYPE_DICTIONARY:
		return mat

	var width = max(surface_size.x, 0.001)
	var height = max(surface_size.y, 0.001)
	var scale_u = 1.0
	var scale_v = 1.0

	var tile_u = 0.0
	var tile_v = 0.0
	if mat_data.has("repeatX"):
		tile_u = float(mat_data.get("repeatX", 0.0))
	elif mat_data.has("texture_scale_x"):
		tile_u = float(mat_data.get("texture_scale_x", 0.0))
	if mat_data.has("repeatY"):
		tile_v = float(mat_data.get("repeatY", 0.0))
	elif mat_data.has("texture_scale_y"):
		tile_v = float(mat_data.get("texture_scale_y", 0.0))

	var has_physical_repeat = false
	if tile_u > 0.0 and tile_v > 0.0:
		scale_u = width / max(tile_u * _scene_unit_scale, 0.000001)
		scale_v = height / max(tile_v * _scene_unit_scale, 0.000001)
		has_physical_repeat = true
	if has_physical_repeat:
		# Apply density boost — multiplying UV scale makes tiles appear smaller.
		mat.uv1_scale = Vector3(scale_u * FLOOR_CEIL_TEXTURE_DENSITY_BOOST,
								scale_v * FLOOR_CEIL_TEXTURE_DENSITY_BOOST, 1.0)
		return mat

	if mat_data.has("repeat"):
		var r = mat_data["repeat"]
		if typeof(r) == TYPE_ARRAY and r.size() >= 2:
			var repeat_u = float(r[0])
			var repeat_v = float(r[1])
			if repeat_u > 0.0:
				scale_u = repeat_u * width / 2.4
			if repeat_v > 0.0:
				scale_v = repeat_v * height / 2.4
			if repeat_u > 0.0 or repeat_v > 0.0:
				# Apply density boost to legacy repeat path too.
				mat.uv1_scale = Vector3(scale_u * FLOOR_CEIL_TEXTURE_DENSITY_BOOST,
									scale_v * FLOOR_CEIL_TEXTURE_DENSITY_BOOST, 1.0)
				return mat

	return mat

# ─────────────────────────────────────────────────────────────────
# Asset loading — mirrors image_glb_creation.gd load_assets / _load_layer_items
# ─────────────────────────────────────────────────────────────────
# ==============================================================================
# ASSET LOADING AND PLACEMENT
# ==============================================================================
# WHY IT EXISTS: To read the items array from the JSON layout, dynamically 
# download the 3D GLB models for furniture, appliances, and decorations, and 
# place them at exact coordinates inside the 3D rooms.
# ==============================================================================
func load_assets(data):
	var layer_map = _get_floor_plan_layer_map(data)
	if layer_map.size() > 0:
		var show_all_floors = data.get("showAllFloors", true)
		var layer_ids = layer_map.keys()
		if not show_all_floors:
			var primary_layer_id = _get_primary_layer_id(data, layer_map)
			layer_ids = []
			if primary_layer_id != "":
				layer_ids.append(primary_layer_id)

		for layer_id in layer_ids:
			if not layer_map.has(layer_id):
				continue
			var layer = layer_map[layer_id]
			if typeof(layer) != TYPE_DICTIONARY:
				continue
			var layer_flat = _arrays_to_dicts(layer)
			if not layer_flat.has("items"):
				continue
			_load_layer_items(layer_flat["items"], _get_render_layer_altitude(layer, show_all_floors), str(layer_id))
		return

	if data.has("items"):
		_load_layer_items(data["items"], 0.0)
	elif data.has("assets"):
		_load_layer_items(data["assets"], 0.0)

func _resolve_local_model_path(path: String) -> String:
	if path == "" or path == "null" or path == "None":
		return ""

	var normalized = str(path).replace("\\", "/")
	if FileAccess.file_exists(normalized): return normalized
	if FileAccess.file_exists("res://" + normalized): return "res://" + normalized
	if FileAccess.file_exists("./" + normalized): return "./" + normalized

	var filename = normalized.get_file()
	if filename == "": return ""
	var filename_base = filename.get_basename()
	var parent_folder_hint = normalized.get_base_dir().get_file()

	var project_root = ProjectSettings.globalize_path("res://")
	var parent_dir = project_root.get_base_dir()
	var asset_downloads = parent_dir.path_join("asset_downloads")
	var sibling_asset_downloads = ""
	if parent_dir.ends_with(" - staging"):
		var non_staging_root = parent_dir.substr(0, parent_dir.length() - " - staging".length())
		sibling_asset_downloads = non_staging_root.path_join("asset_downloads")

	var search_dirs = [
		asset_downloads, sibling_asset_downloads,
		"glb-assets", "res://glb-assets", "./glb-assets",
		"assets", "res://assets", "."
	]

	for dir in search_dirs:
		if dir == "": continue
		var candidate = dir + "/" + filename
		if FileAccess.file_exists(candidate):
			return candidate

	var hints = []
	if parent_folder_hint != "":
		hints.append(parent_folder_hint.to_lower())
	var base_l = filename_base.to_lower()
	if base_l != "":
		hints.append(base_l)
		if base_l.ends_with("_lp"): hints.append(base_l.substr(0, base_l.length() - 3))
		if base_l.ends_with("_hp"): hints.append(base_l.substr(0, base_l.length() - 3))
		if base_l.ends_with("_low"): hints.append(base_l.substr(0, base_l.length() - 4))

	for dir in search_dirs:
		if dir == "": continue
		var da = DirAccess.open(dir)
		if da == null: continue
		da.list_dir_begin()
		var entry = da.get_next()
		while entry != "":
			if not da.current_is_dir() and entry.to_lower().ends_with(".glb"):
				var el = entry.to_lower()
				for h in hints:
					if h != "" and h in el:
						return dir + "/" + entry
			entry = da.get_next()

	return ""

func _is_light_fixture_item(item: Dictionary) -> bool:
	var item_type = str(item.get("type", "")).to_lower()
	var item_name = str(item.get("name", "")).to_lower()
	var mounting_type = str(item.get("mounting_type", "")).to_lower()
	var model_hint = ""
	if item.has("asset_urls") and typeof(item["asset_urls"]) == TYPE_DICTIONARY:
		var urls = item["asset_urls"]
		if urls.has("GLB_File_URL") and urls["GLB_File_URL"] != null:
			model_hint = str(urls["GLB_File_URL"]).to_lower()
		elif urls.has("glb_Url") and urls["glb_Url"] != null:
			model_hint = str(urls["glb_Url"]).to_lower()

	var full_desc = item_type + " " + item_name + " " + mounting_type + " " + model_hint
	var light_keywords = [
		"light", "lamp", "pendant", "pendent", "chandelier",
		"lantern", "sconce", "ceilinglamp", "ceiling_light",
		"wallmount", "streetlamp", "lighting fixture"
	]
	for kw in light_keywords:
		if kw in full_desc:
			return true
	return false

func _apply_light_fixture_emission(node: Node3D, light_color: Color, emission_energy: float) -> bool:
	var meshes = _get_all_meshes(node)
	var applied = false
	var mood_key = _lighting_color_mood.to_lower()
	
	# Adjust emission energy multiplier based on mood type and passed dynamic emission_energy
	var mood_emission_scale = 1.0 # Default
	match mood_key:
		"warm":
			mood_emission_scale = 1.10
		"soft":
			mood_emission_scale = 0.95
		"cool":
			mood_emission_scale = 0.90
		"neutral":
			mood_emission_scale = 1.00
		"day":
			mood_emission_scale = 0.85
		_:
			mood_emission_scale = 1.00
			
	# Dynamically calculate final emission energy to preserve illumination levels from JSON
	# Base night emission_energy is around 6.5 to 10.0. Multiplying by 1.5 reaches ~10 to 15.
	var final_emission_energy = emission_energy * 1.5 * mood_emission_scale
	
	for m in meshes:
		if not m.mesh:
			continue
		for i in range(m.mesh.get_surface_count()):
			var mat = m.get_active_material(i)
			if mat == null:
				mat = m.mesh.surface_get_material(i)
			
			if mat and mat is BaseMaterial3D:
				var mat_name = str(mat.resource_name).to_lower()
				var surface_name = str(m.mesh.surface_get_name(i)).to_lower()
				
				var is_emissive_surface = false
				# STRICT WORKAROUND: Only enable emission if the material or surface name explicitly contains bulb/led/filament keywords.
				# This ignores the GLB's base emission colors to prevent incorrectly authored assets from glowing entirely.
				if mat.emission_enabled:
					var strict_keywords = ["bulb", "filament", "led", "emiss", "glow", "neon"]
					for kw in strict_keywords:
						if kw in mat_name or kw in surface_name:
							is_emissive_surface = true
							break
				
				if not is_emissive_surface:
					continue
				
				var new_mat = mat.duplicate()
				if day_render:
					new_mat.emission_enabled = false
					new_mat.emission_energy_multiplier = 0.0
				else:
					new_mat.emission_enabled = true
					
					var hardcoded_mood_color = Color(1.0, 1.0, 1.0)
					match mood_key:
						"warm":
							hardcoded_mood_color = Color(1.0, 0.84, 0.66) # Soft realistic warm white (2700K)
						"soft":
							hardcoded_mood_color = Color(1.0, 0.88, 0.72) # Soft warm-white (3000K)
						"cool":
							hardcoded_mood_color = Color(0.92, 0.96, 1.0) # Crisp cool white (5500K)
						"neutral":
							hardcoded_mood_color = Color(1.0, 0.94, 0.88) # Clean neutral white (4000K)
						"day":
							hardcoded_mood_color = Color(1.0, 0.835, 0.50) # warm daylight white (6500K)
						_:
							hardcoded_mood_color = light_color # Fallback to passed color
					
					new_mat.emission = hardcoded_mood_color
					new_mat.emission_energy_multiplier = final_emission_energy
				m.set_surface_override_material(i, new_mat)
				applied = true
	return applied

func _node_has_emissive_material(node: Node3D) -> bool:
	var meshes = _get_all_meshes(node)
	var emissive_keywords = [
		"emiss", "glow", "bulb", "led",
		"filament", "diffuser", "lamp_head",
		"shade_inner", "tube"
	]

	for m in meshes:
		if not m.mesh:
			continue
		for i in range(m.mesh.get_surface_count()):
			var mat = m.get_active_material(i)
			if mat == null:
				mat = m.mesh.surface_get_material(i)

			if mat and mat is BaseMaterial3D:
				if mat.emission_enabled or mat.emission_energy_multiplier > 0.05:
					return true

			var mat_name = ""
			var surface_name = ""
			if mat != null:
				mat_name = str(mat.resource_name).to_lower()
			surface_name = str(m.mesh.surface_get_name(i)).to_lower()
			for kw in emissive_keywords:
				if kw in mat_name or kw in surface_name:
					return true

	return false

func _should_add_light_fixture_effect(node: Node3D, item: Dictionary) -> bool:
	# ONLY items whose metadata explicitly identifies them as light fixtures
	# should get an OmniLight3D.  The _node_has_emissive_material() fallback
	# was adding OmniLights to beds, sofas, and other furniture whose GLBs
	# happened to have emissive materials — causing a warm center blob in renders.
	if _is_light_fixture_item(item):
		print("[LightFixture] ACCEPTED: ", item.get("name", "?"), " type=", item.get("type", "?"), " mount=", item.get("mounting_type", "?"))
		return true
	return false

# Counts only ceiling_mount light fixtures — the denominator for sqrt normalisation.
func _count_ceiling_fixture_lights(geom_data: Dictionary) -> int:
	var count := 0
	var _scan := func(items) -> void:
		if typeof(items) == TYPE_ARRAY:
			for item in items:
				if typeof(item) == TYPE_DICTIONARY \
				and str(item.get("mounting_type", "")).to_lower() == "ceiling_mount" \
				and _is_light_fixture_item(item):
					count += 1
		elif typeof(items) == TYPE_DICTIONARY:
			for id in items:
				var item = items[id]
				if typeof(item) == TYPE_DICTIONARY \
				and str(item.get("mounting_type", "")).to_lower() == "ceiling_mount" \
				and _is_light_fixture_item(item):
					count += 1
	if geom_data.has("items"):
		_scan.call(geom_data["items"])
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		for layer_id in geom_data["layers"]:
			var layer = geom_data["layers"][layer_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("items"):
				_scan.call(layer["items"])
	return count

func _normalize_material_label(value: String) -> String:
	var text := str(value).strip_edges().to_lower()
	var normalized := ""
	var allowed := "abcdefghijklmnopqrstuvwxyz0123456789_"
	for i in range(text.length()):
		var ch := text.substr(i, 1)
		if ch in allowed:
			normalized += ch
	return normalized

func _material_key_matches_surface(key: String, mat_name: String, surface_name: String) -> bool:
	# Keep material overrides surgical: only exact-name matches should win.
	# This avoids one bookshelf texture update bleeding into every similarly
	# named mesh part that happens to share a loose substring match.
	var key_norm := _normalize_material_label(key)
	if key_norm == "":
		return false

	for candidate in [mat_name, surface_name]:
		var candidate_norm := _normalize_material_label(candidate)
		if candidate_norm != "" and candidate_norm == key_norm:
			return true

	return false

func _material_key_is_generic(key: String) -> bool:
	var key_norm := _normalize_material_label(key)
	return key_norm in [
		"wood",
		"material",
		"materials",
		"default",
		"surface",
		"surfaces",
		"mat",
		"texture",
	]

func _add_light_fixture_effect(node: Node3D, item: Dictionary, local_aabb: AABB, final_scale: Vector3) -> void:
	if item.get("is_exterior_black", false):
		return
	if not _should_add_light_fixture_effect(node, item):
		return

	var item_type = str(item.get("type", "")).to_lower()
	var item_name = str(item.get("name", "")).to_lower()
	var mounting_type = str(item.get("mounting_type", "")).to_lower()
	var full_desc = item_type + " " + item_name + " " + mounting_type

	var scaled_origin = Vector3(
		local_aabb.position.x * final_scale.x,
		local_aabb.position.y * final_scale.y,
		local_aabb.position.z * final_scale.z
	)
	var scaled_size = Vector3(
		abs(local_aabb.size.x * final_scale.x),
		abs(local_aabb.size.y * final_scale.y),
		abs(local_aabb.size.z * final_scale.z)
	)
	var emitter_local = scaled_origin + scaled_size * 0.5

	if mounting_type == "ceiling_mount":
		emitter_local.y = scaled_origin.y + scaled_size.y * 0.18
	elif "wall" in full_desc:
		emitter_local.y = scaled_origin.y + scaled_size.y * 0.45
		emitter_local.z = scaled_origin.z + scaled_size.z * 0.22
	elif mounting_type == "floor_mount":
		emitter_local.y = scaled_origin.y + scaled_size.y * 0.82
	else:
		emitter_local.y = scaled_origin.y + scaled_size.y * 0.72

	var is_street_light = "street" in full_desc or "exterior" in full_desc
	var is_night = lighting_profile == "night"
	var is_sunset = lighting_profile == "sunset"
	var warm_color = Color(1.0, 0.90, 0.74)
	var street_color = Color(1.0, 0.92, 0.80)
	if is_sunset:
		warm_color = Color(1.0, 0.72, 0.46)
		street_color = Color(1.0, 0.78, 0.52)
	elif is_night:
		warm_color = Color(1.0, 0.84, 0.62)
		street_color = Color(1.0, 0.78, 0.52)
	var light_color = street_color if is_street_light else warm_color

	var light_energy = 1.15
	var light_range = max(max(scaled_size.x, scaled_size.z) * 5.5, 3.6)
	var emission_energy = 4.5
	if is_sunset:
		light_energy = 2.6
		emission_energy = 7.5
	elif is_night:
		light_energy = 4.2
		emission_energy = 9.0

	if mounting_type == "ceiling_mount":
		light_energy = 1.5
		light_range = max(light_range, 5.8)
		emission_energy = 5.8
		if is_sunset:
			light_energy = 3.4
			emission_energy = 9.2
		elif is_night:
			light_energy = 5.5
			emission_energy = 11.5
	elif "wall" in full_desc:
		light_energy = 1.2
		light_range = max(light_range, 4.2)
		emission_energy = 5.0
		if is_sunset:
			light_energy = 2.9
			emission_energy = 8.1
		elif is_night:
			light_energy = 4.6
			emission_energy = 9.8
	elif mounting_type == "floor_mount":
		if is_street_light:
			light_energy = 2.0
			light_range = max(light_range, 8.5)
			emission_energy = 6.0
			if is_sunset:
				light_energy = 4.2
				emission_energy = 9.6
			elif is_night:
				light_energy = 7.2
				emission_energy = 12.0
		else:
			light_energy = 1.35
			light_range = max(light_range, 4.8)
			emission_energy = 5.2
			if is_sunset:
				light_energy = 3.1
				emission_energy = 8.4
			elif is_night:
				light_energy = 5.0
				emission_energy = 10.0

	if not day_render:
		# Boosted Night Logic: t = scale / 0.5
		var t = _lighting_illumination_scale / 0.5
		var illuminationLevel = float(item.get("illumination_level", 5.0))
		
		# Updated Fixture energy calculation (Reduced to 2.2 for better night atmosphere)
		light_energy = _lighting_illumination_scale * (illuminationLevel / 5.0) * 2.2
		
		# Reduced 8.5m range for ceiling fixtures to avoid washing out walls/cupboards
		if mounting_type == "ceiling_mount":
			light_range = 8.5
		
		emission_energy *= _lighting_illumination_scale * (illuminationLevel / 5.0)
	else:
		light_energy = 0.0
		emission_energy = 0.0

	# Ceiling fixture sqrt normalisation — mirrors image_glb_creation.gd.
	# Divides per-fixture energy by sqrt(N) so total luminance grows as sqrt(N) not N.
	# Cap divisor at sqrt(16)=4.0 to avoid over-dimming in very large plans.
	if mounting_type == "ceiling_mount":
		var sqrt_n := sqrt(float(clamp(_ceiling_fixture_count, 1, 16)))
		light_energy /= sqrt_n
		emission_energy /= sqrt_n

	var emissive_surface_found = _apply_light_fixture_emission(node, light_color, emission_energy)

	var world_pos = node.to_global(emitter_local)
	var is_wall_panel_light = (
		"wall" in full_desc
		and (
			"panel" in full_desc
			or "led" in full_desc
			or "walllamp" in full_desc
			or "wall lamp" in full_desc
		)
	)

	if is_wall_panel_light:
		var omni = OmniLight3D.new()
		omni.name = "FixtureLight_" + str(item.get("id", item.get("name", "Light")))
		omni.global_position = world_pos
		omni.light_color = light_color
		omni.light_energy = light_energy
		omni.light_specular = 0.25
		omni.shadow_enabled = false
		omni.omni_range = max(light_range, 10.0)
		omni.omni_attenuation = 0.5 # Midrange falloff for depth
		omni.add_to_group("fixture_lights")
		add_child(omni)
	elif mounting_type == "ceiling_mount":
		# Ceiling fixtures — SpotLight3D pointing downward to prevent ceiling reflections
		var spot_ceil = SpotLight3D.new()
		spot_ceil.name = "FixtureLight_" + str(item.get("id", item.get("name", "Light")))
		spot_ceil.global_position = world_pos
		spot_ceil.rotation_degrees = Vector3(-90, 0, 0)
		spot_ceil.light_color = light_color
		spot_ceil.light_energy = light_energy
		spot_ceil.light_specular = 0.0
		spot_ceil.shadow_enabled = false
		
		# Optimized Radius and Angle Controls for SpotLight3D
		spot_ceil.spot_range = max(light_range, 15.0) # Midrange reach
		spot_ceil.spot_angle = 175.0 # High angle but restores some depth
		spot_ceil.spot_angle_attenuation = 1.5 # Midrange edge softness
		spot_ceil.spot_attenuation = 0.35 # Midrange distance falloff
			
		spot_ceil.add_to_group("fixture_lights")
		add_child(spot_ceil)
		
		# Upward ceiling bounce spotlight (to fix dark ceiling near fixtures)
		var spot_ceil_up = SpotLight3D.new()
		spot_ceil_up.name = "FixtureLightUp_" + str(item.get("id", item.get("name", "Light")))
		# Position 0.8 meters below the ceiling fixture so it hits the ceiling at a good angle (dot product)
		spot_ceil_up.global_position = world_pos - Vector3(0, 0.8, 0)
		spot_ceil_up.rotation_degrees = Vector3(90, 0, 0) # Point straight UP
		spot_ceil_up.light_color = light_color
		spot_ceil_up.light_energy = light_energy * 0.90
		spot_ceil_up.light_specular = 0.0
		spot_ceil_up.shadow_enabled = false
		spot_ceil_up.spot_range = max(light_range * 1.2, 10.0)
		spot_ceil_up.spot_angle = 160.0 # Wide angle to spread across the ceiling
		spot_ceil_up.spot_angle_attenuation = 1.0 # Smooth edge
		spot_ceil_up.spot_attenuation = 0.5 # Smooth falloff
		spot_ceil_up.add_to_group("fixture_lights")
		add_child(spot_ceil_up)
	elif "wall" in full_desc or is_street_light:
		# Wall sconces and street lights — SpotLight3D aimed downward/outward
		var spot = SpotLight3D.new()
		spot.name = "FixtureLight_" + str(item.get("id", item.get("name", "Light")))
		spot.global_position = world_pos
		spot.light_color = light_color
		spot.light_energy = light_energy
		spot.light_specular = 0.25
		spot.shadow_enabled = false
		spot.spot_range = max(light_range, 10.0)
		spot.spot_angle = 90.0 # Midrange wall spread
		spot.spot_attenuation = 0.5 # Midrange falloff
		spot.spot_angle_attenuation = 1.5
		spot.add_to_group("fixture_lights")
		add_child(spot)

		var target_local = emitter_local + Vector3(0, -max(1.0, light_range * 0.45), 0)
		if "wall" in full_desc and not is_street_light:
			target_local = emitter_local + Vector3(0, -0.15, -max(0.8, light_range * 0.25))
		spot.look_at(node.to_global(target_local), Vector3.UP)
	else:
		var omni = OmniLight3D.new()
		omni.name = "FixtureLight_" + str(item.get("id", item.get("name", "Light")))
		omni.global_position = world_pos
		omni.light_color = light_color
		omni.light_energy = light_energy
		omni.light_specular = 0.25
		omni.shadow_enabled = false
		omni.omni_range = max(light_range, 10.0)
		omni.omni_attenuation = 0.5 # Spread further
		omni.add_to_group("fixture_lights")
		add_child(omni)

	if not emissive_surface_found:
		print("[VideoGLB] Light fixture added without material override for asset: ", item.get("name", "Light"))

func _load_layer_items(items, layer_altitude, layer_id = "root"):
	for item_id in items:
		var item
		if typeof(items) == TYPE_DICTIONARY:
			item = items[item_id]
		else:
			item = item_id # Array iteration
		if typeof(item) != TYPE_DICTIONARY:
			continue

		var model_path = ""
		var used_path = ""

		if item.has("local_glb_path") and str(item["local_glb_path"]) != "":
			model_path = str(item["local_glb_path"])
		elif item.has("local_path") and str(item["local_path"]) != "":
			model_path = str(item["local_path"])
		elif item.has("asset_urls"):
			var urls = item["asset_urls"]
			if urls.has("GLB_File_URL") and urls["GLB_File_URL"] != null and str(urls["GLB_File_URL"]) != "":
				model_path = str(urls["GLB_File_URL"])
			elif urls.has("glb_Url") and urls["glb_Url"] != null and str(urls["glb_Url"]) != "":
				model_path = str(urls["glb_Url"])

		var load_status = "not_attempted"
		var load_reason = ""

		if model_path != "":
			var resolved_model_path = _resolve_local_model_path(model_path)
			if resolved_model_path != "":
				used_path = resolved_model_path
			else:
				used_path = model_path

			if FileAccess.file_exists(used_path):
				var node = null
				var is_instance = false
				
				if ENABLE_DUPLICATION and _glb_cache.has(used_path):
					var cached = _glb_cache[used_path]
					if cached != null and is_instance_valid(cached):
						node = cached.duplicate()
						is_instance = true
					else:
						_glb_cache.erase(used_path)
				
				if node == null and not is_instance:
					var glTF = GLTFDocument.new()
					var glTFState = GLTFState.new()
					var error = glTF.append_from_file(used_path, glTFState)
					if error == OK:
						var generated = glTF.generate_scene(glTFState)
						if generated:
							if LOW_TEXTURE_QUALITY:
								_compress_glb_node_textures(generated, 2048)
							node = generated
							if ENABLE_DUPLICATION:
								var cache_copy = generated.duplicate()
								_glb_cache[used_path] = cache_copy

				# ── node is now set (cache duplicate or fresh generate_scene) ──
				if node:
					add_child(node)
					_sanitize_glb_lights(node)
					load_status = "loaded"

					# Position
					var px = float(item.get("x", 0)) * _scene_unit_scale
					var py = float(item.get("y", 0)) * _scene_unit_scale
					var pz = _resolve_item_altitude_value(item) * _scene_unit_scale

					pz += layer_altitude
					node.position = Vector3(px, pz, py)

					# Rotation
					var rot = 0.0
					if item.has("rotation"):
						rot = float(item["rotation"])
					elif item.has("properties") and item["properties"].has("rotation"):
						rot = float(item["properties"]["rotation"])
					node.rotation.y = _world_yaw_from_source_rotation(rot) + _item_front_axis_correction()

					# Smart scale
					var props = {}
					if item.has("properties") and typeof(item["properties"]) == TYPE_DICTIONARY:
						props = item["properties"]

					var raw_width = props.get("width", 100)
					var raw_depth = props.get("depth", 100)
					var raw_height_p = props.get("height", 100)

					var target_w = get_dimension_value(raw_width) * _scene_unit_scale
					var target_d = get_dimension_value(raw_depth) * _scene_unit_scale
					var target_h = get_dimension_value(raw_height_p) * _scene_unit_scale

					var default_w = get_dimension_value(100) * _scene_unit_scale
					var default_h = get_dimension_value(100) * _scene_unit_scale
					var default_d = get_dimension_value(100) * _scene_unit_scale
					var is_user_resized = (abs(target_w - default_w) > 0.001 or abs(target_h - default_h) > 0.001 or abs(target_d - default_d) > 0.001)

					var aabb = _get_hierarchy_aabb(node)
					var dims = aabb.size
					if dims.x == 0: dims.x = 1.0
					if dims.y == 0: dims.y = 1.0
					if dims.z == 0: dims.z = 1.0

					var scale_x = target_w / dims.x
					var scale_y = target_h / dims.y
					var scale_z = target_d / dims.z

					var scale_x_swapped = target_w / dims.z
					var scale_z_swapped = target_d / dims.x

					var diff_normal = abs(scale_x - scale_z)
					var diff_swapped = abs(scale_x_swapped - scale_z_swapped)

					var final_scale = Vector3.ONE

					if diff_swapped < diff_normal and diff_swapped < 0.3:
						final_scale = Vector3(scale_x_swapped, scale_y, scale_z_swapped)
					else:
						var avg_xz_scale = (scale_x + scale_z) / 2.0
						var item_type = str(item.get("type", "")).to_lower()
						var item_name = str(item.get("name", "")).to_lower()
						var full_desc = item_type + " " + item_name

						var is_ceiling_light = ("hanging" in full_desc or "chandelier" in full_desc or "ceiling_light" in full_desc or "ceilinglight" in full_desc or "lamp" in full_desc or "light" in full_desc) and str(item.get("mounting_type", "")).to_lower() == "ceiling_mount"
						var is_thin_wall_item = ("frame" in full_desc or "picture" in full_desc or "art" in full_desc or "painting" in full_desc or "mirror" in full_desc or "curtain" in full_desc or "drape" in full_desc or "tv" in full_desc or "television" in full_desc or "monitor" in full_desc or "screen" in full_desc)
						var is_tall_appliance = ("fridge" in full_desc or "refrigerat" in full_desc or "freezer" in full_desc or "shower" in full_desc or "bathtub" in full_desc or "bath_tub" in full_desc)

						if not is_user_resized and not is_ceiling_light and not is_thin_wall_item and not is_tall_appliance:
							var height_diff_ratio = 0.0
							if avg_xz_scale > 0:
								height_diff_ratio = abs(scale_y - avg_xz_scale) / avg_xz_scale
							if height_diff_ratio > 0.2 or scale_y > 1.5:
								scale_y = avg_xz_scale
						final_scale = Vector3(scale_x, scale_y, scale_z)

					node.scale = final_scale
					var flip_x = bool(item.get("flipX", false))
					var flip_y = bool(item.get("flipY", item.get("fipy", false)))
					var flip_z = bool(item.get("flipZ", false))
					var applied_flips: Array = []
					if flip_x:
						node.scale.x = - abs(node.scale.x)
						applied_flips.append("X")
					if flip_y:
						node.scale.y = - abs(node.scale.y)
						applied_flips.append("Y")
					if flip_z:
						node.scale.z = - abs(node.scale.z)
						applied_flips.append("Z")
					if not applied_flips.is_empty():
						print("[VideoGLB] Applied flip(s) on axis/axes ", applied_flips, " for asset: ", item.get("name", "Unknown"))
					var bounds_y_min = aabb.position.y * final_scale.y
					node.position.y = pz - bounds_y_min

					var local_center = Vector3(aabb.position.x + aabb.size.x / 2.0, 0.0, aabb.position.z + aabb.size.z / 2.0)
					var world_offset = node.transform.basis * local_center
					node.position.x = px - world_offset.x
					node.position.z = py - world_offset.z

					# Track exterior assets for sunlight optimization
					var item_name_l = str(item.get("name", "")).to_lower()
					var item_type_l = str(item.get("type", "")).to_lower()
					var ext_keywords = ["tree", "plant", "garden", "outdoor", "landscape", "bush", "shrub", "vegetat", "flower"]
					var is_ext = false
					for kw in ext_keywords:
						if kw in item_type_l or kw in item_name_l:
							is_ext = true
							break
					if is_ext:
						_exterior_assets.append({
							"node": node,
							"position": node.global_position,
							"name": item.get("name", "unknown")
						})

					# Force-black for exterior items
					if item.get("is_exterior_black", false):
						var meshes = _get_all_meshes(node)
						var black_mat = StandardMaterial3D.new()
						black_mat.albedo_color = Color.BLACK
						black_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
						for m in meshes:
							if not m.mesh: continue
							for i in range(m.mesh.get_surface_count()):
								m.set_surface_override_material(i, black_mat)

					# Material overrides per surface
					_apply_item_materials(node, item)

					_add_light_fixture_effect(node, item, aabb, final_scale)

					print("[VideoGLB] Loaded asset: ", used_path, " final scale: ", final_scale)
				else:
					load_reason = "generate_scene_null"
		else:
			load_reason = "file_not_found"

		_tracked_assets.append({
			"type": "item_asset",
			"id": item.get("id", "unknown"),
			"name": item.get("name", "unknown"),
			"layer_id": layer_id,
			"path": used_path if used_path != "" else model_path,
			"status": load_status,
			"reason": load_reason,
			"position": item.get("x", 0),
		})

# ─────────────────────────────────────────────────────────────────────────────
# _disable_shadow_casting_recursive and smart glass handling
# ─────────────────────────────────────────────────────────────────────────────
# Automatically detects glass materials and default unnamed materials that resemble glass
# and configures them with alpha transparency so that sunlight can pass through them.
# Opaque parts of the window (like frames and mullions) remain opaque to cast shadows.
func _fix_glass_materials_for_shadows(node: Node) -> void:
	if not node:
		return
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh != null:
			var surface_count := mesh_inst.get_surface_override_material_count()
			if surface_count == 0:
				surface_count = mesh_inst.mesh.get_surface_count()
				
			# Step 1: Detect if this mesh contains any transparent or glass surfaces
			var mesh_has_glass = false
			var surfaces_info = []
			
			for s in range(surface_count):
				var mat = mesh_inst.get_surface_override_material(s)
				if mat == null:
					mat = mesh_inst.mesh.surface_get_material(s)
				if mat == null:
					surfaces_info.append({"mat": null, "is_glass": false})
					continue
					
				var is_glass = false
				if mat is StandardMaterial3D:
					var std_mat := mat as StandardMaterial3D
					var mat_name := std_mat.resource_name.to_lower()
					
					# Case A: Name-based check
					for keyword in ["glass", "glaz", "pane", "transp", "glazing", "window_fill"]:
						if keyword in mat_name:
							is_glass = true
							break
							
					# Case B: Already transparent in GLB
					if not is_glass:
						if std_mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
							is_glass = true
						elif std_mat.albedo_color.a < 0.95:
							is_glass = true
							
					# Case C: Generic material with high gloss
					if not is_glass:
						if mat_name.begins_with("material") and std_mat.roughness < 0.2:
							is_glass = true
							
				surfaces_info.append({"mat": mat, "is_glass": is_glass})
				if is_glass:
					mesh_has_glass = true
			
			# Step 2: Fix materials. If the mesh contains glass, we also treat any default
			# "material.xxx" surface in it as a glass pane.
			for s in range(surface_count):
				var info = surfaces_info[s]
				var mat = info["mat"]
				if mat == null:
					continue
					
				var should_be_glass = info["is_glass"]
				if not should_be_glass and mesh_has_glass:
					if mat is StandardMaterial3D:
						var std_mat := mat as StandardMaterial3D
						var mat_name := std_mat.resource_name.to_lower()
						if mat_name.begins_with("material"):
							should_be_glass = true
							print("  [SmartGlass] Coerced default material '", mat_name, "' in glass-bearing mesh '", mesh_inst.name, "' to glass transparency.")
				
				if should_be_glass and mat is StandardMaterial3D:
					var std_mat := mat as StandardMaterial3D
					var mat_name := std_mat.resource_name.to_lower()
					var new_mat = std_mat.duplicate() as StandardMaterial3D
					new_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					if new_mat.albedo_color.a > 0.9:
						new_mat.albedo_color.a = 0.35
					new_mat.roughness = min(new_mat.roughness, 0.05)
					new_mat.metallic_specular = 1.0
					
					mesh_inst.set_surface_override_material(s, new_mat)
					print("  [SmartGlass] Fixed transparency for material '", mat_name, "' on mesh '", mesh_inst.name, "'")

	for child in node.get_children():
		_fix_glass_materials_for_shadows(child)

func _disable_shadow_casting_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var is_glass := _is_glass_mesh(mesh_inst)
		if is_glass:
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			# Frame / mullion / bar — keep shadows ON for grid pattern
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_disable_shadow_casting_recursive(child)

# Returns true if a MeshInstance3D looks like a glass/transparent pane.
func _is_glass_mesh(mesh_inst: MeshInstance3D) -> bool:
	# 1. Name-based check (covers most GLB exports)
	var lower_name := mesh_inst.name.to_lower()
	for keyword in ["glass", "glaz", "pane", "transp", "window_fill", "glazing"]:
		if keyword in lower_name:
			return true

	# 2. Material-based check — transparent or near-zero alpha
	var surface_count := mesh_inst.get_surface_override_material_count()
	if surface_count == 0 and mesh_inst.mesh != null:
		surface_count = mesh_inst.mesh.get_surface_count()

	for s in range(surface_count):
		var mat = mesh_inst.get_surface_override_material(s)
		if mat == null and mesh_inst.mesh != null:
			mat = mesh_inst.mesh.surface_get_material(s)
		if mat == null:
			continue
		if mat is StandardMaterial3D:
			var std_mat := mat as StandardMaterial3D
			# Transparent blend mode or very low albedo alpha → glass
			if std_mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				return true
			if std_mat.albedo_color.a < 0.5:
				return true

	return false

func _count_shadow_casters(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		if (node as MeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			count += 1
	for child in node.get_children():
		count += _count_shadow_casters(child)
	return count

# ─────────────────────────────────────────────────────────────────────────────
# _add_window_grid_shadow_caster
# ─────────────────────────────────────────────────────────────────────────────
func _add_window_grid_shadow_caster(win_center: Vector3, win_width: float,
		win_height: float, wall_angle: float, outer_dir: Vector3,
		layer_altitude: float) -> void:
	var bar_t := 0.04
	var bar_d := 0.06
	var grid_pos := win_center + outer_dir * 0.06

	var grid_root := Node3D.new()
	grid_root.name = "WindowGridShadowCaster"
	grid_root.position = grid_pos
	grid_root.rotation.y = wall_angle
	add_child(grid_root)

	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.15, 0.10, 0.08)
	frame_mat.roughness = 0.6
	frame_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var border_meshes := [
		Vector3(0.0, win_height * 0.5 - bar_t * 0.5, 0.0), Vector3(win_width, bar_t, bar_d),
		Vector3(0.0, -win_height * 0.5 + bar_t * 0.5, 0.0), Vector3(win_width, bar_t, bar_d),
		Vector3(-win_width * 0.5 + bar_t * 0.5, 0.0, 0.0), Vector3(bar_t, win_height, bar_d),
		Vector3(win_width * 0.5 - bar_t * 0.5, 0.0, 0.0), Vector3(bar_t, win_height, bar_d),
	]

	var bi := 0
	while bi + 1 < border_meshes.size():
		var b_pos: Vector3 = border_meshes[bi]
		var b_size: Vector3 = border_meshes[bi + 1]
		bi += 2
		var bm := BoxMesh.new()
		bm.size = b_size
		var bmi := MeshInstance3D.new()
		bmi.mesh = bm
		bmi.position = b_pos
		bmi.set_surface_override_material(0, frame_mat)
		bmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		grid_root.add_child(bmi)

	var vm := BoxMesh.new()
	vm.size = Vector3(bar_t, win_height - bar_t * 2.0, bar_d)
	var vmi := MeshInstance3D.new()
	vmi.mesh = vm
	vmi.position = Vector3(0.0, 0.0, 0.0)
	vmi.set_surface_override_material(0, frame_mat)
	vmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	grid_root.add_child(vmi)

	var hm := BoxMesh.new()
	hm.size = Vector3(win_width - bar_t * 2.0, bar_t, bar_d)
	var hmi := MeshInstance3D.new()
	hmi.mesh = hm
	hmi.position = Vector3(0.0, 0.0, 0.0)
	hmi.set_surface_override_material(0, frame_mat)
	hmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	grid_root.add_child(hmi)
	print("[VideoGLB]   Added procedural window grid shadow caster at ", grid_pos)

# ─────────────────────────────────────────────────────────────────
# get_dimension_value — identical to image_glb_creation.gd
# ─────────────────────────────────────────────────────────────────
func get_dimension_value(prop_value, default_val = 100.0) -> float:
	if typeof(prop_value) == TYPE_ARRAY and prop_value.size() > 0:
		return float(prop_value[0])
	elif typeof(prop_value) == TYPE_DICTIONARY:
		return float(prop_value.get("length", default_val))
	elif typeof(prop_value) == TYPE_INT or typeof(prop_value) == TYPE_FLOAT:
		return float(prop_value)
	elif typeof(prop_value) == TYPE_STRING and prop_value.is_valid_float():
		return float(prop_value)
	else:
		return float(default_val)

# ─────────────────────────────────────────────────────────────────
# AABB helpers — identical to image_glb_creation.gd
# ─────────────────────────────────────────────────────────────────
func _get_hierarchy_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first = true
	var meshes = _get_all_meshes(node)
	if meshes.size() == 0:
		return AABB(Vector3.ZERO, Vector3.ONE)
	for mesh_inst in meshes:
		var xform = node.global_transform.affine_inverse() * mesh_inst.global_transform
		var mesh_aabb = xform * mesh_inst.get_aabb()
		if first:
			aabb = mesh_aabb
			first = false
		else:
			aabb = aabb.merge(mesh_aabb)
	return aabb

func _get_all_meshes(node: Node) -> Array:
	var meshes = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_get_all_meshes(child))
	return meshes

# ─────────────────────────────────────────────────────────────────
# create_material — full parity with image_glb_creation.gd
# ─────────────────────────────────────────────────────────────────
# ==============================================================================
# PBR MATERIAL CREATION
# ==============================================================================
# WHY IT EXISTS: To build physically based rendering (PBR) materials for surfaces. 
# It takes basic colors or downloaded textures (diffuse, normal, roughness) and 
# applies them to Godot materials so floors and walls look realistic and react 
# correctly to light.
# ==============================================================================
func create_material(mat_data):
	var mat = StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = mat_data.get("roughness", 0.65)
	mat.metallic = mat_data.get("metallic", 0.0)
	mat.metallic_specular = 0.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX

	var base_color = Color(0.82, 0.82, 0.82)
	var has_explicit_color = false
	if mat_data.has("color"):
		var c_str = str(mat_data["color"]).strip_edges()
		if c_str.length() >= 3 and not c_str.begins_with("#"):
			c_str = "#" + c_str
		if c_str.is_valid_html_color():
			base_color = Color(c_str)
			has_explicit_color = true
		else:
			print("[VideoGLB] Warning: Invalid color string: ", c_str)
	mat.albedo_color = base_color

	var map_url = ""
	if mat_data.has("mapUrl") and mat_data["mapUrl"] != null and str(mat_data["mapUrl"]) != "":
		map_url = str(mat_data["mapUrl"])
	elif mat_data.has("texture_urls") and typeof(mat_data["texture_urls"]) == TYPE_ARRAY and mat_data["texture_urls"].size() > 0:
		map_url = str(mat_data["texture_urls"][0])

	if map_url != "":
		var tex = load_texture_from_path(map_url)
		if tex:
			mat.albedo_texture = tex
			if not has_explicit_color:
				mat.albedo_color = Color(1.0, 1.0, 1.0)

	if mat_data.has("normalUrl") and mat_data["normalUrl"] != null and str(mat_data["normalUrl"]) != "":
		var tex = load_texture_from_path(str(mat_data["normalUrl"]))
		if tex:
			mat.normal_enabled = true
			mat.normal_texture = tex

	if mat_data.has("roughnessUrl") and mat_data["roughnessUrl"] != null and str(mat_data["roughnessUrl"]) != "":
		var tex = load_texture_from_path(str(mat_data["roughnessUrl"]))
		if tex:
			mat.roughness_texture = tex
			mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN

	var scale_u = 1.0
	var scale_v = 1.0

	if mat_data.has("repeat"):
		var r = mat_data["repeat"]
		if typeof(r) == TYPE_ARRAY and r.size() >= 2:
			scale_u = float(r[0]) if float(r[0]) > 0 else 1.0
			scale_v = float(r[1]) if float(r[1]) > 0 else 1.0
	
	if mat_data.has("repeatX"):
		scale_u = float(mat_data["repeatX"]) if float(mat_data["repeatX"]) > 0 else scale_u
	if mat_data.has("repeatY"):
		scale_v = float(mat_data["repeatY"]) if float(mat_data["repeatY"]) > 0 else scale_v

	if mat_data.has("scale"):
		var s = mat_data["scale"]
		if typeof(s) == TYPE_ARRAY and s.size() >= 2:
			scale_u = float(s[0]) if float(s[0]) > 0 else scale_u
			scale_v = float(s[1]) if float(s[1]) > 0 else scale_v
		elif typeof(s) == TYPE_FLOAT or typeof(s) == TYPE_INT:
			var sf = float(s)
			if sf > 0:
				scale_u = sf; scale_v = sf
		elif typeof(s) == TYPE_STRING and s.is_valid_float():
			var sf = float(s)
			if sf > 0:
				scale_u = sf; scale_v = sf

	mat.uv1_scale = Vector3(scale_u, scale_v, 1.0)
	
	if mat_data.get("is_structure", false):
		mat.uv1_triplanar = true

	# ── Material optimization (mirrors image_glb_creation.gd / optimize_material) ──
	# The mapUrl / texture path contains the material type keyword.
	# Without this, marble floors have roughness=0.65 → zero visible reflections.
	var opt_path = map_url.to_lower().get_file()
	var is_glass_mat = "glass" in opt_path or "window" in opt_path or "mirror" in opt_path
	var is_marble_mat = not is_glass_mat and (
		"marble" in opt_path or "stone" in opt_path or "polished" in opt_path or
		"granite" in opt_path or "travertine" in opt_path or "terrazzo" in opt_path
	)
	var is_tile_mat = not is_glass_mat and not is_marble_mat and (
		"tile" in opt_path or "ceramic" in opt_path or "porcelain" in opt_path
	)
	var is_wood_mat = not is_glass_mat and (
		"wood" in opt_path or "parquet" in opt_path or "plank" in opt_path or
		"oak" in opt_path or "walnut" in opt_path or "timber" in opt_path or "bamboo" in opt_path
	)

	if is_glass_mat:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.01
		mat.metallic_specular = 1.0
		if mat.albedo_color.a > 0.95:
			mat.albedo_color.a = 0.35

	elif is_marble_mat:
		# Sharp polished surface — must be low roughness for reflections to appear
		mat.roughness = 0.10
		mat.metallic = 0.0
		mat.metallic_specular = 0.65
		mat.clearcoat_enabled = true
		mat.clearcoat = 0.20
		mat.clearcoat_roughness = 0.10

	elif is_tile_mat:
		mat.roughness = 0.14
		mat.metallic = 0.0
		mat.metallic_specular = 0.55
		mat.clearcoat_enabled = true
		mat.clearcoat = 0.15
		mat.clearcoat_roughness = 0.14

	elif is_wood_mat:
		mat.roughness = 0.25
		mat.metallic = 0.0
		mat.metallic_specular = 0.20
		mat.clearcoat_enabled = false
		mat.anisotropy_enabled = false

	return mat

# ─────────────────────────────────────────────────────────────────
# Texture loading — identical to image_glb_creation.gd
# ─────────────────────────────────────────────────────────────────
func _resolve_local_texture(url: String) -> String:
	if url == "" or url == "null": return ""
	var normalized = url.replace("\\", "/")
	if FileAccess.file_exists(normalized): return normalized
	var filename = normalized.get_file()
	if filename == "": return ""
	var project_root = ProjectSettings.globalize_path("res://")
	var parent_dir = project_root.get_base_dir()
	var asset_downloads = parent_dir.path_join("asset_downloads")
	var search_dirs = [
		asset_downloads, "textures", "res://textures", "./textures",
		"downloaded_textures", "assets/textures", "res://assets", "."
	]
	for dir in search_dirs:
		var candidate = dir + "/" + filename
		if FileAccess.file_exists(candidate):
			return candidate

	# Fallback: if we can't find exact match, try matching by suffix ignoring hash prefix
	if "_" in filename:
		var suffix = filename.substr(filename.find("_"))
		for dir in search_dirs:
			var da = DirAccess.open(dir)
			if da:
				da.list_dir_begin()
				var f = da.get_next()
				while f != "":
					if f.ends_with(suffix):
						print("Fuzzy matched texture: ", filename, " -> ", f)
						return dir + "/" + f
					f = da.get_next()

	return ""

func load_texture_from_path(path):
	if path == "" or path == "null" or path == "None": return null
	var norm_path = str(path).replace("\\", "/")

	if ENABLE_DUPLICATION and _texture_cache.has(norm_path):
		print("[INSTANCE] Texture: ", norm_path)
		return _texture_cache[norm_path]

	var tex = null
	if FileAccess.file_exists(norm_path):
		tex = load_image_texture(norm_path)
	else:
		var local = _resolve_local_texture(norm_path)
		if local != "":
			tex = load_image_texture(local)
		elif norm_path.begins_with("http"):
			tex = null
		else:
			print("[VideoGLB] Texture not found (skipped): ", norm_path)
			
	if tex:
		print("[ORIGINAL] Texture: ", norm_path, " ".repeat(4096))
		if ENABLE_DUPLICATION:
			_texture_cache[norm_path] = tex
		
	return tex

func load_image_texture(path):
	var img = Image.load_from_file(path)
	if img:
		if LOW_TEXTURE_QUALITY:
			var max_dim = 2048
			if img.get_width() > max_dim or img.get_height() > max_dim:
				var new_w = mini(img.get_width(), max_dim)
				var new_h = mini(img.get_height(), max_dim)
				img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
				
		if not img.has_mipmaps():
			img.generate_mipmaps()
		return ImageTexture.create_from_image(img)
	return null

func _compress_glb_node_textures(root: Node, max_dim: int) -> void:
	for child in root.get_children():
		_compress_glb_node_textures(child, max_dim)
	if not (root is MeshInstance3D):
		return
	var mi := root as MeshInstance3D
	if not mi.mesh:
		return
	for surf_idx in range(mi.mesh.get_surface_count()):
		var mat = mi.mesh.surface_get_material(surf_idx)
		if not (mat is BaseMaterial3D):
			continue
		for slot in ["albedo_texture", "normal_texture", "roughness_texture",
					 "metallic_texture", "ao_texture", "emission_texture"]:
			var tex = mat.get(slot)
			if not (tex is ImageTexture):
				continue
			var img: Image = (tex as ImageTexture).get_image()
			if img == null:
				continue
			if img.get_width() <= max_dim and img.get_height() <= max_dim:
				continue
			var new_w := mini(img.get_width(), max_dim)
			var new_h := mini(img.get_height(), max_dim)
			img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
			img.generate_mipmaps()
			mat.set(slot, ImageTexture.create_from_image(img))


# ─────────────────────────────────────────────────────────────────────────────
# Fabric Anti-Illusion: Material Creation
# ─────────────────────────────────────────────────────────────────────────────

func _is_fabric_item(item_name: String) -> bool:
	# Detect fabric-based furniture items by their name from the scene JSON.
	var lower := item_name.to_lower()
	var fabric_keywords := [
		"rug", "carpet", "sofa", "couch", "chair", "bed", "mattress",
		"pillow", "cushion", "ottoman", "pouf", "bedding", "duvet",
		"comforter", "blanket", "curtain", "drape", "upholst",
		"fabric", "cloth", "linen", "velvet", "cotton", "wool"
	]
	for kw in fabric_keywords:
		if kw in lower:
			return true
	return false

func _create_fabric_material(orig: StandardMaterial3D) -> StandardMaterial3D:
	# Build a fresh StandardMaterial3D with 'Soft-Pass' anti-illusion properties.
	var mat := StandardMaterial3D.new()

	# ── Preserve original appearance ──────────────────────────────────────────
	mat.albedo_color = orig.albedo_color
	mat.albedo_texture = orig.albedo_texture

	if orig.emission_enabled:
		mat.emission_enabled = true
		mat.emission = orig.emission
		mat.emission_energy_multiplier = orig.emission_energy_multiplier
		mat.emission_texture = orig.emission_texture

	# ── Fabric PBR properties ─────────────────────────────────────────────────
	mat.roughness = 1.0 # Max diffusion removes specular glitter
	mat.metallic = 0.0
	mat.metallic_specular = 0.0

	# ── Normal map: Reduced scale ─────────────────────────────────────────────
	# Prevents the high-frequency shadow flickering that triggers the illusion.
	if orig.normal_enabled and orig.normal_texture != null:
		mat.normal_enabled = true
		mat.normal_texture = orig.normal_texture
		mat.normal_scale = 0.2 # Soft depth
	else:
		mat.normal_enabled = false

	# ── Texture filtering: Standard Mipmap (No Anisotropy) ─────────────────────
	# DISABLING Anisotropy forces a natural low-pass blur at sharp viewing angles,
	# which is the most effective way to cancel out interference patterns.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	# ── UV scale: Non-integer ratio ───────────────────────────────────────────
	# Using 0.45x helps break the pixel-grid alignment that causes moiré.
	const UV_ANTI_ILLUSION_SCALE := 0.45
	mat.uv1_scale = Vector3(
		orig.uv1_scale.x * UV_ANTI_ILLUSION_SCALE,
		orig.uv1_scale.y * UV_ANTI_ILLUSION_SCALE,
		orig.uv1_scale.z
	)
	mat.uv1_offset = orig.uv1_offset

	return mat


# ─────────────────────────────────────────────────────────────────────────────
# Perfect natural day rendering: Material/Light Sanitation & Portal Lights
# ─────────────────────────────────────────────────────────────────────────────

func _sanitize_material(mat: Material) -> void:
	if not mat:
		return
	if mat is BaseMaterial3D:
		mat.emission_enabled = false
		mat.emission_energy_multiplier = 0.0

func _sanitize_glb_lights(node: Node) -> void:
	if node is Light3D:
		if day_render:
			node.light_energy = 0.0
			node.visible = false
		else:
			node.shadow_enabled = false
			node.light_energy = min(node.light_energy, 0.3)
	
	if day_render and node is MeshInstance3D:
		if node.material_override:
			if not node.material_override.is_local_to_scene():
				node.material_override = node.material_override.duplicate()
			_sanitize_material(node.material_override)
		
		var mesh = node.mesh
		if mesh:
			for i in range(mesh.get_surface_count()):
				var mat = node.get_surface_override_material(i)
				if mat:
					if not mat.is_local_to_scene():
						mat = mat.duplicate()
						node.set_surface_override_material(i, mat)
					_sanitize_material(mat)
				else:
					var mesh_mat = mesh.surface_get_material(i)
					if mesh_mat:
						var dup_mat = mesh_mat.duplicate()
						_sanitize_material(dup_mat)
						node.set_surface_override_material(i, dup_mat)
	
	for child in node.get_children():
		_sanitize_glb_lights(child)

func _create_window_portal_lights() -> void:
	if not day_render or _window_sunlight_data.is_empty():
		return

	# Window portal SpotLights simulate diffuse sky light entering through windows.
	# Synced with image_glb_creation.gd portal light logic.
	print("[VideoGLB] Creating window portal lights (sky diffuse) for ", _window_sunlight_data.size(), " windows.")
	for i in range(_window_sunlight_data.size()):
		var win = _window_sunlight_data[i]
		var win_center = win["center"] as Vector3
		var inner_dir = win["inner_dir"] as Vector3

		# SpotLight aimed inward from the window — simulates sky diffuse flooding in.
		# 89 degree cone = near-hemispherical so all corners receive light.
		# Positioned 0.5 m inside to avoid lighting the window frame mesh.
		var portal_pos = win_center + inner_dir * 0.5

		var portal_spot = SpotLight3D.new()
		portal_spot.name = "WindowPortalSpot_" + str(i)
		portal_spot.position = portal_pos

		# Windows get slightly higher energy than doors (direct sky view)
		portal_spot.light_energy = 0.4
		portal_spot.light_color = Color(1.0, 0.835, 0.50) # 10AM warm golden sky

		# 89 degree cone: near-hemispherical so every corner falls inside it
		portal_spot.spot_angle = 89.0
		# 0.1 attenuation: nearly flat brightness across the whole cone
		portal_spot.spot_angle_attenuation = 0.1
		portal_spot.spot_range = 20.0
		portal_spot.spot_attenuation = 0.3
		portal_spot.light_specular = 0.0
		portal_spot.shadow_enabled = true

		add_child(portal_spot)
		# Aim 5 m deep so the cone is centered on the room interior
		portal_spot.look_at(win_center + inner_dir * 5.0, Vector3.UP)
		print("  [PortalSpot] Window ", i, " sky fill spot at ", portal_pos)

	# -- Subtle SpotLights for non-window holes (doors, openings) --
	# Doors allow some light bleed into the room but should not dominate.
	for j in range(_door_hole_data.size()):
		var dh = _door_hole_data[j]
		var dh_center = dh["center"] as Vector3
		var dh_inner = dh["inner_dir"] as Vector3
		# Place just inside the opening so it doesn't light the door frame itself
		var dh_pos = dh_center + dh_inner * 0.4
		# Shadow enabled only for glass doors (sliding glass door)
		var dh_is_glass_door: bool = dh.get("has_glass", false)

		var dh_spot = SpotLight3D.new()
		dh_spot.name = "DoorFillSpot_" + str(j)
		dh_spot.position = dh_pos

		# Low energy — doors let in less light than windows (no direct sky view)
		if dh_is_glass_door:
			dh_spot.light_energy = 0.4
		else:
			dh_spot.light_energy = 0.2

		dh_spot.light_color = Color(1.0, 0.835, 0.50) # warm golden

		# Moderate cone — wide enough to spread into the room but not hemispherical
		dh_spot.spot_angle = 89.0
		dh_spot.spot_angle_attenuation = 0.1
		dh_spot.spot_range = 20.0
		dh_spot.spot_attenuation = 0.2
		dh_spot.light_specular = 0.0

		dh_spot.shadow_enabled = false # dh_is_glass_door

		add_child(dh_spot)
		# Aim 3 m into the room from the door opening
		var dh_target = dh_center + dh_inner * 3.0
		dh_spot.look_at(dh_target, Vector3.UP)
		print("  [DoorFill] ", dh["hole_type"], " fill spot at ", dh_pos, " | glass_door=", dh_is_glass_door, " shadow=", dh_is_glass_door)


func _has_fixture_lights(geom_data: Dictionary) -> bool:
	# Check for fixtures at the root level
	if geom_data.has("items"):
		var items = geom_data["items"]
		if typeof(items) == TYPE_ARRAY:
			for item in items:
				if typeof(item) == TYPE_DICTIONARY and _is_light_fixture_item(item):
					return true
		elif typeof(items) == TYPE_DICTIONARY:
			for id in items:
				if typeof(items[id]) == TYPE_DICTIONARY and _is_light_fixture_item(items[id]):
					return true
	
	# Check for fixtures within layers
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		var layers = geom_data["layers"]
		for layer_id in layers:
			var layer = layers[layer_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("items"):
				var items = layer["items"]
				if typeof(items) == TYPE_ARRAY:
					for item in items:
						if typeof(item) == TYPE_DICTIONARY and _is_light_fixture_item(item):
							return true
				elif typeof(items) == TYPE_DICTIONARY:
					for id in items:
						if typeof(items[id]) == TYPE_DICTIONARY and _is_light_fixture_item(items[id]):
							return true
	return false

func _has_authored_lights(geom_data: Dictionary) -> bool:
	if _has_fixture_lights(geom_data):
		return true
	var custom_lights: Dictionary = {}
	_collect_custom_lights_from_source(geom_data, custom_lights)
	return not custom_lights.is_empty()

func _build_custom_lights(geom_data: Dictionary) -> void:
	var custom_lights: Dictionary = {}
	_collect_custom_lights_from_source(geom_data, custom_lights)
	
	if custom_lights.is_empty():
		return
		
	print("Building ", custom_lights.size(), " custom lights.")
	for light_id in custom_lights:
		var light_data = custom_lights[light_id]
		if not light_data.get("isOn", true):
			continue
			
		var light: Light3D
		var ltype = str(light_data.get("lightKind", light_data.get("lightType", "point"))).to_lower()
		if ltype == "spot":
			light = SpotLight3D.new()
			light.spot_angle = float(light_data.get("coneAngle", 45.0))
			light.spot_range = 15.0
		else:
			light = OmniLight3D.new()
			light.omni_range = 15.0
			
		light.name = "CustomLight_" + str(light_id)
		# Crucial: mark as authored so video_render.gd doesn't overwrite its color with the global fill tint
		light.set_meta("authored_custom_light", true)
		
		var color_hex = light_data.get("color", "#ffffff")
		var base_color = Color(color_hex)
		var energy_mult = 1.0
		if light_data.has("intensityMultiplier"):
			energy_mult = float(light_data["intensityMultiplier"])
		else:
			energy_mult = float(light_data.get("brightness", 100.0)) / 100.0
		light.light_color = base_color
		
		# Map brightness to appropriate energy for Godot 4 physical light units
		var base_e = 5.0
		if not day_render:
			base_e = 15.0
			
		if ltype == "spot":
			base_e *= 4.0 # Boost spot lights so their apparent intensity matches omni lights
			
		light.light_energy = energy_mult * base_e * _lighting_illumination_scale
		
		if bool(light_data.get("castShadow", false)):
			light.shadow_enabled = true
			light.light_size = 0.18
			light.shadow_bias = 0.08
			light.shadow_normal_bias = 1.7
			light.shadow_blur = 1.35
			light.shadow_opacity = 0.78
		
		var px = float(light_data.get("x", 0.0))
		var pz = float(light_data.get("y", 0.0))
		var altitude = float(light_data.get("altitude", 0.0)) * _scene_unit_scale
		
		var transformed2d = _plan_point_2d(px, pz)
		var world_pos = Vector3(
			transformed2d.x * _scene_unit_scale,
			altitude,
			transformed2d.y * _scene_unit_scale
		)
		
		light.position = world_pos
		
		if ltype == "spot":
			var rot_y = float(light_data.get("rotationY", 0.0))
			var tilt = float(light_data.get("tiltAngle", 0.0))
			light.rotation.y = rot_y
			light.rotation.x = - deg_to_rad(tilt) if tilt != 0.0 else -PI / 2
			
		add_child(light)

func _collect_custom_lights_from_source(source: Dictionary, out_lights: Dictionary) -> void:
	if typeof(source) != TYPE_DICTIONARY or source.is_empty():
		return

	if source.has("customLights") and typeof(source["customLights"]) == TYPE_DICTIONARY:
		var raw_lights: Dictionary = source["customLights"]
		for light_id in raw_lights:
			out_lights[str(light_id)] = raw_lights[light_id]
	if source.has("sceneLights") and typeof(source["sceneLights"]) == TYPE_DICTIONARY:
		var raw_lights: Dictionary = source["sceneLights"]
		for light_id in raw_lights:
			out_lights[str(light_id)] = raw_lights[light_id]

	if source.has("layers") and typeof(source["layers"]) == TYPE_DICTIONARY:
		var layers: Dictionary = source["layers"]
		var selected_layer = str(source.get("selectedLayer", "")).strip_edges()

		var layer_ids: Array = []
		if selected_layer != "" and layers.has(selected_layer):
			layer_ids.append(selected_layer)
		else:
			for layer_id in layers:
				layer_ids.append(layer_id)

		for layer_id in layer_ids:
			var layer = layers[layer_id]
			if typeof(layer) != TYPE_DICTIONARY:
				continue
			if layer.has("customLights") and typeof(layer["customLights"]) == TYPE_DICTIONARY:
				var layer_lights: Dictionary = layer["customLights"]
				for light_id in layer_lights:
					out_lights[str(light_id)] = layer_lights[light_id]
			if layer.has("sceneLights") and typeof(layer["sceneLights"]) == TYPE_DICTIONARY:
				var layer_lights: Dictionary = layer["sceneLights"]
				for light_id in layer_lights:
					out_lights[str(light_id)] = layer_lights[light_id]

		if out_lights.is_empty():
			for layer_id in layers:
				if selected_layer != "" and layer_id == selected_layer:
					continue
				var layer = layers[layer_id]
				if typeof(layer) != TYPE_DICTIONARY:
					continue
				if layer.has("customLights") and typeof(layer["customLights"]) == TYPE_DICTIONARY:
					var layer_lights: Dictionary = layer["customLights"]
					for light_id in layer_lights:
						out_lights[str(light_id)] = layer_lights[light_id]
				if layer.has("sceneLights") and typeof(layer["sceneLights"]) == TYPE_DICTIONARY:
					var layer_lights: Dictionary = layer["sceneLights"]
					for light_id in layer_lights:
						out_lights[str(light_id)] = layer_lights[light_id]

	if source.has("floor_plan_data"):
		var fp = source["floor_plan_data"]
		if typeof(fp) == TYPE_DICTIONARY:
			_collect_custom_lights_from_source(fp, out_lights)
		elif typeof(fp) == TYPE_STRING:
			var fp_json = JSON.new()
			if fp_json.parse(fp) == OK and typeof(fp_json.data) == TYPE_DICTIONARY:
				_collect_custom_lights_from_source(fp_json.data, out_lights)

func _apply_item_materials(node: Node3D, item: Dictionary) -> void:
	if item.has("materials") and typeof(item["materials"]) == TYPE_DICTIONARY:
		var item_mats = item["materials"]
		var applied_material_keys = {}
		var limit_single_generic_key = item_mats.size() == 1
		if limit_single_generic_key:
			var only_key = str(item_mats.keys()[0])
			limit_single_generic_key = _material_key_is_generic(only_key)
		var meshes = _get_all_meshes(node)
		for m in meshes:
			if not m.mesh: continue
			for i in range(m.mesh.get_surface_count()):
				var mat = m.get_active_material(i)
				if mat and mat is StandardMaterial3D:
					var mat_name = str(mat.resource_name)
					var surface_name = str(m.mesh.surface_get_name(i))

					var matched_key = ""
					for key in item_mats:
						if _material_key_matches_surface(str(key), mat_name, surface_name):
							matched_key = key
							break

					if matched_key == "" and item_mats.size() == 1 and m.mesh.get_surface_count() == 1:
						matched_key = item_mats.keys()[0]

					if matched_key != "":
						var matched_key_text = str(matched_key)
						var mat_opt = item_mats[matched_key]
						if typeof(mat_opt) == TYPE_DICTIONARY:
							var new_mat = mat.duplicate()
							var modified = false

							var asset_map_url = ""
							if mat_opt.has("mapUrl") and mat_opt["mapUrl"] != null and str(mat_opt["mapUrl"]) != "":
								asset_map_url = str(mat_opt["mapUrl"])
							elif mat_opt.has("texture_urls") and typeof(mat_opt["texture_urls"]) == TYPE_ARRAY and mat_opt["texture_urls"].size() > 0:
								asset_map_url = str(mat_opt["texture_urls"][0])
							var has_texture = asset_map_url != ""

							var has_asset_color = false
							if item.get("is_exterior_black", false):
								new_mat.albedo_color = Color.BLACK
								has_asset_color = true
								modified = true
							elif mat_opt.has("color"):
								var c_str = str(mat_opt.get("color", "ffffff")).strip_edges()
								if c_str.length() >= 3 and not c_str.begins_with("#"):
									c_str = "#" + c_str
								if c_str.is_valid_html_color():
									new_mat.albedo_color = Color(c_str)
									has_asset_color = true
									modified = true

							if has_texture:
								var albedo_tex = load_texture_from_path(asset_map_url)
								if albedo_tex:
									new_mat.albedo_texture = albedo_tex
									if not has_asset_color:
										new_mat.albedo_color = Color(1.0, 1.0, 1.0)
									modified = true
							elif has_asset_color:
								new_mat.albedo_texture = null

							if mat_opt.has("normalUrl") and mat_opt["normalUrl"] != null and str(mat_opt["normalUrl"]) != "":
								var normal_tex = load_texture_from_path(str(mat_opt["normalUrl"]))
								if normal_tex:
									new_mat.normal_enabled = true
									new_mat.normal_texture = normal_tex
									modified = true

							if mat_opt.has("roughnessUrl") and mat_opt["roughnessUrl"] != null and str(mat_opt["roughnessUrl"]) != "":
								var rough_tex = load_texture_from_path(str(mat_opt["roughnessUrl"]))
								if rough_tex:
									new_mat.roughness_texture = rough_tex
									new_mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
									modified = true

							if item.get("is_exterior_black", false):
								new_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

							var scale_u = new_mat.uv1_scale.x
							var scale_v = new_mat.uv1_scale.y
							var changed_scale = false

							if mat_opt.has("repeat"):
								var r = mat_opt["repeat"]
								if typeof(r) == TYPE_ARRAY and r.size() >= 2:
									scale_u = float(r[0]) if float(r[0]) > 0 else 1.0
									scale_v = float(r[1]) if float(r[1]) > 0 else 1.0
									changed_scale = true

							if mat_opt.has("scale"):
								var s = mat_opt["scale"]
								if typeof(s) == TYPE_ARRAY and s.size() >= 2:
									scale_u = float(s[0]) if float(s[0]) > 0 else scale_u
									scale_v = float(s[1]) if float(s[1]) > 0 else scale_v
									changed_scale = true
								elif typeof(s) == TYPE_FLOAT or typeof(s) == TYPE_INT:
									var sf = float(s)
									if sf > 0:
										scale_u = sf; scale_v = sf
										changed_scale = true
								elif typeof(s) == TYPE_STRING and s.is_valid_float():
									var sf = float(s)
									if sf > 0:
										scale_u = sf; scale_v = sf
										changed_scale = true

							if changed_scale:
								new_mat.uv1_scale = Vector3(scale_u, scale_v, 1.0)
								modified = true

							if modified:
								# --- Inline material optimizer for glass (matches image_glb_creation.gd) ---
								var opt_path = asset_map_url.to_lower().get_file()
								if "glass" in opt_path or "glaz" in opt_path or "window" in opt_path:
									new_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
									new_mat.roughness = 0.01
									new_mat.metallic_specular = 1.0
									if new_mat.albedo_color.a > 0.95:
										new_mat.albedo_color.a = 0.35
									print("  [Optimizer] Glass detected in GLB material -> enabling alpha-transparency.")
								# -------------------------------------------------------------------------

								m.set_surface_override_material(i, new_mat)
								applied_material_keys[matched_key_text] = true
								if limit_single_generic_key:
									break

			if limit_single_generic_key and applied_material_keys.size() > 0:
				break


# ==============================================================================
# PAVING / TILING OVERLAY SYSTEM
# ==============================================================================
# JSON schema (floor_properties.paving):
#   pattern      : 'grid' | 'brickwork' | 'stagger' | 'herringbone' | 'chevron'
#   gapMode      : 'false' | 'real'   (default 'false' = visual seam only)
#   gapMm        : number             (gap width mm, only used for 'real')
#   gapColorMode : 'custom' | 'material'
#   gapColor     : '#rrggbb'          (only when gapColorMode == 'custom')
# ==============================================================================

func _build_paving_overlay(
		area_id: String,
		pattern: String,
		pav_cfg: Dictionary,
		uv_polygon: PackedVector2Array,
		layer_altitude: float,
		floor_span: Vector2,
		material_data: Dictionary
) -> void:
	# -- Tile dimensions (match frontend AreaMaterialConfig) ---
	# repeatX / repeatY on material = tile WIDTH/HEIGHT in mm.
	# _scene_unit_scale converts source units to metres.
	var tile_w_mm4: float = 1000.0
	var tile_h_mm4: float = 1000.0
	if material_data.has("repeatX") and float(material_data["repeatX"]) > 0.0:
		tile_w_mm4 = float(material_data["repeatX"])
	if material_data.has("repeatY") and float(material_data["repeatY"]) > 0.0:
		tile_h_mm4 = float(material_data["repeatY"])
	var tile_w: float = clamp(tile_w_mm4 * _scene_unit_scale, 0.05, 5.0)
	var tile_h: float = clamp(tile_h_mm4 * _scene_unit_scale, 0.05, 5.0)
	# ── AABB of the room polygon ───────────────────────────────────────────────
	var min_x = 1e9; var max_x = -1e9
	var min_y = 1e9; var max_y = -1e9
	for pt in uv_polygon:
		min_x = min(min_x, pt.x); max_x = max(max_x, pt.x)
		min_y = min(min_y, pt.y); max_y = max(max_y, pt.y)
	var bounds_min = Vector2(min_x, min_y)
	var bounds_max = Vector2(max_x, max_y)

	# ── Generate tile list ─────────────────────────────────────────────────────
	var tiles: Array = []
	match pattern:
		"grid":
			tiles = _paving_grid(bounds_min, bounds_max, tile_w, tile_h)
		"brickwork":
			tiles = _paving_brick(bounds_min, bounds_max, tile_w, tile_h, 0.5)
		"stagger":
			tiles = _paving_brick(bounds_min, bounds_max, tile_w, tile_h, 1.0 / 3.0)
		"herringbone":
			tiles = _paving_herringbone(bounds_min, bounds_max, tile_w, tile_h)
		"chevron":
			tiles = _paving_chevron(bounds_min, bounds_max, tile_w, tile_h)
		_:
			return

	if tiles.is_empty():
		print("[Paving] No tiles generated for pattern '", pattern, "' — skipping.")
		return

	# ── Gap / grout settings ───────────────────────────────────────────────────
	# gapMode 'false' = visual seam (2 mm physical shrink so grout shows through)
	# gapMode 'real'  = full mortar joint using gapMm value
	var gap_mode = str(pav_cfg.get("gapMode", "false")).strip_edges().to_lower()
	var gap_mm = float(pav_cfg.get("gapMm", 5.0))
	var gap_real = (gap_mode == "real" and gap_mm > 0.1)
	# Effective shrink in metres:
	#   real  → half the grout joint on each side of the tile
	#   false → fixed 1 mm visual seam (matches frontend stroke width ~= 1 px at 1 mm/px)
	var shrink_m: float = 0.001
	if gap_real:
		shrink_m = clamp(gap_mm * _scene_unit_scale * 0.5, 0.0005, 0.05)

	# Grout / seam color
	# Priority 1: gapColor present in JSON → always use it (gapColorMode may be absent)
	# Priority 2: gapColorMode == 'custom' with gapColor
	# Priority 3: gapColorMode == 'material' → lighten the floor material colour
	# Priority 4: off-white default
	var grout_color: Color = Color(0.92, 0.90, 0.88) # off-white default
	var gap_color_mode = str(pav_cfg.get("gapColorMode", "none")).strip_edges().to_lower()
	var has_gap_color = pav_cfg.has("gapColor") and str(pav_cfg.get("gapColor", "")).strip_edges() != ""
	if has_gap_color:
		# gapColor set explicitly → use it directly (covers both custom and legacy JSON)
		grout_color = Color(str(pav_cfg["gapColor"]))
	elif gap_color_mode == "material":
		# Use a lightened version of the floor material colour as cement grout
		if material_data.has("color") and str(material_data["color"]).strip_edges() != "":
			var mat_col = Color(str(material_data["color"]))
			grout_color = mat_col.lightened(0.55) # noticeably lighter than tile

	# ── Tile material ──────────────────────────────────────────────────────────
	var tile_mat: StandardMaterial3D
	if material_data.is_empty():
		tile_mat = StandardMaterial3D.new()
		tile_mat.albedo_color = Color(0.85, 0.82, 0.78)
	else:
		tile_mat = create_material(material_data)
		# Apply texture scale so texture fills individual tiles (not the whole room)
		var per_tile_span = Vector2(tile_w, tile_h)
		tile_mat = _apply_architecture_texture_scale(tile_mat, material_data, per_tile_span)
	# Ensure winding/shading is correct for the tile top face
	var per_tile_mat: StandardMaterial3D = tile_mat.duplicate()
	per_tile_mat.cull_mode = BaseMaterial3D.CULL_BACK

	# ── Grout material — ALWAYS created ────────────────────────────────────────
	# A full-room slab sits 1 mm below the tile tops so it peeks through the seams.
	# This is how the frontend 3D preview shows colour between tiles.
	var grout_mat = StandardMaterial3D.new()
	grout_mat.albedo_color = grout_color
	grout_mat.roughness = 0.90
	grout_mat.metallic = 0.0

	# ── Parent node ────────────────────────────────────────────────────────────
	var pav_root = Node3D.new()
	pav_root.name = "PavingOverlay_" + area_id
	add_child(pav_root)

	var tile_y = layer_altitude + 0.002 # 2 mm above base floor slab
	var tile_depth = 0.004 # 4 mm ceramic / plank thickness

	# ── Grout slab — placed FIRST so tiles render on top ───────────────────────
	var grout_slab = CSGPolygon3D.new()
	grout_slab.name = "PavGrout_" + area_id
	grout_slab.polygon = uv_polygon
	grout_slab.mode = CSGPolygon3D.MODE_DEPTH
	grout_slab.depth = tile_depth
	grout_slab.rotation.x = PI / 2
	grout_slab.position.y = tile_y - 0.001 # 1 mm below tile surfaces → shows in seams
	grout_slab.material = grout_mat
	pav_root.add_child(grout_slab)

	# ── Emit tile slabs ─────────────────────────────────────────────────────────
	var tile_idx = 0
	for tile in tiles:
		var tile_poly_raw: Array = tile["polygon"]
		if tile_poly_raw.size() < 3:
			continue

		var tile_pts = PackedVector2Array()
		for p in tile_poly_raw:
			tile_pts.append(Vector2(float(p.x), float(p.y)))

		var clipped = Geometry2D.intersect_polygons(tile_pts, uv_polygon)
		if clipped.is_empty():
			continue

		for clip_poly in clipped:
			if clip_poly.size() < 3:
				continue

			# Shrink tile inward to expose the grout slab below
			var render_poly = clip_poly
			var shrunk = Geometry2D.offset_polygon(clip_poly, -shrink_m)
			if shrunk.size() > 0 and shrunk[0].size() >= 3:
				render_poly = shrunk[0]

			# Ensure CCW winding
			var sa2 = 0.0
			for pi in range(render_poly.size()):
				var pa2 = render_poly[pi]
				var pb2 = render_poly[(pi + 1) % render_poly.size()]
				sa2 += pa2.x * pb2.y - pb2.x * pa2.y
			if sa2 < 0:
				render_poly.reverse()

			var tp = CSGPolygon3D.new()
			tp.name = "PavTile_%s_%d" % [area_id, tile_idx]
			tp.polygon = render_poly
			tp.mode = CSGPolygon3D.MODE_DEPTH
			tp.depth = tile_depth
			tp.rotation.x = PI / 2
			tp.position.y = tile_y
			tp.material = per_tile_mat
			pav_root.add_child(tp)
			tile_idx += 1

	print("[Paving] Emitted ", tile_idx, " tiles + grout slab for area ", area_id)
	print("[Paving] Grout color: ", grout_color, " | shrink: ", shrink_m * 1000.0, " mm")


# ── Tile pattern generators ────────────────────────────────────────────────────
# Each returns an Array of Dictionaries:
#   { polygon: Array[{x,y}], cx: float, cy: float, angle: float }
# Coordinates are in world metres (same space as uv_polygon).

func _paving_grid(bmin: Vector2, bmax: Vector2, tw: float, th: float) -> Array:
	var tiles: Array = []
	var y = bmin.y
	while y < bmax.y:
		var x = bmin.x
		while x < bmax.x:
			tiles.append({
				"polygon": [
					{"x": x, "y": y},
					{"x": x + tw, "y": y},
					{"x": x + tw, "y": y + th},
					{"x": x, "y": y + th},
				],
				"cx": x + tw * 0.5, "cy": y + th * 0.5, "angle": 0.0
			})
			x += tw
		y += th
	return tiles

func _paving_brick(bmin: Vector2, bmax: Vector2, tw: float, th: float, offset_frac: float) -> Array:
	var tiles: Array = []
	var row = 0
	var y = bmin.y
	while y < bmax.y:
		var shift = fmod(float(row) * offset_frac, 1.0) * tw
		var x = bmin.x - tw + shift
		while x < bmax.x:
			tiles.append({
				"polygon": [
					{"x": x, "y": y},
					{"x": x + tw, "y": y},
					{"x": x + tw, "y": y + th},
					{"x": x, "y": y + th},
				],
				"cx": x + tw * 0.5, "cy": y + th * 0.5, "angle": 0.0
			})
			x += tw
		row += 1
		y += th
	return tiles

func _paving_herringbone(bmin: Vector2, bmax: Vector2, tw: float, th: float) -> Array:
	var tiles: Array = []
	var cx0 = (bmin.x + bmax.x) * 0.5
	var cy0 = (bmin.y + bmax.y) * 0.5
	var diag = sqrt(pow(bmax.x - bmin.x, 2) + pow(bmax.y - bmin.y, 2)) + tw + th
	var cos_r = sqrt(0.5)
	var sin_r = sqrt(0.5)
	var row = 0
	var v = - diag
	while v < diag:
		var row_shift = 0.0 if (row % 2 == 0) else (tw + th) * 0.5
		var u = - diag + row_shift
		while u < diag:
			_hb_push_rect(tiles, u, v, u + tw, v + th, 0.0, cos_r, sin_r, cx0, cy0)
			_hb_push_rect(tiles, u + tw, v - (tw - th), u + tw + th, v + th, PI * 0.5, cos_r, sin_r, cx0, cy0)
			u += (tw + th)
		row += 1
		v += th
	return tiles

func _hb_push_rect(
		out: Array,
		u0: float, v0: float, u1: float, v1: float,
		local_angle: float,
		cos_r: float, sin_r: float,
		cx0: float, cy0: float
) -> void:
	var ucx = (u0 + u1) * 0.5
	var vcy = (v0 + v1) * 0.5
	var to_world = func(u: float, v: float) -> Dictionary:
		return {"x": cx0 + u * cos_r - v * sin_r, "y": cy0 + u * sin_r + v * cos_r}
	out.append({
		"polygon": [
			to_world.call(u0, v0), to_world.call(u1, v0),
			to_world.call(u1, v1), to_world.call(u0, v1),
		],
		"cx": cx0 + ucx * cos_r - vcy * sin_r,
		"cy": cy0 + ucx * sin_r + vcy * cos_r,
		"angle": local_angle + PI * 0.25
	})

func _paving_chevron(bmin: Vector2, bmax: Vector2, tw: float, th: float) -> Array:
	var tiles: Array = []
	var L = tw
	var h = th
	var row = 0
	var y = bmin.y - h
	while y < bmax.y + h:
		var right_slant = (row % 2 == 0)
		var x = bmin.x - L * 2.0
		while x < bmax.x + L:
			var polygon: Array
			var cx: float
			var tile_angle: float
			var cy = y + h * 0.5
			if right_slant:
				polygon = [
					{"x": x, "y": y},
					{"x": x + L, "y": y},
					{"x": x + L + h, "y": y + h},
					{"x": x + h, "y": y + h},
				]
				cx = x + L * 0.5 + h * 0.5
				tile_angle = PI * 0.25
			else:
				polygon = [
					{"x": x + h, "y": y},
					{"x": x + L + h, "y": y},
					{"x": x + L, "y": y + h},
					{"x": x, "y": y + h},
				]
				cx = x + L * 0.5 + h * 0.5
				tile_angle = - PI * 0.25
			tiles.append({"polygon": polygon, "cx": cx, "cy": cy, "angle": tile_angle})
			x += L
		row += 1
		y += h
	return tiles
