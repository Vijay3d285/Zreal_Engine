class_name CustomShapeGenerator
extends Node

var main_script = null

func _init(_main_script):
	main_script = _main_script

# ============================================================================
# PUBLIC API - Floor Custom Shapes
# ============================================================================
func generate_floor_shapes(parent: Node3D, custom_shapes: Array, scale_factor: float, layer_altitude: float = 0.0) -> void:
	if custom_shapes == null or custom_shapes.size() == 0:
		return
		
	var shape_idx = 0
	for shape_data in custom_shapes:
		if typeof(shape_data) != TYPE_DICTIONARY:
			continue
			
		var shape_node = _create_floor_ceiling_shape(shape_data, scale_factor, "floor", layer_altitude, shape_idx)
		if shape_node:
			parent.add_child(shape_node)
		shape_idx += 1

# ============================================================================
# PUBLIC API - Ceiling Custom Shapes
# ============================================================================
func generate_ceiling_shapes(parent: Node3D, custom_shapes: Array, scale_factor: float, ceiling_y: float, ceil_depth: float) -> void:
	if custom_shapes == null or custom_shapes.size() == 0:
		return
		
	var shape_idx = 0
	for shape_data in custom_shapes:
		if typeof(shape_data) != TYPE_DICTIONARY:
			continue
			
		var shape_node = _create_floor_ceiling_shape(shape_data, scale_factor, "ceiling", ceiling_y, shape_idx, ceil_depth)
		if shape_node:
			parent.add_child(shape_node)
		shape_idx += 1

# ============================================================================
# PUBLIC API - Wall Custom Shapes (Inner/Outer)
# ============================================================================
func generate_wall_shapes(parent: Node3D, custom_shapes: Array, context: Dictionary) -> void:
	if custom_shapes == null or custom_shapes.size() == 0:
		return
		
	var hole_rects = context.get("hole_rects", [])
	
	# Ensure context has required values for 3D positioning
	if not context.has("base_y"):
		context["base_y"] = 0.0
	if not context.has("wall_thickness"):
		context["wall_thickness"] = 0.1  # Default 10cm wall
	
	for shape_data in custom_shapes:
		if typeof(shape_data) != TYPE_DICTIONARY:
			continue
			
		var shape_node = _create_wall_shape(shape_data, context, hole_rects)
		if shape_node:
			parent.add_child(shape_node)

# ============================================================================
# INTERNAL - Floor/Ceiling Shape Creation
# ============================================================================
func _create_floor_ceiling_shape(shape_data: Dictionary, scale_factor: float, surface_type: String, base_position: float, shape_idx: int, ceil_depth: float = 0.0) -> Node3D:
	# Parse points from documentation format
	var polygon_points = _parse_points_array(shape_data.get("points", []), scale_factor, Vector2.ZERO, false, false)
	if polygon_points.size() < 3:
		print("[CustomShape] Invalid points for floor/ceiling shape")
		return null
		
	# Enforce CCW winding for correct normals
	if _get_signed_area(polygon_points) < 0:
		polygon_points.reverse()
		
	# Get thickness from documentation format
	var thickness = _parse_thickness(shape_data.get("thickness", 10.0)) * scale_factor
	
	# Create CSG node
	var combiner = CSGCombiner3D.new()
	combiner.operation = CSGShape3D.OPERATION_UNION
	
	var csg_poly = CSGPolygon3D.new()
	csg_poly.mode = CSGPolygon3D.MODE_DEPTH
	csg_poly.polygon = polygon_points
	csg_poly.operation = CSGShape3D.OPERATION_UNION
	
	# Apply material
	_apply_material_to_node(csg_poly, shape_data.get("material", null))
	
	combiner.add_child(csg_poly)
	
	# Position based on surface type
	match surface_type:
		"floor":
			# Z-fighting prevention: 5mm above floor + 1mm per shape index
			var y_offset = base_position + 0.005 + (0.001 * shape_idx)
			combiner.position = Vector3(0, y_offset, 0)
			# Rotate so polygon (XZ plane) extrudes upward (Y axis)
			combiner.rotation = Vector3(-PI / 2, 0, 0)
			csg_poly.depth = thickness
			
		"ceiling":
			# Drop ceiling: hang below the ceiling slab
			var actual_thickness = thickness
			# Extend by 10mm to penetrate ceiling and avoid gaps
			csg_poly.depth = thickness + 0.01
			# Position: (ceiling_y - ceil_depth) - shape_thickness
			var y_position = (base_position - ceil_depth) - actual_thickness
			combiner.position = Vector3(0, y_position, 0)
			# Rotate to extrude downward
			combiner.rotation = Vector3(PI / 2, 0, 0)
	
	return combiner

# ============================================================================
# INTERNAL - Wall Shape Creation with Hole Clipping
# ============================================================================
func _create_wall_shape(shape_data: Dictionary, context: Dictionary, hole_rects: Array) -> Node3D:
	var scale_factor = context.get("scale_factor", 1.0)
	var p1 = context.get("p1", Vector2.ZERO)
	var p2 = context.get("p2", Vector2.ZERO)
	var wall_length = p1.distance_to(p2)
	var wall_height = context.get("height", 3.0)
	var face = context.get("face", "inner")
	var wall_base_y = context.get("base_y", 0.0)  # Floor Y position
	var wall_thickness = context.get("wall_thickness", 0.1)
	
	# Parse points for wall coordinates
	var polygon_points = _parse_points_array(
		shape_data.get("points", []),
		scale_factor,
		Vector2(wall_length, wall_height),
		true,  # flip_y
		face == "outer"  # flip_x for outer face
	)
	
	if polygon_points.size() < 3:
		print("[CustomShape] Invalid points for wall shape")
		return null
		
	# Enforce CCW winding
	if _get_signed_area(polygon_points) < 0:
		polygon_points.reverse()
		
	# Get thickness
	var thickness = _parse_thickness(shape_data.get("thickness", 10.0)) * scale_factor
	
	# Clip polygon against wall holes (doors/windows)
	var clipped_fragments = _clip_polygon_against_holes(polygon_points, hole_rects)
	
	if clipped_fragments.size() == 0:
		return null
		
	# Create CSGCombiner for all fragments
	var combiner = CSGCombiner3D.new()
	combiner.operation = CSGShape3D.OPERATION_UNION
	
	for fragment in clipped_fragments:
		if fragment.size() < 3:
			continue
			
		var csg_poly = CSGPolygon3D.new()
		csg_poly.mode = CSGPolygon3D.MODE_DEPTH
		csg_poly.depth = thickness
		csg_poly.polygon = fragment
		csg_poly.operation = CSGShape3D.OPERATION_UNION
		
		# Apply material
		_apply_material_to_node(csg_poly, shape_data.get("material", null))
		
		combiner.add_child(csg_poly)
		
	# =========================================================================
	# CRITICAL FIX: Position and rotate to match wall's 3D world location
	# =========================================================================
	
	# Calculate wall direction in floor plan (2D)
	var wall_dir_2d = (p2 - p1)
	if wall_dir_2d.length() < 0.001:
		return combiner
	var wall_dir_normalized = wall_dir_2d.normalized()
	
	# Calculate rotation angle around Y axis
	# To align local +X with wall direction (dx, 0, dz), the angle is atan2(-dz, dx)
	var wall_angle = atan2(-wall_dir_normalized.y, wall_dir_normalized.x)
	
	# Position at wall's start point in 3D space
	# Floor plan X -> 3D X, Floor plan Y -> 3D Z
	var pos_3d = Vector3(
		p1.x * scale_factor,
		wall_base_y,
		p1.y * scale_factor
	)
	
	# Calculate perpendicular offset for extrusion direction
	# Perpendicular to wall direction in XZ plane
	var perp_x = -wall_dir_normalized.y  # Rotated 90 degrees
	var perp_z = wall_dir_normalized.x
	
	# For inner face: shape extrudes inward (towards room center)
	# For outer face: shape extrudes outward (away from room center)
	var extrude_offset = 0.0
	if face == "outer":
		# Outer face - extrude away from inner side
		extrude_offset = wall_thickness * scale_factor
		# Also need to flip the Y rotation since we're looking from other side
		wall_angle += PI
		perp_x = -perp_x
		perp_z = -perp_z
	
	# Apply Z-fighting prevention (small offset from wall surface)
	var surface_offset = 0.005 if face == "inner" else -0.005
	
	# Set final position with perpendicular offset for extrusion
	combiner.position = Vector3(
		pos_3d.x + perp_x * (extrude_offset + surface_offset),
		pos_3d.y,
		pos_3d.z + perp_z * (extrude_offset + surface_offset)
	)
	
	# Set rotation to align with wall direction
	combiner.rotation.y = wall_angle
	
	return combiner

# ============================================================================
# POINTS PARSING - Handles Documentation Format
# ============================================================================
func _parse_points_array(points_raw, scale_factor: float, bounds: Vector2, flip_y: bool, flip_x: bool) -> PackedVector2Array:
	var result = PackedVector2Array()
	
	if typeof(points_raw) != TYPE_ARRAY:
		return result
		
	for p in points_raw:
		var px: float = 0.0
		var py: float = 0.0
		
		if typeof(p) == TYPE_DICTIONARY:
			px = float(p.get("x", 0))
			py = float(p.get("y", 0))
		elif typeof(p) == TYPE_VECTOR2:
			px = p.x
			py = p.y
		else:
			continue
		
		# Apply scale
		px *= scale_factor
		py *= scale_factor
		
		# Flip Y (frontend Y=0 is top, Godot Y=0 is bottom)
		if flip_y and bounds.y > 0:
			py = bounds.y - py
			
		# Flip X for outer wall face
		if flip_x and bounds.x > 0:
			px = bounds.x - px
		
		result.append(Vector2(px, py))
	
	return result

# ============================================================================
# THICKNESS PARSING - Handles Both Formats
# ============================================================================
func _parse_thickness(thickness_data, default_value: float = 10.0) -> float:
	if thickness_data == null:
		return default_value
		
	# Format 1: Direct float/int
	if typeof(thickness_data) == TYPE_FLOAT or typeof(thickness_data) == TYPE_INT:
		return float(thickness_data)
		
	# Format 2: Dictionary with "length" key
	if typeof(thickness_data) == TYPE_DICTIONARY:
		if thickness_data.has("length"):
			return float(thickness_data["length"])
		if thickness_data.has("depth"):
			return float(thickness_data["depth"])
			
	return default_value

# ============================================================================
# HOLE CLIPPING - Using Geometry2D (as per documentation)
# ============================================================================
func _clip_polygon_against_holes(polygon: PackedVector2Array, hole_rects: Array) -> Array:
	var fragments = [polygon]
	
	for hole_rect in hole_rects:
		if typeof(hole_rect) != TYPE_ARRAY or hole_rect.size() < 3:
			continue
		
		# Convert hole rect points to PackedVector2Array
		var hole_polygon = PackedVector2Array()
		for pt in hole_rect:
			if typeof(pt) == TYPE_VECTOR2:
				hole_polygon.append(pt)
			elif typeof(pt) == TYPE_DICTIONARY:
				hole_polygon.append(Vector2(float(pt.get("x", 0)), float(pt.get("y", 0))))
		
		if hole_polygon.size() < 3:
			continue
			
		# Clip all current fragments against this hole
		var new_fragments = []
		for fragment in fragments:
			var clipped = Geometry2D.clip_polygons(fragment, hole_polygon)
			for c in clipped:
				if c.size() >= 3:
					new_fragments.append(c)
		fragments = new_fragments
		
		if fragments.size() == 0:
			break  # Shape completely consumed by holes
			
	return fragments

# ============================================================================
# GEOMETRY HELPERS
# ============================================================================
func _get_signed_area(polygon: PackedVector2Array) -> float:
	var area = 0.0
	var n = polygon.size()
	for i in range(n):
		var j = (i + 1) % n
		area += polygon[i].x * polygon[j].y
		area -= polygon[j].x * polygon[i].y
	return area / 2.0

# ============================================================================
# MATERIAL HELPER
# ============================================================================
func _apply_material_to_node(node: Node, material_data) -> void:
	if material_data == null:
		return
	if main_script == null or not main_script.has_method("create_material"):
		return
		
	if not (node is CSGShape3D):
		return
		
	var mat_arg = material_data
	if typeof(material_data) == TYPE_STRING:
		mat_arg = {"color": material_data}
		
	var godot_mat = main_script.create_material(mat_arg)
	if godot_mat:
		node.material = godot_mat

# ============================================================================
# LEGACY SUPPORT - For Old JSON Format
# ============================================================================
func generate_shapes(parent: Node3D, shapes_json_str: String, scale_factor: float, target_size: Vector3 = Vector3(-1, -1, -1)) -> void:
	if shapes_json_str == "" or shapes_json_str == "[]" or shapes_json_str == "null":
		return
		
	var json = JSON.new()
	var err = json.parse(shapes_json_str)
	if err != OK:
		print("[CustomShape] Failed to parse shapesJson: ", json.get_error_message())
		return
		
	var shapes = json.data
	if typeof(shapes) != TYPE_ARRAY:
		print("[CustomShape] shapesJson is not an array")
		return
		
	# Detect format: Documentation format vs Old format
	if _is_documentation_format(shapes):
		_generate_from_documentation_format(parent, shapes, scale_factor, target_size)
	else:
		_generate_from_legacy_format(parent, shapes, scale_factor, target_size)

func _is_documentation_format(shapes: Array) -> bool:
	if shapes.size() == 0:
		return false
	var first = shapes[0]
	if typeof(first) != TYPE_DICTIONARY:
		return false
	# Documentation format has "points" and "thickness", not "id" and "extrude"
	return first.has("points") and first.has("thickness")

func _generate_from_documentation_format(parent: Node3D, shapes: Array, scale_factor: float, target_size: Vector3) -> void:
	# Treat as floor shapes by default
	generate_floor_shapes(parent, shapes, scale_factor * 10.0)
	
	# Apply target size scaling if specified
	if target_size.x > 0 or target_size.y > 0 or target_size.z > 0:
		var last_child = parent.get_child(parent.get_child_count() - 1)
		if last_child:
			_apply_target_size_scaling(last_child, shapes, scale_factor * 10.0, target_size)

func _apply_target_size_scaling(node: Node3D, shapes: Array, scale_factor: float, target_size: Vector3) -> void:
	# Calculate natural bounds
	var min_x = 999999.0
	var max_x = -999999.0
	var min_y = 999999.0
	var max_y = -999999.0
	var max_depth = 0.0
	
	for shape in shapes:
		if typeof(shape) != TYPE_DICTIONARY:
			continue
		var points = shape.get("points", [])
		if typeof(points) == TYPE_ARRAY:
			for p in points:
				if typeof(p) == TYPE_DICTIONARY:
					var px = float(p.get("x", 0))
					var py = float(p.get("y", 0))
					min_x = min(min_x, px)
					max_x = max(max_x, px)
					min_y = min(min_y, py)
					max_y = max(max_y, py)
		max_depth = max(max_depth, _parse_thickness(shape.get("thickness", 0)))
	
	var natural_w = (max_x - min_x) * scale_factor
	var natural_d = (max_y - min_y) * scale_factor
	var natural_h = max_depth * scale_factor
	
	var sx = target_size.x / natural_w if natural_w > 0.001 and target_size.x > 0 else 1.0
	var sz = target_size.z / natural_d if natural_d > 0.001 and target_size.z > 0 else 1.0
	var sy = target_size.y / natural_h if natural_h > 0.001 and target_size.y > 0 else 1.0
	
	# Center the shape
	var center_x = (min_x + max_x) / 2.0 * scale_factor
	var center_z = (min_y + max_y) / 2.0 * scale_factor
	
	node.position.x -= center_x
	node.position.z -= center_z
	node.scale = Vector3(sx, sy, sz)

func _generate_from_legacy_format(parent: Node3D, shapes: Array, scale_factor: float, target_size: Vector3) -> void:
	if shapes.size() == 0:
		return

	# ── Step 1: Parse all canvas-space bounds (raw pixel coords, no scaling yet) ──
	var min_x = 999999.0; var max_x = -999999.0
	var min_y = 999999.0; var max_y = -999999.0
	var found_bounds = false

	for shape in shapes:
		if typeof(shape) != TYPE_DICTIONARY: continue
		var type = str(shape.get("type", "")).to_lower()
		match type:
			"rectangle":
				if shape.has("start") and shape.has("end"):
					var sx2 = float(shape["start"].get("x", 0))
					var sy2 = float(shape["start"].get("y", 0))
					var ex2 = float(shape["end"].get("x", 0))
					var ey2 = float(shape["end"].get("y", 0))
					min_x = min(min_x, min(sx2, ex2)); max_x = max(max_x, max(sx2, ex2))
					min_y = min(min_y, min(sy2, ey2)); max_y = max(max_y, max(sy2, ey2))
					found_bounds = true
			"circle":
				if shape.has("center") and shape.has("radius"):
					var cx2 = float(shape["center"].get("x", 0))
					var cy2 = float(shape["center"].get("y", 0))
					var r2 = float(shape["radius"])
					min_x = min(min_x, cx2 - r2); max_x = max(max_x, cx2 + r2)
					min_y = min(min_y, cy2 - r2); max_y = max(max_y, cy2 + r2)
					found_bounds = true
			"polygon", "freehand", "line":
				var pts = shape.get("points", [])
				if typeof(pts) == TYPE_ARRAY:
					for p in pts:
						if typeof(p) == TYPE_DICTIONARY and p.has("x") and p.has("y"):
							min_x = min(min_x, float(p["x"])); max_x = max(max_x, float(p["x"]))
							min_y = min(min_y, float(p["y"])); max_y = max(max_y, float(p["y"]))
							found_bounds = true

	if not found_bounds:
		return

	var raw_cx = (min_x + max_x) / 2.0  # canvas-space center X
	var raw_cy = (min_y + max_y) / 2.0  # canvas-space center Y
	var raw_w  = max_x - min_x           # canvas-space width
	var raw_d  = max_y - min_y           # canvas-space depth

	# The build context uses scale_factor * 10.0 (same as legacy: mm * scale * 10)
	var build_scale = scale_factor * 10.0

	# ── Step 2: Build all CSG leaf nodes, already centered in canvas space ──
	var csg_nodes: Dictionary = {}
	for i in range(shapes.size()):
		var shape = shapes[i]
		if typeof(shape) != TYPE_DICTIONARY: continue
		var id = str(shape.get("id", ""))
		if id == "": continue

		# Pass the canvas-space center as an offset context so _map_pt can subtract it.
		# This means all polygon verts come out centered around (0,0) in Godot 2D space.
		var ctx = {"flip_y": false, "center_offset_x": raw_cx, "center_offset_y": raw_cy}
		var csg_node = _create_legacy_csg_node(shape, build_scale, ctx)
		if csg_node == null: continue

		# Apply per-shape material
		var mat = shape.get("material", null)
		if mat:
			_apply_material_to_node(csg_node, mat)

		# Solid shapes that are drawn on top of each other should be visually embossed.
		# We lift them by extrude_depth * build_scale so each layer stacks properly.
		if not shape.get("isHole", false) and i > 0:
			var prev_depth = 0.0
			for j in range(i):
				var ps = shapes[j]
				if typeof(ps) == TYPE_DICTIONARY and not ps.get("isHole", false):
					if ps.has("extrude") and typeof(ps["extrude"]) == TYPE_DICTIONARY:
						prev_depth = max(prev_depth, float(ps["extrude"].get("depth", 0)))
			# Lift this shape by the depth of the tallest shape beneath it
			csg_node.position.y += prev_depth * build_scale

		csg_nodes[id] = csg_node

	# ── Step 3: Wire up any hole children declared in shapes ──
	for shape in shapes:
		if typeof(shape) != TYPE_DICTIONARY: continue
		var id = str(shape.get("id", ""))
		var parent_node = csg_nodes.get(id)
		if parent_node == null: continue
		if shape.has("holes") and typeof(shape["holes"]) == TYPE_ARRAY:
			for hole_id in shape["holes"]:
				var hole_node = csg_nodes.get(str(hole_id))
				if hole_node and not hole_node.get_parent():
					parent_node.add_child(hole_node)

	# ── Step 4: Build combiner, apply target_size scaling, add to scene ──
	var combiner = CSGCombiner3D.new()
	combiner.name = "CustomShapeCombiner"
	combiner.operation = CSGShape3D.OPERATION_UNION

	# Apply target_size scaling if requested (target_size in Godot meters)
	if target_size.x > 0 or target_size.y > 0 or target_size.z > 0:
		# Natural Godot-unit size after build_scale
		var natural_w = raw_w * build_scale
		var natural_d = raw_d * build_scale
		var natural_h = 0.0
		for shape in shapes:
			if typeof(shape) == TYPE_DICTIONARY and shape.has("extrude"):
				var ext = shape["extrude"]
				if typeof(ext) == TYPE_DICTIONARY:
					natural_h = max(natural_h, float(ext.get("depth", 0)) * build_scale)

		var sx = target_size.x / natural_w if natural_w > 0.001 and target_size.x > 0 else 1.0
		var sy = target_size.y / natural_h if natural_h > 0.001 and target_size.y > 0 else 1.0
		var sz = target_size.z / natural_d if natural_d > 0.001 and target_size.z > 0 else 1.0
		combiner.scale = Vector3(sx, sy, sz)

	parent.add_child(combiner)

	# Add all unparented csg_nodes as combiner children
	for id in csg_nodes:
		var csg_node = csg_nodes[id]
		if not csg_node.get_parent():
			combiner.add_child(csg_node)

func _create_legacy_csg_node(shape: Dictionary, scale_factor: float, context: Dictionary) -> CSGShape3D:
	# Original legacy node creation code
	var type = str(shape.get("type", "")).to_lower()
	var is_hole = shape.get("isHole", false)
	
	var depth = 250.0
	if shape.has("extrude") and typeof(shape["extrude"]) == TYPE_DICTIONARY:
		if shape["extrude"].has("depth"):
			depth = float(shape["extrude"]["depth"])
			
	var scaled_depth = depth * scale_factor
	var csg: CSGShape3D = null
	
	if type in ["polygon", "rectangle", "freehand", "line"]:
		var csg_poly = CSGPolygon3D.new()
		csg_poly.mode = CSGPolygon3D.MODE_DEPTH
		csg_poly.depth = scaled_depth
		
		var points = shape.get("points", [])
		if type == "rectangle" and (points == null or typeof(points) != TYPE_ARRAY or points.size() == 0):
			if shape.has("start") and shape.has("end"):
				var st = shape["start"]
				var en = shape["end"]
				if typeof(st) == TYPE_DICTIONARY and typeof(en) == TYPE_DICTIONARY:
					points = [
						{"x": float(st.get("x", 0)), "y": float(st.get("y", 0))},
						{"x": float(en.get("x", 0)), "y": float(st.get("y", 0))},
						{"x": float(en.get("x", 0)), "y": float(en.get("y", 0))},
						{"x": float(st.get("x", 0)), "y": float(en.get("y", 0))}
					]
					
		if typeof(points) == TYPE_ARRAY:
			var vec2_array = PackedVector2Array()
			for p in points:
				if typeof(p) == TYPE_DICTIONARY and p.has("x") and p.has("y"):
					var mapped = _map_pt(float(p["x"]), float(p["y"]), scale_factor, context)
					vec2_array.append(mapped)
			
			if vec2_array.size() >= 3:
				var signed_area = 0.0
				for pi in range(vec2_array.size()):
					var pa = vec2_array[pi]
					var pb = vec2_array[(pi + 1) % vec2_array.size()]
					signed_area += (pa.x * pb.y - pb.x * pa.y)
				if signed_area < 0:
					vec2_array.reverse()
				csg_poly.polygon = vec2_array
				csg = csg_poly
	elif type == "circle":
		var csg_poly = CSGPolygon3D.new()
		csg_poly.mode = CSGPolygon3D.MODE_DEPTH
		csg_poly.depth = scaled_depth
		
		var radius = float(shape.get("radius", 100.0)) * scale_factor
		var center = shape.get("center", {"x": 0, "y": 0})
		var cx = 0.0
		var cy = 0.0
		if typeof(center) == TYPE_DICTIONARY:
			cx = float(center.get("x", 0))
			cy = float(center.get("y", 0))
			
		var mapped_center = _map_pt(cx, cy, scale_factor, context)
		
		var vec2_array = PackedVector2Array()
		var segments = 32
		for i in range(segments):
			var angle = i * (2.0 * PI / segments)
			vec2_array.append(Vector2(mapped_center.x + cos(angle) * radius, mapped_center.y + sin(angle) * radius))
			
		var signed_area = 0.0
		for pi in range(vec2_array.size()):
			var pa = vec2_array[pi]
			var pb = vec2_array[(pi + 1) % vec2_array.size()]
			signed_area += (pa.x * pb.y - pb.x * pa.y)
		if signed_area < 0:
			vec2_array.reverse()
			
		csg_poly.polygon = vec2_array
		csg = csg_poly
	elif type == "arc":
		var csg_poly = CSGPolygon3D.new()
		csg_poly.mode = CSGPolygon3D.MODE_DEPTH
		csg_poly.depth = scaled_depth
		
		var center = shape.get("center", {"x": 0, "y": 0})
		var cx = 0.0
		var cy = 0.0
		if typeof(center) == TYPE_DICTIONARY:
			cx = float(center.get("x", 0))
			cy = float(center.get("y", 0))
			
		var mapped_center = _map_pt(cx, cy, scale_factor, context)
		var radius = float(shape.get("radius", 100.0)) * scale_factor
		var start_angle = float(shape.get("arcStartAngle", 0.0))
		var end_angle = float(shape.get("arcEndAngle", PI * 2.0))
		
		if context.get("flip_y", false):
			var temp2 = start_angle
			start_angle = -end_angle
			end_angle = -temp2
			
		var vec2_array = PackedVector2Array()
		var is_full_circle = abs(end_angle - start_angle) >= (PI * 2.0 - 0.001)
		
		if not is_full_circle:
			vec2_array.append(mapped_center)
		
		var segments = 32
		var angle_step = (end_angle - start_angle) / segments
		var points_to_generate = segments if is_full_circle else segments + 1
		
		for i in range(points_to_generate):
			var angle = start_angle + i * angle_step
			vec2_array.append(Vector2(mapped_center.x + cos(angle) * radius, mapped_center.y + sin(angle) * radius))
			
		var signed_area = 0.0
		for pi in range(vec2_array.size()):
			var pa = vec2_array[pi]
			var pb = vec2_array[(pi + 1) % vec2_array.size()]
			signed_area += (pa.x * pb.y - pb.x * pa.y)
		if signed_area < 0:
			vec2_array.reverse()
		csg_poly.polygon = vec2_array
		csg = csg_poly
		
	if csg == null:
		return null
		
	csg.operation = CSGShape3D.OPERATION_SUBTRACTION if is_hole else CSGShape3D.OPERATION_UNION
	_apply_material_to_node(csg, shape.get("material", null))
	
	var orientation = str(shape.get("orientation", "top")).to_lower()
	if not (context.has("surface_type") and context["surface_type"] == "wall"):
		if orientation == "top":
			csg.transform = csg.transform.rotated(Vector3(1, 0, 0), deg_to_rad(90))
	
	return csg

func _map_pt(px: float, py: float, scale_factor: float, context: Dictionary) -> Vector2:
	# Subtract canvas-space center offset BEFORE scaling so that all vertex coordinates
	# are centered around (0,0). This is used by the legacy format generator.
	if context.has("center_offset_x"):
		px -= context["center_offset_x"]
	if context.has("center_offset_y"):
		py -= context["center_offset_y"]
	px = px * scale_factor
	py = py * scale_factor
	if context.has("surface_type") and context["surface_type"] == "wall":
		var face = context.get("face", "inner")
		var p1 = context.get("p1", Vector2.ZERO)
		var p2 = context.get("p2", Vector2.ZERO)
		var length = p1.distance_to(p2)
		var height = context.get("height", 0.0)
		if face == "outer":
			px = length - px
		py = height - py
	elif context.get("flip_y", false):
		py = -py
	return Vector2(px, py)
