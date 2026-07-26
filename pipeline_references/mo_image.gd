class_name MOImage extends RefCounted

const USE_REFLECTION_PROBE_HOTSPOT_FIX = true

static func optimize_material(mat: StandardMaterial3D, mat_data: Dictionary, surface_type: String = "item") -> StandardMaterial3D:
	var path          = str(mat_data.get("mapUrl", "")).to_lower()
	var has_metalness = mat_data.has("metalnessUrl") and str(mat_data["metalnessUrl"]) != ""
	var has_normal    = mat_data.has("normalUrl") and str(mat_data["normalUrl"]) != ""
	var has_roughness = mat_data.has("roughnessUrl") and str(mat_data["roughnessUrl"]) != ""
	var has_any_map   = path != "" or has_normal or has_roughness or has_metalness
	var has_explicit_color = false
	if mat_data.has("color"):
		var c_str = str(mat_data["color"]).strip_edges()
		if c_str.length() >= 3 and not c_str.begins_with("#"):
			c_str = "#" + c_str
		has_explicit_color = c_str.is_valid_html_color()
	var is_color_only_wall = surface_type == "wall" and has_explicit_color and not has_any_map

	# --- BASE ARCHITECTURAL DEFAULTS BY SURFACE TYPE ---
	match surface_type:
		"ceiling":
			# Ceilings with roughness < 0.5 reflect SDFGI probes as grid dots. Make it highly rough.
			mat.metallic = 0.0
			mat.metallic_specular = 0.05
			mat.roughness = 0.95 # Highly rough to diffuse SDFGI/SSIL probe noise
			print("  [Optimizer] Ceiling context -> applying soft-diffuse properties.")
			return mat # Ceilings rarely need texture-based overriding for roughness

		"wall":
			mat.metallic = 0.0
			# Real matte paint has subtle Fresnel. Never disable specular mode.
			mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			mat.metallic_specular = 0.2 # Catches a tiny highlight at grazing angles
			mat.roughness = 0.85 # Matte paint texture
			print("  [Photorealism] Wall context -> high-roughness matte properties.")

		"floor":
			mat.metallic = 0.1 # Just a hint of metalness helps Godot's SSR
			mat.metallic_specular = 1.0
			mat.roughness = 0.15 # Refined for chandelier reflection
			mat.clearcoat_enabled = true
			mat.clearcoat = 1.0
			mat.clearcoat_roughness = 0.1

		_: # "item"
			mat.metallic = 0.0
			mat.metallic_specular = 0.5
			mat.roughness = 0.6

	if is_color_only_wall:
		# Keep colored walls visually neutral. Avoid later glossy overrides.
		mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX # Keep enabled for Fresnel
		mat.clearcoat_enabled = false
		mat.metallic = 0.0
		mat.metallic_specular = 0.1
		mat.roughness = 0.8
		print("  [Photorealism] Color-only wall detected -> using soft Fresnel matte.")
		return mat

	# --- SMART DETECTION OVERRIDES (Based on texture path keywords) ---
	if "marble" in path or "tile" in path or "granite" in path or "polished" in path or "porcelain" in path:
		# High-Gloss Interior Surfaces
		mat.roughness = 0.02
		mat.metallic_specular = 1.0
		mat.clearcoat_enabled = true
		mat.clearcoat = 1.0
		mat.clearcoat_roughness = 0.05
		print("  [Optimizer] Glossy Surface detected -> clearcoat enabled.")

	elif "wood" in path or "parquet" in path or "plank" in path or "floor" in path:
		# Realistic wood
		mat.roughness = 0.32
		mat.metallic_specular = 0.55
		# Boost wood floor reflections significantly for better probe interaction
		if surface_type == "floor": 
			mat.roughness = 0.08
			mat.clearcoat_enabled = true
			mat.clearcoat = 0.4
		print("  [Optimizer] Wood detected -> semi-gloss preset.")

	elif "fabric" in path or "rug" in path or "cloth" in path or "textile" in path or "upholster" in path:
		# Dead-flat Fabrics
		mat.roughness = 0.95
		mat.metallic_specular = 0.1
		mat.clearcoat_enabled = false
		# Add Sheen for "soft touch" fabric look
		mat.sheen_enabled = true
		mat.sheen = 0.5
		mat.sheen_tint = 0.2
		print("  [Photorealism] Fabric/Textile detected -> added sheen/soft-touch.")

	elif "mirror" in path:
		# Perfect Mirror
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.roughness = 0.0
		mat.metallic = 1.0
		mat.metallic_specular = 1.0
		mat.clearcoat_enabled = false
		print("  [Optimizer] Mirror detected -> enabling perfect reflection.")

	elif "glass" in path or "glaz" in path or "window" in path:
		# High-Gloss Glass
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.01
		mat.metallic_specular = 1.0
		if mat.albedo_color.a > 0.95: mat.albedo_color.a = 0.4
		print("  [Optimizer] Glass detected -> enabling alpha-transparency.")

	# --- NORMAL MAP OPTIMIZATION ---
	if mat.normal_enabled:
		mat.normal_scale = 0.35

	# --- REFLECTION PROBE HOTSPOT FIX ---
	# Ensure no material is 100% mirror. Godot's ReflectionProbe looks best with some roughness.
	if USE_REFLECTION_PROBE_HOTSPOT_FIX and not "mirror" in path:
		mat.roughness = clamp(mat.roughness, 0.1, 1.0)
		mat.metallic_specular = 0.5 # Cap specular to physical defaults

		if "wood" in path or surface_type == "floor":
			mat.metallic = 0.0
			mat.roughness = 0.25
			mat.metallic_specular = 0.2
			mat.clearcoat_enabled = false
			mat.clearcoat = 0.0
			mat.anisotropy_enabled = false
			
		if "marble" in path or "tile" in path:
			mat.roughness = 0.12 # Sharp but not "mirror"
			mat.clearcoat_enabled = true
			mat.clearcoat = 0.2

	return mat
