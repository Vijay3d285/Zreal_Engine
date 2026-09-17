extends "res://tests/pt_validation.gd"

## Many-light noise probe -- our tracer's half of
## tools/cycles_comparison/cycles_manylight_noise.py (2026-09-17).
##
##   bin\godot.windows.editor.x86_64.console.exe --rendering-driver vulkan \
##       --path pipeline_references res://tests/pt_manylight_noise_probe_scene.tscn
##
## The same 6 x 4 x 2.8 m box room (walls 0.6, ceiling 0.7, floor 0.4),
## sixteen identical hard point lights on a 4 x 4 grid at 1.9 m, no sky, the
## same camera (Blender (-1.5, -1, 1.2) looking at (2, 1.5, 2.8), 60 deg
## horizontal), 512 x 288, 256 accumulated samples, no denoiser, no clamp, 12
## bounces. Prints the robust relative noise (MAD / median) of the same two
## frame patches the Cycles script prints, and writes the raw frame as PFM to
## ZR_PROBE_OUT when set. Not a gate: it has no pass / fail, it is a
## measurement to set beside Cycles' (roadmap Gap #30 follow-up).

var FRAMES: int = 256 if OS.get_environment("ZR_PROBE_FRAMES") == "" else int(OS.get_environment("ZR_PROBE_FRAMES"))
const ROOM := Vector3(6.0, 2.8, 4.0) # Godot: x width, y height, z depth (Blender y -> Godot -z)
## ZR_PROBE_WIRE=1: the pipeline's kind of rig (wide spots aimed down, the
## ceiling lit by bounce alone) plus a 3 mm dark cable 5 cm under the ceiling,
## and the OIDN final pass; writes wire_godot_raw.pfm and wire_godot_oidn.pfm.
var _wire := OS.get_environment("ZR_PROBE_WIRE") == "1"


func _ready() -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(512, 288)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	get_viewport().use_taa = false
	get_viewport().use_debanding = false
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await get_tree().process_frame
	await get_tree().process_frame

	get_viewport().use_hdr_2d = true
	var env := _new_env(Color(0, 0, 0))
	env.set_pathtracing_max_bounces(12)
	if _wire:
		env.set_pathtracing_oidn_denoise(true)

	var w := ROOM.x
	var h := ROOM.y
	var d := ROOM.z
	_wall(Vector3(0, 0, 0), Vector3(0, 1, 0), Vector2(w, d), 0.4) # floor, faces up
	_wall(Vector3(0, h, 0), Vector3(0, -1, 0), Vector2(w, d), 0.7) # ceiling, faces down
	_wall(Vector3(0, h / 2, -d / 2), Vector3(0, 0, 1), Vector2(w, h), 0.6) # Blender y+ wall
	_wall(Vector3(0, h / 2, d / 2), Vector3(0, 0, -1), Vector2(w, h), 0.6) # Blender y- wall
	_wall(Vector3(w / 2, h / 2, 0), Vector3(-1, 0, 0), Vector2(d, h), 0.6) # x+ wall
	_wall(Vector3(-w / 2, h / 2, 0), Vector3(1, 0, 0), Vector2(d, h), 0.6) # x- wall

	for i in range(4):
		for j in range(4):
			# Blender (x, y, z) -> Godot (x, z, -y).
			var pos := Vector3(-w * 0.375 + i * w * 0.25, 1.9, -(-d * 0.375 + j * d * 0.25))
			if _wire:
				var sl := SpotLight3D.new()
				sl.position = pos
				sl.rotation_degrees = Vector3(-90, 0, 0) # -Z -> down
				sl.light_energy = 10.0
				sl.spot_angle = 45.0 # 90 deg cone, as Cycles' spot_size 90
				sl.spot_angle_attenuation = 1.0
				sl.spot_range = 14.0
				sl.spot_attenuation = 1.0
				sl.light_size = 0.0
				sl.shadow_enabled = true
				add_child(sl)
			else:
				var l := OmniLight3D.new()
				l.position = pos
				l.light_energy = 5.0
				l.omni_range = 14.0
				l.omni_attenuation = 1.0
				l.light_size = 0.0
				l.shadow_enabled = true
				add_child(l)
	if _wire:
		var cable := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0015
		cm.bottom_radius = 0.0015
		cm.height = w
		cm.radial_segments = 12
		cable.mesh = cm
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color(0.1, 0.1, 0.1)
		cmat.roughness = 1.0
		cmat.metallic = 0.0
		cmat.metallic_specular = 0.0
		cable.material_override = cmat
		# Blender: along x at (0, 1.0, h - 0.05) -> Godot (0, h - 0.05, -1.0); a
		# CylinderMesh stands along Y, so roll it onto X.
		cable.position = Vector3(0, h - 0.05, -1.0)
		cable.rotation_degrees = Vector3(0, 0, 90)
		add_child(cable)

	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = 60.0
	cam.near = 0.05
	cam.far = 50.0
	add_child(cam)
	cam.look_at_from_position(Vector3(-1.5, 1.2, 1.0), Vector3(2.0, 2.8, -1.5), Vector3.UP)
	cam.make_current()
	await get_tree().create_timer(1.0).timeout

	var img: Image = await _render_accum(env, get_viewport().get_viewport_rid(), FRAMES)
	var out := OS.get_environment("ZR_PROBE_OUT")
	if out != "":
		_save_pfm(img, out.path_join("wire_godot_raw.pfm" if _wire else "manylight_godot.pfm"))
	if _wire and out != "":
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var den: Image = get_viewport().get_texture().get_image()
		_save_pfm(den, out.path_join("wire_godot_oidn.pfm"))
	print("\n=== MANY-LIGHT NOISE, our tracer, %d spp, 16 point lights ===" % FRAMES)
	for probe in [["ceiling", 0.35, 0.05, 0.65, 0.25], ["wall", 0.70, 0.55, 0.95, 0.85]]:
		var st := _robust(img, probe[1], probe[2], probe[3], probe[4])
		print("  %-8s median %.5f  robust noise %.1f%%  max/median %.0fx" % [probe[0], st["median"], 100.0 * st["rel"], st["maxratio"]])
	print("PROBE DONE")
	get_tree().quit(0)


func _wall(p_pos: Vector3, p_normal: Vector3, p_size: Vector2, p_albedo: float) -> void:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = p_size
	mi.mesh = qm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(p_albedo, p_albedo, p_albedo)
	m.roughness = 1.0
	m.metallic = 0.0
	m.metallic_specular = 0.0
	mi.material_override = m
	add_child(mi)
	# A QuadMesh faces +Z: aim +Z along the inward normal.
	if absf(p_normal.dot(Vector3.UP)) > 0.99:
		mi.look_at_from_position(p_pos, p_pos - p_normal, Vector3.FORWARD)
	else:
		mi.look_at_from_position(p_pos, p_pos - p_normal, Vector3.UP)


func _robust(p_img: Image, fx0: float, fy0: float, fx1: float, fy1: float) -> Dictionary:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var vals: Array[float] = []
	for y in range(int(fy0 * h), int(fy1 * h)):
		for x in range(int(fx0 * w), int(fx1 * w)):
			var c := p_img.get_pixel(x, y)
			vals.append((c.r + c.g + c.b) / 3.0)
	vals.sort()
	var med: float = vals[vals.size() / 2]
	var dev: Array[float] = []
	for v in vals:
		dev.append(absf(v - med))
	dev.sort()
	var mad: float = dev[dev.size() / 2] * 1.4826
	return {"median": med, "rel": mad / maxf(med, 1e-9), "maxratio": vals[vals.size() - 1] / maxf(med, 1e-9)}


func _save_pfm(p_img: Image, p_path: String) -> void:
	var w := p_img.get_width()
	var h := p_img.get_height()
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("PF\n%d %d\n-1.0\n" % [w, h])
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	for y in range(h - 1, -1, -1):
		for x in range(w):
			var c := p_img.get_pixel(x, y)
			buf.put_float(c.r)
			buf.put_float(c.g)
			buf.put_float(c.b)
	f.store_buffer(buf.data_array)
	f.close()


func _new_env(p_bg: Color) -> Environment:
	var pano := Image.create(8, 4, false, Image.FORMAT_RGBF)
	pano.fill(p_bg)
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = ImageTexture.create_from_image(pano)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	env.set_pathtracing_enabled(true)
	env.set_pathtracing_samples_per_pixel(1)
	env.set_pathtracing_denoiser(0)
	env.set_pathtracing_oidn_denoise(false)
	env.set_pathtracing_dlss_rr_final(false)
	env.set_pathtracing_clamp_direct(0.0)
	env.set_pathtracing_clamp_indirect(0.0)
	env.set_pathtracing_noise_threshold(0.0)
	return env
