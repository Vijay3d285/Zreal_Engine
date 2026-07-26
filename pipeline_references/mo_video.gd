class_name MOVideo extends RefCounted

const USE_REFLECTION_PROBE_HOTSPOT_FIX = true

static func optimize_material(mat: StandardMaterial3D, map_url: String) -> StandardMaterial3D:
	var opt_path = map_url.to_lower().get_file()
	var is_mirror_mat = "mirror" in opt_path
	var is_glass_mat = not is_mirror_mat and ("glass" in opt_path or "window" in opt_path)
	var is_marble_mat = not is_glass_mat and not is_mirror_mat and (
		"marble" in opt_path or "stone" in opt_path or "polished" in opt_path or
		"granite" in opt_path or "travertine" in opt_path or "terrazzo" in opt_path
	)
	var is_tile_mat = not is_glass_mat and not is_mirror_mat and not is_marble_mat and (
		"tile" in opt_path or "ceramic" in opt_path or "porcelain" in opt_path
	)
	var is_wood_mat = not is_glass_mat and not is_mirror_mat and (
		"wood" in opt_path or "parquet" in opt_path or "plank" in opt_path or
		"oak" in opt_path or "walnut" in opt_path or "timber" in opt_path or "bamboo" in opt_path
	)

	if is_mirror_mat:
		mat.transparency       = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.roughness          = 0.0
		mat.metallic           = 1.0
		mat.metallic_specular  = 1.0
		mat.clearcoat_enabled  = false

	elif is_glass_mat:
		mat.transparency       = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness          = 0.01
		mat.metallic_specular  = 1.0
		if mat.albedo_color.a > 0.95:
			mat.albedo_color.a = 0.35

	elif is_marble_mat:
		# Sharp polished surface — must be low roughness for reflections to appear
		mat.roughness          = 0.10
		mat.metallic           = 0.0
		mat.metallic_specular  = 0.65
		mat.clearcoat_enabled  = true
		mat.clearcoat          = 0.20
		mat.clearcoat_roughness = 0.10

	elif is_tile_mat:
		mat.roughness          = 0.14
		mat.metallic           = 0.0
		mat.metallic_specular  = 0.55
		mat.clearcoat_enabled  = true
		mat.clearcoat          = 0.15
		mat.clearcoat_roughness = 0.14

	elif is_wood_mat:
		mat.roughness          = 0.25
		mat.metallic           = 0.0
		mat.metallic_specular  = 0.20
		mat.clearcoat_enabled  = false
		mat.anisotropy_enabled = false

	return mat

static func apply_reflection_hotspot_fix_to_all(node: Node) -> void:
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

			var surf_name = m.get_surface_override_material_name(i)
			if surf_name == "":
				surf_name = m.mesh.surface_get_name(i)
			if surf_name == "" and mat.resource_path != "":
				surf_name = mat.resource_path.get_file()
			elif surf_name == "" and mat.resource_name != "":
				surf_name = mat.resource_name
	
			if surf_name == "" and sm.albedo_texture != null:
				var tex_path = sm.albedo_texture.resource_path
				if tex_path == "" and sm.albedo_texture.resource_name != "":
					tex_path = sm.albedo_texture.resource_name
				if tex_path != "":
					surf_name = tex_path.get_file()
			surf_name = surf_name.to_lower()

			var is_bright_neutral = false
			if surf_name == "":
				var c = sm.albedo_color
				is_bright_neutral = (c.r > 0.70 and c.g > 0.70 and c.b > 0.70 and sm.roughness > 0.35)

			var is_mirror = "mirror" in surf_name
			var is_marble = "marble" in surf_name or "stone" in surf_name or "polished" in surf_name or "granit" in surf_name
			var is_tile   = "tile" in surf_name or "ceramic" in surf_name or "porcelain" in surf_name or "travert" in surf_name
			var is_wood   = "wood" in surf_name or "parquet" in surf_name or "plank" in surf_name or "oak" in surf_name or "walnut" in surf_name or "timber" in surf_name
			var is_floor  = "floor" in surf_name or "ground" in surf_name

			if is_bright_neutral and not is_mirror:
				is_marble = true

			if is_mirror:
				pass # Let the material optimizer handle it
			elif is_marble or is_tile:
				sm.roughness = clamp(sm.roughness, 0.08, 0.20)
				sm.metallic_specular = min(sm.metallic_specular, 0.65)
				sm.metallic = 0.0
				sm.clearcoat_enabled = true
				sm.clearcoat = 0.15
				sm.clearcoat_roughness = 0.12
			elif is_wood:
				sm.metallic = 0.0
				sm.roughness = 0.25
				sm.metallic_specular = 0.2
				sm.clearcoat_enabled = false
				sm.clearcoat = 0.0
				sm.anisotropy_enabled = false
			elif is_floor:
				sm.roughness = max(sm.roughness, 0.18)
				sm.metallic_specular = min(sm.metallic_specular, 0.5)
				sm.metallic = 0.0
				sm.clearcoat_enabled = false
			else:
				sm.roughness = clamp(sm.roughness, 0.05, 1.0)
				sm.metallic_specular = min(sm.metallic_specular, 0.5)

static func _get_all_meshes(node: Node) -> Array:
	var meshes = []
	if node is MeshInstance3D:
		meshes.append(node)
	for child in node.get_children():
		meshes.append_array(_get_all_meshes(child))
	return meshes
