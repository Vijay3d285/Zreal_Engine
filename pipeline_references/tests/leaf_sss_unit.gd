extends SceneTree

# Preloaded, not global class names: the live pipeline has no class cache.
const ImageGlb = preload("res://image_glb_creation.gd")
const VideoGlb = preload("res://video_glb_creation.gd")

## Headless checks for which GLB materials get the thin-wall "leaf" subsurface preset
## (GLB_SUBSURFACE_PRESETS, _glb_is_plant_asset, _glb_is_leaf_green), run against BOTH routes:
## image_glb_creation.gd (stills: every preset row) and video_glb_creation.gd (walkthroughs: the
## leaf row only, ported 2026-10-23).
##
## Run it from a copy of pipeline_references WITHOUT .godot/ (the repo's class cache has a
## duplicate CustomShapeGenerator):
##   bin\godot.windows.editor.x86_64.console.exe --headless --path <copy> -s res://tests/leaf_sss_unit.gd
##
## The colours are the measured averages (albedo x albedo-texture mean) of library assets,
## 2026-10-23: dc3cfb7e_IndoorPlant Material.002 (leaves) and Material.001 (pot), the Areca palm
## "plant", a blue pot, a pale rubber-plant underside and a yellow-green hedge cluster.

var _failures: Array[String] = []
var _checks := 0
var _label := ""


func _check_true(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	_checks += 1
	var name := "[%s] %s" % [_label, p_name]
	print("  %s: %s %s" % [name, "ok" if p_cond else "FAILED", p_detail])
	if not p_cond:
		_failures.append("%s %s" % [name, p_detail])


func _preset_for(p_glb, p_name: String) -> String:
	return p_glb._apply_glb_subsurface_preset(StandardMaterial3D.new(), p_name)


## A MeshInstance3D with one triangle per material.
func _mesh(p_mats: Array) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for mat in p_mats:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.add_vertex(Vector3(0, 0, 0))
		st.add_vertex(Vector3(1, 0, 0))
		st.add_vertex(Vector3(0, 1, 0))
		st.set_material(mat)
		st.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _mat(p_name: String, p_color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = p_name
	m.albedo_color = p_color
	return m


func _sss(p_mi: MeshInstance3D, p_surface: int) -> bool:
	var m = p_mi.get_surface_override_material(p_surface)
	return m != null and m is BaseMaterial3D and (m as BaseMaterial3D).subsurf_scatter_enabled


## Every leaf check against one route's script. p_all_presets: the route also carries the
## marble / wax / lampshade rows (stills); video ports the leaf row only.
func _suite(glb, p_label: String, p_all_presets: bool) -> void:
	_label = p_label
	print("\n=== leaf_sss_unit [%s]: names ===" % p_label)
	for n in ["Plant.001", "plant", "Leaves_2.001", "Foliage_A", "palm_frond", "fern", "GRASS", "Leaf", "leaf_stalk_01"]:
		_check_true("K1 '%s' -> leaf" % n, _preset_for(glb, n) in ["leaf", "leaves", "foliage", "frond", "fern", "grass", "plant"],
				"(%s)" % _preset_for(glb, n))
	for n in ["Planter", "plant_pot", "PlantVase", "plant soil", "Grasscloth", "Pot", "Wood.012", "Material.001"]:
		_check_true("K2 '%s' -> no preset" % n, _preset_for(glb, n) == "", "(%s)" % _preset_for(glb, n))
	if p_all_presets:
		_check_true("K3 'marble' still -> marble", _preset_for(glb, "marble") == "marble")
		_check_true("K3 'lampshade' still -> lampshade", _preset_for(glb, "lampshade") == "lampshade")
	else:
		_check_true("K3 'marble' -> no preset (leaves only on this route)", _preset_for(glb, "marble") == "")
	var leaf := StandardMaterial3D.new()
	glb._apply_glb_subsurface_preset(leaf, "Plant.001")
	_check_true("K4 leaf preset is thin-wall at 0.5", leaf.subsurf_scatter_enabled and is_equal_approx(leaf.subsurf_scatter_strength, 0.5)
			and leaf.subsurf_scatter_transmittance_depth == 0.0, "(strength %.2f depth %.2f)" % [leaf.subsurf_scatter_strength, leaf.subsurf_scatter_transmittance_depth])

	print("\n=== leaf_sss_unit [%s]: plant assets ===" % p_label)
	for a in ["dc3cfb7e_IndoorPlant_HP_high.glb", "19d8a27f_DecorativeIndoorArecaPalmPlant_HP_high.glb",
			"6ba6ffa3_ShortPineTree_HP_modified_high.glb", "db8de83e_Bushes_HP_modified_high.glb",
			"17c3dfcf_HedgePlant_HP_high.glb", "fdf95e70_IndoorRubberPlant_HP_high.glb"]:
		_check_true("A1 '%s' is a plant" % a, glb._glb_is_plant_asset(a))
	for a in ["54fb6182_EmeraldPalmArtDecoWallFrame_HP_high.glb", "0e573d93_MinimalTreeArtworkFrame_HP_high.glb",
			"4b8057b1_DecorativeHangingWallPlanterLight_HP_high.glb", "da026c98_FreshwaterPlantedGlassAquarium_HP_high.glb",
			"93c4d017_MetallicLeafDecorSet_HP_high.glb", "ad283975_RusticSolidWoodRectangularCoffeeTable_HP_high.glb", ""]:
		_check_true("A2 '%s' is not a plant" % a, not glb._glb_is_plant_asset(a))

	print("\n=== leaf_sss_unit [%s]: green ===" % p_label)
	for c in [Color(0.34, 0.43, 0.09), Color(0.33, 0.48, 0.09), Color(0.27, 0.35, 0.26), Color(0.01, 0.73, 0.00), Color(0.14, 0.17, 0.06)]:
		_check_true("G1 %s is leaf green" % str(c), glb._glb_is_leaf_green(c))
	for c in [Color(0.20, 0.17, 0.17), Color(0.27, 0.38, 0.73), Color(0.62, 0.64, 0.54), Color(0.59, 0.62, 0.24),
			Color(0.53, 0.47, 0.31), Color(0.5, 0.5, 0.5), Color(0, 0, 0)]:
		_check_true("G2 %s is not leaf green" % str(c), not glb._glb_is_leaf_green(c))
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.8, 0.1))
	var textured := _mat("Material.009", Color(1.0, 0.5, 1.0))
	textured.albedo_texture = ImageTexture.create_from_image(img)
	var avg: Color = glb._glb_material_avg_color(textured)
	_check_true("G3 average colour is albedo x texture mean", absf(avg.r - 0.2) < 0.02 and absf(avg.g - 0.4) < 0.02 and absf(avg.b - 0.1) < 0.02, str(avg))

	print("\n=== leaf_sss_unit [%s]: _apply_glb_subsurface ===" % p_label)
	var pot := _mat("Material.001", Color(0.20, 0.17, 0.17))
	var leaves := _mat("Material.002", Color(0.34, 0.43, 0.09))
	var plant := _mesh([pot, leaves])
	var root := Node3D.new()
	root.add_child(plant)
	glb._apply_glb_subsurface(root, "dc3cfb7e_IndoorPlant_HP_high.glb")
	_check_true("P1 plant asset: green unnamed material gets the leaf preset", _sss(plant, 1))
	_check_true("P1 plant asset: dark pot material is left alone", not _sss(plant, 0))
	_check_true("P1 the shared material resource is not mutated", not leaves.subsurf_scatter_enabled)
	var frame := _mesh([_mat("image", Color(0.33, 0.48, 0.09))])
	var root2 := Node3D.new()
	root2.add_child(frame)
	glb._apply_glb_subsurface(root2, "54fb6182_EmeraldPalmArtDecoWallFrame_HP_high.glb")
	_check_true("P2 a green picture in a palm wall frame stays opaque", not _sss(frame, 0))
	var table := _mesh([_mat("Material.004", Color(0.01, 0.73, 0.00))])
	var root3 := Node3D.new()
	root3.add_child(table)
	glb._apply_glb_subsurface(root3, "ad283975_RusticSolidWoodRectangularCoffeeTable_HP_high.glb")
	_check_true("P3 green paint on a non-plant asset stays opaque", not _sss(table, 0))
	root.free()
	root2.free()
	root3.free()
	glb.free()


func _init() -> void:
	_suite(ImageGlb.new(), "stills", true)
	_suite(VideoGlb.new(), "video", false)

	print("")
	if _failures.is_empty():
		print("PASS: all %d leaf checks passed." % _checks)
		quit(0)
	else:
		for f in _failures:
			print("FAIL - %s" % f)
		print("FAIL: %d of %d checks failed." % [_failures.size(), _checks])
		quit(1)
