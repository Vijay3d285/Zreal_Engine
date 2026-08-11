extends Node3D
const MOImage = preload("res://mo_image.gd")
# image_glb_creation.gd
# Handles the construction of the scene: Architecture (Walls, Floors, Ceilings) and Asset Loading.

const ENABLE_DUPLICATION = true
const LOW_TEXTURE_QUALITY = false

var _tracked_assets = []
var _window_sunlight_data = [] # Collected during hole building, used to place window sunlights
var _door_hole_data = [] # Collected during hole building, used for subtle door fill lights
var _exterior_assets = [] # Tracks trees/plants/etc for shadow optimization
var _dir_light: DirectionalLight3D = null
var _directional_light_authoring_locked: bool = false
var _interior_shadow_clusters := {}
var _glb_cache := {}
var _texture_cache := {}
var day_render = true
var lighting_profile = "day"
const ENABLE_PROCEDURAL_WINDOW_GRID_CASTER = false
# Global kill-switch for room reflection probes.
# true  -> build and use the reflection probe
# false -> skip probe creation entirely
const USE_REFLECTION_PROBE = true
# When true, only create the probe if the scene contains reflective surfaces
# such as floor tile, glass, mirror, polished stone, or metal materials.
const USE_REFLECTION_PROBE_ONLY_FOR_REFLECTIVE_SURFACES = true
# When true, reflective floor/metal/glass materials get a small response boost
# so the probe is actually visible on the intended surfaces.
const USE_REFLECTION_RESPONSE_ASSIST = true
# Global kill-switch for the material optimizer.
# true  -> apply optimizer presets / overrides
# false -> keep raw material values from the JSON / asset defaults
const USE_MATERIAL_OPTIMIZER = false # true
# Global kill-switch for reflection probe material hotspot blurring
const USE_REFLECTION_PROBE_HOTSPOT_FIX = true
# Global kill-switch for the UnrealPostFX compositor effect (tonemapping, CDL,
# vignette, chromatic aberration, film grain).
# true  -> attach the compositor effect to the Camera3D at render time
# false -> skip entirely (safe rollback, raw Godot output)
const USE_POST_FX = false
# Must match the video scene builder so floor and ceiling textures stay
# consistent across both render paths.
const FLOOR_CEIL_TEXTURE_DENSITY_BOOST: float = 2.0
var _camera_pose = {
	"position": Vector3.ZERO,
	"target": Vector3.ZERO
}
var _camera_height_m: float = 0.0
var _scene_unit_scale: float = 0.01
var _scene_rotation_is_radians: bool = false
var _scene_plan_rotation_radians: float = 0.0
var _scene_plan_pivot: Vector2 = Vector2.ZERO
var _floor_plan_root_data: Dictionary = {}
var structure_builder
var _lighting_color_mood: String = "day"
var _lighting_illumination_scale: float = 1.0
var _image_render_only: bool = false
# Count of ceiling_mount light fixtures in the scene — used by sqrt normalization
# to prevent n fixtures from contributing n× the intended luminance additively.
var _ceiling_fixture_count: int = 1
# Room center cached from setup_lighting — used by the companion shadow-caster.
var _room_center: Vector3 = Vector3.ZERO

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

	# Version 2.0.0 stores floor-plan measurements in millimetres.
	# Older inputs keep the legacy centimetre-based plan coordinates.
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
	# The editor stores the room orientation as the forward-facing angle of the
	# plan, so world placement needs the inverse rotation.
	return -deg_to_rad(angle_deg)

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

func _rotation_to_radians(raw_rotation: float) -> float:
	if _scene_rotation_is_radians:
		return raw_rotation
	return deg_to_rad(raw_rotation)

func _world_yaw_from_source_rotation(raw_rotation: float) -> float:
	# Use the same yaw conversion for both legacy and 2.0.0 JSON.
	# Legacy inputs are degrees, new inputs are radians.
	return -_rotation_to_radians(raw_rotation)

func _item_front_axis_correction() -> float:
	# New editor exports should respect the authored item rotation directly.
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

func _kelvin_to_rgb(kelvin: float) -> Color:
	var temp = kelvin / 100.0
	var r: float
	var g: float
	var b: float

	if temp <= 66:
		r = 255
		g = temp
		g = 99.4708025861 * log(g) - 161.1195681661
		if temp <= 19:
			b = 0
		else:
			b = temp - 10
			b = 138.5177312231 * log(b) - 305.0447927307
	else:
		r = temp - 60
		r = 329.698727446 * pow(r, -0.1332047592)
		g = temp - 60
		g = 288.1221695283 * pow(g, -0.0755148492)
		b = 255

	return Color(
		clamp(r / 255.0, 0.0, 1.0),
		clamp(g / 255.0, 0.0, 1.0),
		clamp(b / 255.0, 0.0, 1.0)
	)

func _plan_point_2d(x: float, y: float) -> Vector2:
	var point = Vector2(x, y) - _scene_plan_pivot
	if abs(_scene_plan_rotation_radians) > 0.000001:
		point = point.rotated(_scene_plan_rotation_radians)
	point += _scene_plan_pivot
	return point

func _plan_point_3d(x: float, y: float, world_y: float = 0.0) -> Vector3:
	var point = _plan_point_2d(x, y)
	return Vector3(point.x * _scene_unit_scale, world_y, point.y * _scene_unit_scale)

func _plan_value_to_meters(value) -> float:
	return get_dimension_value(value) * _scene_unit_scale


func _transform_plan_point_meters(point: Vector3) -> Vector3:
	if abs(_scene_plan_rotation_radians) < 0.000001:
		return point
	var scale = max(_scene_unit_scale, 0.000001)
	var transformed = _plan_point_2d(point.x / scale, point.z / scale)
	return Vector3(transformed.x * scale, point.y, transformed.y * scale)

# ==============================================================================
# SCENE INITIALIZATION (MAIN ENTRY POINT)
# ==============================================================================
# WHY IT EXISTS: This is the main conductor function. It triggers the entire 
# rendering pipeline in order: setting global scales, generating lighting, 
# building 3D walls/floors, building custom stairs/shapes, and loading furniture.
# ==============================================================================
func build_scene(data):
	structure_builder = preload("res://structure.gd").new(self)
	lighting_profile = _resolve_lighting_profile(data)
	day_render = lighting_profile != "night"
	_interior_shadow_clusters.clear()

	var geom_data = data
	if data.has("floor_plan_data"):
		var fp = data["floor_plan_data"]
		if typeof(fp) == TYPE_STRING:
			var json = JSON.new()
			var err = json.parse(fp)
			if err == OK:
				geom_data = json.data
				print("Parsed floor_plan_data from string.")
			else:
				print("Error parsing floor_plan_data string: ", json.get_error_message())
		else:
			geom_data = fp

	_scene_unit_scale = _resolve_scene_unit_scale(data, geom_data)
	_scene_rotation_is_radians = _resolve_scene_rotation_is_radians(data, geom_data)
	_scene_plan_rotation_radians = _resolve_scene_plan_rotation_radians(data, geom_data)
	_scene_plan_pivot = _resolve_scene_plan_pivot(data, geom_data)
	_floor_plan_root_data = geom_data if typeof(geom_data) == TYPE_DICTIONARY else {}

	# Resolve the camera after the scene scale/rotation globals are ready so
	# camera-dependent culling uses the same coordinate frame as the geometry.
	_camera_pose = _extract_camera_pose(data)
	_camera_height_m = float(_camera_pose["position"].y)

	print("Using scene unit scale: ", _scene_unit_scale, " meters per source unit")
	print("Using radians for plan rotations: ", _scene_rotation_is_radians)
	print("Using plan rotation (radians): ", _scene_plan_rotation_radians)
	print("Using plan pivot (source units): ", _scene_plan_pivot)

	setup_lighting(data, geom_data)

	_window_sunlight_data.clear()
	_door_hole_data.clear()
	build_architecture(geom_data)
	# _create_window_sunlights()  # Place sunlights through detected windows
	build_structures(geom_data)
	load_assets(geom_data)
	
	_build_custom_lights(geom_data)
	
	if USE_REFLECTION_PROBE:
		_generate_localized_reflection_probes(geom_data)
	
	if day_render:
		_create_window_portal_lights()
		# _create_day_ambient_fill(geom_data) -- NOT used in PT: every OmniLight casts
		# PT shadows regardless of shadow_enabled. Use ambient_light_energy instead.
		if _dir_light and not _directional_light_authoring_locked:
			_orient_directional_light_from_windows(_dir_light)
		
		# VoxelGI for high-quality day bounce lighting
		_setup_voxel_gi(geom_data)

	_apply_anisotropic_filtering_to_all(self)
	# setup_camera(data) - Moved to render_image.gd

# ==============================================================================
# DAY AMBIENT FILL LIGHT
# ==============================================================================
# WHY IT EXISTS: _create_window_portal_lights() is disabled because it caused
# overexposure and timing issues in the PT pipeline. Without it the room is
# correctly lit only where sunlight directly hits and in window zones, leaving
# all non-sunlit surfaces too dark for a realistic 10AM interior look.
# This function places a single shadow-free OmniLight3D at the room center,
# mid-ceiling height, to replicate the diffuse sky bounce that would naturally
# fill an interior from a large window wall in morning light.
# light_specular = 0 prevents the circular hotspot artifact that appears on
# reflective/glassy/polished-floor materials from omni lights.
# ==============================================================================
func _create_day_ambient_fill(geom_data) -> void:
	var room_info = _extract_room_lighting_bounds(geom_data)
	var room_center: Vector3 = room_info.get("center", _room_center)
	var room_extent: Vector2 = room_info.get("extent", Vector2(6.0, 6.0))
	var room_ceiling_y: float = room_info.get("ceiling_y", room_center.y + 2.8)

	# Position at vertical room center — midpoint between floor (room_center.y)
	# and ceiling (room_ceiling_y) — so the OmniLight spreads evenly up and down.
	var light_y = (room_center.y + room_ceiling_y) * 0.5

	var fill = OmniLight3D.new()
	fill.name = "DayAmbientFill"
	fill.position = Vector3(room_center.x, light_y, room_center.z)

	# Energy 3.5: equivalent to portal system total output (SpotLight 2.0 + OmniLight 0.6 per window).
	# A single central OmniLight needs this level to fill the room as evenly as the portal system did.
	fill.light_energy = 0.8

	# 10AM warm white - same color as portal SpotLight.
	fill.light_color = Color(1.0, 0.93, 0.80)

	# Range: full room diagonal + generous padding so all corners are reached.
	var room_diag = sqrt(room_extent.x * room_extent.x + room_extent.y * room_extent.y)
	fill.omni_range = room_diag * 1.5 + 6.0

	# Specular = 0: prevents the circular gloss hotspot artifact on
	# marble/tile/glass that omni lights cause when placed at room center.
	fill.light_specular = 0.0

	fill.shadow_enabled = false
	add_child(fill)
	print("[DayAmbientFill] Placed at ", fill.position, " energy=3.5 range=", snappedf(fill.omni_range, 0.1))

func _setup_voxel_gi(geom_data):
	print("[VoxelGI] Setting up VoxelGI for Day Render...")
	var room_info = _extract_room_lighting_bounds(geom_data)
	var room_center: Vector3 = room_info.get("center", _room_center)
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

# ==============================================================================
# PHOTOREALISTIC LIGHTING SETUP
# ==============================================================================
# WHY IT EXISTS: To dynamically build realistic lighting based on the requested 
# "mood" (e.g. warm, cool, night, day). It sets up the sun, ambient bounce 
# lighting (SDFGI), screen-space indirect lighting (SSIL), and colour grading 
# to ensure the final render looks like a photograph instead of a flat game.
# ==============================================================================
func setup_lighting(data, geom_data = {}):
	var lighting = _get_lighting_profile_settings()
	_lighting_color_mood = _resolve_color_mood(data)
	if day_render:
		# Day renders should stay neutral; mood tinting is reserved for night.
		_lighting_color_mood = "day"
	_lighting_illumination_scale = _resolve_illumination_scale(data)

	# Camera and room bounds are used for fill lighting and room-wide effects.
	var cam_pose = _extract_camera_pose(data)
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

	# Cache room_center for use inside _add_light_fixture_effect (companion shadow-caster).
	_room_center = room_center

	# --- Primary Directional Light (Sun / Moon) ---

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

	# CRITICAL: add_child BEFORE look_at
	add_child(dir_light)
	_dir_light = dir_light

	# ── Shadow Atlas Resolution — Scaled to Output Resolution ─────────────────
	# Default Godot shadow atlas = 4096. At 4K (3840×2160) this produces
	# pixelated/jagged shadow edges on tree leaves, furniture and window frames.
	# Rule: shadow atlas ≥ 4× render height for clean edges.
	#   1080p → 4096  |  1440p → 8192  |  4K → 16384
	# use_16_bit=false → 32-bit depth = better precision, no shadow acne.
	var _vp_h = get_viewport().size.y
	var _shadow_atlas: int
	if _vp_h >= 2000:
		_shadow_atlas = 16384
	elif _vp_h >= 1300:
		_shadow_atlas = 8192
	else:
		_shadow_atlas = 4096
	RenderingServer.directional_shadow_atlas_set_size(_shadow_atlas, false)
	print("[Shadow] Viewport height=", _vp_h, " → shadow atlas=", _shadow_atlas)

	# ── Sun Energy and Color ──────────────────────────────────────────
	# DAY RENDERS: Ignore JSON energy/color entirely.
	# The JSON sends directional:4 with color {r:1,g:1,b:1} (pure cold white) which
	# kills the golden warmth. We hardcode the correct photorealistic sun values so
	# the render always looks like the warm golden reference image, not a white lab.
	#
	# NIGHT RENDERS: Still read from JSON so authored night moods are respected.
	var dir_energy = lighting["dir_energy"]
	var dir_color = lighting["dir_color"]

	if day_render:
		# 6.0 gives physically realistic PT sunlight — the path tracer needs high
		# directional energy to bounce enough photons off walls/floor and fill the interior.
		# Without portal lights, this is the sole light source driving GI bounces.
		dir_energy = 1.0
		dir_color = Color(1.0, 0.835, 0.50) # Color(1.0, 0.93, 0.76) 10AM sunlight — warm golden white
		print("[Sun] Day render: 10AM sunlight energy=6.0, blur=1.2, angular=0.8 (soft shadows).")
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

	# For day renders the energy is already physical — do NOT multiply by illumination scale.
	# That scale represents interior fixture dimming, not sunlight intensity.
	# Night renders still scale so fixture-driven moods work correctly.
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

	_apply_directional_light_pose_from_json(dir_light, data)
	
	# Force sun energy to 0 if night render
	if not day_render:
		dir_light.light_energy = 0.0
		dir_light.visible = false
	# --- Sky / Environment ---

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
			print("Loaded EXR sky background: ", exr_path)
		else:
			print("Warning: Failed to load EXR: ", exr_path, " Error: ", load_err)
	else:
		print("Warning: EXR sky file not found: ", exr_path)

	if not sky_material_set:
		var sky_mat = ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = lighting["sky_top_color"]
		sky_mat.sky_horizon_color = lighting["sky_horizon_color"]
		sky_mat.ground_bottom_color = lighting["ground_bottom_color"]
		sky_mat.ground_horizon_color = lighting["ground_horizon_color"]
		sky_mat.sun_angle_max = lighting["sun_angle_max"]
		sky_mat.sun_curve = lighting["sun_curve"]
		env.sky.sky_material = sky_mat
		print("Using fallback procedural sky")

	# --- Ambient Light ---
	# DAY RENDERS: Use SKY as ambient source.
	# The EXR panorama sky is a real daylight HDR — using it as ambient means the
	# entire sky dome contributes light to interior surfaces, naturally illuminating
	# the ceiling, far walls and corners without any fake fill lights.
	# This is the physically correct way to spread sunlight through a window.
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
		# exposure=1.0: let PT handle brightness naturally.
		env.tonemap_exposure = 1.5 # 1.4
		# ambient_light_energy=6.0: in the PT engine this is the sky dome energy sampled
		# from ALL directions to fill dark corners and shadowed walls. Unlike an OmniLight
		# it has no position, no shadow rays, and casts no shadows — it is purely an
		# environment contribution integrated across the hemisphere at each surface point.
		env.ambient_light_energy = 6.0
		env.ambient_light_color = Color(1.0, 0.835, 0.50) # Color(1.0, 0.95, 0.85)
		print("[Lighting] Day PT: exposure=1.0, sky ambient energy=6.0")
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
		# Night PT: SDFGI provides fill for surfaces that PT under-samples at 24 SPP
		# (occluded backs, engraving crevices). Raised bounce_feedback so indirect
		# light reaches recessed geometry without causing overexposure.
		env.sdfgi_normal_bias = 1.5
		env.sdfgi_probe_bias = 1.2
		if mood_key == "warm":
			env.sdfgi_bounce_feedback = 0.40 # Up from 0.25 — more fill on occluded surfaces
			env.sdfgi_energy = 0.35 # Up from 0.28 — visible indirect on dark backs
		else:
			env.sdfgi_bounce_feedback = 0.35 # Up from 0.20 — engraving/relief detail visible
			env.sdfgi_energy = 0.30 # Up from 0.22 — without PT double-count risk

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
		# Night PT: SSIL at 0.8 adds strong screen-space fill on top of PT bounce → washout.
		# Reduce to a light touch; PT already gives physically correct indirect light.
		if mood_key == "warm":
			env.ssil_radius = 3.0
			env.ssil_intensity = 0.25
		else:
			env.ssil_radius = 3.0
			env.ssil_intensity = 0.20

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
		# 1.05 was too flat — shadow under sofa/plants looked same as lit floor.
		env.adjustment_contrast = 1.10
		env.adjustment_saturation = 1.05
	elif mood_key == "warm":
		env.adjustment_brightness = 0.92
		env.adjustment_contrast = 1.35
		env.adjustment_saturation = 1.05
	else:
		env.adjustment_brightness = 0.92
		env.adjustment_contrast = 1.35
		env.adjustment_saturation = 1.10

	# ── NVIDIA RTX Path Tracing ────────────────────────────────────────────────
	# The setter methods are bound to GDScript via ClassDB::bind_method.
	# The PathtracingDenoiser enum is NOT registered with BIND_ENUM_CONSTANT so we
	# use the raw integer value confirmed from rendering_server_enums.h:
	#   PT_DENOISER_NONE = 0
	#   PT_DENOISER_DLSS_RAY_RECONSTRUCTION = 1
	env.set_pathtracing_enabled(true)
	# SKY LIGHTING IS NOW IMPORTANCE-SAMPLED (roadmap C3 / Phase B). There is no
	# knob for it and none is wanted: the integrator builds a CDF over the sky
	# octmap whenever an Environment with a Sky exists, samples it for next-event
	# estimation, and MIS-combines that against BSDF rays that reach the sky.
	#
	# The practical consequence for this script: DO NOT ADD A FILL LIGHT to
	# compensate for sky noise. Measured on a sky-lit scene with real occluders,
	# RMSE at matched sample counts fell 6.6x-9.5x (5.3x-6.9x once the extra
	# shadow ray's frame-time cost is priced in), so the grain that a fill light
	# used to paper over is largely gone. Adding one now just flattens the
	# lighting and costs frames.
	#
	# Two caveats worth knowing before tuning anything here:
	#   * INDOORS the win is smaller. The distribution is over the sky, not over
	#     what is actually visible from a shading point, so behind walls most
	#     environment samples are occluded and thrown away. Portal sampling is
	#     the technique for that and is not implemented.
	#   * There is an OPEN +2.4% brightening on dielectric specular surfaces --
	#     which is most materials this script renders -- traced to the
	#     COMBINE_BRDFS_WITH_FRESNEL integrand mismatch in brdf_inc.glsl. If a
	#     day render reads slightly hot against an older reference, that is the
	#     likely cause; see PATH_TRACER_QUALITY_ROADMAP.md item C3 before
	#     "correcting" it with an exposure tweak here.
	#
	# Pathtracer config. DLSS Ray Reconstruction (DLSS-RR) is a NEURAL TEMPORAL denoiser:
	# it cleans noise by ACCUMULATING INFORMATION ACROSS FRAMES (per RenderingServer docs: "a
	# low sample count (1-2) is typically sufficient since the denoiser accumulates information
	# across frames"). So for stills we run the REALTIME DLSS-RR path (accumulate OFF, 1-SPP
	# per frame) and let the render.gd loop drive enough frames for that temporal accumulation
	# to converge to a clean, detail-reconstructed still — DLSS-RR IS the temporal accumulator,
	# so no separate Phase-A running-average is wanted (feeding DLSS a converged image gives it
	# nothing new to accumulate → passthrough/no denoise, which is the Phase F2 dead end).
	# Day: max_bounces 12, night: 8. SPP stays moderate; DLSS-RR temporally integrates
	# 1 sample/frame across the drive-frame count.
	#
	# NOTE on what max_bounces below actually caps: the integrator terminates a path
	# as soon as EITHER its diffuse or its glossy lobe count reaches its own cap (set
	# below), not when the combined total reaches max_bounces. Every surviving bounce
	# increments exactly one of the two counters, so with per-lobe caps D and G the
	# longest reachable path is D + G - 1 bounces, independent of max_bounces --
	# with the 4/4 caps set below that ceiling is 7. So max_bounces=12 (day) and
	# max_bounces=8 (night) are both headroom above a bound that per-lobe caps reach
	# first, not targets this scene will ever hit. This is not a bug to "fix" by
	# raising max_bounces: Blender Cycles ships the identical 4 diffuse / 4 glossy /
	# 12 total defaults (intern/cycles/blender/addon/properties.py) and terminates
	# paths the same way, so stock Cycles is effectively bounded near 7 too --
	# matching that is the point, not a coincidence to route around.
	if day_render:
		env.set_pathtracing_max_bounces(12)
		env.set_pathtracing_samples_per_pixel(20)
	else:
		env.set_pathtracing_max_bounces(8)
		env.set_pathtracing_samples_per_pixel(10)

	# Per-lobe bounce limits (Phase B3). Before this the integrator hardcoded a cap of
	# TWO diffuse bounces regardless of max_bounces, which is why interior corners and
	# ceilings read flat and lifeless: light could not make three diffuse hops to reach
	# them. Blender's shipped defaults are 4 diffuse / 4 glossy, matched here. Raising
	# diffuse buys softer, warmer indirect light, but its render-time cost is
	# scene-dependent, not a guaranteed linear scaling: this engine has no Russian
	# Roulette path termination yet (roadmap item B4), so a higher cap can cost more
	# or less than proportionally depending on how much throughput has already decayed
	# by the time paths reach it.
	env.set_pathtracing_max_diffuse_bounce(4)
	env.set_pathtracing_max_glossy_bounce(4)

	# ── ROUTE SELECT: realtime DLSS-RR (default) vs Phase A offline accumulation ──
	#
	#   >>> FLIP THIS ONE LINE TO true TO USE THE PHASE A OFFLINE ROUTE <<<
	const PHASE_A_OFFLINE_STILL := false

	# Tuning, all editable here (env vars of the same name below still override).
	#   ACCUM_TARGET     frames to accumulate. Noise falls as 1/sqrt(N), so 4x the
	#                    frames halves the grain. 256 is a preview, 1024 a hero shot.
	#   FINAL            "none" | "oidn" | "dlssrr". OIDN removes residual grain at a
	#                    cost in fine detail; prefer more samples first, but on a dark
	#                    interior OIDN at 256-512 beats raw at 256.
	#   CLAMP_INDIRECT   firefly suppression, 0 = off. Blender's default is 10.0.
	#   NOISE_THRESHOLD  adaptive sampling, 0 = off. Spends the budget on noisy pixels.
	const PHASE_A_ACCUM_TARGET := 256
	const PHASE_A_FINAL := "none"
	const PHASE_A_CLAMP_INDIRECT := 0.0
	const PHASE_A_NOISE_THRESHOLD := 0.0
	#
	# ZR_PHASE_A=1 also forces it on, but be aware the variable must be set for the
	# process that SPAWNS Godot — i.e. the uvicorn server — not a separate shell.
	# Setting it in another terminal does nothing, which is why the constant above
	# exists as the reliable switch.
	#
	# Whichever way it is enabled, the run logs a "[PhaseA] Offline accumulation ON"
	# line. If that line is absent from the Godot log, the offline route did NOT run
	# and you are looking at the realtime result.
	#
	# REQUIRES an engine built from vijay_PTEngine_v8_Quality at commit 6d6efa87ad or
	# later. On an older binary render.gd will not even parse, because
	# RenderingServer.viewport_get_pathtracing_accum_image is unbound there.
	#
	# Optional tuning env vars (offline route only):
	#   ZR_PT_ACCUM_TARGET   accumulation frames        (default 256)
	#   ZR_PT_CLAMP_INDIRECT firefly clamp, 0 = off     (default 0; Blender's is 10)
	#   ZR_PT_NOISE_THRESH   adaptive sampling, 0 = off (default 0 for a pure reference)
	#   ZR_PT_FINAL          "oidn" | "dlssrr" | "none" (default "oidn")
	var phase_a_offline := PHASE_A_OFFLINE_STILL or OS.get_environment("ZR_PHASE_A") == "1"

	if phase_a_offline:
		# PHASE A OFFLINE STILL: trace one sample per driver frame into a persistent
		# fp32 running average until it converges, then optionally denoise once. This
		# is the Cycles-style route — it anti-aliases (jittered primary ray per frame)
		# and render.gd additionally writes a linear .exr beside the .png.
		# SPP is ignored here: the accumulate branch traces exactly one sample per
		# launch and the frame count supplies the budget instead.
		var accum_target := PHASE_A_ACCUM_TARGET
		var t_env := OS.get_environment("ZR_PT_ACCUM_TARGET")
		if t_env.is_valid_int():
			accum_target = maxi(1, t_env.to_int())

		var clamp_indirect := PHASE_A_CLAMP_INDIRECT
		var c_env := OS.get_environment("ZR_PT_CLAMP_INDIRECT")
		if c_env.is_valid_float():
			clamp_indirect = maxf(0.0, c_env.to_float())

		var noise_thresh := PHASE_A_NOISE_THRESHOLD
		var n_env := OS.get_environment("ZR_PT_NOISE_THRESH")
		if n_env.is_valid_float():
			noise_thresh = maxf(0.0, n_env.to_float())

		# Default "none": at a few hundred accumulated samples the image is already
		# converged, and OIDN is built for NOISY input — run on a clean image it
		# smooths away fine detail (fabric weave, pencil lines on artwork, wood grain)
		# and softens edges. Set ZR_PT_FINAL=oidn if a dark scene is still grainy,
		# but prefer raising ZR_PT_ACCUM_TARGET first: more samples cost time,
		# denoising costs detail.
		var final_pass := OS.get_environment("ZR_PT_FINAL")
		if final_pass == "":
			final_pass = PHASE_A_FINAL

		env.set_pathtracing_denoiser(0) # 0 = PT_DENOISER_NONE; realtime DLSS-RR is not the integrator here.
		env.set_pathtracing_accumulate(true)
		env.set_pathtracing_accumulation_target(accum_target)
		env.set_pathtracing_oidn_denoise(final_pass == "oidn")
		env.set_pathtracing_dlss_rr_final(final_pass == "dlssrr")
		# Opt-in knobs added in Phase A. Both default to off so a first run measures the
		# unmodified estimator; that is what the convergence check needs.
		env.set_pathtracing_clamp_direct(0.0)
		env.set_pathtracing_clamp_indirect(clamp_indirect)
		env.set_pathtracing_noise_threshold(noise_thresh)
		print("[PhaseA] Offline accumulation ON — target=%d frames, final=%s, clamp_indirect=%.2f, noise_threshold=%.4f"
				% [accum_target, final_pass, clamp_indirect, noise_thresh])
	else:
		env.set_pathtracing_denoiser(1) # 1 = PT_DENOISER_DLSS_RAY_RECONSTRUCTION (realtime temporal path)
		# DLSS-RR REALTIME STILL path: accumulate OFF (no Phase-A running average — DLSS-RR is the
		# temporal integrator), Viewport.SCALING_3D_MODE_DLSS + scaling_3d_scale=1.0 (set in render.gd
		# line ~144) → DLAA 1:1 (no upscaling) so the SCALE_DLSS branch runs DLSS-RR every frame on the
		# raw 1-SPP noisy radiance. render.gd drives ~DLSS_RR_REALTIME_STILL_FRAMES frames (256) so the
		# temporal accumulation converges to a clean reconstructed still, then captures.
		# Alternatives left compiled but OFF: Phase F OIDN final (pathtracing_oidn_denoise) and Phase F2
		# converge-then-reconstruct (pathtracing_dlss_rr_final) — documented fallbacks, not this route.
		env.set_pathtracing_accumulate(false)
		env.set_pathtracing_oidn_denoise(false)
		env.set_pathtracing_dlss_rr_final(false)
	# NOTE: the earlier `env.set("raytracing_params", PackedFloat32Array([...]))` line was
	# a no-op (Environment._set doesn't handle that key, and there's no ClassDB property by
	# that name), so removing it does not change behavior and avoids it shadowing the real
	# pathtracing setters above if that handler ever gains support.

	var world_env = WorldEnvironment.new()
	var reflective_surfaces_present = _scene_has_reflective_surfaces(geom_data)

	# Reflection probes are now localized per room and generated automatically via _generate_localized_reflection_probes.

	world_env.environment = env
	add_child(world_env)

	# ── Scene Fill Lights ──────────────────────────────────────────────────────
	if lighting_profile == "day" or lighting_profile == "sunset":
		var fill = OmniLight3D.new()
		fill.name = "FillLight"
		fill.position = Vector3(room_center.x, room_ceiling_y - 0.55, room_center.z)
		fill.light_energy = lighting["fill_energy"] * 1
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
		fill_front.light_energy = lighting["front_back_fill_energy"] * 1
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
		fill_back.light_energy = lighting["front_back_fill_energy"] * 1
		fill_back.omni_range = max(room_extent.x, room_extent.y) * 1.6 + 4.0
		fill_back.light_color = Color(
			lighting["front_back_fill_color"].r * mood_fill_color.r,
			lighting["front_back_fill_color"].g * mood_fill_color.g,
			lighting["front_back_fill_color"].b * mood_fill_color.b
		)
		fill_back.light_specular = 0.0
		fill_back.shadow_enabled = false
		add_child(fill_back)


	print("Photorealistic lighting setup complete. profile=", lighting_profile)

func _configure_soft_interior_shadow(light: Light3D) -> void:
	# Keep the shadow present but gentle so it reads as one soft interior shadow.
	light.shadow_enabled = true
	light.light_size = 0.18
	light.shadow_bias = 0.08
	light.shadow_normal_bias = 1.7
	light.shadow_blur = 1.35
	light.shadow_opacity = 0.78

func _shadow_cluster_key(world_pos: Vector3, light_range: float) -> String:
	# Group nearby interior fixtures together so only one soft shadow source
	# is active per local lighting cluster.
	var bucket_size = max(220.0, light_range * 55.0)
	var cluster_x = int(round(world_pos.x / bucket_size))
	var cluster_z = int(round(world_pos.z / bucket_size))
	return str(cluster_x) + ":" + str(cluster_z)

func _should_use_interior_shadow_light(world_pos: Vector3, light_range: float, is_street_light: bool) -> bool:
	if is_street_light:
		return false
	var key = _shadow_cluster_key(world_pos, light_range)
	if _interior_shadow_clusters.has(key):
		return false
	_interior_shadow_clusters[key] = true
	return true

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

func parse_vec3(d):
	if typeof(d) == TYPE_DICTIONARY:
		return Vector3(d.get("x", 0), d.get("y", 0), d.get("z", 0))
	return Vector3.ZERO

func _apply_directional_light_pose_from_json(dir_light: DirectionalLight3D, data: Dictionary) -> void:
	var lighting_block: Dictionary = {}
	if data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
		lighting_block = data["_lightingSettings"]

	var light_data: Dictionary = {}
	if data.has("directional_light") and typeof(data["directional_light"]) == TYPE_DICTIONARY:
		light_data = data["directional_light"]

	var position_found := false
	var light_position := Vector3.ZERO
	if light_data.has("position") and typeof(light_data["position"]) == TYPE_DICTIONARY:
		light_position = parse_vec3(light_data["position"])
		position_found = true
	elif lighting_block.has("directionalPosition") and typeof(lighting_block["directionalPosition"]) == TYPE_DICTIONARY:
		light_position = parse_vec3(lighting_block["directionalPosition"])
		position_found = true

	if position_found:
		if abs(_scene_plan_rotation_radians) > 0.000001:
			light_position = _transform_plan_point_meters(light_position)
		dir_light.position = light_position

	var target_found := false
	var light_target := Vector3.ZERO
	if light_data.has("target") and typeof(light_data["target"]) == TYPE_DICTIONARY:
		light_target = parse_vec3(light_data["target"])
		target_found = true
	elif lighting_block.has("directionalTarget") and typeof(lighting_block["directionalTarget"]) == TYPE_DICTIONARY:
		light_target = parse_vec3(lighting_block["directionalTarget"])
		target_found = true

	if target_found:
		if abs(_scene_plan_rotation_radians) > 0.000001:
			light_target = _transform_plan_point_meters(light_target)
		if dir_light.position.distance_to(light_target) > 0.001:
			dir_light.look_at(light_target, Vector3.UP)

	if position_found or target_found:
		_directional_light_authoring_locked = true

func _segment_intersection_2d(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> Dictionary:
	var r = a2 - a1
	var s = b2 - b1
	var denom = r.cross(s)
	if abs(denom) < 0.000001:
		return {}

	var qp = b1 - a1
	var t = qp.cross(s) / denom
	var u = qp.cross(r) / denom
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return {}

	return {
		"t": t,
		"u": u,
		"point": a1 + r * t
	}

func _get_camera_view_segment_2d() -> Dictionary:
	if typeof(_camera_pose) != TYPE_DICTIONARY:
		return {}

	var cam_pos = _camera_pose.get("position", Vector3.ZERO)
	if typeof(cam_pos) != TYPE_VECTOR3:
		cam_pos = Vector3.ZERO

	var cam_target = _camera_pose.get("target", cam_pos + Vector3(0.0, 0.0, -1.0))
	if typeof(cam_target) != TYPE_VECTOR3:
		cam_target = cam_pos + Vector3(0.0, 0.0, -1.0)

	return {
		"start": Vector2(cam_pos.x, cam_pos.z),
		"end": Vector2(cam_target.x, cam_target.z)
	}

func _camera_view_hits_item(item: Dictionary) -> bool:
	var segment = _get_camera_view_segment_2d()
	if segment.is_empty():
		return false

	var item_xy = _plan_point_2d(float(item.get("x", 0)), float(item.get("y", 0)))
	var center = Vector2(item_xy.x * _scene_unit_scale, item_xy.y * _scene_unit_scale)
	var radius = _camera_blocking_item_radius(item)
	var closest = Geometry2D.get_closest_point_to_segment(center, segment["start"], segment["end"])
	return closest.distance_to(center) <= radius

func _camera_blocking_item_radius(item: Dictionary) -> float:
	var props = {}
	if item.has("properties") and typeof(item["properties"]) == TYPE_DICTIONARY:
		props = item["properties"]

	var raw_width = props.get("width", item.get("width", 100))
	var raw_depth = props.get("depth", item.get("depth", 100))
	var width_m = get_dimension_value(raw_width) * _scene_unit_scale
	var depth_m = get_dimension_value(raw_depth) * _scene_unit_scale
	return max(max(width_m, depth_m) * 0.5, 0.35)

func _resolve_lighting_profile(data: Dictionary) -> String:
	var string_keys = ["lighting_profile", "time_of_day", "timeOfDay", "render_time", "environment_preset"]
	var candidate_sources: Array = [data]
	if data.has("_lightingSettings") and typeof(data["_lightingSettings"]) == TYPE_DICTIONARY:
		candidate_sources.append(data["_lightingSettings"])

	for source in candidate_sources:
		for key in string_keys:
			if source.has(key):
				var value = str(source[key]).to_lower().strip_edges()
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
		return candidate
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
	
	# Assumes level 5 is 0.5 for the cinematic math t = scale / 0.5
	return float(level) * 0.10

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
				"directional":
					# Soft warm directional tint
					return Color(1.0, 0.95, 0.90)
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

func _get_lighting_profile_settings() -> Dictionary:
	match lighting_profile:
		"night":
			return {
				"sky_exr": "res://night.exr",
				"dir_energy": 0.0,
				"dir_color": Color(0.55, 0.62, 0.90),
				"sky_top_color": Color(0.01, 0.02, 0.05),
				"sky_horizon_color": Color(0.04, 0.06, 0.10),
				"ground_bottom_color": Color(0.005, 0.005, 0.01),
				"ground_horizon_color": Color(0.03, 0.05, 0.08),
				"sun_angle_max": 10.0,
				"sun_curve": 0.05,
				"ambient_color": Color("#4a3528"), # Warm tint for night ceiling
				# PT accumulates ambient additively — 0.38 × 0.8 scale was too bright.
				# 0.18 gives a dark ambient floor without crushing the interior fixtures.
				"ambient_energy": 0.18,
				"hemi_energy": 0.08,
				# PT exposure: lower from 0.65 to avoid blowing out fixture glow.
				"tonemap_exposure": 0.42,
				"tonemap_white": 4.8,
				"tonemap_agx_white": 14.0,
				"tonemap_agx_contrast": 1.0,
				# Keep glow subtle — PT already produces physical bloom via bounces.
				"glow_intensity": 0.18,
				"glow_bloom": 0.06,
				"glow_hdr_threshold": 1.0, # Raised — only true hot-spots trigger bloom
				"glow_hdr_scale": 1.4, # Reduced from 2.1 — PT doesn't need amplification
				"fill_energy": 0.06,
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
				# CHANGE 2: Raise to 3.5 (was 1.0) — physical sun strength for visible rays/shafts
				"dir_energy": 3.5,
				# Warm golden sun color (was cold 0.96, 0.88 white)
				"dir_color": Color(1.0, 0.92, 0.78),
				"sky_top_color": Color(0.25, 0.40, 0.78),
				"sky_horizon_color": Color(0.80, 0.82, 0.88),
				"ground_bottom_color": Color(0.08, 0.06, 0.04),
				"ground_horizon_color": Color(0.30, 0.28, 0.22),
				"sun_angle_max": 30.0,
				"sun_curve": 0.15,
				# Warmer ambient color for interior bounce (was cold 0.76, 0.77, 0.78)
				"ambient_color": Color(1.0, 0.835, 0.50), # Color(0.82, 0.80, 0.76),
				# CHANGE 2: Raise ambient_energy 0.15→0.35 — needed for warm GI bounce fill
				"ambient_energy": 0.35,
				# CHANGE 2: Higher exposure 0.72→0.90 — brings interior into balance with sun
				"tonemap_exposure": 0.90,
				"tonemap_white": 6.0,
				"tonemap_agx_white": 16.29,
				"tonemap_agx_contrast": 1.18,
				# Slightly stronger glow for golden sun highlights
				"glow_intensity": 0.28,
				"glow_bloom": 0.10,
				"glow_hdr_threshold": 1.20,
				"glow_hdr_scale": 2.0,
				"fill_energy": 0.10,
				"fill_color": Color(1.0, 0.95, 0.85),
				"front_back_fill_energy": 0.03,
				"front_back_fill_color": Color(0.99, 0.97, 0.93)
			}

func _extract_camera_pose(data: Dictionary) -> Dictionary:
	var cam_pos = Vector3(0, 1.6, 6)
	var cam_target = Vector3.ZERO
	var found = false
	var found_target = false
	var should_transform_camera = false

	if data.has("floor_plan_data"):
		var fp_raw = data["floor_plan_data"]
		if typeof(fp_raw) == TYPE_DICTIONARY:
			should_transform_camera = str(fp_raw.get("version", "")).strip_edges() != "2.0.0"
		elif typeof(fp_raw) == TYPE_STRING:
			var fp_json = JSON.new()
			var fp_err = fp_json.parse(fp_raw)
			if fp_err == OK and typeof(fp_json.data) == TYPE_DICTIONARY:
				should_transform_camera = str(fp_json.data.get("version", "")).strip_edges() != "2.0.0"

	if data.has("threejs_camera") and typeof(data["threejs_camera"]) == TYPE_DICTIONARY:
		var tc = data["threejs_camera"]
		if tc.has("position") and typeof(tc["position"]) == TYPE_DICTIONARY:
			cam_pos = parse_vec3(tc["position"])
			found = true
		if tc.has("target") and typeof(tc["target"]) == TYPE_DICTIONARY:
			cam_target = parse_vec3(tc["target"])
			found_target = true
	elif data.has("blender_camera") and typeof(data["blender_camera"]) == TYPE_DICTIONARY:
		var bc = data["blender_camera"]
		if bc.has("location") and typeof(bc["location"]) == TYPE_ARRAY and bc["location"].size() >= 3:
			# Blender (x,y,z) -> Godot (x,z,-y)
			cam_pos = Vector3(float(bc["location"][0]), float(bc["location"][2]), -float(bc["location"][1]))
			found = true
		if data.has("blender_target") and typeof(data["blender_target"]) == TYPE_DICTIONARY:
			var bt = data["blender_target"]
			if bt.has("location") and typeof(bt["location"]) == TYPE_ARRAY and bt["location"].size() >= 3:
				cam_target = Vector3(float(bt["location"][0]), float(bt["location"][2]), -float(bt["location"][1]))
				found_target = true

	if found and should_transform_camera:
		cam_pos = _transform_plan_point_meters(cam_pos)
	if found_target and should_transform_camera:
		cam_target = _transform_plan_point_meters(cam_target)

	if not found:
		cam_pos = Vector3(0, 1.6, 6)
	if cam_target.distance_to(cam_pos) < 0.001:
		cam_target = cam_pos + Vector3(0, 0, -1)

	return {"position": cam_pos, "target": cam_target}

func _has_reflective_surface_hint(value: String) -> bool:
	var text = value.to_lower()
	if text == "":
		return false
	var keywords = [
		"glass", "mirror", "metal", "chrome", "polish", "polished",
		"marble", "granite", "tile", "porcelain", "gloss", "reflect",
		"shiny", "steel", "chrome", "gold"
	]
	for kw in keywords:
		if kw in text:
			return true
	return false

func _material_dict_has_reflection_hint(mat_data) -> bool:
	if typeof(mat_data) != TYPE_DICTIONARY:
		return false
	if mat_data.has("mapUrl") and _has_reflective_surface_hint(str(mat_data.get("mapUrl", ""))):
		return true
	if mat_data.has("normalUrl") and _has_reflective_surface_hint(str(mat_data.get("normalUrl", ""))):
		return true
	if mat_data.has("roughnessUrl") and _has_reflective_surface_hint(str(mat_data.get("roughnessUrl", ""))):
		return true
	if mat_data.has("metalnessUrl") and str(mat_data.get("metalnessUrl", "")) != "":
		return true
	if mat_data.has("color") and _has_reflective_surface_hint(str(mat_data.get("color", ""))):
		return true
	return false

func _scene_has_reflective_surfaces(geom_data: Dictionary) -> bool:
	if typeof(geom_data) != TYPE_DICTIONARY:
		return false

	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		for layer in geom_data["layers"].values():
			if typeof(layer) != TYPE_DICTIONARY:
				continue

			for line in layer.get("lines", {}).values():
				if typeof(line) != TYPE_DICTIONARY:
					continue
				if line.has("asset_urls") and typeof(line["asset_urls"]) == TYPE_DICTIONARY:
					var au = line["asset_urls"]
					for face in ["inner", "outer"]:
						if au.has(face) and _material_dict_has_reflection_hint(au[face]):
							return true
				for prop_key in ["inner_properties", "outer_properties"]:
					if line.has(prop_key) and typeof(line[prop_key]) == TYPE_DICTIONARY:
						var props = line[prop_key]
						if props.has("material") and _material_dict_has_reflection_hint(props["material"]):
							return true

			for area_key in ["areas"]:
				if not layer.has(area_key) or typeof(layer[area_key]) != TYPE_DICTIONARY:
					continue
				for area in layer[area_key].values():
					if typeof(area) != TYPE_DICTIONARY:
						continue
					for prop_key in ["floor_properties", "ceiling_properties"]:
						if area.has(prop_key) and typeof(area[prop_key]) == TYPE_DICTIONARY:
							var props = area[prop_key]
							if props.has("material") and _material_dict_has_reflection_hint(props["material"]):
								return true

			for item in layer.get("items", {}).values():
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var item_desc = "%s %s" % [str(item.get("name", "")), str(item.get("type", ""))]
				if _has_reflective_surface_hint(item_desc):
					return true
				if item.has("materials") and typeof(item["materials"]) == TYPE_DICTIONARY:
					for mat in item["materials"].values():
						if _material_dict_has_reflection_hint(mat):
							return true

	if geom_data.has("materials") and typeof(geom_data["materials"]) == TYPE_DICTIONARY:
		for mat in geom_data["materials"].values():
			if _material_dict_has_reflection_hint(mat):
				return true

	return false

func _material_is_reflective_candidate(mat_data, surface_type: String) -> bool:
	if typeof(mat_data) != TYPE_DICTIONARY:
		return false

	var text = ""
	if mat_data.has("mapUrl"):
		text += " " + str(mat_data.get("mapUrl", ""))
	if mat_data.has("normalUrl"):
		text += " " + str(mat_data.get("normalUrl", ""))
	if mat_data.has("roughnessUrl"):
		text += " " + str(mat_data.get("roughnessUrl", ""))
	if mat_data.has("metalnessUrl"):
		text += " " + str(mat_data.get("metalnessUrl", ""))
	if mat_data.has("color"):
		text += " " + str(mat_data.get("color", ""))
	text = text.to_lower()

	if surface_type == "floor":
		var floor_keywords = ["tile", "marble", "granite", "polished", "porcelain", "gloss", "reflect", "metal", "chrome", "glass"]
		for kw in floor_keywords:
			if kw in text:
				return true

	if surface_type == "wall" or surface_type == "item":
		var spec_keywords = ["glass", "mirror", "metal", "chrome", "gold"]
		for kw in spec_keywords:
			if kw in text:
				return true

	return false

func _apply_reflection_response_assist(mat: StandardMaterial3D, mat_data: Dictionary, surface_type: String) -> StandardMaterial3D:
	if not USE_REFLECTION_PROBE or not USE_REFLECTION_RESPONSE_ASSIST:
		return mat

	if not _material_is_reflective_candidate(mat_data, surface_type):
		return mat

	var path = str(mat_data.get("mapUrl", "")).to_lower()
	if surface_type == "floor":
		mat.metallic = 0.0
		mat.roughness = min(mat.roughness, 0.25)
		mat.metallic_specular = max(mat.metallic_specular, 0.65)
		mat.clearcoat_enabled = true
		mat.clearcoat = max(mat.clearcoat, 0.25)
		mat.clearcoat_roughness = min(mat.clearcoat_roughness, 0.12)
		print("  [ReflectionAssist] Floor candidate -> boosting probe response.")
	elif "glass" in path or "mirror" in path:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = min(mat.roughness, 0.05)
		mat.metallic = 0.0
		mat.metallic_specular = 1.0
		print("  [ReflectionAssist] Glass/mirror candidate -> enabling crisp reflections.")
	elif "metal" in path or "steel" in path or "chrome" in path or "gold" in path:
		mat.metallic = 1.0
		mat.roughness = min(mat.roughness, 0.18)
		mat.metallic_specular = 1.0
		print("  [ReflectionAssist] Metal candidate -> boosting reflections.")

	return mat

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

	# 1. Main Room Probes (per area)
	for aid in areas:
		var area = areas[aid]
		if typeof(area) != TYPE_DICTIONARY or not area.has("vertices"):
			continue
		
		var min_x = 1e20
		var max_x = -1e20
		var min_z = 1e20
		var max_z = -1e20
		var got_any = false

		for vid in area["vertices"]:
			var key = str(vid)
			if not vertices.has(key): continue
			var v = vertices[key]
			var p = _plan_point_2d(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
			var x = p.x * _scene_unit_scale
			var z = p.y * _scene_unit_scale
			min_x = min(min_x, x)
			max_x = max(max_x, x)
			min_z = min(min_z, z)
			max_z = max(max_z, z)
			got_any = true
			
		if not got_any: continue

		var ceil_h = 2.8
		if area.has("ceiling_properties"):
			var cp = area["ceiling_properties"]
			if typeof(cp) == TYPE_DICTIONARY and cp.has("height"):
				var h = float(cp["height"]) * _scene_unit_scale
				if h > 0.1: ceil_h = h

		var center = Vector3((min_x + max_x) * 0.5, layer_alt + ceil_h * 0.5, (min_z + max_z) * 0.5)
		var extent_x = max(2.0, max_x - min_x)
		var extent_z = max(2.0, max_z - min_z)
		
		var probe = ReflectionProbe.new()
		probe.name = "AreaProbe_" + str(aid)
		probe.position = center
		
		# Optimized probe sizes: room_bounds * 0.85
		probe.size = Vector3(extent_x * 0.85, ceil_h * 0.85, extent_z * 0.85)
		
		# Always enable box_projection
		probe.box_projection = true
		
		# Optimized settings
		probe.interior = true
		# UPDATE_ALWAYS ensures the probe updates continuously during the 40 wait frames
		# so it captures fully settled SDFGI/lighting, rather than a dark first frame.
		probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
		probe.enable_shadows = false
		probe.intensity = 0.4 # Increased from 0.2 for better marble visibility
		probe.mesh_lod_threshold = 1.5
		probe.set("resolution", 1024)
		
		# Layer 1 Cull Mask
		probe.cull_mask = 1
		
		add_child(probe)

	# 2. Door/Window Probes
	var all_holes = work.get("holes", {})
	if typeof(lines) == TYPE_DICTIONARY:
		for lid in lines:
			var line = lines[lid]
			if typeof(line) != TYPE_DICTIONARY or not line.has("holes"): continue
			
			var v1_id = str(line.get("vertices", [])[0])
			var v2_id = str(line.get("vertices", [])[1])
			if not vertices.has(v1_id) or not vertices.has(v2_id): continue
			
			var p1_raw = vertices[v1_id]
			var p2_raw = vertices[v2_id]
			var pt1 = _plan_point_2d(float(p1_raw.get("x", 0.0)), float(p1_raw.get("y", 0.0))) * _scene_unit_scale
			var pt2 = _plan_point_2d(float(p2_raw.get("x", 0.0)), float(p2_raw.get("y", 0.0))) * _scene_unit_scale
			var line_p1 = Vector3(pt1.x, layer_alt, pt1.y)
			var line_p2 = Vector3(pt2.x, layer_alt, pt2.y)
			
			for hole_id in line["holes"]:
				var hid = str(hole_id)
				if not all_holes.has(hid): continue
				var hole = all_holes[hid]
				
				var h_width = get_dimension_value(hole.get("width", 0)) * _scene_unit_scale
				var h_height = get_dimension_value(hole.get("height", 0)) * _scene_unit_scale
				var h_alt = get_dimension_value(hole.get("altitude", 0)) * _scene_unit_scale
				
				var offset_ratio = 0.5
				var raw_offset = float(hole.get("offset", 0.0))
				if hole.has("properties") and hole["properties"].has("offset"):
					raw_offset = float(hole["properties"]["offset"])
				
				var wall_len = line_p1.distance_to(line_p2)
				if raw_offset > 1.0 and wall_len > 0.0001:
					offset_ratio = clamp((raw_offset * _scene_unit_scale) / wall_len, 0.0, 1.0)
				else:
					offset_ratio = raw_offset
					
				var hole_pos = line_p1.lerp(line_p2, offset_ratio)
				hole_pos.y = layer_alt + h_alt + h_height / 2.0
				
				var is_window = hole.get("type", "") == "window"
				var is_door = hole.get("type", "") == "door"
				
				if is_window or is_door:
					var probe = ReflectionProbe.new()
					probe.name = "HoleProbe_" + hid
					probe.position = hole_pos
					probe.size = Vector3(max(2.0, h_width * 1.5), max(2.0, h_height * 1.5), 2.0)
					probe.box_projection = true
					probe.interior = true
					probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
					probe.enable_shadows = false
					# Lower reflection intensity near doors, windows, outdoor openings
					probe.intensity = 0.1
					probe.mesh_lod_threshold = 1.5
					probe.set("resolution", 1024)
					probe.cull_mask = 1
					add_child(probe)

func _extract_room_lighting_bounds(geom_data: Dictionary) -> Dictionary:
	var out = {
		"center": Vector3.ZERO,
		"extent": Vector2(6.0, 6.0),
		"ceiling_y": 2.8
	}
	if typeof(geom_data) != TYPE_DICTIONARY:
		return out

	var work = geom_data
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		var selected = str(geom_data.get("selectedLayer", ""))
		var layers = geom_data["layers"]
		if selected != "" and layers.has(selected):
			work = layers[selected]
		elif layers.size() > 0:
			work = layers[layers.keys()[0]]

	if typeof(work) != TYPE_DICTIONARY:
		return out
	if not work.has("areas") or not work.has("vertices"):
		return out

	var areas = work["areas"]
	var vertices = work["vertices"]
	if typeof(areas) != TYPE_DICTIONARY or typeof(vertices) != TYPE_DICTIONARY or areas.size() == 0:
		return out

	var min_x = 1e20
	var max_x = -1e20
	var min_z = 1e20
	var max_z = -1e20
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
			var p = _plan_point_2d(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
			var x = p.x * _scene_unit_scale
			var z = p.y * _scene_unit_scale
			min_x = min(min_x, x)
			max_x = max(max_x, x)
			min_z = min(min_z, z)
			max_z = max(max_z, z)
			got_any = true

	if not got_any:
		return out

	var layer_alt = 0.0
	if work.has("altitude"):
		var alt = work["altitude"]
		if typeof(alt) == TYPE_DICTIONARY and alt.has("length"):
			layer_alt = float(alt["length"]) * _scene_unit_scale
		else:
			layer_alt = float(alt) * _scene_unit_scale

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

	out["center"] = Vector3((min_x + max_x) * 0.5, layer_alt + ceil_h * 0.5, (min_z + max_z) * 0.5)
	out["extent"] = Vector2(max(2.0, max_x - min_x), max(2.0, max_z - min_z))
	out["ceiling_y"] = layer_alt + ceil_h
	return out

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# _orient_directional_light_from_windows
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _orient_directional_light_from_windows(dir_light: DirectionalLight3D):
	if _window_sunlight_data.size() == 0:
		return

	# â”€â”€ Step 0: Camera Orientation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	# We want sunlight to favor windows the camera is looking at.
	var cam_pos = _camera_pose["position"]
	var cam_target = _camera_pose["target"]
	var cam_forward = (cam_target - cam_pos).normalized()
	cam_forward.y = 0.0 # horizontal view direction
	if cam_forward.length() < 0.001:
		cam_forward = Vector3(0, 0, -1)
	cam_forward = cam_forward.normalized()

	# â”€â”€ Step 1: Weighted outer_dir â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
	avg_outer_dir.y = 0.0 # flatten â€” elevation handled separately below
	if avg_outer_dir.length() < 0.001:
		avg_outer_dir = Vector3(1, 0, 0) # safe fallback
	avg_outer_dir = avg_outer_dir.normalized()

	# â”€â”€ Step 2: Sun elevation per lighting profile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	# This is the downward angle of sunlight.
	var elevation_deg: float
	match lighting_profile:
		"day": elevation_deg = 28.0 # slightly lower for longer, more dramatic shadows
		"sunset": elevation_deg = 8.0 # high grazing golden hour light
		"night": elevation_deg = 55.0 # moon, steep and cool
		_: elevation_deg = 28.0

	# â”€â”€ Step 3: Build a direction vector from outer_dir + elevation â”€â”€â”€â”€â”€â”€â”€
	# Sun ray direction: horizontal component = -avg_outer_dir (sun comes from outside)
	var elevation_rad := deg_to_rad(elevation_deg)
	var sun_dir := Vector3(
		- avg_outer_dir.x,
		- sin(elevation_rad), # negative = pointing downward
		- avg_outer_dir.z
	).normalized()

	# ——— Step 4: Orient the directional light —————————————————————————————————
	# Place the virtual sun far away and look_at the center of the windows.
	var weighted_center := Vector3.ZERO
	for win in _window_sunlight_data:
		weighted_center += (win["center"] as Vector3)
	weighted_center /= float(_window_sunlight_data.size())

	dir_light.position = weighted_center - sun_dir * 50.0
	if dir_light.position.distance_to(weighted_center) > 0.001:
		dir_light.look_at(weighted_center, Vector3.UP)

	print("Dynamic Sunlight oriented: cam_forward=", cam_forward,
		  " weighted_outer=", avg_outer_dir, " elevation=", elevation_deg)

func _create_window_portal_lights() -> void:
	if not day_render or _window_sunlight_data.is_empty():
		return

	# Window portal SpotLights simulate diffuse sky light entering through windows.
	# This is the PRIMARY source of room ambient brightness when windows are present.
	# WHY IT WAS "ARTIFICIAL" BEFORE:
	#   - Light was positioned AT the window frame → frame itself got lit → orange glow
	#   - shadow_enabled = true → visible shadow artifacts on frame edges
	#   - specular = 0.15 → hot-spot shimmer on the window frame mesh
	# FIX:
	#   - Position 0.8m INSIDE the room → light never touches the frame geometry
	#   - shadow_enabled = false → directional sun handles all shadows
	#   - specular = 0.0 → no artificial hot spots
	#   - OmniLight is NOT re-enabled (it caused a circular ceiling hotspot)
	print("[ImageGLB] Creating window portal lights (sky diffuse) for ", _window_sunlight_data.size(), " windows.")
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
		portal_spot.light_color = Color(1.0, 0.835, 0.50) # Color(1.0, 0.93, 0.76) # 10AM warm-white sky

		# 89 degree cone: near-hemispherical so every corner falls inside it
		portal_spot.spot_angle = 89.0
		# 0.1 attenuation: nearly flat brightness across the whole cone,
		# so far corners get ~90% of the energy the window-adjacent area gets.
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
	# Using a narrow SpotLight aimed inward at very low energy keeps the
	# fill subtle. PT will compute physical occlusion for these naturally.
	for j in range(_door_hole_data.size()):
		var dh = _door_hole_data[j]
		var dh_center = dh["center"] as Vector3
		var dh_inner = dh["inner_dir"] as Vector3
		# Place just inside the opening so it doesn't light the door frame itself
		var dh_pos = dh_center + dh_inner * 0.4
		# Shadow enabled only for glass doors (sliding glass door):
		# _node_has_any_glass() detected glass meshes in the loaded asset.
		# Solid wood/metal doors: shadow disabled (they don't transmit light).
		var dh_is_glass_door: bool = dh.get("has_glass", false)

		var dh_spot = SpotLight3D.new()
		dh_spot.name = "DoorFillSpot_" + str(j)
		dh_spot.position = dh_pos

		# Low energy 0.2 — doors let in less light than windows (no direct sky view)
		if dh_is_glass_door:
			dh_spot.light_energy = 0.2 # 0.2
		else:
			dh_spot.light_energy = 0.1 # 0.1
			
		dh_spot.light_color = Color(1.0, 0.835, 0.50) # Color(1.0, 0.95, 0.88) Slightly cooler than sun
			
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

	# --- WindowAmbientOmni: gentle room fill — DO NOT REMOVE ---
	# This OmniLight provides soft diffuse fill that prevents the room from going dark.
	# The SpotLight3D that was here (energy=14.0, shadow=true) has been removed —
	# it was causing frame artifacts and doubling portal energy.
	# The OmniLight is kept because removing it makes the room visibly darker.
	# print("[ImageGLB] Creating window ambient omni fill for ", _window_sunlight_data.size(), " windows.")
	# for i in range(_window_sunlight_data.size()):
	# 	var win = _window_sunlight_data[i]
	# 	var win_center = win["center"] as Vector3
	# 	var inner_dir = win["inner_dir"] as Vector3

	# 	var ambient_omni = OmniLight3D.new()
	# 	ambient_omni.name = "WindowAmbientOmni_" + str(i)
	# 	ambient_omni.position = win_center + inner_dir * 0.8 + Vector3(0, 0.75, 0)
	# 	ambient_omni.light_energy = 0.6 # Reduced so sky ambient dominates in dark areas
	# 	ambient_omni.light_color = Color(0.88, 0.94, 1.0)
	# 	ambient_omni.omni_range = 6.5
	# 	ambient_omni.shadow_enabled = false
	# 	ambient_omni.light_specular = 0.0
	# 	add_child(ambient_omni)
	# 	print("  [AmbientOmni] Window ", i, " fill omni at ", ambient_omni.position)

# ==============================================================================
# BASE ARCHITECTURE GENERATION (WALLS, FLOORS, CEILINGS)
# ==============================================================================
# WHY IT EXISTS: This converts flat 2D lines and area data from the JSON layout 
# into physical 3D meshes. It mathematically extrudes the walls upwards, draws 
# polygons for floors/ceilings, and cuts holes (booleans) where windows and 
# doors need to go.
# ==============================================================================
func build_architecture(data):
	print("Building Architecture...")

	if data.has("layers"):
		print("Found layers in architecture data.")

		# Determine which layers to process based on showAllFloors / selectedLayer
		var show_all_floors = data.get("showAllFloors", true)
		var selected_layer = data.get("selectedLayer", "")
		var camera_layer_id = ""
		var keep_all_layers = show_all_floors
		# use_showall=False means scene_optimizer.py has forced all ceilings visible.
		# Read it from fp_data (stamped by the optimizer) â€” default true = normal culling.
		var use_showall_flag: bool = bool(data.get("use_showall", true))

		# In single-layer mode the caller explicitly chose the floor to render.
		# Do not let camera-height heuristics swap it to another layer.
		if show_all_floors:
			camera_layer_id = _resolve_camera_layer_id(data)
		elif selected_layer == "":
			# Fallback only when the input forgot to provide a selected layer.
			camera_layer_id = _resolve_camera_layer_id(data)

		if camera_layer_id != "":
			var layers_dict: Dictionary = data.get("layers", {})
			var camera_layer = layers_dict.get(camera_layer_id, {})
			var camera_layer_mode = str(camera_layer.get("render_mode", "INTERIOR")).to_upper()

			if camera_layer_mode == "INTERIOR":
				if not show_all_floors:
					if selected_layer == "" or str(selected_layer) != camera_layer_id:
						print("Camera is inside layer ", camera_layer_id, " - overriding selectedLayer=", selected_layer)
					# Interior renders should favor the camera's actual layer so we do not
					# render the floor slab above the camera as the visible ceiling.
					print("Interior camera layer resolved to ", camera_layer_id, " - isolating this layer for ceiling correctness.")
					show_all_floors = false
					keep_all_layers = false
					selected_layer = camera_layer_id
			else:
				print("Camera layer ", camera_layer_id, " is EXTERIOR - keeping all layers enabled.")
				show_all_floors = true
				keep_all_layers = true

		if show_all_floors:
			print("showAllFloors is true â€” building ALL layers.")
		else:
			print("showAllFloors is false â€” building only selected layer: ", selected_layer)

		for layer_id in data["layers"]:
			# If showAllFloors is false, skip layers that don't match selectedLayer
			if not keep_all_layers and selected_layer != "" and str(layer_id) != str(selected_layer):
				print("Skipping layer: ", layer_id, " (not selected)")
				continue

			var layer = data["layers"][layer_id]
			print("Processing layer: ", layer_id)
			var layer_alt = 0.0
			# When rendering a single layer (showAllFloors=false), place it at
			# ground level so it doesn't float at its original altitude.
			if show_all_floors:
				if layer.has("altitude"):
					var alt_val = layer["altitude"]
					if typeof(alt_val) == TYPE_DICTIONARY and alt_val.has("length"):
						layer_alt = float(alt_val["length"]) * _scene_unit_scale
					else:
						layer_alt = float(alt_val) * _scene_unit_scale
			else:
				print("Single-layer mode: placing layer '", layer_id, "' at ground level (altitude 0)")

			if layer.has("lines") and layer.has("vertices"):
				# â”€â”€ render_mode forwarded by scene_optimizer.py â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
				# "INTERIOR" = camera inside a room, "EXTERIOR" = camera outside.
				# Falls back to top-level fp_data render_mode, then "INTERIOR".
				var layer_render_mode = layer.get("render_mode",
					data.get("render_mode", "INTERIOR"))
				print("Layer ", layer_id, " render_mode: ", layer_render_mode)
				_build_layer_geometry(layer, layer_alt, show_all_floors, layer_render_mode, use_showall_flag)
	elif data.has("lines") and data.has("vertices"):
		print("Found lines/vertices in root data.")
		var root_render_mode = data.get("render_mode", "INTERIOR")
		_build_layer_geometry(data, 0.0, data.get("showAllFloors", true), root_render_mode, bool(data.get("use_showall", true)))
	else:
		print("Warning: No lines or vertices found in floor plan data.")

func _resolve_area_floor_material_data(area: Dictionary, floor_props: Dictionary = {}) -> Dictionary:
	var resolved: Dictionary = {}

	if typeof(floor_props) == TYPE_DICTIONARY and floor_props.has("material") and typeof(floor_props["material"]) == TYPE_DICTIONARY:
		resolved = floor_props["material"].duplicate(true)
	elif area.has("material") and typeof(area["material"]) == TYPE_DICTIONARY:
		resolved = area["material"].duplicate(true)

	if area.has("material") and typeof(area["material"]) == TYPE_DICTIONARY:
		for key in area["material"]:
			if not resolved.has(key):
				resolved[key] = area["material"][key]

	if area.has("properties") and typeof(area["properties"]) == TYPE_DICTIONARY:
		var props = area["properties"]
		if props.has("material") and typeof(props["material"]) == TYPE_DICTIONARY:
			for key in props["material"]:
				if not resolved.has(key):
					resolved[key] = props["material"][key]

		if (not resolved.has("mapUrl") or str(resolved.get("mapUrl", "")).strip_edges() == ""):
			var texture_url := ""
			if typeof(floor_props) == TYPE_DICTIONARY and floor_props.has("texture"):
				texture_url = str(floor_props.get("texture", "")).strip_edges()
			if texture_url == "" and props.has("texture"):
				texture_url = str(props.get("texture", "")).strip_edges()
			if texture_url != "" and texture_url.to_lower() != "none":
				resolved["mapUrl"] = texture_url

	return resolved

func _build_external_area_floor(area_id: String, area: Dictionary, vertices: Dictionary, layer_altitude: float, scale_factor: float) -> void:
	if not area.has("vertices") or area["vertices"].size() < 3:
		return

	var polygon = PackedVector2Array()
	for v_id in area["vertices"]:
		var vs = str(v_id)
		if vertices.has(vs):
			var v = vertices[vs]
			var p = _plan_point_2d(float(v["x"]), float(v["y"]))
			polygon.append(p * scale_factor)

	if polygon.size() < 3:
		return

	var signed_area = 0.0
	for pi in range(polygon.size()):
		var pa = polygon[pi]
		var pb = polygon[(pi + 1) % polygon.size()]
		signed_area += (pa.x * pb.y - pb.x * pa.y)
	signed_area *= 0.5
	if signed_area < 0:
		polygon.reverse()

	var uv_polygon = polygon.duplicate()
	var floor_props: Dictionary = {}
	if area.has("floor_properties") and typeof(area["floor_properties"]) == TYPE_DICTIONARY:
		floor_props = area["floor_properties"]

	var floor_is_visible = true
	if area.has("visible"):
		floor_is_visible = bool(area["visible"])
	elif typeof(floor_props) == TYPE_DICTIONARY and floor_props.has("visible"):
		floor_is_visible = bool(floor_props["visible"])
	elif typeof(floor_props) == TYPE_DICTIONARY and floor_props.has("isvisible"):
		floor_is_visible = bool(floor_props["isvisible"])
	elif typeof(floor_props) == TYPE_DICTIONARY and floor_props.has("isVisible"):
		floor_is_visible = bool(floor_props["isVisible"])

	print("[VISIBILITY] External Area: ", area_id, " | Floor visible: ", floor_is_visible)

	if not floor_is_visible:
		return

	var floor_depth = 0.1
	if area.has("properties") and typeof(area["properties"]) == TYPE_DICTIONARY and area["properties"].has("thickness"):
		var t = get_dimension_value(area["properties"]["thickness"], 20.0) * scale_factor
		if t > 0.001:
			floor_depth = t
	elif floor_props.has("thickness"):
		var t2 = get_dimension_value(floor_props["thickness"], 20.0) * scale_factor
		if t2 > 0.001:
			floor_depth = t2

	var floor_poly = CSGPolygon3D.new()
	floor_poly.polygon = polygon
	floor_poly.mode = CSGPolygon3D.MODE_DEPTH
	floor_poly.depth = floor_depth
	floor_poly.rotation.x = PI / 2
	# Push external areas below the main floor by their full depth + a margin to avoid Z-fighting and ensure they don't cover interior floors.
	floor_poly.position.y = layer_altitude - floor_depth - 0.01
	var floor_span = _get_polygon_world_span(uv_polygon)

	var floor_material_data = _resolve_area_floor_material_data(area, floor_props)
	if not floor_material_data.is_empty():
		var f_mat = create_material(floor_material_data, "floor")
		f_mat = _apply_architecture_texture_scale(f_mat, floor_material_data, floor_span)
		floor_poly.material = f_mat
		print("External Area Material Optimized: ", floor_material_data.get("mapUrl", "default"))
	else:
		var floor_mat = StandardMaterial3D.new()
		floor_mat.albedo_color = Color(0.3, 0.6, 0.3)
		if USE_MATERIAL_OPTIMIZER:
			floor_mat = MOImage.optimize_material(floor_mat, {"color": "#4c994c"}, "floor")
		floor_poly.material = floor_mat

	var floor_csg = CSGCombiner3D.new()
	floor_csg.name = "ExternalAreaCSG_" + str(area_id)
	floor_csg.use_collision = true
	add_child(floor_csg)
	floor_csg.add_child(floor_poly)

func _resolve_camera_layer_id(data: Dictionary) -> String:
	if not data.has("layers") or typeof(data["layers"]) != TYPE_DICTIONARY:
		return ""

	var layers = data["layers"]
	var selected = str(data.get("selectedLayer", "")).strip_edges()
	if selected != "" and layers.has(selected):
		var selected_layer = layers[selected]
		if typeof(selected_layer) == TYPE_DICTIONARY:
			var selected_alt_m = 0.0
			if selected_layer.has("altitude"):
				var selected_alt = selected_layer["altitude"]
				if typeof(selected_alt) == TYPE_DICTIONARY and selected_alt.has("length"):
					selected_alt_m = float(selected_alt["length"]) * _scene_unit_scale
				else:
					selected_alt_m = float(selected_alt) * _scene_unit_scale

			var selected_height_m = 3.0
			if selected_layer.has("lines") and typeof(selected_layer["lines"]) == TYPE_DICTIONARY:
				for line in selected_layer["lines"].values():
					if typeof(line) != TYPE_DICTIONARY:
						continue
					if line.has("properties") and typeof(line["properties"]) == TYPE_DICTIONARY and line["properties"].has("height"):
						var h_prop = line["properties"]["height"]
						var wall_h_m = 0.0
						if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
							wall_h_m = float(h_prop["length"]) * _scene_unit_scale
						else:
							wall_h_m = float(h_prop) * _scene_unit_scale
						if wall_h_m > selected_height_m:
							selected_height_m = wall_h_m

			var selected_top_m = selected_alt_m + selected_height_m
			if _camera_height_m >= selected_alt_m and _camera_height_m < selected_top_m:
				return selected

	for layer_id in layers:
		var layer = layers[layer_id]
		if typeof(layer) != TYPE_DICTIONARY:
			continue

		var layer_alt_m = 0.0
		if layer.has("altitude"):
			var alt_val = layer["altitude"]
			if typeof(alt_val) == TYPE_DICTIONARY and alt_val.has("length"):
				layer_alt_m = float(alt_val["length"]) * _scene_unit_scale
			else:
				layer_alt_m = float(alt_val) * _scene_unit_scale

		var wall_heights: Array = []
		if layer.has("lines") and typeof(layer["lines"]) == TYPE_DICTIONARY:
			for line in layer["lines"].values():
				if typeof(line) != TYPE_DICTIONARY:
					continue
				if line.has("properties") and typeof(line["properties"]) == TYPE_DICTIONARY and line["properties"].has("height"):
					var h_prop = line["properties"]["height"]
					var wall_h_m = 0.0
					if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
						wall_h_m = float(h_prop["length"]) * _scene_unit_scale
					else:
						wall_h_m = float(h_prop) * _scene_unit_scale
					if wall_h_m > 0.1:
						wall_heights.append(wall_h_m)

		var layer_height_m = 3.0
		for h in wall_heights:
			if float(h) > layer_height_m:
				layer_height_m = float(h)
		var layer_top_m = layer_alt_m + layer_height_m
		if _camera_height_m >= layer_alt_m and _camera_height_m < layer_top_m:
			return str(layer_id)

	return ""

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# _get_wall_facing_direction
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Mirrors the frontend's getWallFacingDirection() from Wall3D.tsx exactly.
#
# Frontend logic recap:
#   1. Find the area (room polygon) that contains BOTH wall vertices.
#   2. Compute the wall's left (+Z-local) and right (-Z-local) perpendicular normals.
#   3. Sample a point 5 cm to the left and 5 cm to the right of the wall midpoint.
#   4. Run a 2D point-in-polygon test on both samples.
#   5. Return "inner-left"  if the left  sample is inside the polygon.
#      Return "inner-right" if the right sample is inside the polygon.
#
# In Godot we work in the 2D plan space (x,y = frontend x,y before converting
# to metres), so source coordinates stay in the input's original plan units.
#
# Returns: "inner-left", "inner-right", or "" (unknown / no area found).
func _get_wall_facing_direction(line: Dictionary, vertices: Dictionary, areas: Dictionary) -> String:
	var v1_id = str(line["vertices"][0])
	var v2_id = str(line["vertices"][1])
	if not vertices.has(v1_id) or not vertices.has(v2_id):
		return ""

	var vA = vertices[v1_id]
	var vB = vertices[v2_id]
	var ax = float(vA["x"]); var ay = float(vA["y"])
	var bx = float(vB["x"]); var by = float(vB["y"])
	var a = _plan_point_2d(ax, ay)
	var b = _plan_point_2d(bx, by)
	ax = a.x
	ay = a.y
	bx = b.x
	by = b.y

	# Wall direction vector (2D)
	var dir = Vector2(bx - ax, by - ay).normalized()

	# Left (+Z local) and right (-Z local) perpendicular normals
	var left_normal = Vector2(-dir.y, dir.x)
	var right_normal = Vector2(dir.y, -dir.x)

	# Wall midpoint
	var mid = Vector2((ax + bx) * 0.5, (ay + by) * 0.5)

	# Sample 5 cm to each side.
	# Convert that physical distance back into source units so it stays correct
	# for both cm-based legacy files and mm-based 2.0.0 files.
	var sample_offset = 0.05 / max(_scene_unit_scale, 0.000001)
	var left_sample = mid + left_normal * sample_offset
	var right_sample = mid + right_normal * sample_offset

	# â”€â”€ Check ALL areas containing both wall vertices â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
	# For shared walls (between two rooms), different areas yield opposite
	# results.  We use the lexicographically smallest area_id to guarantee
	# a deterministic outcome regardless of dictionary iteration order
	# (which changes after scene-optimizer culling).
	var best_result = ""
	var best_area_id = ""

	# ── T-Junction fix: Geometry2D boundary-distance check ───────────────────
	# Instead of requiring both endpoints to be named room corners, we check
	# whether each wall endpoint lies ON a boundary segment of the area polygon.
	# This correctly handles T-junction walls whose endpoints land mid-edge.
	var snap_dist = 0.05 / max(_scene_unit_scale, 0.000001) # 5 cm in source units

	for area_id in areas:
		var area = areas[area_id]
		if not area.has("vertices"):
			continue
		var area_verts = area["vertices"]

		# Build polygon from this area's vertices
		var area_polygon: Array = []
		for vid in area_verts:
			var vs = str(vid)
			if vertices.has(vs):
				var v = vertices[vs]
				area_polygon.append(_plan_point_2d(float(v["x"]), float(v["y"])))
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
			continue # Both inside or neither â€” skip this area

		# Deterministic: pick the area with smallest area_id
		if best_result == "" or area_id < best_area_id:
			best_result = result
			best_area_id = area_id

	if best_result != "":
		return best_result

	# No area found â€” return empty (fallback to centroid in caller)
	return ""

# Ray-casting point-in-polygon test (mirrors frontend isPointInPolygon).
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

# —————————————————————————————————————————————————————————————————————————————
# _build_layer_geometry  (updated — matches frontend inner/outer assignment)
# —————————————————————————————————————————————————————————————————————————————
func _build_layer_geometry(layer_data, layer_altitude, show_all_floors = true, render_mode: String = "INTERIOR", use_showall: bool = true):
	var csg = CSGCombiner3D.new()
	csg.use_collision = true
	add_child(csg)

	var lines = layer_data["lines"]
	var vertices = layer_data["vertices"]
	var scale_factor = _scene_unit_scale # Convert source units → metres

	# Helper map for hole definitions
	var all_holes = {}
	if layer_data.has("holes"):
		all_holes = layer_data["holes"]
	if _floor_plan_root_data.has("holes") and typeof(_floor_plan_root_data["holes"]) == TYPE_DICTIONARY:
		for hole_id in _floor_plan_root_data["holes"]:
			if not all_holes.has(hole_id):
				all_holes[hole_id] = _floor_plan_root_data["holes"][hole_id]

	# Areas dictionary — required by the facing-direction helper
	var areas = {}
	if layer_data.has("areas"):
		areas = layer_data["areas"]

	# Structures dictionary — used for floor openings and procedural meshes
	var structures = {}
	if layer_data.has("structures") and typeof(layer_data["structures"]) == TYPE_DICTIONARY:
		structures = layer_data["structures"]
	var camera_view_segment := _get_camera_view_segment_2d()

	# ——— Compute room centroid (used for inner_sign fallback only) —————————————
	# The centroid approach is a legacy fallback kept for walls that belong to
	# no named area. The primary facing-direction logic now uses per-area
	# polygon tests via _get_wall_facing_direction(), matching the frontend.
	var room_centroid = Vector3.ZERO
	var centroid_count = 0
	for area_id in areas:
		var area = areas[area_id]
		if not area.has("vertices"): continue
		for v_id in area["vertices"]:
			var vs = str(v_id)
			if vertices.has(vs):
				var v = vertices[vs]
				room_centroid += _plan_point_3d(float(v["x"]), float(v["y"]))
				centroid_count += 1
	if centroid_count > 0:
		room_centroid /= centroid_count
	var has_centroid = centroid_count > 0

	print("Layer has ", lines.size(), " lines. Room centroid: ", room_centroid)

	# ——— 1. Build Walls ——————————————————————————————————————————————————————
	for line_id in lines:
		var line = lines[line_id]
		var wall_visible = true
		if line.has("visible"): wall_visible = bool(line["visible"])
		elif line.has("isvisible"): wall_visible = bool(line["isvisible"])
		elif line.has("isVisible"): wall_visible = bool(line["isVisible"])
		if not wall_visible: continue

		var wall_csg = CSGCombiner3D.new()
		wall_csg.name = "WallCSG_" + str(line_id)
		wall_csg.use_collision = true
		add_child(wall_csg)
		
		if not line.has("vertices") or line["vertices"].size() < 2: continue

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

		var p1 = _plan_point_3d(v1_x + align_offset_2d.x, v1_y + align_offset_2d.y)
		var p2 = _plan_point_3d(v2_x + align_offset_2d.x, v2_y + align_offset_2d.y)

		var diff = p2 - p1
		var length = diff.length()
		var center = (p1 + p2) / 2.0
		var height = 240.0 * scale_factor # Default height

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

		# ——— Determine inner/outer facing (mirrors frontend exactly) ———————————
		var wall_facing = _get_wall_facing_direction(line, vertices, areas)

		# ——— Fallback: centroid dot-product (legacy, area-free walls) ———————————
		var inner_sign = 1.0 # +1 → +Z is inner, -1 → -Z is inner
		if wall_facing == "inner-left":
			inner_sign = 1.0
		elif wall_facing == "inner-right":
			inner_sign = -1.0
		else:
			# No area polygon found — fall back to centroid approach
			var wall_basis = Basis(Vector3.UP, wall_angle)
			var wall_normal_world = wall_basis * Vector3(0, 0, 1)
			if has_centroid:
				var to_centroid = room_centroid - center
				to_centroid.y = 0.0
				if to_centroid.dot(wall_normal_world) < 0:
					inner_sign = -1.0
			wall_facing = "inner-left" if inner_sign > 0 else "inner-right"

		print("Wall ", line_id, " facing: ", wall_facing, " inner_sign: ", inner_sign)

		# ——— Resolve inner/outer material data from the line ———————————————————
		var inner_mat_data = _resolve_wall_face_material(line, "inner", wall_facing)
		var outer_mat_data = _resolve_wall_face_material(line, "outer", wall_facing)

		var wall = CSGPolygon3D.new()
		wall.polygon = poly_pts
		wall.depth = wall_thickness
		wall.position = wall_pos + Basis(Vector3.UP, wall_angle) * Vector3(0, 0, wall_thickness / 2.0)
		wall.rotation.y = wall_angle

		var outer_mat: StandardMaterial3D
		if outer_mat_data != null:
			outer_mat = create_material(outer_mat_data, "wall")
		else:
			outer_mat = StandardMaterial3D.new()
			outer_mat.albedo_color = Color(0.82, 0.82, 0.82)
			if USE_MATERIAL_OPTIMIZER:
				outer_mat = MOImage.optimize_material(outer_mat, {}, "wall")

		var inner_mat_for_wall: StandardMaterial3D
		if inner_mat_data != null:
			inner_mat_for_wall = create_material(inner_mat_data, "wall")
		else:
			inner_mat_for_wall = StandardMaterial3D.new()
			inner_mat_for_wall.albedo_color = Color(0.82, 0.82, 0.82)
			if USE_MATERIAL_OPTIMIZER:
				inner_mat_for_wall = MOImage.optimize_material(inner_mat_for_wall, {}, "wall")

		if render_mode == "INTERIOR":
			# INTERIOR: apply inner material on the structural wall.
			# The camera is inside and mainly sees the inner face. This
			# prevents outer textures (brick/stone) from bleeding through.
			inner_mat_for_wall.cull_mode = BaseMaterial3D.CULL_DISABLED
			inner_mat_for_wall = _apply_architecture_texture_scale(
				inner_mat_for_wall,
				inner_mat_data,
				Vector2(corner_length, height)
			)
			wall.material = inner_mat_for_wall
		else:
			# Exterior: show outer material from both sides
			outer_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			outer_mat = _apply_architecture_texture_scale(
				outer_mat,
				outer_mat_data,
				Vector2(corner_length, height)
			)
			wall.material = outer_mat

		wall_csg.add_child(wall)

		# â”€â”€ Dual overlay panels (INTERIOR mode only) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
		#
		# To correctly render both inner and outer textures on their
		# respective faces (matching the frontend's per-face material
		# assignment), we create two thin overlay panels:
		#   1. Inner panel â€” on the room-facing side, with inner material
		#   2. Outer panel â€” on the exterior-facing side, with outer material
		#
		# Each panel is 3 mm thick, placed flush with the structural wall
		# surface, using CULL_BACK (only the outward-facing side renders).
		# This ensures the camera sees the correct texture regardless of
		# which side of the wall it is viewing.
		#
		# EXTERIOR render: skip â€” structural wall alone is sufficient.
		var inner_csg: CSGCombiner3D = null
		var outer_csg: CSGCombiner3D = null

		if render_mode == "INTERIOR":
			var face_t = 0.003 # 3 mm â€” clears Z-fighting at close range
			var wall_basis = Basis(Vector3.UP, wall_angle)

			# â”€â”€ Inner overlay panel â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
				var inner_mat = create_material(inner_mat_data, "wall")
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

			# â”€â”€ Outer overlay panel â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
			# Placed on the opposite side from the inner panel.
			# This ensures walls viewed from adjacent rooms or the exterior
			# show the correct outer texture instead of the inner material
			# that is now on the structural wall.
			if outer_mat_data != null:
				var outer_offset = wall_thickness / 2.0 + face_t / 2.0
				# Outer side is opposite to inner_sign
				var outer_world = wall_pos + wall_basis * Vector3(0, 0, outer_offset * (-inner_sign))

				outer_csg = CSGCombiner3D.new()
				outer_csg.position = outer_world
				outer_csg.rotation.y = wall_angle
				add_child(outer_csg)

				var outer_box = CSGPolygon3D.new()
				outer_box.polygon = poly_pts
				outer_box.depth = face_t
				outer_box.position = Vector3(0, 0, face_t / 2.0)
				var outer_panel_mat = create_material(outer_mat_data, "wall")
				outer_panel_mat = _apply_architecture_texture_scale(
					outer_panel_mat,
					outer_mat_data,
					poly_span
				)
				# CULL_DISABLED: exterior panel must render from inside the room too.
				outer_panel_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				outer_box.material = outer_panel_mat
				outer_csg.add_child(outer_box)

		# â”€â”€ Build Holes (Doors / Windows) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
					var wall_len = p1.distance_to(p2)
					if wall_len > 0.0001:
						offset_ratio = clamp((raw_offset * scale_factor) / wall_len, 0.0, 1.0)
					else:
						offset_ratio = raw_offset
				else:
					offset_ratio = raw_offset

				var hole_pos_xz = p1.lerp(p2, offset_ratio)
				var h_center_pos = hole_pos_xz
				h_center_pos.y = layer_altitude + h_alt + h_height / 2.0

				if h_width < 0.01 or h_height < 0.01: continue

				# 1. Cut through the structural wall
				var hole_csg = CSGBox3D.new()
				hole_csg.operation = CSGBox3D.OPERATION_SUBTRACTION
				hole_csg.size = Vector3(h_width, h_height, wall_thickness + 0.2)
				hole_csg.position = h_center_pos
				hole_csg.rotation.y = wall_angle
				wall_csg.add_child(hole_csg)
				print("Added hole cutter at: ", h_center_pos)

				# 2. Cut through the inner face panel
				if inner_csg != null:
					var inner_hole = CSGBox3D.new()
					inner_hole.operation = CSGBox3D.OPERATION_SUBTRACTION
					inner_hole.size = Vector3(h_width, h_height, 0.5)
					var delta_w = h_center_pos - inner_csg.position
					var local_pos = Basis(Vector3.UP, wall_angle).transposed() * delta_w
					inner_hole.position = local_pos
					inner_csg.add_child(inner_hole)

				# 2b. Cut through the outer face panel
				if outer_csg != null:
					var outer_hole = CSGBox3D.new()
					outer_hole.operation = CSGBox3D.OPERATION_SUBTRACTION
					outer_hole.size = Vector3(h_width, h_height, 0.5)
					var delta_o = h_center_pos - outer_csg.position
					var local_pos_o = Basis(Vector3.UP, wall_angle).transposed() * delta_o
					outer_hole.position = local_pos_o
					outer_csg.add_child(outer_hole)

				# 3. Exterior black blocker (if flagged)
				if hole.get("is_exterior_black", false):
					var blocker = CSGBox3D.new()
					blocker.size = Vector3(h_width + 0.02, h_height + 0.02, 0.01)
					blocker.position = h_center_pos
					blocker.rotation.y = wall_angle
					var black_mat = StandardMaterial3D.new()
					black_mat.albedo_color = Color.BLACK
					blocker.material = black_mat
					add_child(blocker)
					print("Added black visibility blocker for exterior hole: ", hid)

				# Determine hole type before asset loading so is_window_for_sun is in scope
				# throughout the asset block (used for glass detection inside if asset_node:).
				var hole_type_sun := str(hole.get("type", "")).to_lower()
				var hole_name_sun := str(hole.get("name", "")).to_lower()
				var is_window_for_sun := hole_type_sun == "window" or "window" in hole_name_sun
				# Glass flag: set to true if the loaded hole asset contains glass meshes.
				# Used to enable shadow_enabled on glass-door fill SpotLights.
				var hole_has_glass := false
				# 4. Instantiate door/window asset GLB
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

									_apply_item_materials(asset_node, hole)
									_fix_glass_materials_for_shadows(asset_node)
									print("Loaded hole asset: ", model_path, " final scale: ", asset_node.scale, " (shadows: handled by material)")
									# Detect glass: enables shadow on glass-door fill SpotLights
									if not is_window_for_sun:
										hole_has_glass = _node_has_any_glass(asset_node)

									# Keep the actual window GLB only.
									# If the imported window is glass-only (or its frame meshes
									# don't cast enough shadow), add a tiny procedural mullion
									# grid so the direct sun still projects a readable window pattern.
									var frame_casters := _count_shadow_casters(asset_node)
									var hole_type := str(hole.get("type", "")).to_lower()
									var hole_name := str(hole.get("name", "")).to_lower()
									var model_name := str(model_path).to_lower()
									var is_window_hole := hole_type == "window" or "window" in hole_name or "window" in model_name
									if ENABLE_PROCEDURAL_WINDOW_GRID_CASTER and is_window_hole and frame_casters == 0 and h_alt > 0.15:
										var wall_basis_g = Basis(Vector3.UP, wall_angle)
										var outer_dir_g = wall_basis_g * Vector3(0, 0, 1) * (-inner_sign)
										_add_window_grid_shadow_caster(
											h_center_pos, h_width, h_height,
											wall_angle, outer_dir_g, layer_altitude
										)
										print("  GLB had no frame casters â€” added procedural grid")
							else:
								print("Failed to load hole GLTF: ", model_path, " Error: ", error)

						_tracked_assets.append({
							"type": "hole_asset",
							"id": hole.get("id", "unknown"),
							"name": hole.get("name", "unknown"),
							"path": model_path
						})

				# -- 5. Collect WINDOW openings for sunlight placement --------
				# Only windows get portal lights -- doors should not receive
				# portal SpotLights because they aim inward and create
				# incorrect shadows (e.g. forward ceiling shadow from a door).
				if is_window_for_sun:
					var wall_basis_sun = Basis(Vector3.UP, wall_angle)
					var wall_normal_sun = wall_basis_sun * Vector3(0, 0, 1)
					# Outer direction = away from interior
					var outer_direction = wall_normal_sun * (-inner_sign)
					# Inner direction = into the room
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
					print("Collected WINDOW opening for sunlight: pos=", h_center_pos, " size=", Vector2(h_width, h_height), " alt=", h_alt)
				else:
					# Non-window hole (door, opening, etc.) — collect for a subtle
					# inward SpotLight that adds gentle fill without incorrect shadows.
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
					print("Collected non-window opening (", hole_type_sun, ") for door fill light: ", hole_name_sun)

		# ── 6. Add Wall Shapes (CustomShapes) ──────────────────────────────────
		# Build a list of hole rectangles in wall-local 2D space so that we can
		# clip them out of every custom shape before rendering.
		# Wall-local X = distance along wall from p1 (metres), Y = height from floor.
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
				var h_cx_along = off_ratio * length # centre x along wall
				var h_left = h_cx_along - hw * 0.5
				var h_right = h_cx_along + hw * 0.5
				var h_bot = ha # from floor
				var h_top = ha + hh
				# Store as a PackedVector2Array rectangle (CCW)
				var hole_rect = PackedVector2Array()
				hole_rect.append(Vector2(h_left, h_bot))
				hole_rect.append(Vector2(h_right, h_bot))
				hole_rect.append(Vector2(h_right, h_top))
				hole_rect.append(Vector2(h_left, h_top))
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
				# Geometry2D.clip_polygons(subject, clip) = subject MINUS clip.
				# We iteratively subtract every hole rectangle from the shape polygon.
				# The result may be zero, one, or several disjoint polygons — emit each.
				var clipped_fragments: Array = [shape_poly_pts]
				for hole_rect in wall_local_hole_rects:
					var next_fragments: Array = []
					for frag in clipped_fragments:
						var remaining = Geometry2D.clip_polygons(frag, hole_rect)
						if remaining.is_empty():
							pass # entirely inside the hole — discard
						else:
							for r in remaining:
								if r.size() >= 3:
									next_fragments.append(r)
					clipped_fragments = next_fragments
					if clipped_fragments.is_empty():
						break

				if clipped_fragments.is_empty():
					print("customShape fully clipped by holes — skipped")
					continue

				# ── Step 1: Detect createOpening flag ─────────────────────────────
				var is_opening = false
				if shape.has("createOpening"):
					var val = shape["createOpening"]
					if typeof(val) == TYPE_BOOL:
						is_opening = val
					else:
						is_opening = (str(val).to_lower() == "true")

				# Prepare material once per original shape
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
						var smat = create_material(shape["material"], "wall")
						# Use custom-shape scale (no density boost) for wall custom shapes
						smat = _apply_custom_shape_texture_scale(smat, shape["material"], shape_poly_span)
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

				print("Added customShape: ", shape.get("shapeKind", "polygon"), " is_opening=", is_opening, " side=", side_sign, " fragments=", frag_idx)

	# â”€â”€ 2. Build Floors and Ceilings from Areas â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

	var force_uniform_ceiling_height = false
	if layer_data.has("force_uniform_ceiling_height"):
		force_uniform_ceiling_height = bool(layer_data["force_uniform_ceiling_height"])
	var global_ceil_height = max_wall_height

	if layer_data.has("externalAreas") and typeof(layer_data["externalAreas"]) == TYPE_DICTIONARY:
		print("Building Floors for ", layer_data["externalAreas"].size(), " external areas.")
		for area_id in layer_data["externalAreas"]:
			var ext_area = layer_data["externalAreas"][area_id]
			if typeof(ext_area) != TYPE_DICTIONARY:
				continue
			_build_external_area_floor(str(area_id), ext_area, vertices, layer_altitude, scale_factor)

	if layer_data.has("areas"):
		print("Building Floors/Ceilings for ", layer_data["areas"].size(), " areas.")
		for area_id in layer_data["areas"]:
			var area = layer_data["areas"][area_id]
			if not area.has("vertices") or area["vertices"].size() < 3: continue

			var polygon = PackedVector2Array()
			for v_id in area["vertices"]:
				var vs = str(v_id)
				if vertices.has(vs):
					var v = vertices[vs]
					var p = _plan_point_2d(float(v["x"]), float(v["y"]))
					polygon.append(p * scale_factor)

			if polygon.size() < 3: continue

			# Enforce CCW winding
			var signed_area = 0.0
			for pi in range(polygon.size()):
				var pa = polygon[pi]
				var pb = polygon[(pi + 1) % polygon.size()]
				signed_area += (pa.x * pb.y - pb.x * pa.y)
			signed_area *= 0.5
			if signed_area < 0:
				polygon.reverse()

			var uv_polygon = polygon.duplicate()
			polygon = _expand_polygon_outward(polygon, max_wall_thickness / 2.0)

			# â”€â”€ 1. Floor â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
			var floor_props = area.get("floor_properties", {})
			var floor_is_visible = true
			if floor_props.has("visible"):
				floor_is_visible = bool(floor_props["visible"])
			elif floor_props.has("isvisible"):
				floor_is_visible = bool(floor_props["isvisible"])
			elif floor_props.has("isVisible"):
				floor_is_visible = bool(floor_props["isVisible"])

			print("[VISIBILITY] Area: ", area_id, " | Floor visible: ", floor_is_visible, " (Found property: ", floor_props.has("isvisible") or floor_props.has("isVisible"), ")")

			if floor_is_visible:
				var floor_depth = 0.1
				if floor_props.has("thickness"):
					var t = float(floor_props["thickness"]) * scale_factor
					if t > 0.001: floor_depth = t

				var floor_poly = CSGPolygon3D.new()
				floor_poly.polygon = polygon
				floor_poly.mode = CSGPolygon3D.MODE_DEPTH
				floor_poly.depth = floor_depth
				floor_poly.rotation.x = PI / 2
				floor_poly.position.y = layer_altitude
				var floor_span = _get_polygon_world_span(uv_polygon)

				# Check if paving is enabled
				var has_paving = false
				var pav_cfg = {}
				if floor_props.has("paving") and typeof(floor_props["paving"]) == TYPE_DICTIONARY:
					pav_cfg = floor_props["paving"]
					var pav_pattern = str(pav_cfg.get("pattern", "none")).strip_edges().to_lower()
					if pav_pattern != "none" and pav_pattern != "":
						has_paving = true

				if has_paving:
					# Generate grout color for floor_poly
					var grout_color: Color = Color(0.0, 0.0, 0.0) # default black grout
					var gap_color_mode = str(pav_cfg.get("gapColorMode", "none")).strip_edges().to_lower()
					var has_gap_color = pav_cfg.has("gapColor") and str(pav_cfg.get("gapColor", "")).strip_edges() != ""
					var pav_material_data = floor_props.get("material", {})
					if has_gap_color:
						var raw_color_str = str(pav_cfg["gapColor"]).strip_edges()
						if raw_color_str.is_valid_html_color():
							grout_color = Color(raw_color_str)
					elif gap_color_mode == "material":
						if pav_material_data.has("color") and str(pav_material_data["color"]).strip_edges() != "":
							var mat_col = Color(str(pav_material_data["color"]))
							grout_color = mat_col.lightened(0.55)

					var grout_mat = StandardMaterial3D.new()
					grout_mat.albedo_color = grout_color
					grout_mat.roughness = 0.90
					grout_mat.metallic = 0.0
					floor_poly.material = grout_mat
					print("[Paving] Setting base floor_poly material to grout color: ", grout_color)
				else:
					if floor_props.has("material"):
						var f_mat = create_material(floor_props["material"], "floor")
						f_mat = _apply_architecture_texture_scale(
							f_mat,
							floor_props["material"],
							floor_span
						)
						floor_poly.material = f_mat
						print("Floor Material Optimized: ", floor_props["material"].get("mapUrl", "default"))
					else:
						var floor_mat = StandardMaterial3D.new()
						floor_mat.albedo_color = Color(0.8, 0.8, 0.8)
						# Apply default optimizer logic to fallback floor with context
						if USE_MATERIAL_OPTIMIZER:
							floor_mat = MOImage.optimize_material(floor_mat, {"color": "#cccccc"}, "floor")
						floor_poly.material = floor_mat

				var floor_csg = CSGCombiner3D.new()
				floor_csg.name = "FloorCSG_" + str(area_id)
				floor_csg.use_collision = true
				add_child(floor_csg)

				floor_csg.add_child(floor_poly)
				structure_builder._add_floor_opening_cutters(floor_csg, structures, str(area_id), layer_altitude, floor_depth, scale_factor)

				# ── Pre-collect custom shape polygons for paving exclusion ────────
				# When both paving AND custom shapes exist, paving tiles must be
				# clipped around the custom shape footprints so the shapes are
				# clearly visible on top.
				var floor_exclusion_polys: Array = []
				if floor_props.has("customShapes") and typeof(floor_props["customShapes"]) == TYPE_ARRAY:
					for cs in floor_props["customShapes"]:
						if not cs.has("points") or typeof(cs["points"]) != TYPE_ARRAY or cs["points"].size() < 3:
							continue
						var ex_pts = PackedVector2Array()
						for pt in cs["points"]:
							var p = _plan_point_2d(float(pt.get("x", 0)), float(pt.get("y", 0)))
							ex_pts.append(p * scale_factor)
						# Ensure CCW winding for Geometry2D clipping
						var ex_sa = 0.0
						for epi in range(ex_pts.size()):
							var epa = ex_pts[epi]
							var epb = ex_pts[(epi + 1) % ex_pts.size()]
							ex_sa += (epa.x * epb.y - epb.x * epa.y)
						if ex_sa < 0: ex_pts.reverse()
						floor_exclusion_polys.append(ex_pts)

				# ── Paving Pattern Overlay ─────────────────────────────────────────
				# When the frontend has set floor_properties.paving (pattern != 'none')
				# we generate per-tile CSGPolygon3D slabs clipped to the room polygon,
				# sitting 2 mm above the base floor slab so they always win z-fighting.
				# pav_root is parented to floor_csg so it stays with the floor node.
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
							pav_material_data,
							floor_csg,
							floor_exclusion_polys
						)
						print("[Paving] Applied pattern '", pav_pattern, "' to area ", area_id, " (exclusions: ", floor_exclusion_polys.size(), ")")

				# ── Floor Custom Shapes ─────────────────────────────────────────────
				# IMPORTANT: Custom shapes are added as STANDALONE CSGCombiner3D nodes
				# directly to the scene root — NOT inside floor_csg.
				# Putting them inside floor_csg caused CSG boolean operations to carve
				# black holes/pits into the floor.  As standalone nodes they are rendered
				# as independent geometry with zero CSG interaction with the floor slab.
				#
				# Y position:  layer_altitude + 0.025 (25 mm above floor base)
				#              This clears the paving tile top face (at +2 mm) by 23 mm,
				#              guaranteeing the shape is always visible on top.
				if floor_props.has("customShapes"):
					for shape_idx in range(floor_props["customShapes"].size()):
						var shape = floor_props["customShapes"][shape_idx]
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
						# Enforce CCW winding so the top face normal points up
						var shape_signed_area = 0.0
						for pi in range(shape_pts.size()):
							var pa = shape_pts[pi]
							var pb = shape_pts[(pi + 1) % shape_pts.size()]
							shape_signed_area += (pa.x * pb.y - pb.x * pa.y)
						if shape_signed_area < 0: shape_pts.reverse()

						# Standalone wrapper — no CSG interaction with floor/paving
						var shape_root = CSGCombiner3D.new()
						shape_root.name = "FloorCustomShape_%s_%d" % [str(area_id), shape_idx]
						add_child(shape_root)

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
							var smat = create_material(shape["material"], "floor")
							var span = Vector2(max_x - min_x, max_y - min_y)
							smat = _apply_custom_shape_texture_scale(smat, shape["material"], span)
							smat.cull_mode = BaseMaterial3D.CULL_BACK
							s_poly.material = smat
						shape_root.add_child(s_poly)
						print("[CustomShape] Floor shape ", shape_idx, " standalone at y=", s_poly.position.y, " (area=", area_id, ")")
			# â”€â”€ 2. Ceiling â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
			var ceiling_props = area.get("ceiling_properties", {})
			# Ceiling visibility rules:
			#   showAllFloors=true  â†’ ceiling visible by default, hidden ONLY if isvisible=false
			#   showAllFloors=false â†’ ceiling hidden by default (removed), kept ONLY if isvisible=true
			var has_visibility_prop = ceiling_props.has("visible") or ceiling_props.has("isvisible") or ceiling_props.has("isVisible")
			var ceil_is_visible: bool
			if has_visibility_prop:
				if ceiling_props.has("visible"): ceil_is_visible = bool(ceiling_props["visible"])
				elif ceiling_props.has("isvisible"): ceil_is_visible = bool(ceiling_props["isvisible"])
				else: ceil_is_visible = bool(ceiling_props["isVisible"])
			else:
				ceil_is_visible = show_all_floors

			print("[VISIBILITY] Area: ", area_id, " | Ceiling visible: ", ceil_is_visible, " | showAllFloors: ", show_all_floors, " | has_prop: ", has_visibility_prop)

			if ceil_is_visible:
				# Resolve ceiling elevation
				var ceil_height = global_ceil_height
				if not force_uniform_ceiling_height:
					ceil_height = max_wall_height
					if area.has("properties") and area["properties"].has("height"):
						var h_prop = area["properties"]["height"]
						var ch = 0.0
						if typeof(h_prop) == TYPE_DICTIONARY and h_prop.has("length"):
							ch = float(h_prop["length"]) * scale_factor
						else:
							ch = float(h_prop) * scale_factor
						# 1.5 m safety threshold: ignore sub-1.5 m values (curbs, outdoor
						# half-walls, or typos like 300 mm) to prevent ceiling collapse.
						if ch >= 1.5: ceil_height = min(ch, max_wall_height)
					elif ceiling_props.has("height"):
						var ch = float(ceiling_props["height"]) * scale_factor
						# 1.5 m safety threshold
						if ch >= 1.5: ceil_height = min(ch, max_wall_height)

				var ceiling_world_y = layer_altitude + ceil_height

				# EXTRA EXCEPTION: Hide ceiling if camera is ABOVE it â€” but ONLY when
				# showAllFloors is false AND use_showall is true (normal culling mode).
				# When use_showall=False, scene_optimizer.py has explicitly forced
				# isvisible=True for ALL ceilings â€” that decision must NOT be overridden
				# here by a camera-height check. This was the root cause of ceilings
				# disappearing even when use_showall=False was set.
				if use_showall and not show_all_floors and _camera_height_m > (ceiling_world_y + 0.1):
					ceil_is_visible = false
					print("[VISIBILITY] Hiding Ceiling automatically (showAllFloors=false): Camera height (", _camera_height_m, ") is above ceiling Y (", ceiling_world_y, ")")

				if ceil_is_visible:
					var ceil_depth = 0.1
					if ceiling_props.has("thickness"):
						var t = float(ceiling_props["thickness"]) * scale_factor
						if t > 0.001: ceil_depth = t
					if ceil_depth < 0.05:
						ceil_depth = 0.05

					var ceil_poly = CSGPolygon3D.new()
					ceil_poly.polygon = polygon
					ceil_poly.mode = CSGPolygon3D.MODE_DEPTH
					ceil_poly.depth = ceil_depth
					ceil_poly.rotation.x = PI / 2
					ceil_poly.position.y = ceiling_world_y - ceil_depth
					var ceil_span = _get_polygon_world_span(uv_polygon)

					if ceiling_props.has("material"):
						var c_mat = create_material(ceiling_props["material"], "ceiling")
						c_mat = _apply_architecture_texture_scale(
							c_mat,
							ceiling_props["material"],
							ceil_span
						)
						ceil_poly.material = c_mat
					else:
						var ceil_mat = StandardMaterial3D.new()
						ceil_mat.albedo_color = Color(0.82, 0.82, 0.82)
						# Optimize fallback ceiling
						if USE_MATERIAL_OPTIMIZER:
							ceil_mat = MOImage.optimize_material(ceil_mat, {"color": "#d1d1d1"}, "ceiling")
						ceil_poly.material = ceil_mat

					var ceil_csg = CSGCombiner3D.new()
					ceil_csg.name = "CeilingCSG_" + str(area_id)
					ceil_csg.use_collision = true
					add_child(ceil_csg)
					ceil_csg.add_child(ceil_poly)
					
					# ── Ceiling Custom Shapes ───────────────────────────────────────────
					# Each shape is a flat panel that hangs BELOW the base ceiling slab.
					# Position rule:
					#   Top face  = ceiling_world_y - ceil_depth - shape_depth - (1mm * idx)
					#   Bottom face (visible from room) = top - shape_depth
					# Subtracting shape_depth ensures the shape is fully BELOW the slab
					# bottom and not z-fighting with or embedded inside it.
					# Shapes are parented to ceil_csg (not bare add_child).
					# Texture scale uses _apply_custom_shape_texture_scale (no density boost).
					if ceiling_props.has("customShapes"):
						for shape_idx in range(ceiling_props["customShapes"].size()):
							var shape = ceiling_props["customShapes"][shape_idx]
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
							# Extend depth to ensure it penetrates the ceiling base by 10mm
							s_poly.depth = shape_depth + 0.010
							s_poly.rotation.x = PI / 2
							# Base ceiling bottom face is at (ceiling_world_y - ceil_depth).
							# We want the shape to stick out below the ceiling by exactly `shape_depth`.
							# Since rotation.x = PI/2 means the polygon extrudes UPWARDS (+Y), 
							# position.y is the BOTTOM of the shape.
							s_poly.position.y = (ceiling_world_y - ceil_depth) - shape_depth - 0.001 * shape_idx
							if shape.has("material"):
								var smat = create_material(shape["material"], "ceiling")
								var span = Vector2(max_x - min_x, max_y - min_y)
								# Use custom-shape scale (no density boost) so tile fills the shape correctly
								smat = _apply_custom_shape_texture_scale(smat, shape["material"], span)
								s_poly.material = smat
							# Parent to ceil_csg so shape lives in the correct CSG combiner
							ceil_csg.add_child(s_poly)

					print("[INFO] Created ceiling for area: ", area_id, " at Y=", ceiling_world_y)

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# _resolve_wall_face_material
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Returns a material-data dictionary for the requested face ("inner" or "outer").
#
# Lookup priority (mirrors the frontend's material resolution):
#   1. line["asset_urls"][face]           â€” texture set block (mapUrl, fallback_color, etc.)
#   2. line["inner_properties"]["material"] / line["outer_properties"]["material"]
#   3. null (caller uses default grey)
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

	# 1. asset_urls block  (same data the frontend wallTextures come from)
	if line.has("asset_urls") and typeof(line["asset_urls"]) == TYPE_DICTIONARY:
		var au = line["asset_urls"]
		if au.has(lookup_face) and typeof(au[lookup_face]) == TYPE_DICTIONARY:
			var block = au[lookup_face]
			# Build a unified mat_data dict that create_material() understands
			var mat_data = {}

			# Texture URL
			if block.has("mapUrl") and block["mapUrl"] != null and str(block["mapUrl"]) != "":
				mat_data["mapUrl"] = block["mapUrl"]
			elif block.has("texture_urls") and typeof(block["texture_urls"]) == TYPE_ARRAY and block["texture_urls"].size() > 0:
				mat_data["mapUrl"] = block["texture_urls"][0]

			# Normal map
			if block.has("normalUrl") and block["normalUrl"] != null and str(block["normalUrl"]) != "":
				mat_data["normalUrl"] = block["normalUrl"]

			# Roughness map
			if block.has("roughnessUrl") and block["roughnessUrl"] != null and str(block["roughnessUrl"]) != "":
				mat_data["roughnessUrl"] = block["roughnessUrl"]

			# Fallback colour (used when texture is absent or as tint)
			var fallback_color = block.get("fallback_color", "")
			if fallback_color == null or str(fallback_color).strip_edges() == "":
				fallback_color = ""
			if fallback_color != "":
				mat_data["color"] = str(fallback_color)

			# Texture scale (maps to UV repeat in create_material)
			if block.has("texture_scale_x") or block.has("texture_scale_y"):
				var sx = float(block.get("texture_scale_x", 0.0))
				var sy = float(block.get("texture_scale_y", 0.0))
				if sx > 0.0 and sy > 0.0:
					mat_data["scale"] = [sx, sy]
			var repeat_x = float(block.get("repeatX", 0.0))
			var repeat_y = float(block.get("repeatY", 0.0))
			if repeat_x > 0.0 or repeat_y > 0.0:
				mat_data["repeatX"] = repeat_x
				mat_data["repeatY"] = repeat_y
			else:
				if block.has("repeat") and typeof(block["repeat"]) == TYPE_ARRAY:
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

	# 3. Cross-fallback: if requesting "outer" and only "inner" exists, use inner (and vice-versa)
	if line.has(other_prop_key) and typeof(line[other_prop_key]) == TYPE_DICTIONARY:
		var props = line[other_prop_key]
		if props.has("material") and typeof(props["material"]) == TYPE_DICTIONARY:
			return props["material"]

	return null

# ==============================================================================
# CUSTOM SHAPES AND STRUCTURES
# ==============================================================================
# WHY IT EXISTS: Handles complex, non-standard geometry that isn't a basic wall. 
# This builds multi-level staircases, pillars, ramps, and custom-shaped walls 
# using Godot's CSG (Constructive Solid Geometry) to mathematically carve out 
# physical blocks.
# ==============================================================================
func build_structures(data):
	if data.has("layers"):
		var layers_dict = data["layers"]
		var show_all_floors = data.get("showAllFloors", true)
		var selected_layer = data.get("selectedLayer", "")

		for layer_id in layers_dict:
			if not show_all_floors and selected_layer != "" and str(layer_id) != str(selected_layer):
				continue

			var layer = layers_dict[layer_id]
			var layer_alt = 0.0
			if show_all_floors:
				if layer.has("altitude"):
					var alt_val = layer["altitude"]
					if typeof(alt_val) == TYPE_DICTIONARY and alt_val.has("length"):
						layer_alt = float(alt_val["length"]) * _scene_unit_scale
					else:
						layer_alt = float(alt_val) * _scene_unit_scale

			if layer.has("structures"):
				var layer_render_mode = str(layer.get("render_mode", data.get("render_mode", "INTERIOR"))).to_upper()
				_load_layer_structures(layer["structures"], layer_alt, str(layer_id), layer_render_mode)
	if data.has("structures"):
		_load_layer_structures(data["structures"], 0.0, "root", str(data.get("render_mode", "INTERIOR")).to_upper())

func _load_layer_structures(structures, layer_altitude, layer_id := "", render_mode: String = "INTERIOR"):
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
		_build_structure_mesh(structure, layer_altitude, layer_id, render_mode)

func _build_structure_mesh(structure: Dictionary, layer_altitude: float, layer_id := "", render_mode: String = "INTERIOR") -> void:
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
			structure_builder._add_sunshade_structure(root, structure, width, depth, height, mat_data, render_mode)
		"flooropening":
			pass # structure_builder._add_floor_opening_frame(root, structure, width, depth, mat_data)
		_:
			structure_builder._add_box_structure(root, structure_type, width, depth, height, mat_data)

# ==============================================================================
# WHY IT EXISTS: To read the items array from the JSON layout, dynamically 
# download the 3D GLB models for furniture, appliances, and decorations, and 
# place them at exact coordinates inside the 3D rooms.
# ==============================================================================
func load_assets(data):
	if data.has("layers"):
		var layers_dict = data["layers"]
		var show_all_floors = data.get("showAllFloors", true)
		var selected_layer = data.get("selectedLayer", "")

		if show_all_floors:
			print("load_assets: showAllFloors is true â€” loading assets for ALL layers.")
		else:
			print("load_assets: showAllFloors is false â€” loading assets only for layer: ", selected_layer)

		for layer_id in layers_dict:
			if not show_all_floors and selected_layer != "" and str(layer_id) != str(selected_layer):
				print("load_assets: Skipping layer: ", layer_id, " (not selected)")
				continue

			var layer = layers_dict[layer_id]
			var layer_alt = 0.0

			if show_all_floors:
				if layer.has("altitude"):
					var alt_val = layer["altitude"]
					if typeof(alt_val) == TYPE_DICTIONARY and alt_val.has("length"):
						layer_alt = float(alt_val["length"]) * _scene_unit_scale
					else:
						layer_alt = float(alt_val) * _scene_unit_scale
			else:
				print("load_assets: Single-layer mode â€” placing assets at ground level")

			var layer_render_mode = str(layer.get("render_mode", data.get("render_mode", "INTERIOR"))).to_upper()
			if layer.has("items"):
				_load_layer_items(layer["items"], layer_alt, str(layer_id), layer_render_mode)
			if layer.has("assets"):
				_load_layer_items(layer["assets"], layer_alt, str(layer_id), layer_render_mode)
	if data.has("assets"):
		_load_layer_items(data["assets"], 0.0, "root", str(data.get("render_mode", "INTERIOR")).to_upper())
	if data.has("items"):
		_load_layer_items(data["items"], 0.0, "root", str(data.get("render_mode", "INTERIOR")).to_upper())

func _resolve_local_model_path(path: String) -> String:
	if path == "" or path == "null" or path == "None":
		return ""

	var normalized = str(path).replace("\\", "/")
	if FileAccess.file_exists(normalized):
		return normalized
	if FileAccess.file_exists("res://" + normalized):
		return "res://" + normalized
	if FileAccess.file_exists("./" + normalized):
		return "./" + normalized

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
						da.list_dir_end()
						return dir + "/" + entry
			entry = da.get_next()
		da.list_dir_end()

	return ""

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
		# Crucial: mark as authored so render.gd doesn't overwrite its color with the global fill tint
		light.set_meta("authored_custom_light", true)
		
		# ── Color: prefer colorTemp (Kelvin) when present, else use hex color ──
		var color_temp_k = light_data.get("colorTemp", 0)
		var base_color: Color
		if float(color_temp_k) > 0.0:
			base_color = _kelvin_to_rgb(float(color_temp_k))
		else:
			var color_hex = light_data.get("color", "#ffffff")
			base_color = Color(color_hex)
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
		
		# Custom light shadow: respects the castShadow flag from the JSON.
		# This is the ONLY non-directional shadow source allowed in day renders.
		if bool(light_data.get("castShadow", false)):
			_configure_soft_interior_shadow(light)
		else:
			light.shadow_enabled = false
		
		var px = float(light_data.get("x", 0.0))
		var pz = float(light_data.get("y", 0.0))
		var altitude = float(light_data.get("altitude", 0.0)) * _scene_unit_scale
		var world_pos = _plan_point_3d(px, pz, altitude)
		light.position = world_pos
		
		if ltype == "spot":
			var rot_y = float(light_data.get("rotationY", 0.0))
			var tilt = float(light_data.get("tiltAngle", 0.0))
			# Ensure rotations work as expected
			light.rotation.y = rot_y
			light.rotation.x = - deg_to_rad(tilt) if tilt != 0.0 else -PI / 2

		# ── IES Photometric Profile ────────────────────────────────────────────
		# Only OmniLight3D and SpotLight3D support IES profiles (guide §"Which lights
		# support it"). IES only visibly affects path-tracing (env.pathtracing_enabled);
		# the rasterizer silently falls back to isotropic emission — no crash.
		var photometric_type = str(light_data.get("photometricType", "")).to_lower()
		if photometric_type == "ies":
			var ies_profile_id = str(light_data.get("iesProfileId", "")).strip_edges()
			if ies_profile_id != "":
				var ies_path = _resolve_ies_filepath(ies_profile_id)
				if ies_path != "":
					light.ies_mode = Light3D.IES_MODE_EXTERNAL
					light.ies_filepath = ies_path
					# ies_strength multiplies the profile's own candela data.
					# Use intensityMultiplier so per-fixture dimming applies on top.
					light.ies_strength = clamp(energy_mult, 0.01, 1000000.0)

					# ── IES energy override ──────────────────────────────────────────
					# In the RTX path tracer, light_energy acts as a physical watt
					# multiplier on top of the IES candela-normalised lobe.  The
					# standard base_e (5–20) tuned for the rasterizer is far too low
					# here because the IES normalisation scales the raw candela peak
					# (e.g. 262 637 cd) by 4π/177.83 ≈ 0.0707 — the resulting per-watt
					# value is physically large, so a small energy multiplier makes the
					# light appear extremely dim in PT.  Multiply by a physical factor
					# (300 × base_e) to produce a clearly visible beam.  Tune
					# ies_strength for relative per-profile brightness afterwards.
					var ies_energy = energy_mult * _lighting_illumination_scale * 0.2
					light.light_energy = ies_energy

					# IES controls the actual beam shape — the spot cone must be wide
					# enough (≥ the IES half-angle) that the lobe isn't clipped.  Set
					# it to 90° (hemisphere) so the profile alone determines shaping.
					# Extend range to 25 m so the beam reaches far walls/floor.
					if light is SpotLight3D:
						(light as SpotLight3D).spot_angle = 90.0
						(light as SpotLight3D).spot_range = 15.0

					print("[IES] Profile '", ies_profile_id, "' assigned to '", light.name,
						"' | energy=", snappedf(ies_energy, 0.1), " ies_strength=", light.ies_strength,
						" | path: ", ies_path)
				else:
					print("[IES] WARNING: .ies file not found for iesProfileId '", ies_profile_id, "' — '", light.name, "' uses isotropic fallback.")
			else:
				print("[IES] WARNING: photometricType is 'ies' but iesProfileId is empty for '", light.name, "' — isotropic fallback.")

		add_child(light)

# Returns the absolute filesystem path to a local .ies file matching the given
# iesProfileId (e.g. "ies_cob_spotlight" → ".../IES_Lights/ies_cob_spotlight.ies").
#
# Lookup order (first existing path wins):
#   1. <project_parent>/IES_Lights/<id>.ies   — standard layout (IES_Lights next to godot_project/)
#   2. <project_root>/IES_Lights/<id>.ies      — IES_Lights inside the Godot project folder
#   3. <project_root>/<id>.ies                 — file placed directly at project root
#
# Returns "" when no candidate file is found so the caller can log a clear warning.
func _resolve_ies_filepath(ies_profile_id: String) -> String:
	# globalize_path("res://") includes a trailing slash on Windows
	# (e.g. "C:/…/godot_project/"). get_base_dir() treats a trailing slash as
	# an empty final component and returns the same directory instead of its
	# parent. Stripping the slash first makes it climb one level correctly.
	var project_root: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var parent_dir: String = project_root.get_base_dir()

	var candidates: PackedStringArray = [
		parent_dir.path_join("IES_Lights").path_join(ies_profile_id + ".ies"),
		project_root.path_join("IES_Lights").path_join(ies_profile_id + ".ies"),
		project_root.path_join(ies_profile_id + ".ies"),
	]

	print("[IES] Resolving '", ies_profile_id, "' — searching: ", candidates[0])
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate

	return ""

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

func _count_fixture_lights(geom_data: Dictionary) -> int:
	var count := 0
	if geom_data.has("items"):
		var items = geom_data["items"]
		if typeof(items) == TYPE_ARRAY:
			for item in items:
				if typeof(item) == TYPE_DICTIONARY and _is_light_fixture_item(item):
					count += 1
		elif typeof(items) == TYPE_DICTIONARY:
			for id in items:
				if typeof(items[id]) == TYPE_DICTIONARY and _is_light_fixture_item(items[id]):
					count += 1
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		for layer_id in geom_data["layers"]:
			var layer = geom_data["layers"][layer_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("items"):
				var items = layer["items"]
				if typeof(items) == TYPE_ARRAY:
					for item in items:
						if typeof(item) == TYPE_DICTIONARY and _is_light_fixture_item(item):
							count += 1
				elif typeof(items) == TYPE_DICTIONARY:
					for id in items:
						if typeof(items[id]) == TYPE_DICTIONARY and _is_light_fixture_item(items[id]):
							count += 1
	return count

# Like _count_fixture_lights but only counts ceiling_mount fixtures — the ones
# that additively stack most severely due to their omnidirectional range.
func _count_ceiling_fixture_lights(geom_data: Dictionary) -> int:
	var count := 0
	var _scan_items := func(items) -> void:
		if typeof(items) == TYPE_ARRAY:
			for item in items:
				if typeof(item) == TYPE_DICTIONARY:
					if str(item.get("mounting_type", "")).to_lower() == "ceiling_mount" \
					and _is_light_fixture_item(item):
						count += 1
		elif typeof(items) == TYPE_DICTIONARY:
			for id in items:
				var item = items[id]
				if typeof(item) == TYPE_DICTIONARY:
					if str(item.get("mounting_type", "")).to_lower() == "ceiling_mount" \
					and _is_light_fixture_item(item):
						count += 1
	if geom_data.has("items"):
		_scan_items.call(geom_data["items"])
	if geom_data.has("layers") and typeof(geom_data["layers"]) == TYPE_DICTIONARY:
		for layer_id in geom_data["layers"]:
			var layer = geom_data["layers"][layer_id]
			if typeof(layer) == TYPE_DICTIONARY and layer.has("items"):
				_scan_items.call(layer["items"])
	return count

func _get_item_model_hint(item: Dictionary) -> String:
	var model_hint := ""
	if item.has("asset_urls") and typeof(item["asset_urls"]) == TYPE_DICTIONARY:
		var urls = item["asset_urls"]
		if urls.has("GLB_File_URL") and urls["GLB_File_URL"] != null:
			model_hint = str(urls["GLB_File_URL"]).to_lower()
		elif urls.has("glb_Url") and urls["glb_Url"] != null:
			model_hint = str(urls["glb_Url"]).to_lower()
	return model_hint


func _is_light_fixture_item(item: Dictionary) -> bool:
	var item_type = str(item.get("type", "")).to_lower()
	var item_name = str(item.get("name", "")).to_lower()
	var mounting_type = str(item.get("mounting_type", "")).to_lower()
	var model_hint = _get_item_model_hint(item)
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

func _apply_light_fixture_emission(node: Node3D, light_color: Color, emission_energy: float, mood_color: Color) -> bool:
	var meshes = _get_all_meshes(node)
	var applied = false
	
	# Adjust emission energy multiplier based on mood type and passed dynamic emission_energy
	var mood_emission_scale = 1.0 # Default
	var mood_key = _lighting_color_mood.to_lower()
	match mood_key:
		"warm":
			mood_emission_scale = 1.10 # Warmer, more prominent glow
		"soft":
			mood_emission_scale = 0.95 # Softer, gentler glow
		"cool":
			mood_emission_scale = 0.90 # Cool, less saturated glow
		"neutral":
			mood_emission_scale = 1.00 # Balanced glow
		"day":
			mood_emission_scale = 0.85 # Subtle glow
		_:
			mood_emission_scale = 1.00 # Default fallback
			
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
					# Day render: disable emissive materials
					new_mat.emission_enabled = false
					new_mat.emission_energy_multiplier = 0.0
				else:
					# Night render: apply hardcoded mood-based emissive color with mood-specific energy
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
							hardcoded_mood_color = Color(0.95, 0.98, 1.0) # Bright daylight white (6500K)
						_:
							hardcoded_mood_color = mood_color # Fallback to passed mood color
					
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
	# should get an OmniLight3D.  The previous _node_has_emissive_material()
	# fallback was adding OmniLights to beds, sofas, and other furniture
	# whose GLBs happened to have emissive materials — causing a warm center
	# blob in every room.
	if _is_light_fixture_item(item):
		print("[LightFixture] ACCEPTED: ", item.get("name", "?"), " type=", item.get("type", "?"), " mount=", item.get("mounting_type", "?"))
		return true
	return false

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
	# This avoids one pantry-shelf texture update bleeding into every similarly
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
	# DAY RENDERS: Skip ALL fixture light spawning.
	# Design rule: Day = Sun + Sky Ambient + Portal Lights only.
	# Fixture lights (ceiling/floor lamp/wall sconce) are NIGHT-ONLY.
	# Even energy=0.0 fixtures were still spawning shadow_companion SpotLights
	# which caused circular unwanted shadows in day renders.
	if day_render:
		return

	if item.get("is_exterior_black", false):
		return
	if not _should_add_light_fixture_effect(node, item):
		return

	var item_type = str(item.get("type", "")).to_lower()
	var item_name = str(item.get("name", "")).to_lower()
	var mounting_type = str(item.get("mounting_type", "")).to_lower()
	var model_hint = _get_item_model_hint(item)
	var full_desc = item_type + " " + item_name + " " + mounting_type + " " + model_hint

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

	var kelvin = 3000.0 # Default warm-white
	if item.has("properties") and typeof(item["properties"]) == TYPE_DICTIONARY:
		var props = item["properties"]
		if props.has("colorTemperature"):
			kelvin = float(props["colorTemperature"])
		elif props.has("kelvin"):
			kelvin = float(props["kelvin"])

	var is_street_light = "street" in full_desc or "exterior" in full_desc
	var is_night = lighting_profile == "night"
	var is_sunset = lighting_profile == "sunset"
	
	if is_street_light:
		kelvin = 2200.0 # Sodium vapor look
	elif is_sunset:
		kelvin = 2500.0 # Golden hour interior
	elif is_night:
		kelvin = 2700.0 # Warm incandescent
	else:
		kelvin = 3200.0 # Halogen/Soft-white
	
	var light_color = _kelvin_to_rgb(kelvin)
	var mood_fixture_color = _get_color_mood_light_color("fixture")
	
	# Blend Kelvin with Mood color for artistic control
	light_color = Color(
		light_color.r * mood_fixture_color.r,
		light_color.g * mood_fixture_color.g,
		light_color.b * mood_fixture_color.b,
		1.0
	)
	light_color.r = clamp(light_color.r, 0.0, 1.0)
	light_color.g = clamp(light_color.g, 0.0, 1.0)
	light_color.b = clamp(light_color.b, 0.0, 1.0)

	var light_energy = 1.45 # increased from 1.15
	var light_range = max(max(scaled_size.x, scaled_size.z) * 6.5, 6.5) # increased from 5.5/3.6
	var emission_energy = 5.5
	if is_sunset:
		light_energy = 3.2
		emission_energy = 8.5
	elif is_night:
		light_energy = 5.2
		emission_energy = 11.0

	if mounting_type == "ceiling_mount":
		# Values doubled from the over-dimmed era — emissive-furniture OmniLights
		# Values raised 2× — room was still dim after previous doubling.
		# At level 5 (scale=0.50) with 21 fixtures (sqrt cap=4.0):
		#   day final/fixture: 2.0 × 0.5 / 4.0 = 0.25  → 21 fixtures = 5.25 total
		#   night final/fixture: 3.5 × 0.5 / 4.0 = 0.44 → 21 fixtures = 9.2 total
		light_energy = 2.0 # day  (was 1.0)
		light_range = max(light_range, 7.0)
		emission_energy = 10.0 # day emission (was 7.0)
		if is_sunset:
			light_energy = 4.2 # was 2.8
			emission_energy = 14.0 # was 10.0
		elif is_night:
			light_energy = 5.5 # was 3.5
			emission_energy = 18.0 # was 13.0
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
		
		emission_energy *= _lighting_illumination_scale * (illuminationLevel / 6.0) * 2.2
	else:
		light_energy = 0.0
		emission_energy = 0.0

	# ── Ceiling fixture sqrt normalization ────────────────────────────────────
	# Problem: N ceiling OmniLights add energy linearly → 21 fixtures = 21× one light.
	# Fix: divide per-fixture energy by sqrt(N) so total luminance ≈ sqrt(N) × base.
	#   N=1  → factor=1.00 (no change)
	#   N=4  → factor=0.50  |  N=9 → factor=0.33  |  N=21 → factor=0.22
	# Cap the divisor at sqrt(16)=4.0 to avoid over-dimming in very large plans.
	if mounting_type == "ceiling_mount":
		var sqrt_n := sqrt(float(clamp(_ceiling_fixture_count, 1, 16)))
		light_energy /= sqrt_n
		emission_energy /= sqrt_n

	# Pass mood_fixture_color (ONLY mood, no Kelvin) for emissive materials
	# OmniLight3D gets blended light_color (Kelvin + mood), but emission gets pure mood
	var emissive_surface_found = _apply_light_fixture_emission(node, light_color, emission_energy, mood_fixture_color)

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
		omni.light_specular = 0.0
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
		spot_ceil.light_energy = light_energy * 0.7 # Halved: shadow companion adds 0.5x so total stays balanced
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

		# Companion shadow-caster: SpotLight3D placed 0.5 m below the ceiling fixture.
		# Shadow is disabled for DAY renders — the DirectionalLight (Sun) already
		# handles all shadow casting. Only the Sun + custom JSON castShadow lights
		# should cast shadows in day mode.
		# Shadow stays ON for night renders where ceiling fixtures are primary lights.
		var shadow_companion = SpotLight3D.new()
		shadow_companion.name = "FixtureLight_Shadow_" + str(item.get("id", item.get("name", "Light")))
		var companion_y = max(world_pos.y - 0.5, _room_center.y + 0.2)
		shadow_companion.global_position = Vector3(world_pos.x, companion_y, world_pos.z)
		shadow_companion.rotation_degrees = Vector3(-90, 0, 0)
		shadow_companion.light_color = light_color
		shadow_companion.light_energy = light_energy * 0.5
		shadow_companion.light_specular = 0.0
		shadow_companion.spot_range = max(light_range, 15.0)
		shadow_companion.spot_angle = 90.0
		shadow_companion.spot_angle_attenuation = 1.5
		shadow_companion.spot_attenuation = 0.35
		# Day: shadow OFF — Sun handles all shadows
		# Night: shadow ON — fixtures are primary light so they need to cast shadows
		shadow_companion.shadow_enabled = not day_render
		if not day_render:
			shadow_companion.shadow_bias = 0.05
			shadow_companion.shadow_normal_bias = 1.0
			shadow_companion.shadow_blur = 1.5
		shadow_companion.add_to_group("fixture_lights")
		add_child(shadow_companion)
		print("[ImageGLB] Shadow companion at y=", companion_y, " shadow=", not day_render)

	elif "wall" in full_desc or is_street_light:
		# Wall sconces and street lights — SpotLight3D aimed downward/outward
		var spot = SpotLight3D.new()
		spot.name = "FixtureLight_" + str(item.get("id", item.get("name", "Light")))
		spot.global_position = world_pos
		spot.light_color = light_color
		spot.light_energy = light_energy
		spot.light_specular = 0.0
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
		omni.light_specular = 0.0 # Set to 0.0 to prevent floating dot reflections
		omni.shadow_enabled = false # match video
		omni.omni_range = max(light_range, 10.0)
		omni.omni_attenuation = 0.5 # Midrange falloff
		omni.add_to_group("fixture_lights")
		add_child(omni)

	if not emissive_surface_found:
		print("[ImageGLB] Light fixture added without material override for asset: ", item.get("name", "Light"))

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


func _load_layer_items(items, layer_altitude, layer_id := "", render_mode: String = "INTERIOR"):
	for item_id in items:
		var item
		if typeof(items) == TYPE_DICTIONARY:
			item = items[item_id]
		else:
			item = item_id
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var model_path = ""

		if item.has("local_glb_path"):
			model_path = item["local_glb_path"]
		elif item.has("local_path"):
			model_path = item["local_path"]
		elif item.has("asset_urls"):
			var urls = item["asset_urls"]
			if urls.has("GLB_File_URL") and urls["GLB_File_URL"] != null and str(urls["GLB_File_URL"]) != "":
				model_path = str(urls["GLB_File_URL"])
			elif urls.has("glb_Url") and urls["glb_Url"] != null and str(urls["glb_Url"]) != "":
				model_path = str(urls["glb_Url"])

		var resolved_model_path = _resolve_local_model_path(model_path)
		var load_status = "failed"
		var load_reason = ""
		var used_path = resolved_model_path

		if model_path == "":
			load_reason = "missing_model_path"
			_tracked_assets.append({
				"type": "item_asset", "id": item.get("id", "unknown"),
				"name": item.get("name", "unknown"), "layer_id": layer_id,
				"requested_path": model_path, "path": "",
				"status": load_status, "reason": load_reason,
				"position": item.get("x", 0),
			})
			continue

		if resolved_model_path == "":
			load_reason = "file_not_found"
			_tracked_assets.append({
				"type": "item_asset", "id": item.get("id", "unknown"),
				"name": item.get("name", "unknown"), "layer_id": layer_id,
				"requested_path": model_path, "path": model_path,
				"status": load_status, "reason": load_reason,
				"position": item.get("x", 0),
			})
			continue

		if resolved_model_path != "":
			var node = null
			var is_instance = false
			if ENABLE_DUPLICATION and _glb_cache.has(resolved_model_path):
				# Re-use cached GLB: duplicate the stored prototype
				var cached = _glb_cache[resolved_model_path]
				if cached != null and is_instance_valid(cached):
					node = cached.duplicate()
					is_instance = true
				else:
					_glb_cache.erase(resolved_model_path)
			if node == null and not is_instance:
				var glTF = GLTFDocument.new()
				var glTFState = GLTFState.new()
				var error = glTF.append_from_file(resolved_model_path, glTFState)
				if error == OK:
					var generated = glTF.generate_scene(glTFState)
					if generated:
						if LOW_TEXTURE_QUALITY:
							_compress_glb_node_textures(generated, 2048)
						# Use this node directly; store a separate copy for future duplicates
						node = generated
						if ENABLE_DUPLICATION:
							var cache_copy = generated.duplicate()
							_glb_cache[resolved_model_path] = cache_copy

			# ── node is now set (cache duplicate or fresh generate_scene) ──
			if node:
				add_child(node)
				_sanitize_glb_lights(node)

				var item_xy = _plan_point_2d(float(item.get("x", 0)), float(item.get("y", 0)))
				var px = item_xy.x * _scene_unit_scale
				var py = item_xy.y * _scene_unit_scale
				var pz = _resolve_item_altitude_value(item) * _scene_unit_scale

				pz += layer_altitude
				node.position = Vector3(px, pz, py)

				var rot = 0.0
				if item.has("rotation"):
					rot = float(item["rotation"])
				elif item.has("properties") and item["properties"].has("rotation"):
					rot = float(item["properties"]["rotation"])

				node.rotation.y = _world_yaw_from_source_rotation(rot) + _item_front_axis_correction()

				var props = {}
				if item.has("properties") and typeof(item["properties"]) == TYPE_DICTIONARY:
					props = item["properties"]

				var raw_width = props.get("width", 100)
				var raw_depth = props.get("depth", 100)
				var raw_height = props.get("height", 100)

				var target_w = get_dimension_value(raw_width) * _scene_unit_scale
				var target_d = get_dimension_value(raw_depth) * _scene_unit_scale
				var target_h = get_dimension_value(raw_height) * _scene_unit_scale

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
				if _image_render_only:
					var flip_x = bool(item.get("flipX", false))
					var flip_y = bool(item.get("flipY", item.get("fipy", false)))
					var flip_z = bool(item.get("flipZ", false))
					var applied_flips: Array[String] = []
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
						print("[ImageGLB] Applied image-only flip(s) on axis/axes ", applied_flips, " for asset: ", item.get("name", "Unknown"))
				var bounds_y_min = aabb.position.y * final_scale.y
				node.position.y = pz - bounds_y_min

				var local_center = Vector3(aabb.position.x + aabb.size.x / 2.0, 0.0, aabb.position.z + aabb.size.z / 2.0)
				var world_offset = node.transform.basis * local_center
				node.position.x = px - world_offset.x
				node.position.z = py - world_offset.z

				var item_name_track = str(item.get("name", "")).to_lower()
				var item_type_track = str(item.get("type", "")).to_lower()
				var ext_keywords = ["tree", "plant", "garden", "outdoor", "landscape", "bush", "shrub", "vegetat", "flower"]
				var is_ext = false
				for kw in ext_keywords:
					if kw in item_type_track or kw in item_name_track:
						is_ext = true
						break
				if is_ext:
					_exterior_assets.append({
						"node": node,
						"position": node.global_position,
						"name": item.get("name", "unknown")
					})

				if item.get("is_exterior_black", false):
					var meshes = _get_all_meshes(node)
					var black_mat = StandardMaterial3D.new()
					black_mat.albedo_color = Color.BLACK
					black_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					for m in meshes:
						if not m.mesh: continue
						for i in range(m.mesh.get_surface_count()):
							m.set_surface_override_material(i, black_mat)
					print("Force-overrode all materials to BLACK for exterior item: ", item_id)

				_apply_item_materials(node, item)
				_add_light_fixture_effect(node, item, aabb, final_scale)
				print("Loaded asset: ", resolved_model_path, " final scale: ", final_scale)
				load_status = "loaded"
				load_reason = ""
		_tracked_assets.append({
			"type": "item_asset", "id": item.get("id", "unknown"),
			"name": item.get("name", "unknown"), "layer_id": layer_id,
			"requested_path": model_path,
			"path": used_path if used_path != "" else model_path,
			"status": load_status, "reason": load_reason,
			"position": item.get("x", 0),
		})

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

	# repeatX/repeatY are stored as physical tile sizes in source units.
	# Convert them to UV repeats using the actual surface size.
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
		# Apply density boost â€” multiplying UV scale makes tiles appear smaller.
		mat.uv1_scale = Vector3(scale_u * FLOOR_CEIL_TEXTURE_DENSITY_BOOST,
								scale_v * FLOOR_CEIL_TEXTURE_DENSITY_BOOST, 1.0)
		return mat

	# Legacy repeat arrays keep the existing 2.4 m density rule.
	if mat_data.has("repeat"):
		var r = mat_data["repeat"]
		if typeof(r) == TYPE_ARRAY and r.size() >= 2:
			var repeat_u = float(r[0])
			var repeat_v = float(r[1])
			if repeat_u > 0.0:
				scale_u = repeat_u * width / 2.0
			if repeat_v > 0.0:
				scale_v = repeat_v * height / 2.0
			if repeat_u > 0.0 or repeat_v > 0.0:
				# Apply density boost to legacy repeat path too.
				mat.uv1_scale = Vector3(scale_u * FLOOR_CEIL_TEXTURE_DENSITY_BOOST,
									scale_v * FLOOR_CEIL_TEXTURE_DENSITY_BOOST, 1.0)
				return mat

	return mat

# ── _apply_custom_shape_texture_scale ────────────────────────────────────────
# Identical to _apply_architecture_texture_scale but OMITS the
# FLOOR_CEIL_TEXTURE_DENSITY_BOOST multiplier.
# Use this for all custom shapes (floor, ceiling, wall) because they are
# already tile-sized — applying the 2x boost would shrink the texture by half.
func _apply_custom_shape_texture_scale(mat: StandardMaterial3D, mat_data: Dictionary, surface_size: Vector2) -> StandardMaterial3D:
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

	if tile_u > 0.0 and tile_v > 0.0:
		# Custom shapes also use world-coordinate UVs.
		scale_u = 1.0 / max(tile_u * _scene_unit_scale, 0.000001)
		scale_v = 1.0 / max(tile_v * _scene_unit_scale, 0.000001)
		# No density boost here — custom shapes are already at tile-level scale.
		mat.uv1_scale = Vector3(scale_u, scale_v, 1.0)
	else:
		# Default fallback scale if no repeat is specified
		mat.uv1_scale = Vector3(1.0, 1.0, 1.0)
		return mat

	if mat_data.has("repeat"):
		var r = mat_data["repeat"]
		if typeof(r) == TYPE_ARRAY and r.size() >= 2:
			var repeat_u = float(r[0])
			var repeat_v = float(r[1])
			if repeat_u > 0.0:
				scale_u = repeat_u * width / 2.0
			if repeat_v > 0.0:
				scale_v = repeat_v * height / 2.0
			if repeat_u > 0.0 or repeat_v > 0.0:
				mat.uv1_scale = Vector3(scale_u, scale_v, 1.0)
				return mat

	return mat

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

func _get_hierarchy_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first = true
	var meshes = _get_all_meshes(node)
	if meshes.size() == 0:
		return AABB(Vector3.ZERO, Vector3.ONE)

	for mesh_inst in meshes:
		var transform = node.global_transform.affine_inverse() * mesh_inst.global_transform
		var mesh_aabb = transform * mesh_inst.get_aabb()
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

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# _disable_shadow_casting_recursive
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Smart shadow control for window/door GLB assets:
#   - FRAME / MULLION meshes  â†’ shadows ON  (cast grid pattern on floor)
#   - GLASS / transparent     â†’ shadows OFF (light passes through glass)
#
# Detection heuristic:
#   A mesh is treated as "glass" if its name contains glass/glaz/pane/transp
#   OR its material is transparent/has low alpha.
#   Everything else (frame, sill, mullion, bar) keeps shadow casting ON.
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
						new_mat.albedo_color.a = 0.35 # 0.05
					new_mat.roughness = min(new_mat.roughness, 0.05)
# The asset still receives diffuse and specular light normally.
# Called ONLY in day_render mode for ceiling_mount items.
func _disable_ceiling_asset_sun_shadow(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_ceiling_asset_sun_shadow(child)

func _disable_shadow_casting_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var is_glass := _is_glass_mesh(mesh_inst)
		if is_glass:
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			# Frame / mullion / bar â€” keep shadows ON for grid pattern
			mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_disable_shadow_casting_recursive(child)

# Recursively checks if any MeshInstance3D in a subtree looks like glass.
# Used at hole-collection time to decide if a door fill SpotLight should
# cast shadows (glass sliding door = yes) or not (solid door = no).
func _node_has_any_glass(node: Node) -> bool:
	if node is MeshInstance3D and _is_glass_mesh(node as MeshInstance3D):
		return true
	for child in node.get_children():
		if _node_has_any_glass(child):
			return true
	return false

# Returns true if a MeshInstance3D looks like a glass/transparent pane.
func _is_glass_mesh(mesh_inst: MeshInstance3D) -> bool:
	# 1. Name-based check (covers most GLB exports)
	var lower_name := mesh_inst.name.to_lower()
	for keyword in ["glass", "glaz", "pane", "transp", "window_fill", "glazing"]:
		if keyword in lower_name:
			return true

	# 2. Material-based check â€” transparent or near-zero alpha
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
			# Transparent blend mode or very low albedo alpha â†’ glass
			if std_mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				return true
			if std_mat.albedo_color.a < 0.5:
				return true

	return false

# Counts how many MeshInstance3D nodes in a subtree have shadow casting ON.
func _count_shadow_casters(node: Node) -> int:
	var count := 0
	if node is MeshInstance3D:
		if (node as MeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			count += 1
	for child in node.get_children():
		count += _count_shadow_casters(child)
	return count

# ──────────────────────────────────────────────────────────────────────────────────────────────────
# _add_window_grid_shadow_caster
# ──────────────────────────────────────────────────────────────────────────────────────────────────
# Adds a thin MeshInstance3D grid (mullion cross pattern) just outside a window
# opening so it casts a realistic grid shadow pattern on the interior floor and
# walls.  Called ONLY when the GLB asset has no detectable frame mesh (i.e. the
# entire asset was glass-only and we got no shadow casters from the GLB).
#
# Grid layout: mirrors a typical 6-pane window —
#   1 vertical centre mullion + 1 horizontal mid-rail — 6 cells
func _add_window_grid_shadow_caster(win_center: Vector3, win_width: float,
		win_height: float, wall_angle: float, outer_dir: Vector3,
		layer_altitude: float) -> void:
	var bar_t := 0.04 # bar thickness (metres) — ~4 cm gives crisp shadow edge
	var bar_d := 0.06 # bar depth into wall opening
	# Place grid just outside the wall on the exterior side so the SpotLight
	# shines through the bars and casts shadows inward.
	var grid_pos := win_center + outer_dir * 0.06

	var grid_root := Node3D.new()
	grid_root.name = "WindowGridShadowCaster"
	grid_root.position = grid_pos
	grid_root.rotation.y = wall_angle
	add_child(grid_root)

	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.15, 0.10, 0.08) # dark wood/metal
	frame_mat.roughness = 0.6
	frame_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# ── Outer border frame ─────────────────────────────────────────────────────────────────────────
	var border_meshes := [
		# top rail
		Vector3(0.0, win_height * 0.5 - bar_t * 0.5, 0.0),
		Vector3(win_width, bar_t, bar_d),
		# bottom rail
		Vector3(0.0, -win_height * 0.5 + bar_t * 0.5, 0.0),
		Vector3(win_width, bar_t, bar_d),
		# left stile
		Vector3(-win_width * 0.5 + bar_t * 0.5, 0.0, 0.0),
		Vector3(bar_t, win_height, bar_d),
		# right stile
		Vector3(win_width * 0.5 - bar_t * 0.5, 0.0, 0.0),
		Vector3(bar_t, win_height, bar_d),
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

	# ── Inner mullions: 1 vertical + 1 horizontal ─────────────────────────────────────────────────
	# Vertical centre mullion
	var vm := BoxMesh.new()
	vm.size = Vector3(bar_t, win_height - bar_t * 2.0, bar_d)
	var vmi := MeshInstance3D.new()
	vmi.mesh = vm
	vmi.position = Vector3(0.0, 0.0, 0.0)
	vmi.set_surface_override_material(0, frame_mat)
	vmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	grid_root.add_child(vmi)

	# Horizontal mid-rail
	var hm := BoxMesh.new()
	hm.size = Vector3(win_width - bar_t * 2.0, bar_t, bar_d)
	var hmi := MeshInstance3D.new()
	hmi.mesh = hm
	hmi.position = Vector3(0.0, 0.0, 0.0)
	hmi.set_surface_override_material(0, frame_mat)
	hmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	grid_root.add_child(hmi)

	print("  Added procedural window grid shadow caster at ", grid_pos)

# ==============================================================================
# PBR MATERIAL CREATION
# ==============================================================================
# WHY IT EXISTS: To build physically based rendering (PBR) materials for surfaces. 
# It takes basic colors or downloaded textures (diffuse, normal, roughness) and 
# applies them to Godot materials so floors and walls look realistic and react 
# correctly to light.
# ==============================================================================
func create_material(mat_data, surface_type: String = "item"):
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
			print("  Warning: Invalid color string: ", c_str)

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
			var repeat_u = float(r[0])
			var repeat_v = float(r[1])
			if repeat_u > 0.0:
				scale_u = repeat_u
			if repeat_v > 0.0:
				scale_v = repeat_v
	
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
	
	if mat_data.get("is_structure", false) or surface_type == "structure":
		mat.uv1_triplanar = true

	# Reflection assist is separate from the main optimizer:
	# it only boosts the surfaces that should visibly pick up the probe.
	mat = _apply_reflection_response_assist(mat, mat_data, surface_type)

	# Apply late-stage material optimization only when enabled.
	if USE_MATERIAL_OPTIMIZER:
		mat = MOImage.optimize_material(mat, mat_data, surface_type)

	return mat


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
			print("Texture not found (skipped): ", norm_path)
			
	if tex:
		print("[ORIGINAL] Texture: ", norm_path)
		if ENABLE_DUPLICATION:
			_texture_cache[norm_path] = tex

		
	return tex

func load_image_texture(path):
	var img = Image.load_from_file(path)
	if img == null or img.is_empty():
		# Fallback: Read file bytes and detect format manually (e.g. wrong extension)
		var file = FileAccess.open(path, FileAccess.READ)
		if file:
			var bytes = file.get_buffer(file.get_length())
			file.close()
			if bytes.size() > 4:
				var new_img = Image.new()
				var err = OK
				# Check PNG magic bytes: \x89 P N G
				if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
					err = new_img.load_png_from_buffer(bytes)
				# Check JPEG magic bytes: \xFF \xD8
				elif bytes[0] == 0xFF and bytes[1] == 0xD8:
					err = new_img.load_jpg_from_buffer(bytes)
				# Check WebP magic bytes: RIFF .... WEBP
				elif bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 and bytes.size() > 12 and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
					err = new_img.load_webp_from_buffer(bytes)
				else:
					# Try them all sequentially as a last resort
					err = new_img.load_png_from_buffer(bytes)
					if err != OK:
						err = new_img.load_jpg_from_buffer(bytes)
					if err != OK:
						err = new_img.load_webp_from_buffer(bytes)
				
				if err == OK and not new_img.is_empty():
					img = new_img
					print("Successfully recovered image with manual format detection for: ", path)
				else:
					print("Failed manual image format detection recovery for: ", path, " error code: ", err)
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
				# Enforce 16x anisotropic filtering globally if the renderer allows it
				RenderingServer.material_set_param(mat.get_rid(), "texture_filter", BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC)
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
									var repeat_u = float(r[0])
									var repeat_v = float(r[1])
									if repeat_u > 0.0:
										scale_u = repeat_u
									if repeat_v > 0.0:
										scale_v = repeat_v
									changed_scale = true
						
							if mat_opt.has("repeatX"):
								scale_u = float(mat_opt["repeatX"]) if float(mat_opt["repeatX"]) > 0 else scale_u
								changed_scale = true
							if mat_opt.has("repeatY"):
								scale_v = float(mat_opt["repeatY"]) if float(mat_opt["repeatY"]) > 0 else scale_v
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
								# Apply Optimizer with context (item)
								if USE_MATERIAL_OPTIMIZER:
									new_mat = MOImage.optimize_material(new_mat, mat_opt, "item")
								m.set_surface_override_material(i, new_mat)
								applied_material_keys[matched_key_text] = true
								if limit_single_generic_key:
									break

			if limit_single_generic_key and applied_material_keys.size() > 0:
				break

# ==============================================================================
# PAVING PATTERN OVERLAY
# ==============================================================================
# GDScript port of frontend/src/core/paving/pavingPatterns.ts.
# Called from the floor-building section when floor_properties.paving is set.
#
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
		material_data: Dictionary,
		parent_node: Node3D = null,
		exclusion_polygons: Array = []
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
	#   false → fixed 3 mm visual seam (matches frontend stroke width ~= 1 px at 1 mm/px, enhanced for visibility)
	var shrink_m: float = 0.003
	if gap_real:
		shrink_m = clamp(gap_mm * _scene_unit_scale * 0.5, 0.0005, 0.05)

	# Grout / seam color
	# Priority 1: gapColor present in JSON → always use it (gapColorMode may be absent)
	# Priority 2: gapColorMode == 'custom' with gapColor
	# Priority 3: gapColorMode == 'material' → lighten the floor material colour
	# Priority 4: black default (if no color is specified)
	var grout_color: Color = Color(0.0, 0.0, 0.0) # default black grout
	var gap_color_mode = str(pav_cfg.get("gapColorMode", "none")).strip_edges().to_lower()
	var has_gap_color = pav_cfg.has("gapColor") and str(pav_cfg.get("gapColor", "")).strip_edges() != ""
	if has_gap_color:
		# gapColor set explicitly → use it directly (covers both custom and legacy JSON)
		var raw_color_str = str(pav_cfg["gapColor"]).strip_edges()
		if raw_color_str.is_valid_html_color():
			grout_color = Color(raw_color_str)
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
		tile_mat = create_material(material_data, "floor")
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
	var pav_root = CSGCombiner3D.new()
	pav_root.name = "PavingOverlay_" + area_id
	# Parent pav_root to floor_csg when provided so tiles live under the floor node.
	if parent_node != null:
		parent_node.add_child(pav_root)
	else:
		add_child(pav_root)

	var tile_y = layer_altitude + 0.002 # 2 mm above base floor slab
	var tile_depth = 0.02 # 20 mm ceramic / plank thickness for solid CSG intersection

	# ── Grout slab — bypassed since floor_poly now serves as the grout layer
	# (Prevents precision discards and Z-fighting issues)
	# var grout_slab = CSGPolygon3D.new()
	# grout_slab.name      = "PavGrout_" + area_id
	# grout_slab.polygon   = uv_polygon
	# grout_slab.mode      = CSGPolygon3D.MODE_DEPTH
	# grout_slab.depth     = tile_depth
	# grout_slab.rotation.x = PI / 2
	# grout_slab.position.y = tile_y - 0.001
	# grout_slab.material  = grout_mat
	# pav_root.add_child(grout_slab)

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

		# ── Subtract custom-shape exclusion polygons from each tile ──────
		# This carves holes in the paving grid so custom shapes placed on
		# top are fully visible without z-fighting or material overlap.
		if not exclusion_polygons.is_empty():
			var after_exclusion: Array = []
			for cp in clipped:
				var remaining: Array = [cp]
				for ex_poly in exclusion_polygons:
					var next_remaining: Array = []
					for rem_poly in remaining:
						var diff = Geometry2D.clip_polygons(rem_poly, ex_poly)
						for d in diff:
							if d.size() >= 3:
								next_remaining.append(d)
					remaining = next_remaining
				for r in remaining:
					after_exclusion.append(r)
			clipped = after_exclusion
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
