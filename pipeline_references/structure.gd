extends RefCounted

var main_script: Object
var custom_shape_gen: Object

func _init(p_main_script: Object):
	main_script = p_main_script
	custom_shape_gen = preload("res://custom_shape.gd").new(main_script)

func _resolve_structure_material(structure: Dictionary, structure_type: String) -> Dictionary:
	var mats = {}
	if structure.has("materials") and typeof(structure["materials"]) == TYPE_DICTIONARY:
		mats = structure["materials"]

	var preferred = []
	match structure_type:
		"squarecolumn", "circlecolumn", "flue":
			preferred = ["Column"]
		"beam":
			preferred = ["Beam"]
		"ramp":
			preferred = ["Ramp"]
		"step":
			preferred = ["Step"]
		"falseceiling":
			preferred = ["False Ceiling", "Drop Section"]
		"staircase":
			preferred = ["StaircaseTop", "Step", "LandingTop"]
		"flooropening":
			preferred = ["FloorOpening", "Frame"]
		_:
			preferred = []

	for key in preferred:
		if mats.has(key) and typeof(mats[key]) == TYPE_DICTIONARY:
			var mat = mats[key].duplicate()
			mat["is_structure"] = true
			return mat

	if mats.size() > 0:
		var first_key = mats.keys()[0]
		if typeof(mats[first_key]) == TYPE_DICTIONARY:
			var mat = mats[first_key].duplicate()
			mat["is_structure"] = true
			return mat

	return {"color": Color(0.78, 0.78, 0.78), "is_structure": true}

func _add_custom_shape_structure(parent: Node3D, structure: Dictionary, scale_factor: float) -> void:
	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var shapes_json_str = ""
	if structure.has("shapesJson"):
		shapes_json_str = str(structure["shapesJson"])
	elif props.has("shapesJson"):
		shapes_json_str = str(props["shapesJson"])
	elif props.has("customShapeData"):
		shapes_json_str = str(props["customShapeData"])
	elif props.has("custom_shape_data"):
		shapes_json_str = str(props["custom_shape_data"])

	if shapes_json_str != "" and shapes_json_str != "null":
		var tw = float(props.get("width", {}).get("length", -1.0)) * scale_factor if props.has("width") else -1.0
		var th = float(props.get("height", {}).get("length", -1.0)) * scale_factor if props.has("height") else -1.0
		var td = float(props.get("depth", {}).get("length", -1.0)) * scale_factor if props.has("depth") else -1.0
		custom_shape_gen.generate_shapes(parent, shapes_json_str, scale_factor, Vector3(tw, th, td))

func _add_sunshade_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary, render_mode: String = "INTERIOR") -> void:
	var w = max(width, 0.05)
	var d = max(depth, 0.05)
	var h = max(height, 0.05)
	var props = structure.get("properties", {})
	var slope_deg = float(props.get("slope", 5.0))
	var slope_rad = deg_to_rad(slope_deg)
	var dh = d * tan(slope_rad)
	var front_thickness = max(h * 0.5, 0.04)
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var wall_top = h
	var wall_bot = 0.0
	var front_top = h - dh
	var front_bot = front_top - front_thickness
	
	var min_x = -w * 0.5
	var max_x = w * 0.5
	var min_z = -d * 0.5
	var max_z = d * 0.5
	
	var v0 = Vector3(min_x, wall_bot, min_z)
	var v1 = Vector3(max_x, wall_bot, min_z)
	var v2 = Vector3(max_x, wall_top, min_z)
	var v3 = Vector3(min_x, wall_top, min_z)
	var v4 = Vector3(min_x, front_bot, max_z)
	var v5 = Vector3(max_x, front_bot, max_z)
	var v6 = Vector3(max_x, front_top, max_z)
	var v7 = Vector3(min_x, front_top, max_z)
	
	st.add_vertex(v0); st.add_vertex(v3); st.add_vertex(v2);
	st.add_vertex(v0); st.add_vertex(v2); st.add_vertex(v1);
	st.add_vertex(v5); st.add_vertex(v6); st.add_vertex(v7);
	st.add_vertex(v5); st.add_vertex(v7); st.add_vertex(v4);
	st.add_vertex(v3); st.add_vertex(v7); st.add_vertex(v6);
	st.add_vertex(v3); st.add_vertex(v6); st.add_vertex(v2);
	st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(v5);
	st.add_vertex(v0); st.add_vertex(v5); st.add_vertex(v4);
	st.add_vertex(v4); st.add_vertex(v7); st.add_vertex(v3);
	st.add_vertex(v4); st.add_vertex(v3); st.add_vertex(v0);
	st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v6);
	st.add_vertex(v1); st.add_vertex(v6); st.add_vertex(v5);
	
	st.generate_normals()
	var mesh = MeshInstance3D.new()
	mesh.mesh = st.commit()
	mesh.material_override = main_script.create_material(mat_data)
	if mesh.material_override is BaseMaterial3D:
		# Sunshades are often thin and viewed from grazing angles, so keep both
		# sides visible instead of relying on face winding.
		(mesh.material_override as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Interior sunshades are often thin and close to the camera; a generous
	# bounding box prevents them from being frustum-culled before they reach
	# the image plane.
	if render_mode.to_upper() == "INTERIOR":
		mesh.extra_cull_margin = 2.0
		mesh.custom_aabb = AABB(Vector3(-w, -h, -d), Vector3(w * 2.0, h * 3.0, d * 2.0))
	else:
		mesh.extra_cull_margin = max(w, d, h) * 0.5 + 0.25
		mesh.custom_aabb = AABB(
			Vector3(-w * 0.5 - 0.25, min(0.0, front_bot) - 0.25, -d * 0.5 - 0.25),
			Vector3(w + 0.5, max(wall_top, front_top) - min(0.0, front_bot) + 0.5, d + 0.5)
		)
	parent.add_child(mesh)

func _add_baywindowsill_structure(parent: Node3D, width: float, depth: float, mat_data: Dictionary) -> void:
	var h = 0.005 # 5mm
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(width, 0.05), h, max(depth, 0.05))
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = main_script.create_material(mat_data)
	parent.add_child(mi)

func _add_niche_structure(parent: Node3D, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var w = max(width, 0.05)
	var d = max(depth, 0.05)
	var h = max(height, 0.05)
	var niche_group = Node3D.new()
	var mat = main_script.create_material(mat_data)
	
	var back = MeshInstance3D.new()
	back.mesh = PlaneMesh.new()
	back.mesh.size = Vector2(w, h)
	back.mesh.orientation = PlaneMesh.FACE_Z
	back.position = Vector3(0, 0, -d / 2.0)
	back.material_override = mat
	niche_group.add_child(back)
	
	var left = MeshInstance3D.new()
	left.mesh = PlaneMesh.new()
	left.mesh.size = Vector2(d, h)
	left.mesh.orientation = PlaneMesh.FACE_Z
	left.position = Vector3(-w / 2.0, 0, 0)
	left.rotation.y = PI / 2.0
	left.material_override = mat
	niche_group.add_child(left)
	
	var right = MeshInstance3D.new()
	right.mesh = PlaneMesh.new()
	right.mesh.size = Vector2(d, h)
	right.mesh.orientation = PlaneMesh.FACE_Z
	right.position = Vector3(w / 2.0, 0, 0)
	right.rotation.y = - PI / 2.0
	right.material_override = mat
	niche_group.add_child(right)
	
	var top = MeshInstance3D.new()
	top.mesh = PlaneMesh.new()
	top.mesh.size = Vector2(w, d)
	top.mesh.orientation = PlaneMesh.FACE_Y
	top.position = Vector3(0, h / 2.0, 0)
	top.rotation.x = PI
	top.material_override = mat
	niche_group.add_child(top)
	
	var bot = MeshInstance3D.new()
	bot.mesh = PlaneMesh.new()
	bot.mesh.size = Vector2(w, d)
	bot.mesh.orientation = PlaneMesh.FACE_Y
	bot.position = Vector3(0, -h / 2.0, 0)
	bot.material_override = mat
	niche_group.add_child(bot)
	
	niche_group.position.y = h / 2.0
	parent.add_child(niche_group)

func _add_box_structure(parent: Node3D, structure_type: String, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(width, 0.05), max(height, 0.05), max(depth, 0.05))
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = main_script.create_material(mat_data)
	mi.position = Vector3(0, max(height, 0.05) * 0.5, 0)
	parent.add_child(mi)

func _add_partitionwall_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	# The frontend stores the shape under properties.partition_shape, not at the root level.
	var props = structure.get("properties", {})
	var subtype = ""
	if typeof(props) == TYPE_DICTIONARY:
		subtype = str(props.get("partition_shape", "")).to_lower().strip_edges()
	if subtype == "":
		subtype = str(structure.get("partitionwall_subtype", "rect")).to_lower().strip_edges()

	# Wall thickness: prefer the authored value from properties (stored as {length: N} in source units).
	var wall_thickness = 0.1524 # fallback: standard 6-inch wall
	if typeof(props) == TYPE_DICTIONARY and props.has("wall_thickness"):
		var wt = props["wall_thickness"]
		var raw_t = 0.0
		if typeof(wt) == TYPE_DICTIONARY and wt.has("length"):
			raw_t = float(wt["length"])
		else:
			raw_t = float(wt)
		if raw_t > 0.0:
			wall_thickness = raw_t * main_script._scene_unit_scale

	match subtype:
		"rect":
			# Front/Back walls
			_add_box_part(parent, Vector3(width, height, wall_thickness), mat_data, Vector3(0, height / 2.0, (depth / 2.0) - (wall_thickness / 2.0)))
			_add_box_part(parent, Vector3(width, height, wall_thickness), mat_data, Vector3(0, height / 2.0, - (depth / 2.0) + (wall_thickness / 2.0)))
			# Side walls
			_add_box_part(parent, Vector3(wall_thickness, height, depth - (2 * wall_thickness)), mat_data, Vector3((width / 2.0) - (wall_thickness / 2.0), height / 2.0, 0))
			_add_box_part(parent, Vector3(wall_thickness, height, depth - (2 * wall_thickness)), mat_data, Vector3(- (width / 2.0) + (wall_thickness / 2.0), height / 2.0, 0))
		"l_shaped":
			_add_box_part(parent, Vector3(width, height, wall_thickness), mat_data, Vector3(0, height / 2.0, - (depth / 2.0) + (wall_thickness / 2.0)))
			_add_box_part(parent, Vector3(wall_thickness, height, depth - wall_thickness), mat_data, Vector3(- (width / 2.0) + (wall_thickness / 2.0), height / 2.0, wall_thickness / 2.0))
		"u_shaped":
			_add_box_part(parent, Vector3(width, height, wall_thickness), mat_data, Vector3(0, height / 2.0, - (depth / 2.0) + (wall_thickness / 2.0)))
			_add_box_part(parent, Vector3(wall_thickness, height, depth - wall_thickness), mat_data, Vector3((width / 2.0) - (wall_thickness / 2.0), height / 2.0, wall_thickness / 2.0))
			_add_box_part(parent, Vector3(wall_thickness, height, depth - wall_thickness), mat_data, Vector3(- (width / 2.0) + (wall_thickness / 2.0), height / 2.0, wall_thickness / 2.0))
		_:
			_add_box_structure(parent, "partitionwall", width, depth, height, mat_data)


func _add_cylinder_structure(parent: Node3D, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var radius = max(width, depth) * 0.5
	var mesh = CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = max(height, 0.05)
	mesh.radial_segments = 24
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = main_script.create_material(mat_data)
	mi.position = Vector3(0, max(height, 0.05) * 0.5, 0)
	parent.add_child(mi)

func _create_ramp_mesh(width: float, depth: float, height: float) -> ArrayMesh:
	var w = max(width, 0.05)
	var d = max(depth, 0.05)
	var h = max(height, 0.05)

	# Triangular prism extruded along X to make a simple ramp wedge.
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var v0 = Vector3(-w * 0.5, 0, -d * 0.5)
	var v1 = Vector3(-w * 0.5, 0, d * 0.5)
	var v2 = Vector3(-w * 0.5, h, d * 0.5)
	var v3 = Vector3(w * 0.5, 0, -d * 0.5)
	var v4 = Vector3(w * 0.5, 0, d * 0.5)
	var v5 = Vector3(w * 0.5, h, d * 0.5)

	# Left triangle
	st.add_vertex(v0)
	st.add_vertex(v1)
	st.add_vertex(v2)
	# Right triangle
	st.add_vertex(v3)
	st.add_vertex(v5)
	st.add_vertex(v4)
	# Bottom face
	st.add_vertex(v0)
	st.add_vertex(v3)
	st.add_vertex(v4)
	st.add_vertex(v0)
	st.add_vertex(v4)
	st.add_vertex(v1)
	# Back face
	st.add_vertex(v1)
	st.add_vertex(v4)
	st.add_vertex(v5)
	st.add_vertex(v1)
	st.add_vertex(v5)
	st.add_vertex(v2)
	# Sloped face
	st.add_vertex(v0)
	st.add_vertex(v2)
	st.add_vertex(v5)
	st.add_vertex(v0)
	st.add_vertex(v5)
	st.add_vertex(v3)

	st.generate_normals()
	return st.commit()

func _add_ramp_structure(parent: Node3D, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var mesh = MeshInstance3D.new()
	mesh.mesh = _create_ramp_mesh(width, depth, height)
	mesh.material_override = main_script.create_material(mat_data)
	parent.add_child(mesh)

func _add_step_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var stair = {}
	if props.has("stair") and typeof(props["stair"]) == TYPE_DICTIONARY:
		stair = props["stair"]

	var flights = []
	if stair.has("flights") and typeof(stair["flights"]) == TYPE_ARRAY:
		flights = stair["flights"]

	var step_count = 1
	var riser = max(height, 0.05)
	var tread = max(depth, 0.05)
	var direction = "forward"

	if flights.size() > 0 and typeof(flights[0]) == TYPE_DICTIONARY:
		var flight = flights[0]
		step_count = max(int(flight.get("step_count", 1)), 1)
		if float(flight.get("riser_height", 0.0)) > 0:
			riser = float(flight.get("riser_height", 0.0)) * main_script._scene_unit_scale
		else:
			riser = max(height / float(step_count), 0.05)
		if float(flight.get("tread_depth", 0.0)) > 0:
			tread = float(flight.get("tread_depth", 0.0)) * main_script._scene_unit_scale
		else:
			tread = max(depth / float(step_count), 0.05)
		direction = str(flight.get("direction", "forward")).to_lower()
	else:
		if stair.has("auto_calculate_steps") and bool(stair["auto_calculate_steps"]):
			step_count = max(int(round(height / 0.15)), 1)
			riser = max(height / float(step_count), 0.05)
			tread = max(depth / float(step_count), 0.05)

	var step_width = max(width, 0.05)
	var dir_vec = Vector3(0, 0, 1)
	var step_rot_y = 0.0
	match direction:
		"backward", "back", "reverse":
			dir_vec = Vector3(0, 0, 1)
		"left":
			dir_vec = Vector3(-1, 0, 0)
			step_rot_y = PI / 2
		"right":
			dir_vec = Vector3(1, 0, 0)
			step_rot_y = PI / 2
		_:
			dir_vec = Vector3(0, 0, -1)

	var stair_csg = CSGCombiner3D.new()
	stair_csg.name = "StepCSG_" + str(structure.get("id", "unknown"))
	parent.add_child(stair_csg)

	var step_mat = main_script.create_material(mat_data)
	var overlap = 0.002
	var run_length = tread * float(step_count)
	var total_height = riser * float(step_count)

	var support_node = MeshInstance3D.new()
	support_node.mesh = _create_step_support_mesh(step_width, run_length, total_height)
	support_node.material_override = step_mat
	match direction:
		"backward", "back", "reverse":
			support_node.rotation.y = 0.0
		"left":
			support_node.rotation.y = - PI / 2.0
		"right":
			support_node.rotation.y = PI / 2.0
		_:
			support_node.rotation.y = PI
	stair_csg.add_child(support_node)

	for i in range(step_count):
		var step_node = CSGBox3D.new()
		step_node.operation = CSGShape3D.OPERATION_UNION
		step_node.size = Vector3(step_width, riser + overlap, tread + overlap)
		step_node.material = step_mat
		var step_pos = Vector3.ZERO
		step_pos += dir_vec * (tread * (i + 0.5))
		step_pos.y = riser * (i + 0.5)
		step_node.position = step_pos
		step_node.rotation.y = step_rot_y
		stair_csg.add_child(step_node)
		
	# Offset the entire stair CSG so the highest step is at the pivot (matching frontend)
	stair_csg.position = - dir_vec * run_length

func _create_step_support_mesh(width: float, run_length: float, total_height: float) -> ArrayMesh:
	var w = max(width, 0.05)
	var r = max(run_length, 0.05)
	var h = max(total_height, 0.05)

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var a = Vector3(-w * 0.5, 0, 0)
	var b = Vector3(-w * 0.5, 0, r)
	var c = Vector3(-w * 0.5, h, r)
	var d = Vector3(w * 0.5, 0, 0)
	var e = Vector3(w * 0.5, 0, r)
	var f = Vector3(w * 0.5, h, r)

	# Left end
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	# Right end
	st.add_vertex(d)
	st.add_vertex(f)
	st.add_vertex(e)
	# Bottom
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(e)
	st.add_vertex(a)
	st.add_vertex(e)
	st.add_vertex(b)
	# Back vertical face
	st.add_vertex(b)
	st.add_vertex(e)
	st.add_vertex(f)
	st.add_vertex(b)
	st.add_vertex(f)
	st.add_vertex(c)
	# Sloped face
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(f)
	st.add_vertex(a)
	st.add_vertex(f)
	st.add_vertex(d)

	st.generate_normals()
	return st.commit()

func _add_false_ceiling_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var drop_height = main_script.get_dimension_value(props.get("drop_height", 0)) * main_script._scene_unit_scale
	var pattern_type = str(props.get("pattern_type", "")).to_lower()
	var slab_h = max(height, 0.03)
	var root_color = mat_data
	var drop_mat = _resolve_structure_material(structure, "falseceiling")
	if structure.has("materials") and typeof(structure["materials"]) == TYPE_DICTIONARY:
		var mats = structure["materials"]
		if mats.has("Drop Section") and typeof(mats["Drop Section"]) == TYPE_DICTIONARY:
			drop_mat = mats["Drop Section"]

	if pattern_type == "coffered" and drop_height > 0.01 and width > 0.2 and depth > 0.2:
		var border = min(width, depth) * 0.16
		border = clamp(border, 0.08, 0.35)

		# Central panel
		_add_box_part(parent, Vector3(max(width - border * 2.0, 0.1), slab_h, max(depth - border * 2.0, 0.1)), root_color, Vector3(0, -slab_h * 0.5, 0))

		# Lower perimeter bands
		var drop_y = - (drop_height + slab_h * 0.5)
		_add_box_part(parent, Vector3(width, slab_h, border), drop_mat, Vector3(0, drop_y, depth * 0.5 - border * 0.5))
		_add_box_part(parent, Vector3(width, slab_h, border), drop_mat, Vector3(0, drop_y, -depth * 0.5 + border * 0.5))
		_add_box_part(parent, Vector3(border, slab_h, max(depth - border * 2.0, 0.1)), drop_mat, Vector3(width * 0.5 - border * 0.5, drop_y, 0))
		_add_box_part(parent, Vector3(border, slab_h, max(depth - border * 2.0, 0.1)), drop_mat, Vector3(-width * 0.5 + border * 0.5, drop_y, 0))
	else:
		_add_box_part(parent, Vector3(width, slab_h, depth), root_color, Vector3(0, -slab_h * 0.5, 0))

func _add_box_part(parent: Node3D, size: Vector3, mat_data: Dictionary, local_position: Vector3) -> void:
	var mesh = BoxMesh.new()
	mesh.size = Vector3(max(size.x, 0.03), max(size.y, 0.03), max(size.z, 0.03))
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = main_script.create_material(mat_data)
	mi.position = local_position
	parent.add_child(mi)

func _add_multi_mat_box(parent: Node3D, size: Vector3, pos: Vector3, mats: Dictionary, rot_y: float = 0.0) -> void:
	var side_mat = mats.get("Sides", mats.get("fallback", {}))
	var top_mat = mats.get("Top", side_mat)
	var bottom_mat = mats.get("Bottom", side_mat)
	var is_multi = mats.has("Top") or mats.has("Bottom")
	if not is_multi:
		_add_box_part(parent, size, side_mat, pos)
		parent.get_child(parent.get_child_count() - 1).rotation.y = rot_y
		return
		
	var core_w = max(size.x - 0.004, 0.01)
	var core_h = max(size.y - 0.004, 0.01)
	var core_d = max(size.z - 0.004, 0.01)
	
	var holder = Node3D.new()
	holder.position = pos
	holder.rotation.y = rot_y
	parent.add_child(holder)
	
	# Core (Sides: Left/Right)
	_add_box_part(holder, Vector3(size.x, core_h, core_d), side_mat, Vector3.ZERO)
	
	# Top (+Y)
	_add_box_part(holder, Vector3(size.x, 0.002, size.z), top_mat, Vector3(0, size.y * 0.5 - 0.001, 0))
	
	# Bottom (-Y)
	_add_box_part(holder, Vector3(size.x, 0.002, size.z), bottom_mat, Vector3(0, -size.y * 0.5 + 0.001, 0))
	
	# Back (+Z in Godot, matching THREE.js +Z which gets StaircaseTop in frontend)
	_add_box_part(holder, Vector3(size.x, core_h, 0.002), top_mat, Vector3(0, 0, size.z * 0.5 - 0.001))
	
	# Front/Riser (-Z in Godot, matching THREE.js -Z which gets StaircaseBottom in frontend)
	_add_box_part(holder, Vector3(size.x, core_h, 0.002), bottom_mat, Vector3(0, 0, -size.z * 0.5 + 0.001))

func _add_staircase_structure(parent: Node3D, structure: Dictionary, width: float, depth: float, height: float, mat_data: Dictionary) -> void:
	var props = {}
	if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
		props = structure["properties"]

	var stair = {}
	if props.has("stair") and typeof(props["stair"]) == TYPE_DICTIONARY:
		stair = props["stair"]

	var stair_type = str(stair.get("stair_type", "straight")).to_lower()
	var bottom_type = str(stair.get("bottom_type", "stepped")).to_lower()
	var flights = []
	if stair.has("flights") and typeof(stair["flights"]) == TYPE_ARRAY:
		flights = stair["flights"]

	var raw_mats = structure.get("materials", {})
	if typeof(raw_mats) != TYPE_DICTIONARY:
		raw_mats = {}
	var step_mats = {
		"Top": raw_mats.get("StaircaseTop", raw_mats.get("Step", mat_data)),
		"Bottom": raw_mats.get("StaircaseBottom", mat_data),
		"Sides": raw_mats.get("StaircaseSides", mat_data),
		"fallback": mat_data
	}
	var landing_mats = {
		"Top": raw_mats.get("LandingTop", step_mats["Top"]),
		"Bottom": raw_mats.get("LandingBottom", step_mats["Bottom"]),
		"Sides": raw_mats.get("LandingSides", step_mats["Sides"]),
		"fallback": mat_data
	}

	var step_material = step_mats
	var total_height = height

	if flights.size() == 0:
		var fallback_width = width
		if fallback_width <= 0.05:
			fallback_width = 1.0
		var fallback_steps = 12
		var fallback_riser = 0.1524
		var fallback_tread = 0.254
		var fallback_dir = _resolve_stair_travel_direction("forward")
		var fallback_start = Vector3.ZERO
		_add_stair_flight(parent, fallback_steps, fallback_riser, fallback_tread, fallback_width, fallback_start, fallback_dir, 0.0, step_material, bottom_type)
		return

	var first_flight = flights[0]
	var first_steps = max(int(first_flight.get("step_count", 12)), 1)
	var first_riser = float(first_flight.get("riser_height", 15.24)) * main_script._scene_unit_scale
	if first_riser <= 0.0:
		first_riser = total_height / float(max(first_steps, 1))
	var first_tread = depth / max(first_steps, 1)
	if float(first_flight.get("tread_depth", 0.0)) > 0:
		first_tread = float(first_flight.get("tread_depth", 0.0)) * main_script._scene_unit_scale
	var stair_width = width
	var first_direction = str(first_flight.get("direction", "forward")).to_lower()
	var first_travel_dir = _resolve_stair_travel_direction(first_direction)
	var first_step_rot_y = _resolve_stair_step_rotation(first_direction)
	var first_start_pos = Vector3.ZERO

	_add_stair_flight(
		parent,
		first_steps,
		first_riser,
		first_tread,
		stair_width,
		first_start_pos,
		first_travel_dir,
		first_step_rot_y,
		step_material,
		bottom_type
	)

	var current_height = first_steps * first_riser
	var first_run = first_steps * first_tread
	var landing_h = max(first_riser, 0.05)
	var landing_depth = max(stair_width, first_tread * 1.5)

	if stair_type == "straight" or flights.size() == 1:
		pass
	elif stair_type == "u_shaped":
		var turn_dir_str = "left"
		if stair.has("turn_direction"):
			turn_dir_str = str(stair["turn_direction"]).to_lower()
		elif structure.has("turn_direction"):
			turn_dir_str = str(structure["turn_direction"]).to_lower()
			
		var landing_x_offset = stair_width * 0.5
		var second_start_x = stair_width
		if turn_dir_str == "right":
			landing_x_offset = - stair_width * 0.5
			second_start_x = - stair_width

		_add_multi_mat_box(parent, Vector3(stair_width * 2.0, landing_h, landing_depth), Vector3(landing_x_offset, current_height - landing_h * 0.5, first_run + landing_depth * 0.5), landing_mats, 0.0)
		if flights.size() > 1:
			var second_flight = flights[1]
			var second_steps = int(second_flight.get("step_count", first_steps))
			var second_riser = first_riser
			if float(second_flight.get("riser_height", 0.0)) > 0:
				second_riser = float(second_flight.get("riser_height", 0.0)) * main_script._scene_unit_scale
			var second_tread = first_tread
			if float(second_flight.get("tread_depth", 0.0)) > 0:
				second_tread = float(second_flight.get("tread_depth", 0.0)) * main_script._scene_unit_scale
			
			var t_dir = Vector3(0, 0, -1)
			var r_y = PI
			_add_stair_flight(parent, second_steps, second_riser, second_tread, stair_width, Vector3(second_start_x, current_height, first_run), t_dir, r_y, step_material, bottom_type)
	elif stair_type == "winder":
		var turn_dir_str = "left"
		if stair.has("turn_direction"):
			turn_dir_str = str(stair["turn_direction"]).to_lower()
		elif structure.has("turn_direction"):
			turn_dir_str = str(structure["turn_direction"]).to_lower()
		
		var turn_sign = -1.0 if turn_dir_str == "right" else 1.0
		var winder_count = 3
		var winder_r = stair_width
		var winder_angle = (PI / 2.0) / winder_count
		var winder_center_z = first_run
		
		for i in range(winder_count):
			var a0 = i * winder_angle
			var a1 = (i + 1) * winder_angle
			
			var st = SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			
			var segs = 4
			var center = Vector3(0, 0, 0)
			var pts = [center]
			for s in range(segs + 1):
				var a = a0 + (a1 - a0) * (float(s) / segs)
				var r_sq = winder_r / max(cos(a), sin(a))
				pts.append(Vector3(-turn_sign * r_sq * cos(a), 0, r_sq * sin(a)))
			
			var step_h = first_riser
			var bottom_y = -i * step_h
			for s in range(segs):
				var p1 = pts[s + 1]
				var p2 = pts[s + 2]
				
				# top
				st.add_vertex(Vector3(0, step_h, 0)); st.add_vertex(Vector3(p2.x, step_h, p2.z)); st.add_vertex(Vector3(p1.x, step_h, p1.z))
				# bottom
				st.add_vertex(Vector3(0, bottom_y, 0)); st.add_vertex(Vector3(p1.x, bottom_y, p1.z)); st.add_vertex(Vector3(p2.x, bottom_y, p2.z))
				# outer curve
				st.add_vertex(Vector3(p2.x, bottom_y, p2.z)); st.add_vertex(Vector3(p1.x, bottom_y, p1.z)); st.add_vertex(Vector3(p1.x, step_h, p1.z))
				st.add_vertex(Vector3(p2.x, bottom_y, p2.z)); st.add_vertex(Vector3(p1.x, step_h, p1.z)); st.add_vertex(Vector3(p2.x, step_h, p2.z))
			
			var p_start = pts[1]
			var p_end = pts[pts.size() - 1]
			st.add_vertex(Vector3(0, bottom_y, 0)); st.add_vertex(Vector3(p_start.x, step_h, p_start.z)); st.add_vertex(Vector3(0, step_h, 0))
			st.add_vertex(Vector3(0, bottom_y, 0)); st.add_vertex(Vector3(p_start.x, bottom_y, p_start.z)); st.add_vertex(Vector3(p_start.x, step_h, p_start.z))
			st.add_vertex(Vector3(p_end.x, bottom_y, p_end.z)); st.add_vertex(Vector3(0, step_h, 0)); st.add_vertex(Vector3(p_end.x, step_h, p_end.z))
			st.add_vertex(Vector3(p_end.x, bottom_y, p_end.z)); st.add_vertex(Vector3(0, bottom_y, 0)); st.add_vertex(Vector3(0, step_h, 0))
			
			st.generate_normals()
			var mesh = MeshInstance3D.new()
			mesh.mesh = st.commit()
			mesh.material_override = main_script.create_material(step_mats.get("Top", step_mats["fallback"]))
			
			mesh.position = Vector3(
				turn_sign * stair_width * 0.5,
				current_height + i * step_h,
				winder_center_z
			)
			parent.add_child(mesh)
		
		if flights.size() > 1:
			var second_flight_w = flights[1]
			var second_steps_w = int(second_flight_w.get("step_count", first_steps))
			var second_riser_w = first_riser
			if float(second_flight_w.get("riser_height", 0.0)) > 0:
				second_riser_w = float(second_flight_w.get("riser_height", 0.0)) * main_script._scene_unit_scale
			var second_tread_w = first_tread
			if float(second_flight_w.get("tread_depth", 0.0)) > 0:
				second_tread_w = float(second_flight_w.get("tread_depth", 0.0)) * main_script._scene_unit_scale
			
			var winder_top_y = current_height + winder_count * first_riser
			var t_dir_w = _resolve_stair_travel_direction(turn_dir_str)
			var r_y_w = turn_sign * (PI / 2.0)
			
			var start_x_w = turn_sign * stair_width * 0.5
			var start_z_w = winder_center_z + stair_width * 0.5
			_add_stair_flight(parent, second_steps_w, second_riser_w, second_tread_w, stair_width, Vector3(start_x_w, winder_top_y, start_z_w), t_dir_w, r_y_w, step_material, bottom_type)

	else:
		_add_multi_mat_box(parent, Vector3(stair_width, landing_h, landing_depth), Vector3(0, current_height - landing_h * 0.5, first_run + landing_depth * 0.5), landing_mats, 0.0)
		if flights.size() > 1:
			var second_flight_l = flights[1]
			var second_steps_l = int(second_flight_l.get("step_count", first_steps))
			var second_riser_l = first_riser
			if float(second_flight_l.get("riser_height", 0.0)) > 0:
				second_riser_l = float(second_flight_l.get("riser_height", 0.0)) * main_script._scene_unit_scale
			var second_tread_l = first_tread
			if float(second_flight_l.get("tread_depth", 0.0)) > 0:
				second_tread_l = float(second_flight_l.get("tread_depth", 0.0)) * main_script._scene_unit_scale
			var dir_str_l = str(second_flight_l.get("direction", "left")).to_lower()
			if stair.has("turn_direction"):
				dir_str_l = str(stair["turn_direction"]).to_lower()
			elif structure.has("turn_direction"):
				dir_str_l = str(structure["turn_direction"]).to_lower()
			var t_dir_l = _resolve_stair_travel_direction(dir_str_l)
			var r_y_l = _resolve_stair_step_rotation(dir_str_l)
			var start_x_l = (stair_width * 0.5) * sign(t_dir_l.x) if abs(t_dir_l.x) > 0.1 else 0.0
			_add_stair_flight(parent, second_steps_l, second_riser_l, second_tread_l, stair_width, Vector3(start_x_l, current_height, first_run + landing_depth * 0.5), t_dir_l, r_y_l, step_material, bottom_type)

	var total_tread_length = first_steps * first_tread
	if flights.size() > 1:
		var second_flight = flights[1]
		var second_steps = int(second_flight.get("step_count", first_steps))
		var second_tread = first_tread
		if float(second_flight.get("tread_depth", 0.0)) > 0:
			second_tread = float(second_flight.get("tread_depth", 0.0)) * main_script._scene_unit_scale
		total_tread_length += second_steps * second_tread

	var cz = total_tread_length * 0.5
	for child in parent.get_children():
		child.position.z -= cz

func _add_stair_flight(parent: Node3D, step_count: int, riser: float, tread: float, stair_width: float, start_pos: Vector3, travel_dir: Vector3, step_rot_y: float, mats: Dictionary, bottom_type: String = "stepped") -> void:
	var steps = max(step_count, 1)
	var step_w = max(stair_width, 0.05)
	var step_h = max(riser, 0.03)
	var step_d = max(tread, 0.05)
	var dir = travel_dir
	if dir.length() < 0.001:
		dir = Vector3(0, 0, 1)
	dir = dir.normalized()

	if bottom_type == "flat":
		var fD = step_d * steps
		var fH = step_h * steps
		var L = sqrt(fD * fD + fH * fH)
		var soffitT = max(step_h * 0.6, 0.002)
		var backClipX = min(fD, soffitT * L / fH)
		var frontClipY = max(0.0, fH - soffitT * L / fD)
		
		var pts = PackedVector2Array()
		pts.append(Vector2(0, 0))
		for i in range(steps):
			var rise_y = (i + 1) * step_h
			var tread_x = (i + 1) * step_d
			pts.append(Vector2(i * step_d, rise_y))
			pts.append(Vector2(tread_x, rise_y))
		pts.append(Vector2(fD, frontClipY))
		pts.append(Vector2(backClipX, 0))
		pts.append(Vector2(0, 0))
		
		var side_mat = main_script.create_material(mats.get("Sides", mats.get("fallback", {})))
		var top_mat = main_script.create_material(mats.get("Top", mats.get("fallback", {})))
		var bot_mat = main_script.create_material(mats.get("Bottom", mats.get("fallback", {})))
		
		var mesh = ArrayMesh.new()
		var st = SurfaceTool.new()
		var hw = step_w * 0.5
		
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(top_mat)
		for i in range(steps):
			var z1 = i * step_d
			var z2 = (i + 1) * step_d
			var y = (i + 1) * step_h
			st.set_normal(Vector3(0, 1, 0))
			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, y, z1))
			st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-hw, y, z2))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, y, z2))
			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, y, z1))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, y, z2))
			st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(hw, y, z1))
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(hw, frontClipY, fD))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(hw, fH, fD))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(-hw, fH, fD))
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(hw, frontClipY, fD))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(-hw, fH, fD))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(-hw, frontClipY, fD))
		st.commit(mesh)
		
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(bot_mat)
		for i in range(steps):
			var z = i * step_d
			var y1 = i * step_h
			var y2 = (i + 1) * step_h
			st.set_normal(Vector3(0, 0, -1))
			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, y1, z))
			st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-hw, y2, z))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, y2, z))
			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, y1, z))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, y2, z))
			st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(hw, y1, z))
		st.set_normal(Vector3(0, -1, 0))
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, 0, backClipX))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-hw, 0, 0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, 0, 0))
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, 0, backClipX))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, 0, 0))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(hw, 0, backClipX))
		var dz = fD - backClipX
		var dy = frontClipY - 0
		var sn = Vector3(0, -dz, dy).normalized()
		st.set_normal(sn)
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, frontClipY, fD))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(-hw, 0, backClipX))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, 0, backClipX))
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(-hw, frontClipY, fD))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(hw, 0, backClipX))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(hw, frontClipY, fD))
		st.commit(mesh)
		
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(side_mat)
		var indices = Geometry2D.triangulate_polygon(pts)
		st.set_normal(Vector3(1, 0, 0))
		for i in range(indices.size() - 1, -1, -1):
			var idx = indices[i]
			var p = pts[idx]
			st.set_uv(Vector2(p.x, p.y)); st.add_vertex(Vector3(hw, p.y, p.x))
		st.set_normal(Vector3(-1, 0, 0))
		for idx in indices:
			var p = pts[idx]
			st.set_uv(Vector2(p.x, p.y)); st.add_vertex(Vector3(-hw, p.y, p.x))
		st.commit(mesh)
		
		var mi = MeshInstance3D.new()
		mi.mesh = mesh
		mi.rotation.y = step_rot_y
		mi.position = start_pos
		parent.add_child(mi)
	else:
		for i in range(steps):
			var pos = start_pos
			pos += dir * (step_d * (i + 0.5))
			pos.y += step_h * (i + 0.5)
			if typeof(mats) == TYPE_DICTIONARY and mats.has("fallback"):
				_add_multi_mat_box(parent, Vector3(step_w, step_h, step_d), pos, mats, step_rot_y)
			else:
				_add_box_part(parent, Vector3(step_w, step_h, step_d), mats, pos)
				parent.get_child(parent.get_child_count() - 1).rotation.y = step_rot_y

func _resolve_stair_travel_direction(direction: String) -> Vector3:
	match direction:
		"backward", "back", "reverse":
			return Vector3(0, 0, -1)
		"left":
			return Vector3(1, 0, 0)
		"right":
			return Vector3(-1, 0, 0)
		_:
			return Vector3(0, 0, 1)

func _resolve_stair_step_rotation(direction: String) -> float:
	match direction:
		"left":
			return PI / 2.0
		"right":
			return -PI / 2.0
		_:
			return 0.0

func _add_floor_opening_frame(parent: Node3D, structure: Dictionary, width: float, depth: float, mat_data: Dictionary) -> void:
	var frame = max(min(width, depth) * 0.08, 0.04)
	var frame_h = 0.04
	var slab_y = frame_h * 0.5
	_add_box_part(parent, Vector3(width + frame * 2.0, frame_h, frame), mat_data, Vector3(0, slab_y, depth * 0.5 + frame * 0.5))
	_add_box_part(parent, Vector3(width + frame * 2.0, frame_h, frame), mat_data, Vector3(0, slab_y, -depth * 0.5 - frame * 0.5))
	_add_box_part(parent, Vector3(frame, frame_h, depth), mat_data, Vector3(width * 0.5 + frame * 0.5, slab_y, 0))
	_add_box_part(parent, Vector3(frame, frame_h, depth), mat_data, Vector3(-width * 0.5 - frame * 0.5, slab_y, 0))

func _add_floor_opening_cutters(csg: CSGCombiner3D, structures, area_id: String, layer_altitude: float, cut_height: float, scale_factor: float) -> void:
	if typeof(structures) != TYPE_DICTIONARY:
		return

	for structure_id in structures:
		var structure = structures[structure_id]
		if typeof(structure) != TYPE_DICTIONARY:
			continue
		if str(structure.get("structure_type", "")).to_lower() != "flooropening":
			continue
		if structure.has("parentId") and str(structure["parentId"]) != area_id:
			continue

		var props = {}
		if structure.has("properties") and typeof(structure["properties"]) == TYPE_DICTIONARY:
			props = structure["properties"]

		var width = main_script.get_dimension_value(props.get("width", structure.get("width", 100))) * scale_factor
		var depth = main_script.get_dimension_value(props.get("depth", structure.get("depth", 100))) * scale_factor
		var altitude = main_script.get_dimension_value(props.get("altitude", structure.get("altitude", 0))) * scale_factor
		var opening_xy = main_script._plan_point_2d(float(structure.get("x", 0)), float(structure.get("y", 0)))
		var opening = CSGBox3D.new()
		opening.operation = CSGBox3D.OPERATION_SUBTRACTION
		opening.size = Vector3(max(width, 0.05), max(cut_height, 0.2), max(depth, 0.05))
		opening.position = Vector3(
			opening_xy.x * scale_factor,
			layer_altitude + altitude - max(cut_height, 0.2) * 0.5,
			opening_xy.y * scale_factor
		)
		csg.add_child(opening)

# ==============================================================================
# ASSET LOADING AND PLACEMENT
# ==============================================================================
# WHY IT EXISTS: To read the items array from the JSON layout, dynamically 
# download the 3D GLB models for furniture, appliances, and decorations, and 
# place them at exact coordinates inside the 3D rooms.
# ==============================================================================
